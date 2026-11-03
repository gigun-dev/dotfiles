"""Exercise generation-pinned activation inputs with a fake uv and no network."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ActivationInputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="activation-inputs-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.body = Path(os.environ["UV_ACTIVATION"]).read_text()
        matches = re.findall(r'(/nix/store/[^"\s]+-uv-activation-inputs)/sync-tools\.sh', self.body)
        self.assertEqual(len(matches), 1)
        self.snapshot = Path(matches[0])
        self.guard = Path(os.environ["UV_GUARD"])
        self.endpoints = Path(os.environ["LANGFUSE_ENDPOINTS"])
        self.checkout = self.base / "checkout"
        (self.checkout / "uv").mkdir(parents=True)
        (self.checkout / "claude").mkdir()
        for name in ("sync-tools.sh", "tools.txt", "uv.toml"):
            shutil.copyfile(ROOT / "uv" / name, self.checkout / "uv" / name)
        shutil.copyfile(ROOT / "claude/langfuse-endpoints.env", self.checkout / "claude/langfuse-endpoints.env")
        (self.base / "config/uv").mkdir(parents=True)
        shutil.copyfile(self.guard, self.base / "config/uv/uv.toml")
        self.fake_uv = self.base / "uv"
        self.fake_uv.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                                'if [ "$1 $2" = "tool list" ]; then '
                                'printf "google-colab-cli v1.0\\nexternal-cli v1.0\\n"; fi\n')
        self.fake_uv.chmod(0o755)

    def run_activation(self, dry_run=""):
        body = re.sub(r'UV_BIN=/nix/store/[^\s]+/bin/uv', f'UV_BIN={self.fake_uv}', self.body)
        body = re.sub(r'/nix/store/[^\s]+/bin/bash', os.environ["TEST_BASH"], body)
        env = dict(os.environ, HOME=str(self.base), XDG_CONFIG_HOME=str(self.base / "config"),
                   DRY_RUN_CMD=dry_run, DOTFILES_PLATFORM="linux-x86_64",
                   CALLS=str(self.base / "calls"), PATH=os.environ["TEST_PATH"])
        return subprocess.run([os.environ["TEST_BASH"], "-c", body], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_snapshot_guard_and_endpoint_survive_checkout_edits(self):
        names = {p.name for p in self.snapshot.iterdir()}
        self.assertEqual(names, {"sync-tools.sh", "tools.txt", "uv.toml"})
        self.assertTrue(all(p.is_file() and not p.is_symlink() for p in self.snapshot.iterdir()))
        old = {name: (self.snapshot / name).read_bytes() for name in names}
        self.assertEqual(old["uv.toml"], self.guard.read_bytes())
        for name in names:
            self.assertEqual(old[name], (self.checkout / "uv" / name).read_bytes())
            (self.checkout / "uv" / name).write_text("changed checkout\n")
        endpoint = self.endpoints.read_bytes()
        self.assertEqual(endpoint, (self.checkout / "claude/langfuse-endpoints.env").read_bytes())
        (self.checkout / "claude/langfuse-endpoints.env").write_text("changed checkout\n")
        self.assertEqual(old, {name: (self.snapshot / name).read_bytes() for name in names})
        self.assertEqual(endpoint, self.endpoints.read_bytes())
        self.assertEqual(os.environ["LANGFUSE_SECRET_DECLARED"], "0")
        self.assertNotIn("langfuse.env", self.body)
        self.assertNotIn("langfuse-endpoints", self.body)
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.base / "calls").read_text().splitlines()
        self.assertEqual(calls, ["tool list"])
        self.assertIn("external-cli", result.stderr)

    def test_dry_run_does_not_invoke_uv(self):
        result = self.run_activation("echo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / "calls").exists())

    def test_guard_mismatch_blocks_uv(self):
        (self.base / "config/uv/uv.toml").write_text("different generation\n")
        result = self.run_activation()
        # Activation deliberately treats a failed sync as non-fatal.
        self.assertEqual(result.returncode, 0)
        self.assertIn("configuration missing or unapplied", result.stderr)
        self.assertFalse((self.base / "calls").exists())


if __name__ == "__main__":
    unittest.main()
