#!/bin/sh
# Frozen Intel mini cannot receive nix-darwin. One sudo invocation installs the
# prepared daemon while keeping source credentials out of argv and terminal output.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run this prepared installer with sudo.' >&2; exit 1; }
staging=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
state=/var/lib/host-heartbeat
source_dir=/usr/local/lib/dotfiles-heartbeat/scripts
plist=/Library/LaunchDaemons/dev.gigun.host-heartbeat.plist
label=dev.gigun.host-heartbeat
/usr/bin/plutil -lint "$staging/daemon.plist" >/dev/null
/usr/bin/python3 - "$staging/token" <<'PY'
from pathlib import Path
import stat, sys
p = Path(sys.argv[1])
if not stat.S_ISREG(p.stat().st_mode) or p.stat().st_mode & 0o077 or not p.read_text().strip():
    raise SystemExit('Private staged token required.')
PY
start_ms=$(/usr/bin/python3 -c 'import time; print(time.time_ns() // 1000000)')
/usr/bin/install -d -m 0700 -o root -g wheel "$state"
# Retain the previous managed install for operator recovery; unrelated daemons stay intact.
if [ -e "$plist" ]; then
    backup="$state/install-backup-$(date -u +%Y%m%dT%H%M%SZ)"
    /usr/bin/install -d -m 0700 -o root -g wheel "$backup"
    /usr/bin/install -m 0600 "$plist" "$backup/daemon.plist"
    [ ! -e "$state/token" ] || /usr/bin/install -m 0400 "$state/token" "$backup/token"
    [ ! -e "$source_dir/host-heartbeat.py" ] || /usr/bin/install -m 0600 "$source_dir/host-heartbeat.py" "$backup/host-heartbeat.py"
fi
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "system/$label"
fi
/usr/bin/install -d -m 0755 -o root -g wheel "$source_dir"
/usr/bin/install -m 0644 -o root -g wheel "$staging/host-heartbeat.py" "$source_dir/host-heartbeat.py"
/usr/bin/install -m 0400 -o root -g wheel "$staging/token" "$state/token"
/usr/bin/install -m 0644 -o root -g wheel "$staging/daemon.plist" "$plist"
/bin/launchctl bootstrap system "$plist"
# RunAtLoad is a real launchd invocation. Wait for a new accepted snapshot, without
# treating boot collection, exit zero or HTTP 200 as a successful hub receipt.
attempt=0
while [ "$attempt" -lt 60 ]; do
    if /usr/bin/python3 - "$state/latest.json" "$start_ms" <<'PY'
from pathlib import Path
import json, sys
try:
    value = json.loads(Path(sys.argv[1]).read_text())
    accepted = value.get('lastAcceptedAt')
    valid = value.get('source') == 'mac' and isinstance(accepted, int) and accepted >= int(sys.argv[2])
except (OSError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
    then
        /usr/bin/python3 - "$staging/token" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink()
PY
        echo 'Mac heartbeat system daemon installed; fresh hub receipt accepted; staged token removed.'
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 1
done
echo 'Daemon installed; no fresh accepted receipt yet. Inspect private snapshot and daemon exit status.' >&2
exit 1
