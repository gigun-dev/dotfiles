#!/usr/bin/env bash
set -euo pipefail

phase=${1:-}
lane=${2:-}
case "$lane" in
  fast) targets=(llm-agents claude-code-overlay cclens) ;;
  slow) targets=() ;;
  *)
    echo "unknown flake update lane: $lane" >&2
    exit 2
    ;;
esac

branch="bot/flake-lock-$lane"
log=${RUNNER_TEMP:-/tmp}/flake-lock-$lane.log
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ "$phase" == prepare ]]; then
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required during preparation}"
  if ((${#targets[@]})); then
    nix flake update "${targets[@]}" 2>&1 | tee "$log"
  else
    nix flake update 2>&1 | tee "$log"
  fi

  if git diff --quiet -- flake.lock; then
    echo "$lane: flake.lock is already current"
    printf 'changed=false\n' >>"$GITHUB_OUTPUT"
    exit 0
  fi

  # Git flakes include staged changes. Build this exact tree before a writer
  # token exists; publish verifies that the resulting commit has the same tree.
  git add flake.lock
  git write-tree >"${RUNNER_TEMP:-/tmp}/flake-lock-$lane.tree"
  nix build --no-link '.#nixosConfigurations.mini-vm.config.system.build.toplevel'
  nix build --no-link '.#homeConfigurations.gigun-mini-vm.activationPackage'
  printf 'changed=true\n' >>"$GITHUB_OUTPUT"
  exit 0
fi

if [[ "$phase" != publish ]]; then
  echo "unknown phase: $phase" >&2
  exit 2
fi

: "${GH_TOKEN:?GH_TOKEN must contain a short-lived GitHub App token}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GIT_ASKPASS:?GIT_ASKPASS must be configured without persisting the token}"

[[ $(git diff --cached --name-only) == flake.lock ]]
git diff --quiet -- flake.lock
[[ $(git write-tree) == "$(cat "${RUNNER_TEMP:-/tmp}/flake-lock-$lane.tree")" ]]
candidate_tree=$(git write-tree)
git commit -m "chore(deps): flake.lock を更新 ($lane)" -m "$(cat "$log")"
[[ $(git rev-parse 'HEAD^{tree}') == "$candidate_tree" ]]

"$script_dir/github-app-push-branch.sh" "$branch"

body=$(printf '%s\n\n```text\n%s\n```\n' \
  'GitHub Actions が mini-vm の NixOS 構成と home-manager 構成をビルドした更新候補です。' \
  "$(cat "$log")")

if pr_number=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state open \
  --json number --jq '.[0].number // empty') && [[ -n "$pr_number" ]]; then
  gh pr edit "$pr_number" --repo "$GITHUB_REPOSITORY" \
    --title "chore(deps): flake.lock を更新 ($lane)" --body "$body"
else
  gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" \
    --title "chore(deps): flake.lock を更新 ($lane)" --body "$body"
fi

pr_number=$(gh pr view "$branch" --repo "$GITHUB_REPOSITORY" --json number --jq '.number')
auto_merge=$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" \
  --json autoMergeRequest --jq '.autoMergeRequest // empty')
if [[ -z "$auto_merge" ]]; then
  gh pr merge "$pr_number" --repo "$GITHUB_REPOSITORY" --auto --squash
fi
