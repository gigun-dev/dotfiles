{ ... }:
let
  # スクリプト本体は .nix に埋め込まず別ファイルに置く。
  # 理由は 2 つ:
  #   1. 「設定ファイル自体は nix に依存しない」という このリポジトリの設計原則
  #      (CLAUDE.md)。障害の最中に `bash nix/modules/darwin/network-watchdog.sh` を
  #      手で叩けることが、番人にとっては本質的に重要 (switch できない状態でも走らせたい)。
  #   2. nix 文字列に埋めると ''${...} のエスケープが要り、shellcheck も掛からなくなる。
  #
  # Why not pkgs.writeShellScriptBin: nixpkgs の bash 5 で動くことになるが、
  # 実測したのは macOS 標準の /bin/bash (3.2)。**試した形のまま**動かしたいので
  # 素のファイルを store に置き、/bin/bash で起動する。
  # ついでに nix store が読めない状況 (それ自体は考えにくいが) への依存も 1 つ減る。
  watchdogScript = ./network-watchdog.sh;
in
{
  # 常時起動ホスト専用。⭐️ このモジュールを import するかどうかは
  # flake.nix の mkDarwinSystem の `alwaysOn` が決める。arch では分岐しない
  # (理由は flake.nix のコメント)。
  #
  # ⚠️ 今の darwin 構成に alwaysOn のホストは無く、このモジュールはどの機械にも
  # 当たっていない。Intel mini の macOS は Nix から外して Ansible へ移しており
  # (docs/mini-ansible.md)、実機では `bootstrap.sh --net-watchdog` が
  # **同じ network-watchdog.sh** を user agent (label: dev.gigun.net-watchdog /
  # 出力先: ~/Library/Logs/net-watchdog) として据えている。
  # 常時起動の Apple Silicon 機を新しい aarch64-darwin ホスト
  # として足す日に、alwaysOn を付ければこの system daemon (/var/log/net-watchdog) が効く。

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
      # 観測のみ。Wi-Fi の自動 off/on は行わない。
      EnvironmentVariables.NET_WATCHDOG_NO_REMEDIATE = "1";
      EnvironmentVariables.PATH = "/usr/bin:/bin:/usr/sbin:/sbin";

      # スクリプト自身の出力は samples.jsonl に行く。ここに来るのは想定外の
      # エラーだけ (= 番人が黙って壊れたときの唯一の手掛かり) なので残す。
      # 標準出力は捨てる: 正常時は何も書かないので、あっても空ファイルが増えるだけ。
      StandardErrorPath = "/var/log/net-watchdog/daemon.err";
    };
  };
}
