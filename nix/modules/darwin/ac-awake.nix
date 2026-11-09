# AC 給電中は蓋を閉じてもスリープさせない。T3 Code の T3 Connect で iPhone / iPad から
# この Mac に繋ぐには本体が起きている必要がある。ryoppippi/dotfiles (MIT) の
# nix/modules/darwin/ac-awake.nix を移植した。
#
# `pmset -c sleep 0` では足りない: 止まるのは放置によるスリープだけで、蓋を閉じた
# スリープ (clamshell) は止まらない。蓋まで止める disablesleep は給電元ごとではなく
# 全体の設定なので、給電元の変化を root daemon で追って切り替え、電源を抜いたら即戻す。
{ pkgs, ... }:
let
  acAwake = pkgs.writers.writeNu "ac-awake" ''
    def on-ac-power []: nothing -> bool {
        ^/usr/bin/pmset -g ps | lines | first | str contains "'AC Power'"
    }

    def sleep-disabled []: nothing -> bool {
        ^/usr/bin/pmset -g | parse --regex 'SleepDisabled\s+(?<value>\d)' | get 0.value | $in == '1'
    }

    def lid-closed []: nothing -> bool {
        ^/usr/sbin/ioreg -r -k AppleClamshellState -d 1 | str contains '"AppleClamshellState" = Yes'
    }

    def main [] {
        let ac = on-ac-power
        if $ac != (sleep-disabled) {
            ^/usr/bin/pmset -a disablesleep (if $ac { 1 } else { 0 })
        }
        # 蓋を閉じたまま電源を抜くと、蓋を開けるまで誰も寝かせない (鞄の中で起き続ける)。
        if not $ac and (lid-closed) {
            ^/usr/bin/pmset sleepnow
        }
    }
  '';
in
{
  launchd.daemons.ac-awake.serviceConfig = {
    ProgramArguments = [ "${acAwake}" ];
    # 給電元の変化で即起動する。通知を取りこぼしたときのために 60 秒ごとにも回す。
    LaunchEvents."com.apple.notifyd.matching".power-source.Notification =
      "com.apple.system.powersources.source";
    RunAtLoad = true;
    StartInterval = 60;
    StandardOutPath = "/var/log/ac-awake.log";
    StandardErrorPath = "/var/log/ac-awake.log";
    ProcessType = "Background";
  };
}
