import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
import state

class StateTests(unittest.TestCase):
    def setUp(self):
        self.lock=state.read(state.ROOT/'fzf.lock.json')
        self.env={'os':'Darwin','arch':'x86_64','macos_major':'15','prefix':'/usr/local'}
    def key(self,lock=None,recipe=b'recipe'):
        return state.key(lock or self.lock,self.env,recipe)
    def test_input_changes_invalidate(self):
        for path in [('version',),('go','version'),('build_sha256',),('go','build_sha256')]:
            other=copy.deepcopy(self.lock); obj=other
            for part in path[:-1]: obj=obj[part]
            obj[path[-1]]='9.9.9' if path[-1]=='version' else 'a'*64
            self.assertNotEqual(self.key(),self.key(other))
        self.assertNotEqual(self.key(),self.key(recipe=b'changed'))
    def test_unrelated_core_and_bottle_metadata_do_not_rebuild(self):
        other=copy.deepcopy(self.lock);other['core_revision']='a'*40;other['formula_sha256']='b'*64
        self.assertEqual(self.key(),self.key(other))
        a='class Fzf\n  bottle do\n    sha256 "old"\n  end\n  def install\n  end\nend\n'
        self.assertEqual(state.build_hash(a),state.build_hash(a.replace('old','new')))
    def test_unknown_dependency_and_wrong_target_refused(self):
        other=copy.deepcopy(self.lock);other['dependencies']['runtime']=['extra']
        with self.assertRaises(AssertionError): self.key(other)
        self.env['arch']='arm64'
        with self.assertRaises(AssertionError): self.key()
    def test_artifacts_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=pathlib.Path(tmp);b=d/'fzf--0.74.5.sequoia.bottle.tar.gz';b.write_bytes(b'bottle')
            m={'schema':1,'key':self.key(),'status':'validated','checks':['formula-test','x86_64','unlinked','no-nix-linkage','go-unchanged'],'files':{b.name:state.sha(b.read_bytes())}}
            def save(): (d/'validated.json').write_text(json.dumps(m))
            save();state.verify(d,self.key())
            with self.assertRaises(AssertionError): state.verify(d,'a'*64)
            b.write_bytes(b'corrupt')
            with self.assertRaises(AssertionError): state.verify(d,self.key())
            b.write_bytes(b'bottle');m['files']={'../escape':state.sha(b.read_bytes())};save()
            with self.assertRaises(AssertionError): state.verify(d,self.key())
            (d/'SHA256SUMS').write_text(state.sha(b.read_bytes())+'  ./'+b.name+'\n')
            self.assertEqual(state.verify_build(d),b)
            (d/'SHA256SUMS').write_text('a'*64+'  /etc/passwd\n')
            with self.assertRaises(AssertionError):state.verify_build(d)
    def test_disabled_policy(self):
        self.assertEqual(state.read(state.ROOT/'policy.json'),{'build_enabled':False,'update_pr_enabled':False,'durable_destination':None,'artifact_retention_days':14})
    def test_prepare_requires_explicit_execution(self):
        p=subprocess.run(['bash',str(state.ROOT/'recipe.sh'),'prepare-ci'],capture_output=True,text=True)
        self.assertEqual(p.returncode,2)
        self.assertIn('no changes made',p.stderr)

if __name__=='__main__':unittest.main()

class ReuseTests(unittest.TestCase):
    def test_only_successful_matching_workflow_can_be_reused(self):
        import reuse
        import os
        key='a'*64
        artifact={'expired':False,'name':'fzf-validated-'+key,'workflow_run':{'id':7}}
        bad={'id':7,'conclusion':'failure','path':'.github/workflows/fzf-intel-bottle.yml','head_repository':{'full_name':'owner/repo'},'event':'workflow_dispatch'}
        with tempfile.TemporaryDirectory() as tmp:
            output=pathlib.Path(tmp)/'output'
            with patch.dict(os.environ,{'GITHUB_REPOSITORY':'owner/repo','GITHUB_OUTPUT':str(output)}),patch.object(sys,'argv',['reuse',key,tmp]),patch.object(reuse,'api',side_effect=[{'artifacts':[artifact]},bad]),patch.object(reuse.subprocess,'run') as download:
                reuse.main();download.assert_not_called()
            self.assertEqual(output.read_text(),'reused=false\n')
            good=dict(bad,conclusion='success')
            with patch.dict(os.environ,{'GITHUB_REPOSITORY':'owner/repo','GITHUB_OUTPUT':str(output)}),patch.object(sys,'argv',['reuse',key,tmp]),patch.object(reuse,'api',side_effect=[{'artifacts':[artifact]},good]),patch.object(reuse.subprocess,'run') as download,patch.object(state,'verify') as verify:
                reuse.main();download.assert_called_once();verify.assert_called_once_with(tmp,key)
            self.assertTrue(output.read_text().endswith('reused=true\n'))

class GoTests(unittest.TestCase):
    def test_same_version_wrong_origin_or_revision_refused(self):
        lock=state.read(state.ROOT/'fzf.lock.json')
        receipt={'source':{'tap':'homebrew/core','tap_git_head':lock['core_revision'],'spec':'stable'}}
        v=lock['go']['version']
        self.assertTrue(state.go_matches('go'+v,v,receipt,lock))
        self.assertFalse(state.go_matches('go'+v,v+'_1',receipt,lock))
        receipt['source']['tap_git_head']='a'*40
        self.assertFalse(state.go_matches('go'+v,v,receipt,lock))
