{
  config,
  modulesPath,
  pkgs,
  lib,
  ...
}:
let
  username = "gigun";
in
{
  # Mac Mini (Intel) 上の Lima VM。
  #
  # 背景: nixpkgs 26.11 が x86_64-darwin を drop し、Apple も macOS 27 で Intel を
  # 切ったため、Mac Mini の macOS 側を nix で管理し続ける道は途絶えた。
  # エージェント基盤 (24/365 の SSH 実行環境) はこの VM に寄せ、macOS 側は
  # Finder 経由の iPhone バックアップ・画面共有・Tailscale だけを担う。
  # ホストは Intel なので x86_64 ゲストがネイティブで動く (vz ドライバ)。
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Lima のインスタンス名・tailnet 名・hostname はすべて mini-vm に揃えてある
  # (mini は macOS 側を指すので、取り違えると事故る)。
  # なお switch では稼働中の hostname は変わらず、次回 boot から反映される。
  networking.hostName = "mini-vm";

  # lima-init が起動時にユーザーを imperative に作るため true 必須。
  # false だと nixos-rebuild がそのユーザーを消してログインできなくなる。
  users.mutableUsers = true;

  # lima-init / lima-guestagent 等、Lima ゲストとして動くのに必要な一式
  services.lima.enable = true;

  services.openssh.enable = true;

  # tailnet の独立ノードとして参加させ、host の macOS を経由せず直接 ssh する
  services.tailscale.enable = true;

  # 上流 DNS を明示する。MagicDNS への依存を断ち切るための固定値。
  #
  # 2026-08-09 障害修正: 2026-08-06 の再起動 (DF-7 検証) 以降、この VM は名前解決が
  # 全滅していた。tailscaled のログは一貫して
  #   dns: resolver: forward: no upstream resolvers set, returning SERVFAIL
  # を吐いていた。仕組みはこうだった:
  #   1. tailnet 側は global nameserver を配っておらず「system default を使え」と指示する
  #   2. tailscaled は起動時に /etc/resolv.conf を読んで上流を決める
  #   3. しかし boot 直後は dhcpcd がまだ resolv.conf を書いておらず、空を掴む
  #   4. その後 tailscaled 自身が resolv.conf を 100.100.100.100 (=自分) で上書きする
  #   5. 以降、上流ゼロのまま誰も再読み込みしないので、公開名は永久に SERVFAIL
  # つまり dhcpcd と tailscaled の起動順レースで、負けると恒久的に壊れる。
  # ping は通り ssh も通るので、到達性テストでは検出できない (DF-7 はこれをすり抜けた)。
  #
  # ここで静的な nameserver を宣言すると resolvconf の固定エントリになり、DHCP の
  # タイミングに関係なく tailscaled が具体的な上流を読める。レース自体が消える。
  #
  # 却下案:
  #   - tailnet の admin console に global nameserver を設定する → 効くが tailnet 全体に
  #     効いてしまう上に dotfiles の外に出るので、この VM の構成として再現できなくなる。
  #     (併用は有効。あちらは他デバイスの保険になる)
  #   - --accept-dns=false で MagicDNS を捨てる → 一番簡単だが、VM から tailnet 名
  #     (mini など) が引けなくなる。ホスト側へ ssh し返す用途を潰すので採らない。
  #
  # Lima のゲートウェイ (192.168.5.2) も DNS を返すが、Lima のネットワーク実装に
  # 依存する値なので採らない。1.1.1.1 なら VM を作り直しても、Lima 以外へ移しても効く。
  networking.nameservers = [
    "1.1.1.1"
    "1.0.0.1"
  ];

  security.sudo.wheelNeedsPassword = false;

  # nix 設定は darwin/system.nix と揃える (キャッシュを共有するため)
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };
  nix.settings = {
    max-jobs = "auto";
    trusted-users = [
      "root"
      username
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    always-allow-substitutes = true;
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
      "https://cclens.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "gigun.cachix.org-1:jP3ksvzV3coFUQORcYZOR3repURIK+eYtpMiIMaN788="
      "cclens.cachix.org-1:0QUNU6PuVyf+yXOvg3n1rd3FksBoB3s3/Jty50iKRNQ="
    ];
  };

  # nixos-lima が生成するイメージのレイアウトに合わせた固定値。
  # ここを変えるとブートしなくなるので触らないこと。
  boot.loader.grub = {
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  fileSystems."/boot" = {
    device = lib.mkForce "/dev/vda1"; # /dev/disk/by-label/ESP
    fsType = "vfat";
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
    options = [
      "noatime"
      "nodiratime"
      "discard"
    ];
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # nix 管理外のプリビルド ELF バイナリを動かすための逃げ道。
  #
  # 動機: Cloudflare OS (workerd / wrangler) を 24/365 でこの VM に置きたい。wrangler は
  # 実行時に @cloudflare/workerd-linux-64 を npm から取ってくるが、これは FHS 前提でビルド
  # された素の ELF で、interpreter が /lib64/ld-linux-x86-64.so.2 を指している。NixOS には
  # そのパスが無いので、nix-ld 無しでは "No such file or directory" で即死する
  # (バイナリは存在するのに出るこのエラーが、NixOS 初見では最も分かりにくい)。
  #
  # 却下案:
  #   - nixpkgs の workerd を使う → wrangler は自分のバージョンに結合した workerd を
  #     同梱・起動する設計なので、外から差し替えても使われない。cloudflare-os の
  #     docs/integration-testing.md も「wrangler と workerd はバージョンが結合している」と
  #     明記している。
  #   - buildFHSEnv でラップ → 対象が wrangler だけなら成立するが、この VM はエージェント
  #     基盤で「npm/pip 由来のバイナリを試しに動かす」用途が今後も繰り返し出る。
  #     その都度ラッパを書くより、逃げ道を 1 本用意しておく方が総コストが低い。
  #
  # なお ~/.local/bin と同じ「例外レーン」の思想。宣言的管理を諦めた領域なので、
  # ここに頼るものが増えてきたら本来は nix 側へ引き上げるべきというサイン。
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # workerd は C++ 製なので libstdc++ が要る。nix-ld の既定セットには含まれないため明示。
    stdenv.cc.cc.lib
  ];

  # CLI ツール群は home-manager standalone (packages.nix) が入れる。
  # ここは VM を最低限操作できるだけの構成に留める。
  environment.systemPackages = with pkgs; [
    gitMinimal
    vim

    # ブラウザ自動化 (chrome-devtools-mcp / Playwright) の実体。
    #
    # なぜ packages.nix ではなくここか: packages.nix は
    # homeConfigurations.gigun-x86_64-linux として WSL と共用されている。WSL 側は
    # 「ブラウザ操作は Windows ネイティブの Chrome に localhost:9222 で繋ぐ」方針
    # (CLAUDE.md の Windows 規約) なので chromium は不要で、共用モジュールに置くと
    # WSL に数百 MB の死蔵が生まれる。mini-vm だけに効かせられる場所がここしかない。
    #
    # chrome-devtools-mcp は実行ファイルを環境変数では受け取らない (--executablePath /
    # --browserUrl / --wsEndpoint のみ。`bunx chrome-devtools-mcp@latest --help` で確認済み)。
    # よって MCP 登録時に絶対パスを渡す必要があるが、nix store パスは更新のたびに変わるため
    # /run/current-system/sw/bin/chromium という安定パスを指すこと。
    # systemPackages に置くのはこの安定パスを得るためでもある。
    chromium
  ];

  # Cloudflare OS を 24/365 常駐させる。
  #
  # 立ち位置: これは「試用インスタンス」であって本番デプロイではない。上流 README の
  # 本番セルフホスト手順 (workerd スタンドアロン) は COMING SOON のままで、KV / R2 /
  # Browser Rendering の代替が提供されていない。それらを miniflare が肩代わりしてくれる
  # `pnpm run-local` を常駐させるのが、現時点で自前ホストに一番近い形になる。
  # 上流が本番手順を出したら、ここは丸ごと置き換わる想定。
  #
  # user service ではなく system service にした理由: user service だと boot 時に上げるのに
  # loginctl enable-linger が要り、それは imperative な状態なので宣言から漏れる。
  # User= を指定した system service なら linger 不要でそのまま boot から上がる。
  #
  # ConditionPathExists でチェックアウトの存在を条件にしている。無いマシンや VM 作り直し
  # 直後に Restart=always と噛み合って無限再起動ループになるのを防ぐため
  # (条件不成立なら systemd は「起動せず成功扱い」にするので静かにスキップされる)。
  systemd.services.cloudflare-os = {
    description = "Cloudflare OS (wrangler dev + workerd) 試用インスタンス";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = "/home/${username}/ghq/github.com/cloudflare/cloudflare-os/package.json";

    # home-manager の profile には依存させない。nixpkgs の node/pnpm だけで完結させることで、
    # home 層の switch 状況に関係なくこのサービスが成立するようにする。
    # なお pnpm は package.json の packageManager (pnpm@11.17.0) を見て自分でその版へ
    # 切り替える (pnpm 10+ の managePackageManagerVersions が既定 true)。実際、手元の
    # pnpm 11.18.0 から起動しても install ログは "using pnpm v11.17.0" になっていた。
    # よってここの pnpm の版は一致していなくてよい。
    path = with pkgs; [
      nodejs
      pnpm
      git # run-local.mjs が git ls-files でソースのハッシュを取るのに使う
      bash
      coreutils
      # ps は wrangler のビルドパイプラインが子プロセスの掃除に使う
      # (`ps -o pid --no-headers --ppid <pid>` を spawn する)。無いと
      # "Error: spawn ps ENOENT" でサービスごと落ちる。対話 shell では
      # 常に PATH にあるため、systemd 化して初めて表面化した。
      procps
    ];

    environment.HOME = "/home/${username}";

    serviceConfig = {
      Type = "simple";
      User = username;
      WorkingDirectory = "/home/${username}/ghq/github.com/cloudflare/cloudflare-os";
      ExecStart = "${pkgs.pnpm}/bin/pnpm run-local";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # ChatGPT サブスク枠を OpenAPI 互換エンドポイントとして生やすブリッジ。
  #
  # 狙い: Cloudflare OS の AI プロバイダに ChatGPT の Codex 枠を使う。Cloudflare OS の
  # openai プロバイダは `openai-responses` を喋り、このブリッジは `/v1/responses` を
  # 実装しているので形式が合う。モデル登録側は provider=openai +
  # apiUrl=http://127.0.0.1:18080/v1 になる。
  #
  # なぜ mini でなければならないか: workshop-backend の compatibility_flags には
  # `global_fetch_strictly_public` が入っており、本番 Worker からは localhost や
  # プライベート IP へ fetch できない (SSRF 対策)。`wrangler dev` だけが意図的に
  # この制限を外している。つまりブリッジを使う構成は run-local と同居させるしかない。
  #
  # 127.0.0.1 に閉じているので --api-key は付けない。ブリッジ自身の README も
  # 「公開ネットワークに晒すなら --api-key 必須」としており、裏を返せばローカル限定なら不要。
  # tailscale serve が外に出しているのは 8787 だけで、このポートは出していない。
  #
  # ConditionPathExists は cloudflare-os と同じ理由。`codex login` がまだなら
  # ~/.codex/auth.json が無く、起動しても認証できずに Restart=always と噛み合って
  # 無限再起動になる。ログイン後に systemctl start すれば上がる。
  systemd.services.codex-openai-bridge = {
    description = "ChatGPT (Codex) 枠を OpenAI 互換 API として出すブリッジ";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = "/home/${username}/.codex/auth.json";

    # uvx は実行時に PyPI から取ってくる。nixpkgs に無いツールなので uv 経由にしている
    # (CLAUDE.md の「~/.local/bin は例外レーン」と同じ発想で、宣言できないものを一箇所に隔離する)。
    # TODO: バージョンを固定していないので上流の破壊的変更をそのまま踏む。
    #       安定して使うと決めたら openai-api-server-via-codex==X.Y.Z に固定すること。
    path = with pkgs; [
      uv
      cacert # uv が PyPI へ HTTPS で取りに行くのに要る
    ];

    environment = {
      HOME = "/home/${username}";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

    serviceConfig = {
      Type = "simple";
      User = username;
      WorkingDirectory = "/home/${username}";
      ExecStart =
        "${pkgs.uv}/bin/uvx openai-api-server-via-codex serve"
        + " --host 127.0.0.1 --port 18080"
        + " --auth-json /home/${username}/.codex/auth.json";
      Restart = "always";
      RestartSec = 10;
    };
  };

  system.stateVersion = "26.05";
}
