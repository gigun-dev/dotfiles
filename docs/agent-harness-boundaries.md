# エージェントharnessの権限境界

Codex、Claude Code、T3 Codeで同じ`Auto`という表示があっても、同じsandboxを意味しない。permission mode、providerの承認方針、OS sandbox、tool hook、外部サービスのpolicyを別の境界として扱う。

実効境界はsession、host、versionごとにlive確認し、変化するcurrent値を恒久文書へ複写しない。sandbox内の失敗をcredential失効へ読み替えない診断は[実行環境とアクセス境界の確認](execution-context.md)を使う。

## 境界の層

| 層 | 決めるもの | 決めないもの |
|---|---|---|
| orchestrator / harness | thread mode、provider選択、tool呼出しと承認の仲介 | OSが実際に拒否する操作、外部サービスの認可 |
| provider approval | commandやtoolを自動実行するか、承認を求めるか | 同一UIDから読める範囲、network到達性 |
| OS sandbox | filesystem、network、process等へのkernel側の拒否 | GitHub scope、tailnet ACL、TCCの同意 |
| tool / hook | Edit・Write・Bash・MCP等の個別経路に対する規則 | 別tool、同一UIDの別process、OS全体 |
| external policy | GitHub権限、tailnet ACL、Access policy等 | local filesystemや別serviceの権限 |
| OS privacy | Keychain、Automation、Accessibility等のOS privacy境界 | provider approvalや外部サービスの認可 |

`Auto`は承認方法の名前であり、network許可、秘密の不可読化、別UID化を保証しない。hookによるEdit / Write拒否も、Bash、MCP、別providerまで隔離しない。

## 実行contextごとの確認項目

各sessionで次を値なしで確認する。

- resolved approval policyと上位managed policy
- kernelが強制するfilesystem read / writeとnetwork
- Bash、Read、Edit、Write、MCPごとのtool境界
- subprocess / remote toolの実行主体と場所
- Keychain、GUI、TCC等のOS privacy境界
- external service側の認可

一つのtoolの成功・拒否を、provider全体または別toolへ一般化しない。設定名やerror文だけからApple Seatbelt、bubblewrap、Landlock等のbackendを断定しない。

## 誤判定を起こしやすいパターン

- repo外read、repo外write、networkは別々に拒否され得る。
- local credential設定の読取成功・失敗はonline認証の成否ではない。
- build toolは評価前にrepo外cache DBへのwriteで失敗し得る。同じcommandを承認済みcontextで比較し、HOMEやcacheをcheckoutへ移す回避を通常設定にしない。
- macOSでは、通常contextと承認済みcontextで同じ無害な`/usr/bin/sandbox-exec` probeを比較できる。通常contextだけnested sandboxの適用を拒否する結果はApple Sandbox経路の関与を示すが、profileの生成元、個別rule、network policyまで特定したことにはならない。
- Edit / Write hookの拒否はBash、MCP、別providerのOS sandboxを証明しない。
- remote toolはlocal process、別process、remote serviceのどこで実行されるかを個別に確認する。
- SSH executorからremote hostでprobeを起動した結果は、そのremote processの境界だけを示す。
  remote host上のT3 / Codex / Claude native sessionを経由していないなら、そのharnessの
  sandboxやapproval policyの証拠として扱わない。

## 観測と記録

実秘密を使わず、同一の非秘密canaryに対して各層を別々に測る。

| probe | 確認するもの | 注意 |
|---|---|---|
| network policy | kernel policy判定とtransport結果 | DNS失敗だけでsandbox backendを判定しない |
| filesystem read / write | workspace内外の専用canary | read成功とwrite成功を分ける。実HOMEをcanaryにしない |
| provider approval | direct CLIとorchestrator経由のresolved mode | 表示名ではなく実際に渡されたpolicyを確認する |
| tool経路 | Bash、Read、Edit、Write、MCPを別々に確認 | 一つのtoolの拒否を全体sandboxへ一般化しない |
| Keychain / GUI | 専用dummy itemとdummy Automation対象 | 実credentialをprobeに使わない。OS privacy denyとsandbox denyを分ける |
| Linux backend | provider diagnosticsと非秘密canary | error文だけでbackendを推測しない |

比較中だけ保持するreceiptは、provider class、version、OS class、resolved mode、probe class、result class、時刻、承認前後の結果に限定する。token、account ID、鍵、内部接続先、exact secret path、生stderrを保存しない。恒久的な設計変更と未解決事項をtodoへ反映した後、receiptは削除する。

共通の非秘密probeはリポジトリrootから次のように実行する。既定ではnetworkへ接続せず、script自身のread、現在の作業directoryとOSの一時directoryへの固定canary write/read/delete、自processだけの`ps`、Apple Sandboxの`network-outbound` policyを独立して記録する。拒否があっても後続probeを止めず、credentialの有効・無効は評価しない。

```sh
python3 scripts/harness-boundary-probe.py \
  --host pro --harness t3-code --provider codex
```

networkを比較するときだけ`--network`を付ける。接続先は固定のpublic canary `example.com`で、DNSとHTTPS HEADを別結果にする。HTTP応答はstatusだけを記録し、bodyやheaderは読まない。実credentialを使うGitHub確認はこのprobeへ混ぜず、`github-auth-diagnose.py`で別に行う。

各harnessで同じcommit、同じ引数を使い、stdoutのJSONを期限付きreceiptとして比較する。`declaredHarness`と`declaredProvider`は呼出側の申告であり、実際に解決されたproviderやapproval policyの証拠ではない。resolved modeとversionはharness自身の表示・session metadataで別に確認する。通常contextと承認済みcontextの結果を上書きせず、両方を残す。

remote executor比較では、receiptに実行経路のclass（例: local harness process / approved local process /
SSH-launched remote process）も添える。SSH-launched processが緩い結果でも、remote hostのnative harnessが
同じ境界だとは判定しない。

## 監査checklist

final resolved policy、OS privacy、Linux backend、MCP実行主体、remote toolの実行場所、上位managed policy、cross-repository rule scopeを非秘密canaryで確認する。

Proからの対話操作は強い権限を許容する。ただし、その許容はPro上のclient / harness contextに限定し、
environment link、remote executor、mini-vmのnative harness、無人jobへ自動的に継承されたとは扱わない。
各経路でresolved sandbox、approval、TCC、実行UIDを別々に確認する。

## 参考実装から採用する原則

ryoppippi/dotfilesは、standalone Codexのapprovalと、調査時のread-only、編集時のworkspace-write、
必要時だけのnetworkを用途別に分けている。mozumasu/dotfilesはClaudeのtool permissionとhookを
細かく宣言している。どちらも独自のSeatbelt profileを正本としておらず、tool allow / denyや
`auto_review`からOS sandboxを推定できない。このrepoでも次だけを原則として採用する。

- 調査・レビューはread-only、repo編集はworkspace-write、networkは必要な実行だけに付与する。
- approval、tool permission、filesystem / network sandbox、TCCを別の境界として記録する。
- Proの対話経路で強い権限を許容しても、remote・無人経路へ一般化しない。
- Claudeの`skipDangerousModePermissionPrompt`は確認表示の省略であり、permission modeやSeatbeltを
  無効化する設定として扱わない。

参照時点の設定は
[ryoppippiのCodex](https://github.com/ryoppippi/dotfiles/blob/620d187d/nix/modules/home/programs/codex/default.nix)、
[用途別sandbox](https://github.com/ryoppippi/dotfiles/blob/620d187d/agents/skills/ask-other-agent/references/outside-t3.md)、
[mozumasuのClaude](https://github.com/mozumasu/dotfiles/blob/b33d01b/.config/nix/home-manager/claude-code.nix)、
[mozumasuのCodex](https://github.com/mozumasu/dotfiles/blob/b33d01b/.config/nix/home-manager/codex.nix)。
current値は変わり得るため、ここへ複写せず比較時に再確認する。

matrixの保守だけならADRは不要。sandbox既定、machine-wide上限、fail-closed化、人用secret rootのread deny、providerの別UID / 別VM化など、戻す費用の高い境界を決める場合はADR候補とする。
