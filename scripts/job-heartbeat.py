#!/usr/bin/env python3
"""H1b success receipts. Sending is opt-in; no credentials are provisioned here."""
import argparse
import json
import os
import re
import stat
import subprocess
import time
import urllib.parse
import uuid

# UTC grids shared with hub/src/heartbeat/config.ts. Activation must first verify
# the timer timezone and initialize all three server-side monitor definitions.
SCHEDULES = {
    "mini-vm-autoswitch": (14_400_000, 86_400_000),
    "mini-vm-lock-fast": (3_600_000, 86_400_000),
    "mini-vm-lock-slow": (266_400_000, 604_800_000),
}
RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}\Z")


def begin(source, now_ms=None, run_id=None):
    anchor, period = SCHEDULES[source]
    now_ms = time.time_ns() // 1_000_000 if now_ms is None else now_ms
    if type(now_ms) is not int or now_ms < anchor:
        raise ValueError("invalid start")
    receipt = {"source": source, "runId": run_id or uuid.uuid4().hex,
               "scheduledFor": anchor + (now_ms - anchor) // period * period}
    validate_receipt(receipt)
    return receipt


def validate_receipt(receipt):
    if not isinstance(receipt, dict) or set(receipt) != {"source", "runId", "scheduledFor"}:
        raise ValueError("invalid receipt")
    source, run_id, slot = receipt["source"], receipt["runId"], receipt["scheduledFor"]
    if not isinstance(source, str) or source not in SCHEDULES:
        raise ValueError("invalid source")
    anchor, period = SCHEDULES[source]
    if (not isinstance(run_id, str) or not RUN_ID.fullmatch(run_id)
            or type(slot) is not int or slot < 0 or slot > 9_007_199_254_740_991
            or (slot - anchor) % period):
        raise ValueError("invalid receipt")


def curl_quote(value):
    if not isinstance(value, str) or any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("invalid curl configuration")
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def deliver(receipt, endpoint, token_file, runner=None, sleep=time.sleep, curl="curl"):
    validate_receipt(receipt)
    curl_quote(endpoint)  # urlsplit can strip controls; reject them before any I/O.
    url = urllib.parse.urlsplit(endpoint)
    if (url.scheme != "https" or not url.hostname or url.username is not None
            or url.password is not None or url.path != "/heartbeat" or url.query or url.fragment):
        raise ValueError("invalid endpoint")
    # Reject symlinks and public files before reading; never include their contents
    # or provider exceptions in logs. The sender runs as the job's existing user.
    fd = os.open(token_file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "r", encoding="ascii") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid not in (0, os.getuid()):
            raise ValueError("invalid token file")
        raw_token = stream.read(259)
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}(?:\r?\n)?", raw_token):
        raise ValueError("invalid token")
    token = raw_token.rstrip("\r\n")
    body = json.dumps(receipt, separators=(",", ":")).encode("ascii")
    config = ("\n".join([
        "url = " + curl_quote(endpoint),
        "header = " + curl_quote("Authorization: Bearer " + token),
        'header = "Content-Type: application/json"',
        "data-binary = " + curl_quote(body.decode("ascii")),
    ]) + "\n").encode()
    runner = subprocess.run if runner is None else runner
    try:
        version = runner([curl, "--disable", "--version"], capture_output=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    match = re.match(rb"curl ([0-9]+)\.([0-9]+)\.([0-9]+)\b", version.stdout)
    # Older curl does not bound an unknown-length response while downloading it.
    if version.returncode or not match or tuple(map(int, match.groups())) < (8, 4, 0):
        return False
    # Use the same standard curl transport as the hub CI caller, without a UA
    # disguise or fallback after a rejection. curlrc/proxy/redirects stay disabled.
    argv = [curl, "--disable", "--silent", "--show-error", "--globoff", "--proto", "=https",
            "--noproxy", "*", "--connect-timeout", "10", "--max-time", "10",
            "--max-filesize", "4096", "--write-out", "\n%{http_code}", "--config", "-"]
    transient_codes = {5, 6, 7, 18, 28, 52, 55, 56, 92}
    for attempt in range(3):
        try:
            # Credentials and payload only use stdin; never shell, argv, logs or
            # temporary files. The process timeout also bounds a stalled child.
            result = runner(argv, input=config, capture_output=True, timeout=15, check=False)
        except subprocess.TimeoutExpired:
            result = None
        except (OSError, subprocess.SubprocessError):
            return False
        if result is not None:
            if result.returncode and result.returncode not in transient_codes:
                return False
            if result.returncode == 0:
                raw, separator, status_bytes = result.stdout.rpartition(b"\n")
                if not separator or not re.fullmatch(rb"[0-9]{3}", status_bytes) or len(raw) > 4096:
                    return False
                status = int(status_bytes)
                if status == 202:
                    try:
                        value = json.loads(raw)
                    except (ValueError, RecursionError):
                        return False
                    return (isinstance(value, dict) and value.get("status") == "accepted"
                            and isinstance(value.get("result"), dict)
                            and value["result"].get("kind") in ("accepted", "duplicate"))
                if status != 429 and not 500 <= status <= 599:
                    return False
        if attempt < 2:
            sleep(attempt + 1)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("begin", "send"))
    parser.add_argument("--source", choices=SCHEDULES)
    parser.add_argument("--receipt")
    parser.add_argument("--enabled", action="store_true")
    parser.add_argument("--endpoint")
    parser.add_argument("--token-file")
    parser.add_argument("--curl-path", default="curl")
    args = parser.parse_args()
    if args.action == "send" and not args.enabled:
        return 0
    try:
        if args.action == "begin":
            print(json.dumps(begin(args.source), separators=(",", ":")))
            return 0
        if not args.endpoint or not args.token_file:
            raise ValueError("missing configuration")
        if deliver(json.loads(args.receipt), args.endpoint, args.token_file, curl=args.curl_path):
            return 0
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        pass
    # No endpoint, token, response body or exception text may reach the journal.
    print("job-heartbeat: receipt preparation or delivery failed", file=__import__("sys").stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
