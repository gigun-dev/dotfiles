#!/usr/bin/env bash
set -euo pipefail

branch=${1:?branch is required}
: "${GH_TOKEN:?GH_TOKEN must contain a short-lived GitHub App token}"
: "${GIT_ASKPASS:?GIT_ASKPASS must be configured without persisting the token}"

remote_sha=''
if remote_line=$(git ls-remote --exit-code --heads origin "refs/heads/$branch" 2>/dev/null); then
  remote_sha=${remote_line%%[[:space:]]*}
else
  status=$?
  if [[ $status -ne 2 ]]; then
    echo "failed to inspect remote branch: $branch" >&2
    exit "$status"
  fi
fi

if [[ -z "$remote_sha" ]]; then
  git push origin "HEAD:refs/heads/$branch"
  exit 0
fi

push_log=$(mktemp "${RUNNER_TEMP:-/tmp}/github-app-push.XXXXXX")
trap 'rm -f "$push_log"' EXIT
if git push --force-with-lease="refs/heads/$branch:$remote_sha" \
  origin "HEAD:refs/heads/$branch" >"$push_log" 2>&1; then
  cat "$push_log"
  exit 0
fi

# A fixed bot branch can predate workflow changes on main. GitHub rejects moving
# it across those commits because the App intentionally lacks Workflows permission.
# Recreate only for that exact denial; every other push failure stays fail-closed.
if grep -Eqi 'workflow(s)?[^[:cntrl:]]*permission|permission[^[:cntrl:]]*workflow' "$push_log"; then
  cat "$push_log" >&2
  echo "recreating $branch without granting Workflows permission" >&2
  git push origin --delete "$branch"
  git push origin "HEAD:refs/heads/$branch"
  exit 0
fi

cat "$push_log" >&2
exit 1
