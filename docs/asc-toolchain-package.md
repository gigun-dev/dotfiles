# ASC/XcodeGenを完全なpackageとして配置する

XcodeGen 2.46.0のHomebrew formulaは`bin/xcodegen`だけでなく`share/xcodegen/SettingPresets`も配置する。binaryだけをversion directory直下へコピーした初期toolchainではpresetが見つからず、生成処理がexit 0のまま`PRODUCT_NAME`等の標準設定を欠いた。専用UIDのarchiveは出力名が`.app`となりcreate-directoryとlinkが衝突した。

同じMiniRouteTest spec・同じbinaryの使い捨てfixtureで、binaryだけではmissing-settings警告あり・PRODUCT_NAMEなし、`bin/xcodegen`と`share/xcodegen/SettingPresets`の相対配置では警告なし・PRODUCT_NAMEありを確認した。fixtureは削除済み。アプリ固有の設定追加でtoolchainの不備を隠さない。

`ansible/mini-macos/scripts/asc_toolchain_install.py`は固定manifestのhashと各fileのhash・mode・pathを検査する。binaryは`bin/asc`・`bin/xcodegen`、presetは`share/xcodegen/SettingPresets/**/*.yml`。既定はplan、`--apply`で新しいversion directoryへroot所有のbinary0555・preset0444を作る。旧版を上書き・採用せず、runner・sudoers・署名資材は変更しない。root/ACL検査は隣接する既存`asc_executor_install.py`を共有し、両スクリプトを同じ保護領域へ配置・hashレビューしてから管理者が実行する。installerはbinaryを実行しない。

```sh
python3 /protected/asc_toolchain_install.py --bundle /private/candidate \
  --manifest-sha256 REVIEWED_MANIFEST_SHA256
# plan確認後、同じ引数に --apply を追加する
```

候補生成時はHomebrew版の同一versionからbinaryとpresetを一式snapshotし、preset一覧・bytesを公式の固定tagのsource archiveとも照合する。実行環境はversion配下の`bin`をPATHへ入れ、ASCも同じ`bin/asc`を絶対pathで選ぶ。新規プロジェクトでもpresetを必要とするため、アプリ単位ではなくhost toolchainの配置単位を修正する。

installerのfixtureはplan無変更、正しい相対配置とmode、既存version拒否、preset改変・manifest不一致・symlink拒否、失敗時に今回作成したfile/空directoryだけを除去することを検証する。実root配置、生成結果、専用UIDのarchive・digest・署名なしは別の受入とする。
