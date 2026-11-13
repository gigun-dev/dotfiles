# 専用UIDのXcode SDK/runtime対応表を初期化する

Xcode 26.3ではiOS SDKが読めてruntimeもavailableでも、ユーザー別のSDK/runtime対応表がないとgeneric iOS destinationが「iOS 26.2 is not installed」になるケースをminiで再現した。同じgigun UID・Xcode・使い捨てHOME/CFFIXED_USER_HOMEで、対応表なしでは利用不可、SDK 23C57 → runtime 23D8133の公式対応1行だけを配置すると利用可能になった。fixtureは削除済み。選択preference、group、SDK実体、Keychainは変更していない。専用UIDの復旧・実buildは別途受入する。

IDEFoundationはDVTDownloadableManagerのsdkToSimulatorMappingsとユーザー別永続化情報を使って互換runtimeを判定し、`~/Library/Developer/Xcode/SDKToSimulatorIndexMapping.plist`へ保存する。runtime件数の一致だけではこの対応表の存在・内容は分からない。

公開データ源はAppleの[Simulator index](https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex)。controllerで認証なし取得し、レビューしたSHA-256を固定する。rootやbuild/sign主体へnetwork資格情報を渡さない。metadata-only更新のCLIは確認できず、`runFirstLaunch -checkForNewerComponents`は追加component導入も含むため、この限定初期化に使わない。

`ansible/mini-macos/scripts/asc_sdk_mapping.py`は対象の非root UIDで実行する。既定はplan。`--apply`時だけ、承認したindexに完全一致の対応行が一件あり、実際のSDK名/buildとavailableなiOS runtime buildも一致した場合に、上記plistを新規0600で作る。親directoryは所有者管理・他者書込不可・symlinkなしを要求し、不足directoryだけ0700で作る。既存ファイルは同じ内容なら変更なし、違えば拒否し、自動移行しない。

```sh
python3 /protected/asc_sdk_mapping.py --index /public/apple-index.plist \
  --index-sha256 REVIEWED_SHA256 --sdk iphoneos26.2 --sdk-build 23C57 \
  --runtime-build 23D8133 --expected-user asc-build
# plan確認後、同じ引数に --apply を追加する
```

`--index -`はrootが先に読み込んだ公開indexを対象UIDのstdinへ渡す用途。秘密入力は不要。SDK/runtime download、simctl runtime match set、platform status override、既存ユーザー設定のコピー、Appleアカウント操作は行わない。Xcode内部のmetadata形式に依存する限定adapterなので、Xcode更新時は再度preflight・公式index・destinationを検証する。通常のGUI初期化で同じ対応表が得られる環境に重ねて適用しない。

適用後は対象UIDでgeneric iOS destinationを再確認し、固定sourceの未署名archive・digest・署名なしを検証する。失敗時は署名・publishへ進まない。このhelperの成功自体はbuild・署名・manifest・HTTPS配布・実機installの成功ではない。
