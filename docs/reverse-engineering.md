# REAとGhidra

Apple Silicon MacではHome Managerが`nix/packages/ghidra-rea`のGhidra 12.2を導入する。公式release ZIPのSHA-256を固定し、同梱ソースからarm64 decompilerをNixのC++ toolchainでビルドする。GUI入口は`ghidra`、headless入口は`ghidra-analyzeHeadless`。

## 版を固定する理由

REA 6.10.1 向けに Ghidra 12.2 と JDK 25 を使用する。既存プロジェクトを開くときは、プロジェクトのコピーで互換性を確認する。

## REAの経路

REAはgigun-dev/claude-codeのflake(input `gigun-plugins`)が版を固定して1回だけビルドし(claude-codeのADR 0007、overlayの`external-plugins`)、`nix/modules/home/agent-plugins.nix`がその出力を各ホストの読む場所へ置く。marketplaceからは入れない。どのhostにも`rea setup`は使わない。

| ホスト | 置き場所 | 読み込まれ方 |
|--------|----------|--------------|
| Claude Code | `~/.claude/skills/rea` → `share/agent-plugins/rea` | `.claude-plugin/plugin.json`を持つので`rea@skills-dir`としてMCPとskillごと読む |
| Codex | `~/.codex/config.toml`の`[mcp_servers.rea]`、`~/.agents/skills/reverse-engineer-anything` | `writeCodexConfig`がmerge。`tool_timeout_sec = 420` |
| agy | `~/.gemini/config/plugins.json`の2つ目のentry(`share/agy-plugins`) | `include_only`に`rea` |

MCPはどのホストからもパッケージの`bin/rea-mcp`1つで起動する。固定したnodeを絶対パスで呼び、Apple Silicon Macでは`GHIDRA_INSTALL_DIR`とJDKの`JAVA_HOME`(`with-ghidra`と同じ値)を中に書き込んである。REAはGhidraのshell launcherを経由せずJVMを直接起動し、Codexは起動するMCPへ親の環境を渡さないため、環境は実行ファイル側に持たせる。Linux(mini-vm・WSL)ではGhidraの環境なしで同じパッケージが入る。

この変更より前の世代へ戻すと、旧世代のmergeは`config.toml`に新世代の`[mcp_servers.rea]`を残す。新世代がGCされるとその起動パスは消えるので、戻したら`[mcp_servers.rea]`の表を手で消し、plugin側のREAに戻す。

Desktopアプリが`~/.claude/skills`のpluginを読むかは確かめていない。端末内の確認をDesktopの接続確認と同一視しない。

## 検証

`nix run .#build`の後、適用前のgenerationで次を確かめる。`$G`はhome-managerのgeneration(`darwin-rebuild build`の`result`からたどるか、`nix eval .#darwinConfigurations.gigun-aarch64-darwin.config.home-manager.users.gigun.home.activationPackage`)。

```sh
readlink "$G/home-files/.claude/skills/rea"                  # .../share/agent-plugins/rea
ls -l "$G/home-files/.agents/skills/"                        # reverse-engineer-anything -> .../skills/reverse-engineer-anything
jq . "$G/home-files/.gemini/config/plugins.json"             # 2つ目のentryが .../share/agy-plugins と rea
grep -A2 'mcp_servers.rea' "$(grep -o '/nix/store/[^ ]*-codex-config' "$G/activate")"
rea_mcp=$(readlink -f "$G/home-files/.claude/skills/rea")/../../../bin/rea-mcp
grep '^export' "$rea_mcp"                                    # GHIDRA_INSTALL_DIR と JAVA_HOME
```

`rea-mcp`を`env -i HOME=$HOME PATH=/usr/bin:/bin`で起動し、MCPの`initialize`と`tools/list`が返ることを見る。ホストの環境に頼っていないことの確認になる。Ghidraの解析まで見るときは、REAの診断(`node .../lib/rea/scripts/rea.mjs doctor --provider ghidra --format json`を`rea-mcp`と同じ環境で実行)と小さなMach-Oの逆コンパイルで確かめる。適用は通常の`nix run .#switch`を使い、既存のCI・適用ゲートを守る。適用後は各ホストで新しいセッションを開き、REAのtoolが見えることを確かめる。
