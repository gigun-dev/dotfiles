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
    };
  };
}
