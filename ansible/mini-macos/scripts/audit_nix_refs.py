#!/usr/bin/env python3
"""Report Nix path references without printing plist values or file contents."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess


REFERENCE_PREFIXES = {
    "/nix/store/": "nix_store",
    "/etc/profiles/": "nix_profile",
    "/run/current-system/": "nix_system",
}


def reference_kinds(value):
    if not isinstance(value, str):
        return []
    return sorted({kind for prefix, kind in REFERENCE_PREFIXES.items() if prefix in value})


def inspect_value(value, key_path=""):
    findings = []
    if isinstance(value, dict):
        for key in sorted(value):
            child = f"{key_path}.{key}" if key_path else str(key)
            findings.extend(inspect_value(value[key], child))
    elif isinstance(value, list):
        for index, child_value in enumerate(value):
            findings.extend(inspect_value(child_value, f"{key_path}[{index}]"))
    else:
        for kind in reference_kinds(value):
            findings.append({"key": key_path, "reference": kind})
    return findings


def inspect_plists(paths):
    results = []
    for directory in paths:
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.plist")):
            try:
                with path.open("rb") as stream:
                    value = plistlib.load(stream)
            except (OSError, plistlib.InvalidFileException):
                results.append({"path": str(path), "status": "unreadable_or_invalid"})
                continue
            findings = inspect_value(value)
            if findings:
                results.append({"path": str(path), "status": "matched", "findings": findings})
    return results


def inspect_text_files(paths):
    results = []
    for path in paths:
        if not path.exists() or not path.is_file():
            continue
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            results.append({"path": str(path), "status": "unreadable"})
            continue
        findings = []
        for number, line in enumerate(lines, 1):
            for kind in reference_kinds(line):
                findings.append({"line": number, "reference": kind})
        if findings:
            results.append({"path": str(path), "status": "matched", "findings": findings})
    return results


def inspect_links(paths):
    results = []
    for path in paths:
        if not path.is_symlink():
            continue
        kinds = reference_kinds(os.readlink(path))
        if kinds:
            results.append({"path": str(path), "references": kinds})
    return results


def resolve_commands(names):
    """Resolve selected commands in a login shell without reporting its environment."""
    probe = "for n in gh fd node; do p=$(command -v \"$n\" 2>/dev/null || true); " \
            "printf 'MINI_COMMAND=%s\\t%s\\n' \"$n\" \"$p\"; done"
    completed = subprocess.run(
        ["/bin/zsh", "-lic", probe], capture_output=True, text=True, timeout=15, check=False,
    )
    resolved = {}
    for line in completed.stdout.splitlines():
        if not line.startswith("MINI_COMMAND="):
            continue
        name, _, path = line.removeprefix("MINI_COMMAND=").partition("\t")
        if name in names:
            resolved[name] = {"path": path or None, "references": reference_kinds(path)}
    return {name: resolved.get(name, {"path": None, "references": []}) for name in names}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, required=True)
    args = parser.parse_args()
    home = args.home.resolve()
    plist_dirs = [home / "Library/LaunchAgents", Path("/Library/LaunchAgents"),
                  Path("/Library/LaunchDaemons")]
    text_paths = [Path("/etc/zshenv"), Path("/etc/zshrc"), home / ".zprofile",
                  home / ".local/share/asc-mcp-runner/.path"]
    link_paths = [home / ".zshenv", home / ".zshrc", home / ".zprofile",
                  home / ".config/sheldon", home / ".config/zeno",
                  home / ".config/zsh/functions"]
    report = json.dumps({
        "commands": resolve_commands(["gh", "fd", "node"]),
        "plists": inspect_plists(plist_dirs),
        "text_files": inspect_text_files(text_paths),
        "links": inspect_links(link_paths),
    }, sort_keys=True)
    print(f"MINI_NIX_REF_AUDIT={report}")


if __name__ == "__main__":
    main()
