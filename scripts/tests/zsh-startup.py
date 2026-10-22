"""Actual macOS zsh startup with temporary HOME; system/external integrations are fixtures.

No real profile, Homebrew, plugin, Nix command, daemon or network operation runs.
The unavoidable /etc/zshenv is skipped via its audited early-return guard and -d
skips remaining global files. A modeled Darwin PATH is loaded from fixture .zshenv.
"""
import os
import re
from collections import Counter
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZSH = os.environ.get("TEST_ZSH", "/bin/zsh")


@unittest.skipUnless(sys.platform == "darwin" and Path(ZSH).exists(), "macOS zsh startup fixture")
class Startup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global_env = Path("/etc/zshenv")
        text = global_env.read_text() if global_env.exists() else ""
        if not any(line.strip() and not line.lstrip().startswith("#") for line in text.splitlines()):
            return
        guard = 'if [ -n "${__ETC_ZSHENV_SOURCED-}" ]; then return; fi'
        if guard not in text or text.split(guard, 1)[0].strip().splitlines()[-1] != '# Only execute this file once per shell.':
            raise AssertionError("global zshenv early-return structure differs; review fixture isolation")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="zsh-startup-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "home"
        self.zdot = self.home / "zdot"
        self.zdot.mkdir(parents=True)
        self.system = self.base / "run/current-system/sw/bin"
        self.default = self.base / "nix/var/nix/profiles/default/bin"
        self.brew = self.base / "opt/homebrew"
        self.mise = self.home / ".local/share/mise/shims"
        self.mise.mkdir(parents=True)
        for directory, version in ((self.system, "managed"), (self.default, "installer")):
            directory.mkdir(parents=True)
            file = directory / "nix"
            file.write_text(f"#!/bin/sh\necho {version}\n")
            file.chmod(0o755)
        self.multi = self.default.parent / "etc/profile.d/nix-daemon.sh"
        self.multi.parent.mkdir(parents=True)
        self.multi.write_text('''if [ -n "${__ETC_PROFILE_NIX_SOURCED:-}" ]; then return; fi
export __ETC_PROFILE_NIX_SOURCED=1
export NIX_PROFILES="installer"
export PATH="$HOME/.nix-profile/bin:REPLACE/bin:$PATH"
'''.replace("REPLACE", str(self.default.parent)))
        self.env = {"HOME": str(self.home), "ZDOTDIR": str(self.zdot), "USER": "fixture",
                    "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh", "TERM": "dumb",
                    "LC_ALL": "C", "__ETC_ZSHENV_SOURCED": "1"}
        self.rc = self.remap((ROOT / "zsh/.zshrc").read_text())
        self.stubs = '''# Disable plugin/completion loading; keep the production rc and PATH edits.
autoload() {
  case "$*" in
    *promptinit*) promptinit() { :; }; prompt() { :; } ;;
    *add-zsh-hook*) add-zsh-hook() { :; } ;;
    *compinit*) compinit() { :; } ;;
  esac
}
zcompile() { :; }
'''
        (self.zdot / ".zshrc").write_text('print -r -- rc >> "$HOME/order"\n' + self.stubs + self.rc)
        # No actual brew executable is called: reproduce shellenv's already-prefix no-op.
        brew = self.brew / "bin/brew"
        brew.parent.mkdir(parents=True)
        brew.write_text('''#!/bin/sh
case "$PATH" in "REPLACE/bin:REPLACE/sbin:"*) exit 0;; esac
printf '%s\n' 'export PATH="REPLACE/bin:REPLACE/sbin:$PATH"'
'''.replace("REPLACE", str(self.brew)))
        brew.chmod(0o755)
        orb = self.home / ".orbstack/shell/init.zsh"
        orb.parent.mkdir(parents=True)
        orb.write_text('export PATH="$PATH:$HOME/.orbstack/bin"\n')
        (self.home / ".orbstack/bin").mkdir()
        self.brew_log = self.home / "brew-calls"
        brew.write_text(brew.read_text().replace('#!/bin/sh\n', '#!/bin/sh\nprintf called >> "$HOME/brew-calls"\n'))
        (self.zdot / ".zprofile").write_text(
            'print -r -- profile >> "$HOME/order"\n' + self.remap((ROOT / "zsh/.zprofile").read_text()))
        (self.zdot / ".zlogin").write_text('print -r -- login >> "$HOME/order"\n')
        self.configure(managed=True)

    def remap(self, source):
        replacements = {"/Users/gigun": self.home, "/nix/var/nix": self.base / "nix/var/nix",
                        "/run/current-system": self.base / "run/current-system",
                        "/etc/profiles/per-user": self.base / "etc/profiles/per-user",
                        "/opt/homebrew": self.brew, "/usr/local": self.base / "usr/local"}
        # A single pass also works when TMPDIR itself lies under /nix/var/nix.
        return re.sub("|".join(re.escape(p) for p in replacements),
                      lambda match: str(replacements[match[0]]), source)

    def configure(self, managed):
        env = 'print -r -- env >> "$HOME/order"\n'
        if managed:
            # Mirrors the audited set-environment PATH and /etc/zshenv brew prepend.
            env += self.remap('''if [ -z "${__NIX_DARWIN_SET_ENVIRONMENT_DONE:-}" ]; then
export __NIX_DARWIN_SET_ENVIRONMENT_DONE=1
export PATH="$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export NIX_PROFILES="darwin"
fi
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
''')
        env += (ROOT / "zsh/.zshenv").read_text()
        (self.zdot / ".zshenv").write_text(env)

    def run_zsh(self, flags, reload=False):
        if reload == "all":
            command = 'source "$ZDOTDIR/.zshenv"; source "$ZDOTDIR/.zprofile"; source "$ZDOTDIR/.zshrc"; '
        else:
            command = 'source "$ZDOTDIR/.zshrc"; ' if reload else ''
        command += '''print
print -r -- "RESULT_PATH=$PATH"
print -r -- "RESULT_NIX=$(whence -p nix)"
if (( $+commands[nix] )); then print -r -- "RESULT_VERSION=$(nix)"; fi
print -r -- "RESULT_PROFILES=${NIX_PROFILES:-}"
'''
        result = subprocess.run([ZSH, "-d", *flags, "-c", command], env=self.env,
                                cwd=self.home, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        data = dict(line.split("=", 1) for line in result.stdout.splitlines() if line.startswith("RESULT_"))
        return data, (self.home / "order").read_text().splitlines()

    def test_all_four_startup_modes_resolve_managed_nix(self):
        for flags, order in (([], ["env"]), (["-l"], ["env", "profile", "login"]),
                             (["-i"], ["env", "rc"]), (["-l", "-i"], ["env", "profile", "rc", "login"])):
            with self.subTest(flags=flags):
                (self.home / "order").unlink(missing_ok=True)
                data, actual = self.run_zsh(flags)
                self.assertEqual(actual, order)
                self.assertEqual(data["RESULT_NIX"], str(self.system / "nix"))
                self.assertEqual(data["RESULT_VERSION"], "managed")
                counts = Counter(data["RESULT_PATH"].split(":"))
                self.assertEqual(counts[str(self.system)], 1)
                self.assertEqual(counts[str(self.default)], 1)
                self.assertFalse(any(n > 1 for n in counts.values()))
                self.assertEqual(data["RESULT_PROFILES"], "darwin")
                expected = [str(self.brew / "bin"), str(self.brew / "sbin"),
                            str(self.home / ".nix-profile/bin"),
                            str(self.base / "etc/profiles/per-user/fixture/bin"),
                            str(self.system), str(self.default), str(self.base / "usr/local/bin"),
                            "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                if "-l" in flags:
                    expected.append(str(self.home / ".orbstack/bin"))
                if "-i" in flags:
                    expected = [str(self.home / ".codeium/windsurf/bin"), str(self.mise),
                                str(self.home / ".cache/.bun/bin"), *expected, str(self.home / ".local/bin")]
                self.assertEqual(data["RESULT_PATH"].split(":"), expected)

    def test_old_condition_reproduces_failure_during_real_interactive_startup(self):
        env = self.zdot / ".zshenv"
        env.write_text(env.read_text().replace("typeset -gU PATH path\n", ""))
        old = self.rc.replace('[ -z "${__NIX_DARWIN_SET_ENVIRONMENT_DONE:-}" ] && ', '')
        (self.zdot / ".zshrc").write_text(self.stubs + old)
        data, _ = self.run_zsh(["-i"])
        self.assertEqual(data["RESULT_VERSION"], "installer")
        self.assertEqual(data["RESULT_PROFILES"], "installer")
        self.assertEqual(Counter(data["RESULT_PATH"].split(":"))[str(self.default)], 2)

    def test_reload_preserves_nix_priority_and_unique_tool_paths(self):
        for flags in (["-i"], ["-l", "-i"]):
            with self.subTest(flags=flags):
                data, _ = self.run_zsh(flags, reload=True)
                counts = Counter(data["RESULT_PATH"].split(":"))
                self.assertEqual(data["RESULT_VERSION"], "managed")
                self.assertEqual(counts[str(self.system)], 1)
                self.assertEqual(counts[str(self.default)], 1)
                for path in (self.mise, self.home / ".cache/.bun/bin", self.home / ".local/bin", self.home / ".codeium/windsurf/bin"):
                    self.assertEqual(counts[str(path)], 1)
                self.assertFalse(any(n > 1 for n in counts.values()))

    def test_all_user_init_reload_preserves_complete_priority(self):
        initial, _ = self.run_zsh(["-l", "-i"])
        repeated, _ = self.run_zsh(["-l", "-i"], reload="all")
        self.assertEqual(repeated["RESULT_PATH"], initial["RESULT_PATH"])
        self.assertEqual(repeated["RESULT_VERSION"], "managed")

    def test_inherited_interactive_path_is_unique_in_all_child_modes(self):
        initial, _ = self.run_zsh(["-l", "-i"])
        self.env["PATH"] = initial["RESULT_PATH"] + ":" + str(self.default)
        self.env["__NIX_DARWIN_SET_ENVIRONMENT_DONE"] = "1"
        self.env["NIX_PROFILES"] = "darwin"
        for flags in ([], ["-l"], ["-i"], ["-l", "-i"]):
            with self.subTest(flags=flags):
                data, _ = self.run_zsh(flags)
                self.assertEqual(data["RESULT_VERSION"], "managed")
                self.assertFalse(any(n > 1 for n in Counter(data["RESULT_PATH"].split(":")).values()))

    def test_old_path_policy_reproduces_other_tool_duplicates(self):
        env = self.zdot / ".zshenv"
        env.write_text(env.read_text().replace("typeset -gU PATH path\n", ""))
        data, _ = self.run_zsh(["-i"], reload=True)
        counts = Counter(data["RESULT_PATH"].split(":"))
        for path in (self.mise, self.home / ".cache/.bun/bin", self.home / ".local/bin", self.home / ".codeium/windsurf/bin"):
            self.assertEqual(counts[str(path)], 2)

    def test_managed_login_never_calls_brew_shellenv(self):
        self.run_zsh(["-l", "-i"], reload="all")
        self.assertFalse(self.brew_log.exists())

    def test_standalone_login_retains_brew_shellenv(self):
        self.configure(managed=False)
        self.run_zsh(["-l", "-i"])
        self.assertEqual(self.brew_log.read_text(), "called")

    def test_standalone_fallback_in_interactive_modes(self):
        self.configure(managed=False)
        for flags in (["-i"], ["-l", "-i"]):
            with self.subTest(flags=flags):
                data, _ = self.run_zsh(flags, reload=True)
                self.assertEqual(data["RESULT_VERSION"], "installer")
                self.assertEqual(Counter(data["RESULT_PATH"].split(":"))[str(self.default)], 1)

    def test_single_user_fallback(self):
        self.configure(managed=False)
        target = self.home / ".nix-profile/etc/profile.d/nix.sh"
        target.parent.mkdir(parents=True)
        target.write_text(self.multi.read_text())
        self.multi.unlink()
        data, _ = self.run_zsh(["-i"])
        self.assertEqual(data["RESULT_VERSION"], "installer")

    def test_no_nix_in_all_four_modes(self):
        self.configure(managed=False)
        self.multi.unlink()
        for flags in ([], ["-l"], ["-i"], ["-l", "-i"]):
            with self.subTest(flags=flags):
                data, _ = self.run_zsh(flags)
                self.assertEqual(data["RESULT_NIX"], "")

    def test_standalone_noninteractive_does_not_source_interactive_fallback(self):
        self.configure(managed=False)
        for flags in ([], ["-l"]):
            with self.subTest(flags=flags):
                data, _ = self.run_zsh(flags)
                self.assertEqual(data["RESULT_NIX"], "")

if __name__ == "__main__":
    unittest.main()
