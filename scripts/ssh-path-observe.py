#!/usr/bin/env python3
"""SSH 途絶と VM 生存を分けて採取する。remote 出力や秘密は保存しない。"""

import argparse
from collections import deque
import datetime
import json
import math
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


# ConnectTimeout は認証・remote 実行全体を制限しないため、別に全体期限を設ける。
TIMEOUT_SECONDS = 25
# At the existing 60s cadence, retain at most one day of awake-client evidence.
HISTORY_LIMIT = 1440
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
PROBE = "hostname; cat /proc/sys/kernel/random/boot_id; cat /proc/uptime"
DIRECT = ["ssh", *SSH_OPTIONS, "mini-vm", PROBE]
VIA_HOST = [
    "ssh", *SSH_OPTIONS, "mini",
    "/usr/local/bin/limactl shell mini-vm -- sh -c " + shlex.quote(PROBE),
]


def parse_boot_id(stdout):
    # 任意の remote 出力を JSON に流さず、期待ホスト・UUID・稼働秒数を確認する。
    lines = stdout.strip().splitlines()
    if len(lines) != 3 or lines[0] != "mini-vm":
        raise ValueError("unexpected probe output")
    boot_id = str(uuid.UUID(lines[1]))
    uptime = lines[2].split()
    if len(uptime) != 2:
        raise ValueError("unexpected uptime")
    if not all(math.isfinite(float(value)) and float(value) >= 0 for value in uptime):
        raise ValueError("invalid uptime")
    return boot_id


def observe_path(command, runner=subprocess.run, clock=time.monotonic):
    started = clock()
    result = {"status": "unknown", "outcome": "execution_error", "elapsedSeconds": None, "bootId": None, "exitCode": None}
    try:
        process = runner(command, capture_output=True, text=True, timeout=TIMEOUT_SECONDS,
                         env={**os.environ, "LC_ALL": "C"})
        result["exitCode"] = process.returncode
        if process.returncode != 0:
            # Classify only the diagnostic phrase in memory; never persist stderr.
            message = (process.stderr or "").lower()
            outcome = "command_failed"
            if "connection refused" in message:
                outcome = "connection_refused"
            elif "operation timed out" in message or "connection timed out" in message:
                outcome = "timeout"
            result.update(status="failed", outcome=outcome)
        else:
            try:
                boot_id = parse_boot_id(process.stdout)
            except (ValueError, AttributeError):
                result["outcome"] = "invalid_output"
            else:
                result.update(status="ok", outcome="completed", bootId=boot_id)
    except subprocess.TimeoutExpired:
        result.update(status="failed", outcome="timeout")
    except (OSError, UnicodeError):
        # 例外本文・stderr は鍵パスや remote の秘密を含み得るため出力しない。
        pass
    result["elapsedSeconds"] = round(max(0, clock() - started), 3)
    return result


def observe(runner=subprocess.run, clock=time.monotonic):
    observed_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    direct = observe_path(DIRECT, runner, clock)
    via_host = {"status": "unknown", "outcome": "not_attempted", "elapsedSeconds": None, "bootId": None, "exitCode": None}
    # 直接経路が使える間は二重接続しない。失敗/不明時だけ独立した Lima 経路を見る。
    if direct["status"] != "ok":
        via_host = observe_path(VIA_HOST, runner, clock)
    return {"observedAt": observed_at,
            "completedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
            "paths": {"direct": direct, "viaHost": via_host}}


def atomic_write(path, content):
    path = Path(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def write_snapshot(path, snapshot):
    # Atomic replacement keeps the previous evidence if a write is interrupted.
    atomic_write(path, json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n")


def write_history(path, snapshot):
    # launchd serializes this single witness. Bound its private rolling evidence,
    # rather than allowing every healthy minute to grow storage indefinitely.
    path = Path(path)
    if path.is_symlink():
        raise OSError("history must be a regular private file")
    records = deque(maxlen=HISTORY_LIMIT)
    if path.exists():
        with path.open(encoding="utf-8") as history:
            records.extend(line.rstrip("\n") + "\n" for line in history if line.strip())
    records.append(json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")) + "\n")
    atomic_write(path, "".join(records))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path, help="最新 JSON の保存先（親ディレクトリは既存）")
    parser.add_argument("--history", type=Path, help="最大1440件のprivate JSONL履歴")
    parser.add_argument("--render-launchd", action="store_true", help="任意の定期観測plistを出力するだけ（loadしない）")
    parser.add_argument("--python", default="/usr/bin/python3", help="plistに使う絶対interpreterパス")
    args = parser.parse_args()
    if args.render_launchd:
        if (not args.snapshot.is_absolute() or not Path(args.python).is_absolute()
                or (args.history and not args.history.is_absolute())):
            parser.error("plist runtime paths must be absolute")
        # This witness runs on the client, independently of mini/VM availability.
        program = [args.python, str(Path(__file__).resolve()), "--snapshot", str(args.snapshot)]
        if args.history:
            program += ["--history", str(args.history)]
        plistlib.dump({
            "Label": "dev.gigun.ssh-path-observe",
            "ProgramArguments": program,
            "RunAtLoad": True, "StartInterval": 60, "ProcessType": "Background", "Umask": 0o077,
        }, sys.stdout.buffer)
        return 0
    snapshot = observe()
    try:
        write_snapshot(args.snapshot, snapshot)
        if args.history:
            write_history(args.history, snapshot)
    except OSError:
        # ローカルのパスや例外詳細もログへ持ち出さない。
        parser.exit(2, "snapshot の保存に失敗しました\n")
    return 0 if any(path["status"] == "ok" for path in snapshot["paths"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
