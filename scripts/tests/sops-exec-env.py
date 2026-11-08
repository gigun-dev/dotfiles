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
