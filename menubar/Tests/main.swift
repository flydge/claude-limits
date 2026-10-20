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

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
