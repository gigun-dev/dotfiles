#!/usr/bin/env python3
"""Check fail-closed SOPS dotenv discovery and command quoting."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
FUNCTIONS = ROOT / "zsh" / "functions"
ZSH = os.environ.get("TEST_ZSH", "/bin/zsh")
SH = os.environ.get("TEST_SH", "/bin/sh")


class SopsEnvFunctionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sops-env-function-")
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sops_capture = self.root / "sops-argv"
        self.command_capture = self.root / "command-argv"

        self.write_executable(
            "git",
            r"""#!/bin/sh
printf '%s\n' "$SOPS_TEST_ROOT"
""",
        )
        self.write_executable(
            "sops",
            r"""#!/bin/sh
printf '%s\0' "$@" > "$SOPS_TEST_CAPTURE"
[ "$1" = exec-env ] && [ "$2" = --pristine ] || exit 2
env -i "$SOPS_TEST_SH" -c "$4"
""",
        )
        self.write_executable(
            "capture-command",
            r"""#!/bin/sh
output=$1
shift
printf '%s\0' "$@" > "$output"
""",
        )

    def tearDown(self):
        self.temporary.cleanup()

    def write_executable(self, name, body):
        path = self.bin / name
        path.write_text(textwrap.dedent(body))
        path.chmod(0o700)
        return path

    def environment(self):
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{env['PATH']}",
                "SOPS_TEST_CAPTURE": str(self.sops_capture),
                "SOPS_TEST_ROOT": str(self.root),
                "SOPS_TEST_SH": SH,
            }
        )
        return env

    def run_function(self, cwd, *arguments):
        script = "fpath=($1 $fpath); autoload -Uz sops-env; shift; sops-env \"$@\""
        return subprocess.run(
            [ZSH, "-f", "-c", script, "sops-env-test", str(FUNCTIONS), *arguments],
            cwd=cwd,
            env=self.environment(),
            capture_output=True,
            text=True,
            timeout=15,
        )

    @staticmethod
    def nul_arguments(path):
        data = path.read_bytes()
        return [part.decode() for part in data.split(b"\0") if part]

    def test_discovers_parent_ciphertext_and_preserves_literal_arguments(self):
        encrypted = self.root / "project.sops.env"
        encrypted.write_text("not-opened-by-the-helper\n")
        nested = self.root / "src" / "nested"
        nested.mkdir(parents=True)
        touched = self.root / "must-not-exist"
        arguments = [
            "space arg",
            "semi;colon",
            "single'quote",
            f"$(touch {touched})",
            "line1\nline2",
        ]

        result = self.run_function(
            nested,
            "--",
            "capture-command",
            str(self.command_capture),
            *arguments,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.nul_arguments(self.command_capture), arguments)
        sops_arguments = self.nul_arguments(self.sops_capture)
        self.assertEqual(sops_arguments[:3], ["exec-env", "--pristine", str(encrypted.resolve())])
        self.assertEqual(len(sops_arguments), 4)
        self.assertFalse(touched.exists(), "command substitution escaped its argument boundary")

    def test_multiple_candidates_fail_closed_without_a_tty(self):
        (self.root / "first.sops.env").write_text("fixture\n")
        (self.root / "second.sops.env").write_text("fixture\n")

        result = self.run_function(self.root, "--", "capture-command", str(self.command_capture))

        self.assertEqual(result.returncode, 2)
        self.assertIn("--file", result.stderr)
        self.assertFalse(self.sops_capture.exists())
        self.assertFalse(self.command_capture.exists())

    def test_plaintext_and_wrong_suffix_are_not_candidates(self):
        (self.root / ".env").write_text("plaintext-must-not-be-read\n")
        (self.root / "wrong.env.sops").write_text("fixture\n")

        result = self.run_function(self.root, "--", "capture-command", str(self.command_capture))

        self.assertEqual(result.returncode, 2)
        self.assertIn("no readable *.sops.env", result.stderr)
        self.assertFalse(self.sops_capture.exists())

    def test_explicit_file_handles_newline_without_reinterpreting_it(self):
        encrypted = self.root / "with\nnewline.sops.env"
        encrypted.write_text("fixture\n")

        result = self.run_function(
            self.root,
            "--file",
            str(encrypted),
            "--",
            "capture-command",
            str(self.command_capture),
            "literal",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.nul_arguments(self.sops_capture)[2], str(encrypted.resolve()))
        self.assertEqual(self.nul_arguments(self.command_capture), ["literal"])

    def test_invalid_explicit_file_never_invokes_sops(self):
        result = self.run_function(
            self.root,
            "--file",
            str(self.root / "missing.sops.env"),
            "--",
            "capture-command",
            str(self.command_capture),
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("readable regular file", result.stderr)
        self.assertFalse(self.sops_capture.exists())


if __name__ == "__main__":
    unittest.main()
