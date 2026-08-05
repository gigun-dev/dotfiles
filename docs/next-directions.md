# 次セッションの方向性(2026-08-06 棚卸し・第1版)

> **位置づけ**: 恒久ドキュメント(セッション引き継ぎの正典)。セッション開始時に SessionStart フック
> (`.claude/settings.json`)がこのファイルの「頭」(`session-head-end` マーカーまで)を自動注入する。
> **更新ルール**: 計画は消さない。完了は打ち消し線 + ✅、状況変化は該当箇所の直下に
> `> **YYYY-MM-DD 更新:** ...` の引用ブロックを積層する。大きな節目でタイトルの日付を更新し
> 全体を棚卸しする(積層を本文へ溶かし込む。生記録が必要な規模なら docs/log.md へ追記)。
> **作業の区切りごとに必ず更新する。**

## 現在地(2026-08-06)

- **Mac Mini (Intel) のエージェント基盤を Lima ゲスト (NixOS) へ移し、稼働中**。macOS 側は nix 管理を
  凍結し、Finder 経由の iPhone バックアップ・画面共有・Xcode 26.3 専用にした。M4 Pro から
  `ssh gigun@mini-vm` で直接入れる (Tailscale SSH / `tag:server`)。経緯はカタログの該当節。

- **mini の再起動からの自動復帰は検証済み (2026-08-06)**。`sudo reboot` を実行し、
  「macOS 自動ログイン (`who` に console) → LaunchAgent → Lima 起動 → VM の tailscaled 復帰」が
  手を触れずに通ることを確認した。**46秒で mini に ssh 可能、その直後に `ssh gigun@mini-vm` も成立**。
  boot 時は `networking.hostName` が効くのでゲストの hostname も `mini-vm` になる
  (switch では稼働中の hostname が変わらないだけだった)。

- **未検証の危険 (実地確認していないもの)**:
  - ⚠️ **pre-push の失敗パスが未検証**。成功パスは本番 push で確認済み (2026-08-06、
    `nix flake check` → `nix fmt` が走ってから push された) が、検証が落ちたときに実際に
    push が止まるところは見ていない。テンプレートに `(! a) && b` の解釈バグがあった経緯が
    あるので、わざと失敗を注入して確かめる価値がある。
  - ⚠️ **apple/container の再起動後の復帰が未検証**。Apple Silicon 限定なので mini では
    確認できず、M4 Pro を再起動しないと分からない。apiserver は launchd 登録済み。

- **裁定待ち**: SPEC.md の扱い (凍結/削除/追従の3案)、CLAUDE.md「ディレクトリ構造」節の圧縮。
  どちらも下の着手順に理由付きで書いてある。

## 着手順(次にやること)

1. ~~**pre-push を `git/hooks/pre-push` に置く**~~ ✅ 2026-08-06 完了
   > **2026-08-06 更新:** harness の `.githooks/pre-push` は採らなかった。`core.hooksPath` は
   > 1つしか持てず、`.githooks` へ切り替えると既存の `git/hooks/pre-commit`(staged .nix の
   > nix fmt 自動整形)が死ぬため、既存側に合わせた。検証内容は CI と同じ
   > `nix flake check --no-build` + `nix fmt -- --ci .`。
   > **検証**: main への push を模擬 (`echo "refs/heads/main <sha> refs/heads/main <sha>" |
   > ./git/hooks/pre-push`) して両コマンドが走り exit 0 を確認 (2026-08-06)。
   > **失敗パスは未検証** — 検証が落ちたときに実際に push が止まるところは見ていない。
   > なお `nix flake check` は現在の system しか評価しない(x86_64-darwin は omit される)ので、
   > 壊れている Intel 構成はこの関門では検出されない。
2. **SPEC.md の扱いを決める** — 2026-04-10 の初期コミット以降まったく更新されておらず、Windows 対応も
   Lima VM も入っていない。現行仕様として読まれると事故る。案: (A) 冒頭に「初期設計の記録」と注記して
   凍結 (推奨)、(B) 削除して CLAUDE.md に一本化、(C) 現状に追従。`docs/` ができたので
   `docs/SPEC-initial.md` へ移す手もある。
3. ~~**harness:doctor の誤検知を起票する**~~ ✅ 2026-08-06 完了
   > **2026-08-06 更新:** 2件起票した。
   > [#1](https://github.com/gigun-dev/claude-code/issues/1) は doctor の誤検知
   > (CLAUDE.md 96行「毎回ソースビルドに**なる**」は症状の記述であって指示ではない。
   > 逆に真に該当する14行「必ず `git add` すること」は挙がっていない)。
   > [#2](https://github.com/gigun-dev/claude-code/issues/2) は init の pre-push テンプレートのバグ
   > (`if ! {{CHECK_COMMAND}}` が複合コマンドで `(! a) && b` と解釈され、前半が失敗しても
   > 素通りする)。**このリポジトリの `git/hooks/pre-push` は修正済み**だが、他リポジトリへ
   > install.sh で配った分は要確認。
4. **CLAUDE.md の「ディレクトリ構造」節を圧縮する** — `zsh/.zshrc # メイン設定` のような同語反復を削り、
   `zsh/functions/ # permission は 755 必須` のような非自明な制約だけ残す。`windows/` 配下の詳細は
   `windows/README.md` があるので1行に畳む。39行 → 15行程度が目標。

<!-- session-head-end: ここから下は SessionStart フックが注入しないオンデマンド領域。着手する節をそのとき読む -->

## 方向性カタログ

### Mac Mini の Intel 打ち切り対応 (2026-08-05 実施)

**背景**: nixpkgs 26.11 が x86_64-darwin を drop し、`nix run .#switch` が eval すら通らなくなった
(実際 mini は 2026-04-25 の generation 26 で止まっていた)。26.05 への固定で延命するには
nixpkgs / home-manager / nix-darwin の3つを固定する必要があり、しかも llm-agents が x86_64-darwin
非対応なので AI ツールは結局入らない。2026年末で切れる延命に複雑度を払わないと判断した。

**採った構成**: macOS を温存したまま Lima ゲスト (NixOS) を常駐させ、エージェント環境だけを移した。
T2 機のネイティブ Linux 化 (デュアルブート) は Activation Lock 解除と Secure Boot 無効化が要り、
かつ有線 LAN 未接続で Wi-Fi (BCM4364) 依存になるためリスクが高く、採らなかった。

**残る選択肢**: Xcode 26.4 以降は macOS Tahoe 26.2 必須なので、mini の Xcode は 26.3 が上限。
それが問題になる日が来たら macOS を残す理由は iPhone バックアップだけになるので、ネイティブ
NixOS 化を再検討してよい。t2linux の NixOS サポートは現役 (nixos-hardware の `apple/t2`、
kernel 6.18 LTS / 7.0 に追従)。

### 宣言管理から外れているもの

- **mini の macOS**: generation 26 で凍結。設定変更は手で当てる。アンインストールはしていない
- **Lima 本体**: brew で導入 (macOS 側が nix 管理外のため)。`limactl autostart enable mini-vm` で
  LaunchAgent 登録済み。**macOS の自動ログインが前提** — 無いと再起動後に VM が上がらない。
  FileVault を有効にすると自動ログインが使えなくなり 24/365 運用が崩れる。
  インスタンス名は当初 `nixos` (テンプレート名のまま) だったが、`limactl stop` →
  `~/.lima/` 配下のディレクトリを rename → `limactl start` で改名できた
  (公式サポートされた操作ではないが動く。autostart は名前が変わるので登録し直しが要る)
- **`~/.local/bin`**: PATH 末尾の例外レーン。self-update 前提のツールや nixpkgs にない uv tool 用
- **apple/container**: 公式署名 pkg のみで brew にも nixpkgs にも無いが、pkg を `fetchurl` で hash 固定し
  activation から冪等に `installer` を叩く形で宣言管理下に置いた
  (`nix/modules/darwin/apple-container.nix`)。同種のツールが出たらこの形を踏襲する

### 保留中の課題 (このセッション以前から)

- **pve の SSD 故障**: 2026-05-20 に ext4 emergency_ro 転落。データは mini へ退避済み
  (`~/pve-*.img.gz` で計 28GB)。交換か再インストールかの判断が保留。mini のストレージ整理と連動する
- **uv tools の宣言管理**: mlx_whisper 等の uv tool 群を nix か宣言スクリプトで管理したい。未着手
- **Taildrive**: mini の `~/Storage` を中央ストレージにする構想だったがほぼ使われていない。
  VM 移行で mini の役割が変わったので、続けるか畳むか要判断
