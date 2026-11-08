# 通知基盤は hub、通知元は dotfiles が所有する

Date: 2026-09-06
Implementation: done

配信・認証・履歴は `gigun-dev/hub` が持ち、dotfiles は通知元と個人の資格情報を持つ。現行の運用は [notifications.md](../notifications.md) を参照。

Accepting: 通知に関わる変更が hub と dotfiles の 2 つのリポジトリにまたがる。
Rejected: dotfiles の Worker で通知基盤を持つ — 通知基盤が二重になり、hub の独立したインフラ state と dotfiles の state が混ざるから。
