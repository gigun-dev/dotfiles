#!/bin/sh
# Local validation only: the integration fixture uses connection:local and temporary HOME paths.
set -eu
cd "$(dirname "$0")"
ANSIBLE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/mini-ansible-verify.XXXXXX")
export ANSIBLE_HOME
trap 'rm -rf "$ANSIBLE_HOME"' EXIT HUP INT TERM
uv run --locked ansible-lint --offline apply.yml audit.yml update.yml
for playbook in apply audit update; do
  uv run --locked ansible-playbook -i inventory.yml "$playbook.yml" --syntax-check
done
uv run --locked python -I -B -m unittest discover -s tests -p 'test_*.py'
