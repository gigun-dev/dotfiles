# Tailscale tailnet の設計

権限定義の正本は[Tailscale policy template](../tofu/tailscale/policy.hujson.tftpl)、判断は[ADR 0010](adr/0010-tailscale-policy-as-code.md)と[ADR 0015](adr/0015-mini-development-trust-boundary.md)である。この文書には公開可能な役割と運用原則だけを置く。実端末との対応、node状態、address、到達性はprovider current stateとして確認し、ここへ複写しない。

## tagの役割

| tag | 役割 |
|---|---|
| `tag:admin-device` | 本人が操作する管理端末。管理SSHの起点 |
| `tag:dev` | 同じtrust domainで扱う個人開発環境 |
| `tag:storage` | file共有機能。継続判断まで独立roleとして扱う |
| `tag:client` | 管理起点にしない一般client |
| `tag:proxmox` | 仮想化host role |

tagは権限class、hostnameは実行先の選択に使う。nodeを追加・用途変更したときは、provider上のtagと宣言の差分を確認する。

## 原則

- tag無しnodeへの包括fallback ruleを置かない。
- network reachabilityとTailscale SSHのuser authorizationを別policyにする。
- 開発環境間はnon-root operatorだけを許可し、rootを常用経路にしない。
- 管理端末からのSSHと、開発環境同士のSSHを区別する。
- 無人nodeでkey expiryを無効にする場合も、廃止・侵害時は明示失効する。これはGitHub、署名、配布credentialの期限を変えない。
- temporary grantは目的、対象、期限を限定し、作業後に削除する。
- policy denialを別host、別user、LAN直結等で迂回しない。必要ならpolicy変更を別承認する。

miniとmini-vmは一組の個人開発環境として扱うため、相互SSHは利便性の経路であり、秘密や署名credentialの隔離を証明しない。build・sign・publishは別の主体と承認点で整理する。

## overlay SSHと直接SSH

overlay network上のSSHとLAN等の直接SSHは、同じsshdへ到達するとは限らず、認証方式も異なり得る。overlay経路の成功から直接経路のpassword認証、root login、公開portを推測しない。診断時は経路と認証主体を分けて記録する。

## file共有

Taildriveは同期ではなくnetwork mountで、提供nodeが停止すれば利用できない。継続する場合は次を受入する。

- provider宣言と実際のshareが一致する
- clientから再読取できる
- shareへ秘密やcredential directoryを含めない
- 提供node停止時の挙動と復旧方法が分かる
- 不要になったtag、share、client mountを撤去できる

実path、node名、tailnet識別子、完全URL、当日の到達結果は恒久文書へ保存しない。利用可否と継続・廃止は`todo.txt`で追跡する。

## live受入

policy変更後は値なしで次を確認する。

- 必要なnodeがRunningへ戻る
- 想定userのSSHだけが成功する
- 禁止したuser / directionが拒否される
- 主要serviceと公開入口が再起動後に復帰する
- provider planに意図しない差分がない

確認結果は「成功したroleと方向、未確認範囲、次操作」に限定し、device対応表や内部addressのsnapshotを残さない。
