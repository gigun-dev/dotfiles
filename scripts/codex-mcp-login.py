#!/usr/bin/env python3
"""codex の MCP OAuth をスマホから張り直す入口と、失効前のリマインダ (ADR 0013)。

serve:  named tunnel の裏 (127.0.0.1) で待ち受ける。/start で `codex mcp login` を起動して
        認可 URL へ 302 し、/callback を codex の固定ポートの listener へ中継する。
        前段の Cloudflare Access が認証境界で、ここでも Access の JWT を検証する。
remind: 最終ログインからの経過日数と journal の refresh 拒否を見て Bark を鳴らす。
record: ログイン成功時刻を記録する (ssh での手動ログイン用ラッパが呼ぶ)。
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import http.client
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Callable

SERVER_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
URL_LINE = re.compile(r"https://\S+\Z")
# 認可 URL と callback の query は state / code / PKCE challenge を運ぶので journal に残さない。
QUERY = re.compile(r"\?[^\s\"'<>]+")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
REJECTED = re.compile(r"failed to refresh OAuth tokens for server (.+?): OAuth refresh token was rejected")
DAY = 86400


def redact(text: str) -> str:
    return QUERY.sub("?…", text)


def log(message: str) -> None:
    print(redact(message), file=sys.stderr, flush=True)


def valid_server(name: str) -> bool:
    return bool(SERVER_NAME.match(name))


# --- 状態 -------------------------------------------------------------------
# 最終ログイン時刻は自前で持つ。~/.codex/.credentials.json の mtime は refresh のたびに
# 進むが、Cloudflare の grant は refresh と無関係にログインから 30 日で切れるので代わりにならない。


def login_at_path(state_dir: Path, server: str) -> Path:
    return state_dir / f"{server}.login-at"


def read_login_at(state_dir: Path, server: str) -> float | None:
    try:
        return float(login_at_path(state_dir, server).read_text().strip())
    except (FileNotFoundError, ValueError):
        return None


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def record_login(state_dir: Path, server: str, now: float | None = None) -> None:
    write_atomic(login_at_path(state_dir, server), f"{int(time.time() if now is None else now)}\n")


# --- ログイン 1 回分 ----------------------------------------------------------


class Login:
    """`codex mcp login` 1 プロセス。認可 URL と終了結果を他スレッドへ渡す。"""

    def __init__(
        self,
        server: str,
        proc: subprocess.Popen,
        hard_timeout: float,
        on_success: Callable[[str], None],
    ) -> None:
        self.server = server
        self.proc = proc
        self.cond = threading.Condition()
        self.urls: list[str] = []
        self.result: tuple[bool, str] | None = None
        self.tail: list[str] = []
        self._readers = [
            threading.Thread(target=self._read_stdout, daemon=True),
            threading.Thread(target=self._read_stderr, daemon=True),
        ]
        for reader in self._readers:
            reader.start()
        threading.Thread(target=self._wait, args=(hard_timeout, on_success), daemon=True).start()

    def running(self) -> bool:
        with self.cond:
            return self.result is None

    def url_count(self) -> int:
        with self.cond:
            return len(self.urls)

    def _remember(self, line: str) -> None:
        with self.cond:
            self.tail = (self.tail + [redact(line)])[-3:]

    def _read_stdout(self) -> None:
        for raw in self.proc.stdout:
            line = ANSI.sub("", raw).strip()
            if URL_LINE.match(line):
                # scope の再試行 (should_retry_without_scopes) では 2 本目の URL が出る。
                with self.cond:
                    self.urls.append(line)
                    self.cond.notify_all()
                log(f"{self.server}: 認可 URL #{len(self.urls)} を受け取った")
            elif line:
                self._remember(line)
                log(f"codex: {line}")

    def _read_stderr(self) -> None:
        for raw in self.proc.stderr:
            line = ANSI.sub("", raw).strip()
            if line:
                self._remember(line)
                log(f"codex: {line}")

    def _wait(self, hard_timeout: float, on_success: Callable[[str], None]) -> None:
        # codex 自身も callback を 300 秒で諦める。これはそれが効かなかったときの保険。
        timed_out = False
        try:
            rc = self.proc.wait(timeout=hard_timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            self.proc.kill()
            rc = self.proc.wait()
        for reader in self._readers:
            reader.join(timeout=5)
        for pipe in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if pipe is not None:
                pipe.close()
        if rc == 0 and not timed_out:
            ok, message = True, "ログイン完了"
            try:
                on_success(self.server)
            except OSError as error:
                message = f"ログイン完了 (ただし時刻の記録に失敗: {error})"
        else:
            ok = False
            reason = "時間切れ" if timed_out else f"exit {rc}"
            message = " / ".join([reason] + self.tail)
        log(f"{self.server}: {message}")
        with self.cond:
            self.result = (ok, message)
            self.cond.notify_all()

    def wait_for(self, predicate: Callable[[], bool], timeout: float) -> None:
        with self.cond:
            self.cond.wait_for(predicate, timeout=timeout)

    def wait_url(self, timeout: float) -> str | None:
        self.wait_for(lambda: bool(self.urls) or self.result is not None, timeout)
        with self.cond:
            return self.urls[-1] if self.urls else None


class LoginError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


class LoginManager:
    """同時に走らせる login は 1 本だけ。固定の callback ポートを取り合わせないため。"""

    def __init__(
        self,
        spawn: Callable[[str], subprocess.Popen],
        on_success: Callable[[str], None],
        url_timeout: float = 60.0,
        hard_timeout: float = 330.0,
    ) -> None:
        self.spawn = spawn
        self.on_success = on_success
        self.url_timeout = url_timeout
        self.hard_timeout = hard_timeout
        self.lock = threading.Lock()
        self.current: Login | None = None

    def start(self, server: str) -> str:
        with self.lock:
            login = self.current
            if login is None or not login.running():
                try:
                    proc = self.spawn(server)
                except OSError as error:
                    raise LoginError(500, f"codex を起動できない: {error}") from error
                login = Login(server, proc, self.hard_timeout, self.on_success)
                self.current = login
                log(f"{server}: ログインを開始")
            elif login.server != server:
                raise LoginError(409, f"{login.server} のログインが進行中 (最長 5 分)")
        # 進行中の同じ server へのタップ (タブを閉じてやり直した等) は同じ URL へ戻す。
        url = login.wait_url(self.url_timeout)
        if url:
            return url
        if login.result is not None:
            raise LoginError(502, f"codex が認可 URL を出さずに終わった: {login.result[1]}")
        raise LoginError(504, "codex が認可 URL を時間内に出さなかった")


def codex_command(codex: str, server: str, origin: str, callback_port: int) -> list[str]:
    return [
        codex,
        "mcp",
        "login",
        server,
        # 認可 URL を stdout へ決まった形で出させるため。貼り付け待ちの stdin は開けたまま
        # 何も書かない (閉じると EOF で login が失敗する)。callback は HTTP 側で受ける。
        "--no-browser",
        # loopback 以外の redirect では CIMD を使わない (codex の Auto も DCR になる)。明示しておく。
        "--oauth-client-registration",
        "DCR",
        "-c",
        f"mcp_oauth_callback_port={callback_port}",
        "-c",
        f"mcp_oauth_callback_url={json.dumps(origin + '/callback')}",
        # system service には D-Bus session が無く keyring は使えない。codex-remote-control が
        # 読む先と揃えるため、auto の暗黙の fallback に頼らずファイルを指定する。
        "-c",
        'mcp_oauth_credentials_store="file"',
    ]


# --- HTTP -------------------------------------------------------------------


def access_verifier(team: str, aud: str | None) -> Callable[[str | None], bool]:
    # Access を消し忘れ・付け忘れたときにここで止めるための二枚目。cloudflared の
    # originRequest.access は NixOS モジュールに無いので origin 側で見る。
    import jwt

    client = jwt.PyJWKClient(f"{team}/cdn-cgi/access/certs", lifespan=3600)

    def verify(token: str | None) -> bool:
        if not token:
            log("Access の JWT が無い (Access を通っていない)")
            return False
        try:
            key = client.get_signing_key_from_jwt(token)
            jwt.decode(
                token,
                key.key,
                algorithms=["RS256"],
                issuer=team,
                audience=aud,
                options={"verify_aud": aud is not None, "require": ["exp", "iss"]},
            )
        except jwt.PyJWTError as error:
            log(f"Access の JWT を拒否: {type(error).__name__}")
            return False
        return True

    return verify


def page(title: str, body: str = "", link: str | None = None) -> bytes:
    link_html = f'<p><a href="{html.escape(link)}">{html.escape(link)}</a></p>' if link else ""
    return (
        "<!doctype html><meta charset=utf-8>"
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        f"<title>{html.escape(title)}</title><h1>{html.escape(title)}</h1>"
        f"<p>{html.escape(body)}</p>{link_html}"
    ).encode()


class App:
    def __init__(
        self,
        manager: LoginManager,
        verify: Callable[[str | None], bool],
        callback_port: int,
        servers: list[str],
        state_dir: Path,
        callback_wait: float = 60.0,
    ) -> None:
        self.manager = manager
        self.verify = verify
        self.callback_port = callback_port
        self.servers = servers
        self.state_dir = state_dir
        self.callback_wait = callback_wait

    def handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        app = self

        class Handler(http.server.BaseHTTPRequestHandler):
            server_version = "codex-mcp-login"

            def log_message(self, format: str, *args: object) -> None:  # noqa: A002
                log(format % args)

            def send_page(self, status: int, title: str, body: str = "", link: str | None = None) -> None:
                data = page(title, body, link)
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)

            def redirect(self, location: str) -> None:
                self.send_response(302)
                self.send_header("Location", location)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self) -> None:  # noqa: N802
                if not app.verify(self.headers.get("Cf-Access-Jwt-Assertion")):
                    self.send_page(403, "Cloudflare Access を通っていない")
                    return
                path, _, query = self.path.partition("?")
                if path == "/":
                    self.status()
                elif path == "/start":
                    self.start(urllib.parse.parse_qs(query).get("server", [app.servers[0]])[0])
                elif path == "/callback" or path.startswith("/callback/"):
                    self.callback()
                else:
                    self.send_page(404, "Not Found")

            def status(self) -> None:
                lines = []
                now = time.time()
                for server in app.servers:
                    at = read_login_at(app.state_dir, server)
                    since = "記録なし" if at is None else f"{(now - at) / DAY:.1f} 日前"
                    lines.append(f"{server}: 最終ログイン {since}")
                login = app.manager.current
                if login is not None:
                    state = "進行中" if login.running() else (login.result or (False, ""))[1]
                    lines.append(f"直近の login ({login.server}): {state}")
                self.send_page(200, "codex MCP ログイン", " / ".join(lines), f"/start?server={app.servers[0]}")

            def start(self, server: str) -> None:
                if not valid_server(server):
                    self.send_page(400, "server 名が不正")
                    return
                try:
                    url = app.manager.start(server)
                except LoginError as error:
                    self.send_page(error.status, "ログインを開始できない", str(error), "/")
                    return
                self.redirect(url)

            def callback(self) -> None:
                login = app.manager.current
                if login is None or not login.running():
                    self.send_page(410, "進行中のログインが無い", "もう一度開始する", "/")
                    return
                seen = login.url_count()
                # codex の listener は 0.0.0.0 で待つが、外からは firewall で落としてある。
                # ここ (loopback) からだけ届く。
                conn = http.client.HTTPConnection("127.0.0.1", app.callback_port, timeout=10)
                try:
                    conn.request("GET", self.path)
                    response = conn.getresponse()
                    status, text = response.status, response.read(4096).decode(errors="replace")
                except OSError as error:
                    self.send_page(502, "codex の callback listener に届かない", str(error), "/")
                    return
                finally:
                    conn.close()
                if status != 200:
                    self.send_page(400, "codex が callback を受け付けなかった", text, "/")
                    return
                # codex は callback に応答してから token を交換するので、終了まで待って結果を出す。
                login.wait_for(
                    lambda: login.result is not None or len(login.urls) > seen,
                    app.callback_wait,
                )
                if login.result is None and login.url_count() > seen:
                    self.redirect(login.urls[-1])
                elif login.result is None:
                    self.send_page(202, "token 交換が終わっていない", "少し待って状態を確認する", "/")
                elif login.result[0]:
                    self.send_page(200, f"{login.server}: ログイン完了", "このタブは閉じてよい")
                else:
                    self.send_page(502, f"{login.server}: ログイン失敗", login.result[1], "/")

        return Handler


def serve(args: argparse.Namespace) -> int:
    origin = args.origin.rstrip("/")
    state_dir = Path(args.state_dir)

    def spawn(server: str) -> subprocess.Popen:
        return subprocess.Popen(
            codex_command(args.codex, server, origin, args.callback_port),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    manager = LoginManager(spawn, lambda server: record_login(state_dir, server))
    app = App(
        manager,
        access_verifier(args.access_team.rstrip("/"), args.access_aud or None),
        args.callback_port,
        args.server,
        state_dir,
    )
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), app.handler())
    httpd.daemon_threads = True
    log(f"127.0.0.1:{args.port} で待ち受け")
    httpd.serve_forever()
    return 0


# --- リマインダ ---------------------------------------------------------------


def parse_rejections(lines: list[str]) -> dict[str, float]:
    """journalctl -o json の行から server ごとの最新の refresh 拒否時刻を拾う。"""
    latest: dict[str, float] = {}
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = entry.get("MESSAGE")
        # tracing の色付けで制御文字が入り、journal はそれを byte 配列で返す。
        if isinstance(message, list):
            message = bytes(message).decode("utf-8", errors="replace")
        if not isinstance(message, str):
            continue
        match = REJECTED.search(ANSI.sub("", message))
        if not match:
            continue
        at = int(entry.get("__REALTIME_TIMESTAMP", "0")) / 1_000_000
        server = match.group(1)
        latest[server] = max(latest.get(server, 0.0), at)
    return latest


def journal_rejections(journalctl: str, since: float) -> dict[str, float]:
    # codex のプロセスに絞る。絞らないと、この文字列を含む ssh コマンドを
    # tailscaled が記録した行まで拾う (2026-10-16 実測)。
    proc = subprocess.run(
        [
            journalctl,
            "_COMM=codex",
            "--since",
            f"@{int(since)}",
            "--no-pager",
            "-o",
            "json",
            "-g",
            "OAuth refresh token was rejected",
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    # -g は一致が無いと 1 で終わる。
    if proc.returncode == 1 and not proc.stdout.strip():
        return {}
    if proc.returncode != 0:
        raise RuntimeError(f"journalctl が失敗 (exit {proc.returncode}): {proc.stderr.strip()[:200]}")
    return parse_rejections(proc.stdout.splitlines())


def assess(
    server: str,
    login_at: float | None,
    rejected_at: float | None,
    now: float,
    has_ttl: bool,
    ttl_days: int,
    remind_after_days: int,
) -> tuple[str, str] | None:
    """通知の種類と本文。不要なら None。"""
    if rejected_at is not None and (login_at is None or rejected_at > login_at):
        return "rejected", f"{server} の refresh token が拒否された (認可が切れている)。タップして再ログイン"
    if not has_ttl:
        return None
    if login_at is None:
        return "unknown", f"{server} の最終ログイン時刻の記録が無い。タップして再ログインすると記録される"
    days = int((now - login_at) // DAY)
    if days >= remind_after_days:
        left = ttl_days - days
        due = f"残り約 {left} 日" if left > 0 else "期限切れの見込み"
        return "age", f"{server} の最終ログインから {days} 日 ({ttl_days} 日で失効、{due})。タップして再ログイン"
    return None


def should_send(previous: dict | None, kind: str, today: str, hour: int, quiet_until: int) -> bool:
    # 日数による催促は朝まで待つ。拒否 (= 既に使えない) は時刻を問わず出す。
    if kind != "rejected" and hour < quiet_until:
        return False
    if previous is None or previous.get("date") != today:
        return True
    # 同じ日に 2 通目を出すのは、催促の後で実際に拒否が出たときだけ。
    return kind == "rejected" and previous.get("kind") != "rejected"


def remind(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    now = time.time()
    local = dt.datetime.fromtimestamp(now)
    failed = False
    try:
        rejections = journal_rejections(args.journalctl, now - (args.ttl_days + 1) * DAY)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        log(f"journal を読めなかった: {error}")
        rejections, failed = {}, True
    servers = list(dict.fromkeys(args.server + sorted(rejections)))
    for server in servers:
        if not valid_server(server):
            log(f"server 名が不正なので飛ばす: {server!r}")
            continue
        verdict = assess(
            server,
            read_login_at(state_dir, server),
            rejections.get(server),
            now,
            server in args.server,
            args.ttl_days,
            args.remind_after_days,
        )
        if verdict is None:
            continue
        kind, body = verdict
        notified = state_dir / f"{server}.notified"
        try:
            previous = json.loads(notified.read_text())
        except (FileNotFoundError, ValueError):
            previous = None
        if not should_send(previous, kind, local.date().isoformat(), local.hour, args.quiet_until):
            log(f"{server}: {kind} (本日は通知済みか、時刻待ち)")
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write(body + "\n")
            body_file = handle.name
        try:
            proc = subprocess.run(
                [
                    args.notifier,
                    args.notify_unit,
                    f"mini-vm MCP 再ログイン: {server}",
                    body_file,
                    f"{args.origin.rstrip('/')}/start?server={urllib.parse.quote(server)}",
                ],
                timeout=120,
            )
        finally:
            os.unlink(body_file)
        if proc.returncode != 0:
            log(f"{server}: 通知に失敗 (exit {proc.returncode})。次の回で再送する")
            failed = True
            continue
        write_atomic(notified, json.dumps({"date": local.date().isoformat(), "kind": kind}) + "\n")
        log(f"{server}: {kind} を通知した")
    return 1 if failed else 0


def record(args: argparse.Namespace) -> int:
    if not valid_server(args.name):
        log(f"server 名が不正: {args.name!r}")
        return 2
    record_login(Path(args.state_dir), args.name)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("serve")
    p.add_argument("--codex", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--callback-port", type=int, required=True)
    p.add_argument("--origin", required=True)
    p.add_argument("--access-team", required=True)
    p.add_argument("--access-aud", default="")
    p.add_argument("--state-dir", required=True)
    p.add_argument("--server", action="append", required=True)
    p.set_defaults(func=serve)

    p = sub.add_parser("remind")
    p.add_argument("--state-dir", required=True)
    p.add_argument("--server", action="append", required=True)
    p.add_argument("--origin", required=True)
    p.add_argument("--notifier", required=True)
    p.add_argument("--notify-unit", required=True)
    p.add_argument("--journalctl", default="journalctl")
    p.add_argument("--ttl-days", type=int, required=True)
    p.add_argument("--remind-after-days", type=int, required=True)
    p.add_argument("--quiet-until", type=int, default=9)
    p.set_defaults(func=remind)

    p = sub.add_parser("record")
    p.add_argument("--state-dir", required=True)
    p.add_argument("name")
    p.set_defaults(func=record)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
