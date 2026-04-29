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

  # vivid LS_COLORS を build 時に評価して静的 export。
  # interactive 起動時に `vivid generate` を fork する必要をなくし、
  # macOS zsh 5.9 の SIGCHLD race を踏まないようにする。
  home.sessionVariables.LS_COLORS =
    let
      ls = pkgs.runCommand "ls-colors" { nativeBuildInputs = [ pkgs.vivid ]; } ''
        vivid generate gruvbox-dark > $out
      '';
    in
    lib.removeSuffix "\n" (builtins.readFile ls);
}
