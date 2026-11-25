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

    # notebook は Colab と VS Code で交互に保存すると、execution_count と
    # metadata.language_info.version の書き換えだけで差分が埋まる。commit 時に落とす
    # filter と、diff から隠す textconv を下で定義する。出力は残す (--keep-output):
    # lect-machine-learning では実行結果ごと GitHub 上で提出・閲覧するため、出力を
    # 落とすと提出物が成り立たない。
    #
    # global に掛けるのは表示だけを変える diff=ipynb に限る。filter=nbstripout は
    # 自分の repo の .gitattributes に書く。clean filter は git が比較する内容そのものを
    # 変えるので、nbstripout を通さずに commit している他人の repo では触っていない
    # notebook が常に変更ありと判定され、pull の autostash でも消えず merge が止まる
    # (openai/codex で踏んだ)。
    attributes = [ "*.ipynb diff=ipynb" ];

    settings = {
      user = {
        # GitHub が web で作る merge commit はアカウント名で書かれるので、手元の commit もそろえる。
        name = "gigun-dev";
        email = "117321963+gigun-dev@users.noreply.github.com";
      };
      ghq.user = "gigun-dev";
      # git-wt が worktree を消すときに rm ではなく ゴミ箱へ送る。macOS は標準の /usr/bin/trash で
      # Finder のゴミ箱 (~/.Trash) に入れる (ryoppippi/dotfiles の trashCommand と同じ)。
      # Why not trash-cli を macOS でも使う: XDG のゴミ箱 (~/.local/share/Trash) に入り、Finder に
      # 出ず自動削除も効かないので、消した worktree が .build ごと溜まり続けた (2026-11-26 に 5.1GB)。
      # nix 側だけに置く: Linux の trash は nix 管理の CLI なので、nix の無い環境
      # (git/gitconfig 共有先) に書くと `git wt -d` が存在しないコマンドを呼んで壊れる。
      wt.remover =
        if pkgs.stdenv.hostPlatform.isDarwin then "/usr/bin/trash" else lib.getExe' pkgs.trash-cli "trash";
      init.defaultBranch = "main";
      pull.rebase = true;
      push = {
        autoSetupRemote = true;
        # --force-with-lease を、背後の fetch で追跡 ref だけ進んだ状態でも安全にする。
        # 手元に取り込んでいない remote の commit があれば force push を拒否する (ryoppippi)
        useForceIfIncludes = true;
      };
      rebase = {
        autoStash = true;
        autoSquash = true;
        # スタックした branch の ref も rebase に追従させる
        updateRefs = true;
      };
      # 同じ conflict を二度解かない
      rerere = {
        enabled = true;
        autoupdate = true;
      };
      merge.conflictstyle = "zdiff3";
      fetch.prune = true;
      # origin だけ。fetch.pruneTags を global にすると、release tag を持たない
      # fork remote を fetch したときに手元の tag が消える (ryoppippi f624e326)
      remote.origin.pruneTags = true;
      # gh CLI を git の credential helper として使用 (Mac/Linux 共通)
      # 新マシンでは `gh auth login` 1 回で git push/pull が動く
      # Windows は GCM (Git Credential Manager) が標準、別途
      # 先頭の空値で継承した helper 一覧を消す。nix の git は system gitconfig に
      # osxkeychain を持ち、gh より先に呼ばれて git 更新のたびにキーチェーンの許可を求める。
      # gh が扱えるのは GitHub だけなので、他ホストは継承した helper のまま残す (ryoppippi と同じ形)
      credential =
        let
          gh = [
            ""
            "!${pkgs.gh}/bin/gh auth git-credential"
          ];
        in
        {
          "https://github.com".helper = gh;
          "https://gist.github.com".helper = gh;
        };

      filter.nbstripout = {
        clean = "${nbstripout} ${nbstripoutArgs}";
        smudge = "cat";
        # filter が失敗したら commit を止める (素通しすると未加工の notebook が入る)。
        required = true;
      };
      diff = {
        algorithm = "histogram";
        colorMoved = "plain";
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
