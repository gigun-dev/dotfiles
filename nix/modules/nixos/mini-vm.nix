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
  ];

  system.stateVersion = "26.05";
}
