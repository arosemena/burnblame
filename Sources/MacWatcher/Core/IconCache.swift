import AppKit
import Foundation

/// Lightweight in-memory cache for process/app icons so SwiftUI rows never re-query NSWorkspace on every tick.
@MainActor
public final class IconCache {
    public static let shared = IconCache()

    private var cache: [String: NSImage] = [:]

    private init() {}

    public func icon(for entry: ProcessEntry) -> NSImage {
        let key = entry.bundlePath ?? entry.executablePath ?? "generic-\(entry.isSystemProcess)"
        if let cached = cache[key] {
            return cached
        }

        let image: NSImage
        if let bundlePath = entry.bundlePath {
            image = NSWorkspace.shared.icon(forFile: bundlePath)
        } else if let execPath = entry.executablePath,
                  FileManager.default.fileExists(atPath: execPath) {
            let fileIcon = NSWorkspace.shared.icon(forFile: execPath)
            // Use crisp SF Symbol for generic Unix binaries rather than the bland default exec icon
            if execPath.hasPrefix("/usr/") || execPath.hasPrefix("/bin/") || execPath.hasPrefix("/opt/") || !execPath.contains(".app/") {
                image = symbolFallback(for: entry) ?? fileIcon
            } else {
                image = fileIcon
            }
        } else {
            image = symbolFallback(for: entry) ?? NSWorkspace.shared.icon(for: .unixExecutable)
        }

        image.size = NSSize(width: 32, height: 32)
        if cache.count > 128 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = image
        return image
    }

    private func symbolFallback(for entry: ProcessEntry) -> NSImage? {
        let lower = entry.name.lowercased()
        let symbolName: String
        if ["zsh", "bash", "sh", "fish", "tmux"].contains(lower) {
            symbolName = "terminal.fill"
        } else if ["node", "bun", "deno", "python", "python3", "ruby", "java", "go", "rustc", "swift", "clang", "swift-frontend"].contains(lower) {
            symbolName = "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("docker") || lower.contains("container") || lower.contains("qemu") {
            symbolName = "shippingbox.fill"
        } else if entry.isSystemProcess {
            symbolName = "gearshape.fill"
        } else {
            symbolName = "cpu.fill"
        }

        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: entry.name)?
            .withSymbolConfiguration(config)
    }
}
