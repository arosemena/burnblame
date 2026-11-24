import Darwin
import Foundation

/// Lightweight native process sampler using `libproc` (`proc_listallpids` + `proc_pidinfo` + `proc_pid_rusage`).
/// Tracks rolling 1m / 5m CPU-seconds, GPU-seconds (fed from GPUSampler), and Disk I/O bytes,
/// retaining recently exited high-heat processes so hit-and-run culprits are never missed.
public final class ProcessSampler: @unchecked Sendable {
    private struct HeatSample {
        let timestamp: TimeInterval
        let cpuSeconds: Double
        let gpuSeconds: Double
        let diskBytes: UInt64
    }

    private struct PreviousSample {
        let startTimeSec: UInt64
        let totalTimeNs: UInt64
        var lastDiskIOBytes: UInt64?
        let peakCPU: Double
        var history: [Double]
        var highCPUSince: Date?
        var heatLedger: [HeatSample]
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
    private var lastRootPSSampleEpoch: TimeInterval = 0
    private var cachedRootProcs: [pid_t: (ppid: pid_t, uid: uid_t, cpu: Double, rssBytes: UInt64, name: String)] = [:]
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
        public let totalHeat1mScore: Double
        public let totalHeat5mScore: Double
        public let totalCPUHeat1mSeconds: Double
        public let sampleDurationMs: Double
    }

    public func sample(
        maxResults: Int = 60,
        includeIdle: Bool = true,
        expectedTotalCoreCPU: Double = 0
    ) -> SampleResult {
        let tStart = CFAbsoluteTimeGetCurrent()
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
                totalHeat1mScore: 0,
                totalHeat5mScore: 0,
                totalCPUHeat1mSeconds: 0,
                sampleDurationMs: (CFAbsoluteTimeGetCurrent() - tStart) * 1000.0
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
            var cpuHeat1m: Double
            var cpuHeat5m: Double
            var gpuHeat1m: Double
            var gpuHeat5m: Double
            var disk1m: UInt64
            var disk5m: UInt64
        }

        var rawProcs: [RawProc] = []
        rawProcs.reserveCapacity(pidCount)

        var selfCPU: Double = 0.0
        var observedUserCPUSum: Double = 0.0
        var unreadablePIDs = Set<pid_t>()
        var totalHeat1mScore: Double = 0.0
        var totalHeat5mScore: Double = 0.0
        var totalCPUHeat1m: Double = 0.0

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
                let gpuDelta = 0.0

                var cpuPct: Double = 0.0
                var deltaSec: Double = 0.0
                var prevHistory: [Double] = []
                var prevPeak: Double = 0.0
                var highSince: Date? = nil
                var ledger: [HeatSample] = []
                var prevDiskIO: UInt64? = nil

                if let prev = previousSamples[pid], prev.startTimeSec == startSec {
                    if let dt = elapsedNs, dt > 0, totalNs >= prev.totalTimeNs {
                        let deltaNs = totalNs - prev.totalTimeNs
                        deltaSec = Double(deltaNs) / 1_000_000_000.0
                        cpuPct = (Double(deltaNs) / Double(dt)) * 100.0
                    }
                    prevHistory = prev.history
                    prevPeak = max(prev.peakCPU, cpuPct)
                    ledger = prev.heatLedger
                    prevDiskIO = prev.lastDiskIOBytes
                    if cpuPct >= sustainedThresholdCPU {
                        highSince = prev.highCPUSince ?? nowDate
                    }
                } else {
                    let initialSec = Double(totalNs) / 1_000_000_000.0
                    if elapsedNs != nil && startSec > 0 && (nowEpoch - TimeInterval(startSec)) < 30.0 && initialSec > 0.05 {
                        deltaSec = min(initialSec, 15.0)
                    }
                    prevPeak = cpuPct
                    if cpuPct >= sustainedThresholdCPU {
                        highSince = nowDate
                    }
                }

                if deltaSec >= 0.004 || gpuDelta >= 0.002 {
                    ledger.append(HeatSample(
                        timestamp: nowEpoch,
                        cpuSeconds: deltaSec,
                        gpuSeconds: gpuDelta,
                        diskBytes: 0
                    ))
                }

                if let firstValid = ledger.firstIndex(where: { $0.timestamp >= cutoff5m }) {
                    if firstValid > 0 {
                        ledger.removeFirst(firstValid)
                    }
                } else if !ledger.isEmpty {
                    ledger.removeAll(keepingCapacity: false)
                }

                let sums = sumLedger(ledger, cutoff1m: cutoff1m)
                totalCPUHeat1m += sums.cpu1m
                totalHeat1mScore += sums.score1m
                totalHeat5mScore += sums.score5m

                prevHistory.append(cpuPct)
                if prevHistory.count > maxHistoryPoints {
                    prevHistory.removeFirst(prevHistory.count - maxHistoryPoints)
                }

                previousSamples[pid] = PreviousSample(
                    startTimeSec: startSec,
                    totalTimeNs: totalNs,
                    lastDiskIOBytes: prevDiskIO,
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
                observedUserCPUSum += cpuPct

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
                    cpuHeat1m: sums.cpu1m,
                    cpuHeat5m: sums.cpu5m,
                    gpuHeat1m: sums.gpu1m,
                    gpuHeat5m: sums.gpu5m,
                    disk1m: sums.disk1m,
                    disk5m: sums.disk5m
                ))
            } else {
                unreadablePIDs.insert(pid)
                let bsdRet = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdOnly, bsdOnlySize)
                if bsdRet == bsdOnlySize {
                    let rawName = extractProcessName(from: bsdOnly)
                    rawNamesByPID[pid] = rawName
                }
            }
        }

        // On-demand root/system process attribution:
        // Only runs `/bin/ps` (rate-limited to >= 3.5s) when whole-Mac CPU exceeds readable user processes
        // by >= 20% per-core, so WindowServer / mds_stores / kernel_task are caught with zero idle cost!
        let elapsedSec = elapsedNs.map { Double($0) / 1_000_000_000.0 } ?? 0.0
        if !RuntimeEnvironment.isSandboxed && !unreadablePIDs.isEmpty && (expectedTotalCoreCPU - observedUserCPUSum) >= 20.0 {
            if nowEpoch - lastRootPSSampleEpoch >= 3.5 {
                lastRootPSSampleEpoch = nowEpoch
                cachedRootProcs = fetchHotRootProcessesViaPS(unreadablePIDs: unreadablePIDs)
            }
        } else if nowEpoch - lastRootPSSampleEpoch >= 10.0 {
            cachedRootProcs.removeAll(keepingCapacity: true)
        }

        for (pid, rp) in cachedRootProcs where alivePIDs.contains(pid) {
            let deltaSec = elapsedSec > 0 ? (rp.cpu / 100.0) * elapsedSec : 0.0
            let prev = previousSamples[pid]
            var ledger = prev?.heatLedger ?? []
            if deltaSec >= 0.004 {
                ledger.append(HeatSample(timestamp: nowEpoch, cpuSeconds: deltaSec, gpuSeconds: 0, diskBytes: 0))
            }
            if let firstValid = ledger.firstIndex(where: { $0.timestamp >= cutoff5m }) {
                if firstValid > 0 { ledger.removeFirst(firstValid) }
            } else if !ledger.isEmpty {
                ledger.removeAll(keepingCapacity: false)
            }
            let sums = sumLedger(ledger, cutoff1m: cutoff1m)
            totalCPUHeat1m += sums.cpu1m
            totalHeat1mScore += sums.score1m
            totalHeat5mScore += sums.score5m

            var hist = prev?.history ?? []
            hist.append(rp.cpu)
            if hist.count > maxHistoryPoints { hist.removeFirst(hist.count - maxHistoryPoints) }
            let peak = max(prev?.peakCPU ?? 0, rp.cpu)
            let highSince: Date? = rp.cpu >= sustainedThresholdCPU ? (prev?.highCPUSince ?? nowDate) : nil

            previousSamples[pid] = PreviousSample(
                startTimeSec: 0,
                totalTimeNs: 0,
                lastDiskIOBytes: nil,
                peakCPU: peak,
                history: hist,
                highCPUSince: highSince,
                heatLedger: ledger,
                lastRawName: rp.name,
                lastPPID: rp.ppid,
                lastUID: rp.uid,
                lastMemoryBytes: rp.rssBytes
            )

            rawProcs.append(RawProc(
                pid: pid,
                ppid: rp.ppid,
                uid: rp.uid,
                rawName: rp.name,
                startTimeSec: 0,
                cpuPercent: rp.cpu,
                peakCPU: peak,
                history: hist,
                residentBytes: rp.rssBytes,
                threadCount: 0,
                state: .running,
                highCPUSince: highSince,
                niceValue: 0,
                totalCPUTimeSeconds: sums.cpu5m,
                cpuHeat1m: sums.cpu1m,
                cpuHeat5m: sums.cpu5m,
                gpuHeat1m: 0,
                gpuHeat5m: 0,
                disk1m: 0,
                disk5m: 0
            ))
        }

        // Capture exited culprits that burned significant heat before exiting
        var deadPIDs: [pid_t] = []
        for (pid, prev) in previousSamples where !alivePIDs.contains(pid) {
            deadPIDs.append(pid)
            let sums = sumLedger(prev.heatLedger, cutoff1m: cutoff1m)
            if sums.score5m >= exitedRetentionHeatThreshold {
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

        // Age out exited culprits
        var exitedEntries: [ProcessEntry] = []
        recentlyExited = recentlyExited.compactMap { culprit in
            var updated = culprit
            updated.heatLedger.removeAll { $0.timestamp < cutoff5m }
            let sums = sumLedger(updated.heatLedger, cutoff1m: cutoff1m)
            guard sums.score5m >= 0.5 else { return nil }

            totalCPUHeat1m += sums.cpu1m
            totalHeat1mScore += sums.score1m
            totalHeat5mScore += sums.score5m

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
                totalCPUTimeSeconds: sums.cpu5m,
                heat1mSeconds: sums.cpu1m,
                heat5mSeconds: sums.cpu5m,
                gpuHeat1mSeconds: sums.gpu1m,
                gpuHeat5mSeconds: sums.gpu5m,
                diskIO1mBytes: sums.disk1m,
                diskIO5mBytes: sums.disk5m,
                exitedAt: updated.exitedAt
            ))
            return updated
        }
        if recentlyExited.count > 40 {
            recentlyExited.removeFirst(recentlyExited.count - 40)
        }

        // Sort live procs by unified heat score so we only resolve rusage/metadata for the top slice
        rawProcs.sort { a, b in
            let sA = (a.cpuHeat1m + a.gpuHeat1m * 1.5) * 4.0 + a.cpuHeat5m + a.gpuHeat5m * 1.5 + a.cpuPercent * 0.15
            let sB = (b.cpuHeat1m + b.gpuHeat1m * 1.5) * 4.0 + b.cpuHeat5m + b.gpuHeat5m * 1.5 + b.cpuPercent * 0.15
            if abs(sA - sB) > 0.01 { return sA > sB }
            if a.state == .stopped && b.state != .stopped { return true }
            if a.state != .stopped && b.state == .stopped { return false }
            return a.residentBytes > b.residentBytes
        }

        var results: [ProcessEntry] = []
        results.reserveCapacity(min(maxResults, rawProcs.count) + exitedEntries.count)

        for var proc in rawProcs {
            if results.count >= maxResults { break }
            if !includeIdle && proc.cpuHeat1m < 0.05 && proc.gpuHeat1m < 0.02 && proc.cpuHeat5m < 0.1 && proc.cpuPercent < 1.0 && proc.state != .stopped {
                continue
            }

            let meta = resolveMetadata(pid: proc.pid, startTimeSec: proc.startTimeSec)
            let displayName = meta.displayName ?? proc.rawName
            let rusage = fetchRusageFootprintAndDisk(pid: proc.pid)
            let memoryBytes = rusage?.footprint ?? proc.residentBytes

            // Zero-extra-cost Disk I/O delta from the exact same proc_pid_rusage call!
            if let totalDisk = rusage?.totalDiskBytes, var prev = previousSamples[proc.pid] {
                if let lastDisk = prev.lastDiskIOBytes, totalDisk > lastDisk {
                    let deltaDisk = totalDisk - lastDisk
                    if deltaDisk >= 512 * 1024 { // >= 512 KB
                        prev.heatLedger.append(HeatSample(
                            timestamp: nowEpoch,
                            cpuSeconds: 0,
                            gpuSeconds: 0,
                            diskBytes: deltaDisk
                        ))
                        let updatedSums = sumLedger(prev.heatLedger, cutoff1m: cutoff1m)
                        let addedScore1m = Double(deltaDisk) / 200_000_000.0
                        totalHeat1mScore += addedScore1m
                        totalHeat5mScore += addedScore1m
                        proc.disk1m = updatedSums.disk1m
                        proc.disk5m = updatedSums.disk5m
                    }
                }
                prev.lastDiskIOBytes = totalDisk
                previousSamples[proc.pid] = prev
            }

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
                heat1mSeconds: proc.cpuHeat1m,
                heat5mSeconds: proc.cpuHeat5m,
                gpuHeat1mSeconds: proc.gpuHeat1m,
                gpuHeat5mSeconds: proc.gpuHeat5m,
                diskIO1mBytes: proc.disk1m,
                diskIO5mBytes: proc.disk5m,
                exitedAt: nil
            ))
        }

        results.append(contentsOf: exitedEntries)

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - tStart) * 1000.0

        return SampleResult(
            processes: results,
            selfCPUPercent: selfCPU,
            totalProcessCount: pidCount,
            totalHeat1mScore: totalHeat1mScore,
            totalHeat5mScore: totalHeat5mScore,
            totalCPUHeat1mSeconds: totalCPUHeat1m,
            sampleDurationMs: elapsedMs
        )
    }

    private func sumLedger(_ ledger: [HeatSample], cutoff1m: TimeInterval) -> (
        cpu1m: Double, cpu5m: Double,
        gpu1m: Double, gpu5m: Double,
        disk1m: UInt64, disk5m: UInt64,
        score1m: Double, score5m: Double
    ) {
        var c1 = 0.0, c5 = 0.0, g1 = 0.0, g5 = 0.0
        var d1: UInt64 = 0, d5: UInt64 = 0
        for item in ledger {
            c5 += item.cpuSeconds
            g5 += item.gpuSeconds
            d5 &+= item.diskBytes
            if item.timestamp >= cutoff1m {
                c1 += item.cpuSeconds
                g1 += item.gpuSeconds
                d1 &+= item.diskBytes
            }
        }
        let s1 = c1 + g1 * 1.5 + Double(d1) / 200_000_000.0
        let s5 = c5 + g5 * 1.5 + Double(d5) / 200_000_000.0
        return (c1, c5, g1, g5, d1, d5, s1, s5)
    }

    private func fetchHotRootProcessesViaPS(
        unreadablePIDs: Set<pid_t>
    ) -> [pid_t: (ppid: pid_t, uid: uid_t, cpu: Double, rssBytes: UInt64, name: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Arc", "-o", "pid=,ppid=,uid=,pcpu=,rss=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var found: [pid_t: (ppid: pid_t, uid: uid_t, cpu: Double, rssBytes: UInt64, name: String)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 6,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]),
                  let uid = uid_t(parts[2]),
                  let cpu = Double(parts[3]),
                  let rssKB = UInt64(parts[4])
            else { continue }

            // ps -r sorts by CPU descending; stop as soon as we hit idle processes (< 1%)
            if cpu < 1.0 { break }
            guard unreadablePIDs.contains(pid) else { continue }

            let name = String(parts[5]).trimmingCharacters(in: .whitespaces)
            found[pid] = (ppid: ppid, uid: uid, cpu: cpu, rssBytes: rssKB * 1024, name: name)
        }
        return found
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

    private func fetchRusageFootprintAndDisk(pid: pid_t) -> (footprint: UInt64, totalDiskBytes: UInt64)? {
        var rusage = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
            }
        }
        guard ret == 0 else { return nil }
        return (rusage.ri_phys_footprint, rusage.ri_diskio_bytesread &+ rusage.ri_diskio_byteswritten)
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
                let execName = (path as NSString).lastPathComponent
                if let bundle = Bundle(path: bPath) {
                    bundleID = bundle.bundleIdentifier
                    let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    if let appName, !appName.isEmpty {
                        displayName = execName.caseInsensitiveCompare(appName) == .orderedSame ? appName : execName
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
