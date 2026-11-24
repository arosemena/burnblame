import Darwin
import Foundation

/// Lightweight native process sampler using `libproc` (`proc_listallpids` + `proc_pidinfo`).
/// Tracks both live CPU% and a rolling 1m / 5m heat ledger (CPU-seconds burned),
/// retaining recently exited high-heat processes so hit-and-run culprits are never missed.
public final class ProcessSampler: @unchecked Sendable {
    private struct HeatSample {
        let timestamp: TimeInterval
        let cpuSeconds: Double
    }

    private struct PreviousSample {
        let startTimeSec: UInt64
        let totalTimeNs: UInt64
        let peakCPU: Double
        var history: [Double]
        var highCPUSince: Date?
        var heatLedger: [HeatSample]
        // Metadata snapshot in case process exits after burning significant heat
        var lastRawName: String
        var lastPPID: pid_t
        var lastUID: uid_t
        var lastMemoryBytes: UInt64
    }

    private struct ExitedCulprit {
        let pid: pid_t
        let ppid: pid_t
        let uid: uid_t
        let rawName: String
        let startTimeSec: UInt64
        let metadata: CachedMetadata
        let exitedAt: Date
        let peakCPU: Double
        let lastMemoryBytes: UInt64
        var heatLedger: [HeatSample]
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
    private var recentlyExited: [ExitedCulprit] = []
    private var lastSampleMonotonicNs: UInt64?
    private var pidBuffer: [pid_t] = Array(repeating: 0, count: 1024)

    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64
    private let maxHistoryPoints = 24
    private let sustainedThresholdCPU: Double = 25.0
    private let maxLedgerWindowSec: TimeInterval = 300.0
    private let exitedRetentionHeatThreshold: Double = 1.5

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebaseNumer = UInt64(info.numer == 0 ? 1 : info.numer)
        self.timebaseDenom = UInt64(info.denom == 0 ? 1 : info.denom)
    }

    @inline(__always)
    private func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        if timebaseNumer == timebaseDenom {
            return ticks
        }
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
        public let totalHeat1mSeconds: Double
        public let totalHeat5mSeconds: Double
    }

    public func sample(
        maxResults: Int = 60,
        includeIdle: Bool = true
    ) -> SampleResult {
        let nowMonotonic = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let nowDate = Date()
        let nowEpoch = nowDate.timeIntervalSince1970
        let cutoff1m = nowEpoch - 60.0
        let cutoff5m = nowEpoch - maxLedgerWindowSec

        let elapsedNs: UInt64? = lastSampleMonotonicNs.map { prev in
            nowMonotonic > prev ? (nowMonotonic - prev) : 1
        }
        lastSampleMonotonicNs = nowMonotonic

        let pidCount = fetchAllPIDs()
        guard pidCount > 0 else {
            return SampleResult(
                processes: [],
                selfCPUPercent: 0,
                totalProcessCount: 0,
                totalHeat1mSeconds: 0,
                totalHeat5mSeconds: 0
            )
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
            let heat1m: Double
            let heat5m: Double
        }

        var rawProcs: [RawProc] = []
        rawProcs.reserveCapacity(pidCount)

        var selfCPU: Double = 0.0
        var totalHeat1m: Double = 0.0
        var totalHeat5m: Double = 0.0

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
                var deltaSec: Double = 0.0
                var prevHistory: [Double] = []
                var prevPeak: Double = 0.0
                var highSince: Date? = nil
                var ledger: [HeatSample] = []

                if let prev = previousSamples[pid], prev.startTimeSec == startSec {
                    if let dt = elapsedNs, dt > 0, totalNs >= prev.totalTimeNs {
                        let deltaNs = totalNs - prev.totalTimeNs
                        deltaSec = Double(deltaNs) / 1_000_000_000.0
                        cpuPct = (Double(deltaNs) / Double(dt)) * 100.0
                    }
                    prevHistory = prev.history
                    prevPeak = max(prev.peakCPU, cpuPct)
                    ledger = prev.heatLedger
                    if cpuPct >= sustainedThresholdCPU {
                        highSince = prev.highCPUSince ?? nowDate
                    }
                } else {
                    // Brand-new short-lived process: credit its initial CPU time if it started recently
                    let initialSec = Double(totalNs) / 1_000_000_000.0
                    if elapsedNs != nil && startSec > 0 && (nowEpoch - TimeInterval(startSec)) < 30.0 && initialSec > 0.05 {
                        deltaSec = min(initialSec, 15.0)
                    }
                    prevPeak = cpuPct
                    if cpuPct >= sustainedThresholdCPU {
                        highSince = nowDate
                    }
                }

                // Append to rolling heat ledger only when meaningful CPU was burned (keeps idle procs at 0 bytes)
                if deltaSec >= 0.004 {
                    ledger.append(HeatSample(timestamp: nowEpoch, cpuSeconds: deltaSec))
                }
                // Prune entries older than 5 minutes
                if let firstValid = ledger.firstIndex(where: { $0.timestamp >= cutoff5m }) {
                    if firstValid > 0 {
                        ledger.removeFirst(firstValid)
                    }
                } else if !ledger.isEmpty {
                    ledger.removeAll(keepingCapacity: false)
                }

                // Sum 1m and 5m heat
                var h1m: Double = 0.0
                var h5m: Double = 0.0
                for item in ledger {
                    h5m += item.cpuSeconds
                    if item.timestamp >= cutoff1m {
                        h1m += item.cpuSeconds
                    }
                }

                totalHeat1m += h1m
                totalHeat5m += h5m

                prevHistory.append(cpuPct)
                if prevHistory.count > maxHistoryPoints {
                    prevHistory.removeFirst(prevHistory.count - maxHistoryPoints)
                }

                previousSamples[pid] = PreviousSample(
                    startTimeSec: startSec,
                    totalTimeNs: totalNs,
                    peakCPU: prevPeak,
                    history: prevHistory,
                    highCPUSince: highSince,
                    heatLedger: ledger,
                    lastRawName: rawName,
                    lastPPID: pid_t(pbsd.pbi_ppid),
                    lastUID: pbsd.pbi_uid,
                    lastMemoryBytes: ptinfo.pti_resident_size
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
                    totalCPUTimeSeconds: Double(totalNs) / 1_000_000_000.0,
                    heat1m: h1m,
                    heat5m: h5m
                ))
            } else {
                let bsdRet = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdOnly, bsdOnlySize)
                if bsdRet == bsdOnlySize {
                    let rawName = extractProcessName(from: bsdOnly)
                    rawNamesByPID[pid] = rawName
                }
            }
        }

        // Capture any dead PIDs that burned significant heat before exiting!
        var deadPIDs: [pid_t] = []
        for (pid, prev) in previousSamples where !alivePIDs.contains(pid) {
            deadPIDs.append(pid)
            let sum5m = prev.heatLedger.reduce(0.0) { acc, item in
                item.timestamp >= cutoff5m ? acc + item.cpuSeconds : acc
            }
            if sum5m >= exitedRetentionHeatThreshold {
                let meta = metadataCache[pid] ?? CachedMetadata(
                    startTimeSec: prev.startTimeSec,
                    executablePath: nil,
                    bundlePath: nil,
                    bundleIdentifier: nil,
                    displayName: prev.lastRawName
                )
                recentlyExited.append(ExitedCulprit(
                    pid: pid,
                    ppid: prev.lastPPID,
                    uid: prev.lastUID,
                    rawName: prev.lastRawName,
                    startTimeSec: prev.startTimeSec,
                    metadata: meta,
                    exitedAt: nowDate,
                    peakCPU: prev.peakCPU,
                    lastMemoryBytes: prev.lastMemoryBytes,
                    heatLedger: prev.heatLedger
                ))
            }
        }
        for pid in deadPIDs {
            previousSamples.removeValue(forKey: pid)
            metadataCache.removeValue(forKey: pid)
        }

        // Age out exited culprits whose heat has fallen out of the 5m window
        var exitedEntries: [ProcessEntry] = []
        recentlyExited = recentlyExited.compactMap { culprit in
            var updated = culprit
            updated.heatLedger.removeAll { $0.timestamp < cutoff5m }
            var h1m = 0.0
            var h5m = 0.0
            for item in updated.heatLedger {
                h5m += item.cpuSeconds
                if item.timestamp >= cutoff1m { h1m += item.cpuSeconds }
            }
            guard h5m >= 0.5 else { return nil }

            totalHeat1m += h1m
            totalHeat5m += h5m

            exitedEntries.append(ProcessEntry(
                pid: updated.pid,
                ppid: updated.ppid,
                uid: updated.uid,
                name: updated.metadata.displayName ?? updated.rawName,
                rawName: updated.rawName,
                executablePath: updated.metadata.executablePath,
                bundlePath: updated.metadata.bundlePath,
                bundleIdentifier: updated.metadata.bundleIdentifier,
                parentName: rawNamesByPID[updated.ppid],
                cpuPercent: 0,
                peakCPUPercent: updated.peakCPU,
                cpuHistory: [0, 0],
                memoryBytes: updated.lastMemoryBytes,
                threadCount: 0,
                state: .exited,
                isSystemProcess: updated.uid == 0 || updated.uid < 500,
                highCPUSince: nil,
                startTime: updated.startTimeSec > 0 ? Date(timeIntervalSince1970: TimeInterval(updated.startTimeSec)) : nil,
                niceValue: 0,
                totalCPUTimeSeconds: h5m,
                heat1mSeconds: h1m,
                heat5mSeconds: h5m,
                exitedAt: updated.exitedAt
            ))
            return updated
        }
        if recentlyExited.count > 40 {
            recentlyExited.removeFirst(recentlyExited.count - 40)
        }

        // Sort live procs by 1m heat + 5m heat + live CPU so we resolve metadata for all real heat contributors
        rawProcs.sort { a, b in
            let scoreA = a.heat1m * 4.0 + a.heat5m + a.cpuPercent * 0.15
            let scoreB = b.heat1m * 4.0 + b.heat5m + b.cpuPercent * 0.15
            if abs(scoreA - scoreB) > 0.01 {
                return scoreA > scoreB
            }
            if a.state == .stopped && b.state != .stopped { return true }
            if a.state != .stopped && b.state == .stopped { return false }
            return a.residentBytes > b.residentBytes
        }

        var results: [ProcessEntry] = []
        results.reserveCapacity(min(maxResults, rawProcs.count) + exitedEntries.count)

        for proc in rawProcs {
            if results.count >= maxResults { break }
            if !includeIdle && proc.heat1m < 0.05 && proc.heat5m < 0.1 && proc.cpuPercent < 1.0 && proc.state != .stopped {
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
                totalCPUTimeSeconds: proc.totalCPUTimeSeconds,
                heat1mSeconds: proc.heat1m,
                heat5mSeconds: proc.heat5m,
                exitedAt: nil
            ))
        }

        results.append(contentsOf: exitedEntries)

        return SampleResult(
            processes: results,
            selfCPUPercent: selfCPU,
            totalProcessCount: pidCount,
            totalHeat1mSeconds: totalHeat1m,
            totalHeat5mSeconds: totalHeat5m
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
        let name: String = withUnsafePointer(to: pbsd.pbi_name) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN)) { cStr in
                String(cString: cStr)
            }
        }
        if !name.isEmpty { return name }
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
            // Use the FIRST (outermost) ".app/" so nested helpers (e.g. Cursor.app/Contents/Frameworks/Cursor Helper.app)
            // roll up cleanly into the parent application bundle!
            if let appRange = path.range(of: ".app/") {
                let bPath = String(path[..<appRange.upperBound].dropLast())
                bundlePath = bPath
                let execName = (path as NSString).lastPathComponent
                if let bundle = Bundle(path: bPath) {
                    bundleID = bundle.bundleIdentifier
                    let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    if let appName, !appName.isEmpty {
                        if execName.caseInsensitiveCompare(appName) == .orderedSame {
                            displayName = appName
                        } else {
                            displayName = execName
                        }
                    } else {
                        displayName = execName
                    }
                } else {
                    displayName = execName
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
