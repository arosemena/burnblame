import AppKit
import Foundation
import Observation

public struct ActionToast: Equatable, Sendable {
    public let message: String
    public let isError: Bool
}

public enum ProcessFilterMode: String, CaseIterable, Sendable {
    case highLoad = "High CPU"
    case allActive = "All Active"
    case userOnly = "My Apps"
}

/// Adaptive monitoring coordinator.
/// - Closed popover: samples only `host_statistics` every 3s, scanning processes only on CPU spikes or every ~12s.
/// - Open popover: samples every 1.5s for live updates and sparklines.
@MainActor
@Observable
public final class MonitorEngine {
    public private(set) var systemCPU: SystemCPUSnapshot = .zero
    public private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 32)
    public private(set) var processes: [ProcessEntry] = []
    public private(set) var selfCPUPercent: Double = 0
    public private(set) var totalProcessCount: Int = 0
    public private(set) var lastUpdated: Date = Date()

    public var isPopoverOpen: Bool = false {
        didSet {
            if isPopoverOpen != oldValue {
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

    public var filterMode: ProcessFilterMode = .allActive
    public var searchQuery: String = ""

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
    private var toastTask: Task<Void, Never>?

    public init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showPercentInMenuBar") == nil {
            self.showPercentInMenuBar = true
        } else {
            self.showPercentInMenuBar = defaults.bool(forKey: "showPercentInMenuBar")
        }
        let storedThreshold = defaults.double(forKey: "alertThresholdPercent")
        self.alertThresholdPercent = storedThreshold > 0 ? storedThreshold : 35.0

        // Prime initial baseline immediately so first open has real deltas
        primeBaseline()
        rescheduleTimer(immediateSample: false)
    }

    public var filteredProcesses: [ProcessEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return processes.filter { proc in
            switch filterMode {
            case .highLoad:
                if proc.cpuPercent < 5.0 && !proc.isPaused { return false }
            case .userOnly:
                if proc.isSystemProcess { return false }
            case .allActive:
                break
            }

            if !query.isEmpty {
                let matchesName = proc.name.lowercased().contains(query)
                let matchesRaw = proc.rawName.lowercased().contains(query)
                let matchesPID = String(proc.pid).contains(query)
                let matchesParent = proc.parentName?.lowercased().contains(query) ?? false
                return matchesName || matchesRaw || matchesPID || matchesParent
            }
            return true
        }
    }

    public var selectedProcess: ProcessEntry? {
        guard let pid = selectedPID else { return nil }
        return processes.first { $0.pid == pid }
    }

    public var topOffender: ProcessEntry? {
        processes.first { $0.cpuPercent >= 20.0 }
    }

    public var hasRunawayProcess: Bool {
        processes.contains { $0.cpuPercent >= 75.0 && $0.sustainedHighDuration != nil }
    }

    public var menuBarSeverity: CPUSeverity {
        if hasRunawayProcess || systemCPU.total >= 80 {
            return .critical
        }
        if systemCPU.total >= alertThresholdPercent || (topOffender?.cpuPercent ?? 0) >= 60 {
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

    public func refreshInspection() {
        guard let entry = selectedProcess else { return }
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
            // Trigger quick refresh to reflect state change
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.triggerSample(forceProcessScan: true)
            }
        case .failure(let error):
            showToast(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Adaptive Scheduling

    private func primeBaseline() {
        let cpuSampler = self.cpuSampler
        let processSampler = self.processSampler
        workerQueue.async {
            _ = cpuSampler.sample()
            _ = processSampler.sample(maxResults: 1, includeIdle: false)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func rescheduleTimer(immediateSample: Bool) {
        stopTimer()
        guard !isMonitoringPaused else { return }

        let interval: TimeInterval = isPopoverOpen ? 1.5 : 3.0
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        // Allow macOS timer coalescing when closed for even better battery efficiency!
        newTimer.tolerance = isPopoverOpen ? 0.15 : 0.8
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
            let shouldPeriodicScan = (backgroundTickCounter % 4 == 0)
            triggerSample(forceProcessScan: shouldPeriodicScan)
        }
    }

    public func triggerSample(forceProcessScan: Bool) {
        let cpuSampler = self.cpuSampler
        let processSampler = self.processSampler
        let threshold = self.alertThresholdPercent
        let isOpen = self.isPopoverOpen

        workerQueue.async { [weak self] in
            let cpuSnap = cpuSampler.sample()
            let shouldScanProcesses = forceProcessScan || isOpen || cpuSnap.total >= threshold

            var procResult: ProcessSampler.SampleResult? = nil
            if shouldScanProcesses {
                procResult = processSampler.sample(
                    maxResults: isOpen ? 30 : 8,
                    includeIdle: isOpen
                )
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

                    // If selected process exited, keep inspection visible with a subtle notice or clear?
                    // Keeping selectedInspection while selectedProcess is nil lets the view show "Exited".
                }
            }
        }
    }
}
