"""A previous result file must never count as evidence for a new device run."""
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run_compatibility_probe import result_status
import run_compatibility_probe as runner


class ProbeResults(unittest.TestCase):
    def test_equal_size_stale_executable_prevents_launch(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            build = work / "build/mapping"
            build.mkdir(parents=True)
            (build / "mapping-probe.exe").write_bytes(b"new-code")
            output = work / "receipt"
            calls = []

            def execute(command, **kwargs):
                calls.append(command)
                if "from" in command:
                    Path(command[command.index("--destination") + 1]).write_bytes(b"old-code")
                return SimpleNamespace(returncode=0)

            with patch.object(sys, "argv", ["probe", "--device", "fixture", "--probe", "mapping",
                                            "--build", str(work / "build"), "--output", str(output)]), \
                    patch.object(runner.subprocess, "run", side_effect=execute):
                self.assertEqual(runner.main(), 1)
            self.assertFalse(any("launch" in command for command in calls))
            self.assertIn('"status": "executable-hash-mismatch"', (output / "receipt.json").read_text())

    def test_transfer_uses_a_unique_subdirectory_and_never_requests_removal(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            build = work / "build/mapping"
            build.mkdir(parents=True)
            binary = b"fixture executable"
            (build / "mapping-probe.exe").write_bytes(binary)
            output = work / "receipt"
            run = uuid.UUID("55555555-1111-2222-3333-444444444444")
            calls = []

            def execute(command, **kwargs):
                calls.append(command)
                self.assertNotIn("--remove-existing-content", command)
                if "--destination" in command:
                    destination = command[command.index("--destination") + 1]
                    if command[4] == "to":
                        self.assertEqual(destination, f"Documents/WindowsVR/ProbeRuns/{run}/mapping")
                    else:
                        Path(destination).write_bytes(binary)
                return SimpleNamespace(returncode=1 if "launch" in command else 0)

            with patch.object(sys, "argv", ["probe", "--device", "fixture", "--probe", "mapping",
                                            "--build", str(work / "build"), "--output", str(output)]), \
                    patch.object(runner.uuid, "uuid4", return_value=run), \
                    patch.object(runner.subprocess, "run", side_effect=execute):
                self.assertEqual(runner.main(), 1)
            self.assertTrue(any("launch" in command for command in calls))

    def test_requires_current_run_and_terminal_success(self):
        self.assertEqual(result_status("START probe run=old\nRESULT PASS\n", "new"), "stale-or-not-started")
        self.assertEqual(result_status("START probe run=new\r\nRESULT PASS\r\n", "new"), "pass")
        self.assertEqual(result_status("START probe run=new\nCHECK okay\n", "new"), "incomplete")
        self.assertEqual(result_status("START probe run=new\nRESULT FAIL exception details\n", "new"), "fail")
        self.assertEqual(result_status("RESULT PASS run=new\n", "new"), "stale-or-not-started")
        self.assertEqual(result_status("START probe run=new\nRESULT PASS\nFAIL after cleanup\n", "new"), "incomplete")


if __name__ == "__main__":
    unittest.main()
