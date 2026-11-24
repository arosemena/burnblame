import SwiftUI

/// High-performance grouped row for 120Hz smooth scrolling:
/// - Zero per-row `.onHover` tracking areas (prevents mid-scroll state churn).
/// - Minimal layer tree (no redundant stroke overlays on calm rows).
/// - Pre-cached O(1) icon lookup.
public struct HeatGroupRowView: View {
    public let group: HeatGroup
    public let window: HeatWindow
    public let isExpanded: Bool
    public let onToggleExpand: () -> Void
    public let onInspect: (ProcessEntry) -> Void

    public init(
        group: HeatGroup,
        window: HeatWindow,
        isExpanded: Bool,
        onToggleExpand: @escaping () -> Void,
        onInspect: @escaping (ProcessEntry) -> Void
    ) {
        self.group = group
        self.window = window
        self.isExpanded = isExpanded
        self.onToggleExpand = onToggleExpand
        self.onInspect = onInspect
    }

    private var isMultiMember: Bool {
        group.members.count > 1
    }

    private var accentColor: Color {
        Theme.color(for: group.severity)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Button {
                if isMultiMember {
                    onToggleExpand()
                } else {
                    onInspect(group.representative)
                }
            } label: {
                HStack(spacing: 10) {
                    groupIcon

                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 5) {
                            Text(group.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            if group.members.count > 1 {
                                badge("\(group.members.count)", color: .secondary)
                            }
                            if group.dominantSource == .gpu {
                                badge("GPU", color: .indigo)
                            } else if group.dominantSource == .disk {
                                badge("DISK", color: .teal)
                            }
                            if group.exitedCount > 0 && group.activeCount == 0 {
                                badge("EXITED", color: .orange)
                            } else if group.exitedCount > 0 {
                                badge("+\(group.exitedCount) exited", color: .orange)
                            }
                            if group.members.contains(where: \.isPaused) {
                                badge("PAUSED", color: .purple)
                            }
                        }

                        HStack(spacing: 5) {
                            Text("\(Formatters.heatSeconds(group.cpuHeatSeconds)) CPU")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)

                            if group.gpuHeatSeconds >= 0.2 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("\(Formatters.heatSeconds(group.gpuHeatSeconds)) GPU")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.indigo)
                            } else if group.diskIOBytes >= 10 * 1024 * 1024 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("\(Formatters.memory(group.diskIOBytes)) I/O")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.teal)
                            } else if group.activeCount > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("now \(Formatters.cpu(group.liveCPUPercent))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(group.liveCPUPercent >= 35 ? Theme.color(forCPUPercent: group.liveCPUPercent) : .secondary)
                            } else if let exitedAt = group.representative.exitedAt {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("ended \(Formatters.relativeTime(exitedAt))")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }

                            if group.totalMemoryBytes > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(Formatters.memory(group.totalMemoryBytes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 3.5) {
                        Text(group.heatSharePercent >= 0.5 ? String(format: "%.0f%%", group.heatSharePercent) : "<1%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(group.heatSharePercent >= 12 ? accentColor : .primary)

                        HeatShareBar(fraction: group.heatSharePercent / 100.0, color: accentColor)
                            .frame(width: 52)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isExpanded ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.45))
                        .rotationEffect(.degrees(isMultiMember && isExpanded ? 90 : 0))
                        .animation(.snappy(duration: 0.16), value: isExpanded)
                        .frame(width: 10)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && isMultiMember {
                Divider().opacity(0.35).padding(.horizontal, 10)

                VStack(spacing: 2.5) {
                    ForEach(group.members.prefix(8)) { member in
                        childRow(member)
                    }
                    if group.members.count > 8 {
                        Text("+\(group.members.count - 8) more low-heat processes")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isExpanded
                        ? Color.primary.opacity(0.065)
                        : (group.severity == .critical ? Color.red.opacity(0.08) : Color.primary.opacity(0.032))
                )
        )
    }

    private func childRow(_ member: ProcessEntry) -> some View {
        Button {
            onInspect(member)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(member.isExited ? Color.orange.opacity(0.6) : Theme.color(for: member.severity))
                    .frame(width: 5, height: 5)

                Text(member.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(member.isExited ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("PID \(member.pid)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if member.isExited {
                    badge("exited", color: .orange)
                } else if member.isPaused {
                    badge("paused", color: .purple)
                }

                Spacer()

                Text(Formatters.heatSeconds(member.heatSeconds(for: window)))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)

                if !member.isExited {
                    Text(Formatters.cpu(member.cpuPercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 36, alignment: .trailing)

                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(member.isExited)
    }

    @ViewBuilder
    private var groupIcon: some View {
        let nsImage = IconCache.shared.icon(for: group.representative)
        if group.bundlePath != nil {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(accentColor)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }
}

/// Zero-GeometryReader proportional bar for 0...1 heat share.
public struct HeatShareBar: View {
    public let fraction: Double
    public let color: Color

    public var body: some View {
        let clamped = CGFloat(min(1.0, max(0.04, fraction)))
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(color)
                .scaleEffect(x: clamped, y: 1.0, anchor: .leading)
        }
        .frame(height: 4.5)
    }
}
