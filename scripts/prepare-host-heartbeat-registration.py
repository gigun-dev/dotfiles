#!/usr/bin/env python3
"""Prepare a private hub credential file; never apply or print its contents."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


def private_file(path):
    mode = Path(path).stat().st_mode
    if not stat.S_ISREG(mode) or mode & 0o077:
        raise ValueError("credential input must be private")


def prepare(existing, reference_source, tokens):
    validate_credentials(existing)
    reference = [item for item in existing if item["source"] == reference_source]
    if len(reference) != 1:
        raise ValueError("reference source must be unique")
    reference = reference[0]
    owner = reference["ownerId"]
    if any(item["source"] in tokens and item["ownerId"] != owner for item in existing):
        raise ValueError("refusing to replace another owner's source")
    result = [item for item in existing if item["source"] not in tokens]
    for source, token in tokens.items():
        # Resolve routing from the existing hub source, never invent owner/destinations.
        result.append({"source": source, "ownerId": owner,
                       "destinations": list(reference["destinations"]), "token": token})
    validate_credentials(result)
    return result


def validate_credentials(values):
    identifier = r"[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}"
    if not isinstance(values, list) or not 1 <= len(values) <= 32:
        raise ValueError("invalid credential list")
    token_set = set()
    for item in values:
        if not isinstance(item, dict):
            raise ValueError("invalid credential")
        for field in ("ownerId", "source"):
            if not isinstance(item.get(field), str) or not re.fullmatch(identifier, item[field]):
                raise ValueError("invalid identity")
        destinations = item.get("destinations")
        if (not isinstance(destinations, list) or not 1 <= len(destinations) <= 8
                or not all(isinstance(v, str) and re.fullmatch(identifier, v) for v in destinations)
                or len(set(destinations)) != len(destinations)):
            raise ValueError("invalid destinations")
        if "monitorControl" in item and not isinstance(item["monitorControl"], bool):
            raise ValueError("invalid management permission")
        token = item.get("token")
        if (not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token)
                or token in token_set):
            raise ValueError("invalid or duplicate token")
        token_set.add(token)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials-file", required=True, type=Path)
    parser.add_argument("--reference-source", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    private_file(args.credentials_file)
    private_file(args.identity)
    # Prevent accidental disclosure through a shared staging directory or overwrite.
    if args.output.exists() or args.output.is_symlink() or args.output.parent.stat().st_mode & 0o077:
        raise ValueError("output must be new in a private staging directory")
    root = Path(__file__).resolve().parents[1]
    tokens = {}
    for source, name in [("mac", "host-heartbeat-mac.age"), ("mini-vm", "host-heartbeat-vm.age")]:
        value = subprocess.run(["age", "-d", "-i", args.identity, str(root / "secrets" / name)],
                               check=True, capture_output=True, timeout=10).stdout.decode().strip()
        if not value or any(c.isspace() for c in value):
            raise ValueError("invalid decrypted token")
        tokens[source] = value
    result = prepare(json.loads(args.credentials_file.read_text()), args.reference_source, tokens)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=args.output.parent, delete=False) as output:
            temporary = Path(output.name)
            json.dump(result, output)
            output.flush()
            os.fsync(output.fileno())
        # O_EXCL prevents a competing invocation from replacing the output.
        os.link(temporary, args.output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        raise SystemExit("registration preparation failed; no credentials printed or applied")
