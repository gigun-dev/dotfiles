サブエージェントが残した git worktree を掃除する。

実体は `~/ghq/github.com/gigun-dev/dotfiles/scripts/worktree-sweep.sh`。
判定ロジックはスクリプト側にあるので、ここで作り直さずそれを呼ぶこと。

## 手順

1. まず判定だけ実行して結果を見せる(引数はそのまま渡す。無ければカレントリポジトリ)。

   ```bash
   ~/ghq/github.com/gigun-dev/dotfiles/scripts/worktree-sweep.sh $ARGUMENTS
   ```

2. 「残す」と判定されたものを一覧で報告する。未取込のコミットや未コミット変更が
   そこにあるという意味なので、消してよいかはユーザーにしか決められない。
3. 対象のエージェントが終了していることと、必要な ignore 成果物を引き継いだことを確認する。
   削除は `--apply` を付けて実行する。**ユーザーが承認してから**。

## 引数

- 無し: カレントリポジトリ
- `--all`: ghq 配下で worktree を持つ全リポジトリ
- パス: そのリポジトリだけ

## 注意

- `--apply` は worktree のディレクトリとブランチを消す。未追跡・ignore 成果物、lock、
  未取込 commit、Git の判定失敗があれば保持する。unlocked の稼働中 agent は検出できず、
  判定直後の ignore ファイル生成とも競合するため、**停止済みの作業だけを対象にする**。
- 取込済みの判定は基準 commit の祖先であること。squash や cherry-pick の同等性は推測しない。
- 「残す」が多いときは、掃除ではなく取り込みの問題。マージするか捨てるかを先に決める。
