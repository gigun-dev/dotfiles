# agy の remote-control は system service が所有する

Date: 2026-10-16

`agy remote-control start` が作る user unit は Nix store の旧パスを保持し、更新後も古い版を実行し得る。dotfiles の system service が flake の package を所有し、変更時に再起動する。

同一アカウントの二重 serve はセッションを奪い合うため、旧 user unit を停止・削除する。登録と Google 認可は手動のまま。版更新時は進行中の会話が中断され得る。認可切れで serve が失敗すれば健全性ゲートを落とし得る。運用は [mini-vm.md](../mini-vm.md) を参照。
