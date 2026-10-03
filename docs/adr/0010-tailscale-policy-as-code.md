# Tailscaleの権限定義と非公開の識別子を分離してOpenTofuで管理する

Date: 2026-10-04
Implementation: done

公開dotfilesにはレビュー可能な権限定義のテンプレートを置き、所有者IDとAPI認証情報は既存agenixで暗号化する。Tailscaleのポリシー全体はOpenTofuの公式providerから管理し、Cloudflareとは別stateにする。公開テンプレートは既に公開している汎用タグと接続関係に限定し、個人識別子を含めない。

Accepting: Gitの差分ではテンプレートを確認し、非公開値を含む最終ポリシーの差分は認証済み環境で確認する必要がある。

Rejected: ACL全体の暗号化 — 権限変更のレビューが難しくなる。

Rejected: 新しいprivateリポジトリ — 既存の暗号化とIaC運用を分断する。

Rejected: 管理画面とGitOps Actionからも適用する — 正典が複数になる。
