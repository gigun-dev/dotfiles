#!/usr/bin/env bash
set -euo pipefail

phase=${1:-}
compose=infra/langfuse/compose.yaml
branch=bot/langfuse-v4
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ "$phase" == publish ]]; then
  : "${GH_TOKEN:?GH_TOKEN must contain a short-lived GitHub App token}"
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  : "${GIT_ASKPASS:?GIT_ASKPASS must be configured without persisting the token}"
  [[ $(git diff --cached --name-only) == "$compose" ]]
  git diff --quiet -- "$compose"
  [[ $(git write-tree) == "$(cat "${RUNNER_TEMP:-/tmp}/langfuse-update.tree")" ]]
  candidate_tree=$(git write-tree)
  version=$(sed -nE 's#.*docker.langfuse.com/langfuse/langfuse:([^@]+)@.*#\1#p' "$compose")
  [[ -n "$version" ]]
  git commit -m "chore(langfuse): v$versionへ更新"
  [[ $(git rev-parse 'HEAD^{tree}') == "$candidate_tree" ]]

  "$script_dir/github-app-push-branch.sh" "$branch"

  body=$(cat <<EOF
Langfuse Web / Workerをv$versionへ揃え、manifest digestを固定しました。

- releaseから7日以上経過
- production secretを使わないCompose構文検証済み
- mini-vmのNixOS構成をビルド済み

major更新はこのレーンの対象外です。
EOF
  )
  if pr_number=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state open \
    --json number --jq '.[0].number // empty') && [[ -n "$pr_number" ]]; then
    gh pr edit "$pr_number" --repo "$GITHUB_REPOSITORY" \
      --title "chore(langfuse): v$versionへ更新" --body "$body"
  else
    gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" \
      --title "chore(langfuse): v$versionへ更新" --body "$body"
  fi

  pr_number=$(gh pr view "$branch" --repo "$GITHUB_REPOSITORY" --json number --jq '.number')
  auto_merge=$(gh pr view "$pr_number" --repo "$GITHUB_REPOSITORY" \
    --json autoMergeRequest --jq '.autoMergeRequest // empty')
  if [[ -z "$auto_merge" ]]; then
    gh pr merge "$pr_number" --repo "$GITHUB_REPOSITORY" --auto --squash
  fi
  exit 0
fi

if [[ "$phase" != prepare ]]; then
  echo "unknown phase: $phase" >&2
  exit 2
fi
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required during preparation}"

cutoff=$(( $(date +%s) - 7 * 24 * 60 * 60 ))
release=$(curl -fsSL 'https://api.github.com/repos/langfuse/langfuse/releases?per_page=100' \
  | jq -r --argjson cutoff "$cutoff" \
    '[.[] | select(.draft == false and .prerelease == false)
      | select(.tag_name | test("^v4\\.[0-9]+\\.[0-9]+$"))
      | select((.published_at | fromdateiso8601) <= $cutoff)][0].tag_name // empty')
if [[ -z "$release" ]]; then
  echo '7日経過したLangfuse v4 releaseはありません'
  printf 'changed=false\n' >>"$GITHUB_OUTPUT"
  exit 0
fi
version=${release#v}

current=$(sed -nE 's#.*docker.langfuse.com/langfuse/langfuse:([^@]+)@.*#\1#p' "$compose")
if [[ -z "$current" ]]; then
  echo 'composeから現在のLangfuse版を読めません' >&2
  exit 1
fi
newest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n 1)
if [[ "$current" == "$version" || "$newest" != "$version" ]]; then
  echo "Langfuse $current より新しく、7日経過したv4 releaseはありません"
  printf 'changed=false\n' >>"$GITHUB_OUTPUT"
  exit 0
fi

web_digest=$(skopeo inspect --format '{{.Digest}}' \
  "docker://docker.langfuse.com/langfuse/langfuse:$version")
worker_digest=$(skopeo inspect --format '{{.Digest}}' \
  "docker://docker.langfuse.com/langfuse/langfuse-worker:$version")
[[ "$web_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$worker_digest" =~ ^sha256:[0-9a-f]{64}$ ]]

updated_compose=$(mktemp "${RUNNER_TEMP:-/tmp}/langfuse-compose.XXXXXX")
trap 'rm -f "$updated_compose"' EXIT
sed -E \
  -e "s#(docker.langfuse.com/langfuse/langfuse-worker:)[^@]+@sha256:[a-f0-9]+#\\1$version@$worker_digest#" \
  -e "s#(docker.langfuse.com/langfuse/langfuse:)[^@]+@sha256:[a-f0-9]+#\\1$version@$web_digest#" \
  "$compose" >"$updated_compose"
mv "$updated_compose" "$compose"

[[ $(grep -Ec "docker.langfuse.com/langfuse/langfuse:$version@$web_digest$" "$compose") -eq 1 ]]
[[ $(grep -Ec "docker.langfuse.com/langfuse/langfuse-worker:$version@$worker_digest$" "$compose") -eq 1 ]]
docker-compose -f "$compose" config --no-interpolate --quiet

git add "$compose"
git write-tree >"${RUNNER_TEMP:-/tmp}/langfuse-update.tree"
nix build --no-link '.#nixosConfigurations.mini-vm.config.system.build.toplevel'
printf 'changed=true\n' >>"$GITHUB_OUTPUT"
