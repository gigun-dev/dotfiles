# main の CI と無人機への適用

Date: 2026-10-15
Implementation: done

管理者の push は required CI を迂回し得るため、push 後の CI で検証し、無人 mini-vm は main の HEAD が green のときだけ適用する。無人 mini の checkout 同期は Nix / Ansible の実機適用と分け、作業コピーの遅延を解消しつつ、機械への適用は別途判断できるようにする。

Accepting: 壊れた変更が main に入り得る。CI が red の間は無人機への適用が止まり、直すまでが push した側の作業になる。
Rejected: push 前に手元で検証するフック — push を待たせるうえ、管理者の push は結局 required CI を迂回し得るから。
Replaces: 0002
