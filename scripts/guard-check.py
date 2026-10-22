#!/usr/bin/env python3
"""Read-only Guard audit. Run with python3 -I -S to skip .pth/sitecustomize.

Reports paths and setting names only, never configuration values or credentials.
Does not invoke a package manager, import project code, or access the network.
"""
import argparse
import configparser
import os
from pathlib import Path
import sys
import tomllib
from urllib.parse import urlsplit

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--home", type=Path, default=Path.home())
parser.add_argument("--scan", type=Path, action="append", default=[], help="scan project registry overrides")
args = parser.parse_args()
errors = []
overrides = []


def report(kind, path, detail):
    print(f"{kind}: {path}: {detail}")
    if kind == "ERROR":
        errors.append(path)
    elif kind == "OVERRIDE":
        overrides.append(path)


def guarded(value, host):
    try:
        url = urlsplit(str(value))
        return url.scheme == "https" and url.hostname == host and not url.query
    except ValueError:
        return False


def inspect(path, project=False):
    try:
        data = path.read_text()
        if path.name in ("uv.toml", "pyproject.toml"):
            config = tomllib.loads(data)
            if path.name == "pyproject.toml":
                config = config.get("tool", {}).get("uv", {})
            for item in config.get("index", []):
                if not guarded(item.get("url", ""), "pypi.flatt.tech"):
                    report("OVERRIDE", path, "uv index bypasses Guard")
            for section in (config, config.get("pip", {})):
                for key in ("index-url", "extra-index-url", "default-index", "index", "find-links", "no-index"):
                    value = section.get(key)
                    if not value or key == "index" and isinstance(value, list) and all(isinstance(x, dict) for x in value):
                        continue
                    values = value if isinstance(value, list) else [value]
                    if not all(guarded(v, "pypi.flatt.tech") for v in values):
                        report("OVERRIDE", path, f"uv {key} changes source selection")
            poetry = tomllib.loads(data).get("tool", {}).get("poetry", {})
            for source in poetry.get("source", []):
                if not guarded(source.get("url", ""), "pypi.flatt.tech"):
                    report("OVERRIDE", path, "Poetry source bypasses Guard")
        elif "bunfig" in path.name:
            install = tomllib.loads(data).get("install", {})
            registries = [install["registry"]] if "registry" in install else []
            registries += list(install.get("scopes", {}).values())
            for value in registries:
                if not guarded(value.get("url", "") if isinstance(value, dict) else value, "npm.flatt.tech"):
                    report("OVERRIDE", path, "Bun registry bypasses Guard")
        else:
            config = configparser.ConfigParser(interpolation=None, strict=False, delimiters=("=",))
            config.read_string("[npm]\n" + data if path.name == ".npmrc" else data)
            for section in config.sections():
                for key, value in config.items(section):
                    if key.endswith("registry") or key in ("index-url", "extra-index-url", "find-links", "no-index"):
                        host = "npm.flatt.tech" if key.endswith("registry") else "pypi.flatt.tech"
                        if value and not all(guarded(v, host) for v in value.split()):
                            report("OVERRIDE", path, f"{key} bypasses Guard")
    except (OSError, ValueError, configparser.Error):
        report("ERROR", path, "unreadable or invalid configuration (contents withheld)")


config = Path(os.environ.get("XDG_CONFIG_HOME", str(args.home / ".config")))
if not config.is_absolute():
    report("ERROR", config, "XDG_CONFIG_HOME must be absolute")
targets = [
    ("npm/npmrc", args.home / ".npmrc"),
    ("bun/bunfig.toml", args.home / ".bunfig.toml"),
    ("bun/bunfig.toml", config / ".bunfig.toml"),
    ("uv/uv.toml", config / "uv/uv.toml"),
    ("pip/pip.conf", config / "pip/pip.conf"),
]
if sys.platform == "darwin":
    targets.append(("pip/pip.conf", args.home / "Library/Application Support/pip/pip.conf"))
for relative, target in targets:
    source = args.repo / relative
    try:
        if source.read_bytes() != target.read_bytes():
            report("ERROR", target, "differs from declared source")
        elif target.is_symlink() and not str(target.resolve()).startswith("/nix/store/"):
            report("ERROR", target, "mutable checkout symlink; contents are not fixed")
        else:
            report("OK", target, "declared contents applied")
        inspect(target)
    except OSError:
        report("ERROR", target, "source or destination missing/unreadable")

# These files and env variables can override otherwise-correct user defaults.
legacy = args.home / ".pip/pip.conf"
if legacy.is_file():
    inspect(legacy)
venv = os.environ.get("VIRTUAL_ENV")
if venv and (Path(venv) / "pip.conf").is_file():
    inspect(Path(venv) / "pip.conf")
for key, value in os.environ.items():
    registry = key.upper() in ("PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "UV_DEFAULT_INDEX", "UV_INDEX_URL", "UV_INDEX", "UV_EXTRA_INDEX_URL", "NPM_CONFIG_REGISTRY", "BUN_CONFIG_REGISTRY")
    if registry:
        host = "npm.flatt.tech" if key.upper().startswith(("NPM", "BUN")) else "pypi.flatt.tech"
        if value and not all(guarded(v, host) for v in value.split()):
            report("OVERRIDE", key, "environment overrides user defaults (value withheld)")
        else:
            report("INFO", key, "Guard environment override present; clean-env check also required")
    elif key in ("PIP_CONFIG_FILE", "UV_CONFIG_FILE", "NPM_CONFIG_USERCONFIG", "npm_config_userconfig", "PIP_NO_INDEX", "UV_NO_CONFIG", "PIP_FIND_LINKS", "UV_FIND_LINKS") and value:
        report("OVERRIDE", key, "explicit configuration override present (value withheld)")

names = {".npmrc", "bunfig.toml", ".bunfig.toml", "uv.toml", "pyproject.toml", "pip.conf"}
for root in args.scan:
    def onerror(error):
        report("ERROR", error.filename, "access denied/unreadable; not retried")
    for directory, dirs, files in os.walk(root, followlinks=False, onerror=onerror):
        dirs[:] = [d for d in dirs if d not in {".git", "node_modules", ".venv", ".build", "__pycache__"}]
        for name in sorted(names.intersection(files)):
            inspect(Path(directory) / name, project=True)
print(f"Guard audit: {len(errors)} errors, {len(overrides)} overrides; no network or package execution")
sys.exit(1 if errors else 2 if overrides else 0)
