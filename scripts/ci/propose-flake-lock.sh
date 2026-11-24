#!/usr/bin/env bash
set -euo pipefail

# Usage: propose-flake-lock.sh prepare|publish fast
#        propose-flake-lock.sh prepare|publish input <root-input>
# prepare runs without any writer token. TARGET_REV (from flake-lock-candidates.py)
# pins an input to a commit at least MINIMUM_RELEASE_AGE_DAYS old.
phase=${1:-}
kind=${2:-}
name=${3:-}
read -r -a fast_inputs <<<"${FAST_INPUTS:-}"
case "$kind" in
  fast)
    name=fast
    if ((${#fast_inputs[@]} == 0)); then
      echo "FAST_INPUTS is required for the fast lane" >&2
      exit 2
    fi
    ;;
  input)
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ || "$name" == fast ]]; then
      echo "invalid flake input name: $name" >&2
      exit 2
    fi
    for fast_input in "${fast_inputs[@]}"; do
      if [[ "$name" == "$fast_input" ]]; then
        echo "$name is updated by the fast lane" >&2
        exit 2
      fi
    done
    ;;
  *)
    echo "unknown flake update proposal: $kind" >&2
    exit 2
    ;;
esac

branch="bot/flake-lock-$name"
state=${RUNNER_TEMP:-/tmp}/flake-lock-$name
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Reads a root input through root.inputs, because the node key can differ from
# the input name (nixpkgs is nixpkgs_4 today).
lock_field() {
  jq -er --arg name "$name" --arg section "$1" --arg field "$2" \
    '.nodes[.nodes.root.inputs[$name]][$section][$field] // ""' flake.lock
}

prepare_input() {
  local before after modified target owner repo min_age note
  min_age=${MINIMUM_RELEASE_AGE_DAYS:-3}
  before=$(lock_field locked rev)
  target=${TARGET_REV:-}
  if [[ -n "$target" ]]; then
    [[ "$target" =~ ^[0-9a-f]{40}$ ]] || {
      echo "TARGET_REV is not a full commit hash" >&2
      exit 2
    }
    owner=$(lock_field original owner)
    repo=$(lock_field original repo)
    [[ "$owner/$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
      echo "$name has no GitHub owner/repo to pin" >&2
      exit 2
    }
    # --override-input changes only `locked`; `original` stays the flake.nix
    # reference, so a later plain `nix flake update` keeps following it.
    nix flake update "$name" --override-input "$name" "github:$owner/$repo/$target" 2>&1 | tee "$state.log"
    if ! git diff --quiet -- flake.lock && [[ $(lock_field locked rev) != "$target" ]]; then
      echo "$name was locked to $(lock_field locked rev), not $target" >&2
      exit 1
    fi
    note="\`$name\` は ${min_age} 日以上前に commit された \`$target\` に固定しています。"
  else
    # flake-lock-candidates.py could not walk this input's history. Take the
    # latest revision and keep it only when it is already old enough.
    nix flake update "$name" 2>&1 | tee "$state.log"
    modified=$(lock_field locked lastModified)
    if [[ -n "$modified" ]] && (($(date +%s) - modified < min_age * 86400)); then
      git checkout -- flake.lock
      echo "$name: the latest revision is younger than $min_age days"
      return
    fi
    note="\`$name\` の履歴を辿れなかったため、最新 revision の lastModified が ${min_age} 日以上前であることを確認しました。"
  fi
  git diff --quiet -- flake.lock && return
  after=$(lock_field locked rev)
  modified=$(lock_field locked lastModified)
  printf 'chore(deps): %s を更新 (%s → %s, %s)\n' "$name" "${before:0:8}" "${after:0:8}" \
    "$(jq -nr --argjson t "${modified:-0}" '$t | strftime("%Y-%m-%d")')" >"$state.title"
  printf '%s\n' "$note" >"$state.note"
}

if [[ "$phase" == prepare ]]; then
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required during preparation}"
  rm -f "$state".*
  if [[ "$kind" == fast ]]; then
    nix flake update "${fast_inputs[@]}" 2>&1 | tee "$state.log"
    printf 'chore(deps): flake.lock を更新 (fast)\n' >"$state.title"
    : >"$state.note"
  else
    prepare_input
  fi

  if git diff --quiet -- flake.lock; then
    echo "$name: flake.lock is already current"
    printf 'changed=false\n' >>"$GITHUB_OUTPUT"
    exit 0
  fi

  # Git flakes include staged changes. Build this exact tree before a writer
  # token exists; publish verifies that the resulting commit has the same tree.
  git add flake.lock
  git write-tree >"$state.tree"
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
candidate_tree=$(git write-tree)
[[ "$candidate_tree" == "$(cat "$state.tree")" ]]
title=$(cat "$state.title")
git commit -m "$title" -m "$(cat "$state.note")" -m "$(cat "$state.log")"
[[ $(git rev-parse 'HEAD^{tree}') == "$candidate_tree" ]]

# Every run starts from the main it checked out, so the push replaces the
# branch rather than rebasing it (see .github/workflows/flake-lock-proposal.yaml).
"$BASH" "$script_dir/github-app-push-branch.sh" "$branch"

body=$(printf '%s\n%s\n\n```text\n%s\n```\n' \
  'GitHub Actions が mini-vm の NixOS 構成と home-manager 構成をビルドした更新候補です。' \
  "$(cat "$state.note")" "$(cat "$state.log")")

if pr_number=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state open \
  --json number --jq '.[0].number // empty') && [[ -n "$pr_number" ]]; then
  gh pr edit "$pr_number" --repo "$GITHUB_REPOSITORY" --title "$title" --body "$body"
else
  gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" \
    --title "$title" --body "$body"
fi

pr_number=$(gh pr view "$branch" --repo "$GITHUB_REPOSITORY" --json number --jq '.number')
auto_merge=$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" \
  --json autoMergeRequest --jq '.autoMergeRequest // empty')
if [[ -z "$auto_merge" ]]; then
  gh pr merge "$pr_number" --repo "$GITHUB_REPOSITORY" --auto --squash
fi
