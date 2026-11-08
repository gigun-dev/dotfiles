#!/usr/bin/env python3
"""Classify GitHub auth without mistaking a sandbox network denial for revocation."""

import argparse
import ctypes
import json
import os
import platform
import re
import shutil
import subprocess
import sys


HTTP_STATUS = re.compile(r"\bHTTP ([1-5][0-9]{2})\b")


def apple_seatbelt_network_policy():
    """Return Apple Seatbelt's outbound decision, without exposing its profile."""
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


def run_gh(arguments, timeout=15):
    try:
        return subprocess.run(
            ["gh", *arguments],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None


def diagnose(local_only=False):
    result = {
        "schemaVersion": 1,
        "sandboxMechanism": "unknown",
        "networkPolicy": "unknown",
        "localCredential": "unknown",
        "onlineProbe": "not-run",
        "httpStatus": None,
        "assessment": "indeterminate",
    }

    if platform.system() == "Darwin":
        result["networkPolicy"] = apple_seatbelt_network_policy()
        result["sandboxMechanism"] = (
            "apple-seatbelt"
            if result["networkPolicy"] == "denied"
            else "not-detected-for-network"
        )

    if shutil.which("gh") is None:
        result["localCredential"] = "gh-unavailable"
        result["assessment"] = "local-prerequisite-missing"
        return result, 3

    # `gh auth status --no-refresh` still contacts GitHub and reports a
    # Seatbelt network denial as "token invalid". Read the selected token into
    # captured stdout only to prove local availability; never return its value.
    local = run_gh(["auth", "token", "--hostname", "github.com"])
    if local is None:
        result["localCredential"] = "check-timed-out"
        result["assessment"] = "local-check-indeterminate"
        return result, 3
    if local.returncode == 0:
        result["localCredential"] = "configured-and-readable"
    else:
        # The macOS profile may allow reading hosts.yml while denying Keychain.
        # `auth status` is used only for the active-account marker; its invalid
        # token conclusion is deliberately discarded.
        status = run_gh(["auth", "status", "--active", "--no-refresh"])
        status_output = "" if status is None else f"{status.stdout}\n{status.stderr}"
        if "Active account: true" in status_output:
            result["localCredential"] = "account-configured-token-unreadable"
        else:
            result["localCredential"] = "not-configured-or-unreadable"

    if local_only:
        result["assessment"] = "local-state-not-online-validation"
        return result, 3

    if result["networkPolicy"] == "denied":
        result["onlineProbe"] = "blocked-by-apple-seatbelt"
        result["assessment"] = "context-limited-network-denial"
        return result, 3

    if result["localCredential"] != "configured-and-readable":
        result["assessment"] = "local-check-indeterminate"
        return result, 3

    online = run_gh(["api", "--silent", "user"])
    if online is None:
        result["onlineProbe"] = "timed-out"
        result["assessment"] = "transport-indeterminate"
        return result, 3
    if online.returncode == 0:
        result["onlineProbe"] = "succeeded"
        result["httpStatus"] = 200
        result["assessment"] = "credential-accepted"
        return result, 0

    combined = f"{online.stdout}\n{online.stderr}"
    match = HTTP_STATUS.search(combined)
    if match is None:
        result["onlineProbe"] = "failed-without-http-response"
        result["assessment"] = "transport-or-client-indeterminate"
        return result, 3

    status = int(match.group(1))
    result["onlineProbe"] = "http-response"
    result["httpStatus"] = status
    if status == 401:
        result["assessment"] = "credential-rejected"
        return result, 1
    if status == 403:
        result["assessment"] = "forbidden-not-token-invalid"
        return result, 2
    result["assessment"] = "http-error-not-token-invalid"
    return result, 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="inspect local credential selection without an online probe",
    )
    args = parser.parse_args()
    result, returncode = diagnose(local_only=args.local_only)
    json.dump(result, sys.stdout, sort_keys=True)
    print()
    return returncode


if __name__ == "__main__":
    raise SystemExit(main())
