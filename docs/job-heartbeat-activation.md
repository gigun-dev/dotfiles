# ジョブ heartbeat の配備記録と残る受入

2026-10-04 19:29 UTCまでに、hubとmini-vmの3ジョブ監視の適用を確認した。
2026-10-05にはfast・autoswitchの自然成功receiptをD1で確認した。週次slowは初回枠待ち。
`todo.txt` の0005は未完了。配備・初期化の確認と、自然実行・実通知の受入を区別する。

## 適用済み

以下の稼働情報は、backend適用・D1照合とMac経由の実機適用報告による。
次節のPR/CIは独立して参照できる検証資料であり、実機適用や実通知の証明ではない。

- dotfiles [PR #37](https://github.com/gigun-dev/dotfiles/pull/37) を
  `2ee26c377dd4bf7a292d8dea6f921cf1a1ccdcfa` としてmergeし、mini-vmへ適用した。
  承認済みMac作業で既存recipient `all` に暗号化した
  `secrets/job-heartbeat-{autoswitch,fast,slow}.age` を使用し、token平文はGitに含めない
- hub [PR #8](https://github.com/gigun-dev/hub/pull/8) のmerge revisionは
  `724e88b76d679aebcbcf43b724310a1d5c38ba1e`、適用Worker versionは
  `c2973135-ac7c-4e41-9e63-0644124645a9`。
  3 source専用credentialはowner=homelab・destination=bark・monitorControlなしで登録し、
  既存4件を維持した。3 scheduleも適用済み
- 2026-10-04 19:11:02 UTCの自然Cronで、対象3件のD1定義が初期化された。
  いずれもhealthy・version=0・lastSuccess=null・receipt=0。
  このhealthyは初期状態であり、ジョブ成功や通知到達の証拠ではない
- mini-vmは上記dotfiles revisionでclean、system generation 72。
  systemは `/nix/store/r4wf9pml0k24qph31ik13h46vddlvmna-nixos-system-mini-vm-26.11.20260930.c9fe7d1`、
  homeは `/nix/store/d3mw2f2zya459nf9snn4q3y4rfgzr24p-home-manager-generation`。
  system・homeのhealth gateを通過し、Langfuseのimage pairは変更していない
- 標準 `/run/agenix/` の3 credentialはregular-file leaf・0400。
  autoswitchはroot:root、fast/slowはgigun:usersで確認済み。
  ON snapshotの3 source・endpointを確認し、timer・timeout・既存即時失敗通知は維持した。
  3 timerはenabled/active/waiting・Persistent=yes、VMはUTCでOnCalendarのTZ明記なしも維持した
- 適用後のCronはhealthy、既存hostの報告はfresh、既存CI #120監視はhealthy。
  outboxのpending/retry/failedは無かった。この配備確認時点では3ジョブの自然実行は未観測だった

## CIの検証範囲

[PR head `0733cb5` のCI](https://github.com/gigun-dev/dotfiles/actions/runs/37226281980) と
[merge後 `2ee26c3` のmain CI](https://github.com/gigun-dev/dotfiles/actions/runs/37227540659) は成功。
108 fixtures、Nix config検証、fmt（25ファイル・変更0）、KVM lifecycle、system/home buildを確認した。
合成試験・CIの成功は、自然timerの成功receipt、missed/recovery通知、本人iPhone表示を代替しない。

moduleの既定値はOFFのまま、mini-vmの宣言で明示的にONへ上書きしている。
`nix/tests/job-heartbeat-config.nix` はmodule単体の既定値と、明示的なpriority overrideによる
OFF/ON/不正設定を分けて検証し、実機設定からテストの欠けた項目を補わない。

## 自然実行の受付確認（2026-10-05）

2026-10-05 04:28 UTCのD1 read-only照合で、次の2件の自然成功heartbeat受付を確認した。
日時はUTC。初期healthyだけでなく、各予定枠のreceiptを照合した。

| source | 対象予定枠 | hub受信時刻 | monitor状態 | receipt件数 |
| --- | --- | --- | --- | --- |
| mini-vm-lock-fast | 2026-10-05 01:00 | 2026-10-05 01:03:47.825 | healthy・version=1・incident=null | 1 |
| mini-vm-autoswitch | 2026-10-05 04:00 | 2026-10-05 04:03:29.405 | healthy・version=1・incident=null | 1 |

週次slowは初回予定枠前で、healthy・version=0・receipt=0の初期状態を維持していた。
対象3 sourceのpending heartbeat eventと通知delivery行は無かった。
これは自然ジョブのhub受付の証拠であり、missed/recovered、H0/Bark/APNs受付、本人iPhone表示の
実受入ではない。差分なし経路や再送重複防止を個別に実証したものとも扱わない。

## 自然枠と未完了の受入

予定枠はUTC、既存timerのjitterは最大30分。hubの猶予は各予定枠から数える。

| source | 適用後最初の予定枠（UTC） | 周期 | 猶予 |
| --- | --- | --- | --- |
| mini-vm-lock-fast | 2026-10-05 01:00 | 毎日01:00 | 135分 |
| mini-vm-autoswitch | 2026-10-05 04:00 | 毎日04:00 | 105分 |
| mini-vm-lock-slow | 2026-10-11 02:00 | 日曜02:00 | 135分 |

- fast・autoswitchの上記2枠はhub受付確認済み。slowは2026-10-11 02:00 UTCの初回枠で確認する。
  差分なし経路を含む残りの受入は続ける。旧OFF invocationから新ON helperへ切り替えた回は
  送信しない仕様を維持する
- 途絶・復旧、再送重複防止、既存即時失敗通知との二重配信防止は実受入未完了。
  hub受付・H0/Bark/APNs受付・本人iPhone表示を分けて記録し、実機強制停止を試験に使わない
- 計画停止のpause/resume/期限自動再開は今後の受入。通常senderへmonitorControlを付けず、
  この適用では追加の管理credentialを発行していない

sender仕様と残る運用上の判断は [notifications.md](notifications.md) を参照。
