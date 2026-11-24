import Darwin
import Foundation

/// Ultra-lightweight system-wide CPU sampler backed by `host_statistics(HOST_CPU_LOAD_INFO)`.
/// Takes microseconds per call with zero allocations or subprocesses.
public final class SystemCPUSampler: @unchecked Sendable {
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    public let coreCount: Int

    public init() {
        self.coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    public func sample() -> SystemCPUSnapshot {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var cpuInfo = host_cpu_load_info_data_t()

        let result: kern_return_t = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return SystemCPUSnapshot(
                user: 0,
                system: 0,
                idle: 100,
                coreCount: coreCount,
                timestamp: Date()
            )
        }

        let user = UInt64(cpuInfo.cpu_ticks.0)
        let system = UInt64(cpuInfo.cpu_ticks.1)
        let idle = UInt64(cpuInfo.cpu_ticks.2)
        let nice = UInt64(cpuInfo.cpu_ticks.3)

        defer {
            previousTicks = (user, system, idle, nice)
        }

        guard let prev = previousTicks else {
            return SystemCPUSnapshot(
                user: 0,
                system: 0,
                idle: 100,
                coreCount: coreCount,
                timestamp: Date()
            )
        }

        let dUser = user >= prev.user ? user - prev.user : 0
        let dSystem = system >= prev.system ? system - prev.system : 0
        let dIdle = idle >= prev.idle ? idle - prev.idle : 0
        let dNice = nice >= prev.nice ? nice - prev.nice : 0

        let totalTicks = Double(dUser + dSystem + dIdle + dNice)
        guard totalTicks > 0 else {
            return SystemCPUSnapshot(
                user: 0,
                system: 0,
                idle: 100,
                coreCount: coreCount,
                timestamp: Date()
            )
        }

        let userPct = (Double(dUser + dNice) / totalTicks) * 100.0
        let sysPct = (Double(dSystem) / totalTicks) * 100.0
        let idlePct = (Double(dIdle) / totalTicks) * 100.0

        return SystemCPUSnapshot(
            user: userPct,
            system: sysPct,
            idle: idlePct,
            coreCount: coreCount,
            timestamp: Date()
        )
    }
}
