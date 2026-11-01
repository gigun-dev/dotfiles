#!/bin/sh
# Local validation only: the integration fixture uses connection:local and temporary HOME paths.
set -eu
case "${1:-full}" in
  full|portable|native) mode=${1:-full} ;;
  *) echo "Usage: $0 [full|portable|native]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [full|portable|native]" >&2
  exit 2
fi
cd "$(dirname "$0")"
ANSIBLE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/mini-ansible-verify.XXXXXX")
export ANSIBLE_HOME
trap 'rm -rf "$ANSIBLE_HOME"' EXIT HUP INT TERM
if [ "$mode" != native ]; then
  uv run --locked ansible-lint --offline apply.yml audit.yml update.yml
  for playbook in apply audit update; do
    uv run --locked ansible-playbook -i inventory.yml "$playbook.yml" --syntax-check
  done
fi
if [ "$mode" != portable ]; then
  if [ "$(uname -s)" != Darwin ] || [ ! -x /usr/bin/plutil ]; then
    echo 'Native fixtures require macOS and /usr/bin/plutil; no native checks were skipped.' >&2
    exit 1
  fi
fi
case "$mode" in
  full) uv run --locked python -I -B tests/run_groups.py full ;;
  portable) uv run --locked python -I -B tests/run_groups.py portable ;;
  native) uv run --locked python -I -B tests/run_groups.py native ;;
esac
