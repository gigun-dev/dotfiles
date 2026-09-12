# worktree は対象リポジトリで分け、書き込みガードと成果物の引き継ぎを併用する

Date: 2026-09-12

2026-09-11 の調査では worktree を割り当てられた 24/32 体の cwd は worktree 内にあったが、8 体が本体 checkout に Edit/Write しており、別 repo の実装では呼出元の worktree が使われなかった（[調査元](https://github.com/gigun-dev/claude-code/blob/main/docs/telemetry/2026-09-11-subagent-time-breakdown.md)）。同じ repo では既存の worktree 隔離を維持し、利用者の裁定でまず別 checkout への Edit/Write をガードする一方、別 repo の仕事は専用 agent を対象 checkout に向けて呼出元の worktree を作らず、対象 checkout を別の書込作業と共有しない。理由は cwd だけでは書込先を守れず、使わない worktree は隔離の役に立たないためで、dotfiles の設定適用時は mkOutOfStoreSymlink が本体を指す既存の隔離なし例外を維持する。

Rejected: 依頼文へ毎回注意事項を追加するだけの運用。既存の todo に記録された指示漏れを、定義とガードへ移す。

Rejected: 全 worktree の build と ignore ファイルを自動共有する。設定の混線と必要な成果物の取りこぼしを避けるため、子が相対パス・用途・受渡し要否を報告し、親が必要なものを引き継ぐ。

このガードは Claude Code の Edit/Write の誤操作対策であり、Bash、MCP、Codex、cwd 自体を本体へ変更した場合まで隔離する sandbox ではない。独立したセッションの書込み制御と実エージェントでの受入は別途検証する。掃除は停止済みの作業だけを対象にし、ignore ファイル、未取込変更、lock、判定失敗があれば保持する。
