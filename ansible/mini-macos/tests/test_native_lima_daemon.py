"""Exercise the Lima boot daemon tasks with fake limactl/launchctl; never touches real launchd."""
from pathlib import Path
import plistlib
import unittest

import test_migration

FAKE_LIMACTL = """#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
case "$1" in
  --version) printf 'limactl version %s\\n' "$(cat "$STATE/version")" ;;
  list) cat "$STATE/status" ;;
  stop) printf 'Stopped' > "$STATE/status" ;;
esac
"""
# print は bootstrap 済みなら 0。bootstrap は status を Running にする (RunAtLoad の代わり)。
FAKE_LAUNCHCTL = """#!/bin/sh
printf 'launchctl %s\\n' "$*" >> "$CALLS"
case "$1" in
  print) [ -e "$STATE/loaded" ] ;;
  bootstrap) : > "$STATE/loaded"; printf 'Running' > "$STATE/status" ;;
  bootout) exit 3 ;;
esac
"""


class NativeLimaDaemon(test_migration.MigrationFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.state = self.base / "state"
        self.state.mkdir()
        (self.state / "version").write_text("2.3.0")
        (self.state / "status").write_text("Running")
        self.calls = self.base / "calls"
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        for name, body in {"limactl": FAKE_LIMACTL, "launchctl": FAKE_LAUNCHCTL}.items():
            script = bin_dir / name
            script.write_text(body.replace("$CALLS", str(self.calls)).replace("$STATE", str(self.state)))
            script.chmod(0o755)
        instance = self.home / ".lima/mini-vm"
        instance.mkdir(parents=True)
        (instance / "lima.yaml").write_text("vmType: vz\n")
        self.agent = self.home / "Library/LaunchAgents/io.lima-vm.autostart.mini-vm.plist"
        self.daemon = self.base / "LaunchDaemons/io.lima-vm.daemon.mini-vm.plist"
        self.daemon.parent.mkdir()
        import getpass
        self.variables.update(
            mini_lima_bin=str(bin_dir / "limactl"), mini_launchctl=str(bin_dir / "launchctl"),
            mini_lima_daemon_plist=str(self.daemon), mini_lima_daemon_become=False,
            mini_lima_daemon_owner=None, mini_lima_daemon_group=None,
            mini_lima_user=getpass.getuser(), mini_lima_start_retries=1)

    def calls_text(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_old_lima_is_rejected_before_any_change(self):
        (self.state / "version").write_text("2.2.0")
        result = self.run_tasks("lima_daemon.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.daemon.exists())
        self.assertNotIn("bootstrap", self.calls_text())

    def test_agent_left_in_place_without_cutover_flag(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_text("agent")
        result = self.run_tasks("lima_daemon.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.agent.exists())
        self.assertFalse(self.daemon.exists())
        self.assertNotIn("stop", self.calls_text())

    def test_cutover_stops_agent_vm_then_boots_daemon_and_is_idempotent(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_text("agent")
        self.variables["mini_lima_daemon_cutover"] = True
        result = self.run_tasks("lima_daemon.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls_text().splitlines()
        self.assertLess(calls.index("stop mini-vm"), calls.index(f"launchctl bootstrap system {self.daemon}"))
        self.assertFalse(self.agent.exists())
        self.assertEqual(len(list(self.agent.parent.glob(self.agent.name + ".before-ansible-*"))), 1)

        plist = plistlib.loads(self.daemon.read_bytes())
        self.assertEqual(plist["Label"], "io.lima-vm.daemon.mini-vm")
        self.assertEqual(plist["ProgramArguments"][1:], ["start", "mini-vm", "--foreground"])
        self.assertEqual(plist["KeepAlive"], {"SuccessfulExit": False})
        self.assertEqual(plist["ExitTimeOut"], 60)
        self.assertEqual(plist["EnvironmentVariables"]["HOME"], str(self.home))
        self.assertEqual(plist["WorkingDirectory"], str(self.home / ".lima/mini-vm"))

        result = self.run_tasks("lima_daemon.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"changed=0\s")
        self.assertEqual(self.calls_text().count("launchctl bootstrap"), 1)


if __name__ == "__main__":
    unittest.main()
