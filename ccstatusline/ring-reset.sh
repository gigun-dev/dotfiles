#!/usr/bin/env bash
# Ring meter + reset timer widget for ccstatusline custom-command.
# Usage: ring-reset.sh 5h|7d
#
# Renders: ◕ 2h15m
# Ring character and color reflect usage percentage.
# Timer shows time until rate limit reset.

set -euo pipefail

# constants
RINGS=('○' '◔' '◑' '◕' '●')
readonly R=$'\033[0m'
readonly DIM=$'\033[2m'
readonly WHITE=$'\033[38;5;188m'

# argument → JSON key mapping
metric="${1:-}"
case "$metric" in
  5h) section='five_hour'; window=18000 ;;   # 5 hours
  7d) section='seven_day'; window=604800 ;;  # 7 days
  *)  echo "Usage: $0 5h|7d" >&2; exit 1 ;;
esac

# extract used_percentage and resets_at from stdin JSON
json=$(cat)
after="${json#*\"$section\"}"

if [[ "$after" =~ \"resets_at\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
  resets_at="${BASH_REMATCH[1]}"
else
  printf '%s%s ○ --%s' "$DIM" "reset" "$R"; exit 0
fi

# remaining time and elapsed percentage
now=$(date +%s)
remaining=$(( resets_at - now ))
(( remaining < 0 )) && remaining=0

elapsed=$(( window - remaining ))
(( elapsed < 0 )) && elapsed=0
p=$(( elapsed * 100 / window ))
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

hours=$(( remaining / 3600 ))
minutes=$(( (remaining % 3600) / 60 ))

if (( hours > 0 )); then
  timer="${hours}hr ${minutes}m"
else
  timer="${minutes}m"
fi

# output
printf '%s%s%s %b%s%s %s%s%s' \
  "$DIM" "reset" "$R" \
  "$color" "$ring" "$R" \
  "$WHITE" "$timer" "$R"
