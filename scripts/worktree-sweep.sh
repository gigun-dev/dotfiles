#!/usr/bin/env bash
# サブエージェントが残した worktree を掃除する。
#
# なぜ手動か: Claude Code は cleanupPeriodDays より古い worktree を自動で消すが、
# この設定はトランスクリプトの保持期間と共用で 9999 にしてある(cclens が読むため)。
# 自動掃除を効かせると履歴が消えるので、掃除だけこちらへ分離した。
# 放置すると溜まる —— esp32-airdrop-poc で 106 本 / 4.8GB まで育った実績がある。
#
# 消す条件は 2 つとも満たすもの:
#   - 内容が既定ブランチへ取り込み済み (squash merge を見るため merge-base ではなく cherry)
#   - 未コミット変更も未追跡ファイルも無い
# 判定は削除の直前にやり直す。別セッションが同時に動いている前提。
#
# 使い方: worktree-sweep.sh [リポジトリ...]        判定だけ表示 (既定は $PWD)
#         worktree-sweep.sh --all                  ghq 配下で worktree を持つ全リポジトリ
#         worktree-sweep.sh --apply [...]          実際に削除
set -uo pipefail

apply=0
all=0
for a in "$@"; do
  case "$a" in
    --apply) apply=1; shift ;;
    --all) all=1; shift ;;
  esac
done

if [ "$all" = 1 ]; then
  # worktree を 1 本でも持つリポジトリだけを対象にする。ghq list は数百件あるので、
  # .git/worktrees の有無で先に絞る (worktree が無ければ掃除するものも無い)
  mapfile -t repos < <(ghq list --full-path | while read -r r; do
    [ -d "$r/.git/worktrees" ] && echo "$r"
  done)
  [ "${#repos[@]}" = 0 ] && { echo "worktree を持つリポジトリなし"; exit 0; }
else
  repos=("${@:-$PWD}")
fi

for repo in "${repos[@]}"; do
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "skip $repo (git 管理外)"; continue; }
  root=$(git -C "$repo" rev-parse --show-toplevel)
  # 既定ブランチ。origin/HEAD が無いリポジトリでは main へ落とす
  base=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || base=main
  echo "=== $root (基準: $base)"

  git -C "$root" worktree list --porcelain \
    | awk '/^worktree /{p=$2} /^branch /{print p"\t"$2}' \
    | while IFS=$'\t' read -r path branch; do
        [ "$path" = "$root" ] && continue
        short=${branch#refs/heads/}

        dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        # cherry は patch-id で比較するので、squash merge されたコミットも '-' になる。
        # '+' が 1 つでもあれば取り込まれていない変更が残っている
        pending=$(git -C "$root" cherry "$base" "$branch" 2>/dev/null | grep -c '^+')

        if [ "$dirty" != 0 ] || [ "$pending" != 0 ]; then
          printf '  残す %-40s 未コミット %s / 未取込 %s\n' "$short" "$dirty" "$pending"
          continue
        fi
        if [ "$apply" = 0 ]; then
          printf '  消せる %-38s %s\n' "$short" "$path"
          continue
        fi
        # 実行中エージェントの worktree は lock されていて、ここで弾かれる
        if git -C "$root" worktree remove "$path" 2>/dev/null; then
          git -C "$root" branch -D "$short" >/dev/null 2>&1
          echo "  削除 $short"
        else
          echo "  失敗 $short (lock 中か、外部から書き換えられている)"
        fi
      done
done

[ "$apply" = 0 ] && echo "(判定のみ。実際に消すには --apply)"
exit 0
