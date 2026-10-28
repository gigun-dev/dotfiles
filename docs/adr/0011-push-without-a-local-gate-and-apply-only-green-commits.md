# main への push は待たずに CI へ任せ、mini-vm は CI green の commit だけを適用する

Date: 2026-10-15
Implementation: done

repo admin の直 push は required CI を迂回できるため、これまでは手元の pre-push フックが `scripts/verify.sh` を走らせて main を守っていた。その代わり push のたびに検証を待つことになり、pull しても switch を忘れて手元の構成が main から遅れ、update した lock が未コミットのまま残ることもあった。

pre-push の関門を外し、main への push は即座に通して検証は push 後の CI に任せる。mini-vm の `dotfiles-autoswitch` は main の HEAD が green のときだけ fast-forward して switch する。red または未完了なら見送る。有人機では Git hook が Nix 構成の変化を見て switch し、`update` 系の app は pull、update、switch の後で lock をその場で commit する。

理由は、無人機への適用の前に CI の関門を置き、push を待たせずに迂回された required CI の穴を塞げること。
無人運用の mini は checkout の同期と実機設定の適用を分ける。同期は GitHub の変更を取り込むだけとし、Nix / Ansible の適用を起動しない。
ただし checkout を参照する symlink を通じて設定が変わり得るため、自動同期の開始前にその影響を確認する。

Accepting: CI が red の commit も main に入り、直るまで main が壊れたまま残る。その間 mini-vm の更新は止まり、毎日見送りの通知が届く。
Accepting: 有人機で hook が有効な場合、Nix の変更を pull すると sudo を伴う switch が走り、pull が長くなる。
Rejected: pre-push を残して CI と二重にする — 待ち時間は毎 push 払うのに、守れるのは手元の 1 台だけで mini-vm への適用は守れない。
Rejected: main が red のとき直近の green な祖先へ戻して適用する — VM は green しか適用しないので red の間も最後に当てた green に留まっており、得られるのは間の数 commit だけ。代わりに HEAD でない状態を当てることになり、dirty / 先行ガードと「稼働 rev = checkout の HEAD」という前提が崩れる。red は main 側ですぐ直す。
Rejected: mini-vm も github の flake を直接参照して CI 結果ごと任せる — 作業コピーと稼働構成の二重の真実を避けた既存の判断と衝突する。
Revisit: main への直 push を PR 必須にして迂回そのものが無くなったとき。

Replaces: 0002
