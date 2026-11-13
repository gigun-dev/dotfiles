import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('signing_state', Path(__file__).parents[1] / 'scripts/asc_signing_state.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class SigningState(unittest.TestCase):
    def test_private_metadata_only_and_no_path_or_other_fields_disclosed(self):
        journal = {'schemaVersion': 1, 'tempDir': str(m.OLD), 'keychainPath': str(m.OLD / 'signing.keychain-db'), 'profileCreated': False, 'irrelevant': 'private-fixture-metadata'}
        receipt = {'outcome': ['wrong type'], 'profileCleanupState': 'removed', 'keychainCleanupState': 'deleted', 'profileUuid': 'private-fixture-uuid'}
        owner = SimpleNamespace(pw_name='asc-sign', pw_uid=601, pw_dir='/fixture-home')
        result = SimpleNamespace(returncode=0, stdout=('/private' + str(m.OLD / 'signing.keychain-db')).encode())
        with patch.object(m.pwd, 'getpwuid', return_value=owner), patch.object(m.os, 'geteuid', return_value=601), patch.object(m, 'private_json', side_effect=[journal, receipt]), patch.object(m, 'exists', return_value=False), patch.object(m.subprocess, 'run', return_value=result), contextlib.redirect_stdout(io.StringIO()) as output:
            m.main()
        d = json.loads(output.getvalue())
        self.assertTrue(d['journalReferencesOldKeychain'])
        self.assertTrue(d['oldKeychainInSearchList'])
        self.assertEqual(d['receiptStates']['outcome'], 'unrecognized')
        self.assertNotIn('private-fixture', output.getvalue())
        self.assertNotIn(str(m.OLD), output.getvalue())

    def test_bounded_owner_metadata_and_symlink_guard(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'journal'; path.write_text('{}'); path.chmod(0o600)
            self.assertEqual(m.private_json(path), {})
            path.chmod(0o644)
            with self.assertRaises(ValueError): m.private_json(path)
            link = Path(td) / 'link'; link.symlink_to(path)
            with self.assertRaises(OSError): m.private_json(link)
            self.assertIsNone(m.private_json(Path(td) / 'absent'))
