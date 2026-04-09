#!/usr/bin/env bash
# Braille dots progress bar widget for ccstatusline custom-command.
# Usage: braille-status.sh 5h|7d
#
# Renders a single metric as: label ⣿⣿⣶⣀     42%
# Colors use True Color (38;2) for the gradient bar.
# Text color fixed to ccstatusline "white" (ansi256:188).

set -euo pipefail

# constants
BRAILLE=(' ' '⣀' '⣄' '⣤' '⣦' '⣶' '⣷' '⣿')
readonly BAR_WIDTH=8

# ANSI escapes
readonly R=$'\033[0m'
readonly DIM=$'\033[2m'
readonly WHITE=$'\033[38;5;188m'


# argument → JSON key mapping

metric="${1:-}"
case "$metric" in
  5h) label='5h'; section='five_hour' ;;
  7d) label='7d'; section='seven_day' ;;
  *)  echo "Usage: $0 5h|7d" >&2; exit 1 ;;
esac

# extract used_percentage from stdin JSON

json=$(cat)
after="${json#*\"$section\"}"
if [[ "$after" =~ \"used_percentage\"[[:space:]]*:[[:space:]]*([0-9]+\.?[0-9]*) ]]; then
  pct="${BASH_REMATCH[1]}"
else
  printf '%s%s         --%s' "$DIM" "$label" "$R"; exit 0
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

# braille bar

bar=""
for (( i = 0; i < BAR_WIDTH; i++ )); do
  seg_start=$(( i * 100 / BAR_WIDTH ))
  seg_end=$(( (i + 1) * 100 / BAR_WIDTH ))
  if (( p >= seg_end )); then
    bar+="${BRAILLE[7]}"
  elif (( p <= seg_start )); then
    bar+="${BRAILLE[0]}"
  else
    frac=$(( (p - seg_start) * 7 / (seg_end - seg_start) ))
    (( frac > 7 )) && frac=7
    bar+="${BRAILLE[$frac]}"
  fi
done

# output

printf '%s%s%s %b%s%s %s%d%%%s' \
  "$DIM" "$label" "$R" \
  "$color" "$bar" "$R" \
  "$WHITE" "$p" "$R"
