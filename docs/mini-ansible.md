# Intel mini の macOS を段階的に管理する

Intel mini の macOS は Ansible への移行中で、既存 Nix generation 26 と未移管の管理を残す。
Ansible は fzf / zoxide / ripgrep / XcodeGen の選択リンク、共通 shell のリンク、選択した user defaults を管理する。
NixOS の mini-vm、Pro の nix-darwin、既存の自動更新・監視は別の所有者のままとする。
watchdog の観測のみ設定は別途適用済みだが、稼働サービスの所有権は移していない。

## 所有者と移行の順序

`mini_targets` の既定は空。playbook を指定しただけでは管理対象を選ばない。
`mini_owners` は shell / packages / defaults / launchd など管理グループの所有者を記録する。
個々の CLI は `mini_tool_policy.<name>.adoption` に現在の owner と adoption state を記録し、
`mini_tool_policy.<name>.target` に希望する版・取得元・checksum 種別・選択先・更新方針をまとめる。
fzf / zoxide / ripgrep / XcodeGen は現在 `ansible` 所有として採用済み。`packages` / `launchd` は `manual` のまま。
通常の変更は所有者を `ansible` へ移管した対象だけ。例外の `launchd_stage` は所有者を
`manual` のまま保ち、起動対象外の staging ディレクトリに候補だけを置く。
対象の選択と所有権の移管は別であり、`mini_targets` に追加するだけでは移管にならない。

## CLI の共通宣言

各 CLI の `target` は目標の版・配布元・checksum と選択方針、`adoption` は実機で確認した現在の
所有者・状態を表す。目標を更新しても実機の adoption 状態は自動で変わらない。採用済み CLI は
実体ファイルの SHA-256 を検査してから選択リンクを作り、未知の既存ファイルやリンクを保全する。
パッケージ導入・更新は別操作であり、各 CLI の `update_policy` は手動のまま。

`fd` は Nix 10.4.2 が login shell で有効で、Homebrew Cellar の 10.5.0 は未選択の候補。
`vivid` は未導入で、Homebrew 0.11.1 の取得元・checksum が確認済みの候補。
`asc` は mini への read-only SSH 棚卸しで、公式 5.17.1 Intel release asset と同一 SHA-256 の
x86_64 実行ファイルとして確認した。release の `asc_5.17.1_macOS_amd64` は圧縮 archive ではなく raw Mach-O executable なので、checksum 種別は `release_executable_sha256`。
[公式 release assets](https://github.com/rorkai/App-Store-Connect-CLI/releases/expanded_assets/5.17.1)
の manifest と asset SHA が一致する。現在の手動配置 `~/.local/bin/asc` も mini で観測したが、login shell の選択先ではなく Ansible の destination にも指定しない。
この3件は adoption / selection が `pending` なので、`mini_targets` に指定しても適用前検査で拒否する。

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
uv run --locked --project ansible/mini-macos ansible-playbook -i ansible/mini-macos/inventory.yml ansible/mini-macos/update.yml --check --diff -e '{"mini_targets":["packages"],"mini_update_formulae":["xcodegen"]}'
```

実更新は `mini_apply_ack=true` と `mini_update_ack=true`、`mini_owners.packages=ansible` を要する。
`mini_targets` は `["packages"]` だけとし、`mini_update_formulae` を空でない対象リストにする。
導入・更新の formula allowlist は `lima` / `xcodegen` / `mo`。更新対象はさらに `mini_formulae` に
含まれている必要がある。`mini_casks` / `mini_update_casks` は空を要求し、cloudflared / Tailscale は対象外。
Homebrew metadata 自体は更新せず、既存 metadata に対して適用する。配布最新版の確認とは区別する。

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
| shell | 既存 repo 正本への5リンク。通常ファイル・別リンク・親リンクを拒否 | `.zprofile`、`/etc/zsh*`、login shell は未移管 |
| packages | Lima / XcodeGen / mo の存在維持。明示更新は別入口 | package install/update は manual。Nix CLI 群・GUI casks・VPN・cloudflared は現状維持 |
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
stagingの親シンボリックリンクは拒否し、既存shellディレクトリのpermissionは維持する。

参考: [check mode](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_checkmode.html)、
[Homebrew](https://docs.ansible.com/projects/ansible/latest/collections/community/general/homebrew_module.html)、
[macOS defaults](https://docs.ansible.com/projects/ansible/latest/collections/community/general/osx_defaults_module.html)。

## 初回shell移管の限定プレビュー

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

### 5リンクの管理権限

mini の shell owner は Ansible。通常の対象指定と apply acknowledgement は引き続き必要。
`.zshenv` / `.zshrc` / `.config/sheldon` / `.config/zeno` /
`.config/zsh/functions` を対象とし、`.zprofile` は移管しない。
mini の新しい HM 構成では `shellLinksManagedByAnsible = true` によってこの5件の生成を除外する。
bootstrap fallback は macOS の `LocalHostName=mini` の場合のみ5件を除外する。
Pro・他ホストの設定は維持する。ホスト名を変更するときはこの所有権判定も見直す。

凍結済みの HM generation は書き換わらないため、その activation を直接再実行しない。
この変更のために mini の Nix/Darwin switch は行わない。新しい HM 構成の除外を
旧 generation に適用済みとは扱わない。

初回移管では、残る3件が既知の HM symlink で、解決先が同じ repo のディレクトリであることを
全件確認する。未知のリンク・通常ファイル・ディレクトリなら停止する。元のsymlinkを
ホスト内の日時付き backup に rename して保全し、通常の shell apply で直リンクを作る。
通常タスクの他管理者リンク拒否は緩めない。復元が必要なら新リンクが想定どおりであることを
確認し、そのリンクだけを外して保存済みリンクを戻す（自動復元しない）。

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
