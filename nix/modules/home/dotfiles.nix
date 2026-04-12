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

  # .zshrc は programs.zsh が管理するため home.file ではなく
  # home.activation で強制シンボリックリンク (ryoppippi パターン)
  # launchd-ui: unsigned app — download from GitHub Releases
  # https://github.com/azu/launchd-ui
  home.activation.installLaunchdUI = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    app="/Applications/launchd-ui.app"
    if [ ! -d "$app" ]; then
      arch="$(uname -m)"
      if [ "$arch" = "arm64" ]; then
        slug="aarch64"
      else
        slug="x64"
      fi
      url="https://github.com/azu/launchd-ui/releases/latest/download/launchd-ui_''${slug}.app.tar.gz"
      echo "Installing launchd-ui ($slug) ..."
      $DRY_RUN_CMD ${lib.getExe pkgs.curl} -fsSL "$url" | PATH="${pkgs.gzip}/bin:$PATH" ${pkgs.gnutar}/bin/tar xz -C /Applications
      $DRY_RUN_CMD /usr/bin/xattr -cr "$app"
    fi
  '';

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
