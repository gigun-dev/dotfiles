# git-wtpr: GitHub の PR を git-wt の worktree として開く。
# 出典: https://github.com/ryoppippi/dotfiles nix/packages/git-wtpr (MIT License,
# Copyright (c) ryoppippi)。シェル連携 (init.fish / init.bash) は持ち込まない。
{
  lib,
  writeShellApplication,
  nushell,
  gh,
  git,
  git-wt,
}:
writeShellApplication {
  name = "git-wtpr";
  runtimeInputs = [
    nushell
    gh
    git
    git-wt
  ];
  text = ''
    exec nu ${./git-wtpr.nu} "$@"
  '';
  meta = {
    description = "Open a GitHub pull request in a git-wt worktree";
    homepage = "https://github.com/ryoppippi/dotfiles";
    license = lib.licenses.mit;
    mainProgram = "git-wtpr";
    platforms = lib.platforms.unix;
  };
}
