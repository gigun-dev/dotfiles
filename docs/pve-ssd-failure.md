# pve の SSD 故障（2026-05-20 発生、2026-08-01 発覚）

pve（Proxmox、192.168.11.100）の root SSD が I/O エラーで ext4 の `emergency_ro` に落ち、2 か月半誰も気づかなかった。データは mini へ退避済み。交換か再インストールかは未決（todo 0019）。

## 経緯

2026-05-20 22:52:34 JST に、ブロックビットマップの読み出しが EIO になり、ジャーナルを続けられず abort した。ext4 スーパーブロックの記録は、最初のエラー関数が `ext4_wait_block_bitmap`、最後が `ext4_journal_check_start`、エラー数 2（同一秒）で、段階的な劣化ではなく一瞬だった。読み取りは通るので SSH で入れてしまい、外形上は動いているように見えたのが発覚を遅らせた。

## ディスク（UDSS UD3CS1HT301-512G、SATA、無名品）

摩耗ではない。平均消去回数は 47 / 5050 で消耗率 0.93%、書き込み総量は 2.6TB。実害は訂正不能セクタ 408、Current_Pending 7。**属性 161（予備ブロック残、61）が本当のカウントダウン指標**で、Current_Pending より先に動く。

推定原因（確度順）:

1. データ保持不良。読み書き比 47:1、温度 54°C、リフレッシュの弱い安物ファームウェア。最初に壊れたのが、よく読まれて書き換えられないブロックビットマップだったことと整合する。
2. 不正な電断。Power-Off_Retract 18 / Power_Cycle 39 で約半数が異常終了。電断保護（PLP）が無い。
3. 無名メーカーの品質。smartctl の DB に無く、SMART のエラーログは空なのに訂正不能が 408 という矛盾がある。

Power_On_Hours 6084h に対し稼働開始は 2025-12-10 で、実質新品が 5 か月で壊れた。

## 退避（完了、gzip -t で全件確認）

mini の `~/` に 9 ファイル、合計 28.4GB（実データ約 53GB）。

| ファイル | 中身 |
|---|---|
| pve-config-20260801.tar.gz | /etc/pve 全体、storage.cfg、config.db、network/interfaces |
| pve-base-100-disk-0 / pve-base-110-disk-0 | lxc-docker、lxc-supabase（テンプレート） |
| pve-vm-101-disk-0 | supabase-01 |
| pve-vm-200-disk-0 | terminus |
| pve-vm-300-disk-0 / disk-1 | nextcloud（システム、データ） |
| pve-vm-400-disk-0 | vikunja |
| pve-vm-500-disk-0 | openclaw |

openclaw のスナップショット 2 本（`snap_vm-500-disk-0_*`）は不要と判断して退避していない。退避中に SMART の値は動かず、ゼロ埋めの欠損は無い。

## 未決

- SSD を交換するか、全消去して再インストールするか。買わなくても直る（不良セクタは書き直しで予備ブロックへ再割り当てされる）が、原因が保持特性なら数か月で再発する。
- 再起動には物理コンソールが前提。fsck が通らないと emergency shell に落ちて SSH できない。
- vm-101（supabase-01）が 98.19% 使用（20GB のうち残り 400MB）。別途対処が要る（todo 0146）。正体は VM ではなく LXC の CT 101（`rootfs: local-lvm:vm-101-disk-0,size=20G`、退避した設定から）。全 CT が root SSD 上の LVM thin pool（local-lvm）にあり、割り当ては 20G × 7 と nextcloud のデータ 128G で計 268G。広げる（`pct resize`）には壊れた SSD の上で書く必要があるので、0019 を決めてからになる。2026-11-09 時点の pve は tailnet で 62 日前から offline で、`192.168.11.100` も mini の LAN から届かず、中身は調べられていない。

## 教訓

壊れたことより、2 か月半気づかなかったことが問題。read-only になると通知・監視・ログが同時に死ぬので、ホスト自身に検知させても意味がない。mini か外部から `touch` して書き込み可否を叩く外部監視が要る。

## 外部監視（todo 0145）

mini-vm の `pve-write-probe` が 10 分ごとに `http://pve:9180/` を叩く。pve 側の受け口は接続のたびに root の ext4 へ実際に書いて fsync し、成功なら 200、失敗なら 503 を返す。503 と接続失敗が 2 回続くと Bark へ 1 回だけ通知し、回復するまで繰り返さない。定義は `nix/modules/nixos/mini-vm.nix`。SSH ではなく HTTP にしたのは、tag:server → tag:proxmox の SSH ルールを増やさないため（タグ間の IP は全許可済み）。

受け口が無い間は timer を止めてある（`pveWriteProbeReady = false`）。pve を直したら（todo 0019）、pve で次を root で入れ、mini-vm から `curl -fsS http://pve:9180/` が `ok` を返すのを確かめてから `pveWriteProbeReady = true` にする。

`/usr/local/sbin/pve-write-probe`（`chmod 755`）:

```sh
#!/bin/sh
# HTTP リクエストを読み切ってから返す。読まずに閉じると RST になり curl が応答を受け取れない。
timeout 2 sed '/^\r*$/q' >/dev/null 2>&1
dir=/var/lib/pve-write-probe
if mkdir -p "$dir" && date +%s > "$dir/probe.tmp" && sync "$dir/probe.tmp" && mv "$dir/probe.tmp" "$dir/probe"; then
  printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nok\n'
else
  printf 'HTTP/1.0 503 Service Unavailable\r\nContent-Type: text/plain\r\n\r\nread-only\n'
fi
```

`/etc/systemd/system/pve-write-probe.socket`:

```ini
[Socket]
ListenStream=9180
Accept=yes

[Install]
WantedBy=sockets.target
```

`/etc/systemd/system/pve-write-probe@.service`:

```ini
[Service]
ExecStart=/usr/local/sbin/pve-write-probe
StandardInput=socket
StandardOutput=socket
StandardError=journal
RuntimeMaxSec=15
```

`systemctl daemon-reload && systemctl enable --now pve-write-probe.socket`。Proxmox のファイアウォールを有効にしている場合は 9180/tcp を tailnet から通す。socket は systemd が常駐で握るので、root が read-only に落ちた後も接続は受けられ、503 が返る。
