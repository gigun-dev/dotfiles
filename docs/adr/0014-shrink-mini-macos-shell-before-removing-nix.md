# mini の macOS はシェルを最小構成に縮めてから Nix を外す

Date: 2026-11-08
Implementation: pending

nixpkgs が x86_64-darwin を外したため、Intel mini の macOS は凍結した Nix generation のまま更新が止まっている。共通の .zshrc が使う sheldon・deno・eza・mise などは今も凍結 generation の実体に依存している。この状態で Nix を外すと mini の対話シェルが起動できなくなる。

mini の macOS の役割は iPhone のバックアップ、画面共有、Xcode、Lima のホストと幾つかの常駐サービスに限られ、開発作業は mini-vm で行う。そこで mini には共通の zsh 設定を配らず、この役割に必要な数個のコマンドだけを前提にした最小のシェル設定を Ansible で配る。共通の zsh 設定を Nix なしで動かす必要は mini が理由だったので、その制約は Pro・mini-vm・WSL では外せる。

Accepting: mini の macOS では zeno の補完や eza の自動 ls などの対話環境が無くなり、mini 用のシェル設定を別に保守する。
Rejected: 凍結 generation の全 CLI を Homebrew へ 1 つずつ移す — 50 を超える CLI の取得元と checksum を検証する手間に対し、mini の役割が使うのは一部だけだから。
Rejected: 凍結 generation を使い続ける — セキュリティ更新が届かない実体が対話シェルとサービスに残り続けるから。
Revisit: mini を Apple Silicon に替えて Nix 管理へ戻すとき。
