# Dotfiles

gigun の macOS + Windows 開発環境を宣言的に管理する dotfiles。
nix-darwin + home-manager を基盤とし、nix なしでも最低限動作する設計。Windows は `windows/` 配下で PowerShell + winget で同等の宣言管理を実現する。

## コマンド

```bash
nix run .#switch              # 変更を適用（新規ファイルは個別に stage）
nix run .#build                # ビルドのみ（適用しない）
nix run .#update               # pull --rebase + flake update + switch + lock を commit (push はしない)
nix run .#update-ai-tools      # 同上。AI ツールの input だけ
```

**重要**: Git flake は未追跡の新規ファイルを含めないため、`nix run .#switch` の前に必要な新規ファイルだけ `git add <path>` すること。switch 用に stage したものが commit に混ざらないよう、エージェントは commit 前に `git diff --cached --stat` で確認する。

**`flake.lock` は main から pull で受け取る**: lock の主な生産者は mini-vm で、定期的に PR で提案し、実機ビルドと required CI を通して自動 merge する。手元は `git pull` するだけでよく、`git/hooks` の post-merge / post-rewrite / post-checkout が flake.nix・flake.lock・nix/ の変化を見て `nix run .#switch` まで走らせる（main の主 checkout でのみ。linked worktree・feature branch・NixOS では何もしない）。手元で lock を更新するときは `nix run .#update` / `update-ai-tools` を使う。pull → update → switch の後に lock をその場で commit するので dirty な lock は残らない。push は手で行う。mini-vm の `dotfiles-autoswitch` は main の HEAD の CI が green のときだけ適用する（red / 未完了は見送って通知）。設計は `docs/adr/0011-push-without-a-local-gate-and-apply-only-green-commits.md`、現在の運用は `docs/mini-vm.md`、残課題は `todo.txt` を参照。

**iTerm2 初回 bootstrap 順序**: `LoadPrefsFromCustomFolder` / `PrefsCustomFolder` は nix 側 (`system.defaults.CustomUserPreferences."com.googlecode.iterm2"`) で system plist に宣言する設計のため、**iTerm2 を起動する前に最初の `nix run .#switch` を完了させる**こと。先に iTerm2 を立ち上げると bootstrap meta key が無く、repo 内 plist が source of truth として読まれない（system plist に書かれた古い設定が継続使用される）。

**キーボード競合**: ショートカットを登録できない、発火しない、別アプリが反応するときは [診断手順](docs/keyboard-conflicts.md) を読む。実入力・受信先PIDの観測を先に行い、候補を絞ってから設定解除や終了比較に進む。

**ディスク容量**: Pro の空きが逼迫したときは [整理の手順書](docs/storage-cleanup.md) を読む。消す前に測り、再生成できるものから順に潰す。Codex の作業フォルダは git worktree を含むため、削除前に確認する。

## 対象マシン

| マシン | アーキテクチャ | 管理 |
|--------|-------------|-----|
| MacBook Pro (M4 Pro) | aarch64-darwin | 標準 nix (nix-darwin + home-manager) |
| Mac Mini (Intel) — macOS | x86_64-darwin | **nix 管理を凍結**（下記参照）。Finder 経由の iPhone バックアップ・画面共有・Xcode 26.3 用 |
| Mac Mini (Intel) — Lima ゲスト | x86_64-linux | `nixosConfigurations.mini-vm` + home-manager standalone。24/365 のエージェント基盤 |
| Windows 11 機 | x86_64-windows | `windows/setup.ps1` (winget configure で DSC YAML 適用)、WSL2 内で home-manager standalone |

`darwinConfigurations` はアーキテクチャ別に生成し、`nix run .#switch` が perSystem で自動選択する。Windows は `windows/setup.ps1` を管理者権限の PowerShell で実行して適用する。

### Mac Mini (Intel) の macOS を nix 管理から外した理由

nixpkgs 26.11 が x86_64-darwin を drop したため。26.05 固定での延命は nixpkgs / home-manager / nix-darwin の 3 つを固定する必要がある上、llm-agents が x86_64-darwin 非対応で AI ツールは結局入らない。2026年末で切れる延命に複雑度を払わない判断。

macOS 側は generation 26 を移行中の依存として残し、[Ansible で対象別に管理を引き継ぐ](docs/mini-ansible.md)。
`ansible/mini-macos` は初期準備段階で、実機移管済みではない。Pro / mini-vm の Nix は継続する。Xcode 26.3 + iOS 26.2 SDK は動くので iOS ビルドには使える（26.4 以降は Tahoe 必須なのでここが上限）。

**手で当てたものの現在地**（凍結ホストに在るものはこの一覧から辿る。増やしたらここに足す）:

- **Lima / Tailscale** — brew で手で導入（tailscale は brews に宣言あり・lima は無し [検査: nix/modules/darwin/homebrew.nix]。宣言は M チップ化した日に効く予約で、凍結中の mini には届かない。手順は「Mac Mini / Lima VM 規約」節）
- **network-watchdog（番人）** — `./bootstrap.sh --net-watchdog` で user agent として導入（`~/Library/LaunchAgents/dev.gigun.net-watchdog.plist`、ログ `~/Library/Logs/net-watchdog/`）。nix 側 `network-watchdog.nix`（system daemon / `/var/log/net-watchdog`）とは意図的な二本立て — nix 側は M チップ化した日に `alwaysOn` でそのまま効くので消さない。user agent の弱点は **OS 起動〜自動ログインの数十秒だけ**（[実測 2026-09-04 mini を `sudo shutdown -r now` で再起動] 自動ログインが効き（autoLoginUser=gigun / FileVault Off）、`launchctl` を叩き直さずに `RunAtLoad` で番人が起動、`StartInterval` も 30 秒間隔で正常に回復した。ネットワーク復帰 23 秒 / ssh はその 3 秒後）。⚠️ この窓を消したいならを消すには sudo 1 回: `sudo bash nix/modules/darwin/net-watchdog-system-install.sh`（ログは `/var/log/net-watchdog` へ移る。旧ログは残置）

## ディレクトリ構造

```text
flake.nix / bootstrap.sh        # Nix と Nix なしの入口
nix/modules/{darwin,nixos,home} # OS 層・共通 home-manager
zsh/ / sheldon/ / zeno/         # shell・補完・snippets
git/ / zed/                    # Git・editor 設定
agents/                        # Claude・Codex 共通のグローバル指示 (正本)
claude/                        # 配布する Claude Code 設定
windows/                       # Windows 宣言・bootstrap (windows/README.md)
infra/ / tofu/ / secrets/       # サービス・IaC・暗号化秘密
docs/                          # 現行運用・ADR
```

## 設計原則

- **nix はオプション強化レイヤー**: 設定ファイル自体は nix に依存しない。理由は、Nix を外す途中の mini の macOS と、Nix 導入前の初期 bootstrap が同じ zsh 設定を読むため。mini が最小のシェル設定へ移れば、Pro・mini-vm・WSL ではこの制約を外せる（`docs/adr/0014-shrink-mini-macos-shell-before-removing-nix.md`）
- **bootstrap は初期準備の入口**: Nix 導入済みの Pro は共通 switch へ委譲。Nix なし・凍結ホストの fallback は同じ Guard 正本を使う。手順は `docs/setup.md`
- **brew は GUI アプリのみ**: CLI ツールは nixpkgs、tap 限定の例外のみ brews
- **cleanup = "uninstall"**: 宣言外のアプリをアンインストールする。zap stanza による追加削除は行わない。使う GUI アプリは必ず casks に宣言する
- **ensure_installed パターン**: ツールが未インストールなら静かにスキップ
- **公式 pkg しか無いものは activation で入れる**: brew にも nixpkgs にも無い署名済み pkg (apple/container) は `fetchurl` で hash 固定し、activation で冪等に `installer` を叩く。手作業で入れると新規 Mac のセットアップが再現できなくなる
- **`~/.local/bin` は例外レーン**: PATH 末尾に追加（nix/brew が常に優先）。self-update 前提のツールなど宣言管理できないものだけ許容する。nixpkgs にない Python CLI は `uv/tools.txt` に宣言し、`uv/sync-tools.sh`（home.activation と bootstrap.sh が呼ぶ）が未導入分だけ入れる。更新は Pro の週次 launchd agent（`uv-tool-upgrade`、`sync-tools.sh --upgrade`、失敗は Bark）、宣言外は警告のみ
- **Python は uv に一本化**: 再現が要るものは uv プロジェクト（pyproject.toml + uv.lock + .python-version を commit）、使い捨ては素の `python3` か PEP 723 スクリプト。グローバル pip・pyenv・nix devShell での依存管理はしない。詳細は `docs/python.md`

## Nix 規約

- **標準 nix を使用**: Determinate Nix は使わない（ryoppippi パターン）
- **nix.settings で全て宣言**: trusted-users, キャッシュ, experimental-features 等
- **フォーマット**: `treefmt`（nixfmt）を使用
- **nixpkgs.follows を全 input で統一**: キャッシュ共有を最大化
- **useGlobalPkgs = false**: overlay との整合性（flake.nix で設定）
- **mkOutOfStoreSymlink**: nix store にコピーせず dotfiles リポを直接参照
- `.zshrc` は `home.activation` で強制リンク（`programs.zsh` は home-manager 側では使わない）
- **AI ツール**: claude-code は ryoppippi overlay。codex/opencode 等 llm-agents のツールは **overlay を使わず** `inputs.llm-agents.packages.${system}.*` を `extraSpecialArgs`（引数名 `llmAgents`）で home モジュールへ渡す。overlay 経由だと我々の nixpkgs に対して再ビルドされ numtide キャッシュ（llm-agents 自身の nixpkgs でビルド）にヒットせず毎回ソースビルドになる（codex の Rust フルビルドが顕著）。standalone 参照ならキャッシュ直ヒット
- **キャッシュヒットを壊さない**: overlay で base パッケージを `overrideAttrs` すると上流キャッシュのハッシュと不一致になり、そのパッケージと依存元が全てソースビルドになる。zsh など基盤パッケージは公式 nixpkgs を使い、override を依存グラフへ波及させない
- **個人キャッシュ**: `nix run .#switch`/`update` は Cachix へ自動送信しない。既存の substituter / trusted keys と `cachix` ツールは維持する。送信者・対象・公開範囲は明示的な送信前に別途判断し、通常適用に全 store 送信を混ぜない。

## Zsh 規約

- **sheldon キャッシュ**: `plugins.toml` の mtime でキャッシュ再生成 + `zcompile`
- **config キャッシュ**: ツール init 出力を `$XDG_CACHE_HOME/zsh/config.zsh` にキャッシュ + `zcompile`
- **deferred compinit**: `zsh-defer` で遅延実行 + WSL は同期 fallback (defer が発火しないため)
- **nix store パスを .zshrc に書かない**: ポータビリティのため
- **chpwd フック**: cd 時に `eza -hlF` で自動 ls

### compinit / 補完の落とし穴 (WSL/Nix 固有)

`.zshrc` 内にコメント付きで対処済。変更時は壊さない:
- **`compinit -u`** で insecure check 緩和 (WSL では `~/.config/zsh/functions` 等の symlink target permission に引っかかる)
- **`compinit` を必ず呼ぶ**こと。`.zcompdump` を `source` するだけだと `_comps` 配列が初期化されず補完登録ゼロになる
- **fpath に zsh の Completion サブディレクトリを動的追加**: Nix の zsh は `share/zsh/$VER/functions/Completion/{Base,Unix,Linux,...}` を自動 fpath 追加しない (Mac は nix-darwin の `programs.zsh` が処理)。`.zshrc` で `readlink -f $(command -v zsh)` から検出して追加
- **`dotfiles/zsh/functions` の permission は 755**: 777 だと compinit が insecure 判定で全補完スキップ。git は permission を完全管理できないので、`bootstrap.sh` や home.activation で `chmod -R go-w` する余地あり (TODO)

### zsh の SIGCHLD race（再発時の切り分け）

macOS 26.4 (Tahoe) と zsh 5.9 の組み合わせで、`$(...)` や widget が永久に wait することがあった（`signal_suspend` が `sigprocmask + pause()` の race 実装。upstream master は `sigsuspend` に直し済み）。master を pin する overlay で根治したが、nixpkgs の zsh に戻した（9bbf1a6）ので、今は stock の 5.9 を使う。再発した場合の目印と罠:

- 目印: `exec zsh` した子シェルで ASCII 入力が echo されない、`ghq_fzf` 等の widget で選択後に固まる、pane 分割で溜まった入力が一気に流れる。固まった zsh は `sample <PID> 3` で `getoutput → waitforpid → signal_suspend → pause`（または `bin_read → settyinfo → tcsetattr`）のスタックになる。`zsh --version` が `5.9` なら race 持ち。
- 罠: prompt (Pure / starship) や fast-syntax-highlighting は原因ではない（症状の出方が変わるだけ）。export の sentinel は `exec` で env を継承して誤検知する。
- 戻す条件: 再発したら zsh master を pin する overlay を入れ直す。nixpkgs の zsh が 5.10 以上なら不要。`prev.zsh.version` で自動切替するのは by-name-overlay と無限再帰で衝突するので手動で運用する。ただしこの overlay はキャッシュヒットを壊す点（上の Nix 規約）に注意。

## Mac Mini / Lima VM 規約

Mac Mini (Intel) のエージェント基盤は macOS 上の Lima ゲスト (NixOS) に置く。ホストが Intel なので x86_64 ゲストが vz ドライバでネイティブに動く（変換なし）。

- **Lima は brew で入れる**: macOS 側の nix 管理を凍結しているため nixpkgs からは入れられない。Tailscale と同じ扱い
- **VM 作成時に home パスを揃える**: 既定では `/home/<user>.guest` になる。WSL と同じ `homeConfigurations.gigun-x86_64-linux` を使い回すため `/home/gigun` に合わせる

  ```bash
  limactl start --name=mini-vm --memory 24 --cpus 8 --disk 300 \
    --set '.user.home = "/home/gigun"' github:nixos-lima
  ```
- **OS 層と home 層を分ける**: OS は `nixosConfigurations.mini-vm`、CLI 環境は WSL と共用の `homeConfigurations.gigun-x86_64-linux`。Lima がユーザーを imperative に作る (`users.mutableUsers = true` が必須) ため、home 層を NixOS module 側へ統合しない
- **`mini-vm.nix` の boot / fileSystems は触らない**: nixos-lima が配布するイメージのレイアウトに合わせた固定値。変えるとブートしなくなる
- **`nix run .#switch` は `/etc/NIXOS` で分岐する**: NixOS なら `nixos-rebuild` + home-manager、WSL なら home-manager のみ。どの機械でも同じコマンドで済ませるための分岐
- **Tailscale は `tag:server`**: `sudo tailscale up --ssh --advertise-tags=tag:server --hostname=mini-vm`。タグ無しだと untagged fallback が無いため到達不能。`tag:vm` は ssh ルールが root/ubuntu 限定で `gigun` が入れないため使わない
- **macOS の自動ログインが前提**: `limactl autostart` は LaunchAgent なので、自動ログイン無しだと再起動後に VM が上がらない。FileVault を有効にすると自動ログインが使えなくなり 24/365 運用が崩れる
- **iOS ビルドはホスト側に投げる**: ゲストから `host.lima.internal` 経由で macOS の Xcode を叩く。Xcode / iOS SDK / Simulator / codesign に Linux 代替は無い

## Windows 規約

- **宣言的構成**: `windows/configuration.dsc.yaml` を single source of truth とし、`winget configure` で冪等適用する。Mac 側の `nix run .#switch` 相当
- **軽量化は dotfiles 責務**: Mac の `system.nix` と同じ論理で、Windows の UI/パフォーマンス設定を DSC YAML の `PSDscResources/Registry`・`Service`・`Script` リソースで宣言
- **winget 一本化**: Scoop / Chocolatey は不採用。winget / msstore にないものだけ DSC `Script` で直接 download + install
- **WSL2 に寄せる**: Windows ネイティブは最小限（ターミナル、エディタ、ブラウザ、GUI アプリ）。CLI 開発は WSL 内で `packages.nix`（x86_64-linux）を適用して Mac と同等の環境にする
- **エディタは Pattern A (Win native + Remote-WSL)**: VSCode / Cursor / Zed は全て Windows native install + 組込 Remote-WSL 機能で使用 (2026 公式推奨)。Linux 版 WSLg は GPU/IME/起動速度で劣るため不採用。keymap は dotfiles で symlink 共有 (Mac は brew cask + home-manager、Win は DSC Script で `%APPDATA%\Zed\keymap.json` 等へ)
- **AI tools は WSL 集約**: `claude-code` / `codex` / `opencode` は nix (`packages.nix`) で WSL 側に。Windows native には入れない方針。`ccstatusline` は軽量なので nix pin せず `bunx`/`npx` 都度実行
- **git auth 統一**: 全 OS で `gh auth login` 1 回 + `credential.helper = '!gh auth git-credential'`。SSH key 管理しない (url rewrite で SSH URL が混入しても HTTPS に変換する手もあるが現在は未採用)
- **ブラウザ自動化**: Claude Code からの対話操作は `chrome-devtools-mcp` に一本化 (agent-browser は撤去)。再現可能なスクリプトが要る場合は Puppeteer ではなく Playwright を選ぶ。CDP 接続時は Chrome 136+ で `--user-data-dir` 必須、`--remote-debugging-port=9222 --user-data-dir=%LOCALAPPDATA%\Google\Chrome Dev` で起動し WSL から `localhost:9222` で接続 (`networkingMode=mirrored` 前提)
- **Tailscale**: MSI デフォルト構成（GUI + daemon + CLI）を尊重。Unattended mode を有効化して daemon 単体で接続継続可能に
- **フォント**: Mac と同じ JetBrains Mono Nerd Font をユーザースコープで配置
- **シンボリックリンク**: DSC Script リソースが `.wslconfig` / `.wezterm.lua` / `kanata.kbd` / `.gitconfig` / Zed `keymap.json` を `windows/` または dotfiles ルート配下から張る（nix の `mkOutOfStoreSymlink` 相当）
- **補助 .ps1 は DSC から呼ばれる**: `fonts/install.ps1` / `tailscale/install-daemon.ps1` は個別実行用ではなく、DSC Script リソースからの呼び出し前提。単独実行してもエラーにならないよう冪等に書く

## Git ワークフロー

- メインブランチ: `main`
- 作業完了時は検証済みの変更を意味のある単位でコミットし、`git status` で残る差分を確認する。未コミットのまま完了扱いにしない。保留を指示された変更は除き、コミットしたら同じ作業の中で `git pull --rebase` してから push する。push 前の手元検証フックは無く、検証は push 後の CI が行う（壊れた main は mini-vm には適用されないが、CI が red になったら直すまでが作業）。mini-vm が flake.lock の PR を origin/main へ自動 merge し続けるため、手元に溜めると ahead/behind に分岐する。pull が nix の変更を取り込むと hook が `nix run .#switch`（sudo）を走らせるので、その pull は長くなる。
  nix の変更は commit 前に `nix run .#build` で通ることを確かめる。pull の前に `git fetch` して `git diff --name-only HEAD...origin/main` で `flake.nix` / `flake.lock` / `nix/` が入るかを見て、入るなら Touch ID が出ると先に伝える（pull 自体は避けない）。

- git 設定・フック・ignore の全体像とエージェント向け規則は `docs/git.md`

## 情報の書き分け方針

- **コード = How** / **テスト = What** / **コミットログ = Why** / **コメント = Why not**。
- コメントは必要十分に書く。詳細は `.claude/rules/comments.md`。

## タスクと決定

- タスクは `todo.txt` に置く。扱うときは todo スキルを使う。
- 覆すのに費用のかかる決定は `docs/adr/` に置く。扱うときは adr スキルを使う。

## 参考

- [ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)
- [mozumasu/dotfiles](https://github.com/mozumasu/dotfiles)
