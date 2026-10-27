#!/usr/bin/env python3
"""Policy-gated update PR resumption. Never approve, merge, publish or apply."""
import argparse
import base64
import json
import os
import pathlib
import subprocess
import state
import releases


def next_action(branch_exists, prs, runs):
    if not branch_exists: return 'branch'
    if not prs: return 'pr'
    assert len(prs)==1, 'multiple update PRs need review'
    if prs[0]['state']!='open': return 'closed'
    # Failed builds are not automatically retried every day; inspect/manual rerun.
    if runs: return 'done'
    return 'dispatch'


def command(*args):
    return subprocess.run(args,check=True)


def main():
    p=argparse.ArgumentParser();p.add_argument('candidate');a=p.parse_args()
    policy=state.read(state.ROOT/'policy.json')
    assert policy['update_pr_enabled'], 'update activation disabled'
    candidate=state.validate(state.read(a.candidate))
    key=state.sha(state.encoded(state.inputs(candidate)))
    branch='update/fzf-'+key
    repo=os.environ['GITHUB_REPOSITORY']
    refs=subprocess.run(['git','ls-remote','--exit-code','--heads','origin',branch],capture_output=True,text=True)
    assert refs.returncode in (0,2), 'remote lookup failed; do not treat access failure as missing branch'
    exists=refs.returncode==0
    if not exists:
        command('git','switch','-c',branch)
        (state.ROOT/'fzf.lock.json').write_text(json.dumps(candidate,indent=2)+'\n')
        command('git','config','user.name','github-actions[bot]')
        command('git','config','user.email','41898282+github-actions[bot]@users.noreply.github.com')
        command('git','add','ci/homebrew-fzf/fzf.lock.json')
        command('git','commit','-m','build: propose fzf formula update')
        command('git','push','origin',branch)
    # Both newly pushed and resumed branches must contain the expected inputs.
    content=releases.api(f'repos/{repo}/contents/ci/homebrew-fzf/fzf.lock.json?ref={branch}')
    remote=state.validate(json.loads(base64.b64decode(content['content'])))
    assert state.inputs(remote)==state.inputs(candidate), 'existing branch inputs changed; review required'
    prs=releases.api(f"repos/{repo}/pulls?state=all&head={repo.split('/')[0]}:{branch}&per_page=100")
    action=next_action(True,prs,[])
    if action=='closed': print('Existing update PR closed; no automatic reopen/build');return
    if action=='pr':
        command('gh','pr','create','--repo',repo,'--draft','--head',branch,'--base','main',
                '--title','build: update Intel fzf inputs','--body',
                'Changed fzf/Go inputs. Bounded build is dispatched explicitly. No automatic approval, merge or host adoption.')
    revision=releases.api(f'repos/{repo}/git/ref/heads/{branch}')['object']['sha']
    runs=releases.api(f'repos/{repo}/actions/workflows/fzf-intel-bottle.yml/runs?branch={branch}&event=workflow_dispatch&per_page=100')['workflow_runs']
    runs=[r for r in runs if r['head_sha']==revision]
    if next_action(True,[{'state':'open'}],runs)=='dispatch':
        assert policy['build_enabled'], 'build activation disabled; no skipped-only run will be dispatched'
        command('gh','workflow','run','fzf-intel-bottle.yml','--repo',repo,'--ref',branch)
    else: print('Existing run for this revision; no duplicate dispatch')

if __name__=='__main__':main()
