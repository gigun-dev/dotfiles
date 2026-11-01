"""Run the generated link activation against isolated Claude settings fixtures."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


class ClaudeUserSettingsTest(unittest.TestCase):
    def test_activation_preserves_user_settings(self):
        activation = Path(os.environ["CLAUDE_ACTIVATION"]).read_text()
        original_home = os.environ["CLAUDE_HOME"]
        for kind in ("file", "symlink", "missing"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                home = Path(temp) / "home"
                claude = home / ".claude"
                repo = home / "ghq/github.com/gigun-dev/dotfiles"
                (repo / "claude").mkdir(parents=True)
                claude.mkdir(parents=True)
                tracked = repo / "claude/settings.json"
                tracked.write_bytes(b'{"host":"tracked"}\n')
                settings = claude / "settings.json"
                if kind == "file":
                    settings.write_bytes(b'{"host":"local"}\n')
                    settings.chmod(0o640)
                    before = settings.stat()
                elif kind == "symlink":
                    settings.symlink_to(tracked)
                script = activation.replace(original_home, str(home))
                env = dict(os.environ, DRY_RUN_CMD="", PATH=os.environ.get("TEST_PATH", os.environ["PATH"]))
                for _ in range(2):
                    subprocess.run([os.environ.get("TEST_BASH", "bash"), "-eu", "-c", script], env=env, check=True)
                    self.assertEqual(tracked.read_bytes(), b'{"host":"tracked"}\n')
                    if kind == "file":
                        self.assertFalse(settings.is_symlink())
                        self.assertEqual(settings.read_bytes(), b'{"host":"local"}\n')
                        self.assertEqual(settings.stat().st_ino, before.st_ino)
                        self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o640)
                    elif kind == "symlink":
                        self.assertTrue(settings.is_symlink())
                        self.assertEqual(settings.readlink(), tracked)
                    else:
                        self.assertFalse(settings.exists())
                        self.assertFalse(settings.is_symlink())
                    for asset in ("hooks", "commands", "agents"):
                        self.assertEqual((claude / asset).readlink(), repo / "claude" / asset)


if __name__ == "__main__":
    unittest.main()
