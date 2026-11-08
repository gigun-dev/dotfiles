#!/usr/bin/env python3
"""Run uv/sync-tools.sh against a fake uv: parse, platform markers, install-only-missing, warn-only."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "uv/sync-tools.sh"
# macOS bootstrap runs before nix, i.e. under /bin/bash 3.2; keep both working.
SHELLS = [s for s in ("/bin/bash", shutil.which("bash")) if s and os.path.exists(s)]

DECL = """\
# comment line
google-colab-cli # trailing comment
fb-idb @darwin
mlx-whisper @darwin-aarch64
plamo-translate @darwin --python 3.12
Foo_Bar.baz[cli]>=1.0 @linux @darwin
"""


class SyncTools(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="uv-sync-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base / "config/uv").mkdir(parents=True)
        shutil.copyfile(ROOT / "uv/uv.toml", self.base / "config/uv/uv.toml")
        self.uv = self.base / "uv"
        self.uv.write_text('#!/bin/sh\necho "uv $*" >> "$FIXTURE/calls"\n'
                           'case "$1 $2" in\n'
                           '"tool list") cat "$FIXTURE/list"; echo "warning: broken" >&2;;\n'
                           '"tool install") exit "${INSTALL_STATUS:-0}";;\n'
                           '"tool dir") echo "$FIXTURE/tools";;\n'
                           '"tool upgrade") exit "${UPGRADE_STATUS:-0}";;\n'
                           'esac\n')
        self.uv.chmod(0o755)
        self.decl = self.base / "tools.txt"
        self.decl.write_text(DECL)
        self.set_list("")

    def set_list(self, text):
        (self.base / "list").write_text(text)

    def run_sync(self, platform, *args, shell=None, env=None, status=0):
        environment = dict(os.environ, FIXTURE=str(self.base), UV_BIN=str(self.uv),
                           DOTFILES_PLATFORM=platform, XDG_CONFIG_HOME=str(self.base / "config"))
        environment.update(env or {})
        environment.pop("UV_DEFAULT_INDEX", None)
        result = subprocess.run([shell or SHELLS[-1], str(SCRIPT), *args, str(self.decl)],
                                env=environment, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, status, result.stderr)
        path = self.base / "calls"
        calls = path.read_text() if path.exists() else ""
        path.unlink(missing_ok=True)
        return calls, result

    def installs(self, calls):
        return [line.removeprefix("uv tool install ") for line in calls.splitlines()
                if line.startswith("uv tool install ")]

    def test_platform_markers_select_lines(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                calls, _ = self.run_sync("darwin-arm64", shell=shell)
                self.assertEqual(self.installs(calls), [
                    "google-colab-cli", "fb-idb", "mlx-whisper",
                    "plamo-translate --python 3.12", "Foo_Bar.baz[cli]>=1.0"])
                calls, _ = self.run_sync("darwin-x86_64", shell=shell)
                self.assertNotIn("mlx-whisper", self.installs(calls))
                self.assertIn("fb-idb", self.installs(calls))
                calls, _ = self.run_sync("linux-x86_64", shell=shell)
                self.assertEqual(self.installs(calls), ["google-colab-cli", "Foo_Bar.baz[cli]>=1.0"])

    def test_installed_tools_are_not_touched_and_names_normalize(self):
        self.set_list("google-colab-cli v0.7.4\n- colab\nfoo-bar-baz v1.2\n- foo\n")
        calls, _ = self.run_sync("linux-x86_64")
        self.assertEqual(calls, "uv tool list\n")

    def test_undeclared_tool_only_warns(self):
        self.set_list("google-colab-cli v0.7.4\n- colab\nmajin-cli v0.1.0\n- majin\n"
                      "foo-bar-baz v1\n")
        calls, result = self.run_sync("linux-x86_64")
        self.assertIn("majin-cli は uv/tools.txt に宣言されていない", result.stderr)
        self.assertNotIn("uninstall", calls)
        self.assertNotIn("colab", result.stderr.replace("google-colab-cli v", ""))

    def test_dry_run_prints_without_installing(self):
        calls, result = self.run_sync("linux-x86_64", "--dry-run")
        self.assertEqual(calls, "uv tool list\n")
        self.assertIn("uv tool install google-colab-cli", result.stdout)

    def test_install_failure_continues_and_reports(self):
        calls, result = self.run_sync("linux-x86_64", env={"INSTALL_STATUS": "3"}, status=1)
        self.assertEqual(len(self.installs(calls)), 2)
        self.assertIn("install に失敗", result.stderr)

    def write_receipt(self, name, requirement):
        directory = self.base / "tools" / name
        directory.mkdir(parents=True)
        (directory / "uv-receipt.toml").write_text(
            f"[tool]\nrequirements = [{requirement}]\n"
            f'entrypoints = [\n    {{ name = "{name}", install-path = "/x/bin/{name}", from = "{name}" }},\n]\n')

    def test_upgrade_skips_local_sources_and_continues_on_failure(self):
        self.set_list("google-colab-cli v0.7.4\n- colab\nplamo-translate v1.2.0\n- plamo-translate\n"
                      "majin-cli v0.1.0\n- majin\n")
        self.write_receipt("google-colab-cli", '{ name = "google-colab-cli" }')
        self.write_receipt("plamo-translate", '{ name = "plamo-translate", path = "/tmp/p.whl" }')
        self.write_receipt("majin-cli", '{ name = "majin-cli", editable = "/src/majin" }')
        for shell in SHELLS:
            with self.subTest(shell=shell):
                calls, result = self.run_sync("darwin-arm64", "--upgrade", shell=shell)
                self.assertEqual(self.installs(calls), [])
                self.assertEqual([c for c in calls.splitlines() if "upgrade" in c],
                                 ["uv tool upgrade google-colab-cli"])
                self.assertIn("plamo-translate はローカルパス等", result.stderr)
                self.assertNotIn("宣言されていない", result.stderr)
        calls, result = self.run_sync("darwin-arm64", "--dry-run", "--upgrade")
        self.assertEqual(result.stdout, "uv tool upgrade google-colab-cli\n")
        self.assertNotIn("tool upgrade", calls)
        _, result = self.run_sync("darwin-arm64", "--upgrade", env={"UPGRADE_STATUS": "2"}, status=1)
        self.assertIn("google-colab-cli の upgrade に失敗", result.stderr)

    def test_upgrade_needs_guard_configuration(self):
        calls, _ = self.run_sync("linux-x86_64", "--upgrade",
                                 env={"XDG_CONFIG_HOME": str(self.base / "missing")}, status=1)
        self.assertEqual(calls, "")

    def test_missing_uv_is_silent(self):
        calls, result = self.run_sync("linux-x86_64", env={"UV_BIN": str(self.base / "nope")})
        self.assertEqual((calls, result.stdout, result.stderr), ("", "", ""))

    def test_guard_configuration_used_without_environment_override(self):
        self.uv.write_text('#!/bin/sh\necho "index=$UV_DEFAULT_INDEX $*" >> "$FIXTURE/calls"\n')
        calls, _ = self.run_sync("linux-x86_64")
        self.assertIn("index= tool install google-colab-cli", calls)

    def test_missing_guard_configuration_stops_before_uv(self):
        calls, result = self.run_sync("linux-x86_64", env={"XDG_CONFIG_HOME": str(self.base / "missing")}, status=1)
        self.assertEqual(calls, "")
        self.assertIn("configuration missing or unapplied", result.stderr)


if __name__ == "__main__":
    unittest.main()
