#!/usr/bin/env python3
"""SSH を実行せず、途絶・秘密混入・代替経路の分類を検証する。"""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock


spec = importlib.util.spec_from_file_location("ssh_path_observe", Path(__file__).parents[1] / "ssh-path-observe.py")
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
BOOT = "bbe51fe1-3c73-4c87-8bde-887bfd5219cf"
VALID = f"mini-vm\n{BOOT}\n1234.56 9999.00\n"


def success(output=VALID):
    return subprocess.CompletedProcess([], 0, output, "SECRET_STDERR")


class ObservationTests(unittest.TestCase):
    def test_direct_success_skips_fallback_and_drops_output(self):
        runner = Mock(return_value=success())
        result = observer.observe(runner)
        self.assertEqual(runner.call_count, 1)
        self.assertEqual(result["paths"]["direct"]["bootId"], BOOT)
        self.assertEqual(result["paths"]["viaHost"]["outcome"], "not_attempted")
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotIn("1234.56", json.dumps(result))
        self.assertEqual(runner.call_args.kwargs["timeout"], 25)

    def test_timeout_then_vm_alive_does_not_erase_direct_failure(self):
        runner = Mock(side_effect=[subprocess.TimeoutExpired([], 25, output="SECRET_TIMEOUT"), success()])
        result = observer.observe(runner)
        self.assertEqual(result["paths"]["direct"]["status"], "failed")
        self.assertEqual(result["paths"]["direct"]["outcome"], "timeout")
        self.assertEqual(result["paths"]["viaHost"]["status"], "ok")
        self.assertEqual(result["paths"]["viaHost"]["bootId"], BOOT)
        self.assertEqual(runner.call_args.args[0], observer.VIA_HOST)
        self.assertNotIn("SECRET", json.dumps(result))

    def test_both_failed_does_not_claim_vm_stopped(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 255, "SECRET_OUT", "SECRET_ERR"))
        result = observer.observe(runner)
        self.assertEqual([p["status"] for p in result["paths"].values()], ["failed", "failed"])
        self.assertTrue(all(p["bootId"] is None for p in result["paths"].values()))
        self.assertNotIn("stopped", json.dumps(result))
        self.assertNotIn("SECRET", json.dumps(result))

    def test_invalid_evidence_is_unknown_and_uses_fallback(self):
        for output in ["other-host\n" + BOOT + "\n1 2", "mini-vm\nSECRET\n1 2", VALID + "SECRET\n", "mini-vm\n" + BOOT + "\nnan 2"]:
            with self.subTest(output=output):
                result = observer.observe(Mock(side_effect=[success(output), success()]))
                self.assertEqual(result["paths"]["direct"]["status"], "unknown")
                self.assertEqual(result["paths"]["direct"]["outcome"], "invalid_output")
                self.assertEqual(result["paths"]["viaHost"]["status"], "ok")
                self.assertNotIn("SECRET", json.dumps(result))

    def test_local_execution_error_is_unknown(self):
        result = observer.observe(Mock(side_effect=FileNotFoundError("SECRET")))
        self.assertTrue(all(p["status"] == "unknown" for p in result["paths"].values()))
        self.assertNotIn("SECRET", json.dumps(result))

    def test_latest_snapshot_is_replaced_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.json"
            path.write_text("old")
            result = observer.observe(Mock(return_value=success()))
            observer.write_snapshot(path, result)
            self.assertEqual(json.loads(path.read_text()), result)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(directory).iterdir()), [path])


if __name__ == "__main__":
    unittest.main()
