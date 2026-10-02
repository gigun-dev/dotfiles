#!/usr/bin/env python3
"""Collect host boot evidence; send only the existing hub H1b receipt contract.

The snapshot is diagnostic evidence, not incident history. hub owns decisions
and notifications; boot metadata awaits its receiving contract.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def boot_info(system=None, read=None, command=None):
    system = system or platform.system()
    read = read or (lambda path: Path(path).read_text())
    command = command or (lambda args: subprocess.check_output(args, text=True, timeout=5).strip())
    if system == "Linux":
        boot_id = read("/proc/sys/kernel/random/boot_id").strip()
        match = re.search(r"^btime (\d+)$", read("/proc/stat"), re.MULTILINE)
    elif system == "Darwin":
        boot_id = command(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"])
        match = re.search(r"sec = (\d+)", command(["/usr/sbin/sysctl", "-n", "kern.boottime"]))
    else:
        raise ValueError("unsupported platform")
    if not boot_id or not match:
        raise ValueError("boot evidence unavailable")
    return {"bootId": boot_id, "bootedAt": int(match[1]) * 1000}


def receipt(source, boot_id, now_ms, period_ms, anchor_ms):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:@/-]{0,63}", source):
        raise ValueError("invalid source")
    if not 60_000 <= period_ms <= 604_800_000 or not 0 <= anchor_ms <= now_ms:
        raise ValueError("invalid schedule")
    slot = anchor_ms + (now_ms - anchor_ms) // period_ms * period_ms
    # Stable across retries and duplicate launchd/systemd invocations in one slot.
    boot = hashlib.sha256(boot_id.encode()).hexdigest()[:32]
    return {"source": source, "runId": f"{boot}/{slot}", "scheduledFor": slot}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a source credential to a redirect destination.
        return None


def send(endpoint, token_file, payload):
    url = urllib.parse.urlsplit(endpoint)
    if (url.scheme != "https" or url.path != "/heartbeat" or not url.hostname
            or url.username or url.password or url.query or url.fragment):
        raise ValueError("endpoint must be an HTTPS /heartbeat URL")
    path = Path(token_file)
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode) or mode & 0o077:
        raise ValueError("token file must be private (0600 or 0400)")
    token = path.read_text().strip()
    if not token or any(c.isspace() for c in token):
        raise ValueError("invalid token file")
    request = urllib.request.Request(endpoint, json.dumps(payload).encode(),
                                     {"Authorization": "Bearer " + token,
                                      "Content-Type": "application/json"}, method="POST")
    opener = urllib.request.build_opener(NoRedirect)
    for attempt in range(3):
        try:
            with opener.open(request, timeout=10) as response:
                # HTTP success alone must not turn an unrelated HTML 200 into a receipt.
                if response.status != 202:
                    raise ValueError("unexpected heartbeat response")
                body = json.loads(response.read(4096))
                if not isinstance(body, dict) or body.get("status") != "accepted":
                    raise ValueError("heartbeat not accepted")
                return
        except urllib.error.HTTPError as error:
            if error.code < 500 and error.code != 429:
                raise ValueError(f"heartbeat HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError):
            pass
        if attempt < 2:
            time.sleep(attempt + 1)
    raise ValueError("heartbeat unavailable after 3 attempts")


def save_snapshot(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # A partial write must not destroy the previous diagnostic snapshot.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = output.name
        try:
            json.dump(value, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        except BaseException:
            os.unlink(temporary)
            raise
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--period-ms", type=int, default=60_000)
    parser.add_argument("--anchor-ms", type=int, default=0)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--endpoint")
    parser.add_argument("--token-file")
    args = parser.parse_args()
    if bool(args.endpoint) != bool(args.token_file):
        parser.error("endpoint and token-file must be supplied together")
    now_ms = time.time_ns() // 1_000_000
    evidence = boot_info()
    payload = receipt(args.source, evidence["bootId"], now_ms, args.period_ms, args.anchor_ms)
    snapshot = {**evidence, "source": args.source, "observedAt": now_ms,
                "heartbeat": payload, "lastAcceptedAt": None}
    path = Path(args.snapshot)
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get("source") != args.source:
            raise ValueError("snapshot belongs to another source")
        snapshot["lastAcceptedAt"] = previous.get("lastAcceptedAt")
    save_snapshot(path, snapshot)
    if args.endpoint:
        send(args.endpoint, args.token_file, payload)
        snapshot["lastAcceptedAt"] = time.time_ns() // 1_000_000
        save_snapshot(path, snapshot)
    print(json.dumps(snapshot, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        # Exceptions can include credentials or response bodies. Keep service logs generic.
        raise SystemExit("host-heartbeat: collection or delivery failed; inspect configuration and connectivity")
