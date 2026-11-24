import AppKit
import Foundation
import Observation
import SwiftUI

public struct ActionToast: Equatable, Sendable {
    public let message: String
    public let isError: Bool
}

/// Adaptive thermal, GPU, SMC, and process monitoring coordinator.
/// - Closed popover: ultra-lean 3s CPU ticks, SMC + GPU + process scans every 6s (or immediately on spikes).
/// - Open popover: 2s live updates with real °C, Fan RPM, Watts, GPU%, and multi-source heat attribution.
/// - Tracks its own per-tick millisecond cost (`telemetry`) so overhead stays visible and lean.
@MainActor
@Observable
public final class MonitorEngine {
    public private(set) var systemCPU: SystemCPUSnapshot = .zero
    public private(set) var gpu: GPUSnapshot = .zero
    public private(set) var hardwareThermal: HardwareThermalSnapshot = .empty
    public private(set) var thermalLevel: ThermalLevel = ThermalLevel(state: ProcessInfo.processInfo.thermalState)
    public private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 32)
    public private(set) var processes: [ProcessEntry] = []
    public private(set) var heatGroups: [HeatGroup] = []
    public private(set) var totalHeat1mScore: Double = 0
    public private(set) var totalHeat5mScore: Double = 0
    public private(set) var totalCPUHeat1mSeconds: Double = 0
    public private(set) var thermalEvents: [ThermalEvent] = []
    public private(set) var telemetry: SelfTelemetry = .zero
    public private(set) var totalProcessCount: Int = 0
    public private(set) var lastUpdated: Date = Date()

    public var selfCPUPercent: Double { telemetry.selfCPUPercent }

    public var selectedWindow: HeatWindow = .oneMinute {
        didSet {
            if selectedWindow != oldValue {
                recomputeGroups(resetOrder: true)
            }
        }
    }

    public var isHoveringList: Bool = false
    public private(set) var isLiveScrolling: Bool = false
    public private(set) var listRenderCount: Int = 0
    public var searchQuery: String = ""
    public var hideSystemProcesses: Bool = false {
        didSet { UserDefaults.standard.set(hideSystemProcesses, forKey: "hideSystemProcesses") }
    }

    public var isPopoverOpen: Bool = false {
        didSet {
            if isPopoverOpen != oldValue {
                if !isPopoverOpen {
                    isHoveringList = false
                }
                rescheduleTimer(immediateSample: isPopoverOpen)
            }
        }
    }

    public var isMonitoringPaused: Bool = false {
        didSet {
            if isMonitoringPaused {
                stopTimer()
            } else {
                rescheduleTimer(immediateSample: true)
            }
        }
    }

    public var showPercentInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }

    public var alertThresholdPercent: Double {
        didSet { UserDefaults.standard.set(alertThresholdPercent, forKey: "alertThresholdPercent") }
    }

    // Inspector state
    public private(set) var selectedPID: pid_t?
    public private(set) var selectedInspection: ProcessInspection?
    public private(set) var isLoadingInspection: Bool = false
    public var toast: ActionToast?

    private let cpuSampler = SystemCPUSampler()
    private let gpuSampler = GPUSampler()
    private let smcSampler = SMCSampler()
    private let processSampler = ProcessSampler()
    private let inspector = ProcessInspector()
    private let workerQueue = DispatchQueue(label: "com.burnblame.sampler", qos: .utility)
    private let inspectorQueue = DispatchQueue(label: "com.burnblame.inspector", qos: .userInitiated)

    private var timer: Timer?
    private var backgroundTickCounter: Int = 0
    private var sustainedLoadStart: Date?
    private var activeThermalEventID: UUID?
    private var lastGroupOrder: [String] = []
    private var toastTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    private var scrollStartObserver: NSObjectProtocol?
    private var scrollEndObserver: NSObjectProtocol?
    private var pendingGroupRefreshAfterScroll: Bool = false

    public init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showPercentInMenuBar") == nil {
            self.showPercentInMenuBar = true
        } else {
            self.showPercentInMenuBar = defaults.bool(forKey: "showPercentInMenuBar")
        }
        self.hideSystemProcesses = defaults.bool(forKey: "hideSystemProcesses")
        let storedThreshold = defaults.double(forKey: "alertThresholdPercent")
        self.alertThresholdPercent = storedThreshold > 0 ? storedThreshold : 35.0

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThermalStateNotification()
            }
        }

        // Defer list SwiftUI diffs while NSScrollView is actively live-scrolling for buttery 120Hz scrolling
        scrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isLiveScrolling = true
            }
        }

        scrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLiveScrolling = false
                if self.pendingGroupRefreshAfterScroll {
                    self.pendingGroupRefreshAfterScroll = false
                    self.recomputeGroups(resetOrder: false)
                }
            }
        }

        primeBaseline()
        rescheduleTimer(immediateSample: false)
    }

    // MARK: - Filtered View Data

    public var filteredHeatGroups: [HeatGroup] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return heatGroups.filter { group in
            if hideSystemProcesses && group.isSystemGroup {
                return false
            }
            if !query.isEmpty {
                if group.name.lowercased().contains(query) { return true }
                return group.members.contains { proc in
                    proc.name.lowercased().contains(query)
                        || proc.rawName.lowercased().contains(query)
                        || String(proc.pid).contains(query)
                        || (proc.parentName?.lowercased().contains(query) ?? false)
                }
            }
            return true
        }
    }

    public var selectedProcess: ProcessEntry? {
        guard let pid = selectedPID else { return nil }
        return processes.first { $0.pid == pid }
    }

    public var avgLoad1mPercent: Double {
        let cores = Double(max(1, systemCPU.coreCount))
        return min(100.0, (totalCPUHeat1mSeconds / (60.0 * cores)) * 100.0)
    }

    /// Combines macOS `ProcessInfo.thermalState` (which only flips once throttling begins)
    /// with real AppleSMC die temperature, fan RPM, and power draw so the badge matches reality.
    public var effectiveThermalLevel: ThermalLevel {
        let cpuC = hardwareThermal.cpuTempC ?? 0
        let gpuC = hardwareThermal.gpuTempC ?? 0
        let maxTemp = max(cpuC, gpuC)
        let rpm = hardwareThermal.peakFanRPM ?? 0
        let watts = hardwareThermal.systemPowerWatts ?? 0

        let hardwareLevel: ThermalLevel
        if maxTemp >= 98 || rpm >= 4500 {
            hardwareLevel = .critical
        } else if maxTemp >= 85 || rpm >= 2400 || watts >= 45 {
            hardwareLevel = .hot
        } else if maxTemp >= 68 || rpm >= 1200 || watts >= 25 {
            hardwareLevel = .warm
        } else {
            hardwareLevel = .cool
        }

        return max(thermalLevel, hardwareLevel)
    }

    public var menuBarSeverity: CPUSeverity {
        if effectiveThermalLevel >= .hot || systemCPU.total >= 80 {
            return .critical
        }
        if effectiveThermalLevel == .warm
            || gpu.deviceUtilizationPercent >= 65
            || systemCPU.total >= alertThresholdPercent {
            return .elevated
        }
        if systemCPU.total >= 15 || gpu.deviceUtilizationPercent >= 25 {
            return .moderate
        }
        return .calm
    }

    // MARK: - Selection & Inspection

    public func selectProcess(_ entry: ProcessEntry) {
        selectedPID = entry.pid
        selectedInspection = nil
        if entry.isExited {
            isLoadingInspection = false
            return
        }
        isLoadingInspection = true

        let inspector = self.inspector
        inspectorQueue.async { [weak self] in
            let details = inspector.inspect(entry: entry)
            Task { @MainActor [weak self] in
                guard let self, self.selectedPID == entry.pid else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    self.selectedInspection = details
                    self.isLoadingInspection = false
                }
            }
        }
    }

    public func selectProcessByPID(_ pid: pid_t) {
        if let entry = processes.first(where: { $0.pid == pid }) {
            selectProcess(entry)
        } else {
            showToast("Process (PID \(pid)) has already exited", isError: false)
        }
    }

    public func refreshInspection() {
        guard let entry = selectedProcess, !entry.isExited else { return }
        selectProcess(entry)
    }

    public func clearSelection() {
        selectedPID = nil
        selectedInspection = nil
        isLoadingInspection = false
    }

    // MARK: - Process Actions

    public func performTerminate(pid: pid_t, name: String) {
        handleActionResult(
            ProcessController.terminate(pid: pid),
            successMessage: "Sent Quit signal to \(name)"
        )
    }

    public func performForceQuit(pid: pid_t, name: String) {
        handleActionResult(
            ProcessController.forceQuit(pid: pid),
            successMessage: "Force quit \(name)"
        )
    }

    public func performTogglePause(entry: ProcessEntry) {
        if entry.isPaused {
            handleActionResult(
                ProcessController.resume(pid: entry.pid),
                successMessage: "Resumed \(entry.name)"
            )
        } else {
            handleActionResult(
                ProcessController.pause(pid: entry.pid),
                successMessage: "Paused \(entry.name) (frozen)"
            )
        }
    }

    public func performThrottle(entry: ProcessEntry) {
        handleActionResult(
            ProcessController.throttle(pid: entry.pid, niceValue: 15),
            successMessage: "Lowered priority of \(entry.name) (nice +15)"
        )
    }

    public func showToast(_ message: String, isError: Bool = false) {
        toast = ActionToast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            if !Task.isCancelled {
                self?.toast = nil
            }
        }
    }

    private func handleActionResult(_ result: Result<Void, ProcessActionError>, successMessage: String) {
        switch result {
        case .success:
            showToast(successMessage, isError: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.triggerSample(forceFullScan: true)
            }
        case .failure(let error):
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Thermal State & Event Tracking

    private func handleThermalStateNotification() {
        let newLevel = ThermalLevel(state: ProcessInfo.processInfo.thermalState)
        let escalated = newLevel > thermalLevel
        thermalLevel = newLevel
        if escalated {
            triggerSample(forceFullScan: true)
        }
    }

    private func updateThermalEvents(now: Date) {
        let currentThermal = ThermalLevel(state: ProcessInfo.processInfo.thermalState)
        thermalLevel = currentThermal

        let highCPU = systemCPU.total >= alertThresholdPercent
        let highGPU = gpu.deviceUtilizationPercent >= 60.0
        let highTemp = (hardwareThermal.cpuTempC ?? 0) >= 85.0
        let fansSpinningHard = (hardwareThermal.peakFanRPM ?? 0) >= 2000.0

        if highCPU || highGPU {
            if sustainedLoadStart == nil {
                sustainedLoadStart = now
            }
        } else {
            sustainedLoadStart = nil
        }

        let sustainedLoad = sustainedLoadStart.map { now.timeIntervalSince($0) >= 10.0 } ?? false
        let isThermalTriggered = currentThermal >= .warm || highTemp || fansSpinningHard

        if isThermalTriggered || sustainedLoad {
            let culprits = makeCulpritSnapshots()

            if let activeID = activeThermalEventID,
               let idx = thermalEvents.firstIndex(where: { $0.id == activeID }) {
                thermalEvents[idx].peakThermalLevel = max(thermalEvents[idx].peakThermalLevel, currentThermal)
                thermalEvents[idx].peakSystemCPU = max(thermalEvents[idx].peakSystemCPU, systemCPU.total)
                thermalEvents[idx].peakGPU = max(thermalEvents[idx].peakGPU, gpu.deviceUtilizationPercent)
                if let temp = hardwareThermal.cpuTempC {
                    thermalEvents[idx].peakTempC = max(thermalEvents[idx].peakTempC ?? temp, temp)
                }
                if let rpm = hardwareThermal.peakFanRPM {
                    thermalEvents[idx].peakFanRPM = max(thermalEvents[idx].peakFanRPM ?? rpm, rpm)
                }
                if let w = hardwareThermal.systemPowerWatts {
                    thermalEvents[idx].peakWatts = max(thermalEvents[idx].peakWatts ?? w, w)
                }
                if !culprits.isEmpty {
                    thermalEvents[idx].culprits = culprits
                }
            } else {
                let reason: String
                if fansSpinningHard, let rpm = hardwareThermal.peakFanRPM {
                    reason = "Fans spun up to \(Int(rpm)) RPM"
                } else if highTemp, let temp = hardwareThermal.cpuTempC {
                    reason = "CPU die reached \(Int(temp))°C"
                } else if currentThermal >= .warm {
                    reason = "macOS thermal pressure rose to \(currentThermal.label)"
                } else if highGPU {
                    reason = "Sustained GPU load (\(Int(gpu.deviceUtilizationPercent))%)"
                } else {
                    reason = "Sustained CPU load ≥ \(Int(alertThresholdPercent))%"
                }

                let event = ThermalEvent(
                    id: UUID(),
                    startedAt: sustainedLoadStart ?? now,
                    endedAt: nil,
                    peakThermalLevel: currentThermal,
                    peakSystemCPU: systemCPU.total,
                    peakGPU: gpu.deviceUtilizationPercent,
                    peakTempC: hardwareThermal.cpuTempC,
                    peakFanRPM: hardwareThermal.peakFanRPM,
                    peakWatts: hardwareThermal.systemPowerWatts,
                    reason: reason,
                    culprits: culprits
                )
                activeThermalEventID = event.id
                thermalEvents.insert(event, at: 0)
                if thermalEvents.count > 10 {
                    thermalEvents.removeLast(thermalEvents.count - 10)
                }
            }
        } else if let activeID = activeThermalEventID {
            if let idx = thermalEvents.firstIndex(where: { $0.id == activeID }) {
                thermalEvents[idx].endedAt = now
            }
            activeThermalEventID = nil
        }
    }

    private func makeCulpritSnapshots() -> [ThermalCulpritSnapshot] {
        let windowGroups = HeatGrouper.group(
            processes: processes,
            window: .oneMinute,
            totalHeatSeconds: totalHeat1mScore,
            previousOrder: [],
            freezeOrder: false
        )
        return windowGroups.prefix(3).filter { $0.heatSeconds >= 0.5 || $0.liveCPUPercent >= 5.0 }.map { g in
            ThermalCulpritSnapshot(
                id: g.id,
                name: g.name,
                pid: g.representative.pid,
                heatSeconds: g.heatSeconds,
                sharePercent: g.heatSharePercent,
                dominantSource: g.dominantSource,
                executablePath: g.representative.executablePath
            )
        }
    }

    private func recomputeGroups(resetOrder: Bool) {
        if isLiveScrolling && !resetOrder {
            pendingGroupRefreshAfterScroll = true
            return
        }
        let totalHeat = selectedWindow == .fiveMinutes ? totalHeat5mScore : totalHeat1mScore
        let grouped = HeatGrouper.group(
            processes: processes,
            window: selectedWindow,
            totalHeatSeconds: totalHeat,
            previousOrder: resetOrder ? [] : lastGroupOrder,
            freezeOrder: isHoveringList && !resetOrder
        )
        heatGroups = grouped
        if !isHoveringList || resetOrder {
            lastGroupOrder = grouped.map(\.id)
        }
    }

    // MARK: - Adaptive Scheduling

    private func primeBaseline() {
        let cpuSampler = self.cpuSampler
        let gpuSampler = self.gpuSampler
        let smcSampler = self.smcSampler
        let processSampler = self.processSampler
        workerQueue.async { [weak self] in
            _ = cpuSampler.sample()
            let gpuSnap = gpuSampler.sample()
            let smcSnap = smcSampler.sample()
            _ = processSampler.sample(maxResults: 28, includeIdle: false)
            Task { @MainActor [weak self] in
                self?.gpu = gpuSnap
                self?.hardwareThermal = smcSnap
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func rescheduleTimer(immediateSample: Bool) {
        stopTimer()
        guard !isMonitoringPaused else { return }

        let interval: TimeInterval = isPopoverOpen ? 2.0 : 3.0
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        newTimer.tolerance = isPopoverOpen ? 0.2 : 0.8
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer

        if immediateSample {
            triggerSample(forceFullScan: true)
        }
    }

    private func tick() {
        if isPopoverOpen {
            triggerSample(forceFullScan: true)
        } else {
            backgroundTickCounter += 1
            // When closed and cool (CPU < 15%, fans off, Thermal Cool), stretch full scan to every 15s (5th tick)
            // for ~60% lower idle CPU/battery; snap back to 6s whenever warm or active.
            let isQuietAndCool = systemCPU.total < 15.0
                && thermalLevel == .cool
                && !hardwareThermal.fansActive
                && gpu.deviceUtilizationPercent < 10.0
            let fullScanModulo = isQuietAndCool ? 5 : 2
            let shouldFullScan = (backgroundTickCounter % fullScanModulo == 0)
            triggerSample(forceFullScan: shouldFullScan)
        }
    }

    public func triggerSample(forceFullScan: Bool) {
        let cpuSampler = self.cpuSampler
        let gpuSampler = self.gpuSampler
        let smcSampler = self.smcSampler
        let processSampler = self.processSampler
        let threshold = self.alertThresholdPercent
        let isOpen = self.isPopoverOpen
        let currentThermal = ThermalLevel(state: ProcessInfo.processInfo.thermalState)

        workerQueue.async { [weak self] in
            let tCpu0 = CFAbsoluteTimeGetCurrent()
            let cpuSnap = cpuSampler.sample()
            let cpuMs = (CFAbsoluteTimeGetCurrent() - tCpu0) * 1000.0

            let shouldRunHeavySensors = forceFullScan
                || isOpen
                || cpuSnap.total >= min(threshold, 25.0)
                || currentThermal >= .warm

            var gpuSnap: GPUSnapshot? = nil
            var smcSnap: HardwareThermalSnapshot? = nil
            var procResult: ProcessSampler.SampleResult? = nil

            if shouldRunHeavySensors {
                gpuSnap = gpuSampler.sample()
                smcSnap = smcSampler.sample()
                let expectedCoreCPU = cpuSnap.total * Double(cpuSnap.coreCount)
                let sampled = processSampler.sample(
                    maxResults: isOpen ? 28 : 20,
                    includeIdle: isOpen,
                    expectedTotalCoreCPU: expectedCoreCPU
                )
                IconCache.shared.prefetch(entries: sampled.processes)
                procResult = sampled
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemCPU = cpuSnap
                self.cpuHistory.append(cpuSnap.total)
                if self.cpuHistory.count > 36 {
                    self.cpuHistory.removeFirst(self.cpuHistory.count - 36)
                }
                self.lastUpdated = cpuSnap.timestamp

                if let gpuSnap {
                    self.gpu = gpuSnap
                }
                if let smcSnap {
                    self.hardwareThermal = smcSnap
                }
                if let procResult {
                    self.processes = procResult.processes
                    self.totalProcessCount = procResult.totalProcessCount
                    self.totalHeat1mScore = procResult.totalHeat1mScore
                    self.totalHeat5mScore = procResult.totalHeat5mScore
                    self.totalCPUHeat1mSeconds = procResult.totalCPUHeat1mSeconds
                    self.recomputeGroups(resetOrder: false)

                    self.telemetry = SelfTelemetry(
                        selfCPUPercent: procResult.selfCPUPercent,
                        cpuTickMs: cpuMs,
                        gpuTickMs: gpuSnap?.sampleDurationMs ?? 0,
                        smcTickMs: smcSnap?.sampleDurationMs ?? 0,
                        procTickMs: procResult.sampleDurationMs
                    )
                }

                self.updateThermalEvents(now: cpuSnap.timestamp)
            }
        }
    }
}
