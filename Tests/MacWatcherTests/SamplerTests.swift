import XCTest
@testable import MacWatcher

final class SamplerTests: XCTestCase {
    func testSystemCPUSamplerReturnsValidRange() {
        let sampler = SystemCPUSampler()
        _ = sampler.sample()
        usleep(50_000)
        let snap = sampler.sample()

        XCTAssertGreaterThan(snap.coreCount, 0)
        XCTAssertGreaterThanOrEqual(snap.user, 0)
        XCTAssertGreaterThanOrEqual(snap.system, 0)
        XCTAssertGreaterThanOrEqual(snap.idle, 0)
        XCTAssertLessThanOrEqual(snap.total, 100.01)
    }

    func testProcessSamplerFindsCurrentProcess() {
        let sampler = ProcessSampler()
        _ = sampler.sample(maxResults: 50, includeIdle: true)
        usleep(50_000)
        let result = sampler.sample(maxResults: 200, includeIdle: true)

        XCTAssertGreaterThan(result.totalProcessCount, 0)
        XCTAssertFalse(result.processes.isEmpty)
    }

    func testProcessInspectorInspectsSelf() {
        let pid = getpid()
        let entry = makeEntry(pid: pid, name: "xctest", heat1m: 1.0)

        let inspector = ProcessInspector()
        let details = inspector.inspect(entry: entry)

        XCTAssertEqual(details.pid, pid)
        XCTAssertNotNil(details.executablePath)
        XCTAssertNotNil(details.workingDirectory)
        XCTAssertFalse(details.parentChain.isEmpty)
        XCTAssertFalse(details.username.isEmpty)
        XCTAssertGreaterThan(details.openFileCount, 0)
    }

    func testHeatGrouperRollsUpHelpersAndFreezesOnHover() {
        let p1 = makeEntry(pid: 10, name: "Cursor", bundlePath: "/Applications/Cursor.app", heat1m: 12.0, cpu: 20.0)
        let p2 = makeEntry(pid: 11, name: "Cursor Helper", bundlePath: "/Applications/Cursor.app", heat1m: 18.0, cpu: 30.0)
        let p3 = makeEntry(pid: 20, name: "swift-frontend", bundlePath: nil, heat1m: 20.0, cpu: 50.0)

        let groups = HeatGrouper.group(
            processes: [p1, p2, p3],
            window: .oneMinute,
            totalHeatSeconds: 50.0,
            previousOrder: [],
            freezeOrder: false
        )

        // Cursor (12 + 18 = 30s -> 60% of heat) should beat swift-frontend (20s -> 40%)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "Cursor")
        XCTAssertEqual(groups[0].members.count, 2)
        XCTAssertEqual(groups[0].heatSeconds, 30.0, accuracy: 0.01)
        XCTAssertEqual(groups[0].heatSharePercent, 60.0, accuracy: 0.1)

        // Now swift-frontend spikes above Cursor, but hover-freeze keeps order pinned!
        let p3Hot = makeEntry(pid: 20, name: "swift-frontend", bundlePath: nil, heat1m: 45.0, cpu: 90.0)
        let frozen = HeatGrouper.group(
            processes: [p1, p2, p3Hot],
            window: .oneMinute,
            totalHeatSeconds: 75.0,
            previousOrder: groups.map(\.id),
            freezeOrder: true
        )
        XCTAssertEqual(frozen[0].name, "Cursor")
        XCTAssertEqual(frozen[1].name, "swift-frontend")

        // When un-hovered, decisive lead (45s vs 30s) swaps swift-frontend to #1
        let unfrozen = HeatGrouper.group(
            processes: [p1, p2, p3Hot],
            window: .oneMinute,
            totalHeatSeconds: 75.0,
            previousOrder: groups.map(\.id),
            freezeOrder: false
        )
        XCTAssertEqual(unfrozen[0].name, "swift-frontend")
    }

    func testSelfCPUScalingAccuracy() {
        let sampler = ProcessSampler()
        _ = sampler.sample(maxResults: 50, includeIdle: true)

        let end = CFAbsoluteTimeGetCurrent() + 0.15
        var sink: UInt64 = 0
        while CFAbsoluteTimeGetCurrent() < end {
            sink &+= 1
        }
        _ = sink

        let result = sampler.sample(maxResults: 200, includeIdle: true)
        XCTAssertGreaterThan(result.selfCPUPercent, 40.0)
        XCTAssertLessThan(result.selfCPUPercent, 200.0)
        XCTAssertGreaterThan(result.totalHeat1mSeconds, 0.05)
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.cpu(0.0), "0.0%")
        XCTAssertEqual(Formatters.cpu(4.56), "4.6%")
        XCTAssertEqual(Formatters.cpu(142.8), "143%")
        XCTAssertEqual(Formatters.heatSeconds(0.42), "0.4s")
        XCTAssertEqual(Formatters.heatSeconds(45.2), "45s")
        XCTAssertEqual(Formatters.heatSeconds(135.0), "2m 15s")
        XCTAssertEqual(Formatters.duration(45), "45s")
        XCTAssertEqual(Formatters.duration(125), "2m 5s")
        XCTAssertEqual(Formatters.duration(3665), "1h 1m")
    }

    private func makeEntry(
        pid: pid_t,
        name: String,
        bundlePath: String? = nil,
        heat1m: Double = 0,
        cpu: Double = 1.0
    ) -> ProcessEntry {
        ProcessEntry(
            pid: pid,
            ppid: getppid(),
            uid: getuid(),
            name: name,
            rawName: name,
            executablePath: ProcessSampler.executablePath(for: pid),
            bundlePath: bundlePath,
            bundleIdentifier: nil,
            parentName: nil,
            cpuPercent: cpu,
            peakCPUPercent: cpu,
            cpuHistory: [cpu],
            memoryBytes: 1024 * 1024,
            threadCount: 1,
            state: .running,
            isSystemProcess: false,
            highCPUSince: nil,
            startTime: Date(),
            niceValue: 0,
            totalCPUTimeSeconds: heat1m,
            heat1mSeconds: heat1m,
            heat5mSeconds: heat1m,
            exitedAt: nil
        )
    }
}
