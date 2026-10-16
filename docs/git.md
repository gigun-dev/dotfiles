# Git の構成

このリポジトリが git まわりに持つもの全部の見取り図。個々の判断の理由はコメントと ADR にあり、ここでは「何がどこにあって、いつ効くか」をまとめる。

## 設定の置き場所

| 対象 | 定義 | 適用先 |
|------|------|--------|
| Mac / Linux (nix) | `nix/modules/home/programs/git/default.nix` (home-manager `programs.git`) | `~/.config/git/config` |
| Windows | `git/gitconfig` | `~/.gitconfig` へ symlink (`windows/configuration.dsc.yaml`) |
| global ignore | `git/ignore` | `~/.config/git/ignore` へ symlink (nix は `dotfiles.nix`、nix なしは `bootstrap.sh`) |
| フック | `git/hooks/` | このリポジトリの `core.hooksPath` (`bootstrap.sh` が設定) |

`git/gitconfig` を張るのは Windows だけ (bootstrap.sh は張らない)。設定を足したら nix 側と `git/gitconfig` の両方に書く。nbstripout の filter と plist の textconv は store のパスや macOS 専用コマンドを指すので nix 側のみ。

## 設定の一覧

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

## attributes と nbstripout

`*.ipynb filter=nbstripout diff=ipynb` を全リポジトリに掛ける (nix 側のみ)。notebook は Colab と VS Code の交互保存で execution_count 等の書き換えだけの差分が出るので、commit 時に落とす。出力は残す。`required = true` なので filter が失敗すると commit も止まる。理由の詳細は `default.nix` のコメント。

## フック (`git/hooks/`)

`core.hooksPath = git/hooks` はこのリポジトリのローカル設定で、`bootstrap.sh` が書く。

- `pre-commit` — stage 済みの `.nix` を `nix fmt` で整形して stage し直す。CI の `nix fmt -- --ci` を落とさないため。nix が無ければ何もしない。
- `post-merge` / `post-rewrite` / `post-checkout` — どれも `switch-on-nix-change` を呼ぶ。pull・rebase・branch 切替で `flake.nix` / `flake.lock` / `nix/` が変わったら `nix run .#switch` を実行する。main の主 checkout だけで動き、linked worktree・feature branch・NixOS (mini-vm) では何もしない。rebase / merge の途中は最終状態だけを見る。`DOTFILES_SKIP_AUTO_SWITCH=1` で抑止できる。
- pre-push は無い。設計は [ADR 0011](adr/0011-push-without-a-local-gate-and-apply-only-green-commits.md)。

## ignore は 2 層

- **global (`git/ignore`)** — OS のゴミ (github/gitignore の `Global/macOS` と `Global/Linux` を commit 固定でそのまま)、`.direnv/`、Claude Code のローカルファイル (`settings.local.json`、`worktrees/`、`CLAUDE.local.md`)。どのリポジトリにも要るものだけ。Python などの言語テンプレートは入れない。`lib/` `build/` `dist/` `.env` `.python-version` のような広いパターンが、他のリポジトリで追跡したいファイルを黙って隠すため (`.python-version` は `docs/python.md` で commit する前提)。テンプレートを更新するときは `git/ignore` の見出しの commit sha ごと差し替える。
- **リポジトリの `.gitignore`** — このリポジトリ固有のもの (`result`、`tofu/` の state、`.claude/plans/`、`.envrc.local`、`__pycache__/`、Windows 用の `Thumbs.db`)。global が無い clone でも最低限守る必要のあるものはここ。

## 日々の流れ

1. 変更を意味のある最小の単位で commit する。
2. `git pull --rebase` してから main へ直接 push する。待たずに push し、検証は push 後の CI が行う ([ADR 0011](adr/0011-push-without-a-local-gate-and-apply-only-green-commits.md))。
3. mini-vm が `flake.lock` の更新を PR で出して自動 merge するので、手元は定期的に pull する ([ADR 0003](adr/0003-update-mini-vm-through-lock-proposal-prs.md))。pull が nix の変更を取り込むと、フックが switch まで走らせるので長くなる。
4. mini-vm の `dotfiles-autoswitch` は main の HEAD の CI が green のときだけ適用する。red なら次の push で直す。詳細は [mini-vm.md](mini-vm.md)。
5. 手元で lock を更新するなら `nix run .#update` (pull、update、switch、lock の commit まで)。push は手で行う。

nix は git index から評価するので、switch / build の前には対象ファイルを `git add` する。

## エージェント向けの規則

`claude/CLAUDE.md` と `codex/AGENTS.md` (どちらも全リポジトリに配布される) に書いてある。人間は `git add .` を使ってよく、これはエージェントだけの規則。

- stage は `git add <path>` の明示パスだけ。`git add .` / `-A` / `-u`、`git commit -a`、対話的な `-p` は使わない。無関係な変更や commit したくないファイルを巻き込むため。
- index は信用しない。switch / build のためだけに stage されたファイルが残っていることが多い。commit 前に `git diff --cached --stat` で確認し、単位の外を unstage する。
- 単独で revert できる最小の単位に分けて commit する。push 済みの commit の修正は追加 commit にし、amend は未 push のものだけ。

(staging の規則は ryoppippi の `agents/shared/git-staging.md` を参考にした。)
