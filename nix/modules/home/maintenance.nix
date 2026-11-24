# Pro の手入れを人が居ない時間に回す user agent (Darwin だけ)。
# どれも 1 時間ごとに起きて AC 電源のときだけ動く。nh-clean (nix/modules/darwin/nh-clean.nix) と同じ形。
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dotfilesPath = "${config.home.homeDirectory}/ghq/github.com/gigun-dev/dotfiles";
  stateDir = "${config.xdg.stateHome}/dotfiles-maintenance";
  logDir = "${config.home.homeDirectory}/Library/Logs";
  system = "${config.home.username}-${pkgs.stdenv.hostPlatform.system}";

  onAcPower = ''
    /usr/bin/pmset -g ps | /usr/bin/head -n 1 | /usr/bin/grep -q "'AC Power'" || exit 0
  '';

  # pull したときの switch を待たせないよう、origin/main のシステムを先にビルドしておく。
  # 結果を out-link (GC root) にするので、nh-clean の GC に消されず pull まで store に残る。
  # nh clean は 7 日より古い root を外すが、その頃には main が進んで root が張り替わっているか、
  # 既に switch 済み (system profile が同じ path を持つ) なので困らない。
  # Why not github: で直接ビルド: pull 後の switch は git+file で評価する。同じ commit でも
  # source の取り方が違うと flake の評価経路が変わるので、手元の clone の commit を指して揃える。
  prefetch = pkgs.writeShellScript "dotfiles-prefetch" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.git ]}:/run/current-system/sw/bin:/usr/bin:/bin
    ${onAcPower}
    mkdir -p ${stateDir}
    git -C ${dotfilesPath} fetch --quiet origin main
    sha=$(git -C ${dotfilesPath} rev-parse refs/remotes/origin/main)
    [ "$(cat ${stateDir}/prefetched-sha 2>/dev/null)" != "$sha" ] || exit 0
    # 既に pull 済みなら switch がビルドしているので要らない。
    if ! git -C ${dotfilesPath} merge-base --is-ancestor "$sha" HEAD; then
      date
      echo "prefetch $sha"
      nice -n 10 nix build --no-write-lock-file \
        "git+file://${dotfilesPath}?ref=refs/remotes/origin/main&rev=$sha#darwinConfigurations.${system}.system" \
        --out-link ${stateDir}/system
    fi
    echo "$sha" > ${stateDir}/prefetched-sha
  '';

  # MCP の `uv run --script` (cman など) がセッション中ずっと ~/.cache/uv の lock を握るので、
  # セッションが全部閉じている時間に当たるまで毎時試す。lock 待ちは timeout で打ち切る
  # (uv は既定で 300 秒待つ。lock を取る前に打ち切るので何も消えていない)。
  # --force は使わない: 実行中の MCP の環境を消しうる。
  uvCachePrune = pkgs.writeShellScript "uv-cache-prune" ''
    set -u
    ${onAcPower}
    mkdir -p ${stateDir}
    stamp=${stateDir}/uv-cache-prune.stamp
    # 1 日 1 回 (20 時間) に絞る。
    [ -z "$(/usr/bin/find "$stamp" -mmin -1200 2>/dev/null)" ] || exit 0
    ${pkgs.coreutils}/bin/timeout 60 ${pkgs.uv}/bin/uv cache prune || exit 0
    date
    touch "$stamp"
  '';

  # switch の brew_upgrade_outdated (flake.nix) が上げるものを先に download しておく。
  # 上げるのは switch のときだけで、ここは cache (~/Library/Caches/Homebrew) に置くまで。
  # 一覧の条件 (greedy なしの brew outdated) は switch 側と揃える。
  brewPrefetch = pkgs.writeShellScript "brew-prefetch" ''
    set -u
    ${onAcPower}
    brew=/opt/homebrew/bin/brew
    [ -x "$brew" ] || exit 0
    mkdir -p ${stateDir}
    stamp=${stateDir}/brew-prefetch.stamp
    # brew update は API の取得を伴うので 6 時間に 1 回。
    [ -z "$(/usr/bin/find "$stamp" -mmin -360 2>/dev/null)" ] || exit 0
    "$brew" update --quiet >/dev/null 2>&1 || exit 0
    formulae=$("$brew" outdated --formula --quiet 2>/dev/null)
    casks=$("$brew" outdated --cask --quiet 2>/dev/null)
    if [ -n "$formulae$casks" ]; then
      date
      echo "fetch:" $formulae $casks
      [ -z "$formulae" ] || HOMEBREW_NO_AUTO_UPDATE=1 "$brew" fetch --formula $formulae
      [ -z "$casks" ] || HOMEBREW_NO_AUTO_UPDATE=1 "$brew" fetch --cask $casks
    fi
    touch "$stamp"
  '';

  hourlyAgent = program: log: {
    enable = true;
    config = {
      ProgramArguments = [ "${program}" ];
      StartInterval = 3600;
      ProcessType = "Background";
      LowPriorityIO = true;
      StandardOutPath = "${logDir}/${log}";
      StandardErrorPath = "${logDir}/${log}";
    };
  };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  launchd.agents.dotfiles-prefetch = hourlyAgent prefetch "dotfiles-prefetch.log";
  launchd.agents.uv-cache-prune = hourlyAgent uvCachePrune "uv-cache-prune.log";
  launchd.agents.brew-prefetch = hourlyAgent brewPrefetch "brew-prefetch.log";
}
