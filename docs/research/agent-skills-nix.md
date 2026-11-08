# agent-skills-nix を導入するかの判断材料

調査日: 2026-11-08。読み取りのみ。

参照した版:

- Kyure-A/agent-skills-nix: `f48aa227f3d157ae3abda12cd9c4ab867f400419`（2026-10-21、ryoppippi の flake.lock が固定している rev と同じ）
- ryoppippi/dotfiles: `de137c2a78c0d551d11e2f3a0aebba9143046805`（2026-11-08）
- gigun-dev/claude-code: `9c50cfd`（2026-11-08）
- gigun-dev/dotfiles: 作業ツリー（HEAD `12c5b09`）

表記: **[確認]** はファイル・コマンド出力・公式 docs で裏取りしたもの。**[推測]** は裏取りしていないもの。

---

## 1. 要点

- agent-skills-nix は **SKILL.md ディレクトリだけ** を Nix で pin し、選んで、各エージェントの skill ディレクトリへ配る。MCP・hooks・agents・commands は扱わない。plugin として書き出す機能（実験的）は MCP と hooks を拒否する。
- ryoppippi は **自前の skill と外部 skill をすべて** これで配っている。MCP は Codex の `t3` 1 本だけを `config.toml` に書いている。Claude Code には MCP を宣言していない。
- gigun の plugin 運用と比べたときの利点は 2 つ。skill と一緒に nix の実行ファイルを置けること（web-fetch の `./ax` が動く）、そして pin の更新を lock で一元管理できること。失うものは 4 つ。enabledPlugins による on/off、`todo:adr` のような名前空間、MCP・hooks との同梱、Nix を凍結している mini macOS への配布。
- **推奨: 外部 skill（ryoppippi などの原本固定分）だけを agent-skills-nix に移し、自前 skill・MCP・hooks は plugin marketplace に残す。** 理由は §6。

---

## 2. agent-skills-nix の仕組み

### 2.1 sources / registry / lock

- source は flake input 名（`input`）か path（`path`）で skill のルートを指す。オプションは `subdir`、`idPrefix`、`filter.maxDepth`、`filter.nameRegex` の 4 つ。**[確認]** `docs/configuration.md`「Sources and discovery」
- 探索は `SKILL.md` を持つディレクトリを再帰的に探す。入れ子の skill の ID は `/` 区切りになる（例 `documents/pdf`）。`maxDepth` の既定は `null`（内部上限 100 まで再帰）。旧既定の挙動にしたい場合は `filter.maxDepth = 1` を指定する。**[確認]** 同上
- **source registry**（任意）を使うと、skill リポジトリを flake input にせずに pin できる。人が編集するのは `registry/sources/<name>.nix`（`pin = { type = "github"; owner; repo; branch; }` と `subdir`/`idPrefix`/`filter`）で、生成物は `registry/sources.lock.json`。lock は agent-skills の schema-v1 で manifest を包み、中身は npins の version-8 lock。**[確認]** `docs/source-registry.md`
  - `branch` を省くと release を追う（`GitRelease` pin）。
  - manifest と lock の正規化結果が一致しないと評価が失敗する。lock を更新し忘れて repo や branch を変えた場合も、黙って古いまま動くことはない。**[確認]** 同「Validation and lock guarantees」
  - 更新は `mkSourceLockProgram` で作るアプリ（ryoppippi では `nix run .#skills-sources-lock`）で行う。失敗時は旧 lock をバイト単位で残し、同じ上流なら同じバイト列を出す。**[確認]** 同上

### 2.2 selection

- 選び方は 3 つあり、組み合わせられる。`skills.enable = [ "id" ]`（カタログから名前で選ぶ）、`skills.enableAll = true | [ "sourceName" ]`、`skills.explicit.<name> = { from; path; rename; agents; packages; rewriteCommands; transform; }`。既定ではどれも空で、**何も入らない**。存在しない ID は評価エラーになる。**[確認]** `docs/configuration.md`「Selecting skills」、`modules/common.nix`
- 同じ出力 ID を `enable` と `explicit` の両方で選ぶことは禁止されている。ID の衝突は rename 後に検査される。**[確認]** 同上

### 2.3 targets と user / project scope

- **user scope**: Home Manager モジュールで `targets.<name>.enable = true`。既定の配置先は次のとおり。**[確認]** `docs/installation.md`「Default target paths」

  | target | global | local |
  |---|---|---|
  | agents | `$HOME/.agents/skills` | `.agents/skills` |
  | codex | `${CODEX_HOME:-$HOME/.codex}/skills` | `.codex/skills` |
  | claude | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills` | `.claude/skills` |
  | antigravity | `$HOME/.gemini/antigravity/skills` | `.agents/skills` |
  | gemini / opencode / pi / cursor / copilot / windsurf | （省略） | |

  Codex は user scope の skill を `$HOME/.agents/skills` から読む（加えて `$CWD` からリポジトリルートまでの `.agents/skills`、`/etc/codex/skills`）。**[確認]** https://learn.chatgpt.com/docs/build-skills （developers.openai.com/codex/skills からの 308 リダイレクト先）
- **project scope**: Home Manager ではなく、利用側の flake に `mkLocalInstallProgram` で `nix run .#skills-install-local` を生やすか、`mkShellHook` で devShell に入ったときに入れる。local target は `copy-tree` で、cwd（または `AGENT_SKILLS_ROOT`）の外には書けない。**[確認]** `docs/installation.md`「Project-local installation」「Development shells」
- 配置方式 `structure` は 3 種類。**[確認]** 同「Target configuration」
  - `link`: HM の `home.file` による再帰 symlink
  - `symlink-tree`: `rsync -a --delete`
  - `copy-tree`: `rsync -aL --delete`
- **所有権**: 中身がある既存ディレクトリのうち、マーカーが無いものは置き換えを拒否する。同期に成功すると `.agent-skills-managed.json` を置く。乗っ取る場合は 1 回だけ `AGENT_SKILLS_FORCE=1` を付ける。**[確認]** 同「Destination ownership」
  - gigun の `~/.claude/skills` には現在 `ios-device-build` と `synced` がある **[確認]** `ls ~/.claude/skills`。tree 系 structure で乗っ取ると `--delete` で消えるので、移行前にこの 2 つの扱いを決める必要がある。

### 2.4 per-skill agents

- `skills.explicit.<name>.agents = [ "claude" "codex" ]` で配り先の target を絞れる。`null`（既定）は有効な全 target、`[]` はどこにも配らない。指定できるのは explicit の skill だけで、`enable`/`enableAll` で選んだものは全 target に配られる。**[確認]** `docs/configuration.md`「Restricting skills to agents」
- `agents` を持つ skill が 1 つでもあると、`AGENT_SKILLS_DESTS` 系の上書きは拒否される。**[確認]** 同上
- ryoppippi は、自前 SKILL.md の frontmatter にある `metadata.agents: [claude, agents]`（1 行の flow 形式に限る）を Nix で読み、この `agents` に流し込んでいる。他の書き方は評価エラーにする。**[確認]** ryoppippi `nix/modules/home/agent-skills.nix`（`skillAgents` 関数）

### 2.5 packages と rewriteCommands

- `packages = [ drv ... ]` を指定すると、skill ディレクトリに実行ファイルの symlink が置かれる。単一バイナリなら `./jq` → `/nix/store/...-jq/bin/jq`、複数バイナリなら `./curl/` → `bin/` という形になる。**[確認]** `docs/configuration.md`「Transforming content and bundling dependencies」
- `rewriteCommands` は packages があると既定で `true` になり、SKILL.md 中のコマンド名を `./name` に書き換える（`lib/bundle.nix` の `rewriteCommandPaths`、190 行目付近）。不要なら `false` にする。**[確認]**
- `transform = { original, dependencies }: ...` で SKILL.md を書き換えられる。`dependencies` は依存表の Markdown。packages があって transform が無い場合は、依存表が末尾に追記される。**[確認]** 同上
- ryoppippi の web-fetch は SKILL.md 自体に最初から `./ax` / `./tgrab` と書いてある。そのため `packages = [ pkgs.llm-agents.ax pkgs.llm-agents.tgrab ]; rewriteCommands = false;` だけで動く。**[確認]** ryoppippi `agents/skills/web-fetch/SKILL.md` 10 行目、`nix/modules/home/agent-skills.nix`
  - gigun の flake でも `inputs.llm-agents.packages.aarch64-darwin` に `ax` と `tgrab` がある。**[確認]** `nix eval` → `{"ax":true,"tgrab":true}`

### 2.6 plugin export の制約（実験的）

- `mkAgentPlugin` は、選んだ skill を **skills だけの** `.codex-plugin/plugin.json` 形式（ChatGPT / Codex 向け）へ書き出す。Claude Code の `.claude-plugin` は出さない。**[確認]** `docs/agent-plugin.md`
- 拒否されるもの:
  - `packages` か `transform` を持つ skill（store に依存し、持ち出せないため）。**web-fetch のように実行ファイルを同梱する skill は plugin にできない。**
  - manifest の `apps` / `mcpServers` / `hooks`
  - `disable-model-invocation: true`
- per-skill の `agents` 制限は export に効かない（export 側の map が中身を決める）。

---

## 3. ryoppippi の使い方

### 3.1 skill **[確認]**

- flake input は `agent-skills = { url = "github:Kyure-A/agent-skills-nix"; inputs.nixpkgs.follows = "nixpkgs"; }`（`flake.nix` 120 行目付近）。他の input（nvimx）も `agent-skills.follows` で揃えている。
- `nix/flake/constants.nix`
  - `local-skills = lib.fileset.toSource { fileset = ../../agents/skills; }`: 自前 skill だけを store に入れ、`.git` などを持ち込まない。
  - `skillRegistry = { manifestsDir = ../../registry/sources; lockFile = ../../registry/sources.lock.json; }`
- `nix/modules/home/agent-skills.nix`
  - `sources = agentSkillsLib.sourcesFromLock skillRegistry // { local = { path = local-skills; subdir = "agents/skills"; filter.maxDepth = 1; }; }`
  - 自前 skill はすべて `skills.explicit` に置く（`agents` 制限を付けるため。コメントは「Explicit rather than skills.enable」）。
  - tstack（t3dotgg/tstack）からは 6 個を explicit で選ぶ。`transform` で `file-pr`→`create-pr`、`sol-loop`→`review-loop` に置換している。
  - `ast-grep`: `packages = [ pkgs.ast-grep ]; rewriteCommands = false;`。transform で絶対 store パスに置換している（`./name` への書き換えが frontmatter を壊すため）。
  - `agent-browser`: transform で `~/.agents/skills/agent-browser/agent-browser` の絶対パスに置換している。
  - `web-fetch`: packages は ax と tgrab、`rewriteCommands = false`。
  - targets は 3 つ。
    - `agents`: `$HOME/.agents/skills`、`copy-tree`
    - `claude`: `.config/claude/skills`、`link`。既定の `${CLAUDE_CONFIG_DIR:-…}` は activation 時に未 export でずれるため、明示している。
    - `claude-personal-0`: 2 つ目のプロファイル用
- `registry/sources/*.nix` は 5 件（agent-browser、ast-grep、gh-stack、t3-limits、tstack）。すべて `branch = "main"`、`filter.maxDepth = 1`。
- 更新: `.github/workflows/update-skill-sources.yaml` が毎日 06:30 UTC に `nix run .#skills-sources-lock` を実行する。動いた pin の表を本文にした PR を bot app で作り、**required checks が通れば自動 merge** する。
- Claude Code 側は skill をすべてこのモジュールに任せている（`programs/claude-code/default.nix` のコメント「All skills (external and local) are managed by agent-skills module」）。plugin marketplace は使っていない。

### 3.2 MCP の宣言と配布 **[確認]**

| エージェント | 宣言場所 | 内容 | merge 方式 |
|---|---|---|---|
| Claude Code | `nix/modules/home/programs/claude-code/default.nix` | **MCP の宣言なし**（`mcpServers` も `claude mcp` も repo 内に無い。`grep -rn "mcpServers\|claude mcp"` で 0 件） | `settings.json` は `jq -s '.[0] * .[1]'` で live ファイルに deep merge する（`activation.writeClaudeSettings`）。宣言したキーが勝ち、`/permissions` が追記した allow などは残る。プロファイル 2 つに同じものを書く |
| Codex | `nix/modules/home/programs/codex/default.nix` | `mcp_servers.t3.url = "http://127.0.0.1:3773/mcp"`（T3 Code の外で動く Codex 向け。T3 内のスレッドには T3 が `t3-code` を注入する） | `merge-config.nu` で TOML を再帰 deep merge する。ChatGPT デスクトップアプリが同じ `config.toml` に書く `node_repl` / `computer-use` MCP と plugin 登録を消さないため（commit `10491ab4` 2026-08-10） |
| OpenCode | `programs/opencode/{settings,cli}.json` | MCP なし（grep で 0 件） | jq の deep merge |
| T3 Code | `programs/t3code/default.nix` | MCP なし。providerInstances の binaryPath を store パスに固定 | jq の deep merge |

- 経緯: Codex に積んでいた context7、deepwiki、figma、playwright、lsmcp、devenv の MCP は 2026-01 から順に撤去された（`8dd47747 chore(codex): remove almost all mcps`、`ed7d4f02` で chrome-devtools も撤去）。Claude 側も `4bf61943 remove Codex MCP configuration`。代わりに skill と CLI（web-fetch の ax/tgrab/exa、agent-browser）で賄っている。
- secrets: MCP 用の秘密は設定ファイルに入れていない。exa と TinyFish の API キーは skill の reference が実行時に `op read op://keys/EXA_API_KEY/credential` で 1Password から読む。**[確認]** `agents/skills/web-fetch/references/exa.md` 11-14 行目
- 他エージェント: `.agents/skills`（agents target）を Codex・OpenCode・Pi などが共用する。agy（Antigravity）向けの MCP 宣言は見当たらない。

### 3.3 gigun の .mcp.json 方式との比較

| 観点 | ryoppippi | gigun（claude-code marketplace） |
|---|---|---|
| MCP の正本 | エージェントごとの Nix 設定（Codex のみ 1 本） | `plugins/<name>/.mcp.json`。`scripts/generate_manifests.py` が `.claude-plugin`、`.codex-plugin`、agy の `mcp_config.json` を生成する **[確認]** README |
| 粒度・on/off | 常時有効。外すには switch が要る | plugin 単位で `enabledPlugins` を切り替える（`claude/settings.json` に 40 件超）。switch は不要 |
| 配布先 | home-manager のある機械だけ | marketplace を登録した機械ならどこでも（Nix 不要。Windows ネイティブや凍結中の mini も可） |
| settings の書き手 | Nix が deep merge で上書き参加 | `settings.json` は Claude とユーザーの所有で、HM は触らない **[確認]** dotfiles `nix/modules/home/dotfiles.nix` 170 行目、`docs/mini-vm.md`「Claude の設定」 |
| secrets | 1Password を実行時に `op read` | agenix（`secrets/*.age`）、plugin の OAuth（asc-mcp の http）、mini-vm の Codex MCP 再ログインは ADR 0013 で Cloudflare Access 経由 |
| 方針 | MCP を減らし、skill と CLI に寄せる | 外部 MCP は薄いラッパー plugin にし、正本を 1 か所に置く |

MCP について agent-skills-nix は何もしない。どの選択肢をとっても、gigun の `.mcp.json` 正本の方式はそのまま残る。

---

## 4. gigun の現状（前提）

- marketplace `gigun` は `extraKnownMarketplaces` の directory source（`/Users/gigun/ghq/github.com/gigun-dev/claude-code`）で登録されている。**[確認]** `claude/settings.json`
- `vendor/upstream-skills.json` は ryoppippi の skill 6 個（worktree、t3-delegate、t3-limits、ask-other-agent、review-loop、edit-skills）を sha 付きで原本のまま固定している。`.github/workflows/upstream-skills.yml` が毎週月曜に差分 PR を作り、**自動 merge はしない**。**[確認]**
- web-fetch は `76ad88c fix(cross-agent): web-fetch を輸入から外す` で撤去された。理由はコミットメッセージにあり、`./ax` は agent-skills-nix の配り方を前提にしているため。**[確認]**
- ADR 0001 は skill 本文を Claude / Codex / AGY で共有すると定めている。ADR 0002 は、上流が plugin 定義を持つ外部 skill を URL 参照にすると定めている。**[確認]** `claude-code/docs/adr/`

補足: Claude Code の plugin は `bin/` に置いた実行ファイルを Bash ツールの PATH に載せる **[確認]** https://code.claude.com/docs/en/plugins-reference 「Standard layout / Executables」。ただし web-fetch の本文は `./ax` という相対パスなので、bin/ に置いても原本のままでは解決しない **[推測: モデルが skill のベースディレクトリを補って `./ax` を実行すれば動くが、bin/ は skill ディレクトリではない]**。Codex の plugin が実行ファイルを同梱できるかは、公式ページに明記が無い **[確認: 記載なし]**。

---

## 5. 選択肢

### A. 全面移行（自前 skill も外部 skill もすべて agent-skills-nix に移す）

- 利点
  - ryoppippi と同じ形になる。`packages` を使う skill が自由に書ける。
  - pin を `registry/sources.lock.json` に一元化し、ryoppippi 型の自動 PR を使える。
  - 名前空間が無いので skill 名が短い（`todo` であって `todo:todo` ではない）。
- 失うもの
  - enabledPlugins による skill の on/off。user scope の skill は常時有効になり、外すには Nix の宣言と switch が要る。
  - plugin 名前空間（`todo:adr` など）。他の plugin の skill と同名になると衝突する。
  - **MCP・hooks・agents は plugin に残るので二重運用は避けられない**（例: telemetry の hooks、pre-push、t3 の MCP）。
  - Nix の無い機械（凍結中の mini macOS、Windows ネイティブ）への配布。
  - ADR 0001 の AGY 用生成（agent-skills-nix には `antigravity` target があるので代わりは効く **[確認]**）。
  - Codex の plugin marketplace 経由の導入。
- 粗い見積もり: 2〜3 日。input 追加、`nix/modules/home/programs/agent-skills.nix`、registry、自前 skill 約 15 plugin 分の移設、`~/.claude/skills` の乗っ取り、marketplace 側の skill 削除と ADR 改訂、mini-vm / WSL での確認。

### B. 外部 skill だけ agent-skills-nix に移す（推奨）

- 対象: `vendor/upstream-skills.json` の 6 個と、撤去した web-fetch（`packages = [ llmAgents.ax llmAgents.tgrab ]`）。必要なら ryoppippi が registry で使っている ast-grep や tstack も足す。
- 利点
  - web-fetch が原本のまま動く。
  - `scripts/sync_upstream_skills.py`、`vendor/`、週次 workflow という「原本コピー」の仕組みを畳める。
  - pin は lock の差分 PR で更新できる（ryoppippi の workflow をほぼ流用可能）。
  - 自前 skill・MCP・hooks は今の marketplace のまま残る。
- 失うもの
  - これらの外部 skill を enabledPlugins で切ること。ただし Pro の live `~/.claude/settings.json` では worktree / t3 / cross-agent / edit-skills の 4 つがすべて `true`。repo の `claude/settings.json` には 4 つとも記載が無い **[確認]**。
  - 名前空間（`cross-agent:review-loop` → `review-loop`）。
  - mini macOS への配布（mini macOS はエージェント基盤ではないので実害は小さい **[推測]**）。
  - t3 plugin は MCP（`t3-code`）だけの plugin になる。
- 注意
  - 移行時には marketplace 側の同じ skill を必ず消す。消さないと `review-loop` と `cross-agent:review-loop` の 2 つが見える。
  - `~/.claude/skills` の既存 2 件（`ios-device-build`、`synced`）の扱いを決める。target の `dest` を分けるのでは解決しない。Claude が読む場所は 1 つなので、既存 2 件も宣言に取り込むか、手動配置をやめる。
- 粗い見積もり: 0.5〜1 日。
  - flake input と `extraSpecialArgs` の配線（`flake.nix`、`nix/modules/home/default.nix`）
  - `nix/modules/home/programs/agent-skills.nix` の新規作成
  - `registry/sources/{ryoppippi-dotfiles,t3-limits}.nix` と lock
  - `nix run .#skills-sources-lock` アプリ
  - 週次（または日次）の lock 更新 workflow。merge 方針は dotfiles の既存 lock PR 運用（ADR 0003 / 0011）と揃える
  - claude-code 側で vendor 6 件を削除し、README / ADR を改訂する

### C. 現状維持

- 利点: 変更が無い。on/off と名前空間が残る。Nix 非依存の配布も残る。
- 失うもの: web-fetch（ax/tgrab の SKILL）は使えないまま。原本コピーの同期スクリプトの保守が続く。
- 代替案: web-fetch だけを plugin 化し、`bin/ax` を PATH 上の `ax` に exec する shim にする。ただし本文の `./ax` を書き換えない限り動かない可能性が高く **[推測]**、「原本のまま固定」の原則に反する。Codex 側で bin/ がどう扱われるかも未確認。

---

## 6. 推奨: B（外部 skill だけ agent-skills-nix）

1. 撤去の原因（web-fetch の `./ax`）は、agent-skills-nix の `packages` でしか原本のまま解けない（§2.5、§4）。
2. 原本コピーの固定は、registry lock の機能（manifest と lock の一致検査、決定的な lock、npins）と目的が同じで、自前スクリプトより検査が厳しい（§2.1）。
3. MCP・hooks・自前 skill を plugin に残しても失うものは無い。agent-skills-nix は MCP を扱わず、plugin export も MCP と hooks を拒否するため（§2.6）、全面移行しても plugin は消えない。
4. 外部 skill は今でも上流の更新に追従するだけで、Pro では 4 plugin とも常に有効 **[確認]**。端末ごとに on/off したい対象ではない **[推測]**。

---

## 7. ユーザーの判断が要る論点

1. 外部 skill の on/off と名前空間を手放してよいか（B と A の前提）。
2. lock 更新 PR を自動 merge するか。ryoppippi は自動、gigun の vendor は手動、dotfiles の flake.lock は自動。
3. `~/.claude/skills` にある `ios-device-build` と `synced` を宣言に取り込むか、撤去するか。
4. Codex 向けに `agents` target（`~/.agents/skills`）を有効にするか。有効にすると marketplace 経由の Codex plugin と同じ skill が重なる。
5. agy に配るのは marketplace（`~/.gemini/config/plugins.json`）か、`antigravity` target か。
