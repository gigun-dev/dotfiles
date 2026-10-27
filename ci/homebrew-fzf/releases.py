#!/usr/bin/env python3
"""Read-only private Release retrieval; API errors are never cache misses."""
import json
import pathlib
import re
import subprocess
import state


def api(endpoint, paginated=False):
    args=['gh','api',endpoint]
    if paginated: args += ['--paginate','--slurp']
    return json.loads(subprocess.check_output(args,text=True))


def retrieve(repo, key, destination):
    assert re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo)
    assert re.fullmatch('[0-9a-f]{64}',key)
    assert api('repos/'+repo)['private'], 'private destination required'
    pages=api(f'repos/{repo}/releases?per_page=100',paginated=True)
    matches=[r for page in pages for r in page if r['tag_name']=='fzf-bottle-'+key]
    if not matches: return False
    assert len(matches)==1 and not matches[0]['draft'], 'incomplete/ambiguous release'
    release=matches[0]
    names=[a['name'] for a in release['assets']]
    assert len(names)==2 and len(set(names))==2 and 'validated.json' in names
    bottle=next(n for n in names if n!='validated.json')
    assert re.fullmatch(r'fzf--[0-9.]+(?:_\d+)?\.sequoia\.bottle\.tar\.gz',bottle)
    dest=pathlib.Path(destination)
    assert not dest.exists(), 'download destination must be new'
    subprocess.run(['gh','release','download',release['tag_name'],'--repo',repo,
                    '--pattern','validated.json','--pattern',bottle,'--dir',str(dest)],check=True)
    state.verify(dest,key)
    return True
