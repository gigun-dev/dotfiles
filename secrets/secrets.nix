# agenix の受信者定義。`agenix -e <file>` はこのファイルを見て再暗号化する。
#
# このファイル自体に秘密は無い (公開鍵だけ)。暗号文 `*.age` も git に入れてよい —
# それが agenix の要点で、秘密を宣言管理下に置きつつ dotfiles を public に保てる。
#
# 復号できるのは以下の鍵の持ち主だけ:
#   - mini-vm のホスト鍵 ... activation 時に NixOS が自動で復号するのに使う
#   - M4 Pro のユーザー鍵 ... `agenix -e` で中身を編集するのに使う
#   - 保管用 age 鍵     ... 上の 2 つを失ったときの復旧用 (下記 backup)
#
# 鍵を足すとき (新しいマシンを増やす等) は publicKeys に追記して
# `agenix -r` で全ファイルを再暗号化すること。追記しただけでは既存の暗号文は
# その鍵で開けない (暗号文は作成時の受信者リストで固定されるため)。
let
  # mini-vm の SSH ホスト鍵 (/etc/ssh/ssh_host_ed25519_key.pub)。
  # コメントが `root@nixos` なのは nixos-lima のイメージ由来で、hostName とは無関係。
  mini-vm = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII9YDN9MH2C/uIr+u5IskIAeUgFruwAdjZrnL+92Bn6L";

  # M4 Pro のユーザー鍵 (~/.ssh/id_ed25519.pub)。編集用。
  gigun = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICg8t7n8SvetqxFxe9blWFfXUxPe/S47zzFl041aOZ+z";

  # 保管用 (2026-09-05 作成)。上の 2 つを同時に失ったときだけ使う。日常では触らない。
  # 秘密鍵は iPhone の「パスワード」アプリ (iCloud Keychain, E2E)。人間が手で 1 回
  # 取り出すだけの秘密なので Keychain でよい (機械が読む秘密は agenix 側で管理する)。
  # パスフレーズ無し: 掛けるとその置き場で同じ問題が再発する。
  backup = "age1hgxrp2tm5n3hf76py9smr6px4cdfsc8g3c2630wu8pxr9qd4vv2qtp47nq";

  all = [
    mini-vm
    gigun
    backup
  ];
in
{
  # Cloudflare トンネルの認証情報。cloudflared が credentialsFile として読む。
  "cloudflared-cloudflare-os.json.age".publicKeys = all;

  # Cloudflare API トークン (Workers AI + AI Gateway + Workers Scripts)。
  # KEY=VALUE 形式で、cloudflare-os サービスの EnvironmentFile として渡す。
  "cloudflare-os-env.age".publicKeys = all;

  # GitHub gatekeeper の OAuth App 資格情報。KEY=VALUE 形式で CLIENT_ID / CLIENT_SECRET。
  # 起動時に packages/gatekeeper-github/.dev.vars へ追記される (mini-vm.nix の
  # dev-vars 生成スクリプト)。他の gatekeeper を繋ぐときは
  # gatekeeper-<short>-env.age という名前で同じ形を増やす。
  "gatekeeper-github-env.age".publicKeys = all;

  # codex ブリッジの設定。api_key が入っているので全体を暗号化している。
  "codex-bridge-config.toml.age".publicKeys = all;

  # OpenTofu 用。他の秘密と違い NixOS の activation では復号しない — 使うのは
  # Mac 上の `nix run .#tofu` で、ラッパが実行時に復号して環境変数へ流し込む。
  # 平文の環境変数を手で管理しないための箱。中身は KEY=VALUE 形式で:
  #   CLOUDFLARE_API_TOKEN   ... アカウント所有トークン (DNS / Access / AI Gateway)
  #   AWS_ACCESS_KEY_ID      ... R2 の S3 認証情報 (state backend 用)
  #   AWS_SECRET_ACCESS_KEY  ...   同上
  #
  # mini-vm の cloudflare-os が使う CLOUDFLARE_API_TOKEN (Workers AI + Workers
  # Scripts) とは**別のトークン**。名前が衝突するので同じファイルに混ぜないこと。
  "tofu-env.age".publicKeys = all;

  # 管理しないもの:
  #   ~/.codex/auth.json — ChatGPT の OAuth 認証。codex 自身がリフレッシュで書き換える
  #     可変状態なので、activation のたびに古い暗号文で上書きすると認証が壊れる。
  #     VM を作り直したら `codex login` をやり直すこと。
}
