{
  config,
  pkgs,
  lib,
  ...
}:
let
  nbstripout = lib.getExe pkgs.nbstripout;
  nbstripoutArgs = "--keep-output --extra-keys 'metadata.language_info.version'";
in
{
  # 手で nbstripout を叩くときのため。filter と textconv は下で store パスを直接指す
  # (Fork 等の GUI クライアントは shell の PATH を持たず、required = true の filter が
  # 見つからないと commit 自体が失敗するため)。
  home.packages = [ pkgs.nbstripout ];

  programs.git = {
    enable = true;

    # isolation: worktree のサブエージェントが全リポジトリで .claude/worktrees/ を作る。
    # 各リポジトリの .gitignore に足して回らずに済ませるため、ここで一括して無視する
    ignores = [ ".claude/worktrees/" ];

    # notebook は Colab と VS Code で交互に保存すると、execution_count と
    # metadata.language_info.version の書き換えだけで差分が埋まる。全リポジトリで
    # commit 時に落とす。出力は残す (--keep-output): lect-machine-learning では
    # 実行結果ごと GitHub 上で提出・閲覧するため、出力を落とすと提出物が成り立たない。
    attributes = [ "*.ipynb filter=nbstripout diff=ipynb" ];

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

      filter.nbstripout = {
        clean = "${nbstripout} ${nbstripoutArgs}";
        smudge = "cat";
        # filter が失敗したら commit を止める (素通しすると未加工の notebook が入る)。
        required = true;
      };
      diff = {
        # textconv にも clean と同じ引数を渡す。素の `-t` だと出力の変更が diff から消え、
        # 作業ツリー側の language_info.version が毎回差分に出る (scratch で両方踏んだ)。
        ipynb.textconv = "${nbstripout} -t ${nbstripoutArgs}";
      }
      # `//` で外から足すと浅い merge で diff ごと上書きされ、ipynb が消える (実際に踏んだ)。
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        # plist を XML 変換して diff 可能にする (plutil は macOS のみ)
        plist.textconv = "plutil -convert xml1 -o -";
      };
    };
  };
}
