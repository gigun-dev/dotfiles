# ryoppippi/dotfiles のエッセンスと gigun dotfiles への寄せ方

調査日 2026-11-08。対象は ryoppippi/dotfiles `de137c2`（全履歴 9413 commit を取得）と gigun-dev/dotfiles の作業ツリー、gigun-dev/claude-code の `plugins/worktree`。以下の sha は特記なければ ryoppippi 側。`g:` を付けた sha は gigun-dev/dotfiles、`cc:` は gigun-dev/claude-code。

---

## 1. 設計原則と考え方

### 1.1 エージェントへの指示は「意図と判断」で書き、細かい規則を並べない

- `agents/AGENTS.md` の "How to Work" が中心にある。根本原因を直す、近くのコードを手本にしない、retry・特例・型の緩和をしたくなったら症状を隠しているサインと疑う、規則の字面が目的に反するときは目的に従ってそう言う、の 4 点だけ。
- 転機は 65fd312（2026-10-31）。本文に "Narrow micro-rules invite agents to satisfy the letter of a rule and to patch symptoms the way nearby code does" とある。断片をまとめ（browser→tools、git-staging/git-worktrees→git.md）、薄いラッパー skill を統合した。
- 同じ考え方が `agents/skills/edit-skills/SKILL.md` の Principles にも書かれている。
  - 意図を書く。1 回の失敗を受けて規則を足す前に原因を探す。
  - lint・hook・script で強制できるものは文章から消してそちらへ移す（"Prefer tooling to prose"）。
  - 1 つの事実は 1 か所に置き、ほかの skill は名前で参照する。
  - 一次情報を書き写さず指し示す（`--help`、URL）。
  - モデルが既に知っていることは書かない。
- 実測で直す。2d0203f4 は transcript を集計し、`direnv blocked` が Bash 結果の 47%、`echo ===` による EQUALS 展開エラーが約 240 件、`fish -lc` のクォート崩れが約 120 件、`cd <path> &&` が Bash 呼び出しの 57%、worktree subagent の複合コマンド拒否が約 400 件あったと示した。そのうえで設定（direnv の whitelist、zsh の `=cmd` 無効化）と指示を直している。gigun の g:7ef79b3 と g:334d74b も cclens の実測を根拠にしており、方法は同じ。
- skill は description が選ばれるかどうかを決める。65fd312 で description を "When ..." の状況記述に統一したところ、skill が選ばれなくなった。fada853f で「何をするか + ユーザーが打つ言葉」の形に戻し、名前もユーザーが使う語（`worktree`、`commit`、`japanese-summary`）にした。

### 1.2 委譲は「要約で済む重い作業」に限り、モデルは作業の重さで選ぶ

`agents/shared/delegate-work.md` の主旨は次の 5 点。

1. 出力が多く結論が小さい作業（Web 検索、コード調査、長い出力の要約、コミットメッセージの下書き）は、自分の native subagent に渡す。
2. 自分と同じ CLI を入れ子で起動しない。別ベンダーの意見がほしいときは `ask-other-agent`、T3 の中では `t3-delegate` を使う。
3. 実装の委譲は「指示書を書く方が自分でやるより安いとき」だけ。計画と分割は親が持ち、自己完結の brief を渡して diff を確認する。自分でやる方が速ければ自分でやる。
4. レビューは逆向きにし、別ベンダーの強いモデルに出す（`review-loop`）。
5. worktree 内の subagent には、1 コールに単純なコマンド 1 つと `git -C` を使わせる。

変遷は次のとおり。

| 時期 | 内容 | sha |
|---|---|---|
| 2026-08 | pi-sub / codex-sub ラッパー経由で外部 CLI に委譲 | 47679ddb, 0bb664e9 |
| 2026-08-27 | Codex の中では native subagent を使う | 6f6ec86d |
| 2026-10-13 | 重い検索を毎回 `codex exec` に回していたため、通常の質問でも Codex が起動していた。各エージェントが自分の native subagent に渡す形に改めた | aab3f38f |
| 2026-10-14 | Codex は sol（high）で計画し、luna（max）の subagent で実装する | ba83fc0f |
| 2026-11-01 | 上の固定配線とモデル名をやめ、「作業の重さでモデルを選ぶ」判断基準だけを書く | 4868bc86 |

subagent の設定も揺れている。445188c1（2026-09-15）で subagent を Opus に固定し、12d9b00f（10-29）で固定を外して agent 定義側が選べるようにした。006ee95f（11-02）では `subagentPromptCacheTtl = "1h"` を入れ、休んでいた subagent を再開するときのキャッシュ再書き込みを避けている。

### 1.3 Nix で宣言する範囲

- 宣言しているもの：
  - 指示ファイルの配布（symlink と生成）
  - skill（agent-skills-nix、外部 skill は `registry/sources/*.nix` で固定）
  - Claude・Codex・T3 Code の設定。いずれもアプリが自分で書き換えるファイルなので、symlink ではなく jq や nu で「宣言したキーが勝つ」merge をする（`programs/claude-code/default.nix` の `writeClaudeSettings`、`codex/merge-config.nu`、`t3code/default.nix`）
  - git hooks（`git-hooks.nix` + `git-hooks.nu`）
- symlink で即時反映させているもの：`AGENTS.md`、`shared/`、`claude/{commands,agents,output-styles}`。いずれも out-of-store symlink なので switch は要らない。Codex 用の `AGENTS.md` だけは生成物なので switch が要る（1628cc76）。
- 外部 skill の固定は flake input ではなく独自の registry で行う。`nix run .#skills-sources-lock` が `flake.lock` に触れずに更新し、毎日の bot（`.github/workflows/update-skill-sources.yaml`）が PR を出す。
- Claude の settings は schema で検証するが、失敗しても止めない（`validateClaudeSettings`）。

### 1.4 Claude・Codex・T3 の統一方法

- 指示は 1 か所にまとめている（0650e3e3, 2026-09-18）。`agents/AGENTS.md` を正本とし、`~/.config/claude/CLAUDE.md` に symlink する。`@~/.config/claude/shared/*.md` で断片を読み込む。
  - Codex には import 機構がない。そのため `codex/default.nix` の `sharedFragments` が `@` 行を落として断片を連結し、`~/.codex/AGENTS.md` を生成する。
  - 新しい断片を足すときは、import と `sharedFragments` の 2 か所に書く必要がある（`agents/README.md`）。
- リポジトリには CLAUDE.md を置かない。Claude Code は built-in の `agents-md` プラグインで `AGENTS.md` を読む（ルートの `AGENTS.md`）。Codex 側は `project_doc_fallback_filenames = ["CLAUDE.md"]` で他リポジトリの CLAUDE.md も読む。
- skill は同じ `agents/skills/` を `~/.agents/skills`（copy-tree）と `~/.config/claude/skills`（link）の両方に配る。対象を絞りたい skill は frontmatter の `metadata.agents: [claude]` で指定する（32854aa0）。
- T3 Code は全 provider の binary を nix の store path に固定する。既定は worktree で動くスレッド、ブランチ名は semantic（prefix は `ryoppippi`）、マージ時に worktree を自動掃除、`removeAgentCreditsOnMerge` を有効にしている（`t3code/default.nix`, 675b1042, b37efcf3）。
  - cmux を外したのは、セッション・プロジェクト・worktree の管理を T3 に寄せたから（60e05cdd）。
  - skill は inside-t3 と outside-t3 の分岐（`references/inside-t3.md`）で両方の経路に対応している。

---

## 2. エージェント運用の全体像（ryoppippi）

| 領域 | 中身 | 根拠 |
|---|---|---|
| 指示ファイル | `agents/AGENTS.md`（約 20 行）と `shared/{tools,nix,code-comments,command-privacy,git,delegate-work}.md`。全体でおよそ 60 行 | 各ファイル |
| 配布 | Claude は symlink と `@import`、Codex は生成。複数アカウント用に `claude`・`claude-personal-0` の各 profile へ同じものを張る | `programs/claude-code/default.nix` |
| skill | ローカル 20 個（commit, create-pr, review-loop, worktree, fix-ci, merge-main, edit-skills, web-fetch, ask-other-agent, t3-delegate など）。外部は tstack・ast-grep・agent-browser・gh-stack・t3-limits を pin | `agents/skills/`, `registry/sources/`, `agent-skills.nix` |
| skill の固定 | agent-skills-nix（cfc2020c, 2026-01-11）。外部 skill は `transform` で文言（`file-pr`→`create-pr`）や binary の絶対パスを書き換える。`packages` で skill が必要とする CLI を一緒に入れる | `agent-skills.nix` |
| custom subagent | なし。`claude/agents/` は `.gitkeep` だけ。2025-09 に git-commit-crafter と pr-workflow-manager を作ったが、a9184c5c（2025-11-14 "migrate from agents to skills system"）で skill に移した | `git log -- claude/agents` |
| worktree | git-wt（k1LoW、nixpkgs）と自作の git-wtpr（PR を worktree で開く nu script）。`wt.remover = trash`。skill `worktree` は「既に linked worktree の中なら動かない」「`--nocd` で出力されたパスを使う」「`-D` はユーザーが言ったときだけ」と定める。Claude の `isolation: worktree` を git-wt に通す hook はない（`rg WorktreeCreate` で 0 件） | `agents/skills/worktree/SKILL.md`, 682efa73, 830d019c, 01ec45fb, aae7931e |
| レビュー | `review-loop`。別ベンダーのモデルに読み取り専用で brief を送る。既定 3 ラウンド、ledger、深刻度を blocker・should・nit に分け、scope creep に反論する。tstack の sol-loop（MIT）を基にしている | `review-loop/SKILL.md`, 23f74b95 |
| hooks | `gh pr create` の前に review-loop を通したかを `/tmp/.claude-review-done` で確かめるゲート（PreToolUse と PostToolUse(Skill)）だけ。dotfiles の git hooks は「main のときだけ switch する」（8ef5b706） | `claude-code/default.nix`, `git-hooks.nu` |
| settings の主な項目 | `defaultMode=auto`、`effortLevel=medium`、`alwaysThinkingEnabled`、`autoMemoryEnabled=false`（719c9791）、`subagentPromptCacheTtl=1h`、`includeCoAuthoredBy=false`、`cleanupPeriodDays` は事実上無期限、`DISABLE_MICROCOMPACT` などの env、ccusage の statusline | 同上 |
| Codex settings | `approvals_reviewer=auto_review`、`multi_agent`、`default_subagent_model=luna`、`max_concurrent_threads_per_session=100`、T3 の MCP | `codex/default.nix` |
| git 規則 | path を明示して stage し、`-A`・`.`・`-u`・`commit -a` は禁止。switch 用の stage とコミット用の stage を分ける。worktree の中に居続ける。`commit` skill は `git add -p` を禁止し、`git apply --cached` を使う | `shared/git.md`, `commit/SKILL.md`, af58173a |

---

## 3. 持ち込めるものと持ち込まない方がよいもの

### 持ち込める（gigun の環境で意味が通じる）

1. 指示の単一化：AGENTS.md と shared 断片を正本にし、Codex 用には生成する（0650e3e3, 1628cc76）。gigun は `claude/CLAUDE.md` と `codex/AGENTS.md` に Git 節を二重に持っている。両者の作業管理節も表現が違う（"Work management" と "Global conventions"）。ryoppippi が 1628cc76 で書いた「already drifted apart once」と同じ状態にある。
2. `edit-skills` の Principles（tooling > prose、1 つの事実は 1 か所、一次情報を指す）と description の書き方（fada853f）。gigun の `.claude/rules/comments.md` や「Only what differs from the agent's own defaults」と方向は同じ。
3. `delegate-work.md` の判断基準。「指示書の方が安いときだけ実装を委譲する」「重い出力は native subagent に回す」「入れ子の CLI は起動しない」「worktree の subagent は単純なコマンドと `git -C`」の 4 点（2d0203f4 の約 400 件の拒否という実測付き）。
4. `review-loop` の構造（ラウンド上限、ledger、深刻度、reviewer は 1 人で subagent を使わない）と、`gh pr create` のゲート hook。gigun は main に直接 push する運用なので、PR ゲートの効く場面は他リポジトリに限られる。
5. settings の宣言的 merge（`jq -s '.[0] * .[1]'`）。gigun は `~/.claude/settings.json` を実ファイルにして activation で触らない（`g:nix/modules/home/dotfiles.nix:170`）。実際に repo 版と実ファイルがずれている。実ファイルにだけ `subagentPromptCacheTtl: "1h"`、`harness@gigun`、`workers-fetch@gigun` があり、repo にだけ `model: "fable"` がある（2026-11-08 に diff で確認）。
6. `subagentPromptCacheTtl=1h`（006ee95f）。実ファイルには既にあるが repo に入っていない。
7. git-wtpr（PR を worktree で開く）と skill `worktree` の「既に worktree の中なら作らない」判定（830d019c）。
8. 外部 skill を registry で pin し、bot が PR を出す方式。gigun は mini-vm が lock PR を出す運用（ADR 0003）と組み合わせられる。

### 持ち込まない方がよい（ryoppippi 固有か、gigun の前提と衝突する）

| 項目 | 理由 |
|---|---|
| T3 Code 前提の経路（`t3-delegate`, inside-t3 references, t3-limits, `defaultThreadEnvMode=worktree`, `removeAgentCreditsOnMerge`） | gigun の T3 設定は provider の固定と ghq だけ（`g:nix/modules/home/programs/t3code/default.nix`）。主な道具は iTerm2 と Claude Code CLI、teammateMode=tmux |
| fish・nushell（Scripting Language Choice で nu を既定にしている、`git-hooks.nu`, `git-wtpr.nu`, `audit.nu`） | gigun は zsh と Python・bash。git-wtpr は nu script を nix でパッケージしたものなので、使うなら derivation ごと持ち込むか bash で書き直す |
| 複数アカウントの profile（`claude-personal-0`, `CLAUDE_CONFIG_DIR=~/.config/claude`） | gigun は `~/.claude` を 1 つだけ使う。agent-skills-nix の `claude` target の dest も合わせて変える必要がある |
| UK English・成果物は英語 | gigun は Japanese 応答、`language: "Japanese"`、日本語のコミット |
| `commit` skill の `git add -p` 禁止 | gigun は g:9f5b822 で、明示 path 方式から mozumasu 方式（add -p を stdin で答える）へ意図的に移した。ryoppippi の git.md の「`git add -A`/`.` 禁止」とも逆 |
| `autoMemoryEnabled=false` | gigun の auto-memory は現に使われている。CLAUDE.md の「durable context は repo に置く」と方向は近いが、止めるかどうかは別に判断する |
| Codex の `approvals_reviewer=auto_review`、`max_concurrent_threads=100` | gigun の CLAUDE.md にある「重いビルドは 1 枠」（mini や Pro の CPU）と衝突する |
| `skipDangerousModePermissionPrompt` など | gigun の settings にも既に同じものがある。差分なし |

---

## 4. gigun との差分

| 観点 | ryoppippi | gigun | 差の意味 |
|---|---|---|---|
| 指示の正本 | `agents/AGENTS.md` + `shared/` の 1 か所。Codex は生成 | `claude/CLAUDE.md`（40 行）と `codex/AGENTS.md`（15 行）を別々に持ち、どちらも symlink（`g:dotfiles.nix:166-169`） | gigun は Git 節を二重に持っている。Codex も symlink なので switch なしで反映される点は gigun の方が良い |
| 書き方 | 意図と原則（How to Work） | 運用の規律が中心（委譲・worktree・検証の枠・引き継ぎ・todo/ADR）で、事故の記録が付いている | gigun は「何をするか」の規則が多く、ryoppippi が 65fd312 で減らした種類に近い。ただし各行に事故の根拠がある（後述 §5） |
| subagent | custom なし。native と `ask-other-agent` | `implementer`（sonnet）/ `artisan`（opus）/ `architect`（fable）/ `cross-repo-implementer`（sonnet）。どれも `disallowedTools: Agent` | gigun は「モデル選択・再委譲禁止・報告形式・worktree の責任分担」を定義側に固定している（g:ff890e6, g:d6343d4, g:334d74b）。ryoppippi は判断基準を文章で与え、毎回選ばせる（4868bc86） |
| worktree の作成 | git-wt（人と skill が使う）。Claude の isolation は既定のまま（`.claude/worktrees` を gitignore） | Claude 標準の `isolation: worktree`（親が渡すときだけ、g:c77445e）、`worktree.baseRef=head` | どちらもエージェントの worktree は Claude 標準。git-wt を通す hook は ryoppippi にもない |
| worktree の統合と掃除 | `git wt -d`（trash へ）、T3 のマージ時自動掃除 | `plugins/worktree` の integrate（merge→commit→finish、commit の成立を機械で確認、cc:8a35641）と sweep（3 分類、squash 判定） | gigun の方が厳しい。ただし `worktree@gigun` は現在 `~/.claude/settings.json` の enabledPlugins にも plugin cache にも無い（2026-11-08 確認）。CLAUDE.md も integrate を名指ししていない。今は実際には動いていない可能性が高い |
| 書き込みガード | なし | `worktree-write-guard.py`（PreToolUse Write\|Edit で、同じ repo の別 checkout への書き込みを拒否） | 根拠は 24 体中 8 体が本体に書いた実測（`g:docs/agent-execution.md`） |
| skill 配布 | agent-skills-nix + registry pin。store に固定し、switch で更新 | 別リポジトリの plugin marketplace（`gigun-dev/claude-code`、`.claude-plugin` / `.codex-plugin` / `.antigravity-plugin` を生成）。`enabledPlugins` に約 45 個 | gigun は plugin として bin・tests・version を持ち、他マシンや Codex にも配れる。nix の外にあるので固定と再現は marketplace 任せ |
| レビュー | `review-loop` + PR ゲート hook | codex plugin と coderabbit plugin はあるが、ループの規約やゲートはない | 持ち込む価値がある |
| hooks | PR ゲートのみ | 通知（bark・iTerm2 cc-status・afplay）、langfuse OTLP、write guard | gigun は観測と通知が厚い |
| settings 管理 | Nix で merge し、schema で検証 | repo に置いたファイルと実ファイルが別で、手で同期 | gigun ではずれが起きている（§3） |
| ADR | なし（コミット本文が理由の置き場） | `docs/adr/`（0003, 0010, 0011, 0013, 0014）。エージェント運用の ADR はまだない | 寄せる判断自体を ADR にする価値がある |

---

## 5. 寄せる順序の案と、寄せると失う安全装置

### 前提 A・B・C の検証

- **A（git-wt 導入 + WorktreeCreate/WorktreeRemove hook + plugins/worktree を ryoppippi の worktree skill に置き換え）**：前提の一部が成り立たない。ryoppippi は Claude の worktree 作成を git-wt に通していない（hook は 0 件）。worktree skill も、人か親が明示的に worktree を作るときの手順書にすぎない。
  - 置き換えると integrate の「commit の成立を確かめてから消す」（cc:8a35641 の 2026-09-15 の事故が由来）と、sweep の squash 判定がなくなる。
  - `git wt -d` は「worktree とブランチを同時に消す」道具で、squash 済みかどうかを確かめない。
  - 持ち込むなら置き換えではなく併用にする。git-wt と git-wtpr は人や親が使う作成・PR checkout の道具として入れ、integrate と sweep は残す。
  - WorktreeCreate hook は ryoppippi の外にある gigun 独自の拡張になる。仕様（hook が返すパス、`baseRef` との関係、WorktreeRemove が integrate より先に走らないか）は Claude Code の docs で未確認。
- **B（skill 配布を agent-skills-nix に）**：部分的に寄せるのが妥当。
  - 利点：外部 skill（mattpocock、tstack など）を pin し bot で更新できる。`~/.agents/skills` 経由で Codex にも配れる。`packages` で依存 CLI も宣言できる。
  - 欠点：gigun の自作 plugin は bin・tests・MCP 設定・複数 harness 用の manifest を持つ「plugin」であり skill ではない。agent-skills-nix は skill 配布なので、MCP や plugin.json の機能は表現できない。switch が必要になり、mini macOS（nix を凍結中）には届かない。
  - 自作 plugin は marketplace のまま残す。素の外部 skill だけを agent-skills-nix に置く 2 層構成なら損が少ない。
- **C（custom subagent を廃止し、delegate-work.md 相当にする）**：失うものが最も多い。ryoppippi が subagent を廃止した動機（a9184c5c）は「commit や PR の手順を agent から skill へ移す」というもので、実装役の subagent を否定したものではない。ryoppippi は実装役をそもそも定義していない。
  - gigun の 4 定義が固定しているのはモデル、`disallowedTools: Agent`、worktree での commit と報告の契約。どれも事故か実測が由来である。
  - 寄せるなら次の 2 点に留める。
    - 定義を残したまま、CLAUDE.md の委譲規則を delegate-work の判断基準（指示書が安いときだけ委譲する、重い出力を native に回す）で置き換える。
    - 「Delegate implementation to a subagent」という常時委譲の規則は見直す。

### 順序案（失うものが少ない順）

1. **指示の単一化**：`agents/AGENTS.md` と `shared/` を作り、Claude は `@import`、Codex は生成か連結 symlink にする。Codex の継続ルール（Work management）は Codex 専用の断片として残す。このとき日本語応答・add -p 方式などの gigun の内容は変えない。
2. **settings の宣言的 merge**：repo の `claude/settings.json` を「勝つキー」として jq で merge し、今のずれ（cache TTL、plugin 2 件、model）を一度解消する。
3. **review-loop の導入**：Codex plugin を reviewer にする。gigun は main 直 push なので、PR ゲート hook は他リポジトリ向けに限る。
4. **git-wt と git-wtpr を道具として追加**：nixpkgs に git-wt がある（47834c80）。git-wtpr は nu の derivation ごと持ち込むか書き直す。`worktree` skill の「既に worktree の中なら作らない」を CLAUDE.md の worktree 規則に統合する。
5. **委譲規則の見直し**：delegate-work の判断基準を取り入れ、「常に委譲」を緩める。custom agent は残す。
6. **外部 skill の一部を agent-skills-nix へ**：自作 plugin は marketplace に残す。
7. （見送りか別判断）WorktreeCreate hook と custom agent の廃止。

各段階を独立したコミットにし、1・5・7 は ADR にする。

### 寄せると失う gigun の安全装置（実測・事故が由来のもの）

| 安全装置 | 由来 | 失う条件 |
|---|---|---|
| `worktree-write-guard.py`（同じ repo の別 checkout への Write/Edit を拒否） | worktree 割り当て 24 体中 8 体が本体に書いた（`g:docs/agent-execution.md`, g:cf5abaa） | ryoppippi 式の「hook は PR ゲートだけ」に揃えた場合 |
| integrate の finish 検査（commit の成立を確かめてから消す） | 2026-09-15、親がコミットに失敗したまま worktree とブランチを消した（cc:8a35641） | `git wt -d` か worktree skill に置き換えた場合。ただし今は plugin が未有効 |
| sweep の squash 判定と 3 分類 | 推測で消さない設計。cf-fireboard での実測（`plugins/worktree/README.md`） | 同上 |
| `isolation: worktree` は親が渡すときだけ | 常に付けると 43 個・19GB の worktree が残った（g:c77445e） | WorktreeCreate hook で worktree 作成が増えた場合 |
| 子の worktree の削除は統合コミットの後に限る | CLAUDE.md "Both directions have cost you a day" | `git wt -d` の手順だけになった場合 |
| `disallowedTools: Agent`（実装役の再委譲禁止） | g:d6343d4 | custom agent を廃止した場合 |
| 実装役は Sonnet・Opus、設計は Fable に固定 | g:ff890e6（caldav の運用） | 同上（毎回のモデル選択が親任せになる） |
| 子は対象の検証、親は統合後に全体を 1 回。重いビルドは 1 枠 | test.sh の重なりの実測（中央値 50→94 秒、`g:docs/agent-execution.md`） | delegate-work には並列数の規律がない。Codex の 100 並列設定を持ち込むと逆行する |
| Codex のタスク文はファイルに書いて `--prompt-file` で渡す | Markdown やシェルのメタ文字が壊れる（同上） | ryoppippi の `codex exec ... "<brief>"`（引数に展開する形、`review-loop/references/outside-t3.md`）をそのまま使った場合 |
| 親が子を残したまま終了しない（Codex の継続ルール） | CoreS3 の停止ログ（同上 2026-10-03） | ryoppippi の AGENTS.md に同等の規則がないまま統合した場合 |
| `git status --untracked-files`（`=no` にしない）と、switch 用 stage の除外 | gigun 固有（switch で stage したものの混入） | ryoppippi の git.md にも同じ趣旨があるので失わない |
| `git add -p`（stdin で答える）を許可 | g:9f5b822 の意図的な選択 | ryoppippi の commit skill（add -p 禁止）を持ち込んだ場合 |
| 引き継ぎ前に確認する、todo/ADR の reconciliation、ignore 成果物の申告 | g:c8c8dc7, `docs/agent-execution.md` | delegate-work に置き換えた場合（ryoppippi には repo 内のタスク台帳がない） |

---

## 判断が要る論点

1. **A**：git-wt を「置き換え」ではなく「道具として追加」に留めてよいか。WorktreeCreate hook は ryoppippi にない独自案なので、作るなら docs の確認と ADR が要る。
2. **plugins/worktree が現在有効になっていない件**：integrate を主経路として復活させるのか（CLAUDE.md で名指しするのか）、git-wt に寄せて手放すのか。
3. **C**：「Delegate implementation to a subagent」（常に委譲）を ryoppippi の「指示書が安いときだけ」に変えるか。custom agent 自体は残す前提でよいか。
4. **settings.json**：Nix の merge で宣言管理に移すか（今は実ファイルと repo がずれている）。
5. **B**：自作 plugin は marketplace、外部の素の skill は agent-skills-nix、という 2 層構成でよいか。mini macOS（nix を凍結中）に届かない点を受け入れるか。
6. **指示の単一化**：Codex の継続ルールなど、harness 固有の節をどこまで共通断片にするか。
