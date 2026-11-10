"""Run the generated link activation against isolated Claude settings fixtures."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


class ClaudeUserSettingsTest(unittest.TestCase):
    def test_activation_preserves_user_settings(self):
        activation = Path(os.environ["CLAUDE_ACTIVATION"]).read_text()
        settings_activation = Path(os.environ["CLAUDE_SETTINGS_ACTIVATION"]).read_text()
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
                old_agents = claude / "agents"
                old_agents.symlink_to(repo / "claude/agents")
                script = (activation + "\n" + settings_activation).replace(original_home, str(home))
                env = dict(os.environ, DRY_RUN_CMD="", PATH=os.environ.get("TEST_PATH", os.environ["PATH"]))
                for iteration in range(2):
                    subprocess.run([os.environ.get("TEST_BASH", "bash"), "-eu", "-c", script], env=env, check=True)
                    self.assertEqual(tracked.read_bytes(), b'{"host":"tracked"}\n')
                    if kind == "file":
                        self.assertFalse(settings.is_symlink())
                        self.assertNotEqual(settings.stat().st_ino, before.st_ino)
                    elif kind == "symlink":
                        self.assertFalse(settings.is_symlink())
                    else:
                        self.assertTrue(settings.exists())
                        self.assertFalse(settings.is_symlink())
                    merged = json.loads(settings.read_text())
                    if kind == "file":
                        self.assertEqual(merged["host"], "local")
                    elif kind == "symlink":
                        self.assertEqual(merged["host"], "tracked")
                    self.assertIs(merged["enabledPlugins"]["t3@gigun"], True)
                    marketplace = merged["extraKnownMarketplaces"]["gigun"]["source"]["path"]
                    self.assertTrue(marketplace.endswith("/ghq/github.com/gigun-dev/claude-code"))
                    if not os.environ["TEST_SYSTEM"].endswith("darwin"):
                        self.assertEqual(
                            marketplace,
                            str(Path(original_home) / "ghq/github.com/gigun-dev/claude-code"),
                        )
                        self.assertNotIn("permissions", merged)
                        self.assertNotIn("hooks", merged)
                    self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o600)
                    for asset in ("hooks", "commands"):
                        self.assertEqual((claude / asset).readlink(), repo / "claude" / asset)
                    self.assertEqual((claude / "CLAUDE.md").readlink(), repo / "agents/AGENTS.md")
                    self.assertEqual((claude / "shared").readlink(), repo / "agents/shared")
                    if iteration == 0:
                        self.assertFalse(old_agents.exists())
                        self.assertFalse(old_agents.is_symlink())
                        old_agents.symlink_to(repo / "host-local-agents")
                    else:
                        self.assertTrue(old_agents.is_symlink())
                        self.assertEqual(old_agents.readlink(), repo / "host-local-agents")

    def test_settings_activation_dry_run_does_not_write(self):
        settings_activation = Path(os.environ["CLAUDE_SETTINGS_ACTIVATION"]).read_text()
        original_home = os.environ["CLAUDE_HOME"]
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "home"
            claude = home / ".claude"
            claude.mkdir(parents=True)
            settings = claude / "settings.json"
            settings.write_text('{"host":"unchanged"}\n')
            before = settings.read_bytes()
            script = settings_activation.replace(original_home, str(home))
            env = dict(os.environ, DRY_RUN_CMD="echo", PATH=os.environ.get("TEST_PATH", os.environ["PATH"]))
            subprocess.run([os.environ.get("TEST_BASH", "bash"), "-eu", "-c", script], env=env, check=True)
            self.assertEqual(settings.read_bytes(), before)
            self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o644)


if __name__ == "__main__":
    unittest.main()
