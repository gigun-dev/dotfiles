import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('toolchain', Path(__file__).parents[1] / 'scripts/asc_toolchain_install.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Toolchain(unittest.TestCase):
    def fixture(self, root):
        bundle = root / 'bundle'; bundle.mkdir(mode=0o700)
        files = []
        for name in ['bin/asc', 'bin/xcodegen', 'share/xcodegen/SettingPresets/base.yml']:
            p = bundle / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(name.encode())
            files.append({'path': name, 'mode': '0555' if name.startswith('bin/') else '0444', 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
        raw = json.dumps({'schemaVersion': 1, 'version': 'fixture-1', 'files': files}).encode()
        (bundle / 'manifest.json').write_bytes(raw)
        return bundle, hashlib.sha256(raw).hexdigest()

    def test_plan_no_writes_and_apply_complete_layout(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); bundle, digest = self.fixture(root)
            target = root / 'versions/fixture-1'
            actual_lstat = Path.lstat
            installers = {Path(m.__file__).absolute(), Path(m.guard.__file__).absolute()}
            def lstat(p):
                return SimpleNamespace(st_uid=0, st_mode=0o100500) if p in installers else actual_lstat(p)
            with patch.object(m, 'BASE', root / 'versions'), patch.object(m.guard, 'protected_ancestors'), patch.object(m.os, 'geteuid', return_value=0), patch.object(m.os, 'chown'), patch.object(m.os, 'fchown'), patch.object(Path, 'lstat', lstat):
                self.assertEqual(m.execute(bundle, digest)['fileCount'], 3)
                self.assertFalse(target.exists())
                m.execute(bundle, digest, True)
                self.assertEqual((target / 'bin/xcodegen').stat().st_mode & 0o777, 0o555)
                self.assertEqual((target / 'share/xcodegen/SettingPresets/base.yml').stat().st_mode & 0o777, 0o444)
                with self.assertRaises(FileExistsError): m.execute(bundle, digest, True)

    def test_changed_preset_or_manifest_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            bundle, digest = self.fixture(Path(td))
            with self.assertRaises(ValueError): m.candidate(bundle, '0' * 64)
            (bundle / 'share/xcodegen/SettingPresets/base.yml').write_bytes(b'changed')
            with self.assertRaises(ValueError): m.candidate(bundle, digest)

    def test_symlink_input_ancestor_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); bundle, digest = self.fixture(root)
            (bundle / 'bin').rename(root / 'outside')
            (bundle / 'bin').symlink_to(root / 'outside')
            with self.assertRaises(ValueError): m.candidate(bundle, digest)

    def test_failure_removes_only_new_tree(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); bundle, digest = self.fixture(root)
            base = root / 'versions'; base.mkdir(); (base / 'old').mkdir()
            original = Path.lstat; installers = {Path(m.__file__).absolute(), Path(m.guard.__file__).absolute()}
            def lstat(p): return SimpleNamespace(st_uid=0, st_mode=0o100500) if p in installers else original(p)
            with patch.object(m, 'BASE', base), patch.object(m.guard, 'protected_ancestors'), patch.object(m.os, 'geteuid', return_value=0), patch.object(m.os, 'chown', side_effect=OSError('fixture failure')), patch.object(Path, 'lstat', lstat):
                with self.assertRaises(OSError): m.execute(bundle, digest, True)
            self.assertEqual(list(base.iterdir()), [base / 'old'])
