{
  config,
  pkgs,
  lib,
  userDefaultsManagedByAnsible ? false,
  ...
}:
let
  username = "gigun";
in
{
  # Fonts (home.packages だと macOS が認識しないため fonts.packages で管理)
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  # Nix settings (ryoppippi pattern)
  nix.gc = {
    automatic = true;
    interval = {
      Hour = 12;
      Minute = 0;
    };
    options = "--delete-older-than 7d";
  };
  # nix-darwin の既定ではログの出先が無く、日次の GC が走ったかも終了コードも残らない
  # (2026-11-08 の調査で、手動 GC で 14.2GiB 回収できた理由を確かめられなかった)。
  launchd.daemons.nix-gc.serviceConfig = {
    StandardOutPath = "/var/log/nix-gc.log";
    StandardErrorPath = "/var/log/nix-gc.log";
  };
  nix.settings = {
    # 日次の GC だけでは、評価のたびに増えるゴミ (path: で store に写ったリポジトリ全体など、
    # 1 個 816MB) に追いつかない日がある。空きが 20GiB を切ったら daemon がビルド中に
    # 50GiB まで GC する。値は 460GB ディスクの Pro に合わせた。
    min-free = 20 * 1024 * 1024 * 1024;
    max-free = 50 * 1024 * 1024 * 1024;
    max-jobs = "auto";
    trusted-users = [
      "root"
      username
    ];
    extra-experimental-features = [
      "nix-command"
      "flakes"
    ];
    always-allow-substitutes = true;
    extra-nix-path = "nixpkgs=flake:nixpkgs";
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
      "https://cclens.cachix.org"
    ];
    # numtide は署名鍵を 2 本使う。旧 cache.numtide.com-1 だけでは、現在 narinfo に付く
    # niks3.numtide.com-1 の署名が `not signed by any of the keys` で弾かれ、全部ローカルビルドになる。
    # 値を疑うときは numtide/system-manager の flake.nix を見る (flake.lock の narHash と取り違えた前例あり)。
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "gigun.cachix.org-1:jP3ksvzV3coFUQORcYZOR3repURIK+eYtpMiIMaN788="
      "cclens.cachix.org-1:0QUNU6PuVyf+yXOvg3n1rd3FksBoB3s3/Jty50iKRNQ="
    ];
  };

  # TouchID sudo。reattach (pam_reattach) は tmux / zellij 内でも Touch ID を通すため。
  # watchIdAuth は蓋を閉じた clamshell で Touch ID が使えないときの代替。
  # pam-watchid は aarch64-darwin 専用 (meta.platforms) なので Intel mini では評価させない。
  security.pam.services.sudo_local = {
    touchIdAuth = true;
    reattach = true;
    watchIdAuth = pkgs.stdenv.hostPlatform.isAarch64;
  };

  # Xcode CLT auto-install + Tailscale Magic DNS resolver
  system.activationScripts.preActivation.text = ''
    if ! /usr/bin/xcrun -f clang >/dev/null 2>&1; then
      touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
      PROD=$(/usr/sbin/softwareupdate -l | grep "\*.*Command Line" | tail -n 1 | sed 's/^[^C]* //')
      /usr/sbin/softwareupdate -i "$PROD" --verbose
    fi

    # Tailscale CLI 版は Magic DNS を自動設定しないため手動で resolver を作成
    mkdir -p /etc/resolver
    echo "nameserver 100.100.100.100" > /etc/resolver/ts.net
  '';

  # User
  system.primaryUser = username;
  users.users.${username} = {
    home = "/Users/${username}";
    shell = pkgs.zsh;
  };
  # /etc/shells に nix の zsh を登録 (chsh で login shell に指定可能にする)。
  environment.shells = [ pkgs.zsh ];
  programs.zsh = {
    enable = true;
    # /etc/zshrc を骨抜きにして dotfiles の zsh/.zshrc に一本化する (mozumasu pattern)。
    # /etc/zshrc による compinit/bashcompinit/promptinit の二重初期化を避ける。
    enableCompletion = false;
    enableBashCompletion = false;
    promptInit = "";
    interactiveShellInit = lib.mkForce "";
    # /etc/zshenv に書き出される。interactive 起動より早く評価され fork なし。
    # `brew shellenv` の path_helper fork を静的 export で代替。
    shellInit =
      let
        prefix = if pkgs.stdenv.hostPlatform.isAarch64 then "/opt/homebrew" else "/usr/local";
      in
      ''
        export HOMEBREW_PREFIX="${prefix}"
        export HOMEBREW_CELLAR="${prefix}/Cellar"
        export HOMEBREW_REPOSITORY="${prefix}"
        export PATH="${prefix}/bin:${prefix}/sbin''${PATH:+:$PATH}"
        export MANPATH="${prefix}/share/man''${MANPATH:+:$MANPATH}:"
        export INFOPATH="${prefix}/share/info:''${INFOPATH:-}"
        fpath=(${prefix}/share/zsh/site-functions $fpath)
      '';
  };

  # macOS system defaults
  system.defaults = {
    # Dock
    dock = {
      autohide = lib.mkIf (!userDefaultsManagedByAnsible) true;
      show-recents = true;
    };

    # Finder (ryoppippi pattern)
    finder = {
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      ShowPathbar = true;
      ShowStatusBar = true;
      FXEnableExtensionChangeWarning = false;
      FXPreferredViewStyle = "Nlsv"; # List view
    };

    # Global
    NSGlobalDomain = {
      # Keyboard (ryoppippi pattern)
      KeyRepeat = lib.mkIf (!userDefaultsManagedByAnsible) 2;
      InitialKeyRepeat = 25;

      # Disable auto-correct and substitutions
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;

      # Menu bar spacing
      NSStatusItemSpacing = 2;
      NSStatusItemSelectionPadding = 2;
    };

    # スクリーンショットをクリップボードに保存
    CustomUserPreferences."com.apple.screencapture".target = "clipboard";

    # Finder サイドバーを表示
    CustomUserPreferences."com.apple.finder".ShowSidebar = true;

    # "Close windows when quitting an application" を無効化
    CustomUserPreferences.NSGlobalDomain.NSQuitAlwaysKeepsWindows = true;

    # iTerm2: Custom Preferences Folder 機構で repo 内の plist を直接読み書き。
    # ~/Library/Preferences/com.googlecode.iterm2.plist にはこの bootstrap meta key
    # だけ宣言し、本体の設定は dotfiles リポ側 plist が single source of truth。
    # GUI 変更は iTerm2 終了時に repo 側 plist へ書き戻されるので、
    # `git diff iterm2/` で変更内容を確認して commit すれば反映される。
    CustomUserPreferences."com.googlecode.iterm2" = {
      LoadPrefsFromCustomFolder = true;
      PrefsCustomFolder = "/Users/${username}/ghq/github.com/gigun-dev/dotfiles/iterm2";
    };
  };

  # Mac Mini (Intel) — サーバー用途のためスリープ無効化
  power = lib.mkIf pkgs.stdenv.hostPlatform.isx86_64 {
    sleep.computer = "never";
    sleep.display = "never";
    sleep.harddisk = "never";
    restartAfterPowerFailure = true;
    restartAfterFreeze = true;
  };

  # Required for darwin-rebuild
  system.stateVersion = 6;
}
