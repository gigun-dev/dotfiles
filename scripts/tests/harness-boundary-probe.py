#!/usr/bin/env python3
"""Synthetic harness-boundary probes: never contact a network endpoint."""

import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "harness_boundary_probe",
    Path(__file__).parents[1] / "harness-boundary-probe.py",
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FileProbeTests(unittest.TestCase):
    def test_fixed_canary_is_read_back_and_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(probe.probe_write(Path(directory)), "succeeded")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_permission_denial_is_classified_without_raw_error(self):
        with mock.patch.object(probe.tempfile, "NamedTemporaryFile", side_effect=PermissionError("SECRET")):
            self.assertEqual(probe.probe_write(Path("/unused")), "permission-denied")

    def test_cleanup_failure_is_not_reported_as_success(self):
        path = mock.Mock()
        path.read_bytes.return_value = probe.FIXTURE
        path.unlink.side_effect = PermissionError("SECRET")
        target = mock.MagicMock()
        target.name = "/fixture/canary"
        with (
            mock.patch.object(probe.tempfile, "NamedTemporaryFile", return_value=target),
            mock.patch.object(probe, "Path", return_value=path),
        ):
            self.assertEqual(probe.probe_write("/fixture"), "cleanup-failed")


class ProcessProbeTests(unittest.TestCase):
    def test_only_the_current_process_is_requested(self):
        completed = subprocess.CompletedProcess(
            ["ps"], 0, f"{os.getpid()}\n", ""
        )
        with mock.patch.object(probe.subprocess, "run", return_value=completed) as run:
            self.assertEqual(probe.probe_self_process(), "succeeded")
        arguments = run.call_args.args[0]
        self.assertEqual(arguments, ["ps", "-p", str(os.getpid()), "-o", "pid="])

    def test_process_permission_error_is_value_free(self):
        completed = subprocess.CompletedProcess(
            ["ps"], 1, "", "ps: operation not permitted: SECRET"
        )
        with mock.patch.object(probe.subprocess, "run", return_value=completed):
            self.assertEqual(probe.probe_self_process(), "permission-denied")


class NetworkProbeTests(unittest.TestCase):
    def test_network_is_opt_in(self):
        with mock.patch.object(probe.socket, "getaddrinfo") as dns:
            result = probe.probe_network(False)
        self.assertEqual(result, {"dns": "not-run", "https": "not-run", "httpStatus": None})
        dns.assert_not_called()

    def test_dns_and_https_are_independent_results(self):
        connection = mock.MagicMock()
        connection.getresponse.return_value.status = 204
        with (
            mock.patch.object(probe.socket, "getaddrinfo", return_value=[("fixture",)]),
            mock.patch.object(probe.http.client, "HTTPSConnection", return_value=connection),
        ):
            result = probe.probe_network(True)
        self.assertEqual(result, {"dns": "succeeded", "https": "http-response", "httpStatus": 204})
        connection.request.assert_called_once_with("HEAD", "/")

    def test_dns_failure_never_claims_a_credential_failure(self):
        with mock.patch.object(probe.socket, "getaddrinfo", side_effect=socket.gaierror("SECRET")):
            result = probe.probe_network(True)
        self.assertEqual(result, {"dns": "unavailable", "https": "not-run", "httpStatus": None})
        self.assertNotIn("SECRET", json.dumps(result))

    def test_https_permission_denial_keeps_dns_success(self):
        connection = mock.MagicMock()
        connection.request.side_effect = PermissionError("SECRET")
        with (
            mock.patch.object(probe.socket, "getaddrinfo", return_value=[("fixture",)]),
            mock.patch.object(probe.http.client, "HTTPSConnection", return_value=connection),
        ):
            result = probe.probe_network(True)
        self.assertEqual(result, {"dns": "succeeded", "https": "permission-denied", "httpStatus": None})


class ObservationTests(unittest.TestCase):
    def test_all_probes_run_after_a_denial_and_no_auth_claim_is_made(self):
        with (
            mock.patch.object(probe, "probe_source_read", return_value="permission-denied") as source,
            mock.patch.object(probe, "probe_write", side_effect=["permission-denied", "succeeded"]) as write,
            mock.patch.object(probe, "probe_self_process", return_value="permission-denied") as process,
            mock.patch.object(probe, "apple_seatbelt_network_policy", return_value="denied") as seatbelt,
            mock.patch.object(probe, "probe_network", return_value={"dns": "not-run", "https": "not-run", "httpStatus": None}) as network,
            mock.patch.object(probe.platform, "system", return_value="Darwin"),
        ):
            value = probe.observe("pro", "t3-code", "codex")
        source.assert_called_once()
        self.assertEqual(write.call_count, 2)
        process.assert_called_once()
        seatbelt.assert_called_once()
        network.assert_called_once_with(False)
        self.assertEqual(value["assessment"], "boundary-observation-only-not-credential-validation")
        self.assertNotIn("credential-rejected", json.dumps(value))


class CliTests(unittest.TestCase):
    arguments = ["--host", "pro", "--harness", "t3-code", "--provider", "codex"]

    def run_cli(self, arguments):
        return subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(Path(probe.__file__)), *arguments],
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_invalid_arguments_do_not_echo_input(self):
        result = self.run_cli([*self.arguments, "syntheticsecret\nPRIVATE"])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "invalid harness probe arguments\n")


if __name__ == "__main__":
    unittest.main()
