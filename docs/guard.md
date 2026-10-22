# Takumi Guard

匿名 Guard の正本は `npm/npmrc`、`bun/bunfig.toml`、`uv/uv.toml`、`pip/pip.conf`。
Home Manager の `nix/modules/home/guard.nix` が内容を世代へ固定する。Guard では
`mkOutOfStoreSymlink` を使わず、checkout の変更だけで適用済み設定が変わらないようにする。
Python のプロジェクト依存は引き続き uv が管理し、pip は新規導入しない。

配置先は `~/.npmrc`、`~/.bunfig.toml`、`$XDG_CONFIG_HOME/.bunfig.toml`、
`$XDG_CONFIG_HOME/uv/uv.toml`、`$XDG_CONFIG_HOME/pip/pip.conf`。
XDG 未設定なら `~/.config`。macOS では pip が優先して読む
`~/Library/Application Support/pip/pip.conf` にも同じ内容を置く。
Bun は XDG 設定時と未設定時で探索先が変わるため両方を持つ。

Nix を適用しないホストでは `bash bootstrap.sh --guard-only` でこの設定だけをコピーする。
通常の bootstrap も同じスクリプトを呼ぶ。全体の bootstrap / activation はツール導入等も
行うため、Guard だけを直すときは実行しない。既存の設定に別の値や認証項目があれば、
全配置先の事前検査で停止して既存ファイルを保持する。欠損した正本も失敗扱いにする。
Pro でも今回のように全体 activation を避ける必要がある場合に限り同じ限定コピーを使う。
Home Manager の世代切替とは別なので、次の通常適用まで世代番号は変わらない。
通常の管理経路は Home Manager のままで、限定コピーは恒久的な別の自動適用系ではない。

限定コピーと宣言の内容が同じなら Home Manager の `checkLinkTargets` は通過する。
このリポジトリの `backupFileExtension = "backup"` により通常ファイルは退避され、
`linkGeneration` で管理リンクへ置き換わる。現ホームの6ファイルには退避先の衝突がないことを
確認済み。別の設定へ変更済みで既存 backup もある場合は、その衝突を解消するまで適用しない。
`GUARD_CHECK_REAL_HOME=1 python3 -I -S -B scripts/tests/guard-settings.py HomeManagerHandoff`
は、適用済み世代の検査・リンク用スクリプトを使い、実ホームでは読取専用検査だけを行う。
リンク作成・backup の試験は一時ホームに限定し、全体 activation は実行しない。

Git flake は未追跡の新規ファイルを含めない。`guard.nix`、`pip/pip.conf`、`uv/uv.toml`
等の新規ファイルは適用前に `git add` が必要で、ステージだけでもローカル flake の対象になる。
変更の追跡と設定の世代切替は別であり、ステージ・検査の成功を HM 適用完了とは扱わない。

`python3 -I -S -B scripts/guard-check.py` はソースと実配置の一致、変更可能な checkout
へのリンク、環境変数による上書きを読み取り専用で確認する。`--scan <project-root>` を
追加すると npm / bun / uv / Poetry / pip のプロジェクト設定を走査する。
終了コードは 0 が一致、1 が欠損・未反映・読取失敗、2 が上書き検出。値・トークンは表示しない。
`-I -S` は `.pth` と `sitecustomize.py` を読み込ませないために付ける。

環境変数・CLI 引数・プロジェクト設定はユーザー設定より優先され得る。`--no-config`、
明示的な設定ファイル、直接 URL、既存 lockfile やキャッシュの利用も含め、レジストリ指定は
ネットワークの強制遮断ではない。プロジェクト設定は一括変更せず検出して判断する。
`.zshrc` からの export は廃止したが、起動済みシェルの変数は終了まで残る。
既存シェルで明示的に渡した認証や別の index を勝手に unset しない。

トークンを含めない匿名構成なので、アカウント連携・ダウンロード追跡・事後通知は別途の
判断になる。Guard はすべての悪性パッケージを遮断できる保証ではない。

仕様: [uv](https://docs.astral.sh/uv/concepts/configuration-files/)、
[pip](https://pip.pypa.io/en/stable/topics/configuration/)、
[Bun](https://bun.sh/docs/runtime/bunfig)、
[Guard](https://shisho.dev/docs/t/guard/quickstart/pypi/)。

## 通常適用後の確認

以下は、別途承認された通常 switch が完了した後の読み取り確認である。
今回の限定コピー・宣言評価だけでは、この状態に到達していない。

1. `readlink /run/current-system` で切替後の system を記録する。
2. `bash scripts/check.sh --declarations` で6件の enable/hash と配置の一致を確認する。
3. 次の6パスがシンボリックリンクになり、参照先が `/nix/store/` 内の
   Home Manager の `home-manager-files` を経由することを `ls -ld` / `readlink` で確認する。
   `.npmrc`、`.bunfig.toml`、`.config/.bunfig.toml`、`.config/uv/uv.toml`、
   `.config/pip/pip.conf`、`Library/Application Support/pip/pip.conf`（すべてホーム相対）。
   単に正本と同じ通常ファイルがあるだけでは、HM 管理完了としない。
4. 新しいシェルでも環境上書きを確認し、利用プロジェクトを必要な範囲だけ
   `guard-check.py --scan <project-root>` で確認する。任意パッケージのインストールは不要。

退避先 `.backup` の衝突や、既存内容が正本と違う場合は上書きして進めない。
共通の操作と PATH の確認は [初期準備と通常適用](setup.md) を参照。
