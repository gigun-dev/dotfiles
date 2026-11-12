# ASC executorの配置候補生成

`ansible/mini-macos/asc_executor_plan.yml`は通常の`apply.yml`から独立したcontroller上の入口である。miniへ接続せず、sourceの固定commitから4つのexecutorファイルとSHA-256 manifestを新規0700 directoryへ生成する。実行コード、toolchain、ユーザー、job directory、sudoers、runner、秘密はhostへ配置しない。

privateな変数ファイルに`asc_executor_plan_selected: true`、`asc_executor_source`（asc-mcp checkout）、`asc_executor_revision`（40桁commit）、`asc_executor_output`（新規directory）を指定する。以下はdotfiles repoから実行する。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook -i localhost, ansible/mini-macos/asc_executor_plan.yml --check -e @/private/path/executor-plan.yml
uv run --locked --project ansible/mini-macos ansible-playbook -i localhost, ansible/mini-macos/asc_executor_plan.yml -e @/private/path/executor-plan.yml
```

check modeも固定commitと対象sourceのclean状態、出力先の未存在を読み取り検査する。未選択、短縮SHA、対象4ファイルの未コミット変更、commitに不足したファイル、symlink、既存出力先は拒否する。worktreeの未コミットbytesへfallbackしない。manifestは予定のroot所有version directoryを示すだけで、適用承認ではない。

実配置にはsource revision/hashのレビュー、install先の全祖先・mode・ACL・symlink確認、既存build/signユーザーと各private job directoryの具体差分、別途保護されたtoolchain、ユーザーの明示適用承認が必要である。現在のhome配下ASCは保護済みtoolchainと見なさない。既存ファイルを上書きするapply入口はまだ実装しない。

これは候補生成の準備であり、恒久的UID分離や本番runnerへの接続が完成した証拠ではない。実機受入済みの基本アクセス制御は[単発fixture](asc-uid-fixture.md)、サービスの配置案はasc-mcpの`docs/asc-execution-plan.md`を参照する。
