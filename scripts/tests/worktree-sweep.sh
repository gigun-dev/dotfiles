#!/usr/bin/env bash
# 使い捨て repo だけを削除する。実 checkout / ユーザー設定には書き込まない。
set -euo pipefail
sweep=$(cd "$(dirname "$0")/.." && pwd)/worktree-sweep.sh
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
repo="$scratch/main repo"
git init -q -b main "$repo"
printf '*.secret\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm initial
for name in clean ignored locked pending dirty untracked; do
  git -C "$repo" worktree add -q -b "$name" "$scratch/$name tree"
done
printf secret >"$scratch/ignored tree/cert.secret"
git -C "$repo" worktree lock "$scratch/locked tree"
printf pending >"$scratch/pending tree/change"
git -C "$scratch/pending tree" add change
git -C "$scratch/pending tree" commit -qm pending
printf dirty >>"$scratch/dirty tree/.gitignore"
printf untracked >"$scratch/untracked tree/new"

"$BASH" "$sweep" "$repo" >"$scratch/dry"
[ -d "$scratch/clean tree" ]
rg -F "消せる $scratch/clean tree" "$scratch/dry" >/dev/null
for name in ignored locked pending dirty untracked; do
  rg -F "残す $scratch/$name tree" "$scratch/dry" >/dev/null
done
# オプションは末尾でも解釈する。実削除は fixture の clean だけ。
"$BASH" "$sweep" "$repo" --apply >"$scratch/apply"
[ ! -e "$scratch/clean tree" ]
for name in ignored locked pending dirty untracked; do [ -d "$scratch/$name tree" ]; done
[ -d "$repo/.git" ]
# linked worktree からの判定でも primary checkout は対象外。
"$BASH" "$sweep" "$scratch/ignored tree" >"$scratch/linked"
! rg -F "消せる $repo" "$scratch/linked"

# 基準 ref が存在しない場合は判定不能として終了値 1、削除しない。
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/missing
if "$BASH" "$sweep" --apply "$repo" >"$scratch/error" 2>&1; then
  echo 'FAIL: invalid base accepted' >&2; exit 1
fi
[ -d "$scratch/pending tree" ]
git -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD

# status の失敗を空出力 (= clean) と取り違えないことを fault injection で検証。
git -C "$repo" worktree add -q -b status-error "$scratch/status-error tree"
real_git=$(command -v git)
mkdir "$scratch/bin"
cat >"$scratch/bin/git" <<'WRAPPER'
#!/usr/bin/env bash
if [ "${1-}" = -C ] && [ "${3-}" = status ]; then exit 128; fi
exec "$SWEEP_REAL_GIT" "$@"
WRAPPER
chmod +x "$scratch/bin/git"
if PATH="$scratch/bin:$PATH" SWEEP_REAL_GIT="$real_git" "$BASH" "$sweep" --apply "$repo" >"$scratch/status-error" 2>&1; then
  echo 'FAIL: status error accepted' >&2; exit 1
fi
[ -d "$scratch/status-error tree" ]
rg -F 'Git status 失敗' "$scratch/status-error" >/dev/null
printf 'PASS: dry-run, apply, spaces, linked checkout, ignored, locked, pending, dirty, untracked, invalid ref, Git status failure\n'
