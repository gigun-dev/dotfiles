# ASC専用UIDの単発受入

`ansible/mini-macos/scripts/asc_uid_fixture.py`は既存のbuild/signユーザーを使う、非秘密canaryだけの単発検証である。恒久的なrunner、sudoers、ユーザー、既存home、Keychainは変更しない。通常Ansibleの認証・sudo管理へ混ぜず、管理者がレビュー済みコピーを明示実行する。

管理者は新しいroot所有0700 directoryへhelperをinstallし、レビューしたSHA-256と一致することを確認してから `/usr/bin/python3 <helper> --build-user <build-user> --sign-user <sign-user> --run-fixture` を実行する。helper自体もroot所有・他者書込不可を要求する。実行後、installしたhelperとその空directoryだけを削除する。

helperは `/private/tmp` の一時領域に2ユーザー所有の0700領域を作り、build側canaryのsign側からの読取拒否、rootコピー後のsign側digest一致、build側からのsign領域のread/write拒否を検証する。子processは固定Pythonコードで、supplementary groupと継承環境を渡さない。成功・失敗時とも一時領域をcleanupする。

成功はOSの基本アクセス制御の受入に限る。rootを恒久brokerにする決定、実archiveの承認、信頼済みdigest配送、既存sudo権限、runnerのKeychain隔離、再起動復帰、署名・publishの成立は別途受入する。恒久配置を決定する場合は既存のsecurity境界タスクからADRへ進める。

本人の管理者実行で、非秘密canaryに限る相互read/write拒否、仲介後digest一致、一時canary領域cleanupが成功した。これは上記fixtureの受入結果であり、本番の境界は未評価のままである。
