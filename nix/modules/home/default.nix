{
  config,
  pkgs,
  lib,
  ...
}:
{
  home.username = "gigun";
  home.homeDirectory = if pkgs.stdenv.hostPlatform.isDarwin then "/Users/gigun" else "/home/gigun";
  home.stateVersion = "25.05";

  imports = [
    ./packages.nix
    ./dotfiles.nix
    ./guard.nix
    ./maintenance.nix
    ./programs/zsh
    ./programs/git
    ./programs/ssh
    ./programs/t3code
    ./programs/codex
    ./programs/agy
  ];

  programs.home-manager.enable = true;

  # Slack platform CLI は起動のたびに新版を検知して「今すぐ自動更新するか」を対話で聞いてくる。
  # y を押すとバイナリ実体 (cask なら Caskroom 配下) を自力で上書きするため、brew が記録する
  # バージョンと実体がズレて `brew upgrade` が効かなくなる。更新経路を brew に一本化するため
  # 検知自体を止める (`-s/--skip-update` フラグの環境変数版。永続設定は CLI 側に無い)。
  # AGY_CLI_DISABLE_AUTO_UPDATE と同じ「自己更新するツールを宣言管理下に置く」パターン。
  # なお Slack CLI は macOS にしか入れていないが、変数を撒いても未インストール環境では無害。
  home.sessionVariables.SLACK_SKIP_UPDATE = "1";

  # vivid LS_COLORS を build 時に評価して静的 export。
  # interactive 起動時の `vivid generate` を省いて起動を軽量化する。
  home.sessionVariables.LS_COLORS =
    let
      ls = pkgs.runCommand "ls-colors" { nativeBuildInputs = [ pkgs.vivid ]; } ''
        vivid generate gruvbox-dark > $out
      '';
    in
    lib.removeSuffix "\n" (builtins.readFile ls);
}
