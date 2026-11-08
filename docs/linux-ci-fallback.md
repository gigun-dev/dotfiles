# Linux CI の一時的な切り替え案

通常は GitHub-hosted を使う。本人が内容を確認した commit に限り、repository variable `DOTFILES_LINUX_CI=self-hosted` と `DOTFILES_CI_REVIEWED_SHA=<完全な commit SHA>` を設定すると、Nix CI の `changes` / `check` / `build` / `nix-ci-gate`、fzf recipe test、mini Ansible portableは専用 label `dotfiles-reviewed` の runner を選ぶ。PR は GitHub が生成する merge commit SHA、push / workflow_dispatch は実行対象 SHA を照合する。PR の head や base が進むと merge commit も変わるため再確認が必要。値が一致しなければ hosted を選ぶ。自動切り替えではない。

## mini-vm の候補

[既定無効の NixOS module](../ci/linux-runner/mini-runner.nix) は mini-vm から import し、専用 system user、NixOS の GitHub runner と systemd sandbox を定義する。明示的に有効化しない限りユーザーやサービスを作らない。短命の registration token は Nix store 外から渡す。1 job で登録解除する ephemeral runner とし、自動再登録・boot 起動はしない。ユーザーに sudo、docker group や `trusted-users` を与えない。NixOS標準 runner moduleは登録前処理の一部をrootで実行するため、有効化・起動時はその権限と短命tokenの受け渡しを別途確認する。

systemd は `ProtectHome` / `ProtectSystem` / `NoNewPrivileges` 等の NixOS module の既定に加え、Docker socket、agenix のリンクと実ディレクトリ、秘密ディレクトリと Tailscale socket を隠す。ただし、これは VM や強いネットワーク隔離ではない。ジョブは同じ kernel とネットワークを使い、公開された store や到達可能なサービス、ジョブ自身の token と runner の認証情報にはアクセスし得る。既存の秘密・socket・home の実際の権限とサービス到達先を登録前に確認する。信頼できないコードには使用しない。

mini-vm の Nix daemon を非 trusted client として使用し、job ごとの Nix client に `accept-flake-config = true`、`max-jobs = 1`、`cores = 2` を設定する。既存の daemon 設定や trusted-users は変えず、GitHub Actions の writable `/nix` cache も復元しない。ただし production と同じ store を読み、daemon を通じて新しい store path やディスク使用量を増やす。store は秘密の保管場所にしない。daemon の sandbox と binary cache の信頼設定、非 trusted client が必要な build / substituter を使えることは実機検証が必要。Nix sandbox は build を対象とし、checkout / action / shell 全体を覆わない。`max-jobs` は client の同時 local build 数、`cores` は builder への並列度の目安であり、他 client や builder 自身に対する厳密な CPU・メモリ上限ではない。runner unit の CPU・メモリ制限は外部 nix-daemon が起動する build に伝播しない。必要な空き資源を確認し、既存サービスへの影響を監視する。

SHA 変数と label は認可境界ではない。同じ repository の別 workflow も label を指定でき、workflow 自体を編集できる人は SHA 条件も変更できる。private repository の本人確認済みコードだけを対象にし、runner を起動する前に実行対象と他の queued job を確認し、使用後は停止・登録解除と作業領域の消去を確認する。runner が利用可能な間の想定外 job 割当を完全には防げないため、repository と workflow の権限を確認する。再利用前に状態を消しても、信頼できないコードを安全に実行できる保証にはならない。

macOS ランナーを使う `macos-regressions.yaml` と `mini-ansible` の `native` は手動実行 (workflow_dispatch) だけで、push / PR では走らない (macOS は分の消費が Linux の 10 倍)。常時走る `mini-ansible` の `portable` は通常hostedのubuntuを使い、確認済みSHAだけself-hostedへ切り替える。Linux 側の結果はmacOS検証を代替しないので、Darwinの回帰はPro上の `nix build .#checks.aarch64-darwin.*`、Ansibleのnative fixtureは `sh ansible/mini-macos/verify.sh native` で手元確認する。移行後のbranch protectionは一意な `nix-ci-gate` だけを必須にし、条件付きの `check` / `build` はgate内で検証する。mini-vm autoswitchは対象commitのGitHub Actionsの失敗check全体も判定するため、`mini-ansible`の`portable`やfzf recipe testが失敗したcommit、または手動実行したmacOS jobが失敗したcommitは自動適用されない。手動実行しない限りmacOS jobのcheck runは存在せず、判定に現れない。

## 切り替えと戻し方

対象 SHA と他の待機 job を確認し、2 変数を設定してから新しい run を起動する。既に待機中の job は変数変更で自動的に振り直されない。短命 token を用意してrunnerを起動し、job終了後の登録解除を確認する。続くNixの`check` / `build`、fzf recipe test、mini Ansible portableはどれが先に割り当てられてもよいが、同時実行せず、一つずつ手動で再登録する。最後に`nix-ci-gate`用にも再登録する。各jobの終了と登録解除を確認し、tokenが期限切れなら再発行する。いずれかのjobが失敗した場合も後始末する。登録・ユーザー作成・systemd適用・変数変更は別途承認する。検証後はserviceを停止し、残ったrunnerの登録を解除、2変数を元に戻し、専用token・state・work・logを処理する。

2026-11-09 に commit `8e9cba03` の workflow_dispatch (run 42495442825) で4回の登録と解除を実測した。`changes` と `build` は成功し、`check` の既存fixture失敗を `nix-ci-gate` がfailureへ集約した。各job後にrepository runnerが0へ戻ること、最後にvariables・token・state・work・logを削除し、mini-vmを既知のboot profileへ戻すことも確認した。これは失敗を成功扱いしない経路の受入であり、全job greenの受入はfixture修正後に別runで行う。

同日、fixture修正後の commit `f77f292e` の workflow_dispatch (run 42496923598) では `changes`、`check`、`build`、`nix-ci-gate` がすべて成功し、各job後にrunnerが0へ戻った。ただし `workflow_dispatch` の成功はPRのrequired checkを満たさない。branch protection移行には、最新baseとのmerge commitを対象にした `pull_request` runで同じ結果を確認する。

その後、最新baseとcommit `94f91e2b` のmerge commitを対象にした `pull_request` run 42498932748 (attempt 2) でも4jobすべてが成功した。各jobを別のephemeral登録で実行し、終了ごとにrunnerが0へ戻ることを確認した。この結果を受入根拠として、mainのrequired checksへ旧`check` / `build`を残したまま`nix-ci-gate`を追加した。gate単独化はmain上の受入とrollback確認後に行う。
