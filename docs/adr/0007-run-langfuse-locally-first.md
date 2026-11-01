# Langfuse は mini-vm の Compose とローカルストレージで始める

Date: 2026-09-20

Langfuse は既存 mini-vm の公式に近い Compose とローカル MinIO で動かし、将来 S3 互換ストレージへ移せる境界を保つ。個人利用で必要な容量や費用を測る前に外部ストレージを増やさず、別の Linux 環境も作らないため。

UI は Cloudflare Access で保護する。tailnet 外の SDK から使う OTLP 入口は対話ログインを要求せず、限定したパスと Langfuse の project key 認証を境界とする。
