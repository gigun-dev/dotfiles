# sandbox 内の失敗を認証失効と取り違えない

この手順は診断だけを扱う。資格情報の更新、scope追加、鍵再生成、quarantine解除、権限・VPN変更は診断の代わりに実行しない。実機のprocess table・live ACLは採取しない。

Codex、Claude Code、T3 Codeのpermission mode、provider approval、OS sandbox、tool hookの違いは[エージェントharnessの権限境界](agent-harness-boundaries.md)を参照する。`Auto`や`sandbox`という表示だけで実効境界を判断しない。

## 失敗の分類

| 分類 | 例 | credentialの判定 |
|---|---|---|
| harness / tool preflight deny | hook、permission rule、managed mode上限 | 未判定 |
| OS sandbox deny | Seatbeltのpolicy deny、sandboxに由来する`EPERM` | 未判定 |
| transport failure | DNS、timeout、connect失敗、HTTP応答なし | 未判定 |
| external policy deny | tailnet ACL、Access policy、organization policy | policy拒否として別扱い |
| HTTP authentication rejection | 対象serverから実測したHTTP 401 | credential不正の候補。対象と選択credentialを確認する |
| HTTP authorization rejection | HTTP 403 | scope、resource、organization policy等。即失効扱いしない |
| TCC / Keychain / GUI deny | Security framework、Automation、Accessibility | OS privacy境界として別扱い |
| harness / provider mismatch | 表示modeとresolved provider policyが異なる | adapterまたは設定伝播の問題候補 |

一つの失敗を複数分類へ重複計上しない。まず最も手前で拒否した層を記録し、その層を通過した証拠が得られた場合だけ次の層を評価する。

## 小さい診断手順

1. 失敗した処理の実行元（Pro / mini / mini-vm）、対象、probe、sandbox有無、時刻を記録する。CLI・対象artifactの版やhash、正確な引数とreview承認の参照は秘密を除いたprivate作業記録に残す。同じ操作の比較に使い、repoへ端末識別子や生出力をcommitしない。
2. DNS/transportの段階と、サーバーが返したHTTP statusを分ける。`scutil`のNo DNS、`dig`のpermission、SSH接続失敗、`gh auth status`のtoken invalidだけでは資格情報の失効を確定しない。HTTP 403もscope不足を単独では確定しない。
3. GitHub認証は `python3 scripts/github-auth-diagnose.py` から確認する。macOSでは最初にApple Seatbeltの`network-outbound`判定を確認し、denyならオンラインprobeを実行せず`context-limited-network-denial`で止める。ローカルのcredential選択は、`gh auth token`の出力をプロセス内で破棄して存在だけを確認する。Keychainがdenyされる場合は`gh auth status --no-refresh`からactive accountの有無だけを取り、同時に出るtoken invalid判定は捨てる。HTTP 401を実測した場合だけ`credential-rejected`とする。403、DNS失敗、timeout、HTTP応答の無い失敗をtoken失効へ読み替えない。
4. sandbox限定の失敗なら、同じ対象・引数・artifactを使うread-only検証を正規のreview経路で実行する。GitHubは同じ診断をreview済みcontextで再実行し、`credential-accepted`またはHTTP statusだけを記録する。tokenやresponse body、headers全体を保存しない。必要な承認が無ければpendingで止める。
5. 一方が成功しても失敗記録を消さない。「そのcontextで成功」「別contextでは失敗」と併記する。両方失敗した場合も、権限・サービス停止・鍵破損を自動で結論にしない。HTTP 401を確認した後も、対象account・実行環境・credential選択を確認してから更新を別途判断する。
6. **TAILNET POLICY DENIEDは停止**。mini→VMの既知の拒否をsandbox偽陰性に分類しない。別ホスト、Lima、別ユーザー、別VPN経路へ切り替えて同じ拒否操作を通さない。ポリシー変更には対象経路を明記した別承認が必要。
7. Gatekeeper/codesignの失敗は同じartifactに対するread-only検証（`spctl --assess --type execute` / `codesign --verify --strict`）をreviewして比較する。出力をそのまま持ち出さない。成功はその検査の範囲だけを示し、配布物全体の安全性やGitHub Verifiedを保証しない。quarantine無効化は対策にしない。

以前拒否された観測はこの手順を理由に再試行しない。新しい関連証拠が拒否理由を解消し、実行されていないことが確かな場合だけ正規reviewで扱う。結果不明なら再実行より先に状態を確認する。

## metadataだけを記録する

`github-auth-diagnose.py` はGitHubだけのprobe、`execution-context.py` は観測済み結果を入力する記録器である。どちらも権限追加、credential更新、自動再試行を行わない。`--context reviewed-read-only`は呼出側の申告であり、承認を与える機能ではない。生出力、command文字列、環境変数、任意のhost名を受け付けない。stdoutのJSONは必要な場合だけprivateな作業記録に保存する。

```sh
# sandbox内: Seatbelt denyならonlineProbeを実行せずexit 3
python3 scripts/github-auth-diagnose.py

# ネットワークに触れず、ローカルcredential選択だけ確認する
python3 scripts/github-auth-diagnose.py --local-only
```

exit 0はGitHub API成功、1はHTTP 401、2は401以外のHTTP失敗、3はsandbox・transport・ローカル前提を含む未確定を表す。exit 3を認証失効として扱わない。

```sh
python3 scripts/execution-context.py --host pro --target github \
  --context sandbox --probe github-api --result transport-failed
python3 scripts/execution-context.py --host pro --target github \
  --context reviewed-read-only --probe github-api --result http-response --http-status 200
python3 scripts/execution-context.py --host mini --target mini-vm \
  --context sandbox --probe ssh --result tailnet-policy-denied
```

例は入力形式を示す合成例であり、実測の成功証拠ではない。既存 `ssh-path-observe.py` はVM生存の観測用で、拒否診断の入口として実行しない。fallbackのある観測を拒否経路の迂回に使わない。

合成回帰は既存の `developer-tools` checkに含める。DNS / token-invalid / permission / signature失敗、HTTP 401/403、別contextでの成功、全contextのpolicy拒否、生出力の入力拒否を検査する。実credential・SSH・署名は使わない。
