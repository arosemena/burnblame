import AppKit
import Observation
import SwiftUI

@main
struct BurnBlameEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Borderless, non-activating floating panel (like Raycast / iStat Menus / Bartender).
/// Faster open/close and smoother 120Hz scrolling than NSPopover, with zero arrow-mask compositing overhead.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct RenderedStatusState: Equatable {
        let symbolName: String
        let severity: CPUSeverity
        let title: String
    }

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var engine: MonitorEngine!
    private var lastRenderedStatus: RenderedStatusState?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    private let panelSize = NSSize(width: 406, height: 550)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay strictly in the menu bar — no Dock icon or app switcher clutter
        NSApp.setActivationPolicy(.accessory)

        engine = MonitorEngine()

        // Build floating rounded panel with native vibrancy material
        let p = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        container.material = .popover
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let hostingView = NSHostingView(rootView: PopoverRootView(engine: engine))
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        p.contentView = container
        // Pre-warm layout pass so first click is instant
        p.contentView?.layoutSubtreeIfNeeded()
        self.panel = p

        // Configure status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            updateStatusBarButton()
        }

        observeEngine()
    }

    private func observeEngine() {
        withObservationTracking {
            _ = engine.systemCPU
            _ = engine.effectiveThermalLevel
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
        let thermal = engine.effectiveThermalLevel
        let symbolName: String = {
            if engine.isMonitoringPaused { return "pause.circle" }
            if thermal >= .hot { return "flame.fill" }
            if thermal == .warm { return "thermometer.high" }
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
        guard nextState != lastRenderedStatus else { return }
        lastRenderedStatus = nextState

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BurnBlame")?
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

    @objc private func togglePanel(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp {
            showContextMenu(from: button)
            return
        }

        if panel.isVisible {
            hidePanel()
        } else {
            showPanel(relativeTo: button)
        }
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        if let buttonWindow = button.window {
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

            var x = buttonRect.midX - panelSize.width / 2.0
            let minX = screenFrame.minX + 8
            let maxX = screenFrame.maxX - panelSize.width - 8
            x = min(max(x, minX), maxX)

            let y = buttonRect.minY - panelSize.height - 6
            panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        }

        engine.isPopoverOpen = true
        panel.orderFrontRegardless()
        panel.makeKey()
        // Prevent the search TextField from auto-focusing with a blinking cursor on open
        panel.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.panel.makeFirstResponder(nil)
        }
        installDismissMonitors()
    }

    private func hidePanel() {
        removeDismissMonitors()
        panel.orderOut(nil)
        engine.isPopoverOpen = false
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                let mouseLoc = NSEvent.mouseLocation
                // Ignore clicks inside the panel or on the status bar button itself (handled by togglePanel)
                if self.panel.frame.contains(mouseLoc) { return }
                if let btnWin = self.statusItem.button?.window, btnWin.frame.contains(mouseLoc) { return }
                self.hidePanel()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.engine.selectedPID != nil {
                        self.engine.clearSelection()
                    } else {
                        self.hidePanel()
                    }
                }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        if panel.isVisible {
            hidePanel()
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

        let quitItem = NSMenuItem(title: "Quit BurnBlame", action: #selector(quitApp), keyEquivalent: "q")
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
}
