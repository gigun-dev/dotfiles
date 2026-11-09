#!/usr/bin/env python3
"""Measure non-secret harness boundaries without testing credentials."""

import argparse
import ctypes
import datetime
import http.client
import json
import os
from pathlib import Path
import platform
import socket
import ssl
import subprocess
import sys
import tempfile


FIXTURE = b"agent-harness-canary-v1\n"
NETWORK_HOST = "example.com"


class DiagnosticParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "invalid harness probe arguments\n")


def classify_os_error(error):
    if isinstance(error, PermissionError):
        return "permission-denied"
    if isinstance(error, TimeoutError):
        return "timed-out"
    return "io-failed"


def probe_source_read():
    try:
        with Path(__file__).open("rb") as source:
            source.read(1)
    except OSError as error:
        return classify_os_error(error)
    return "succeeded"


def probe_write(directory):
    path = None
    result = "failed"
    try:
        with tempfile.NamedTemporaryFile(
            prefix=".agent-harness-canary-",
            dir=directory,
            delete=False,
        ) as target:
            path = Path(target.name)
            target.write(FIXTURE)
        if path.read_bytes() != FIXTURE:
            result = "readback-mismatch"
        else:
            result = "succeeded"
    except OSError as error:
        result = classify_os_error(error)
    if path is not None:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            # A leftover fixed-value canary is not a secret, but cleanup
            # failure must stay visible instead of being reported success.
            return "cleanup-failed"
    return result


def probe_self_process():
    try:
        result = subprocess.run(
            ["ps", "-p", str(os.getpid()), "-o", "pid="],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except FileNotFoundError:
        return "command-unavailable"
    except PermissionError:
        return "permission-denied"
    except subprocess.TimeoutExpired:
        return "timed-out"
    if result.returncode == 0 and result.stdout.strip() == str(os.getpid()):
        return "succeeded"
    if "operation not permitted" in result.stderr.lower() or "permission denied" in result.stderr.lower():
        return "permission-denied"
    return "failed"


def apple_seatbelt_network_policy():
    if platform.system() != "Darwin":
        return "not-applicable"
    try:
        sandbox = ctypes.CDLL("/usr/lib/system/libsystem_sandbox.dylib")
        sandbox.sandbox_check.restype = ctypes.c_int
        decision = sandbox.sandbox_check(os.getpid(), b"network-outbound", 0)
    except (AttributeError, OSError):
        return "unknown"
    if decision == 1:
        return "denied"
    if decision == 0:
        return "allowed"
    return "unknown"


def probe_network(enabled):
    if not enabled:
        return {"dns": "not-run", "https": "not-run", "httpStatus": None}
    try:
        socket.getaddrinfo(NETWORK_HOST, 443, type=socket.SOCK_STREAM)
    except PermissionError:
        return {"dns": "permission-denied", "https": "not-run", "httpStatus": None}
    except socket.gaierror:
        return {"dns": "unavailable", "https": "not-run", "httpStatus": None}
    except OSError:
        return {"dns": "failed", "https": "not-run", "httpStatus": None}

    connection = http.client.HTTPSConnection(
        NETWORK_HOST,
        443,
        timeout=10,
        context=ssl.create_default_context(),
    )
    try:
        connection.request("HEAD", "/")
        response = connection.getresponse()
        status = response.status
        response.close()
    except PermissionError:
        return {"dns": "succeeded", "https": "permission-denied", "httpStatus": None}
    except (TimeoutError, socket.timeout):
        return {"dns": "succeeded", "https": "timed-out", "httpStatus": None}
    except (OSError, ssl.SSLError, http.client.HTTPException):
        return {"dns": "succeeded", "https": "transport-failed", "httpStatus": None}
    finally:
        connection.close()
    return {"dns": "succeeded", "https": "http-response", "httpStatus": status}


def observe(host, harness, provider, network=False):
    return {
        "schemaVersion": 1,
        "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "declaredHost": host,
        "declaredHarness": harness,
        "declaredProvider": provider,
        "osClass": platform.system().lower() or "unknown",
        "probes": {
            "sourceRead": probe_source_read(),
            "workingDirectoryWrite": probe_write(Path.cwd()),
            "temporaryDirectoryWrite": probe_write(Path(tempfile.gettempdir())),
            "selfProcessVisibility": probe_self_process(),
            "appleSeatbeltNetworkPolicy": apple_seatbelt_network_policy(),
            "outboundNetwork": probe_network(network),
        },
        "assessment": "boundary-observation-only-not-credential-validation",
    }


def main():
    parser = DiagnosticParser(description=__doc__)
    parser.add_argument("--host", required=True, choices=("pro", "mini", "mini-vm", "wsl"))
    parser.add_argument("--harness", required=True, choices=("direct", "t3-code"))
    parser.add_argument("--provider", required=True, choices=("codex", "claude"))
    parser.add_argument(
        "--network",
        action="store_true",
        help="run DNS and HTTPS HEAD probes against the fixed public canary",
    )
    args = parser.parse_args()
    json.dump(observe(args.host, args.harness, args.provider, args.network), sys.stdout, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
