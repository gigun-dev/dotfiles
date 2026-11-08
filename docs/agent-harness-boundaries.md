# エージェントharnessの権限境界

Codex、Claude Code、T3 Codeで同じ`Auto`という表示があっても、同じsandboxを意味しない。permission mode、providerの承認方針、OS sandbox、tool hook、外部サービスのpolicyを別の境界として記録する。

この文書は2026-11-09時点の値なし台帳である。現況、今回の実測、過去観測、未確認を分け、設定名だけから実効境界を推測しない。sandbox内の失敗をcredential失効へ読み替えないための診断手順は[実行環境とアクセス境界の確認](execution-context.md)を使う。

## 境界の層

| 層 | 決めるもの | 決めないもの |
|---|---|---|
| orchestrator / harness | thread mode、provider選択、tool呼出しと承認の仲介 | OSが実際に拒否する操作、外部サービスの認可 |
| provider approval | commandやtoolを自動実行するか、承認を求めるか | 同一UIDから読める範囲、network到達性 |
| OS sandbox | filesystem、network、process等へのkernel側の拒否 | GitHub scope、tailnet ACL、TCCの同意 |
| tool / hook | Edit・Write・Bash・MCP等の個別経路に対する規則 | 別tool、同一UIDの別process、OS全体 |
| external policy | GitHub権限、tailnet ACL、Cloudflare Access等 | local filesystemや別serviceの権限 |
| OS privacy | Keychain、Automation、Accessibility等のTCC・Security framework境界 | provider approvalや外部サービスの認可 |

`Auto`は承認方法の名前であり、network許可、秘密の不可読化、別UID化を保証しない。hookによるEdit / Write拒否も、Bash、MCP、別providerまで隔離しない。

## 現況matrix

| 実行面 | policyの主体 | OS強制 | filesystem | network | subprocess / MCP | Keychain / GUI | 追加承認経路 |
|---|---|---|---|---|---|---|---|
| standalone Codex / Pro | Codex user設定 | 現設定ではsandboxなし | `danger-full-access` | 制限なし相当 | 同一UID | 通常のOS / TCC境界。live未確認 | 現設定は`approval_policy=never`のためなし |
| T3 → Codex Auto / Pro | T3 thread modeとCodex app-server | Apple Seatbeltを今回実測 | repo外readは可。writeはcheckoutと明示rootに限定され、repo外canaryはdeny | Seatbeltの`network-outbound` denyを今回実測 | Codex tool policyの対象。remote toolはshell通信と別 | GitHub credentialの読取不能を観測。Keychain全体とGUIは未確認 | `require_escalated`をT3 `auto_review`または人が承認した別実行 |
| standalone Claude Code / Pro | Claude settingsとpermission mode | 現行repo / user設定ではBash sandbox未設定 | Edit / Writeはworktree hook対象。Bashは同一UID | BashのOS sandboxは未確認 | MCP、hook、file toolはBash sandboxと別 | 通常のOS / TCC境界。live未確認 | Claudeのpermission prompt。sandbox有効時は別途unsandbox承認 |
| T3 → Claude Auto / Pro | T3 orchestratorがClaude provider / `auto`を指定。Claude user設定も`auto` | Claude Bash sandboxは無効。Seatbelt `network-outbound` allowを実測 | Bashはrepo外を含む同一UID範囲へwrite可。Write/EditはAuto classifierとworktree hookの別境界 | Bash processにSeatbeltのnetwork denyなし。外部transport自体は未実行 | Write/Edit hookはBashを覆わない。MCPはlocal subprocess / remote serviceごとに別 | Keychain / GUI / TCCは未確認 | Auto classifier、hook、permission callback。T3が渡した最終callback metadataは未確認 |
| T3 / mini-vm | T3 thread mode、provider設定、Linux host設定 | backend未確認 | 同一UIDならT3、provider、業務code間の隔離にはならない | live policy未確認 | providerとMCPごとに確認が必要 | Linux側のcredential保管境界は未確認 | providerごとのapproval経路を実測する |

standalone Codexの現設定は推奨ではなく現況である。`danger-full-access`の廃止、Claude sandboxのfail-closed化、T3の上限mode固定は、利便性と既存運用への影響を比較して別途決める。

## backendの扱い

確認済み:

- T3から起動したCodexの今回のProセッションでは、harnessが`workspace-write`とnetwork制限を選び、macOS側でApple Seatbeltの`network-outbound` denyを実測した。
- 同セッションではcheckoutと`/private/tmp`へのwrite、repo外文書のread、repo外への非秘密canary作成denyを実測した。resolved `workspace-write`と一致するが、private APIのpath-filter付き`sandbox_check`は正例もdenyになったため証拠として使わない。
- `scripts/github-auth-diagnose.py --local-only`はSeatbelt denyとlocal credentialの読取不能を分離した。これはcredential失効の証拠ではない。
- 同じ診断をT3 `auto_review`の`require_escalated` contextで実行するとSeatbeltのnetwork denyは無く、GitHubからHTTP 200を得た。token値、response body、headerは記録していない。
- T3からClaude 2.1.319を`auto`で起動したProセッションでは、ClaudeのBash sandbox設定が無く、`network-outbound`はSeatbelt上allowだった。Bashはcheckout外の非秘密canaryも作成できた一方、Write toolはAuto classifierまたはworktree hookで拒否された。したがってWrite/EditのdenyをBashやClaude全体のOS sandboxへ一般化しない。
- Claudeのworktree guardはEdit / Write経路のhookであり、Bash、MCP、Codexの強制境界ではない。

仕様上の候補で、live未確認:

- Claude Codeはsandboxを有効にしたmacOSでApple Seatbelt、Linuxでbubblewrapとnetwork proxyを使い得る。
- CodexのLinux backendはversionとpolicyによりLandlockまたはbubblewrap系の経路があり得る。
- T3のmanaged policyは選択可能なruntime modeを制限する管理面であり、OS sandboxそのものではない。

mini-vmやWSLではprovider versionとresolved policyを採取するまでbackendを断定しない。DNS失敗、`EPERM`、tool denyの文言だけからSeatbelt、bubblewrap、Landlockのいずれかを決めない。

## 観測と記録

観測は実秘密を使わず、同一の非秘密canaryに対して各層を別々に測る。

| probe | 確認するもの | 注意 |
|---|---|---|
| network policy | macOSでは`network-outbound`判定とtransport結果 | DNS失敗だけでSeatbeltと判定しない |
| filesystem read / write | workspace内外の専用canary | read成功とwrite成功を分ける。実HOMEをcanaryにしない |
| provider approval | direct CLIとT3 threadのresolved mode | 表示名ではなく実際に渡されたpolicyを記録する |
| Claude tool経路 | Bash、Read、Edit、MCPを別々に確認 | 一つのtoolの拒否を全体sandboxへ一般化しない |
| Keychain / GUI | 専用dummy itemとdummy Automation対象 | 実credentialをprobeに使わない。TCC denyとsandbox denyを分ける |
| Linux backend | provider diagnosticsと非秘密canary | error文だけでbackendを推測しない |

private作業記録へ残すmetadataは、harness、providerとversion、host OS、thread / runtime mode、approval policy、sandbox policy、観測backend、probe class、result class、時刻、承認前後の結果に限定する。token、account ID、鍵、内部接続先、exact secret path、生stderrは記録しない。

## 未確認と次の判断

- T3からClaudeを起動した場合にadapterが渡す最終permission callback metadata。今回orchestratorは`auto`を指定し、実挙動もAuto classifierを観測したが、session内から最終値を直接読めていない
- standalone Codexを`danger-full-access`にしている現在の運用意図
- T3 → CodexでのKeychain全体、GUI、TCCの実効範囲
- mini-vmとWSLでのCodex / Claude backend、provider設定、MCP実行主体
- remote toolがlocal process、別process、remote serviceのどこで動くか
- repo外のmanaged settingsや上位policyの有無
- Claudeのuser-wide Auto classifier contextに別repository固有の前提が残る現況のscope修正

matrixの保守だけならADRは不要。standalone Codexのsandbox既定、T3のmachine-wide上限、Claude sandboxのfail-closed、人用secret rootのread deny、providerの別UID / 別VM化を決める場合はADR候補とする。
