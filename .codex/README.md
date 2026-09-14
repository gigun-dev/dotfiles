# Claude Code / Codex の共有設定

Claude Code 側を正典にし、同じ内容を表現できる Codex surface は symlink で共有する。

| Codex | 正典 | 方式 |
| --- | --- | --- |
| `AGENTS.md` | `CLAUDE.md` | symlink |
| `.agents/skills/*` | `.claude/skills/*` | symlink |

ユーザーグローバルの配置先は別途管理する。`claude/CLAUDE.md` → `~/.claude/CLAUDE.md`、
`codex/AGENTS.md` → `~/.codex/AGENTS.md` を bootstrap と home-manager の両方でリンクする。
ルートの `AGENTS.md` はこの dotfiles リポジトリ用で、ユーザーグローバルではない。
グローバルの委譲・中断条件は両者で揃え、Claude 固有の agent / CLI 指示と Codex の
`collaboration` API 名は各ファイルに置く。共通方針を変えるときは両方を確認する。

## コンテキストの正典

1. `AGENTS.md` / `CLAUDE.md`: 常時必要な不変条件。
2. `todo.txt`: タスク。`docs/adr/`: 覆すのに費用のかかる決定。
3. project skills: トリガー時だけ必要な長い手順。

Claude project memory や session JSONL / tool results は機械依存・一時的で秘密を含み得るため
symlink しない。恒久化すべき知識だけを上記の instructions / docs / skills へ昇格する。

## 保守

- 共通 instruction、skill、rules は **Claude 側の正典だけを編集する**。
- Claude settings / plugin / MCP を変えた場合、Codex adapter にも同じ意図を反映する。
- `.claude/settings.local.json` の permission allowlist は個人環境なので Codex へ移植しない。
