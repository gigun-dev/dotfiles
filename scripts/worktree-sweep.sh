#!/usr/bin/env bash
# セッション履歴の保持 (cleanupPeriodDays=9999) と切り離して worktree を掃除する。
# 判定は 3 分類: 消せる / 人が決める / 触るな。行動が変わるのはこの 3 つだけ。
#   消せる     … 未コミット・未追跡・ignore 成果物が無く、既定ブランチの祖先。
#   人が決める … ignore 成果物のみ残っている(内容の可否は機械には分からない)、
#                または既定ブランチの祖先ではない(squash 取り込み済みかもしれないが
#                machine には判断できない)。
#   触るな     … locked / prunable / detached、未コミットの変更、判定エラー。
# force は使わない(lock・並行変更を Git に拒否させるため)。
# 使い方: worktree-sweep.sh [--apply] [--purge-ignored] [--all | リポジトリ...]
# 既定は判定のみ。--apply だけでは ignore 成果物が残る worktree は消さない
# (内容がプロジェクトごとに違うため。ビルド成果物なら捨ててよいが、ローカル DO/D1
# の実体のように戻せないものもある)。ignore 成果物ごと消すには --purge-ignored も要る。
set -uo pipefail

apply=0
all=0
purge_ignored=0
repos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) apply=1 ;;
    --purge-ignored) purge_ignored=1 ;;
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

# KB を人が読める単位に丸める。合計・内訳の表示で使う。
human_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    v = kb + 0; u = "KB"
    if (v >= 1024 * 1024) { v = v / 1024 / 1024; u = "GB" }
    else if (v >= 1024) { v = v / 1024; u = "MB" }
    printf "%.1f%s", v, u
  }'
}

failed=0
total_removable=0
total_removable_kb=0
total_decide=0

inspect() {
  # porcelain の先頭は primary worktree。linked worktree から呼んでも本体を消さない。
  if [ "$first" = 1 ]; then first=0; return; fi
  [ "$path" != "$root" ] || return
  if [ "$locked" = 1 ] || [ "$prunable" = 1 ] || [ -z "$branch" ]; then
    printf '  触るな %s (locked / prunable / detached)\n' "$path"
    return
  fi
  # 未追跡は normal で見る(ディレクトリ単位で十分。all にすると内訳がファイル単位に
  # 潰れて「上位ディレクトリの内訳」が作れなくなる)。ignored=no でここでは ignore 成果物
  # を数えない。ignore 成果物だけが残る状態を、実際の未コミット変更と区別するため。
  if ! real_dirty=$(git -C "$path" status --porcelain --untracked-files=normal --ignored=no); then
    printf '  触るな %s (Git status 失敗)\n' "$path"
    failed=1
    return
  fi
  if [ -n "$real_dirty" ]; then
    printf '  触るな %s (未コミット / 未追跡)\n' "$path"
    return
  fi
  if ! head=$(git -C "$path" rev-parse --verify HEAD); then
    printf '  触るな %s (HEAD 判定失敗)\n' "$path"
    failed=1
    return
  fi
  git -C "$root" merge-base --is-ancestor "$head" "$base_oid"
  rc=$?
  if [ "$rc" -gt 1 ]; then
    printf '  触るな %s (祖先判定に失敗)\n' "$path"
    failed=1
    return
  fi

  # 祖先ではない: squash で取り込まれた可能性がある。祖先判定が使えないだけで、
  # 未取込と断定はしない。git cherry はコミット単位の patch-id 一致を見るだけなので、
  # squash で 1 コミットにまとめられていれば「不一致」になるのが普通。
  # 不一致は「未取込の証拠」にはならないため、一致件数は参考情報として出すだけで
  # 判定には使わない。
  if [ "$rc" -eq 1 ]; then
    cherry=$(git -C "$root" cherry "$base_oid" "$head" 2>/dev/null)
    unique=$(printf '%s\n' "$cherry" | grep -c '^' 2>/dev/null || true)
    [ -n "$cherry" ] || unique=0
    equiv=$(printf '%s\n' "$cherry" | grep -c '^-' 2>/dev/null || true)
    printf '  人が決める %s (祖先ではない。squash 取り込み済みかもしれないが機械には判断できない。git cherry 等価一致 %s/%s件、不一致は未取込の証拠にしない)\n' \
      "$path" "$equiv" "$unique"
    total_decide=$((total_decide + 1))
    return
  fi

  # ここに来るのは既定ブランチの祖先(取込済み)で、実変更・未追跡は無い。
  # 残り得るのは ignore 成果物だけ。内容の可否(再生成できるビルド物か、
  # ローカル DO/D1 の実体のように戻せないものか)はリポジトリ次第で機械には
  # 判断できないため、内訳を見せて人に決めさせる。
  ignored=$(git -C "$path" status --porcelain --untracked-files=normal --ignored=matching)
  if [ -n "$ignored" ]; then
    entries=()
    while IFS= read -r line; do
      case "$line" in
        '!! '*) ;;
        *) continue ;;
      esac
      entry=${line#'!! '}
      sz=$(du -sk "$path/$entry" 2>/dev/null | awk '{print $1}')
      [ -n "$sz" ] || sz=0
      entries+=("$sz	$entry")
    done <<EOF
$ignored
EOF
    total_kb=0
    for e in "${entries[@]}"; do
      total_kb=$((total_kb + ${e%%$'\t'*}))
    done
    breakdown=$(printf '%s\n' "${entries[@]}" | sort -rn | head -10 | \
      awk -F'\t' '{printf "%s(%dKB) ", $2, $1}')
    if [ "$purge_ignored" = 1 ]; then
      total_removable=$((total_removable + 1))
      total_removable_kb=$((total_removable_kb + total_kb))
      if [ "$apply" = 0 ]; then
        printf '  消せる %s (取込済み。ignore 成果物 %s を --purge-ignored で含めて削除: %s)\n' \
          "$path" "$(human_kb "$total_kb")" "$breakdown"
        return
      fi
    else
      total_decide=$((total_decide + 1))
      printf '  人が決める %s (取込済みだが ignore 成果物のみ残存 %s。内訳: %s。--purge-ignored で削除対象にできる)\n' \
        "$path" "$(human_kb "$total_kb")" "$breakdown"
      # ignore 成果物が残る限り、--purge-ignored が無ければ --apply でも消さない。
      return
    fi
  else
    dir_kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
    [ -n "$dir_kb" ] || dir_kb=0
    total_removable=$((total_removable + 1))
    total_removable_kb=$((total_removable_kb + dir_kb))
    if [ "$apply" = 0 ]; then
      printf '  消せる %s (%s)\n' "$path" "$(human_kb "$dir_kb")"
      return
    fi
  fi

  if [ "$apply" = 0 ]; then
    return
  fi
  # force は使わない。lock や追跡ファイルへの並行変更は Git にも拒否させる。
  # 稼働中の作業には --apply しない(判定後の ignore ファイル生成と不可分に競合する)。
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
    echo "触るな $root (既定ブランチ取得失敗)" >&2
    failed=1
    continue
  fi
  # 基準はローカルの既定ブランチにする。統合はローカルで起きる(squash マージ含む)ため、
  # origin/HEAD がローカルより遅れていると取込済みの worktree まで未取込と誤判定する。
  # ローカルに同名ブランチが無ければ従来どおり origin/HEAD へ落ちる。
  case "$base" in
    origin/*) local_branch=${base#origin/} ;;
    *) local_branch=$base ;;
  esac
  if git -C "$root" show-ref --verify --quiet "refs/heads/$local_branch"; then
    base_ref="refs/heads/$local_branch"
    base_display="$local_branch (ローカル)"
  else
    base_ref="$base"
    base_display="$base"
  fi
  if ! base_oid=$(git -C "$root" rev-parse --verify "${base_ref}^{commit}"); then
    echo "触るな $root (基準 $base_display の取得失敗)" >&2
    failed=1
    continue
  fi
  printf '=== %s (基準: %s)\n' "$root" "$base_display"
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

printf '=== 合計: 消せる %d件 (回収見込み %s) / 人が決める %d件\n' \
  "$total_removable" "$(human_kb "$total_removable_kb")" "$total_decide"
[ "$apply" = 1 ] || echo '(判定のみ。実際に消すには --apply。ignore 成果物ごと消すには --purge-ignored も付ける)'
exit "$failed"
