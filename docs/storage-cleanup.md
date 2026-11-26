# ストレージ整理（Pro）

MacBook Pro（M4 Pro、SSD 460GB）の空き容量が逼迫したときの手順書。次の整理の前にここを読む。
日付付きの経過は nb のログに残し、ここには再利用できる知識だけを置く。
2026-03-24 は 2.4GB → 119GB、2026-11-08 は 5.0GB → 約68GB まで回復した。
どちらも数か月で埋まっており、大きいのは毎回「再生成できるキャッシュ」「リポジトリのビルド成果物」「Nix の古い世代」である。
2026-11-10 は 2 日で約 57GB 減って 11GB になった。主因はエージェントのスクラッチパッド（`/private/tmp/claude-501`、35GB）で、ホーム配下だけを測る手順では見えなかった。
ebook2pdf の実験セッションが同じ 283MB の入力 PDF を実験ごとに普通のコピーで複製していた（83 個）。リポジトリの `reanalyze-library` は `clonefile` を使っており、自作の実験手順がそれを迂回していた。そのセッションに指摘して片付けさせ、全体で 71GB まで戻した。全体指示への追加は 1 件だけでは見送った（todo に昇格条件を置いた）。
2026-11-21 は 3.7GB → 約 38GB。13 日で約 56GB 増えていた。主因は、worktree に残った `result` が古いシステム世代を固定していたこと（約 10GB、下記「Nix」）、iOS DeviceSupport の再取得、Paste のスクリーンショット履歴、Codex の session だった。

2026-11-26 は 9.4GB まで減っていた（5 日で約 50GB 増）。大物は無く分散していたが、仕組みとして溜まり続けていたのは `git wt -d` の削除先だった。`wt.remover` が macOS でも trash-cli を使い、消した worktree が `.build` ごと XDG のゴミ箱（`~/.local/share/Trash`、5.1GB）に入っていた。ここは Finder に出ず自動削除も効かない。macOS は標準の `/usr/bin/trash`（Finder のゴミ箱）に替えた（ryoppippi と同じ）。測るときは `du` の見かけのサイズに注意する。SwiftPM の `CompilationCache.noindex` はスパースファイルで、`stat -f %z` では 12〜25GB に見えるが実際は数 KB。`find -newermt` で期間の増加を集計するときは `stat -f %b`（512 バイトのブロック数）で数える。

APFS のクローン（`cp -c`、および既定の `ditto`）は、`du` で元と写しの両方に数えられる。df は増えない。2026-11-26 に Regrab の 8.1GB のバックアップを「重複」と誤って判断した例がある（実際は 479 ファイルすべてがブロックを共有していた）。どれだけ増えたかは `df` の差で判断し、`du` はどこにあるかを探すために使う。

`~/Library/Logs/storage-usage/<日付>.tsv` に、1 日 1 回、`df` の空きと、3 階層までの 500MB 以上のフォルダが記録される（`nix/modules/home/maintenance.nix` の `storage-usage`、180 日分）。空きが急に減ったら、前の日のファイルと比べる。

定型の掃除（キャッシュ、マージ済み worktree、Nix GC の確認）は ryoppippi の `clean-storage` スキルで行う（`nix/modules/home/agent-skills.nix` で配布）。この手順書は、その後に残る大物を測って判断するためのもの。

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

dirty な worktree は、変更が main に入っているかを調べてから扱う（esp32-airdrop-poc の `.claude/worktrees` と `-worktrees/` で 22 個、2026-11-21）。main に無い作業は、patch ではなく、そのブランチに WIP commit として積み、`keep/<内容>` に改名してから worktree を消す。patch は基点を失って埋もれ、main が進むと当たらなくなる。

### (d) 残すもの

- Claude Code / Codex のセッション記録（`~/.claude`、`~/.codex/sessions`、thread_history）。
- `~/.claude/plugins/cache`。動作中の MCP サーバー（cman など）がここから起動する。2026-03 に消したが、今は消さない。
- 使用中の Hugging Face モデル（whisper、PLaMo）。
- ebook2pdf アプリのライブラリ `~/Library/Application Support/ebook2pdf/Library/records`（変換済み PDF 51 件、17GB）。個人データで再生成できない。
- Claude Desktop の `vm_bundles`（現行の 1 つ。消すと動かない）、bun のグローバルキャッシュ（全プロジェクトのハードリンク元）。
- Nix の現行システム closure（約 6.8GB）。

## 個別の注意

### Nix

定期 GC は `nix/modules/darwin/nh-clean.nix` の daemon（`nh clean all --keep-since 7d --keep 3 --optimise`、AC 電源時に 1 日 1 回、ログは `/var/log/nh-clean.log`）。
2026-11-21 までは `nix.gc`（`nix-collect-garbage --delete-older-than 7d`）だったが、これは GC root を外さない。エージェントが worktree ごとに `nix run .#build` すると、各 worktree の `result` が当時のシステム closure を固定する。`.wt/` の 9 個と本体の `result` が 10 世代・約 10GB を残し、手動 GC でも 1GB しか減らなかった。`nh clean` は 7 日より古い `result` や direnv の root も外す。

GC が効かないときは、まず root を見る。

```bash
nix-store --gc --print-roots | grep -v -E '\{lsof\}|\{censored\}'   # result や .direnv が並ぶ
sudo nh clean all --keep-since 7d --keep 3 --optimise              # daemon と同じ手動実行
```

古いシステム世代は root 所有なので、手で GC するときは sudo が要る。
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
再起動しても、Claude Code・Codex・T3 Code を開けば MCP がまた立ち上がりロックが戻るので、再起動は条件にならない。他のエージェントが動いていないときに、自分のセッションの `uv run` を止めてから `uv cache prune`（公式が定期実行を勧める方）を流す。止めたセッションでは cman と agy が使えなくなり、新しいセッションで戻る。

```bash
pkill -f 'uv run --script' && sleep 1 && uv cache prune
```

2026-11-21 はこれで 10.1GiB 消えた。普段は `nix/modules/home/maintenance.nix` の `uv-cache-prune` agent が、AC 電源のときに毎時 60 秒だけ lock を待って試し、成功したら 20 時間休む（ログは `~/Library/Logs/uv-cache-prune.log`）。agy-mcp は 2026-11-24 に自動有効化から外したので、lock を握るのは cman だけ。`--force` は動作中の MCP サーバーの環境を壊しうるので使わない。経緯と uv 側の改善待ちは todo 0141。
11-01〜11-08 の増加の大半は、`uvx markitdown-mcp` が同じ中身の venv（約 341MB）を 10 個作ったもの（3.3GB）。gigun-dev/claude-code の 881d9ca（11-09）で nix の markitdown-mcp を直接起動するようにして止まった。
過去に、`environments-v2` と `~/.local/share/uv/tools` の symlink / `.pth` から参照される `archive-v0/<id>` だけを残して他を `rm` したことがある（568 件中 527 件を消して 16GB から 10GB）。ただし公式は「キャッシュを直接変更するのは決して安全ではない」としており、実行中のプロセスが参照するエントリを消しうるので、手順としては勧めない。
キャッシュの大半は `archive-v0`（6.9GB）と `environments-v2`（0.9GB）。

### iOS バックアップ（MobileSync）

`~/Library/Application Support/MobileSync/Backup/*` は大きくなりやすい。`Status.plist` を `plutil -p` で読む（バイナリ plist なので `cat` は不可）。
`SnapshotState=uploading` や `BackupState=empty` で、直下に `Manifest.db` が無く hex 名のサブディレクトリ（`00`〜`ff`）だけが残っていれば、中断した壊れたバックアップなので消してよい（約 50GB の例）。
Finder の iPhone の Wi-Fi 自動バックアップが中断を繰り返すと同じものが毎日再生成される。容量不足でフルバックアップを書けないことが一因と推定している。恒久対策は未実施で、Finder で iCloud バックアップへ切り替えるか、一度ケーブルで完走させてから Wi-Fi 自動バックアップを止める。

### Android

AVD 実体 `~/.android/avd`、SDK の system-images と emulator、`~/.gradle` で合計 12GB 級。Android Studio が入れ直す。
`~/.android` は `avd` だけ消す。直下の `debug.keystore`（デバッグ署名鍵）と `adbkey`（ADB 認証鍵）を巻き込むと、既存デバッグアプリの再インストールと実機の再認証が要る。

### Paste（クリップボード履歴）

`~/Library/Application Support/com.wiheads.paste-setapp/.db_SUPPORT/_EXTERNAL_DATA` が増える。スクリーンショットをコピーすると、macOS は同じ画像を無圧縮の TIFF（1 件約 32MB）でも載せ、Paste は全表現を保存する。2026-11-08〜21 に 6.5GB 増えた。大半は Kickstart や ebook2pdf などの検証中にアプリからコピーした画像だった。
コピー元アプリ別の量は、DB を読み取り専用で開いて数える（`ZITEMDATAENTITY.ZRAWPASTEBOARDITEMS` が外部ファイルの UUID を持つ）。消すときは Paste アプリから消す。`_EXTERNAL_DATA` を直接消すと DB との整合が壊れる。増やさないには、Paste の設定の「無視するアプリ」に検証対象のアプリを入れる。

### Codex の session

`~/.codex/sessions` は残す。シミュレータやブラウザのスクリーンショットを base64 で埋め込むため、画像の多い作業で急に増える（2026-11 は 1 か月で 7.4GB、1 行 23MB の例）。

### Hugging Face

hub キャッシュは、モデル間で blob を共有する構造（`hub/blobs/<2 文字>/<hash>`）に変わった。モデルディレクトリを消すだけでは共有側の blob が残る。他のモデルから参照されていない blob だけを `realpath` で突き合わせて消す。`du -L` のモデル別集計は重複を数えるので当てにしない。

### 手で消さないもの

- **OneDrive**: `Group Containers/...` の 4GB と `CloudStorage/OneDrive-...` の 4GB は FileProvider の同一実体で、二重ではない。`rm` は同期を壊す。Finder の「空き容量を増やす」を使う。`FileProviderLogs` だけは消してよい。
- **MacWhisper**: 4GB のうちモデルが 1.5GB、`Database/ExternalMedia` が 2.6GB（文字起こし元の動画・音声を丸ごと保持）。消すと文字起こしテキストは残るがアプリ内で再生できない。

### アプリの削除

Pro の switch は system の適用後に `brew bundle --force-cleanup` を実行する。Brewfile から外した cask や tap はこの段階で自動的に削除される。
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
