#!/bin/bash
# Tests for install.sh against a temporary HOME. `claude` and `launchctl` are
# stubs, so the real Claude Code setup and launchd are never touched.
# Run: bash tests/install.test.sh
cd "$(dirname "$0")/.." || exit 1
REPO=$PWD
FAILS=0
OURS='{"type":"command","command":"~/.claude/statusline-limits.sh","refreshInterval":60}'

expect() {  # name expected actual
  if [ "$2" == "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"
    FAILS=$((FAILS + 1))
  fi
}

# A fresh HOME with stubs; sets HOME_DIR, STUBS, STATE, LOG.
fresh() {
  ROOT_TMP=$(mktemp -d)
  HOME_DIR=$ROOT_TMP/home STUBS=$ROOT_TMP/stubs STATE=$ROOT_TMP/state LOG=$ROOT_TMP/log
  mkdir -p "$HOME_DIR" "$STUBS" "$STATE"
  : > "$LOG"
  cat > "$STUBS/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >> "$STUB_LOG"
case "$*" in
  "--version") echo "2.1.304 (Claude Code)" ;;
  "plugin marketplace list --json") [ -f "$STUB_STATE/marketplace" ] && echo '[{"name":"flydge"}]' || echo '[]' ;;
  "plugin marketplace add flydge/claude-limits") touch "$STUB_STATE/marketplace" ;;
  "plugin marketplace remove flydge") rm -f "$STUB_STATE/marketplace" ;;
  "plugin list --json") [ -f "$STUB_STATE/plugin" ] && echo '[{"id":"limit-rings@flydge","enabled":true}]' || echo '[]' ;;
  "plugin install limit-rings@flydge") touch "$STUB_STATE/plugin" ;;
  "plugin uninstall limit-rings@flydge") rm -f "$STUB_STATE/plugin" ;;
esac
exit 0
EOF
  cat > "$STUBS/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "$STUB_LOG"
# Like launchd, bootout is asynchronous: the agent is still listed once after it,
# and bootstrap fails while it is.
case "$1" in
  bootstrap) [ -f "$STUB_STATE/agent" ] && exit 5; touch "$STUB_STATE/agent" ;;
  bootout) [ -f "$STUB_STATE/agent" ] || exit 3; touch "$STUB_STATE/dying" ;;
  print)
    [ -f "$STUB_STATE/agent" ] || exit 113
    if [ -f "$STUB_STATE/dying" ]; then rm -f "$STUB_STATE/agent" "$STUB_STATE/dying"; fi
    exit 0 ;;
  kickstart) [ -f "$STUB_STATE/agent" ] || exit 113 ;;
esac
EOF
  chmod +x "$STUBS/claude" "$STUBS/launchctl"
}

inst() {  # install.sh arguments...; prints its output, returns its exit code
  HOME=$HOME_DIR STUB_LOG=$LOG STUB_STATE=$STATE \
    PATH="$STUBS:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO/install.sh" "$@"
}
settings() { cat "$HOME_DIR/.claude/settings.json" 2>/dev/null; }
count() { grep -c -- "$1" "$LOG"; }

# Fresh install: everything in place, settings merged, other keys kept.
fresh
mkdir -p "$HOME_DIR/.claude" && echo '{"theme":"dark"}' > "$HOME_DIR/.claude/settings.json"
out=$(inst); code=$?
expect "fresh install exits 0" 0 "$code"
expect "status line script installed" yes "$([ -x "$HOME_DIR/.claude/statusline-limits.sh" ] && echo yes)"
expect "statusLine added" "$OURS" "$(settings | jq -c .statusLine)"
expect "other settings kept" dark "$(settings | jq -r .theme)"
expect "settings backed up" 1 "$(ls "$HOME_DIR/.claude/" | grep -c 'settings.json.bak')"
expect "app installed" yes "$([ -x "$HOME_DIR/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits" ] && echo yes)"
expect "launch agent written" yes "$([ -f "$HOME_DIR/Library/LaunchAgents/com.flydge.claude-limits.plist" ] && echo yes)"
expect "launch agent loaded" yes "$([ -f "$STATE/agent" ] && echo yes)"
expect "marketplace added" 1 "$(count 'plugin marketplace add flydge/claude-limits')"
expect "mod installed" 1 "$(count 'plugin install limit-rings@flydge')"
expect "summary line" "done" "$(printf '%s\n' "$out" | tail -1 | cut -d: -f1)"
expect "check passes" 0 "$(inst check >/dev/null; echo $?)"

# Second run changes nothing.
before=$(settings)
out=$(inst); code=$?
expect "rerun exits 0" 0 "$code"
expect "rerun leaves settings" "$before" "$(settings)"
expect "rerun makes no new backup" 1 "$(ls "$HOME_DIR/.claude/" | grep -c 'settings.json.bak')"
expect "rerun adds no marketplace" 1 "$(count 'plugin marketplace add')"
expect "rerun installs no mod" 1 "$(count 'plugin install ')"

# A new app build restarts the running agent; a changed plist reloads it.
printf 'x' >> "$HOME_DIR/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits"
out=$(inst); code=$?
expect "app update exits 0" 0 "$code"
expect "app update restarts in place" 1 "$(count 'launchctl kickstart -k')"
out=$(inst --lang ru); code=$?
expect "plist change exits 0" 0 "$code"
expect "plist change reloads the agent" yes "$([ -f "$STATE/agent" ] && echo yes)"
inst --lang auto >/dev/null

# Uninstall removes what install added, and only that.
mkdir -p "$HOME_DIR/.claude/attention" && echo "{}" > "$HOME_DIR/.claude/attention/cli-1.json"
echo "{}" > "$HOME_DIR/.claude/attention.json"
out=$(inst uninstall); code=$?
expect "uninstall exits 0" 0 "$code"
expect "statusLine removed" null "$(settings | jq -c .statusLine)"
expect "other settings survive uninstall" dark "$(settings | jq -r .theme)"
expect "script removed" no "$([ -e "$HOME_DIR/.claude/statusline-limits.sh" ] && echo yes || echo no)"
expect "app removed" no "$([ -e "$HOME_DIR/Applications/ClaudeLimits.app" ] && echo yes || echo no)"
expect "attention states removed" no "$([ -e "$HOME_DIR/.claude/attention" ] && echo yes || echo no)"
expect "attention list removed" no "$([ -e "$HOME_DIR/.claude/attention.json" ] && echo yes || echo no)"
expect "agent unloaded" no "$([ -f "$STATE/agent" ] && echo yes || echo no)"
expect "mod uninstalled" 1 "$(count 'plugin uninstall limit-rings@flydge')"
expect "check fails after uninstall" 1 "$(inst check >/dev/null; echo $?)"

# Someone else's status line: stop with code 3 and touch nothing.
fresh
mkdir -p "$HOME_DIR/.claude"
echo '{"statusLine":{"type":"command","command":"~/mine.sh"}}' > "$HOME_DIR/.claude/settings.json"
before=$(settings)
out=$(inst); code=$?
expect "foreign status line exits 3" 3 "$code"
expect "foreign status line kept" "$before" "$(settings)"
expect "conflict is named" yes "$(printf '%s\n' "$out" | grep -q 'statusline-conflict' && echo yes)"
out=$(inst --no-statusline); code=$?
expect "keeping theirs exits 0" 0 "$code"
expect "keeping theirs leaves settings" "$before" "$(settings)"
expect "keeping theirs still installs the app" yes "$([ -x "$HOME_DIR/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits" ] && echo yes)"
out=$(inst --force-statusline); code=$?
expect "forced install exits 0" 0 "$code"
expect "forced install replaces it" "$OURS" "$(settings | jq -c .statusLine)"
expect "forced install backs up the old one" '~/mine.sh' \
  "$(cat "$HOME_DIR"/.claude/settings.json.bak* | jq -r .statusLine.command)"

# No settings file and no claude CLI: still installs the rest.
fresh
rm -f "$STUBS/claude"
out=$(inst); code=$?
expect "without claude exits 0" 0 "$code"
expect "settings created" "$OURS" "$(settings | jq -c .statusLine)"
expect "mod step skipped" yes "$(printf '%s\n' "$out" | grep -q '^skip mod' && echo yes)"

# An old Claude Code on PATH (no plugin commands, opens its UI instead) is
# skipped, never run into a hang.
fresh
cat > "$STUBS/claude" <<'EOF2'
#!/bin/bash
[ "$1" == "--version" ] && { echo "0.2.99 (Claude Code)"; exit 0; }
sleep 600
EOF2
chmod +x "$STUBS/claude"
started=$(date +%s)
out=$(inst --no-menubar); code=$?
expect "old claude exits 0" 0 "$code"
expect "old claude is not used" yes "$(printf '%s\n' "$out" | grep -q '^skip mod: .*0.2.99' && echo yes)"
expect "old claude does not hang" 1 "$(( $(date +%s) - started < 60 ))"
# CLAUDE_BIN points at a working one.
mkdir -p "$ROOT_TMP/good"
cat > "$ROOT_TMP/good/claude" <<'EOF2'
#!/bin/bash
echo "claude $*" >> "$STUB_LOG"
case "$*" in
  "--version") echo "2.1.304 (Claude Code)" ;;
  "plugin marketplace list --json" | "plugin list --json") echo '[]' ;;
esac
EOF2
chmod +x "$ROOT_TMP/good/claude"
out=$(CLAUDE_BIN=$ROOT_TMP/good/claude inst --no-menubar); code=$?
expect "CLAUDE_BIN is used" 1 "$(count 'plugin install limit-rings@flydge')"

# --lang pins the language for all three parts; no flag keeps the choice.
fresh
out=$(inst --lang ru --no-mod); code=$?
plist=$HOME_DIR/Library/LaunchAgents/com.flydge.claude-limits.plist
expect "--lang exits 0" 0 "$code"
expect "--lang sets settings env" ru "$(settings | jq -r .env.CLAUDE_LIMITS_LANG)"
expect "--lang reaches the menu bar app" yes "$(grep -q '<key>CLAUDE_LIMITS_LANG</key><string>ru</string>' "$plist" && echo yes)"
inst --no-mod >/dev/null
expect "no flag keeps the language" ru "$(settings | jq -r .env.CLAUDE_LIMITS_LANG)"
out=$(inst --lang=auto --no-mod); code=$?
expect "--lang=auto exits 0" 0 "$code"
expect "--lang=auto removes it" null "$(settings | jq -c .env)"
expect "--lang=auto clears the app" no "$(grep -q CLAUDE_LIMITS_LANG "$plist" && echo yes || echo no)"
expect "bad language exits 2" 2 "$(inst --lang de >/dev/null; echo $?)"
inst --lang en --no-mod >/dev/null
inst uninstall >/dev/null
expect "uninstall removes the language" null "$(settings | jq -c .env)"

# Flags turn parts off.
fresh
out=$(inst --no-menubar --no-mod); code=$?
expect "partial install exits 0" 0 "$code"
expect "no app with --no-menubar" no "$([ -e "$HOME_DIR/Applications/ClaudeLimits.app" ] && echo yes || echo no)"
expect "no mod with --no-mod" 0 "$(count 'plugin install')"

echo
if ((FAILS)); then echo "$FAILS failed"; exit 1; else echo "all passed"; fi
