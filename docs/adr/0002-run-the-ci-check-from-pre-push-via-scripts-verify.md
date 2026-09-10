# pre-push は scripts/verify.sh 経由で CI と同一の検証を実行する

Date: 2026-09-10

main の branch protection は repo admin (= 本人と Claude Code) の直 push でバイパスできるため (`todo.txt` の `old:DF-40`)、壊れたコードが main に入るのを実際に止めているのは手元の pre-push フックである。従来のフックは harness 配布物 (harness-template v0.4.0) で、検証コマンドが `nix flake check --no-build && nix fmt -- --ci .` とフック本体に直書きされており、`--no-build` の有無が CI (`.github/workflows/nix-build.yaml`、`--no-build` を**付けない**ことを明記) と食い違っていた。harness の撤去 (`docs/adr/0001-keep-tasks-in-todo-txt-and-decisions-in-docs-adr.md`) に合わせてフックを配布物から自前のものに置き換え、検証の中身は `scripts/verify.sh` に 1 か所へまとめて、フックはそれを `exec` するだけにする。理由は、CI とフックが同じスクリプトを指していれば食い違いが構造的に起きないこと、および複合コマンドをフックのシェル構文 (`if ! { a && b; }` のグループ化) に埋め込む必要が無くなること。

Considered Options:

- **`--no-build` を残して速さを取る** —— 却下。2026-09-10 の実測で aarch64-darwin の全 `nix flake check` は 20 秒、`nix fmt -- --ci .` は 8 秒であり、`--no-build` (実測 12 秒) との差は push を待つ体感を変えない。CI と揃える価値の方が大きい。
- **pre-push を廃止して GitHub 側の required CI だけに任せる** —— 却下。required CI は admin の直 push で強制されない (`old:DF-40`) ので、いま歯止めとして効いているのは手元のフックだけ。`old:DF-40` が閉じるまでは外せない。
- **フックを `.githooks/` へ移す (pre-push スキルの既定)** —— 却下。このリポジトリは既に `core.hooksPath = git/hooks` で pre-commit (staged な `.nix` の自動整形) を動かしており、`core.hooksPath` は 1 つしか持てないので切り替えるとその pre-commit が無言で死ぬ。

Consequences:

- `core.hooksPath` は `.git/config` に入るため git 管理されない。clone ごとに `git config core.hooksPath git/hooks` が 1 回必要という条件は従来どおり続く。
- harness の自己テスト口 (`HARNESS_PREPUSH_SELFTEST`) は無くなる。フックの生死は `VERIFY_FORCE_FAIL=1 git push` で確かめる (`scripts/verify.sh` が必ず失敗する口)。
- 検証はいま作業ツリーで走る。push するコミットと検査した内容が一致する保証はない (この性質は従来のフックと同じ)。
