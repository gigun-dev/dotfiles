# codex の MCP OAuth は Access で保護した入口から再ログインする

Date: 2026-10-16
Implementation: done

Cloudflare MCP の OAuth grant は refresh してもログインから 30 日で切れる。スマホから張り直せるよう、通知のタップ後にログインを開始する。入口は Cloudflare Access と origin の JWT 検証で守る。ここを通った人の Cloudflare アカウントが mini-vm の codex の MCP 資格情報になるため、Access 設定が失われても素通しにしない。

codex の callback listener は非 loopback にも bind するため、loopback 以外からの接続を raw 表で遮断する。firewall の方式を変更するときもこの制約を維持する。運用と回避手順は [mini-vm.md](../mini-vm.md) を参照。

Accepting: 入口の安全性が Access と JWT 検証の設定に依存する。`accessAud` の既定値は null で、設定しないと同じ team の他アプリの JWT を区別できない。
Rejected: 通知の時点で認可 URL を発行する — 気づく前に callback の待機期限が切れ得るから。
Rejected: tailnet や SSH 経由で張り直す — スマホから張り直せないから。
