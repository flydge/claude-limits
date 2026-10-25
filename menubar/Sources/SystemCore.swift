import Foundation

// Pure logic for the second menu bar item: memory and disk readings, their levels,
// grouping processes by app and the menu lines. No AppKit or system calls here.

enum Pressure: Equatable {
    case normal, warn, critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical.
    init(sysctlLevel: Int32) {
        switch sysctlLevel {
        case 4: self = .critical
        case 2: self = .warn
        default: self = .normal
        }
    }
}

struct MemoryReading: Equatable {
    let total: UInt64       // physical RAM
    let used: UInt64        // app + wired + compressed, as Activity Monitor counts "Memory Used"
    let compressed: UInt64
    let swapUsed: UInt64
    let pressure: Pressure
}

struct DiskReading: Equatable {
    let total: UInt64
    let available: UInt64   // what Finder shows as available, purgeable space included
}

struct ProcessGroup: Equatable {
    let name: String
    let count: Int
    let footprint: UInt64
}

let gibibyte: Double = 1_073_741_824
let gigabyte: Double = 1_000_000_000
// Swap lives on the boot disk: below these the system starts to stall.
let diskWarnBelow: UInt64 = 50_000_000_000
let diskDangerBelow: UInt64 = 20_000_000_000
let alertCooldown: TimeInterval = 1_800

private func worse(_ a: Level, _ b: Level) -> Level {
    func rank(_ level: Level) -> Int { level == .danger ? 2 : level == .warn ? 1 : 0 }
    return rank(a) >= rank(b) ? a : b
}

/// The worse of the kernel's memory pressure and the swap size: swap of a quarter of RAM
/// is a warning, half of RAM is danger, whatever the pressure says at this moment.
func memoryLevel(_ memory: MemoryReading) -> Level {
    let byPressure: Level = memory.pressure == .critical ? .danger : memory.pressure == .warn ? .warn : .ok
    let swapShare = Double(memory.swapUsed) / Double(max(memory.total, 1))
    let bySwap: Level = swapShare >= 0.5 ? .danger : swapShare >= 0.25 ? .warn : .ok
    return worse(byPressure, bySwap)
}

func diskLevel(_ disk: DiskReading) -> Level {
    if disk.available < diskDangerBelow { return .danger }
    if disk.available < diskWarnBelow { return .warn }
    return .ok
}

private func usedRing(used: UInt64, total: UInt64, level: Level) -> RingState {
    guard total > 0 else { return .empty }
    let fraction = min(1, Double(used) / Double(total))
    return .normal(fraction: fraction, level: level, label: String(min(99, Int((fraction * 100).rounded()))))
}

func memoryRing(_ memory: MemoryReading?) -> RingState {
    guard let memory else { return .empty }
    return usedRing(used: memory.used, total: memory.total, level: memoryLevel(memory))
}

func diskRing(_ disk: DiskReading?) -> RingState {
    guard let disk else { return .empty }
    return usedRing(used: disk.total - min(disk.available, disk.total), total: disk.total, level: diskLevel(disk))
}

/// One alert per fall into danger, and none sooner than `alertCooldown` after the last one.
func shouldAlert(previous: Level?, current: Level, lastAlert: TimeInterval?, now: TimeInterval) -> Bool {
    guard current == .danger, previous != .danger else { return false }
    guard let lastAlert else { return true }
    return now - lastAlert >= alertCooldown
}

/// The app a process belongs to: the outermost `.app` in its path, so every Chrome or
/// Claude helper counts as its app. Claude Code sessions get their own name.
func appName(fromPath path: String) -> String {
    if path.contains("/claude-code/") || path.contains("/claude/versions/") { return "Claude Code" }
    let parts = path.split(separator: "/")
    if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
    return parts.last.map(String.init) ?? path
}

func groupProcesses(_ processes: [(path: String, footprint: UInt64)], limit: Int) -> [ProcessGroup] {
    var groups: [String: (count: Int, footprint: UInt64)] = [:]
    for process in processes {
        let name = appName(fromPath: process.path)
        let group = groups[name] ?? (0, 0)
        groups[name] = (group.count + 1, group.footprint + process.footprint)
    }
    return groups
        .map { ProcessGroup(name: $0.key, count: $0.value.count, footprint: $0.value.footprint) }
        .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.name < $1.name }
        .prefix(limit)
        .map { $0 }
}

struct SystemStrings {
    let memory, disk, pressure, compressed, swap, free, used, of, unit, top, activityMonitor, tooltip: String
    let normal, high, critical, memoryHint, diskHint, memoryAlert, diskAlert: String

    static func of(_ lang: Lang) -> SystemStrings {
        switch lang {
        case .ru:
            return SystemStrings(memory: "Память", disk: "Диск", pressure: "давление", compressed: "сжато",
                                 swap: "своп", free: "свободно", used: "занято", of: "из", unit: "ГБ",
                                 top: "Больше всего памяти", activityMonitor: "Открыть Мониторинг системы",
                                 tooltip: "Память и диск", normal: "норма", high: "высокое", critical: "критическое",
                                 memoryHint: "закройте лишние сессии и приложения",
                                 diskHint: "своп и обновления могут не поместиться",
                                 memoryAlert: "Память на исходе", diskAlert: "Диск почти заполнен")
        case .en:
            return SystemStrings(memory: "Memory", disk: "Disk", pressure: "pressure", compressed: "compressed",
                                 swap: "swap", free: "free", used: "used", of: "of", unit: "GB",
                                 top: "Top memory", activityMonitor: "Open Activity Monitor",
                                 tooltip: "Memory and disk", normal: "normal", high: "high", critical: "critical",
                                 memoryHint: "close the sessions and apps you do not need",
                                 diskHint: "swap and updates may not fit",
                                 memoryAlert: "Memory is running out", diskAlert: "Disk is almost full")
        }
    }
}

/// Gigabytes with one decimal below 100, whole above, a decimal comma in Russian.
func formatSize(_ bytes: UInt64, unit: Double, lang: Lang) -> String {
    let value = Double(bytes) / unit
    let text: String
    if value >= 100 || (value * 10).rounded() == value.rounded() * 10 {
        text = String(Int(value.rounded()))
    } else {
        text = String(format: "%.1f", value)
    }
    return lang == .ru ? text.replacingOccurrences(of: ".", with: ",") : text
}

func memoryLine(_ memory: MemoryReading?, lang: Lang) -> String {
    let text = SystemStrings.of(lang)
    guard let memory else { return "\(text.memory): \(Strings.of(lang).noData)" }
    let pressure = memory.pressure == .critical ? text.critical : memory.pressure == .warn ? text.high : text.normal
    let used = formatSize(memory.used, unit: gibibyte, lang: lang)
    let total = formatSize(memory.total, unit: gibibyte, lang: lang)
    return "\(text.memory): \(text.used) \(used) \(text.of) \(total) \(text.unit) · \(text.pressure): \(pressure)"
}

func memoryDetailLine(_ memory: MemoryReading, lang: Lang) -> String {
    let text = SystemStrings.of(lang)
    return "\(text.compressed) \(formatSize(memory.compressed, unit: gibibyte, lang: lang)) \(text.unit) · "
        + "\(text.swap) \(formatSize(memory.swapUsed, unit: gibibyte, lang: lang)) \(text.unit)"
}

func diskLine(_ disk: DiskReading?, lang: Lang) -> String {
    let text = SystemStrings.of(lang)
    guard let disk else { return "\(text.disk): \(Strings.of(lang).noData)" }
    let free = formatSize(disk.available, unit: gigabyte, lang: lang)
    let total = formatSize(disk.total, unit: gigabyte, lang: lang)
    return "\(text.disk): \(text.free) \(free) \(text.of) \(total) \(text.unit)"
}

func processLine(_ group: ProcessGroup, lang: Lang) -> String {
    let count = group.count > 1 ? " ×\(group.count)" : ""
    return "\(group.name)\(count) · \(formatSize(group.footprint, unit: gibibyte, lang: lang)) \(SystemStrings.of(lang).unit)"
}

private func levelName(_ level: Level) -> String {
    level == .danger ? "danger" : level == .warn ? "warn" : "ok"
}

/// `~/.claude/system.json` and `ClaudeLimits --system-json`, read by the desktop mod: raw bytes plus the levels
/// computed here, so the thresholds live in one place.
func systemJSON(memory: MemoryReading?, disk: DiskReading?, top: [ProcessGroup],
                updatedAt: TimeInterval? = nil) -> String {
    var object: [String: Any] = [:]
    if let updatedAt { object["updated_at"] = Int(updatedAt) }
    if let memory {
        object["memory"] = [
            "total": memory.total, "used": memory.used, "compressed": memory.compressed,
            "swap_used": memory.swapUsed, "level": levelName(memoryLevel(memory)),
            "pressure": memory.pressure == .critical ? "critical" : memory.pressure == .warn ? "warn" : "normal",
        ] as [String: Any]
    }
    if let disk {
        object["disk"] = ["total": disk.total, "available": disk.available,
                          "level": levelName(diskLevel(disk))] as [String: Any]
    }
    object["top"] = top.map { ["name": $0.name, "count": $0.count, "footprint": $0.footprint] as [String: Any] }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
