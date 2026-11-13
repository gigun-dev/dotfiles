import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sdk_mapping', Path(__file__).parents[1] / 'scripts/asc_sdk_mapping.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ROW = {'sdkIdentifier': 'iphoneos26.2', 'sdkBuildUpdate': '23C57', 'simulatorBuildUpdate': '23D8133'}
DATA = plistlib.dumps({'sdkToSimulatorMappings': [ROW]})
DIGEST = hashlib.sha256(DATA).hexdigest()


class SDKMapping(unittest.TestCase):
    def call(self, home, apply=False):
        account = SimpleNamespace(pw_uid=os.geteuid(), pw_name='fixture', pw_dir=str(home))
        with patch.object(m.pwd, 'getpwuid', return_value=account), patch.object(m, 'installed_pair'):
            return m.initialize(DATA, DIGEST, 'iphoneos26.2', '23C57', '23D8133', 'fixture', apply)

    def test_plan_then_apply_and_identical_rerun(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            self.assertEqual(self.call(home)['status'], 'planned')
            self.assertFalse((home / 'Library').exists())
            self.assertTrue(self.call(home, True)['changed'])
            target = home / m.RELATIVE
            self.assertEqual(plistlib.loads(target.read_bytes()), [ROW])
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertFalse(self.call(home, True)['changed'])

    def test_hash_and_unapproved_mapping_rejected(self):
        with self.assertRaises(ValueError):
            m.select_mapping(DATA, '0' * 64, 'iphoneos26.2', '23C57', '23D8133')
        with self.assertRaises(ValueError):
            m.select_mapping(DATA, DIGEST, 'iphoneos26.2', '23C57', 'other')
        duplicate = plistlib.dumps({'sdkToSimulatorMappings': [ROW, ROW]})
        with self.assertRaises(ValueError):
            m.select_mapping(duplicate, hashlib.sha256(duplicate).hexdigest(), 'iphoneos26.2', '23C57', '23D8133')

    def test_existing_metadata_preserved(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home); target = home / m.RELATIVE
            target.parent.mkdir(parents=True)
            target.write_bytes(b'existing metadata')
            with self.assertRaises(ValueError):
                self.call(home, True)
            self.assertEqual(target.read_bytes(), b'existing metadata')

    def test_symlink_ancestor_and_target_rejected(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as other:
            home = Path(home)
            (home / 'Library').symlink_to(other)
            with self.assertRaises(ValueError):
                self.call(home, True)
            (home / 'Library').unlink()
            target = home / m.RELATIVE
            target.parent.mkdir(parents=True)
            target.symlink_to(Path(other) / 'missing')
            with self.assertRaises(OSError):
                self.call(home, True)
            self.assertEqual(list(Path(other).iterdir()), [])

    def test_writable_ancestor_rejected(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            (home / 'Library').mkdir(mode=0o777)
            (home / 'Library').chmod(0o777)
            with self.assertRaises(ValueError):
                self.call(home, True)

    def test_sdk_runtime_binding_failure_creates_nothing(self):
        with tempfile.TemporaryDirectory() as home:
            account = SimpleNamespace(pw_uid=os.geteuid(), pw_name='fixture', pw_dir=home)
            with patch.object(m.pwd, 'getpwuid', return_value=account), patch.object(m, 'installed_pair', side_effect=ValueError('wrong installed pair')):
                with self.assertRaises(ValueError):
                    m.initialize(DATA, DIGEST, 'iphoneos26.2', '23C57', '23D8133', 'fixture', True)
            self.assertEqual(list(Path(home).iterdir()), [])

    def test_non_root_expected_owner_required(self):
        for uid, name in [(0, 'fixture'), (601, 'other')]:
            with patch.object(m.pwd, 'getpwuid', return_value=SimpleNamespace(pw_uid=uid, pw_name=name)):
                with self.assertRaises(ValueError):
                    m.initialize(DATA, DIGEST, 'iphoneos26.2', '23C57', '23D8133', 'fixture', True)
