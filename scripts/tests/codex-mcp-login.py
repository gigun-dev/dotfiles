#!/usr/bin/env python3
"""codex-mcp-login: 偽の codex で /start → callback 中継 → 記録までを通し、通知判定を固定する。"""

import contextlib
import http.client
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("codex_mcp_login", ROOT / "scripts/codex-mcp-login.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

AUTH_URL = "https://auth.example/authorize?state=STATE123&code_challenge=CHALLENGE"

# 本物の codex mcp login --no-browser と同じ順に出力し、-c で渡された固定ポートで callback を待つ。
FAKE_CODEX = r"""
import http.server, os, sys, time
args = sys.argv[1:]
port = int(next(a.split("=", 1)[1] for a in args if a.startswith("mcp_oauth_callback_port=")))
mode = os.environ["FAKE_MODE"]
if mode == "fail":
    print("Error: discovery boom", file=sys.stderr)
    sys.exit(3)
print("Authorize the MCP server by opening this URL in your browser:", flush=True)
print(os.environ["FAKE_AUTH_URL"], flush=True)
print("", flush=True)
result = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = "state=STATE123" in self.path and self.path.startswith("/callback")
        body = b"Authentication complete. You may close this window." if ok else b"Invalid OAuth callback"
        self.send_response(200 if ok else 400)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        result["ok"] = ok
    def log_message(self, *a):
        pass
server = http.server.HTTPServer(("127.0.0.1", port), H)
server.timeout = 20
server.handle_request()
server.server_close()
sys.exit(0 if result.get("ok") else 1)
"""


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Endpoint(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.base = Path(self.dir.name)
        (self.base / "codex.py").write_text(FAKE_CODEX)
        self.callback_port = free_port()
        self.spawned = []
        self.stderr = io.StringIO()
        self.redirect = contextlib.redirect_stderr(self.stderr)
        self.redirect.__enter__()

    def tearDown(self):
        if hasattr(self, "httpd"):
            self.httpd.shutdown()
            self.httpd.server_close()
        self.redirect.__exit__(None, None, None)
        self.dir.cleanup()

    def start_app(self, mode):
        def spawn(server):
            cmd = mod.codex_command("codex", server, "https://login.example", self.callback_port)
            self.spawned.append(cmd)
            return subprocess.Popen(
                [sys.executable, str(self.base / "codex.py"), *cmd[1:]],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=dict(os.environ, FAKE_MODE=mode, FAKE_AUTH_URL=AUTH_URL),
            )

        manager = mod.LoginManager(spawn, lambda s: mod.record_login(self.base, s, now=1000), url_timeout=10)
        self.app = mod.App(manager, lambda token: token == "ok", self.callback_port, ["cloudflare"], self.base, callback_wait=10)
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.app.handler())
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def get(self, path, token="ok"):
        conn = http.client.HTTPConnection("127.0.0.1", self.httpd.server_address[1], timeout=20)
        try:
            conn.request("GET", path, headers={"Cf-Access-Jwt-Assertion": token} if token else {})
            response = conn.getresponse()
            return response.status, response.getheader("Location"), response.read().decode()
        finally:
            conn.close()

    def test_full_flow(self):
        self.start_app("ok")
        self.assertEqual(self.get("/start", token=None)[0], 403)
        self.assertEqual(self.spawned, [])
        status, location, _ = self.get("/start?server=cloudflare")
        self.assertEqual((status, location), (302, AUTH_URL))
        # 再タップは同じ login を指す (固定ポートを取り合う 2 本目を起動しない)。
        self.assertEqual(self.get("/start")[:2], (302, AUTH_URL))
        self.assertEqual(len(self.spawned), 1)
        self.assertIn('mcp_oauth_callback_url="https://login.example/callback"', self.spawned[0])
        self.assertIn("--no-browser", self.spawned[0])
        status, _, body = self.get("/callback?code=CODE&state=STATE123&iss=https%3A%2F%2Fauth.example")
        self.assertEqual(status, 200, body)
        self.assertIn("ログイン完了", body)
        self.assertEqual(mod.read_login_at(self.base, "cloudflare"), 1000)
        self.assertEqual(self.get("/callback?code=CODE&state=STATE123")[0], 410)
        logs = self.stderr.getvalue()
        for secret in ("STATE123", "CHALLENGE", "CODE"):
            self.assertNotIn(secret, logs)
        self.assertIn("ログイン完了", logs)

    def test_bad_server_and_unknown_path(self):
        self.start_app("ok")
        self.assertEqual(self.get("/start?server=..%2Fetc")[0], 400)
        self.assertEqual(self.get("/nope")[0], 404)
        self.assertEqual(self.get("/callback?code=x&state=y")[0], 410)
        self.assertEqual(self.spawned, [])

    def test_codex_fails_before_url(self):
        self.start_app("fail")
        status, _, body = self.get("/start")
        self.assertEqual(status, 502)
        self.assertIn("discovery boom", body)
        self.assertIsNone(mod.read_login_at(self.base, "cloudflare"))


class Reminder(unittest.TestCase):
    DAY = 86400

    def assess(self, login_at, rejected_at=None, has_ttl=True, now=100 * 86400):
        return mod.assess("cloudflare", login_at, rejected_at, now, has_ttl, 30, 27)

    def test_assess(self):
        now = 100 * self.DAY
        self.assertIsNone(self.assess(now - 26 * self.DAY))
        kind, body = self.assess(now - 27 * self.DAY)
        self.assertEqual(kind, "age")
        self.assertIn("残り約 3 日", body)
        self.assertEqual(self.assess(None)[0], "unknown")
        # 拒否はログイン後のものだけ数える (再ログイン前の古い拒否で鳴り続けない)。
        self.assertEqual(self.assess(now - self.DAY, rejected_at=now - 0.5 * self.DAY)[0], "rejected")
        self.assertIsNone(self.assess(now - self.DAY, rejected_at=now - 2 * self.DAY))
        self.assertEqual(self.assess(None, rejected_at=now, has_ttl=False)[0], "rejected")
        self.assertIsNone(self.assess(None, has_ttl=False))

    def test_should_send(self):
        self.assertFalse(mod.should_send(None, "age", "2026-10-16", 3, 9))
        self.assertTrue(mod.should_send(None, "rejected", "2026-10-16", 3, 9))
        self.assertTrue(mod.should_send({"date": "2026-10-15", "kind": "age"}, "age", "2026-10-16", 9, 9))
        self.assertFalse(mod.should_send({"date": "2026-10-16", "kind": "age"}, "age", "2026-10-16", 12, 9))
        self.assertTrue(mod.should_send({"date": "2026-10-16", "kind": "age"}, "rejected", "2026-10-16", 12, 9))
        self.assertFalse(mod.should_send({"date": "2026-10-16", "kind": "rejected"}, "rejected", "2026-10-16", 12, 9))

    def test_parse_rejections(self):
        colored = (
            "\x1b[2m2026-10-15T05:53:49Z\x1b[0m \x1b[31mERROR\x1b[0m codex_rmcp_client::oauth::refresh_transaction"
            "\x1b[2m:\x1b[0m \x1b[3merror\x1b[0m\x1b[2m=\x1b[0mfailed to refresh OAuth tokens for server cloudflare:"
            " OAuth refresh token was rejected: Server returned error response: invalid_grant: Grant not found"
        )
        lines = [
            json.dumps({"MESSAGE": list(colored.encode()), "__REALTIME_TIMESTAMP": "2000000"}),
            json.dumps({"MESSAGE": colored.replace("cloudflare", "local:figma"), "__REALTIME_TIMESTAMP": "5000000"}),
            json.dumps({"MESSAGE": colored, "__REALTIME_TIMESTAMP": "1000000"}),
            json.dumps({"MESSAGE": "unrelated", "__REALTIME_TIMESTAMP": "9000000"}),
            "not json",
        ]
        self.assertEqual(mod.parse_rejections(lines), {"cloudflare": 2.0, "local:figma": 5.0})

    def test_remind_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            line = json.dumps({
                "MESSAGE": "failed to refresh OAuth tokens for server cloudflare: OAuth refresh token was rejected: x",
                "__REALTIME_TIMESTAMP": str(10**18),
            })
            (base / "journal.json").write_text(line + "\n")
            journalctl = base / "journalctl"
            journalctl.write_text(f"#!/bin/sh\ncat {base / 'journal.json'}\n")
            notifier = base / "notify"
            notifier.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {base / 'argv'}\ncat \"$3\" > {base / 'body'}\n")
            for path in (journalctl, notifier):
                path.chmod(0o755)
            state = base / "state"
            state.mkdir()
            mod.record_login(state, "cloudflare", now=1)
            argv = [
                "remind", "--state-dir", str(state), "--server", "cloudflare",
                "--origin", "https://login.example/", "--notifier", str(notifier),
                "--notify-unit", "codex-mcp-login-remind.service", "--journalctl", str(journalctl),
                "--ttl-days", "30", "--remind-after-days", "27", "--quiet-until", "0",
            ]
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(mod.main(argv), 0)
            sent = (base / "argv").read_text().splitlines()
            self.assertEqual(sent[0], "codex-mcp-login-remind.service")
            self.assertEqual(sent[3], "https://login.example/start?server=cloudflare")
            self.assertIn("拒否", (base / "body").read_text())
            self.assertEqual(json.loads((state / "cloudflare.notified").read_text())["kind"], "rejected")
            (base / "argv").unlink()
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(mod.main(argv), 0)
            self.assertFalse((base / "argv").exists())


class Redaction(unittest.TestCase):
    def test_redact(self):
        self.assertEqual(
            mod.redact('"GET /callback?code=A&state=B HTTP/1.1" 200 -'),
            '"GET /callback?… HTTP/1.1" 200 -',
        )
        self.assertEqual(mod.redact(AUTH_URL), "https://auth.example/authorize?…")


if __name__ == "__main__":
    unittest.main()
