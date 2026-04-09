{
  config,
  pkgs,
  lib,
  ...
}:
{
  # programs.zsh.enable は nix-darwin 側 (system.nix) で有効化
  # home-manager 側では無効 — .zshrc は dotfiles リポから直接シンボリックリンク

  programs.direnv = {
    enable = true;
    enableZshIntegration = false; # .zshrc config cache handles this
    nix-direnv.enable = true;
    config.global = {
      warn_timeout = "0s";
      hide_env_diff = true;
    };
    stdlib = ''export DIRENV_LOG_FORMAT=""'';
  };
}
