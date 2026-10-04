# 通知の現行運用

所有境界は [ADR 0004](adr/0004-send-notifications-through-hub-instead-of-a-dotfiles-worker.md)。
配信・監視履歴・再試行はhub、通知元と資格情報はdotfilesが持つ。

mini-vmの失敗通知とClaude hookは `secrets/bark-env.age` の `BARK_PUSH_URL` にある
hub H0へ送り、既存のAES暗号化を維持する。[mini-vm運用](mini-vm.md)を参照。
HTTP成功とJSONの受付成功、APNs受付、本人端末での表示は別の検証である。

Mac/VMの生存報告と公開Codex・Langfuseの検査、停止・復旧履歴と通知は配備済み。
通信形式とsender運用は [host-heartbeat.md](host-heartbeat.md)、監視・配送の現在地は
[hubの運用記録](../../hub/docs/uptime-current-operation-2026-10-03.md)を参照。

`dotfiles-autoswitch`・`dotfiles-lock-propose@fast`・`@slow` のジョブ成功heartbeatは
未配備で、`todo.txt` の0005に残る。ホストの生存報告だけではtimerの不発を検知できない。
正常終了（差分なしを含む）・途絶・復旧・計画停止・二重配信防止の確認が必要である。


## ジョブ成功 heartbeat の準備（todo0005、既定OFF）

`scripts/job-heartbeat.py` はhub H1b用の3系統共通sender。開始時にUTC予定枠とrunIdを固定し、
同じreceiptを成功時の再試行にも使う。`services.dotfiles-job-heartbeat` は既定でOFF、
endpointはnull、tokenFilesは空。mini-vmの有効化候補はこの既定値を明示的に上書きするが、
[配備前提](job-heartbeat-activation.md)が揃うまでは未配備として扱う。
OFFではcredentialの解決・stat・読取、curl起動、HTTP通信を行わない。
既存の失敗通知、H0/Bark経路、timerの時刻は変更していない。

有効化前のtransport互換性を揃えるため、3ジョブ共通senderはhub CI callerと同じ標準curlを使う。
同じhubドメインのCI送信でurllibが拒否された事例を踏まえた準備であり、ジョブ用 `/heartbeat`
が本番で拒否されたと確認したものではない。生存heartbeat senderはこの変更の対象外。
Nix wrapperは選択世代のcurl絶対パスとCA bundleを固定し、旧coordinatorのPATHに依存しない。
curl 8.4以上、curlrc無効、HTTPS限定・証明書検証・redirect/proxy不使用とし、UAは偽装しない。
Bearerと本文はstdinだけに渡し、接続/全転送10秒・子process15秒・最大3回・応答4KiBで制限する。
202とJSON受付成功の両方を確認し、403やTLS検証失敗に別transportで再挑戦しない。
OFF時はtoken読取だけでなくcurlのversion照会・起動も行わない。

- autoswitchは固定revisionのsystem・home・health gateと最終世代照合の後だけ送信候補になる。
  coordinatorの同一invocationから新世代helperへ開始receiptを渡す。rollback後のgate成功は
  更新成功として扱わず、旧coordinatorからの移行で開始snapshotが無い実行も送らない
- lock-fast/slowは差分なし、または両build・push・PR更新・auto-merge設定の成功で送信候補になる。
  GitHub CI/merge完了やsystemへの適用完了は意味しない
- sender失敗はjournalに秘密を含まない固定文を残す。正常な適用をrollbackしたり、
  既存OnFailure経路で重ねて通知したりせず、将来有効化するhub側の欠測判定に任せる

設定例（準備用、OFFのまま。値を配置しただけでは有効化しない）:

```nix
services.dotfiles-job-heartbeat = {
  enable = false;
  endpoint = "https://hub.example/heartbeat";
  tokenFiles = {
    mini-vm-autoswitch = "/run/agenix/job-heartbeat-autoswitch";
    mini-vm-lock-fast = "/run/agenix/job-heartbeat-fast";
    mini-vm-lock-slow = "/run/agenix/job-heartbeat-slow";
  };
};
```

ONには公開HTTPS `/heartbeat` endpointと3系統それぞれの異なるruntime pathが必須。
pathはNix path literalではなく文字列で指定する。未知source、Nix store、相対path、
改行・specifier・曖昧なpath、認証情報・query付きURLは評価時に拒否する。
`secrets/job-heartbeat-{autoswitch,fast,slow}.age` の作成・hub登録・agenix宣言は別の配備段階。
受付登録の候補だけを作るローカル手順は [job-heartbeat-registration.md](job-heartbeat-registration.md)。
予定する所有権はautoswitchがroot:root 0400、fast/slowがgigun:users 0400。
本来のjobがcredential欠落・権限エラーで起動不能になるのを避けるため、
`LoadCredential` や `SetCredential` は使わず、成功後のsenderだけがファイルを開く。
欠落・不正・読取不可は固定文の警告だけになり、jobの終了状態は変えない。

開始時に `DOTFILES_JOB_HEARTBEAT_ENABLED`、`DOTFILES_JOB_HEARTBEAT_ENDPOINT`、
`DOTFILES_JOB_HEARTBEAT_TOKEN_FILE` の非秘密設定を固定する。candidate helperは自身もONで、
開始時もON、endpointも一致する場合だけ開始時pathを使う。旧OFFから新ONへswitchした回、
endpoint変更回、新OFFへの切替回は送らず、次のinvocationから新設定を使う。
環境変数だけで、OFFにビルドされたwrapperを有効化することはできない。

固定するのは設定identityであり、token本文ではない。標準 `/run/agenix/<name>` は
symlinkディレクトリ配下のregular-file leafなので、既存senderの `O_NOFOLLOW` と両立する。
switchで旧agenix世代は消えるため、開始時に実体pathへcanonicalizeしない。
同じlogical pathのrotation後は新token本文を読む。新旧tokenのhub有効期間は配備側で調整する。
最終leafがsymlinkのcustom aliasは非対応。senderはregular-file、private mode、
rootまたは実行UID所有を検証し、秘密をargv・環境変数・journalへ出さない。

有効化前に必要な判断と受入:

1. 3 source専用credentialの既存有無を値を表示せず照合する。生存用mac/mini-vm tokenは
   流用しない。未存在なら発行・hub登録・agenix配置を承認後に行う。通常senderに
   monitorControlを付けず、計画停止は別管理credentialで扱う
2. 2026-10-04の実機read-only照合ではVM timezoneはUTC、3 timerはenabled/active/waiting、
   Persistent=yes、jitter30分・accuracy1分。hub候補（毎日04:00/01:00、日曜02:00、
   猶予105/135/135分）と一致する。OnCalendarのTZ明記なしと周期は維持し、配備時にも再照合する
3. hubのUPTIME_JOB_SCHEDULESは別途承認して登録し、最初の対象枠より前にD1初期化を確認する。
   本senderは開始時点の直近UTC枠を選ぶ。Persistent追いつき実行と手動実行の扱いも照合する
4. 既存の即時失敗通知は維持する。H1b欠測との相関を決めないまま、両経路の
   二重配信防止済みとは扱わない
5. 正常/差分なし/途絶/復旧、pause/resume/期限自動再開、再送重複防止を確認する。
   hub受付・H0/APNs受付・本人iPhone表示は分けて記録し、実機強制停止を試験に使わない

合成試験は `scripts/tests/job-heartbeat.py`、`job-heartbeat-activation.py`、
`lock-propose-heartbeat.py` と既存 `dotfiles-autoswitch.py`。外部HTTPはfake transportのみ。
Nixの共通checkにはこれらと `nix/tests/job-heartbeat-config.nix` を登録し、OFF既定値・
不正設定の拒否・credential unit設定なし・既存timer/失敗通知の不変を検証する。
合成試験は実systemd activation、自然timer、実通知の受入を代替しない。
