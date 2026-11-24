# REAとGhidra

Apple Silicon MacではHome Managerが`nix/packages/ghidra-rea`のGhidra 12.2を導入する。公式release ZIPのSHA-256を固定し、同梱ソースからarm64 decompilerをNixのC++ toolchainでビルドする。GUI入口は`ghidra`、headless入口は`ghidra-analyzeHeadless`。

## 版を固定する理由

REA 6.10.1 向けに Ghidra 12.2 と JDK 25 を使用する。既存プロジェクトを開くときは、プロジェクトのコピーで互換性を確認する。

## REAへ環境を渡す

REAはGhidraのshell launcherを経由せず、JVMを直接起動する。そのため、Ghidra launcher内のJava設定だけではREAのJVM選択は固定できない。`with-ghidra`は次のコマンドだけにNix版Ghidraの`GHIDRA_INSTALL_DIR`とJDK21の`JAVA_HOME`を渡す。全シェルのJava設定は変更しない。

```sh
with-ghidra npx -y rea-agents@6.8.0 doctor --provider ghidra --format json
```

REA本体・skill・MCPはgigun-dev/claude-codeで管理する。Claude CodeとCodexはmarketplaceの上流plugin参照(npm `rea-agents`の固定版)で入る。agyにはmarketplaceから入らないため、flake input `gigun-plugins`のoverlayが包んだagy版を`nix/modules/home/dotfiles.nix`が`~/.gemini/config/plugins.json`の2つ目のentryとして読ませ、このNix版GhidraとJDK21を`mcpEnv`で渡す(claude-codeのADR 0005)。どのhostにも`rea setup`は使わない。GhidraのNix導入は、Claude Code・Codex側のplugin登録の完了を意味しない。Desktopアプリのpluginがこれらの環境値を継承するかは、その接続元でprovider診断して確認する。端末内の確認をDesktopの接続確認と同一視しない。

## 検証

宣言追加後は`nix run .#build`でシステム構成をビルドし、Nix版のGhidra/arm64 decompilerをREAの診断と小さなMach-Oの逆コンパイルで確認する。適用は通常の`nix run .#switch`を使い、既存のCI・適用ゲートを守る。
