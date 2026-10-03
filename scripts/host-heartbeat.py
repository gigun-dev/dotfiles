#!/usr/bin/env python3
"""Report independent host liveness using hub /uptime/heartbeat.

The snapshot is diagnostic evidence, not incident history. hub owns decisions
and notifications; unavailable service/function evidence stays unknown.
"""

import argparse
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


def observation(source, boot, now_ms):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", source):
        raise ValueError("invalid source")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", boot["bootId"]):
        raise ValueError("invalid boot ID")
    if not 0 <= boot["bootedAt"] <= now_ms:
        raise ValueError("invalid boot time")
    # lastSuccessAt is successful local collection, never delivery or app health.
    # Missing explicit tests must not be inferred from liveness or an HTTP 200.
    return {"source": source, "observedAt": now_ms, **boot,
            "lastSuccessAt": now_ms, "tunnel": "unknown", "service": "unknown",
            "functional": "unknown"}


def local_vm_checks(systemctl, tunnel_unit, ready_url, command=None, opener=None):
    """Observe origin readiness; unit active alone cannot prove an edge connection."""
    command = command or (lambda args: subprocess.run(args, text=True, capture_output=True, timeout=3))
    opener = opener or urllib.request.build_opener(NoRedirect)
    unit = "unknown"
    try:
        result = command([systemctl, "is-active", tunnel_unit])
        state = result.stdout.strip()
        if result.returncode == 0 and state == "active":
            unit = "ok"
        elif state in ("inactive", "failed", "deactivating"):
            unit = "failed"
    except (OSError, subprocess.SubprocessError):
        pass

    def probe(url, schema=None):
        evidence = {"status": "unknown", "httpStatus": None}
        try:
            with opener.open(url, timeout=3) as response:
                evidence["httpStatus"] = response.status
                if response.status != 200:
                    evidence["status"] = "failed"
                elif schema is None:
                    evidence["status"] = "ok"
                else:
                    value = json.loads(response.read(4096))
                    if schema == "tunnel":
                        count = value.get("readyConnections")
                        if type(count) is int and count >= 0 and value.get("status") == 200:
                            evidence["readyConnections"] = count
                            evidence["status"] = "ok" if count > 0 else "failed"
                    elif value.get("status") == "OK":
                        evidence["status"] = "ok"
                    else:
                        evidence["status"] = "failed"
        except urllib.error.HTTPError as error:
            evidence.update(status="failed", httpStatus=error.code)
            error.close()
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            evidence["status"] = "failed"
        except (OSError, ValueError, AttributeError):
            # Malformed evidence or collector errors do not mean a successful service.
            pass
        return evidence

    ready = probe(ready_url, "tunnel")
    codex = probe("http://127.0.0.1:18080/healthz")
    langfuse = probe("http://127.0.0.1:3000/api/public/health?failIfDatabaseUnavailable=true", "langfuse")
    tunnel = "unknown"
    if unit == "ok":
        tunnel = ready["status"]
    elif unit == "failed" and ready["status"] != "ok":
        tunnel = "failed"
    states = [codex["status"], langfuse["status"]]
    service = "failed" if "failed" in states else "ok" if states == ["ok", "ok"] else "unknown"
    return {"tunnel": tunnel, "service": service, "functional": "unknown"}, {
        "cloudflaredUnit": unit, "cloudflaredReady": ready,
        "codexHealthz": codex, "langfuseDatabaseHealth": langfuse,
    }


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward a source credential to a redirect destination.
        return None


def send(endpoint, token_file, payload, local_test=False):
    url = urllib.parse.urlsplit(endpoint)
    loopback = local_test and url.scheme == "http" and url.hostname == "127.0.0.1"
    if (not (url.scheme == "https" or loopback) or url.path != "/uptime/heartbeat"
            or not url.hostname or url.username or url.password or url.query or url.fragment):
        raise ValueError("endpoint must be an HTTPS /uptime/heartbeat URL")
    if local_test and not loopback:
        raise ValueError("local test must use literal IPv4 loopback HTTP")
    path = Path(token_file)
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode) or mode & 0o077:
        raise ValueError("token file must be private (0600 or 0400)")
    token = path.read_text().strip()
    if local_test and not token.startswith("local-fixture-"):
        raise ValueError("local test requires a fixture token")
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
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--endpoint")
    parser.add_argument("--token-file")
    parser.add_argument("--local-vm-checks", action="store_true")
    parser.add_argument("--systemctl", default="systemctl")
    parser.add_argument("--tunnel-unit")
    parser.add_argument("--tunnel-ready-url", default="http://127.0.0.1:20241/ready")
    args = parser.parse_args()
    if args.local_vm_checks and (platform.system() != "Linux" or not args.tunnel_unit):
        parser.error("local-vm-checks requires Linux and a tunnel-unit")
    if args.tunnel_ready_url != "http://127.0.0.1:20241/ready":
        parser.error("tunnel readiness must use the declared loopback endpoint")
    if bool(args.endpoint) != bool(args.token_file):
        parser.error("endpoint and token-file must be supplied together")
    evidence = boot_info()
    now_ms = time.time_ns() // 1_000_000
    payload = observation(args.source, evidence, now_ms)
    local_checks = None
    if args.local_vm_checks:
        checks, local_checks = local_vm_checks(args.systemctl, args.tunnel_unit, args.tunnel_ready_url)
        payload.update(checks)
        # The contract has exactly eight fields; detailed local evidence stays private.
        payload["observedAt"] = time.time_ns() // 1_000_000
        payload["lastSuccessAt"] = payload["observedAt"]
    snapshot = {**payload, "lastAcceptedAt": None}
    if local_checks is not None:
        snapshot["localChecks"] = local_checks
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
