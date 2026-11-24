import Foundation
import IOKit

public struct GPUSnapshot: Sendable, Equatable {
    public let deviceUtilizationPercent: Double
    public let rendererUtilizationPercent: Double
    public let tilerUtilizationPercent: Double
    public let sampleDurationMs: Double

    public static let zero = GPUSnapshot(
        deviceUtilizationPercent: 0,
        rendererUtilizationPercent: 0,
        tilerUtilizationPercent: 0,
        sampleDurationMs: 0
    )
}

/// Ultra-lean native IOKit GPU sampler (`IOAccelerator` -> `PerformanceStatistics`).
/// Takes ~0.2ms per call and skips empty per-client registry walks.
public final class GPUSampler: @unchecked Sendable {
    public init() {}

    public func sample() -> GPUSnapshot {
        let t0 = CFAbsoluteTimeGetCurrent()

        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return .zero
        }
        defer { IOObjectRelease(iter) }

        var deviceUtil: Double = 0
        var rendererUtil: Double = 0
        var tilerUtil: Double = 0

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

            svc = IOIteratorNext(iter)
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        return GPUSnapshot(
            deviceUtilizationPercent: deviceUtil,
            rendererUtilizationPercent: rendererUtil,
            tilerUtilizationPercent: tilerUtil,
            sampleDurationMs: elapsedMs
        )
    }
}
