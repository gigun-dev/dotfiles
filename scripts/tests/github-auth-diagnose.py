#!/usr/bin/env python3
"""Synthetic GitHub auth diagnostics: never contact GitHub or read credentials."""

import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "github_auth_diagnose",
    Path(__file__).parents[1] / "github-auth-diagnose.py",
)
diagnose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnose)


def completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(["gh"], returncode, stdout, stderr)


class DiagnoseTests(unittest.TestCase):
    def run_diagnosis(self, *, seatbelt="allowed", online=None, local=None, status=None, local_only=False):
        responses = [local or completed()]
        if local is not None and local.returncode != 0:
            responses.append(status or completed(1))
        if online is not None:
            responses.append(online)
        with (
            mock.patch.object(diagnose.platform, "system", return_value="Darwin"),
            mock.patch.object(diagnose, "apple_seatbelt_network_policy", return_value=seatbelt),
            mock.patch.object(diagnose.shutil, "which", return_value="/fixture/gh"),
            mock.patch.object(diagnose, "run_gh", side_effect=responses) as run,
        ):
            value, code = diagnose.diagnose(local_only=local_only)
        return value, code, run

    def test_seatbelt_denial_stops_before_online_auth_claim(self):
        value, code, run = self.run_diagnosis(seatbelt="denied")
        self.assertEqual(code, 3)
        self.assertEqual(value["sandboxMechanism"], "apple-seatbelt")
        self.assertEqual(value["onlineProbe"], "blocked-by-apple-seatbelt")
        self.assertEqual(value["assessment"], "context-limited-network-denial")
        self.assertEqual(run.call_count, 1)

    def test_local_only_never_validates_or_rejects_token(self):
        value, code, run = self.run_diagnosis(local_only=True)
        self.assertEqual(code, 3)
        self.assertEqual(value["assessment"], "local-state-not-online-validation")
        self.assertEqual(run.call_count, 1)

    def test_account_config_and_token_store_readability_are_separate(self):
        value, code, run = self.run_diagnosis(
            seatbelt="denied",
            local=completed(1),
            status=completed(1, stderr="Active account: true\nThe token is invalid"),
        )
        self.assertEqual(code, 3)
        self.assertEqual(value["localCredential"], "account-configured-token-unreadable")
        self.assertEqual(value["assessment"], "context-limited-network-denial")
        self.assertEqual(run.call_count, 2)

    def test_success_is_the_only_accepted_result(self):
        value, code, _ = self.run_diagnosis(online=completed())
        self.assertEqual(code, 0)
        self.assertEqual(value["sandboxMechanism"], "not-detected-for-network")
        self.assertEqual(value["httpStatus"], 200)
        self.assertEqual(value["assessment"], "credential-accepted")

    def test_only_http_401_rejects_the_credential(self):
        value, code, _ = self.run_diagnosis(online=completed(1, stderr="gh: bad credentials (HTTP 401)"))
        self.assertEqual(code, 1)
        self.assertEqual(value["assessment"], "credential-rejected")

    def test_http_403_is_not_token_invalid(self):
        value, code, _ = self.run_diagnosis(online=completed(1, stderr="gh: forbidden (HTTP 403)"))
        self.assertEqual(code, 2)
        self.assertEqual(value["assessment"], "forbidden-not-token-invalid")

    def test_network_failure_without_http_is_indeterminate(self):
        value, code, _ = self.run_diagnosis(online=completed(1, stderr="connect: operation not permitted"))
        self.assertEqual(code, 3)
        self.assertIsNone(value["httpStatus"])
        self.assertEqual(value["assessment"], "transport-or-client-indeterminate")

    def test_raw_gh_output_is_never_returned(self):
        value, _, _ = self.run_diagnosis(online=completed(1, stderr="SECRET_TOKEN\nHTTP 401"))
        self.assertNotIn("SECRET", json.dumps(value))


if __name__ == "__main__":
    unittest.main()
