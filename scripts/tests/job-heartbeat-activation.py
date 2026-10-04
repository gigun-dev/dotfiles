#!/usr/bin/env python3
"""Exercise the shipped Nix shell fragments with direct runtime credentials and fake curl."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "nix/modules/nixos/mini-vm.nix").read_text()
SCRIPT = ROOT / "scripts/job-heartbeat.py"
ENDPOINT = "https://hub.example/heartbeat"
SNAPSHOT = SOURCE.split("  jobHeartbeatSnapshot = ''\n", 1)[1].split("\n  '';", 1)[0]
WRAPPER = SOURCE.split('pkgs.writeShellScript "dotfiles-job-heartbeat" \'\'\n', 1)[1].split("\n  '';", 1)[0]
FIELDS = ["ENABLED", "ENDPOINT", "TOKEN_FILE"]


class ActivationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="job-heartbeat-activation-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.credentials = self.root / "runtime-credentials"
        self.credentials.mkdir()
        self.token = self.credentials / "mini-vm-autoswitch"
        self.token.write_text("public-fixture-original-token-1234567890")
        self.token.chmod(0o400)
        self.calls = self.root / "curl-calls"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("DOTFILES_JOB_HEARTBEAT_") and key != "CREDENTIALS_DIRECTORY"}
        self.env.update(FIXTURE_CALLS=str(self.calls))
        self.write_exec(self.bin / "curl", '''
if [ "$2" = --version ]; then
  echo version >> "$FIXTURE_CALLS"
  echo 'curl 8.4.0 fixture'; exit 0
fi
cat >> "$FIXTURE_CALLS"
printf '\\n%s\\n202' '{"status":"accepted","result":{"kind":"accepted"}}'
''')
        self.receipt = json.dumps({"source": "mini-vm-autoswitch", "runId": "start-run",
                                  "scheduledFor": 14_400_000})

    def write_exec(self, path, body):
        path.write_text("#!" + shutil.which("bash") + "\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def render(self, body, enabled, endpoint=ENDPOINT, token_file=None):
        values = {
            "${jobHeartbeatEnabled}": "1" if enabled else "0",
            "${lib.escapeShellArg jobHeartbeatEndpoint}": shlex.quote(endpoint if enabled else ""),
            "${pkgs.cacert}": "/fixture-ca",
            "${pkgs.python3}/bin/python3": shlex.quote(sys.executable),
            "${../../../scripts/job-heartbeat.py}": shlex.quote(str(SCRIPT)),
            "${pkgs.curl}/bin/curl": shlex.quote(str(self.bin / "curl")),
        }
        for source in ["mini-vm-autoswitch", "mini-vm-lock-fast", "mini-vm-lock-slow"]:
            key = '${lib.escapeShellArg (jobHeartbeatConfig.tokenFiles.' + source + ' or "")}'
            values[key] = shlex.quote(str(token_file or self.credentials / source))
        for key, value in values.items():
            body = body.replace(key, value)
        self.assertNotRegex(body, r"(?<!')\$\{(?:pkgs|lib|config|jobHeartbeat)")
        return body.replace("''${", "${")

    def run_flow(self, old=True, new=True, old_endpoint=ENDPOINT, new_endpoint=ENDPOINT,
                 after_snapshot="", snapshot=True, old_token=None, new_token=None, source="mini-vm-autoswitch"):
        wrapper = self.write_exec(self.root / "helper", self.render(WRAPPER, new, new_endpoint, new_token))
        body = "heartbeat_source=" + shlex.quote(source) + "\n" + self.render(SNAPSHOT, old, old_endpoint, old_token) if snapshot else ""
        body += "\n" + after_snapshot + "\nexec " + shlex.quote(str(wrapper))
        receipt = json.loads(self.receipt)
        receipt["source"] = source
        receipt["scheduledFor"] = {"mini-vm-autoswitch": 14_400_000,
                                   "mini-vm-lock-fast": 3_600_000,
                                   "mini-vm-lock-slow": 266_400_000}[source]
        body += " send --receipt " + shlex.quote(json.dumps(receipt))
        coordinator = self.write_exec(self.root / "coordinator", body)
        return subprocess.run([str(coordinator)], env=self.env, capture_output=True, text=True, timeout=3)

    def assert_no_send(self, **kwargs):
        result = self.run_flow(**kwargs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertFalse(self.calls.exists(), "OFF or mismatched generation must not invoke curl")

    def test_off_to_off_and_off_to_on_do_not_read_credentials_or_invoke_curl(self):
        # A FIFO would hang a sender that reached token reading without O_NONBLOCK;
        # even a nonblocking read must be rejected rather than attempted when OFF.
        self.token.unlink()
        os.mkfifo(self.token, 0o600)
        for new in [False, True]:
            with self.subTest(new=new):
                self.assert_no_send(old=False, new=new)

    def test_on_to_off_does_not_send(self):
        self.assert_no_send(new=False)

    def test_old_coordinator_without_snapshot_does_not_enable(self):
        self.assert_no_send(snapshot=False)

    def test_endpoint_change_waits_for_next_invocation(self):
        self.assert_no_send(new_endpoint="https://next.example/heartbeat")

    def test_on_to_on_sends_with_original_configured_path(self):
        replacement = self.root / "new-credentials"
        replacement.mkdir()
        (replacement / "mini-vm-autoswitch").write_text("public-fixture-new-token-0000000000000")
        (replacement / "mini-vm-autoswitch").chmod(0o400)
        result = self.run_flow(new_token=replacement / "mini-vm-autoswitch")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text()
        self.assertIn("public-fixture-original-token-1234567890", calls)
        self.assertNotIn("public-fixture-new-token-0000000000000", calls)
        self.assertIn("start-run", calls)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_each_source_selects_its_own_configured_path(self):
        for source in ["mini-vm-autoswitch", "mini-vm-lock-fast", "mini-vm-lock-slow"]:
            with self.subTest(source=source):
                token = self.credentials / source
                if source != "mini-vm-autoswitch":
                    token.write_text("public-fixture-" + source + "-1234567890")
                    token.chmod(0o400)
                result = self.run_flow(source=source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(token.read_text(), self.calls.read_text())
                self.assertIn(source, self.calls.read_text())
                self.calls.unlink()

    def test_agenix_directory_rotation_keeps_logical_path_usable(self):
        generation = self.root / "next-generation"
        generation.mkdir()
        rotated = generation / "token"
        rotated.write_text("public-fixture-rotated-token-1234567890")
        rotated.chmod(0o400)
        alias = self.root / "agenix"
        alias.symlink_to(self.credentials, target_is_directory=True)
        configured = alias / self.token.name
        # The new directory contains the same configured name, as agenix does.
        rotated.rename(generation / self.token.name)
        rotate = "rm " + shlex.quote(str(alias)) + "; ln -s " + shlex.quote(str(generation)) + " " + shlex.quote(str(alias))
        rotate += "; rm -rf " + shlex.quote(str(self.credentials))
        result = self.run_flow(old_token=configured, after_snapshot=rotate)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("public-fixture-rotated-token-1234567890", self.calls.read_text())
        self.assertNotIn("public-fixture-original-token-1234567890", self.calls.read_text())

    def test_custom_final_symlink_is_rejected_without_curl(self):
        alias = self.root / "custom-token-alias"
        alias.symlink_to(self.token)
        result = self.run_flow(old_token=alias)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "job-heartbeat: receipt preparation or delivery failed\n")
        self.assertFalse(self.calls.exists())

    def test_missing_snapshot_token_path_warns_without_curl(self):
        result = self.run_flow(after_snapshot="unset DOTFILES_JOB_HEARTBEAT_TOKEN_FILE")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "job-heartbeat: receipt preparation or delivery failed\n")
        self.assertFalse(self.calls.exists())

    def test_missing_token_and_invalid_token_warn_before_curl(self):
        for missing in [True, False]:
            with self.subTest(missing=missing):
                self.token.unlink(missing_ok=True)
                if not missing:
                    self.token.write_text("invalid-public-fixture")
                    self.token.chmod(0o400)
                result = self.run_flow()
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "job-heartbeat: receipt preparation or delivery failed\n")
                self.assertFalse(self.calls.exists())

    def test_each_snapshot_field_is_required(self):
        for field in FIELDS:
            with self.subTest(field=field):
                result = self.run_flow(after_snapshot="unset DOTFILES_JOB_HEARTBEAT_" + field)
                self.assertEqual(result.returncode, 1 if field == "TOKEN_FILE" else 0)
                self.assertFalse(self.calls.exists())

    def test_start_snapshot_is_before_receipt_and_work_for_both_jobs(self):
        coordinator = SOURCE.split('pkgs.writeShellScript "dotfiles-autoswitch" \'\'\n', 1)[1]
        proposal = SOURCE.split('pkgs.writeShellScript "dotfiles-lock-propose" \'\'\n', 1)[1]
        for body in [coordinator, proposal]:
            self.assertLess(body.index("${jobHeartbeatSnapshot}"), body.index("${jobHeartbeat} begin"))
            self.assertLess(body.index("${jobHeartbeat} begin"), body.index("cd ${dotfilesDir}"))
        self.assertEqual(SOURCE.count("${jobHeartbeatSnapshot}"), 2)
        self.assertIn("exec \"$selected_system/etc/dotfiles-autoswitch/post-apply\"", SOURCE)

    def test_timer_grids_remain_unchanged(self):
        grids = ["*-*-* 04:00:00", "*-*-* 01:00:00", "Sun *-*-* 02:00:00"]
        names = ["dotfiles-autoswitch", "dotfiles-lock-propose-fast", "dotfiles-lock-propose-slow"]
        for name, grid in zip(names, grids):
            block = SOURCE.split("systemd.timers." + name + " =", 1)[1].split("\n  };", 1)[0]
            self.assertIn('OnCalendar = "' + grid + '";', block)
            self.assertIn("RandomizedDelaySec = 1800;", block)
            self.assertIn("Persistent = true;", block)


if __name__ == "__main__":
    unittest.main()
