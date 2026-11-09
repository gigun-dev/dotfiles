#!/usr/bin/env python3
"""Read/download only: reuse a successful same-repository validated artifact."""
import json
import os
import pathlib
import re
import subprocess
import sys
import state
import releases

def api(endpoint):
    return json.loads(subprocess.check_output(['gh','api',endpoint],text=True))

def main():
    key, destination = sys.argv[1:]
    assert re.fullmatch('[0-9a-f]{64}',key)
    repo=os.environ['GITHUB_REPOSITORY']
    policy=state.read(state.ROOT/'policy.json')
    durable=policy['durable_destination']
    if durable:
        assert durable==repo, 'cross-repository storage is not configured'
        if releases.retrieve(repo,key,destination):
            with open(os.environ['GITHUB_OUTPUT'],'a') as out: out.write('reused=true\n')
            print('Validated private Release reused');return
    name='fzf-validated-'+key
    artifacts=api(f'repos/{repo}/actions/artifacts?name={name}&per_page=100')['artifacts']
    reused=False
    for artifact in artifacts:
        if artifact['expired'] or artifact['name'] != name:
            continue
        run=api(f"repos/{repo}/actions/runs/{artifact['workflow_run']['id']}")
        if run['conclusion'] != 'success' or run['path'] != '.github/workflows/fzf-intel-bottle.yml':
            continue
        if (run['head_repository']['full_name'] != repo or run['head_branch'] != 'main'
                or run['event'] not in ('repository_dispatch', 'workflow_dispatch')):
            continue
        subprocess.run(['gh','run','download',str(run['id']),'--repo',repo,'--name',name,'--dir',destination],check=True)
        state.verify(destination,key)  # A corrupt hit stops; it is never silently rebuilt.
        reused=True
        break
    with open(os.environ['GITHUB_OUTPUT'],'a') as out:
        out.write('reused='+str(reused).lower()+'\n')
    print('Validated artifact reused' if reused else 'No retained validated artifact; build required')

if __name__=='__main__':
    main()
