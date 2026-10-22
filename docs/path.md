# PATH の管理元と整理案

以下は Pro で統合・適用して確認した管理経路。mini/VM へは適用していない。

| 追加元 | 現状の追加と優先理由 | 宣言管理の担当・提案 |
|---|---|---|
| nix-darwin set-environment | user profile → per-user → current-system → installer default → OS標準。nix-darwin既定の順 | system世代。独自の並べ替えはしない |
| `/etc/zshenv` shellInit | Homebrew bin/sbinを先頭。既存の共通環境設定 | `nix/modules/darwin/system.nix`を唯一の管理済みbrew初期化元として維持 |
| `~/.zshenv` | XDG。提案でPATH一意属性を設定 | HM activationからrepositoryへリンク。重複防止のみ、追加元の代用ではない |
| 現ホーム `~/.zprofile` | brew shellenvとOrbStack init。通常ファイルで宣言管理外 | 新しい `zsh/.zprofile` を正本とし、HM `home.file` と旧bootstrapから配置 |
| `.zshrc` 冒頭 | standalone/WSL用installer fallback | Darwin初期化済みならskip。Nix固有の重複初期化を解消 |
| `.zshrc` Bun | cacheのBun global binを先頭 | 対話用追加をここに維持。既存override順位を変更しない |
| `.zshrc` mise | 存在時shimsを先頭。projectごとのtool-version解決、zenoがdenoを見つけるためpluginより前 | 対話用追加をここに維持 |
| `.zshrc` local bin | Nix/brewで管理できない例外CLIを低優先の末尾 | 対話用追加をここに維持 |
| `.zshrc` Windsurf | 最後に先頭追加される既存設定。高優先の理由は記録なし | 使用していないとの情報だけで削除・順位変更しない |
| OrbStack | loginのみbinを末尾、completionをfpath末尾 | vendor initの既存2行と等価な宣言をrepository `.zprofile` に集約 |
| Home Manager | per-userパッケージと起動ファイル配置。独自home.sessionPath定義は確認範囲になし | 各PATHを重ねて追加する場所にはしない |

## 実際の差分案

1. `.zshenv` の `typeset -gU PATH path` で、同じ文字列の先頭要素を保つ。
   scalar/array双方に属性を付け、後続の `export PATH=...` にも適用する。
2. `.zshrc` はDarwin初期化済みならinstaller profileを読まない。
3. 新規 `zsh/.zprofile` は管理済みDarwinではbrewを呼ばない。Nix未導入/standaloneのMac
   だけ `/opt/homebrew` または `/usr/local` の既存brewで `shellenv zsh` を使う。
   シェル名を明示し、brewのshell検出用psを不要にする。
4. 現ホームのOrbStack initはPATH/fpath追加だけだったため、その内容を `.zprofile` に移す。
   vendor initをsourceせず、OrbStack binが存在する場合に同じ位置へ追加する。
   今後vendorが追加する統合機能は自動追従しないため、必要ならこの正本をレビューして更新する。
5. HMの `home.file.".zprofile".text` は正本をreadFileする。Nix未導入/凍結側の
   bootstrap fallbackは同じ正本へリンクする。欠損時は導入開始前に停止。
   通常のProではbootstrapが共通switchへ委譲するので二重適用にならない。

現在の `.zprofile` はbrew+OrbStackの2処理だけで、上記で内容を保全する。
HMの既存 `backupFileExtension="backup"` により通常ファイルは退避される想定。
Proでは通常適用後、元の `.zprofile` の backup と HM 世代リンクを確認済み。
新規ホストでは適用直前に内容/backup衝突を確認する。Home Manager側の programs.zsh は現構成では無効なので、
既存の `.zprofile` 生成宣言との競合は静的には見つかっていない。

## 保つ優先順位と残る判断

対話loginでは Windsurf → mise shims → Bun cache bin → Homebrew → user profile →
per-user → current-system → installer default → OS標準 → OrbStack → local bin を維持。
非対話ではrc追加なし、非loginではprofile追加なし。HomebrewがNixより先である現状も変えない。
ryoのXcodeよりNix gitを優先する判断を、そのままbrew全体の順位変更へ拡張しない。
user profileに独自nixがあればcurrent-systemより優先される既定設計も維持する。
現Proの `~/.nix-profile/bin` は未存在。Windsurf/Bun/mise/local/OrbStackの各binは存在する。
存在しないパスの一括削除やsymlink実体の正規化は行わない。

ryoは主shell fishのfish_add_path、mozuはHM zshモジュールへの集約を用いる。
ここでは重複回避と管理元明示を参考にし、shell変更や `no_global_rcs` の模倣はしない。
本番のglobal rcは従来どおり読む。テストの `-d` は安全なfixture隔離専用。

実zshの隔離fixtureで4起動モード、旧条件再現、rc再読込、env/profile/rc再読込、
継承PATH、Nix未導入、standalone fallbackを確認する。初回全順序を比較し、再読込・継承時も
Nix優先と一意性、管理済みbrew非実行、fallback brew実行を検査する。
補完/pluginはstub、system初期化とbrewはfixture。repositoryの新しい `.zprofile` は実際に読む。
詳細と制限は [setup](setup.md#path-の確認) と [検証](testing.md)。Pro の通常適用後には新規シェルの Nix 解決先・PATH の一意性も確認した。
