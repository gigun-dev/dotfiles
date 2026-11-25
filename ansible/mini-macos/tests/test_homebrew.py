"""Exercise Homebrew guards with a fake brew; never runs the real Homebrew."""
import copy
import unittest

import yaml

import test_migration

# list は state/installed、outdated は state/outdated、deps <name> は state/deps-<name> を返す。
# それ以外 (install / upgrade など) は記録して失敗する。
FAKE_BREW = """#!/bin/sh
printf '%s\\n' "$*" >> "$CALLS"
case "$1" in
  list) cat "$STATE/installed" ;;
  outdated) cat "$STATE/outdated" ;;
  deps) cat "$STATE/deps-$3" 2>/dev/null ;;
  *) exit 97 ;;
esac
"""


class HomebrewGuards(test_migration.MigrationFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.state = self.base / "state"
        self.state.mkdir()
        self.calls = self.base / "calls"
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        brew = bin_dir / "brew"
        brew.write_text(FAKE_BREW.replace("$CALLS", str(self.calls)).replace("$STATE", str(self.state)))
        brew.chmod(0o755)
        self.variables.update(mini_brew_bin=str(bin_dir), mini_formulae=["lima", "gh"], mini_casks=[])

    def test_normal_apply_disables_install_upgrade_cleanup_and_dependent_checks(self):
        play = yaml.safe_load((test_migration.ROOT / "apply.yml").read_text())[0]
        for name in ("HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_INSTALL_UPGRADE",
                     "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "HOMEBREW_NO_AUTO_UPDATE"):
            self.assertEqual(play["environment"][name], "1")

    def test_missing_formula_that_would_upgrade_a_dependency_stops_before_install(self):
        (self.state / "installed").write_text("lima\npcre2\n")
        (self.state / "outdated").write_text("pcre2\n")
        (self.state / "deps-gh").write_text("pcre2\n")
        result = self.run_tasks("homebrew.yml")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Installing gh would upgrade pcre2", result.stdout)
        self.assertIn("update.yml", result.stdout)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls, ["list --formula -1", "outdated --formula --quiet", "deps --formula gh"])

    def test_nothing_missing_skips_the_dependency_reads(self):
        (self.state / "installed").write_text("gh\nlima\n")
        result = self.run_tasks("homebrew.yml", check=True)
        # The fake brew cannot answer the homebrew module itself; only the guard calls matter here.
        self.assertEqual(self.calls.read_text().splitlines()[0], "list --formula -1")
        self.assertNotIn("outdated", self.calls.read_text())
        self.assertNotIn("Installing", result.stdout)


class UpdateRequest(test_migration.MigrationFixture, unittest.TestCase):
    def request(self, formulae):
        variables = copy.deepcopy(self.variables)
        variables.update(mini_targets=["homebrew"], mini_update_ack=True, mini_update_formulae=formulae)
        return self.run_tasks("validate_update.yml", variables)

    def test_declared_unpinned_formula_may_be_updated(self):
        for name in ("lima", "tailscale", "gh"):
            with self.subTest(formula=name):
                result = self.request([name])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_formulae_pinned_by_cli_selection_are_refused(self):
        for name in ("fzf", "zoxide", "ripgrep", "xcodegen"):
            with self.subTest(formula=name):
                result = self.request(["lima", name])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} is pinned by", result.stdout)

    def test_undeclared_formula_is_refused(self):
        result = self.request(["cloudflared"])
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
