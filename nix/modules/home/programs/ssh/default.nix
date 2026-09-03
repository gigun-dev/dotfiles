{
  config,
  pkgs,
  lib,
  ...
}:
{
  # 2026-09-02: nix/modules/darwin/secure-enclave-key.nix を初適用したところ、upstream
  # (ryoppippi/nix-secure-enclave-key) の home-manager モジュールが内部で
  #   programs.ssh.enable = lib.mkDefault true
  #   programs.ssh.enableDefaultConfig = lib.mkDefault false
  #   programs.ssh.settings."*" = { IdentityFile = [ enclave鍵 ]; SecurityKeyProvider = ...; }
  # を立てる。これにより home-manager が ~/.ssh/config の管理権を握り、それまで手書きしていた
  # 設定は `~/.ssh/config.backup` へ退避されて消えた (home-manager は生成物と衝突する既存
  # ファイルを黙って *.backup に退避する挙動を持つ)。このモジュールは消えた手書き分を
  # 宣言側に取り込み、再発 (次に nix なしの手書きへ戻ってしまう / 再度 backup に飛ばされる)
  # を防ぐためのもの。
  #
  # 実害その2 (2026-09-02 追加発覚): OpenSSH は設定ファイルで IdentityFile が1つでも
  # 明示されると「未指定なら試す既定候補」(~/.ssh/id_rsa, id_ecdsa, id_ed25519 等) を
  # 一切追加しない。upstream が settings."*".IdentityFile に enclave 鍵しか入れていない
  # ため、実在する ~/.ssh/id_ed25519 (2025-04-20 作成、GitHub 等で日常的に使っていた鍵) が
  # 一切提示されなくなり、host 側で個別に IdentityFile を持たない宛先の公開鍵認証が
  # 軒並み失敗する状態になっていた。復旧 (enclave鍵 + id_ed25519 の明示リスト化) は
  # Darwin 固有の破壊に対する Darwin 固有の対処なので、このファイルではなく
  # nix/modules/darwin/secure-enclave-key.nix 側で lib.mkForce により行う。
  # ここに書くと Linux まで巻き込む理由は settings."*" 内のコメントを参照。
  #
  # このモジュール単体でも成立するように programs.ssh.enable は明示的に true。
  # upstream (secure-enclave-key.nix) は darwin (aarch64) にしか import されないため、
  # Linux (mini-vm / WSL) では upstream モジュールが存在せず enable の mkDefault も飛ばない。
  # 明示しないと Linux 側で ssh config が一切生成されなくなる。
  #
  # 注意 (2026-09-02): この enable = true により、これまで home-manager が
  # 関与していなかった Linux (mini-vm / WSL) 側でも `~/.ssh/config` が home-manager
  # の管理下に入る。mini-vm は `~/.ssh/config` が元々存在しない (秘密鍵も無く
  # `authorized_keys` のみ) ことを確認済みで実害は無いが、**WSL 側は未確認**。
  # もし WSL に手書きの `~/.ssh/config` があれば、次回 `nix run .#switch` 時に
  # home-manager の backupFileExtension 設定 (flake.nix, `backupFileExtension =
  # "backup"`) に従って `~/.ssh/config.backup` へ退避され、このモジュールが生成する
  # 内容 (includes は darwin 限定なので中身はほぼ空) に置き換わる。これはまさに
  # 今回の発端 (M4 Pro での ~/.ssh/config 消失) と同じ経路なので、WSL で switch する
  # 前に既存の `~/.ssh/config` の有無と中身を確認し、必要ならこのモジュールへ
  # 先に取り込んでおくこと。
  programs.ssh = {
    enable = true;

    # OrbStack / colima のコメント原文が明示する通り、Include はファイル先頭でなければ
    # 機能しない ("This only works if it's at the top of ssh_config"）。home-manager の
    # `extraConfig` は生成順序が保証されず末尾に置かれることがあるため使えない。
    # `includes` オプションは生成される ssh config の先頭に Include 行として出力される
    # ため、これを使う。
    #
    # OrbStack / colima はどちらも macOS 専用の仮想化ツールで、生成する ssh config の
    # Include 先 (~/.orbstack/ssh/config, ~/.colima/ssh_config) は macOS でしか存在しない。
    # Linux (mini-vm / WSL) でこの Include を出すと、参照先が無いディレクトリのため
    # ssh 起動時に警告 (または Include できずエラー) になる。darwin 限定にする。
    includes = lib.optionals pkgs.stdenv.isDarwin [
      "~/.orbstack/ssh/config"
      "/Users/gigun/.colima/ssh_config"
    ];

    # upstream (secure-enclave-key.nix 経由) は settings."*" に既に
    # IdentityFile (enclave 鍵) と SecurityKeyProvider を入れている。
    # ここで新たに `Host *` ブロックを作ると同じ Host パターンが二重に出力され
    # ssh_config としては後勝ちで意味的に紛らわしくなるため、同じ "*" キーへ
    # マージする形にする (home-manager の settings はアトリビュートセットとして
    # 複数モジュールから足し合わされる)。
    settings."*" = {
      # 手書き設定にあった唯一の `Host *` 項目。IPv6 環境での QoS タギングが
      # 一部ネットワーク機器 (家庭用ルータ等) で不安定要因になることがあるため無効化。
      IPQoS = "none";

      # 2026-09-02 レビュー指摘で撤回: 当初ここに
      #   IdentityFile = lib.mkAfter [ "~/.ssh/id_ed25519" ];
      # を書いていたが、これは Darwin で踏んだのと同じ実害を Linux 側に持ち込む
      # 改悪だった。OpenSSH は IdentityFile を1つでも設定ファイルに明示すると、
      # 未指定時にだけ試す既定候補 (id_rsa / id_ecdsa / id_ecdsa_sk / id_ed25519 /
      # id_ed25519_sk) を一切追加しない仕様。id_ed25519 だけを明示すると
      # 「id_ed25519 以外の既定鍵が一切提示されなくなる」という、まさに Darwin 側で
      # 直したのと同種の縮小を Linux (mini-vm / WSL) に新規に発生させてしまう。
      # 「明示した方が挙動が読める」という直感は誤りで、この行自体が退行の原因に
      # なる — 次に同じ理由で書き足したくなったときのための警告として本文を残す。
      #
      # 結論: Linux では settings."*".IdentityFile を一切設定しない。
      # 何も書かなければ OpenSSH の既定探索がそのまま働き、これまでの (nix 導入前の)
      # 挙動と完全に一致する = 一番安全。
      #
      # 役割分担: Darwin だけ明示リストが必要なのは、upstream
      # (nix-secure-enclave-key の home-manager-module.nix) が
      # settings."*".IdentityFile に enclave 鍵1件だけを入れてしまい、上記の仕様で
      # 既定探索を潰すため。その復旧 (enclave鍵 + id_ed25519 を lib.mkForce で
      # 明示リスト化) は nix/modules/darwin/secure-enclave-key.nix 側の責務。
      # このモジュールは Mac/Linux 共通なので、Darwin 専用の復旧ロジックをここに
      # 書くと Linux にまで波及してしまう (upstream 自体が import されない Linux では
      # 復旧すべき破壊が起きていないのに、id_ed25519 だけ明示することで新たな
      # 縮小を作ってしまう) — だからこそ Darwin 側のファイルに閉じ込めてある。
    };

    # host 固有の IdentityFile は、settings."*" の IdentityFile (enclave 鍵 +
    # id_ed25519) より host ブロック側の指定が ssh_config の仕様上優先される
    # (ssh は同名ディレクティブを「最初に見つかったもの」を採用し、Host ブロックは
    # Host * より前に列挙されるため)。よってこれらは自分専用の鍵だけを提示すればよい。
    settings.realbind-sst-bot-ec2 = {
      HostName = "35.76.88.127";
      User = "ubuntu";
      IdentityFile = "/Users/gigun/dev-realbind/ssh/sst-key.pem";
    };

    settings.windows = {
      HostName = "100.116.27.94";
      User = "gigun";
      IdentityFile = "~/.ssh/id_ed25519_windows";
    };
  };
}
