#!/usr/bin/env python3
"""Exercise UTC receipts and the opt-in curl sender without network access."""
import contextlib
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
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
POST_ARGS = [
    "--disable", "--silent", "--show-error", "--globoff", "--proto", "=https", "--noproxy", "*",
    "--connect-timeout", "10", "--max-time", "10", "--max-filesize", "4096",
    "--write-out", "\n%{http_code}", "--config", "-",
]
GENERIC_ERROR = "job-heartbeat: receipt preparation or delivery failed\n"


def milliseconds(value):
    return int(datetime.fromisoformat(value).replace(tzinfo=timezone.utc).timestamp() * 1000)


def accepted(kind="accepted"):
    return json.dumps({"status": "accepted", "result": {"kind": kind}}).encode()


def response(status=202, body=None, returncode=0, stderr=b""):
    body = accepted() if body is None else body
    return subprocess.CompletedProcess([], returncode, body + f"\n{status:03d}".encode(), stderr)


def version(value="8.4.0", returncode=0):
    return subprocess.CompletedProcess([], returncode,
                                       f"curl {value} (fixture-platform) libcurl/{value}\n".encode(), b"")


class Runner:
    def __init__(self, *outcomes, version_result=None):
        self.outcomes = list(outcomes)
        self.version_result = version() if version_result is None else version_result
        self.calls = []

    @property
    def posts(self):
        return [(args, kwargs) for args, kwargs in self.calls if "--version" not in args]

    def __call__(self, args, **kwargs):
        self.calls.append((list(args), kwargs.copy()))
        if "--version" in args:
            outcome = self.version_result
        else:
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
        for target in ["socket.create_connection", "subprocess.run", "subprocess.Popen"]:
            guard = mock.patch(target, side_effect=AssertionError("No real network or subprocess in tests"))
            guard.start()
            self.addCleanup(guard.stop)

    def deliver(self, runner, receipt=None, endpoint=ENDPOINT, curl="curl"):
        return heartbeat.deliver(self.receipt if receipt is None else receipt,
                                 endpoint, str(self.token_file), runner=runner,
                                 sleep=self.sleeps.append, curl=curl)

    def run_cli(self, *args, runner=None, no_reads=False):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            stack.enter_context(mock.patch.object(sys, "argv", [str(SCRIPT), *args]))
            stack.enter_context(mock.patch("time.sleep"))
            # argparse localization probes the filesystem independently of the sender.
            stack.enter_context(mock.patch("argparse._", side_effect=lambda value: value))
            if runner is not None:
                stack.enter_context(mock.patch("subprocess.run", side_effect=runner))
            if no_reads:
                for target in ["builtins.open", "io.open", "os.open", "os.stat", "os.lstat"]:
                    stack.enter_context(mock.patch(target, side_effect=AssertionError("Unexpected file access")))
            try:
                exec(CLI_CODE, {"__name__": "__main__", "__file__": str(SCRIPT)})
                status = 0
            except SystemExit as exc:
                status = 0 if exc.code is None else exc.code
        return status, stdout.getvalue(), stderr.getvalue()

    def assert_rejected(self, runner, **kwargs):
        try:
            self.assertFalse(self.deliver(runner, **kwargs))
        except (ValueError, OSError):
            pass

    def config(self, post):
        args, kwargs = post
        self.assertEqual(args[1:], POST_ARGS)
        self.assertEqual(set(kwargs), {"input", "capture_output", "timeout", "check"})
        self.assertIs(kwargs["capture_output"], True)
        self.assertEqual(kwargs["timeout"], 15)
        self.assertIs(kwargs["check"], False)
        self.assertIsInstance(kwargs["input"], bytes)
        config = {}
        for line in kwargs["input"].decode("ascii").splitlines():
            match = re.fullmatch(r'([a-z-]+)\s*=\s*(".*")', line)
            self.assertIsNotNone(match, "Curl config values must be quoted")
            key, value = match.groups()
            config.setdefault(key, []).append(json.loads(value))
        self.assertEqual(set(config), {"url", "header", "data-binary"})
        self.assertEqual(len(config["url"]), 1)
        self.assertEqual(len(config["header"]), 2)
        self.assertEqual(len(config["data-binary"]), 1)
        return config

    def test_nix_wrapper_pins_curl_and_trust_store_while_sends_stay_disabled(self):
        module = (ROOT / "nix/modules/nixos/mini-vm.nix").read_text()
        match = re.search(r"jobHeartbeat = pkgs\.writeShellScript \"dotfiles-job-heartbeat\" ''(.*?)\n  '';",
                          module, re.DOTALL)
        self.assertIsNotNone(match)
        wrapper = match.group(1)
        self.assertIn("--curl-path ${pkgs.curl}/bin/curl", wrapper)
        self.assertIn("export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt", wrapper)
        self.assertIn('export CURL_CA_BUNDLE="$SSL_CERT_FILE"', wrapper)
        self.assertLess(wrapper.index("export SSL_CERT_FILE="), wrapper.index("export CURL_CA_BUNDLE="))
        self.assertNotIn("--enabled", wrapper)
        sends = re.findall(r"\$\{jobHeartbeat\} send[^\n]*", module)
        self.assertTrue(sends)
        self.assertTrue(all("--enabled" not in send for send in sends))

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

    def test_accepted_and_duplicate_use_safe_curl_with_stdin_only_secrets(self):
        for kind in ["accepted", "duplicate"]:
            with self.subTest(kind=kind):
                runner = Runner(response(body=accepted(kind)))
                self.assertTrue(self.deliver(runner))
                self.assertEqual(runner.calls[0], (["curl", "--disable", "--version"],
                                                  {"capture_output": True, "timeout": 5, "check": False}))
                self.assertEqual(len(runner.calls), 2)
                config = self.config(runner.posts[0])
                self.assertEqual(config["url"], [ENDPOINT])
                self.assertCountEqual(config["header"], ["Authorization: Bearer " + TOKEN,
                                                       "Content-Type: application/json"])
                self.assertEqual(json.loads(config["data-binary"][0]), self.receipt)
                for args, kwargs in runner.calls:
                    for secret in [TOKEN, ENDPOINT, self.receipt["runId"], str(self.token_file)]:
                        self.assertNotIn(secret, repr(args))
                        self.assertNotIn(secret, repr({key: value for key, value in kwargs.items()
                                                     if key != "input"}))
                self.assertNotIn(TOKEN, config["data-binary"][0])
                self.assertEqual(self.sleeps, [])

    def test_url_braces_are_passed_literally_with_curl_globbing_disabled(self):
        endpoint = "https://{hub,other}.example/heartbeat"
        runner = Runner(response())
        self.assertTrue(self.deliver(runner, endpoint=endpoint))
        self.assertEqual(len(runner.posts), 1)
        args, _ = runner.posts[0]
        self.assertIn("--globoff", args)
        self.assertEqual(self.config(runner.posts[0])["url"], [endpoint])
        self.assertNotIn(endpoint, args)

    def test_default_runner_is_resolved_at_call_time(self):
        runner = Runner(response())
        with mock.patch("subprocess.run", side_effect=runner):
            self.assertTrue(heartbeat.deliver(self.receipt, ENDPOINT, str(self.token_file),
                                              sleep=self.sleeps.append))
        self.assertEqual(len(runner.calls), 2)
        self.config(runner.posts[0])

    def test_pinned_curl_path_is_used_for_version_and_delivery(self):
        curl = "/nix/store/fixture-curl-8.4.0/bin/curl"
        runner = Runner(response())
        self.assertTrue(self.deliver(runner, curl=curl))
        self.assertTrue(all(args[0] == curl for args, _ in runner.calls))

    def test_supported_curl_versions_are_accepted(self):
        for value in ["8.4.0", "8.4.1", "8.10.0", "9.0.0"]:
            with self.subTest(version=value):
                runner = Runner(response(), version_result=version(value))
                self.assertTrue(self.deliver(runner))
                self.assertEqual(len(runner.posts), 1)

    def test_old_malformed_or_failed_version_checks_never_post(self):
        cases = [version("7.88.1"), version("8.3.0"), version("8.3.99"),
                 version("not-a-version"), version("8.4"), version(returncode=1),
                 subprocess.CompletedProcess([], 0, b"not curl 8.4.0\n", b""),
                 subprocess.CompletedProcess([], 0, b"", b""),
                 subprocess.TimeoutExpired(["curl", "--version"], 5),
                 FileNotFoundError("missing-curl-secret")]
        for outcome in cases:
            with self.subTest(outcome=outcome):
                runner = Runner(version_result=outcome)
                self.assert_rejected(runner)
                self.assertEqual(len(runner.calls), 1)
                self.assertEqual(runner.posts, [])
                self.assertEqual(self.sleeps, [])

    def test_retries_preserve_identity_and_config_across_schedule_boundary(self):
        for source, (anchor, period) in EXPECTED_SCHEDULES.items():
            with self.subTest(source=source):
                self.sleeps.clear()
                now = anchor + 100 * period + period - 1
                receipt = heartbeat.begin(source, now_ms=now, run_id="stable-retry-run")
                original = receipt.copy()
                runner = Runner(response(0, returncode=56), response(503), response())
                with mock.patch("time.time", return_value=(now + 2 * period) / 1000), \
                     mock.patch("time.time_ns", return_value=(now + 2 * period) * 1_000_000):
                    self.assertTrue(self.deliver(runner, receipt=receipt))
                self.assertEqual(len(runner.calls), 4)
                inputs = [kwargs["input"] for _, kwargs in runner.posts]
                self.assertEqual(inputs, [inputs[0]] * 3)
                payload = json.loads(self.config(runner.posts[0])["data-binary"][0])
                self.assertEqual(payload, original)
                self.assertEqual(receipt, original)
                self.assertEqual(self.sleeps, [1, 2])

    def test_transient_curl_errors_retry_up_to_three_attempts(self):
        for code in [5, 6, 7, 18, 28, 52, 55, 56, 92]:
            with self.subTest(code=code):
                failure = response(0, returncode=code, stderr=b"provider-response-secret")
                runner = Runner(failure, failure, failure)
                self.sleeps.clear()
                self.assertFalse(self.deliver(runner))
                self.assertEqual(len(runner.posts), 3)
                self.assertEqual(self.sleeps, [1, 2])
                for post in runner.posts:
                    self.config(post)

    def test_subprocess_timeouts_retry_and_can_recover(self):
        failure = subprocess.TimeoutExpired(["curl"], 15, output=b"response-secret", stderr=TOKEN.encode())
        for outcomes, expected, delays in [([failure, response()], True, [1]),
                                           ([failure, failure, failure], False, [1, 2])]:
            with self.subTest(expected=expected):
                self.sleeps.clear()
                runner = Runner(*outcomes)
                self.assertEqual(self.deliver(runner), expected)
                self.assertEqual(len(runner.posts), len(outcomes))
                self.assertEqual(self.sleeps, delays)

    def test_tls_oversize_and_other_permanent_curl_errors_never_retry(self):
        for code in [1, 2, 3, 22, 23, 26, 35, 51, 58, 60, 63, 77, 80, 82, 83, 90, 91, 99]:
            with self.subTest(code=code):
                runner = Runner(response(503, returncode=code))
                self.assertFalse(self.deliver(runner))
                self.assertEqual(len(runner.posts), 1)
                self.assertEqual(self.sleeps, [])

    def test_transient_http_responses_retry_and_exhaust(self):
        for status in [429, 500, 502, 503, 599]:
            for recover in [True, False]:
                with self.subTest(status=status, recover=recover):
                    self.sleeps.clear()
                    outcomes = [response(status), response()] if recover else [response(status)] * 3
                    runner = Runner(*outcomes)
                    self.assertEqual(self.deliver(runner), recover)
                    self.assertEqual(len(runner.posts), len(outcomes))
                    self.assertEqual(self.sleeps, [1] if recover else [1, 2])

    def test_non_202_nontransient_statuses_stop_without_following_redirects(self):
        for status in [100, 200, 201, 204, 206, 301, 302, 303, 307, 308,
                       400, 401, 403, 404, 409, 422, 499, 600]:
            with self.subTest(status=status):
                runner = Runner(response(status))
                self.assertFalse(self.deliver(runner))
                self.assertEqual(len(runner.posts), 1)
                self.config(runner.posts[0])
                self.assertEqual(self.sleeps, [])

    def test_202_requires_explicit_valid_json_acknowledgment_without_retry(self):
        for body in [b"", b"not-json", b"[]", b"null", b'"accepted"', b"{}", b'\xff',
                     b'{"status":"rejected","result":{"kind":"accepted"}}',
                     b'{"status":"accepted"}', b'{"status":"accepted","result":null}',
                     b'{"status":"accepted","result":[]}',
                     b'{"status":"accepted","result":{"kind":"ignored"}}',
                     b"[" * 1100 + b"]" * 1100, accepted() + accepted()]:
            with self.subTest(body=body):
                runner = Runner(response(body=body))
                self.assertFalse(self.deliver(runner))
                self.assertEqual(len(runner.posts), 1)
                self.assertEqual(self.sleeps, [])

    def test_acknowledgment_body_limit_excludes_status_trailer(self):
        base = accepted()
        for size, expected in [(4096, True), (4097, False)]:
            with self.subTest(size=size):
                runner = Runner(response(body=base + b" " * (size - len(base))))
                self.assertEqual(self.deliver(runner), expected)
                self.assertEqual(len(runner.posts), 1)
                self.config(runner.posts[0])
                self.assertEqual(self.sleeps, [])
        self.assertTrue(self.deliver(Runner(response(body=base + b"\n\n"))))

    def test_malformed_http_status_trailer_does_not_acknowledge_or_retry(self):
        for output in [b"", accepted(), accepted() + b"\nabc", accepted() + b"\n000",
                       accepted() + b"\n202garbage", accepted() + b"\n0202", accepted() + b"\n202\n"]:
            with self.subTest(output=output):
                runner = Runner(subprocess.CompletedProcess([], 0, output, b""))
                self.assertFalse(self.deliver(runner))
                self.assertEqual(len(runner.posts), 1)
                self.assertEqual(self.sleeps, [])

    def test_endpoint_rejection_precedes_token_and_subprocess_access(self):
        for endpoint in ["http://hub.example/heartbeat", "https://hub.example/uptime/heartbeat",
                         "https://hub.example/heartbeat/", "https://hub.example/",
                         "https://hub.example/heartbeat?token=secret", "https://hub.example/heartbeat#secret",
                         "https://user:secret@hub.example/heartbeat", "https:///heartbeat",
                         "file:///heartbeat", "https://hub.example/%68eartbeat", None,
                         "\n" + ENDPOINT, "https://hub.examp\tle/heartbeat", ENDPOINT + "\r",
                         "https://hub.example\x00/heartbeat", "https://hub.example\x7f/heartbeat"]:
            with self.subTest(endpoint=endpoint):
                runner = Runner()
                with mock.patch("builtins.open", side_effect=AssertionError("Read before endpoint validation")), \
                     mock.patch("io.open", side_effect=AssertionError("Read before endpoint validation")), \
                     mock.patch("os.open", side_effect=AssertionError("Read before endpoint validation")):
                    self.assert_rejected(runner, endpoint=endpoint)
                self.assertEqual(runner.calls, [])

    def test_invalid_receipts_never_start_a_subprocess(self):
        for receipt in [{}, None, [], {**self.receipt, "source": "unknown-job"},
                        {**self.receipt, "source": []}, {**self.receipt, "runId": ""},
                        {**self.receipt, "runId": "run\nheader-injection"},
                        {**self.receipt, "runId": "a" * 129},
                        {**self.receipt, "scheduledFor": "yesterday"},
                        {**self.receipt, "scheduledFor": True}, {**self.receipt, "scheduledFor": -1},
                        {**self.receipt, "scheduledFor": self.receipt["scheduledFor"] + 1},
                        {**self.receipt, "extra": "unexpected-data"}]:
            with self.subTest(receipt=receipt):
                runner = Runner()
                with self.assertRaises(ValueError):
                    heartbeat.deliver(receipt, ENDPOINT, str(self.token_file), runner=runner)
                self.assertEqual(runner.calls, [])

    def test_token_must_be_private_regular_and_nonempty(self):
        for mode in [0o604, 0o640, 0o666]:
            with self.subTest(mode=oct(mode)):
                self.token_file.chmod(mode)
                runner = Runner()
                self.assert_rejected(runner)
                self.assertEqual(runner.calls, [])
        self.token_file.chmod(0o600)
        self.token_file.write_text(" \n")
        self.assert_rejected(Runner())
        self.token_file.unlink()
        self.assert_rejected(Runner())
        self.token_file.mkdir(mode=0o700)
        self.assert_rejected(Runner())

    def test_token_accepts_one_optional_line_ending_at_length_boundaries(self):
        for token in ["a" * 32, "b" * 256]:
            for ending in ["", "\n", "\r\n"]:
                with self.subTest(length=len(token), ending=repr(ending)):
                    self.token_file.write_bytes((token + ending).encode())
                    runner = Runner(response())
                    self.assertTrue(self.deliver(runner))
                    self.assertIn("Authorization: Bearer " + token, self.config(runner.posts[0])["header"])

    def test_oversized_multiline_nonascii_or_padded_tokens_are_rejected(self):
        for value in ["a" * 31, "a" * 257, "a" * 4096, "a" * 256 + "\n\n" + "b",
                      "a" * 32 + "\n" + "b" * 32, " " + TOKEN, TOKEN + " ", TOKEN + "\n\n",
                      TOKEN + "\r\nInjected: header", TOKEN + '"', TOKEN + "\\", TOKEN + "é"]:
            with self.subTest(length=len(value)):
                self.token_file.write_bytes(value.encode())
                runner = Runner()
                self.assert_rejected(runner)
                self.assertEqual(runner.calls, [])

    @unittest.skipUnless(hasattr(os, "mkfifo") and hasattr(os, "O_NONBLOCK"),
                         "Nonblocking FIFO checks require POSIX")
    def test_fifo_token_is_rejected_without_blocking(self):
        self.token_file.unlink()
        os.mkfifo(self.token_file, mode=0o600)
        real_open = os.open

        def open_nonblocking(path, flags, *args, **kwargs):
            self.assertTrue(flags & os.O_NONBLOCK, "Opening a token FIFO must not hang a job")
            return real_open(path, flags, *args, **kwargs)

        runner = Runner()
        with mock.patch("os.open", side_effect=open_nonblocking):
            self.assert_rejected(runner)
        self.assertEqual(runner.calls, [])

    def test_symlinked_token_is_rejected(self):
        actual = self.token_file.with_name("actual-token")
        self.token_file.rename(actual)
        self.token_file.symlink_to(actual)
        runner = Runner()
        self.assert_rejected(runner)
        self.assertEqual(runner.calls, [])

    def test_token_owned_by_another_user_is_rejected(self):
        info = mock.Mock(st_mode=stat.S_IFREG | 0o600, st_uid=os.getuid() + 1, st_size=len(TOKEN) + 1)
        runner = Runner()
        with mock.patch("os.fstat", return_value=info):
            self.assert_rejected(runner)
        self.assertEqual(runner.calls, [])

    def test_disabled_send_does_no_file_or_subprocess_io_with_invalid_config(self):
        for arguments in [[], ["--receipt", "{}"],
                          ["--receipt", "invalid-json-secret", "--endpoint", "not-a-url",
                           "--token-file", "/missing/token-secret", "--curl-path", "/missing/curl"]]:
            with self.subTest(arguments=arguments):
                status, stdout, stderr = self.run_cli("send", *arguments, no_reads=True)
                self.assertEqual(status, 0, stderr)
                self.assertEqual(stdout + stderr, "")

    def test_begin_cli_emits_receipt_without_token_or_subprocess_access(self):
        status, stdout, stderr = self.run_cli("begin", "--source", "mini-vm-lock-slow", no_reads=True)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(stderr, "")
        receipt = json.loads(stdout)
        self.assertEqual(set(receipt), {"source", "runId", "scheduledFor"})
        self.assertEqual(receipt["source"], "mini-vm-lock-slow")
        self.assertEqual(uuid.UUID(receipt["runId"]).version, 4)

    def test_enabled_cli_success_with_default_and_pinned_curl(self):
        for curl_args, expected in [([], "curl"),
                                    (["--curl-path", "/nix/store/fixture/bin/curl"], "/nix/store/fixture/bin/curl")]:
            with self.subTest(curl=expected):
                runner = Runner(response())
                status, stdout, stderr = self.run_cli(
                    "send", "--enabled", "--receipt", json.dumps(self.receipt),
                    "--endpoint", ENDPOINT, "--token-file", str(self.token_file), *curl_args, runner=runner)
                self.assertEqual(status, 0, stderr)
                self.assertEqual(stdout + stderr, "")
                self.assertEqual(len(runner.calls), 2)
                self.assertTrue(all(args[0] == expected for args, _ in runner.calls))
                self.config(runner.posts[0])

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
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, GENERIC_ERROR)

    def test_cli_failed_version_check_is_generic_and_never_posts(self):
        for outcome in [version("8.3.0"), FileNotFoundError(TOKEN),
                        subprocess.TimeoutExpired(["curl"], 5, output=TOKEN.encode(), stderr=TOKEN.encode())]:
            with self.subTest(outcome=outcome):
                runner = Runner(version_result=outcome)
                status, stdout, stderr = self.run_cli(
                    "send", "--enabled", "--receipt", json.dumps(self.receipt),
                    "--endpoint", ENDPOINT, "--token-file", str(self.token_file), runner=runner)
                self.assertEqual(status, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, GENERIC_ERROR)
                self.assertEqual(runner.posts, [])

    def test_cli_delivery_failures_are_generic_and_redacted(self):
        timeout = subprocess.TimeoutExpired(["curl"], 15, output=TOKEN.encode(), stderr=TOKEN.encode())
        for outcomes in [[response(0, TOKEN.encode(), 56, TOKEN.encode())] * 3,
                         [response(503, TOKEN.encode(), stderr=TOKEN.encode())] * 3,
                         [timeout] * 3, [response(202, TOKEN.encode())],
                         [response(0, TOKEN.encode(), 60, TOKEN.encode())],
                         [OSError(TOKEN)]]:
            with self.subTest(attempts=len(outcomes)):
                runner = Runner(*outcomes)
                status, stdout, stderr = self.run_cli(
                    "send", "--enabled", "--receipt", json.dumps(self.receipt),
                    "--endpoint", ENDPOINT, "--token-file", str(self.token_file), runner=runner)
                self.assertEqual(status, 1)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr, GENERIC_ERROR)
                self.assertEqual(len(runner.posts), len(outcomes))
                self.assertEqual(len({kwargs["input"] for _, kwargs in runner.posts}), 1)


if __name__ == "__main__":
    unittest.main()
