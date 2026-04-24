# Dotfiles

gigun の macOS + Windows 開発環境を宣言的に管理する dotfiles。
nix-darwin + home-manager を基盤とし、nix なしでも最低限動作する設計。Windows は `windows/` 配下で PowerShell + winget で同等の宣言管理を実現する。

## コマンド

```bash
git add . && nix run .#switch  # 変更を適用
nix run .#build                # ビルドのみ（適用しない）
nix run .#update               # flake update + switch
```

**重要**: nix は git index から評価するため、`nix run .#switch` の前に必ず `git add` すること。

## 対象マシン

| マシン | アーキテクチャ | 管理 |
|--------|-------------|-----|
| Mac Mini (Intel) | x86_64-darwin | 標準 nix (nix-darwin + home-manager) |
| MacBook Pro (M4 Pro) | aarch64-darwin | 標準 nix (nix-darwin + home-manager) |
| Windows 11 機 | x86_64-windows | `windows/setup.ps1` (winget configure で DSC YAML 適用)、WSL2 内で home-manager standalone |

`darwinConfigurations` はアーキテクチャ別に生成し、`nix run .#switch` が perSystem で自動選択する。Windows は `windows/setup.ps1` を管理者権限の PowerShell で実行して適用する。

## ディレクトリ構造

```
├── flake.nix                # エントリポイント
├── bootstrap.sh             # nix なしの初期セットアップ
├── nix/modules/
│   ├── darwin/
│   │   ├── system.nix       # macOS 設定（nix.settings, TouchID, system.defaults）
│   │   └── homebrew.nix     # casks / brews
│   └── home/
│       ├── default.nix      # home-manager エントリ
│       ├── packages.nix     # home.packages（グローバル CLI）
│       ├── dotfiles.nix     # シンボリックリンク（mkOutOfStoreSymlink + home.activation）
│       └── programs/
│           ├── zsh/         # programs.direnv（programs.zsh は nix-darwin 側で管理）
│           └── git/         # programs.git + programs.delta
├── zsh/
│   ├── .zshrc               # メイン設定（nix 非依存）
│   └── functions/            # zsh 関数（ghq_fzf 等、permission は 755 必須）
├── sheldon/plugins.toml      # sheldon プラグイン定義
├── zeno/config.yml           # zeno snippets
├── zed/keymap.json           # Zed エディタ keymap (Mac/Win 共通、Cursor 風 Cmd+J/L)
├── git/gitconfig             # .gitconfig 実体 (Windows は DSC Script で symlink、Mac/Linux は programs.git で生成)
└── windows/                  # Windows 11 用（詳細: windows/README.md）
    ├── configuration.dsc.yaml # Single source of truth (winget configure)
    ├── setup.ps1             # winget configure を呼ぶ薄いラッパ
    ├── fonts/install.ps1     # JetBrains Mono Nerd Font
    ├── hotkey/
    │   └── mac-like.ahk      # Scancode Map + Mac 風 modifier + IME 変換 + WezTerm トグル
    ├── kanata/kanata.kbd     # karabiner.json から移植 (現状未使用、将来 device 別 remap 用)
    ├── tailscale/            # MSI 導入 + unattended mode 有効化
    ├── tools/
    │   └── keyboard-probe.ahk # 物理 VK/SC 実測ツール
    ├── wsl/wslconfig         # WSL2 設定の実体
    └── terminal/wezterm.lua  # WezTerm 設定の実体
```

## 設計原則

- **nix はオプション強化レイヤー**: 設定ファイル自体は nix に依存しない
- **bootstrap.sh と dotfiles.nix は同じことをする**: 後者が前者を自動化するだけ
- **brew は GUI アプリのみ**: CLI ツールは nixpkgs、tap 限定の例外のみ brews
- **cleanup = "zap"**: 宣言外のアプリは完全削除。使う GUI アプリは必ず casks に宣言する
- **ensure_installed パターン**: ツールが未インストールなら静かにスキップ
- **`~/.local/bin` は例外レーン**: PATH 末尾に追加（nix/brew が常に優先）。self-update 前提のツールや nixpkgs にない uv tool 等、宣言管理できないものだけ許容する

## Nix 規約

- **標準 nix を使用**: Determinate Nix は使わない（ryoppippi パターン）
- **nix.settings で全て宣言**: trusted-users, キャッシュ, experimental-features 等
- **フォーマット**: `treefmt`（nixfmt）を使用
- **nixpkgs.follows を全 input で統一**: キャッシュ共有を最大化
- **useGlobalPkgs = false**: overlay との整合性（flake.nix で設定）
- **mkOutOfStoreSymlink**: nix store にコピーせず dotfiles リポを直接参照
- `.zshrc` は `home.activation` で強制リンク（`programs.zsh` は home-manager 側では使わない）
- **AI ツール**: claude-code は ryoppippi overlay、codex 等は llm-agents overlay（`pkgs.llm-agents.*`）

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

## Windows 規約

- **宣言的構成**: `windows/configuration.dsc.yaml` を single source of truth とし、`winget configure` で冪等適用する。Mac 側の `nix run .#switch` 相当
- **軽量化は dotfiles 責務**: Mac の `system.nix` と同じ論理で、Windows の UI/パフォーマンス設定を DSC YAML の `PSDscResources/Registry`・`Service`・`Script` リソースで宣言
- **winget 一本化**: Scoop / Chocolatey は不採用。winget / msstore にないものだけ DSC `Script` で直接 download + install
- **WSL2 に寄せる**: Windows ネイティブは最小限（ターミナル、エディタ、ブラウザ、GUI アプリ）。CLI 開発は WSL 内で `packages.nix`（x86_64-linux）を適用して Mac と同等の環境にする
- **エディタは Pattern A (Win native + Remote-WSL)**: VSCode / Cursor / Zed は全て Windows native install + 組込 Remote-WSL 機能で使用 (2026 公式推奨)。Linux 版 WSLg は GPU/IME/起動速度で劣るため不採用。keymap は dotfiles で symlink 共有 (Mac は brew cask + home-manager、Win は DSC Script で `%APPDATA%\Zed\keymap.json` 等へ)
- **AI tools は WSL 集約**: `claude-code` / `codex` / `opencode` / `ccstatusline` は nix (`packages.nix`) で WSL 側に。Windows native には入れない方針
- **git auth 統一**: 全 OS で `gh auth login` 1 回 + `credential.helper = '!gh auth git-credential'`。SSH key 管理しない (url rewrite で SSH URL が混入しても HTTPS に変換する手もあるが現在は未採用)
- **ブラウザ自動化 (CDP)**: Chrome 136+ は `--user-data-dir` 必須。`--remote-debugging-port=9222 --user-data-dir=%LOCALAPPDATA%\Google\Chrome Dev` で起動し、WSL から `localhost:9222` で接続 (`networkingMode=mirrored` 前提)。agent-browser は `--cdp 9222`、headed で開くには `tab new https://...`（`open` は Playwright 内部コンテキストで Chrome タブに出ない）
- **Tailscale**: MSI デフォルト構成（GUI + daemon + CLI）を尊重。Unattended mode を有効化して daemon 単体で接続継続可能に
- **フォント**: Mac と同じ JetBrains Mono Nerd Font をユーザースコープで配置
- **シンボリックリンク**: DSC Script リソースが `.wslconfig` / `.wezterm.lua` / `kanata.kbd` / `.gitconfig` / Zed `keymap.json` を `windows/` または dotfiles ルート配下から張る（nix の `mkOutOfStoreSymlink` 相当）
- **補助 .ps1 は DSC から呼ばれる**: `fonts/install.ps1` / `tailscale/install-daemon.ps1` は個別実行用ではなく、DSC Script リソースからの呼び出し前提。単独実行してもエラーにならないよう冪等に書く

## Git ワークフロー

- メインブランチ: `main`
- サブエージェントを活用すること

## 参考

- [ryoppippi/dotfiles](https://github.com/ryoppippi/dotfiles)
- [mozumasu/dotfiles](https://github.com/mozumasu/dotfiles)
