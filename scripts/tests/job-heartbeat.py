#!/usr/bin/env python3
"""Exercise job-success receipts and the opt-in sender without network access."""
import contextlib
from datetime import datetime, timezone
import importlib.util
import http.client
import io
import json
import os
from pathlib import Path
import ssl
import stat
import sys
import tempfile
import time
import unittest
from unittest import mock
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/job-heartbeat.py"
SPEC = importlib.util.spec_from_file_location("job_heartbeat", SCRIPT)
heartbeat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(heartbeat)
CLI_CODE = compile(SCRIPT.read_text(), str(SCRIPT), "exec")
ENDPOINT = "https://hub.example/heartbeat"
TOKEN = "fixture-bearer-secret-never-print"
DAY = 86_400_000
WEEK = 7 * DAY
EXPECTED_SCHEDULES = {
    "mini-vm-autoswitch": (14_400_000, DAY),
    "mini-vm-lock-fast": (3_600_000, DAY),
    "mini-vm-lock-slow": (266_400_000, WEEK),
}


def milliseconds(value):
    return int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp() * 1000)


def accepted(kind="accepted"):
    return json.dumps({"status": "accepted", "result": {"kind": kind}}).encode()


class Response:
    def __init__(self, status=202, body=None):
        self.status = self.code = status
        self.body = io.BytesIO(accepted() if body is None else body)
        self.read_sizes = []
        self.closed = False
        self.headers = {}

    def read(self, size=-1):
        self.read_sizes.append(size)
        return self.body.read(size)

    def getcode(self):
        return self.status

    def close(self):
        self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class Opener:
    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def open(self, request, timeout=None):
        self.calls.append((request, timeout))
        if not self.outcomes:
            raise AssertionError("Unexpected extra delivery attempt")
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class HeartbeatTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="job-heartbeat-")
        self.addCleanup(self.tmp.cleanup)
        self.token_file = Path(self.tmp.name) / "token"
        self.token_file.write_text(TOKEN + "\n")
        self.token_file.chmod(0o600)
        self.receipt = heartbeat.begin("mini-vm-autoswitch",
                                       now_ms=milliseconds("2026-10-04T04:00:01"),
                                       run_id="fixture-run-1")
        self.sleeps = []
        guard = mock.patch("socket.create_connection",
                           side_effect=AssertionError("Tests must never use the network"))
        guard.start()
        self.addCleanup(guard.stop)

    def deliver(self, opener, receipt=None, endpoint=ENDPOINT):
        return heartbeat.deliver(self.receipt if receipt is None else receipt,
                                 endpoint, str(self.token_file),
                                 opener=opener, sleep=self.sleeps.append)

    def run_cli(self, *args, opener=None, no_reads=False):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            stack.enter_context(mock.patch.object(sys, "argv", [str(SCRIPT), *args]))
            stack.enter_context(mock.patch("time.sleep"))
            # argparse localization probes the filesystem independently of the sender.
            stack.enter_context(mock.patch("argparse._", side_effect=lambda value: value))
            stack.enter_context(mock.patch("urllib.request.urlopen",
                                          side_effect=AssertionError("Unexpected urlopen")))
            if opener is None:
                stack.enter_context(mock.patch("urllib.request.build_opener",
                                              side_effect=AssertionError("Unexpected opener")))
            else:
                stack.enter_context(mock.patch("urllib.request.build_opener", return_value=opener))
            if no_reads:
                for target in ["builtins.open", "io.open", "os.open", "os.stat"]:
                    stack.enter_context(mock.patch(target, side_effect=AssertionError("Unexpected file access")))
            try:
                exec(CLI_CODE, {"__name__": "__main__", "__file__": str(SCRIPT)})
                status = 0
            except SystemExit as exc:
                status = 0 if exc.code is None else exc.code
        return status, stdout.getvalue(), stderr.getvalue()

    def assert_rejected(self, opener, **kwargs):
        try:
            self.assertFalse(self.deliver(opener, **kwargs))
        except (ValueError, OSError):
            pass

    def test_schedules_match_hub_proposed_utc_grid(self):
        self.assertEqual(heartbeat.SCHEDULES, EXPECTED_SCHEDULES)

    def test_daily_slots_before_at_and_after_anchor(self):
        for source, hour in [("mini-vm-autoswitch", "04"), ("mini-vm-lock-fast", "01")]:
            with self.subTest(source=source):
                anchor = milliseconds(f"2026-10-04T{hour}:00:00")
                for delta, expected in [(-1, anchor - DAY), (0, anchor), (1, anchor),
                                        (DAY - 1, anchor), (DAY, anchor + DAY)]:
                    receipt = heartbeat.begin(source, now_ms=anchor + delta, run_id="fixed-run")
                    self.assertEqual(receipt, {"source": source, "runId": "fixed-run",
                                               "scheduledFor": expected})

    def test_weekly_slots_before_at_and_after_sunday_anchor(self):
        anchor = milliseconds("2026-10-04T02:00:00")
        for delta, expected in [(-1, anchor - WEEK), (0, anchor), (1, anchor),
                                (WEEK - 1, anchor), (WEEK, anchor + WEEK)]:
            with self.subTest(delta=delta):
                receipt = heartbeat.begin("mini-vm-lock-slow", now_ms=anchor + delta,
                                           run_id="weekly-run")
                self.assertEqual(receipt["scheduledFor"], expected)

    @unittest.skipUnless(hasattr(time, "tzset"), "tzset is unavailable")
    def test_slot_calculation_is_independent_of_local_timezone_and_dst(self):
        try:
            for zone in ["UTC", "America/New_York", "Asia/Tokyo"]:
                with mock.patch.dict(os.environ, {"TZ": zone}):
                    time.tzset()
                    for instant in ["2026-03-08T04:00:00", "2026-11-01T04:00:00"]:
                        with self.subTest(zone=zone, instant=instant):
                            now = milliseconds(instant)
                            receipt = heartbeat.begin("mini-vm-autoswitch", now_ms=now,
                                                       run_id="dst-run")
                            self.assertEqual(receipt["scheduledFor"], now)
        finally:
            time.tzset()

    def test_begin_generates_unique_uuid_run_ids(self):
        first = heartbeat.begin("mini-vm-autoswitch")
        second = heartbeat.begin("mini-vm-autoswitch")
        self.assertNotEqual(first["runId"], second["runId"])
        self.assertEqual(uuid.UUID(first["runId"]).version, 4)
        anchor, period = heartbeat.SCHEDULES[first["source"]]
        self.assertEqual((first["scheduledFor"] - anchor) % period, 0)

    def test_begin_unknown_source_fails(self):
        with self.assertRaises((ValueError, KeyError)):
            heartbeat.begin("unknown-job", now_ms=0)

    def test_accepted_and_duplicate_are_success(self):
        for kind in ["accepted", "duplicate"]:
            with self.subTest(kind=kind):
                response = Response(body=accepted(kind))
                opener = Opener(response)
                self.assertTrue(self.deliver(opener))
                self.assertEqual(len(opener.calls), 1)
                request, timeout = opener.calls[0]
                self.assertEqual(timeout, 10)
                self.assertEqual(request.get_method(), "POST")
                self.assertEqual(request.full_url, ENDPOINT)
                self.assertEqual(request.get_header("Authorization"), "Bearer " + TOKEN)
                payload = json.loads(request.data)
                for key, value in self.receipt.items():
                    self.assertEqual(payload[key], value)
                self.assertNotIn(TOKEN, request.data.decode())
                self.assertTrue(response.closed)
                self.assertEqual(self.sleeps, [])

    def test_retries_preserve_run_id_and_slot_across_schedule_boundary(self):
        for source, (anchor, period) in EXPECTED_SCHEDULES.items():
            with self.subTest(source=source):
                now = anchor + 100 * period + period - 1
                receipt = heartbeat.begin(source, now_ms=now, run_id="stable-retry-run")
                opener = Opener(urllib.error.URLError("network failure"), Response(503), Response())
                with mock.patch("time.time", return_value=(now + 2 * period) / 1000):
                    self.assertTrue(self.deliver(opener, receipt=receipt))
                self.assertEqual(len(opener.calls), 3)
                bodies = [request.data for request, _ in opener.calls]
                self.assertEqual(bodies, [bodies[0]] * 3)
                payload = json.loads(bodies[0])
                self.assertEqual(payload["runId"], "stable-retry-run")
                self.assertEqual(payload["scheduledFor"], anchor + 100 * period)
                self.assertEqual(receipt["scheduledFor"], anchor + 100 * period)

    def test_transport_retries_are_bounded(self):
        for failure in [urllib.error.URLError("offline"), TimeoutError("timed out"),
                        ssl.SSLCertVerificationError("certificate rejected")]:
            with self.subTest(failure=type(failure).__name__):
                opener = Opener(failure, failure, failure)
                self.sleeps.clear()
                self.assertFalse(self.deliver(opener))
                self.assertEqual(len(opener.calls), 3)
                self.assertTrue(all(timeout == 10 for _, timeout in opener.calls))
                self.assertLessEqual(len(self.sleeps), 2)

    def test_transient_http_responses_retry(self):
        for status in [429, 500, 502, 503]:
            with self.subTest(status=status):
                opener = Opener(Response(status), Response())
                self.assertTrue(self.deliver(opener))
                self.assertEqual(len(opener.calls), 2)

    def test_transient_http_errors_retry(self):
        for status in [429, 500, 503]:
            with self.subTest(status=status):
                failure = urllib.error.HTTPError(ENDPOINT, status, "failed", {}, None)
                opener = Opener(failure, Response())
                self.assertTrue(self.deliver(opener))
                self.assertEqual(len(opener.calls), 2)

    def test_client_http_failures_do_not_retry(self):
        for status in [400, 401, 403, 404, 409, 422]:
            for raised in [False, True]:
                with self.subTest(status=status, raised=raised):
                    failure = (urllib.error.HTTPError(ENDPOINT, status, "failed", {}, None)
                               if raised else Response(status))
                    opener = Opener(failure)
                    self.sleeps.clear()
                    self.assertFalse(self.deliver(opener))
                    self.assertEqual(len(opener.calls), 1)
                    self.assertEqual(self.sleeps, [])

    def test_only_202_with_explicit_accepted_or_duplicate_acknowledges_delivery(self):
        cases = [
            (200, accepted()), (201, accepted()), (204, b""),
            (202, b""), (202, b"not-json"), (202, b"[]"), (202, b"null"),
            (202, b'"accepted"'), (202, b"{}"),
            (202, b'{"status":"rejected","result":{"kind":"accepted"}}'),
            (202, b'{"status":"accepted"}'),
            (202, b'{"status":"accepted","result":null}'),
            (202, b'{"status":"accepted","result":[]}'),
            (202, b'{"status":"accepted","result":{"kind":"ignored"}}'),
            (202, b'\xff'),
        ]
        for status, body in cases:
            with self.subTest(status=status, body=body):
                opener = Opener(*(Response(status, body) for _ in range(3)))
                self.assertFalse(self.deliver(opener))
                self.assertLessEqual(len(opener.calls), 3)

    def test_response_read_and_accepted_body_size_are_bounded(self):
        base = accepted()
        at_limit = Response(body=base + b" " * (4096 - len(base)))
        self.assertTrue(self.deliver(Opener(at_limit)))
        oversized = [Response(body=base + b" " * (4097 - len(base))) for _ in range(3)]
        self.assertFalse(self.deliver(Opener(*oversized)))
        for response in [at_limit, *oversized]:
            for size in response.read_sizes:
                self.assertGreater(size, 0)
                self.assertLessEqual(size, 4097)
            self.assertLessEqual(sum(response.read_sizes), 4097)

    def test_endpoint_rejection_happens_before_token_or_network_access(self):
        bad_endpoints = [
            "http://hub.example/heartbeat", "https://hub.example/uptime/heartbeat",
            "https://hub.example/heartbeat/", "https://hub.example/",
            "https://hub.example/heartbeat?token=secret", "https://hub.example/heartbeat#secret",
            "https://user:secret@hub.example/heartbeat", "https:///heartbeat",
            "file:///heartbeat", "https://hub.example/%68eartbeat",
        ]
        for endpoint in bad_endpoints:
            with self.subTest(endpoint=endpoint):
                opener = Opener()
                with mock.patch("builtins.open", side_effect=AssertionError("Read before endpoint validation")), \
                     mock.patch("io.open", side_effect=AssertionError("Read before endpoint validation")), \
                     mock.patch("os.open", side_effect=AssertionError("Read before endpoint validation")):
                    self.assert_rejected(opener, endpoint=endpoint)
                self.assertEqual(opener.calls, [])

    def test_invalid_receipts_never_send(self):
        cases = [{}, None, [], {**self.receipt, "source": "unknown-job"},
                 {**self.receipt, "source": []}, {**self.receipt, "runId": ""},
                 {**self.receipt, "runId": "run\nheader-injection"},
                 {**self.receipt, "runId": "a" * 129},
                 {**self.receipt, "scheduledFor": "yesterday"},
                 {**self.receipt, "scheduledFor": True},
                 {**self.receipt, "scheduledFor": -1},
                 {**self.receipt, "scheduledFor": self.receipt["scheduledFor"] + 1},
                 {**self.receipt, "extra": "unexpected-data"}]
        for receipt in cases:
            with self.subTest(receipt=receipt):
                opener = Opener()
                if receipt is None:
                    with self.assertRaises(ValueError):
                        heartbeat.deliver(None, ENDPOINT, str(self.token_file), opener=opener)
                else:
                    self.assert_rejected(opener, receipt=receipt)
                self.assertEqual(opener.calls, [])

    def test_token_must_be_private_regular_and_nonempty(self):
        for mode in [0o604, 0o640, 0o666]:
            with self.subTest(mode=oct(mode)):
                self.token_file.chmod(mode)
                opener = Opener()
                self.assert_rejected(opener)
                self.assertEqual(opener.calls, [])
        self.token_file.chmod(0o600)
        self.token_file.write_text(" \n")
        self.assert_rejected(Opener())
        self.token_file.unlink()
        self.assert_rejected(Opener())
        self.token_file.mkdir(mode=0o700)
        self.assert_rejected(Opener())

    def test_token_accepts_one_optional_line_ending_at_length_boundaries(self):
        for token in ["a" * 32, "b" * 256]:
            for ending in ["", "\n", "\r\n"]:
                with self.subTest(length=len(token), ending=repr(ending)):
                    self.token_file.write_bytes((token + ending).encode())
                    opener = Opener(Response())
                    self.assertTrue(self.deliver(opener))
                    self.assertEqual(opener.calls[0][0].get_header("Authorization"), "Bearer " + token)

    def test_oversized_multiline_or_whitespace_padded_tokens_are_rejected(self):
        for value in ["a" * 31, "a" * 257, "a" * 256 + "\n\n" + "b",
                      "a" * 32 + "\n" + "b" * 32,
                      " " + TOKEN, TOKEN + " ", TOKEN + "\n\n",
                      TOKEN + "\r\nInjected: header"]:
            with self.subTest(length=len(value)):
                self.token_file.write_bytes(value.encode())
                opener = Opener()
                self.assert_rejected(opener)
                self.assertEqual(opener.calls, [])

    @unittest.skipUnless(hasattr(os, "mkfifo") and hasattr(os, "O_NONBLOCK"),
                         "Nonblocking FIFO checks require POSIX")
    def test_fifo_token_is_rejected_without_blocking(self):
        self.token_file.unlink()
        os.mkfifo(self.token_file, mode=0o600)
        real_open = os.open

        def open_nonblocking(path, flags, *args, **kwargs):
            self.assertTrue(flags & os.O_NONBLOCK, "Opening a token FIFO must not hang a job")
            return real_open(path, flags, *args, **kwargs)

        opener = Opener()
        with mock.patch("os.open", side_effect=open_nonblocking):
            self.assert_rejected(opener)
        self.assertEqual(opener.calls, [])

    def test_symlinked_token_is_rejected(self):
        actual = self.token_file.with_name("actual-token")
        self.token_file.rename(actual)
        self.token_file.symlink_to(actual)
        opener = Opener()
        self.assert_rejected(opener)
        self.assertEqual(opener.calls, [])

    def test_token_owned_by_another_user_is_rejected(self):
        info = mock.Mock(st_mode=stat.S_IFREG | 0o600, st_uid=os.getuid() + 1)
        opener = Opener()
        with mock.patch("os.fstat", return_value=info):
            self.assert_rejected(opener)
        self.assertEqual(opener.calls, [])

    def test_default_transport_verifies_tls_and_refuses_redirects(self):
        observed = []

        def open_without_network(opener, request, timeout=None):
            observed.append(opener)
            self.assertEqual(timeout, 10)
            return Response()

        with mock.patch.object(urllib.request.OpenerDirector, "open", open_without_network):
            self.assertTrue(heartbeat.deliver(self.receipt, ENDPOINT, str(self.token_file),
                                              sleep=self.sleeps.append))
        self.assertEqual(len(observed), 1)
        handlers = observed[0].handlers
        https = [handler for handler in handlers if isinstance(handler, urllib.request.HTTPSHandler)]
        self.assertEqual(len(https), 1)
        context = https[0]._context
        if context is not None:
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
        redirects = [handler for handler in handlers
                     if isinstance(handler, urllib.request.HTTPRedirectHandler)]
        self.assertTrue(redirects)
        request = urllib.request.Request(ENDPOINT)
        for status in [301, 302, 303, 307, 308]:
            with self.subTest(status=status):
                try:
                    redirected = redirects[0].redirect_request(request, None, status, "redirect", {},
                                                               "https://other.example/heartbeat")
                except urllib.error.HTTPError:
                    continue
                self.assertIsNone(redirected)

    def test_disabled_send_is_zero_read_zero_network_even_with_invalid_configuration(self):
        for arguments in [[], ["--receipt", "{}"],
                          ["--receipt", "invalid-json-secret", "--endpoint", "not-a-url",
                           "--token-file", "/missing/token-secret"]]:
            with self.subTest(arguments=arguments):
                status, stdout, stderr = self.run_cli("send", *arguments, no_reads=True)
                self.assertEqual(status, 0, stderr)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, "")

    def test_begin_cli_emits_receipt_without_token_or_network_access(self):
        status, stdout, stderr = self.run_cli("begin", "--source", "mini-vm-lock-slow", no_reads=True)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(stderr, "")
        receipt = json.loads(stdout)
        self.assertEqual(set(receipt), {"source", "runId", "scheduledFor"})
        self.assertEqual(receipt["source"], "mini-vm-lock-slow")
        self.assertEqual(uuid.UUID(receipt["runId"]).version, 4)

    def test_enabled_cli_success_returns_zero(self):
        opener = Opener(Response())
        status, stdout, stderr = self.run_cli("send", "--enabled", "--receipt", json.dumps(self.receipt),
                                             "--endpoint", ENDPOINT, "--token-file", str(self.token_file),
                                             opener=opener)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(len(opener.calls), 1)
        self.assertNotIn(TOKEN, stdout + stderr)

    def test_enabled_cli_validation_failure_is_generic_and_redacted(self):
        for receipt, endpoint, token_file in [
            ("invalid-json-secret", ENDPOINT, str(self.token_file)),
            (json.dumps(self.receipt), "https://user:password-secret@hub.example/heartbeat", str(self.token_file)),
            (json.dumps(self.receipt), ENDPOINT, str(self.token_file.parent / "missing-path-secret")),
        ]:
            with self.subTest(receipt=receipt, endpoint=endpoint, token_file=token_file):
                status, stdout, stderr = self.run_cli("send", "--enabled", "--receipt", receipt,
                                                     "--endpoint", endpoint, "--token-file", token_file)
                self.assertEqual(status, 1)
                self.assertTrue(stderr.strip())
                for secret in [TOKEN, "invalid-json-secret", "password-secret", "missing-path-secret"]:
                    self.assertNotIn(secret, stdout + stderr)
                self.assertNotIn("Traceback", stdout + stderr)

    def test_http_protocol_errors_retry_with_unchanged_receipt(self):
        class BrokenBody(Response):
            def read(self, size=-1):
                raise http.client.IncompleteRead(b"provider-response-secret", 100)

        for failure in [http.client.BadStatusLine("provider-response-secret"), BrokenBody()]:
            with self.subTest(failure=type(failure).__name__):
                opener = Opener(failure, Response())
                status, stdout, stderr = self.run_cli(
                    "send", "--enabled", "--receipt", json.dumps(self.receipt),
                    "--endpoint", ENDPOINT, "--token-file", str(self.token_file), opener=opener)
                self.assertEqual(status, 0, stderr)
                self.assertEqual(len(opener.calls), 2)
                self.assertEqual(opener.calls[0][0].data, opener.calls[1][0].data)
                self.assertEqual(stdout + stderr, "")
                if isinstance(failure, BrokenBody):
                    self.assertTrue(failure.closed)

    def test_http_protocol_error_exhaustion_is_generic_and_redacted(self):
        class BrokenBody(Response):
            def read(self, size=-1):
                raise http.client.IncompleteRead(b"provider-response-secret", 100)

        for outcomes in [[http.client.BadStatusLine("provider-response-secret") for _ in range(3)],
                         [BrokenBody() for _ in range(3)]]:
            opener = Opener(*outcomes)
            status, stdout, stderr = self.run_cli(
                "send", "--enabled", "--receipt", json.dumps(self.receipt),
                "--endpoint", ENDPOINT, "--token-file", str(self.token_file), opener=opener)
            self.assertEqual(status, 1)
            self.assertEqual(len(opener.calls), 3)
            self.assertEqual(stdout, "")
            self.assertEqual(stderr, "job-heartbeat: receipt preparation or delivery failed\n")
            for secret in [TOKEN, "provider-response-secret", "Traceback"]:
                self.assertNotIn(secret, stdout + stderr)
            self.assertEqual(len({call[0].data for call in opener.calls}), 1)
            for outcome in outcomes:
                if isinstance(outcome, BrokenBody):
                    self.assertTrue(outcome.closed)

    def test_enabled_cli_delivery_exhaustion_is_generic_and_redacted(self):
        for outcomes in [[urllib.error.URLError(TOKEN)] * 3,
                         [Response(503, TOKEN.encode()) for _ in range(3)]]:
            opener = Opener(*outcomes)
            status, stdout, stderr = self.run_cli("send", "--enabled", "--receipt", json.dumps(self.receipt),
                                                 "--endpoint", ENDPOINT, "--token-file", str(self.token_file),
                                                 opener=opener)
            self.assertEqual(status, 1)
            self.assertTrue(stderr.strip())
            self.assertNotIn(TOKEN, stdout + stderr)
            self.assertNotIn("Traceback", stdout + stderr)
            self.assertEqual(len(opener.calls), 3)


if __name__ == "__main__":
    unittest.main()
