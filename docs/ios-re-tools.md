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
