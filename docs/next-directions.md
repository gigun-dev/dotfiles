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
  インスタンス名・tailnet 名・hostname はすべて `mini-vm`(`mini` は macOS 側を指す)。

- **未検証の危険**: apple/container の再起動後の復帰。Apple Silicon 限定なので mini では確認できず、
  M4 Pro を再起動しないと分からない (apiserver は launchd 登録済み)。→ `DF-5`

- **裁定待ち**: SPEC.md の扱いと CLAUDE.md「ディレクトリ構造」節の圧縮。どちらも下に理由付きで書いた。
  あわせて「やってみて分かった手順知識」の置き場所が決まっていない (CLAUDE.md は 200 行制限があり
  不適、log.md は時系列なので引きにくい)。→ `DF-2` `DF-3` `DF-6`

## 着手順(次にやること)

- [ ] `DF-2` SPEC.md の扱いを決める
      2026-04-10 の初期コミット以降まったく更新されておらず、Windows 対応も Lima VM も入っていない。
      現行仕様として読まれると事故る。案: (A) 冒頭に「初期設計の記録」と注記して凍結 (推奨)、
      (B) 削除して CLAUDE.md に一本化、(C) 現状に追従。`docs/SPEC-initial.md` へ移す手もある。
      → 完了条件: 3案のどれかを実施し、現行仕様と誤読されない状態にする
- [ ] `DF-3` CLAUDE.md の「ディレクトリ構造」節を圧縮する
      `zsh/.zshrc # メイン設定` のような同語反復を削り、`zsh/functions/ # permission は 755 必須`
      のような非自明な制約だけ残す。`windows/` 配下の詳細は `windows/README.md` に委ねる。
      → 完了条件: 39 行 → 15 行程度にし、doctor の「長い節」指摘が消えること
- [ ] `DF-5` apple/container の再起動後の復帰を確認する
      M4 Pro を再起動する機会に `container system status` を見るだけ。単独で再起動する必要はない。
      → 完了条件: 再起動後に手を触れず apiserver が running であること
- [ ] `DF-6` 手順知識の置き場所を決める
      「Lima のインスタンス名は rename できる」のような、やってみて分かった再利用可能な操作知識に
      置き場所が無い。CLAUDE.md は 200 行制限があり不適、log.md は時系列で引きにくい、
      コメントは対応するコードが無い。skill 化 (呼ばれたときだけロード) が候補。
      → 完了条件: 置き場所を決めて、Lima リネーム手順を実際にそこへ移す
- [x] `DF-1` pre-push を `git/hooks/pre-push` に置く
      harness の `.githooks` は採らなかった。`core.hooksPath` は 1 つしか持てず、切り替えると
      既存の `git/hooks/pre-commit`(staged .nix の nix fmt 自動整形)が無言で死ぬため。
      検証内容は CI と同じ `nix flake check --no-build` + `nix fmt -- --ci .`。
      なお `nix flake check` は現在の system しか評価しないので、壊れている x86_64-darwin 構成は
      この関門では検出されない。
      → 2026-08-06 / f5c82f2 / 成功パス: 本番 push で両コマンドが走ってから push されるのを確認。
        失敗パス: 検証コマンドを `false` に差し替えた複製を実行し、exit 1 と中止メッセージを確認
- [x] `DF-4` harness の不具合を配布元へ起票する
      → 2026-08-06 / gigun-dev/claude-code#1 #2 / #1 は doctor が「毎回〜に**なる**」(症状の記述)を
        自動化指示と誤検知し、真に該当する行を挙げていないこと。#2 は init の pre-push テンプレートが
        `if ! {{CHECK_COMMAND}}` のため複合コマンドで `(! a) && b` と解釈され前半の失敗が素通りすること
        (このリポジトリの分は修正済み、他リポジトリへ配った分は要確認)
- [x] `DF-7` mini の再起動からの自動復帰を検証する
      → 2026-08-06 / 2ff15f4 / `sudo reboot` 後、「macOS 自動ログイン → LaunchAgent → Lima 起動 →
        VM の tailscaled 復帰」が手を触れず通ることを確認。46 秒で mini へ、その直後に mini-vm へも
        ssh 成立。boot 時は `networking.hostName` が効きゲストの hostname も `mini-vm` になる
- [x] `DF-8` Lima インスタンス名を mini-vm に揃える
      → 2026-08-06 / 2ff15f4 / `limactl stop` → `~/.lima/nixos` を rename → `limactl start` で改名でき、
        VM 作り直し (nix store 9.5GB の再取得) は不要だった。autostart は名前が変わるので登録し直し。
        `limactl list` が `mini-vm Running`、LaunchAgent も `io.lima-vm.autostart.mini-vm.plist` に

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
