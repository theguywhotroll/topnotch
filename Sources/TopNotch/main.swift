import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = TopNotchModel()
    private var statusItem: NSStatusItem!
    private var panels: [NotchPanel] = []
    private var settingsWindow: NSWindow?
    private var refreshTimer: Timer?
    private var hoverTimer: Timer?
    private var hoverExitDeadline: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "TopNotch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open TopNotch", action: #selector(togglePanel), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit TopNotch", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        model.onExpansionChange = { [weak self] in self?.layoutPanels() }
        model.onDisplayChange = { [weak self] in self?.rebuildPanels() }
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildPanels), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        rebuildPanels()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collapseWhenPointerLeaves() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        hoverTimer?.invalidate()
    }

    @objc private func togglePanel() {
        model.expanded.toggle()
        if model.expanded { hoverExitDeadline = Date().addingTimeInterval(2) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func rebuildPanels() {
        panels.forEach { $0.close() }
        panels.removeAll()
        let screens = model.showOnAllDisplays ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for screen in screens {
            let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 42), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: NotchView(model: model, openSettings: { [weak self] in self?.openSettings() }))
            panel.orderFrontRegardless()
            panels.append(panel)
            position(panel, on: screen)
        }
    }

    private func layoutPanels() {
        if panels.count != (model.showOnAllDisplays ? NSScreen.screens.count : 1) {
            rebuildPanels()
            return
        }
        let screens = model.showOnAllDisplays ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for (panel, screen) in zip(panels, screens) { position(panel, on: screen) }
    }

    private func collapseWhenPointerLeaves() {
        guard model.expanded else {
            hoverExitDeadline = nil
            return
        }
        let pointer = NSEvent.mouseLocation
        let hovering = panels.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(pointer) }
        if hovering {
            hoverExitDeadline = nil
        } else if let deadline = hoverExitDeadline {
            if Date() >= deadline {
                model.expanded = false
                hoverExitDeadline = nil
            }
        } else {
            hoverExitDeadline = Date().addingTimeInterval(0.45)
        }
    }

    private func position(_ panel: NotchPanel, on screen: NSScreen) {
        let size = model.expanded ? NSSize(width: 384, height: 226) : NSSize(width: 240, height: 42)
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true, animate: true)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 360), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "TopNotch Settings"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
