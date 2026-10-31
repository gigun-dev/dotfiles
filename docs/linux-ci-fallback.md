# Linux CI の一時的な切り替え案

通常は GitHub-hosted を使う。専用環境を用意・検証した後にだけ、repository variable `DOTFILES_LINUX_CI` を `self-hosted` にすると、Nix CI の `changes`、`check`、`build` が `self-hosted` / `linux` / `x64` / `dotfiles-isolated` の全ラベルを持つ runner に割り当てられる。自動切り替えではない。この案だけでは runner は存在せず、該当 runner がオフラインまたは存在しない場合はジョブが待機する。

## 専用 runner の前提

- x86_64 Linux の隔離された一時環境で、ホストの個人ファイル、鍵、認証情報、keychain、管理用ソケット、運用中の `/nix` store や VM を公開しない。共有ホスト上の別ユーザーや別ディレクトリだけでは不足する。
- 信頼できる変更だけを実行し、PR のコードが任意のコマンドを実行できる前提で扱う。runner の権限、ネットワーク、実行後の破棄・初期化を登録前に確認する。[Lima 設定案](../ci/linux-runner/lima.yaml) は plain モードを使用するが、既定のゲストネットワークからホストや mini-vm に到達できない保証はない。登録前に通信境界を設計・検証する。
- 専用 guest に Nix を事前導入し、[設定案](../ci/linux-runner/nix.conf)を使う。flake の substituter と署名鍵を受け入れられること、必要なアクセス・容量・時間制限と KVM の有無を事前に確認する。preflight は OS、architecture、設定を検査するが、隔離を証明しない。
- self-hosted では setup-nix と GitHub Actions の writable `/nix` store cache を使わない。運用中の store にキャッシュを復元しない。hosted の setup と cache は従来どおり。

Lima 設定案の 2 CPU / 4 GiB / 50 GiB は初回検証用の仮値で、現行 mini-vm と同時に稼働できることや build の所要量を証明しない。image の URL・digest は Lima 2.2.0 の固定例で、取得可否と provenance を作成前に確認する。plain mode でも Lima の管理用 SSH identity は存在する。ホストの秘密・store・checkout・管理 socket は mount しない。runner は常時稼働させず、1 job ごとに使い捨て、guest 自体も再初期化する。GitHub への outbound 接続と repo に限定した登録が必要。登録 credential は repo や guest image に焼き込まない。

macOS の `macos-regressions` と `mini-ansible` は変更しない。Linux 側だけでは macOS 検証を置き換えられない。branch protection の必須 check は `check` / `build` だが、mini-vm autoswitch は GitHub Actions の失敗 check 全体も判定する。macOS job が失敗すれば Linux の成功だけでは自動適用されない。

## 戻すとき

repository variable を削除するか `self-hosted` 以外に戻すと、新しいジョブは GitHub-hosted を選ぶ。既に作成・待機中のジョブは自動で振り直されないため、対象 run を個別に扱う。runner の登録・停止、変数変更や run の再実行は別の操作として判断する。

runner 登録、短命 credential の発行、VM 作成・起動・資源割当、repository variable の変更は別途承認後に実施する。未使用時は guest と runner を停止する。候補 PR 自体で self-hosted を選ぶ場合も、この前提とチェックの実行結果を先に確認する。
