import SwiftUI

public struct ProcessRowView: View {
    public let entry: ProcessEntry
    public let coreCount: Int
    public let onSelect: () -> Void

    @State private var isHovered = false

    public init(entry: ProcessEntry, coreCount: Int, onSelect: @escaping () -> Void) {
        self.entry = entry
        self.coreCount = coreCount
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // App / Process Icon
                processIcon

                // Name + Metadata
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 5) {
                        Text(entry.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if entry.isPaused {
                            statusBadge("PAUSED", color: .purple)
                        } else if let sustained = entry.sustainedHighDuration {
                            statusBadge("HIGH \(Formatters.duration(sustained))", color: Theme.color(for: entry.severity))
                        }
                    }

                    HStack(spacing: 5) {
                        Text("PID \(entry.pid)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if let parent = entry.parentName, !parent.isEmpty, parent != "launchd" {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("via \(parent)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if entry.isSystemProcess {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("System")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 4)

                // CPU Metric + Bar + Memory
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(Formatters.cpu(entry.cpuPercent))
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(entry.cpuPercent >= 12 ? Theme.color(forCPUPercent: entry.cpuPercent) : .primary)
                    }

                    HStack(spacing: 6) {
                        CPUMeterBar(cpuPercent: entry.cpuPercent, coreCount: coreCount)
                            .frame(width: 46)

                        Text(Formatters.memory(entry.memoryBytes))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 42, alignment: .trailing)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.35))
                    .frame(width: 10)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.075) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        entry.severity == .critical
                            ? Color.red.opacity(isHovered ? 0.45 : 0.25)
                            : Color.primary.opacity(isHovered ? 0.12 : 0.04),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var processIcon: some View {
        let nsImage = IconCache.shared.nsImage(for: entry)
        ZStack {
            if entry.bundlePath == nil {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.color(forCPUPercent: entry.cpuPercent).opacity(0.14))
                    .frame(width: 28, height: 28)
            }
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: entry.bundlePath != nil ? 28 : 16, height: entry.bundlePath != nil ? 28 : 16)
                .foregroundStyle(Theme.color(forCPUPercent: entry.cpuPercent))
        }
        .frame(width: 28, height: 28)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
