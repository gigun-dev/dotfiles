# Intel mini の macOS を段階的に管理する

Intel mini の macOS は Ansible への移行中で、既存 Nix generation 26 と未移管の管理を残す。
Ansible は fzf / zoxide / ripgrep / XcodeGen の選択リンク、mini 専用の最小 shell 設定のリンク、選択した user defaults を管理する。
NixOS の mini-vm、Pro の nix-darwin、既存の自動更新・監視は別の所有者のままとする。
watchdog の観測のみ設定は別途適用済みだが、稼働サービスの所有権は移していない。

## 所有者と移行の順序

2026-10-29 の mini 読み取り時点の整理。Pro が Ansible controller、mini が管理対象。
導入された実体と、選択リンク・設定の所有者は別に扱う。

| 対象 | 現在の管理元・確認範囲 |
|---|---|
| Nix | macOS の新規適用は凍結中。既存 generation と user profile は残り、一部 CLI の実体を供給している |
| Homebrew | Lima / Tailscale や GUI cask 等の導入元。パッケージの導入・更新は手動管理のまま |
| Ansible | shell・defaults と採用済み CLI 選択リンクの所有を宣言。4 CLI の Homebrew 実体へのリンクと shell リンクは実機で確認した。既定では対象を選択しない |
| 常駐サービス | mini-vm の起動は `lima_daemon` が所有する。watchdog など他の `launchd` は未移管で、候補の staging と稼働サービスの管理を区別する |

`mini_targets` の既定は空。playbook を指定しただけでは管理対象を選ばない。
`mini_owners` は shell / packages / formulae / defaults / launchd など管理グループの所有者を記録する。
個々の CLI は `mini_tool_policy.<name>.adoption` に現在の owner と adoption state を記録し、
`mini_tool_policy.<name>.target` に希望する版・取得元・checksum 種別・選択先・更新方針をまとめる。
fzf / zoxide / ripgrep / XcodeGen の選択リンクは現在 `ansible` 所有として採用済み。Homebrew 全体の
`packages` と `launchd` は `manual` のまま。Lima formula の存在維持と明示更新だけを
`formulae` として切り出し、`mini_formula_policy` で `ansible` 所有にしている。XcodeGen / mo の
formula 所有者は監査・移管前の `manual` であり、選択リンクの所有権とは別である。
通常の変更は所有者を `ansible` へ移管した対象だけ。例外の `launchd_stage` は所有者を
`manual` のまま保ち、起動対象外の staging ディレクトリに候補だけを置く。
対象の選択と所有権の移管は別であり、`mini_targets` に追加するだけでは移管にならない。

## CLI の共通宣言

各 CLI の `target` は目標の版・配布元・checksum と選択方針、`adoption` は実機で確認した現在の
所有者・状態を表す。目標を更新しても実機の adoption 状態は自動で変わらない。採用済み CLI は
実体ファイルの SHA-256 を検査してから選択リンクを作り、未知の既存ファイルやリンクを保全する。
パッケージ導入・更新は別操作であり、各 CLI の `update_policy` は手動のまま。

`fd` は Nix 10.4.2 が login shell で有効で、Homebrew Cellar の 10.5.0 は未選択の候補。
`vivid` は現在 Nix 0.10.1 が存在し、Homebrew 0.11.1 は取得元・checksum が確認済みの未採用候補。
`asc` は mini への read-only SSH 棚卸しで、公式 5.17.1 Intel release asset と同一 SHA-256 の
x86_64 実行ファイルとして確認した。release の `asc_5.17.1_macOS_amd64` は圧縮 archive ではなく raw Mach-O executable なので、checksum 種別は `release_executable_sha256`。
[公式 release assets](https://github.com/rorkai/App-Store-Connect-CLI/releases/expanded_assets/5.17.1)
の manifest と asset SHA が一致する。現在は `~/.local/bin/asc` に手動配置され、rollback 用の 5.9.2 がある。
2026-10-31 の SSH 確認では、対話 login shell (`zsh -lic`、TTY なし) はこの配置を選び、noninteractive shell では見つからなかった。Ansible の destination には指定しない。
この3件は adoption / selection が `pending` なので、`mini_targets` に指定しても適用前検査で拒否する。

## 凍結 generation 参照の監査境界

2026-11-12 の値非表示監査では、login shell の `gh` / `fd` / `node` はいずれも
`/etc/profiles/per-user/gigun/bin` の Nix profile を解決した。`fd` には検証済み Homebrew
候補があるが、mini で使っていないため採用しない。`gh` も mini の現在の役割だけを理由に
新規導入しない。`node` を使っていた mugi-claw は未使用と確認できたため、2026-11-12 に
LaunchAgent を unload し、plist リンクと専用 Chrome process だけを除去した。`~/.mugi-claw`
と owning repo は保持している。

残存参照は `audit_nix_refs.py` が値を出さず、plist はファイル名・key path・参照種別、text は
ファイル名・行番号・参照種別だけを報告する。実測では次の所有境界だった。

| 参照 | 現在の所有者 | 次の切り出し |
|---|---|---|
| `com.mugi-claw.plist` の program / PATH | mugi-claw repo | 未使用のため退役済み。Node の代替導入はしない |
| ASC runner の `.path` | runner の運用設定 | build workflowへ固定Nodeを反映済み。実build受入後にrunnerを停止し、Nix profile 1要素だけを除去する |
| `/etc/zshenv` | 凍結 nix-darwin generation | Nix 撤去時まで監査対象として保持。ユーザー shell cutover とは分離 |
| Nix の activate / daemon / gc plist | Nix 自身 | 全 consumer の参照解消後の撤去作業だけで扱う |

NotchBar の LaunchAgent は存在するが、同日の構造化監査では Nix 参照を検出しなかった。
過去の記録を現状の根拠にせず、この監査結果を撤去前に再確認する。監査は plist の値、環境変数、
資格情報を表示しない。ここで確認しただけでは launchd の所有権移管や切替の承認にはならない。

ASC runner の保存PATHは system 5要素、home 1要素、Nix user profile 1要素だった。Nix要素だけを
除く候補では `python3`、`xcodebuild`、`git`、`asc` が残り、`node` と `npm` だけが消える。
原因はprivate build workflowがhostのNodeを暗黙利用し、check workflowにある
`actions/setup-node`を欠いていたことだった。2026-11-12に公開templateとprivate control repoの
両方へ同じ完全SHAのactionを反映した。Nodeは現行`engines`が許す24系を指定し、
`check-latest: true`で各jobが最新security patchを取得する。patch更新で同じworkflow SHAの
実行環境が変わる代償を受け入れ、majorは自動で越えない。Node 26 LTS対応は依存互換性と
`engines`を同時に更新する別作業とする。miniホストへNodeを常設しない。

PATH切替前後の固定source実buildは、どちらもNode setup、`npm ci`、Xcode archiveまで成功し、
同じ署名export境界で停止した。失敗原因は現GUI runner contextにDistribution identityと有効な
Xcode accountが無いことで、Node由来ではない。runner停止中にNix profile要素だけを原子的に
除去し、他の6要素を保持して再開した。runnerはonline/idleへ戻り、値非表示監査でASC runnerの
Nix参照が消えた。これはarchive工程とPATH移行の受入であり、署名・publish・OTA配布の成功ではない。

`selection.mode: protected_service` は destination 文字列の allowlist だけを検査する。
これは実際のファイル保護を証明しない。採用前に mini 上で実体と全親の symlink chain をたどり、
実体・親ディレクトリそれぞれの owner、group、mode、ACL を確認し、ユーザーが書き込めないことを確認する。
許可する文字列パターンは `/nix/store/<store-path>`、`/run/current-system/sw/bin/<name>`、
`/Library/PrivilegedHelperTools/<name>` に限る。`/usr/local` 全体は allowlist に含めず、
`/usr/local/bin` や `~/.local/bin` のようなユーザーが書き込める可能性のある場所はサービスの選択先にしない。

1. audit で現状と既存の所有者を確認する。古い導入記録を現在の実機状態の代わりにしない。
2. 対象のファイル、競合する既存管理、更新方法、復旧方法をレビューし、所有権を明示的に移す。
3. check mode の差分を確認する。実適用は対象を限定して別途承認する。
4. 適用後に対象を検証する。サービスの所有権・起動方式の移行はさらに別の段階で扱う。

`shell` から始めても、既存 Nix のリンク、bootstrap の生成物、手編集のファイルを
無条件に上書きする許可にはならない。`packages` の導入と更新も区別する。
移管した対象に旧 bootstrap / home-manager を再実行して、管理を二重化しない。
認証、sudo、trusted-users、ネットワーク設定、SecretOps / 1Password の再設計はこの移行に混ぜない。

## playbook の使い分け

以下はリポジトリルートからの操作例。inventory の接続先と対象所有者を確認してから使う。
audit も対象ホストへの接続が必要になるので、リポジトリ内の構文確認とは区別する。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/audit.yml
```

`apply.yml` は選択した対象の宣言を適用する。まず差分を確認する。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml --check --diff -e '{"mini_targets":["shell"]}'
```

check mode でも、選んだ通常対象の所有者は `ansible` である必要がある。例えば shell の
移管レビュー後に `mini_owners.shell` を変更してから上記を実行する。
実適用は追加の acknowledgement を要する（`launchd_stage` の staging 書き込みも含む）。
これは実行時の誤操作防止であり、ユーザーの適用承認を代替しない。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml -e '{"mini_targets":["shell"],"mini_apply_ack":true}'
```

`update.yml` は更新を明示的に選ぶ入口。通常の適用に一括 upgrade を混ぜない。
既存の自動更新を無効化する入口でもない。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/update.yml --check --diff -e '{"mini_targets":["formulae"],"mini_update_formulae":["lima"]}'
```

実更新は `mini_apply_ack=true` と `mini_update_ack=true`、`mini_owners.formulae=ansible` を要する。
`mini_targets` は `["formulae"]` だけとし、`mini_update_formulae` を空でない対象リストにする。
formula の構造上の allowlist は `lima` / `xcodegen` / `mo` だが、実際の対象はさらに
`mini_formula_policy` で個別に `ansible` 所有へ移し、`mini_formulae` に含める必要がある。
現在は Lima だけである。`mini_casks` / `mini_update_casks` は空を要求し、cloudflared / Tailscale は対象外。
Homebrew metadata 自体は更新せず、既存 metadata に対して適用する。配布最新版の確認とは区別する。

## Git 署名ツールの配布候補

`signing_tools` は既定で未選択、所有者は `manual`。移管と適用の承認後にのみ
`ansible` へ変更し、`mini_targets: [signing_tools]` と `mini_apply_ack: true` で選ぶ。
この対象は鍵の作成・参照の自動採用・Git 設定・GitHub 登録を行わない。

Pro 上の専用 cache に公式 Nushell 0.116.1 Intel archive と、upstream commit
`7975b7d33ec2b6c733e08c87c9cb1e7945462a1c` の 2 script を取得し、archive、展開後の
`nu`、各 script の SHA-256 を宣言値と照合する。mini の
`~/.local/share/dotfiles/mini-signing/versions/<bundle>/` へ検証済みの `nu`、script、
引数を渡す wrapper を配置し、全ファイルの hash と mode を検証してから `current` を選ぶ。
`current/git-sign` は将来 Git から参照できる候補で、今回の playbook は Git を設定しない。

更新は新しい版・source・hash を宣言し、旧 `current` の絶対パスを
`mini_signing_approved_previous` に列挙したうえで `mini_update_ack: true` も要する。
rollback も戻す版の宣言と、現在の選択先の明示承認・同じ確認フラグを要する。以前の
version ディレクトリは削除しない。未知のファイルやリンク、異なる hash は上書きせず停止する。
`--check` は既存選択を検査するが、download・展開・配置後の hash は実行しない。
実機への適用、鍵参照の検証、署名試験および GitHub 登録は別の作業である。

## mini-vm のブート時起動 (`lima_daemon`)

mini-vm は `/Library/LaunchDaemons/io.lima-vm.daemon.mini-vm.plist` から起動する。
2026-11-11 に macOS の自動アップデートで再起動したとき、アップデート後の設定アシスタント (MiniBuddy) が
終わるまで gui/501 が on-demand-only のままになり、LaunchAgent から起動していた VM が 10 分上がらなかった。
system ドメインの daemon はログインもこの待ちも経ない。plist は Lima 2.3.0 の
`limactl autostart enable` (condition=boot) の雛形に `ExitTimeOut=60` と `HOME` / `USER` を足したもの。
Lima 2.2.x では daemon 起動の vz インスタンスが再起動のたびに Broken になる (lima-vm/lima#5087) ため、2.3.0 以上を要求する。

```sh
# 1. Lima を上げる (稼働中の hostagent はそのまま。新しい版は次の起動から)
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/update.yml -e '{"mini_targets":["formulae"],"mini_update_formulae":["lima"],"mini_apply_ack":true,"mini_update_ack":true}'
# 2. 切り替え (VM を止め、旧 LaunchAgent を .before-ansible-* へ退避し、daemon を bootstrap)。sudo のため -K
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml -K -e '{"mini_targets":["lima_daemon"],"mini_lima_daemon_cutover":true,"mini_apply_ack":true}'
```

旧 LaunchAgent が残っていると、切り替えフラグ無しでは止まる (二重起動を防ぐ)。
`limactl stop mini-vm` は daemon 起動でも SIGINT で止まり、正常終了なので `KeepAlive{SuccessfulExit=false}` は起こし直さない。
その後の `limactl start` は launchd を経ずに起動し、次のブートで daemon に戻る。
plist の変更は読み込み済みの job には効かない (次回ブートか、VM を止めて bootout / bootstrap)。

macOS には shutdown の前にゲストを止める公開の仕組みがない。launchd は SIGTERM 後 `ExitTimeOut` 秒で kill し、
Lima 2.3.0 は停止要求が通らなければ SSH で `shutdown -h now` を送るが、ホストの shutdown で VZ が先に落ちると届かない。
手で再起動するときは先に `limactl stop mini-vm` する。

戻すときは daemon を `launchctl bootout system/io.lima-vm.daemon.mini-vm` して plist を消し、
退避した LaunchAgent を元の名前へ戻して `launchctl bootstrap gui/501` する。

## launchd はまず配置候補だけ

初期段階は `mini_targets=["launchd_stage"]` で staging のみとし、稼働中の plist の差し替え、load / unload、
`bootstrap` / `bootout` / `kickstart` は行わない。staging の成功を監視の移行完了とは扱わない。

watchdog は Wi-Fi の復旧操作を持つため、確認目的で本体スクリプトを実行しない。
既存の `bootstrap.sh --net-watchdog` や system installer も呼び出さない。
将来の移管では次を維持・確認する。

- user agent の `dev.gigun.net-watchdog` と system daemon の同名ラベル、Nix 側の
  `org.nixos.network-watchdog` を調べる。二重起動は Wi-Fi 復旧操作を競合させる。
- スクリプトは checkout へのリンクではなくコピー。30 秒間隔、`RunAtLoad`、標準 PATH を維持する。
- user 側の `~/Library/Logs/net-watchdog` と system 側の `/var/log/net-watchdog` の過去ログを保存する。
- script だけの変更と plist の変更を区別する。既存 bootstrap は script だけなら再ロードしない。
- GUI セッション、Lima の自動起動、自動ログインの前提を勝手に変更しない。

## 検証の限界

`--check --diff` は実機適用の成功保証ではない。command が skip される場合や、まだ作成されていない
ディレクトリに後続処理が依存する場合がある。`check_mode: false` のタスクは check mode でも実行される。
現実装の例外実行は `uname` / `id` と audit の読み取りコマンドだけ。サービス handler はない。
Homebrew / defaults モジュールは check mode を持つが diff を返さないため、`--diff` だけで
変更内容をすべて確認できるとは限らない。staging ディレクトリが存在しない場合、check mode では
作成が予測されるだけなので、後続 copy / template の検証は実適用と同じにはならない。

ローカルでは YAML / playbook の構文、template の plist 構造、対象未選択時の挙動、所有権・acknowledgement
のゲート、staging の差分を検証する。mini の接続性、GitHub 認証、パッケージ導入、稼働サービスの正常性は
その検証結果に含めない。`gh` コマンドの存在だけでは認証の有効性は分からない。

## 2026-10-26 の実機 snapshot

既存 SSH 経路の読み取り結果では mini は Intel / macOS 15.7.9、`/usr/bin/python3` は 3.9.6。
この Python は対象側の実行環境で、controller 側の uv project の Python とは別に扱う。
GitHub の `gh` 認証が現在有効かは未確認。

Homebrew の採取時点の一覧は次のとおり。自動的な削除リストや最新版保証には使わない。

- formula: `cloudflared`, `lima`, `mo`, `tailscale`, `xcodegen`
- cask: `aqua-voice`, `azookey`, `claude`, `cmux`, `codex`, `discord`, `figma`, `fork`,
  `google-chrome`, `iterm2`, `karabiner-elements`, `monitorcontrol`, `ollama-app`, `postman`,
  `proxyman`, `slack`, `tableplus`, `zed`

shell の env / rc / sheldon / zeno / functions は repo へのリンク。
一方、`.zprofile` は 44 bytes の通常ファイルであり、自動置換しない。

watchdog の user label は `dev.gigun.net-watchdog`。`/bin/bash` で
`~/Library/Application Support/net-watchdog/network-watchdog.sh` を実行し、30 秒間隔、
`RunAtLoad=true`、`LastExitStatus=0`。環境は `NET_WATCHDOG_DIR=~/Library/Logs/net-watchdog`、
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`、stderr は同ログディレクトリの `daemon.err`。
system 側の両 watchdog plist は存在しなかった。終了コード 0 だけでは回線復旧能力を検証したことにはならない。

**稼働中 script と repo script の SHA-256 が異なる**（採取結果の prefix はそれぞれ
`aaebae7f…` / `9e912aa9…`）。比較で判明した差分は過去の GUI セッション停止を説明するコメント 9 行の欠落だけで、
実行コードの動作は同じだった。Ansible の launchd 対象は staging のみ。
別途承認された最小変更として、2026-10-26 に既存user plistへ `NET_WATCHDOG_NO_REMEDIATE=1` を
追加し同じagentを再読み込みした。script・起動方式・間隔は維持し、Wi-Fi自動操作だけを無効化した。

## 2026-11-12 の再監査

mini-vm の controller checkout は `main` で、dirty なし、`origin/main` と同期していた。
既存 SSH 経路から読んだ mini は Macmini8,1、Intel x86_64、macOS 15.8.3 (24H241)。mini 側
checkout は `main` の `3a258846` で、`claude/settings.json` にClaude Codeが書いた未コミット変更が
あった。この変更は本人承認後に破棄した。

古い追跡参照では129 commit behindに見えたが、live fetch後の実態は326 ahead / 562 behind、
共通祖先 `3a8a7fa` だった。現在のmainはpublic化時の履歴再構成後にあり、fast-forwardではない。
`scripts/mini-checkout-sync.py` は設計どおり停止した。旧側固有の非merge patchが0件でworking treeが
cleanなことを確認し、本人承認後に退避参照を作らず現行`origin/main`へ付け替えた。付け替え後は
`922c949`でahead / behind 0 / 0、dirtyなし。

再auditは成功し、Homebrew一覧、defaults、watchdog、generation 26の参照は付け替え前と同じだった。
最小shell切替の`--check --diff`も成功した。予告された差分は、既知の旧5リンクを日時付き名称へ退避し、
`.zshenv` / `.zshrc` の2件だけを`ansible/mini-macos/files/zsh/`へ張り替えるもの。formula、defaults、
launchdは対象外で、実適用はまだ行っていない。

本人承認後、同じ対象で実適用した。旧5リンクは
`.before-ansible-20261112T125027Z`へ退避され、`.zshenv` / `.zshrc` はmini専用設定を指す。
非対話shellは正常起動し、TTYなしのlogin shellでもbrew / limactl / xcodegenを解決した。
後者ではfzf / zoxideのinitが`zle`警告を出したが終了コードは0で、TTY対話利用とは条件が異なる。
mini専用2ファイルにはNix profileや旧pluginへの実行時参照はない。再適用はchanged=0だった。

Homebrew formula は `cloudflared`, `fd`, `fzf`, `go`, `lima`, `mo`, `pcre2`, `ripgrep`,
`tailscale`, `xcodegen`, `zoxide`。cask は 2026-10-26 の一覧と同じだった。defaults の2項目と
user watchdog は宣言どおりで、watchdog の LastExitStatus は 0。ただし回線復旧能力の検証ではない。
`/run/current-system` は generation 26 を指す。`.zshenv` / `.zshrc` は古い mini checkout 内の共通
`zsh/` をまだ指し、ADR 0014 の最小 shell への実機切替は未完了である。これは owner 宣言の完了と
実機適用を同一視できない例なので、target checkout の同期と shell 切替はそれぞれ別承認で扱う。

## 既存記録の読み方

既存の [mini-vm 運用記録](mini-vm.md) と [セットアップ手順](setup.md) には、macOS 側の
Homebrew による Lima / Tailscale 導入、Lima の LaunchAgent、自動ログインへの依存、
XcodeGen 2.46.0 の導入記録がある。これらは導入時点の記録で、現在の完全なパッケージ一覧ではない。
watchdog の user agent と system daemon のコードが両方存在することも、両方が実機で稼働している証拠にはならない。
移管対象の snapshot には採取時刻と取得元を添え、formula / cask、plist の存在、ロード状態を区別して残す。

## watchdog が観測・復旧するもの

既定 gateway への ICMP、外部 IP `1.1.1.1` への ICMP と TCP/443、既定 resolver による
`one.one.one.one` の A レコード解決を観測する。gateway と Wi-Fi デバイスは動的に検出する。
復旧対象は「リンク active・IPv4 あり・gateway ICMP 失敗・外部 ICMP/TCP の両方失敗」の状態。
DNS 失敗だけでは Wi-Fi を操作しない。状態が連続 2 サンプル続くと Wi-Fi off/on を一度試み、
健全なサンプルを見るまで再発火しない。`NET_WATCHDOG_NO_REMEDIATE=1` なら復旧を実行しない。
ルータ自体の停止も同じ条件に入るため、判定だけで Wi-Fi ドライバ障害とは断定できない。
自動復旧の効果は保存ログで実証されていない。現在は全配布plist/宣言で
`NET_WATCHDOG_NO_REMEDIATE=1` とし、サンプル記録だけを継続する。代替の自動再接続は導入しない。
上記のoff/on分岐はスクリプト内に残るが、現在のサービス設定では実行されない。
元plistは `~/Library/LaunchAgents/dev.gigun.net-watchdog.plist.before-observe-only` に保全。
これを戻すと自動復旧が再び有効になるため、通常の復旧手順として無断で戻さない。

## 管理境界と復旧

| 対象 | 初期実装の範囲 | 残す管理・依存 |
|---|---|---|
| shell | `ansible/mini-macos/files/zsh/` の最小 `.zshenv` / `.zshrc` への2リンク。通常ファイル・別リンク・親リンクを拒否。旧5リンクの撤去は明示フラグ | `.zprofile`、`/etc/zsh*`、login shell は未移管 |
| packages | Homebrew 全体は manual のまま | Nix CLI 群・GUI casks・VPN・cloudflared を含め、包括的には移管しない |
| formulae | Lima の存在維持。明示更新は別入口 (2026-11-11 の 2.3.0 更新を契機に個別移管) | XcodeGen / mo の formula 所有者は manual。選択リンクの所有権とは別 |
| lima_daemon | mini-vm の LaunchDaemon 1件と、旧 LaunchAgent の退避 | VM の設定 (`lima.yaml`)・ディスクは Lima のまま |
| xcodegen | 検証済み 2.46.0 Cellar binary への `/usr/local/bin/xcodegen` 1リンク | Homebrew formula の導入・更新と Nix profile は変更しない |
| defaults | Dock autohide / KeyRepeat の2項目 | 他のOS設定、電源、認証は未移管 |
| launchd | 起動検索対象外へ候補2ファイルを配置 | 稼働 user watchdog、heartbeat、Lima等のサービスは現状維持 |

`mini_owners` と CLI ごとの `adoption.owner` は移管の記録であり、旧管理者を自動停止するコードではない。
変更前にその対象の旧writerを特定し、miniの旧bootstrap/HMを併用しない運用を確認してから記録を変更する。
既存のNix daemon・store・generationや自動更新・監視は一括停止しない。
パッケージ更新は依存パッケージや実行中のLimaへの影響を伴い得るため、更新候補名だけで安全とは扱わない。

復旧は対象別に行う。今回のshell実装は既存オブジェクトを上書きしないため、新規リンクだけならその作成を
取り消せる。defaultsは事前のread結果へ戻す。Homebrew更新の巻き戻しは保証されないので、Lima更新前には
互換性とVM復旧手順を別途確認する。launchd stagingは稼働対象外なので既存サービスを触らず破棄できる。
Nixの削除は、残存CLI・shell・launchdからのstore参照がなくなったことを棚卸ししてからの最終段階とする。

## ローカル検証

```sh
sh ansible/mini-macos/verify.sh
```

uv.lock で controller の Ansible / ansible-lint を固定する。初回はツール取得のネットワークアクセスがある。
Python 3.12 はcontroller用、miniのPython 3.9はこの固定Ansible coreの対象実行に使う。
verify はlint、3 playbookのsyntax、実Ansibleを使う一時ディレクトリのリンク・staging検証を実行する。
SSHは実行しない。CIもmacOS runnerの一時領域だけを使い、inventoryのminiには接続しない。
`verify.sh portable` は lint・syntax と macOS 固有ツールを使わない fixture を実行し、
`verify.sh native` は macOS の `plutil` が必要な fixture を実行する。引数なしは両方を含み、native の前提がなければ失敗する。
2026-10-29 に NixOS x86_64 の固定依存で portable 24 件が成功した。native や macOS 固有の動作の検証には代わらない。
stagingの親シンボリックリンクは拒否し、既存shellディレクトリのpermissionは維持する。

controller は project の `pyproject.toml` / `uv.lock` / `.python-version` を使う。
2026-10-29 の Intel mini では lock 中の `cryptography` 50.0.2 に対応 wheel がなく、
上流は 49 以降の macOS x86_64 サポートを終了している
([上流 changelog](https://cryptography.io/en/50.0.2/changelog/#v49-0-0))。
Pro の Apple Silicon では 2026-10-29 に固定依存で lint、3 playbook の構文検査、ローカル fixture 20 件が成功した。対象への SSH・apply は行っていない。
Linux controller で inventory の解析・syntax 等を検討できても、macOS 固有の検証は別に必要。
グローバル導入や未検討の依存 downgrade で解消済みとは扱わない。

参考: [check mode](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_checkmode.html)、
[Homebrew](https://docs.ansible.com/projects/ansible/latest/collections/community/general/homebrew_module.html)、
[macOS defaults](https://docs.ansible.com/projects/ansible/latest/collections/community/general/osx_defaults_module.html)。

## 初回shell移管の限定プレビュー

(履歴: 2026-11-08 に共通 shell のリンクから最小設定へ切り替えた。現行の手順は下の「最小 shell 設定への切り替え」。
3件がHM中間リンクだったという下記の観察と異なり、同日の再読み取りでは5件とも repo への直リンクだった。)

2026-10-26のminiでは、`.zshenv`と`.zshrc`はrepoへの直リンクだが、
`.config/sheldon`・`.config/zeno`・`.config/zsh/functions`はHMの中間リンクを経由する。
最終参照先が同じでもHM所有リンクの置換は移管とは別なので拒否する。
親ディレクトリの作成先は常に`mini_home`配下とし、実行時のcwdに依存しない。

以下は最初の2リンクだけのプレビュー。owner指定はこの呼び出し限りで、
永続的な所有権移管や実適用の承認にはならない。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook \
  -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml --check --diff \
  -e '{"mini_targets":["shell"],"mini_owners":{"shell":"ansible","packages":"manual","defaults":"legacy","launchd":"manual"},"mini_shell_links":[{"src":"zsh/.zshenv","dest":".zshenv"},{"src":"zsh/.zshrc","dest":".zshrc"}]}'
```

実適用を承認する場合は、この2リンクに限る所有権の移管を記録し、旧bootstrapと
凍結HMのshellリンクactivationを併用しないことを確認する。HMにはこの2リンクを
再作成するcustom activationも残るため、`home-files`にないことだけでは未管理と
判断しない。今後Nix/HMを再適用する際は所有境界を再確認する。
他3リンク、defaults、packages、launchdは初回移管に含めない。
実適用コマンドは上記から`--check --diff`を外し、`-e '{"mini_apply_ack":true}'`を追加する。
miniでは`.config`と`.config/zsh`も既存の通常ディレクトリであることを確認済み。
既存2リンクとこの親2ディレクトリが正しければ変更予定はゼロ。親が欠けていれば
共通shell taskはこの2ディレクトリも作成するため、適用前のdiffに含めて確認する。
shell起動設定やPATH本文を変更せず、
アプリ再起動・package更新・cleanup・sudoは行わない。

### 最小 shell 設定への切り替え (ADR 0014)

mini の shell owner は Ansible。通常の対象指定と apply acknowledgement は引き続き必要。
mini の対話シェルは iPhone バックアップ・Xcode・Lima・Tailscale の操作と保守だけなので、
共通の `zsh/` は配らず、Nix に依存しない最小の2ファイルを使う。

- `ansible/mini-macos/files/zsh/.zshenv`: `typeset -gU PATH`、XDG、`brew shellenv` 相当の静的 export
  (`/usr/local`)、`~/.local/bin` を PATH 末尾へ。fork なし
- `ansible/mini-macos/files/zsh/.zshrc`: history (`$XDG_STATE_HOME/zsh/history`)、補完、素朴なプロンプト、
  `ls -G`、`fzf` / `zoxide` は `/usr/local/bin` にある場合だけ init
- sheldon / zeno / deno / eza / mise / vivid と、`/nix` や `/etc/profiles` の参照は持ち込まない
- 対象は `.zshenv` / `.zshrc` の2リンクで、`.zprofile` は移管しない (中身は `brew shellenv` で無害)
- `/etc/zshenv` `/etc/zshrc` は nix-darwin の生成物で Nix の PATH を足す。この変更では触らない (Nix 撤去の段階で扱う)

旧構成の5リンク (`.zshenv` / `.zshrc` が共通 `zsh/`、`.config/sheldon` / `.config/zeno` /
`.config/zsh/functions` が repo 直リンク) は `mini_shell_legacy_links` に宣言してある。
2026-11-08 の読み取りでは5件とも repo への直リンクだった (HM の中間リンクではない)。
旧リンクの撤去は通常の apply とは別の明示操作で、`mini_shell_retire_legacy=true` を渡した時だけ行う。
宣言した repo パスを指す symlink だけを対象にし、通常ファイル・ディレクトリ・他のリンク先は
どれか1件でもあれば何も動かさず停止する。対象は元の名前に日時 (`.before-ansible-<UTC>`) を付けて
rename し、削除しない。フラグ無しでは `.zshenv` / `.zshrc` が旧リンクのまま競合として止まる。
sheldon / zeno / functions の3リンクは、フラグ無しなら放置される (管理しないだけで消さない)。

mini の source は確認済み main への fast-forward で同期するため、`--check` で新ファイルの存在を
確かめるには、先に mini の checkout へ新ファイルが届いている必要がある。

```sh
# 差分の確認 (retire はフラグ有りの場合の計画を debug で表示。command は check mode では skip)
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml --check --diff -e '{"mini_targets":["shell"],"mini_shell_retire_legacy":true}'
# 承認後の実適用
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml -e '{"mini_targets":["shell"],"mini_shell_retire_legacy":true,"mini_apply_ack":true}'
```

復元は新リンクが想定どおりであることを確認し、その2リンクを外して `.before-ansible-*` を
元の名前へ戻す (自動復元しない)。

HM とbootstrap は mini で共通の5リンクを作らない。mini の新しい HM 構成では
`shellLinksManagedByAnsible = true` により生成を除外し、bootstrap fallback は macOS の
`LocalHostName=mini` の場合のみ除外する。Pro・他ホストの設定は維持する。
ホスト名を変更するときはこの所有権判定も見直す。凍結済みの HM generation は書き換わらないため、
その activation を直接再実行しない。この変更のために mini の Nix/Darwin switch は行わない。

### user defaults の管理

miniのDock `autohide=true` と `NSGlobalDomain.KeyRepeat=2` はAnsibleが所有する。
`--check --diff -e '{"mini_targets":["defaults"],"mini_apply_ack":true}'` で現在値を確認し、
同じ引数でcheckを外して適用する。他のdefaults、アプリ再起動、packagesは対象外。
新しいmini用Nix宣言はこの2項目だけを除外し、Proには従来値を残す。
凍結済みDarwin activationは変更しないため直接再実行しない。

miniのsource同期は、作業差分を保全し、確認済みmainへのfast-forwardで行う。
同期前にhookとIntel自動switch抑止、live参照ファイルの差分を確認する。
Nix/Darwin switchをsource同期の一部として実行しない。

### fzf の通常利用への移管

`mini_targets: [fzf]` は検証済み Homebrew Cellar の fzf 実行ファイルを
`/usr/local/bin/fzf` にリンクするだけです。PATH、共通 zsh 設定、fzf-tmux、
fzf-preview.sh、man、Nix profile は変更しません。通常の packages/update
対象にも fzf は追加しません。版の更新は別途検証し、この宣言を更新します。

採用版は 0.74.5。private Release
`fzf-bottle-8fbf99f81906e22c07d07e19157a2e51d7a4fdfea26e2f15a25b4bb4c80d5068`
の bottle SHA-256 は
`45957f1abe8b2c450629c09c3ed9afa31feb8bc16935417949b387f53249e689`。
既存の隔離導入済み実行ファイルは同 Release 内の実行ファイルと同一で、
Ansible は実行ファイルの SHA-256 を検証してからリンクします。
未知の既存ファイル・リンクや異なる実行ファイルは上書きせず停止します。

```sh
cd ansible/mini-macos
uv run --locked ansible-playbook -i inventory.yml apply.yml \
  -e '{"mini_targets":["fzf"],"mini_apply_ack":true}' --check --diff
# 差分が fzf の1リンクだけであることを確認後、--check --diff を外して適用
```

初回はリンクが存在しない状態を記録してから適用します。既存 Nix 0.71.0
は保持されます。rollback はこの target の適用を止め、リンク先が上記の
承認済み Cellar 実体であることを確認して `/usr/local/bin/fzf` のリンクのみ
取り除き、shell の `rehash` / 新規起動で Nix 版への解決を確認します。
Homebrew package 自体や他のリンクは削除しません。

### zoxide の通常利用への移管

公式 Homebrew zoxide 0.10.0 Intel Sonoma bottle は Sequoia の既存
Homebrewで `--force-bottle --skip-link` 導入できました。追加依存なし、
receipt は poured_from_bottle=true。公式 bottle SHA-256 は
`d3c9b69ac0b3d814619be69d32acfd5416d9e082ef5cddf21c698a5e0ae90ecb`。
Intel は Homebrew の Tier 3 で、新しい Intel bottle の継続提供は保証されません。

`mini_targets: [zoxide]` は1リンクだけを選択し、owner は `ansible` です。
現在の Nix 0.9.9 とユーザーDB・shell cache は保持します。
隔離検証は一時 `_ZO_DATA_DIR` と一時HOMEで z/zi を確認しました。

通常採用時の影響は `/usr/local/bin/zoxide` の追加と、新規shellが既存の
共通 `.zshrc` に従って init cache を更新することです。既存cacheの更新条件は
実行ファイルのmtimeなので、採用時は旧cacheの保全と新版initとの整合確認が必要です。
初回採用では旧版の標準init出力と一致するcacheだけを退避し、新版の
`zoxide init zsh` から同じ共通設定のhook除去を行い、zcompileします。
未知の編集やリンクがあれば停止します。Ansibleの反復適用はcacheを書き換えません。
rollback は target適用を止め、承認したCellar実体を指すリンクだけを外し、
保全したinit cacheを戻すか共通shellで再生成します。DB移行・削除は行いません。


### ripgrep の通常利用への移管

mini の通常利用では、検証済み Homebrew ripgrep 15.2.0 を
`/usr/local/bin/rg` に選択します。Ansible は Cellar の実行ファイルを SHA-256
`f8cf484393a97aaaa4ce35df1c5ea2790f6b8af6d86c8d31b3e694369dc5ebb4` で確認してから
この1リンクだけを作成します。Homebrew package の導入・更新・cleanup、PATH、Nix
profile は変更せず、Nix ripgrep 15.1.0 を fallback として保持します。
未知の既存ファイルや異なるリンクは上書きしません。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook \
  -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml \
  --check --diff -e '{"mini_targets":["ripgrep"]}'
# 差分が /usr/local/bin/rg の1リンクだけだと確認後に適用する
uv run --locked --project ansible/mini-macos ansible-playbook \
  -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml \
  -e '{"mini_targets":["ripgrep"],"mini_apply_ack":true}'
```

新規シェルで `command -v rg` が `/usr/local/bin/rg`、`rg --version` が 15.2.0、
normal と `--pcre2` の synthetic search が成功することを確認します。動的リンクに
`/nix/store` が含まれないことと、git / gh の解決先が変わらないことも確認します。
Ansible の再適用で `changed=0` を確認してください。

rollback は対象指定を止め、`/usr/local/bin/rg` が上記の Cellar 実体を指すリンクで
あることを確認してから、そのリンクだけを削除します。新規 zsh で Nix 15.1.0 が
選ばれることを確認します。Homebrew package、Nix profile、他のリンクは削除しません。

### XcodeGen の選択リンク

mini に導入済みの XcodeGen 2.46.0 は Homebrew core の Intel Sonoma bottle から
Sequoia に pour され、formula の依存はありません。公式 bottle SHA-256 は
`d0e021076a96894c2d48a51003e99ab4885130f69ea922a67de8bef3062c5a50`。
`/usr/local/bin/xcodegen` は同じ Cellar binary
を指す Homebrew の相対 symlink でした。Ansible は実行ファイルの SHA-256
`b8714a29ed5d40319ff8a653e08fa684c756deee1ff0db15cac66b6392a55ba3` を検査し、既知の
Homebrew symlink だけを絶対パスの symlink に置き換えます。未知のファイルやリンクは
そのまま拒否します。

`mini_targets: [xcodegen]` はこの1リンクだけを扱います。Homebrew formula の導入・更新、
PATH、shell 設定、Nix profile、他の Homebrew link は変更しません。

```sh
uv run --locked --project ansible/mini-macos ansible-playbook \
  -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml \
  --check --diff -e '{"mini_targets":["xcodegen"]}'
# 差分が /usr/local/bin/xcodegen のリンク先表記だけだと確認後に適用する
uv run --locked --project ansible/mini-macos ansible-playbook \
  -i ansible/mini-macos/inventory.yml ansible/mini-macos/apply.yml \
  -e '{"mini_targets":["xcodegen"],"mini_apply_ack":true}'
```

新規 login / interactive zsh で `/usr/local/bin/xcodegen` と版 2.46.0 を確認します。
checksum-gate は同じ binary を検証し、再適用は `changed=0` です。rollback はリンク先が
検証済み Cellar binary であることを確認し、Homebrew が元に作った相対 link
`../Cellar/xcodegen/2.46.0/bin/xcodegen` に戻します。Cellar package は削除しません。
