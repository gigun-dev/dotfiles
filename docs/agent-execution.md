# エージェントの書き込みと検証

2026-09-12 の変更。worktree の境界は [ADR 0005](adr/0005-scope-worktrees-to-target-repositories.md) に置く。

## 調査の訂正

根拠は隣の `gigun-dev/claude-code` の
[`docs/telemetry/2026-09-11-subagent-time-breakdown.md`](https://github.com/gigun-dev/claude-code/blob/main/docs/telemetry/2026-09-11-subagent-time-breakdown.md)。
dotfiles 内の同名パスは存在しない。

- worktree を割り当てられたのは 24/32 体。その cwd は worktree 内だったが、8 体が本体に Edit/Write した。
- test.sh の中央値は単独 50 秒、重なった回は 94 秒、最大 764 秒。長い3件は失敗であり、最大値の原因を競合だけと断定しない。
- 検証は32体の実時間合計の17%、個体中央値9%。「6割が検証」「毎回コールドビルド」は根拠にしない。

## 配布するルール

`claude/CLAUDE.md` は通常の symlink 配布で Claude Code に届く。今回 `~/.claude/CLAUDE.md`
がこのファイルを指すことを確認した。`~/.codex/AGENTS.md` は別管理であり、この変更が Codex
の全セッションにも自動で適用されるわけではない。

今回 `~/.claude/settings.json` は symlink ではなく実ファイルだったため、既存の設定を保ち
PreToolUse の当該エントリだけを追加した。リポジトリ側にも同じエントリを置いている。
hook の実体は既存の `~/.claude/hooks` symlink 経由で参照する。

- Codex への文章はファイル作成ツールで保存し、companion の `task --prompt-file` にパスを渡す。
  直接 CLI を使う場合は `codex exec - < prompt.md`。文章を shell の引数へ展開しない。
- 子は対象検証、親は統合後の手動全検証を1回。変更・失敗調査・残る懸念があれば必要な再検証をする。
  同じホストで調整している agent 群の重い検証は1枠。CI/pre-push の必須検証は省かない。
- 子の報告に検証対象・コマンド・結果・未検証範囲、todo/ADR候補、必要な ignore 成果物を含める。
  親が成果物を引き継ぎ、残件を todo に記録してから worktree を片付ける。

1枠は運用上の上限で、独立した別セッションを強制的に止めるホスト全体ロックではない。
ccache や build ディレクトリ共有も今回導入しない。実環境での所要時間改善は未測定。

## 検証の境界

- インストール済み companion 1.0.6 の `readTaskPrompt` をオフラインで実行し、日本語、表、
  バッククォート、引用符、`$()`、改行を空白入りパスからそのまま読み取ることを確認した。
  Claude からの実際の委譲で、この渡し方が選ばれることは未検証。
- worktree ガードは [Claude Code の PreToolUse](https://code.claude.com/docs/en/hooks#pretooluse)
  を使う。Edit/Write の file_path だけを扱い、Bash/MCP/Codex の書込みは対象外。
- `scripts/tests/` の使い捨て repo による検証と、実 agent の起動時に hook が発火する受入を分ける。
  実 worktree の削除や、本番設定の switch は行わない。
- `python3 scripts/tests/worktree-write-guard.py` は5テスト（Write/Edit の24境界ケースを含む）通過、
  `/bin/bash scripts/tests/worktree-sweep.sh` は11境界通過。実設定の hook コマンドを fixture 入力で実行し、symlink 経由でガードが動いて本体宛てを拒否することも確認した。
- 使い捨て worktree から実 Claude の Write を試す受入は、週間上限の API 429 で推論前に終了した。
  hook 発火の成功証拠には数えない。応答のリセット予定は9月15日2時 JST。実委譲の受入は残件。

## Codex全体の作業継続（2026-10-03）

CoreS3開発で、親が未完の子を残して終了し、次の利用者入力後に子の成果を受け取った例を確認した。対象ログで子の完了71件はすべて親の受信記録と一致し、通知欠落を主因とする根拠は無い。分析記録は `gigun-dev/esp32-airdrop-poc/docs/reviews/session-stops-2026-10-03.md` にある。これはPJ固有のルールではなく、親の終了判断と成果統合の共通課題として扱う。

継続ルールは `codex/AGENTS.md` に置く。現在のMacでは `~/.codex/AGENTS.md` がこのファイルへのsymlinkで、ファイル更新が読み込み先へ届く。質問・進捗回答だけで元の作業を終了しない。親は未完の子と依頼範囲内の実行可能な仕事を確認し、成果の統合・検証・台帳更新・次の依存解除を引き受ける。人の入力で塞がる項目があっても、独立した仕事を先に進める。

これは文章による進行管理ルールである。終了した親を子完了で再開するhook、アプリの修正、finalの強制拒否は実装しない。既存の停止ログでは子完了だけによる親の新ターン開始が確認できず、一般的な自動再開仕様は未確認。適用確認は指示ファイルのsymlink・内容・PJ重複の除去までであり、将来すべての停止を防げることや他ホストへの配布完了を保証しない。

同日の日本語化は、説明用の翻訳依頼を誤読した変更だったため英語へ戻した。委譲と継続を分けず、全体を6項目へ整理した。親の統合責任・独立作業の継続・子待機・引継ぎ条件・停止報告を残し、重複を削る。
