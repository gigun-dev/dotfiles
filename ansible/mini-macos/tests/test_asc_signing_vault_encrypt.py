import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import asc_signing_vault_encrypt as vault


class EncryptionTests(unittest.TestCase):
    def test_descriptor_binding_rejects_replacement_and_symlink(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            path = home / 'fixture'
            path.write_bytes(b'nonsecret fixture')
            path.chmod(0o600)
            binding = vault.planner.private_metadata(path, os.geteuid(), home)
            path.rename(home / 'original')
            path.write_bytes(b'replacement')
            path.chmod(0o600)
            with self.assertRaises(ValueError):
                vault.open_bound(binding)
            path.unlink()
            path.symlink_to(home / 'original')
            with self.assertRaises(OSError):
                vault.open_bound(binding)

    def test_encryption_uses_descriptor_and_suppresses_stderr(self):
        with tempfile.TemporaryFile() as source:
            source.write(b'NONSECRET test bytes')
            source.seek(0)
            command = [sys.executable, '-c',
                       'import sys; assert sys.stdin.buffer.read()==b"NONSECRET test bytes"; '
                       'sys.stderr.write("not forwarded"); sys.stdout.buffer.write(b"cipher fixture")']
            self.assertEqual(vault.encrypt_fd(command, {}, source.fileno()), b'cipher fixture')

    def test_owner_local_flow_retains_sources_and_never_decrypts_them(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            inputs = home / 'inputs'
            inputs.mkdir(mode=0o700)
            for name in ('distribution.p12', 'identity-password', 'distribution.key'):
                (inputs / name).write_bytes(b'NONSECRET fixture ' + name.encode())
                (inputs / name).chmod(0o600)
            before = {p.name: p.read_bytes() for p in inputs.iterdir()}
            recipients = home / 'recovery.txt'
            recipients.write_text('age1yubikey1' + 'q'*40 + '\nage1yubikey1' + 'p'*40 + '\n')
            output = home / 'vault'
            owner = types.SimpleNamespace(pw_dir=str(home), pw_name='fixture', pw_uid=os.geteuid())
            calls = []
            def run(command, env, data=None):
                calls.append(command)
                if 'keygen' in command:
                    vault.se.write(output / 'se-identity.txt', b'NONSECRET identity fixture')
                    return b''
                if 'recipients' in command:
                    return b'age1se1fixture'
                if '--encrypt' in command:
                    self.assertEqual(data, vault.se.CANARY)
                    return b'NONSECRET canary ciphertext fixture'
                self.assertEqual(Path(command[-1]).name, 'canary.sops')
                self.assertIn('--decrypt', command)
                return vault.se.CANARY
            commands = {name: name for name in vault.se.NAMES}
            with patch.object(vault.se, 'account', return_value=owner), \
                 patch.object(vault.se, 'tools', return_value=commands), \
                 patch.object(vault.se, 'run', side_effect=run), \
                 patch.object(vault, 'encrypt_fd', return_value=b'NONSECRET ciphertext') as encrypt:
                result = vault.execute(output, 'fixture', Path('/protected/bin'), inputs,
                                       inputs / 'distribution.key', recipients)
            self.assertEqual(encrypt.call_count, 3)
            self.assertFalse(result['realMaterialDecrypted'])
            self.assertFalse(result['sourceFilesDeleted'])
            self.assertEqual(before, {p.name: p.read_bytes() for p in inputs.iterdir()})
            self.assertEqual(len([c for c in calls if '--decrypt' in c]), 1)
            for p in output.iterdir():
                self.assertEqual(p.stat().st_mode & 0o077, 0)


if __name__ == '__main__':
    unittest.main()
