import SwiftUI

public struct ProcessInspectorView: View {
    @Bindable public var engine: MonitorEngine
    @State private var confirmingForceQuit = false

    public init(engine: MonitorEngine) {
        self.engine = engine
    }

    private var entry: ProcessEntry? {
        engine.selectedProcess
    }

    private var inspection: ProcessInspection? {
        engine.selectedInspection
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Navigation Bar
            headerBar

            Divider().opacity(0.5)

            if let entry {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 11) {
                        telemetryCard(entry: entry)
                        originForensicsCard(entry: entry)
                        commandLineCard
                        if let ports = inspection?.listeningPorts, !ports.isEmpty {
                            listeningPortsCard(ports: ports)
                        }
                        if entry.isSystemProcess {
                            systemWarningBanner
                        }
                    }
                    .padding(12)
                }

                Divider().opacity(0.5)
                actionBar(entry: entry)
            } else {
                processExitedState
            }
        }
        .onChange(of: engine.selectedPID) { _, _ in
            confirmingForceQuit = false
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    engine.clearSelection()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Spacer()

            if let entry {
                Text("PID \(entry.pid)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    engine.refreshInspection()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Re-inspect process details")

                if let entry {
                    Button {
                        ProcessController.copyDiagnostics(entry: entry, inspection: inspection)
                        engine.showToast("Copied diagnostics to clipboard")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Copy full process diagnostics")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Telemetry Card

    private func telemetryCard(entry: ProcessEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                let nsImage = IconCache.shared.icon(for: entry)
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        statePill(entry.state)
                        if let user = inspection?.username {
                            Text(user)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if let start = entry.startTime {
                            Text("· Up \(Formatters.duration(Date().timeIntervalSince(start)))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(Formatters.cpu(entry.cpuPercent))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.color(forCPUPercent: entry.cpuPercent))
                        .contentTransition(.numericText())

                    if entry.cpuPercent >= 100 {
                        Text(String(format: "~%.1f cores", entry.cpuPercent / 100.0))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("CPU Load")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Per-process live sparkline
            SparklineView(
                values: entry.cpuHistory.count >= 2 ? entry.cpuHistory : [0, entry.cpuPercent],
                maxValue: max(100.0, entry.peakCPUPercent * 1.15),
                accentColor: Theme.color(forCPUPercent: entry.cpuPercent)
            )
            .frame(height: 36)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.03)))

            // Compact 4-metric grid
            HStack(spacing: 8) {
                metricCell(label: "Peak CPU", value: Formatters.cpu(entry.peakCPUPercent))
                metricCell(label: "Memory", value: Formatters.memory(inspection?.physicalFootprintBytes ?? entry.memoryBytes))
                metricCell(label: "Threads", value: "\(entry.threadCount)")
                metricCell(label: "Nice", value: entry.niceValue > 0 ? "+\(entry.niceValue)" : "\(entry.niceValue)")
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
    }

    private func statePill(_ state: ProcessRunState) -> some View {
        let color: Color = {
            switch state {
            case .running: return .green
            case .sleeping: return .secondary
            case .stopped: return .purple
            case .zombie: return .red
            case .unknown: return .secondary
            }
        }()
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5.5, height: 5.5)
            Text(state.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: - Forensic Origin Card

    private func originForensicsCard(entry: ProcessEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Where It Came From", systemImage: "magnifyingglass.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if engine.isLoadingInspection {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let inspection {
                // Launch Origin
                HStack(spacing: 7) {
                    Image(systemName: inspection.launchOrigin.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.12)))

                    Text(inspection.launchOrigin.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if case .launchAgent(_, let plistPath) = inspection.launchOrigin {
                        revealButton(label: "Plist", path: plistPath)
                    } else if case .launchDaemon(_, let plistPath) = inspection.launchOrigin {
                        revealButton(label: "Plist", path: plistPath)
                    } else if case .application(_, let bundlePath) = inspection.launchOrigin {
                        revealButton(label: "App", path: bundlePath)
                    }
                }

                // Parent Ancestry Breadcrumbs
                if !inspection.parentChain.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LAUNCH CHAIN")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(inspection.parentChain) { ancestor in
                                    Text(ancestor.name)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2.5)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(entry.name)
                                    .font(.system(size: 10.5, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }

                // Working Directory
                if let cwd = inspection.workingDirectory {
                    pathRow(
                        label: "WORKING DIRECTORY",
                        path: cwd,
                        actionTitle: "Open",
                        onAction: { ProcessController.openFolder(path: cwd) }
                    )
                }

                // Executable Path
                if let execPath = inspection.executablePath {
                    pathRow(
                        label: "EXECUTABLE",
                        path: execPath,
                        actionTitle: "Reveal",
                        onAction: { ProcessController.revealInFinder(path: execPath) }
                    )
                }

                // Extra small stats
                HStack(spacing: 12) {
                    Label("\(inspection.openFileCount) open files", systemImage: "doc.text")
                    Label("\(inspection.idleWakeups) wakeups", systemImage: "bolt")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                Text("Inspecting launch origin, ancestry, and working directory…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    private func pathRow(label: String, path: String, actionTitle: String, onAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Button(actionTitle, action: onAction)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            Text(Formatters.shortenedPath(path))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func revealButton(label: String, path: String) -> some View {
        Button {
            ProcessController.revealInFinder(path: path)
        } label: {
            Label(label, systemImage: "folder")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Command Line Card

    private var commandLineCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("LAUNCH COMMAND")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                if let cmd = inspection?.formattedCommand {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        engine.showToast("Copied command line")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(inspection?.formattedCommand ?? "Loading…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.14)))
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    // MARK: - Listening Ports

    private func listeningPortsCard(ports: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Listening Network Ports", systemImage: "network")
                .font(.system(size: 11, weight: .semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(ports, id: \.self) { port in
                        Text(port)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.teal.opacity(0.16)))
                            .foregroundStyle(.teal)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }

    // MARK: - System Warning

    private var systemWarningBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text("System-owned process. Stopping it may require privileges or affect macOS stability.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    // MARK: - Action Bar

    private func actionBar(entry: ProcessEntry) -> some View {
        HStack(spacing: 7) {
            // Pause / Resume
            Button {
                engine.performTogglePause(entry: entry)
            } label: {
                Label(entry.isPaused ? "Resume" : "Pause", systemImage: entry.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.purple.opacity(0.15)))
                    .foregroundStyle(.purple)
            }
            .buttonStyle(.plain)
            .help(entry.isPaused ? "Resume process (SIGCONT)" : "Freeze process without killing (SIGSTOP)")

            // Throttle
            Button {
                engine.performThrottle(entry: entry)
            } label: {
                Label("Throttle", systemImage: "tortoise.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("Lower CPU scheduling priority (nice +15)")

            // Quit (SIGTERM)
            Button {
                engine.performTerminate(pid: entry.pid, name: entry.name)
            } label: {
                Label("Quit", systemImage: "xmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Request graceful exit (SIGTERM)")

            // Force Quit (SIGKILL) with two-step confirmation
            Button {
                if confirmingForceQuit {
                    confirmingForceQuit = false
                    engine.performForceQuit(pid: entry.pid, name: entry.name)
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        confirmingForceQuit = true
                    }
                }
            } label: {
                Label(confirmingForceQuit ? "Confirm?" : "Kill", systemImage: "bolt.slash.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(confirmingForceQuit ? Color.red : Color.red.opacity(0.16))
                    )
                    .foregroundStyle(confirmingForceQuit ? .white : .red)
            }
            .buttonStyle(.plain)
            .help("Force terminate immediately (SIGKILL)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var processExitedState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text("Process Exited")
                .font(.system(size: 14, weight: .semibold))
            Text("This process is no longer running.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Return to List") {
                engine.clearSelection()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
