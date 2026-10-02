#!/usr/bin/env python3
"""秘密は fake token のみ。routing と私有 staging の fail-closed を検証する。"""

import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-host-heartbeat-registration.py"
SPEC = importlib.util.spec_from_file_location("registration", SCRIPT)
registration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registration)
REFERENCE = {"source": "autoswitch", "ownerId": "owner-1", "destinations": ["bark-personal"], "token": "R" * 40, "monitorControl": True}
TOKENS = {"mac": "M" * 40, "mini-vm": "V" * 40}


class RoutingTests(unittest.TestCase):
    def test_existing_route_is_preserved_without_management_authority(self):
        existing = [copy.deepcopy(REFERENCE)]
        result = registration.prepare(existing, "autoswitch", TOKENS)
        self.assertEqual(existing, [REFERENCE])
        self.assertEqual(result[0], REFERENCE)
        for entry in result[1:]:
            self.assertEqual(entry["ownerId"], REFERENCE["ownerId"])
            self.assertEqual(entry["destinations"], REFERENCE["destinations"])
            self.assertNotIn("monitorControl", entry)
            self.assertEqual(set(entry), {"source", "ownerId", "destinations", "token"})

    def test_other_owner_cannot_be_overwritten(self):
        other = {**REFERENCE, "source": "mac", "ownerId": "other-owner", "token": "O" * 40}
        with self.assertRaises(ValueError):
            registration.prepare([REFERENCE, other], "autoswitch", TOKENS)

    def test_reference_must_be_unique(self):
        for entries in [[], [REFERENCE, {**REFERENCE, "token": "D" * 40}]]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                registration.prepare(entries, "autoswitch", TOKENS)

    def test_invalid_routing_is_rejected_before_preparation(self):
        bad_fields = [
            {"ownerId": ""}, {"ownerId": "owner with spaces"},
            {"destinations": []}, {"destinations": "bark-personal"},
            {"destinations": ["bark", "bark"]}, {"destinations": ["bad destination"]},
            {"destinations": [str(index) for index in range(9)]},
            {"monitorControl": "true"},
        ]
        for fields in bad_fields:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                registration.prepare([{**REFERENCE, **fields}], "autoswitch", TOKENS)

    def test_invalid_or_duplicate_tokens_are_rejected(self):
        for tokens in [{"mac": "short", "mini-vm": "V" * 40}, {"mac": "M" * 40, "mini-vm": "M" * 40}, {"mac": "R" * 40, "mini-vm": "V" * 40}]:
            with self.subTest(tokens=tokens), self.assertRaises(ValueError):
                registration.prepare([REFERENCE], "autoswitch", tokens)

    def test_token_alphabet_and_length_match_hub_contract(self):
        for token in ["M" * 257, "M" * 39 + "/", "M" * 39 + "!", "M" * 39 + "あ", "M" * 39 + "\n"]:
            with self.subTest(token=token), self.assertRaises(ValueError):
                registration.prepare([REFERENCE], "autoswitch", {**TOKENS, "mac": token})
        allowed = "m_" + "-" * 30
        result = registration.prepare([REFERENCE], "autoswitch", {**TOKENS, "mac": allowed})
        self.assertEqual(next(entry["token"] for entry in result if entry["source"] == "mac"), allowed)

    def test_registration_cannot_exceed_hub_source_limit(self):
        existing = [REFERENCE] + [
            {**REFERENCE, "source": f"source-{index}", "token": f"token{index:035d}"}
            for index in range(30)
        ]
        with self.assertRaises(ValueError):
            registration.prepare(existing, "autoswitch", TOKENS)

    def test_unrelated_invalid_routing_is_not_carried_into_output(self):
        invalid = {**REFERENCE, "source": "other", "token": "O" * 40, "destinations": []}
        with self.assertRaises(ValueError):
            registration.prepare([REFERENCE, invalid], "autoswitch", TOKENS)


class PrivateStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.directory.chmod(0o700)
        self.credentials = self.directory / "credentials.json"
        self.credentials.write_text(json.dumps([REFERENCE]))
        self.credentials.chmod(0o600)
        self.identity = self.directory / "fake-identity"
        self.identity.write_text("FAKE_IDENTITY")
        self.identity.chmod(0o600)
        self.output = self.directory / "candidate.json"
        self.argv = [str(SCRIPT), "--credentials-file", str(self.credentials), "--reference-source", "autoswitch", "--identity", str(self.identity), "--output", str(self.output)]
        self.decrypt = Mock(side_effect=[subprocess.CompletedProcess([], 0, b"M" * 40, b"SECRET_STDERR"), subprocess.CompletedProcess([], 0, b"V" * 40, b"SECRET_STDERR")])

    def invoke(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", self.argv), patch.object(subprocess, "run", self.decrypt), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            registration.main()
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")

    def test_private_output_and_no_stdout(self):
        self.invoke()
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)
        prepared = json.loads(self.output.read_text())
        self.assertEqual({entry["source"] for entry in prepared}, {"autoswitch", "mac", "mini-vm"})
        self.assertEqual(self.decrypt.call_count, 2)
        for call in self.decrypt.call_args_list:
            self.assertEqual(call.kwargs, {"check": True, "capture_output": True, "timeout": 10})

    def test_shared_credential_input_is_rejected_before_decryption(self):
        self.credentials.chmod(0o644)
        with self.assertRaises(ValueError):
            self.invoke()
        self.decrypt.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_shared_identity_is_rejected_before_decryption(self):
        self.identity.chmod(0o644)
        with self.assertRaises(ValueError):
            self.invoke()
        self.decrypt.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_non_regular_input_is_rejected(self):
        with self.assertRaises(ValueError):
            registration.private_file(self.directory)

    def test_shared_output_directory_is_rejected_before_decryption(self):
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError):
            self.invoke()
        self.decrypt.assert_not_called()

    def test_existing_output_is_never_overwritten(self):
        self.output.write_text("keep existing")
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertEqual(self.output.read_text(), "keep existing")
        self.decrypt.assert_not_called()

    def test_dangling_output_symlink_is_rejected(self):
        self.output.symlink_to(self.directory / "missing")
        with self.assertRaises(ValueError):
            self.invoke()
        self.assertTrue(self.output.is_symlink())
        self.decrypt.assert_not_called()

    def test_concurrent_output_creation_is_not_replaced(self):
        def competing_link(source, destination):
            Path(destination).write_text("other invocation")
            raise FileExistsError("exists")
        with patch.object(registration.os, "link", competing_link), self.assertRaises(FileExistsError):
            self.invoke()
        self.assertEqual(self.output.read_text(), "other invocation")
        self.assertEqual({path.name for path in self.directory.iterdir()}, {"credentials.json", "fake-identity", "candidate.json"})

    def test_decryption_exception_does_not_disclose_secrets(self):
        self.decrypt.side_effect = subprocess.CalledProcessError(1, "SECRET_COMMAND", output=b"SECRET_OUT", stderr=b"SECRET_ERR")
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(sys, "argv", self.argv), patch.object(subprocess, "run", self.decrypt), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as error:
            runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertNotIn("SECRET", str(error.exception))
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
