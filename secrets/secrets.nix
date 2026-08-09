# agenix の受信者定義。`agenix -e <file>` はこのファイルを見て再暗号化する。
#
# このファイル自体に秘密は無い (公開鍵だけ)。暗号文 `*.age` も git に入れてよい —
# それが agenix の要点で、秘密を宣言管理下に置きつつ dotfiles を public に保てる。
#
# 復号できるのは以下の鍵の持ち主だけ:
#   - mini-vm のホスト鍵 ... activation 時に NixOS が自動で復号するのに使う
#   - M4 Pro のユーザー鍵 ... `agenix -e` で中身を編集するのに使う
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

  all = [
    mini-vm
    gigun
  ];
in
{
  # Cloudflare トンネルの認証情報。cloudflared が credentialsFile として読む。
  "cloudflared-cloudflare-os.json.age".publicKeys = all;

  # Cloudflare API トークン (Workers AI + AI Gateway + Workers Scripts)。
  # KEY=VALUE 形式で、cloudflare-os サービスの EnvironmentFile として渡す。
  "cloudflare-os-env.age".publicKeys = all;

  # codex ブリッジの設定。api_key が入っているので全体を暗号化している。
  "codex-bridge-config.toml.age".publicKeys = all;

  # 管理しないもの:
  #   ~/.codex/auth.json — ChatGPT の OAuth 認証。codex 自身がリフレッシュで書き換える
  #     可変状態なので、activation のたびに古い暗号文で上書きすると認証が壊れる。
  #     VM を作り直したら `codex login` をやり直すこと。
}
