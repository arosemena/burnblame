import AppKit
import Observation
import SwiftUI

@main
struct MacWatcherEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private struct RenderedStatusState: Equatable {
        let symbolName: String
        let severity: CPUSeverity
        let title: String
    }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var engine: MonitorEngine!
    private var lastRenderedStatus: RenderedStatusState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay strictly in the menu bar — no Dock icon or app switcher clutter
        NSApp.setActivationPolicy(.accessory)

        engine = MonitorEngine()

        // Configure popover: animates = false eliminates AppKit's ~200ms close-animation dead window
        // where clicks on the status bar icon get silently ignored, and makes opening instantaneous.
        let hostingController = NSHostingController(rootView: PopoverRootView(engine: engine))
        // Pre-warm SwiftUI hosting view so the very first click has zero cold-start layout lag
        _ = hostingController.view

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 406, height: 550)
        pop.behavior = .transient
        pop.animates = false
        pop.delegate = self
        pop.contentViewController = hostingController
        self.popover = pop

        // Configure status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Fire on mouseDown for instant response without waiting for release or losing clicks on redraw
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            updateStatusBarButton()
        }

        observeEngine()
    }

    private func observeEngine() {
        withObservationTracking {
            _ = engine.systemCPU
            _ = engine.thermalLevel
            _ = engine.showPercentInMenuBar
            _ = engine.menuBarSeverity
            _ = engine.isMonitoringPaused
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusBarButton()
                self?.observeEngine()
            }
        }
    }

    private func updateStatusBarButton() {
        guard let button = statusItem?.button else { return }

        let severity = engine.menuBarSeverity
        let symbolName: String = {
            if engine.isMonitoringPaused { return "pause.circle" }
            if engine.thermalLevel >= .hot { return "flame.fill" }
            if engine.thermalLevel == .warm { return "thermometer.high" }
            switch severity {
            case .critical: return "flame.fill"
            case .elevated: return "thermometer.medium"
            case .moderate, .calm: return "thermometer.low"
            }
        }()

        let titleText = engine.showPercentInMenuBar
            ? " \(Int(engine.systemCPU.total.rounded()))%"
            : ""

        let nextState = RenderedStatusState(
            symbolName: symbolName,
            severity: severity,
            title: titleText
        )
        // Skip redundant button redraws when displayed text/icon didn't actually change
        guard nextState != lastRenderedStatus else { return }
        lastRenderedStatus = nextState

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MacWatcher")?
            .withSymbolConfiguration(config) {
            if severity == .elevated || severity == .critical {
                let tinted = baseImage.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [Theme.nsColor(for: severity)])
                )
                tinted?.isTemplate = false
                button.image = tinted ?? baseImage
            } else {
                baseImage.isTemplate = true
                button.image = baseImage
            }
        }

        if !titleText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: severity == .critical ? .bold : .medium),
                .foregroundColor: Theme.nsColor(for: severity)
            ]
            button.attributedTitle = NSAttributedString(string: titleText, attributes: attrs)
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp {
            showContextMenu(from: button)
            return
        }

        if popover.isShown {
            popover.close()
        } else {
            // Show immediately on the current frame; activate lazily so WindowServer focus switch doesn't stall open
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.close()
        }

        let menu = NSMenu()
        let pauseTitle = engine.isMonitoringPaused ? "Resume Monitoring" : "Pause Monitoring"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let pctItem = NSMenuItem(
            title: engine.showPercentInMenuBar ? "Hide Menu Bar %" : "Show Menu Bar %",
            action: #selector(toggleMenuBarPercent),
            keyEquivalent: ""
        )
        pctItem.target = self
        menu.addItem(pctItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit MacWatcher", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePause() {
        engine.isMonitoringPaused.toggle()
    }

    @objc private func toggleMenuBarPercent() {
        engine.showPercentInMenuBar.toggle()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSPopoverDelegate (Drives Adaptive Sampling!)

    func popoverWillShow(_ notification: Notification) {
        engine.isPopoverOpen = true
    }

    func popoverDidClose(_ notification: Notification) {
        engine.isPopoverOpen = false
    }
}
