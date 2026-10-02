# Mac / VM の独立heartbeat

hubの `docs/uptime-heartbeat-contract.md`（2026-10-03）に合わせ、
`POST /uptime/heartbeat`へ`source/observedAt/bootId/bootedAt/lastSuccessAt/tunnel/service/functional`
の8項目を送る。ジョブ成功用H1b `/heartbeat`とは別の契約である。
Mac=`mac`、VM=`mini-vm`は別Bearerで、自身のboot ID・起動時刻を60秒ごとに報告する。
Macの処理はLimaに依存しない。hubが停止範囲の判定・履歴・通知を所有する。

## 送信と観測の意味

Linuxの`/proc`、macOSの`sysctl`からbootを採取し、完了時刻を`observedAt`と
`lastSuccessAt`へ入れる。ここでの成功は**観測元のboot採取完了**であり、hub受付や
アプリ機能の成功ではない。Tunnel/service/functionalは明示的なチェック未実施のため
常に`unknown`。healthの200から機能成功を推定しない。

各回は新しい観測、通信再送は同じ本文・同じobservedAt。10秒timeout・最大3回、
202かつJSONの`status=accepted`の場合だけローカル`lastAcceptedAt`を更新する。
失敗でも最新観測は原子的に保存し、以前の受付成功時刻は保持する。
lastAcceptedAtはローカル診断項目で、hubへの8項目本文に追加しない。
401/403/400/409は再送して時刻や本文を書き換えず、次の通常観測で新しい時刻を作る。
hubは未来60秒超・過去120秒超を拒否し、古い報告・同時刻の異なる本文を409にする。
202はD1保存だけを意味し、Bark/APNsや端末表示の証拠ではない。

本番はTLS必須・redirect禁止。tokenはprivateな実行時ファイルから読み、argv・環境・
Nix storeに平文を置かない。ログへtoken・応答本文・例外詳細を出さない。
結合テストだけはPython APIの`local_test=True`でliteral `127.0.0.1`のHTTPと
`local-fixture-`で始まるtokenを許す。通常CLIにこの例外を公開しない。

## 準備済みの秘密とsource登録

`secrets/host-heartbeat-mac.age` / `host-heartbeat-vm.age`には独立した候補tokenを用意した。
ライブSSH公開鍵を照合して暗号化し、M4の管理鍵で復号一致をメモリ内で確認した。
Mac候補はminiホスト/M4管理/backup、VM候補はmini-vmホスト/M4管理/backup宛て。
age受信者に互いのホスト鍵を含めない。平文をファイルへ残していない。
候補はhubへ未登録、実ホストへ未配置であり、暗号文だけをコミットする。

既存hub credentials JSONのowner・配送先を一意の管理/通知sourceから引き継ぎ、
`mac` / `mini-vm`だけを候補tokenへ置換する準備helperを用意した。
同名sourceの別ownerは拒否し、既存の他source・管理tokenを保持する。
送信sourceへmonitorControlを引き継がない。hubコード・stateは編集しない。

```sh
# credentials-fileはhub所有の既存JSONをprivateに取得したもの。reference-sourceを実設定と照合する。
# 出力を表示したりgit addしない。helperは0600の新規ファイルを作るだけで適用しない。
mkdir -m 700 /private/tmp/heartbeat-registration-staging
python3 scripts/prepare-host-heartbeat-registration.py \
  --credentials-file /absolute/private/existing-hub-credentials.json \
  --reference-source uptime-monitor --identity "$HOME/.ssh/id_ed25519" \
  --output /private/tmp/heartbeat-registration-staging/H1_SOURCE_CREDENTIALS.json
```

hub側で既存owner/destination、mac/vm/notification sourceの同ownerと別tokenを確認し、
本番entrypointの秘密設定へ登録する。`H1_UPTIME_CONFIG`のsourceは
`macSource=mac` / `vmSource=mini-vm`で一致させる。
fixture時計・local-sink入りのlocal-workerを本番へ公開しない。
本番URL、配送adapter、途絶180秒候補の確定・source登録の適用はhub側の承認済み計画に従う。

## 有効化準備（実行・適用はまだしない）

NixOS moduleは既定enable=false。以下を適用する場合だけ専用age秘密をroot:0400で
`/run/agenix/host-heartbeat-vm`へ復号する。VMのsystem serviceはログイン不要、
boot後15秒に開始、以降60秒ごと。ほかのサービスや既存Bark経路を変更しない。

```nix
services.host-heartbeat = {
  enable = true;
  source = "mini-vm";
  endpoint = "https://<accepted-hub-host>/uptime/heartbeat";
  tokenFile = config.age.secrets.host-heartbeat-vm.path;
};
```

MacのNix moduleはalwaysOn専用。凍結Intel miniへは届かないため、system LaunchDaemonの
生成helperを用意した。miniの`/usr/bin/python3`は3.9.6とライブ確認済み。
user agentはログイン前の観測ができないため使わない。

```sh
python3 scripts/host-heartbeat-launchd.py \
  --python /usr/bin/python3 --repo /absolute/path/to/dotfiles \
  --source mac --endpoint 'https://<accepted-hub-host>/uptime/heartbeat' \
  --token-file /var/lib/host-heartbeat/token \
  > /private/tmp/dev.gigun.host-heartbeat.plist
plutil -lint /private/tmp/dev.gigun.host-heartbeat.plist
```

承認後、M4のprivate staging directory（0700）内へMac専用暗号文をageで復号し、
scpでminiの同じ0700 stagingへ転送する。token本体をshell引数やログへ展開しない。
miniではsudoで`/var/lib/host-heartbeat`をroot:wheel/0700、tokenを0400で配置する。
生成plistをroot:wheel/0644で`/Library/LaunchDaemons/dev.gigun.host-heartbeat.plist`へ置き、
`launchctl bootstrap system /Library/LaunchDaemons/dev.gigun.host-heartbeat.plist`を実行する。
配置後は両端stagingの平文を削除する。miniに別ホストの秘密鍵をコピーしない。
Nix管理Macでは手動plistを併用せずNix moduleを使う。

有効化前にhubのD1 migration・本番entrypoint・source登録とローカル結合が成功していることを
確認する。有効化後は自然発火でMac/VMのobservedAtが更新され、boot情報と別sourceが
D1へ残ることを確認する。root専用snapshotとサービス終了状態を確認し、通知受理と
端末表示の確認はhub側の別受入へ渡す。実停止試験は別途承認する。

## rollbackと計画停止

NixOSは承認後に`systemctl stop host-heartbeat.timer`で追加送信を止め、enable=falseへ戻して
旧generation/設定を再適用する。Macは`launchctl bootout system/dev.gigun.host-heartbeat`後に
追加plistを退避する。初回導入なので旧H1b `/heartbeat`へ8項目本文を戻して送らない。
hubのD1や履歴を削除しない。既存KV/Barkの外形監視は切替承認まで維持する。
漏えい・失効時はhubで該当source tokenを無効化してから新しい候補へrotateする。

現行uptime契約に計画停止/pause APIはない。H1bの`/heartbeat/control`はこのsourceの
停止抑制として流用できない。計画停止時のhub通知抑制はhub側で別途確定し、
未確定のまま実停止試験を実施しない。

## 検証

```sh
python3 -B -W error scripts/tests/host-heartbeat.py
python3 -B -W error scripts/tests/host-heartbeat-registration.py
python3 -B -W error scripts/tests/ssh-path-observe.py
node scripts/tests/host-heartbeat-hub.mjs --hub-root /absolute/path/to/hub
sh scripts/verify.sh
```

結合はhubの現在のlocal-workerを一時outdirへdry-run buildし、一時D1/Queueとlocal-sinkを使う。
外向きfetchを禁止し、Mac/VM別Bearer、boot保存、再送、認証source拒否、古い報告、boot変更、
runtime再起動後の保存を検証する。本番送信・実停止・外部通知は行わない。
Macの実boot採取とPython3.9 fixtureはminiの一時directoryで検証し、終了時に削除した。
VMも既存Nix storeのPythonでboot情報を読み、8項目の生成を確認した（送信なし）。
VMの通常PATHにpython3は無いため、宣言serviceはpkgs.python3の絶対パスを使う。
2026-10-03の結果は送信18件・秘密準備17件・SSH経路6件のfixture成功、
sender→hub→D1結合成功（外部fetch試行0）、両plistの構文検証成功。
共通`verify.sh`ではPython fixtureの実ビルドとNix/fmtチェックを行う。
実自然timer発火、実ホスト再起動、端末表示、Linux構成の実ビルドは未検証。
