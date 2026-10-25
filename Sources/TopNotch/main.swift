import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let panelSize = NSSize(width: 760, height: 280)

    private let model = TopNotchModel()
    private var prefs: Preferences { model.prefs }
    private var statusItem: NSStatusItem?
    private var panels: [(panel: NotchPanel, context: PanelContext, screen: NSScreen)] = []
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var timers: [Timer] = []
    private var monitors: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var scrollTotal = CGSize.zero
    private var scrollHandled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        updateStatusItem()
        rebuildPanels()

        prefs.changed
            .receive(on: RunLoop.main)
            .sink { [weak self] key in self?.preferenceChanged(key) }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildPanels), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        timers = [
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.model.refresh()
                    self?.updateVisibility()
                }
            },
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.model.refreshFast() }
            },
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.trackPointer() }
            }
        ]
        installMonitors()
        updateVisibility()
        if !prefs.hasCompletedOnboarding { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timers.forEach { $0.invalidate() }
        monitors.forEach { NSEvent.removeMonitor($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        if prefs.hideMenuBarIcon {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "TopNotch")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open TopNotch", action: #selector(openPanel), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Preview Alert", action: #selector(previewAlert), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit TopNotch", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() { model.openFromMenu() }
    @objc private func previewAlert() { model.previewAlert() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Panels

    private var targetScreens: [NSScreen] {
        let screens = NSScreen.screens
        let fallback = [NSScreen.main ?? screens[0]]
        switch prefs.showOnDisplay {
        case .allDisplays: return screens
        case .builtInDisplay: return screens.first(where: \.isBuiltIn).map { [$0] } ?? fallback
        case .mainScreen: return screens.first.map { [$0] } ?? fallback
        case .specificDisplay: return screens.first(where: { $0.localizedName == prefs.selectedDisplayName }).map { [$0] } ?? fallback
        }
    }

    private func geometry(for screen: NSScreen) -> NotchGeometry {
        if let notch = screen.hardwareNotch {
            return NotchGeometry(width: notch.width, height: notch.height, visibleWhenIdle: true)
        }
        let height = prefs.notchHeight > 0 ? CGFloat(prefs.notchHeight) : screen.menuBarHeight
        return NotchGeometry(width: CGFloat(prefs.notchWidth), height: height, visibleWhenIdle: prefs.forceSimulatedNotch)
    }

    @objc private func rebuildPanels() {
        panels.forEach { $0.panel.close() }
        panels.removeAll()
        guard !NSScreen.screens.isEmpty else { return }
        for screen in targetScreens {
            guard let displayID = screen.displayID else { continue }
            let context = PanelContext(displayID: displayID, geometry: geometry(for: screen))
            let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
            panel.isMovable = false
            panel.ignoresMouseEvents = true
            panel.acceptsMouseMovedEvents = true
            let hosting = NSHostingView(rootView: NotchRootView(model: model, panel: context))
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.setFrame(frame(on: screen), display: false)
            panels.append((panel, context, screen))
            panel.orderFrontRegardless()
        }
        applyWindowBehaviour()
        updateVisibility()
    }

    private func frame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - Self.panelSize.width / 2,
            y: screen.frame.maxY - Self.panelSize.height,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        )
    }

    private func applyWindowBehaviour() {
        for entry in panels {
            entry.panel.sharingType = prefs.hideFromScreenCapture ? .none : .readOnly
            entry.panel.collectionBehavior = prefs.hideInMissionControl
                ? [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
                : [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    private func updateVisibility() {
        let gaming = prefs.hideWhileGaming && WindowEnvironment.frontmostIsGame
        for entry in panels {
            let fullscreen = prefs.hideInFullscreen && WindowEnvironment.hasFullscreenWindow(on: entry.screen)
            let hidden = gaming || fullscreen
            if entry.context.hidden != hidden {
                entry.context.hidden = hidden
                if hidden, model.expandedDisplay == entry.context.displayID { model.setExpanded(false) }
            }
        }
    }

    /// The screen-space rectangle the notch currently occupies, or the idle hover strip.
    private func hitRect(for entry: (panel: NotchPanel, context: PanelContext, screen: NSScreen)) -> NSRect? {
        guard !entry.context.hidden else { return nil }
        var size = model.shapeSize(on: entry.context)
        if size.height < 1 {
            // Without a visible notch, keep a hover strip so the panel can still be opened.
            let geometry = entry.context.geometry
            size = CGSize(width: geometry.width, height: geometry.height)
        }
        let screen = entry.screen.frame
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }

    private func trackPointer() {
        let pointer = NSEvent.mouseLocation
        for entry in panels {
            let inside = hitRect(for: entry)?.insetBy(dx: -3, dy: -3).contains(pointer) ?? false
            if entry.panel.ignoresMouseEvents == inside { entry.panel.ignoresMouseEvents = !inside }
            model.pointer(inside: inside, display: entry.context.displayID)
        }
    }

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.clickedOutside() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            guard event.window is NotchPanel else { return event }
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func clickedOutside() {
        guard model.expanded else { return }
        let pointer = NSEvent.mouseLocation
        let inside = panels.contains { hitRect(for: $0)?.contains(pointer) ?? false }
        if !inside { model.setExpanded(false) }
    }

    /// Converts trackpad scrolling over the notch into swipes, once per gesture.
    private func handleScroll(_ event: NSEvent) {
        if event.phase == .began {
            scrollTotal = .zero
            scrollHandled = false
        }
        guard event.momentumPhase == [] else { return }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        scrollTotal.width += event.scrollingDeltaX * sign
        scrollTotal.height += event.scrollingDeltaY * sign
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 28 : 3
        if !scrollHandled, max(abs(scrollTotal.width), abs(scrollTotal.height)) > threshold {
            scrollHandled = true
            model.swipe(horizontal: scrollTotal.width, vertical: scrollTotal.height)
        }
        if event.phase == .ended || event.phase == .cancelled || event.phase == [] && !event.hasPreciseScrollingDeltas {
            scrollTotal = .zero
            if event.phase == [] { scrollHandled = false }
        }
    }

    // MARK: Preferences

    private func preferenceChanged(_ key: String) {
        switch key {
        case "showOnDisplay", "selectedDisplayName", "forceSimulatedNotch", "notchWidth", "notchHeight":
            if ["notchWidth", "notchHeight", "forceSimulatedNotch"].contains(key) {
                for entry in panels { entry.context.geometry = geometry(for: entry.screen) }
            } else {
                rebuildPanels()
            }
        case "hideFromScreenCapture", "hideInMissionControl":
            applyWindowBehaviour()
        case "hideMenuBarIcon":
            updateStatusItem()
        case "hideInFullscreen", "hideWhileGaming":
            updateVisibility()
        default:
            break
        }
    }

    // MARK: Windows

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "TopNotch Settings"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        model.setExpanded(false)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.prefs.hasCompletedOnboarding = true
            self?.onboardingWindow?.close()
            self?.model.previewAlert()
        })
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
