#!/usr/bin/env bash
# Ring meter widget for context window usage (ccstatusline custom-command).
# Usage: ring-ctx.sh
#
# Renders: ctx ◕ 42%
# Ring character and color reflect context window usage percentage.

set -euo pipefail

# constants
RINGS=('○' '◔' '◑' '◕' '●')
readonly R=$'\033[0m'
readonly DIM=$'\033[2m'
readonly WHITE=$'\033[38;5;188m'

# extract used_percentage from stdin JSON
json=$(cat)
after="${json#*\"context_window\"}"
if [[ "$after" =~ \"used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+\.?[0-9]*) ]]; then
  pct="${BASH_REMATCH[1]}"
else
  printf '%s%s ○ --%s' "$DIM" "ctx" "$R"; exit 0
fi

p=$(printf '%.0f' "$pct")
(( p < 0 )) && p=0
(( p > 100 )) && p=100

# gradient color (green → yellow → red)
if (( p < 50 )); then
  r=$(( p * 255 / 50 ))
  color="\033[38;2;${r};200;80m"
else
  g=$(( 200 - (p - 50) * 4 ))
  (( g < 0 )) && g=0
  color="\033[38;2;255;${g};60m"
fi

# ring character
idx=$(( p / 25 ))
(( idx > 4 )) && idx=4
ring="${RINGS[$idx]}"

# output
printf '%s%s%s %b%s%s %s%d%%%s' \
  "$DIM" "ctx" "$R" \
  "$color" "$ring" "$R" \
  "$WHITE" "$p" "$R"
