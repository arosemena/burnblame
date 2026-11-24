import AppKit
import Foundation
import Observation

public struct ActionToast: Equatable, Sendable {
    public let message: String
    public let isError: Bool
}

/// Adaptive thermal & process monitoring coordinator.
/// - Tracks macOS `ProcessInfo.thermalState` + rolling 1m / 5m CPU-seconds heat ledger.
/// - Automatically logs Thermal Events whenever thermal pressure escalates or sustained high load occurs.
/// - Groups helpers under their parent app and stabilizes ordering with hysteresis + hover-freeze.
@MainActor
@Observable
public final class MonitorEngine {
    public private(set) var systemCPU: SystemCPUSnapshot = .zero
    public private(set) var thermalLevel: ThermalLevel = ThermalLevel(state: ProcessInfo.processInfo.thermalState)
    public private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 32)
    public private(set) var processes: [ProcessEntry] = []
    public private(set) var heatGroups: [HeatGroup] = []
    public private(set) var totalHeat1mSeconds: Double = 0
    public private(set) var totalHeat5mSeconds: Double = 0
    public private(set) var thermalEvents: [ThermalEvent] = []
    public private(set) var selfCPUPercent: Double = 0
    public private(set) var totalProcessCount: Int = 0
    public private(set) var lastUpdated: Date = Date()

    public var selectedWindow: HeatWindow = .oneMinute {
        didSet {
            if selectedWindow != oldValue {
                recomputeGroups(resetOrder: true)
            }
        }
    }

    public var isHoveringList: Bool = false
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
    private let processSampler = ProcessSampler()
    private let inspector = ProcessInspector()
    private let workerQueue = DispatchQueue(label: "com.macwatcher.sampler", qos: .utility)

    private var timer: Timer?
    private var backgroundTickCounter: Int = 0
    private var sustainedLoadStart: Date?
    private var activeThermalEventID: UUID?
    private var lastGroupOrder: [String] = []
    private var toastTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?

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

        // Listen for instant macOS thermal pressure changes (zero polling cost!)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThermalStateNotification()
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

    public var topHeatCulprit: HeatGroup? {
        heatGroups.first { $0.heatSeconds >= 8.0 || $0.heatSharePercent >= 25.0 }
    }

    public var avgLoad1mPercent: Double {
        let cores = Double(max(1, systemCPU.coreCount))
        return min(100.0, (totalHeat1mSeconds / (60.0 * cores)) * 100.0)
    }

    public var menuBarSeverity: CPUSeverity {
        if thermalLevel >= .hot || systemCPU.total >= 80 {
            return .critical
        }
        if thermalLevel == .warm || systemCPU.total >= alertThresholdPercent {
            return .elevated
        }
        if systemCPU.total >= 15 {
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
        workerQueue.async { [weak self] in
            let details = inspector.inspect(entry: entry)
            Task { @MainActor [weak self] in
                guard let self, self.selectedPID == entry.pid else { return }
                self.selectedInspection = details
                self.isLoadingInspection = false
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
                self?.triggerSample(forceProcessScan: true)
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
            // Immediately scan processes so we capture who caused the thermal jump!
            triggerSample(forceProcessScan: true)
        }
    }

    private func updateThermalEvents(now: Date) {
        let currentThermal = ThermalLevel(state: ProcessInfo.processInfo.thermalState)
        thermalLevel = currentThermal

        let isHighCPU = systemCPU.total >= alertThresholdPercent
        if isHighCPU {
            if sustainedLoadStart == nil {
                sustainedLoadStart = now
            }
        } else {
            sustainedLoadStart = nil
        }

        let sustainedHigh = sustainedLoadStart.map { now.timeIntervalSince($0) >= 10.0 } ?? false
        let isThermalElevated = currentThermal >= .warm

        if isThermalElevated || sustainedHigh {
            let culprits = makeCulpritSnapshots()

            if let activeID = activeThermalEventID,
               let idx = thermalEvents.firstIndex(where: { $0.id == activeID }) {
                thermalEvents[idx].peakThermalLevel = max(thermalEvents[idx].peakThermalLevel, currentThermal)
                thermalEvents[idx].peakSystemCPU = max(thermalEvents[idx].peakSystemCPU, systemCPU.total)
                if !culprits.isEmpty {
                    thermalEvents[idx].culprits = culprits
                }
            } else {
                let reason = isThermalElevated
                    ? "macOS thermal pressure rose to \(currentThermal.label)"
                    : "Sustained CPU load ≥ \(Int(alertThresholdPercent))%"
                let event = ThermalEvent(
                    id: UUID(),
                    startedAt: sustainedLoadStart ?? now,
                    endedAt: nil,
                    peakThermalLevel: currentThermal,
                    peakSystemCPU: systemCPU.total,
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
            totalHeatSeconds: totalHeat1mSeconds,
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
                executablePath: g.representative.executablePath
            )
        }
    }

    private func recomputeGroups(resetOrder: Bool) {
        let totalHeat = selectedWindow == .fiveMinutes ? totalHeat5mSeconds : totalHeat1mSeconds
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
        let processSampler = self.processSampler
        workerQueue.async {
            _ = cpuSampler.sample()
            _ = processSampler.sample(maxResults: 40, includeIdle: false)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func rescheduleTimer(immediateSample: Bool) {
        stopTimer()
        guard !isMonitoringPaused else { return }

        // Open: 2.0s calm live cadence; Closed: 3.0s micro-tick
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
            triggerSample(forceProcessScan: true)
        }
    }

    private func tick() {
        if isPopoverOpen {
            triggerSample(forceProcessScan: true)
        } else {
            backgroundTickCounter += 1
            // Even when closed, scan processes every ~6s (every 2nd tick) or immediately on load/thermal spikes
            // so the 1m & 5m heat ledger is always accurate the moment you hear the fans!
            let shouldPeriodicScan = (backgroundTickCounter % 2 == 0)
            triggerSample(forceProcessScan: shouldPeriodicScan)
        }
    }

    public func triggerSample(forceProcessScan: Bool) {
        let cpuSampler = self.cpuSampler
        let processSampler = self.processSampler
        let threshold = self.alertThresholdPercent
        let isOpen = self.isPopoverOpen
        let currentThermal = ThermalLevel(state: ProcessInfo.processInfo.thermalState)

        workerQueue.async { [weak self] in
            let cpuSnap = cpuSampler.sample()
            let shouldScanProcesses = forceProcessScan
                || isOpen
                || cpuSnap.total >= min(threshold, 25.0)
                || currentThermal >= .warm

            var procResult: ProcessSampler.SampleResult? = nil
            if shouldScanProcesses {
                let sampled = processSampler.sample(
                    maxResults: isOpen ? 60 : 30,
                    includeIdle: isOpen
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

                if let procResult {
                    self.processes = procResult.processes
                    self.selfCPUPercent = procResult.selfCPUPercent
                    self.totalProcessCount = procResult.totalProcessCount
                    self.totalHeat1mSeconds = procResult.totalHeat1mSeconds
                    self.totalHeat5mSeconds = procResult.totalHeat5mSeconds
                    self.recomputeGroups(resetOrder: false)
                }

                self.updateThermalEvents(now: cpuSnap.timestamp)
            }
        }
    }
}
