import Darwin
import Foundation
import IOKit

/// One sample of system usage, each value 0...1 (nil = unavailable).
struct SystemStats: Equatable {
    var cpu: Double?
    var gpu: Double?
    var ram: Double?
    var ssd: Double?
}

/// Polls CPU/GPU/RAM/SSD usage for the compact notch, using the same system
/// APIs and formulas as the open-source Stats app (github.com/exelban/stats).
@MainActor
final class SystemStatsModel: ObservableObject {
    @Published private(set) var stats = SystemStats()

    private var poller: Task<Void, Never>?

    func start() {
        guard poller == nil else { return }
        poller = Task.detached(priority: .utility) { [weak self] in
            // CPU usage is a delta between samples; the first tick reports the
            // since-boot average, which settles on the next one.
            var previousTicks = host_cpu_load_info()
            while !Task.isCancelled {
                var cpu: Double?
                if let ticks = SystemStatsReader.cpuTicks() {
                    cpu = SystemStatsReader.cpuUsage(from: previousTicks, to: ticks)
                    previousTicks = ticks
                }
                let snapshot = SystemStats(
                    cpu: cpu,
                    gpu: SystemStatsReader.gpuUsage(),
                    ram: SystemStatsReader.ramUsage(),
                    ssd: SystemStatsReader.ssdUsage()
                )
                guard let self else { return }
                await MainActor.run { self.stats = snapshot }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit {
        poller?.cancel()
    }
}

enum SystemStatsReader {
    static func cpuTicks() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// (user + system) / total ticks elapsed between the two samples.
    static func cpuUsage(from previous: host_cpu_load_info, to current: host_cpu_load_info) -> Double? {
        let user = Double(current.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(current.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(current.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(current.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system) / total
    }

    /// Memory pressure formula from Stats: app + wired + compressed, minus
    /// purgeable and file-backed pages.
    static func ramUsage() -> Double? {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_page_size)
        let used = (Double(vm.active_count) + Double(vm.inactive_count)
            + Double(vm.speculative_count) + Double(vm.wire_count)
            + Double(vm.compressor_page_count) - Double(vm.purgeable_count)
            - Double(vm.external_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    /// "Device Utilization %" from the IOAccelerator registry entry (the GPU on
    /// Apple Silicon); highest one wins on multi-GPU Macs.
    static func gpuUsage() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any]
            else { continue }
            let value = (perf["Device Utilization %"] as? Int) ?? (perf["GPU Activity(%)"] as? Int)
            if let value {
                best = max(best ?? 0, Double(value) / 100)
            }
        }
        return best
    }

    /// Used fraction of the boot volume; free space counts purgeable data as
    /// available, matching Finder.
    static func ssdUsage() -> Double? {
        let root = URL(fileURLWithPath: "/")
        var fs = statfs()
        guard statfs(root.path, &fs) == 0 else { return nil }
        let total = Double(fs.f_blocks) * Double(fs.f_bsize)
        guard total > 0 else { return nil }
        var free = Double(fs.f_bfree) * Double(fs.f_bsize)
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            free = Double(important)
        }
        return min(max((total - free) / total, 0), 1)
    }
}
