"""Inspect evaluated declarations, independently of Nix source formatting."""
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class Declarations(unittest.TestCase):
    def test_guard_and_profile_use_canonical_contents(self):
        data = json.loads(Path(os.environ['DECLARATIONS']).read_text())
        expected = {'.npmrc':'npm/npmrc', '.bunfig.toml':'bun/bunfig.toml',
                    '.config/.bunfig.toml':'bun/bunfig.toml', '.config/uv/uv.toml':'uv/uv.toml',
                    '.config/pip/pip.conf':'pip/pip.conf', '.zprofile':'zsh/.zprofile'}
        if os.environ['TEST_SYSTEM'].endswith('darwin'):
            expected['Library/Application Support/pip/pip.conf'] = 'pip/pip.conf'
        self.assertEqual(set(data['files']), set(expected))
        for target, source in expected.items():
            with self.subTest(target=target):
                file = data['files'][target]
                self.assertTrue(file['enable'])
                self.assertFalse(file['force'])
                self.assertEqual(file['target'], target)
                self.assertEqual(file['text'], (ROOT / source).read_text())
        self.assertEqual(data['cleanup'], 'uninstall')

if __name__ == '__main__':
    unittest.main()
