# claude-limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Показывать расход 5-часового и недельного лимита Claude в строке статуса Claude Code (S4) и в строке меню macOS (R2).

**Architecture:** Bash-скрипт строки статуса читает JSON от Claude Code со stdin, печатает полосы и атомарно сохраняет последние значения в `~/.claude/limits.json`. Приложение на Swift/AppKit без Xcode-проекта раз в 30 с читает этот файл и рисует два кольца с числами и меню с деталями. Чистая логика (`LimitsCore.swift`) отделена от AppKit и тестируется отдельно.

**Tech Stack:** bash 3.2 (системный macOS), jq, Swift 5 (`swiftc` из Command Line Tools), AppKit, launchd.

Спецификация: `docs/superpowers/specs/2026-10-20-claude-limits-design.md`.

## Global Constraints

- Скрипт совместим с `/bin/bash` 3.2 на macOS: без ассоциативных массивов, `mapfile`, `${var,,}`; без `set -e`/`set -u` в самом скрипте строки статуса (он всегда должен что-то вывести и выйти с 0).
- Никакой сети. Не читать `~/.claude/.credentials.json`, cookie, эндпоинты. Единственный вход скрипта — stdin; единственный вход приложения — `limits.json`.
- Зависимости: скрипт — только `jq`; Swift — только Foundation и AppKit; минимальная macOS 13.0.
- Длина окна: 5ч = `18000` с, неделя = `604800` с.
- Пороги цвета по исходному проценту `u`: `u < 60` зелёный, `60 ≤ u < 85` жёлтый, `u ≥ 85` красный. В строке меню «жёлтый» рисуется `NSColor.systemOrange` (на светлой строке меню `systemYellow` нечитаем).
- Данные устаревшие, если `now − updated_at > 1800` с. Прогноз считается, только если прошло `≥ 600` с окна и `0 < u < 100`.
- Строки интерфейса — на русском, ровно как в спецификации: `5ч`, `нед`, `лимиты: —`, `5 часов`, `Неделя`, `сброс в`, `в таком темпе кончится ~`, `обновлено … назад`, `Выход`.
- Переменные окружения для тестов: `CLAUDE_LIMITS_NOW` (текущее время, epoch-секунды), `CLAUDE_LIMITS_FILE` (путь к `limits.json`), `NO_COLOR` (непустая — без ANSI-цветов).
- Коммиты заканчиваются строкой `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Email автора уже настроен локально в репозитории.
- Зависимости между задачами: 1 и 2 независимы; 3 зависит от 2; 4 зависит от 1 и 3; 5 выполняет только ведущая сессия, с подтверждениями пользователя.

## File Structure

```
statusline/statusline-limits.sh   скрипт строки статуса: вывод S4 + запись limits.json
statusline/test/run.sh            тесты скрипта
menubar/Sources/LimitsCore.swift  чистая логика: разбор, пороги, состояния колец, время, прогноз, строки меню
menubar/Sources/RingIcon.swift    рисование значка: два кольца с числами
menubar/Sources/AppDelegate.swift строка меню: значок, меню, таймер
menubar/Sources/Preview.swift     --preview: рендер всех состояний значка в PNG
menubar/Sources/main.swift        точка входа
menubar/Tests/main.swift          тесты LimitsCore
menubar/Info.plist                LSUIElement-приложение
menubar/build.sh                  сборка build/ClaudeLimits.app
menubar/test.sh                   сборка и запуск тестов LimitsCore
menubar/install-launch-agent.sh   автозапуск через LaunchAgent
install.sh                        копирует скрипт и приложение на место
```

---

### Task 1: Скрипт строки статуса

**Files:**
- Create: `statusline/statusline-limits.sh`
- Test: `statusline/test/run.sh`

**Interfaces:**
- Consumes: JSON Claude Code на stdin (`rate_limits.five_hour|seven_day.used_percentage|resets_at`).
- Produces: одна строка на stdout; файл `$CLAUDE_LIMITS_FILE` (по умолчанию `~/.claude/limits.json`) вида `{"updated_at":<int>,"five_hour":{"used_percentage":<num>,"resets_at":<num>},"seven_day":{...}}`, где отсутствующее окно опущено. Этот формат читает Task 2 (`parseSnapshot`).

- [ ] **Step 1: Write the failing test**

`statusline/test/run.sh`:

```bash
#!/bin/bash
# Tests for statusline-limits.sh. Run: bash statusline/test/run.sh
cd "$(dirname "$0")/.." || exit 1
SCRIPT=$PWD/statusline-limits.sh
NOW=1760958000
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

run() {  # $1 = stdin
  printf '%s' "$1" | NO_COLOR=1 CLAUDE_LIMITS_NOW=$NOW CLAUDE_LIMITS_FILE="$TMP/limits.json" bash "$SCRIPT"
}
run_colored() {  # $1 = stdin
  printf '%s' "$1" | env -u NO_COLOR CLAUDE_LIMITS_NOW=$NOW CLAUDE_LIMITS_FILE="$TMP/limits.json" bash "$SCRIPT"
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

expect "green below 60" yes "$(contains "$(run_colored "$(limits "$(win 59.9 7800)" "")")" $'\e[32m')"
expect "yellow at 62" yes "$(contains "$(run_colored "$(limits "$(win 62 7800)" "")")" $'\e[33m')"
expect "red at 85" yes "$(contains "$(run_colored "$(limits "$(win 85 7800)" "")")" $'\e[31m')"
expect "no color with NO_COLOR" no "$(contains "$(run "$(limits "$H5" "")")" $'\e[')"

echo
if ((FAILS)); then echo "$FAILS failed"; exit 1; else echo "all passed"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash statusline/test/run.sh`
Expected: FAIL почти во всех проверках (скрипта ещё нет), последняя строка `N failed`, код выхода 1.

- [ ] **Step 3: Write minimal implementation**

`statusline/statusline-limits.sh`:

```bash
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
```

Then: `chmod +x statusline/statusline-limits.sh statusline/test/run.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash statusline/test/run.sh`
Expected: все строки `ok …`, последняя строка `all passed`, код выхода 0.

- [ ] **Step 5: Commit**

```bash
git add statusline
git commit -m "Add status line script with smooth limit bars" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Логика строки меню (LimitsCore)

**Files:**
- Create: `menubar/Sources/LimitsCore.swift`
- Create: `menubar/test.sh`
- Test: `menubar/Tests/main.swift`

**Interfaces:**
- Consumes: формат `limits.json` из Task 1.
- Produces (используется в Task 3):
  - `struct LimitWindow: Equatable { let usedPercentage: Double; let resetsAt: TimeInterval }`
  - `struct Snapshot: Equatable { let updatedAt: TimeInterval; let fiveHour: LimitWindow?; let sevenDay: LimitWindow? }`
  - `enum WindowKind { case fiveHour, sevenDay; var length: TimeInterval }`
  - `enum Level: Equatable { case ok, warn, danger }`
  - `enum RingState: Equatable { case normal(fraction: Double, level: Level, label: String); case exhausted; case stale(fraction: Double, label: String); case empty }`
  - `func parseSnapshot(_ data: Data) -> Snapshot?`
  - `func level(for used: Double) -> Level`
  - `func ringState(_ window: LimitWindow?, updatedAt: TimeInterval?, now: TimeInterval) -> RingState`
  - `func formatClock(_ time: TimeInterval, now: TimeInterval, calendar: Calendar) -> String`
  - `func forecastExhaustion(_ window: LimitWindow, kind: WindowKind, now: TimeInterval) -> TimeInterval?`
  - `func windowLine(title: String, _ window: LimitWindow?, now: TimeInterval, calendar: Calendar) -> String`
  - `func forecastLine(_ window: LimitWindow?, kind: WindowKind, now: TimeInterval, calendar: Calendar) -> String?`
  - `func updatedLine(_ updatedAt: TimeInterval?, now: TimeInterval) -> String`

- [ ] **Step 1: Write the failing test**

`menubar/Tests/main.swift`:

```swift
import Foundation

var failures = 0

func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected {
        print("ok   \(name)")
    } else {
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
        failures += 1
    }
}

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let now: TimeInterval = 1_760_958_000  // Mon 2025-10-20 11:00 UTC

let both = #"{"updated_at":1760958000,"five_hour":{"used_percentage":42.5,"resets_at":1760965800},"seven_day":{"used_percentage":18,"resets_at":1761314400}}"#
check("parse both", parseSnapshot(Data(both.utf8)),
      Snapshot(updatedAt: now,
               fiveHour: LimitWindow(usedPercentage: 42.5, resetsAt: 1_760_965_800),
               sevenDay: LimitWindow(usedPercentage: 18, resetsAt: 1_761_314_400)))
check("parse five hour only",
      parseSnapshot(Data(#"{"updated_at":1,"five_hour":{"used_percentage":1,"resets_at":2}}"#.utf8))?.sevenDay, nil)
check("parse invalid", parseSnapshot(Data("not json".utf8)), nil)
check("parse without updated_at",
      parseSnapshot(Data(#"{"five_hour":{"used_percentage":1,"resets_at":2}}"#.utf8)), nil)

check("59.9 ok", level(for: 59.9), .ok)
check("60 warn", level(for: 60), .warn)
check("84.9 warn", level(for: 84.9), .warn)
check("85 danger", level(for: 85), .danger)

let w62 = LimitWindow(usedPercentage: 62, resetsAt: now + 3_600)
check("ring normal", ringState(w62, updatedAt: now, now: now),
      .normal(fraction: 0.62, level: .warn, label: "62"))
check("ring exhausted",
      ringState(LimitWindow(usedPercentage: 104, resetsAt: now + 60), updatedAt: now, now: now), .exhausted)
check("ring stale", ringState(w62, updatedAt: now - 1_801, now: now), .stale(fraction: 0.62, label: "62"))
check("ring not yet stale", ringState(w62, updatedAt: now - 1_800, now: now),
      .normal(fraction: 0.62, level: .warn, label: "62"))
check("ring reset passed",
      ringState(LimitWindow(usedPercentage: 62, resetsAt: now), updatedAt: now, now: now), .empty)
check("ring no window", ringState(nil, updatedAt: now, now: now), .empty)
check("ring no file", ringState(w62, updatedAt: nil, now: now), .empty)
check("ring label caps at 99",
      ringState(LimitWindow(usedPercentage: 99.75, resetsAt: now + 60), updatedAt: now, now: now),
      .normal(fraction: 0.9975, level: .danger, label: "99"))

check("clock same day", formatClock(now + 7_800, now: now, calendar: utc), "13:10")
check("clock other day", formatClock(now + 356_400, now: now, calendar: utc), "пт 14:00")

let fast = LimitWindow(usedPercentage: 62, resetsAt: now + 10_800)  // 2h into the 5h window
check("forecast before reset",
      forecastExhaustion(fast, kind: .fiveHour, now: now).map { formatClock($0, now: now, calendar: utc) }, "12:13")
check("no forecast early in window",
      forecastExhaustion(LimitWindow(usedPercentage: 30, resetsAt: now + 17_700), kind: .fiveHour, now: now), nil)
check("no forecast when it lasts",
      forecastExhaustion(LimitWindow(usedPercentage: 18, resetsAt: now + 356_400), kind: .sevenDay, now: now), nil)
check("no forecast at zero",
      forecastExhaustion(LimitWindow(usedPercentage: 0, resetsAt: now + 10_800), kind: .fiveHour, now: now), nil)

check("window line", windowLine(title: "5 часов", fast, now: now, calendar: utc), "5 часов: 62% · сброс в 14:00")
check("window line reset",
      windowLine(title: "Неделя", LimitWindow(usedPercentage: 5, resetsAt: now - 1), now: now, calendar: utc),
      "Неделя: сброшен")
check("window line missing", windowLine(title: "Неделя", nil, now: now, calendar: utc), "Неделя: нет данных")
check("forecast line", forecastLine(fast, kind: .fiveHour, now: now, calendar: utc), "в таком темпе кончится ~12:13")
check("updated just now", updatedLine(now - 30, now: now), "обновлено только что")
check("updated minutes", updatedLine(now - 150, now: now), "обновлено 2 мин назад")
check("updated hours", updatedLine(now - 7_300, now: now), "обновлено 2 ч назад")
check("updated never", updatedLine(nil, now: now), "нет данных: запустите Claude Code")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
```

`menubar/test.sh`:

```bash
#!/bin/bash
# Builds and runs the LimitsCore tests. Run: bash menubar/test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../build
swiftc -o ../build/limits-core-tests Sources/LimitsCore.swift Tests/main.swift
../build/limits-core-tests
```

Then: `chmod +x menubar/test.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash menubar/test.sh`
Expected: ошибка компиляции `no such file or directory: 'Sources/LimitsCore.swift'` (или `cannot find 'parseSnapshot' in scope`), код выхода ≠ 0.

- [ ] **Step 3: Write minimal implementation**

`menubar/Sources/LimitsCore.swift`:

```swift
import Foundation

// Pure logic for the menu bar app: parsing ~/.claude/limits.json, thresholds,
// ring states, clock formatting and the exhaustion forecast. No AppKit here.

struct LimitWindow: Equatable {
    let usedPercentage: Double
    let resetsAt: TimeInterval
}

struct Snapshot: Equatable {
    let updatedAt: TimeInterval
    let fiveHour: LimitWindow?
    let sevenDay: LimitWindow?
}

enum WindowKind {
    case fiveHour, sevenDay

    var length: TimeInterval { self == .fiveHour ? 18_000 : 604_800 }
}

enum Level: Equatable {
    case ok, warn, danger
}

enum RingState: Equatable {
    case normal(fraction: Double, level: Level, label: String)
    case exhausted
    case stale(fraction: Double, label: String)
    case empty
}

let staleAfter: TimeInterval = 1_800
let forecastMinElapsed: TimeInterval = 600

private let weekdays = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]

func parseSnapshot(_ data: Data) -> Snapshot? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let updatedAt = (object["updated_at"] as? NSNumber)?.doubleValue else { return nil }
    func window(_ key: String) -> LimitWindow? {
        guard let w = object[key] as? [String: Any],
              let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        return LimitWindow(usedPercentage: used, resetsAt: resets)
    }
    return Snapshot(updatedAt: updatedAt, fiveHour: window("five_hour"), sevenDay: window("seven_day"))
}

func level(for used: Double) -> Level {
    if used < 60 { return .ok }
    if used < 85 { return .warn }
    return .danger
}

private func percentLabel(_ used: Double) -> String {
    String(Int(used.rounded()))
}

func ringState(_ window: LimitWindow?, updatedAt: TimeInterval?, now: TimeInterval) -> RingState {
    guard let window, let updatedAt, window.resetsAt > now else { return .empty }
    if window.usedPercentage >= 100 { return .exhausted }
    let fraction = max(0, window.usedPercentage) / 100
    let label = String(min(99, Int(window.usedPercentage.rounded())))
    if now - updatedAt > staleAfter { return .stale(fraction: fraction, label: label) }
    return .normal(fraction: fraction, level: level(for: window.usedPercentage), label: label)
}

func formatClock(_ time: TimeInterval, now: TimeInterval, calendar: Calendar) -> String {
    let date = Date(timeIntervalSince1970: time)
    let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
    let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    if calendar.isDate(date, inSameDayAs: Date(timeIntervalSince1970: now)) { return clock }
    return "\(weekdays[(parts.weekday ?? 1) - 1]) \(clock)"
}

func forecastExhaustion(_ window: LimitWindow, kind: WindowKind, now: TimeInterval) -> TimeInterval? {
    let used = window.usedPercentage
    let elapsed = now - (window.resetsAt - kind.length)
    guard elapsed >= forecastMinElapsed, used > 0, used < 100 else { return nil }
    let end = now + (100 - used) * elapsed / used
    return end < window.resetsAt ? end : nil
}

func windowLine(title: String, _ window: LimitWindow?, now: TimeInterval, calendar: Calendar) -> String {
    guard let window else { return "\(title): нет данных" }
    guard window.resetsAt > now else { return "\(title): сброшен" }
    let reset = formatClock(window.resetsAt, now: now, calendar: calendar)
    return "\(title): \(percentLabel(window.usedPercentage))% · сброс в \(reset)"
}

func forecastLine(_ window: LimitWindow?, kind: WindowKind, now: TimeInterval, calendar: Calendar) -> String? {
    guard let window, window.resetsAt > now,
          let end = forecastExhaustion(window, kind: kind, now: now) else { return nil }
    return "в таком темпе кончится ~\(formatClock(end, now: now, calendar: calendar))"
}

func updatedLine(_ updatedAt: TimeInterval?, now: TimeInterval) -> String {
    guard let updatedAt else { return "нет данных: запустите Claude Code" }
    let minutes = Int(max(0, now - updatedAt) / 60)
    if minutes < 1 { return "обновлено только что" }
    if minutes < 60 { return "обновлено \(minutes) мин назад" }
    if minutes < 1_440 { return "обновлено \(minutes / 60) ч назад" }
    return "обновлено \(minutes / 1_440) д назад"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash menubar/test.sh`
Expected: все строки `ok …`, последняя `all passed`, код выхода 0.

- [ ] **Step 5: Commit**

```bash
git add menubar/Sources/LimitsCore.swift menubar/Tests menubar/test.sh
git commit -m "Add menu bar limits logic with tests" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Приложение в строке меню

**Files:**
- Create: `menubar/Sources/RingIcon.swift`
- Create: `menubar/Sources/Preview.swift`
- Create: `menubar/Sources/AppDelegate.swift`
- Create: `menubar/Sources/main.swift`
- Create: `menubar/Info.plist`
- Create: `menubar/build.sh`

**Interfaces:**
- Consumes: всё из Task 2 (`Snapshot`, `RingState`, `Level`, `WindowKind`, `parseSnapshot`, `ringState`, `windowLine`, `forecastLine`, `updatedLine`).
- Produces: `build/ClaudeLimits.app` (через `bash menubar/build.sh`); режим `ClaudeLimits --preview <png>`; переменная `CLAUDE_LIMITS_FILE` переопределяет путь к файлу. Используется в Task 4.

- [ ] **Step 1: Write the build script and bundle metadata**

`menubar/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.flydge.claude-limits</string>
  <key>CFBundleName</key><string>ClaudeLimits</string>
  <key>CFBundleExecutable</key><string>ClaudeLimits</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
```

`menubar/build.sh`:

```bash
#!/bin/bash
# Builds build/ClaudeLimits.app with swiftc. Run: bash menubar/build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=../build/ClaudeLimits.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ClaudeLimits" Sources/*.swift
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $(cd "$APP" && pwd)"
```

Then: `chmod +x menubar/build.sh`

- [ ] **Step 2: Run the build to verify it fails**

Run: `bash menubar/build.sh`
Expected: ошибка компиляции, в модуле нет точки входа (`main.swift` ещё не создан), код выхода ≠ 0.

- [ ] **Step 3: Write the icon, preview, delegate and entry point**

`menubar/Sources/RingIcon.swift`:

```swift
import AppKit

// Draws the menu bar icon: two rings with the percentage inside.

enum RingIcon {
    static let ringSize: CGFloat = 20
    static let gap: CGFloat = 4
    static let lineWidth: CGFloat = 1.8

    static func image(_ left: RingState, _ right: RingState) -> NSImage {
        let size = NSSize(width: ringSize * 2 + gap, height: ringSize)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(left, in: NSRect(x: 0, y: 0, width: ringSize, height: ringSize))
            draw(right, in: NSRect(x: ringSize + gap, y: 0, width: ringSize, height: ringSize))
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(for state: RingState) -> NSColor {
        switch state {
        case .normal(_, let level, _): return color(for: level)
        case .exhausted: return .systemRed
        case .stale, .empty: return .secondaryLabelColor
        }
    }

    static func color(for level: Level) -> NSColor {
        switch level {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .danger: return .systemRed
        }
    }

    private static func draw(_ state: RingState, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (rect.width - lineWidth) / 2 - 0.5

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()

        let fraction: Double
        let label: String
        switch state {
        case .normal(let f, _, let l), .stale(let f, let l): (fraction, label) = (f, l)
        case .exhausted: (fraction, label) = (1, "!")
        case .empty: (fraction, label) = (0, "–")
        }

        if fraction > 0 {
            let arc = NSBezierPath()
            if fraction >= 1 {
                arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            } else {
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
                arc.lineCapStyle = .round
            }
            arc.lineWidth = lineWidth
            color(for: state).setStroke()
            arc.stroke()
        }

        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
```

`menubar/Sources/Preview.swift`:

```swift
import AppKit

// Renders every ring state, in light and dark appearance, to a PNG so the icon
// can be checked without the menu bar:  ClaudeLimits --preview out.png

enum Preview {
    static func render(to path: String) -> Bool {
        let rows: [(RingState, RingState)] = [
            (.normal(fraction: 0.42, level: .ok, label: "42"), .normal(fraction: 0.18, level: .ok, label: "18")),
            (.normal(fraction: 0.62, level: .warn, label: "62"), .normal(fraction: 0.88, level: .danger, label: "88")),
            (.exhausted, .stale(fraction: 0.3, label: "30")),
            (.empty, .empty),
        ]
        let scale: CGFloat = 4
        let pad: CGFloat = 6
        let icon = NSSize(width: RingIcon.ringSize * 2 + RingIcon.gap, height: RingIcon.ringSize)
        let columnWidth = icon.width + pad * 2
        let width = columnWidth * 2
        let height = (icon.height + pad) * CGFloat(rows.count) + pad
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (column, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let x = CGFloat(column) * columnWidth
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: x, y: 0, width: columnWidth, height: height).fill()
                for (index, row) in rows.enumerated() {
                    let y = height - CGFloat(index + 1) * (icon.height + pad)
                    RingIcon.image(row.0, row.1).draw(
                        at: NSPoint(x: x + pad, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
```

`menubar/Sources/AppDelegate.swift`:

```swift
import AppKit

// Menu bar item: two rings from ~/.claude/limits.json, details in the menu.

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private let fileURL: URL = {
        let path = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_FILE"] ?? "~/.claude/limits.json"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Лимиты Claude: 5 часов и неделя"
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func tick() {
        refresh()
    }

    private func refresh() {
        let snapshot = (try? Data(contentsOf: fileURL)).flatMap(parseSnapshot)
        let now = Date().timeIntervalSince1970
        let five = ringState(snapshot?.fiveHour, updatedAt: snapshot?.updatedAt, now: now)
        let week = ringState(snapshot?.sevenDay, updatedAt: snapshot?.updatedAt, now: now)
        statusItem.button?.image = RingIcon.image(five, week)
        rebuildMenu(snapshot, five: five, week: week, now: now)
    }

    private func rebuildMenu(_ snapshot: Snapshot?, five: RingState, week: RingState, now: TimeInterval) {
        let calendar = Calendar.current
        menu.removeAllItems()

        menu.addItem(windowItem(windowLine(title: "5 часов", snapshot?.fiveHour, now: now, calendar: calendar),
                                state: five))
        if case .normal = five,
           let line = forecastLine(snapshot?.fiveHour, kind: .fiveHour, now: now, calendar: calendar) {
            menu.addItem(noteItem(line, indented: true))
        }

        menu.addItem(windowItem(windowLine(title: "Неделя", snapshot?.sevenDay, now: now, calendar: calendar),
                                state: week))
        if case .normal = week,
           let line = forecastLine(snapshot?.sevenDay, kind: .sevenDay, now: now, calendar: calendar) {
            menu.addItem(noteItem(line, indented: true))
        }

        menu.addItem(.separator())
        menu.addItem(noteItem(updatedLine(snapshot?.updatedAt, now: now), indented: false))

        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func windowItem(_ title: String, state: RingState) -> NSMenuItem {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: "● ", attributes: [
            .font: font, .foregroundColor: RingIcon.color(for: state),
        ])
        text.append(NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]))
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = text
        return item
    }

    private func noteItem(_ title: String, indented: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.indentationLevel = indented ? 1 : 0
        return item
    }
}
```

`menubar/Sources/main.swift`:

```swift
import AppKit

let app = NSApplication.shared

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--preview" {
    exit(Preview.render(to: arguments[2]) ? 0 : 1)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 4: Build and verify**

Run: `bash menubar/build.sh`
Expected: `Built /Users/…/claude-limits/build/ClaudeLimits.app`, код выхода 0.

Run: `build/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --preview build/preview.png && echo ok`
Expected: `ok`. Открыть `build/preview.png` (инструмент Read) и проверить:
- светлая и тёмная колонки, по 4 ряда;
- ряд 1: зелёные кольца, заполнены примерно на 42 % и 18 %, числа `42` и `18` читаются и стоят по центру;
- ряд 2: оранжевое кольцо `62`, красное `88`;
- ряд 3: полное красное кольцо `!`, серое кольцо `30`;
- ряд 4: два пустых кольца с `–`;
- в тёмной колонке цифры светлые.

Run: `bash menubar/test.sh`
Expected: `all passed` (новые файлы не сломали LimitsCore).

Живая проверка:

```bash
mkdir -p build/live && printf '{"updated_at":%s,"five_hour":{"used_percentage":62,"resets_at":%s},"seven_day":{"used_percentage":18,"resets_at":%s}}' "$(date +%s)" "$(( $(date +%s) + 10800 ))" "$(( $(date +%s) + 356400 ))" > build/live/limits.json
```

```bash
CLAUDE_LIMITS_FILE=$PWD/build/live/limits.json build/ClaudeLimits.app/Contents/MacOS/ClaudeLimits &
```

Сделать скриншот верхней полосы экрана (`screencapture -x -R0,0,1800,40 build/menubar.png` или скриншот через computer-use, если нет права на запись экрана). Убедиться, что кольца `62` и `18` видны. Открыть меню кликом и проверить строки: `5 часов: 62% · сброс в …`, прогноз `в таком темпе кончится ~…`, `Неделя: 18% · сброс в …`, `обновлено только что`, `Выход`. Закрыть приложение: `pkill -f build/ClaudeLimits.app`.

- [ ] **Step 5: Commit**

```bash
git add menubar
git commit -m "Add menu bar app with ring icon and details menu" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Установка и README

**Files:**
- Create: `install.sh`
- Create: `menubar/install-launch-agent.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `statusline/statusline-limits.sh` (Task 1), `menubar/build.sh` и `build/ClaudeLimits.app` (Task 3).
- Produces: `~/.claude/statusline-limits.sh`, `~/Applications/ClaudeLimits.app`; LaunchAgent `com.flydge.claude-limits`. Используется в Task 5.

- [ ] **Step 1: Write install scripts**

`install.sh`:

```bash
#!/bin/bash
# Copies the status line script and the menu bar app into place.
# Does not edit ~/.claude/settings.json or install the launch agent: see README.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p "$HOME/.claude" "$HOME/Applications"
install -m 755 statusline/statusline-limits.sh "$HOME/.claude/statusline-limits.sh"
bash menubar/build.sh
rm -rf "$HOME/Applications/ClaudeLimits.app"
cp -R build/ClaudeLimits.app "$HOME/Applications/"
echo "Installed:"
echo "  $HOME/.claude/statusline-limits.sh"
echo "  $HOME/Applications/ClaudeLimits.app"
```

`menubar/install-launch-agent.sh`:

```bash
#!/bin/bash
# Starts ClaudeLimits at login through a user LaunchAgent, and starts it now.
set -euo pipefail
LABEL=com.flydge.claude-limits
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$HOME/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits"
[ -x "$BIN" ] || { echo "Run ./install.sh first: $BIN not found" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Loaded $PLIST"
```

Then: `chmod +x install.sh menubar/install-launch-agent.sh`

- [ ] **Step 2: Verify scripts without touching the real home**

Run: `bash -n install.sh && bash -n menubar/install-launch-agent.sh && echo syntax-ok`
Expected: `syntax-ok`.

Run: `T=$(mktemp -d) && HOME=$T bash install.sh && ls "$T/.claude/statusline-limits.sh" "$T/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits"`
Expected: `Installed:`, затем оба пути внутри временной папки печатаются `ls` без ошибок. Настоящий `~` не затронут.

- [ ] **Step 3: Update README**

`README.md` целиком:

````markdown
# claude-limits

Показывает расход 5-часового и недельного лимита подписки Claude:

- в строке статуса Claude Code — гладкие полосы с процентом и временем до сброса;
- в строке меню macOS — два кольца с числами и меню с деталями.

```
5ч ████▎····· 42% 2ч10м   нед █▊········ 18% 4д3ч
```

Данные берутся только из JSON, который Claude Code сам передаёт скрипту строки статуса.
Без сети, без токенов и cookie. Строка меню читает копию этих данных из `~/.claude/limits.json`,
поэтому обновляется, пока вы работаете в Claude Code.

Требования: macOS 13+, `jq`, Command Line Tools (`swiftc`), подписка Claude Pro или Max.

## Установка

```bash
./install.sh
```

Затем добавьте в `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/statusline-limits.sh",
  "refreshInterval": 60
}
```

Автозапуск строки меню при входе:

```bash
bash menubar/install-launch-agent.sh
```

## Удаление

```bash
launchctl bootout "gui/$(id -u)/com.flydge.claude-limits"; rm -f ~/Library/LaunchAgents/com.flydge.claude-limits.plist
rm -rf ~/Applications/ClaudeLimits.app ~/.claude/statusline-limits.sh ~/.claude/limits.json
```

И уберите `statusLine` из `~/.claude/settings.json`.

## Разработка

```bash
bash statusline/test/run.sh      # тесты строки статуса
bash menubar/test.sh             # тесты логики строки меню
bash menubar/build.sh            # сборка build/ClaudeLimits.app
build/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --preview build/preview.png   # все состояния значка
```

Дизайн: [docs/superpowers/specs/2026-10-20-claude-limits-design.md](docs/superpowers/specs/2026-10-20-claude-limits-design.md).
````

- [ ] **Step 4: Run all tests**

Run: `bash statusline/test/run.sh && bash menubar/test.sh`
Expected: оба заканчиваются `all passed`.

- [ ] **Step 5: Commit**

```bash
git add install.sh menubar/install-launch-agent.sh README.md
git commit -m "Add install scripts and README" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Установка на машине пользователя (только ведущая сессия)

Каждый шаг, меняющий конфигурацию пользователя, выполняется только после явного «да» в чате.

**Files:**
- Modify: `~/.claude/settings.json` (после подтверждения)
- Create: `~/Library/LaunchAgents/com.flydge.claude-limits.plist` (после подтверждения)

- [ ] **Step 1: Install files**

Run: `./install.sh`
Expected: `Installed:` и пути `~/.claude/statusline-limits.sh`, `~/Applications/ClaudeLimits.app`.

- [ ] **Step 2: Show settings.json diff and ask**

```bash
jq '.statusLine = {"type":"command","command":"~/.claude/statusline-limits.sh","refreshInterval":60}' ~/.claude/settings.json > build/settings.new.json && diff -u ~/.claude/settings.json build/settings.new.json
```

Показать diff пользователю. Только после «да»: `cp ~/.claude/settings.json build/settings.backup.json && mv build/settings.new.json ~/.claude/settings.json`.

- [ ] **Step 3: Ask about the launch agent**

Показать пользователю содержимое plist из `menubar/install-launch-agent.sh`. Только после «да»: `bash menubar/install-launch-agent.sh`. Иначе запустить один раз: `open ~/Applications/ClaudeLimits.app`.

- [ ] **Step 4: Check Claude Desktop**

После следующего ответа в этой сессии (вкладка Code приложения Claude) проверить:
`stat -f '%Sm' ~/.claude/limits.json; jq . ~/.claude/limits.json`.
Если файл появился и `updated_at` свежий — строка статуса запускается и в Desktop. Если нет — запускается только в терминальном `claude`. Сообщить пользователю результат.

- [ ] **Step 5: Push**

```bash
git push
```
