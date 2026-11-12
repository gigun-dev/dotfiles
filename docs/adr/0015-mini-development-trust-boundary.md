# miniとmini-vmを一組の開発環境として扱う

Date: 2026-11-09
Implementation: done

mini-vm は主たる開発環境で、mini は Xcode・Simulator・ChatGPT の Computer Use を動かす macOS 実行環境である。従来の server / storage という分類だけでは、両者の間で日常的に処理を渡す用途を表せない。

両者を tag:dev の同じ開発環境として扱い、gigun ユーザーの相互 SSH を許可する。

Accepting: mini-vm 上のコードが mini の同じユーザーで実行できるため、両者の home や資格情報は強く隔離されない。

Rejected: mini と mini-vm の SSH を用途ごとの単発許可に限定する — 一組の常用開発環境として使う意図に合わない。
