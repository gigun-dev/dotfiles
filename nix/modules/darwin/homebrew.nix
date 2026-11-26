{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.homebrew;
  inherit (cfg) onActivation;
  brew = "${cfg.prefix}/bin/brew";
  # nix-darwin の activation と同じ derivation (同じ名前と中身) なので、宣言との食い違いは起きない。
  brewfile = pkgs.writeText "Brewfile" cfg.brewfile;

  # Brewfile の `trusted: true` は install 時にしか trust store へ反映されず、
  # 宣言した項目のうち自分で更新しないもの (azooKey・tailscale・cloudflared など) だけを上げる。
  # `brew outdated` は greedy でなければ auto_updates 付きの cask を出さないので、その一覧を
  # 名指しで upgrade し、auto_updates 付きはアプリ自身に任せる (onActivation.upgrade を使わない
  # 理由は下の homebrew の冒頭)。download は brew-prefetch agent が先に済ませておく
  # (nix/modules/home/maintenance.nix)。失敗しても system と bundle は適用済みなので、警告に留める。
  upgradeOutdated = ''
    brew update --quiet >/dev/null 2>&1 || true
    outdated=$(brew outdated --quiet 2>/dev/null) || true
    if [ -n "$outdated" ]; then
      mapfile -t names <<<"$outdated"
      echo "brew upgrade: ''${names[*]}" >&2
      if ! HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade "''${names[@]}"; then
        echo "warning: brew upgrade が失敗した。brew outdated で残りを確かめる。" >&2
      fi
      if [[ " ''${names[*]} " == *" azookey "* ]]; then
        echo "azooKey を更新した。ログアウトしてログインし直すまで、アプリで入力できない。" >&2
      fi
    fi
  '';

  # nix-darwin の activation は root から `sudo --user` で brew bundle を動かす。sudo 1.9.17 の
  # use_pty で activation は新しい pty に載り、sudo の timestamp は tty ごとなので、cask の
  # installer が呼ぶ sudo は switch で通した認証を使えず、端末の無い所で聞き直す。
  # switch app がこれを activation の後に利用者として、認証済みの端末で動かす
  # (ryoppippi/dotfiles の nix/modules/darwin/system.nix と同じ形)。
  brewBundle = pkgs.writeShellApplication {
    name = "brew-bundle";
    text =
      if config.dotfiles.homebrew.bundleAfterSwitch then
        ''
          export PATH=${cfg.prefix}/bin:${lib.makeBinPath [ pkgs.mas ]}:$PATH
          ${lib.optionalString (!onActivation.autoUpdate) "export HOMEBREW_NO_AUTO_UPDATE=1"}
          ${lib.concatLines (
            lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") onActivation.extraEnv
          )}
          # nix-darwin の activation と同じく、brew の無い機械 (bootstrap 前) では飛ばすだけにする。
          if [ ! -x ${brew} ]; then
            echo "error: Homebrew が無い (${brew})。brew bundle を飛ばす。" >&2
            exit 0
          fi
          brew bundle --file=${brewfile} ${
            lib.escapeShellArgs (
              lib.optional (!onActivation.upgrade) "--no-upgrade"
              ++ lib.optional (onActivation.cleanup == "uninstall") "--force-cleanup"
              ++ lib.optionals (onActivation.cleanup == "zap") [
                "--zap"
                "--force-cleanup"
              ]
              ++ onActivation.extraFlags
            )
          }
          ${upgradeOutdated}
        ''
      else
        ''
          echo "brew-bundle: この世代は Homebrew を扱わない。" >&2
        '';
  };
in
{
  options.dotfiles.homebrew.bundleAfterSwitch = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "switch app が activation の後に system の brew-bundle で Homebrew を揃えるか。";
  };

  config.system = {
    build = { inherit brewBundle brewfile; };
    systemBuilderCommands = ''
      ln -s ${lib.getExe brewBundle} $out/brew-bundle
    '';
    # root の activation から brew bundle を外す。理由は brewBundle の上。nix-darwin の
    # homebrew activation は brew bundle だけなので、root 側に残す準備は無い
    # (ryoppippi は nix-homebrew の setup-homebrew を残すが、ここは nix-homebrew を使わない)。
    # nix-darwin 内部の option 名に依存するので、lock を上げたら developer check
    # (homebrew-user-bundle) が通ることを確かめる。
    activationScripts.homebrew.text = lib.mkForce "";
  };

  config.homebrew = {
    enable = true;
    onActivation.cleanup = "uninstall";
    # 更新は onActivation.upgrade ではなく brew-bundle の upgradeOutdated (上) が行う。
    # 2026-11-25 に upgrade = true を試したところ、brew bundle が auto_updates 付きの cask
    # (Discord・Chrome・iTerm2・Zed など 7 個) まで upgrade し、どれも中身の空な .app を残して
    # 壊れた。auto_updates の無いもの (azooKey・1password-cli・slack-cli) と brews は無事だった。
    # Why not brew-nix (ryoppippi): azooKey は /Library/Input Methods へ入れる署名済み pkg で、
    # nix store から配る形にできない。

    taps = [
      "fayazara/tap" # screendrop の cask
      "k1LoW/tap"
      "rudrankriyam/tap"
    ];

    brews = [
      "asc" # App Store Connect CLI。署名・配布ツールは公式が案内するHomebrew経路で更新する。
      "cloudflared"
      "k1LoW/tap/mo"
      "tailscale"
      "rudrankriyam/tap/afm"
    ];

    casks = [
      "android-studio"
      "aqua-voice"
      "azookey"
      "claude"
      "claude-devtools" # Claude Code のセッション transcript を可視化する Electron アプリ。実体は GUI なので nix ではなく cask
      "1password"
      "1password-cli" # 公式の macOS 配布経路。Nix の CLI は unfree。
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
