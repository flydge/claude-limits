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

check("clock same day", formatClock(now + 7_800, now: now, calendar: utc, lang: .ru), "13:10")
check("clock other day", formatClock(now + 356_400, now: now, calendar: utc, lang: .ru), "пт 14:00")

let fast = LimitWindow(usedPercentage: 62, resetsAt: now + 10_800)  // 2h into the 5h window
check("forecast before reset",
      forecastExhaustion(fast, kind: .fiveHour, now: now).map { formatClock($0, now: now, calendar: utc, lang: .ru) }, "12:13")
check("no forecast early in window",
      forecastExhaustion(LimitWindow(usedPercentage: 30, resetsAt: now + 17_700), kind: .fiveHour, now: now), nil)
check("no forecast when it lasts",
      forecastExhaustion(LimitWindow(usedPercentage: 18, resetsAt: now + 356_400), kind: .sevenDay, now: now), nil)
check("no forecast at zero",
      forecastExhaustion(LimitWindow(usedPercentage: 0, resetsAt: now + 10_800), kind: .fiveHour, now: now), nil)

check("window line", windowLine(title: "5 часов", fast, now: now, calendar: utc, lang: .ru), "5 часов: 62% · сброс в 14:00")
check("window line reset",
      windowLine(title: "Неделя", LimitWindow(usedPercentage: 5, resetsAt: now - 1), now: now, calendar: utc, lang: .ru),
      "Неделя: сброшен")
check("window line missing", windowLine(title: "Неделя", nil, now: now, calendar: utc, lang: .ru), "Неделя: нет данных")
check("forecast line", forecastLine(fast, kind: .fiveHour, now: now, calendar: utc, lang: .ru), "в таком темпе кончится ~12:13")
check("updated just now", updatedLine(now - 30, now: now, lang: .ru), "обновлено только что")
check("updated minutes", updatedLine(now - 150, now: now, lang: .ru), "обновлено 2 мин назад")
check("updated hours", updatedLine(now - 7_300, now: now, lang: .ru), "обновлено 2 ч назад")
check("updated never", updatedLine(nil, now: now, lang: .ru), "нет данных: запустите Claude Code")

check("lang override wins", Lang.resolve(override: "ru", preferred: ["en-US"]), .ru)
check("lang from system", Lang.resolve(override: nil, preferred: ["ru-BY", "en-US"]), .ru)
check("empty override uses system", Lang.resolve(override: "", preferred: ["en-US"]), .en)
check("other languages are english", Lang.resolve(override: nil, preferred: ["de-DE"]), .en)
check("no languages is english", Lang.resolve(override: nil, preferred: []), .en)
check("english window line", windowLine(title: "5 hours", fast, now: now, calendar: utc, lang: .en),
      "5 hours: 62% · resets 14:00")
check("english other day", formatClock(now + 356_400, now: now, calendar: utc, lang: .en), "Fri 14:00")
check("english forecast", forecastLine(fast, kind: .fiveHour, now: now, calendar: utc, lang: .en),
      "at this pace runs out ~12:13")
check("english reset", windowLine(title: "Week", LimitWindow(usedPercentage: 5, resetsAt: now - 1), now: now,
                                  calendar: utc, lang: .en), "Week: reset")
check("english updated", updatedLine(now - 150, now: now, lang: .en), "updated 2 min ago")
check("english never", updatedLine(nil, now: now, lang: .en), "no data: run Claude Code")

// System item
let gib64: UInt64 = 1_073_741_824
func mem(used: UInt64, swap: UInt64 = 0, pressure: Pressure = .normal) -> MemoryReading {
    MemoryReading(total: 48 * gib64, used: used * gib64, compressed: 20 * gib64, swapUsed: swap * gib64,
                  pressure: pressure)
}
check("pressure from sysctl", [1, 2, 4, 0].map { Pressure(sysctlLevel: $0) }, [.normal, .warn, .critical, .normal])
check("memory ok", memoryLevel(mem(used: 40)), .ok)
check("memory pressure warn", memoryLevel(mem(used: 40, pressure: .warn)), .warn)
check("memory pressure critical", memoryLevel(mem(used: 40, pressure: .critical)), .danger)
check("swap quarter of ram warns", memoryLevel(mem(used: 40, swap: 12)), .warn)
check("swap half of ram is danger", memoryLevel(mem(used: 40, swap: 24, pressure: .warn)), .danger)
check("memory ring", memoryRing(mem(used: 42, swap: 29, pressure: .warn)),
      .normal(fraction: 0.875, level: .danger, label: "88"))
check("memory ring missing", memoryRing(nil), .empty)

let tb: UInt64 = 995_000_000_000
check("disk ok", diskLevel(DiskReading(total: tb, available: 50_000_000_000)), .ok)
check("disk warn", diskLevel(DiskReading(total: tb, available: 49_999_999_999)), .warn)
check("disk danger", diskLevel(DiskReading(total: tb, available: 19_200_000_000)), .danger)
check("disk ring", diskRing(DiskReading(total: tb, available: 19_200_000_000)),
      .normal(fraction: 1 - 19.2 / 995, level: .danger, label: "98"))
check("disk ring available above total", diskRing(DiskReading(total: 10, available: 20)),
      .normal(fraction: 0, level: .danger, label: "0"))

check("alert on fall into red", shouldAlert(previous: .warn, current: .danger, lastAlert: nil, now: now), true)
check("alert at launch in red", shouldAlert(previous: nil, current: .danger, lastAlert: nil, now: now), true)
check("no alert while staying red", shouldAlert(previous: .danger, current: .danger, lastAlert: nil, now: now), false)
check("no alert outside red", shouldAlert(previous: .ok, current: .warn, lastAlert: nil, now: now), false)
check("no alert within cooldown", shouldAlert(previous: .warn, current: .danger, lastAlert: now - 1_799, now: now), false)
check("alert after cooldown", shouldAlert(previous: .warn, current: .danger, lastAlert: now - 1_800, now: now), true)

check("app from helper", appName(fromPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"), "Google Chrome")
check("app claude code in desktop", appName(fromPath: "/Users/u/Library/Application Support/Claude/claude-code/2.1.299/4fa9/claude.app/Contents/MacOS/claude"), "Claude Code")
check("app claude code cli", appName(fromPath: "/Users/u/.local/share/claude/versions/2.1.299"), "Claude Code")
check("app plain binary", appName(fromPath: "/opt/homebrew/Cellar/node/24.1.0/bin/node"), "node")
check("group processes", groupProcesses([
    (path: "/Applications/Claude.app/Contents/MacOS/Claude", footprint: 3),
    (path: "/usr/local/bin/node", footprint: 4),
    (path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper", footprint: 2),
    (path: "/bin/zsh", footprint: 1),
], limit: 2), [ProcessGroup(name: "Claude", count: 2, footprint: 5), ProcessGroup(name: "node", count: 1, footprint: 4)])

check("size one decimal ru", formatSize(45_500_000_000, unit: gigabyte, lang: .ru), "45,5")
check("size whole", formatSize(48 * gib64, unit: gibibyte, lang: .en), "48")
check("size above hundred", formatSize(994_700_000_000, unit: gigabyte, lang: .en), "995")
check("memory line ru", memoryLine(mem(used: 42, swap: 29, pressure: .warn), lang: .ru),
      "Память: занято 42 из 48 ГБ · давление: высокое")
check("memory line en", memoryLine(mem(used: 42, pressure: .critical), lang: .en),
      "Memory: used 42 of 48 GB · pressure: critical")
check("memory detail", memoryDetailLine(mem(used: 42, swap: 29), lang: .ru), "сжато 20 ГБ · своп 29 ГБ")
check("disk line ru", diskLine(DiskReading(total: tb, available: 19_200_000_000), lang: .ru),
      "Диск: свободно 19,2 из 995 ГБ")
check("disk line missing", diskLine(nil, lang: .en), "Disk: no data")
check("process line", processLine(ProcessGroup(name: "ChatGPT", count: 292, footprint: 25_340_000_000), lang: .ru),
      "ChatGPT ×292 · 23,6 ГБ")
check("process line single", processLine(ProcessGroup(name: "Xogot", count: 1, footprint: 2 * gib64), lang: .en),
      "Xogot · 2 GB")

check("system json", systemJSON(memory: mem(used: 42, swap: 29, pressure: .warn),
                                disk: DiskReading(total: 100, available: 10),
                                top: [ProcessGroup(name: "node", count: 2, footprint: 5)]),
      #"{"disk":{"available":10,"level":"danger","total":100},"memory":{"compressed":21474836480,"level":"danger","pressure":"warn","swap_used":31138512896,"total":51539607552,"used":45097156608},"top":[{"count":2,"footprint":5,"name":"node"}]}"#)
check("system json empty", systemJSON(memory: nil, disk: nil, top: []), #"{"top":[]}"#)
check("system json stamped", systemJSON(memory: nil, disk: nil, top: [], updatedAt: 1_760_958_000.7),
      #"{"top":[],"updated_at":1760958000}"#)

// Attention: sessions waiting on the person.

check("state file", parseStateFile(Data(#"{"session_id":"cli-1","state":"permission","since":1760958000}"#.utf8)),
      SessionStateFile(cliId: "cli-1", state: .permission, since: now))
check("state file unknown state", parseStateFile(Data(#"{"session_id":"cli-1","state":"odd","since":1}"#.utf8)), nil)
check("state file not json", parseStateFile(Data("nope".utf8)), nil)
check("app session", parseAppSession(Data(#"{"sessionId":"local_a","cliSessionId":"cli-1","title":"Зона","isArchived":false,"lastFocusedAt":1760958000500,"model":"x"}"#.utf8)),
      AppSession(id: "local_a", cliId: "cli-1", title: "Зона", isArchived: false, lastFocusedAt: now + 0.5))
check("app session without title", parseAppSession(Data(#"{"sessionId":"local_a","cliSessionId":"cli-1"}"#.utf8))?.title, "")
check("app session without cli id", parseAppSession(Data(#"{"sessionId":"local_a"}"#.utf8)), nil)

func app(_ n: Int, focused: TimeInterval = now - 3_600, archived: Bool = false) -> AppSession {
    AppSession(id: "local_\(n)", cliId: "cli-\(n)", title: "S\(n)", isArchived: archived, lastFocusedAt: focused)
}
func state(_ n: Int, _ s: AttentionState, since: TimeInterval) -> SessionStateFile {
    SessionStateFile(cliId: "cli-\(n)", state: s, since: since)
}
let apps = [app(1), app(2), app(3), app(4, archived: true), app(5), app(6, focused: now - 60)]
let listed = waitingSessions(states: [
    state(1, .done, since: now - 600),          // finished, not looked at since
    state(2, .question, since: now - 120),
    state(3, .working, since: now - 30),        // working: not shown
    state(4, .permission, since: now - 900),    // archived in the app
    state(5, .permission, since: now - 300),
    state(7, .permission, since: now - 999),    // a terminal session: no app file
    state(6, .done, since: now - 120),          // opened after it finished
], apps: apps, claudeIsFrontmost: false)
check("waiting order and filter", listed.map(\.id), ["local_5", "local_2", "local_1"])
check("waiting link", listed.first?.link, "claude://claude.ai/epitaxy/local_5")
check("done on screen in a frontmost app is seen",
      waitingSessions(states: [state(6, .done, since: now - 30)], apps: apps, claudeIsFrontmost: true).count, 0)
check("done on screen in a background app waits",
      waitingSessions(states: [state(6, .done, since: now - 30)], apps: apps, claudeIsFrontmost: false).map(\.id),
      ["local_6"])
check("blocking on screen still waits",
      waitingSessions(states: [state(6, .permission, since: now - 30)], apps: apps, claudeIsFrontmost: true).count, 1)

check("bell hidden", bell([]), nil)
check("bell blocking", bell(listed), Bell(count: 3, isBlocking: true))
check("bell done only", bell(listed.filter { $0.state == .done }), Bell(count: 1, isBlocking: false))

let started = now - 3_600
let spell = waitingSessions(states: [state(5, .permission, since: now - 299)], apps: apps, claudeIsFrontmost: false)
check("no reminder before five minutes", remindersDue(spell, reminded: [], startedAt: started, now: now).count, 0)
check("reminder at five minutes", remindersDue(spell, reminded: [], startedAt: started, now: now + 1).map(\.id), ["local_5"])
check("one reminder per spell",
      remindersDue(spell, reminded: [spell[0].episode], startedAt: started, now: now + 600).count, 0)
let next = waitingSessions(states: [state(5, .done, since: now + 60)], apps: apps, claudeIsFrontmost: false)
check("a new spell is reminded anew",
      remindersDue(next, reminded: [spell[0].episode], startedAt: started, now: now + 360).map(\.state), [.done])
check("no reminder for a spell that passed five minutes before start",
      remindersDue(spell, reminded: [], startedAt: now + 2, now: now + 600).count, 0)

check("attention line ru", attentionLine(listed[0], now: now, lang: .ru), "S5 · нужно разрешение · 5 мин")
check("attention line en", attentionLine(listed[1], now: now, lang: .en), "S2 · has a question · 2 min")
check("attention line untitled",
      attentionLine(WaitingSession(id: "local_x", cliId: "c", title: " ", state: .done, since: now), now: now, lang: .ru),
      "Сессия без названия · готово · 0 мин")
check("attention json", attentionJSON([listed[0]], updatedAt: now + 0.4),
      #"{"sessions":[{"cli_id":"cli-5","id":"local_5","link":"claude://claude.ai/epitaxy/local_5","since":1760957700,"state":"permission","title":"S5"}],"updated_at":1760958000}"#)
check("attention json empty", attentionJSON([]), #"{"sessions":[]}"#)

let decided = waitingSessions(states: [
    state(1, .done, since: now - 900),
    state(2, .decision, since: now - 60),
    state(5, .question, since: now - 30),
], apps: apps, claudeIsFrontmost: false)
check("decision is orange, ahead of done", decided.map(\.state), [.decision, .question, .done])
check("bell orange for a decision", bell(decided.filter { $0.state != .question }), Bell(count: 2, isBlocking: true))
check("decision state file", parseStateFile(Data(#"{"session_id":"c","state":"decision","since":1}"#.utf8))?.state, .decision)
check("decision line ru", attentionLine(decided[0], now: now, lang: .ru), "S2 · ждёт решения · 1 мин")
check("decision line en", attentionLine(decided[0], now: now, lang: .en), "S2 · needs your decision · 1 min")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
