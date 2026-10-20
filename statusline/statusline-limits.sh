#!/bin/bash
# Claude Code status line: 5-hour and weekly subscription limits.
# Reads only the JSON Claude Code passes on stdin. No network, no credentials.
# Also saves the latest limits to $CLAUDE_LIMITS_FILE for the menu bar app.

NOW=${CLAUDE_LIMITS_NOW:-$(date +%s)}
LIMITS_FILE=${CLAUDE_LIMITS_FILE:-$HOME/.claude/limits.json}

if [ -n "${NO_COLOR:-}" ]; then
  RESET='' MUTED='' GREEN='' YELLOW='' RED=''
else
  RESET=$'\e[0m' MUTED=$'\e[90m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RED=$'\e[31m'
fi

PARTIAL=('' '▏' '▎' '▍' '▌' '▋' '▊' '▉')

input=$(cat)

# percent|eighths|level|resets for 5h, then the same for 7d; empty fields when absent.
fields=$(printf '%s' "$input" | jq -r '
  def valid(w): (w | type) == "object"
    and (w.used_percentage | type) == "number" and (w.resets_at | type) == "number";
  def win(w):
    if valid(w) then
      w.used_percentage as $u
      | ([([$u, 0] | max), 100] | min) as $c
      | "\($u | round)|\($c / 100 * 80 | round)|\(if $u < 60 then "g" elif $u < 85 then "y" else "r" end)|\(w.resets_at | floor)"
    else "|||" end;
  .rate_limits as $r | "\(win($r.five_hour))|\(win($r.seven_day))"
' 2>/dev/null)

IFS='|' read -r fh_pct fh_eighths fh_level fh_reset sd_pct sd_eighths sd_level sd_reset <<< "$fields"

format_left() {  # $1 = seconds until reset, > 0
  local d=$1 m
  if ((d < 3600)); then
    m=$((d / 60))
    ((m < 1)) && m=1
    printf '%sм' "$m"
  elif ((d < 86400)); then
    printf '%sч%sм' $((d / 3600)) $((d % 3600 / 60))
  else
    printf '%sд%sч' $((d / 86400)) $((d % 86400 / 3600))
  fi
}

segment() {  # label percent eighths level resets
  local label=$1 pct=$2 eighths=$3 level=$4 resets=$5
  [ -n "$pct" ] || return 1
  local left=$((resets - NOW))
  ((left > 0)) || return 1
  local full=$((eighths / 8)) rem=$((eighths % 8)) fill='' empty='' cells i color
  for ((i = 0; i < full; i++)); do fill+='█'; done
  cells=$full
  if ((rem > 0)); then
    fill+=${PARTIAL[rem]}
    cells=$((cells + 1))
  fi
  for ((i = cells; i < 10; i++)); do empty+='·'; done
  case $level in
    g) color=$GREEN ;;
    y) color=$YELLOW ;;
    *) color=$RED ;;
  esac
  printf '%s %s%s%s%s%s%s %s%s%%%s %s%s%s' \
    "$label" "$color" "$fill" "$RESET" "$MUTED" "$empty" "$RESET" \
    "$color" "$pct" "$RESET" "$MUTED" "$(format_left "$left")" "$RESET"
}

save_limits() {
  local dir tmp
  dir=$(dirname "$LIMITS_FILE")
  mkdir -p "$dir" 2>/dev/null || return
  tmp=$(mktemp "$dir/.limits.XXXXXX" 2>/dev/null) || return
  if printf '%s' "$input" | jq -c --argjson now "$NOW" '
      def valid(w): (w | type) == "object"
        and (w.used_percentage | type) == "number" and (w.resets_at | type) == "number";
      def pick(w): {used_percentage: w.used_percentage, resets_at: w.resets_at};
      .rate_limits as $r
      | {updated_at: $now}
        + (if valid($r.five_hour) then {five_hour: pick($r.five_hour)} else {} end)
        + (if valid($r.seven_day) then {seven_day: pick($r.seven_day)} else {} end)
    ' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$LIMITS_FILE"
  else
    rm -f "$tmp"
  fi
}

if [ -n "$fh_pct" ] || [ -n "$sd_pct" ]; then
  save_limits
fi

parts=()
s=$(segment '5ч' "$fh_pct" "$fh_eighths" "$fh_level" "$fh_reset") && parts+=("$s")
s=$(segment 'нед' "$sd_pct" "$sd_eighths" "$sd_level" "$sd_reset") && parts+=("$s")

if ((${#parts[@]} == 0)); then
  printf '%sлимиты: —%s\n' "$MUTED" "$RESET"
elif ((${#parts[@]} == 1)); then
  printf '%s\n' "${parts[0]}"
else
  printf '%s   %s\n' "${parts[0]}" "${parts[1]}"
fi
exit 0
