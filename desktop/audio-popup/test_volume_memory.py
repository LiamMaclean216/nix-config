"""Run with python -m unittest discover -s desktop/audio-popup -p test_volume_memory.py."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from volume_memory import VolumeMemory, application_key, remember_volume, valid_volume


class Volume:
    def __init__(self, values):
        self.values = list(values)

    @property
    def value_flat(self):
        return sum(self.values) / len(self.values)


def stream(index, volume, name="Firefox", values=None):
    return SimpleNamespace(index=index, proplist={"application.name": name,
                           "object.serial": str(index + 1000)},
                           volume=Volume(values or [volume, volume]))


class VolumeMemoryTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "volumes.json"
        self.memory = VolumeMemory(self.path)
        self.writes = []

    def tick(self, items, now):
        self.memory.tick(items, now,
                         lambda item, volume: self.writes.append((item.index, list(volume.values))))

    def test_recreated_stream_restores_app_level_under_new_index(self):
        first = stream(1, .32)
        self.tick([first], 0)
        new = stream(9, 1)
        self.tick([new], 1)
        self.assertFalse(self.writes)
        self.tick([new], 1.8)
        self.assertEqual(self.writes, [(9, [.32, .32])])
        self.assertEqual(application_key(first), application_key(new))

    def test_popup_edit_during_settling_supersedes_saved_level(self):
        self.tick([stream(1, .32)], 0)
        new = stream(9, 1)
        self.tick([new], 1)
        new.volume = Volume([.61, .61])
        self.memory.remember({"app": application_key(new), "volume": .61})
        self.tick([new], 1.2)
        self.tick([new], 2)
        self.assertFalse(self.writes)
        self.assertEqual(self.memory.volumes[application_key(new)], .61)

    def test_external_edits_are_saved_and_restore_is_not_a_volume_lock(self):
        self.tick([stream(1, .32)], 0)
        item = stream(9, 1)
        self.tick([item], 1)
        self.tick([item], 2)
        item.volume = Volume([.45, .45])
        self.tick([item], 3)
        self.tick([item], 4)
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.memory.volumes[application_key(item)], .45)

    def test_late_popup_message_wins_a_restore_racing_the_explicit_edit(self):
        self.tick([stream(1, .32)], 0)
        item = stream(9, 1)
        self.tick([item], 1)
        # The popup edited to 61%, but the old preference was applied before
        # its datagram reached the next daemon iteration.
        self.tick([item], 2)
        self.memory.remember({"app": application_key(item), "volume": .61})
        self.tick([item], 2.1)
        self.assertEqual(self.writes, [(9, [.32, .32]), (9, [.61, .61])])
        self.assertEqual(self.memory.volumes[application_key(item)], .61)

    def test_audio_reconnect_does_not_learn_client_initial_reset(self):
        self.tick([stream(1, .32)], 0)
        self.memory.disconnected()
        item = stream(1, 1)
        self.tick([item], 1)
        self.assertEqual(self.memory.volumes[application_key(item)], .32)
        self.tick([item], 2)
        self.assertEqual(self.writes, [(1, [.32, .32])])

    def test_service_start_preserves_current_live_stream_and_saved_preference(self):
        item = stream(1, .8)
        self.memory.save(application_key(item), .32)
        self.memory.flush()
        self.memory = VolumeMemory(self.path)
        self.tick([item], 0)
        self.tick([item], 2)
        self.assertFalse(self.writes)
        self.assertEqual(self.memory.volumes[application_key(item)], .32)

    def test_balance_is_preserved(self):
        self.tick([stream(1, .25)], 0)
        item = stream(2, .5, values=[.2, .8])
        self.tick([item], 1)
        self.tick([item], 2)
        self.assertEqual(self.writes, [(2, [.1, .4])])

    def test_state_is_atomic_private_and_contains_no_transient_ids(self):
        self.tick([stream(1, .32)], 0)
        self.memory.flush()
        data = json.loads(self.path.read_text())
        self.assertEqual(data, {"version": 1, "volumes": {"application.name:Firefox": .32}})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(list(self.path.parent.iterdir())), 1)

    def test_invalid_preferences_are_ignored_and_unavailable_socket_is_harmless(self):
        for value in (-1, 1.51, float("nan"), float("inf"), True, "0.5", None):
            self.assertFalse(valid_volume(value))
            self.memory.remember({"app": "application.name:Firefox", "volume": value})
        self.assertFalse(self.memory.volumes)
        with patch("volume_memory.socket.socket", side_effect=OSError("Unavailable")):
            self.assertFalse(remember_volume(stream(1, .3), .3))

    def test_application_id_precedes_name_and_media_title_is_never_an_identity(self):
        item = stream(1, .3)
        item.proplist["application.id"] = "org.mozilla.firefox"
        item.proplist["media.name"] = "A changing video title"
        self.assertEqual(application_key(item), "application.id:org.mozilla.firefox")
        item.proplist = {"media.name": "A changing video title"}
        self.assertIsNone(application_key(item))


if __name__ == "__main__":
    unittest.main()
