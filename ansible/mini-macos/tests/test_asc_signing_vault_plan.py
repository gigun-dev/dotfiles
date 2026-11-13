import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('vault_plan',Path(__file__).parents[1]/'scripts/asc_signing_vault_plan.py'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class VaultPlan(unittest.TestCase):
    def fixture(self,home):
        identity=home/'identity'; identity.mkdir(mode=0o700)
        key=home/'key'; key.write_bytes(b'fixture key that must never be opened'); key.chmod(0o600)
        for name in ['distribution.p12','identity-password']:
            p=identity/name; p.write_bytes(b'fixture source secret'); p.chmod(0o600)
        return identity,key

    def test_source_secret_bytes_never_opened_and_no_effects(self):
        with tempfile.TemporaryDirectory() as td:
            home=Path(td); identity,key=self.fixture(home)
            with patch.object(m.os,'open',side_effect=AssertionError('source bytes must not be read')):
                result=m.plan(home,os.geteuid(),'fixture',identity,key,home/'vault')
            self.assertFalse(result['secretBytesRead']); self.assertFalse(result['readyForApply'])
            self.assertIn('recovery-recipient-metadata-missing',result['blockers'])
            self.assertIn('post-reboot-first-unlock-behavior-not-accepted',result['blockers'])
            self.assertFalse((home/'vault').exists())
            self.assertNotIn('fixture source secret',json.dumps(result))

    def test_metadata_drift_changes_plan_and_existing_vault_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            home=Path(td); identity,key=self.fixture(home)
            a=m.plan(home,os.geteuid(),'fixture',identity,key,home/'vault')
            key.write_bytes(b'changed fixture length')
            b=m.plan(home,os.geteuid(),'fixture',identity,key,home/'vault')
            self.assertNotEqual(a['planSHA256'],b['planSHA256'])
            (home/'vault').mkdir()
            with self.assertRaises(ValueError): m.plan(home,os.geteuid(),'fixture',identity,key,home/'vault')

    def test_symlink_and_parent_escape_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            home=Path(td); identity,key=self.fixture(home)
            link=home/'linked-key'; link.symlink_to(key)
            with self.assertRaises(ValueError): m.private_metadata(link,os.geteuid(),home)
            with self.assertRaises(ValueError): m.private_metadata(home/'..'/'key',os.geteuid(),home)

    def test_native_age_recipient_file_does_not_prove_real_hardware_recovery(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'recipients.txt'
            public=['age1yubikey1'+'q'*40,'age1yubikey1'+'p'*40]
            path.write_text('# primary then backup public fixtures\n'+'\n'.join(public)+'\n')
            recipients,blockers=m.recovery_metadata(path)
            self.assertEqual([x['role'] for x in recipients],['recovery-a','recovery-b'])
            self.assertIn('independent-recovery-canaries-not-accepted',blockers)
            path.write_text('AGE-PLUGIN-YUBIKEY-PRIVATE-FIXTURE\n'+public[1])
            with self.assertRaises(ValueError): m.recovery_metadata(path)
            path.write_text(public[0]+'\n'+public[0])
            with self.assertRaises(ValueError): m.recovery_metadata(path)
