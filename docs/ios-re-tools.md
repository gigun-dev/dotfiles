# iPhone / iPad アプリの解析準備

Pro の Home Manager が `ipatool` と `unfairplay` を配置する。ipatool は
flake.lock の nixpkgs、UnfairPlay は `nix/packages/unfairplay` の公式リリースと
依存ハッシュで固定する。適用はリポジトリの `nix run .#switch` を使う。

## IPA の取得

`ipatool auth login` を対話端末で実行し、メールアドレス・パスワード・2FA は
プロンプトへ入力する。資格情報をコマンド引数や dotfiles に書かない。
取得先は dotfiles の外にする。

```sh
ipatool auth login
ipatool download --app-id <App ID> --platform iphone --output /absolute/path/App.ipa
```

ライセンス未取得なら、App Store で取得してから再実行する。`--purchase` は
ライセンス取得を伴うので、ダウンロードと分けて判断する。

## UnfairPlay の初回設定と復号

Apple Silicon Mac のネイティブ Mac App Store にサインインし、対応する
iPhone / iPad アプリをインストールして一度起動する。同一 enrollment の
インストール済みアプリから初回モデルを作る。

```sh
sudo "$(command -v unfairplay)" setup --app /Applications/App.app
unfairplay decrypt --input /absolute/path/App.ipa
```

モデルは同一 Store enrollment に対応する IPA に使える。対応形式や整合性の検証に
失敗した場合、CLI の導入成功とは分けて扱う。モデル作成・実アプリの復号は
dotfiles の build や activation では実行しない。

Apple Account 認証、enrollment、復号モデル、元 IPA、復号結果はホスト側の非公開状態であり、
Git や Nix store に入れない。モデルをバックアップする場合は暗号化する。
上流の仕様は [UnfairPlay README](https://github.com/DrWhax/unfairplay/tree/v0.4.0) を参照。

## セキュリティキー付き Apple Account

Apple Silicon の Home Manager は `ipatool-security-key` も配置する。
実装・認証テストは private な [派生リポジトリ](https://github.com/gigun-dev/ipatool) で管理し、
dotfiles の `nix/packages/ipatool-security-key/default.nix` は検証済み commit と
Go 依存ハッシュ、Nix の libfido2 を固定する。別 flake は作らない。
責務の境界は [ADR 0019](adr/0019-private-ipatool-downstream.md) を参照。

private ソースは `builtins.fetchGit` が実行ユーザーの SSH 認証で取得する。
GitHub の `gigun-dev/ipatool` にアクセスできる SSH 鍵をホスト側で用意する。
トークンや秘密鍵を Nix 式・URL・derivation に書かない。ソース取得は Darwin 用の
このパッケージを評価するときに必要となり、Linux の通常ビルドには要求しない。
ビルドされたソース・成果物はローカル Nix store に置かれる。
Darwin switch は root で再評価するため、共有 switch 本体が Git の SSH transport にだけ
元ユーザーで動く wrapper を指定する。ユーザーの SSH 設定・known_hosts・agent を使い、
root 用の秘密鍵や known_hosts のコピーは作らない。通常の profile 更新・rollback 引数は
公式 darwin-rebuild に渡したままにする。
この transport による private repo の取得、Darwin の隔離 routing 検査、全体 build は確認した。
2026-11-17、ユーザーの対話端末で pull 後の switch 完了を受け入れた。
適用後の PATH 上で `ipatool-security-key --version` が `security-key-f6ef5b6` を返すことも確認した。

通常版とはコマンド名・Keychain サービス・セッション保存先を分ける。
認証時は Apple Account に登録した USB セキュリティキーを接続し、対話端末で実行する。

```sh
IPATOOL_SECURITY_KEY_CLIENT_PROFILE=reference-xcode ipatool-security-key auth login --security-key
ipatool-security-key download --app-id <App ID> --platform iphone --external-version-id <Version ID> --output /absolute/path/App.ipa
```

Home Manager 適用前は `nix run .#ipatool-security-key -- ...` でも起動できる。
`reference-xcode` は鍵検証段階の `X-MMe-Client-Info` だけを固定の参照値へ切り替える。
SRP・provisioning・proof・UA・Accept の全段階を一括置換せず、自動 fallback もしない。

メール・パスワード・必要時の PIN は端末のプロンプトへ入力する。
外部 Anisette サービスの `--anisette-url` と `--verbose` は指定しない。
成功時にも氏名・メールが表示されるため、認証出力はそのまま共有しない。
初回認証は Apple の固定 IPSW の認証コードとハッシュ固定の Unicorn runtime を取得し、
ローカルで実行する。USB 以外のキー接続は非対応。

## 上流への追従

派生リポジトリは `majd/ipatool` の履歴と、`fdkevin0` の鍵対応コミットを保持する。
独自修正は目的別コミットに分け、週次の upstream check が未取り込みの更新を issue に
まとめる。更新は専用ブランチで review・merge・テストし、必要な対話認証を受入した後で
採用する。自動 merge と dotfiles の自動 pin 更新は行わない。
具体的な操作は派生側の `docs/downstream-maintenance.md` に置く。

GitHub Actions は private リポジトリの billing / spending limit により初回ジョブが
開始前に拒否された。workflow は配置済みだが、制限解消後の CI と週次検知の実行は未確認。
これを手元テスト成功で green と扱わない。

## 実アカウントの受入状況

2026-11-17、USB キーの assertion、GrandSlam PET、Store native 認証と保存、
保存済み資格情報による ent download が成功した。対象 IPA は
`jp.13an.LockScreenNotes` / `1.24.0` / build `1` / iPhoneOS と照合した。
自動版解決の storefront 一覧取得は失敗するため、公開カタログの external version ID
`895278582` を明示した。この自動解決は未修正。

非対話実行の Keychain 読取は失敗し、手元の対話端末では取得できた。
keyring v1.9.0 は空結果を伴う検索エラーを `ErrKeyNotFound` に置き換えるため、
項目欠落とは断定しない。許可ダイアログの有無と実際の失敗理由は未確認。

UnfairPlay は既存 Mac enrollment の snapshot と取得 IPA からモデルを作成し、
アカウント情報を除いた解析用 IPA を復号した。ZIP 整合性とメイン・拡張の `cryptid=0`
を確認した。モデルと snapshot は非公開ホスト状態として扱い、Git に入れない。
