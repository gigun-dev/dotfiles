# Linux CI の一時的な切り替え案

通常は GitHub-hosted を使う。本人が内容を確認した commit に限り、repository variable `DOTFILES_LINUX_CI=self-hosted` と `DOTFILES_CI_REVIEWED_SHA=<完全な commit SHA>` を設定すると、Nix CI の `changes` / `check` / `build` は専用 label `dotfiles-reviewed` の runner を選ぶ。PR は GitHub が生成する merge commit SHA、push / workflow_dispatch は実行対象 SHA を照合する。PR の head や base が進むと merge commit も変わるため再確認が必要。値が一致しなければ hosted を選ぶ。自動切り替えではない。

## mini-vm の候補

[未 import の NixOS module 案](../ci/linux-runner/mini-runner.nix) は、専用 system user、NixOS の GitHub runner と systemd sandbox を定義する。既定は無効で、明示的に import・有効化しない限りユーザーやサービスを作らない。短命の registration token は Nix store 外から渡す。1 job で登録解除する ephemeral runner とし、自動再登録・boot 起動はしない。ユーザーに sudo、docker group や `trusted-users` を与えない。NixOS 標準 runner module は登録前処理の一部を root で実行するため、導入・起動時はその権限と短命 token の受け渡しを別途確認する。

systemd は `ProtectHome` / `ProtectSystem` / `NoNewPrivileges` 等の NixOS module の既定に加え、Docker socket、agenix のリンクと実ディレクトリ、秘密ディレクトリと Tailscale socket を隠す。ただし、これは VM や強いネットワーク隔離ではない。ジョブは同じ kernel とネットワークを使い、公開された store や到達可能なサービス、ジョブ自身の token と runner の認証情報にはアクセスし得る。既存の秘密・socket・home の実際の権限とサービス到達先を登録前に確認する。信頼できないコードには使用しない。

mini-vm の Nix daemon を非 trusted client として使用し、job ごとの Nix client だけに `accept-flake-config = true` を設定する。既存の daemon 設定や trusted-users は変えず、GitHub Actions の writable `/nix` cache も復元しない。ただし production と同じ store を読み、daemon を通じて新しい store path やディスク使用量を増やす。store は秘密の保管場所にしない。daemon の sandbox と binary cache の信頼設定、非 trusted client が必要な build / substituter を使えることは実機検証が必要。Nix sandbox は build を対象とし、checkout / action / shell 全体を覆わない。runner unit の CPU・メモリ制限は外部 nix-daemon が起動する build には自動的に伝播しないため、資源上限と既存サービスへの影響は別に検証する。

SHA 変数と label は認可境界ではない。同じ repository の別 workflow も label を指定でき、workflow 自体を編集できる人は SHA 条件も変更できる。private repository の本人確認済みコードだけを対象にし、runner を起動する前に実行対象と他の queued job を確認し、使用後は停止・登録解除と作業領域の消去を確認する。runner が利用可能な間の想定外 job 割当を完全には防げないため、repository と workflow の権限を確認する。再利用前に状態を消しても、信頼できないコードを安全に実行できる保証にはならない。

macOS の `macos-regressions` と `mini-ansible` は hosted のまま。Linux 側の結果は macOS 検証を代替しない。branch protection の必須 check は `check` / `build` だが、mini-vm autoswitch は GitHub Actions の失敗 check 全体も判定する。macOS job が失敗すれば Linux の成功だけでは自動適用されない。

## 切り替えと戻し方

利用前に対象 SHA を確認し、短命 token を用意して runner を一時的に登録・起動したうえで、2 変数を設定する。登録・ユーザー作成・systemd 適用・変数変更は別途承認する。検証後は変数を削除し、runner の停止・登録解除と task-local な状態の処理を確認する。既に待機中の job は変数変更で自動的に振り直されない。job ごとに再登録が必要であり、3 job の順次・並行実行や cleanup の手順は未検証。
