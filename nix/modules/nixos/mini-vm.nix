{
  config,
  modulesPath,
  pkgs,
  lib,
  llmAgents, # inputs.llm-agents.packages.x86_64-linux (flake.nix の specialArgs)
  cloudflareOsRev, # inputs.cloudflare-os.rev (flake.nix の specialArgs)
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
      # gatekeeper は OAuth の redirect URI と、UI に返す接続用 URL を BASE_URL から組み立てる。
      # 既定は `http://localhost:8787/gatekeeper/<name>` で、トンネルの後ろに置いた構成では
      # ブラウザから開けず Not Found になる (Slack 接続で実際に踏んだ)。
      #
      # 上流のリリースビルドは `$PUBLIC_BASE_URL/gatekeeper/<name>` を各 gatekeeper に
      # 設定している (scripts/release/manifest-lib.mjs)。仕組みは上流のものだが、
      # run-dev-server.js は面倒を見ない — ローカル実行は localhost が本物の origin である
      # 前提で組まれているため。VITE_CF_ACCESS_MODE と同じ「本番用の配線が dev に無い」類型。
      #
      # リポジトリを patch せず、起動のたびに各 gatekeeper の .dev.vars を生成して埋める。
      # wrangler は設定ファイルと同じディレクトリの .dev.vars を自分で読むので、これで届く。
      # .dev.vars は gitignore 済みなので checkout の差分はゼロのまま保てる。
      # 非秘密の設定を毎起動時に生成する。
      #
      # ここで扱う値はどれも秘密ではない (Access の aud は全ての JWT ヘッダに入っており、
      # iss は公開の team ドメイン)。よって agenix ではなく宣言から生成する方が適切で、
      # VM を作り直しても手作業が要らなくなる。
      #
      # wrangler は設定ファイルと同じディレクトリの .dev.vars を自分で読む。この性質を使えば
      # 上流リポジトリを patch せずに値を届けられる (.dev.vars は gitignore 済みなので
      # checkout の差分もゼロのまま保てる)。
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
  # ConditionPathExists は cloudflare-os と同じ理由。`codex login` がまだなら
  # ~/.codex/auth.json が無く、起動しても認証できずに Restart=always と噛み合って
  # 無限再起動になる。ログイン後に systemctl start すれば上がる。
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
  # ConditionPathExists は codex-openai-bridge と同じ理由 (`codex login` 前は
  # auth.json が無く、Restart=always と噛み合って無限再起動になる)。
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

  system.stateVersion = "26.05";
}
