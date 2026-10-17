# セキュリティの方針

個人のアカウントから開発環境・クラウドまでを、侵害に強くするための見取り図。YubiKey の導入 (2026-10 に届く予定) を機に作った。決まったことは「決定」、決めていないことは「未決事項」に置き、未決事項は 1 項目ずつ合意してから「決定」へ移す。

## 1. 考え方

- **YubiKey は防波堤の 1 つ**。Mac がマルウェアや悪性ライブラリ (サプライチェーン攻撃) に侵害されても、YubiKey の中の鍵は取り出せず、タッチが要る操作は本人が触らない限り通らない。
- **無人で動くものは YubiKey で守れない**。エージェントが無人でできることは、同じユーザーで動くマルウェアにもできる。そこは YubiKey ではなく、権限を狭く・期限を短く・課金に上限を付けて、盗まれたときの被害を小さくする。
- **不便を払うなら抜け道を残さない**。タッチを要求しても、同じことができるタッチ不要の別経路が開いていれば意味がない。
- **Mac に置く秘密は「盗まれても被害が小さいもの」だけにする**。重要な鍵は YubiKey か Secure Enclave に置き、平文のファイルにしない。
- エージェントを止めない認証 (タッチ不要) も大事にする。どこでタッチを払うかを選ぶ。

## 2. 守るものと手段

| 守るもの | YubiKey が効くところ | YubiKey では守れない主な脅威と対策 |
|---|---|---|
| Apple ID・Google・メール (すべての起点) | フィッシングに強いログイン。数字コードや SMS の経路を閉じる | ログイン済みセッションの乗っ取り |
| GitHub | ログイン、鍵やトークンの追加 (sudo mode) | 盗まれたトークン → 権限を絞る |
| 決済・証券 | 対応しているサービスのログイン | 非対応のサービス。証券のパスキーはキーに入れない (§4) |
| クラウド (AWS / Cloudflare / LLM、課金が青天井) | コンソールのログイン | API キーの漏洩 → 権限・期限・利用上限 |
| dotfiles の秘密 (agenix)・tofu のトークン | 人が復号するとき (タッチ) | 無人で復号するもの |
| 開発中サービスの .env・API キー | 人が起動するときの復号 (タッチ) | 実行中プロセスの環境変数・メモリ |
| 開発中サービスのユーザー個人情報 | 本番やコンソールのログイン | アプリの脆弱性、DB の権限 |
| ライブラリ (サプライチェーン) | ほぼ効かない | Takumi Guard、lockfile、取り込みの待ち期間、実行権限 |

## 3. 決定

| 日付 | 決定 | 理由 |
|---|---|---|
| 2026-10-17 | commit 署名は今のまま (Secure Enclave の鍵、Touch ID なし、`nix/modules/darwin/secure-enclave-key.nix`)。YubiKey は署名に使わない | 鍵は持ち出せないので、他のマシンからのなりすましは防げる。署名のたびにタッチを求めるとエージェントの commit が止まる。ryoppippi も同じ選択 (理由はエージェントが止まらないこと) |
| 2026-10-17 | 1Password などサブスクのパスワードマネージャは入れない | 費用。パスワードは Apple の「パスワード」、機械が読む秘密は agenix |
| 2026-10-17 | Apple ID と Google に YubiKey を 2 本とも登録する。Apple ID はセキュリティキー、Google は高度な保護機能プログラムも有効にする。Nano は Mac に挿したまま、NFC 版は自宅で保管する。証券のパスキーはキーに入れない | 起点のアカウントで、数字コードや SMS などフィッシングできる経路を閉じる。iPhone で要るときは Nano (USB-C) か自宅の NFC 版を使う |
| 2026-10-17 | Logpush 用の Cloudflare API トークンは tofu 用のトークンと分け、別の .age に置く (別セッションで決定、todo 0094) | 漏れたときの被害範囲を分ける |
| 2026-10-17 | 開発プロジェクトの平文 .env は当面そのまま運用する。扱いは他の人の運用例を集めてから決める (todo 0099) | 急いで仕組みを入れるより、実例を見て慎重に決めたい |

## 4. 現状の抜け道 (2026-10-17 に実機で確認)

- **`~/.ssh/id_ed25519` (パスフレーズなし) が役割を兼ねすぎている**。これ 1 本が盗まれると全部失う。
  - GitHub の SSH 認証鍵 (「Github CLI」、2025-04-20)。ghq 配下 170 リポのうち 36 リポの remote が SSH。
  - agenix の受信者 `gigun` (編集用)。`secrets/secrets.nix` の `all` に入っている秘密をすべて開ける。
  - `nix run .#tofu` の実行時復号 (`secrets/tofu-env.age`)。
  - `claude/hooks/bark-notify.sh` の自動復号 (todo 0098)。
  - ほかのホストへの SSH ログインの既定鍵 (どこが受け入れているかは未確認)。
- **gh のトークンに `admin:public_key` と `admin:ssh_signing_key`** がある。トークンを読めるプロセスは、自分の鍵を GitHub に登録して裏口を作れる。署名鍵の `autoAdd` のために足したもの。
- **gh の github.com 用 `git_protocol` が `ssh`**。全体の設定は `https`。
- **main の保護は署名を求めず、管理者には適用されない** (`required_signatures=false`、`enforce_admins=false`)。
- **GitHub のログインに TOTP が残る**。passkey の前に必須な GitHub の仕様。
- **開発プロジェクトの .env は平文** (gitignore のみ)。Claude Code の設定に .env の deny・sandbox・環境変数の scrub は無く、Codex にも env policy が無い。

## 5. 未決事項

効果の大きい順。1 項目ずつ決める。

2. **GitHub のログインと鍵の管理**。YubiKey を passkey / セキュリティキーとして 2 本登録。TOTP のシードを YubiKey の OATH に移し、リカバリコードはオフラインに置く。gh のトークンから admin 系の権限を外し、鍵の登録は Web の sudo mode で行う。
3. **push の権限を誰に持たせるか**。候補: push は SSH と Secure Enclave の鍵 (ryoppippi の `type = "both"`、持ち出せない) で行い、gh のトークンは fine-grained にして Contents の書き込みを外す (盗まれても push できない)。未確認: Contents 書き込み無しで gh の普段の操作が回るか、期限管理の手間。あわせて「Github CLI」の鍵の削除、`git_protocol`、36 リポの remote を決める。
4. **`~/.ssh/id_ed25519` を役割ごとに分ける**。人が使う秘密 (agenix の編集、tofu) は age-plugin-yubikey (PIV、復号のたびにタッチ) に移す。保管用の age 鍵は NFC 版の YubiKey に移す候補。無人で復号するもの (bark など) は、その秘密だけを開ける専用の鍵にする。agenix-rekey は YubiKey を前提にした拡張で候補。
5. **開発プロジェクトの API キー** (長期、todo 0099。当面は平文のまま)。候補 (中間案): .env を SOPS (v3.10 以降で age プラグイン対応) + age-plugin-yubikey で暗号化して平文を消し、秘密を使う開発サーバーはエージェントの外の端末で `sops exec-env` から起動する。dotenvx は鍵の置き場が `.env.keys` か有料の Armor で、YubiKey に非対応。`dotenvx run --redact` は出力の文字列を伏せるだけでエージェントからの隔離にはならない ([docs](https://dotenvx.com/docs/cli/run-redact/))。
6. **エージェントから秘密を切り離す設定**。Claude Code: `Read(**/.env*)` の deny、sandbox の `filesystem.denyRead` (`~/.ssh`、`.env`)、`allowUnsandboxedCommands: false`、`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`。deny は `grep -r` や Python が自分で開く場合には効かない ([permissions](https://code.claude.com/docs/en/permissions)、[sandboxing](https://code.claude.com/docs/en/sandboxing))。Codex: 既定で環境変数をすべて子プロセスに渡すので、env policy と `*.env` の deny を足す。
7. **課金の上限とキーの寿命**。Anthropic: 独自の月額上限、キーの期限 (作成時に選ぶ)、workspace 限定。OpenAI: project のハードリミット、Restricted キー。AWS: ハードキャップは無い。Budget actions で Deny ポリシーを自動適用、長期キーをやめて一時認証情報へ。Cloudflare: 予算アラートは通知のみ。トークンを権限・リソース・IP・TTL で絞る。
8. **Cloudflare のログインと Access** (別セッションの todo 0097 / 0094 と連携)。Cloudflare アカウントのログインに YubiKey を 2 本登録し、TOTP を外す。Access の IdP は Cloudflare アカウントなので、新規ログインの強さはここで決まる。Access 側でハードウェアキーを要求できるか (independent MFA / AMR) は未確認。Logpush 用のトークンを分けることは決定済み (§3)。
9. **IaC (OpenTofu) の秘密と state**。state には平文の秘密が入りうる。OpenTofu の client-side state encryption (1.7 以降) を候補に (未検証)。
10. **GitHub Actions とリポの硬化** (ryoppippi の ccusage を参考に)。workflow 先頭の `permissions: {}` / `read-all`、checkout の `persist-credentials: false`、actionlint・zizmor・gitleaks (pre-commit と CI)、依存の取り込みに待ち期間 (renovate の `minimumReleaseAge: 3 days`、pnpm の `minimumReleaseAge` と `allowBuilds`)、npm 公開は OIDC の trusted publishing と `--provenance`、bot の commit は GitHub App で作る。
11. **エージェント規則**。秘密をコマンドの文字列に書かず、実行時に `$(gh auth token)` などで読む。漏れたら rotate する (ryoppippi の `agents/shared/command-privacy.md`)。
12. **紛失・侵害時の手順書**。YubiKey の紛失、Mac の紛失、侵害の疑いそれぞれで、GitHub のトークンと鍵の失効、Apple ID・Google の鍵の削除、Cloudflare Access のセッション取り消し (Zero Trust > Users > Revoke)、クラウドのキーの rotate をどの順で行うか。
13. **sudo は Touch ID のまま** の確認。挿しっぱなしの Nano をタッチするだけの pam-u2f は、生体認証の Touch ID より弱い。

## 6. YubiKey が届いたら最初に確認すること

- `ykman info` で型番とファームウェア。OpenAI のバンドルは C NFC と C Nano の 2 本組と報じられている (未確認)。FIDO 専用の「Security Key」系なら PIV が無く、age-plugin-yubikey は使えない (その場合は age-plugin-se = Touch ID で代替)。ファームウェア 5.7 未満なら ECDSA の advisory (YSA-2024-03、物理アクセスが前提) を読む。
- 挿しっぱなしにする Nano は、誤タッチで文字列を打ち込まないよう OTP を無効にする (`ykman config usb --disable OTP`)。

## 7. 参考

- YubiKey 5 の機能ごとのタッチ / PIN: [ykman FIDO](https://docs.yubico.com/software/yubikey/tools/ykman/FIDO_Commands.html)、[PIV の touch policy](https://docs.yubico.com/yesdk/users-manual/application-piv/pin-touch-policies.html) (PIV は鍵の生成後に変更できない)
- GitHub の SSH 鍵とセキュリティキー: [GitHub Docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)、[blog 2021](https://github.blog/engineering/platform-security/security-keys-supported-ssh-git-operations/)。HTTPS と SSH のどちらかを公式には推奨していない ([About remote repositories](https://docs.github.com/en/get-started/git-basics/about-remote-repositories))
- [ryoppippi/nix-secure-enclave-key](https://github.com/ryoppippi/nix-secure-enclave-key)、[ryoppippi/renovate-config](https://github.com/ryoppippi/renovate-config)
- [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey)、[age-plugin-se](https://github.com/remko/age-plugin-se)、[SOPS の age](https://getsops.io/docs/usage/identities/age/)、[agenix-rekey](https://github.com/oddlama/agenix-rekey)
- 平文の認証情報を盗んだ実例: [s1ngularity (Nx)](https://github.com/nrwl/nx/security/advisories/GHSA-cxm3-wv7p-598c)、[Shai-Hulud (CISA)](https://www.cisa.gov/news-events/alerts/2025/09/23/widespread-supply-chain-compromise-impacting-npm-ecosystem)
- 課金の上限: [Anthropic](https://platform.claude.com/docs/en/api/rate-limits)、[OpenAI](https://help.openai.com/en/articles/6614457)、[AWS Budget actions](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html)、[Cloudflare](https://developers.cloudflare.com/billing/manage/budget-alerts/)
