{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "gigun";
        email = "117321963+gigun-dev@users.noreply.github.com";
      };
      ghq.user = "gigun-dev";
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      # gh CLI を git の credential helper として使用 (Mac/Linux 共通)
      # 新マシンでは `gh auth login` 1 回で git push/pull が動く
      # Windows は GCM (Git Credential Manager) が標準、別途
      credential.helper = "!${pkgs.gh}/bin/gh auth git-credential";

      # SSH URL を強制的に HTTPS に rewrite → gh auth に統一、SSH 経路完全排除
      # Claude Code の plugin marketplace fetch 等で known_hosts prompt が出なくなる
      url."https://github.com/".insteadOf = "git@github.com:";
    };
  };
}
