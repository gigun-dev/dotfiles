#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["websockets==16.0"]
# ///
"""mini-vmの既存app-serverから短命のペアリングコードを発行する。"""
import asyncio
import json
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import websockets


async def pair(socket):
    async with websockets.unix_connect(str(socket), uri="ws://localhost", open_timeout=10) as ws:
        async def request(number, method, params):
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": number, "method": method, "params": params}))
            # 0.160.0のCLIはローカルRPCを2秒で打ち切るが、サーバーのHTTP上限は30秒。
            # 通知が続いても上限を延長しない。公開ポートや常駐を追加せず既存ソケットを使う。
            async with asyncio.timeout(40):
                while True:
                    result = json.loads(await ws.recv())
                    if result.get("id") == number:
                        if "error" in result:
                            raise RuntimeError(f"{method}: RPC error {result['error']['code']}")
                        return result["result"]

        await request(1, "initialize", {"clientInfo": {"name": "codex_app_server_daemon", "version": "0.160.0"}, "capabilities": {"experimentalApi": True}})
        await ws.send(json.dumps({"jsonrpc": "2.0", "method": "initialized"}))
        result = await request(2, "remoteControl/pairing/start", {"manualCode": True})
        # 応答全体は認証情報を含みうるため、利用者が入力するコードと期限だけ表示する。
        print("Pairing code:", result["manualPairingCode"])
        print("Expires:", datetime.fromtimestamp(result["expiresAt"]).astimezone().isoformat())


async def main():
    host = sys.argv[1] if len(sys.argv) == 2 else "gigun@mini-vm"
    if len(sys.argv) > 2 or host.startswith("-"):
        raise ValueError("usage: uv run scripts/codex-pair.py [SSH-host]")
    with tempfile.TemporaryDirectory(prefix="codex-pair-") as directory:
        socket = Path(directory) / "control.sock"
        forward = subprocess.Popen(["ssh", "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10", "-L", f"{socket}:/home/gigun/.codex/app-server-control/app-server-control.sock", host])
        try:
            async with asyncio.timeout(12):
                while not socket.exists():
                    if forward.poll() is not None:
                        raise RuntimeError("SSH forwarding failed")
                    await asyncio.sleep(0.05)
            await pair(socket)
        finally:
            forward.terminate()
            forward.wait(timeout=5)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (TimeoutError, OSError, RuntimeError, ValueError) as error:
        print(f"Pairing failed: {error}", file=sys.stderr)
        sys.exit(1)
