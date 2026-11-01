# codex の MCP OAuth は Access で保護した入口から再ログインする

Date: 2026-10-16

Cloudflare MCP の OAuth grant は refresh してもログインから 30 日で切れる。tailnet や SSH に依存せずスマホから張り直すため、通知のタップ後にログインを開始する。認可 URL を通知時に発行すると、気づく前に callback の待機期限が切れ得るため。

入口は Cloudflare Access と origin の JWT 検証で守る。ここを通った人の Cloudflare アカウントが mini-vm の codex の MCP 資格情報になるため、Access 設定が失われても素通しにしない。`accessAud` の既定値は null で、設定しない場合は同じ team の他アプリの JWT を区別できない。

codex の callback listener は非 loopback にも bind するため、loopback 以外からの接続を raw 表で遮断する。firewall の方式を変更するときもこの制約を維持する。再ログイン後に稼働中の codex が新資格情報を読み直すかは未確認。運用と回避手順は [mini-vm.md](../mini-vm.md) を参照。
