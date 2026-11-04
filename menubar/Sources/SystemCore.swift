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
    /// macOS's own estimate of what is free for new work (`kern.memorystatus_level` × RAM), the figure
    /// `memory_pressure` and gpu-run use. One pool: CPU and GPU share it.
    var available: UInt64? = nil
}

/// Cumulative CPU ticks of all cores; the load is the busy share between two samples.
struct CPUTicks: Equatable {
    let busy: UInt64
    let total: UInt64
}

/// What the GPU does now, from IOAccelerator's PerformanceStatistics (no root needed).
struct GPUReading: Equatable {
    let utilization: Int    // "Device Utilization %"
    let inUse: UInt64       // "In use system memory": unified memory the GPU holds now
    let allocated: UInt64   // "Alloc system memory": what its driver has allocated
}

/// Jobs in the shared GPU memory queue (~/.gpu-queue, see `gpu-run status`).
struct QueueReading: Equatable {
    let running: Int
    let waiting: Int
    let runningGB: Double
    let budgetGB: Double
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

func cpuPercent(previous: CPUTicks?, current: CPUTicks) -> Double? {
    guard let previous, current.total > previous.total, current.busy >= previous.busy else { return nil }
    return min(100, Double(current.busy - previous.busy) / Double(current.total - previous.total) * 100)
}

/// CPU and GPU load: orange from 60 %, red from 85 %. Colour only, no alert: a model at full load is normal.
func loadLevel(_ percent: Double) -> Level {
    percent >= 85 ? .danger : percent >= 60 ? .warn : .ok
}

func loadRing(_ percent: Double?) -> RingState {
    guard let percent else { return .empty }
    let p = min(100, max(0, percent))
    return .normal(fraction: p / 100, level: loadLevel(p), label: String(min(99, Int(p.rounded()))))
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

/// The share macOS counts as taken (RAM minus its own available estimate, the figure gpu-run admits jobs by);
/// Activity Monitor's "Memory Used" when that estimate is missing.
func memoryRing(_ memory: MemoryReading?) -> RingState {
    guard let memory else { return .empty }
    let used = memory.available.map { memory.total - min($0, memory.total) } ?? memory.used
    return usedRing(used: used, total: memory.total, level: memoryLevel(memory))
}

func diskRing(_ disk: DiskReading?) -> RingState {
    guard let disk else { return .empty }
    return usedRing(used: disk.total - min(disk.available, disk.total), total: disk.total, level: diskLevel(disk))
}

/// The rings the system item can show in the menu bar, in their order there.
enum SystemRing: String, CaseIterable {
    case cpu, gpu, memory, disk
}

/// The rings chosen in the menu, kept in UserDefaults as their raw names; all four when nothing was chosen yet.
/// Unknown names are dropped, and an empty choice falls back to all, so the item never vanishes.
func shownRings(stored: [String]?) -> [SystemRing] {
    guard let stored else { return SystemRing.allCases }
    let chosen = SystemRing.allCases.filter { stored.contains($0.rawValue) }
    return chosen.isEmpty ? SystemRing.allCases : chosen
}

/// The choice after the person picks `ring` in the menu: on becomes off and back; the last ring stays on.
func toggled(_ ring: SystemRing, in shown: [SystemRing]) -> [SystemRing] {
    if shown.contains(ring) { return shown.count > 1 ? shown.filter { $0 != ring } : shown }
    return SystemRing.allCases.filter { $0 == ring || shown.contains($0) }
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
    let showInMenuBar: String
    let memory, disk, pressure, compressed, swap, free, used, of, unit, top, activityMonitor, tooltip: String
    let normal, high, critical, memoryHint, diskHint, memoryAlert, diskAlert: String
    let available, usedByMonitor, gpuHolds, gpuAllocated, queue, running, waiting: String

    static func of(_ lang: Lang) -> SystemStrings {
        switch lang {
        case .ru:
            return SystemStrings(showInMenuBar: "Показывать в строке меню", memory: "Память", disk: "Диск", pressure: "давление", compressed: "сжато",
                                 swap: "своп", free: "свободно", used: "занято", of: "из", unit: "ГБ",
                                 top: "Больше всего памяти", activityMonitor: "Открыть Мониторинг системы",
                                 tooltip: "Память и диск", normal: "норма", high: "высокое", critical: "критическое",
                                 memoryHint: "закройте лишние сессии и приложения",
                                 diskHint: "своп и обновления могут не поместиться",
                                 memoryAlert: "Память на исходе", diskAlert: "Диск почти заполнен",
                                 available: "доступно", usedByMonitor: "в Мониторинге занято", gpuHolds: "держит", gpuAllocated: "выделено",
                                 queue: "Очередь GPU", running: "идут", waiting: "ждут")
        case .en:
            return SystemStrings(showInMenuBar: "Show in the menu bar", memory: "Memory", disk: "Disk", pressure: "pressure", compressed: "compressed",
                                 swap: "swap", free: "free", used: "used", of: "of", unit: "GB",
                                 top: "Top memory", activityMonitor: "Open Activity Monitor",
                                 tooltip: "Memory and disk", normal: "normal", high: "high", critical: "critical",
                                 memoryHint: "close the sessions and apps you do not need",
                                 diskHint: "swap and updates may not fit",
                                 memoryAlert: "Memory is running out", diskAlert: "Disk is almost full",
                                 available: "available", usedByMonitor: "Activity Monitor used", gpuHolds: "holds", gpuAllocated: "allocated",
                                 queue: "GPU queue", running: "running", waiting: "waiting")
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
    if let available = memory.available {
        let free = formatSize(available, unit: gibibyte, lang: lang)
        return "\(text.memory): \(text.available) \(free) \(text.of) \(total) \(text.unit) · \(text.pressure): \(pressure)"
    }
    return "\(text.memory): \(text.used) \(used) \(text.of) \(total) \(text.unit) · \(text.pressure): \(pressure)"
}

func cpuLine(_ percent: Double?, lang: Lang) -> String {
    guard let percent else { return "CPU: \(Strings.of(lang).noData)" }
    return "CPU: \(Int(percent.rounded()))%"
}

func gpuLine(_ gpu: GPUReading?, lang: Lang) -> String {
    let text = SystemStrings.of(lang)
    guard let gpu else { return "GPU: \(Strings.of(lang).noData)" }
    return "GPU: \(gpu.utilization)% · \(text.gpuHolds) \(formatSize(gpu.inUse, unit: gibibyte, lang: lang)) \(text.unit)"
        + " · \(text.gpuAllocated) \(formatSize(gpu.allocated, unit: gibibyte, lang: lang)) \(text.unit)"
}

/// Nil when the queue is empty: nothing to show.
func queueLine(_ queue: QueueReading?, lang: Lang) -> String? {
    guard let queue, queue.running + queue.waiting > 0 else { return nil }
    let text = SystemStrings.of(lang)
    let gb = { (v: Double) in formatSize(UInt64(v * gibibyte), unit: gibibyte, lang: lang) }
    return "\(text.queue): \(text.running) \(queue.running) (\(gb(queue.runningGB)) \(text.of) \(gb(queue.budgetGB)) \(text.unit))"
        + " · \(text.waiting) \(queue.waiting)"
}

func memoryDetailLine(_ memory: MemoryReading, lang: Lang) -> String {
    let text = SystemStrings.of(lang)
    let used = memory.available == nil ? "" : "\(text.usedByMonitor) \(formatSize(memory.used, unit: gibibyte, lang: lang)) \(text.unit) · "
    return used + "\(text.compressed) \(formatSize(memory.compressed, unit: gibibyte, lang: lang)) \(text.unit) · "
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
                cpu: Double? = nil, gpu: GPUReading? = nil, queue: QueueReading? = nil,
                updatedAt: TimeInterval? = nil) -> String {
    var object: [String: Any] = [:]
    if let updatedAt { object["updated_at"] = Int(updatedAt) }
    if let cpu { object["cpu"] = ["percent": Int(cpu.rounded()), "level": levelName(loadLevel(cpu))] as [String: Any] }
    if let gpu {
        object["gpu"] = ["utilization": gpu.utilization, "in_use": gpu.inUse, "allocated": gpu.allocated,
                         "level": levelName(loadLevel(Double(gpu.utilization)))] as [String: Any]
    }
    if let queue {
        object["queue"] = ["running": queue.running, "waiting": queue.waiting,
                           "running_gb": queue.runningGB, "budget_gb": queue.budgetGB] as [String: Any]
    }
    if let memory {
        var fields: [String: Any] = [
            "total": memory.total, "used": memory.used, "compressed": memory.compressed,
            "swap_used": memory.swapUsed, "level": levelName(memoryLevel(memory)),
            "pressure": memory.pressure == .critical ? "critical" : memory.pressure == .warn ? "warn" : "normal",
        ]
        if let available = memory.available { fields["available"] = available }
        object["memory"] = fields
    }
    if let disk {
        object["disk"] = ["total": disk.total, "available": disk.available,
                          "level": levelName(diskLevel(disk))] as [String: Any]
    }
    object["top"] = top.map { ["name": $0.name, "count": $0.count, "footprint": $0.footprint] as [String: Any] }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

func ringName(_ ring: SystemRing, lang: Lang) -> String {
    let text = SystemStrings.of(lang)
    switch ring {
    case .cpu: return "CPU"
    case .gpu: return "GPU"
    case .memory: return text.memory
    case .disk: return text.disk
    }
}
