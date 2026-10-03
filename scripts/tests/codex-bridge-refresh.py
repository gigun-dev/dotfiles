#!/usr/bin/env python3
"""Exercise the shipped refresh shell with isolated process/network fixtures."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bridge-refresh-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.state = self.base / "state"
        self.state.mkdir()
        self.version = self.base / "version"
        self.version.write_text("0.2.1\n")
        self.env = dict(os.environ, FIXTURE=str(self.base), ACTIVE="yes",
                        DETECTED="unknown", LATEST="0.2.1", HEALTH="401")
        self.command("systemctl", '''
printf '%s\\n' "$*" >> "$FIXTURE/calls"
if [ "$1" = is-active ]; then [ "$ACTIVE" = yes ]; fi
''')
        self.command("record", '''
printf '%s\\n' "$DETECTED" > "$FIXTURE/version"
''')
        self.command("curl", '''
case "$*" in
  *pypi.org*) printf '{"info":{"version":"%s"}}\\n' "$LATEST" ;;
  *) printf '%s' "$HEALTH" ;;
esac
''')
        self.command("sleep", "exit 0\n")
        source = (ROOT / "nix/modules/nixos/mini-vm.nix").read_text()
        body = source.split('codexBridgeRefresh = pkgs.writeShellScript "codex-bridge-refresh" \'\'\n', 1)[1].split("\n  '';", 1)[0]
        replacements = {
            "${config.systemd.package}/bin/systemctl": shlex.quote(str(self.base / "systemctl")),
            "${pkgs.curl}/bin/curl": shlex.quote(str(self.base / "curl")),
            "${pkgs.jq}/bin/jq": shlex.quote(shutil.which("jq")),
            "${pkgs.coreutils}/bin/cat": "cat",
            "${codexBridgeRecordVersion}": shlex.quote(str(self.base / "record")),
            "/run/codex-bridge/version": str(self.version),
            "/var/lib/codex-bridge-refresh": str(self.state),
        }
        for old, new in replacements.items():
            body = body.replace(old, new)
        self.assertNotRegex(body, r"\$\{")
        self.script = self.base / "refresh"
        self.script.write_text(body)
        self.env["PATH"] = str(self.base) + os.pathsep + self.env["PATH"]

    def command(self, name, body):
        path = self.base / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_refresh(self, expected=0):
        result = subprocess.run(["bash", str(self.script)], env=self.env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def restarts(self):
        calls = self.base / "calls"
        return calls.read_text().count("try-restart") if calls.exists() else 0

    def test_current_version_keeps_connections(self):
        self.run_refresh()
        self.assertEqual(self.restarts(), 0)

    def test_known_upgrade_restarts_and_checks_health(self):
        self.env["LATEST"] = "0.2.2"
        self.run_refresh()
        self.assertEqual(self.restarts(), 1)
        self.env["HEALTH"] = "503"
        self.run_refresh(1)

    def test_unknown_continuation_notifies_once_without_restarting(self):
        self.version.write_text("unknown\n")
        self.run_refresh()
        self.run_refresh(1)
        self.run_refresh()
        self.run_refresh()
        self.assertEqual(self.restarts(), 0)
        self.assertEqual((self.state / "unknown-count").read_text(), "2\n")

    def test_recovered_detection_resumes_update_and_resets_failure(self):
        self.version.unlink()
        self.run_refresh()
        self.run_refresh(1)
        self.env.update(DETECTED="0.2.1", LATEST="0.2.2")
        self.run_refresh()
        self.assertEqual(self.restarts(), 1)
        self.assertEqual(list(self.state.iterdir()), [])
        self.version.write_text("unknown\n")
        self.env["DETECTED"] = "unknown"
        self.run_refresh()
        self.run_refresh(1)

    def test_empty_version_and_invalid_counter_fail_closed(self):
        self.version.write_text("")
        (self.state / "unknown-count").write_text("corrupted\n")
        self.run_refresh()
        self.run_refresh(1)
        self.assertEqual(self.restarts(), 0)

    def test_inactive_service_stays_stopped(self):
        self.env["ACTIVE"] = "no"
        self.version.write_text("unknown\n")
        self.run_refresh()
        self.assertEqual(list(self.state.iterdir()), [])
        self.assertEqual(self.restarts(), 0)

    def test_pypi_outage_does_not_restart_or_block_recovery(self):
        self.env["LATEST"] = ""
        (self.state / "unknown-notified").touch()
        self.run_refresh()
        self.assertEqual(self.restarts(), 0)
        self.assertEqual(list(self.state.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
