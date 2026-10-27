#!/usr/bin/env bash
# Manual bounded pcre2 build + official ripgrep bottle; no update scheduling.
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
mode=${1:-preflight}; work=${2:-}; execute=${3:-}
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTOREMOVE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_MAKE_JOBS=2
if ! [[ $(uname -sm) == 'Darwin x86_64' && $(sw_vers -productVersion) == 15.* && $(brew --prefix) == /usr/local ]]; then
  echo 'requires Intel macOS15 /usr/local' >&2; exit 2
fi
if [[ $mode == preflight ]]; then
  brew list --versions pcre2 ripgrep || true
  exit
fi
if ! [[ $execute == --execute && -n $work ]]; then
  echo 'Explicit --execute and work directory required' >&2; exit 2
fi
# Local consumers must be empty. Only disposable CI may replace preinstalled target packages.
install_target() {
  local name=$1; shift
  if brew list --versions "$name" >/dev/null 2>&1; then
    [[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
      echo "Existing $name must be preserved on a non-disposable host" >&2; exit 1;
    }
    # install supports a target-only upgrade; never use unsupported reinstall flags.
    brew install --skip-link "$@"
  else
    brew install --skip-link "$@"
  fi
}
if [[ $mode == prepare-ci ]]; then
  python3 - "$root" <<'PY'
import json,sys,pathlib
r=pathlib.Path(sys.argv[1]);assert json.loads((r/'lock.json').read_text())['core_revision']==json.loads((r.parent/'homebrew-fzf/fzf.lock.json').read_text())['core_revision']
PY
  bash "$root/../homebrew-fzf/recipe.sh" prepare-ci --execute --disposable-runner
  exit
fi
core=$(brew --repo homebrew/core)
python3 - "$root" "$core" <<'PY'
import json,hashlib,pathlib,subprocess,sys
r,c=map(pathlib.Path,sys.argv[1:]);l=json.loads((r/'lock.json').read_text())
assert subprocess.check_output(['git','-C',str(c),'rev-parse','HEAD'],text=True).strip()==l['core_revision']
for n,h in l['formulae'].items():assert hashlib.sha256((c/'Formula'/n[0]/(n+'.rb')).read_bytes()).hexdigest()==h
PY
mkdir -p "$work"
case $mode in
build)
  [[ ! -e $work/SHA256SUMS ]]
  brew config > "$work/toolchain.txt"
  cp "$root/lock.json" "$work/lock.json"
  install_target pcre2 --build-bottle pcre2
  python3 - <<'PYRECEIPT'
import json,pathlib
r=json.loads(pathlib.Path('/usr/local/Cellar/pcre2/10.49/INSTALL_RECEIPT.json').read_text())
assert r.get('built_as_bottle') and not r.get('poured_from_bottle'), 'runner did not actually build pcre2; do not reuse preinstalled binary'
PYRECEIPT
  brew test pcre2
  (cd "$work"; brew bottle --json pcre2; shasum -a 256 ./*.bottle.tar.gz > SHA256SUMS)
  ;;
verify)
  # Same-version install can be a no-op: never count the runner's old bottle as ours.
  if [[ -d /usr/local/Cellar/pcre2/10.49 ]]; then
    echo 'Preinstalled same-version pcre2 prevents independent bottle verification' >&2; exit 2
  fi
  python3 - "$work" <<'PYVERIFY'
import hashlib,pathlib,re,sys
p=pathlib.Path(sys.argv[1]);lines=(p/'SHA256SUMS').read_text().splitlines();assert len(lines)==1
m=re.fullmatch(r'([0-9a-f]{64})  (?:\./)?(pcre2--10\.49[^/]*\.bottle\.tar\.gz)',lines[0]);assert m
b=p/m[2];assert b.is_file() and not b.is_symlink();assert hashlib.sha256(b.read_bytes()).hexdigest()==m[1]
PYVERIFY
  bottle=$(find "$work" -maxdepth 1 -name 'pcre2--10.49*.bottle.tar.gz')
  [[ -n $bottle && $(printf '%s\n' "$bottle" | wc -l) -eq 1 ]]
  install_target pcre2 "$bottle"
  # force-bottle forbids any Rust build for ripgrep.
  install_target ripgrep --force-bottle ripgrep
  brew test pcre2 ripgrep
  rg=/usr/local/opt/ripgrep/bin/rg
  "$rg" --version
  [[ $("$rg" --version | head -1) == 'ripgrep 15.2.0' ]]
  printf 'alpha42\nbeta\n' > "$work/fixture.txt"
  [[ $("$rg" -o 'alpha[0-9]+' "$work/fixture.txt") == alpha42 ]]
  [[ $("$rg" --pcre2 -o '(?<=alpha)[0-9]+' "$work/fixture.txt") == 42 ]]
  file "$rg" | grep -q x86_64
  ! otool -L "$rg" | grep -q /nix/store
  otool -L "$rg"
  python3 - "$work" <<'PY'
import json,pathlib,sys
for n,v in [('pcre2','10.49'),('ripgrep','15.2.0')]:
 p=pathlib.Path('/usr/local/Cellar')/n/v/'INSTALL_RECEIPT.json';r=json.loads(p.read_text());assert r['poured_from_bottle']
pathlib.Path(sys.argv[1],'verified.txt').write_text('official ripgrep + self-built pcre2: normal and PCRE2 fixtures passed\n')
PY
  ;;
*) echo 'unknown mode' >&2; exit 2 ;;
esac
