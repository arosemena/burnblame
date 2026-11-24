import Darwin
import Foundation

/// Lightweight native process sampler using `libproc` (`proc_listallpids` + `proc_pidinfo`).
/// Avoids spawning `ps` or `top`, caches static process metadata by `(pid, startTime)`,
/// and computes accurate CPU% deltas using `mach_timebase_info`.
public final class ProcessSampler: @unchecked Sendable {
    private struct PreviousSample {
        let startTimeSec: UInt64
        let totalTimeNs: UInt64
        let peakCPU: Double
        var history: [Double]
        var highCPUSince: Date?
    }

    private struct CachedMetadata {
        let startTimeSec: UInt64
        let executablePath: String?
        let bundlePath: String?
        let bundleIdentifier: String?
        let displayName: String?
    }

    private var previousSamples: [pid_t: PreviousSample] = [:]
    private var metadataCache: [pid_t: CachedMetadata] = [:]
    private var lastSampleMonotonicNs: UInt64?
    private var pidBuffer: [pid_t] = Array(repeating: 0, count: 1024)

    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let maxHistoryPoints = 24
    private let sustainedThresholdCPU: Double = 25.0

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseNumer = UInt64(info.numer == 0 ? 1 : info.numer)
        self.timebaseDenom = UInt64(info.denom == 0 ? 1 : info.denom)
    }

    /// Converts Mach absolute time ticks (returned by `pti_total_user`/`pti_total_system`) to nanoseconds.
    @inline(__always)
    private func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        if timebaseNumer == timebaseDenom {
            return ticks
        }
        // Use 128-bit arithmetic via multipliedFullWidth to avoid overflow on long-running processes
        let (high, low) = ticks.multipliedFullWidth(by: timebaseNumer)
        if high == 0 {
            return low / timebaseDenom
        }
        return (ticks / timebaseDenom) * timebaseNumer
    }

    public struct SampleResult: Sendable {
        public let processes: [ProcessEntry]
        public let selfCPUPercent: Double
        public let totalProcessCount: Int
    }

    /// Samples all processes natively and returns sorted entries.
    /// - Parameters:
    ///   - maxResults: Maximum number of top processes to return (plus paused processes).
    ///   - minCPUPercent: Minimum CPU% to include in the result (if `includeIdle` is false).
    ///   - includeIdle: If true, returns top processes even if CPU is 0%.
    public func sample(
        maxResults: Int = 25,
        minCPUPercent: Double = 0.0,
        includeIdle: Bool = true
    ) -> SampleResult {
        let nowMonotonic = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let nowDate = Date()
        let elapsedNs: UInt64? = lastSampleMonotonicNs.map { prev in
            nowMonotonic > prev ? (nowMonotonic - prev) : 1
        }
        lastSampleMonotonicNs = nowMonotonic

        let pidCount = fetchAllPIDs()
        guard pidCount > 0 else {
            return SampleResult(processes: [], selfCPUPercent: 0, totalProcessCount: 0)
        }

        let currentPID = getpid()
        var alivePIDs = Set<pid_t>(minimumCapacity: pidCount)
        var rawNamesByPID: [pid_t: String] = [:]
        rawNamesByPID.reserveCapacity(pidCount)

        struct RawProc {
            let pid: pid_t
            let ppid: pid_t
            let uid: uid_t
            let rawName: String
            let startTimeSec: UInt64
            let cpuPercent: Double
            let peakCPU: Double
            let history: [Double]
            let residentBytes: UInt64
            let threadCount: Int
            let state: ProcessRunState
            let highCPUSince: Date?
            let niceValue: Int32
            let totalCPUTimeSeconds: Double
        }

        var rawProcs: [RawProc] = []
        rawProcs.reserveCapacity(pidCount)

        var selfCPU: Double = 0.0
        var taskAll = proc_taskallinfo()
        let taskAllSize = Int32(MemoryLayout<proc_taskallinfo>.stride)
        var bsdOnly = proc_bsdinfo()
        let bsdOnlySize = Int32(MemoryLayout<proc_bsdinfo>.stride)

        for i in 0..<pidCount {
            let pid = pidBuffer[i]
            if pid <= 0 { continue }
            alivePIDs.insert(pid)

            let ret = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &taskAll, taskAllSize)
            if ret == taskAllSize {
                let pbsd = taskAll.pbsd
                let ptinfo = taskAll.ptinfo

                let rawName = extractProcessName(from: pbsd)
                rawNamesByPID[pid] = rawName

                let totalTicks = ptinfo.pti_total_user &+ ptinfo.pti_total_system
                let totalNs = machTicksToNanoseconds(totalTicks)
                let startSec = pbsd.pbi_start_tvsec

                var cpuPct: Double = 0.0
                var prevHistory: [Double] = []
                var prevPeak: Double = 0.0
                var highSince: Date? = nil

                if let prev = previousSamples[pid], prev.startTimeSec == startSec {
                    if let dt = elapsedNs, dt > 0, totalNs >= prev.totalTimeNs {
                        let deltaNs = totalNs - prev.totalTimeNs
                        cpuPct = (Double(deltaNs) / Double(dt)) * 100.0
                    }
                    prevHistory = prev.history
                    prevPeak = max(prev.peakCPU, cpuPct)
                    if cpuPct >= sustainedThresholdCPU {
                        highSince = prev.highCPUSince ?? nowDate
                    } else {
                        highSince = nil
                    }
                } else {
                    prevPeak = cpuPct
                    if cpuPct >= sustainedThresholdCPU {
                        highSince = nowDate
                    }
                }

                prevHistory.append(cpuPct)
                if prevHistory.count > maxHistoryPoints {
                    prevHistory.removeFirst(prevHistory.count - maxHistoryPoints)
                }

                previousSamples[pid] = PreviousSample(
                    startTimeSec: startSec,
                    totalTimeNs: totalNs,
                    peakCPU: prevPeak,
                    history: prevHistory,
                    highCPUSince: highSince
                )

                if pid == currentPID {
                    selfCPU = cpuPct
                }

                let runState = ProcessRunState(bsdStatus: pbsd.pbi_status)

                rawProcs.append(RawProc(
                    pid: pid,
                    ppid: pid_t(pbsd.pbi_ppid),
                    uid: pbsd.pbi_uid,
                    rawName: rawName,
                    startTimeSec: startSec,
                    cpuPercent: cpuPct,
                    peakCPU: prevPeak,
                    history: prevHistory,
                    residentBytes: ptinfo.pti_resident_size,
                    threadCount: Int(ptinfo.pti_threadnum),
                    state: runState,
                    highCPUSince: highSince,
                    niceValue: pbsd.pbi_nice,
                    totalCPUTimeSeconds: Double(totalNs) / 1_000_000_000.0
                ))
            } else {
                // Fallback for protected processes where task info isn't readable
                let bsdRet = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdOnly, bsdOnlySize)
                if bsdRet == bsdOnlySize {
                    let rawName = extractProcessName(from: bsdOnly)
                    rawNamesByPID[pid] = rawName
                }
            }
        }

        // Prune dead PIDs from caches to keep memory footprint tiny
        if previousSamples.count > alivePIDs.count + 32 {
            previousSamples = previousSamples.filter { alivePIDs.contains($0.key) }
            metadataCache = metadataCache.filter { alivePIDs.contains($0.key) }
        }

        // Sort by CPU descending, then paused processes, then memory descending
        rawProcs.sort { a, b in
            if abs(a.cpuPercent - b.cpuPercent) > 0.05 {
                return a.cpuPercent > b.cpuPercent
            }
            if a.state == .stopped && b.state != .stopped {
                return true
            }
            if a.state != .stopped && b.state == .stopped {
                return false
            }
            return a.residentBytes > b.residentBytes
        }

        // Only resolve paths, bundle metadata, and physical memory footprint for the top slice!
        // This keeps background/popover sampling blazing fast.
        var results: [ProcessEntry] = []
        results.reserveCapacity(min(maxResults, rawProcs.count))

        for proc in rawProcs {
            if results.count >= maxResults { break }
            if !includeIdle && proc.cpuPercent < minCPUPercent && proc.state != .stopped {
                continue
            }

            let meta = resolveMetadata(pid: proc.pid, startTimeSec: proc.startTimeSec)
            let displayName = meta.displayName ?? proc.rawName
            let memoryBytes = fetchPhysicalFootprint(pid: proc.pid) ?? proc.residentBytes
            let parentName = rawNamesByPID[proc.ppid]

            results.append(ProcessEntry(
                pid: proc.pid,
                ppid: proc.ppid,
                uid: proc.uid,
                name: displayName,
                rawName: proc.rawName,
                executablePath: meta.executablePath,
                bundlePath: meta.bundlePath,
                bundleIdentifier: meta.bundleIdentifier,
                parentName: parentName,
                cpuPercent: proc.cpuPercent,
                peakCPUPercent: proc.peakCPU,
                cpuHistory: proc.history,
                memoryBytes: memoryBytes,
                threadCount: proc.threadCount,
                state: proc.state,
                isSystemProcess: proc.uid == 0 || proc.uid < 500,
                highCPUSince: proc.highCPUSince,
                startTime: proc.startTimeSec > 0 ? Date(timeIntervalSince1970: TimeInterval(proc.startTimeSec)) : nil,
                niceValue: proc.niceValue,
                totalCPUTimeSeconds: proc.totalCPUTimeSeconds
            ))
        }

        return SampleResult(
            processes: results,
            selfCPUPercent: selfCPU,
            totalProcessCount: pidCount
        )
    }

    private func fetchAllPIDs() -> Int {
        let estimatedBytes = proc_listallpids(nil, 0)
        guard estimatedBytes > 0 else { return 0 }

        let neededCount = Int(estimatedBytes) + 64
        if pidBuffer.count < neededCount {
            pidBuffer = Array(repeating: 0, count: neededCount)
        }

        let byteSize = Int32(pidBuffer.count * MemoryLayout<pid_t>.stride)
        let actualCount = pidBuffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, byteSize)
        }
        return max(0, Int(actualCount))
    }

    private func extractProcessName(from pbsd: proc_bsdinfo) -> String {
        // pbi_name is up to 32 bytes (more complete than 16-byte pbi_comm)
        let name: String = withUnsafePointer(to: pbsd.pbi_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN)) { cStr in
                String(cString: cStr)
            }
        }
        if !name.isEmpty {
            return name
        }
        return withUnsafePointer(to: pbsd.pbi_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cStr in
                String(cString: cStr)
            }
        }
    }

    private func fetchPhysicalFootprint(pid: pid_t) -> UInt64? {
        var rusage = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
            }
        }
        guard ret == 0 else { return nil }
        return rusage.ri_phys_footprint
    }

    private func resolveMetadata(pid: pid_t, startTimeSec: UInt64) -> CachedMetadata {
        if let cached = metadataCache[pid], cached.startTimeSec == startTimeSec {
            return cached
        }

        let execPath = Self.executablePath(for: pid)
        var bundlePath: String? = nil
        var bundleID: String? = nil
        var displayName: String? = nil

        if let path = execPath {
            if let appRange = path.range(of: ".app/") {
                let bPath = String(path[..<appRange.upperBound].dropLast())
                bundlePath = bPath
                if let bundle = Bundle(path: bPath) {
                    bundleID = bundle.bundleIdentifier
                    let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    let execName = (path as NSString).lastPathComponent
                    // If this is a helper inside an app bundle, show e.g. "Chrome Helper" or the executable name
                    if let appName, !appName.isEmpty {
                        if execName.caseInsensitiveCompare(appName) == .orderedSame {
                            displayName = appName
                        } else if execName.localizedCaseInsensitiveContains("helper")
                                    || execName.localizedCaseInsensitiveContains("renderer")
                                    || execName.localizedCaseInsensitiveContains("gpu")
                                    || execName.localizedCaseInsensitiveContains("plugin") {
                            displayName = execName
                        } else {
                            displayName = execName
                        }
                    }
                }
            } else {
                let last = (path as NSString).lastPathComponent
                if !last.isEmpty {
                    displayName = last
                }
            }
        }

        let meta = CachedMetadata(
            startTimeSec: startTimeSec,
            executablePath: execPath,
            bundlePath: bundlePath,
            bundleIdentifier: bundleID,
            displayName: displayName
        )
        metadataCache[pid] = meta
        return meta
    }

    public static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard ret > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return String(cString: base)
        }
    }
}
