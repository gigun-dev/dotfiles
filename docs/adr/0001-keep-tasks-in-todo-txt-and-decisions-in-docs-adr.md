# タスクは todo.txt に、決定は docs/adr に置く

Date: 2026-09-10

このリポジトリは長く harness (gigun-dev/claude-code の plugins/harness) の方式 —— `docs/next-directions.md` を「正典」とし、その「頭」を SessionStart フックで毎セッション注入する —— でタスクと現在地を管理してきたが、正典が予算制の 1 ファイルに集中するため、注入の切り詰め・肥大化検知・鮮度検知といった**機構を守るための機構**が増え続けていた (経緯は `docs/harness-retired.md`)。利用者の裁定により harness を撤去し、タスクは `todo.txt` / `done.txt` (todo スキルと同梱 CLI)、覆すのに費用のかかる決定は `docs/adr/` (adr スキル) に置く方式へ移行する。理由は、どちらも 1 行 / 1 ファイルが独立していて予算制の注入を必要とせず、形式の検査 (`todo check` / `adr check`) が書き込みのたびに走るため、検知器を自作して保守する必要が無いこと。

`DF-6`「意思決定 (ADR) の置き場所について harness の結論を取り込む」はこの ADR で決着した。

Considered Options:

- **harness を継続する** —— 却下。切り詰め警告が切り詰めで消える型の事故 (`docs/harness-retired.md`) を含め、正典 1 ファイルへの集中が生む失敗が繰り返し起きていた。
- **`docs/next-directions.md` を「正典」の位置づけのまま残し、todo.txt と併用する** —— 却下。タスクの置き場が二重になり、どちらが最新かを人が判断し続けることになる。

Consequences:

- 旧タスク `DF-*` は `todo.txt` の各行へ移し、`old:DF-NN` で旧 ID との対応を残した。完了済みの記録は `docs/task-archive.md` に残り、`DF-*` の番号は再利用しない。
- 旧正典の調査メモは主題ごとに `docs/mini-vm.md` / `docs/notifications.md` / `docs/cloudflare-os.md` へ分散した。「いま何が動いているか」の常時ロードは `CLAUDE.md` だけが担う。
- セッション開始時に現在地が自動注入されなくなる。次のセッションは `todo ready` を自分で読む必要がある。
