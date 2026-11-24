import AppKit
import CoreGraphics
import Foundation

public enum CachedIcon: Sendable {
    case bitmap(CGImage)
    case symbol(String)
}

/// Thread-safe, zero-main-thread-I/O icon cache.
/// - App bundles are pre-rasterized once on the background queue into an exact 2x Retina (52x52px) `CGImage`
///   for direct Metal/CoreAnimation texture binding (no `NSImage` bridging overhead).
/// - CLI/system processes resolve to crisp vector SF Symbol names.
public final class IconCache: @unchecked Sendable {
    public static let shared = IconCache()

    private let lock = NSLock()
    private var cache: [String: CachedIcon] = [:]

    private init() {}

    /// Call from a background queue to warm icons for a batch of processes before publishing to UI.
    public func prefetch(entries: [ProcessEntry]) {
        for entry in entries {
            let key = cacheKey(for: entry)
            lock.lock()
            let exists = cache[key] != nil
            lock.unlock()
            if exists { continue }

            let loaded = loadIcon(for: entry)
            lock.lock()
            if cache.count > 160 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = loaded
            lock.unlock()
        }
    }

    /// Pure O(1) lookup for SwiftUI rendering. Never performs disk I/O or LaunchServices IPC.
    public func cachedIcon(for entry: ProcessEntry) -> CachedIcon {
        let key = cacheKey(for: entry)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        return .symbol(symbolName(for: entry))
    }

    /// Convenience for Inspector header (also O(1)).
    public func nsImage(for entry: ProcessEntry) -> NSImage {
        switch cachedIcon(for: entry) {
        case .bitmap(let cg):
            return NSImage(cgImage: cg, size: NSSize(width: 26, height: 26))
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            return NSImage(systemSymbolName: name, accessibilityDescription: entry.name)?
                .withSymbolConfiguration(config)
                ?? NSImage(size: NSSize(width: 26, height: 26))
        }
    }

    private func cacheKey(for entry: ProcessEntry) -> String {
        if let bundlePath = entry.bundlePath {
            return "app:\(bundlePath)"
        }
        return "sym:\(entry.name.lowercased()):\(entry.isSystemProcess)"
    }

    private func loadIcon(for entry: ProcessEntry) -> CachedIcon {
        if let bundlePath = entry.bundlePath {
            let nsIcon = NSWorkspace.shared.icon(forFile: bundlePath)
            if let cg = rasterizeToCGImage(nsIcon, pointSize: NSSize(width: 26, height: 26)) {
                return .bitmap(cg)
            }
        }
        return .symbol(symbolName(for: entry))
    }

    private func rasterizeToCGImage(_ source: NSImage, pointSize: NSSize) -> CGImage? {
        let pixelW = Int(pointSize.width * 2)
        let pixelH = Int(pointSize.height * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            source.draw(
                in: NSRect(origin: .zero, size: pointSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }

    private func symbolName(for entry: ProcessEntry) -> String {
        let lower = entry.name.lowercased()
        if ["zsh", "bash", "sh", "fish", "tmux"].contains(lower) {
            return "terminal.fill"
        } else if ["node", "bun", "deno", "python", "python3", "ruby", "java", "go", "rustc", "swift", "clang", "swift-frontend"].contains(lower) {
            return "chevron.left.forwardslash.chevron.right"
        } else if lower.contains("docker") || lower.contains("container") || lower.contains("qemu") {
            return "shippingbox.fill"
        } else if entry.isSystemProcess {
            return "gearshape.fill"
        } else {
            return "cpu.fill"
        }
    }
}
