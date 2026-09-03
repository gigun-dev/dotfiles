{ ... }:
let
  # スクリプト本体は .nix に埋め込まず別ファイルに置く。
  # 理由は 2 つ:
  #   1. 「設定ファイル自体は nix に依存しない」という このリポジトリの設計原則
  #      (CLAUDE.md)。障害の最中に `bash nix/modules/darwin/network-watchdog.sh` を
  #      手で叩けることが、番人にとっては本質的に重要 (switch できない状態でも走らせたい)。
  #   2. nix 文字列に埋めると ''${...} のエスケープが要り、shellcheck も掛からなくなる。
  #
  # Why not pkgs.writeShellApplication: ビルド時に shellcheck を要求する。
  # x86_64-darwin は nixpkgs 26.11 で drop されており (CLAUDE.md 参照)、
  # このホストでビルド可能な derivation は少ないほど良い。検証は手元 (aarch64) で
  # shellcheck を掛けて担保する。
  # Why not pkgs.writeShellScriptBin: nixpkgs の bash 5 で動くことになるが、
  # 実測したのは macOS 標準の /bin/bash (3.2)。**試した形のまま**動かしたいので
  # 素のファイルを store に置き、/bin/bash で起動する。
  # ついでに nix store が読めない状況 (それ自体は考えにくいが) への依存も 1 つ減る。
  watchdogScript = ./network-watchdog.sh;
in
{
  # 常時起動ホスト (mini) 専用。⭐️ このモジュールを import するかどうかは
  # flake.nix の mkDarwinSystem の `alwaysOn` が決める。
  # ⛔️ system == "x86_64-darwin" で分岐しないこと: mini が Intel なのは偶然で、
  # 「常時起動の拠点である」という事実とは無関係。詳細は flake.nix のコメント。
  #
  # ⚠️ ただし 2026-09-03 現在、このモジュールは唯一の常時起動ホストである実機
  # mini には**届いていない**。mini の macOS は nix 管理を凍結中 (CLAUDE.md の
  # 凍結の節) で、x86_64-darwin の darwin 構成は評価できない。実機には
  # `bootstrap.sh --net-watchdog` が**同じ network-watchdog.sh** を user agent
  # (label: dev.gigun.net-watchdog / 出力先: ~/Library/Logs/net-watchdog) として
  # 当てている。sudo 1 回で system daemon へ昇格するのは
  # net-watchdog-system-install.sh。
  # ⛔️ 「使われていないから」とこのモジュールを消さないこと: mini を
  # Apple Silicon に替えた日、alwaysOn を付け替えるだけでこの system daemon
  # (/var/log/net-watchdog) がそのまま効く。消すと同じ設計をやり直すことになる。

  # 出力先ディレクトリは activation で先に作る。
  # なお apple-container.nix も postActivation.text を書くが、この option は
  # types.lines なので両方が連結される (どちらかが消えることはない)。
  # スクリプト自身も mkdir -p するが、
  # launchd は ProgramArguments を起動する**前**に StandardErrorPath を open するので、
  # ディレクトリが無いと最初の 1 回がジョブごと spawn 失敗する (スクリプトまで到達しない)。
  system.activationScripts.postActivation.text = ''
    mkdir -p /var/log/net-watchdog
  '';

  launchd.daemons.network-watchdog = {
    serviceConfig = {
      # /bin/bash で起動する理由は上の watchdogScript のコメント参照。
      ProgramArguments = [
        "/bin/bash"
        "${watchdogScript}"
      ];

      # 起動間隔 30 秒。⛔️ 好みで選んだ数ではなく、下 2 つの制約の間にある値:
      #   下限: [実測 2026-09-03 mini] 全プローブが到達しない最悪ケースで 1 サンプル
      #         約 6〜7 秒 (ping ×2 / nc / dig がそれぞれ 2 秒で打ち切られる)。
      #         StartInterval は前回の終了を待たないので、間隔がこれに近いと
      #         サンプルが重なって互いのログを乱す。30 秒なら最悪でも 4 倍以上の余裕。
      #   上限: 連続 2 サンプルのデバウンスで復帰を撃つので、検知は最悪 2 間隔 =
      #         60 秒。2026-09-03 の障害は 7 時間続いたので、分の単位で気づければ十分。
      # 変えるときは network-watchdog.sh の MAX_BYTES (ログ量の計算) も直すこと。
      StartInterval = 30;

      # 再起動直後 (= 今回の復旧手段が使われた直後) こそ観測したいので即座に 1 回走らせる。
      RunAtLoad = true;

      # launchd の既定 PATH は /usr/bin:/bin:/usr/sbin:/sbin。スクリプトが使う
      # route/ifconfig/ping (/sbin)、networksetup/netstat/ipconfig (/usr/sbin)、
      # nc/dig/awk/sed (/usr/bin) は全てこの中にある。
      # [実測 2026-09-03 mini] 手動実行もこの PATH を明示して通している。
      # 明示するのは、将来 nix の PATH が混ざって「どの ping か」が変わるのを防ぐため。
      EnvironmentVariables.PATH = "/usr/bin:/bin:/usr/sbin:/sbin";

      # スクリプト自身の出力は samples.jsonl に行く。ここに来るのは想定外の
      # エラーだけ (= 番人が黙って壊れたときの唯一の手掛かり) なので残す。
      # 標準出力は捨てる: 正常時は何も書かないので、あっても空ファイルが増えるだけ。
      StandardErrorPath = "/var/log/net-watchdog/daemon.err";
    };
  };
}
