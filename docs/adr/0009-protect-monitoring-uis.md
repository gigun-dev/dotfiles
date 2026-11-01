# 監視 UI は Cloudflare Access で保護する

Date: 2026-09-21

ホスト資源は Beszel、サービス死活と履歴は Uptime Kuma で確認し、UI は Cloudflare Access で保護する。Access の認証済み利用者を信頼し、アプリ内の二重ログインは設けない。以前は公開ステータスページを作らない方針だったが、監視履歴と操作 UI が必要になり、この構成を選んだ。

VM 内の監視は VM・ホスト・Tunnel の停止時には一緒に止まるため、別の障害領域にある Cloudflare Worker の外形監視も残す。Worker は公開 UI を持たない定期実行とする。
