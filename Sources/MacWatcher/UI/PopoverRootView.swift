import SwiftUI

public struct PopoverRootView: View {
    @Bindable public var engine: MonitorEngine
    @State private var showingSettings = false
    @State private var expandedGroupIDs: Set<String> = []

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

    // MARK: - Overview View

    private var overviewView: some View {
        VStack(spacing: 0) {
            thermalHeroHeader
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
                heatGroupList
            }

            Divider().opacity(0.45)
            footerBar
        }
    }

    // MARK: - Thermal Hero Header

    private var thermalHeroHeader: some View {
        let thermalColor = Theme.color(for: engine.thermalLevel)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                // Thermal State Pill
                HStack(spacing: 5) {
                    Image(systemName: engine.thermalLevel.symbolName)
                        .font(.system(size: 11, weight: .bold))
                    Text("Thermal: \(engine.thermalLevel.label)")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(thermalColor.opacity(0.16)))
                .foregroundStyle(thermalColor)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f%%", engine.systemCPU.total))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.color(for: engine.menuBarSeverity))
                        .contentTransition(.numericText())

                    VStack(alignment: .leading, spacing: 1) {
                        Text("live load")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(String(format: "1m avg %.0f%%", engine.avgLoad1mPercent))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(engine.systemCPU.coreCount) cores · \(Formatters.heatSeconds(engine.totalHeat1mSeconds)) burned / 1m")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            SparklineView(
                values: engine.cpuHistory,
                maxValue: 100.0,
                accentColor: Theme.color(for: engine.menuBarSeverity)
            )
            .frame(width: 164, height: 58)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Active Heat Banner

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

    // MARK: - Window Tabs & Search

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

    // MARK: - Grouped Heat List (Hover-Frozen!)

    private var heatGroupList: some View {
        let items = engine.filteredHeatGroups

        return VStack(spacing: 0) {
            // Subtle column header + hover-pin indicator
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

            if items.isEmpty {
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
                    LazyVStack(spacing: 5) {
                        ForEach(items) { group in
                            HeatGroupRowView(
                                group: group,
                                window: engine.selectedWindow,
                                isExpanded: expandedGroupIDs.contains(group.id),
                                onToggleExpand: {
                                    if expandedGroupIDs.contains(group.id) {
                                        expandedGroupIDs.remove(group.id)
                                    } else {
                                        expandedGroupIDs.insert(group.id)
                                    }
                                },
                                onInspect: { entry in
                                    engine.selectProcess(entry)
                                }
                            )
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

            Text("Ranks apps by rolling CPU-seconds burned (heat) over 1m / 5m and logs thermal pressure spikes.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
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
