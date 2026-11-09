#!/usr/bin/env python3
"""Exercise the Bark key cutover state machine using disposable age identities."""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/bark-key-cutover.py"


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, **kwargs)


class BarkKeyCutover(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        (self.repo / "secrets").mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Fixture"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "commit.gpgsign", "false"], check=True)
        self.identity = self.base / "identity"
        generated = run(["age-keygen", "-o", str(self.identity)], text=True)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.identity.chmod(0o600)
        recipient = run(["age-keygen", "-y", str(self.identity)], text=True, check=True).stdout.strip()
        second_identity = self.base / "second-identity"
        self.assertEqual(run(["age-keygen", "-o", str(second_identity)]).returncode, 0)
        second_recipient = run(["age-keygen", "-y", str(second_identity)], text=True, check=True).stdout.strip()
        self.recipients = self.base / "recipients"
        self.recipients.write_text(f"{recipient}\n{second_recipient}\n")
        self.secret = self.repo / "secrets/bark-env.age"
        self.current_key = "fixture-current-encryption-key-01"[:32]
        self.device_key = "fixture-device-route"
        plaintext = (
            f"BARK_DEVICE_KEY={self.device_key}\n"
            f"BARK_ENCRYPT_KEY={self.current_key}\n"
            "BARK_ENCRYPT_IV=fixture-deprecated-iv\n"
        ).encode()
        encrypted = run(["age", "--armor", "-R", str(self.recipients)], input=plaintext, check=True).stdout
        self.secret.write_bytes(encrypted)
        subprocess.run(["git", "-C", str(self.repo), "add", "secrets/bark-env.age"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "fixture"], check=True)
        self.state = self.base / "state"
        self.clipboard = self.base / "clipboard"
        self.clipboard_stub = self.base / "clipboard-stub"
        self.clipboard_stub.write_text(f"#!/bin/sh\ncat > {self.clipboard}\n")
        self.clipboard_stub.chmod(0o755)
        self.clipboard_read_stub = self.base / "clipboard-read-stub"
        self.clipboard_read_stub.write_text(f"#!/bin/sh\ncat {self.clipboard}\n")
        self.clipboard_read_stub.chmod(0o755)

    def tearDown(self):
        self.temporary.cleanup()

    def command(self, action, *extra):
        return [
            sys.executable,
            str(HELPER),
            "--repo", str(self.repo),
            "--secret-file", str(self.secret),
            "--identity", str(self.identity),
            "--state-dir", str(self.state),
            "--recipients-file", str(self.recipients),
            "--clipboard-command", str(self.clipboard_stub),
            "--clipboard-read-command", str(self.clipboard_read_stub),
            action,
            *extra,
        ]

    def decrypt(self, path):
        return run(["age", "-d", "-i", str(self.identity), str(path)], check=True).stdout.decode()

    def assert_no_secret_output(self, result):
        output = (result.stdout + result.stderr).decode()
        self.assertNotIn(self.current_key, output)
        self.assertNotIn(self.device_key, output)

    def test_prepare_activate_rollback_and_cleanup(self):
        original = self.secret.read_bytes()
        prepared = run(self.command("prepare"))
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        self.assert_no_secret_output(prepared)
        self.assertEqual(self.secret.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        for path in self.state.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        candidate = self.decrypt(self.state / "candidate.age")
        self.assertIn(f"BARK_DEVICE_KEY={self.device_key}\n", candidate)
        self.assertNotIn(self.current_key, candidate)
        self.assertNotIn("BARK_ENCRYPT_IV", candidate)
        self.assertTrue((self.state / "candidate.age").read_bytes().startswith(b"-----BEGIN AGE ENCRYPTED FILE-----"))

        copied = run(self.command("copy-key"))
        self.assertEqual(copied.returncode, 0, copied.stderr)
        self.assert_no_secret_output(copied)
        next_key = (self.state / "next-key").read_bytes()
        self.assertEqual(self.clipboard.read_bytes(), next_key)
        self.assertEqual(len(next_key), 32)
        cleared = run(self.command("clear-key"))
        self.assertEqual(cleared.returncode, 0, cleared.stderr)
        self.assertEqual(self.clipboard.read_bytes(), b"")

        activated = run(self.command("activate"))
        self.assertEqual(activated.returncode, 0, activated.stderr)
        self.assertEqual(self.secret.read_bytes(), (self.state / "candidate.age").read_bytes())
        self.assertEqual(json.loads((self.state / "metadata.json").read_text())["status"], "activated")

        rolled_back = run(self.command("rollback"))
        self.assertEqual(rolled_back.returncode, 0, rolled_back.stderr)
        self.assertEqual(self.secret.read_bytes(), original)
        cleaned = run(self.command("abort"))
        self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
        self.assertFalse(self.state.exists())

    def test_rejects_dirty_ciphertext_and_existing_state(self):
        self.secret.write_bytes(self.secret.read_bytes() + b"dirty")
        dirty = run(self.command("prepare"))
        self.assertNotEqual(dirty.returncode, 0)
        self.assertFalse(self.state.exists())
        subprocess.run(["git", "-C", str(self.repo), "checkout", "--", "secrets/bark-env.age"], check=True)
        self.assertEqual(run(self.command("prepare")).returncode, 0)
        repeated = run(self.command("prepare"))
        self.assertNotEqual(repeated.returncode, 0)

    def test_rejects_digest_drift_and_symlink(self):
        self.assertEqual(run(self.command("prepare")).returncode, 0)
        self.secret.write_bytes(self.secret.read_bytes() + b"drift")
        drift = run(self.command("activate"))
        self.assertNotEqual(drift.returncode, 0)
        self.secret.unlink()
        self.secret.symlink_to(self.state / "original.age")
        symlink = run(self.command("activate"))
        self.assertNotEqual(symlink.returncode, 0)

    def test_copy_rejects_next_key_drift(self):
        self.assertEqual(run(self.command("prepare")).returncode, 0)
        (self.state / "next-key").write_bytes(b"x" * 32)
        rejected = run(self.command("copy-key"))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertFalse(self.clipboard.exists())

    def test_cleanup_rejects_symlinked_state_directory(self):
        self.assertEqual(run(self.command("prepare")).returncode, 0)
        real_state = self.base / "real-state"
        self.state.rename(real_state)
        self.state.symlink_to(real_state, target_is_directory=True)
        rejected = run(self.command("abort"))
        self.assertNotEqual(rejected.returncode, 0)
        self.assertTrue((real_state / "metadata.json").exists())
        self.assertTrue((real_state / "original.age").exists())

    def test_finalize_requires_all_acceptance_and_committed_candidate(self):
        self.assertEqual(run(self.command("prepare")).returncode, 0)
        self.assertEqual(run(self.command("activate")).returncode, 0)
        missing = run(self.command("finalize", "--pro-confirmed"))
        self.assertNotEqual(missing.returncode, 0)
        uncommitted = run(self.command(
            "finalize", "--pro-confirmed", "--mini-vm-confirmed", "--iphone-confirmed"
        ))
        self.assertNotEqual(uncommitted.returncode, 0)
        subprocess.run(["git", "-C", str(self.repo), "add", "secrets/bark-env.age"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "activate"], check=True)
        finalized = run(self.command(
            "finalize", "--pro-confirmed", "--mini-vm-confirmed", "--iphone-confirmed"
        ))
        self.assertEqual(finalized.returncode, 0, finalized.stderr)
        self.assertFalse(self.state.exists())

    def test_rejects_invalid_dotenv_contract(self):
        invalid_cases = [
            b"BARK_DEVICE_KEY=device\nBARK_ENCRYPT_KEY=short\n",
            b"BARK_DEVICE_KEY=device\nBARK_ENCRYPT_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nUNKNOWN_FIELD=value\n",
            b"BARK_DEVICE_KEY=device\nBARK_DEVICE_KEY=duplicate\nBARK_ENCRYPT_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n",
            b"BARK_DEVICE_KEY=device\nBARK_ENCRYPT_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\nBARK_PUSH_URL=http://fixture.invalid\n",
        ]
        for index, plaintext in enumerate(invalid_cases):
            with self.subTest(index=index):
                encrypted = run(["age", "-R", str(self.recipients)], input=plaintext, check=True).stdout
                self.secret.write_bytes(encrypted)
                subprocess.run(["git", "-C", str(self.repo), "add", "secrets/bark-env.age"], check=True)
                subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", f"invalid-{index}"], check=True)
                rejected = run(self.command("prepare"))
                self.assertNotEqual(rejected.returncode, 0)
                self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
