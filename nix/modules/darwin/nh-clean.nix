# 古い世代と、残った GC root をまとめて片付ける (ryoppippi/dotfiles の nh-clean.nix と同じ形)。
#
# nix.gc (nix-collect-garbage --delete-older-than 7d) から置き換えた理由: 世代は消すが
# GC root は外さない。エージェントが worktree ごとに `nix run .#build` すると各 worktree の
# `result` が当時のシステム closure を固定し続け、2026-11-21 には dotfiles/.wt/ の 9 個と
# 本体の result が 10 世代・約 10GB を残していた (手動 GC でも 1GB しか減らなかった)。
# nh clean は既定で result や direnv の root も --keep-since より古ければ外す。
#
# root でないとシステム profile の世代を消せないので daemon で動かす。launchd は電源で
# 起動を絞れないため、1 時間ごとに確かめて、AC 電源のときに 1 日 1 回だけ実行する。
{
  config,
  lib,
  pkgs,
  ...
}:
let
  nhClean = pkgs.writers.writeNu "nh-clean" ''
    const stamp = '/var/db/nh-clean.stamp'

    def on-ac-power []: nothing -> bool {
        ^/usr/bin/pmset -g ps | lines | first | str contains "'AC Power'"
    }

    def ran-recently []: nothing -> bool {
        ($stamp | path exists) and ((date now) - (ls $stamp | get 0.modified) < 20hr)
    }

    def main [] {
        if not (on-ac-power) or (ran-recently) { return }
        ^/usr/bin/caffeinate -i ${lib.getExe pkgs.nh} clean all --keep-since 7d --keep 3 --optimise
        touch $stamp
    }
  '';
in
{
  launchd.daemons.nh-clean.serviceConfig = {
    ProgramArguments = [ "${nhClean}" ];
    # /usr/sbin は lsof のため。Nix の GC は実行中のプロセスが開いている store のパスを
    # lsof で拾って root にする。無いと "executing lsof" で失敗し、使用中のパスまで消しうる。
    EnvironmentVariables.PATH = "${config.nix.package}/bin:/usr/bin:/bin:/usr/sbin";
    StartInterval = 3600;
    StandardOutPath = "/var/log/nh-clean.log";
    StandardErrorPath = "/var/log/nh-clean.log";
    LowPriorityIO = true;
    ProcessType = "Background";
  };
}
