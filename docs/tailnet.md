# Tailscale tailnet の設計メモ

権限の定義そのものは [tofu/tailscale/policy.hujson.tftpl](../tofu/tailscale/policy.hujson.tftpl) が正本で、方針は [ADR 0010](adr/0010-tailscale-policy-as-code.md)。ここにはテンプレートから読めない意図と運用だけを置く。

## タグの意味

| タグ | 役割 | 例 |
|---|---|---|
| `tag:admin-device` | 持ち歩く信頼端末。SSH の起点と Taildrive の利用側 | Pro、iPhone |
| `tag:dev` | 主開発環境と macOS 実行環境。gigun で相互 SSH | mini-vm、mini |
| `tag:storage` | Taildrive 共有用の機能タグ。継続・廃止の判断まで保持 | mini |
| `tag:client` | 据え置きの個人端末。滅多に起動しない | Windows のノート |
| `tag:proxmox` | pve | pve |

mini-vm は主開発環境、mini は Xcode・Simulator・ChatGPT の Computer Use を動かす macOS 実行環境として、一組の信頼範囲に置く（[ADR 0015](adr/0015-mini-development-trust-boundary.md)）。タグは権限の分類、ホスト名は実行先の選択に使う。

## 原則

- **タグ必須**: 新しい端末は管理画面で必ずタグを付ける。タグ無し端末への fallback ルール（`user -> *`）は無い。タグ無しだと到達できない。
- **単一ユーザーの homelab**: 本人性は GitHub OAuth で担保する前提で、タグ間の IP は全許可にして細粒度にしない。絞るのは SSH と Taildrive。
- **開発環境の相互 SSH**: tag:dev 同士は gigun のみ許可する。root は許可しない。admin-device から開発環境へは nonroot を許可し、client からの SSH は許可しない。
- **ノード鍵の期限**: mini と mini-vm は無人運用のため期限を無効化する。廃止・侵害時は明示失効する。これは SSH と署名・配布の資格情報の期限を変えない。
- **Linux と macOS の責務**: mini-vm でコード編集・エージェント・ジョブを動かし、macOS が必要な処理を mini に渡す。同じ gigun への SSH があるため、署名・配布の工程分離だけでは資格情報の隔離を証明できない。

## dev 移行の現在地

2026-11-09 に dev のポリシーを OpenTofu で適用し、管理画面で mini を dev + storage、mini-vm を dev に更新した。両ノードの期限切れを観測したため、本人の指示でノード鍵の期限を無効化した。変更前の鍵期限は未観測で、タグ要求変更が期限切れの原因とは断定しない。Pro から両端末への SSH と、mini-vm → mini / mini → mini-vm の gigun による相互実行を確認した。旧 server の互換ルールはノード移行後に削除・適用し、再度相互接続と変更なし plan を確認した。

## Tailscale SSH の挙動

pve では Tailscale SSH が有効なので、`ssh root@pve` はパスワードなしで通る。LAN の IP（`192.168.11.100`）を直接指すと Tailscale SSH を迂回して本物の sshd に当たり、パスワードを聞かれる。

`storage -> proxmox` の root ルールは、2026-08-01 に pve の SSD 障害で mini へディスクイメージを退避するために足し（[pve-ssd-failure.md](pve-ssd-failure.md)）、退避が終わったので 2026-11-09 にテンプレートから外した（todo 0147）。同じ退避を再びやるなら一時的に戻す。そのときの `action` は `accept` にする。`check` だとブラウザの再認証で長い転送が途切れる。

## Taildrive（iCloud 風の共有）

2026-11-09 に mini の `tailscale drive list` で storage → /Users/gigun/Storage（gigun）の設定は確認した。クライアントから利用できるかは未確認で、本人からも使えていない可能性が指摘されている。利用可否と継続・廃止は別タスクで判断する。

- mini の `~/Storage` を `tailscale drive share storage ~/Storage` で公開し、iPhone の Files と Pro の Finder（`Cmd+K` で `http://100.100.100.100:8080/<tailnet>/mini/storage`）から開く。
- 同期ではなくマウント。mini が落ちると全クライアントから見えなくなる。
- Spotlight / Time Machine の除外は sudo で手動設定が要る。
