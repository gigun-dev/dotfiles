# Mac / VM の独立heartbeat送信準備

hub の `src/heartbeat/http.ts` と `README.md`（2026-10-03確認）に合わせ、
送信本文は `{source, runId, scheduledFor}` のみとする。新しい受付や通知先は追加しない。
Mac と VM はそれぞれ自身の boot ID・起動時刻を採取する。Mac の処理は Lima に依存しない。
boot 情報はローカルの最新snapshotに残すだけで、hubには未送信である。
boot ID由来のrunIdは冪等性用で、hubが起動履歴として解釈する契約ではない。

## 準備済みの動作と境界

`scripts/host-heartbeat.py` は Linux の `/proc`、macOS の `sysctl` から採取する。
観測時刻と UTC 固定グリッドの予定枠を分離し、同じ起動・同じ枠の再送は同じrunIdを使う。
通信timeoutは各10秒、最大3回。202かつJSONの`status=accepted`を確認した場合だけ
`lastAcceptedAt`を更新する。失敗時も最新boot証拠は残し、以前の受付成功時刻は保持する。
これはhubの受付成功であり、iPhone配信やservice機能の成功を示さない。
snapshotは一ファイルを原子的に置換する。停止判定・履歴・通知はhubが所有する。

TLS必須・redirect禁止。tokenはprivateな実行時ファイルから読み、argvやNix storeへ
平文を置かない。ログにtoken・応答本文・例外詳細を出さない。
新しいtokenの発行、暗号文の作成、本番サービスへの適用はまだ行っていない。

## hubと合わせる項目（未確定）

- Mac / VM別sourceとそれぞれのBearer資格情報。例は`mini-host` / `mini-vm-host`。
- 周期・anchor・猶予と監視開始の登録。送信側既定は60秒・anchor=0、起動後15秒/30秒poll。
  未登録sourceの404を送信側で正常扱いしない。hub初期化前に送信だけを有効にしない。
- boot ID・boot時刻・観測時刻・最終成功を受け取る契約。現行H1bは追加項目を400で拒否する。
  契約確定時にこの送信側を追従し、ローカルfixtureで再起動と途絶の区別を確認する。
- Mac停止 / VM停止 / Tunnel障害 / service障害 / 機能失敗 / hub Cron障害の相関と
  unknownの扱い・永続履歴・通知はhubで検証する。このheartbeatだけで原因を断定しない。

## 宣言と秘密（まだ有効にしない）

NixOSは`mini-vm.nix`がmoduleをimportし、`services.host-heartbeat.enable`の既定はfalse。
tokenの発行後に専用`host-heartbeat-token.age`を`secrets/secrets.nix`の既存受信者へ暗号化し、
`age.secrets.host-heartbeat-token.file`へ宣言する。中身はenvではなくtoken単体。
次の設定はhub登録内容と照合してから適用する（ここでは適用しない）。

```nix
services.host-heartbeat = {
  enable = true;
  source = "mini-vm-host";
  endpoint = "https://<hub-host>/heartbeat";
  tokenFile = config.age.secrets.host-heartbeat-token.path;
  periodMs = 60000;
  anchorMs = 0;
};
```

MacのNix moduleはalwaysOnだけにimportされる。凍結中のIntel miniには届かないため、
同じscriptをsystem LaunchDaemonで起動するplist生成を用意した。user agentでは
ログイン前を観測できないので、既存network-watchdogのuser agentとは別にする。
Mac自身で復号できる専用age受信者を確定し、root専用tokenファイルへ配る手順が必要。
既存のVM/M4/backup用秘密をminiへコピーして代用しない。

```sh
# mini上の使用可能なpython3の絶対パスを確認してから生成する。load/適用はしない。
python3 scripts/host-heartbeat-launchd.py \
  --python /absolute/path/to/python3 --repo /absolute/path/to/dotfiles \
  --source mini-host --endpoint 'https://<hub-host>/heartbeat' \
  --token-file /var/lib/host-heartbeat/token \
  > /tmp/dev.gigun.host-heartbeat.plist
plutil -lint /tmp/dev.gigun.host-heartbeat.plist
```

承認後の適用はrootで`/var/lib/host-heartbeat`を0700、tokenを0400にし、
生成plistを`/Library/LaunchDaemons/`へroot:wheel・0644で配置してから
`launchctl bootstrap system /Library/LaunchDaemons/dev.gigun.host-heartbeat.plist`を実行する。
Nix管理のMacでは手動plistを併用せずNix moduleで適用する。
停止時はhubのpause権限を持つ管理資格情報で期限付き停止を先に登録し、その後
`launchctl bootout system/dev.gigun.host-heartbeat`またはsystemd timer停止を行う。
送信tokenへmonitorControl権限を付けない。

## 非破壊検証と残る受入

```sh
python3 scripts/tests/host-heartbeat.py
python3 scripts/host-heartbeat.py --source fixture-mac --snapshot /tmp/host-heartbeat-latest.json
```

後者は外部送信なしで採取する。独立source・boot切替・同一枠再送・HTTP失敗はfixtureで確認する。
本番token/endpoint、自然timer発火、boot情報のhub保存、実再起動、復旧通知・端末表示は未検証。
実ホストの停止試験や本番切替は、hub側の受入と具体的な手順に対する承認後に行う。

2026-10-03の検証では16件のfixtureテスト、Nixの`checks.aarch64-darwin.host-heartbeat`の
実ビルド、plistの`plutil -lint`、Mac/VM両moduleの有効設定の評価が成功した。
M4 Pro自身のboot情報も送信なしで採取した。mini-vm構成の既定enable=falseを確認した。
Linux構成の実ビルド・本番適用は行っていない。
