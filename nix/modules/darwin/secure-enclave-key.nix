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
  pkgs,
  lib,
  ...
}:
let
  # upstream (home-manager-module.nix) の resolve-key-file と同じロジックをここでも
  # 踏襲する: identities.git-signing.keyFile は "~/.ssh/id_enclave_key" という
  # tilde 付き文字列で管理されており、upstream 自身もこの文字列を都度 tilde 展開して
  # 使っている (署名鍵の実ファイルパス解決や ssh IdentityFile 設定)。ここでは同じ
  # keyFile から ".pub" を導出するだけなので、"~/.ssh/id_enclave_key" という文字列を
  # このファイル内で 2 箇所に書く (上の identities.git-signing.keyFile と、もし
  # ここでベタ書きしたら) 二重管理を避けるため、config から読んで組み立てる。
  enclaveKeyFile = config.programs.nix-secure-enclave-key.identities.git-signing.keyFile;
  enclavePubKeyPath =
    if lib.hasPrefix "~/" enclaveKeyFile then
      "${config.home.homeDirectory}/${lib.removePrefix "~/" enclaveKeyFile}.pub"
    else
      "${enclaveKeyFile}.pub";

  # allowed_signers は git config (`programs.git.settings`) が書き出す
  # $XDG_CONFIG_HOME/git/config と同じ置き場に揃える (XDG 準拠、Mac 標準の
  # ~/.config を素直に使う)。
  allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";

  # email はここでハードコードしない。共通モジュール
  # (nix/modules/home/programs/git/default.nix) が programs.git.settings.user.email
  # として宣言している値をそのまま読む — 同じ email を 2 箇所で管理すると、
  # 片方だけ変更されたときに allowed_signers の principal と実際のコミット
  # identity がズレて「ローカル検証だけ通らない」という気付きにくい壊れ方をする。
  signingEmail = config.programs.git.settings.user.email;
in
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

  # ローカルでの SSH 署名検証 (`git log --show-signature` / `%G?`) を有効にする。
  #
  # GitHub 側は署名鍵を登録済みなので検証できるが、ローカルの git には
  # gpg.ssh.allowedSignersFile が無いと `error: gpg.ssh.allowedSignersFile needs
  # to be configured and exist for ssh signature verification` で常に検証不能 (N)
  # になる。upstream (home-manager-module.nix) は署名の「生成」(gpg.ssh.program)
  # までしか設定を持たず、検証用の allowedSigners は範囲外 — ソースを grep して
  # 確認済みで、upstream にオプションを足す余地は無いので自前で用意する。
  programs.git.settings.gpg.ssh.allowedSignersFile = allowedSignersFile;

  # allowed_signers の中身は activation で生成する (nix の静的な値としては書けない)。
  # 理由: 中身に埋め込む公開鍵 (`~/.ssh/id_enclave_key.pub`) は Secure Enclave 上で
  # activation 時に初めて作られるファイルで、eval 時点 (nix build/switch を実行する
  # 前) にはまだ存在しない。新マシンでは当然、既存マシンでも鍵を作り直した直後は
  # 読めない。公開鍵の文字列そのものをここにハードコードする案もボツにした:
  # マシンごとに Secure Enclave が別鍵を生成するため (このファイル冒頭のコメント
  # 参照)、ハードコードすると宣言と実体が即座にズレる。
  home.activation.nix-secure-enclave-key-allowed-signers =
    # upstream の nix-secure-enclave-key-ensure (公開鍵を書き出す activation) より
    # 後に走らないと、初回 switch では公開鍵がまだ無くこの activation が空振りする。
    # DAG 依存で「ensure の後」を明示することで、2 回目以降の switch を待たずに
    # 初回から allowed_signers が揃うようにしている。
    lib.hm.dag.entryAfter [ "nix-secure-enclave-key-ensure" ] ''
      pub_key_path=${lib.escapeShellArg enclavePubKeyPath}
      allowed_signers_file=${lib.escapeShellArg allowedSignersFile}
      signing_email=${lib.escapeShellArg signingEmail}

      # 公開鍵がまだ無いケース (ensure が autoEnsure=false になった/失敗した等、
      # 順序を守っても理論上あり得る) では activation 全体を落とさず警告に留める。
      # ensure_installed パターン (apple-container.nix 等) と同じ「無ければ静かに
      # スキップ」思想 — allowed_signers が古いまま/未生成でも、それは
      # `git log --show-signature` がまだ使えないだけで、コミット・署名・push
      # 自体には影響しない機能なので activation を失敗させるほどの重大度ではない。
      if [ -f "$pub_key_path" ]; then
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$allowed_signers_file")"

        # man ssh-keygen(1) の ALLOWED SIGNERS 節の書式:
        #   principals(USER@DOMAIN) [options] keytype base64-key
        # 公開鍵ファイルは "keytype base64-key" の1行 (コメント無し) なので、
        # 先頭に principal (= git commit の author email) を1個スペース区切りで
        # 足すだけでよい。options 相当 (namespaces=/valid-after= 等) は使わない
        # (署名鍵の用途を絞る必要が無いシンプルな個人運用のため)。
        # 冪等性: 内容が変わらなければ書き直さない (mtime を無駄に更新しない)。
        new_line="$signing_email $(${pkgs.coreutils}/bin/cat "$pub_key_path")"
        if [ ! -f "$allowed_signers_file" ] || \
           [ "$(${pkgs.coreutils}/bin/cat "$allowed_signers_file")" != "$new_line" ]; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/tee "$allowed_signers_file" > /dev/null <<< "$new_line"
        fi
      else
        echo "warning: $pub_key_path が無いため allowed_signers を更新できなかった (次回 switch で再試行される)" >&2
      fi
    '';
}
