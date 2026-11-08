# Tailscale tailnet の設計メモ

権限の定義そのものは [tofu/tailscale/policy.hujson.tftpl](../tofu/tailscale/policy.hujson.tftpl) が正本で、方針は [ADR 0010](adr/0010-tailscale-policy-as-code.md)。ここにはテンプレートから読めない意図と運用だけを置く。

## タグの意味

| タグ | 役割 | 例 |
|---|---|---|
| `tag:admin-device` | 持ち歩く信頼端末。SSH の起点と Taildrive の利用側 | Pro、iPhone |
| `tag:storage` | 中央ストレージ。Taildrive の共有側 | mini |
| `tag:client` | 据え置きの個人端末。滅多に起動しない | Windows のノート |
| `tag:proxmox` | pve | pve |
| `tag:server` | 24/365 のエージェント基盤 | mini-vm |

「持ち歩く = admin、据え置き = サブ」で信頼の境界を分け、端末が侵害されたときの横展開を抑える。mini と Windows は 2026-05 に admin-device から降格した。

## 原則

- **タグ必須**: 新しい端末は管理画面で必ずタグを付ける。タグ無し端末への fallback ルール（`user -> *`）は無い。タグ無しだと到達できない。
- **単一ユーザーの homelab**: 本人性は GitHub OAuth で担保する前提で、タグ間の IP は全許可にして細粒度にしない。絞るのは SSH と Taildrive。
- **SSH の起点は admin-device だけ**: VM・storage・client から能動的に SSH しない（lateral movement の抑制）。常用は `ssh gigun@mini` のように nonroot。サーバ群（proxmox / server）は root / ubuntu も許可する。
- **`tag:server` と `tag:vm` を分ける**: mini-vm は Lima が作る `gigun` ユーザーで入る。旧 `tag:vm` の SSH ルールは root / ubuntu 限定で、そこに nonroot を足すと既存 VM が全部緩むので別タグにした。`tag:vm`（nextcloud、openclaw、supabase-01、terminus、vikunja）は現行テンプレートに無い。
- 参加は `sudo tailscale up --ssh --advertise-tags=tag:server --hostname=mini-vm`。Tailscale SSH なので鍵配布は不要。`networking.hostName` は次の boot から効くので、すぐ変えるなら `sudo hostname mini-vm`。

## Tailscale SSH の挙動

pve では Tailscale SSH が有効なので、`ssh root@pve` はパスワードなしで通る。LAN の IP（`192.168.11.100`）を直接指すと Tailscale SSH を迂回して本物の sshd に当たり、パスワードを聞かれる。

`storage -> proxmox` の root ルールは、2026-08-01 に pve の SSD 障害で mini へディスクイメージを退避するために足した（[pve-ssd-failure.md](pve-ssd-failure.md)）。`action` は `accept`。`check` だとブラウザの再認証で長い転送が途切れる。退避は終わっているので、不要になったら削除してよい。

## Taildrive（iCloud 風の共有）

2026-05 の運用メモ。現行ホストでの実在は今回確認していない。

- mini の `~/Storage` を `tailscale drive share storage ~/Storage` で公開し、iPhone の Files と Pro の Finder（`Cmd+K` で `http://100.100.100.100:8080/<tailnet>/mini/storage`）から開く。
- 同期ではなくマウント。mini が落ちると全クライアントから見えなくなる。
- Spotlight / Time Machine の除外は sudo で手動設定が要る。
