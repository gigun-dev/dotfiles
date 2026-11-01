#!/usr/bin/env bash
# Publish verified assets to the approved private repository only.
set -euo pipefail
: "${APPROVED_PRIVATE_REPOSITORY:?Destination approval required}"
: "${VALIDATED_DIRECTORY:?}"
: "${ENVIRONMENT_JSON:?}"
root=$(cd "$(dirname "$0")" && pwd)
python3 - "$root/policy.json" "$APPROVED_PRIVATE_REPOSITORY" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['durable_destination']==sys.argv[2]
PY
key=$(python3 "$root/state.py" verify --directory "$VALIDATED_DIRECTORY" --environment "$ENVIRONMENT_JSON")
tag="fzf-bottle-$key"
# Check repository visibility before any release write. Never overwrite existing assets.
test "$(gh repo view "$APPROVED_PRIVATE_REPOSITORY" --json visibility --jq .visibility)" = PRIVATE
existing=$(python3 - "$root" "$APPROVED_PRIVATE_REPOSITORY" "$key" <<'PYCODE'
import sys,tempfile,pathlib
sys.path.insert(0,sys.argv[1]);import releases
with tempfile.TemporaryDirectory() as tmp:
    print(str(releases.retrieve(sys.argv[2],sys.argv[3],pathlib.Path(tmp)/'release')).lower())
PYCODE
)
if [ "$existing" = true ]; then
  echo 'Existing release downloaded and verified; no overwrite.'; exit 0
fi
gh release create "$tag" "$VALIDATED_DIRECTORY/validated.json" "$VALIDATED_DIRECTORY/"*.bottle.tar.gz \
  --repo "$APPROVED_PRIVATE_REPOSITORY" --target "${APPROVED_COMMIT:?}" \
  --latest=false --title "Intel fzf $key" --notes 'Validated Intel macOS 15 bottle; see validated.json for inputs and checksum.'
