{
  config,
  pkgs,
  lib,
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
  nix.settings = {
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
    ];
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKlx087E31z7KurReQ1YHSKp5iw="
      "gigun.cachix.org-1:jP3ksvzV3coFUQORcYZOR3repURIK+eYtpMiIMaN788="
    ];
  };

  # TouchID sudo
  security.pam.services.sudo_local = {
    touchIdAuth = true;
    reattach = true;
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
  programs.zsh.enable = true;

  # macOS system defaults
  system.defaults = {
    # Dock
    dock = {
      autohide = true;
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
      KeyRepeat = 2;
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

    # iTerm2: plist (iterm2/com.googlecode.iterm2.plist) が source of truth
    # defaults は不要 (plist リストアで全設定が復元される)
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
