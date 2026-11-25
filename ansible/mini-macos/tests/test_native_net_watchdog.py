"""Exercise the watchdog user agent tasks with a fake launchctl; never touches real launchd."""
from pathlib import Path
import plistlib
import unittest

import test_migration

# print は読み込み済みなら 0。bootstrap / bootout は loaded の印を付け外しする。
FAKE_LAUNCHCTL = """#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
case "$1" in
  print) [ -e "$STATE/loaded" ] ;;
  bootstrap) : > "$STATE/loaded" ;;
  bootout) rm -f "$STATE/loaded" ;;
esac
"""


class NativeNetWatchdog(test_migration.MigrationFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.state = self.base / "state"
        self.state.mkdir()
        self.calls = self.base / "calls"
        launchctl = self.base / "launchctl"
        launchctl.write_text(FAKE_LAUNCHCTL.replace("$CALLS", str(self.calls)).replace("$STATE", str(self.state)))
        launchctl.chmod(0o755)
        self.daemon = self.base / "LaunchDaemons/dev.gigun.net-watchdog.plist"
        self.variables.update(
            mini_launchctl=str(launchctl),
            mini_watchdog_conflicts=[str(self.daemon)],
            mini_watchdog_app_dir=str(self.home / "Library/Application Support/net-watchdog"),
            mini_watchdog_log_dir=str(self.home / "Library/Logs/net-watchdog"),
            mini_watchdog_plist=str(self.home / "Library/LaunchAgents/dev.gigun.net-watchdog.plist"))
        self.plist = Path(self.variables["mini_watchdog_plist"])
        self.script = Path(self.variables["mini_watchdog_app_dir"]) / "network-watchdog.sh"

    def calls_text(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_check_mode_only_reads_launchd(self):
        result = self.run_tasks("net_watchdog.yml", check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.script.exists())
        self.assertEqual(self.calls_text().split(), ["print", "gui/501/dev.gigun.net-watchdog"])

    def test_install_load_and_idempotency(self):
        result = self.run_tasks("net_watchdog.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.script.read_bytes(),
                         (test_migration.ROOT.parent.parent / "nix/modules/darwin/network-watchdog.sh").read_bytes())
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["ProgramArguments"], ["/bin/bash", str(self.script)])
        self.assertTrue(Path(self.variables["mini_watchdog_log_dir"]).is_dir())
        self.assertEqual(self.calls_text().count("bootstrap"), 1)
        again = self.run_tasks("net_watchdog.yml")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertRegex(again.stdout, r"changed=0\s")
        self.assertEqual(self.calls_text().count("bootstrap"), 1)

    def test_script_only_change_keeps_the_loaded_job(self):
        self.assertEqual(self.run_tasks("net_watchdog.yml").returncode, 0)
        self.script.write_text("old script\n")
        result = self.run_tasks("net_watchdog.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("bootout", self.calls_text())
        self.assertEqual(self.calls_text().count("bootstrap"), 1)

    def test_plist_change_reloads_the_job(self):
        self.assertEqual(self.run_tasks("net_watchdog.yml").returncode, 0)
        self.plist.write_bytes(self.plist.read_bytes().replace(b"<integer>30</integer>", b"<integer>60</integer>"))
        result = self.run_tasks("net_watchdog.yml")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls_text().splitlines()
        self.assertLess(calls.index("bootout gui/501/dev.gigun.net-watchdog"), len(calls) - 1)
        self.assertEqual(calls[-1], f"bootstrap gui/501 {self.plist}")
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["StartInterval"], 30)

    def test_system_watchdog_blocks_before_any_change(self):
        self.daemon.parent.mkdir()
        self.daemon.write_text("daemon")
        result = self.run_tasks("net_watchdog.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.plist.exists())
        self.assertEqual(self.calls_text(), "")


if __name__ == "__main__":
    unittest.main()
