# dotfiles 仕様書

## 概要

gigun の macOS 開発環境を宣言的に管理する dotfiles。
nix-darwin + home-manager を基盤とし、nix なしでも最低限動作する設計。

---

## 対象マシン

| ホスト | 機種 | アーキテクチャ |
|---|---|---|
| Mac Mini | Mac Mini | x86_64-darwin（Intel） |
| MacBook Pro | MacBook Pro | aarch64-darwin（M4 Pro） |

`darwinConfigurations.gigun` として単一設定で両マシンに適用する。

---

## アーキテクチャ

### 3層構造

```
Layer 1: Bootstrap
  - nix 不要
  - bootstrap.sh でシンボリックリンクを作成
  - Xcode CLT のインストール
  - zsh + sheldon + zeno が動けば十分

Layer 2: Nix 管理
  - nix-darwin + home-manager
  - Layer 1 と同じシンボリックリンクを自動化
  - CLI ツール、direnv、mise、git 設定を宣言的に管理

Layer 3: Project scope（dotfiles スコープ外）
  - 各リポジトリの flake.nix + .envrc(use flake)
  - nixpkgs.url は dotfiles と同一にする（キャッシュ共有）
```

### 設計原則

- **nix はオプション強化レイヤー**：設定ファイル自体は nix に依存しない
- **bootstrap.sh と dotfiles.nix は同じことをする**：後者が前者を自動化するだけ
- **nixpkgs.follows を全 input で統一**：キャッシュ共有を最大化
- **brew は GUI アプリのみ**：CLI ツールは nixpkgs、tap 限定の例外のみ brews
- **cleanup = "zap"**：宣言外のアプリは完全削除、宣言的状態を保つ
- **中身は徐々に育てる**：構造は最初から正しく、packages/snippets/casks は最小限から

---

## ディレクトリ構造

```
dotfiles/
├── SPEC.md                    # 本仕様書
├── CLAUDE.md                  # Claude Code 向けガイド
├── flake.nix                  # エントリポイント
├── flake.lock
├── bootstrap.sh               # nix なしでの初期セットアップ
│
├── nix/
│   └── modules/
│       ├── darwin/
│       │   ├── system.nix     # macOS 設定、TouchID、CLT 自動化
│       │   └── homebrew.nix   # casks、brews、masApps
│       └── home/
│           ├── default.nix    # home-manager エントリ
│           ├── packages.nix   # home.packages
│           ├── dotfiles.nix   # シンボリックリンク管理
│           └── programs/
│               ├── zsh/
│               │   └── default.nix  # zsh + direnv 設定
│               └── git/
│                   └── default.nix  # programs.git
│
├── zsh/
│   ├── .zshrc                 # メイン設定（nix 依存なし）
│   └── functions/             # zsh 関数（ghq_fzf 等）
│
├── sheldon/
│   └── plugins.toml           # sheldon プラグイン定義
│
├── zeno/
│   └── config.yml             # zeno snippets（最小限から追加）
│
├── claude/                    # → ~/.claude/（デフォルトパス）
│   ├── settings.json
│   ├── hooks/
│   ├── commands/
│   └── skills/
│
├── nvim/                      # Neovim 設定（旧からコピー）
├── ghostty/                   # Ghostty + cmux 設定（新規）
├── zed/                       # Zed IDE 設定（旧からコピー）
├── cursor/                    # Cursor 設定（旧からコピー）
├── iterm2/                    # iTerm2 設定（旧からコピー、後で個別設定）
├── terminal/                  # macOS ターミナル設定（旧からコピー）
├── ccstatusline/              # ccstatusline 設定（旧からコピー）
├── mise/                      # mise 設定（タスクランナー用途）
├── npmrc                      # npm 設定
└── bunfig.toml                # Bun 設定
```

---

## flake.nix 仕様

### 構造

flake-parts を使用。ryoppippi パターン準拠。

### inputs

| input | url | follows |
|---|---|---|
| nixpkgs | github:nixos/nixpkgs/nixpkgs-unstable | — |
| flake-parts | github:hercules-ci/flake-parts | — |
| nix-darwin | github:LnL7/nix-darwin | nixpkgs |
| home-manager | github:nix-community/home-manager | nixpkgs |
| treefmt-nix | github:numtide/treefmt-nix | nixpkgs |
| git-hooks | github:cachix/git-hooks.nix | nixpkgs |
| llm-agents | github:numtide/llm-agents.nix | — |
| claude-code-overlay | github:ryoppippi/claude-code-overlay | nixpkgs |

### nixConfig（binary cache）

```
https://cache.nixos.org
https://cache.numtide.com（llm-agents 用）
```

### overlays

```nix
claude-code    ← claude-code-overlay
codex          ← llm-agents
opencode       ← llm-agents
ccstatusline   ← llm-agents
agent-browser  ← llm-agents
```

### perSystem

- treefmt（nixfmt）
- pre-commit hooks（treefmt）
- devShells.default（pre-commit 用）

### apps

| コマンド | 内容 |
|---|---|
| `nix run .#switch` | darwin-rebuild switch |
| `nix run .#build` | darwin-rebuild build |
| `nix run .#update` | flake update + switch |

### darwinConfigurations

```
darwinConfigurations.gigun
  ├── nix/modules/darwin/system.nix
  ├── nix/modules/darwin/homebrew.nix
  └── home-manager（nix/modules/home/default.nix）
```

両アーキテクチャ（aarch64-darwin / x86_64-darwin）を `systems` に含め、
`nix run .#switch` 内で `uname -m` で切り替える。

---

## nix/modules/darwin/system.nix 仕様

### 責務

- nix 設定（gc、experimental-features、trusted-users）
- TouchID sudo（pam-reattach 含む）
- Xcode CLT 自動インストール（activationScripts）
- ユーザー設定（shell = zsh）
- macOS system.defaults（最小限）

### 必須設定

```nix
# nix gc
nix.gc.automatic = true;
nix.gc.interval = { Hour = 12; Minute = 0; };
nix.gc.options = "--delete-older-than 7d";
nix.settings.max-jobs = "auto";
nix.settings.trusted-users = [ "root" username ];

# TouchID
security.pam.services.sudo_local.touchIdAuth = true;
security.pam.services.sudo_local.reattach = true;

# shell
users.users.${username}.shell = pkgs.zsh;
programs.zsh.enable = true;

# system.defaults（最小限）
system.defaults.dock.autohide = true;
system.defaults.finder.AppleShowAllExtensions = true;
system.defaults.NSGlobalDomain.NSAutomaticCapitalizationEnabled = false;
# ... 他は後から追加
```

### Xcode CLT 自動化（mozumasu パターン）

```bash
if ! /usr/bin/xcrun -f clang >/dev/null 2>&1; then
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  PROD=$(softwareupdate -l | grep "\*.*Command Line" | tail -n 1 | sed 's/^[^C]* //')
  softwareupdate -i "$PROD" --verbose
fi
```

---

## nix/modules/darwin/homebrew.nix 仕様

### 責務

Homebrew で管理するアプリ・ツールの宣言。

### 制約

- `casks` のみ GUI アプリ
- `brews` は nixpkgs にない tap 限定の例外 CLI ツールのみ
- `cleanup = "zap"` で宣言外は完全削除

### 初期値

```nix
homebrew = {
  enable = true;
  onActivation.cleanup = "zap";

  taps = [ "k1LoW/tap" "manaflow-ai/cmux" ];

  brews = [
    "mas"
    "k1LoW/tap/mo"
  ];

  casks = [
    "aqua-voice"
    "azookey"
    "cmux"
    "google-chrome"
    "monitorcontrol"
    "zed"
  ];

  masApps = {
    "Xcode" = 497799835;
  };
};
```

---

## nix/modules/home/default.nix 仕様

### 責務

home-manager のエントリポイント。サブモジュールを import する。

### 実装

```nix
{ config, pkgs, lib, ... }:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
in
{
  home.username = "gigun";
  home.homeDirectory = "/Users/gigun";
  home.stateVersion = "25.05";

  imports = [
    ./packages.nix
    ./dotfiles.nix
    ./programs/zsh
    ./programs/git
  ];

  programs.home-manager.enable = true;
}
```

**注意：** `useGlobalPkgs = false` は flake.nix の home-manager 設定で指定する（ここではない）。

---

## nix/modules/home/packages.nix 仕様

### 責務

グローバルに常に使える CLI ツールの宣言。
プロジェクト固有のランタイムはここに入れない（devShell へ）。

### 初期パッケージ

```nix
# JS/Python ランタイム（グローバル常用）
nodejs, bun, deno, pnpm, uv

# AI（overlay 経由）
claude-code, codex, opencode, ccstatusline, agent-browser

# Git
gh, ghq

# 検索・ファイル
ripgrep, fd, fzf, eza, bat, zoxide, jq

# シェル
sheldon, vivid

# 開発
cocoapods, mise

# エディタ
neovim
```

**注意：**
- `direnv` は `programs.direnv.enable = true` で自動インストールされるため packages に含めない
- `mise` はタスクランナー用途のみ（ランタイム管理には使わない）

---

## nix/modules/home/dotfiles.nix 仕様

### 責務

dotfiles リポジトリのファイルを `~/.config/` 等にシンボリックリンクする。
`bootstrap.sh` と同一のリンクを home-manager activation で自動化。

### リンク一覧

| ソース | リンク先 |
|---|---|
| `zsh/.zshrc` | `~/.zshrc` |
| `zsh/functions/` | `~/.config/zsh/functions/` |
| `sheldon/` | `~/.config/sheldon/` |
| `zeno/` | `~/.config/zeno/` |
| `nvim/` | `~/.config/nvim/` |
| `claude/` | `~/.claude/` |
| `ghostty/` | `~/.config/ghostty/` |
| `zed/` | `~/.config/zed/` |
| `cursor/` | `~/.config/cursor/` |
| `ccstatusline/` | `~/.config/ccstatusline/` |
| `mise/` | `~/.config/mise/` |
| `npmrc` | `~/.npmrc` |
| `bunfig.toml` | `~/.bunfig.toml` |

**注意：**
- git は `programs.git` で管理するためリンク不要（home-manager が自動生成）
- iterm2, terminal は後で個別に設定方法を決める

### 実装

`xdg.configFile` / `home.file` + `mkOutOfStoreSymlink`（mozumasu パターン）を使用。
nix store にファイルを取り込まず、dotfiles リポジトリのファイルを直接参照。

```nix
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  mkLink = path: config.lib.file.mkOutOfStoreSymlink "${dotfilesPath}/${path}";
in
{
  xdg.configFile = {
    "sheldon".source = mkLink "sheldon";
    "zeno".source = mkLink "zeno";
    "nvim".source = mkLink "nvim";
    "claude".source = mkLink "claude";
    "zsh/functions".source = mkLink "zsh/functions";
  };

  home.file = {
    ".zshrc".source = mkLink "zsh/.zshrc";
  };
}
```

**注意：** `programs.git` で管理する場合、`home.file.".gitconfig"` は不要
（home-manager が `~/.config/git/config` を自動生成する）。

---

## nix/modules/home/programs/zsh/default.nix 仕様

### 責務

zsh を home-manager に認識させる最小限の設定。
`.zshrc` 本体は `zsh/.zshrc`（dotfiles 管理、nix 非依存）。

### 設計思想（ryoppippi + mozumasu ハイブリッド）

- **nix はツールをインストールするだけ**：shell の初期化方法は .zshrc が管理
- **enableZshIntegration = false を全ツールに適用**：.zshrc のポータビリティを保つ
- **.zshrc はリポジトリにファイルとして存在**：home-manager の initContent で生成しない

### home-manager で管理する内容

```nix
programs.zsh = {
  enable = true;
  enableCompletion = false;  # deferred compinit で自前管理
  promptInit = "";           # pure を sheldon 経由で管理
};

programs.direnv = {
  enable = true;
  enableZshIntegration = false;  # .zshrc の config cache で管理
  nix-direnv.enable = true;
  config.global = {
    warn_timeout = "0s";
    hide_env_diff = true;
  };
  stdlib = ''export DIRENV_LOG_FORMAT=""'';
};

# zoxide, fzf 等は programs.* を使わず packages に入れるだけ
# hook 初期化は .zshrc の config cache が担当
```

---

## nix/modules/home/programs/git/default.nix 仕様

### 責務

`programs.git` による git 設定の宣言的管理。

### 設定内容

```nix
programs.git = {
  enable = true;
  userName = "gigun";
  userEmail = "TBD";  # Keychain 連携は後回し
  delta.enable = true;
  extraConfig = {
    init.defaultBranch = "main";
    pull.rebase = true;
    push.autoSetupRemote = true;
  };
};
```

---

## nix/modules/home/programs/direnv.nix 仕様

zsh/default.nix に統合。programs/direnv.nix は作成しない。
direnv の設定は zsh モジュール内で一元管理する。

---

## zsh/.zshrc 仕様

### 責務

zsh のメイン設定。nix ストアパスを直接参照しない。
nix なしでも動作する（ツールが未インストールなら静かにスキップ）。

### ensure_installed パターン（ryoppippi 準拠）

```zsh
ensure_installed() {
  local cmd=$1; shift
  if command -v "$cmd" &>/dev/null; then
    "$cmd" "$@"
  fi
}
```

ツールが存在しない場合は何もせずスキップ。キャッシュ生成時に使用。

### 構成（読み込み順序）

```
1. XDG パス設定
2. ensure_installed 関数定義
3. sheldon キャッシュ読み込み（プラグイン）
   → zsh-defer, autosuggestions, syntax-highlighting, pure, zeno
4. config cache 読み込み（ツール初期化）
   → brew shellenv, vivid LS_COLORS, direnv hook, zoxide init, mise activate
5. zeno 環境変数・キーバインド設定
   export ZENO_HOME="${XDG_CONFIG_HOME}/zeno"
   export ZENO_ENABLE_SOCK=1
   export ZENO_GIT_CAT="bat --color=always"
   export ZENO_GIT_TREE="eza --tree"
   bindkey ' '  zeno-auto-snippet
   bindkey '^m' zeno-auto-snippet-and-accept-line
   bindkey '^i' zeno-completion
   bindkey '^r' zeno-smart-history-selection
   bindkey '^x^s' zeno-insert-snippet
6. エイリアス
7. 関数定義（ghq_fzf 等）
8. キーバインド（Ctrl+G 等）
9. deferred compinit
```

### sheldon キャッシュパターン（mozumasu パターン）

`sheldon source` は毎回実行すると遅いため、キャッシュして ZWC コンパイルする。

```zsh
# sheldon cache（plugins.toml 変更時のみ再生成）
_sheldon_cache="${XDG_CACHE_HOME}/sheldon.zsh"
_sheldon_toml="${XDG_CONFIG_HOME}/sheldon/plugins.toml"
if [[ ! -r "$_sheldon_cache" || "$_sheldon_toml" -nt "$_sheldon_cache" ]]; then
  sheldon source > "$_sheldon_cache"
  zcompile "$_sheldon_cache"
fi
source "$_sheldon_cache"
unset _sheldon_cache _sheldon_toml
```

### config cache パターン（ryoppippi パターン + ZWC コンパイル）

各種ツールの init 出力をキャッシュし、ZWC コンパイルで高速化する。

```zsh
_config_cache="${XDG_CACHE_HOME}/zsh/config.zsh"
if [[ ! -f "$_config_cache" || "${ZDOTDIR:-$HOME}/.zshrc" -nt "$_config_cache" ]]; then
  mkdir -p "${XDG_CACHE_HOME}/zsh"
  {
    # brew shellenv（アーキテクチャに応じたパス）
    if [[ "$(uname -m)" == "arm64" ]]; then
      /opt/homebrew/bin/brew shellenv 2>/dev/null
    else
      /usr/local/bin/brew shellenv 2>/dev/null
    fi
    # ツール初期化（ensure_installed で未インストール時はスキップ）
    ensure_installed vivid generate gruvbox-dark | xargs -I{} echo 'export LS_COLORS="{}"'
    ensure_installed direnv hook zsh
    ensure_installed zoxide init zsh
  } > "$_config_cache"
  zcompile "$_config_cache"
fi
source "$_config_cache"
unset _config_cache
```

### deferred compinit（mozumasu パターン）

補完システムの初期化を遅延して起動を高速化する。

```zsh
function _deferred_compinit() {
  autoload -Uz compinit
  local dump="${ZDOTDIR:-$HOME}/.zcompdump"
  if [[ -r "$dump" ]]; then
    compinit -d "$dump"
  else
    compinit -d "$dump"
  fi
  zcompile "$dump"
}
zsh-defer _deferred_compinit
```

---

## sheldon/plugins.toml 仕様

`zsh-defer` による遅延読み込みで起動を高速化する（mozumasu パターン）。

```toml
shell = "zsh"

# 遅延読み込みテンプレート
[templates]
defer = "{{ hooks | get: \"pre\" | nl }}{% for file in files %}zsh-defer source \"{{ file }}\"\n{% endfor %}{{ hooks | get: \"post\" | nl }}"

# zsh-defer は最初に読み込む（他プラグインの defer に必要）
[plugins.zsh-defer]
github = "romkatv/zsh-defer"

[plugins.zsh-autosuggestions]
github = "zsh-users/zsh-autosuggestions"
apply = ["defer"]

[plugins.zsh-syntax-highlighting]
github = "zsh-users/zsh-syntax-highlighting"
apply = ["defer"]

[plugins.pure]
github = "sindresorhus/pure"
use = ["{async,pure}.zsh"]
apply = ["source"]

[plugins.zeno]
github = "yuki-yano/zeno.zsh"
apply = ["source"]
```

**読み込み順序の原則：**
- `zsh-defer` は最初（他の defer テンプレートの前提）
- pure / zeno は即時読み込み（プロンプトとキーバインドに必要）
- autosuggestions / syntax-highlighting は defer（遅延読み込みで十分）

---

## zeno/config.yml 仕様

最小限からスタート。使いながら追加。

### 初期 snippets

```yaml
snippets:
  - keyword: ll
    snippet: eza -hl

  - keyword: la
    snippet: eza -hlA

  - keyword: lt
    snippet: eza --tree

  - keyword: gg
    snippet: ghq get

  - keyword: v
    snippet: nvim

  - keyword: gca
    snippet: git commit -m

  - keyword: ngc
    snippet: nix-collect-garbage -d
```

---

## bootstrap.sh 仕様

### 責務

nix なしで最低限の環境を構築する。

### 手順

```
1. Xcode CLT インストール（未インストールの場合）
2. Homebrew インストール（未インストールの場合）
3. シンボリックリンク作成（dotfiles.nix と同一内容）
4. sheldon インストール（curl）
5. 完了メッセージ（次のステップ: nix インストール）
```

### 制約

- 冪等性を保つ（何度実行しても同じ結果）
- エラー時は停止（set -euo pipefail）
- nix が入っている場合は `nix run .#switch` を案内して終了

---

## 制約・注意事項

- `git add` 必須：nix は git index から評価するため、`nix run .#switch` 前に必ず `git add`
- `xdg.configFile` と `home.activation` シンボリックリンクを同一パスに併用しない（競合）
- nix store パスを `.zshrc` 等のポータブルファイルに直接書かない
- sheldon はキャッシュパターンで読み込む（`eval "$(sheldon source)"` は毎回遅いため避ける）
- `useGlobalPkgs = false`：overlay との整合性を保つため（ryoppippi パターン）
- `nixConfig` はリテラルセットで記述する（`import` や `let-in` は使えない）
- `programs.zsh.enableCompletion = false`：compinit を .zshrc で deferred 実行するため
- `programs.zsh.promptInit = ""`：sheldon 経由で pure を読み込むため
- `enableZshIntegration = false` を全ツールに適用（.zshrc のポータビリティを保つ）
- `ensure_installed` で未インストールのツールは静かにスキップ（nixなしでも壊れない）
- ZWC コンパイル：キャッシュファイルは `zcompile` で `.zwc` に変換して高速化
