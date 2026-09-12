import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "console", Path(__file__).resolve().parents[1] / "scripts/notebook-hibernate-console.py")
console = importlib.util.module_from_spec(spec)
spec.loader.exec_module(console)


class ConsoleTest(unittest.TestCase):
    def test_refuses_to_touch_running_x(self):
        with patch.object(console, "graphics_running", return_value=True), \
                patch.object(console.os, "open") as open_fd:
            with self.assertRaisesRegex(RuntimeError, "X sigue activo"):
                console.switch_to_text(63)
            open_fd.assert_not_called()

    def test_verifies_target_and_text_mode(self):
        with patch.object(console, "graphics_running", return_value=False), \
                patch.object(console.os, "open", side_effect=[10, 11]), \
                patch.object(console.os, "close") as close_fd, \
                patch.object(console.fcntl, "ioctl") as ioctl, \
                patch.object(console, "read_ioctl", side_effect=[(63, 0, 0), (0, 0, 0, 0, 0), (0,)]):
            console.switch_to_text(63)
            ioctl.assert_any_call(10, console.VT_ACTIVATE, 63)
            self.assertEqual(close_fd.call_count, 2)

    def test_switch_timeout_closes_descriptors(self):
        with patch.object(console, "graphics_running", return_value=False), \
                patch.object(console.os, "open", side_effect=[10, 11]), \
                patch.object(console.os, "close") as close_fd, \
                patch.object(console.fcntl, "ioctl"), \
                patch.object(console, "read_ioctl", return_value=(1, 0, 0)), \
                patch.object(console.time, "monotonic", side_effect=[0, 6]):
            with self.assertRaisesRegex(RuntimeError, "en plazo"):
                console.switch_to_text(63)
            self.assertEqual(close_fd.call_count, 2)

    def test_graphics_mode_is_not_accepted(self):
        with patch.object(console, "graphics_running", return_value=False), \
                patch.object(console.os, "open", side_effect=[10, 11]), \
                patch.object(console.os, "close"), \
                patch.object(console.fcntl, "ioctl"), \
                patch.object(console, "read_ioctl", side_effect=[(63, 0, 0), (0, 0, 0, 0, 0), (1,)]):
            with self.assertRaisesRegex(RuntimeError, "KD_TEXT"):
                console.switch_to_text(63)


if __name__ == "__main__":
    unittest.main()
