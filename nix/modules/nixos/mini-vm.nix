{
  config,
  modulesPath,
  pkgs,
  lib,
  llmAgents, # inputs.llm-agents.packages.x86_64-linux (flake.nix の specialArgs)
  cloudflareOsRev, # inputs.cloudflare-os.rev (flake.nix の specialArgs)
  homeManager, # inputs.home-manager.packages.x86_64-linux.home-manager (flake.nix の specialArgs)
  ...
}:
let
  username = "gigun";

  # Cloudflare OS のチェックアウト。4 箇所 (ConditionPathExists / WorkingDirectory /
  # ExecStartPre 2 本) から参照するので 1 箇所に括り出す。
  #
  # **2026-09-01 に fork を畳んで本家直結に戻した**。2026-08-11 に gigun-dev へ fork し
  # 「main は upstream を追い、自前パッチは mini ブランチへ」という運用を敷いたが、
  # 3 週間経って独自コミットは 1 本も積まれなかった (upstream/main..HEAD が空)。
  # 担っていない構造を維持すると、ghq のパスが本家と食い違う分だけ読み違いを誘う。
  # gatekeeper に手を入れたくなったらそのとき fork し直せばいい (パスもそのとき戻す)。
  #
  # ここは**編集する作業コピーではない**。ExecStartPre が毎起動時に
  # `git checkout --force --detach <flake.lock の rev>` で強制的に合わせるので、
  # 手で加えた変更は黙って消える。直したいことがあれば upstream へ PR を出すか、
  # 一時的に fork を復活させること。
  cloudflareOsDir = "/home/${username}/ghq/github.com/cloudflare/cloudflare-os";

  # 自動更新 (dotfiles-autoswitch) が switch する dotfiles の作業コピー。
  # cloudflareOsDir と違い**これは編集する作業コピー**で、自動更新は
  # `git pull --ff-only` しかしない (手で書きかけたものを踏み潰さないため)。
  dotfilesDir = "/home/${username}/ghq/github.com/gigun-dev/dotfiles";

  # 更新後にこの VM が「使える状態か」を見るゲート。switch 直後と rollback 直後の
  # 2 回呼ぶので独立したスクリプトにしてある。
  #
  # 項目はこのリポジトリで実際に起きた壊れ方から引いた。抽象的な網羅ではなく、
  # 「ssh は通るのに使えない」を検出することが目的 (DF-12 の教訓)。
  healthGate = pkgs.writeShellScript "mini-vm-health-gate" ''
    set -u
    fail=0

    # (1) 名前解決。2026-08-09 の障害 (dhcpcd と tailscaled の起動順レース、
    #     networking.nameservers のコメント参照) は ping も ssh も通ったまま
    #     名前解決だけが恒久的に死んでいて、到達性テストをすり抜けた。
    if ! getent hosts github.com > /dev/null; then
      echo "gate: 名前解決に失敗 (github.com)" >&2
      fail=1
    fi

    # ConditionPathExists で起動をスキップされた unit は inactive のままになる。
    # その場合 Result は success なので、異常 (落ちた/起動失敗) と区別できる。
    unit_ok() {
      systemctl is-active --quiet "$1" && return 0
      [ "$(systemctl show -p Result --value "$1")" = "success" ]
    }

    # (2) cloudflare-os が実際に応答するか。unit が active でも中では実行時の
    #     pnpm install + Vite ビルドが走っているので、開くまで最大 5 分待つ。
    #     スキップされている機械 (チェックアウトが無い) では待たずに飛ばす。
    if [ "$(systemctl show -p ConditionResult --value cloudflare-os)" = "no" ]; then
      echo "gate: cloudflare-os は条件不成立でスキップ" >&2
    else
      deadline=$(( $(date +%s) + 300 ))
      until curl -sf -o /dev/null http://127.0.0.1:8787; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "gate: cloudflare-os が 5 分以内に応答しない (127.0.0.1:8787)" >&2
          fail=1
          break
        fi
        sleep 10
      done
    fi

    # (3) 常駐 unit の状態。cloudflared の unit 名は tunnel ID から決まる
    #     (services.cloudflared.tunnels の宣言と対で、片方だけ変えると素通りする)。
    for unit in \
      cloudflare-os \
      codex-openai-bridge \
      codex-remote-control \
      cloudflared-tunnel-5b8ec787-4730-4b2b-87b8-e86acbd3954b; do
      if ! unit_ok "$unit"; then
        echo "gate: $unit が異常 ($(systemctl show -p ActiveState -p Result --value "$unit" | tr '\n' ' '))" >&2
        fail=1
      fi
    done

    # (4) codex-remote-control の control socket。スマホから実際に使えるかは機械では
    #     見られないので、pair が探す既定パスに口が開いていることまでを見る。
    #     unit がスキップされている (codex login 前) 機械では socket も無いので見ない。
    if systemctl is-active --quiet codex-remote-control \
      && [ ! -S "/home/${username}/.codex/app-server-control/app-server-control.sock" ]; then
      echo "gate: codex-remote-control の control socket が無い" >&2
      fail=1
    fi

    exit "$fail"
  '';

  # unit の失敗を Bark (iOS プッシュ) へ届ける。$1 = journal を読む unit、$2 = 通知タイトル。
  # 呼び出し側は `EnvironmentFile = "-/run/agenix/bark-env"` で BARK_* を渡すこと。
  #
  # 括り出してあるのは、暗号化の手順を unit ごとに写すと Bark アプリ側の復号設定
  # (鍵と IV は 1 組しか持てない) と食い違ったときの直す場所が増えるため。形式
  # (AES-256-CBC、ciphertext と iv を form で POST) は macOS 側の
  # claude/hooks/bark-notify.sh と必ず揃えること。
  #
  # 依存は store パスで直接呼ぶ。呼び出し側 unit に `path` を書かせると、それも
  # 写しの対象になる。
  barkNotifyUnitFailure = pkgs.writeShellScript "bark-notify-unit-failure" ''
    set -u
    unit=$1
    title=$2

    # 秘密が無い機械では黙って終わる (失敗自体は journal に残る)。
    [ -n "''${BARK_DEVICE_KEY:-}" ] || exit 0
    [ -n "''${BARK_ENCRYPT_KEY:-}" ] || exit 0
    [ -n "''${BARK_ENCRYPT_IV:-}" ] || exit 0

    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt

    # 本文は journal の末尾。Bark の本文長に収まるよう切る。
    body=$(${config.systemd.package}/bin/journalctl -u "$unit" -n 30 --no-pager -o cat 2>/dev/null \
      | ${pkgs.coreutils}/bin/tail -c 900)
    [ -n "$body" ] || body="(journal を取得できなかった)"

    payload=$(${pkgs.jq}/bin/jq -n \
      --arg title "$title" \
      --arg body "$body" \
      --arg group "mini-vm" \
      --arg level "timeSensitive" \
      '{title: $title, body: $body, group: $group, level: $level}')

    key_hex=$(printf '%s' "$BARK_ENCRYPT_KEY" | ${pkgs.coreutils}/bin/od -An -tx1 | tr -d ' \n')
    iv_hex=$(printf '%s' "$BARK_ENCRYPT_IV" | ${pkgs.coreutils}/bin/od -An -tx1 | tr -d ' \n')

    ciphertext=$(printf '%s' "$payload" \
      | ${pkgs.openssl}/bin/openssl enc -aes-256-cbc -K "$key_hex" -iv "$iv_hex" -base64 -A)

    ${pkgs.curl}/bin/curl -sS -m 30 --retry 3 \
      --data-urlencode "ciphertext=$ciphertext" \
      --data-urlencode "iv=$BARK_ENCRYPT_IV" \
      "https://api.day.app/$BARK_DEVICE_KEY" > /dev/null
  '';

  # flake.lock の更新を「提案」する本体。$1 がレーン名で、更新する input が変わる。
  # 呼ぶのは dotfiles-lock-propose@<lane>.service (下の unit にレーンの設計を書いてある)。
  dotfilesLockPropose = pkgs.writeShellScript "dotfiles-lock-propose" ''
    set -eu
    set -o pipefail

    lane=$1
    case "$lane" in
      # AI ツール。上流が速く動くので日次で追う (codex を早く受け取るのがこの仕組みの動機)。
      fast) targets="llm-agents claude-code-overlay cclens" ;;
      # 引数を渡さない `nix flake update` は全 input が対象。
      slow) targets="" ;;
      *)
        echo "未知のレーン: $lane" >&2
        exit 1
        ;;
    esac

    # systemd が StateDirectory で用意する。手で叩くときのために既定値も持たせる。
    state=''${STATE_DIRECTORY:-/var/lib/dotfiles-lock-trial}
    trial="$state/$lane"
    log="$state/$lane.log"
    branch="auto/lock-$lane"

    # **dotfilesDir の作業コピーには触らない**。ここで `nix flake update` すると
    # dotfiles-autoswitch の dirty ガードと `git pull --ff-only` の両方を踏み、毎朝の
    # 自動更新が恒久停止する。使い捨ての worktree に隔離するのはそのため
    # (worktree の作成は .git 配下にしか書かないので、作業コピーは clean のまま)。
    cd ${dotfilesDir}
    git fetch --quiet origin

    rm -rf "$trial"
    git worktree prune # VM が落ちて trap を逃した前回分の登録を消す
    git worktree add --quiet --detach "$trial" origin/main
    trap 'cd ${dotfilesDir}; git worktree remove --force "$trial" > /dev/null 2>&1 || rm -rf "$trial"' EXIT

    cd "$trial"
    # shellcheck disable=SC2086  # 空なら「全 input」の意味なので、あえて分割展開させる
    nix flake update $targets 2>&1 | tee "$log"

    if git diff --quiet -- flake.lock; then
      echo "$lane: lock に差分なし"
      exit 0
    fi

    # ビルドの**前**に commit する。dirty なまま build すると nix が見るのは作業ツリー
    # だが、merge されるのは commit の中身。検証対象と提案物を同一にする。
    git add flake.lock
    git commit --quiet -m "chore(deps): flake.lock を更新 ($lane)" -m "$(cat "$log")"

    # 本番と同じ機械・同じ構成で検証する。これがこの設計の主な利点で、GitHub Actions の
    # ubuntu runner でのビルドに勝る点。
    nix build --no-link '.#nixosConfigurations.mini-vm.config.system.build.toplevel'
    nix build --no-link '.#homeConfigurations.gigun-x86_64-linux.activationPackage'

    # 毎回 origin/main から作り直すので force で上書きする。PR が開いていれば
    # この push だけで中身が入れ替わる (作り直さない)。
    git push --quiet --force origin "HEAD:refs/heads/$branch"

    body=$(printf '%s\n\n```\n%s\n```\n' \
      "mini-vm がこの lock で nixosConfigurations.mini-vm と homeConfigurations.gigun-x86_64-linux のビルドを確認済み。" \
      "$(cat "$log")")

    # `.[0].number` ではなく `.[].number`。前者は PR が無いとき空ではなく "null" を出す。
    if [ -n "$(gh pr list --head "$branch" --state open --json number --jq '.[].number')" ]; then
      gh pr edit "$branch" --body "$body"
    else
      gh pr create --base main --head "$branch" \
        --title "chore(deps): flake.lock を更新 ($lane)" --body "$body"
    fi

    # CI (.github/workflows/nix-build.yaml) が green になったら GitHub が squash merge する。
    # 有効化済みの PR に再度掛けると gh がエラーを返すので、状態を見てから叩く。
    if [ "$(gh pr view "$branch" --json autoMergeRequest --jq '.autoMergeRequest // "off"')" = "off" ]; then
      gh pr merge --auto --squash "$branch"
    fi
  '';
in
{
  # Mac Mini (Intel) 上の Lima VM。
  #
  # 背景: nixpkgs 26.11 が x86_64-darwin を drop し、Apple も macOS 27 で Intel を
  # 切ったため、Mac Mini の macOS 側を nix で管理し続ける道は途絶えた。
  # エージェント基盤 (24/365 の SSH 実行環境) はこの VM に寄せ、macOS 側は
  # Finder 経由の iPhone バックアップ・画面共有・Tailscale だけを担う。
  # ホストは Intel なので x86_64 ゲストがネイティブで動く (vz ドライバ)。
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # Lima のインスタンス名・tailnet 名・hostname はすべて mini-vm に揃えてある
  # (mini は macOS 側を指すので、取り違えると事故る)。
  # なお switch では稼働中の hostname は変わらず、次回 boot から反映される。
  networking.hostName = "mini-vm";

  # lima-init が起動時にユーザーを imperative に作るため true 必須。
  # false だと nixos-rebuild がそのユーザーを消してログインできなくなる。
  users.mutableUsers = true;

  # lima-init / lima-guestagent 等、Lima ゲストとして動くのに必要な一式
  services.lima.enable = true;

  services.openssh.enable = true;

  # 公開鍵認証だけに絞る。2026-08-11 のセキュリティ監査 (M-1) で、既定の
  # `PasswordAuthentication = yes` のまま sshd が 0.0.0.0:22 で待ち受けていることが判明した。
  #
  # **現時点では実害は無い** — `gigun` も `root` も /etc/shadow のパスワード欄が `!`
  # (ロック済み) なので、パスワード認証は実際には成立しない。塞ぐのは「将来 `passwd` で
  # パスワードを設定した瞬間に、総当たり可能な口が開く」という時限式の穴を消すため。
  # 宣言しておけば、誰かが後からパスワードを付けても入口は開かない。
  #
  # このホストは agenix の受信者 (SSH ホスト鍵が復号鍵) なので、侵入されると public repo に
  # ある `secrets/*.age` を全部復号できる。入口はできる限り狭くしておく。
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;

  # tailnet の独立ノードとして参加させ、host の macOS を経由せず直接 ssh する
  services.tailscale.enable = true;

  # 上流 DNS を明示する。MagicDNS への依存を断ち切るための固定値。
  #
  # 2026-08-09 障害修正: 2026-08-06 の再起動 (DF-7 検証) 以降、この VM は名前解決が
  # 全滅していた。tailscaled のログは一貫して
  #   dns: resolver: forward: no upstream resolvers set, returning SERVFAIL
  # を吐いていた。仕組みはこうだった:
  #   1. tailnet 側は global nameserver を配っておらず「system default を使え」と指示する
  #   2. tailscaled は起動時に /etc/resolv.conf を読んで上流を決める
  #   3. しかし boot 直後は dhcpcd がまだ resolv.conf を書いておらず、空を掴む
  #   4. その後 tailscaled 自身が resolv.conf を 100.100.100.100 (=自分) で上書きする
  #   5. 以降、上流ゼロのまま誰も再読み込みしないので、公開名は永久に SERVFAIL
  # つまり dhcpcd と tailscaled の起動順レースで、負けると恒久的に壊れる。
  # ping は通り ssh も通るので、到達性テストでは検出できない (DF-7 はこれをすり抜けた)。
  #
  # ここで静的な nameserver を宣言すると resolvconf の固定エントリになり、DHCP の
  # タイミングに関係なく tailscaled が具体的な上流を読める。レース自体が消える。
  #
  # 却下案:
  #   - tailnet の admin console に global nameserver を設定する → 効くが tailnet 全体に
  #     効いてしまう上に dotfiles の外に出るので、この VM の構成として再現できなくなる。
  #     (併用は有効。あちらは他デバイスの保険になる)
  #   - --accept-dns=false で MagicDNS を捨てる → 一番簡単だが、VM から tailnet 名
  #     (mini など) が引けなくなる。ホスト側へ ssh し返す用途を潰すので採らない。
  #
  # Lima のゲートウェイ (192.168.5.2) も DNS を返すが、Lima のネットワーク実装に
  # 依存する値なので採らない。1.1.1.1 なら VM を作り直しても、Lima 以外へ移しても効く。
  networking.nameservers = [
    "1.1.1.1"
    "1.0.0.1"
  ];

  security.sudo.wheelNeedsPassword = false;

  # nix 設定は darwin/system.nix と揃える (キャッシュを共有するため)
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 7d";
  };
  nix.settings = {
    max-jobs = "auto";
    trusted-users = [
      "root"
      username
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    always-allow-substitutes = true;
    extra-substituters = [
      "https://cache.numtide.com"
      "https://gigun.cachix.org"
      "https://cclens.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.numtide.com-1:bf1jVIGj3GBKisevCptOlNXMoMnPkKlkh89RqPsNJWo="
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "gigun.cachix.org-1:jP3ksvzV3coFUQORcYZOR3repURIK+eYtpMiIMaN788="
      "cclens.cachix.org-1:0QUNU6PuVyf+yXOvg3n1rd3FksBoB3s3/Jty50iKRNQ="
    ];
  };

  # nixos-lima が生成するイメージのレイアウトに合わせた固定値。
  # ここを変えるとブートしなくなるので触らないこと。
  boot.loader.grub = {
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  fileSystems."/boot" = {
    device = lib.mkForce "/dev/vda1"; # /dev/disk/by-label/ESP
    fsType = "vfat";
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
    options = [
      "noatime"
      "nodiratime"
      "discard"
    ];
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  # nix 管理外のプリビルド ELF バイナリを動かすための逃げ道。
  #
  # 動機: Cloudflare OS (workerd / wrangler) を 24/365 でこの VM に置きたい。wrangler は
  # 実行時に @cloudflare/workerd-linux-64 を npm から取ってくるが、これは FHS 前提でビルド
  # された素の ELF で、interpreter が /lib64/ld-linux-x86-64.so.2 を指している。NixOS には
  # そのパスが無いので、nix-ld 無しでは "No such file or directory" で即死する
  # (バイナリは存在するのに出るこのエラーが、NixOS 初見では最も分かりにくい)。
  #
  # 却下案:
  #   - nixpkgs の workerd を使う → wrangler は自分のバージョンに結合した workerd を
  #     同梱・起動する設計なので、外から差し替えても使われない。cloudflare-os の
  #     docs/integration-testing.md も「wrangler と workerd はバージョンが結合している」と
  #     明記している。
  #   - buildFHSEnv でラップ → 対象が wrangler だけなら成立するが、この VM はエージェント
  #     基盤で「npm/pip 由来のバイナリを試しに動かす」用途が今後も繰り返し出る。
  #     その都度ラッパを書くより、逃げ道を 1 本用意しておく方が総コストが低い。
  #
  # なお ~/.local/bin と同じ「例外レーン」の思想。宣言的管理を諦めた領域なので、
  # ここに頼るものが増えてきたら本来は nix 側へ引き上げるべきというサイン。
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # workerd は C++ 製なので libstdc++ が要る。nix-ld の既定セットには含まれないため明示。
    stdenv.cc.cc.lib
  ];

  # CLI ツール群は home-manager standalone (packages.nix) が入れる。
  # ここは VM を最低限操作できるだけの構成に留める。
  environment.systemPackages = with pkgs; [
    gitMinimal
    vim

    # ブラウザ自動化 (chrome-devtools-mcp / Playwright) の実体。
    #
    # なぜ packages.nix ではなくここか: packages.nix は
    # homeConfigurations.gigun-x86_64-linux として WSL と共用されている。WSL 側は
    # 「ブラウザ操作は Windows ネイティブの Chrome に localhost:9222 で繋ぐ」方針
    # (CLAUDE.md の Windows 規約) なので chromium は不要で、共用モジュールに置くと
    # WSL に数百 MB の死蔵が生まれる。mini-vm だけに効かせられる場所がここしかない。
    #
    # chrome-devtools-mcp は実行ファイルを環境変数では受け取らない (--executablePath /
    # --browserUrl / --wsEndpoint のみ。`bunx chrome-devtools-mcp@latest --help` で確認済み)。
    # よって MCP 登録時に絶対パスを渡す必要があるが、nix store パスは更新のたびに変わるため
    # /run/current-system/sw/bin/chromium という安定パスを指すこと。
    # systemPackages に置くのはこの安定パスを得るためでもある。
    chromium
  ];

  # Cloudflare OS を 24/365 常駐させる。
  #
  # 立ち位置: これは「試用インスタンス」であって本番デプロイではない。上流 README の
  # 本番セルフホスト手順 (workerd スタンドアロン) は COMING SOON のままで、KV / R2 /
  # Browser Rendering の代替が提供されていない。それらを miniflare が肩代わりしてくれる
  # `pnpm run-local` を常駐させるのが、現時点で自前ホストに一番近い形になる。
  # 上流が本番手順を出したら、ここは丸ごと置き換わる想定。
  #
  # user service ではなく system service にした理由: user service だと boot 時に上げるのに
  # loginctl enable-linger が要り、それは imperative な状態なので宣言から漏れる。
  # User= を指定した system service なら linger 不要でそのまま boot から上がる。
  #
  # ConditionPathExists でチェックアウトの存在を条件にしている。無いマシンや VM 作り直し
  # 直後に Restart=always と噛み合って無限再起動ループになるのを防ぐため
  # (条件不成立なら systemd は「起動せず成功扱い」にするので静かにスキップされる)。
  systemd.services.cloudflare-os = {
    description = "Cloudflare OS (wrangler dev + workerd) 試用インスタンス";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = "${cloudflareOsDir}/package.json";

    # home-manager の profile には依存させない。nixpkgs の node/pnpm だけで完結させることで、
    # home 層の switch 状況に関係なくこのサービスが成立するようにする。
    # なお pnpm は package.json の packageManager (pnpm@11.17.0) を見て自分でその版へ
    # 切り替える (pnpm 10+ の managePackageManagerVersions が既定 true)。実際、手元の
    # pnpm 11.18.0 から起動しても install ログは "using pnpm v11.17.0" になっていた。
    # よってここの pnpm の版は一致していなくてよい。
    path = with pkgs; [
      nodejs
      pnpm
      # git は ExecStartPre (1) が rev を合わせるのに要る。
      # かつては run-local.mjs 自身が `git ls-files` でソースのハッシュを取っていたが、
      # 上流の af56a9d 時点では run-local.ts に git 参照は無い (Vite+ がキャッシュを持つ)。
      # 理由は変わったが必要性は残っているので、消さないこと。
      git
      bash
      coreutils
      # ps は wrangler のビルドパイプラインが子プロセスの掃除に使う
      # (`ps -o pid --no-headers --ppid <pid>` を spawn する)。無いと
      # "Error: spawn ps ENOENT" でサービスごと落ちる。対話 shell では
      # 常に PATH にあるため、systemd 化して初めて表面化した。
      procps
      # workerd が外向き HTTPS を張るのに要る (下の SSL_CERT_FILE 参照)。
      cacert
    ];

    environment = {
      HOME = "/home/${username}";

      # 2026-08-10 障害修正: これが無いと workerd の外向き HTTPS が全滅する。
      #   kj/compat/tls.c++:269: failed: TLS peer's certificate is not trusted;
      #   reason = unable to get local issuer certificate
      # 最初に踏んだのは Cloudflare Access の JWKS 取得
      # (https://<team>.cloudflareaccess.com/cdn-cgi/access/certs) で、画面には
      # "Can't reach the server. Retrying..." としか出ず原因が見えなかった。
      # AI プロバイダへの推論リクエストも同じ経路なので、どのみち踏む地雷だった。
      #
      # 対話シェルでは NixOS が SSL_CERT_FILE を自動で入れるため手動起動では再現せず、
      # 環境を絞った systemd service にして初めて表面化する。procps の件と同じ罠。
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

      # フロントエンドを Cloudflare Access モードでビルドする。
      #
      # これはバックエンドの CF_ACCESS_AUD とは別物で、**ビルド時に SPA へ焼き込まれる**フラグ
      # (workshop-frontend/src/useAuth.ts:5 が import.meta.env.VITE_CF_ACCESS_MODE を見る)。
      # false のままだと、バックエンドが Access 待ち受けでもフロントは
      # authenticateFromCfAccess() を一度も呼ばず、ひたすらユーザー名/パスワード画面を出す。
      # 「バックエンドを直したのに直らない」という症状の正体がこれだった。
      #
      # 上流の公式リリースビルド (scripts/release/build-release.mjs) は同じ変数を "true" にして
      # Access 版フロントを作っている。run-local の vite build には渡されないだけで、
      # 仕組みとしては上流が用意したもの。vite は VITE_ 接頭辞の環境変数を拾うので
      # ここで渡せば足りる (リポジトリ側の改変は不要)。
      #
      # 注意: ビルドはキャッシュされるので、この変数を足しただけでは古いバンドルが
      # 使われ続けることがある。効いていないと思ったらキャッシュを捨てて作り直すこと。
      #
      # (2026-09-01 更新) キャッシュの持ち主が変わった。以前は run-local.mjs が
      # `git ls-files` でソースのハッシュを取り `.run-local-stamp` と突き合わせていたが、
      # 上流の af56a9d 時点では run-local.ts が Vite+ (`vp run --cache`) に委ねている。
      # よって「.run-local-stamp を消す」という以前の逃げ道はもう無い。
      VITE_CF_ACCESS_MODE = "true";
    };

    serviceConfig = {
      Type = "simple";
      User = username;
      WorkingDirectory = cloudflareOsDir;

      # 各 gatekeeper に BASE_URL を配る。
      #
      # gatekeeper は OAuth の redirect URI と接続用 URL を BASE_URL から組み立てる。既定の
      # `http://localhost:8787/gatekeeper/<name>` はトンネルの後ろではブラウザから開けず
      # Not Found になる (Slack 接続で実際に踏んだ)。上流のリリースビルドは
      # `$PUBLIC_BASE_URL/gatekeeper/<name>` を配っている (scripts/release/manifest-lib.mjs) が
      # run-dev-server.js は面倒を見ない — ローカル実行は localhost が本物の origin である
      # 前提のため。VITE_CF_ACCESS_MODE と同じ「本番用の配線が dev に無い」類型。
      #
      # 届け方: wrangler は設定ファイルと同じディレクトリの .dev.vars を自分で読む。これを
      # 起動のたびに生成する (上流を patch しない。.dev.vars は gitignore 済みなので
      # checkout の差分もゼロ)。扱う値はどれも秘密ではない (Access の aud は全 JWT ヘッダに
      # 入り、iss は公開の team ドメイン) ので、agenix ではなく宣言から生成する。
      ExecStartPre = [
        # (1) 作業コピーを flake.lock が指す rev へ合わせる。
        #
        # **これが「版の宣言管理」の実体**。以前は誰も版を固定しておらず、mini-vm の
        # 作業コピーの HEAD がたまたまの版だった。実際 2026-09-01 に upstream から
        # 106 コミット (3 週間) 遅れているのを偶然見つけている。遅れそのものより
        # 「気づけない」ことが問題で、pin すれば上流は自分が更新したときにしか動かない。
        #
        # 更新の手順は codex (llm-agents) と同じレーンに乗る:
        #   dotfiles で `nix flake update cloudflare-os` → lock を commit/push
        #   → mini-vm で `git pull && nix run .#switch`
        # nix はソースをビルドしない (`flake = false`)。運ぶのは rev だけで、
        # 実際に checkout するのはここ。
        #
        # **Why not derivation 化**: run-local.ts は実行時に `pnpm install` +
        # Vite+ のビルドを回す (27 ワークスペース / node_modules 874MB)。これを Nix に
        # 載せると上流が lockfile を触るたびに壊れるのに、得られるのは dev サーバの
        # 起動の再現性という薄い利益しかない。動かしているのは wrangler dev であって
        # 配布物ではないので、版だけ固定してビルドは実行時に任せるのが釣り合う。
        #
        # **`git clean` はしないこと**。node_modules (874MB) を毎起動時に取り直すことになる。
        # .dev.vars は gitignore 済みなので `checkout --force` でも消えない。
        (pkgs.writeShellScript "cloudflare-os-sync-rev" ''
          set -eu
          root=${cloudflareOsDir}
          rev=${cloudflareOsRev}
          cd "$root"

          # 既に目的の rev なら fetch も要らない (再起動のたびにネットワークを叩かない)。
          if [ "$(git rev-parse HEAD)" != "$rev" ]; then
            git fetch --quiet origin
            git checkout --quiet --force --detach "$rev"
          fi
        '')

        # (2) 非秘密の設定を .dev.vars として生成する。
        # rev を合わせた**後**に走らせること。gatekeeper パッケージの構成は rev で変わる。
        (pkgs.writeShellScript "cloudflare-os-generate-dev-vars" ''
          set -eu
          root=${cloudflareOsDir}
          base=https://os.097969.xyz

          # ルート: run-dev-server.js が自前で読み、allowlist にある変数だけを worker へ渡す。
          printf 'PUBLIC_BASE_URL=%s\n' "$base" > "$root/.dev.vars"

          # backend: Cloudflare Access 認証の有効化。この 2 つが揃って初めて有効になる。
          # ここに置くのは、ルートの .dev.vars では run-dev-server.js の allowlist
          # (OPTIONAL_FEATURE_VARS) に CF_ACCESS_* が無く worker まで届かないため。
          {
            printf 'CF_ACCESS_AUD=%s\n' "171feed26a9a959a47baea51a250993280867e6a264baca9328220dc93fbf419"
            printf 'CF_ACCESS_ISS=%s\n' "https://gigun.cloudflareaccess.com"
          } > "$root/packages/workshop-backend/.dev.vars"

          # gatekeeper: OAuth の redirect URI と接続 URL の組み立てに使う。
          # 既定は http://localhost:8787/gatekeeper/<name> で、トンネルの後ろでは開けない。
          for dir in "$root"/packages/gatekeeper-*/; do
            [ -d "$dir" ] || continue
            pkg=$(basename "$dir")
            # パッケージ名 gatekeeper-slack → URL 上の短縮名 slack
            # (router のパス走査もこの短縮名で行われる)
            short=''${pkg#gatekeeper-}
            printf 'BASE_URL=%s/gatekeeper/%s\n' "$base" "$short" > "$dir/.dev.vars"

            # OAuth の client id / secret など、gatekeeper 固有の秘密を継ぎ足す。
            #
            # 秘密なので agenix 側から来る (age.secrets.gatekeeper-<short>-env)。ここが
            # 追記 (>>) なのは、直前の BASE_URL を消さないため。
            #
            # **命名が規約になっている**: 短縮名 <short> の gatekeeper が秘密を要るなら
            # age.secrets.gatekeeper-<short>-env を足せばよく、このスクリプトは
            # 触らずに済む。新しい gatekeeper を繋ぐときの作業は
            #   (1) 提供元で OAuth App を作る (ブラウザ必須。GitHub の場合 REST API に
            #       OAuth App 作成の口が無く gh CLI でも作れない)
            #   (2) `agenix -e secrets/gatekeeper-<short>-env.age` に KEY=VALUE で書く
            #   (3) secrets.nix と下の age.secrets に 1 エントリ足す
            # の 3 つだけになる。
            #
            # **Why not EnvironmentFile**: サービス全体の環境変数にすると、全 gatekeeper が
            # 同じ CLIENT_ID / CLIENT_SECRET を見ることになる (変数名が gatekeeper 間で
            # 共通のため、github の値を slack が拾う)。.dev.vars は wrangler が設定ファイルと
            # 同じディレクトリのものだけを読むので、worker 単位に閉じ込められる。
            # agenix の既定の置き場 (/run/agenix) をそのまま使う。
            #
            # 当初は他の秘密に合わせて /var/lib/cloudflare-os/gatekeeper-<short>.env へ
            # path を切ったが、**そのディレクトリは agenix が root 0700 で作る**ため
            # User=${username} で走るこのスクリプトから辿れず、秘密は届かないのに
            # ExecStartPre は成功し、gatekeeper だけが Not Configured のまま黙る、
            # という一番たちの悪い形になった (実測)。
            # /run/agenix.d は root:keys 0751 で others に x があるので、パスを直接
            # 指定すれば (listing はできなくても) 読める。
            secret="/run/agenix/gatekeeper-$short-env"
            # -r で見るのは、存在しても読めない (所有権ミス) 場合に静かに素通りさせないため —
            # と言いたいところだが set -eu 下でも [ ] は失敗しても止まらないので、
            # 読めなければ「未設定」として扱われ gatekeeper 側が Not Configured 画面を出す。
            # 症状から遡れるように、ここでは黙らずログへ落としておく。
            if [ -e "$secret" ]; then
              if [ -r "$secret" ]; then
                cat "$secret" >> "$dir/.dev.vars"
              else
                echo "warning: $secret exists but is not readable by $(id -un); $short will report Not Configured" >&2
              fi
            fi
          done
        '')
      ];

      # --use-workers-ai-binding を付けると生成される worker 設定に
      # `ai: { binding: "WORKERS_AI" }` が入り、env.WORKERS_AI が生える。
      # これを使うのは webFetch の文書→Markdown 変換だけ (推論本体は HTTPS + トークン経由)。
      # 無いと WebFetchEnv.ai が undefined のまま `env.ai.toMarkdown()` が呼ばれて
      # TypeError になり、HTML/PDF/DOCX を取りに行った時点で webFetch が壊れる
      # (ガードが無い。web-fetch.ts:26 の `ai: Ai` は必須フィールド)。
      #
      # 変換対象は Workers AI のモデルを使わない形式に絞られていて課金は発生しない。
      # 画像だけは意図的に除外されている (有料モデルを使うため)。
      #
      # **必要な権限に注意**: Workers AI バインディングは `AI / remote` としてリモート実行され、
      # wrangler がリモートセッションを張る。このセッション生成には Workers AI の権限だけでは
      # 足りず、**Workers Scripts: Edit** が別途要る。無いとサービスが起動時に落ちる:
      #   This Worker uses bindings that need to run remotely, even when developing
      #   locally, but the remote session could not be authenticated.
      # トークンが有効でも (Workers AI の REST は 200 を返していた) この症状が出るので、
      # 「トークンが壊れている」と誤診しやすい。
      # 上流の既知の制約で、狭い権限で動くようにする要望が上がっている:
      #   https://github.com/cloudflare/workers-sdk/issues/10091
      #
      # 引き換えに影響範囲は広がっている。Workers Scripts: Edit はアカウント内の Worker を
      # デプロイ・改変・削除できる権限で、このトークンは無期限かつ 24/365 の機械にある。
      # webFetch の文書→Markdown 変換と引き換えに受け入れた判断であることを覚えておくこと。
      ExecStart = "${pkgs.pnpm}/bin/pnpm run-local --use-workers-ai-binding";
      Restart = "always";
      RestartSec = 10;

      # 秘密の受け渡し口。dotfiles は public なので、トークン類は git に入れず
      # root 所有 0400 のこのファイルへ置き、systemd 経由で環境変数として渡す。
      # (Cloudflare の API トークン等。書式は KEY=VALUE の 1 行 1 件)
      #
      # 先頭の "-" は「無ければ黙って無視する」指定。まだ配置していないマシンや
      # VM 作り直し直後でもサービスが起動できるようにするため
      # (cloudflare-os 本体は ConditionPathExists で守っているが、こちらは
      #  秘密が無くても動く機能があるので、起動そのものは止めない方が良い)。
      EnvironmentFile = "-/var/lib/cloudflare-os/env";
    };
  };

  # 秘密の宣言管理 (agenix)。暗号文は secrets/*.age として git に入っており、
  # このホストの SSH ホスト鍵で activation 時に復号される。受信者は secrets/secrets.nix。
  #
  # これを入れる前は 4 つの秘密を手で置いており、VM を作り直すと全部消えて手作業に
  # 戻る状態だった。置き場所を忘れたら復旧できないという意味で、宣言管理から最も遠い部分だった。
  #
  # path を明示しているのは、既存のサービス定義 (credentialsFile / EnvironmentFile) を
  # 書き換えずに済ませるため。agenix の既定は /run/agenix/<name>。
  age.secrets = {
    cloudflared-cloudflare-os = {
      file = ../../../secrets/cloudflared-cloudflare-os.json.age;
      path = "/var/lib/cloudflared/cloudflare-os.json";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    cloudflare-os-env = {
      file = ../../../secrets/cloudflare-os-env.age;
      path = "/var/lib/cloudflare-os/env";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    # GitHub gatekeeper の OAuth App 資格情報 (CLIENT_ID / CLIENT_SECRET)。
    #
    # owner が root ではなく username なのは、これを読むのが ExecStartPre の
    # dev-vars 生成スクリプトで、そのスクリプトが serviceConfig.User = username で
    # 走るため。root 0400 にすると読めず、gatekeeper は Not Configured 画面のまま
    # 何も言わずに沈黙する (ExecStartPre が失敗するわけではないので気づきにくい)。
    #
    # ファイル名の -env は「KEY=VALUE 形式」の目印。cloudflare-os-env と同じ規約。
    #
    # path を指定していないのは既定 (/run/agenix/<name>) で足りるから。他の秘密に
    # 合わせて /var/lib/cloudflare-os/ へ置こうとすると、agenix がそのディレクトリを
    # root 0700 で作るせいで username から読めなくなる (上の生成スクリプト参照)。
    gatekeeper-github-env = {
      file = ../../../secrets/gatekeeper-github-env.age;
      owner = username;
      group = "users";
      mode = "0400";
    };

    # ブリッジは既定で ~/.config/openai-api-server-via-codex/config.toml を読むが、
    # home 配下へ agenix で配ると activation の順序と所有権が絡んで面倒なので、
    # /var/lib 配下に置いて ExecStart で --config を明示する形にした。
    codex-bridge-config = {
      file = ../../../secrets/codex-bridge-config.toml.age;
      path = "/var/lib/codex-bridge/config.toml";
      owner = username;
      group = "users";
      mode = "0400";
    };

    # Bark (iOS プッシュ通知) の宛先と暗号鍵。自動更新の失敗通知が読む。
    # 読むのが root で走る unit なので既定の root 0400 のまま。
    bark-env = {
      file = ../../../secrets/bark-env.age;
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  # Cloudflare named tunnel。Cloudflare OS の公開経路を tailnet から Cloudflare へ移す。
  #
  # 狙い: 認証の境界を Cloudflare Access (エッジ) に置く。tailscale serve だと境界が
  # 「tailnet に居るかどうか」になり、Cloudflare アカウントでのログインにならなかった。
  # トンネルを張るとエッジが前段に立つので Access が使える。Tailscale は ssh 用に残す。
  #
  # Access 側は API で作成済み:
  #   アプリ  Cloudflare OS (mini-vm) / os.097969.xyz / self_hosted / session 168h
  #   ポリシー gigun-dev account members (include: cloudflare_account_member)
  #   aud     171feed26a9a959a47baea51a250993280867e6a264baca9328220dc93fbf419
  # Cloudflare OS 自身が Access を一級の認証方式として持ち、Access の verified email で
  # UserDurableObject を引く (docs/oauth-signin.md: "the same scheme as Cloudflare Access")。
  # そのためアプリ内 OAuth gatekeeper を足さなくてもログインが完結する。
  #
  # 積み残し: cloudflared 側で Cf-Access-Jwt-Assertion を検証する originRequest.access は
  # NixOS モジュールが公開していない (originRequest に access オプションが無い)。
  # 多層防御の 1 枚を諦めている。主境界であるエッジの Access は効いているので実害は小さいが、
  # Access の設定を消すと素通しになる点は覚えておくこと。
  #
  # config_src は local を選んだ。ingress を Cloudflare 側の管理画面ではなくこのファイルに
  # 置きたいため (宣言的管理の方針)。remote 管理にすると ingress が git の外へ出る。
  services.cloudflared = {
    enable = true;
    tunnels."5b8ec787-4730-4b2b-87b8-e86acbd3954b" = {
      # 秘密なので git には入れない。root 所有 0400 で置き、systemd の LoadCredential が
      # DynamicUser へ渡す (モジュールが serviceConfig.LoadCredential を設定している)。
      credentialsFile = "/var/lib/cloudflared/cloudflare-os.json";
      ingress = {
        "os.097969.xyz".service = "http://127.0.0.1:8787";

        # ChatGPT サブスク枠を mini の外からも使えるようにする口。
        #
        # ここには **Access を張らない**。Access で守ると
        # CF-Access-Client-Id / CF-Access-Client-Secret ヘッダが要るが、Cloudflare OS の
        # Add Model 画面は apiUrl と apiToken (= Authorization: Bearer) しか送れず、
        # カスタムヘッダを足す口が無いため噛み合わない。
        # 代わりにブリッジ自身の api_key で守る (Authorization ヘッダに乗るので噛み合う)。
        # 鍵は ~/.config/openai-api-server-via-codex/config.toml (0600) にあり git には無い。
        #
        # **ローカルの Cloudflare OS はこの URL を使わないこと。** 同じ mini に居るので
        # http://127.0.0.1:18080/v1 へループバックで届く。トンネル経由にすると
        # mini → Cloudflare エッジ → mini と往復する上、エッジやトンネルの不調が
        # ローカルの AI まで巻き込む。ループバックは落ちない。
        # この口の価値は「mini の外から使えること」だけ。
        "codex.097969.xyz".service = "http://127.0.0.1:18080";
      };
      # 宣言していないホスト名は原点まで通さない。トンネルを他用途へ流用されないための既定。
      default = "http_status:404";
    };
  };

  # 認証情報がまだ置かれていないマシンで LoadCredential が失敗して騒がしくなるのを防ぐ。
  # cloudflare-os / codex-openai-bridge と同じ考え方 (条件不成立なら静かにスキップ)。
  systemd.services."cloudflared-tunnel-5b8ec787-4730-4b2b-87b8-e86acbd3954b".unitConfig.ConditionPathExists =
    "/var/lib/cloudflared/cloudflare-os.json";

  # ChatGPT サブスク枠を OpenAPI 互換エンドポイントとして生やすブリッジ。
  #
  # 狙い: Cloudflare OS の AI プロバイダに ChatGPT の Codex 枠を使う。Cloudflare OS の
  # openai プロバイダは `openai-responses` を喋り、このブリッジは `/v1/responses` を
  # 実装しているので形式が合う。モデル登録側は provider=openai +
  # apiUrl=http://127.0.0.1:18080/v1 になる。
  #
  # なぜ mini でなければならないか: workshop-backend の compatibility_flags には
  # `global_fetch_strictly_public` が入っており、本番 Worker からは localhost や
  # プライベート IP へ fetch できない (SSRF 対策)。`wrangler dev` だけが意図的に
  # この制限を外している。つまりブリッジを使う構成は run-local と同居させるしかない。
  #
  # 127.0.0.1 に閉じているので --api-key は付けない。ブリッジ自身の README も
  # 「公開ネットワークに晒すなら --api-key 必須」としており、裏を返せばローカル限定なら不要。
  # tailscale serve が外に出しているのは 8787 だけで、このポートは出していない。
  #
  # ConditionPathExists は cloudflare-os と同じ理由 (`codex login` 前は auth.json が無い)。
  # ログイン後に systemctl start すれば上がる。
  systemd.services.codex-openai-bridge = {
    description = "ChatGPT (Codex) 枠を OpenAI 互換 API として出すブリッジ";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = "/home/${username}/.codex/auth.json";

    # uvx は実行時に PyPI から取ってくる。nixpkgs に無いツールなので uv 経由にしている
    # (CLAUDE.md の「~/.local/bin は例外レーン」と同じ発想で、宣言できないものを一箇所に隔離する)。
    # バージョンは意図的に固定しない。こちらは fork も改造もしておらず、上流の最新を
    # そのまま使いたい (軽量化や codex 側 API 追従の恩恵を取りこぼさない) ため。
    # Why not 固定: ピン留めすると「上流が動いたら手で上げる」作業が発生し、
    # 放置すると codex バックエンドの仕様変更に取り残されて逆に壊れる。
    # 代償として破壊的変更は再起動時にそのまま踏む。実際 v0.2.0 で Python/FastAPI から
    # Go 実装へ全面置換されたが、serve / --config / --host / --port / --auth-json と
    # config.toml のキー ([server].api_key 等) は据え置きだったのでこの unit は無変更で通った
    # (2026-09-01 に再起動して 0.2.0 で疎通確認済み)。
    # 壊れたときの逃げ道: ExecStart の引数を
    # `uvx openai-api-server-via-codex@X.Y.Z serve ...` にすれば即座に版を戻せる。
    path = with pkgs; [
      uv
      cacert # uv が PyPI へ HTTPS で取りに行くのに要る
    ];

    environment = {
      HOME = "/home/${username}";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

    serviceConfig = {
      Type = "simple";
      User = username;
      WorkingDirectory = "/home/${username}";
      # --config は agenix が復号した設定 (api_key を含む) を指す。既定の
      # ~/.config/... ではなく /var/lib 配下に置いているため明示が要る。
      ExecStart =
        "${pkgs.uv}/bin/uvx openai-api-server-via-codex serve"
        + " --config /var/lib/codex-bridge/config.toml"
        + " --host 127.0.0.1 --port 18080"
        + " --auth-json /home/${username}/.codex/auth.json";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # スマホ (ChatGPT アプリ) から mini-vm の Codex を実行環境として使うための常駐。
  #
  # 狙い: ssh も公開ポートも無しでスマホから Codex を回す。app-server は
  # chatgpt.com 側のリレー (backend-api/wham/remote/control/server) へ **アウトバウンドで**
  # WebSocket を張り、スマホはリレー越しに繋ぐ。受け口を開けないので、隣の
  # codex-openai-bridge (codex.097969.xyz) が抱えている「守りが api_key 1 枚」問題が
  # 構造的に発生しない。
  #
  # 用途は codex-openai-bridge と別物なので両方残す。あちらは Cloudflare OS から叩く
  # OpenAI 互換 API、こちらは Codex そのものをスマホから操作する口。
  #
  # **Why not `codex remote-control start` / `codex app-server daemon bootstrap`**:
  # 上流が案内する起動方法はこれだが、どちらも
  # `~/.codex/packages/standalone/current/codex` の standalone install を必須にする
  # (実際 `remote-control start` はそれが無いと "managed standalone Codex install not
  # found" で落ちる)。bootstrap はそこへ install.sh 経由で別バイナリを落とし、
  # **1 時間ごとに自己更新するループを回す**。つまり flake.lock を見ても実際に動いている
  # 版が分からなくなり、上流の変更が予告なく降ってくる。さらに daemon 化は pidfile 方式で
  # systemd に登録しないため、VM 再起動で消え更新ループも戻らない。
  # → 「常駐と再起動耐性」は systemd がやればよく、standalone install は要らない。
  #
  # **Why `--listen unix://` (not `off`)**: `off` でもリレーには繋がるが、
  # `codex remote-control pair` が探す既定パスの control socket
  # (~/.codex/app-server-control/app-server-control.sock) が作られず、ペアリングコードを
  # 発行できない (前景起動は一時ディレクトリの rc.sock を使うため)。`unix://` を渡すと
  # 既定パスに作られ、daemon 無しで pair が通る。ここが daemon を回避できた分岐点。
  # なおこの socket は 0600 / ユーザー所有で、ネットワークには一切出ない。
  #
  # ペアリングは手動の一度きりの作業: `codex remote-control pair` でコードを出し、
  # スマホ側で入力する。コードは短命なので、切れたら叩き直す。
  #
  # ConditionPathExists は codex-openai-bridge と同じ理由。
  systemd.services.codex-remote-control = {
    description = "Codex app-server (remote control) — スマホから mini-vm の Codex を使う口";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    unitConfig.ConditionPathExists = "/home/${username}/.codex/auth.json";

    environment = {
      HOME = "/home/${username}";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

    serviceConfig = {
      Type = "simple";
      User = username;
      WorkingDirectory = "/home/${username}";
      ExecStart = "${llmAgents.codex}/bin/codex app-server --remote-control --listen unix://";
      Restart = "always";
      RestartSec = 10;
    };
  };

  # root が gigun 所有の dotfiles を flake として読めるようにする。
  #
  # 2026-09-06 に実機で判明。自動更新は nixos-rebuild を root で走らせるが、
  # **nix 自身 (libgit2) が所有者を検証して弾く**:
  #   repository path '...' is not owned by current user (libgit2 error code = 7)
  # git の safe.directory 保護と同じ仕組みが nix 側にもある。git コマンドの方は
  # sudo -u gigun で回避したが、nixos-rebuild は root でしか動かせないので
  # ここで許可するしかない。
  #
  # 却下案: --flake path:... で git を介さずディレクトリごとコピーさせる →
  # 通るが「nix は git index から評価する」という前提が崩れ、手動 switch
  # (CLAUDE.md の `git add` 必須ルール) と挙動が食い違う。
  programs.git = {
    enable = true;
    config.safe.directory = dotfilesDir;
  };

  # dotfiles を毎日取り込んで switch する。**この機械は無人運用**で、手で
  # `git pull && nix run .#switch` を打つ機会が無いと、push 済みの変更が
  # 何週間も届かないまま気づけない (cloudflare-os で実際に 106 コミット遅れた)。
  #
  # 自動化するのは**適用だけ**。`nix flake update` はここでは絶対にやらない —
  # lock の更新はレビューを通す (手元で update → commit/push) 経路に閉じる。
  # ここが破られると、無人機がレビュー無しで世界の変化を取り込むことになる。
  #
  # 却下案:
  #   - system.autoUpgrade → home 層が視野の外 (nixos-rebuild しか叩かない) で、
  #     pre/post フックが無いため健全性ゲートも dirty ガードも挟めない。
  #     提供されるのは timer 1 本分だけなので、自前で書いた方が読める。
  #   - --flake github:gigun-dev/dotfiles の直接参照 → 手動 switch (作業コピー) と
  #     自動更新 (github:) で真実が二重になり、「いま動いている rev」を作業コピーから
  #     読めなくなる。ローカル pull なら食い違いが下の dirty ガードで鳴る。
  #
  # 駆動スクリプトは**現 generation のもの**が走る。新しいツリーが更新器自身を
  # 壊しても、次回は壊れる前の更新器で回る (自己更新は 1 サイクル遅れる)。
  systemd.services.dotfiles-autoswitch = {
    description = "dotfiles を pull して system + home を switch する";
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];

    unitConfig = {
      ConditionPathExists = "${dotfilesDir}/flake.nix";
      OnFailure = [ "dotfiles-autoswitch-notify-failure.service" ];
    };

    # systemd の unit は対話 shell の PATH を継承しない。ここに挙げたものだけが
    # 見える。2026-09-06 に実機で nixos-rebuild と getent の欠落を踏んだ
    # (前者は status=127 で即死、後者は健全性ゲートが黙って落ちる)。
    path = with pkgs; [
      git
      openssh # git pull が SSH remote を使う場合に要る
      nix
      nixos-rebuild # system 層の switch 本体
      systemd
      curl
      coreutils
      gnugrep
      getent # 健全性ゲートの名前解決確認。pkgs.glibc の out には入っていない
      nix # nix-env --rollback (下の rollback 手順で使う)
    ];

    environment.NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

    serviceConfig = {
      Type = "oneshot";
      # nixos-rebuild に root が要る。home 層だけは下で sudo -u gigun に落とす。
      User = "root";
      # switch は substituter 待ちで長引くことがある。既定の 90 秒では足りない。
      TimeoutStartSec = "60min";

      ExecStart = pkgs.writeShellScript "dotfiles-autoswitch" ''
        set -eu
        cd ${dotfilesDir}

        # git はリポジトリの所有者 (gigun) で叩く。2026-09-06 に実機で判明:
        # root で叩くと `detected dubious ownership` (safe.directory 保護) で
        # 即死する。加えて pull の認証情報 (gh credential helper) は gigun の
        # 設定にしか無いので、どのみち root では引けない。
        as_user() { ${pkgs.sudo}/bin/sudo -u ${username} "$@"; }

        # dirty ガード。**これは弱点ではなく検知器**。作業コピーが汚れているのは
        # 「誰かが VM 上で dotfiles をいじって放置した」ということなので、
        # 黙って踏み潰さず、更新を止めて通知する (翌朝それを知れる)。
        if [ -n "$(as_user ${pkgs.git}/bin/git status --porcelain)" ]; then
          echo "作業コピーが dirty。更新を中止する" >&2
          as_user ${pkgs.git}/bin/git status --short >&2
          exit 1
        fi

        # --ff-only。分岐していたら人間の裁定事項なので、ここでは止める。
        as_user ${pkgs.git}/bin/git pull --ff-only

        # system 層 → home 層の順。system unit は home profile に依存しない設計
        # (cloudflare-os / codex-* は store パスを直接参照) なので、home 側が
        # 失敗しても常駐サービスは巻き添えにならない。
        nixos-rebuild switch --flake "${dotfilesDir}#mini-vm"
        ${pkgs.sudo}/bin/sudo -u ${username} ${homeManager}/bin/home-manager \
          switch --flake "${dotfilesDir}#${username}-x86_64-linux"

        # 「switch は成功したが使えない」を検出する。失敗したら 1 世代戻して、
        # 戻した先でもゲートを回してから落ちる (戻して直ったのかを記録に残すため)。
        if ! ${healthGate}; then
          echo "健全性ゲートが失敗。rollback する" >&2
          # **`nixos-rebuild switch --rollback` は使えない** (2026-09-06 実測)。
          # flake モードでは実装されておらず `<nixpkgs/nixos>` を NIX_PATH に
          # 探しに行って失敗する。profile を 1 つ戻して switch-to-configuration を
          # 直接叩くのが flake 環境での正しい手順。
          nix-env --rollback -p /nix/var/nix/profiles/system
          /nix/var/nix/profiles/system/bin/switch-to-configuration switch
          if ${healthGate}; then
            echo "rollback 後はゲートを通過した" >&2
          else
            echo "rollback してもゲートが失敗している" >&2
          fi
          exit 1
        fi
      '';
    };
  };

  # **再起動はしない**。boot.kernelPackages = linuxPackages_latest なので kernel は
  # 頻繁に上がり、稼働カーネルと /run/current-system はズレ続けるが、無人で再起動を
  # 掛ける前に DF-33 (再起動後に codex-remote-control が復帰し、スマホから繋がるか)
  # の実測が要る。解禁は DF-33 の完了条件に紐付けてある。
  systemd.timers.dotfiles-autoswitch = {
    description = "dotfiles-autoswitch を毎日回す";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      # 4 時ちょうどに substituter へ殺到しないよう散らす。
      RandomizedDelaySec = 1800;
      # VM が止まっていて発火を逃した分は、次に上がったときに 1 回だけ回す。
      Persistent = true;
    };
  };

  # 失敗を人へ届ける。無人機なので、これが無いと更新が何週間止まっても気づけない。
  #
  # 積み残し: これは「失敗したら鳴らす」だけで、**沈黙は検出できない**
  # (timer が発火しない / VM ごと落ちる / 通知経路が死ぬ)。成功のたびに外部へ
  # ping を打ち、途絶を外部に鳴らさせる形が要る。
  systemd.services.dotfiles-autoswitch-notify-failure = {
    description = "dotfiles-autoswitch の失敗を Bark へ通知する";

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = "-/run/agenix/bark-env";
      ExecStart = "${barkNotifyUnitFailure} dotfiles-autoswitch.service 'mini-vm 自動更新 失敗'";
    };
  };

  # flake.lock の更新を提案する。**適用はしない** — PR を出して CI に通し、merge されたら
  # 翌朝の dotfiles-autoswitch が普通の main の変更として拾う。
  #
  # 何を埋めるか: dotfiles-autoswitch は main を適用するだけなので、`nix flake update` を
  # 誰も叩かない限り上流の新版 (codex 等) は永久に届かない。実測で lock の更新は 2〜4 週間
  # 空いていた。ここは「更新を提案する側」を無人機に持たせて、判断 (merge) は CI と人に残す。
  #
  # 却下案:
  #   - GitHub Actions の update-flake-lock + PAT → 既存 workflow は secrets ゼロ・token
  #     read-only。そこへ書き込み可能な秘密を置くのは量ではなく質の変化。加えて ubuntu
  #     runner でのビルドは、実際に適用される機械そのもので検証するのに劣る。
  #   - mini-vm が main へ直接 commit/push → 共有 lock の生産者が無人機になり、M4 Pro が
  #     「無人機が決めた lock」を pull する側に回る。
  #   - dotfilesDir の作業コピーで直接 `nix flake update` → autoswitch が恒久停止する
  #     (スクリプト側のコメント参照)。
  #
  # テンプレート unit にしたのは、fast/slow の差が「更新対象の input」と「発火間隔」だけで、
  # 手順が完全に同じため。instance 名がそのままレーン名になる。
  systemd.services."dotfiles-lock-propose@" = {
    description = "flake.lock を更新・検証して PR を出す (%i レーン)";
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];

    unitConfig = {
      ConditionPathExists = "${dotfilesDir}/flake.nix";
      OnFailure = [ "dotfiles-lock-propose-notify-failure@%i.service" ];
    };

    # 対話 shell の PATH は継承されない。2026-09-06 に autoswitch で nixos-rebuild と
    # getent の欠落を踏んでいるので、ここは実際に使うものを全部並べる。
    path = with pkgs; [
      git
      openssh
      nix
      gh
      coreutils
      gnugrep
      jq
      curl
      openssl
      cacert
    ];

    environment = {
      # git の user.* と gh の認証情報は gigun の home にしか無い。
      HOME = "/home/${username}";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

    serviceConfig = {
      Type = "oneshot";
      # root は要らない (ビルドと git 操作だけ)。リポジトリの所有者で走らせれば
      # autoswitch が踏んだ safe.directory / libgit2 の所有者検証も起きない。
      User = username;
      # 使い捨て worktree の置き場。systemd が作って STATE_DIRECTORY で渡す。
      StateDirectory = "dotfiles-lock-trial";
      # 全 input 更新 (slow) は substituter が効かず素のビルドになることがある。
      TimeoutStartSec = "90min";
      ExecStart = "${dotfilesLockPropose} %i";
    };
  };

  systemd.services."dotfiles-lock-propose-notify-failure@" = {
    description = "dotfiles-lock-propose@%i の失敗を Bark へ通知する";

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      EnvironmentFile = "-/run/agenix/bark-env";
      ExecStart = "${barkNotifyUnitFailure} 'dotfiles-lock-propose@%i.service' 'mini-vm lock 更新 (%i) 失敗'";
    };
  };

  # 発火は autoswitch (04:00 + 最大 30 分) より前に置く。同時刻に回すと switch 中の nix と
  # 競合する上、その日に出した PR が翌日まで適用されない。propose → CI → merge を先に
  # 済ませ、04:00 の autoswitch がその結果を拾う流れにする。
  # 遅延を足しても 03:00 を越えない値にしてあるので、間隔を詰めるときはここを見ること。
  #
  # timer 名に `@` を入れていないのは、`foo@fast.timer` という実体ファイルが
  # テンプレート `foo@.timer` の instance と紛らわしいため。対象は Unit= で明示する。
  systemd.timers.dotfiles-lock-propose-fast = {
    description = "AI ツールの lock 更新提案を毎日回す";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Unit = "dotfiles-lock-propose@fast.service";
      OnCalendar = "*-*-* 01:00:00";
      RandomizedDelaySec = 1800;
      Persistent = true;
    };
  };

  # 全 input はビルドが重く、壊れたときの原因切り分けも広い。日次で回すと fast の PR と
  # 毎日衝突するので週次に留める (衝突した側は次回 origin/main から作り直されて解消する)。
  systemd.timers.dotfiles-lock-propose-slow = {
    description = "全 input の lock 更新提案を毎週回す";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Unit = "dotfiles-lock-propose@slow.service";
      OnCalendar = "Sun *-*-* 02:00:00";
      RandomizedDelaySec = 1800;
      Persistent = true;
    };
  };

  system.stateVersion = "26.05";
}
