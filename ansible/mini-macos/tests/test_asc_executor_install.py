import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).resolve().parents[1] / 'scripts/asc_executor_install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ExecutorInstall(unittest.TestCase):
    def bundle(self, root):
        bundle = root / 'bundle'
        bundle.mkdir(mode=0o700)
        revision = 'a' * 40
        entries = []
        for name in installer.FILES:
            data = ('# fixture ' + name).encode()
            (bundle / name).write_bytes(data)
            entries.append({'name': name, 'sha256': hashlib.sha256(data).hexdigest(),
                            'plannedOwner': 'root', 'plannedMode': '0444'})
        raw = json.dumps({'schemaVersion': 1, 'sourceRevision': revision,
                          'plannedVersionDirectory': str(installer.VERSION_BASE / revision),
                          'files': entries}).encode()
        (bundle / 'manifest.json').write_bytes(raw)
        return bundle, hashlib.sha256(raw).hexdigest()

    def test_manifest_and_file_hashes_are_both_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle, digest = self.bundle(Path(temporary))
            revision, blobs = installer.candidate(bundle, digest)
            self.assertEqual(revision, 'a' * 40)
            self.assertEqual(set(blobs), set(installer.FILES))
            with self.assertRaisesRegex(ValueError, 'manifest hash'):
                installer.candidate(bundle, '0' * 64)
            (bundle / installer.FILES[0]).write_text('unreviewed')
            with self.assertRaisesRegex(ValueError, 'executor hash'):
                installer.candidate(bundle, digest)

    def test_symlink_and_special_file_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, digest = self.bundle(root)
            path = bundle / installer.FILES[0]
            path.unlink()
            path.symlink_to(bundle / installer.FILES[1])
            with self.assertRaises(OSError):
                installer.candidate(bundle, digest)
            with self.assertRaises(ValueError):
                installer.read_regular(bundle)

    def test_plan_never_writes_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, digest = self.bundle(root)
            paths = [root / 'version', root / 'build', root / 'sign']
            args = SimpleNamespace(bundle=bundle, manifest_sha256=digest,
                                   build_user='build', sign_user='sign', apply=False)
            with patch.object(installer, 'targets', return_value=(paths, None, None)):
                result = installer.execute(args)
            self.assertEqual(result['operation'], 'plan')
            self.assertTrue(all(not path.exists() for path in paths))

    def test_existing_target_is_never_adopted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'versions').mkdir()
            (root / 'versions' / ('a' * 40)).mkdir()
            accounts = [SimpleNamespace(pw_uid=600), SimpleNamespace(pw_uid=601)]
            with patch.object(installer, 'VERSION_BASE', root / 'versions'), \
                 patch.object(installer.pwd, 'getpwnam', side_effect=accounts):
                with self.assertRaises(FileExistsError):
                    installer.targets('a' * 40, 'build', 'sign')

    def test_unsafe_or_acl_parent_refused(self):
        fake = SimpleNamespace(st_mode=0o040777, st_uid=0)
        with patch.object(Path, 'lstat', return_value=fake):
            with self.assertRaisesRegex(ValueError, 'protected root'):
                installer.protected_ancestors(Path('/fixture'))
        fake.st_mode = 0o040755
        with patch.object(Path, 'lstat', return_value=fake), \
             patch.object(installer.subprocess, 'run', return_value=SimpleNamespace(stdout='directory\n 0: group:everyone allow write\n')):
            with self.assertRaisesRegex(ValueError, 'ACL'):
                installer.protected_ancestors(Path('/fixture'))

    def test_apply_fixture_creates_only_new_outputs_and_cleans_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with patch.object(installer, 'VERSION_BASE', root / 'versions'), \
                     patch.object(installer, 'JOB_BASE', root / 'jobs'):
                    bundle, digest = self.bundle(root)
                    args = SimpleNamespace(bundle=bundle, manifest_sha256=digest,
                                           build_user='builder', sign_user='signer', apply=True)
                    accounts = [SimpleNamespace(pw_uid=600, pw_gid=20), SimpleNamespace(pw_uid=601, pw_gid=20)]
                    original_lstat = Path.lstat
                    script = Path(installer.__file__).absolute()
                    def file_info(path):
                        if path == script:
                            return SimpleNamespace(st_mode=0o100500, st_uid=0)
                        return original_lstat(path)
                    with patch.object(installer.pwd, 'getpwnam', side_effect=accounts), \
                         patch.object(installer, 'protected_ancestors'), \
                         patch.object(installer.os, 'geteuid', return_value=0), \
                         patch.object(installer.os, 'fchown'), \
                         patch.object(Path, 'lstat', file_info), \
                         patch.object(installer.os, 'chown', side_effect=OSError('fixture failure') if fail else None):
                        if fail:
                            with self.assertRaises(OSError):
                                installer.execute(args)
                            self.assertFalse((root / 'versions').exists())
                            self.assertFalse((root / 'jobs').exists())
                        else:
                            result = installer.execute(args)
                            self.assertEqual(result['operation'], 'apply')
                            self.assertEqual((root / 'jobs/build').stat().st_mode & 0o777, 0o700)
                            self.assertEqual((root / 'versions' / ('a' * 40) / installer.FILES[0]).stat().st_mode & 0o777, 0o444)


if __name__ == '__main__':
    unittest.main()
