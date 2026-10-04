#!/usr/bin/env python3
"""Run the shipped proposal shell with inert git/nix/gh/heartbeat fixtures."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "nix/modules/nixos/mini-vm.nix").read_text()


class ProposalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.state = self.root / "state"
        self.state.mkdir()
        self.env = dict(os.environ, FIXTURE=str(self.root), STATE_DIRECTORY=str(self.state),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        DIFF="1", FAIL="")
        self.command("git", '''
echo "git $*" >> "$FIXTURE/calls"
[ "$FAIL" != "git-$1" ] || exit 9
case "$1 $2" in
'worktree add') mkdir -p "$5";;
'diff --quiet') exit "$DIFF";;
esac
''')
        self.command("nix", '''
echo "nix $*" >> "$FIXTURE/calls"
[ "$FAIL" != "nix-$1" ] || exit 9
[ "$FAIL" != "nix-$2" ] || exit 9
''')
        self.command("gh", '''
echo "gh $*" >> "$FIXTURE/calls"
[ "$FAIL" != "gh-$2" ] || exit 9
[ "$2" != view ] || echo off
''')
        self.command("heartbeat", '''
case "$1" in
begin) echo "begin $3" >> "$FIXTURE/calls"; echo fixed-start-receipt;;
send) echo "heartbeat $2 $3" >> "$FIXTURE/calls";;
esac
''')
        body = SOURCE.split('pkgs.writeShellScript "dotfiles-lock-propose" \'\'\n', 1)[1].split("\n  '';", 1)[0]
        body = body.replace("${dotfilesDir}", shlex.quote(str(self.repo)))
        body = body.replace("${jobHeartbeatSnapshot}", "export DOTFILES_JOB_HEARTBEAT_ENABLED=0 DOTFILES_JOB_HEARTBEAT_ENDPOINT= DOTFILES_JOB_HEARTBEAT_TOKEN_FILE=")
        body = body.replace("${jobHeartbeat}", shlex.quote(str(self.bin / "heartbeat")))
        body = body.replace("''${", "${")
        self.script = self.root / "propose"
        self.script.write_text(body)

    def command(self, name, text):
        path = self.bin / name
        path.write_text("#!" + shutil.which("bash") + "\n" + text)
        path.chmod(0o755)

    def run_job(self, lane="fast", success=True):
        result = subprocess.run(["bash", str(self.script), lane], env=self.env,
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        path = self.root / "calls"
        calls = path.read_text() if path.exists() else ""
        self.assertEqual(calls.count("heartbeat --receipt fixed-start-receipt"), int(success), calls)
        return calls

    def test_success_bindings_keep_activation_in_shared_wrapper(self):
        calls = [line for line in SOURCE.splitlines() if "${jobHeartbeat}" in line]
        self.assertEqual(len(calls), 5)
        self.assertTrue(all("--enabled" not in line for line in calls))
        self.assertTrue(all("--endpoint" not in line and "--token-file" not in line for line in calls))
        self.assertIn("restartIfChanged = false;", SOURCE)
        self.assertIn("X-StopOnRemoval = false;", SOURCE)
        self.assertIn('exec "$selected_system/etc/dotfiles-autoswitch/post-apply"', SOURCE)

    def test_fast_proposal_success_after_merge_request(self):
        calls = self.run_job()
        self.assertIn("nix flake update llm-agents claude-code-overlay cclens", calls)
        self.assertLess(calls.index("gh pr merge"), calls.index("heartbeat --receipt"))

    def test_slow_proposal_success(self):
        calls = self.run_job("slow")
        self.assertIn("begin mini-vm-lock-slow", calls)
        self.assertIn("nix flake update\n", calls)

    def test_no_diff_success(self):
        self.env["DIFF"] = "0"
        calls = self.run_job()
        self.assertNotIn("nix build", calls)
        self.assertNotIn("gh pr", calls)

    def test_sender_failure_does_not_fail_proposal_or_no_diff_job(self):
        self.command("heartbeat", '''
case "$1" in
begin) echo fixed-start-receipt;;
send) echo "heartbeat $2 $3" >> "$FIXTURE/calls"; exit 9;;
esac
''')
        for lane in ["fast", "slow"]:
            for diff in ["0", "1"]:
                with self.subTest(lane=lane, diff=diff):
                    (self.root / "calls").unlink(missing_ok=True)
                    self.env["DIFF"] = diff
                    self.run_job(lane)

    def test_each_failed_stage_does_not_send_success(self):
        for failure in ["git-fetch", "nix-flake", "git-commit", "nix-build", "git-push", "gh-list", "gh-create", "gh-view", "gh-merge"]:
            with self.subTest(failure=failure):
                (self.root / "calls").unlink(missing_ok=True)
                self.env["FAIL"] = failure
                self.run_job(success=False)

    def test_unknown_lane_does_not_send_success(self):
        self.run_job("invalid", success=False)

    def test_condition_skips_start_and_timeout_has_no_success(self):
        # systemd evaluates this before ExecStart; an absent checkout must not
        # get an unconditional ExecStartPost success hook in later integration.
        unit = SOURCE.split('systemd.services."dotfiles-lock-propose@" =', 1)[1].split('\n  };', 1)[0]
        self.assertIn('ConditionPathExists = "${dotfilesDir}/flake.nix";', unit)
        self.assertNotIn("ExecStartPost", unit)
        self.command("nix", "sleep 10\n")
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess.run(["bash", str(self.script), "fast"], env=self.env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=0.2)
        self.assertNotIn("heartbeat --receipt", (self.root / "calls").read_text())


if __name__ == "__main__":
    unittest.main()
