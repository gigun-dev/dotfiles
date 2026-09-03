# M4 Pro 専用: Secure Enclave 内の SSH 鍵で Git コミットを署名する。
#
# upstream モジュール本体 (options.nix / home-manager-module.nix) の import は
# ここではやらない。flake.nix の mkDarwinSystem が aarch64-darwin のときだけ
# `inputs.nix-secure-enclave-key.homeManagerModules.default` を足す形にしている
# (Intel Mac / Linux では upstream の systems が aarch64-darwin のみで評価不能
# なので、この import 自体を条件から外している)。ここは設定値だけを持つ。
#
# なぜ共通の nix/modules/home/programs/git に置かないか:
# そこは Linux (mini-vm / WSL) と共用のモジュールで、Linux 側には Secure Enclave も
# 署名鍵も無い。signByDefault をあちらに書くと Linux の `git commit` が
# 「鍵が無い」で全部失敗する。署名関連の設定は darwin 専用のこのファイルに閉じ込める。
{
  config,
  lib,
  ...
}:
{
  programs.nix-secure-enclave-key = {
    enable = true;

    identities.git-signing = {
      # 秘密鍵ではない。Secure Enclave が鍵を保持し、これは ssh-keychain.dylib 経由で
      # チップの鍵を参照するためのスタブ (公開鍵参照)。チップから持ち出せない代わりに
      # マシンごとに別鍵になる — 他マシンにコピーしても意味を持たない。
      keyFile = "~/.ssh/id_enclave_key";
      label = "gigun-git-signing";

      # "bio" にすると署名のたびに Touch ID を要求されうる。この Mac では
      # Claude Code / codex が自律的に `git commit` するため、生体認証待ちで
      # エージェントのセッションが固まってしまう。"none" の代償は保護境界が
      # 「ログイン中のこの Mac」までに緩むこと (Touch ID 相当の追加確認は無い)。
      protection = "none";

      # activation で Secure Enclave 上に鍵を作り、SSH スタブを用意する。
      autoEnsure = true;

      github = {
        # activation 時に公開鍵を GitHub へ自動登録する。
        # 前提: gh に admin:ssh_signing_key スコープが要る (現状は admin:public_key
        # までしか無い)。スコープ不足でも activation 自体は失敗せず、手で叩く
        # `gh ssh-key add` コマンドが表示されるだけなので autoAdd = true のままにしてある。
        # 事前に以下を一度手で実行しておくこと (対話フローなのでここでは実行しない):
        #   gh auth refresh --hostname github.com \
        #     --scopes admin:ssh_signing_key,admin:public_key
        autoAdd = true;

        # push の認証は `gh auth git-credential` (HTTPS) で行っており SSH 認証鍵は
        # 使っていない。"both" にすると不要な認証用登録まで GitHub に生えるので、
        # 署名用途 (signing) だけに絞る。
        type = "signing";
      };
    };

    signingIdentity = "git-signing";
    signByDefault = true;
  };

  # 2026-09-02 実害その2: 上の設定により upstream (home-manager-module.nix) が
  #   programs.ssh.settings."*".IdentityFile = map (identity: identity.keyFile) identities;
  # で enclave 鍵だけを settings."*".IdentityFile に入れる。OpenSSH は IdentityFile が
  # 1つでも設定ファイルに明示されると「未指定時だけ試す既定候補」(~/.ssh/id_rsa,
  # id_ecdsa, id_ed25519 等) を一切追加しない仕様のため、実在する ~/.ssh/id_ed25519
  # (2025-04-20 作成、GitHub 等で日常的に使っていた鍵) が host 側で個別指定の無い宛先に
  # 一切提示されなくなり、公開鍵認証が軒並み失敗していた。
  #
  # 対処は共通モジュール (nix/modules/home/programs/ssh) 側からの追記ではなく
  # ここで lib.mkForce により丸ごと上書きする形にした。理由: home-manager の
  # `programs.ssh.settings` は freeformType が `types.attrsOf types.anything` で、
  # anything 型はリスト同士でも「連結」ではなく「完全一致でなければ conflicting
  # definition」というマージしか持たない (nixpkgs lib/types.nix の anything.merge を
  # 実際に読んで確認した)。よって `lib.mkAfter [...]` を別モジュールから足しても
  # 定義競合エラーになり、追記という形では解決できない。
  #
  # id_ed25519 の文字列を共通モジュール側に置かずあえてここに直書きしているのは、
  # この副作用自体が本ファイル (upstream の enableDefaultConfig=false 化) に起因する
  # ため、原因と対処を同じファイルに閉じ込めて次に読む人が追いやすくするため。
  #
  # 順序は enclave 鍵 (署名用) を先、id_ed25519 を後にしてある。日常的な認証を
  # enclave 経由に寄せたい意図で既存の並びを崩さない判断だが、enclave 鍵は
  # signingIdentity 用途 (github.type = "signing") で GitHub に認証鍵としては
  # 登録していないため、認証の成否という意味では順序を入れ替えても実害はほぼ無い。
  programs.ssh.settings."*".IdentityFile = lib.mkForce [
    config.programs.nix-secure-enclave-key.identities.git-signing.keyFile
    "~/.ssh/id_ed25519"
  ];
}
