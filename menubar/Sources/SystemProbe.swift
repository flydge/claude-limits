import Darwin
import Foundation
import IOKit

// Reads CPU, GPU, memory, swap, disk and per-process memory from the kernel and IOKit, and the
// gpu-run queue files. Local calls only, nothing needs root: processes of other users are skipped.

enum SystemProbe {
    static func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = (app + UInt64(stats.wire_count)) * page + compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? swap.xsu_used : 0

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) != 0 { level = 1 }

        let total = ProcessInfo.processInfo.physicalMemory
        var freePercent: Int32 = -1
        var freeSize = MemoryLayout<Int32>.size
        let available: UInt64? = sysctlbyname("kern.memorystatus_level", &freePercent, &freeSize, nil, 0) == 0
            && (0...100).contains(freePercent) ? total / 100 * UInt64(freePercent) : nil

        return MemoryReading(total: total, used: used, compressed: compressed,
                             swapUsed: swapUsed, pressure: Pressure(sysctlLevel: level), available: available)
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// The busiest IOAccelerator (Apple silicon has one).
    static func gpu() -> GPUReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
            == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: GPUReading?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue()
                    as? [String: Any],
                  let utilization = (stats["Device Utilization %"] as? NSNumber)?.intValue else { continue }
            let number = { (key: String) in (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            let reading = GPUReading(utilization: utilization, inUse: number("In use system memory"),
                                     allocated: number("Alloc system memory"))
            if best == nil || reading.utilization > best!.utilization { best = reading }
        }
        return best
    }

    /// Live entries of ~/.gpu-queue/jobs and /wait; nil when the queue was never set up.
    static func queue(home: String = NSHomeDirectory()) -> QueueReading? {
        let root = "\(home)/.gpu-queue"
        guard FileManager.default.fileExists(atPath: "\(root)/jobs") else { return nil }
        func live(_ dir: String) -> [Double] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? []
            return names.compactMap { name in
                guard let data = FileManager.default.contents(atPath: "\(root)/\(dir)/\(name)"),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
                      kill(pid, 0) == 0 || errno == EPERM else { return nil }
                return (object["gb"] as? NSNumber)?.doubleValue ?? 0
            }
        }
        let running = live("jobs"), waiting = live("wait")
        let budgetText = (try? String(contentsOfFile: "\(root)/budget_gb", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return QueueReading(running: running.count, waiting: waiting.count, runningGB: running.reduce(0, +),
                            budgetGB: budgetText.flatMap(Double.init) ?? 30)
    }

    static func disk(path: String = "/") -> DiskReading? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
            ?? UInt64(max(0, values.volumeAvailableCapacity ?? 0))
        return DiskReading(total: UInt64(total), available: available)
    }

    /// Path and memory footprint (what Activity Monitor's Memory column shows) of each process.
    static func processes() -> [(path: String, footprint: UInt64)] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard found > 0 else { return [] }

        var result: [(path: String, footprint: UInt64)] = []
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(found) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0, info.ri_phys_footprint > 0 else { continue }
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            result.append((String(cString: pathBuffer), info.ri_phys_footprint))
        }
        return result
    }
}
