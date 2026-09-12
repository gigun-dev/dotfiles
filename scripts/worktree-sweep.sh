#!/usr/bin/env bash
# セッション履歴の保持 (cleanupPeriodDays=9999) と切り離して worktree を掃除する。
# 削除対象は、既定ブランチの祖先で、未追跡・ignore を含めた残存変更が無いものだけ。
# squash/cherry-pick 済みの推測はしない。判断できないものは残し、Git の失敗は終了値に返す。
# 使い方: worktree-sweep.sh [--apply] [--all | リポジトリ...]
# 既定は判定のみ。--apply も実行中の非 locked エージェントまでは検出できない。
set -uo pipefail

apply=0
all=0
repos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --all) all=1 ;;
    --) shift; repos+=("$@"); break ;;
    -*) echo "不明な引数: $1" >&2; exit 1 ;;
    *) repos+=("$1") ;;
  esac
  shift
done
if [ "$all" = 1 ] && [ "${#repos[@]}" -gt 0 ]; then
  echo '--all と個別リポジトリは同時指定できません' >&2
  exit 1
fi
scratch=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch"' EXIT
if [ "$all" = 1 ]; then
  ghq list --full-path >"$scratch/repos" || exit 1
  while IFS= read -r repo; do
    [ ! -d "$repo/.git/worktrees" ] || repos+=("$repo")
  done <"$scratch/repos"
else
  [ "${#repos[@]}" -gt 0 ] || repos=("$PWD")
fi

failed=0
inspect() {
  # porcelain の先頭は primary worktree。linked worktree から呼んでも本体を消さない。
  if [ "$first" = 1 ]; then first=0; return; fi
  [ "$path" != "$root" ] || return
  if [ "$locked" = 1 ] || [ "$prunable" = 1 ] || [ -z "$branch" ]; then
    printf '  残す %s (locked / prunable / detached)\n' "$path"
    return
  fi
  if ! dirty=$(git -C "$path" status --porcelain --untracked-files=all --ignored=matching); then
    printf '  残す %s (Git status 失敗)\n' "$path"
    failed=1
    return
  fi
  if [ -n "$dirty" ]; then
    printf '  残す %s (未コミット / 未追跡 / ignore 成果物)\n' "$path"
    return
  fi
  # 一覧取得後の HEAD を検査する。merge-base の 1 は未取込、その他は判定エラー。
  if ! head=$(git -C "$path" rev-parse --verify HEAD); then
    printf '  残す %s (HEAD 判定失敗)\n' "$path"
    failed=1
    return
  fi
  git -C "$root" merge-base --is-ancestor "$head" "$base_oid"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  残す %s (未取込または祖先判定失敗)\n' "$path"
    [ "$rc" -eq 1 ] || failed=1
    return
  fi
  if [ "$apply" = 0 ]; then
    printf '  消せる %s\n' "$path"
    return
  fi
  # force は使わない。lock や追跡ファイルへの並行変更は Git にも拒否させる。
  # ignore ファイル追加との競合は不可分に防げないため、稼働中の作業には --apply しない。
  if ! git -C "$root" worktree remove "$path"; then
    printf '  失敗 %s (worktree 削除失敗)\n' "$path"
    failed=1
    return
  fi
  # -D で強制しない。upstream など Git 側の判定で拒否されたブランチは残す。
  if git -C "$root" branch -d -- "${branch#refs/heads/}"; then
    printf '  削除 %s\n' "$path"
  else
    printf '  worktree のみ削除、ブランチは保持 %s\n' "$branch"
    failed=1
  fi
}

for repo in "${repos[@]}"; do
  if ! root=$(git -C "$repo" rev-parse --show-toplevel); then
    echo "skip $repo (Git 管理外または取得失敗)" >&2
    failed=1
    continue
  fi
  base=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD)
  rc=$?
  if [ "$rc" -eq 1 ]; then
    base=main
  elif [ "$rc" -ne 0 ]; then
    echo "残す $root (既定ブランチ取得失敗)" >&2
    failed=1
    continue
  fi
  if ! base_oid=$(git -C "$root" rev-parse --verify "$base^{commit}"); then
    echo "残す $root (基準 $base の取得失敗)" >&2
    failed=1
    continue
  fi
  printf '=== %s (基準: %s)\n' "$root" "$base"
  if ! git -C "$root" worktree list --porcelain -z >"$scratch/worktrees"; then
    failed=1
    continue
  fi
  first=1
  path= branch= locked=0 prunable=0
  # -z により空白・改行入りパスを引用解除や awk の分割無しで読む。
  while IFS= read -r -d '' field; do
    case "$field" in
      'worktree '*) path=${field#worktree } ;;
      'branch '*) branch=${field#branch } ;;
      locked*) locked=1 ;;
      prunable*) prunable=1 ;;
      '') inspect; path= branch= locked=0 prunable=0 ;;
    esac
  done <"$scratch/worktrees"
done
[ "$apply" = 1 ] || echo '(判定のみ。実際に消すには --apply)'
exit "$failed"
