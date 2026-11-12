# mini-vm の lock 更新は提案 PR で行う

Date: 2026-09-06
Implementation: done

無人の mini-vm は、lock 更新を実機でビルドして PR に提案し、required CI を通して自動 merge する。適用は別の autoswitch が行う。人が差分を判定しにくい lock 更新は、手動レビューを関門にするより実機ビルドと CI で検証する。自動適用の CI 判定は [ADR 0011](0011-push-without-a-local-gate-and-apply-only-green-commits.md)、運用は [mini-vm.md](../mini-vm.md) を参照。

Accepting: lock 更新は人の差分レビューを経ずに main へ merge される。
Rejected: 手元でレビューしてから merge する — lock の差分は人が判定しにくいから。
Rejected: 自動側だけ flake を `github:` で直接参照する — 手動と自動で参照先が異なると、稼働中の revision と作業コピーが食い違うから。
