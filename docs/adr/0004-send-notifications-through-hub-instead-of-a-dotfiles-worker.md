# 通知は gigun-dev/hub に寄せ、dotfiles には通知元だけを置く

Date: 2026-09-06

当初 `DF-35` は「dotfiles の `tofu/` に dead-man's switch の Worker を作る」計画だったが、hub を読んだ結果それが `gigun-dev/hub` の再発明だと分かったため撤回した。配信 API・認証・履歴・Bark backend・Slack adapter は hub が持ち、dotfiles が持つのは**通知元 hook・利用 URL・個人の資格情報**だけとする。理由は、通知基盤を 2 か所に持つと配信先・認証・履歴がどちらにあるか決まらなくなること、および hub 側は独立した暗号化 state で Worker と D1 を OpenTofu 管理しており、dotfiles の共通インフラと state に混ぜたくないこと。所有境界の定義は hub 側の `docs/infra-ownership-2026-09-06.md`、dotfiles 側の移行範囲は `docs/notifications.md`。

Consequences:

- dotfiles 側は当面 Bark 直送を維持し、hub の共通受付 `/notify` (H1) の受け入れ後に切り替える。
- 沈黙の検出 (`todo.txt` の `old:DF-35`) は hub の H1b に依存するため、このリポジトリだけでは完了できない。
- 通知履歴の UI (Cloudflare OS gadget) と エージェント向けの MCP はどちらも候補として残し、専用 MCP を一律には却下しない (2026-09-06 に一度した却下を撤回)。
