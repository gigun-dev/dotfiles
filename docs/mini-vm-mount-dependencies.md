# mini-vm のホストhome共有を絞るための依存表

この表は2026-11-01のrepository宣言と既存運用記録から作成した。下記のLima設定と固定path・unit propertyだけを非root read-onlyで追加確認した。process-tableは読んでいない。秘密、鍵、keychain内容は読んでいない。先行する限定canary/sudo観測は[PR #122](https://github.com/gigun-dev/dotfiles/pull/122)に記録し、この設計branchからは追加のsudo照会やcanary操作を行っていない。設定案の実機適用、mount・権限・ネットワーク変更、停止・再起動は含まない。

適用前の実測と停止前保留の状態は[preflight記録](mini-vm-mount-preflight-2026-11-01.json)を参照する。

## VM内で保持するpath

宣言上、常駐サービスと自動更新に必要なのはVM内のpathであり、ホストの `/Users/gigun` 全体を共有する必要は確認できない。実機のdotfiles/Cloudflare OS checkoutと主要auth pathはVM homeと同じdeviceにあり、host homeへのsymlinkではないことをmetadataで確認した。全ての利用者jobまで網羅したものではない。

| 機能 | 宣言されているpath | home全体共有を外す場合 |
|---|---|---|
| Cloudflare OS | `/home/gigun/ghq/github.com/cloudflare/cloudflare-os`、`/var/lib/cloudflare-os/env`、`/run/agenix/gatekeeper-*-env` | VM内のcheckout・runtime state・秘密の供給を保持する。host checkoutの共有は不要。VM内checkoutの実体が独立していればmount削減だけでpathは変わらない |
| Codex bridge / remote control | `/home/gigun/.codex/auth.json`、`/home/gigun/.codex/`、`/home/gigun/.codex/app-server-control/`、`/run/codex-bridge` | VM側auth・enrollment・socketを保持する。hostの `.codex` は共有対象にしない。host authへのsymlinkを使っていれば起動条件が不成立になり、サービスがskipされ得る |
| agy remote control | `/home/gigun/.gemini/antigravity-cli/antigravity-oauth-token`、`/home/gigun/.config/systemd/user` | VM側の認可状態を保持する。host認可の共有を追加しない。system serviceのHOMEとWorkingDirectoryはVM home |
| dotfiles autoswitch / lock提案 | `/home/gigun/ghq/github.com/gigun-dev/dotfiles`、`/home/gigun/.config/gh`等のVM user設定、`/var/lib/dotfiles-lock-trial`、`/run/dotfiles-autoswitch-*` | VM内の編集可能な主checkoutとVM credentialを保持する。hostのdotfiles checkoutを残す理由にはならない。共有へのsymlinkならdirty/不在ガードで更新が止まり得る |
| Langfuse / Docker | `/etc/langfuse/compose.yaml`、`/run/agenix`、Docker named volumes、更新提案用のVM dotfiles checkout | Composeのnamed volumesを保持する。host homeのbind mountは宣言にない。Lima再起動ではVM内のLangfuseとDockerも停止するため、mount依存がなくても計画停止の影響を受ける |
| Beszel / heartbeat / MCP再ログイン | `/var/lib/beszel*`、`/run/beszel`、`/var/lib/host-heartbeat`、`/var/lib/codex-mcp-login`、VM home | 各VM内stateを保持する。host home共有は宣言上不要。停止中は監視・再ログイン受付・heartbeatが中断する |
| VM CLI / shell / HM links | `/nix/store`、`/etc/profiles/per-user/gigun`、`/home/gigun/.nix-profile`、`/home/gigun/.local/bin`、VM dotfiles checkout | Linux用CLIはVM側package/profileから使う。out-of-store symlinkはVM checkoutを参照する宣言なので、host checkoutを残す必要はない |

根拠は [mini-vm.nix](../nix/modules/nixos/mini-vm.nix) の `cloudflareOsDir` / `dotfilesDir` と各serviceのHOME・WorkingDirectory・ConditionPathExists、[home-managerのlink定義](../nix/modules/home/dotfiles.nix)、[Langfuse module](../nix/modules/nixos/services/langfuse.nix)、[Compose volumes](../infra/langfuse/compose.yaml)、[Beszel module](../nix/modules/nixos/services/beszel.nix)、[MCP再ログインmodule](../nix/modules/nixos/services/codex-mcp-login.nix) にある。設定キーのpathを確認しただけで、秘密ファイル自体は開いていない。

## ホスト側pathの取扱い

| ホスト側path / 接続 | 根拠と現在の用途 | 最小案・停止し得る機能 |
|---|---|---|
| `/Users/gigun` | [mount宣言](../nix/modules/nixos/mini-vm.nix) がhome全体をroで公開する。通常サービスからの直接参照は見つかっていない | 全体共有を残す要求は宣言から導けない。削除前にVM側のsymlinkと実際の利用checkoutを限定metadataで確認する |
| `/Users/gigun/.ssh`、`/Users/gigun/Library/Keychains`、host側の認証・設定directory | 限定canary検証で0600ファイルもVM同一UIDから読めたという作業結果がある | narrow mountへ含めない。VMが読めなくなるのは共有経由のpathであり、実鍵の利用・別通信経路まで遮断したとは扱わない |
| `/Users/gigun/dev-realbind/ssh/sst-key.pem` | [共通SSH設定](../nix/modules/home/programs/ssh/default.nix) の `realbind-sst-bot-ec2` がOS制限なしでIdentityFileに指定する | この鍵directoryを例外mountして互換性を維持しない。VMから当該aliasを使っていれば認証が止まり得る。host側で実行するか、業務用主体と資格情報の分離を別承認で決める |
| `/Users/gigun/.codeium/windsurf/bin` | [zshrc](../zsh/.zshrc) がOS判定なしでPATHへ追加する | mountを残す理由にしない。VMの対話shellで当該CLI候補が消える。Mac用PATH追加をDarwin限定にする設定案で整理できる。systemd serviceの固定PATHには影響しない |
| `/Users/gigun/ghq/github.com/gigun-dev/dotfiles` | [mini checkout同期](../scripts/mini-checkout-sync.py)・[Ansible変数](../ansible/mini-macos/group_vars/mini_macos.yml) はhost自身のcheckoutを対象にする。[pkg command例](../claude/commands/pkg.md) にMac絶対pathが残る | Pro→miniのAnsibleとhost checkout同期は、VMへのmountを必要としない。VMのagentがMac絶対pathのcommand例に従う動作は止まり得るため、VM用の `/home/gigun/...` または実行環境から求めるpathへ修正する。host checkoutの共有継続で補わない |
| `/Users/gigun/ghq/github.com/gigun-dev/swift-mcp-app`、`~/.local/share/asc-mcp-runner` | [既存iOSビルド記録](mini-vm.md#mini本体でのiosビルド署名) はmini側のcheckout・GUI session runnerでbuild/sign/exportする | mini本体のpathは保持するがVMへmountしない。VMはcommit SHA・設定・artifact hashを指定してhost側工程を起動する。VMが共有checkoutを直接読む未記録workflowは別途特定する |
| `~/.config/ota-deploy/`、`~/.ota-deploy/` | [既存OTA記録](mini-vm.md#cloudflareのアプリ配布) はhost設定と生成物をこのpathに分ける | publisher設定・credentialをVMへ共有しない。配布対象の署名済み成果物だけを明示的に受け渡す。現行toolがVMからこれらを読むかは未確認 |
| `/tmp/lima` | 現行はrwのvirtiofs mount。repository内にここを利用するservice・転送scriptの宣言は見つかっていない | 互換性のため最初の候補に残せるが、必要性は未確定。Lima設定の実sourceとmountPoint、利用する転送手順を確認してから、専用の非秘密artifact directoryへ絞るか削除する |
| `host.lima.internal`、Pro→miniのSSH、miniのGUI runner | [規約](../CLAUDE.md) はVMからhostでXcodeを使う構想、[mini運用記録](mini-vm.md) はhost SSHとrunnerの実績を記す | 通信とGUI sessionはmountと独立して残る。home共有を削ってもhost側で実行できる権限が残れば、その権限の範囲でhost homeへ到達し得る。今回この接続・権限を変更しない |

Darwin限定のOrbStack/Colima SSH Includeは [共通SSH設定](../nix/modules/home/programs/ssh/default.nix) で既にLinuxから除外される。これを理由にhostの `.colima` や `.orbstack` を共有する必要はない。[ESP32Drop記録](esp32drop.md) のMac絶対pathもhost作業例であり、VM常駐サービスの必要pathには数えない。

## 設定案で残す範囲

最小の第一候補は、VM内の `/home/gigun`・`/nix`・`/var/lib`・`/run` を維持し、host home全体のvirtiofs共有を外す形である。ホスト側の各checkoutやkeychainは移動・削除しない。互換性を優先して `/tmp/lima` を一旦残す場合でも、host側の実sourceに秘密やhome全体へのlinkを混ぜない運用が必要になる。

build/sign/publishを分ける案では、mini側のbuild checkoutと署名機能をVMの共有pathにしない。buildはcommit SHAを受け取ってmini側で用意し、署名は承認済みarchive hashを入力にhost側で実行する。publisherには署名済み成果物だけを渡す。VMからhostへのSSHやGUI runnerを同じUID・同じcredentialのまま残す場合、その実行権限は別の残存境界として扱う。

この候補だけで完全隔離は成立しない。VM current userのroot NOPASSWD ALL、VM内credential、Docker、Tailscaleやhostへの既存接続はmount削減では変わらない。必要pathのallowlistと、host側で実行できるcommand・署名・publish権限の分離は別にレビューする。

## 確認済みの実機metadataと残る不明点

2026-11-01の許可済みread-only確認:

- miniはLima 2.2.0、backendはvz、statusはRunning。instanceのmountsは `~` roと `/tmp/lima` rw。Limaの `_config/default.yaml` / `override.yaml` は存在しなかった。後日の設定変更までは保証しない。
- VMのdotfiles・Cloudflare OS checkout、`.codex/auth.json`、agy token、gh設定はsymlinkではなくVM homeと同じdevice。中身は開かず、存在・symlink・device一致だけを確認した。`.nix-profile` はVMのNix storeを指す。
- Cloudflare OSのWorkingDirectoryはVM内checkout。Codex bridge/remote controlとagyは `/home/gigun`。autoswitchのUserはroot。指定6unitのUser / WorkingDirectory / RootDirectoryだけを読み、Environmentやprocess一覧は取得していない。
- 実mountはvirtiofsでhome ro / tmp rw。Lima 2.2.0の[MountTag実装](https://github.com/lima-vm/lima/blob/v2.2.0/pkg/limayaml/defaults.go#L88-L93)から、locationとmountPointの組で既存2tagを再現できる。今回残すtmpのsource/pointを変えず、既存 `lima-1fd4cbcaa36d359d` を維持する。

未確認なのは、未宣言のhost↔VM転送・対話job、realbind SSH aliasとWindsurfの利用要否、tmp共有の実利用・保管物である。tmpは必要性が確定したためではなく、転送経路を同時に変えないため一旦残す候補とする。先のmetadata観測ではhostの `/tmp/lima` が存在しなかったため、適用前にsourceの存在を再確認し、必要な再作成や一時データの扱いも承認対象に含める。秘密の横断検索やprocess-tableへ調査を広げない。

ProのNOPASSWDの対象は、取得済み要約以上の分類ができないため未確定のままにする。新しいsudo照会や、miniの認証要求の再試行は実施していない。

## 未適用の設定案

[host側のLima field案](../infra/lima/mini-vm-mounts.draft.yaml)はhome exportを含まず、既存tmpだけを残す。これはfull instance設定ではない。丸ごと `lima.yaml` にコピーしたり、既存mountsへ追記したりしない。[guest側のNixOS案](../infra/lima/mini-vm-narrow-mounts.draft.nix)はhomeのfstab宣言を無効にするだけで、未importのため本番設定は変わらない。boot / root disk / 他のfileSystemsは触らない。[保守timer案](../infra/lima/mini-vm-mount-maintenance.draft.nix)も未importで、更新に関係する5timerを無効にし、bridgeの起動版を必須入力で一時pinする。

片側だけの変更では足りない。guestのfstabだけを消してもhypervisorがhomeをexportしたままなら、VM rootが再mountできる。hostだけを変えると古いguestのmount宣言が残り、起動待ち・失敗unit・次回switchの不整合を起こし得る。Limaの[設定合成](https://github.com/lima-vm/lima/blob/v2.2.0/pkg/limayaml/defaults.go#L122-L135)ではglobal設定のmountsが加算され得るため、instanceだけでなく適用時のdefault/overrideも照合する。

合成check `mini-vm-narrow-mounts` は、実際の本番home mountが有効なままのこと、同じ本番宣言を純粋評価で拡張したcandidateでhomeを無効にするとfstabから消えtmp/rootは変わらないこと、Lima field案がtmpだけを許可すること、計算したtmp tagが本番宣言のdeviceと一致することを検査する。保守案を含む適用候補と復旧候補の両方で5timerが無効、本番では有効のままであることも検査する。A/B双方のbridge commandは版だけが変わり、config/auth path等の引数は本番と同じであること、latest指定を拒否することも検査する。実bridge取得・起動、実mountや実VMの再起動は検証していない。

## 保守中に抑止する自動変更とbridge起動版

5timerは全てPersistentであり、停止期間の追実行を避けるためA/B両世代で無効にする。開始時は各timerを停止するだけでなく、対応する既存jobが完了していることを確認する。実行中jobの強制終了はこの案に含めず、必要なら別途承認する。

| timer | 確認するjob | 実コードの作用 |
|---|---|---|
| `dotfiles-autoswitch.timer` | `dotfiles-autoswitch.service` | NixOS/home更新 |
| `dotfiles-lock-propose-fast.timer` | `dotfiles-lock-propose@fast.service` | lock更新提案 |
| `dotfiles-lock-propose-slow.timer` | `dotfiles-lock-propose@slow.service` | lock更新提案 |
| `codex-openai-bridge-refresh.timer` | `codex-openai-bridge-refresh.service` | 最新版確認後、bridgeをtry-restartする（[mini-vm.nix](../nix/modules/nixos/mini-vm.nix)） |
| `langfuse-update-propose.timer` | `langfuse-update-propose.service` | build・branch push・PR作成/更新・auto-merge設定まで行う（[Langfuse module](../nix/modules/nixos/services/langfuse.nix)） |

refreshを止めても、本番bridgeのExecStartは `uvx openai-api-server-via-codex@latest` なので必須のbootで版が変わり得る。Nix世代を戻すだけではその版を戻せない。保守draftは `import .../mini-vm-mount-maintenance.draft.nix { bridgeVersion = V; }` の形で、事前確認した既知稼働版Vを必須入力にする。設計時にはVは未取得だった。後続の実測はpreflight記録を参照する。check内の0.0.0は合成値で、実配置には使わない。

適用前に、承認された非秘密version記録（例 `/run/codex-bridge/version`）とreadinessからVを確定し、private receiptへ記録する。unknown・不一致なら適用を止め、process-table走査で埋めない。同じVでA/Bの起動と復帰が可能かを承認済み範囲で確認する。Vを含むcommand・package取得可能性・cache前提・healthを検証できなければ再起動しない。pinは主packageの版を固定するもので、依存解決/cacheのbit単位復元まで保証しない。

この抑止は既知5本の自動更新経路に限定する。heartbeatやMCPログイン通知、外部actor、既存のGitHub auto-merge予約まで止めたとは扱わない。既に外部へ送られたPR/CIはtimerを止めても取り消されないため、保守前にその状態もread-onlyで確認し、必要な保留操作は別承認とする。A/Bは同じ固定sourceから作り、mainの動きを即座に適用させない。

## 承認対象・適用順・停止範囲

draftは未importなので、このPRをmergeしてもhome export/fstabを除外しない。実際の削減は次の一組を、計画停止の時間帯とともに別承認する。

| 対象 | 承認後の変更 | 影響 |
|---|---|---|
| `nix/modules/nixos/mini-vm.nix` のhome fileSystems block | draftを本番変更へ昇格し、homeのfstab宣言だけを除外する。draftの「本番は未変更」という検査も承認後の方針へ更新する | VMの共有homeを使う対話作業・上記SSH alias等が使えなくなる |
| miniの `~/.lima/mini-vm/lima.yaml` のmounts/mountType fields | 停止後、homeを除きtmpだけを残す。現在版のhelpで `--mount-only` / `--mount-type` 対応を確認済み | VZからhomeをexportしなくする。CPU・disk・user・network・provisionは変更しない |
| VMの更新timerと進行中agent作業 | 保守案で上記5timerを無効にした候補・復旧世代を準備する。現在のtimer停止と進行中jobの完了確認も保守操作に含める | 単なるstopやruntime maskは再起動を跨げない。5timerはPersistent=trueなので、保守世代なしの起動・rollbackは追実行し得る。今回は全て未実施 |
| VM bridgeのExecStart | A/B双方で既知版Vへ一時pin。通常方針へ戻すCではpin解除も別の受入段階にする | mount以外の追加変更。bridge可用性とCloudflare OSの推論経路に影響し得る。実版照会・pin・再起動は今回は未実施 |
| mini-vmの停止・起動 | clean stop→field変更→start | Cloudflare OS、bridge/remote agents、Langfuse/Docker、Beszel、heartbeat、MCP受付が全て一時停止。mount依存の有無とは別の停止影響 |

Lima 2.2.0の[edit実装](https://github.com/lima-vm/lima/blob/v2.2.0/cmd/limactl/edit.go#L55-L65)はrunning instanceのeditを拒否する。したがってこの案はhot変更ではなく計画停止・再起動を要する。これはProやmini macOSの再起動ではない。

承認後の順序は次のとおり。以下は未実行の保守案である。

1. `/tmp/lima` の存在と実source/mountPoint、Lima global default/overrideからの追加共有、未宣言の転送・進行中作業、管理consoleの復旧経路を確認する。確認不能なら適用せず、上表の追加変更と停止を承認する。Lima設定全体をprivateにmode保持でbackupし、NixOSの現行世代とpinned source revisionを記録する。設定backupの中身はログへ出さない。
2. 同じ固定revisionから、復旧用A（元mounts＋5timer無効＋V pin）、適用候補B（home除外＋5timer無効＋同じV pin）、検証後の通常運用C（home除外＋通常更新方針）をbuild・差分確認する。保守操作として現在の5timerを停止し、関連jobが終わっていることを確認してBを次のboot世代へ準備する。A/Bの両方で5timer unitが無効、bridge commandが同じVであることを起動前に確認する。無関係なlock更新やDB migrationを混ぜず、running guestのmountを先に切り替えない。
3. miniで `limactl stop mini-vm` 後、既存設定のmount fieldsだけを `limactl edit mini-vm --mount-only /tmp/lima:w --mount-type virtiofs --tty=false` 相当にする。full field案で設定全体を上書きしない。global/defaultからhomeが再追加されないこと、tmp sourceの存在・扱いを確認してからstartする。
4. 起動後にhome export/deviceとguest mountが両方なく、tmpだけが意図したrwであることをmetadataで照合する。非秘密canaryの陰性確認は改めて承認された範囲で行い、実鍵を試さない。
5. VM内checkoutとagent認可の存在、各サービスhealth、Cloudflare OSの認証済み経路、Langfuseのreadiness、heartbeat受理を確認する。期限切れ認証はmount障害と分けて止め、勝手に再認証しない。mount受入の確認後に限り、別段階でCのpin解除と5timer再開を行う。@latest再解決・Persistent追実行が起こり得るので、bridge版とhealthを再確認する受入窓も承認する。解除が未承認/未検証ならBの保守状態を継続し、通常復帰完了とはしない。

autoswitchが旧home宣言を再導入しないよう、実適用するpinned sourceと継続運用するmainの方針を揃える必要がある。未importのdraftを単発で使い、旧mainへ自動復帰させる運用は承認案に含めない。

## 復旧

pin解除後の問題がbridge版だけなら、home除外を維持するB（既知版V pin＋5timer無効）へ戻してbridgeを再受入する。版問題の解消にhomeを再公開する必要はない。実際の世代切替・service再起動は別承認する。

mount自体の問題で元へ戻す必要があれば、元Lima設定と復旧用A（元mounts＋5timer無効＋既知版V pin）のNixOS世代・sourceへ両方戻し、計画停止・起動で旧home ro / tmp rwへ復帰する。rawな旧世代ではboot時にPersistent timerが再開するため、Aを用意せずrollbackしない。復旧後のhealth確認まで保守状態とV pinを維持する。復旧はhome全体の秘密への公開範囲も元へ戻す操作である。mainのmount/更新方針が復旧方針と一致するまでは5timerを再開しない。guestが直接SSH可能なら既存のNixOS世代復旧を使い、SSH不能なら事前に承認・確認した管理console手順が必要となる。console未確認のまま実適用しない。拒否されたmini→VMのSSHを別経路で通す診断としては使わない。

VM disk、Docker/DB volumes、host/guest checkoutを削除・巻戻ししない。guest世代rollbackではDBデータは戻らない。復旧後はmount metadataとサービスhealthを再確認し、元の秘密公開範囲も戻る点を確認する。main整合と別承認した通常復帰の条件が揃ってから、pin解除・timer再開とbridgeの再受入を行う。

## iOS build / sign / publishへの反映

標準ascを使う既存案の工程は維持するが、VMからhostのcheckout・keychain・publisher設定をmountしない。miniのbuildは承認したcommit SHAからhost内checkoutを用意し、sign/exportは承認済みarchiveとprofile/identityをhost側の明示操作へ渡す。publisherには署名済みartifactだけを渡す。tmpを使うなら非秘密artifactの一時受渡しだけとし、rw共有に置かれた任意ファイルを自動で署名・公開しない。hashは同一性の照合であり、それだけで送り手の信頼性を証明しない。

同じGUI sessionのgigunでbuildとsignを実行する限り、工程を分けてもUnix/keychainの隔離にはならない。hostへのSSH、GUI runner、既存credential、VM rootとnetworkの到達性は別の境界として残る。専用主体作成・権限変更・署名・publishはこのdraftの適用対象外である。

観測と未採用の候補を整理する段階のため、新しいADRや独自の転送・署名frameworkは作らない。
