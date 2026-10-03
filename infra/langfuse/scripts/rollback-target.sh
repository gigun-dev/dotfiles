#!/usr/bin/env bash
# retry 時の「1 世代前」は移行前の image を指すことがある。戻す先は今回の
# switch 直前に稼働した system に限定し、DB と同じ image の対かを確認する。
set -euo pipefail
[[ $# == 3 ]] || exit 2
previous=$(readlink -f "$1")
current=$(readlink -f "$2")
[[ -x $previous/bin/switch-to-configuration ]] || exit 2
"$3" "$previous/etc/langfuse/compose.yaml" "$current/etc/langfuse/compose.yaml"
printf '%s\n' "$previous"
