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
  };

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
  '';
}
