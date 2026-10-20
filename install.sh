#!/bin/bash
# claude-limits installer, written to be run by an agent: no prompts, idempotent,
# one line per step on stdout, a final summary line, and exit codes that say
# what to do next.
#
#   ./install.sh [install] [--force-statusline | --no-statusline] [--no-menubar] [--no-mod]
#                [--lang ru|en|auto]
#   ./install.sh check
#   ./install.sh uninstall
#
# Language: every part follows the first macOS system language (Russian or
# English). --lang ru|en pins it (CLAUDE_LIMITS_LANG in settings.json env and in
# the launch agent), --lang auto goes back to the system's; no flag keeps it.
#
# Lines: "ok <step>: ...", "skip <step>: ...", "fail <step>: ...", then
# "done", "incomplete" or "conflict".
#
# Exit codes:
#   0  done (install, uninstall), or everything present (check)
#   1  a step failed, or something is missing (check); the fail line says which
#   2  unsupported system or a missing requirement; the fail line names the fix
#   3  another status line is configured: nothing was changed. Ask the user, then
#      rerun with --force-statusline (the old settings are backed up first), or
#      with --no-statusline to install everything else and keep theirs.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
REPO=$PWD

CLAUDE_DIR=$HOME/.claude
SETTINGS=$CLAUDE_DIR/settings.json
SCRIPT_DST=$CLAUDE_DIR/statusline-limits.sh
SCRIPT_CMD='~/.claude/statusline-limits.sh'
STATUSLINE=$(printf '{"type":"command","command":"%s","refreshInterval":60}' "$SCRIPT_CMD")
APP_BUILD=$REPO/build/ClaudeLimits.app
APP_DST=$HOME/Applications/ClaudeLimits.app
LABEL=com.flydge.claude-limits
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
MARKETPLACE=flydge
MARKETPLACE_SRC=flydge/claude-limits
PLUGIN=limit-rings@flydge

FAILED=0
CLAUDE='' OLD_CLAUDE=''
export GIT_TERMINAL_PROMPT=0
ok() { echo "ok $*"; }
skip() { echo "skip $*"; }
fail() { echo "fail $*"; FAILED=1; }
has() { command -v "$1" >/dev/null 2>&1; }

# Runs a command with stdin closed, killed after $1 seconds: an agent's run
# must never hang on a prompt or an interactive UI.
with_timeout() {  # seconds, command...
  local seconds=$1
  shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@" < /dev/null
}

# Finds a Claude Code with plugin commands (2.x or newer). An old one on PATH
# opens its interactive UI for unknown commands, so each candidate's version is
# checked first: $CLAUDE_BIN, the native install, PATH, the desktop app's own.
find_claude() {
  local candidates=() c version major
  [ -n "${CLAUDE_BIN:-}" ] && candidates+=("$CLAUDE_BIN")
  candidates+=("$HOME/.claude/local/claude")
  while IFS= read -r c; do candidates+=("$c"); done < <(which -a claude 2> /dev/null)
  while IFS= read -r c; do candidates+=("$c"); done < <(
    ls -d "$HOME/Library/Application Support/Claude/claude-code/"*/*/claude.app/Contents/MacOS/claude 2> /dev/null | sort -r)
  for c in "${candidates[@]}"; do
    [ -x "$c" ] || continue
    version=$(with_timeout 20 "$c" --version 2> /dev/null | head -1)
    major=$(printf '%s' "$version" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')
    if [ -n "$major" ] && ((major >= 2)); then
      CLAUDE=$c
      return 0
    fi
    [ -n "$version" ] && [ -z "$OLD_CLAUDE" ] && OLD_CLAUDE="$c is $version"
  done
  return 1
}

no_claude() {
  if [ -n "$OLD_CLAUDE" ]; then
    echo "Claude Code 2.x not found ($OLD_CLAUDE, too old for plugins; set CLAUDE_BIN to a newer claude)"
  else
    echo "claude CLI not found"
  fi
}

cl() { with_timeout 180 "$CLAUDE" "$@"; }

# The status line entry is ours when it runs our script.
is_ours() {  # settings JSON on stdin
  jq -e --arg a "$SCRIPT_CMD" --arg b "$SCRIPT_DST" \
    '.statusLine.command == $a or .statusLine.command == $b' >/dev/null 2>&1
}

# Writes settings atomically, backing up the previous file once per change.
write_settings() {  # new JSON
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak.claude-limits-$(date +%Y%m%d-%H%M%S)" || return 1
  fi
  local tmp
  tmp=$(mktemp "$CLAUDE_DIR/.settings.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$SETTINGS"
}

preflight() {
  [ "$(uname -s)" == Darwin ] || { echo "fail system: macOS is required"; exit 2; }
  local major
  major=$(sw_vers -productVersion | cut -d. -f1)
  ((major >= 13)) || { echo "fail system: macOS 13 or newer is required, found $(sw_vers -productVersion)"; exit 2; }
  has jq || { echo "fail requirement: jq is missing; install it with: brew install jq"; exit 2; }
  if ((WITH_MENUBAR)) && ! has swiftc; then
    echo "fail requirement: swiftc is missing; install Command Line Tools with: xcode-select --install"
    exit 2
  fi
}

install_statusline() {
  mkdir -p "$CLAUDE_DIR" || { fail "statusline: cannot create $CLAUDE_DIR"; return; }
  if cmp -s statusline/statusline-limits.sh "$SCRIPT_DST"; then
    ok "statusline: script already current at $SCRIPT_DST"
  elif install -m 755 statusline/statusline-limits.sh "$SCRIPT_DST"; then
    ok "statusline: script installed at $SCRIPT_DST"
  else
    fail "statusline: cannot write $SCRIPT_DST"
  fi
}

configure_settings() {
  local current='{}' next
  if [ -f "$SETTINGS" ]; then
    current=$(cat "$SETTINGS")
    jq -e . >/dev/null 2>&1 <<< "$current" || { fail "settings: $SETTINGS is not valid JSON"; return; }
  fi
  if jq -e '.statusLine' >/dev/null 2>&1 <<< "$current" && ! is_ours <<< "$current" && ((!FORCE)); then
    echo "fail statusline-conflict: $SETTINGS already has a statusLine: $(jq -c .statusLine <<< "$current")"
    echo "conflict: nothing changed; ask the user, then rerun with --force-statusline (replace it) or --no-statusline (keep it)"
    exit 3
  fi
  next=$(jq --argjson sl "$STATUSLINE" '.statusLine = $sl' <<< "$current")
  if [ "$(jq -S . <<< "$current")" == "$(jq -S . <<< "$next")" ]; then
    ok "settings: statusLine already configured"
  elif write_settings "$next"; then
    ok "settings: statusLine set in $SETTINGS (previous file backed up beside it)"
  else
    fail "settings: cannot write $SETTINGS"
  fi
}

# The pinned language, or nothing: settings.json env is where it is kept.
pinned_lang() {
  [ -f "$SETTINGS" ] && jq -r '.env.CLAUDE_LIMITS_LANG // empty' "$SETTINGS" 2> /dev/null
}

configure_lang() {
  [ -z "$LANG_CHOICE" ] && return
  local current='{}' next
  [ -f "$SETTINGS" ] && current=$(cat "$SETTINGS")
  jq -e . > /dev/null 2>&1 <<< "$current" || { fail "lang: $SETTINGS is not valid JSON"; return; }
  if [ "$LANG_CHOICE" == auto ]; then
    next=$(jq 'del(.env.CLAUDE_LIMITS_LANG) | if .env == {} then del(.env) else . end' <<< "$current")
  else
    next=$(jq --arg l "$LANG_CHOICE" '.env.CLAUDE_LIMITS_LANG = $l' <<< "$current")
  fi
  if [ "$(jq -S . <<< "$current")" == "$(jq -S . <<< "$next")" ]; then
    ok "lang: already $LANG_CHOICE"
  elif mkdir -p "$CLAUDE_DIR" && write_settings "$next"; then
    ok "lang: $LANG_CHOICE (new sessions and the menu bar app follow it)"
  else
    fail "lang: cannot write $SETTINGS"
  fi
}

build_app() {
  local bin=$APP_BUILD/Contents/MacOS/ClaudeLimits
  if [ -x "$bin" ] && [ -z "$(find menubar/Sources menubar/Info.plist -newer "$bin" 2>/dev/null)" ]; then
    return 0
  fi
  bash menubar/build.sh >/dev/null
}

launch_agent_plist() {
  local lang env=''
  lang=$(pinned_lang)
  [ -n "$lang" ] && env="
  <key>EnvironmentVariables</key><dict><key>CLAUDE_LIMITS_LANG</key><string>$lang</string></dict>"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_DST/Contents/MacOS/ClaudeLimits</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>$env
</dict>
</plist>
EOF
}

install_menubar() {
  build_app || { fail "menubar: build failed; run: bash menubar/build.sh"; return; }
  local changed=0
  if cmp -s "$APP_BUILD/Contents/MacOS/ClaudeLimits" "$APP_DST/Contents/MacOS/ClaudeLimits"; then
    ok "menubar: app already current at $APP_DST"
  else
    mkdir -p "$HOME/Applications" && rm -rf "$APP_DST" && cp -R "$APP_BUILD" "$APP_DST" \
      || { fail "menubar: cannot copy the app to $APP_DST"; return; }
    changed=1
    ok "menubar: app installed at $APP_DST"
  fi

  local domain="gui/$(id -u)" want
  want=$(launch_agent_plist)
  if [ "$(cat "$PLIST" 2>/dev/null)" != "$want" ]; then
    mkdir -p "$(dirname "$PLIST")" && printf '%s\n' "$want" > "$PLIST" \
      || { fail "menubar: cannot write $PLIST"; return; }
    changed=1
  fi
  if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
    if ((changed)); then
      launchctl bootout "$domain/$LABEL" >/dev/null 2>&1
      launchctl bootstrap "$domain" "$PLIST" >/dev/null 2>&1 || { fail "menubar: launchctl bootstrap failed"; return; }
      ok "menubar: launch agent $LABEL restarted"
    else
      ok "menubar: launch agent $LABEL already running"
    fi
  elif launchctl bootstrap "$domain" "$PLIST" >/dev/null 2>&1; then
    ok "menubar: launch agent $LABEL loaded; starts at login"
  else
    fail "menubar: launchctl bootstrap $domain $PLIST failed"
  fi
}

install_mod() {
  if ! find_claude; then
    skip "mod: $(no_claude); in the Claude app: + next to the prompt > Plugins > Add marketplace $MARKETPLACE_SRC > Add plugin limit-rings"
    return
  fi
  local markets plugins entry
  markets=$(cl plugin marketplace list --json 2> /dev/null)
  jq -e 'type == "array"' > /dev/null 2>&1 <<< "$markets" \
    || { fail "mod: $CLAUDE plugin marketplace list --json gave no JSON"; return; }
  if jq -e --arg n "$MARKETPLACE" '.[] | select(.name == $n)' > /dev/null <<< "$markets"; then
    cl plugin marketplace update "$MARKETPLACE" > /dev/null 2>&1
  elif ! cl plugin marketplace add "$MARKETPLACE_SRC" > /dev/null 2>&1; then
    fail "mod: $CLAUDE plugin marketplace add $MARKETPLACE_SRC failed or timed out"
    return
  fi
  plugins=$(cl plugin list --json 2> /dev/null)
  jq -e 'type == "array"' > /dev/null 2>&1 <<< "$plugins" \
    || { fail "mod: $CLAUDE plugin list --json gave no JSON"; return; }
  entry=$(jq -c --arg id "$PLUGIN" '.[] | select(.id == $id)' <<< "$plugins")
  if [ -z "$entry" ]; then
    cl plugin install "$PLUGIN" > /dev/null 2>&1 && ok "mod: $PLUGIN installed; shows in new Claude app sessions" \
      || fail "mod: $CLAUDE plugin install $PLUGIN failed or timed out"
    return
  fi
  cl plugin update "$PLUGIN" > /dev/null 2>&1
  if jq -e '.enabled' > /dev/null <<< "$entry"; then
    ok "mod: $PLUGIN already installed"
  else
    cl plugin enable "$PLUGIN" > /dev/null 2>&1 && ok "mod: $PLUGIN enabled" || fail "mod: $CLAUDE plugin enable $PLUGIN failed"
  fi
}

do_install() {
  preflight
  if ((WITH_STATUSLINE)); then
    install_statusline
    configure_settings
  else
    skip "statusline: --no-statusline"
  fi
  configure_lang
  if ((WITH_MENUBAR)); then install_menubar; else skip "menubar: --no-menubar"; fi
  if ((WITH_MOD)); then install_mod; else skip "mod: --no-mod"; fi
  if ((FAILED)); then
    echo "incomplete: fix the fail lines above and rerun ./install.sh"
    exit 1
  fi
  echo "done: the status line shows after the next Claude Code response; ./install.sh check verifies"
}

do_check() {
  [ -x "$SCRIPT_DST" ] && ok "statusline: script at $SCRIPT_DST" || fail "statusline: $SCRIPT_DST missing"
  if [ -f "$SETTINGS" ] && is_ours < "$SETTINGS"; then ok "settings: statusLine configured"; else fail "settings: statusLine not configured"; fi
  [ -x "$APP_DST/Contents/MacOS/ClaudeLimits" ] && ok "menubar: app at $APP_DST" || fail "menubar: $APP_DST missing"
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && ok "menubar: launch agent loaded" || fail "menubar: launch agent $LABEL not loaded"
  if find_claude; then
    cl plugin list --json 2> /dev/null | jq -e --arg id "$PLUGIN" '.[] | select(.id == $id and .enabled)' > /dev/null 2>&1 \
      && ok "mod: $PLUGIN installed and enabled" || fail "mod: $PLUGIN not installed"
  else
    skip "mod: $(no_claude)"
  fi
  local lang
  lang=$(pinned_lang)
  if [ -n "$lang" ]; then ok "lang: $lang, pinned with --lang"; else ok "lang: the first macOS system language"; fi
  if [ -f "$CLAUDE_DIR/limits.json" ]; then
    ok "data: $CLAUDE_DIR/limits.json updated $(( $(date +%s) - $(jq -r '.updated_at // 0' "$CLAUDE_DIR/limits.json") ))s ago"
  else
    skip "data: no readings yet; they appear after the next Claude response on a Pro or Max subscription"
  fi
  if ((FAILED)); then echo "incomplete: run ./install.sh"; exit 1; fi
  echo "done: everything is installed"
}

do_uninstall() {
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" >/dev/null 2>&1
  rm -f "$PLIST" && ok "menubar: launch agent removed"
  rm -rf "$APP_DST" && ok "menubar: app removed"
  rm -f "$SCRIPT_DST" "$CLAUDE_DIR/limits.json" && ok "statusline: script and limits.json removed"
  if [ -f "$SETTINGS" ] && has jq && { is_ours < "$SETTINGS" || [ -n "$(pinned_lang)" ]; }; then
    local cleaned
    cleaned=$(jq --arg a "$SCRIPT_CMD" --arg b "$SCRIPT_DST" '
      (if .statusLine.command == $a or .statusLine.command == $b then del(.statusLine) else . end)
      | del(.env.CLAUDE_LIMITS_LANG) | if .env == {} then del(.env) else . end' "$SETTINGS")
    write_settings "$cleaned" && ok "settings: statusLine and language removed" || fail "settings: cannot write $SETTINGS"
  else
    skip "settings: nothing of ours"
  fi
  if find_claude; then
    cl plugin uninstall "$PLUGIN" > /dev/null 2>&1
    cl plugin marketplace remove "$MARKETPLACE" > /dev/null 2>&1
    ok "mod: $PLUGIN and marketplace $MARKETPLACE removed"
  else
    skip "mod: $(no_claude)"
  fi
  if ((FAILED)); then echo "incomplete"; exit 1; fi
  echo "done: claude-limits removed"
}

COMMAND=install FORCE=0 WITH_STATUSLINE=1 WITH_MENUBAR=1 WITH_MOD=1 LANG_CHOICE=''
while (($#)); do
  arg=$1
  shift
  case $arg in
    --lang) LANG_CHOICE=${1:-}; shift ;;
    --lang=*) LANG_CHOICE=${arg#--lang=} ;;
    install | check | uninstall) COMMAND=$arg ;;
    --force-statusline) FORCE=1 ;;
    --no-statusline) WITH_STATUSLINE=0 ;;
    --no-menubar) WITH_MENUBAR=0 ;;
    --no-mod) WITH_MOD=0 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "fail usage: unknown argument $arg; see ./install.sh --help"; exit 2 ;;
  esac
done
case $LANG_CHOICE in
  '' | ru | en | auto) ;;
  *) echo "fail usage: --lang takes ru, en or auto, not '$LANG_CHOICE'"; exit 2 ;;
esac

case $COMMAND in
  install) do_install ;;
  check) do_check ;;
  uninstall) do_uninstall ;;
esac
