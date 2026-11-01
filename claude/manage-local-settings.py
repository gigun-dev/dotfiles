#!/usr/bin/env python3
"""Keep host-specific Claude settings writable without changing the checkout."""
import json
import os
from pathlib import Path
import sys
import tempfile


def identity(path):
    info = path.lstat()
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def main():
    settings, template = map(Path, sys.argv[1:3])
    marketplace = sys.argv[3]
    was_symlink = settings.is_symlink()
    if was_symlink:
        if settings.resolve(strict=True) != template.resolve(strict=True):
            raise ValueError("settings symlink is not the dotfiles template")
        before = identity(settings)
        original = settings.read_bytes()
        settings_data = json.loads(original)
        if settings_data["extraKnownMarketplaces"]["gigun"]["source"]["path"] != marketplace:
            raise ValueError("existing marketplace path differs from declared path")
        if identity(settings) != before or settings.read_bytes() != original:
            raise ValueError("settings changed during migration")
    elif settings.exists():
        if not settings.is_file():
            raise ValueError("settings is not a regular file")
        settings_data = json.loads(settings.read_bytes())
        if settings_data["extraKnownMarketplaces"]["gigun"]["source"]["path"] != marketplace:
            raise ValueError("existing marketplace path differs from declared path")
        return
    else:
        settings_data = json.loads(template.read_bytes())
        settings_data["extraKnownMarketplaces"]["gigun"]["source"]["path"] = marketplace
        original = (json.dumps(settings_data, ensure_ascii=False, indent=2) + "\n").encode()

    fd, temporary = tempfile.mkstemp(prefix=".settings.json.", dir=settings.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(original)
        # Don't overwrite a setting edited while the copy was prepared.
        if was_symlink:
            if not settings.is_symlink() or identity(settings) != before or settings.read_bytes() != original:
                raise ValueError("settings changed during migration")
        elif settings.exists() or settings.is_symlink():
            raise ValueError("settings appeared during initialization")
        os.replace(temporary, settings)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Claude settings: {error}", file=sys.stderr)
        sys.exit(1)
