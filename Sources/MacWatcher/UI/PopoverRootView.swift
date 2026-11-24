import SwiftUI

public struct PopoverRootView: View {
    @Bindable public var engine: MonitorEngine
    @State private var showingSettings = false

    public init(engine: MonitorEngine) {
        self.engine = engine
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if engine.selectedPID != nil {
                    ProcessInspectorView(engine: engine)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    overviewView
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }

            if let toast = engine.toast {
                toastBanner(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 46)
                    .padding(.horizontal, 14)
            }
        }
        .frame(width: 400, height: 540)
        .animation(.snappy(duration: 0.22), value: engine.selectedPID)
        .animation(.easeOut(duration: 0.18), value: engine.toast)
    }

    // MARK: - Overview View

    private var overviewView: some View {
        VStack(spacing: 0) {
            heroHeader
            Divider().opacity(0.45)

            if let runaway = engine.processes.first(where: { $0.cpuPercent >= 70 && $0.sustainedHighDuration != nil }) {
                runawayBanner(runaway)
            }

            filterAndSearchBar

            processList

            Divider().opacity(0.45)
            footerBar
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.0f%%", engine.systemCPU.total))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.color(for: engine.menuBarSeverity))
                        .contentTransition(.numericText())

                    Text("CPU")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    statDot(color: .cyan, label: "User", value: String(format: "%.0f%%", engine.systemCPU.user))
                    statDot(color: .orange, label: "Sys", value: String(format: "%.0f%%", engine.systemCPU.system))
                }

                Text("\(engine.systemCPU.coreCount) cores · \(engine.totalProcessCount) procs")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // Live System Sparkline
            VStack(alignment: .trailing, spacing: 4) {
                SparklineView(
                    values: engine.cpuHistory,
                    maxValue: 100.0,
                    accentColor: Theme.color(for: engine.menuBarSeverity)
                )
                .frame(width: 170, height: 54)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func statDot(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 3.5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Runaway Alert Banner

    private func runawayBanner(_ proc: ProcessEntry) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                engine.selectProcess(proc)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Sustained High Load: \(proc.name)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let dur = proc.sustainedHighDuration {
                        Text("\(Formatters.cpu(proc.cpuPercent)) for \(Formatters.duration(dur)) — click to inspect")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.11))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Color.red.opacity(0.25)),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter & Search

    private var filterAndSearchBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(ProcessFilterMode.allCases, id: \.self) { mode in
                    let isSelected = engine.filterMode == mode
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            engine.filterMode = mode
                        }
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter by name, parent, or PID…", text: $engine.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))

                if !engine.searchQuery.isEmpty {
                    Button {
                        engine.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Process List

    private var processList: some View {
        let items = engine.filteredProcesses
        return Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: engine.filterMode == .highLoad ? "checkmark.seal.fill" : "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(engine.filterMode == .highLoad ? .green : .secondary)
                    Text(engine.filterMode == .highLoad ? "All Quiet!" : "No Matching Processes")
                        .font(.system(size: 13, weight: .semibold))
                    Text(
                        engine.filterMode == .highLoad
                            ? "No processes are currently above 5% CPU."
                            : "Try clearing the search or switching filters."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 5) {
                        ForEach(items) { proc in
                            ProcessRowView(
                                entry: proc,
                                coreCount: engine.systemCPU.coreCount
                            ) {
                                withAnimation(.snappy(duration: 0.22)) {
                                    engine.selectProcess(proc)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.isMonitoringPaused ? Color.orange : Color.green)
                    .frame(width: 6.5, height: 6.5)
                Text(
                    engine.isMonitoringPaused
                        ? "Paused"
                        : String(format: "Watcher: %.1f%% CPU", engine.selfCPUPercent)
                )
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                engine.isMonitoringPaused.toggle()
            } label: {
                Image(systemName: engine.isMonitoringPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help(engine.isMonitoringPaused ? "Resume live monitoring" : "Pause live monitoring")

            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Preferences")
            .popover(isPresented: $showingSettings, arrowEdge: .top) {
                settingsPopover
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Quit MacWatcher")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacWatcher Settings")
                .font(.system(size: 12.5, weight: .bold))

            Toggle("Show CPU % in menu bar", isOn: $engine.showPercentInMenuBar)
                .font(.system(size: 11.5))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Alert threshold")
                        .font(.system(size: 11.5))
                    Spacer()
                    Text("\(Int(engine.alertThresholdPercent))%")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $engine.alertThresholdPercent, in: 15...85, step: 5)
            }

            Text("When closed, MacWatcher uses minimal Mach host ticks every 3s and only scans processes on spikes.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 240)
    }

    // MARK: - Toast

    private func toastBanner(_ toast: ActionToast) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(toast.isError ? .red : .green)
            Text(toast.message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(toast.isError ? Color.red.opacity(0.4) : Color.primary.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}
