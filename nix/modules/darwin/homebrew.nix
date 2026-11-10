{
  config,
  pkgs,
  lib,
  ...
}:
let
  isAarch64 = pkgs.stdenv.hostPlatform.isAarch64;
in
{
  homebrew = {
    enable = true;
    onActivation.cleanup = "uninstall";

    taps = [
      "fayazara/tap" # screendrop の cask
      "k1LoW/tap"
      "manaflow-ai/cmux"
    ]
    ++ lib.optionals isAarch64 [
      "rudrankriyam/tap"
    ];

    brews = [
      "asc" # App Store Connect CLI。署名・配布ツールは公式が案内するHomebrew経路で更新する。
      "cloudflared"
      "k1LoW/tap/mo"
      "tailscale"
    ]
    ++ lib.optionals isAarch64 [
      "rudrankriyam/tap/afm"
    ];

    casks = [
      "android-studio"
      "aqua-voice"
      "azookey"
      "claude"
      "claude-devtools" # Claude Code のセッション transcript を可視化する Electron アプリ。実体は GUI なので nix ではなく cask
      "cmux"
    ]
    ++ lib.optionals isAarch64 [
      "1password"
      "1password-cli" # 公式の macOS 配布経路。Nix の CLI は unfree。
    ]
    ++ lib.optionals (!isAarch64) [
      "codex" # Intel Mac のみ brew cask (Rust build 回避)。aarch64 + Linux は packages.nix で nix install
    ]
    ++ [
      "discord"
      "drawio" # GUI + headless export CLI (drawio -x ...) を同梱。CLI 目的でも実体は desktop app のため cask
      "figma"
      "fiji" # ImageJ ディストリ (Fiji Is Just ImageJ)。ARM ネイティブ。素の imagej cask は Gatekeeper 不通過で deprecated のため不採用
      "fork"
      # 作者の tap の cask (auto_updates true なので更新は Sparkle 任せ)。~/Applications に置く:
      # Sparkle が bundle を差し替えるので親がユーザー所有なら管理者認証が要らず、以前の
      # 置き場所とも同じ。~/Applications/Screendrop.app が既にある場合 (activation 版の残り)、
      # brew bundle は install 時に既定で --adopt を付けるので、入れ直さず brew 管理へ取り込む。
      {
        name = "fayazara/tap/screendrop";
        args = {
          appdir = "/Users/${config.system.primaryUser}/Applications";
        };
      }
      "google-chrome"
      "iterm2"
      "karabiner-elements"
      "monitorcontrol"
      "orbstack"
      "postman"
      "proxyman"
      "slack"
      # Slack app 開発用 platform CLI (`slack` コマンド)。デスクトップアプリの "slack" とは別物。
      # nixpkgs の slack-cli は rockymadden/slack-cli (メッセージ投稿用シェルスクリプト) という
      # 完全な別プロジェクトなので nix では入らない。公式インストーラ (~/.slack/bin) は
      # 宣言管理できないため cask を採用した。CLI だが「brew は GUI アプリのみ」の例外扱い
      # (tailscale / cloudflared と同じ列)。
      # 2026-08-10 移行: それまで公式 install.sh の ~/.slack/bin を ~/.local/bin から
      # symlink していた (v3.14.0 で固着)。self-update 抑止は home/default.nix の
      # SLACK_SKIP_UPDATE を参照。
      "slack-cli"
      "t3-code" # coding agent 用デスクトップ GUI (pingdotgg/t3code)。設定は home/programs/t3code で merge
      "tableplus"
      "thaw"
      "zed"
    ];

    masApps = {
    };
  };
}
