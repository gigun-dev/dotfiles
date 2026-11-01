#!/usr/bin/env python3
"""Record allowlisted diagnostic metadata without executing probes or retaining output."""

import argparse
import datetime
import json
import sys

HOSTS = ("pro", "mini", "mini-vm")
CONTEXTS = ("sandbox", "reviewed-read-only", "human-terminal")
PROBES = ("dns", "github-api", "ssh", "gatekeeper", "codesign")
RESULTS = ("success", "dns-unavailable", "transport-failed", "token-invalid-message",
           "permission-denied", "tailnet-policy-denied", "verification-failed", "http-response")


def record(host, target, context, probe, result, http_status=None):
    if host not in HOSTS or target not in HOSTS + ("github",) or context not in CONTEXTS or probe not in PROBES or result not in RESULTS:
        raise ValueError("unsupported metadata")
    if (result == "http-response") != (http_status is not None):
        raise ValueError("HTTP response requires a status; other results must omit it")
    if http_status is not None and (probe != "github-api" or type(http_status) is not int or not 100 <= http_status <= 599):
        raise ValueError("invalid HTTP metadata")
    if (probe == "github-api") != (target == "github"):
        raise ValueError("github target is reserved for github-api")
    if result == "tailnet-policy-denied" and probe != "ssh":
        raise ValueError("policy denial requires SSH evidence")
    assessment = "unconfirmed"
    if result == "tailnet-policy-denied":
        assessment = "policy-denied-stop"
    elif result == "success" or (http_status is not None and 200 <= http_status < 300):
        assessment = "succeeded-in-this-context"
    elif http_status == 401:
        assessment = "http-401-in-this-context"
    elif http_status == 403:
        assessment = "http-403-in-this-context"
    elif context == "sandbox":
        assessment = "context-limited-failure"
    return {"schemaVersion": 1, "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "sourceHost": host, "target": target, "context": context, "probe": probe,
            "result": result, "httpStatus": http_status, "assessment": assessment}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, choices=HOSTS)
    parser.add_argument("--target", required=True, choices=HOSTS + ("github",))
    parser.add_argument("--context", required=True, choices=CONTEXTS)
    parser.add_argument("--probe", required=True, choices=PROBES)
    parser.add_argument("--result", required=True, choices=RESULTS)
    parser.add_argument("--http-status", type=int)
    args = parser.parse_args()
    try:
        value = record(args.host, args.target, args.context, args.probe, args.result, args.http_status)
    except ValueError as error:
        parser.error(str(error))
    json.dump(value, sys.stdout, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
