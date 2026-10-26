# Intel mini の macOS を段階的に管理する

Intel mini の macOS は Ansible への移行中、既存 Nix generation 26 を残し、移す範囲を個別に決める。
NixOS の mini-vm、Pro の nix-darwin、既存の自動更新・監視は別の所有者のままとする。
Ansible の実機適用はまだ行っていない。既存watchdogの観測のみ設定は、別途承認を受けて最小変更で適用した。

## 所有者と移行の順序

`mini_targets` の既定は空。playbook を指定しただけでは管理対象を選ばない。
`mini_owners` は `shell` / `packages` / `defaults` / `launchd` ごとの所有者を持ち、
`shell=legacy` / `packages=manual` / `defaults=legacy` / `launchd=manual` が既定。
通常の変更は所有者を `ansible` へ移管した対象だけ。例外の `launchd_stage` は所有者を
`manual` のまま保ち、起動対象外の staging ディレクトリに候補だけを置く。
対象の選択と所有権の移管は別であり、`mini_targets` に追加するだけでは移管にならない。

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
| packages | Lima / XcodeGen / mo の存在維持。明示更新は別入口 | Nix CLI 群・GUI casks・VPN・cloudflared は現状維持 |
| defaults | Dock autohide / KeyRepeat の2項目 | 他のOS設定、電源、認証は未移管 |
| launchd | 起動検索対象外へ候補2ファイルを配置 | 稼働 user watchdog、heartbeat、Lima等のサービスは現状維持 |

`mini_owners` は移管の記録であり、旧管理者を自動停止するコードではない。変更前にその対象の
旧writerを特定し、miniの旧bootstrap/HMを併用しない運用を確認してから記録を変更する。
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
