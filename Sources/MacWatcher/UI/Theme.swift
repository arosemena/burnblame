import SwiftUI

public enum Theme {
    public static func color(for severity: CPUSeverity) -> Color {
        switch severity {
        case .calm:
            return Color(nsColor: .systemGreen)
        case .moderate:
            return Color(nsColor: .systemCyan)
        case .elevated:
            return Color(nsColor: .systemOrange)
        case .critical:
            return Color(nsColor: .systemRed)
        }
    }

    public static func color(for thermal: ThermalLevel) -> Color {
        switch thermal {
        case .cool:
            return Color(nsColor: .systemGreen)
        case .warm:
            return Color(nsColor: .systemOrange)
        case .hot:
            return Color(nsColor: .systemRed)
        case .critical:
            return Color(nsColor: .systemPink)
        }
    }

    public static func color(forCPUPercent cpu: Double) -> Color {
        if cpu >= 80 { return Color(nsColor: .systemRed) }
        if cpu >= 35 { return Color(nsColor: .systemOrange) }
        if cpu >= 12 { return Color(nsColor: .systemCyan) }
        return Color(nsColor: .systemGreen)
    }

    public static func nsColor(for severity: CPUSeverity) -> NSColor {
        switch severity {
        case .calm: return .labelColor
        case .moderate: return .labelColor
        case .elevated: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

public enum Formatters {
    public static func cpu(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "%.0f%%", value)
        } else if value >= 10 {
            return String(format: "%.1f%%", value)
        } else if value >= 0.05 {
            return String(format: "%.1f%%", value)
        } else {
            return "0.0%"
        }
    }

    public static func heatSeconds(_ seconds: Double) -> String {
        if seconds >= 120 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        } else if seconds >= 10 {
            return String(format: "%.0fs", seconds)
        } else if seconds >= 0.1 {
            return String(format: "%.1fs", seconds)
        } else {
            return "<0.1s"
        }
    }

    public static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024.0)
        } else if mb >= 10 {
            return String(format: "%.0f MB", mb)
        } else if mb >= 1 {
            return String(format: "%.1f MB", mb)
        } else {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.0f KB", kb)
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(mins)m"
        } else if mins > 0 {
            return "\(mins)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }

    public static func relativeTime(_ date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 {
            return "\(Int(elapsed))s ago"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m ago"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: date)
        }
    }

    public static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    public static func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
