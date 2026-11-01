# 通知基盤は hub、通知元は dotfiles が所有する

Date: 2026-09-06

配信・認証・履歴は `gigun-dev/hub` が持ち、dotfiles は通知元と個人の資格情報を持つ。通知基盤を二重にせず、hub の独立したインフラ state と dotfiles の state を混ぜないため。

現行の運用は [notifications.md](../notifications.md) を参照。
