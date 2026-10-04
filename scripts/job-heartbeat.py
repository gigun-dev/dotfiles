#!/usr/bin/env python3
"""H1b success receipts. Sending is opt-in; no credentials are provisioned here."""
import argparse
import http.client
import json
import os
import re
import ssl
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def deliver(receipt, endpoint, token_file, opener=None, sleep=time.sleep):
    validate_receipt(receipt)
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
    body = json.dumps(receipt, separators=(",", ":")).encode()
    opener = opener or urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    for attempt in range(3):
        request = urllib.request.Request(endpoint, data=body, method="POST", headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/json",
            "User-Agent": "dotfiles-job-heartbeat/1"})
        try:
            with opener.open(request, timeout=10) as response:
                status = response.status
                raw = response.read(4097)
            if status == 202 and len(raw) <= 4096:
                result = json.loads(raw)
                if (isinstance(result, dict) and result.get("status") == "accepted"
                        and isinstance(result.get("result"), dict)
                        and result["result"].get("kind") in ("accepted", "duplicate")):
                    return True
            if status != 429 and not 500 <= status <= 599:
                return False
        except urllib.error.HTTPError as error:
            retry = error.code == 429 or 500 <= error.code <= 599
            error.close()
            if not retry:
                return False
        except (OSError, ValueError, urllib.error.URLError, http.client.HTTPException):
            pass
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
    args = parser.parse_args()
    if args.action == "send" and not args.enabled:
        return 0
    try:
        if args.action == "begin":
            print(json.dumps(begin(args.source), separators=(",", ":")))
            return 0
        if not args.endpoint or not args.token_file:
            raise ValueError("missing configuration")
        if deliver(json.loads(args.receipt), args.endpoint, args.token_file):
            return 0
    except (OSError, ValueError, TypeError, KeyError):
        pass
    # No endpoint, token, response body or exception text may reach the journal.
    print("job-heartbeat: receipt preparation or delivery failed", file=__import__("sys").stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
