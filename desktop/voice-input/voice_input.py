"""Hold Mouse 5 to stream microphone audio to Soniox. No audio is saved."""

import argparse
import asyncio
import contextlib
import fcntl
import getpass
import json
import os
import re
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path

ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket"
MAX_SECONDS = 180


class DictationError(RuntimeError):
    """A user-facing failure that never includes credentials or transcript data."""


def key_path():
    return (
        Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        / "voice-input/api-key"
    )


def socket_path():
    return str(Path(os.environ["XDG_RUNTIME_DIR"]) / "voice-input.sock")


def read_key():
    key = os.environ.get("SONIOX_API_KEY", "").strip()
    if not key:
        try:
            key = key_path().read_text().strip()
        except FileNotFoundError:
            pass
    if not key:
        raise DictationError("Run voice-input setup-key in a terminal first.")
    return key


class Transcript:
    def __init__(self):
        self.final = ""
        self.partial = ""

    def update(self, message):
        if not isinstance(message, dict):
            raise DictationError(
                "Soniox returned an invalid response. Please try again."
            )
        if message.get("error_code") or message.get("error_type"):
            # Don't log server payloads or credentials.
            raise DictationError(
                f"Soniox error: {message.get('error_type', message.get('error_code'))}"
            )
        # Status/keepalive messages must not erase the live provisional words.
        if "tokens" not in message:
            return self.final + self.partial
        tokens = message["tokens"]
        if not isinstance(tokens, list):
            raise DictationError("Soniox returned invalid transcript tokens.")
        partial = []
        for token in tokens:
            if not isinstance(token, dict) or not isinstance(token.get("text"), str):
                raise DictationError("Soniox returned an invalid transcript token.")
            text = token.get("text", "")
            if text in {"<end>", "<fin>"}:
                continue
            if token.get("is_final"):
                self.final += text
            else:
                partial.append(text)
        self.partial = "".join(partial)
        return self.final + self.partial

    def result(self):
        # Normalize dictated whitespace; submission adds exactly one Return below.
        return " ".join(self.final.split())


async def command(*args, data=None, timeout=5):
    proc = await asyncio.create_subprocess_exec(
        *args,
        stdin=asyncio.subprocess.PIPE
        if data is not None
        else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        output, _ = await asyncio.wait_for(proc.communicate(data), timeout=timeout)
        if proc.returncode:
            raise DictationError(f"{args[0]} failed.")
        return output
    finally:
        if proc.returncode is None:
            proc.kill()
            await proc.wait()


async def focused_window():
    return json.loads(await command("hyprctl", "activewindow", "-j")).get("address")


async def send_shortcut(modifiers, key, target):
    # Only compositor addresses and fixed key names enter the Lua expression;
    # dictated text travels exclusively through wl-copy's stdin.
    if not isinstance(target, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", target):
        raise DictationError("No valid focused window; text was not inserted.")
    dispatcher = (
        "hl.dsp.send_shortcut({"
        f"mods = {json.dumps(modifiers)}, key = {json.dumps(key)}, "
        f'window = "address:{target}"'
        "})"
    )
    try:
        await command("hyprctl", "dispatch", dispatcher)
    except DictationError:
        raise DictationError(
            "Hyprland could not send the shortcut. Text is available in the clipboard."
        ) from None


class Session:
    def __init__(self, ui):
        self.ui = ui
        self.released = asyncio.Event()
        self.recorder = None
        self.target = None
        self.target_task = None

    def stop(self):
        if self.released.is_set():
            return
        self.released.set()
        self.target_task = asyncio.create_task(focused_window())
        self.stop_recorder()
        self.ui("status", "Finishing…")

    def stop_recorder(self):
        if self.recorder and self.recorder.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                self.recorder.terminate()

    async def insert_text(self, text):
        window = json.loads(await command("hyprctl", "activewindow", "-j"))
        if window.get("address") != self.target:
            raise DictationError("Focus changed; text was not pasted.")
        # A real clipboard paste reaches terminals as bracketed paste, avoiding
        # Vim insert mappings/completion and per-character keyboard timing.
        await command(
            "wl-copy", "--type", "text/plain;charset=utf-8", data=text.encode()
        )
        if await focused_window() != self.target:
            raise DictationError("Focus changed; text was not pasted.")
        terminal_classes = {
            "alacritty",
            "kitty",
            "foot",
            "footclient",
            "wezterm",
            "org.wezfurlong.wezterm",
            "org.gnome.terminal",
            "gnome-terminal",
            "konsole",
            "com.mitchellh.ghostty",
        }
        modifiers = (
            "CTRL SHIFT"
            if window.get("class", "").lower() in terminal_classes
            else "CTRL"
        )
        await send_shortcut(modifiers, "v", self.target)
        # Clipboard transfer and application processing are asynchronous. Keep
        # Enter separate, and leave a cancellation window after the paste.
        await asyncio.sleep(0.25)
        if await focused_window() != self.target:
            raise DictationError("Focus changed after pasting; Enter was not pressed.")
        await send_shortcut("", "Return", self.target)

    async def capture(self, queue):
        try:
            while chunk := await self.recorder.stdout.read(3200):
                # Bound the pre-connection/network backlog to about 30 seconds.
                queue.put_nowait(chunk)
            await self.recorder.wait()
            if not self.released.is_set():
                raise DictationError(
                    "Microphone stopped. Check your default input device."
                )
            queue.put_nowait(None)
        except asyncio.QueueFull:
            raise DictationError("Audio upload stalled. Please try again.") from None

    async def send_audio(self, ws, queue):
        while (chunk := await queue.get()) is not None:
            await ws.send(chunk)
        # Soniox reliably finalizes on an empty TEXT message. An empty binary
        # message can leave the server waiting for more audio indefinitely.
        await ws.send("")

    async def receive(self, ws, transcript):
        async for payload in ws:
            # A blank transport message is not Soniox's `finished` response.
            # Keep waiting within the completion deadline, without parsing it.
            if not payload.strip():
                continue
            try:
                message = json.loads(payload)
            except (ValueError, UnicodeError):
                raise DictationError(
                    "Soniox returned an unreadable response. Please try again."
                ) from None
            transcript.update(message)
            self.ui("text", (transcript.final, transcript.partial))
            if message.get("finished"):
                return
        raise DictationError("Soniox disconnected before finishing. Please try again.")

    async def run(self):
        from websockets.asyncio.client import connect

        tasks = []
        try:
            key = read_key()
            self.ui("show", "Listening…")
            self.recorder = await asyncio.create_subprocess_exec(
                "pw-record",
                "--raw",
                "--format",
                "s16",
                "--rate",
                "16000",
                "--channels",
                "1",
                "--latency",
                "50ms",
                "-",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            if self.released.is_set():
                self.stop_recorder()
            queue = asyncio.Queue(maxsize=300)
            capture = asyncio.create_task(self.capture(queue))
            tasks.append(capture)
            transcript = Transcript()
            async with connect(ENDPOINT, open_timeout=8, close_timeout=2) as ws:
                await ws.send(
                    json.dumps(
                        {
                            "api_key": key,
                            "model": os.environ.get("SONIOX_MODEL", "stt-rt-v5"),
                            "audio_format": "pcm_s16le",
                            "sample_rate": 16000,
                            "num_channels": 1,
                            "language_hints": ["en"],
                            "enable_endpoint_detection": True,
                        }
                    )
                )
                sender = asyncio.create_task(self.send_audio(ws, queue))
                receiver = asyncio.create_task(self.receive(ws, transcript))
                tasks.extend([sender, receiver])
                # Surface capture/network errors immediately, including before release.
                done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
                if receiver in done and not self.released.is_set():
                    raise DictationError(
                        "Soniox ended the session early. Please try again."
                    )
                await capture
                await asyncio.wait_for(sender, timeout=10)
                await asyncio.wait_for(receiver, timeout=15)
                # Deliver finalized text before the WebSocket close handshake,
                # which can take about a second even after `finished` arrives.
                text = transcript.result()
                if text:
                    self.target = await self.target_task if self.target_task else None
                    if not self.target or await focused_window() != self.target:
                        raise DictationError(
                            "Focus changed while finishing; text was not inserted."
                        )
                    self.ui("status", "Pasting…")
                    await self.insert_text(text)
                    self.ui("hide", "")
                else:
                    self.ui("error", "No speech detected. Hold Mouse 5 and try again.")
        finally:
            self.stop_recorder()
            for task in tasks:
                task.cancel()
            if self.target_task:
                tasks.append(self.target_task)
                self.target_task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            if self.recorder:
                try:
                    await asyncio.wait_for(self.recorder.wait(), timeout=2)
                except asyncio.TimeoutError:
                    self.recorder.kill()
                    await self.recorder.wait()


class Daemon:
    def __init__(self, ui):
        self.ui = ui
        self.session = None
        self.task = None
        self.tasks = set()
        self.last_event = 0

    async def run_session(self, session):
        try:
            async with asyncio.timeout(MAX_SECONDS):
                await session.run()
        except asyncio.CancelledError:
            session.ui("hide", "")
            raise
        except TimeoutError:
            session.ui("error", "Dictation timed out. Hold Mouse 5 to try again.")
        except Exception as exc:  # noqa: BLE001 -- keep the desktop daemon alive after session failures.
            message = (
                str(exc)
                if isinstance(exc, DictationError)
                else "Connection failed. Check your network and Soniox key."
            )
            session.ui("error", message)
        finally:
            if self.session is session:
                self.session = None

    def control(self, action, stamp):
        if stamp <= self.last_event:
            return
        self.last_event = stamp
        if action == "start":
            if self.session:
                self.session.stop_recorder()
            if self.task and not self.task.done():
                self.task.cancel()

            def update(action, text):
                # A canceled connection may still be cleaning up when its
                # replacement starts. Never let it overwrite the new overlay.
                if self.session is session:
                    self.ui(action, text)

            session = Session(update)
            self.session = session
            self.task = asyncio.create_task(self.run_session(session))
            self.tasks.add(self.task)
            self.task.add_done_callback(self.tasks.discard)
        elif action == "stop" and self.session:
            self.session.stop()
        elif action == "cancel" and self.task and not self.task.done():
            self.task.cancel()

    async def serve(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        path = socket_path()
        lock = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Remove a stale socket only after acquiring the single-instance lock.
        Path(path).unlink(missing_ok=True)
        sock.bind(path)
        os.chmod(path, 0o600)
        sock.setblocking(False)
        try:
            while True:
                payload = await asyncio.get_running_loop().sock_recv(sock, 256)
                try:
                    action, stamp = payload.decode().split()
                    if action in {"start", "stop", "cancel"}:
                        self.control(action, int(stamp))
                except (ValueError, UnicodeError):
                    continue
        finally:
            pending = list(self.tasks)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
            sock.close()
            Path(path).unlink(missing_ok=True)
            os.close(lock)


def run_daemon():
    from overlay import DictationOverlay
    from gi.repository import GLib, Gtk

    Gtk.init([])
    overlay = DictationOverlay()

    loop = asyncio.new_event_loop()
    daemon = Daemon(lambda action, text: GLib.idle_add(overlay.update, action, text))
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()
    future = asyncio.run_coroutine_threadsafe(daemon.serve(), loop)
    future.add_done_callback(lambda _: GLib.idle_add(Gtk.main_quit))
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(
            GLib.PRIORITY_DEFAULT, sig, lambda: (Gtk.main_quit(), False)[1]
        )
    try:
        Gtk.main()
        if future.done() and not future.cancelled():
            future.result()
    finally:
        future.cancel()

        # Let cancellation stop the microphone and remove the socket before exiting.
        async def shutdown():
            pending = [
                task
                for task in asyncio.all_tasks()
                if task is not asyncio.current_task()
            ]
            await asyncio.gather(*pending, return_exceptions=True)

        with contextlib.suppress(Exception):
            asyncio.run_coroutine_threadsafe(shutdown(), loop).result(timeout=4)
        loop.call_soon_threadsafe(loop.stop)
        thread.join(timeout=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=["daemon", "start", "stop", "cancel", "setup-key"]
    )
    args = parser.parse_args()
    if args.action == "daemon":
        run_daemon()
    elif args.action == "setup-key":
        key = getpass.getpass("Soniox API key: ").strip()
        if not key:
            parser.error("The key cannot be empty.")
        path = key_path()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(key + "\n")
        print(f"Key saved to {path}. Hold Mouse 5 to dictate.")
    else:
        stamp = time.monotonic_ns()
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            try:
                sock.sendto(f"{args.action} {stamp}".encode(), socket_path())
            except (FileNotFoundError, ConnectionRefusedError):
                if args.action == "start":
                    subprocess.run(
                        [
                            "notify-send",
                            "Voice input",
                            "Start voice-input.service or log into Hyprland again.",
                        ],
                        check=False,
                    )
                    raise SystemExit(1)


if __name__ == "__main__":
    main()
