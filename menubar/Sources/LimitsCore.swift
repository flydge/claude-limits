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
