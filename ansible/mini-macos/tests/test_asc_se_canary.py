import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('se_canary', Path(__file__).parents[1] / 'scripts/asc_se_canary.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class SECanary(unittest.TestCase):
    def test_se_and_independent_recovery_have_separate_identities_and_no_ambient_env(self):
        calls = []
        with tempfile.TemporaryDirectory() as td:
            home = Path(td); out = home / 'new'
            owner = SimpleNamespace(pw_uid=os.geteuid(), pw_name='fixture', pw_dir=td)
            def tool(argv, env, data=None):
                calls.append((argv, env, data))
                self.assertNotIn('UNEXPECTED_SECRET', env)
                if 'keygen' in argv or '-o' in argv:
                    path = Path(argv[argv.index('-o') + 1]); m.write(path, b'disposable fixture identity')
                    return b''
                if 'recipients' in argv: return b'age1se1public-fixture\n'
                if '-y' in argv: return b'age1public-recovery-fixture\n'
                if '--encrypt' in argv:
                    self.assertEqual(data, m.CANARY)
                    config = json.loads((out / 'sops.yaml').read_text())
                    self.assertEqual(config['creation_rules'][0]['age'], 'age1se1public-fixture,age1public-recovery-fixture')
                    return b'fixture ciphertext'
                return m.CANARY
            with patch.object(m, 'account', return_value=owner), patch.object(m, 'tools', return_value={n: '/tools/' + n for n in m.NAMES}), patch.object(m, 'run', side_effect=tool), patch.dict(os.environ, {'UNEXPECTED_SECRET': 'fixture'}, clear=True):
                result = m.execute(out, 'fixture', Path('/tools'))
                with self.assertRaises(FileExistsError): m.execute(out, 'fixture', Path('/tools'))
            self.assertTrue(result['headlessSERoundtripPassed'])
            self.assertFalse(result['realSigningMaterialUsed'])
            self.assertNotIn('disposable fixture identity', json.dumps(result))
            decrypt = [env['SOPS_AGE_KEY_FILE'] for argv, env, _ in calls if '--decrypt' in argv]
            self.assertEqual(decrypt, [str(out / 'se-identity.txt'), str(out / 'recovery-identity.txt')])
            for p in out.iterdir():
                if p.is_file(): self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_explicit_background_class_is_new_canary_only_and_probe_reuses_it(self):
        with tempfile.TemporaryDirectory() as td:
            home=Path(td); out=home/'background'; owner=SimpleNamespace(pw_uid=os.geteuid(),pw_name='fixture',pw_dir=td)
            calls=[]
            def tool(argv,env,data=None):
                calls.append(argv)
                if '-o' in argv:
                    m.write(Path(argv[argv.index('-o')+1]),b'fixture identity'); return b''
                if 'recipients' in argv: return b'age1se1fixture'
                if '-y' in argv: return b'age1recoveryfixture'
                if '--encrypt' in argv: return b'fixed fixture ciphertext'
                return m.CANARY
            with patch.object(m,'account',return_value=owner),patch.object(m,'tools',return_value={n:'/tools/'+n for n in m.NAMES}),patch.object(m,'run',side_effect=tool):
                result=m.execute(out,'fixture',Path('/tools'),'after-first-unlock')
                self.assertEqual(result['accessibilityClass'],'after-first-unlock')
                self.assertIn('--accessibility',calls[0]); self.assertEqual(calls[0][-1],'after-first-unlock')
                before=len(calls)
                probe=m.verify_existing(out,'fixture',Path('/tools'),'unlocked')
                self.assertTrue(probe['seDecryptPassed']); self.assertFalse(probe['newKeyGenerated'])
                self.assertEqual(len(calls),before+1)
                self.assertNotIn('keygen',calls[-1])
                (out/'canary.sops').write_bytes(b'changed')
                with self.assertRaises(ValueError): m.verify_existing(out,'fixture',Path('/tools'),'locked')
            with self.assertRaises(ValueError): m.execute(out,'fixture',Path('/tools'),'always')

    def test_wrong_parent_and_owner_rejected(self):
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as outside:
            owner = SimpleNamespace(pw_uid=os.geteuid(), pw_name='fixture', pw_dir=td)
            with patch.object(m, 'account', return_value=owner):
                with self.assertRaises(ValueError): m.execute(Path(outside) / 'new', 'fixture', Path('/tools'))
            with patch.object(m.pwd, 'getpwuid', return_value=SimpleNamespace(pw_uid=0, pw_name='fixture')):
                with self.assertRaises(ValueError): m.account('fixture')
