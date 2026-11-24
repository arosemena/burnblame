import SwiftUI

/// Displays recorded Thermal & Sustained-Load Events so the user can see what triggered
/// their fans even after the spike has ended.
public struct ThermalEventsView: View {
    public let events: [ThermalEvent]
    public let onSelectPID: (pid_t) -> Void

    public init(events: [ThermalEvent], onSelectPID: @escaping (pid_t) -> Void) {
        self.events = events
        self.onSelectPID = onSelectPID
    }

    public var body: some View {
        if events.isEmpty {
            VStack(spacing: 9) {
                Spacer()
                Image(systemName: "snowflake")
                    .font(.system(size: 28))
                    .foregroundStyle(.cyan)
                Text("Staying Cool")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("No thermal pressure jumps or sustained high-load spikes have been recorded yet. When your fans kick on, the culprits will be logged here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    ForEach(events) { event in
                        eventCard(event)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private func eventCard(_ event: ThermalEvent) -> some View {
        let levelColor = Theme.color(for: event.peakThermalLevel)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: event.peakThermalLevel.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(levelColor)

                Text(Formatters.clockTime(event.startedAt))
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))

                if event.isOngoing {
                    Text("ONGOING")
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.red.opacity(0.18)))
                        .foregroundStyle(.red)
                } else {
                    Text("· \(Formatters.duration(event.duration))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Peak \(Int(event.peakSystemCPU.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(levelColor)
            }

            Text(event.reason)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            if !event.culprits.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOP HEAT ORIGINATORS")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)

                    ForEach(event.culprits) { culprit in
                        Button {
                            onSelectPID(culprit.pid)
                        } label: {
                            HStack(spacing: 6) {
                                Text(culprit.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                Text("\(Formatters.heatSeconds(culprit.heatSeconds))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Text(String(format: "%.0f%%", culprit.sharePercent))
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(levelColor)
                                    .frame(minWidth: 32, alignment: .trailing)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4.5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(event.isOngoing ? Color.red.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }
}
