# ストレージ整理（Pro）

MacBook Pro（M4 Pro、SSD 460GB）の空き容量が逼迫したときの手順書。次の整理の前にここを読む。
日付付きの経過は nb のログに残し、ここには再利用できる知識だけを置く。
2026-03-24 は 2.4GB → 119GB、2026-11-08 は 5.0GB → 約68GB まで回復した。
どちらも数か月で埋まっており、大きいのは毎回「再生成できるキャッシュ」「リポジトリのビルド成果物」「Nix の古い世代」である。
2026-11-10 は 2 日で約 57GB 減って 11GB になった。主因はエージェントのスクラッチパッド（`/private/tmp/claude-501`、35GB）で、ホーム配下だけを測る手順では見えなかった。

## 現状を測る

空きは Data ボリュームで見る。`df -h /` は System ボリュームを指し、実態とずれる。

```bash
df -h /System/Volumes/Data
du -sh ~/* ~/.[!.]* 2>/dev/null | sort -rh | head -20   # ホーム直下
du -sh ~/Library/* 2>/dev/null | sort -rh | head -15
du -sh ~/Library/Application\ Support/* 2>/dev/null | sort -rh | head -10
du -sh ~/.cache/* | sort -rh | head -10
du -sh ~/ghq/*/*/* | sort -rh | head -20                  # リポジトリごと
du -sh /nix /Applications /private/tmp /private/var/run
du -sh /private/tmp/claude-501/*/*/scratchpad 2>/dev/null | sort -rh | head   # セッション別スクラッチパッド
```

`df` の使用量とホーム配下の合計が大きくずれていたら、ホームの外（上の 3 行目）を疑う。
`/private/var/run/com.apple.security.cryptexd`（17GB）は macOS のシステム領域なので触らない。
`du` は数分かかる。大きい順に上から潰し、1 項目ごとに `df` で効果を確かめる。
2026-11-08 の内訳は Library 98G（Application Support 55G、Xcode 13G）、ghq 79G、.cache 33G、/nix 29G だった。

## 対象の分類

### (a) 再生成できるキャッシュ

消しても困らない。コマンドがあるものはそれを使う。

| 対象 | コマンド | 注意 |
| --- | --- | --- |
| Nix 世代と store | `sudo nix-collect-garbage -d` | 下記「Nix」を参照。2026-11-08 に 14.2GiB |
| pnpm store | `pnpm store prune` | 参照されないパッケージだけ消す。0.9GB（2026-11-10 は 0.27GB で、3.6GB の大半は参照中だった） |
| bun cache | `bun pm cache rm` | |
| npm cache | `npm cache clean --force` | 2026-03 に 16GB。bun/pnpm 併用なら再び溜まる |
| pip cache | `pip cache purge` | uv に一本化済みでほぼ空 |
| uv cache | `uv cache clean` | **MCP サーバーが動いていると終わらない**。下記「uv」を参照 |
| mise の tarball | `rm -rf ~/.local/share/mise/http-tarballs` | `mise cache clear` では消えない。2026-03 に 21GB |
| Xcode の未使用シミュレータ | `xcrun simctl delete unavailable` | |
| Xcode iOS DeviceSupport | 下記 | 1 世代 5〜7GB |
| Xcode の古いシミュレータランタイム | `xcrun simctl runtime delete <id>` | 1 本約 8GB。最新は残す |
| npx の蓄積 | `rm -rf ~/.npm/_npx` | `npm cache clean --force` は `_cacache` しか消さない。両方消して初めて空く（3.6GB 級） |
| Chrome のオンデバイスモデル | 設定で無効化してから消す | `OptGuideOnDeviceModel`（Gemini Nano）約 4GB。無効化しないと再取得される |
| Adobe Camera Raw | `rm -rf ~/Library/Caches/"Adobe Camera Raw 2"` | 再生成される。2026-03 に 7.8GB |
| ESP32 ツールチェーン | `rm -rf ~/.cache/esp32drop` | arduino の toolchain。次のビルドで再取得。5.4GB |
| Hugging Face | 使っていないモデルのみ手で消す | 使用中の whisper / PLaMo は残す |

iOS DeviceSupport はデバイス・OS ごとのディレクトリ（`~/Library/Developer/Xcode/iOS DeviceSupport/<機種> <OS>`）になっている。
Simulator には不要で、実機デバッグとシンボル解決にだけ要る。
接続中の機種の最新版を残して古いものを `rm -rf` する。次に実機をつなぐと Xcode が再生成する。

### (b) リポジトリのビルド成果物

`~/ghq` 配下で見つかる。消す前に、そのリポジトリが MCP サーバーやツールの実体になっていないか、プロセスの cwd になっていないかを確かめる。

```bash
lsof -a -d cwd -c '' 2>/dev/null | awk 'NR>1{print $NF}' | grep ghq | sort | uniq -c   # 全プロセスの cwd
find ~/ghq -name node_modules -type d -maxdepth 5 -prune                   # 候補の列挙
find ~/ghq -name .build -type d -maxdepth 4 -prune                         # SwiftPM
```

| 対象 | 例 | 注意 |
| --- | --- | --- |
| `node_modules` | `rm -rf <repo>/node_modules` | 必要になったら `bun install`。MCP サーバーやツールの実体（figmate、asc-mcp、caldav、tdr-concierge、hub など）と、動作中プロセスの cwd は残す |
| 古い `node_modules` | `find ~/ghq -type d -name node_modules -prune -mtime +90` | 90 日超だけに絞ると作業中を巻き込まない。build 成果物は `-maxdepth 5` で `.next` / `dist` / `build` / `target` / `.venv` を探すと、`node_modules` の内側を拾わない |
| SwiftPM `.build` | `rm -rf <repo>/.build` | swift-mcp-app で 4.8GB。次のビルドで戻る |
| C/C++ の `build/` | `rm -rf <repo>/build` | esp32-airdrop-poc で 2.4GB |
| wrangler のローカルログ | `rm -rf <repo>/.wrangler/state/v3/observability` | 5.3GB。同じ階層の d1 / do / kv / r2 はローカル状態なので残す |
| 実験の出力 | ebook2pdf の `dist/` | 22GB。成果物（`dist/result*.pdf`）だけ残した |

### (c) 内容の判断が要るもの

削除前に中身を見て、本人が決める。

- **エージェントのスクラッチパッド**: `/private/tmp/claude-501/<作業ディレクトリ>/<セッションID>/scratchpad`。Claude Code がセッションごとに作る一時フォルダで、実験のたびにモデルやビルドのコピーを置くと数 GB ずつ増える（ebook2pdf の実験で 1 セッション 24GB）。動作中のセッションのものは消さない。直近の更新（`find <dir> -mmin -60`）と、その worktree を cwd にするプロセス（上の `lsof`）で判定し、終わったセッションの分は本人かそのセッションで片付ける。
- **Codex の作業フォルダ**: `~/Documents/Codex`（日ごとのフォルダ）と `~/.codex/worktrees`。中に ghq リポジトリの git worktree を含む。
- **Pictures**（Lightroom、旧年のライブラリ、スクリーンショット）、**Downloads**。
- **/Applications**（Adobe、Office、IntelliJ、Android Studio）と **~/.lmstudio**。
- **Android AVD**、**iStat Menus の履歴**（SQLite 1 ファイル。自動管理に任せる）。

Codex の作業フォルダは次の順で扱う。

```bash
for r in ~/ghq/*/*/*; do [ -d "$r/.git" ] || continue; git -C "$r" worktree list; done   # 外部にある worktree を洗い出す
git -C <worktree> status --short                           # 未コミットが無いか
git -C <worktree> rev-list --count HEAD --not --remotes    # 0 なら未 push なし
git -C <repo> branch --contains <sha>                      # detached HEAD のとき。どのブランチからも辿れなければ消すと失う
git -C <repo> worktree remove <worktree>                   # clean なものだけ。.git の登録も外れる
git -C <repo> worktree prune                               # フォルダを直接消した後
```

2026-11-08 は clean かつ未 push なしの worktree だけ消し、dirty か ahead の 8 つを残した。

### (d) 残すもの

- Claude Code / Codex のセッション記録（`~/.claude`、`~/.codex/sessions`、thread_history）。
- `~/.claude/plugins/cache`。動作中の MCP サーバー（cman など）がここから起動する。2026-03 に消したが、今は消さない。
- 使用中の Hugging Face モデル（whisper、PLaMo）。
- ebook2pdf アプリのライブラリ `~/Library/Application Support/ebook2pdf/Library/records`（変換済み PDF 51 件、17GB）。個人データで再生成できない。
- Claude Desktop の `vm_bundles`（現行の 1 つ。消すと動かない）、bun のグローバルキャッシュ（全プロジェクトのハードリンク元）。
- Nix の現行システム closure（約 6.8GB）。

## 個別の注意

### Nix

古いシステム世代は root 所有なので、GC は `sudo nix-collect-garbage -d` で行う。
事前に `nix-store --gc --print-dead` で回収量の目安が出る（2026-11-08 は約 10.3GB と見積もり、実際は 14.2GiB）。
`nix/modules/darwin/system.nix` に `nix.gc`（毎日 12:00、7 日より古い世代）があり launchd に載っているが、これで間に合わず手動 GC で大きく減った。理由は未調査（todo 0142）。
2026-03 には、コード署名付き `.app` が chmod エラーで GC を止めた。

```bash
sudo chflags -R noschg,nouchg /nix/store/<止めているパス>
sudo rm -rf /nix/store/<止めているパス>
sudo nix-collect-garbage -d    # 再試行
```

### uv

`uv cache clean` と `uv cache prune` は `~/.cache/uv/.lock` を取る。
Claude Code のセッションごとに `uv run --script`（agy-mcp、cman）と `uv tool uvx markitdown-mcp` が親プロセスとして常駐し、ロックを握り続けるため、300 秒でタイムアウトする（2026-11-08 に 17 プロセスを観測）。
`uv run` と `uvx` が実行中ずっとロックを持つのは、実行中の環境を消させないための uv の意図した挙動（astral-sh/uv#15990）。
再起動の直後、Claude Code と Codex を開く前に `uv cache prune`（公式が定期実行を勧める方）を流す。`--force` は動作中の MCP サーバーの環境を壊しうるので使わない。経緯と uv 側の改善待ちは todo 0141。
過去に、`environments-v2` と `~/.local/share/uv/tools` の symlink / `.pth` から参照される `archive-v0/<id>` だけを残して他を `rm` したことがある（568 件中 527 件を消して 16GB から 10GB）。ただし公式は「キャッシュを直接変更するのは決して安全ではない」としており、実行中のプロセスが参照するエントリを消しうるので、手順としては勧めない。
キャッシュの大半は `archive-v0`（6.9GB）と `environments-v2`（0.9GB）。

### iOS バックアップ（MobileSync）

`~/Library/Application Support/MobileSync/Backup/*` は大きくなりやすい。`Status.plist` を `plutil -p` で読む（バイナリ plist なので `cat` は不可）。
`SnapshotState=uploading` や `BackupState=empty` で、直下に `Manifest.db` が無く hex 名のサブディレクトリ（`00`〜`ff`）だけが残っていれば、中断した壊れたバックアップなので消してよい（約 50GB の例）。
Finder の iPhone の Wi-Fi 自動バックアップが中断を繰り返すと同じものが毎日再生成される。容量不足でフルバックアップを書けないことが一因と推定している。恒久対策は未実施で、Finder で iCloud バックアップへ切り替えるか、一度ケーブルで完走させてから Wi-Fi 自動バックアップを止める。

### Android

AVD 実体 `~/.android/avd`、SDK の system-images と emulator、`~/.gradle` で合計 12GB 級。Android Studio が入れ直す。
`~/.android` は `avd` だけ消す。直下の `debug.keystore`（デバッグ署名鍵）と `adbkey`（ADB 認証鍵）を巻き込むと、既存デバッグアプリの再インストールと実機の再認証が要る。

### 手で消さないもの

- **OneDrive**: `Group Containers/...` の 4GB と `CloudStorage/OneDrive-...` の 4GB は FileProvider の同一実体で、二重ではない。`rm` は同期を壊す。Finder の「空き容量を増やす」を使う。`FileProviderLogs` だけは消してよい。
- **MacWhisper**: 4GB のうちモデルが 1.5GB、`Database/ExternalMedia` が 2.6GB（文字起こし元の動画・音声を丸ごと保持）。消すと文字起こしテキストは残るがアプリ内で再生できない。

### アプリの削除

`homebrew.nix` の casks で宣言したアプリは、行を消して switch すると cleanup でアンインストールされる。
switch は宣言外の brew 項目を見つけると sudo の手前で止まり、`DOTFILES_ALLOW_BREW_CLEANUP=1` を付けた再実行を求める（Touch ID が出ないのはこのため）。
エージェントからの実行は Claude Code の自動許可判定が不可逆な削除として止めるので、本人がターミナルで実行する。
アンインストール後も常駐プロセス（Ollama の `ollama serve` など）とログイン項目が残ることがあるので、`pgrep` で確かめて止める。
手で入れたアプリ（LM Studio など）は `.app` に加えてホーム直下のデータ（`~/.lmstudio`）も消す。

### 削除量と `df` の差

削除量の合計より `df` の増加が小さいのは、APFS ローカルスナップショットの解放待ちによる（44GB 削除して 33GB 反映の例）。`tmutil listlocalsnapshots /` で確かめる。通常は自動で解放される。

### 消した後

- フォルダを直接消した後は `git worktree prune` を各リポジトリで実行する。

## 落とし穴

- **Codex のフォルダ削除で未コミットの変更が消える**: `~/Documents/Codex` に ghq リポジトリの worktree（dotfiles の detached HEAD、別ブランチ、cf-fireboard）が入っていた。コミットは残ったが、未コミットの変更は失った。detached HEAD の 1 つは `rescue/codex-guard-settings` ブランチとして救出した。削除前に上の worktree 確認を行う。
- **`mise cache clear` で `http-tarballs/` は消えない**: 直接削除する。
- **`du` のリポジトリ別集計はビルド成果物を含む**: 大きいからと言ってリポジトリごと消さない。まず `.build`、`node_modules`、`dist` を見る。
- **消したものは `ls` で確かめる**: 存在しないパスへの `rm -rf` は黙って成功する。コマンドの出力と `df` の差分で効果を確認する。
- **zsh ではグロブが 1 つ外れると `rm` 全体が実行されない**: `rm -rf a b ~/Library/Caches/foo*` で `foo*` が一致しないと `no matches found` で止まり、a と b も消えない。グロブは別コマンドに分けるか `setopt nullglob` を使う。

## ツールの現状（2026-11-10 時点）

2026-03 の整理で消した asdf、fnm は残っていない。ランタイムは Nix と mise、パッケージマネージャは bun と pnpm（Nix 配布）を使う。
`~/.colima` は残っているが、コンテナ実行は OrbStack（`nix/modules/darwin/homebrew.nix`）なので colima は使わない。残っていれば不要。
2026-11-10 に LM Studio（モデル 0 件、旧エンジン 3.3GB）、Ollama（ローカルモデル 0 件）、Maestro Studio を削除した。ローカル LLM は Hugging Face + MLX（PLaMo、whisper）で足りている。
`~/ghq/github.com/emscripten-core/emsdk`（1.5GB）は stack-chan の WebAssembly ビルド用なので残す。IntelliJ も残す（JDK は IntelliJ とは独立に Oracle JDK 25 と Temurin 21 が入っている）。
