# 初期準備と通常適用

通常の管理元は `~/ghq/github.com/gigun-dev/dotfiles`。Nix 導入済みの Pro では
`bash bootstrap.sh` が同じ `nix run .#switch` に委譲し、旧リンク処理を重ねない。
固定 checkout 以外からの誤適用は停止する。Nix 未導入なら従来の導入経路を残す。
初期の Nix 導入方式や鍵の準備を、この変更で新たに自動化するものではない。

| 操作 | コマンド | 範囲・副作用 |
|---|---|---|
| 限定検査 | `bash scripts/check.sh` | Guard の正本・配置・環境上書きを読む。activation なし |
| Guard 宣言評価 | `bash scripts/check.sh --declarations` | 同じ検査と6件の HM enable/hash。offline・lock書換なし・IFD禁止 |
| 全体ビルド | `nix run .#build` | 必要な取得・ビルド。設定は適用しない |
| 通常適用 | `nix run .#switch` | system/HM世代切替、Homebrew/uv等の既存 activation、cleanup（Cachix自動送信なし） |
| 依存更新 | `nix run .#update` | pull/rebase、全input更新、適用、lockのローカルcommit。pushなし |
| AI依存更新 | `nix run .#update-ai-tools` | 指定AI input更新、以降は既存updateと同じ |

cleanup は `uninstall`（宣言外のアプリをアンインストールし、zap stanza の追加削除はしない）。
Cachix のキャッシュ取得設定は維持し、通常 switch/update の自動送信は行わない。
明示送信の対象・公開範囲は別判断で、全 store 送信を別コマンドへ移設していない。
通常適用は Guard だけを反映する操作ではない。
main 上の Git hooks による自動 switch と既存の Git 運用も維持する。

検査の Python は `-I -S -B` で起動し `.pth` 等を読まない。
必要なら `CHECK_PYTHON=/absolute/path/to/python3 bash scripts/check.sh` で既存の実体を指定する。
宣言評価は Nix デーモンの許可が必要な場合があり、拒否時は再試行や迂回をしない。
`ls-colors` は既存の IFD を使うため、IFD 禁止の全体評価では止まる。
Guard 個別評価の成功は、全体ビルドや activation の成功を示さない。
activation の dry-run でも独自処理が書き込む場合があるため、検査に使わない。
新規ファイルは Git flake の対象になるよう、内容を確認して個別に stage する。

## PATH の確認

`.zshrc` は `__NIX_DARWIN_SET_ENVIRONMENT_DONE` がある場合、installer profile を
再読込しない。standalone/WSL の従来初期化は残す。既存シェルの PATH を書き換える処理ではない。
将来の承認済み適用後、新しく nix-darwin の環境を読み込んだログイン環境で
`command -v nix`、`nix --version`、`/run/current-system/sw/bin/nix --version` を比べる。
単に既存シェルで `.zshrc` を source しても、継承済みの古い PATH は修復されない。

`python3 -I -S -B scripts/tests/zsh-startup.py` は macOS の実 zsh でログイン／非ログイン・
対話／非対話の4通りと `.zshrc` 再読込を検査する。一時 HOME/ZDOTDIR の中に配置した
本番 `.zshenv`・`.zprofile`・`.zshrc` を使い、絶対パスを一時領域に置換する。
監査済み `/etc/zshenv` は早期 return、他の global rc は `-d` で抑止し、Darwin の
環境初期化とbrew shellenvはfixture、補完／prompt／plugin読込とzcompileはstubとする。
OrbStackの追加宣言は一時パスで実行し、vendor initは読まない。
実 Homebrew・Nix・サービス・ネットワークは実行しない。したがって実ログイン環境と
外部 plugin の完全な統合テストではない。非 macOS や global rc の構造が違う場合は skip する。

追加案の `.zshenv` は `typeset -gU PATH path` で、先頭優先の順序を保ち重複を避ける。
新しい fixture 起動の全PATH順序、rc再読込、env/profile/rc再読込、継承環境でも
Nixの優先順位と一意性を検査済み。旧設定でBun/mise/Windsurf/localの重複が増えることも再現。
WindsurfのPATHやアプリは削除していない。管理元の一覧は [PATH](path.md)。
standalone の非対話シェルが `.zshrc` の fallback を読まない従来挙動も変えていない。

## Guard の引き継ぎ確認

通常適用前は限定コピーの通常ファイル、適用後は HM の世代リンクになることを確認する。
[Guard の確認手順](guard.md#通常適用後の確認) に従い、内容一致と管理リンクを別々に確認する。
Pro は通常適用後、6件の内容一致と HM 世代リンクを実機確認済み。mini/VM の適用を示すものではない。

## 凍結ホストと互換経路

Intel mini の Nix 適用凍結は解除しない。Nix 導入済み Intel Mac の bootstrap は停止する。
Guard 限定は `bash bootstrap.sh --guard-only`、読取検査は `bash scripts/check.sh`。
旧包括経路を意図して使う場合だけ `--legacy`、番人も必要なら `--net-watchdog`。
Nix 未導入の場合もこの包括経路に入り、CLT/Homebrew/uv tools の導入やリンク・launchd変更を伴う。
Guard の正本が欠けた checkout では、これらを始める前に停止する。
今回 mini と VM には接続・適用していない。

参考は [ryoppippi の bootstrap](https://github.com/ryoppippi/dotfiles/blob/d456236dd0075394908abc3f317854575f9b0f1c/nix/flake/apps/bootstrap.nix)
の共通 switch への委譲。cleanup は uninstall、Cachix は自動送信なし。
今後の明示送信の範囲や CA の更新は別課題として残る。
