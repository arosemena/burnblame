import XCTest
@testable import MacWatcher

final class SamplerTests: XCTestCase {
    func testSystemCPUSamplerReturnsValidRange() {
        let sampler = SystemCPUSampler()
        _ = sampler.sample()
        usleep(50_000) // 50ms
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
        let entry = ProcessEntry(
            pid: pid,
            ppid: getppid(),
            uid: getuid(),
            name: "xctest",
            rawName: "xctest",
            executablePath: ProcessSampler.executablePath(for: pid),
            bundlePath: nil,
            bundleIdentifier: nil,
            parentName: nil,
            cpuPercent: 1.0,
            peakCPUPercent: 1.0,
            cpuHistory: [1.0],
            memoryBytes: 0,
            threadCount: 1,
            state: .running,
            isSystemProcess: false,
            highCPUSince: nil,
            startTime: Date(),
            niceValue: 0,
            totalCPUTimeSeconds: 0.1
        )

        let inspector = ProcessInspector()
        let details = inspector.inspect(entry: entry)

        XCTAssertEqual(details.pid, pid)
        XCTAssertNotNil(details.executablePath)
        XCTAssertNotNil(details.workingDirectory)
        XCTAssertFalse(details.parentChain.isEmpty)
        XCTAssertFalse(details.username.isEmpty)
        XCTAssertGreaterThan(details.openFileCount, 0)
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.cpu(0.0), "0.0%")
        XCTAssertEqual(Formatters.cpu(4.56), "4.6%")
        XCTAssertEqual(Formatters.cpu(142.8), "143%")
        XCTAssertEqual(Formatters.duration(45), "45s")
        XCTAssertEqual(Formatters.duration(125), "2m 5s")
        XCTAssertEqual(Formatters.duration(3665), "1h 1m")
    }
}
