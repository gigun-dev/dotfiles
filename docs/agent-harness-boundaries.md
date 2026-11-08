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
- Edit / Write hookの拒否はBash、MCP、別providerのOS sandboxを証明しない。
- remote toolはlocal process、別process、remote serviceのどこで実行されるかを個別に確認する。

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

## 監査checklist

final resolved policy、OS privacy、Linux backend、MCP実行主体、remote toolの実行場所、上位managed policy、cross-repository rule scopeを非秘密canaryで確認する。

matrixの保守だけならADRは不要。sandbox既定、machine-wide上限、fail-closed化、人用secret rootのread deny、providerの別UID / 別VM化など、戻す費用の高い境界を決める場合はADR候補とする。
