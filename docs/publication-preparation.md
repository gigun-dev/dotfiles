# 公開準備

現在は準備段階であり、公開可能との判定でも visibility 変更の承認でもない。

## 優先して分離する範囲

| 対象 | 分類 | 非破壊で進める方法 |
|---|---|---|
| docs/security.md | 個人アカウント・鍵の役割・保管と復旧の運用情報 | 非公開正本の保持確認後、公開側は一般原則にする |
| ansible/mini-macos/inventory.yml | 実ホストの接続先・ユーザー | [例示 inventory](../ansible/mini-macos/inventory.example.yml) を追加し、非公開 `inventory.private.yml` を明示選択する導線を検証する。実運用 inventory の変更は後段 |
| nix/modules/home/programs/ssh/default.nix | ホスト固有の宛先・ユーザー・鍵参照 | 非公開入力設計と生成結果の互換性テストを先行する。Host/Include 順序、IdentityFile の累積、Darwin/Linux 差を維持 |
| docs/mini-vm.md、関連運用 docs、todo.txt | 内部構成・手順・運用メタデータ | 一文ずつ機密性と再現性を分類する。すべての内部名を機械的に削除しない |
| tofu/ と secrets/ の宣言 | リソース情報・暗号化秘密の受信者 | 実秘密を出力せず、公開してよいメタデータと不要な権限を分ける |

## 検証と保持

- 現行 `docs/security.md` は変更前に本人の非公開正本へ保全し、ハッシュ、再読取、権限とバックアップ先を確認する。旧 commit だけを唯一の退避先にせず、ignore を暗号化やバックアップと見なさない。
- [非公開運用台帳の索引例](private-inventory-index.example.md)には秘密値を書かない。参照先自体が機密なら索引も非公開にする。`docs/private/` と `ansible/mini-macos/inventory.private.yml` は ignore 対象であり、権限制御やバックアップではない。
- 限定restoreは[値なしmanifest](private-recovery-manifest.example.json)とread-only verifierでbyte一致を確認する。verifierは保管先の独立性、provider認証、別端末復旧を証明しない。
- 例示 inventory は到達不能な宛先で、既定 inventory として設定しない。Ansible はディレクトリ指定で複数ファイルを読み得るため、`-i` にはディレクトリではなく使用する inventory ファイルを明示する。既存の実運用 inventory は変更しない。
- inventory や SSH の挙動変更を文書改善に混ぜない。既存入力を使う場合の生成結果と fixture tests を確認する。
- ignore 設定は既存 tracked ファイルや履歴を消さない。`git check-ignore` の正例・負例を確認する。
- 公開対象の履歴、branch/tag、PR/issue、Actions 出力・artifact、Release 資産の確認は別の公開前 gate。現行 tree だけの検査で閉じず、旧監査後の追加 commit・artifact・Release も含める。

## 今ここでは行わない

visibility 変更、別 repo 作成、履歴 rewrite / force-push、秘密の使用テスト、鍵 rotation、SSH / VPN / sandbox 権限変更、実機 apply。これらは必要な時点で具体的な対象・影響を示す。
