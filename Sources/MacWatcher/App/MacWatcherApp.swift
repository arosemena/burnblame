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
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var engine: MonitorEngine!
    private var statusUpdateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay strictly in the menu bar — no Dock icon or app switcher clutter
        NSApp.setActivationPolicy(.accessory)

        engine = MonitorEngine()

        // Configure popover
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 400, height: 540)
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = NSHostingController(rootView: PopoverRootView(engine: engine))
        self.popover = pop

        // Configure status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusBarButton()
        }

        // Observe engine changes to update the menu bar label smoothly
        observeEngine()
    }

    private func observeEngine() {
        withObservationTracking {
            _ = engine.systemCPU
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
            switch severity {
            case .critical: return "flame.fill"
            case .elevated: return "cpu.fill"
            case .moderate, .calm: return "cpu"
            }
        }()

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

        if engine.showPercentInMenuBar {
            let pct = Int(engine.systemCPU.total.rounded())
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: severity == .critical ? .bold : .medium),
                .foregroundColor: Theme.nsColor(for: severity)
            ]
            button.attributedTitle = NSAttributedString(string: " \(pct)%", attributes: attrs)
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(from: button)
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
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
