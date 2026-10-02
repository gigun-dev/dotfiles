#!/usr/bin/env python3
"""Prevent false receipts, credential leaks, and lost acceptance evidence.

All HTTP and OS boot reads are fixtures; this suite never sends a heartbeat.
"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request

SPEC = importlib.util.spec_from_file_location(
    "host_heartbeat", Path(__file__).resolve().parents[1] / "host-heartbeat.py"
)
heartbeat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(heartbeat)


class BootAndReceiptTests(unittest.TestCase):
    def test_linux_boot_fixture(self):
        fixture = {
            "/proc/sys/kernel/random/boot_id": "linux-boot-uuid\n",
            "/proc/stat": "cpu 1 2 3\nbtime 1780000000\nprocesses 42\n",
        }
        self.assertEqual(
            heartbeat.boot_info("Linux", read=fixture.__getitem__),
            {"bootId": "linux-boot-uuid", "bootedAt": 1780000000000},
        )

    def test_darwin_boot_fixture(self):
        command = Mock(side_effect=[
            "DARWIN-BOOT-UUID", "{ sec = 1780000000, usec = 1234 } Sat May 30 00:00:00 2026"
        ])
        self.assertEqual(
            heartbeat.boot_info("Darwin", command=command),
            {"bootId": "DARWIN-BOOT-UUID", "bootedAt": 1780000000000},
        )
        self.assertEqual(command.call_args_list[0].args[0],
                         ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"])

    def test_missing_boot_time_fails_instead_of_inventing_evidence(self):
        with self.assertRaises(ValueError):
            heartbeat.boot_info("Linux", read=lambda path: "uuid" if path.endswith("boot_id") else "cpu 1")

    def test_independent_sources_reboot_and_unknown_evidence(self):
        first = heartbeat.observation("mac", {"bootId": "boot-a", "bootedAt": 1000}, 2000)
        vm = heartbeat.observation("mini-vm", {"bootId": "vm-boot", "bootedAt": 1500}, 2000)
        reboot = heartbeat.observation("mac", {"bootId": "boot-b", "bootedAt": 3000}, 4000)
        self.assertNotEqual(first["source"], vm["source"])
        self.assertNotEqual(first["bootId"], reboot["bootId"])
        self.assertEqual(first["lastSuccessAt"], 2000)
        self.assertEqual(set(first), {"source", "bootId", "bootedAt", "observedAt",
                                     "lastSuccessAt", "tunnel", "service", "functional"})
        self.assertTrue(all(first[key] == "unknown" for key in ("tunnel", "service", "functional")))

    def test_future_boot_and_invalid_identifiers_fail(self):
        for source, boot in [("bad/source", {"bootId": "boot", "bootedAt": 1}),
                             ("mac", {"bootId": "bad/boot", "bootedAt": 1}),
                             ("mac", {"bootId": "boot", "bootedAt": 2001})]:
            with self.assertRaises(ValueError):
                heartbeat.observation(source, boot, 2000)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.token = Path(self.directory.name) / "token"
        self.token.write_text("fixture-only-secret\n")
        self.token.chmod(0o600)
        self.endpoint = "https://hub.example/uptime/heartbeat"
        self.payload = heartbeat.observation("mini-vm", {"bootId": "boot-a", "bootedAt": 100000}, 125000)
        self.opener = Mock()
        self.build = patch.object(heartbeat.urllib.request, "build_opener", return_value=self.opener).start()
        self.addCleanup(patch.stopall)
        self.sleep = patch.object(heartbeat.time, "sleep").start()

    def response(self, status=202, body=b'{"status":"accepted"}'):
        response = Mock(status=status)
        response.read.return_value = body
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        return response

    def error(self, code):
        error = urllib.error.HTTPError(self.endpoint, code, "fixture", {}, io.BytesIO())
        self.addCleanup(error.close)
        return error

    def deliver(self):
        return heartbeat.send(self.endpoint, self.token, self.payload)

    def test_202_accepted_succeeds(self):
        self.opener.open.return_value = self.response()
        self.deliver()
        request = self.opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(json.loads(request.data), self.payload)
        self.assertEqual(request.get_header("Authorization"), "Bearer fixture-only-secret")
        self.opener.open.assert_called_once()

    def test_other_2xx_and_unaccepted_202_fail(self):
        for status, body in [(200, b'{"status":"accepted"}'),
                             (204, b''), (202, b'{"status":"rejected"}')]:
            with self.subTest(status=status, body=body):
                self.opener.open.reset_mock()
                self.opener.open.return_value = self.response(status, body)
                with self.assertRaises(ValueError):
                    self.deliver()
                self.opener.open.assert_called_once()
        self.sleep.assert_not_called()

    def test_non_object_202_response_is_a_safe_failure(self):
        # A malformed upstream body must not escape the generic service error path.
        for body in [b'null', b'[]', b'"accepted"']:
            with self.subTest(body=body):
                self.opener.open.reset_mock()
                self.opener.open.return_value = self.response(202, body)
                with self.assertRaises(ValueError):
                    self.deliver()
                self.opener.open.assert_called_once()
        self.sleep.assert_not_called()

    def test_401_does_not_retry(self):
        self.opener.open.side_effect = self.error(401)
        with self.assertRaisesRegex(ValueError, "HTTP 401"):
            self.deliver()
        self.opener.open.assert_called_once()
        self.sleep.assert_not_called()

    def test_503_retries_identical_receipt_and_stops_on_acceptance(self):
        self.opener.open.side_effect = [self.error(503), self.error(503), self.response()]
        self.deliver()
        bodies = [call.args[0].data for call in self.opener.open.call_args_list]
        self.assertEqual(len(bodies), 3)
        self.assertTrue(all(body == bodies[0] for body in bodies))
        self.assertEqual(json.loads(bodies[0]), self.payload)
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [1, 2])

    def test_outage_has_bounded_retry(self):
        self.opener.open.side_effect = urllib.error.URLError("fixture offline")
        with self.assertRaisesRegex(ValueError, "after 3 attempts"):
            self.deliver()
        self.assertEqual(self.opener.open.call_count, 3)

    def test_redirect_is_not_followed_or_retried(self):
        self.opener.open.side_effect = self.error(302)
        with self.assertRaisesRegex(ValueError, "HTTP 302"):
            self.deliver()
        self.opener.open.assert_called_once()
        self.build.assert_called_once_with(heartbeat.NoRedirect)
        request = urllib.request.Request(self.endpoint)
        self.assertIsNone(heartbeat.NoRedirect().redirect_request(
            request, None, 302, "redirect", {}, "https://other.example/uptime/heartbeat"
        ))
        self.sleep.assert_not_called()

    def test_public_secret_is_rejected_before_http(self):
        for mode in [0o644, 0o640, 0o604]:
            with self.subTest(mode=oct(mode)):
                self.token.chmod(mode)
                with self.assertRaisesRegex(ValueError, "private"):
                    self.deliver()
        self.opener.open.assert_not_called()

    def test_read_only_private_secret_is_accepted(self):
        self.token.chmod(0o400)
        self.opener.open.return_value = self.response()
        self.deliver()
        self.opener.open.assert_called_once()

    def test_invalid_endpoint_never_reads_or_transmits_secret(self):
        for endpoint in ["http://hub.example/uptime/heartbeat", "https://hub.example/other",
                         "https://user@hub.example/uptime/heartbeat", "https://hub.example/uptime/heartbeat?q=1"]:
            with self.subTest(endpoint=endpoint):
                with self.assertRaises(ValueError):
                    heartbeat.send(endpoint, "/does/not/exist", self.payload)
        self.opener.open.assert_not_called()
    def test_local_http_requires_literal_loopback_and_fixture_token(self):
        self.opener.open.return_value = self.response()
        self.token.write_text("local-fixture-only-secret")
        heartbeat.send("http://127.0.0.1:1234/uptime/heartbeat", self.token, self.payload, local_test=True)
        for endpoint in ["http://localhost:1234/uptime/heartbeat",
                         "http://example.com/uptime/heartbeat",
                         "https://example.com/uptime/heartbeat"]:
            with self.assertRaises(ValueError):
                heartbeat.send(endpoint, self.token, self.payload, local_test=True)
        self.token.write_text("real-secret")
        with self.assertRaises(ValueError):
            heartbeat.send("http://127.0.0.1:1234/uptime/heartbeat", self.token, self.payload, local_test=True)



class SnapshotTests(unittest.TestCase):
    def test_failed_delivery_preserves_previous_acceptance_and_new_boot_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "state.json"
            snapshot.write_text(json.dumps({"source": "mini-vm", "lastAcceptedAt": 50000}))
            argv = ["host-heartbeat", "--source", "mini-vm", "--snapshot", str(snapshot),
                    "--endpoint", "https://hub.example/uptime/heartbeat", "--token-file", "fixture"]
            with patch("sys.argv", argv), patch.object(heartbeat, "boot_info", return_value={
                "bootId": "new-boot", "bootedAt": 100000
            }), patch.object(heartbeat.time, "time_ns", return_value=125000000000), \
                    patch.object(heartbeat, "send", side_effect=ValueError("fixture unavailable")):
                with self.assertRaises(ValueError):
                    heartbeat.main()
            state = json.loads(snapshot.read_text())
            self.assertEqual(state["lastAcceptedAt"], 50000)
            self.assertEqual(state["observedAt"], 125000)
            self.assertEqual(state["bootId"], "new-boot")

    def test_success_updates_acceptance_only_after_send(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "state.json"
            argv = ["host-heartbeat", "--source", "mini-vm", "--snapshot", str(snapshot),
                    "--endpoint", "https://hub.example/uptime/heartbeat", "--token-file", "fixture"]
            def accepted(*args):
                self.assertIsNone(json.loads(snapshot.read_text())["lastAcceptedAt"])
            with patch("sys.argv", argv), patch.object(heartbeat, "boot_info", return_value={
                "bootId": "boot", "bootedAt": 100000
            }), patch.object(heartbeat.time, "time_ns", side_effect=[125000000000, 126000000000]), \
                    patch.object(heartbeat, "send", side_effect=accepted), \
                    contextlib.redirect_stdout(io.StringIO()):
                heartbeat.main()
            self.assertEqual(json.loads(snapshot.read_text())["lastAcceptedAt"], 126000)


if __name__ == "__main__":
    unittest.main()
