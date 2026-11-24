import Foundation

public enum ThermalLevel: Int, Comparable, Sendable, Equatable {
    case cool = 0       // .nominal
    case warm = 1       // .fair
    case hot = 2        // .serious
    case critical = 3   // .critical

    public init(state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .cool
        case .fair: self = .warm
        case .serious: self = .hot
        case .critical: self = .critical
        @unknown default: self = .cool
        }
    }

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .cool: return "Cool"
        case .warm: return "Warm"
        case .hot: return "Hot"
        case .critical: return "Critical"
        }
    }

    public var symbolName: String {
        switch self {
        case .cool: return "thermometer.low"
        case .warm: return "thermometer.medium"
        case .hot: return "thermometer.high"
        case .critical: return "flame.fill"
        }
    }
}

public enum HeatWindow: String, CaseIterable, Sendable {
    case oneMinute = "1m Heat"
    case fiveMinutes = "5m Heat"
    case events = "Heat Log"

    public var durationSeconds: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .events: return 60
        }
    }
}

public struct SelfTelemetry: Sendable, Equatable {
    public let selfCPUPercent: Double
    public let cpuTickMs: Double
    public let gpuTickMs: Double
    public let smcTickMs: Double
    public let procTickMs: Double

    public var totalTickMs: Double {
        cpuTickMs + gpuTickMs + smcTickMs + procTickMs
    }

    public static let zero = SelfTelemetry(
        selfCPUPercent: 0,
        cpuTickMs: 0,
        gpuTickMs: 0,
        smcTickMs: 0,
        procTickMs: 0
    )
}

public struct SystemCPUSnapshot: Sendable, Equatable {
    public let user: Double      // 0...100
    public let system: Double    // 0...100
    public let idle: Double      // 0...100
    public let coreCount: Int
    public let timestamp: Date

    public var total: Double {
        min(100.0, max(0.0, user + system))
    }

    public static let zero = SystemCPUSnapshot(
        user: 0,
        system: 0,
        idle: 100,
        coreCount: ProcessInfo.processInfo.activeProcessorCount,
        timestamp: Date()
    )
}

public enum ProcessRunState: String, Sendable, Equatable {
    case running = "Running"
    case sleeping = "Idle"
    case stopped = "Paused"
    case zombie = "Zombie"
    case exited = "Exited"
    case unknown = "Unknown"

    init(bsdStatus: UInt32) {
        switch bsdStatus {
        case 1: self = .unknown   // SIDL
        case 2: self = .running   // SRUN
        case 3: self = .sleeping  // SSLEEP
        case 4: self = .stopped   // SSTOP
        case 5: self = .zombie    // SZOMB
        default: self = .unknown
        }
    }
}

public struct ProcessEntry: Identifiable, Sendable, Equatable {
    public var id: pid_t { pid }

    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    public let name: String
    public let rawName: String
    public let executablePath: String?
    public let bundlePath: String?
    public let bundleIdentifier: String?
    public let parentName: String?
    public let cpuPercent: Double
    public let peakCPUPercent: Double
    public let cpuHistory: [Double]
    public let memoryBytes: UInt64
    public let threadCount: Int
    public let state: ProcessRunState
    public let isSystemProcess: Bool
    public let highCPUSince: Date?
    public let startTime: Date?
    public let niceValue: Int32
    public let totalCPUTimeSeconds: Double

    // Rolling multi-source heat accounting (CPU-sec, GPU-sec, Disk I/O bytes)
    public let heat1mSeconds: Double
    public let heat5mSeconds: Double
    public let gpuHeat1mSeconds: Double
    public let gpuHeat5mSeconds: Double
    public let diskIO1mBytes: UInt64
    public let diskIO5mBytes: UInt64
    public let exitedAt: Date?

    public var isPaused: Bool {
        state == .stopped
    }

    public var isExited: Bool {
        state == .exited || exitedAt != nil
    }

    public func cpuHeatSeconds(for window: HeatWindow) -> Double {
        window == .fiveMinutes ? heat5mSeconds : heat1mSeconds
    }

    public func gpuHeatSeconds(for window: HeatWindow) -> Double {
        window == .fiveMinutes ? gpuHeat5mSeconds : gpuHeat1mSeconds
    }

    public func diskIOBytes(for window: HeatWindow) -> UInt64 {
        window == .fiveMinutes ? diskIO5mBytes : diskIO1mBytes
    }

    /// Unified heat score combining CPU-seconds + weighted GPU-seconds (1.5x) + Disk I/O energy.
    public func heatScore(for window: HeatWindow) -> Double {
        let cpu = cpuHeatSeconds(for: window)
        let gpu = gpuHeatSeconds(for: window)
        let disk = Double(diskIOBytes(for: window)) / 200_000_000.0
        return cpu + (gpu * 1.5) + disk
    }

    public func heatSeconds(for window: HeatWindow) -> Double {
        heatScore(for: window)
    }

    public var sustainedHighDuration: TimeInterval? {
        guard let since = highCPUSince, !isExited else { return nil }
        let elapsed = Date().timeIntervalSince(since)
        return elapsed >= 5 ? elapsed : nil
    }

    public func normalizedCPUPercent(coreCount: Int) -> Double {
        guard coreCount > 0 else { return cpuPercent }
        return cpuPercent / Double(coreCount)
    }

    public var severity: CPUSeverity {
        let score = heatScore(for: .oneMinute)
        if score >= 45 || cpuPercent >= 80 { return .critical }
        if score >= 18 || cpuPercent >= 35 { return .elevated }
        if score >= 5 || cpuPercent >= 12 { return .moderate }
        return .calm
    }
}

public enum HeatSourceTag: String, Sendable, Equatable {
    case cpu = "CPU"
    case gpu = "GPU"
    case disk = "DISK"
}

/// A logical app or process-family group rolling up helpers & short-lived children.
public struct HeatGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let representative: ProcessEntry
    public let members: [ProcessEntry]
    public let heatSeconds: Double       // Unified heat score (CPU + 1.5*GPU + Disk)
    public let cpuHeatSeconds: Double
    public let gpuHeatSeconds: Double
    public let diskIOBytes: UInt64
    public let heatSharePercent: Double
    public let liveCPUPercent: Double
    public let totalMemoryBytes: UInt64
    public let isSystemGroup: Bool
    public let activeCount: Int
    public let exitedCount: Int

    public var dominantSource: HeatSourceTag {
        let gpuWeighted = gpuHeatSeconds * 1.5
        let diskWeighted = Double(diskIOBytes) / 200_000_000.0
        if gpuWeighted > cpuHeatSeconds && gpuWeighted >= 0.5 {
            return .gpu
        }
        if diskWeighted > cpuHeatSeconds && diskWeighted >= 0.5 {
            return .disk
        }
        return .cpu
    }

    public var severity: CPUSeverity {
        if heatSharePercent >= 35 || heatSeconds >= 45 { return .critical }
        if heatSharePercent >= 18 || heatSeconds >= 18 { return .elevated }
        if heatSharePercent >= 7 || heatSeconds >= 5 { return .moderate }
        return .calm
    }
}

public struct ThermalCulpritSnapshot: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let pid: pid_t
    public let heatSeconds: Double
    public let sharePercent: Double
    public let dominantSource: HeatSourceTag
    public let executablePath: String?
}

/// Recorded automatically whenever fans spin up, die temp climbs, macOS thermal state escalates, or sustained load occurs.
public struct ThermalEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public var endedAt: Date?
    public var peakThermalLevel: ThermalLevel
    public var peakSystemCPU: Double
    public var peakGPU: Double
    public var peakTempC: Double?
    public var peakFanRPM: Double?
    public var peakWatts: Double?
    public var reason: String
    public var culprits: [ThermalCulpritSnapshot]

    public var isOngoing: Bool {
        endedAt == nil
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

public enum CPUSeverity: Sendable, Equatable {
    case calm
    case moderate
    case elevated
    case critical
}

public struct ProcessAncestor: Identifiable, Sendable, Equatable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let executablePath: String?
}

public enum LaunchOrigin: Sendable, Equatable {
    case application(name: String, bundlePath: String)
    case launchAgent(label: String, plistPath: String)
    case launchDaemon(label: String, plistPath: String)
    case terminal(shell: String, workingDir: String?)
    case parentProcess(name: String)
    case systemDaemon
    case unknown

    public var title: String {
        switch self {
        case .application(let name, _): return "App Bundle (\(name))"
        case .launchAgent(let label, _): return "LaunchAgent (\(label))"
        case .launchDaemon(let label, _): return "LaunchDaemon (\(label))"
        case .terminal(let shell, _): return "Terminal / \(shell)"
        case .parentProcess(let name): return "Spawned by \(name)"
        case .systemDaemon: return "macOS System Service"
        case .unknown: return "Unknown Origin"
        }
    }

    public var iconName: String {
        switch self {
        case .application: return "app.badge"
        case .launchAgent, .launchDaemon: return "gearshape.2"
        case .terminal: return "terminal"
        case .parentProcess: return "arrow.branch"
        case .systemDaemon: return "cpu"
        case .unknown: return "questionmark.circle"
        }
    }
}

public struct ProcessInspection: Sendable, Equatable {
    public let pid: pid_t
    public let executablePath: String?
    public let workingDirectory: String?
    public let commandLine: [String]
    public let parentChain: [ProcessAncestor]
    public let username: String
    public let launchOrigin: LaunchOrigin
    public let openFileCount: Int
    public let listeningPorts: [String]
    public let idleWakeups: UInt64
    public let physicalFootprintBytes: UInt64
    public let inspectedAt: Date

    public var formattedCommand: String {
        if commandLine.isEmpty {
            return executablePath ?? "Unavailable (insufficient permissions)"
        }
        return commandLine.map { arg in
            if arg.contains(" ") || arg.contains("\"") {
                return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return arg
        }.joined(separator: " ")
    }
}

public enum ProcessActionError: LocalizedError, Sendable {
    case permissionDenied(String)
    case processNotFound
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied(let msg): return msg
        case .processNotFound: return "Process already exited."
        case .failed(let msg): return msg
        }
    }
}
