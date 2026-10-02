# mini-vm の Tailscale SSH 途絶の診断（2026-10-03）

2026-10-03 01:03〜01:06 JST の読み取りでは Mac と VM が生存し、直接 Tailscale SSH もコマンド実行まで成功した。過去の一時タイムアウトは再現していない。ただし最後の直接 SSH は接続から終了まで 14.86 秒かかり、DERP 経由の経路は遅延を含めて別途観測が必要。Mac 停止、VM 停止、SSH 途絶を同一の判定にしない。

## 実測と根拠

操作は手元の MBPM4Pro から行った。SSH は `BatchMode=yes` と `ConnectTimeout=8` を指定し、Python の `subprocess.run(timeout=25)` でコマンド全体を制限した。netcheck とホスト経由のログ採取は全体 35 秒以内。設定変更、再起動、通知送信、秘密ファイルの読み取りは行っていない。ログは診断に必要な行の要約だけを記録し、SSH コマンド全文、鍵指紋、公開 IP、認証情報は残さない。

| 観測対象 | 操作と結果 | 分かること・限界 |
|---|---|---|
| Mac mini | `ssh mini` が成功。`hostname` は Macmini、`sysctl kern.boottime` は epoch 1790954044 = 00:14:04 JST。uptime は約 50 分 | この時点で Mac は生存。9/28 の停止原因は証明しない |
| Lima | mini 上の `/usr/local/bin/limactl list` は mini-vm Running、vz/x86_64、SSH 127.0.0.1:49256 | Running 表示だけを VM 機能確認にしない |
| VM のホスト経由実行 | mini 上の `limactl shell mini-vm -- sh -c …` で hostname/proc/systemd の読み取り成功 | VM の実行とローカル Lima SSH 経路を確認 |
| VM の boot | `/proc/stat` の btime 1790954071 = 00:14:31 JST。boot ID は `bbe51fe1-3c73-4c87-8bde-887bfd5219cf` | Mac boot の 27 秒後。直接 SSH と Lima の両経路で同じ boot ID |
| VM のサービス | `systemctl is-active tailscaled sshd` はともに active。両 unit は 00:15:00 開始、00:15:01 active、NRestarts=0 | 現 boot の状態。過去 boot やすべての手動再起動を排除する証拠ではない |
| 手元の Tailscale 状態 | BackendState=Running、mini/mini-vm Online=true | control-plane の状態だけでは SSH 成功を証明しない |
| 手元→mini | `tailscale ping --c 2 --timeout 5s mini` は LAN direct、101 ms、exit 0 | ホストへの経路は成功 |
| 手元→mini-vm | 同じ ping は DERP(tok) pong 1.317 秒 / 2.482 秒、direct connection not established、exit 1 | pong があるので到達している。exit 1 だけで VM 不達と扱わない |
| 直接 SSH | Tailscale SSH banner、認証成功、hostname/boot ID 実行成功。その後 2 回の修正済みコマンドも exit 0。最後は全体 14.86 秒 | 現在は利用可能だが遅延あり。初回 exit 1 は VM の `uptime -s` 非対応によるもので通信失敗ではない |
| netcheck | 両端 UDP=true、MappingVariesByDestIP=true、CaptivePortal=false、Nearest DERP=Tokyo。手元 IPv6=yes、VM IPv6=no。tok latency は手元 247.2 ms / VM 145.6 ms | その時点の観測値。NAT/direct 未確立と過去タイムアウトの因果は未確定 |
| VM route | default via 192.168.5.2、enp0s1 の source 192.168.5.15 | VM は Lima のネットワーク内。LAN 上の mini と別の経路を取る |

## 現 boot のログ

mini 経由で `sudo -n journalctl -u tailscaled -u sshd` を読み、UTC の出力を JST に直した。

- 00:15:00: tailscaled の bootstrap DNS が `network is unreachable`。
- 00:15:06: Tailscale の network-status が network down、00:15:07 に ok。
- 00:15:21: ipn state が Starting → Running、DERP Singapore への接続開始。00:15:24 に connected。
- 00:20:54〜55: DERP Tokyo に接続。
- 00:38:57: `CreateEndpoint error ... -> ...:22: connection was refused`。このエラーと既報の一時タイムアウトとの同一性は未確認。
- 00:43:57: Tailscale SSH の access granted と Session complete（`true`）。
- 01:04:03: 今回の直接 SSH に access granted。hostname/boot ID 実行後、非対応の `uptime -s` で code=1。

SSH の実受付は tailscaled 側のログに出た。今回の直接 SSH は Tailscale の banner と認証を確認したため、sshd の active だけではこの経路を検証したことにならない。採取範囲でアクセス拒否を示す行は見つからなかったが、ACL 全体や接続チェックの設定は検査していない。

## 再発時の非破壊手順

1. 発生時刻を JST/UTC で記録し、手元の `tailscale status`、mini/mini-vm への `tailscale ping --c 2 --timeout 5s` を採取する。pong の有無と direct/DERP を分けて読む。
2. 直接 SSH を全体 timeout 付きで 1 回実行し、タイムアウト、認証拒否、remote コマンドの終了コードを区別する。`ConnectTimeout` だけでは remote 実行時間全体は制限できない。
3. mini に入れるなら `limactl list` のあと `limactl shell mini-vm` で boot ID、btime、uptime、tailscaled/sshd の状態を採取する。ここが成功したら VM 生存の証拠とし、直接 SSH の失敗だけをホスト停止へ昇格しない。
4. 発生の前後数分の tailscaled/sshd ログと両端 netcheck を読む。SSH command 全文を含むログは共有文書にコピーせず、接続・拒否・サービス起動・経路変化だけを抜粋する。
5. 直接 SSH が使えない間は、今回検証した mini → `limactl shell mini-vm` を管理の代替経路にする。ネットワーク設定を変えずに VM の情報を読み、単発の bounded 再試行で復帰を確認する。mini 経由も失敗したら、ホスト停止・手元側経路障害・tailnet 障害は未確定のまま外部観測と相関する。

以下は今回成功した直接 SSH の最小確認。親 SSH プロセスの待ち時間は 25 秒で制限する。出力は秘密を含まない boot と稼働秒数だけにする。

```python
import subprocess

try:
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "mini-vm",
         "hostname; cat /proc/sys/kernel/random/boot_id; cat /proc/uptime"],
        capture_output=True, text=True, timeout=25,
    )
    print(result.returncode, result.stdout, result.stderr)
except subprocess.TimeoutExpired:
    print("SSH の全体待ち時間が 25 秒を超えた")
```

`tailscale up/down`、SSH 設定切替、tailscaled 再起動、Lima 再起動、Mac 再起動を自動復旧に追加していない。必要になった場合は、進行中の接続への影響とロールバックを具体化して承認を受ける。

## 残る検証

過去タイムアウトの正確な発生時刻・クライアントログとの相関、00:38:57 の拒否理由、direct 未確立の原因、14.86 秒の内訳、長時間 SSH/複数経路の安定性は unknown。パケット採取、ACL/prefs の検査、故障注入、再起動後の再試験は未実施。

運用上の検知は hub が持つ Mac/VM heartbeat と外形観測に、SSH の実行結果・観測時刻・経路という別の証拠を相関させる。dotfiles に別の監視判定・通知受付を増やさない。hub の受付契約に合わせた継続観測・途絶通知・復旧履歴の受け入れは未検証なので、Tailscale SSH 途絶の運用検証（todo 0057）は open のままとする。所有境界は [監視改善メモ](monitoring-follow-up-2026-10-03.md)、Lima の運用は [mini-vm の運用](mini-vm.md)、通知の所有は ADR 0004 に従う。
