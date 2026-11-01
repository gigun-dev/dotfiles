# mini-vm の lock 更新は提案 PR で行う

Date: 2026-09-06

無人の mini-vm は、lock 更新を実機でビルドして PR に提案し、required CI を通して自動 merge する。適用は別の autoswitch が行う。人が差分を判定しにくい lock 更新は、手動レビューを関門にするより実機ビルドと CI で検証する。

手動と自動で異なる flake を参照すると稼働中の revision と作業コピーが食い違うため、`github:` 直接参照にはしない。自動適用の CI 判定は [ADR 0011](0011-push-without-a-local-gate-and-apply-only-green-commits.md)、運用は [mini-vm.md](../mini-vm.md) を参照。
