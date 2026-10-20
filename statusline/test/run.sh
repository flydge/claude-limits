#!/bin/bash
# Tests for statusline-limits.sh. Run: bash statusline/test/run.sh
cd "$(dirname "$0")/.." || exit 1
SCRIPT=$PWD/statusline-limits.sh
NOW=1760958000
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

export CLAUDE_LIMITS_CACHE="$TMP/cache"

run() {  # $1 = stdin
  printf '%s' "$1" | NO_COLOR=1 CLAUDE_LIMITS_NOW=$NOW CLAUDE_LIMITS_FILE="$TMP/limits.json" bash "$SCRIPT"
}
run_colored() {  # $1 = stdin
  printf '%s' "$1" | env -u NO_COLOR CLAUDE_LIMITS_NOW=$NOW CLAUDE_LIMITS_FILE="$TMP/limits.json" bash "$SCRIPT"
}
with_session() {  # session id, limits JSON -> the JSON with session_id added
  printf '%s' "$2" | jq -c --arg id "$1" '. + {session_id: $id}'
}
expect() {  # name expected actual
  if [ "$2" == "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"
    FAILS=$((FAILS + 1))
  fi
}
contains() {  # haystack needle -> yes/no
  case $1 in *"$2"*) echo yes ;; *) echo no ;; esac
}
win() {  # percent, seconds until reset
  printf '{"used_percentage":%s,"resets_at":%s}' "$1" $((NOW + $2))
}
limits() {  # five_hour JSON or "", seven_day JSON or ""
  local body=''
  [ -n "$1" ] && body="\"five_hour\":$1"
  [ -n "$2" ] && body="${body:+$body,}\"seven_day\":$2"
  printf '{"rate_limits":{%s}}' "$body"
}

H5=$(win 42 7800)
W7=$(win 18 356400)

rm -f "$TMP/limits.json"
expect "both windows" "5ч ████▎····· 42% 2ч10м   нед █▊········ 18% 4д3ч" "$(run "$(limits "$H5" "$W7")")"
expect "file has both" "$NOW 42 18" \
  "$(jq -r '"\(.updated_at) \(.five_hour.used_percentage) \(.seven_day.used_percentage)"' "$TMP/limits.json")"

rm -f "$TMP/limits.json"
expect "five hour only" "5ч ████▎····· 42% 2ч10м" "$(run "$(limits "$H5" "")")"
expect "file has only five hour" "true false" \
  "$(jq -r '"\(has("five_hour")) \(has("seven_day"))"' "$TMP/limits.json")"

rm -f "$TMP/limits.json"
expect "empty input" "лимиты: —" "$(run '')"
expect "empty input writes no file" "absent" "$([ -e "$TMP/limits.json" ] && echo present || echo absent)"

echo '{"updated_at":1}' > "$TMP/limits.json"
expect "no rate_limits" "лимиты: —" "$(run '{"model":{"display_name":"Opus"}}')"
expect "no rate_limits keeps file" '{"updated_at":1}' "$(cat "$TMP/limits.json")"
expect "invalid json" "лимиты: —" "$(run 'not json')"

expect "zero percent" "5ч ·········· 0% 2ч10м" "$(run "$(limits "$(win 0 7800)" "")")"
expect "full" "5ч ██████████ 100% 2ч10м" "$(run "$(limits "$(win 100 7800)" "")")"
expect "over 100" "5ч ██████████ 104% 2ч10м" "$(run "$(limits "$(win 104 7800)" "")")"
expect "fractional percent" "5ч ██▍······· 24% 2ч10м" "$(run "$(limits "$(win 23.5 7800)" "")")"
expect "past reset hidden" "нед █▊········ 18% 4д3ч" "$(run "$(limits "$(win 42 -10)" "$W7")")"
expect "minutes" "5ч ████▎····· 42% 45м" "$(run "$(limits "$(win 42 2700)" "")")"
expect "under a minute" "5ч ████▎····· 42% 1м" "$(run "$(limits "$(win 42 30)" "")")"

# An idle session re-runs every minute with the same old numbers: it must not
# overwrite what another session wrote since.
S1=$(with_session one "$(limits "$H5" "$W7")")
rm -rf "$TMP/limits.json" "$TMP/cache"
run "$S1" >/dev/null
echo '{"updated_at":1}' > "$TMP/limits.json"
run "$S1" >/dev/null
expect "same data again leaves file alone" '{"updated_at":1}' "$(cat "$TMP/limits.json")"
run "$(with_session one "$(limits "$(win 43 7800)" "$W7")")" >/dev/null
expect "changed data rewrites file" "43" "$(jq -r '.five_hour.used_percentage' "$TMP/limits.json")"
echo '{"updated_at":1}' > "$TMP/limits.json"
run "$(with_session two "$(limits "$(win 43 7800)" "$W7")")" >/dev/null
expect "another session writes its first reading" "43" "$(jq -r '.five_hour.used_percentage' "$TMP/limits.json")"

expect "green below 60" yes "$(contains "$(run_colored "$(limits "$(win 59.9 7800)" "")")" $'\e[32m')"
expect "yellow at 62" yes "$(contains "$(run_colored "$(limits "$(win 62 7800)" "")")" $'\e[33m')"
expect "red at 85" yes "$(contains "$(run_colored "$(limits "$(win 85 7800)" "")")" $'\e[31m')"
expect "no color with NO_COLOR" no "$(contains "$(run "$(limits "$H5" "")")" $'\e[')"

echo
if ((FAILS)); then echo "$FAILS failed"; exit 1; else echo "all passed"; fi
