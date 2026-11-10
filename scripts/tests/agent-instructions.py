#!/usr/bin/env python3
"""Check that shared agent instructions reach Claude and generated Codex settings."""

import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
AGENTS = ROOT / "agents"
SOURCE = AGENTS / "AGENTS.md"
PRIVACY = AGENTS / "shared/command-privacy.md"
IMPORT_PREFIX = "@~/.claude/shared/"


class AgentInstructionsTest(unittest.TestCase):
    def shared_imports(self):
        return [
            line.removeprefix(IMPORT_PREFIX)
            for line in SOURCE.read_text().splitlines()
            if line.startswith(IMPORT_PREFIX)
        ]

    def generated_codex_instructions(self):
        result = subprocess.run(
            [os.environ.get("TEST_SH", "sh"), str(AGENTS / "codex-agents-md.sh"), str(AGENTS)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_claude_shared_imports_exist_and_are_unique(self):
        imports = self.shared_imports()
        self.assertEqual(len(imports), len(set(imports)))
        self.assertEqual(imports.count("command-privacy.md"), 1)
        for name in imports:
            with self.subTest(name=name):
                self.assertTrue((AGENTS / "shared" / name).is_file())

    def test_codex_generation_expands_privacy_once(self):
        generated = self.generated_codex_instructions()
        privacy = PRIVACY.read_text().rstrip()
        self.assertEqual(generated.count(privacy.splitlines()[0]), 1)
        self.assertEqual(generated.count(privacy), 1)
        self.assertNotIn(IMPORT_PREFIX, generated)


if __name__ == "__main__":
    unittest.main()
