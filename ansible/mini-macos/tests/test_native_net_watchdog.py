"""Exercise the watchdog user agent tasks with a fake launchctl; never touches real launchd."""
from pathlib import Path
import os
import plistlib
import unittest

import test_migration

# print gui/<uid> は GUI ドメインの有無 (no-gui で無し)、print gui/<uid>/<label> は読み込み済みなら 0。
# fail-bootout / fail-bootstrap-once で失敗を注入する。bootstrap は読んだ plist の中身を loaded に残す。
FAKE_LAUNCHCTL = """#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
case "$1" in
  print)
    case "$2" in
      */*/*) [ -e "$STATE/loaded" ] ;;
      *) [ ! -e "$STATE/no-gui" ] ;;
    esac ;;
  bootstrap)
    if [ -e "$STATE/fail-bootstrap-once" ]; then rm "$STATE/fail-bootstrap-once"; exit 5; fi
    cp "$3" "$STATE/loaded" ;;
  bootout)
    [ -e "$STATE/fail-bootout" ] && exit 5
    rm -f "$STATE/loaded" ;;
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
        self.domain = f"gui/{os.getuid()}"
        self.script = Path(self.variables["mini_watchdog_app_dir"]) / "network-watchdog.sh"

    def calls_text(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_check_mode_only_reads_launchd(self):
        result = self.run_tasks("net_watchdog.yml", check=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.script.exists())
        self.assertEqual(self.calls_text().splitlines(),
                         [f"print {self.domain}", f"print {self.domain}/dev.gigun.net-watchdog"])

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
        self.assertLess(calls.index(f"bootout {self.domain}/dev.gigun.net-watchdog"), len(calls) - 1)
        self.assertEqual(calls[-1], f"bootstrap {self.domain} {self.plist}")
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["StartInterval"], 30)

    def test_system_watchdog_blocks_before_any_change(self):
        self.daemon.parent.mkdir()
        self.daemon.write_text("daemon")
        result = self.run_tasks("net_watchdog.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.plist.exists())
        self.assertNotIn("bootstrap", self.calls_text())

    def test_missing_gui_session_blocks_before_any_change(self):
        (self.state / "no-gui").write_text("")
        result = self.run_tasks("net_watchdog.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("log in to the GUI", result.stdout)
        self.assertFalse(self.plist.exists())
        self.assertFalse(self.script.exists())

    def installed_with_old_interval(self):
        self.assertEqual(self.run_tasks("net_watchdog.yml").returncode, 0)
        old = self.plist.read_bytes().replace(b"<integer>30</integer>", b"<integer>60</integer>")
        self.plist.write_bytes(old)
        (self.state / "loaded").write_bytes(old)
        return old

    def test_failed_bootout_restores_the_old_plist_so_a_rerun_retries(self):
        old = self.installed_with_old_interval()
        (self.state / "fail-bootout").write_text("")
        result = self.run_tasks("net_watchdog.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("previous plist was restored", result.stdout)
        self.assertEqual(self.plist.read_bytes(), old)
        self.assertEqual((self.state / "loaded").read_bytes(), old)
        self.assertEqual(list(self.plist.parent.glob("*~")), [])
        (self.state / "fail-bootout").unlink()
        again = self.run_tasks("net_watchdog.yml")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(plistlib.loads((self.state / "loaded").read_bytes())["StartInterval"], 30)

    def test_failed_bootstrap_reloads_the_old_job(self):
        old = self.installed_with_old_interval()
        (self.state / "fail-bootstrap-once").write_text("")
        result = self.run_tasks("net_watchdog.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("job reloaded", result.stdout)
        self.assertEqual(self.plist.read_bytes(), old)
        self.assertEqual((self.state / "loaded").read_bytes(), old)
        self.assertEqual(list(self.plist.parent.glob("*~")), [])


if __name__ == "__main__":
    unittest.main()
