# グローバル方針(全プロジェクト共通)

## 作業の癖の矯正(cclens 実測 2026-08-05: 63プロジェクト・1626失敗の上位パターンより)

- **編集前に対象を Read する。** Edit の old_string 不一致が最多失敗(344件)。ファイルは
  セッション中に変わる — Edit が失敗したら old_string をいじり回さず、再 Read してから直す。
- **パスを推測しない。** path-not-found 137件。ls / Glob で実在を確認してから Read/Edit/Bash に渡す。
- **`cd` を繰り返さない。** Bash の25%が単独 cd だった。コマンドは絶対パスで打つ。

## 開発の進め方

- **実装は subagent(implementer / artisan)に委譲し、main は設計・レビューに徹する。**
- **コメントはコードと同量レベルでベッタベタに書く**(意図・経緯・ボツ案 = Why not)。
  リポジトリに `.claude/rules/comments.md` があればそちらが正。
- **恒久情報は Claude メモリーではなくリポジトリ内ファイルへ**(git 管理・マシン非依存・
  他エージェント可視)。セッション引き継ぎは docs/next-directions.md 方式。
  未導入リポジトリへの導入は `/harness:init`(gigun マーケットプレイスの harness プラグイン)。
