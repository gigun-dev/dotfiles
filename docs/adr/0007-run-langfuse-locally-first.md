# Langfuse は mini-vm の Compose とローカルストレージで始める

Date: 2026-09-20
Implementation: done

Langfuse は既存 mini-vm の公式に近い Compose とローカル MinIO で動かし、将来 S3 互換ストレージへ移せる境界を保つ。UI は Cloudflare Access で保護する。tailnet 外の SDK から使う OTLP 入口は対話ログインを要求せず、限定したパスと Langfuse の project key 認証を境界とする。

Accepting: データは mini-vm のローカルディスクに置かれ、mini-vm と同じ障害の影響を受ける。
Rejected: 外部の S3 互換ストレージから始める — 個人利用で必要な容量や費用を測る前に外部ストレージを増やさないため。
Rejected: Langfuse 用に別の Linux 環境を作る — 既存の mini-vm で足りるから。
Revisit: 容量や費用を測って、ローカルストレージで足りないと分かったとき。
