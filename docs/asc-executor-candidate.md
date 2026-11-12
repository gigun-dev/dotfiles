# ASC executorの配置候補生成

`ansible/mini-macos/asc_executor_plan.yml`は通常の`apply.yml`から独立したcontroller上の入口である。miniへ接続せず、sourceの固定commitから4つのexecutorファイルとSHA-256 manifestを新規0700 directoryへ生成する。実行コード、toolchain、ユーザー、job directory、sudoers、runner、秘密はhostへ配置しない。

privateな変数ファイルに`asc_executor_plan_selected: true`、`asc_executor_source`（asc-mcp checkout）、`asc_executor_revision`（40桁commit）、`asc_executor_output`（新規directory）を指定する。以下はdotfiles repoから実行する。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook -i localhost, ansible/mini-macos/asc_executor_plan.yml --check -e @/private/path/executor-plan.yml
uv run --locked --project ansible/mini-macos ansible-playbook -i localhost, ansible/mini-macos/asc_executor_plan.yml -e @/private/path/executor-plan.yml
```

check modeも固定commitと対象sourceのclean状態、出力先の未存在を読み取り検査する。未選択、短縮SHA、対象4ファイルの未コミット変更、commitに不足したファイル、symlink、既存出力先は拒否する。worktreeの未コミットbytesへfallbackしない。manifestは予定のroot所有version directoryを示すだけで、適用承認ではない。

実配置にはsource revision/hashのレビュー、install先の全祖先・mode・ACL・symlink確認、既存build/signユーザーと各private job directoryの具体差分、別途保護されたtoolchain、ユーザーの明示適用承認が必要である。現在のhome配下ASCは保護済みtoolchainと見なさない。

## 独立したcreate-only配置helper

`scripts/asc_executor_install.py`は既定でplanだけを返す。manifestの承認済みSHA-256、4ファイルのhash・名前・予定mode・予定install先を検証し、既存targetを拒否する。全既存祖先はroot所有で他者書込不可、symlinkなし、明示ACLなしを要求する。許容可能なACLも自動採用せず別レビューに止める。

管理者はレビュー済みinstallerをroot所有・他者書込不可のdirectoryへinstallしてhashを確認する。引数は次の通り。`--apply`を省くと検査のみでhostを変更しない。

```sh
sudo /usr/bin/python3 <root-owned-installer> --bundle <candidate-directory> --manifest-sha256 <reviewed-manifest-sha256> --build-user <existing-build-user> --sign-user <existing-sign-user>
sudo /usr/bin/python3 <root-owned-installer> --bundle <candidate-directory> --manifest-sha256 <reviewed-manifest-sha256> --build-user <existing-build-user> --sign-user <existing-sign-user> --apply
```

applyは新規version directoryへroot:wheel 0444の4スクリプト、private job領域へ各実行ユーザー所有0700のbuild/sign directoryを作る。既存targetが一つでもあれば何も採用・上書きせず拒否する。失敗時はこの実行で作ったファイルと空directoryだけをcleanupし、再帰削除は行わない。既存job領域を使うupgrade、toolchain配置、ユーザー・sudoers・runner・サービス・署名資材は対象外である。単体fixtureのapplyはowner変更をmockしており、実root配置は別の受入である。

これは候補生成の準備であり、恒久的UID分離や本番runnerへの接続が完成した証拠ではない。実機受入済みの基本アクセス制御は[単発fixture](asc-uid-fixture.md)、サービスの配置案はasc-mcpの`docs/asc-execution-plan.md`を参照する。
