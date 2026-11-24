import Foundation
import IOKit

public struct HardwareThermalSnapshot: Sendable, Equatable {
    public let cpuTempC: Double?
    public let gpuTempC: Double?
    public let systemPowerWatts: Double?
    public let fanRPMs: [Double]
    public let maxFanRPM: Double?
    public let sampleDurationMs: Double

    public var peakFanRPM: Double? {
        fanRPMs.max()
    }

    public var fansActive: Bool {
        (peakFanRPM ?? 0) >= 100
    }

    public var fanSpeedPercent: Double? {
        guard let rpm = peakFanRPM, let maxRPM = maxFanRPM, maxRPM > 0 else { return nil }
        return min(100.0, max(0.0, (rpm / maxRPM) * 100.0))
    }

    public static let empty = HardwareThermalSnapshot(
        cpuTempC: nil,
        gpuTempC: nil,
        systemPowerWatts: nil,
        fanRPMs: [],
        maxFanRPM: nil,
        sampleDurationMs: 0
    )
}

/// Lean native AppleSMC reader using IOKit (`IOConnectCallStructMethod`).
/// Caches SMC key descriptors at init so each tick only performs direct `kSMCReadKey` calls (~1ms total).
/// Gracefully returns empty readings if SMC is unavailable or restricted.
public final class SMCSampler: @unchecked Sendable {
    private struct CachedKey {
        let key: String
        let fourCC: UInt32
        let dataSize: Int
        let dataSizeBytes: [UInt8]
        let dataType: String
    }

    private var connection: io_connect_t = 0
    private var isConnected = false
    private var fanCount: Int = 0
    private var maxFanRPM: Double?

    private var fanKeys: [CachedKey] = []
    private var cpuTempKeys: [CachedKey] = []
    private var gpuTempKeys: [CachedKey] = []
    private var powerKey: CachedKey?

    public init() {
        openConnection()
    }

    deinit {
        if isConnected && connection != 0 {
            IOServiceClose(connection)
        }
    }

    private func openConnection() {
        // Skip AppleSMC inside the Mac App Store sandbox to avoid sandbox denial logs
        guard !RuntimeEnvironment.isSandboxed else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else {
            return
        }
        self.connection = conn
        self.isConnected = true

        // Probe available keys once at startup so ticks are fast and never query non-existent keys
        if let fNumKey = resolveKey("FNum"), let val = readValue(fNumKey) {
            self.fanCount = min(4, max(0, Int(val)))
        }
        for i in 0..<fanCount {
            if let k = resolveKey("F\(i)Ac") {
                fanKeys.append(k)
            }
        }
        if let maxKey = resolveKey("F0Mx"), let maxVal = readValue(maxKey), maxVal > 0 {
            self.maxFanRPM = maxVal
        }

        // Apple Silicon & Intel CPU die temperature candidates (keep up to 3 valid ones)
        let cpuCandidates = ["Tp01", "Tp05", "Tp09", "Tp0T", "Tp0f", "TC0P", "TC0D"]
        for name in cpuCandidates {
            if let k = resolveKey(name), let v = readValue(k), v > 10 && v < 130 {
                cpuTempKeys.append(k)
                if cpuTempKeys.count >= 3 { break }
            }
        }

        // GPU die temperature candidates (keep up to 2 valid ones)
        let gpuCandidates = ["Tg05", "Tg0f", "Tg0D", "TG0P"]
        for name in gpuCandidates {
            if let k = resolveKey(name), let v = readValue(k), v > 10 && v < 130 {
                gpuTempKeys.append(k)
                if gpuTempKeys.count >= 2 { break }
            }
        }

        // Total system power draw in Watts
        for name in ["PSTR", "PDTR"] {
            if let k = resolveKey(name), let v = readValue(k), v >= 0 && v < 300 {
                powerKey = k
                break
            }
        }
    }

    public func sample() -> HardwareThermalSnapshot {
        guard isConnected else { return .empty }

        let t0 = CFAbsoluteTimeGetCurrent()

        var rpms: [Double] = []
        rpms.reserveCapacity(fanKeys.count)
        for k in fanKeys {
            if let rpm = readValue(k), rpm >= 0 && rpm < 15000 {
                rpms.append(rpm)
            }
        }

        var maxCpuTemp: Double? = nil
        for k in cpuTempKeys {
            if let t = readValue(k), t > 10 && t < 130 {
                maxCpuTemp = max(maxCpuTemp ?? t, t)
            }
        }

        var maxGpuTemp: Double? = nil
        for k in gpuTempKeys {
            if let t = readValue(k), t > 10 && t < 130 {
                maxGpuTemp = max(maxGpuTemp ?? t, t)
            }
        }

        var watts: Double? = nil
        if let pk = powerKey, let w = readValue(pk), w >= 0 && w < 300 {
            watts = w
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        return HardwareThermalSnapshot(
            cpuTempC: maxCpuTemp,
            gpuTempC: maxGpuTemp,
            systemPowerWatts: watts,
            fanRPMs: rpms,
            maxFanRPM: maxFanRPM,
            sampleDurationMs: elapsedMs
        )
    }

    // MARK: - Low-level 80-byte SMC Protocol

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    private func resolveKey(_ key: String) -> CachedKey? {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        var k = fourCC(key)
        withUnsafeBytes(of: &k) { input.replaceSubrange(0..<4, with: $0) }
        input[42] = 9 // kSMCGetKeyInfo

        var outSize = 80
        let kr = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outSize)
        guard kr == KERN_SUCCESS, output[40] == 0 else { return nil }

        let dataSize = Int(output.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) })
        let dataType = output.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
        guard dataSize > 0, dataSize <= 32 else { return nil }

        let typeStr = String(
            bytes: [
                UInt8((dataType >> 24) & 0xff),
                UInt8((dataType >> 16) & 0xff),
                UInt8((dataType >> 8) & 0xff),
                UInt8(dataType & 0xff)
            ],
            encoding: .ascii
        ) ?? "????"

        return CachedKey(
            key: key,
            fourCC: k,
            dataSize: dataSize,
            dataSizeBytes: Array(output[28..<32]),
            dataType: typeStr
        )
    }

    private func readValue(_ cached: CachedKey) -> Double? {
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        var k = cached.fourCC
        withUnsafeBytes(of: &k) { input.replaceSubrange(0..<4, with: $0) }
        input.replaceSubrange(28..<32, with: cached.dataSizeBytes)
        input[42] = 5 // kSMCReadKey

        var outSize = 80
        let kr = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outSize)
        guard kr == KERN_SUCCESS, output[40] == 0 else { return nil }

        let bytes = Array(output[48..<(48 + cached.dataSize)])
        switch cached.dataType {
        case "flt " where bytes.count == 4:
            let f = bytes.withUnsafeBytes { $0.load(as: Float.self) }
            return f.isFinite ? Double(f) : nil
        case "fpe2" where bytes.count == 2:
            let v = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(v) / 4.0
        case "sp78" where bytes.count == 2:
            let v = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(v) / 256.0
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        default:
            return nil
        }
    }
}
