# macOSのキーボードショートカット競合

キーを登録できない、登録できても動かない、別アプリが反応するときは、設定を変える前に入力経路と受信先を観測する。アプリを順に終了する方法は、観測で絞れなかった場合の後段の手段とする。

## 1. 症状と実入力を確認する

- 「設定欄が組み合わせを受け付けない」と「保存されたキーが発火しない」を分ける。
- 対象キー、別の修飾キーを足した比較用キー、左右の修飾キー、入力ソースを記録する。
- Karabiner-EventViewerで、修飾キーを保持したまま対象キーのdown/upが届くか確認する。ここで正常でも、通常のアプリに届くことまでは証明しない。
- Computer Useなどの合成入力は実キーボードと配送経路が異なる。合成入力の成功だけで実入力の競合を否定しない。

次へ進む条件は、再現操作と比較用の操作が決まり、どちらの入力を観測したかを区別できること。

## 2. 受信先を調べる

リポジトリルートから実行する。SwiftとmacOSが必要で、Nixの適用やツールのインストールは不要。

```sh
# デフォルトはOption＋Space。実キーを押すと送信先PID・アプリ名を表示する。
swift scripts/diagnose-hotkey.swift

# Control＋Option＋Spaceとの比較（Spaceの仮想キーコードは49）
swift scripts/diagnose-hotkey.swift --key-code 49 --modifiers control+option --seconds 30

# 通知を受動観測する前に、Carbonの登録競合だけを検査する場合
swift scripts/diagnose-hotkey.swift --check
```

通常モードは、session event tapで指定キーの実入力を検出し、直後1秒以内のannotated-sessionのsystem-defined hotkey通知から`eventTargetUnixProcessID`を読む。ShortcutDetectiveと同じ方式で、どちらのtapも`listenOnly`。設定変更、入力の書き換え、アプリ終了、ログファイルの保存はしない。実行元に入力監視権限が必要で、スクリプトは権限要求を自動表示しない。

`RECIPIENT`は指定キーと時間的に対応した通知の送信先。短時間に別のショートカットを混ぜず、複数の登録先が出たらすべて候補として残す。取得したPIDが現在も同じプロセスかは、アプリ名・bundle IDと合わせて確認する。

この通知形式は全OS・全ショートカットでの検出を保証しない。`MATCH`のみ、または通知0件は「競合なし」ではない。event tapで先に消費された入力、通知を公開しない方式、権限不足などが残る。

`--check`は`RegisterEventHotKey`へ`kEventHotKeyExclusive`を指定して一時登録し、直後に解除する。`REGISTERED`（−9878）は同じ組み合わせの排他登録があることを示し、登録元PIDは分からない。**options=0の非排他登録は、他アプリが占有していても成功するため、競合なしの判定には使わない。** `AVAILABLE`でも非排他登録、システム予約、event tapの横取りは否定できない。排他登録は既存の非排他登録への通知を一時的に抑えるため、`--check`の実行中はその組み合わせを押さない。

## 3. 設定と照合し、原因を確認する

受信先のアプリ設定・メニュー・保存設定を照合する。受信先を取れない場合は、次を確認して候補を絞る。

- システム設定のキーボードショートカット、サービス、入力ソース。
- Karabinerの選択中プロファイル、デバイス別変換、修飾キー変換。
- ランチャー、IME、ブラウザ拡張、開発ツールなどのグローバルキー。
- dotfilesの宣言元、アプリの保存先、実行中の状態の違い。plistの値だけで実行中の登録を断定しない。

HotkeyClashは設定・メニューの競合候補の一覧に使える。ただし実キー試験の判定にはtapの通過状況やアプリの前面化も使うため、通知先PIDの確定と区別する。専用ツールを使う前に、現在のOSでの対応と必要権限を確認する。

受信先または候補が絞れたら、そのキーだけを一時解除して再測定する。終了が必要なら対象アプリだけを正常終了し、解放を確認する。必要に応じて再有効化・再起動で再発することも確認する。複数の登録元がある場合、一つを外しても競合が残るので、単独の陰性結果だけで除外しない。

観測で絞れなければ、ログイン項目を抑えたログイン、別ユーザー、セーフモードなどの比較でユーザー設定と常駐処理を切り分ける。再起動やユーザー作成は本人と調整する。その後、必要な候補群を二分して比較し、アプリごとの無差別な強制終了を避ける。

完了条件は、原因の操作で解放・再発を確認でき、元のアプリでキーの登録と実入力での発火を確認し、検証用に変えた設定や一時終了したアプリの状態を戻したこと。未検証の範囲は残して報告する。

## 確認事例: Option＋SpaceとAccessibility Inspector

2026-10-31 JST、実入力のhotkey通知先が`com.apple.AccessibilityInspector`と判明した。Inspectorの表示は「⌥Space toggles inspection pointer」。終了で排他登録可能、再起動で登録済みに戻ることを確認した。

このときのInspectorはOption＋Spaceを固定値でexclusive登録していた。通常の設定やmacOSのメニューショートカット変更でCarbon登録を変更する構造ではなかった。対処は必要時だけ起動して使用後に⌘Qで終了するか、併用するアプリを別キーへ変えること。ウィンドウを閉じるだけでは占有が残った。他バージョンの設定可否はその都度確認する。

## 参照

- [ShortcutDetective公式配布・検出限界](https://www.irradiatedsoftware.com/labs/)
- [HotkeyClashの実キー観測](https://github.com/Wunderlandmedia/HotkeyClash/blob/2ce1a5a42db386e67fae8631831de6be28c72a5b/HotkeyClash/Services/ShortcutTester.swift)
- [Apple: ログイン項目の切り分け](https://support.apple.com/ja-jp/guide/mac-help/mh21210/mac)
- Carbonの登録仕様: macOS SDKの`HIToolbox.framework/Headers/CarbonEvents.h`、`RegisterEventHotKey`と`kEventHotKeyExclusive`の説明。
