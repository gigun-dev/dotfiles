#!/usr/bin/env python3
"""Prepare and apply a one-time Bark encryption-key cutover without printing secrets."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
import tempfile


ALLOWED_FIELDS = {"BARK_DEVICE_KEY", "BARK_ENCRYPT_KEY", "BARK_ENCRYPT_IV", "BARK_PUSH_URL"}
REQUIRED_FIELDS = {"BARK_DEVICE_KEY", "BARK_ENCRYPT_KEY"}
KEY_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"


def fail(message):
    raise SystemExit(f"bark-key-cutover: {message}")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def recipient_stanza_types(ciphertext):
    raw = run(["age-inspect", "--json"], input_data=ciphertext)
    try:
        inspected = json.loads(raw)
        types = inspected["stanza_types"]
    except (json.JSONDecodeError, KeyError, TypeError):
        fail("age ciphertext metadata is malformed")
    if not isinstance(types, list) or not types or not all(isinstance(item, str) for item in types):
        fail("age ciphertext has no recipient stanza types")
    return sorted(types)


def require_regular(path, *, private=False):
    try:
        details = path.lstat()
    except FileNotFoundError:
        fail("required file is missing")
    mode = details.st_mode
    if not stat.S_ISREG(mode) or path.is_symlink():
        fail("file must be regular and not a symlink")
    if private:
        if details.st_uid != os.getuid():
            fail("private file has an unexpected owner")
        if mode & 0o077:
            fail("private file permissions are too broad")


def require_private_dir(path):
    try:
        details = path.lstat()
    except FileNotFoundError:
        fail("private state directory is missing")
    if not stat.S_ISDIR(details.st_mode) or path.is_symlink():
        fail("private state must be a directory and not a symlink")
    if details.st_uid != os.getuid():
        fail("private state directory has an unexpected owner")
    if stat.S_IMODE(details.st_mode) != 0o700:
        fail("private state directory permissions must be 0700")


def parse_dotenv(data):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail("decrypted dotenv is not UTF-8")
    values = {}
    for line in text.splitlines():
        if not line:
            continue
        if "=" not in line:
            fail("decrypted dotenv contains a malformed line")
        key, value = line.split("=", 1)
        if key not in ALLOWED_FIELDS or key in values:
            fail("decrypted dotenv contains an unknown or duplicate field")
        if not value or "\n" in value or "\r" in value:
            fail("decrypted dotenv contains an empty or multiline value")
        values[key] = value
    if set(values) - ALLOWED_FIELDS or not REQUIRED_FIELDS.issubset(values):
        fail("decrypted dotenv fields do not match the Bark contract")
    if len(values["BARK_ENCRYPT_KEY"].encode()) != 32:
        fail("current Bark encryption key has an unexpected length")
    if "BARK_PUSH_URL" in values and not values["BARK_PUSH_URL"].startswith("https://"):
        fail("Bark route must use HTTPS")
    return values


def encode_dotenv(values):
    order = ("BARK_DEVICE_KEY", "BARK_ENCRYPT_KEY", "BARK_PUSH_URL")
    return "".join(f"{key}={values[key]}\n" for key in order if key in values).encode()


def run(command, *, input_data=None):
    result = subprocess.run(command, input=input_data, capture_output=True)
    if result.returncode:
        fail("a secret-processing command failed")
    return result.stdout


def atomic_write(path, data, mode):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def default_state_dir():
    base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return base / "dotfiles/bark-key-cutover"


def absolute(path):
    return Path(os.path.abspath(os.path.expanduser(path)))


def canonical_leaf(path):
    path = absolute(path)
    return path.parent.resolve() / path.name


def resolve_paths(args):
    repo = args.repo.resolve()
    secret_file = canonical_leaf(args.secret_file or repo / "secrets/bark-env.age")
    identity = canonical_leaf(args.identity or Path.home() / ".ssh/id_ed25519")
    state_dir = canonical_leaf(args.state_dir or default_state_dir())
    return repo, secret_file, identity, state_dir


def read_recipients(repo, supplied):
    if supplied:
        require_regular(supplied)
        lines = [line for line in supplied.read_text().splitlines() if line.strip()]
    else:
        policy = repo / "secrets/secrets.nix"
        require_regular(policy)
        tracked = run(["git", "-C", str(repo), "show", "HEAD:secrets/secrets.nix"])
        if policy.read_bytes() != tracked:
            fail("recipient policy has uncommitted changes")
        expression = (
            'let rules = import ./secrets/secrets.nix; '
            'in rules."bark-env.age".publicKeys'
        )
        raw = run(["nix", "eval", "--impure", "--json", "--expr", expression], input_data=None)
        try:
            lines = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            fail("recipient policy could not be evaluated")
    if not isinstance(lines, list) or not lines or not all(isinstance(line, str) and line for line in lines):
        fail("recipient policy is empty or malformed")
    return lines


def load_metadata(state_dir):
    require_private_dir(state_dir)
    require_regular(state_dir / "metadata.json", private=True)
    try:
        return json.loads((state_dir / "metadata.json").read_text())
    except (json.JSONDecodeError, OSError):
        fail("rotation metadata is invalid")


def save_metadata(state_dir, metadata):
    atomic_write(state_dir / "metadata.json", (json.dumps(metadata, sort_keys=True) + "\n").encode(), 0o600)


def remove_state(state_dir):
    require_private_dir(state_dir)
    expected = {"candidate.age", "metadata.json", "next-key", "original.age", ".recipients"}
    found = {path.name for path in state_dir.iterdir()}
    if not found.issubset(expected):
        fail("rotation state contains unexpected files")
    for name in expected:
        (state_dir / name).unlink(missing_ok=True)
    state_dir.rmdir()


def prepare(args):
    repo, secret_file, identity, state_dir = resolve_paths(args)
    require_regular(secret_file)
    require_regular(identity, private=True)
    if state_dir.exists():
        fail("rotation state already exists")
    state_dir.mkdir(mode=0o700, parents=True)
    require_private_dir(state_dir)
    try:
        original = secret_file.read_bytes()
        try:
            relative = secret_file.relative_to(repo)
        except ValueError:
            fail("Bark ciphertext must be inside the repository")
        tracked = run(["git", "-C", str(repo), "show", f"HEAD:{relative.as_posix()}"])
        if original != tracked:
            fail("tracked Bark ciphertext has uncommitted changes")
        plaintext = run(["age", "-d", "-i", str(identity), str(secret_file)])
        values = parse_dotenv(plaintext)
        next_key = "".join(secrets.choice(KEY_ALPHABET) for _ in range(32))
        if secrets.compare_digest(values["BARK_ENCRYPT_KEY"], next_key):
            fail("generated key unexpectedly matches the current key")
        candidate_values = dict(values)
        candidate_values.pop("BARK_ENCRYPT_IV", None)
        candidate_values["BARK_ENCRYPT_KEY"] = next_key
        recipients = read_recipients(repo, args.recipients_file)
        recipients_path = state_dir / ".recipients"
        atomic_write(recipients_path, ("\n".join(recipients) + "\n").encode(), 0o600)
        encrypt_command = ["age"]
        if original.startswith(b"-----BEGIN AGE ENCRYPTED FILE-----\n"):
            encrypt_command.append("--armor")
        encrypt_command.extend(["-R", str(recipients_path)])
        candidate = run(encrypt_command, input_data=encode_dotenv(candidate_values))
        recipients_path.unlink()
        if recipient_stanza_types(original) != recipient_stanza_types(candidate):
            fail("candidate recipient stanza types differ from the current ciphertext")
        round_trip = run(["age", "-d", "-i", str(identity)], input_data=candidate)
        if parse_dotenv(round_trip) != candidate_values:
            fail("candidate ciphertext did not round-trip")
        atomic_write(state_dir / "original.age", original, 0o600)
        atomic_write(state_dir / "candidate.age", candidate, 0o600)
        atomic_write(state_dir / "next-key", next_key.encode(), 0o600)
        save_metadata(state_dir, {
            "candidate_digest": digest(candidate),
            "next_key_digest": digest(next_key.encode()),
            "original_digest": digest(original),
            "relative_secret": relative.as_posix(),
            "status": "prepared",
        })
    except BaseException:
        if state_dir.exists() and not (state_dir / "metadata.json").exists():
            remove_state(state_dir)
        raise
    print("Bark key cutover candidate prepared; production ciphertext is unchanged.")


def copy_key(args):
    _, _, identity, state_dir = resolve_paths(args)
    metadata = load_metadata(state_dir)
    if metadata.get("status") not in {"prepared", "activated"}:
        fail("rotation state is not ready for clipboard delivery")
    key_file = state_dir / "next-key"
    require_regular(key_file, private=True)
    key = key_file.read_bytes()
    recorded_digest = metadata.get("next_key_digest")
    if recorded_digest is not None and digest(key) != recorded_digest:
        fail("next Bark encryption key drifted after prepare")
    candidate_file = state_dir / "candidate.age"
    require_regular(candidate_file, private=True)
    candidate_values = parse_dotenv(run(["age", "-d", "-i", str(identity), str(candidate_file)]))
    if not secrets.compare_digest(candidate_values["BARK_ENCRYPT_KEY"].encode(), key):
        fail("next Bark encryption key does not match the candidate")
    command = args.clipboard_command or "/usr/bin/pbcopy"
    if not Path(command).is_absolute():
        fail("clipboard command must be an absolute path")
    run([command], input_data=key)
    print("Next Bark encryption key copied to the clipboard.")


def clear_key(args):
    _, _, _, state_dir = resolve_paths(args)
    load_metadata(state_dir)
    key_file = state_dir / "next-key"
    require_regular(key_file, private=True)
    read_command = args.clipboard_read_command or "/usr/bin/pbpaste"
    write_command = args.clipboard_command or "/usr/bin/pbcopy"
    if not Path(read_command).is_absolute() or not Path(write_command).is_absolute():
        fail("clipboard commands must be absolute paths")
    clipboard = run([read_command])
    if secrets.compare_digest(clipboard, key_file.read_bytes()):
        run([write_command], input_data=b"")
        print("Bark encryption key removed from the clipboard.")
    else:
        print("Clipboard no longer contains the prepared Bark encryption key.")


def activate(args):
    _, secret_file, _, state_dir = resolve_paths(args)
    metadata = load_metadata(state_dir)
    if metadata.get("status") != "prepared":
        fail("rotation state is not prepared")
    require_regular(secret_file)
    candidate_path = state_dir / "candidate.age"
    require_regular(candidate_path, private=True)
    current = secret_file.read_bytes()
    candidate = candidate_path.read_bytes()
    if digest(current) != metadata.get("original_digest"):
        fail("current ciphertext drifted after prepare")
    if digest(candidate) != metadata.get("candidate_digest"):
        fail("candidate ciphertext drifted after prepare")
    atomic_write(secret_file, candidate, stat.S_IMODE(secret_file.stat().st_mode))
    metadata["status"] = "activated"
    save_metadata(state_dir, metadata)
    print("Candidate Bark ciphertext activated in the working tree.")


def rollback(args):
    _, secret_file, _, state_dir = resolve_paths(args)
    metadata = load_metadata(state_dir)
    if metadata.get("status") != "activated":
        fail("rotation state is not activated")
    require_regular(secret_file)
    original_path = state_dir / "original.age"
    require_regular(original_path, private=True)
    if digest(secret_file.read_bytes()) != metadata.get("candidate_digest"):
        fail("active ciphertext drifted after activation")
    original = original_path.read_bytes()
    if digest(original) != metadata.get("original_digest"):
        fail("rollback ciphertext drifted")
    atomic_write(secret_file, original, stat.S_IMODE(secret_file.stat().st_mode))
    metadata["status"] = "rolled-back"
    save_metadata(state_dir, metadata)
    print("Original Bark ciphertext restored in the working tree.")


def abort(args):
    _, secret_file, _, state_dir = resolve_paths(args)
    metadata = load_metadata(state_dir)
    expected = {
        "prepared": metadata.get("original_digest"),
        "rolled-back": metadata.get("original_digest"),
    }.get(metadata.get("status"))
    require_regular(secret_file)
    if expected is None or digest(secret_file.read_bytes()) != expected:
        fail("only a prepared or rolled-back cutover can be aborted")
    remove_state(state_dir)
    print("Unapplied Bark cutover state removed.")


def finalize(args):
    repo, secret_file, _, state_dir = resolve_paths(args)
    metadata = load_metadata(state_dir)
    if metadata.get("status") != "activated":
        fail("only an activated cutover can be finalized")
    if not (args.pro_confirmed and args.mini_vm_confirmed and args.iphone_confirmed):
        fail("finalize requires Pro, mini-vm, and iPhone acceptance confirmation")
    require_regular(secret_file)
    current = secret_file.read_bytes()
    if digest(current) != metadata.get("candidate_digest"):
        fail("working-tree ciphertext does not match the candidate")
    relative = metadata.get("relative_secret")
    if not isinstance(relative, str) or not relative:
        fail("rotation metadata does not identify the ciphertext")
    if run(["git", "-C", str(repo), "show", f"HEAD:{relative}"]) != current:
        fail("candidate ciphertext is not committed at HEAD")
    remove_state(state_dir)
    print("Accepted Bark cutover state finalized and removed.")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", type=Path, default=Path.cwd())
    result.add_argument("--secret-file", type=Path)
    result.add_argument("--identity", type=Path)
    result.add_argument("--state-dir", type=Path)
    result.add_argument("--recipients-file", type=Path)
    result.add_argument("--clipboard-command")
    result.add_argument("--clipboard-read-command")
    subparsers = result.add_subparsers(dest="command", required=True)
    subparsers.add_parser("prepare").set_defaults(function=prepare)
    subparsers.add_parser("copy-key").set_defaults(function=copy_key)
    subparsers.add_parser("clear-key").set_defaults(function=clear_key)
    subparsers.add_parser("activate").set_defaults(function=activate)
    subparsers.add_parser("rollback").set_defaults(function=rollback)
    subparsers.add_parser("abort").set_defaults(function=abort)
    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--pro-confirmed", action="store_true")
    finalize_parser.add_argument("--mini-vm-confirmed", action="store_true")
    finalize_parser.add_argument("--iphone-confirmed", action="store_true")
    finalize_parser.set_defaults(function=finalize)
    return result


def main():
    args = parser().parse_args()
    os.umask(0o077)
    try:
        os.chdir(args.repo)
        args.function(args)
    except SystemExit:
        raise
    except Exception:
        fail("operation failed safely")


if __name__ == "__main__":
    main()
