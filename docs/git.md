# Git と GitHub の使い方

このリポジトリの環境で git / GitHub をどう使うか。前半が手順、後半が設定の見取り図。個々の判断の理由はコメントと ADR にある。

## 1. 日々の流れ (dotfiles)

```bash
$EDITOR ...
git add .                    # nix は git index から評価する。switch / build の前に必須
nix run .#build              # 適用せず確認 (適用するなら nix run .#switch)
git commit                   # pre-commit が stage 済みの .nix を nix fmt する
git pull                     # 先に取り込む。nix の変更が入るとフックが switch まで走る
git push                     # 待たずに push。検証は push 後の CI
gh run list -b main -L 3     # CI (CI: Nix check) の結果
gh run watch                 # 走っている run を待つ
```

- `git pull` は `pull.rebase = true` により rebase で取り込む。GitHub の新しい commit の後ろに、手元の未 push の commit を付け直す。merge commit を作らないので履歴が 1 本に並ぶ。push 済みの履歴や他人の commit は書き換えない。
- commit は意味のある最小の単位。push 済みの修正は追加 commit。
- main へ直接 push する。手元に pre-push は無く、CI が red なら直すまでが作業 ([ADR 0011](adr/0011-push-without-a-local-gate-and-apply-only-green-commits.md))。
- mini-vm が `flake.lock` の更新を PR で出し、required CI を通して自動 merge する ([ADR 0003](adr/0003-update-mini-vm-through-lock-proposal-prs.md))。手元は定期的に `git pull` するだけでよい。
- mini-vm の `dotfiles-autoswitch` は main の HEAD の CI が green のときだけ適用する。red なら次の push で直す。詳細は [mini-vm.md](mini-vm.md)。
- 手元で lock を更新するなら `nix run .#update` (pull、flake update、switch、lock の commit まで。push は手で)。AI ツールだけなら `nix run .#update-ai-tools`。
- 溜めない。mini-vm が origin/main へ merge し続けるので、手元に溜めると ahead/behind に分岐する。

### pull で起きること (フック)

`core.hooksPath = git/hooks` はこのリポジトリのローカル設定で、`bootstrap.sh` が書く。

| フック | 動作 |
|--------|------|
| `pre-commit` | stage 済みの `.nix` を `nix fmt` して stage し直す。CI の `nix fmt -- --ci` を落とさないため。nix が無ければ何もしない |
| `post-merge` / `post-rewrite` / `post-checkout` | `switch-on-nix-change` を呼ぶ。`flake.nix` / `flake.lock` / `nix/` が変わっていたら `nix run .#switch` を実行する |
| pre-push | 無い |

`switch-on-nix-change` の条件:

- main の主 checkout だけで動く。linked worktree・feature branch・NixOS (mini-vm) では何もしない。
- rebase / merge の途中は最終状態だけを見る。
- `DOTFILES_SKIP_AUTO_SWITCH=1` で抑止できる。
- 端末の有無は見ない。エージェントや Fork からの pull でも switch し、Touch ID の確認が出る。認証できなくても pull は成功のまま残る。

## 2. 困ったとき

### pull が conflict で止まった

手元と GitHub が同じ行を変えていると、git はどちらを残すか決められず、両方をファイルに並べて止まる。

1. `git status` で conflict のファイルを見る。
2. ファイルを編集する。マーカーは zdiff3 形式で、`<<<<<<<` (手元側) / `|||||||` (共通祖先) / `=======` / `>>>>>>>` (取り込んだ側) が出る。共通祖先との差分で両側の意図を読む。
3. `git add <path>` → `git rebase --continue`。
4. 諦めるなら `git rebase --abort` (pull 前に戻る)。

- `rerere` が直し方を記録する。`--abort` してやり直したときなど、同じ conflict は次から自動で直され、`autoupdate` で add まで済む。commit はされないので、`git diff --cached` で確かめてから `--continue` する。記録の確認・破棄は `git rerere status` / `diff` / `forget <path>`。
- `rebase.autoStash` により、dirty でも pull は止まらない。rebase 後に stash が戻り、そこで conflict したら通常の conflict として解く。
- rebase の途中は switch フックが動かない。`--continue` で完了したときに final 状態で判定される。

### ahead / behind に分岐した

`git status -sb` で `[ahead N, behind M]` が出る。`git pull` で手元の commit を origin の上に付け直し、その後 push。

### force push が要るとき

rebase や amend で push 済みの履歴を書き換えた branch だけ。main には使わない。

```bash
git push --force-with-lease --force-if-includes
```

- `--force-with-lease`: 最後に fetch した状態から origin が動いていなければ上書きする。
- `--force-if-includes`: fetch したが取り込んでいない他人の push があれば拒否する。`push.useForceIfIncludes` で既定にしてあり、`--force-with-lease` だけでも効く。
- 素の `--force` は使わない。

### 取り消し

| 状況 | コマンド |
|------|----------|
| 未 push の commit を取り消して変更は stage に残す | `git reset --soft HEAD~1` |
| 未 push の直前 commit に足す | `git commit --amend` |
| working tree の変更を捨てる | `git restore <path>` |
| stage だけ外す | `git restore --staged <path>` |
| push 済みの commit を打ち消す | `git revert <commit>` (打ち消す commit が増える。履歴は書き換えない) |

`--hard` は未 commit の変更を失う。使う前に `git status` を見る。

### branch の掃除

```bash
git fetch --prune                    # 消えた remote branch の追跡 ref を落とす (fetch.prune で pull 時にも走る)
git branch --merged main             # main に入った local branch
git branch -d <branch>               # merge 済みなら削除 (未 merge は -D で強制)
git push origin --delete <branch>    # remote branch の削除
```

## 3. GitHub

### 認証

```bash
gh auth login        # 1 回。以後 git の push / pull も通る
gh auth status
```

`credential.helper = gh auth git-credential` なので SSH key は管理しない。remote は HTTPS。

### repo の置き場所 (ghq)

`ghq root` は `~/ghq`。repo は `~/ghq/github.com/<owner>/<repo>` に置く。`ghq.user = gigun-dev` が `ghq get` / `ghq create` の既定 owner。

| やりたいこと | コマンド |
|--------------|----------|
| 取得する | `ghq get <owner>/<repo>` (`-u` で既存を更新、`-p` で SSH clone) |
| 一覧 | `ghq list` |
| 新規作成 (まず local だけ) | `ghq create <repo>` |
| 後から GitHub に公開 | repo の中で `gh repo create --source . --private --push` |

`gh repo create` の `--private` / `--public` / `--internal` はどれか 1 つが要る。

### 他人の repo への PR

```bash
ghq get <owner>/<repo>
git switch -c <branch>
# 編集・commit (merged PR の様式に合わせる)
git push                                         # push.autoSetupRemote で upstream を自動設定
gh pr create --title "..." --body-file <path>    # --draft で下書き
gh pr checks                                     # 現在の branch の PR の CI
gh run watch                                     # 走っている run を待つ
```

fork が要る repo は `gh repo fork` を使う。本文は `--body-file` に書いたファイルから渡す (シェルのクォートを避けるため)。

### dotfiles の CI

workflow は `CI: Nix check` (`.github/workflows/nix-build.yaml`)。

```bash
gh run list -b main -L 5
gh run watch <run-id>
gh run view <run-id> --log-failed
```

### 入っているツール

`gh` と `ghq` だけが `packages.nix` にある。`gh extension list` は空 (2026-10-16 確認)。拡張を前提にした手順は書かない。

## 4. エージェントの規則

`claude/CLAUDE.md` と `codex/AGENTS.md` (どちらも全リポジトリに配布される) に書いてある。エージェント向けで、人が `git add .` を使うのは自由。

- commit 前に `git status --short --untracked-files` (`=no` にしない) と `git diff --cached --stat` で全体を確認する。
- switch / build のためだけに stage されたファイルが残っていることが多い。単位の外は unstage する。
- 1 ファイルに別々の変更が混ざっていたら `git add -p` で分ける (エージェントは答えを stdin で渡す)。
- `--no-verify` で hook を飛ばさない。
- 単独で revert できる最小の単位に分けて commit する。push 済みの commit の修正は追加 commit にし、amend は未 push のものだけ。

(staging の規則は mozumasu の `git-commit` スキルを元にした。)

## 5. 未決事項

ユーザーと議論中で、まだ決まっていないもの (2026-10-16 時点)。

- **(a) mozumasu の zeno / zsh helper の採用** — `ghq get` の補完、gibo + fzf による gitignore 生成、`gh run` の補完。

## 6. 設定リファレンス

### 設定の置き場所

| 対象 | 定義 | 適用先 |
|------|------|--------|
| Mac / Linux (nix) | `nix/modules/home/programs/git/default.nix` (home-manager `programs.git`) | `~/.config/git/config` |
| Windows | `git/gitconfig` | `~/.gitconfig` へ symlink (`windows/configuration.dsc.yaml`) |
| global ignore | `git/ignore` | `~/.config/git/ignore` へ symlink (nix は `dotfiles.nix`、nix なしは `bootstrap.sh`) |
| フック | `git/hooks/` | このリポジトリの `core.hooksPath` (`bootstrap.sh` が設定) |

`git/gitconfig` を張るのは Windows だけ (bootstrap.sh は張らない)。設定を足したら nix 側と `git/gitconfig` の両方に書く。nbstripout の filter と plist の textconv は store のパスや macOS 専用コマンドを指すので nix 側のみ。

### 設定の一覧

(ryoppippi) は [ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles) から取り入れたもの。

| キー | 理由 |
|------|------|
| `pull.rebase` | pull で merge commit を作らない |
| `push.autoSetupRemote` | 新しい branch の初回 push で upstream を自動設定 |
| `push.useForceIfIncludes` (ryoppippi) | force push が、まだ取り込んでいない他人の push を上書きしないようにする |
| `rebase.autoStash` (ryoppippi) | 作業ツリーが dirty でも `pull --rebase` が止まらない |
| `rebase.autoSquash` (ryoppippi) | `fixup!` / `squash!` commit を rebase 時に自動で畳む |
| `rebase.updateRefs` (ryoppippi) | 積んだ branch の途中の ref も rebase に追従させる |
| `rerere.enabled` / `autoupdate` (ryoppippi) | 解いた conflict を記録し、同じ conflict を二度解かない |
| `merge.conflictstyle = zdiff3` (ryoppippi) | conflict に共通祖先を出し、解決の手掛かりを増やす |
| `diff.algorithm = histogram` (ryoppippi) | 既定より読みやすい diff を出す |
| `diff.colorMoved = plain` (ryoppippi) | 移動しただけの行を別色にする |
| `fetch.prune` (ryoppippi) | 消えた remote branch の追跡 ref を掃除する |
| `remote.origin.pruneTags` (ryoppippi) | origin だけ tag も掃除する。global の `fetch.pruneTags` にしないのは、release tag を持たない fork remote を fetch したときに手元の tag が消えるため (ryoppippi の f624e326) |
| `credential.helper` | `gh auth git-credential` に統一し、`gh auth login` 1 回で push/pull が動く |
| `user.*` / `ghq.user` / `init.defaultBranch` | 識別と ghq の既定 |

### attributes と nbstripout

`*.ipynb filter=nbstripout diff=ipynb` を全リポジトリに掛ける (nix 側のみ)。notebook は Colab と VS Code の交互保存で execution_count 等の書き換えだけの差分が出るので、commit 時に落とす。出力は残す。`required = true` なので filter が失敗すると commit も止まる。理由の詳細は `default.nix` のコメント。

### ignore は 2 層

- **global (`git/ignore`)** — OS のゴミ (github/gitignore の `Global/macOS` と `Global/Linux` を commit 固定でそのまま)、`.direnv/`、Claude Code のローカルファイル (`settings.local.json`、`worktrees/`、`CLAUDE.local.md`)。どのリポジトリにも要るものだけ。Python などの言語テンプレートは入れない。`lib/` `build/` `dist/` `.env` `.python-version` のような広いパターンが、他のリポジトリで追跡したいファイルを黙って隠すため (`.python-version` は `docs/python.md` で commit する前提)。テンプレートを更新するときは `git/ignore` の見出しの commit sha ごと差し替える。
- **リポジトリの `.gitignore`** — このリポジトリ固有のもの (`result`、`tofu/` の state、`.claude/plans/`、`.envrc.local`、`__pycache__/`、Windows 用の `Thumbs.db`)。global が無い clone でも最低限守る必要のあるものはここ。
