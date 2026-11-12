import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('asc_uid_fixture', Path(__file__).resolve().parents[1] / 'scripts/asc_uid_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class UIDFixture(unittest.TestCase):
    def test_non_root_cannot_start(self):
        with patch.object(fixture.os, 'geteuid', return_value=501), patch.object(fixture.subprocess, 'run') as child:
            with self.assertRaises(ValueError):
                fixture.execute('builder', 'signer')
            child.assert_not_called()

    def test_same_uid_cannot_claim_separation(self):
        account = SimpleNamespace(pw_uid=600, pw_gid=20)
        with patch.object(fixture.os, 'geteuid', return_value=0), patch.object(fixture.pwd, 'getpwnam', return_value=account), patch.object(fixture.subprocess, 'run') as child:
            with self.assertRaises(ValueError):
                fixture.execute('builder', 'signer')
            child.assert_not_called()

    def test_child_has_no_ambient_credentials_or_groups(self):
        account = SimpleNamespace(pw_uid=600, pw_gid=20)
        with patch.object(fixture.subprocess, 'run') as child:
            fixture.as_user(account, Path('/fixture'), fixture.READ, '/fixture/canary')
        call = child.call_args
        self.assertEqual(call.kwargs['env'], {'PATH': '/usr/bin:/bin', 'HOME': '/fixture'})
        self.assertEqual(call.kwargs['extra_groups'], [])
        self.assertEqual(call.kwargs['user'], 600)
        self.assertEqual(call.args[0][:3], ['/usr/bin/python3', '-I', '-c'])
