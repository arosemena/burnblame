import SwiftUI

public struct PopoverRootView: View {
    @Bindable public var engine: MonitorEngine
    @State private var expandedGroupIDs: Set<String> = []
    @State private var showQuietApps = false

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
        .frame(width: 406, height: 550)
        .animation(.snappy(duration: 0.2), value: engine.selectedPID)
        .animation(.easeOut(duration: 0.16), value: engine.toast)
    }

    private var overviewView: some View {
        VStack(spacing: 0) {
            // Isolated child view so CPU/SMC/sparkline ticks NEVER invalidate the ScrollView below!
            ThermalHeroHeaderView(engine: engine)
            Divider().opacity(0.45)

            if let activeEvent = engine.thermalEvents.first(where: \.isOngoing),
               let top = activeEvent.culprits.first {
                activeHeatBanner(event: activeEvent, topCulprit: top)
            }

            windowAndSearchBar

            if engine.selectedWindow == .events {
                ThermalEventsView(events: engine.thermalEvents) { pid in
                    engine.selectProcessByPID(pid)
                }
            } else {
                HeatGroupListSection(
                    engine: engine,
                    expandedGroupIDs: $expandedGroupIDs,
                    showQuietApps: $showQuietApps
                )
            }

            Divider().opacity(0.45)
            FooterBarView(engine: engine)
        }
    }

    private func activeHeatBanner(event: ThermalEvent, topCulprit: ThermalCulpritSnapshot) -> some View {
        Button {
            engine.selectProcessByPID(topCulprit.pid)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Heat Driver: \(topCulprit.name) (\(String(format: "%.0f%%", topCulprit.sharePercent)) of heat)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(event.reason) · \(Formatters.duration(event.duration)) — click to inspect")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.12))
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundStyle(Color.orange.opacity(0.25)),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    private var windowAndSearchBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                ForEach(HeatWindow.allCases, id: \.self) { tab in
                    let isSelected = engine.selectedWindow == tab
                    Button {
                        engine.selectedWindow = tab
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            if tab == .events && !engine.thermalEvents.isEmpty {
                                Text("\(engine.thermalEvents.count)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.22)))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 8)
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

            if engine.selectedWindow != .events {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Filter by app, helper, or PID…", text: $engine.searchQuery)
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
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

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

// MARK: - Isolated Hero Header Subview

private struct ThermalHeroHeaderView: View {
    let engine: MonitorEngine

    var body: some View {
        let thermalColor = Theme.color(for: engine.thermalLevel)
        let hw = engine.hardwareThermal

        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: engine.thermalLevel.symbolName)
                                .font(.system(size: 10.5, weight: .bold))
                            Text(engine.thermalLevel.label)
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(thermalColor.opacity(0.16)))
                        .foregroundStyle(thermalColor)

                        if let watts = hw.systemPowerWatts {
                            HStack(spacing: 2.5) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9))
                                Text(String(format: "%.1fW", watts))
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(watts >= 30 ? .orange : .secondary)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.0f%%", engine.systemCPU.total))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Theme.color(for: engine.menuBarSeverity))
                            Text("CPU")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.0f%%", engine.gpu.deviceUtilizationPercent))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(engine.gpu.deviceUtilizationPercent >= 40 ? .indigo : .primary.opacity(0.8))
                            Text("GPU")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                SparklineView(
                    values: engine.cpuHistory,
                    maxValue: 100.0,
                    accentColor: Theme.color(for: engine.menuBarSeverity)
                )
                .frame(width: 152, height: 50)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }

            HStack(spacing: 6) {
                if let cpuC = hw.cpuTempC {
                    sensorPill(
                        icon: "thermometer.medium",
                        label: "CPU",
                        value: "\(Int(cpuC.rounded()))°C",
                        tint: cpuC >= 85 ? .red : (cpuC >= 70 ? .orange : .secondary)
                    )
                }
                if let gpuC = hw.gpuTempC {
                    sensorPill(
                        icon: "square.stack.3d.up.fill",
                        label: "GPU",
                        value: "\(Int(gpuC.rounded()))°C",
                        tint: gpuC >= 80 ? .red : (gpuC >= 65 ? .orange : .secondary)
                    )
                }
                if let rpm = hw.peakFanRPM {
                    sensorPill(
                        icon: "fanblades.fill",
                        label: rpm >= 100 ? "\(Int(rpm.rounded())) RPM" : "Fans off",
                        value: "",
                        tint: rpm >= 2500 ? .orange : (rpm >= 100 ? .cyan : .secondary)
                    )
                }
                Spacer(minLength: 0)
                Text(String(format: "1m avg %.0f%%", engine.avgLoad1mPercent))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func sensorPill(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(value.isEmpty ? label : "\(label) \(value)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint == .secondary ? .primary.opacity(0.85) : tint)
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Isolated Scrollable Heat List Subview

private struct HeatGroupListSection: View {
    let engine: MonitorEngine
    @Binding var expandedGroupIDs: Set<String>
    @Binding var showQuietApps: Bool

    var body: some View {
        let allItems = engine.filteredHeatGroups
        let isSearching = !engine.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let significantItems: [HeatGroup]
        let quietCount: Int
        if isSearching || showQuietApps {
            significantItems = allItems
            quietCount = 0
        } else {
            let filtered = allItems.filter { group in
                group.heatSharePercent >= 1.0
                    || group.heatSeconds >= 0.35
                    || group.liveCPUPercent >= 3.0
                    || group.members.contains(where: \.isPaused)
            }
            // Always show at least the top 5 rows even on a completely idle Mac
            if filtered.count >= 5 || allItems.count <= 5 {
                significantItems = filtered.isEmpty ? Array(allItems.prefix(5)) : filtered
            } else {
                significantItems = Array(allItems.prefix(5))
            }
            quietCount = max(0, allItems.count - significantItems.count)
        }

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(engine.selectedWindow == .oneMinute ? "HEAT CULPRITS · LAST 1M" : "HEAT CULPRITS · LAST 5M")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)

                Spacer()

                if engine.isHoveringList {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                        Text("Order pinned")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                } else {
                    Text("% of heat")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            if significantItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.green)
                    Text("No Matching Culprits")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Try clearing the search or showing system processes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    // Use plain VStack instead of LazyVStack: with ~8-20 rows, all rows stay laid out
                    // once so trackpad scrolling is pure GPU translation with zero mid-scroll view creation!
                    VStack(spacing: 5) {
                        ForEach(significantItems) { group in
                            HeatGroupRowView(
                                group: group,
                                window: engine.selectedWindow,
                                isExpanded: expandedGroupIDs.contains(group.id),
                                onToggleExpand: {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        if expandedGroupIDs.contains(group.id) {
                                            expandedGroupIDs.remove(group.id)
                                        } else {
                                            expandedGroupIDs.insert(group.id)
                                        }
                                    }
                                },
                                onInspect: { entry in
                                    engine.selectProcess(entry)
                                }
                            )
                        }

                        if !isSearching && (quietCount > 0 || showQuietApps) {
                            Button {
                                showQuietApps.toggle()
                            } label: {
                                Text(showQuietApps ? "Hide quiet apps (<1%)" : "Show \(quietCount) quiet apps (<1%)")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.03)))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .onHover { hovering in
                    engine.isHoveringList = hovering
                }
            }
        }
    }
}

// MARK: - Isolated Footer Subview

private struct FooterBarView: View {
    @Bindable var engine: MonitorEngine
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.isMonitoringPaused ? Color.orange : Color.green)
                    .frame(width: 6.5, height: 6.5)
                Text(
                    engine.isMonitoringPaused
                        ? "Paused"
                        : String(format: "Watcher: %.1f%% · %.1fms/tick", engine.selfCPUPercent, engine.telemetry.totalTickMs)
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

            Toggle("Hide macOS system daemons", isOn: $engine.hideSystemProcesses)
                .font(.system(size: 11.5))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Heat event CPU threshold")
                        .font(.system(size: 11.5))
                    Spacer()
                    Text("\(Int(engine.alertThresholdPercent))%")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $engine.alertThresholdPercent, in: 20...85, step: 5)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 3) {
                Text("SAMPLER OVERHEAD (LAST TICK)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                let t = engine.telemetry
                Text(String(
                    format: "CPU %.2fms · GPU %.1fms · SMC %.1fms · Procs %.1fms",
                    t.cpuTickMs, t.gpuTickMs, t.smcTickMs, t.procTickMs
                ))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Text("Ranks apps by unified heat (CPU + 1.5× GPU + Disk I/O) over 1m / 5m. Heavy sensors pause to 6s cadence when closed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
    }
}
