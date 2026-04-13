{
  config,
  pkgs,
  lib,
  ...
}:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  mkLink = path: config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/${path}";
in
{
  xdg.configFile = {
    "sheldon".source = mkLink "sheldon";
    "zeno".source = mkLink "zeno";
    "zsh/functions".source = mkLink "zsh/functions";
    "karabiner".source = mkLink "karabiner";
    "ccstatusline".source = mkLink "ccstatusline";
  };

  # launchd-ui: unsigned app — download from GitHub Releases
  # https://github.com/azu/launchd-ui
  # launchd-ui: unsigned app — download from GitHub Releases
  # https://github.com/azu/launchd-ui
  home.activation.installLaunchdUI = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    app="/Applications/launchd-ui.app"
    if [ ! -d "$app" ]; then
      arch="$(uname -m)"
      if [ "$arch" = "arm64" ]; then slug="aarch64"; else slug="x64"; fi
      url="https://github.com/azu/launchd-ui/releases/latest/download/launchd-ui_''${slug}.app.tar.gz"
      echo "Installing launchd-ui ($slug) ..."
      $DRY_RUN_CMD /usr/bin/curl -fsSL "$url" | /usr/bin/tar xz -C /Applications
      $DRY_RUN_CMD /usr/bin/xattr -cr "$app"
    fi
  '';

  # NotchBar: macOS notch notification app + CLI
  # https://github.com/azu/notchbar
  home.activation.installNotchBar = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    app="/Applications/NotchBar.app"
    if [ ! -d "$app" ]; then
      echo "Installing NotchBar ..."
      $DRY_RUN_CMD /usr/bin/curl -fsSL \
        "https://github.com/azu/notchbar/releases/latest/download/NotchBar.tar.gz" \
        | /usr/bin/tar xz -C /Applications
      $DRY_RUN_CMD /usr/bin/xattr -cr "$app"
    fi
  '';

  # uv: Python ランタイムを uv 管理に統一 (system python は 3.9 で古い)
  home.activation.installUvPython = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if command -v uv &>/dev/null; then
      $DRY_RUN_CMD uv python install 3.13 2>/dev/null || true
    fi
  '';

  # .zshrc は programs.zsh が管理するため home.file ではなく
  # home.activation で強制シンボリックリンク (ryoppippi パターン)
  home.activation.linkDotfiles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    link_force() {
      local src="$1" dst="$2"
      [ -L "$dst" ] && rm "$dst"
      [ -e "$dst" ] && mv "$dst" "$dst.backup"
      ln -sf "$src" "$dst"
    }
    link_force "${dotfilesPath}/zsh/.zshrc" "${config.home.homeDirectory}/.zshrc"

    # iTerm2 Dynamic Profiles
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/Library/Application Support/iTerm2/DynamicProfiles"
    link_force "${dotfilesPath}/iterm2/Profiles.json" "${config.home.homeDirectory}/Library/Application Support/iTerm2/DynamicProfiles/Profiles.json"

    # Claude Code (~/.claude/ は memory/log 等があるので個別リンク)
    $DRY_RUN_CMD mkdir -p "${config.home.homeDirectory}/.claude"
    link_force "${dotfilesPath}/claude/settings.json" "${config.home.homeDirectory}/.claude/settings.json"
    link_force "${dotfilesPath}/claude/hooks" "${config.home.homeDirectory}/.claude/hooks"
    link_force "${dotfilesPath}/claude/commands" "${config.home.homeDirectory}/.claude/commands"
    link_force "${dotfilesPath}/claude/skills" "${config.home.homeDirectory}/.claude/skills"
  '';
}
