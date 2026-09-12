# 通知基盤

旧 `docs/next-directions.md`(2026-09-10 に廃止)から降ろした調査メモ。
「hub に寄せる」という決定そのものは `docs/adr/0004-send-notifications-through-hub-instead-of-a-dotfiles-worker.md`
に書かれている。以下はその決定に至った経緯と、移行範囲の詳細。

## 通知基盤は hub に寄せる (2026-09-06 決定)

**当初 `DF-35` は「dotfiles の `tofu/` に dead-man's switch の Worker を作る」計画だったが、
それは `gigun-dev/hub` の再発明だった**。hub を読んで撤回した。

**実装済みは H0 の Bark backend 検証 Worker**。OpenTofu で公開し、D1 への端末登録と
APNs 配信を検証済み。本人が iPhone で通常通知・AES 暗号化通知を両方読めたと確認し、
成立性ゲートを通過した。URL タップ・group・level の表示挙動や鍵更新などの受け入れは残る。

**共通受付 `/notify`、履歴・outbox・再試行は H1、heartbeat による沈黙検知は H1b の計画**で、
まだ実装されていない。Slack 配信も未実装。`level` と配信先の対応は今後の設計対象とする。
pve の SSD 障害に長期間気づけなかった反省は引き継ぐが、7 日ごとの一律確認ではなく、
通知元ごとの実行周期に応じて成功確認の遅延を検出する。

**所有境界**([hub の定義](../../hub/docs/infra-ownership-2026-09-06.md)):
配信 API・認証・履歴・Bark backend・Slack adapter は hub、
**通知元 hook・利用 URL・個人の資格情報は dotfiles**。
H0 は Worker/version/deployment と D1 を hub の OpenTofu で管理し、暗号化した独立 state を使う。
Wrangler は bundle と migration に使う。dotfiles の共通インフラと state へ混ぜない。

**dotfiles 側の移行範囲**(現時点では既存の Bark 直送を維持):

1. mini-vm の共通失敗通知と `claude/hooks/bark-notify.sh` を hub の共通受付へ移行する。
2. `dotfiles-autoswitch`・`dotfiles-lock-propose@fast`・`@slow` の **3 系統**に成功 heartbeat を足す。
   lock に差分が無い正常終了も報告する。Claude hook はイベント駆動なので同じ周期監視に含めない。
3. 通知元 ID・認証・監視周期を宣言管理し、30 分の起動ジッターと処理時間を猶予に含める。
   日次と週次を区別し、不発・復旧・計画停止と移行時の二重配信防止を検証する。

共通受付への切替は H1 の受け入れ後。**DF-35 完了には H1b の監視と H2 の移行検証も必要**。
「成功確認が届かない」ことを知らせる設計であり、通知だけで VM 障害の原因を断定しない。

**UI と MCP は両立する**。通知履歴を見る Cloudflare OS gadget は候補、エージェントによる
hub 操作には MCP を検討する。どちらも未実装で、専用 MCP を一律に却下しない。
外部 MCP の認証互換性 (`DF-30`) は gadget が API を呼ぶ経路とは別途検証する。

**認証案は実装済み構成と分ける**。機械向け `/notify` は Bearer、人向け `/history` は
Cloudflare Access で守る案を持つが、H0 は workers.dev 上の秘密のパス接頭辞による構成。
共通 API・履歴 UI の認証と独自ドメインは hub 側で確定する。

**訂正の履歴** (2026-09-06): 一度この節を「設計は既にある」と書いたが、実機で成立が確認できて
いるのは H0 と OpenTofu 管理だけで H1/H1b/H2 は未着手だった。専用 MCP の一律却下も同時に撤回し、
通知移行の範囲に lock 提案 2 系統の成功確認を足した。
