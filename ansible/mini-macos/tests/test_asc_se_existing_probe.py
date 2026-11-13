import hashlib
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch
BASE = Path(__file__).parents[1] / 'scripts'
def load(name):
    s=importlib.util.spec_from_file_location(name, BASE / (name+'.py')); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
m=load('asc_se_existing_probe'); core=load('asc_se_canary')


class ExistingProbe(unittest.TestCase):
    def fixture(self, root, response):
        tc=root/'toolchain'; tc.mkdir(); (tc/'asc_se_canary.py').write_bytes(b'public fixture core')
        fixture=root/'fixture'; fixture.mkdir(mode=0o700)
        for name in ['canary.sops','se-identity.txt','sops.yaml','result.json']:
            core.write(fixture/name,b'nonsecret fixture')
        invoke=Mock(return_value=response)
        namespace={'account':lambda expected:SimpleNamespace(pw_dir=str(root),pw_name='gigun'), 'private_file':core.private_file,'tools':lambda path:{'sops':'/tools/sops'},'run':invoke,'write':core.write,'CANARY':core.CANARY}
        return tc,fixture,namespace,invoke

    def test_existing_canary_only_no_regeneration_and_create_only_result(self):
        with tempfile.TemporaryDirectory() as td:
            tc,fixture,ns,invoke=self.fixture(Path(td),core.CANARY)
            with patch.object(m,'TOOLCHAIN',tc),patch.object(m,'FIXTURE',fixture),patch.object(m,'CORE_SHA256',hashlib.sha256(b'public fixture core').hexdigest()),patch.object(m,'CIPHER_SHA256',hashlib.sha256(b'nonsecret fixture').hexdigest()),patch.object(m.runpy,'run_path',return_value=ns):
                result=m.execute('unlocked',0)
                self.assertTrue(result['seDecryptPassed']); self.assertFalse(result['newKeyGenerated']); self.assertFalse(result['stateObservedByOS'])
                with self.assertRaises(FileExistsError): m.execute('unlocked',0)
                invoke.assert_called_once()
                self.assertNotIn('keygen',str(invoke.call_args))
                self.assertEqual((fixture/'se-identity.txt').read_bytes(),b'nonsecret fixture')

    def test_decrypt_failure_is_typed_and_does_not_display_diagnostic(self):
        with tempfile.TemporaryDirectory() as td:
            tc,fixture,ns,invoke=self.fixture(Path(td),b''); invoke.side_effect=ValueError('do not display diagnostic')
            with patch.object(m,'TOOLCHAIN',tc),patch.object(m,'FIXTURE',fixture),patch.object(m,'CORE_SHA256',hashlib.sha256(b'public fixture core').hexdigest()),patch.object(m,'CIPHER_SHA256',hashlib.sha256(b'nonsecret fixture').hexdigest()),patch.object(m.runpy,'run_path',return_value=ns):
                result=m.execute('locked',0)
                self.assertFalse(result['seDecryptPassed']); self.assertIsNone(result['plaintextSHA256']); self.assertNotIn('diagnostic',json.dumps(result))

    def test_labels_and_delay_are_bounded(self):
        for label,delay in [('other',0),('locked',61),('unlocked',True)]:
            with self.assertRaises(ValueError): m.execute(label,delay)
