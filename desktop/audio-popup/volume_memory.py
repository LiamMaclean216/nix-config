"""Remember playback app levels across stream recreation, independently of devices."""
import json
import math
import os
from pathlib import Path
import socket
import tempfile
import time


def application_key(item):
    props = item.proplist
    for prop in ("application.id", "application.name", "application.process.binary"):
        if props.get(prop):
            return prop + ":" + str(props[prop])
    return None


def socket_path():
    return str(Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
               / "audio-popup-volume.sock")


def valid_volume(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and 0 <= value <= 1.5)


def remember_volume(item, value):
    """Notify the sole state writer after a successful explicit app-slider edit."""
    key = application_key(item)
    if not key or not valid_volume(value):
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as client:
            client.setblocking(False)
            client.sendto(json.dumps({"app": key, "volume": value}).encode(), socket_path())
        return True
    except OSError:
        # The popup still controls audio when the optional service is unavailable.
        return False


class VolumeMemory:
    SETTLE_SECONDS = 0.75
    EPSILON = 0.0001

    def __init__(self, path):
        self.path = Path(path)
        self.volumes = {}
        try:
            data = json.loads(self.path.read_text())
            if data.get("version") == 1 and isinstance(data.get("volumes"), dict):
                self.volumes = {k: v for k, v in data["volumes"].items()
                                if isinstance(k, str) and valid_volume(v)}
        except (OSError, ValueError, AttributeError):
            pass
        self.streams = {}
        self.initialized = False
        self.explicit = set()
        self.dirty = False

    def save(self, key, volume):
        if valid_volume(volume) and abs(self.volumes.get(key, -1) - volume) > self.EPSILON:
            self.volumes[key] = volume
            self.dirty = True

    def remember(self, message):
        if not isinstance(message, dict):
            return
        key, value = message.get("app"), message.get("volume")
        if isinstance(key, str) and len(key) <= 4096 and valid_volume(value):
            self.save(key, value)
            # The next fresh snapshot is the result of the user's edit. Do not
            # mistake it for an app's initial volume or restore an older value.
            self.explicit.add(key)

    def flush(self):
        if not self.dirty:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=self.path.parent,
                                             prefix=".volumes-", delete=False) as target:
                temporary = target.name
                json.dump({"version": 1, "volumes": self.volumes}, target)
                target.flush()
                os.fsync(target.fileno())
            os.replace(temporary, self.path)
            self.dirty = False
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)

    def disconnected(self):
        self.streams.clear()
        self.explicit.clear()

    def apply(self, item, target, set_volume):
        current = item.volume.value_flat
        if abs(target - current) > self.EPSILON:
            # Scale channel levels together, retaining a custom balance.
            if current > 0:
                item.volume.values = [v * target / current for v in item.volume.values]
            else:
                item.volume.values = [target for _ in item.volume.values]
            set_volume(item, item.volume)
        return target

    def tick(self, items, now, set_volume):
        seen = set()
        for item in items:
            key = application_key(item)
            volume = item.volume.value_flat
            if not key or not valid_volume(volume):
                continue
            # The serial disambiguates reused server indices. Only the stable
            # application key is persisted; neither field reaches the state file.
            identity = (item.index, item.proplist.get("object.serial"), key)
            seen.add(identity)
            state = self.streams.get(identity)
            if state is None:
                state = {"app": key, "last": volume,
                         "pending": now + self.SETTLE_SECONDS if self.initialized else None}
                self.streams[identity] = state
                if not self.initialized and key not in self.volumes:
                    self.save(key, volume)
            if key in self.explicit:
                # An older restore may have raced the popup's successful write
                # just before its message arrived. Ensure the explicit edit wins.
                volume = self.apply(item, self.volumes[key], set_volume)
                state.update(last=volume, pending=None)
            elif state["pending"] is not None:
                if now < state["pending"]:
                    continue
                target = self.volumes.get(key)
                if target is not None and abs(target - volume) > self.EPSILON:
                    volume = self.apply(item, target, set_volume)
                elif target is None:
                    self.save(key, volume)
                state.update(last=volume, pending=None)
            elif abs(state["last"] - volume) > self.EPSILON:
                # Later edits from pavucontrol, media keys or the app itself are
                # authoritative; this is a one-time restore, not a volume lock.
                self.save(key, volume)
                state["last"] = volume
        self.streams = {key: value for key, value in self.streams.items() if key in seen}
        self.initialized = True
        self.explicit.clear()


def main():
    import fcntl
    import select
    import sys
    import pulsectl

    state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    memory = VolumeMemory(state_home / "audio-popup/volumes.json")
    address = socket_path()
    # Do not unlink a running instance's socket if started twice accidentally.
    lock = open(address + ".lock", "a")
    os.chmod(address + ".lock", 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    pulse = None
    retry_at = 0
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as server:
        try:
            Path(address).unlink(missing_ok=True)
            server.bind(address)
            os.chmod(address, 0o600)
            server.setblocking(False)
            while True:
                # Drain explicit edits before taking the audio snapshot and
                # before applying any delayed restore.
                while True:
                    try:
                        raw = server.recv(8192)
                    except BlockingIOError:
                        break
                    try:
                        memory.remember(json.loads(raw))
                    except (ValueError, UnicodeError):
                        pass
                now = time.monotonic()
                if pulse is None and now >= retry_at:
                    try:
                        pulse = pulsectl.Pulse("audio-popup-volume-memory")
                    except pulsectl.PulseError:
                        retry_at = now + 1
                if pulse is not None:
                    try:
                        memory.tick(pulse.sink_input_list(), now, pulse.volume_set)
                    except pulsectl.PulseError:
                        pulse.close()
                        pulse = None
                        memory.disconnected()
                        retry_at = now + 1
                try:
                    memory.flush()
                except OSError as error:
                    print(f"Could not save app volumes: {error}", file=sys.stderr)
                select.select([server], [], [], 0.15)
        finally:
            if pulse is not None:
                pulse.close()
            Path(address).unlink(missing_ok=True)
            lock.close()


if __name__ == "__main__":
    main()
