import copy
import hashlib
from pathlib import Path
import subprocess
import tarfile
import unittest

from test_migration import MigrationFixture


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SigningTools(MigrationFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        sources = self.base / 'sources'
        sources.mkdir()
        nu = sources / 'nu'
        nu.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        archive = sources / 'nu.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(nu, arcname='fixture/nu')
        key = sources / 'nix-secure-enclave-key.nu'
        key.write_text('# fake enclave tool; not executed\n')
        signer = sources / 'nix-secure-enclave-key-git-sign.nu'
        signer.write_text('# fake signer; not executed\n')
        self.variables.update(
            mini_apply_ack=True,
            mini_signing_root=str(self.home / '.local/share/dotfiles/mini-signing'),
            mini_signing_cache=str(self.base / 'controller-cache'),
            mini_signing_bundle_id='fixture-a',
            mini_signing_approved_previous=[],
            mini_signing_archive_member='fixture/nu',
            mini_signing_nu_sha256=sha(nu),
            mini_signing_artifacts=[{'name': p.name, 'url': p.as_uri(), 'sha256': sha(p)}
                                    for p in (archive, key, signer)],
        )
        self.root = Path(self.variables['mini_signing_root'])
        self.cache = Path(self.variables['mini_signing_cache'])

    def apply(self, check=False):
        return self.run_tasks('signing_tools.yml', check=check)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_preview_install_idempotence_and_wrapper_arguments(self):
        self.assert_ok(self.apply(check=True))
        self.assertFalse(self.root.exists())
        self.assertFalse(self.cache.exists())
        self.assert_ok(self.apply())
        self.assertEqual((self.root / 'current').resolve(), self.root / 'versions/fixture-a')
        self.assertFalse((self.home / '.ssh').exists())
        self.assertFalse((self.home / '.gitconfig').exists())
        wrapper = self.root / 'current/git-sign'
        command = subprocess.run([str(wrapper), 'one', 'two words'], capture_output=True, text=True, check=True)
        self.assertEqual(command.stdout.splitlines(), [str(self.root / 'current/nix-secure-enclave-key-git-sign.nu'), 'one', 'two words'])
        again = self.apply()
        self.assert_ok(again)
        self.assertRegex(again.stdout, r'changed=0\s')

    def test_unknown_selection_and_symlinked_parent_are_preserved(self):
        self.root.mkdir(parents=True)
        (self.root / 'current').write_text('existing')
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'current').read_text(), 'existing')
        self.assertFalse(self.cache.exists())
        (self.root / 'current').unlink()
        missing = self.base / 'unknown-missing-target'
        (self.root / 'current').symlink_to(missing)
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / 'current').is_symlink())
        self.assertEqual((self.root / 'current').readlink(), missing)
        self.assertFalse(self.cache.exists())
        (self.root / 'current').unlink()
        self.root.rmdir()
        target = self.base / 'unrelated'
        target.mkdir()
        self.root.symlink_to(target)
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.root.is_symlink())
        self.assertEqual(list(target.iterdir()), [])

    def test_wrong_artifact_and_unknown_destination_fail_closed(self):
        self.variables['mini_signing_nu_sha256'] = '0' * 64
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'current').exists())
        self.variables['mini_signing_nu_sha256'] = sha(self.base / 'sources/nu')
        destination = self.root / 'versions/fixture-a/nu'
        destination.parent.mkdir(parents=True)
        destination.write_text('preserve')
        result = self.apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), 'preserve')
        self.assertFalse((self.root / 'current').exists())

    def test_update_and_rollback_require_ack_and_approved_previous(self):
        self.assert_ok(self.apply())
        first = self.root / 'versions/fixture-a'
        second = self.root / 'versions/fixture-b'
        self.variables['mini_signing_bundle_id'] = 'fixture-b'
        self.variables['mini_signing_approved_previous'] = [str(first)]
        denied = self.apply()
        self.assertNotEqual(denied.returncode, 0)
        self.assertEqual((self.root / 'current').resolve(), first)
        self.variables['mini_update_ack'] = True
        self.assert_ok(self.apply())
        self.assertEqual((self.root / 'current').resolve(), second)
        self.assertTrue((first / 'nu').exists())
        self.variables['mini_signing_bundle_id'] = 'fixture-a'
        self.variables['mini_signing_approved_previous'] = [str(second)]
        self.assert_ok(self.apply())
        self.assertEqual((self.root / 'current').resolve(), first)
        self.assertTrue((second / 'nu').exists())

    def test_signing_target_is_manual_until_ownership_transfer(self):
        variables = copy.deepcopy(self.variables)
        variables.update(inventory_hostname='mini', ansible_host='mini', ansible_user='gigun',
                         mini_home='/Users/gigun', mini_repo='/Users/gigun/ghq/github.com/gigun-dev/dotfiles',
                         mini_targets=['signing_tools'], mini_apply_ack=True)
        result = self.run_tasks('preflight.yml', variables)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Retire the previous writer', result.stdout)
        self.assertNotIn('TASK [Read target operating', result.stdout)


if __name__ == '__main__':
    unittest.main()
