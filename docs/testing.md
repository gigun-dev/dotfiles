# 検証の入口と範囲

手元と Linux CI の共通入口は `sh scripts/verify.sh`。個別 Python を直接重複実行せず、`nix flake check` が pin された依存を持つ checks を実行し、続けて `nix fmt -- --ci .` を実行する。ESP devShell の既存 IFD があるため全体 check に `--no-build` を付けない。

`.github/actions/setup-nix/action.yaml` が installer と GitHub Actions store cache の共通設定。cache は OS/arch/job/lock/config で分離し、PR は復元のみ、main の成功時だけ保存する。Cachix への送信や認証資格は追加しない。

| check | 対象・境界 |
|---|---|
| guard-settings | 一時 HOME で配置・既存認証保存・秘密非表示・欠損・上書き検知。評価済み Guard と本番 `.zprofile` の内容、cleanup option も検査 |
| guard-handoff | pin された HM の最小 fixture 世代から collision/link helper を読み、一時 HOME の既存ファイル・backup・リンクを検査。世代全体の activation は実行しない |
| setup-routing | bootstrap が本番と同じ routing/preflight 関数を使う。委譲・失敗伝播・凍結ホスト・worktree・backup 衝突を stub で検査。legacy installer は実行しない |
| switch-routing | 評価された共通 switch 本体の実行先を stub に置き換え、引数・終了コード・呼出し順・送信がないことを検査。sudo/rebuild は実行しない |
| developer-tools | 従来 verify.sh にあった execution-context/bridge/login/Bark/uv 等の fixture テスト。依存は Nix で固定 |
| mini-vm-narrow-mounts | 未適用の共有削減draft。本番宣言がhomeを保持し、純粋評価で拡張したcandidateだけがhomeを除外してtmp/rootを保持すること、Lima field案のpath allowlistと既存tmp tagを検査。実mount・VM停止・起動なし |
| zsh-startup | Darwin のみ。四起動モード・再読込・Nix優先順位・一意性・standalone/未導入 fallback を実 zsh と一時 HOME で検査。OS層・brew・plugin は fixture |

macOS 固有 check は Linux に存在させて skip するのでなく、Darwin checks と `macos-regressions` job で明示実行する。job は ARM macOS runner の対象 checks だけを build し、OS設定の全体build/switchをしない。`check` / `build` の既存 job 名は維持する。required status のサーバー側設定はこの変更で操作しない。

限定して実行する例:

```sh
nix build --no-link .#checks.aarch64-darwin.guard-settings .#checks.aarch64-darwin.guard-handoff .#checks.aarch64-darwin.setup-routing .#checks.aarch64-darwin.switch-routing .#checks.aarch64-darwin.zsh-startup
```

HM helper を抽出できない場合や監査済みの global zshenv の構造が変わった場合は失敗させる。実 HOME の collision check は自動 checks に含めない。実機適用・サービス・ネットワーク・実 credential の検証とは区別する。

新規 Nix module/script は Git flake に含まれる必要があるため、適用・check 前に作成した対象ファイルだけを stage する。無関係な staged 変更は混ぜない。
