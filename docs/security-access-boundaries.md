# Pro・mini・mini-vm のアクセス境界

この文書は公開可能なtrust boundaryと受入条件を扱う。hostごとのUID、mode、sudo一覧、socket、mount、到達性等のcurrent stateは実機で確認し、恒久文書へ複写しない。過去の観測を現在の実効権限として扱わない。

## 宣言上の境界

- Proの人と対話agentは同じlogin userで動き、そのuserはNix trusted userである。
- miniはNix管理を凍結し、限定したAnsible対象だけをProから管理する。実効sudoやKeychain状態はlive確認する。
- mini-vmの対話agentは通常user、autoswitch等の管理serviceはrootで動く。通常userはwheelかつNix trusted userである。
- miniとmini-vmは一組の個人開発環境として扱う。別checkoutや別processは隔離ではない（[ADR 0015](adr/0015-mini-development-trust-boundary.md)）。
- miniのhome全体をmini-vmへ共有する宣言は撤去済みで、非秘密データ交換用の限定mountだけを残す。live mountは宣言と別に確認する。

## 権限を評価する原則

| 境界 | 意味 |
|---|---|
| 同一UID | 同じfile、Keychain利用権、socket、agent stateへ到達し得る。prompt上の役割や別checkoutはsecurity boundaryではない |
| passwordless sudo | 同一host上の低権限分離を崩す。sudo対象を列挙できない状態を「権限なし」と扱わない |
| Nix trusted user | daemonへ任意optionやsubstituterを渡せるため、通常の非trusted clientとして扱わない |
| system service | owner、capability、writable path、socket、networkを個別に確認する。system serviceという名前だけでは隔離にならない |
| dedicated CI user | 誤操作とambient credentialを減らすが、kernel、network、Nix store、diskをhostと共有する |
| Secure Enclave | private keyをexportできないことを保証するが、login中の同一UIDによる署名利用を防がない |

Guardとworktreeは誤編集・競合を防ぐ運用制御である。同一UIDからの秘密読取を技術的に遮断するものではない。

## SSH・network・credential

network reachabilityとSSH user authorizationは別policyとして扱う。タグ間でpacketが届いても、対象userのSSHを許可したことにはならない。宣言は[Tailscale policy template](../tofu/tailscale/policy.hujson.tftpl)、current stateはproviderで確認し、一時grantは目的終了後に削除する。

SSH login、Git HTTPS credential、Git SSH signing、secret decryptionは別用途である。一つの成功を別用途へ一般化せず、人用と無人用のcredentialも分離する。秘密配送は[ADR 0018](adr/0018-unify-secret-delivery-with-sops-and-allow-device-recipients-for-development.md)に従いSOPSへ移行する。

## container・Nix・共有file

- Docker socketを操作できる主体はhostの管理権限に近い。group非所属だけで全経路の拒否を証明しない。
- macOS container runtimeをDocker socketと同一視せず、実際のownerと接続経路を確認する。
- Nix storeは秘密の保管先にしない。非trusted CI clientでもstore、daemon、diskを共有する。
- 共有mountは非秘密artifactの交換に限定する。owner-only modeは、同一UIDの別環境に対する隔離にならない。
- checkout分離は競合対策であり、home、credential、Keychain、socketを分離しない。

## build・sign・publish

工程分離は、資格情報を持つ主体と承認点を明確にするために行う。

| 工程 | 入力と主体 | credential・承認点 |
|---|---|---|
| build | review済みsource、toolchain、SDKからartifactを作るbuild主体 | 配布identityやpublish credentialを与えない。source revisionとartifact hashを記録する |
| sign / export | 承認済みartifact hashとprofile / identityの組を署名主体へ渡す | automatic provisioningを既定にしない。temporary keychainも同一UID/rootからの強い隔離ではない |
| publish | 署名済みartifactとhashをpublisherへ渡す | 対象、destination、dry-run結果を確認してから外部変更を独立承認する |

miniで実装する場合は、専用UID、固定hash manifest、credential拒否、cleanup、旧GUI経路へのrollbackを非秘密fixtureで受入する。Linux CI runnerを署名runnerと同一視しない。

## 未確認の受入

- miniで実際に必要なsudo権限と用途不明な規則
- 撤去後のmini-vm live mountと追加mountの不存在
- current Keychain / signing identityのownerと利用主体
- 専用UIDによるbuild・sign・publishの受渡しとrollback
- 各serviceのwritable path、socket、network、capability

これらは値なしで実機確認し、結論と次操作だけを`todo.txt`へ残す。生のsudo一覧、UID、内部path、credential metadata、canary receiptを恒久保存しない。
