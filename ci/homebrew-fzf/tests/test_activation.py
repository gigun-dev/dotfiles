import base64
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
import releases
import state
import update

class ReleaseTests(unittest.TestCase):
    def test_missing_release_and_api_denial_are_distinct(self):
        with patch.object(releases,'api',side_effect=[{'private':True},[]]):
            self.assertFalse(releases.retrieve('o/r','a'*64,'unused'))
        with patch.object(releases,'api',side_effect=subprocess.CalledProcessError(1,['gh'])):
            with self.assertRaises(subprocess.CalledProcessError): releases.retrieve('o/r','a'*64,'unused')
    def test_valid_download_then_checksum_verification(self):
        key='a'*64;bottle='fzf--0.74.5.sequoia.bottle.tar.gz'
        release={'tag_name':'fzf-bottle-'+key,'draft':False,'assets':[{'name':'validated.json'},{'name':bottle}]}
        with tempfile.TemporaryDirectory() as tmp:
            dest=pathlib.Path(tmp)/'download'
            def download(*args,**kwargs):
                dest.mkdir();(dest/bottle).write_bytes(b'bottle')
                (dest/'validated.json').write_text(json.dumps({'schema':1,'key':key,'status':'validated','checks':['formula-test','x86_64','unlinked','no-nix-linkage','go-unchanged'],'files':{bottle:state.sha(b'bottle')}}))
            with patch.object(releases,'api',side_effect=[{'private':True},[[release]]]),patch.object(releases.subprocess,'run',side_effect=download):
                self.assertTrue(releases.retrieve('o/r',key,dest))
    def test_incomplete_public_and_bad_asset_refused(self):
        key='a'*64
        for private,release in [(False,None),(True,{'tag_name':'fzf-bottle-'+key,'draft':True,'assets':[]}), (True,{'tag_name':'fzf-bottle-'+key,'draft':False,'assets':[{'name':'validated.json'},{'name':'../escape'}]})]:
            with patch.object(releases,'api',side_effect=[{'private':private},[[release]]]),patch.object(releases.subprocess,'run') as download:
                with self.assertRaises(AssertionError):releases.retrieve('o/r',key,'unused')
                download.assert_not_called()

class ResumeTests(unittest.TestCase):
    def test_transition_recovery(self):
        self.assertEqual(update.next_action(False,[],[]),'branch')
        self.assertEqual(update.next_action(True,[],[]),'pr')
        self.assertEqual(update.next_action(True,[{'state':'open'}],[]),'dispatch')
        for status in ['queued','in_progress','success','failure']:
            self.assertEqual(update.next_action(True,[{'state':'open'}],[{'status':status}]),'done')
        self.assertEqual(update.next_action(True,[{'state':'closed'}],[]),'closed')
    def test_resume_does_not_repush_or_recreate_pr(self):
        lock=state.read(state.ROOT/'fzf.lock.json')
        content={'content':base64.b64encode(json.dumps(lock).encode()).decode()}
        for prs,expected in [([],['pr','workflow']),([{'state':'open'}],['workflow']),([{'state':'closed'}],[])]:
            with tempfile.TemporaryDirectory() as tmp:
                candidate=pathlib.Path(tmp)/'candidate';candidate.write_text(json.dumps(lock))
                original=state.read
                def read(path):return {'update_pr_enabled':True,'build_enabled':True} if pathlib.Path(path).name=='policy.json' else original(path)
                responses=[content,prs]+([] if prs==[{'state':'closed'}] else [{'object':{'sha':'b'*40}},{'workflow_runs':[]}])
                with patch.object(sys,'argv',['update',str(candidate)]),patch.dict(os.environ,{'GITHUB_REPOSITORY':'o/r'}),patch.object(state,'read',side_effect=read),patch.object(update.subprocess,'run',return_value=subprocess.CompletedProcess([],0)),patch.object(releases,'api',side_effect=responses),patch.object(update,'command') as command:
                    update.main()
                    self.assertEqual([c.args[1] for c in command.call_args_list],expected)
    def test_disabled_has_no_remote_effect(self):
        with patch.object(state,'read',return_value={'update_pr_enabled':False}),patch.object(sys,'argv',['update','unused']),patch.object(update,'command') as command,patch.object(releases,'api') as api:
            with self.assertRaises(AssertionError):update.main()
            command.assert_not_called();api.assert_not_called()


class BuildPolicyTests(unittest.TestCase):
    def test_update_enabled_build_disabled_never_dispatches(self):
        lock=state.read(state.ROOT/'fzf.lock.json')
        content={'content':base64.b64encode(json.dumps(lock).encode()).decode()}
        with tempfile.TemporaryDirectory() as tmp:
            candidate=pathlib.Path(tmp)/'candidate';candidate.write_text(json.dumps(lock))
            original=state.read
            def read(path):return {'update_pr_enabled':True,'build_enabled':False} if pathlib.Path(path).name=='policy.json' else original(path)
            with patch.object(sys,'argv',['update',str(candidate)]),patch.dict(os.environ,{'GITHUB_REPOSITORY':'o/r'}),patch.object(state,'read',side_effect=read),patch.object(update.subprocess,'run',return_value=subprocess.CompletedProcess([],0)),patch.object(releases,'api',side_effect=[content,[{'state':'open'}],{'object':{'sha':'b'*40}},{'workflow_runs':[]}]),patch.object(update,'command') as command:
                with self.assertRaisesRegex(AssertionError,'build activation disabled'):update.main()
                command.assert_not_called()


class LocalGitResumeTests(unittest.TestCase):
    def test_real_branch_push_then_pr_failure_resumes_without_second_push(self):
        # Real Git writes are confined to a temporary local remote; GitHub calls are mocks.
        lock=state.read(state.ROOT/'fzf.lock.json')
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp);remote=root/'remote.git';repo=root/'repo'
            def git(*args):subprocess.run(['git',*args],check=True,capture_output=True)
            git('init','--bare',str(remote));git('init','-b','main',str(repo))
            git('-C',str(repo),'config','user.name','Test');git('-C',str(repo),'config','user.email','test@example.invalid')
            folder=repo/'ci/homebrew-fzf';folder.mkdir(parents=True)
            (folder/'policy.json').write_text(json.dumps({'update_pr_enabled':True,'build_enabled':True}))
            (folder/'fzf.lock.json').write_text(json.dumps(lock))
            git('-C',str(repo),'add','.');git('-C',str(repo),'-c','commit.gpgsign=false','commit','-m','fixture')
            git('-C',str(repo),'remote','add','origin',str(remote));git('-C',str(repo),'push','origin','main')
            git('-C',str(repo),'config','commit.gpgsign','false')
            proposed=dict(lock,version='0.74.6');candidate=root/'candidate.json';candidate.write_text(json.dumps(proposed))
            content={'content':base64.b64encode(json.dumps(proposed).encode()).decode()}
            commands=[]
            def execute(*args):
                commands.append(args)
                if args[0]=='git':return subprocess.run(args,check=True,capture_output=True)
                if args[:3]==('gh','pr','create'):raise subprocess.CalledProcessError(1,args)
            previous=os.getcwd();os.chdir(repo)
            try:
                with patch.object(state,'ROOT',folder),patch.object(sys,'argv',['update',str(candidate)]),patch.dict(os.environ,{'GITHUB_REPOSITORY':'o/r'}),patch.object(releases,'api',side_effect=[content,[]]),patch.object(update,'command',side_effect=execute):
                    with self.assertRaises(subprocess.CalledProcessError):update.main()
                self.assertEqual(sum(c[:2]==('git','push') for c in commands),1)
                with patch.object(state,'ROOT',folder),patch.object(sys,'argv',['update',str(candidate)]),patch.dict(os.environ,{'GITHUB_REPOSITORY':'o/r'}),patch.object(releases,'api',side_effect=[content,[],{'object':{'sha':'b'*40}},{'workflow_runs':[]}]),patch.object(update,'command') as resumed:
                    update.main()
                    self.assertEqual([c.args[:2] for c in resumed.call_args_list],[('gh','pr'),('gh','workflow')])
            finally:os.chdir(previous)

if __name__=='__main__':unittest.main()
