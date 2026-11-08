# セキュリティの方針

個人のアカウントから開発環境・クラウドまでを、侵害に強くするための見取り図。YubiKey の導入 (2026-10 に届く予定) を機に作った。決まったことは「決定」、決めていないことは「未決事項」に置き、未決事項は 1 項目ずつ合意してから「決定」へ移す。

## 1. 考え方

- **YubiKey は防波堤の 1 つ**。Mac がマルウェアや悪性ライブラリ (サプライチェーン攻撃) に侵害されても、YubiKey の中の鍵は取り出せず、タッチが要る操作は本人が触らない限り通らない。
- **無人で動くものは YubiKey で守れない**。エージェントが無人でできることは、同じユーザーで動くマルウェアにもできる。そこは YubiKey ではなく、権限を狭く・期限を短く・課金に上限を付けて、盗まれたときの被害を小さくする。
- **不便を払うなら抜け道を残さない**。タッチを要求しても、同じことができるタッチ不要の別経路が開いていれば意味がない。
- **Mac に置く秘密は「盗まれても被害が小さいもの」だけにする**。重要な鍵は YubiKey か Secure Enclave に置き、平文のファイルにしない。
- エージェントを止めない認証 (タッチ不要) も大事にする。どこでタッチを払うかを選ぶ。

### 秘密ごとの決め方

「dotfiles に入れるか」と「Mac の上でどう守るか」は別の問い。dotfiles で暗号化して管理しても、Mac で平文のファイルになるなら Mac 上の安全性は変わらない (変わるのは新しいマシンでの再現性だけ)。

1. **dotfiles に入れるか**: 新しいマシンで自動で用意したいなら入れる。dotfiles は public なので暗号化が必須。マシンごとに 1 回手で設定すれば済むなら、入れずにローカルに置く。
2. **Mac の上でどう守るか**: 誰がいつ使うかで決める。

| 使われ方 | 復号に使う鍵 | 平文が存在する時間 |
|---|---|---|
| 人がたまに使う (tofu など) | YubiKey (毎回タッチ) | 実行中だけ |
| アプリや自動処理がファイルから常に読む (npmrc、MCP のトークンなど) | タッチ不要の鍵 (Secure Enclave など) | 常に。だからトークンの権限を狭く・期限を短くする |
| 無人のホスト (mini-vm) | そのホストの鍵 | 起動中 |

資格情報の現在の分類は[資格情報クラス台帳](credential-inventory.md)、正確な対象・保管・権限・期限・複製先・失効順はrepo外の非公開正本で管理する。認証要求の見分け方と紛失・侵害時の一般順序は[復旧runbook](security-recovery.md)に置く。過去の実機観測は現在値として扱わない。

例: cachix のトークンは `~/.config/cachix/cachix.dhall` (600) に平文で、dotfiles に入れていない。この平文保存方式ではトークンを読み取って送信できる。通常 switch/update の自動送信は廃止したが、明示送信時の保管・認証方式は別途判断する。盗まれると gigun キャッシュに偽のビルド結果を上げられ、それを取り込む mini-vm などに入る。トークンを gigun への書き込みだけに絞っても、この「偽物を混ぜる」は防げない (防げるのはキャッシュの削除・設定変更・他キャッシュへの影響だけ)。根本の対策は「誰に push を許すか」で、未決事項 14。

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
| 2026-11-03 | 既存アカウントを使うため、Pro に 1Password アプリと CLI を導入する | 保管先の移行や CLI 連携、SSH agent の利用は別途判断する |
| 2026-10-17 | Apple ID と Google に YubiKey を 2 本とも登録する。Apple ID はセキュリティキー、Google は高度な保護機能プログラムも有効にする。Nano は Mac に挿したまま、NFC 版は自宅で保管する。証券のパスキーはキーに入れない | 起点のアカウントで、数字コードや SMS などフィッシングできる経路を閉じる。iPhone で要るときは Nano (USB-C) か自宅の NFC 版を使う |
| 2026-10-22 | Google は普段 Apple の「パスワード」の passkey (Touch ID) でログインし、YubiKey 2 本は passkey として予備と新しい環境用に登録する。認証システム (TOTP) と 2 段階認証の SMS は消した。パスワード・再設定用の電話番号とメールは残す。バックアップコード・自撮り動画・復旧用の連絡先は足さない | ログインの強さは残っている一番弱い経路で決まる。TOTP と SMS は偽サイトでその場で中継でき、SMS は SIM スワップも受ける。Apple から独立した鍵があるので弱い経路を消しても締め出されない。復旧の経路は増やすほど入口が増える |
| 2026-10-22 | Mac から GitHub への push は Secure Enclave の SSH 鍵 (`pushInsteadOf`)、fetch は HTTPS のまま。Enclave の鍵は Web の画面で Authentication key としても登録する。mini-vm・WSL・Windows は HTTPS とトークンのまま | 持ち出せない鍵に push を寄せ、盗んだトークンや鍵ファイルで push させない (サプライチェーン攻撃の典型)。Enclave は Mac ごとに作られ同期されないので、Linux には置けない。いちばん使っていて外部のコードが多く入る Mac から固める |
| 2026-10-22 | TOTP は YubiKey の OATH に移さず、Apple の「パスワード」に置いたままにする (2026-10-17 の GitHub の行の「OATH に移す」を改める)。GitHub は普段 Apple の passkey、YubiKey 2 本は passkey として予備 | Apple の「パスワード」は確認コードを正しいドメインでしか自動入力しないので、偽サイトに気づく合図になる。OATH は手で打つので合図が無い。パスワードと TOTP が同じ保管庫に入る弱さは、Apple アカウントを YubiKey で守ったことで小さくなった |
| 2026-10-22 | Cloudflare の 2 段階認証は Apple の「パスワード」の passkey (Touch ID) を普段使いにし、TOTP は消す。YubiKey は予備 | Cloudflare は passkey でのログインが無く毎回 2 段階認証が要り、Access (IdP が Cloudflare アカウント) の入口でもある。YubiKey はタッチ・PIN・タッチで日常には重い。Apple の passkey ならドメインに結びついたまま Touch ID 1 回で済む |
| 2026-10-22 | 高度な保護機能プログラムでは、このアカウントの Gmail・Drive を自作の OAuth クライアントから読めなくなる (テストモードでも `policy_enforced`)。Gmail と連携するアプリの開発には、プログラムに入れていない別アカウントをテストユーザーに使う | gws は 3 月から使っておらず困らない。要るようになったらプログラムはいつでも抜けられる |
| 2026-10-22 | FIDO2 の PIN はキー 1 本につき 1 つで全サービス共通。Nano と NFC は同じ値にし、Mac のログインパスワードとは別にして Apple の「パスワード」に保存する。要るのはキーの中に passkey を作るときだけ | Nano は Mac に挿したままなので、Mac と一緒に盗まれる。のぞき見た 1 つの秘密で両方が開かないようにする |
| 2026-10-17 | GitHub に YubiKey を passkey / セキュリティキーとして 2 本とも登録し、TOTP のシードを YubiKey の OATH に移す。リカバリコードは Apple の「パスワード」に置く | TOTP は GitHub の仕様で外せないので、6 桁を出すのにもタッチを要求する。Apple ID を YubiKey で固めるので、保管庫は十分に強い |
| 2026-10-17 | gh のトークンから `admin:public_key` と `admin:ssh_signing_key` を外し、署名鍵の `autoAdd` を止める。鍵の登録は新しい Mac のときに Web で手で行う | 鍵を足せるトークンが盗まれると、攻撃者の鍵を登録されて失効後も残る裏口になる |
| 2026-10-17 | Access の Logpush はダッシュボードの自動セットアップで作る。R2 の鍵は Cloudflare が自分で作り、tofu にも `.age` にも入れない (別セッションで決定、todo 0094) | 手元に持つ秘密を増やさない |
| 2026-10-17 | 開発プロジェクトの平文 .env は当面そのまま運用する。扱いは他の人の運用例を集めてから決める (todo 0099) | 急いで仕組みを入れるより、実例を見て慎重に決めたい |

## 4. 現状の抜け道 (2026-10-17 に実機で確認)

- **`~/.ssh/id_ed25519` (パスフレーズなし) が役割を兼ねすぎている**。これ 1 本が盗まれると全部失う。
  - GitHub の SSH 認証鍵 (「Github CLI」、2025-04-20)。ghq 配下 170 リポのうち 36 リポの remote が SSH。
  - agenix の受信者 `gigun` (編集用)。`secrets/secrets.nix` の `all` に入っている秘密をすべて開ける。
  - `nix run .#tofu` の実行時復号 (`secrets/tofu-env.age`)。
- **`tofu-env.age` の受信者が `all`** で、mini-vm のホスト鍵でも開ける。mini-vm の nix 設定に tofu の利用は無く、Cloudflare を書き換えられるトークンを無人のホストに持たせている。
  - `claude/hooks/bark-notify.sh` の自動復号 (todo 0098)。
  - ほかのホストへの SSH ログインの既定鍵 (どこが受け入れているかは未確認)。
- **gh の github.com 用 `git_protocol` が `ssh`**。全体の設定は `https`。
- **main の保護は署名を求めず、管理者には適用されない** (`required_signatures=false`、`enforce_admins=false`)。
- **GitHub のログインに TOTP が残る**。passkey の前に必須な GitHub の仕様。
- **開発プロジェクトの .env は平文** (gitignore のみ)。Claude Code の設定に .env の deny・sandbox・環境変数の scrub は無く、Codex にも env policy が無い。

## 5. 未決事項

効果の大きい順。1 項目ずつ決める。

3. **push の権限を誰に持たせるか**。 **2026-10-22**: Mac の push を Enclave の SSH 鍵に寄せた (§3)。残りは gh のトークンから push の権限を外すこと、`id_ed25519` を GitHub から外すこと、mini-vm のトークンを必要なリポと権限だけの fine-grained にすること (無人機なので期限の更新を自動化できるかが論点)。候補: push は SSH と Secure Enclave の鍵 (ryoppippi の `type = "both"`、持ち出せない) で行い、gh のトークンは fine-grained にして Contents の書き込みを外す (盗まれても push できない)。未確認: Contents 書き込み無しで gh の普段の操作が回るか、期限管理の手間。あわせて「Github CLI」の鍵の削除、`git_protocol`、36 リポの remote を決める。
4. **`~/.ssh/id_ed25519` を役割ごとに分ける**。 **試行 (2026-10-22)**: Nano の PIV に age の鍵を作った (PIN は once、タッチは always。ファームウェア 5.7 は管理鍵の初期値が AES で age-plugin-yubikey が未対応 (#92) のため、`ykman piv access change-management-key -a TDES --protect` で PIN 保護の TDES に置き換えてから生成)。ダミーの .env を sops で暗号化し、`sops exec-env` で復号できた。初回は PIN とタッチ、2 回目以降はタッチだけ。dummy復号試験は本番移行や予備鍵復旧の証拠にしない。 **方向 (2026-10-17、未決定)**: agenix から sops-nix へ全面移行する案だった。 **監査途中案 (2026-11-09、未採用)**: 無人runtimeだけagenixを残すhybridも検討した。 **再評価 (2026-11-09、現行推奨・採否未決定)**: agenix導入時の「秘密4個・host 1台・user 1人」という前提に対し、現在は暗号文15個と複数host / human consumerがあり、sops-nixでもNixOS activation時の無人復号、owner / mode、generation切替とrollbackを扱えるため、恒久hybridではなくSOPS / sops-nixへ全面移行する。人用秘密はprimary / backup YubiKeyだけ、mini-vmとminiの秘密は各host専用SOPS identity + 両YubiKeyとし、人用暗号文からhost identityを外す。通知は暗号文だけでなくprovider credentialも人用 / 無人用へ分ける。影響の小さいhost heartbeatをpilotにし、owner / mode、regular-file配送、service継続、reboot、予備鍵復旧、agenix pathへのrollbackを受入してから展開する。全agenix参照をなくし、重要credentialをrotateして旧credential拒否を確認した後にagenixを撤去する。SOPSでもbinaryは構造差分が見えず、structured fileはkey名とrecipient metadataが見えるため、公開境界はtodo 0177で別に決める。Macのswitch時にYubiKey待ちを持ち込まず、人用秘密は利用時だけ復号する。
5. **開発プロジェクトの API キー** (長期、todo 0099。当面は平文のまま)。候補 (中間案): .env を SOPS (v3.10 以降で age プラグイン対応) + age-plugin-yubikey で暗号化して平文を消し、秘密を使う開発サーバーはエージェントの外の端末で `sops exec-env` から起動する。dotenvx は鍵の置き場が `.env.keys` か有料の Armor で、YubiKey に非対応。`dotenvx run --redact` は出力の文字列を伏せるだけでエージェントからの隔離にはならない ([docs](https://dotenvx.com/docs/cli/run-redact/))。
6. **エージェントから秘密を切り離す設定**。Claude Code: `Read(**/.env*)` の deny、sandbox の `filesystem.denyRead` (`~/.ssh`、`.env`)、`allowUnsandboxedCommands: false`、`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`。deny は `grep -r` や Python が自分で開く場合には効かない ([permissions](https://code.claude.com/docs/en/permissions)、[sandboxing](https://code.claude.com/docs/en/sandboxing))。Codex: 既定で環境変数をすべて子プロセスに渡すので、env policy と `*.env` の deny を足す。
7. **課金の上限とキーの寿命**。Anthropic: 独自の月額上限、キーの期限 (作成時に選ぶ)、workspace 限定。OpenAI: project のハードリミット、Restricted キー。AWS: ハードキャップは無い。Budget actions で Deny ポリシーを自動適用、長期キーをやめて一時認証情報へ。Cloudflare: 予算アラートは通知のみ。トークンを権限・リソース・IP・TTL で絞る。
8. **Cloudflare のログインと Access** (別セッションの todo 0097 / 0094 と連携)。Cloudflare アカウントのログインに YubiKey を 2 本登録し、TOTP を外す。Access の IdP は Cloudflare アカウントなので、新規ログインの強さはここで決まる。Access 側でハードウェアキーを要求できるか (independent MFA / AMR) は未確認。 2 段階認証は §3 で決定済み (Apple の passkey)。Access の IdP を Google (passkey) に変える案は、急がない改善として残す。Logpush の扱いは決定済み (§3)。
9. **IaC (OpenTofu) の秘密と state**。state は 2026-09-06 から暗号化済み (pbkdf2 + aes_gcm、平文の書き込みを拒否する enforced、`tofu/versions.tf`)。`tofu-env.age` には Cloudflare のトークン、R2 (state バケット) の AWS キー、state のパスフレーズ、Tailscale の OAuth が入っている。論点はこの `.age` を開ける鍵の扱いで、4 と同じ話として決める。受信者が `all` である件は §4。Cloudflare 以外に広げるときもこの形を踏襲するか。 スマホから変更したい場合の候補: tofu を GitHub Actions で実行し、apply の前に environment の承認を挟む (承認は GitHub へのログイン = YubiKey で守られる)。トークンは GitHub の secret に置くことになる。
10. **GitHub Actions とリポの硬化** (ryoppippi の ccusage を参考に)。2026-11-09時点で、外部Actionは40桁SHA固定、repository側のSHA固定強制は有効、既定workflow tokenはread、PR review承認は禁止、read-only jobのcheckoutはcredentialを保持しない。branch protectionの最終gate移行はlive確認中。残りはactionlint・zizmorの導入判断、書込jobの権限分割、依存の取り込みに待ち期間 (renovate の `minimumReleaseAge: 3 days`、pnpm の `minimumReleaseAge` と `allowBuilds`)、npm 公開時のOIDC trusted publishingと`--provenance`、bot commitのGitHub App化。ryoppippiの現行Nix buildはread-only checkoutでもcredentialを保持する既定値だが、このrepoはprivate self-hosted fallbackを持つため狭くした。
11. **エージェント規則**。秘密をコマンドの文字列に書かず、実行時に `$(gh auth token)` などで読む。漏れたら rotate する (ryoppippi の `agents/shared/command-privacy.md`)。
12. **紛失・侵害時の手順書**。YubiKey の紛失、Mac の紛失、侵害の疑いそれぞれで、GitHub のトークンと鍵の失効、Apple ID・Google の鍵の削除、Cloudflare Access のセッション取り消し (Zero Trust > Users > Revoke)、クラウドのキーの rotate をどの順で行うか。
13. **sudo は Touch ID のまま** の確認。挿しっぱなしの Nano をタッチするだけの pam-u2f は、生体認証の Touch ID より弱い。
14. **cachix に push できるのは誰か**。通常 switch/update からの自動送信は廃止した。 **監査更新 (2026-11-09)**: repo、CI、switch/update、常駐serviceにCachix送信経路はなく、GitHub ActionsにもCachix writer secretは無い。Proにはmode 0600の標準設定ファイルが存在するが、内容・tokenの有無・有効性は読んでいない。mini-vm等のrepo外設定とprovider側writer・最終利用も未確認である。ryoppippiの現行もread-only Cachix + GitHub Actions cacheで、Cachix writer/actionは撤去済み。現行推奨は当面送信せず、provider側writerを確認・失効してから各hostのlocal writer設定を削除し、substituter / trusted keyだけを残すこと。正式採用までは削除済みと扱わない。書込を廃止しても既存cacheのreadは継続でき、失うのは新しいlocal buildを他hostへCachix経由で再配布する機能である。将来必要になった場合だけ、送信主体・対象・承認点を限定したCI writerを別設計する。

## 6. YubiKey が届いたらやること

### 最初に確認すること

- `ykman info` で型番とファームウェア。OpenAI のバンドルは C NFC と C Nano の 2 本組と報じられている (未確認)。FIDO 専用の「Security Key」系なら PIV が無く、age-plugin-yubikey は使えない (その場合は age-plugin-se = Touch ID で代替)。ファームウェア 5.7 未満なら ECDSA の advisory (YSA-2024-03、物理アクセスが前提) を読む。
- 挿しっぱなしにする Nano は、誤タッチで文字列を打ち込まないよう OTP を無効にする (`ykman config usb --disable OTP`)。

### 登録と移行 (§3 の決定を実行する)

順に行う。各サービスで 2 本とも登録する (NFC 版は登録後に自宅で保管)。

- [x] Apple ID: セキュリティキーを登録する (数字コードの経路が閉じる) — 2026-10-22
- [x] Google: キーを登録し、高度な保護機能プログラムを有効にする — 2026-10-22
- [x] OpenAI (ChatGPT・API の課金): セキュリティキーを登録し、リカバリーコードを Apple の「パスワード」に置く — 2026-10-22
- [x] GitHub: YubiKey 2 本を passkey として登録 (普段は Apple の passkey)。TOTP は Apple の「パスワード」のまま (§3)。backup email は primary (iCloud) だけ、メールを晒す push を止める設定を有効 — 2026-10-22
- [x] GitHub: リカバリコードを作り直して Apple の「パスワード」に置く。GitHub Mobile の 2 台が自分の端末か確かめる — 2026-10-22
- [x] Cloudflare: Apple の「パスワード」の passkey をセキュリティキーとして登録し、TOTP を消し、バックアップコードを作り直して Apple の「パスワード」に置く 。YubiKey 2 本も予備として登録 — 2026-10-22
- [ ] 決済・クラウド (AWS など) のうち、セキュリティキーに対応しているものに登録する (証券のパスキーはキーに入れない)
- [ ] PIV があれば、sops + age-plugin-yubikey を 1 ファイルで試してから、未決事項 4 を決める

## 7. 参考

- YubiKey 5 の機能ごとのタッチ / PIN: [ykman FIDO](https://docs.yubico.com/software/yubikey/tools/ykman/FIDO_Commands.html)、[PIV の touch policy](https://docs.yubico.com/yesdk/users-manual/application-piv/pin-touch-policies.html) (PIV は鍵の生成後に変更できない)
- GitHub の SSH 鍵とセキュリティキー: [GitHub Docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent)、[blog 2021](https://github.blog/engineering/platform-security/security-keys-supported-ssh-git-operations/)。HTTPS と SSH のどちらかを公式には推奨していない ([About remote repositories](https://docs.github.com/en/get-started/git-basics/about-remote-repositories))
- [ryoppippi/nix-secure-enclave-key](https://github.com/ryoppippi/nix-secure-enclave-key)、[ryoppippi/renovate-config](https://github.com/ryoppippi/renovate-config)
- [age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey)、[age-plugin-se](https://github.com/remko/age-plugin-se)、[SOPS の age](https://getsops.io/docs/usage/identities/age/)、[agenix-rekey](https://github.com/oddlama/agenix-rekey)
- 平文の認証情報を盗んだ実例: [s1ngularity (Nx)](https://github.com/nrwl/nx/security/advisories/GHSA-cxm3-wv7p-598c)、[Shai-Hulud (CISA)](https://www.cisa.gov/news-events/alerts/2025/09/23/widespread-supply-chain-compromise-impacting-npm-ecosystem)
- 課金の上限: [Anthropic](https://platform.claude.com/docs/en/api/rate-limits)、[OpenAI](https://help.openai.com/en/articles/6614457)、[AWS Budget actions](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html)、[Cloudflare](https://developers.cloudflare.com/billing/manage/budget-alerts/)

## 実行環境とアクセス境界の確認

[診断手順](execution-context.md)でsandbox内の失敗と認証・署名の問題を区別する。[ホスト別のアクセス境界](security-access-boundaries.md)は、宣言と実機未確認を分けて記載する。秘密の棚卸しは既存の非公開記録に置き、ここには値を持ち込まない。
