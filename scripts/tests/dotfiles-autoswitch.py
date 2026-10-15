#!/usr/bin/env python3
"""Run the shipped coordinator/helper shells with isolated system/repository fixtures.

These tests do not emulate systemd activation. Unit lifecycle is covered separately
by the NixOS VM test; no same-generation retry is a self-update regression test.
"""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "nix/modules/nixos/mini-vm.nix").read_text()


def check_runs(*runs, app="github-actions"):
    return {"check_runs": [{"name": name, "status": status, "conclusion": conclusion,
                            "app": {"slug": app}} for name, status, conclusion in runs]}


GREEN = check_runs(("changes", "completed", "success"), ("check", "completed", "success"),
                   ("build", "completed", "success"))


def body(name):
    return SOURCE.split(f'pkgs.writeShellScript "{name}" \'\'\n', 1)[1].split("\n  '';", 1)[0].split("\n      '';", 1)[0]


class AutoswitchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="autoswitch-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.previous = self.base / "previous"
        self.selected = self.base / "selected"
        self.current = self.base / "current"
        self.current.symlink_to(self.previous)
        self.env = dict(os.environ, FIXTURE=str(self.base), DIRTY="", REV="fixed42",
                        HM_STATUS="0", GATE_STATUS="0", SWITCH_STATUS="0", GH_STATUS="0",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.set_check_runs(GREEN)
        self.command("heartbeat", '''
case "$1" in
begin) echo start-receipt;;
send) echo "heartbeat $2 $3" >> "$FIXTURE/calls";;
esac
''')
        self.command("git", '''
echo "git $*" >> "$FIXTURE/calls"
echo "git env SKIP=${DOTFILES_SKIP_AUTO_SWITCH:-}" >> "$FIXTURE/calls"
case "$1" in
status) printf '%s' "$DIRTY";;
fetch|merge) exit 0;;
rev-parse)
  if [ "$2" = HEAD ] && [ -n "${AHEAD:-}" ]; then echo local-ahead; else printf '%s\\n' "$REV"; fi;;
esac
''')
        self.command("gh", '''
echo "gh $*" >> "$FIXTURE/calls"
[ "$GH_STATUS" = 0 ] || exit "$GH_STATUS"
cat "$FIXTURE/check-runs.json"
''')
        self.command("systemctl", 'echo "systemctl $*" >> "$FIXTURE/calls"\n')
        self.command("sudo", 'shift 2; exec "$@"\n')
        self.command("nix", '''
echo "nix $*" >> "$FIXTURE/calls"
printf '%s/selected\\n' "$FIXTURE"
''')
        self.command("nixos-rebuild", '''
echo "switch $*" >> "$FIXTURE/calls"
[ "$SWITCH_STATUS" = 0 ] || exit "$SWITCH_STATUS"
[ "${WRONG_TARGET:-no}" = no ] || exit 0
rm "$FIXTURE/current"; ln -s "$FIXTURE/selected" "$FIXTURE/current"
echo checkout-mutated > "$FIXTURE/repo/checkout"
''')
        self.command("home-manager", '''
echo "home $*" >> "$FIXTURE/calls"
echo "home PATH=$PATH" >> "$FIXTURE/calls"
if [ "${CHANGE_DURING_HOME:-no}" = yes ]; then
  rm "$FIXTURE/current"; ln -s "$FIXTURE/previous" "$FIXTURE/current"
fi
exit "$HM_STATUS"
''')
        self.command("gate", '''
echo new-gate >> "$FIXTURE/calls"
if [ "${CHANGE_DURING_GATE:-no}" = yes ]; then
  rm "$FIXTURE/current"; ln -s "$FIXTURE/previous" "$FIXTURE/current"
fi
exit "$GATE_STATUS"
''')
        self.command("nix-env", 'echo "profile $*" >> "$FIXTURE/calls"\n')
        self.replacements = {
            "${jobHeartbeatSnapshot}": "export DOTFILES_JOB_HEARTBEAT_ENABLED=0 DOTFILES_JOB_HEARTBEAT_ENDPOINT= DOTFILES_JOB_HEARTBEAT_TOKEN_FILE=",
            "${jobHeartbeat}": shlex.quote(str(self.bin / "heartbeat")),
            "${autoswitchPath}": shlex.quote(self.env["PATH"]),
            "${pkgs.cacert}": "/new-generation-ca",
            "${pkgs.sudo}/bin/sudo": shlex.quote(str(self.bin / "sudo")),
            "${pkgs.coreutils}/bin/env": "env",
            "${pkgs.git}/bin/git": shlex.quote(str(self.bin / "git")),
            "${homeManager}/bin/home-manager": shlex.quote(str(self.bin / "home-manager")),
            "${dotfilesSource}": "/immutable-source-fixed42",
            "${dotfilesRevision}": "fixed42",
            "${username}": "fixture-user",
            "${dotfilesDir}": str(self.repo),
            "${pkgs.gh}/bin/gh": shlex.quote(str(self.bin / "gh")),
            "${pkgs.jq}/bin/jq": shlex.quote(shutil.which("jq") or "jq"),
            "${dotfilesRepo}": "fixture/dotfiles",
            "${requiredChecksJson}": '["check","build"]',
            "${autoswitchSkipReason}": shlex.quote(str(self.base / "skip-reason")),
            "${generationHealthGate}": shlex.quote(str(self.bin / "gate")),
            "${rollbackTarget}": shlex.quote(str(self.bin / "rollback-target")),
            "${langfuseRollbackSafe}": shlex.quote(str(self.bin / "rollback-safe")),
            "/run/current-system": str(self.current),
            "/nix/var/nix/profiles/system": str(self.base / "profile"),
        }
        self.coordinator = self.base / "coordinator"
        self.coordinator.write_text(self.render(body("dotfiles-autoswitch")))
        for generation in [self.previous, self.selected]:
            (generation / "etc/dotfiles-autoswitch").mkdir(parents=True)
            (generation / "etc/langfuse").mkdir()
            (generation / "bin").mkdir()
            (generation / "etc/langfuse/compose.yaml").write_text(
                "  image: docker.langfuse.com/langfuse/langfuse:4.46.0\n"
                "  image: docker.langfuse.com/langfuse/langfuse-worker:4.46.0\n")
        self.write_exec(self.selected / "etc/dotfiles-autoswitch/post-apply",
                        self.render(body("dotfiles-autoswitch-post-apply")))
        (self.selected / "etc/dotfiles-autoswitch/revision").write_text("fixed42\n")
        self.write_exec(self.previous / "etc/dotfiles-autoswitch/health-gate",
                        'echo restored-gate >> "$FIXTURE/calls"; exit "${RESTORED_GATE_STATUS:-0}"\n')
        self.write_exec(self.previous / "bin/switch-to-configuration", '''
echo rollback >> "$FIXTURE/calls"
rm "$FIXTURE/current"; ln -s "$FIXTURE/previous" "$FIXTURE/current"
''')
        for name in ["rollback-target", "rollback-safe"]:
            self.write_exec(self.bin / name, (ROOT / f"infra/langfuse/scripts/{name}.sh").read_text())

    def set_check_runs(self, payload):
        (self.base / "check-runs.json").write_text(json.dumps(payload))

    def render(self, script):
        for old, new in self.replacements.items():
            script = script.replace(old, new)
        self.assertNotIn("${", script)
        return script

    def write_exec(self, path, script):
        path.write_text("#!" + shutil.which("bash") + "\n" + script)
        path.chmod(0o755)

    def command(self, name, script):
        self.write_exec(self.bin / name, script)

    def run_update(self, status=0):
        result = subprocess.run(["bash", str(self.coordinator)], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, status, result.stderr)
        calls = self.calls()
        self.assertEqual(calls.count("heartbeat --receipt start-receipt"), 1 if status == 0 else 0)
        return result

    def calls(self):
        path = self.base / "calls"
        return path.read_text() if path.exists() else ""

    def test_old_coordinator_without_receipt_does_not_send(self):
        self.current.unlink()
        self.current.symlink_to(self.selected)
        env = dict(self.env)
        env.pop("DOTFILES_JOB_HEARTBEAT_RECEIPT", None)
        result = subprocess.run([str(self.selected / "etc/dotfiles-autoswitch/post-apply"),
                                 str(self.previous), str(self.selected), "fixed42"], env=env,
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("heartbeat --receipt", self.calls())

    def test_sender_failure_never_rolls_back_successful_apply(self):
        self.command("heartbeat", '''
case "$1" in
begin) echo start-receipt;;
send) echo "heartbeat $2 $3" >> "$FIXTURE/calls"; exit 9;;
esac
''')
        self.run_update()
        self.assertNotIn("rollback\n", self.calls())

    def test_job_timeout_does_not_send_success(self):
        # Deliberately exceed the old startup timeout before entering the blocked stage.
        self.command("gate", 'sleep 0.3; echo started > "$FIXTURE/gate-started"; exec sleep 30\n')
        started = self.base / "gate-started"
        process = subprocess.Popen(["bash", str(self.coordinator)], env=self.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 30
            while not started.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(started.exists(), "Fixture did not reach the blocked gate stage")
            with self.assertRaises(subprocess.TimeoutExpired):
                process.wait(timeout=0.2)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        calls = (self.base / "calls").read_text()
        self.assertIn("home switch", calls)
        self.assertNotIn("heartbeat --receipt", calls)

    def test_new_helper_uses_fixed_source_after_checkout_changes(self):
        self.run_update()
        calls = self.calls()
        self.assertEqual(calls.count("git merge --ff-only --quiet fixed42"), 1)
        self.assertNotIn("git pull", calls)
        self.assertEqual(calls.count("switch switch --flake"), 1)
        self.assertIn("?rev=fixed42#mini-vm", calls)
        self.assertIn("home switch --flake /immutable-source-fixed42#fixture-user-x86_64-linux", calls)
        self.assertEqual(calls.count("new-gate"), 1)
        self.assertNotIn("restored-gate", calls)
        self.assertEqual((self.repo / "checkout").read_text().strip(), "checkout-mutated")

    def test_dirty_checkout_never_pulls_or_switches(self):
        self.env["DIRTY"] = " M user-file"
        self.run_update(1)
        self.assertNotIn("git fetch", self.calls())
        self.assertNotIn("git merge", self.calls())
        self.assertNotIn("switch ", self.calls())

    def test_git_runs_with_hook_switch_suppressed(self):
        self.run_update()
        self.assertNotIn("git env SKIP=\n", self.calls())
        self.assertIn("git env SKIP=1\n", self.calls())

    def test_ci_gate_queries_the_fetched_upstream_commit(self):
        self.run_update()
        calls = self.calls()
        self.assertIn("git rev-parse @{upstream}", calls)
        self.assertIn("gh api repos/fixture/dotfiles/commits/fixed42/check-runs?per_page=100", calls)
        self.assertLess(calls.index("gh api"), calls.index("git merge"))

    def assert_skipped(self, verdict):
        result = self.run_update()
        calls = self.calls()
        self.assertNotIn("git merge", calls)
        self.assertNotIn("nix build", calls)
        self.assertNotIn("switch ", calls)
        self.assertIn("systemctl start --no-block dotfiles-autoswitch-notify-skip.service", calls)
        reason = (self.base / "skip-reason").read_text()
        self.assertIn(f"fixed42 ({verdict})", reason)
        self.assertIn(verdict, result.stderr)

    def test_failed_required_check_skips_without_failure(self):
        self.set_check_runs(check_runs(("changes", "completed", "success"),
                                       ("check", "completed", "success"),
                                       ("build", "completed", "failure")))
        self.assert_skipped("red build=failure")

    def test_running_check_skips(self):
        self.set_check_runs(check_runs(("changes", "completed", "success"),
                                       ("check", "in_progress", None),
                                       ("build", "completed", "success")))
        self.assert_skipped("pending check")

    def test_check_runs_not_created_yet_skip(self):
        self.set_check_runs(check_runs(("changes", "completed", "success")))
        self.assert_skipped("pending check,build")

    def test_cancelled_run_is_not_green(self):
        self.set_check_runs(check_runs(("changes", "completed", "success"),
                                       ("check", "completed", "cancelled"),
                                       ("build", "completed", "success")))
        self.assert_skipped("red check=cancelled")

    def test_failed_filter_job_is_not_masked_by_skipped_required_checks(self):
        self.set_check_runs(check_runs(("changes", "completed", "failure"),
                                       ("check", "completed", "skipped"),
                                       ("build", "completed", "skipped")))
        self.assert_skipped("red changes=failure")

    def test_paths_filter_skip_counts_as_green(self):
        self.set_check_runs(check_runs(("changes", "completed", "success"),
                                       ("check", "completed", "skipped"),
                                       ("build", "completed", "skipped")))
        self.run_update()
        self.assertIn("git merge --ff-only", self.calls())
        self.assertNotIn("notify-skip", self.calls())

    def test_checks_from_other_apps_do_not_gate(self):
        payload = check_runs(("lint", "completed", "failure"), app="other-app")
        payload["check_runs"] += GREEN["check_runs"]
        self.set_check_runs(payload)
        self.run_update()
        self.assertIn("git merge --ff-only", self.calls())

    def test_unreadable_ci_state_fails_instead_of_skipping(self):
        self.env["GH_STATUS"] = "4"
        self.run_update(4)
        self.assertNotIn("git merge", self.calls())
        self.assertNotIn("notify-skip", self.calls())
        self.assertNotIn("switch ", self.calls())

    def test_checkout_ahead_of_upstream_never_switches(self):
        self.env["AHEAD"] = "yes"
        self.assertIn("先行", self.run_update(1).stderr)
        self.assertNotIn("switch ", self.calls())

    def test_missing_helper_fails_before_switch(self):
        (self.selected / "etc/dotfiles-autoswitch/post-apply").unlink()
        self.assertIn("helper", self.run_update(1).stderr)
        self.assertNotIn("switch ", self.calls())

    def test_revision_mismatch_fails_before_switch(self):
        (self.selected / "etc/dotfiles-autoswitch/revision").write_text("other\n")
        self.run_update(1)
        self.assertNotIn("switch ", self.calls())

    def test_helper_rechecks_revision(self):
        self.current.unlink(); self.current.symlink_to(self.selected)
        result = subprocess.run([str(self.selected / "etc/dotfiles-autoswitch/post-apply"),
                                 str(self.previous), str(self.selected), "wrong"], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("home ", self.calls())

    def test_switch_failure_never_runs_home_or_gate(self):
        self.env["SWITCH_STATUS"] = "4"
        self.run_update(4)
        self.assertNotIn("home ", self.calls())

    def test_wrong_current_target_fails(self):
        self.env["WRONG_TARGET"] = "yes"
        self.run_update(1)
        self.assertNotIn("home ", self.calls())

    def test_home_failure_is_not_success_or_rollback(self):
        self.env["HM_STATUS"] = "7"
        self.run_update(7)
        self.assertNotIn("new-gate", self.calls())
        self.assertNotIn("rollback", self.calls())

    def test_failed_gate_rolls_back_only_captured_generation(self):
        self.env["GATE_STATUS"] = "1"
        result = self.run_update(1)
        self.assertEqual(self.current.resolve(), self.previous)
        self.assertEqual(self.calls().count("new-gate"), 1)
        self.assertEqual(self.calls().count("restored-gate"), 1)
        self.assertIn("rollback 後はゲートを通過", result.stderr)

    def test_target_changed_during_home_fails_before_gate(self):
        self.env["CHANGE_DURING_HOME"] = "yes"
        result = self.run_update(1)
        self.assertIn("generation が後半処理中に変わった", result.stderr)
        self.assertNotIn("new-gate", self.calls())
        self.assertNotIn("rollback\n", self.calls())

    def test_target_changed_during_successful_gate_is_not_success(self):
        self.env["CHANGE_DURING_GATE"] = "yes"
        result = self.run_update(1)
        self.assertIn("generation が後半処理中に変わった", result.stderr)
        self.assertNotIn("system + home + gate 完了", result.stderr)
        self.assertNotIn("rollback\n", self.calls())

    def test_target_changed_during_failed_gate_never_rolls_back(self):
        self.env.update(CHANGE_DURING_GATE="yes", GATE_STATUS="1")
        result = self.run_update(1)
        self.assertIn("generation が後半処理中に変わった", result.stderr)
        self.assertNotIn("rollback\n", self.calls())
        self.assertNotIn("profile ", self.calls())

    def test_changed_langfuse_image_pair_blocks_rollback(self):
        self.env["GATE_STATUS"] = "1"
        path = self.selected / "etc/langfuse/compose.yaml"
        path.write_text(path.read_text().replace("4.46.0", "4.47.0"))
        self.run_update(1)
        self.assertNotIn("rollback\n", self.calls())
        self.assertEqual(self.current.resolve(), self.selected)

    def test_missing_image_metadata_blocks_rollback(self):
        self.env["GATE_STATUS"] = "1"
        (self.previous / "etc/langfuse/compose.yaml").unlink()
        self.run_update(1)
        self.assertNotIn("rollback\n", self.calls())

    def test_same_generation_retry_never_rolls_back_to_history(self):
        self.env["GATE_STATUS"] = "1"
        self.current.unlink(); self.current.symlink_to(self.selected)
        self.run_update(1)
        self.assertNotIn("rollback\n", self.calls())

    def test_restored_gate_failure_still_fails(self):
        self.env.update(GATE_STATUS="1", RESTORED_GATE_STATUS="1")
        self.assertIn("世代ゲートが失敗", self.run_update(1).stderr)
        self.assertEqual(self.calls().count("restored-gate"), 1)

    def test_legacy_generation_without_gate_is_not_claimed_healthy(self):
        self.env["GATE_STATUS"] = "1"
        (self.previous / "etc/dotfiles-autoswitch/health-gate").unlink()
        self.assertIn("旧世代のゲートが公開されていない", self.run_update(1).stderr)
        self.assertEqual(self.calls().count("new-gate"), 1)


if __name__ == "__main__":
    unittest.main()
