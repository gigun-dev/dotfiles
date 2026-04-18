{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.username = "gigun";
  home.homeDirectory = if pkgs.stdenv.isDarwin then "/Users/gigun" else "/home/gigun";
  home.stateVersion = "25.05";

  imports = [
    ./packages.nix
    ./dotfiles.nix
    ./programs/zsh
    ./programs/git
  ];

  programs.home-manager.enable = true;
}
