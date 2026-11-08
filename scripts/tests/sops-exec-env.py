#!/usr/bin/env python3
"""Verify SOPS dotenv execution without using a real key or secret."""

import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


SOPS = os.environ.get("TEST_SOPS", shutil.which("sops") or "sops")
AGE_KEYGEN = os.environ.get("TEST_AGE_KEYGEN", shutil.which("age-keygen") or "age-keygen")


class ExecEnvFixture(unittest.TestCase):
    def run_quietly(self, args, *, env=None):
        result = subprocess.run(
            args,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, "fixture command failed without exposing its output")
        return result

    def run_expect_failure(self, args, *, env=None):
        result = subprocess.run(
            args,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertNotEqual(result.returncode, 0, "fixture command unexpectedly succeeded")
        return result

    def create_identity(self, root, name):
        identity = root / f"{name}.age-identity"
        generated = self.run_quietly([AGE_KEYGEN, "-o", str(identity)])
        self.assertFalse(generated.stdout, "age-keygen unexpectedly emitted fixture material")
        identity.chmod(0o600)
        recipient = self.run_quietly([AGE_KEYGEN, "-y", str(identity)]).stdout.strip()
        self.assertTrue(recipient)
        return identity, recipient

    def decrypt_to(self, encrypted, output, identity):
        env = dict(os.environ)
        env["SOPS_AGE_KEY_FILE"] = str(identity)
        self.run_quietly([SOPS, "decrypt", "--output", str(output), str(encrypted)], env=env)

    def assert_cannot_decrypt(self, encrypted, identity, output):
        output.unlink(missing_ok=True)
        env = dict(os.environ)
        env["SOPS_AGE_KEY_FILE"] = str(identity)
        self.run_expect_failure(
            [SOPS, "decrypt", "--output", str(output), str(encrypted)],
            env=env,
        )
        self.assertFalse(output.exists(), "failed decryption retained plaintext output")

    def encrypt_dotenv(self, source, encrypted, recipients):
        self.run_quietly(
            [
                SOPS,
                "encrypt",
                "--age",
                ",".join(recipients),
                "--input-type",
                "dotenv",
                "--output-type",
                "dotenv",
                "--output",
                str(encrypted),
                str(source),
            ]
        )

    def assert_plaintext_matches(self, encrypted, identity, expected_digest, root, name):
        output = root / f"{name}.env"
        self.decrypt_to(encrypted, output, identity)
        plaintext = output.read_text()
        self.assertEqual(hashlib.sha256(plaintext.encode()).hexdigest(), expected_digest)
        output.unlink()

    def test_recipient_separation_and_recovery_rekey(self):
        marker = "nonsecret-sops-recovery-" + secrets.token_hex(12)
        plaintext = f"RECOVERY_MARKER={marker}\n"
        expected_digest = hashlib.sha256(plaintext.encode()).hexdigest()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identities = {
                name: self.create_identity(root, name)
                for name in ("primary", "backup", "host", "replacement-primary", "replacement-host")
            }
            source = root / "recovery.env"
            human_encrypted = root / "human.sops.env"
            host_encrypted = root / "host.sops.env"
            source.write_text(plaintext)
            source.chmod(0o600)

            primary, primary_recipient = identities["primary"]
            backup, backup_recipient = identities["backup"]
            host, host_recipient = identities["host"]
            replacement_primary, replacement_primary_recipient = identities["replacement-primary"]
            replacement_host, replacement_host_recipient = identities["replacement-host"]

            self.encrypt_dotenv(source, human_encrypted, [primary_recipient, backup_recipient])
            self.encrypt_dotenv(
                source,
                host_encrypted,
                [primary_recipient, backup_recipient, host_recipient],
            )
            source.unlink()

            for name, identity in (("human-primary", primary), ("human-backup", backup)):
                self.assert_plaintext_matches(human_encrypted, identity, expected_digest, root, name)
            self.assert_cannot_decrypt(human_encrypted, host, root / "human-host-denied.env")

            for name, identity in (
                ("host-primary", primary),
                ("host-backup", backup),
                ("host-machine", host),
            ):
                self.assert_plaintext_matches(host_encrypted, identity, expected_digest, root, name)

            recovered_human = root / "recovered-human.env"
            rotated_human = root / "rotated-human.sops.env"
            self.decrypt_to(human_encrypted, recovered_human, backup)
            self.encrypt_dotenv(
                recovered_human,
                rotated_human,
                [backup_recipient, replacement_primary_recipient],
            )
            recovered_human.unlink()
            self.assert_cannot_decrypt(rotated_human, primary, root / "retired-primary-denied.env")
            for name, identity in (("rotated-backup", backup), ("rotated-replacement", replacement_primary)):
                self.assert_plaintext_matches(rotated_human, identity, expected_digest, root, name)

            recovered_host = root / "recovered-host.env"
            rotated_host = root / "rotated-host.sops.env"
            self.decrypt_to(host_encrypted, recovered_host, backup)
            self.encrypt_dotenv(
                recovered_host,
                rotated_host,
                [primary_recipient, backup_recipient, replacement_host_recipient],
            )
            recovered_host.unlink()
            self.assert_cannot_decrypt(rotated_host, host, root / "retired-host-denied.env")
            for name, identity in (("new-host", replacement_host), ("new-host-backup", backup)):
                self.assert_plaintext_matches(rotated_host, identity, expected_digest, root, name)

            # Rekeying only changes the new ciphertext. Historical copies remain
            # readable by retired recipients, so underlying credentials still need rotation.
            self.assert_plaintext_matches(human_encrypted, primary, expected_digest, root, "old-primary-copy")
            self.assert_plaintext_matches(host_encrypted, host, expected_digest, root, "old-host-copy")

            for encrypted in (human_encrypted, host_encrypted, rotated_human, rotated_host):
                self.assertNotIn(marker, encrypted.read_text(), "ciphertext retained plaintext marker")

        self.assertFalse(root.exists())

    def test_pristine_environment_is_ephemeral_but_inherited_by_children(self):
        marker = "nonsecret-sops-pilot-" + secrets.token_hex(12)
        ambient = "nonsecret-ambient-" + secrets.token_hex(12)
        marker_digest = hashlib.sha256(marker.encode()).hexdigest()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            identity = root / "age-identity.txt"
            source = root / "pilot.env"
            # exec-env infers dotenv from the final extension; keep .env last.
            encrypted = root / "pilot.sops.env"
            expected = root / "expected.sha256"
            probe = root / "probe.py"
            child_result = root / "child.json"
            grandchild_result = root / "grandchild.json"

            generated = self.run_quietly([AGE_KEYGEN, "-o", str(identity)])
            self.assertFalse(generated.stdout, "age-keygen unexpectedly emitted fixture material")
            identity.chmod(0o600)
            recipient_result = self.run_quietly([AGE_KEYGEN, "-y", str(identity)])
            recipient = recipient_result.stdout.strip()
            self.assertTrue(recipient)

            source.write_text(f"SOPS_PILOT_MARKER={marker}\n")
            source.chmod(0o600)
            expected.write_text(marker_digest + "\n")
            expected.chmod(0o600)
            probe.write_text(
                textwrap.dedent(
                    """\
                    import hashlib
                    import json
                    import os
                    from pathlib import Path
                    import subprocess
                    import sys

                    expected = Path(sys.argv[1]).read_text().strip()
                    output = Path(sys.argv[2])
                    marker = os.environ.get("SOPS_PILOT_MARKER", "")
                    state = {
                        "ambient_absent": "SOPS_AMBIENT_SENTINEL" not in os.environ,
                        "marker_matches": hashlib.sha256(marker.encode()).hexdigest() == expected,
                    }
                    output.write_text(json.dumps(state, sort_keys=True))
                    if "--grandchild" not in sys.argv:
                        subprocess.run(
                            [sys.executable, __file__, sys.argv[1], sys.argv[3], "--grandchild"],
                            check=True,
                        )
                    """
                )
            )
            probe.chmod(0o700)

            encrypted_result = self.run_quietly(
                [
                    SOPS,
                    "encrypt",
                    "--age",
                    recipient,
                    "--input-type",
                    "dotenv",
                    "--output-type",
                    "dotenv",
                    "--output",
                    str(encrypted),
                    str(source),
                ]
            )
            source.unlink()
            self.assertFalse(source.exists())

            env = dict(os.environ)
            env["SOPS_AGE_KEY_FILE"] = str(identity)
            env["SOPS_AMBIENT_SENTINEL"] = ambient
            command = " ".join(
                shlex.quote(str(part))
                for part in (
                    sys.executable,
                    probe,
                    expected,
                    child_result,
                    grandchild_result,
                )
            )
            executed = self.run_quietly(
                [SOPS, "exec-env", "--pristine", str(encrypted), command],
                env=env,
            )

            combined_output = "".join(
                (
                    generated.stdout,
                    encrypted_result.stdout,
                    encrypted_result.stderr,
                    executed.stdout,
                    executed.stderr,
                )
            )
            identity_text = identity.read_text()
            for material in (marker, ambient, identity_text, recipient):
                self.assertFalse(
                    material in combined_output,
                    "sensitive fixture material reached command output",
                )
            self.assertFalse(executed.stdout + executed.stderr, "exec-env unexpectedly emitted output")

            expected_state = {"ambient_absent": True, "marker_matches": True}
            for result_path in (child_result, grandchild_result):
                self.assertEqual(json.loads(result_path.read_text()), expected_state)
                self.assertFalse(marker in result_path.read_text(), "probe result retained plaintext")

            self.assertFalse(source.exists())
            encrypted_text = encrypted.read_text()
            self.assertFalse(marker in encrypted_text, "ciphertext retained plaintext marker")
            self.assertFalse(identity_text in encrypted_text, "ciphertext retained the age identity")

        self.assertFalse(root.exists())


if __name__ == "__main__":
    unittest.main()
