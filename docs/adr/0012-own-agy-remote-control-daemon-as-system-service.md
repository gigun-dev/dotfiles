# agy の remote-control 常駐は dotfiles の system service が所有する

Date: 2026-10-16

`agy remote-control start` が書くユーザー unit (`~/.config/systemd/user/antigravity-cli-daemon.service`) は `ExecStart` に store パスを直書きする。nix が agy を 1.3.1 から 1.3.6 へ上げても daemon は 1.3.1 のまま動き続け、GC でそのパスが消えれば起動できなくなる。さらに `home.sessionVariables` は systemd に届かず `AGY_CLI_DISABLE_AUTO_UPDATE` が無いので、daemon の auto_updater が毎回失敗していた。そこで `codex-remote-control` (`mini-vm.nix`) と同じ型で、`antigravity-remote-control` を **NixOS の system service (User=gigun)** として宣言し、`ExecStart` を flake の package に固定する。版が変わった switch で `restartIfChanged` により `dotfiles-autoswitch` が再起動し、健全性ゲートの常駐 unit 一覧にも codex と同じ扱いで入れる。認可トークンが無い機械は `ConditionPathExists` でスキップされ (ゲートは Result=success を許す)、未認可の agy が健全な世代を rollback させない。登録 (`agy remote-control start`) と Google 認可は imperative のままにする。

二重 serve の防止が設計の要である。同一アカウントの `serve` が 2 つ動くと同じ WebChannel セッションを取り合い、`Reconnection attempt N failed` を繰り返す (2026-10-16 実測)。ExecStartPre (`+` = root) が旧ユーザー unit を `disable --now` で止めて unit ファイルごと消し、`agy remote-control start` が再実行されて復活しても、system service の次の (再) 起動で自己修復する。unit ファイルを消すのは、user manager が落ちていても再起動時の自動起動を確実に断てるため。linger は旧ユーザー unit のためだけに有効化していたので `linger-gigun` を外す。

Rejected:

- **agy の unit に drop-in を足し、安定した profile パスを指す** —— 却下。`ExecStart` は固定できるが、版が変わったことを契機に再起動する仕組みが無く、所有も agy のまま。`start` の再実行で unit が書き直される。
- **autoswitch とは別の「アイドル時再起動 timer」** —— 却下。codex の前例 (autoswitch に乗せる) から外れる上、アイドル判定が当てにならない (作業中でも `conversations/*.pb` が現れない)。
- **home-manager の user service** —— 却下。home 構成 `gigun-x86_64-linux` は WSL と共用で、WSL でも常駐してしまう。

Consequences:

- agy は autoswitch (2026-10-16 の timezone 修正 f5a7905 以降 04:00 JST) で版が変わるときに再起動し、その時刻に進行中の会話は中断される。
- `agy remote-control start` の再実行は旧ユーザー unit を復活させる。再登録後は `systemctl restart antigravity-remote-control` で収束させる。
- `agy remote-control status` は旧ユーザー unit を見ている場合 inactive と出得る (判定対象は未検証)。実態は `systemctl status` と journal で見る。
- 認可が切れて serve が失敗し続ける (トークンは在るが二段目の認可が無い) 状態は ConditionPathExists では除外されず、codex と同様にゲートを落とし得る。
