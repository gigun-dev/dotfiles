# 公開前監査 2026-11-01

公開可能との判定ではない。[公開準備](publication-preparation.md)の gate を実測で補う。基準 main は `fb0e18dc953f3030ea3ac466c3359a5af8a4716d`。専用 clone / `audit/publication-coverage` で調査し、実機設定は適用していない。

## 実測範囲

| 資料 | 確認方法・結果 | 限界 |
|---|---|---|
| 現行 tree | tracked 280 files。公開準備・security の章構成・inventory・SSH・秘密宣言・CI 宣言を確認 | 全文の機密性判定は未完 |
| 到達可能 Git objects | 既存ローカル clone 由来 refs と取得した main から `rev-list --objects --all`、4,589 objects / 628 commits / 1,825 blobs / 18,878,274 bytes を検査。下記4形式の一致0 | remote 全refs取得の証明ではない。unreachable objects、削除refs、PR専用refsは対象外 |
| 運用情報の履歴 | `git log --all -- docs/security.md` は22 commits、実inventoryは2 commits | 現行版の置換だけでは履歴を消せない |
| PR / issues | `gh pr list --state all --limit 200 --json number,body,comments` で119 PR本文・118会話コメント。4形式の一致0。通常issueの全state一覧は0件 | inline review / review本文 / diff / 添付 / 削除済み内容は未検査。PR本文に運用語句候補あり |
| Actions | latest10 run metadata。既知 PCRE2 run `40437718383` の取得ログ67,928 bytesは4形式の一致0 | 全runログ、全attempt、cache bytesは未検査。先行調査の694 runという総数は今回再計測していない |
| PCRE2 artifacts | 同runの `pcre2-build` / `pcre2-verified` をローカル取得。補助ファイルとbottleの通常ファイル241件を各々読み取り検査し4形式の一致0 | archive内コードは実行していない。形式外の秘密、内部情報の意味判定は未完 |
| Releases | release一覧2件。PCRE2の `validated.json` 1,359 bytesとbottle 2,510,246 bytesを取得。JSON top-level fieldsはasset/formula/platform/provenance/reproducibility/verification/version。4形式の一致0 | fzfの2 assetsはbytes未検査。Release本文・履歴は未検査 |
| 非公開正本 | 索引例は未記入。指定の `docs/private/` は今回cloneにも既存主checkoutにも見つからない | 他の保管先がないとは言えない。実在backup・hash・再読取・権限・復旧可能性は未確認 |

4形式は private-key PEM/OpenSSH header、GitHub token (`gh[pousr]_` / `github_pat_`)、AWS `AKIA` access ID、Google `AIza` API key。Python標準ライブラリの正規表現で値を出さず件数だけ出力した。新scannerの導入はしていない。形式限定であり、汎用password、OAuth client secret、他provider、分割・符号化済み値の不在は示さない。age ciphertextは復号していない。

PCRE2 bottleのSHA256は build / verified / Release で全て `16b7d45ac5e4604605bae87a2faae5a84271c4c71b8a83bd871838f1c155b19b`。artifact期限切れでもReleaseコピーは残る。ローカルで読み取った通常ファイルと補助資料の合計は build 7,378,539 bytes、verified 7,378,622 bytes、Release 7,362,273 bytes（圧縮bottle自体のサイズとは異なる）。

履歴検査refsは local main / audit branch と `origin/{HEAD,main,chore/public-preparation,feat/mini-ansible,feat/mini-ripgrep-adoption,fix/portable-iterm-hook,fix/xdg-in-zshenv}`。main以外のremote-tracking refsは元cloneのsnapshotであり最新性未確認。tag refsはこのcloneで0件。先行調査で拒否された `/tags?per_page=100` と fzf per-workflow runs endpointは再取得・別routeでの迂回をしていない。

## 公開前に扱う情報の種類と所在

- `docs/security.md` はアカウント・鍵の役割、配置、既知の抜け道、復旧・移行計画を含む。値の検出とは別に、個人運用の分離判断が必要。
- `AGENTS.md`、`docs/mini-vm.md`、関連運用docs、`todo.txt` はホスト運用・アクセス境界・復旧のメタデータを含み得る。公開可能な再現手順との一文単位の分類が必要。
- `ansible/mini-macos/inventory.yml`、`nix/modules/home/programs/ssh/default.nix`、`tofu/`、`secrets/secrets.nix` は接続先・利用者・鍵参照・リソース・暗号化受信者の分類対象。
- PR本文の運用語句候補は #34, #35, #36, #38, #64, #81, #93, #99, #105, #106。`FileVault|~/.ssh|Tailscale|復旧|秘密|inventory` の候補抽出であり、それだけで秘密露出とは断定しない。review/patch等も含め公開可否を精査する。

## 最小の次の手順

1. 本人管理の既存非公開保管先を特定する。security原文・接続設定・復旧手順について保全対象と責任者を決め、hash、再読取、権限、別backupをread-only確認する。例示索引や旧Git commitを証明にしない。新規外部保存は別承認。
2. 保全確認後、公開側securityを一般原則にし、運用情報を切り分ける。inventory/SSHは既存挙動を維持する別変更とする。
3. 最新全refsと全履歴の範囲を合意する。履歴に残す情報の判断を記録する。rewriteや別repo化が必要なら対象・影響・保全を具体化して別承認を得る。
4. PR review/inline/patch/添付、全runログとcache、fzf assets、Release本文を追加監査する。制約で取得できない対象は未確認のままgateに残す。秘密の有効性テストはしない。
5. 直前mainとの差分と追加run/assetsを再検査し、全gateを本人が判断する。削除・rotation・visibility変更・mergeはこの監査の許可範囲外。

`todo ready` は既存の重複 `id:0116` を報告した。この監査では別タスクを改番していない。
