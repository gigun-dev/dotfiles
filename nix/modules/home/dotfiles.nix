{
  config,
  pkgs,
  lib,
  ...
}:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  mkLink = path: config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/${path}";
  isDarwin = pkgs.stdenv.isDarwin;
in
{
  xdg.configFile = {
    "sheldon".source = mkLink "sheldon";
    "zeno".source = mkLink "zeno";
    "zsh/functions".source = mkLink "zsh/functions";
    "ccstatusline".source = mkLink "ccstatusline";
  }
  // lib.optionalAttrs isDarwin {
    "karabiner".source = mkLink "karabiner";
  };

  # NotchBar: 開発ビルドをログイン時に自動起動 (darwin only)
  launchd.agents = lib.optionalAttrs isDarwin {
    notchbar = {
      enable = true;
      config = {
        Label = "com.github.gigun-dev.NotchBar";
        Program = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/notchbar/.build/debug/NotchBar";
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/tmp/notchbar.log";
        StandardErrorPath = "/tmp/notchbar.log";
      };
    };
  };

  # launchd-ui: unsigned app — download from GitHub Releases
  # https://github.com/azu/launchd-ui
  home.activation.installLaunchdUI = lib.mkIf isDarwin (lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    app="/Applications/launchd-ui.app"
    if [ ! -d "$app" ]; then
      arch="$(uname -m)"
      if [ "$arch" = "arm64" ]; then slug="aarch64"; else slug="x64"; fi
      url="https://github.com/azu/launchd-ui/releases/latest/download/launchd-ui_''${slug}.app.tar.gz"
      echo "Installing launchd-ui ($slug) ..."
      $DRY_RUN_CMD /usr/bin/curl -fsSL "$url" | /usr/bin/tar xz -C /Applications
      $DRY_RUN_CMD /usr/bin/xattr -cr "$app"
    fi
  '');

  # Linux: bash ログイン時に zsh へ exec (chsh 不要で宣言的に zsh デフォルト化)
  # Mac 側は nix-darwin の users.users.${username}.shell = pkgs.zsh で設定済み
  programs.bash = lib.mkIf (!isDarwin) {
    enable = true;
    initExtra = ''
      # Interactive shell で zsh があれば自動で exec
      if [[ $- == *i* && -z "$ZSH_VERSION" && -x "$HOME/.nix-profile/bin/zsh" ]]; then
        exec "$HOME/.nix-profile/bin/zsh" -l
      fi
    '';
  };

  # uv: Python ランタイムを uv 管理に統一 (system python は 3.9 で古い)
  home.activation.installUvPython = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if command -v uv &>/dev/null; then
      $DRY_RUN_CMD uv python install 3.13 2>/dev/null || true
    fi
  '';

  # .zshrc は programs.zsh が管理するため home.file ではなく
  # home.activation で強制シンボリックリンク (ryoppippi パターン)
  home.activation.linkDotfiles = lib.hm.dag.entryAfter [ "linkGeneration" ] (''
    link_force() {
      local src="$1" dst="$2"
      [ -L "$dst" ] && rm "$dst"
      [ -e "$dst" ] && mv "$dst" "$dst.backup"
      ln -sf "$src" "$dst"
    }
    link_force "${dotfilesPath}/zsh/.zshrc" "${config.home.homeDirectory}/.zshrc"

    # Claude Code (~/.claude/ は memory/log 等があるので個別リンク)
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.claude"
    link_force "${dotfilesPath}/claude/settings.json" "${config.home.homeDirectory}/.claude/settings.json"
    link_force "${dotfilesPath}/claude/hooks" "${config.home.homeDirectory}/.claude/hooks"
    link_force "${dotfilesPath}/claude/commands" "${config.home.homeDirectory}/.claude/commands"
    link_force "${dotfilesPath}/claude/skills" "${config.home.homeDirectory}/.claude/skills"
  '' + lib.optionalString isDarwin ''

    # iTerm2 Dynamic Profiles (darwin only)
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/Library/Application Support/iTerm2/DynamicProfiles"
    link_force "${dotfilesPath}/iterm2/Profiles.json" "${config.home.homeDirectory}/Library/Application Support/iTerm2/DynamicProfiles/Profiles.json"
  '');
}
