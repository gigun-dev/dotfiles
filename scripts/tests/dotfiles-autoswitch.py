#!/usr/bin/env python3
"""Run the shipped coordinator/helper shells with isolated system/repository fixtures.

These tests do not emulate systemd activation. Unit lifecycle is covered separately
by the NixOS VM test; no same-generation retry is a self-update regression test.
"""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "nix/modules/nixos/mini-vm.nix").read_text()


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
                        HM_STATUS="0", GATE_STATUS="0", SWITCH_STATUS="0",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.command("git", '''
echo "git $*" >> "$FIXTURE/calls"
case "$1" in
status) printf '%s' "$DIRTY";;
pull) exit 0;;
rev-parse) printf '%s\\n' "$REV";;
esac
''')
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
exit "$HM_STATUS"
''')
        self.command("gate", '''
echo new-gate >> "$FIXTURE/calls"
exit "$GATE_STATUS"
''')
        self.command("nix-env", 'echo "profile $*" >> "$FIXTURE/calls"\n')
        self.replacements = {
            "${autoswitchPath}": shlex.quote(self.env["PATH"]),
            "${pkgs.cacert}": "/new-generation-ca",
            "${pkgs.sudo}/bin/sudo": shlex.quote(str(self.bin / "sudo")),
            "${pkgs.git}/bin/git": shlex.quote(str(self.bin / "git")),
            "${homeManager}/bin/home-manager": shlex.quote(str(self.bin / "home-manager")),
            "${dotfilesSource}": "/immutable-source-fixed42",
            "${dotfilesRevision}": "fixed42",
            "${username}": "fixture-user",
            "${dotfilesDir}": str(self.repo),
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
        return result

    def calls(self):
        path = self.base / "calls"
        return path.read_text() if path.exists() else ""

    def test_new_helper_uses_fixed_source_after_checkout_changes(self):
        self.run_update()
        calls = self.calls()
        self.assertEqual(calls.count("git pull --ff-only"), 1)
        self.assertEqual(calls.count("switch switch --flake"), 1)
        self.assertIn("?rev=fixed42#mini-vm", calls)
        self.assertIn("home switch --flake /immutable-source-fixed42#fixture-user-x86_64-linux", calls)
        self.assertEqual(calls.count("new-gate"), 1)
        self.assertNotIn("restored-gate", calls)
        self.assertEqual((self.repo / "checkout").read_text().strip(), "checkout-mutated")

    def test_dirty_checkout_never_pulls_or_switches(self):
        self.env["DIRTY"] = " M user-file"
        self.run_update(1)
        self.assertNotIn("git pull", self.calls())
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
