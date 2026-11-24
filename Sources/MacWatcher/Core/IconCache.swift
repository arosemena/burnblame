import AppKit
import Foundation

/// Thread-safe, zero-main-thread-I/O icon cache.
/// Icons are prefetched on the background sampler queue before rows are published to SwiftUI,
/// so `icon(for:)` on the main thread is always a pure O(1) in-memory lookup.
public final class IconCache: @unchecked Sendable {
    public static let shared = IconCache()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private let fallbackSymbol: NSImage

    private init() {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        self.fallbackSymbol = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: 24, height: 24))
    }

    /// Call from a background queue to warm icons for a batch of processes before publishing to UI.
    public func prefetch(entries: [ProcessEntry]) {
        for entry in entries {
            let key = cacheKey(for: entry)
            lock.lock()
            let exists = cache[key] != nil
            lock.unlock()
            if exists { continue }

            let image = loadIcon(for: entry)
            lock.lock()
            if cache.count > 160 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = image
            lock.unlock()
        }
    }

    /// Fast O(1) lookup for SwiftUI rendering. Never performs disk I/O or LaunchServices IPC.
    public func icon(for entry: ProcessEntry) -> NSImage {
        let key = cacheKey(for: entry)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Pure in-memory SF Symbol fallback if not yet prefetched
        return symbolFallback(for: entry) ?? fallbackSymbol
    }

    private func cacheKey(for entry: ProcessEntry) -> String {
        if let bundlePath = entry.bundlePath {
            return "app:\(bundlePath)"
        }
        return "sym:\(entry.name.lowercased()):\(entry.isSystemProcess)"
    }

    private func loadIcon(for entry: ProcessEntry) -> NSImage {
        let image: NSImage
        if let bundlePath = entry.bundlePath {
            image = NSWorkspace.shared.icon(forFile: bundlePath)
        } else {
            image = symbolFallback(for: entry) ?? fallbackSymbol
        }
        image.size = NSSize(width: 28, height: 28)
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

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: entry.name)?
            .withSymbolConfiguration(config)
    }
}
