# main の CI と無人機への適用

Date: 2026-10-15

管理者の push は required CI を迂回し得るため、push 後の CI で検証し、無人 mini-vm は main の HEAD が green のときだけ適用する。push を待たせず、失敗した変更が無人機に反映されることを防ぐ。

無人 mini の checkout 同期は Nix / Ansible の実機適用と分ける。作業コピーの遅延を解消しつつ、機械への適用は別途判断できるようにする。

Replaces: 0002
