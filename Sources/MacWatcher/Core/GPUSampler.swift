import Foundation
import IOKit

public struct GPUSnapshot: Sendable, Equatable {
    public let deviceUtilizationPercent: Double
    public let rendererUtilizationPercent: Double
    public let tilerUtilizationPercent: Double
    /// Per-PID GPU seconds burned since the previous scan (populated only when per-process scan ran).
    public let processGPUDeltaSeconds: [pid_t: Double]
    public let sampleDurationMs: Double

    public static let zero = GPUSnapshot(
        deviceUtilizationPercent: 0,
        rendererUtilizationPercent: 0,
        tilerUtilizationPercent: 0,
        processGPUDeltaSeconds: [:],
        sampleDurationMs: 0
    )
}

/// Lean native IOKit GPU sampler (`IOAccelerator`).
/// - System-wide GPU% takes ~0.2ms.
/// - Per-process GPU time (`AppUsage` -> `accumulatedGPUTime`) is only scanned when `scanPerProcess` is true
///   or when system GPU utilization exceeds 5%, keeping idle overhead near zero.
public final class GPUSampler: @unchecked Sendable {
    private var previousGPUTimeNs: [pid_t: UInt64] = [:]

    public init() {}

    public func sample(scanPerProcess: Bool) -> GPUSnapshot {
        let t0 = CFAbsoluteTimeGetCurrent()

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return .zero
        }
        defer { IOObjectRelease(iter) }

        var deviceUtil: Double = 0
        var rendererUtil: Double = 0
        var tilerUtil: Double = 0
        var currentTotalsNs: [pid_t: UInt64] = [:]
        var scannedClients = false

        var svc = IOIteratorNext(iter)
        while svc != 0 {
            defer { IOObjectRelease(svc) }

            if let stats = IORegistryEntryCreateCFProperty(
                svc,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                if let d = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                    deviceUtil = max(deviceUtil, d)
                }
                if let r = (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue {
                    rendererUtil = max(rendererUtil, r)
                }
                if let t = (stats["Tiler Utilization %"] as? NSNumber)?.doubleValue {
                    tilerUtil = max(tilerUtil, t)
                }
            }

            // Only walk child clients if requested or GPU is actually doing work (> 5%)
            if scanPerProcess || deviceUtil >= 5.0 {
                scannedClients = true
                var childIter: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(svc, kIOServicePlane, &childIter) == KERN_SUCCESS {
                    defer { IOObjectRelease(childIter) }
                    var child = IOIteratorNext(childIter)
                    while child != 0 {
                        defer { IOObjectRelease(child) }
                        if let usage = IORegistryEntryCreateCFProperty(
                            child,
                            "AppUsage" as CFString,
                            kCFAllocatorDefault,
                            0
                        )?.takeRetainedValue() as? [[String: Any]], !usage.isEmpty {
                            let creator = IORegistryEntryCreateCFProperty(
                                child,
                                "IOUserClientCreator" as CFString,
                                kCFAllocatorDefault,
                                0
                            )?.takeRetainedValue() as? String

                            if let pid = parsePID(from: creator) {
                                var gpuNs: UInt64 = 0
                                for item in usage {
                                    if let t = (item["accumulatedGPUTime"] as? NSNumber)?.uint64Value {
                                        gpuNs &+= t
                                    }
                                }
                                if gpuNs > 0 {
                                    currentTotalsNs[pid, default: 0] &+= gpuNs
                                }
                            }
                        }
                        child = IOIteratorNext(childIter)
                    }
                }
            }

            svc = IOIteratorNext(iter)
        }

        var deltas: [pid_t: Double] = [:]
        if scannedClients {
            for (pid, totalNs) in currentTotalsNs {
                if let prevNs = previousGPUTimeNs[pid], totalNs > prevNs {
                    let deltaSec = Double(totalNs - prevNs) / 1_000_000_000.0
                    if deltaSec >= 0.002 {
                        deltas[pid] = deltaSec
                    }
                }
            }
            previousGPUTimeNs = currentTotalsNs
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        return GPUSnapshot(
            deviceUtilizationPercent: deviceUtil,
            rendererUtilizationPercent: rendererUtil,
            tilerUtilizationPercent: tilerUtil,
            processGPUDeltaSeconds: deltas,
            sampleDurationMs: elapsedMs
        )
    }

    /// Parses `"pid 400, WindowServer"` -> `400`.
    private func parsePID(from creator: String?) -> pid_t? {
        guard let creator, creator.hasPrefix("pid ") else { return nil }
        let rest = creator.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        guard let val = Int32(digits), val > 0 else { return nil }
        return pid_t(val)
    }
}
