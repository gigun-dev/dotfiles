#!/usr/bin/env python3
"""Render a frozen Intel Mac's daemon declaration without installing/loading it."""
import argparse
from pathlib import Path
import plistlib
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--python", required=True)
parser.add_argument("--repo", required=True)
parser.add_argument("--source", required=True)
parser.add_argument("--endpoint", required=True)
parser.add_argument("--token-file", required=True)
parser.add_argument("--period-ms", type=int, default=60_000)
parser.add_argument("--anchor-ms", type=int, default=0)
args = parser.parse_args()
for path in (args.python, args.repo, args.token_file):
    if not Path(path).is_absolute():
        parser.error("runtime paths must be absolute")
plist = {
    "Label": "dev.gigun.host-heartbeat",
    "ProgramArguments": [args.python, str(Path(args.repo) / "scripts/host-heartbeat.py"),
                         "--source", args.source, "--endpoint", args.endpoint,
                         "--token-file", args.token_file,
                         "--period-ms", str(args.period_ms), "--anchor-ms", str(args.anchor_ms),
                         "--snapshot", "/var/lib/host-heartbeat/latest.json"],
    "RunAtLoad": True,
    "StartInterval": 30,
    "ProcessType": "Background",
}
plistlib.dump(plist, sys.stdout.buffer)
