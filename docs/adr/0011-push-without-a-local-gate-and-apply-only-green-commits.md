# main への push は待たずに CI へ任せ、mini-vm は CI green の commit だけを適用する

Date: 2026-10-15
Implementation: done

repo admin の直 push は required CI を迂回できるため、これまでは手元の pre-push フックが `scripts/verify.sh` を走らせて main を守っていた。その代わり push のたびに検証を待つことになり、pull しても switch を忘れて手元の構成が main から遅れ、update した lock が未コミットのまま残ることもあった。

pre-push の関門を外し、main への push は即座に通して検証は push 後の CI に任せる。壊れた commit が無人で適用され得るのは mini-vm だけなので、関門をそこへ移す。`dotfiles-autoswitch` は fetch した main の HEAD について GitHub Actions の check run を読み、green の commit だけへ fast-forward して switch し、red や未完了なら見送りを通知して翌日に判定し直す。手元は post-merge / post-rewrite / post-checkout フックが Nix 構成の変化を見て switch し、`update` 系の app は pull、update、switch の後で lock をその場で commit する。

理由は、人が前にいる機械では switch の失敗がその場で見えるので、手元で止める価値は push を待たせる費用に見合わないこと、および無人機の前に関門を置けば迂回された required CI の穴を適用の側で塞げること。

Accepting: CI が red の commit も main に入り、直るまで main が壊れたまま残る。その間 mini-vm の更新は止まり、毎日見送りの通知が届く。
Accepting: nix に触れる変更を pull すると、そのたびに sudo を伴う switch が走って pull が長くなる。
Rejected: pre-push を残して CI と二重にする — 待ち時間は毎 push 払うのに、守れるのは手元の 1 台だけで mini-vm への適用は守れない。
Rejected: mini-vm も github の flake を直接参照して CI 結果ごと任せる — 作業コピーと稼働構成の二重の真実を避けた既存の判断と衝突する。
Revisit: main への直 push を PR 必須にして迂回そのものが無くなったとき。

Replaces: 0002
