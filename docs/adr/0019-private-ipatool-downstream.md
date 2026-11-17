# ipatoolの独自修正をprivate派生リポジトリで保守する

Date: 2026-11-17
Implementation: done

セキュリティキー対応 ipatool は独自の認証修正とテストを持つ。公開 dotfiles にパッチを重ねる構成では、ソースの保守と環境への配置が同じ場所に混ざる。上流への PR は collaborator に制限されており、自分で更新を保守する必要がある。

上流履歴を保持した private 派生リポジトリで実装とテストを管理し、dotfiles の既存 flake は検証済み commit の取得とパッケージ化を担当する。上流更新の検知と取り込み、dotfiles への採用を分ける。認証情報と復号モデルはリポジトリに入れない。

Accepting: private ソースの取得にホスト側の認証が必要となり、派生リポジトリの CI と上流追従を自分で保守する。
Rejected: 解析環境を別 flake に分ける — 現在は独立した環境の配布が必要なく、既存 flake で commit を固定すれば宣言管理できる。
Rejected: 全修正を公開 dotfiles のパッチとして持つ — 実装変更と配置設定の保守が混在する。
