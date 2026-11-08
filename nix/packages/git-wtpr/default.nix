# git-wtpr: GitHub の PR を git-wt の worktree として開く。
# 出典: https://github.com/ryoppippi/dotfiles nix/packages/git-wtpr (MIT License,
# Copyright (c) ryoppippi)。シェル連携は zsh 用の init.zsh だけ持つ (理由は init.zsh 冒頭)。
{
  lib,
  writeShellApplication,
  runCommand,
  nushell,
  gh,
  git,
  git-wt,
}:
let
  # `--init zsh` は git-wtpr.nu と同じディレクトリの init.zsh を読む。
  # `${./git-wtpr.nu}` 単体だと store に別々のパスで置かれ、隣が見えない。
  src = runCommand "git-wtpr-src" { } ''
    mkdir -p $out
    cp ${./git-wtpr.nu} $out/git-wtpr.nu
    cp ${./init.zsh} $out/init.zsh
  '';
in
writeShellApplication {
  name = "git-wtpr";
  runtimeInputs = [
    nushell
    gh
    git
    git-wt
  ];
  text = ''
    exec nu ${src}/git-wtpr.nu "$@"
  '';
  meta = {
    description = "Open a GitHub pull request in a git-wt worktree";
    homepage = "https://github.com/ryoppippi/dotfiles";
    license = lib.licenses.mit;
    mainProgram = "git-wtpr";
    platforms = lib.platforms.unix;
  };
}
