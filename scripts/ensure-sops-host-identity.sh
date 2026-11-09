set -euo pipefail

identity=${1:?SOPS host identity path is required}
parent=$(dirname "$identity")

if [ -L "$identity" ]; then
  echo "refusing symlink SOPS host identity" >&2
  exit 1
fi

if [ -e "$identity" ]; then
  if [ ! -f "$identity" ]; then
    echo "refusing non-regular SOPS host identity" >&2
    exit 1
  fi
  if [ "$(stat -c %a "$identity")" != 600 ] || [ "$(stat -c %u "$identity")" != "$(id -u)" ]; then
    echo "refusing SOPS host identity with unexpected owner or mode" >&2
    exit 1
  fi
  age-keygen -y "$identity" >/dev/null 2>&1
  exit 0
fi

install -d -m 0700 "$parent"
temporary=$(mktemp "$parent/.sops-host-identity.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT

if ! age-keygen >"$temporary" 2>/dev/null; then
  echo "failed to generate SOPS host identity" >&2
  exit 1
fi
chmod 0600 "$temporary"

if [ -L "$identity" ] || [ -e "$identity" ]; then
  echo "refusing to replace SOPS host identity created concurrently" >&2
  exit 1
fi

mv "$temporary" "$identity"
trap - EXIT
