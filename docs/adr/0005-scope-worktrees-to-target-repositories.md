# worktree は対象リポジトリごとに分ける

Date: 2026-09-12

同一 repo の並行作業は worktree で分離し、別 repo の仕事は対象 checkout を専有する。cwd だけでは別 checkout への誤書き込みを防げないため、Claude Code の Edit/Write をガードする。これは Bash、MCP、Codex や cwd 自体の変更を隔離する sandbox ではない。

設定適用では `mkOutOfStoreSymlink` が本体を指す既存の例外を維持する。ignore 対象の成果物は自動共有せず、必要なものを報告して引き継ぐ。
