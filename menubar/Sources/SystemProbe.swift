import Darwin
import Foundation

// Reads memory, swap, disk and per-process memory from the kernel. Local calls only,
// nothing needs root: processes of other users are skipped.

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

        return MemoryReading(total: ProcessInfo.processInfo.physicalMemory, used: used, compressed: compressed,
                             swapUsed: swapUsed, pressure: Pressure(sysctlLevel: level))
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
