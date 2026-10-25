import AppKit
import Combine
import CoreAudio
import ServiceManagement
import SwiftUI

struct NotchAlert: Identifiable {
    enum Kind: Equatable { case volume, brightness, battery, connectivity, focus, calendar, media, info }
    enum Style { case ears, peek }

    var id = UUID()
    var kind: Kind
    var style: Style = .ears
    var symbol: String
    var tint: Color = .white
    /// Ears: text beside the symbol on the left.
    var leading: String?
    /// Ears: text on the right.
    var trailing: String?
    var progress: Double?
    var batteryLevel: Int?
    var charging = false
    /// Peek: headline, subtitle, image and optional event.
    var title = ""
    var subtitle = ""
    var image: NSImage?
    var event: CalendarEvent?
}

enum CompactActivity: Equatable { case nowPlaying, calendar, duo }

enum ExpandedTab: String, CaseIterable {
    case nowPlaying, calendar, duo

    var symbol: String {
        switch self {
        case .nowPlaying: "music.note"
        case .calendar: "calendar"
        case .duo: "square.split.2x1"
        }
    }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .calendar: "Calendar"
        case .duo: "Duo"
        }
    }
}

struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Hardware notches, and simulated ones when forced, stay visible while idle.
    var visibleWhenIdle: Bool
}

@MainActor
final class PanelContext: ObservableObject {
    let displayID: CGDirectDisplayID
    @Published var geometry: NotchGeometry
    @Published var hidden = false

    init(displayID: CGDirectDisplayID, geometry: NotchGeometry) {
        self.displayID = displayID
        self.geometry = geometry
    }
}

@MainActor
final class TopNotchModel: ObservableObject {
    let prefs = Preferences()

    @Published var expanded = false
    @Published var expandedDisplay: CGDirectDisplayID?
    @Published private(set) var hoverDisplay: CGDirectDisplayID?
    @Published var tab: ExpandedTab = .nowPlaying
    @Published var displayedMonth = Date()
    @Published private(set) var clock = Date()
    @Published private(set) var alert: NotchAlert?

    @Published private(set) var track: NowPlaying?
    @Published private(set) var trackTint: Color = .white
    @Published private(set) var trackSecondaryTint: Color = .white
    /// The artwork color darkened enough to read on the light expanded panel.
    @Published private(set) var trackTintOnLight: Color = .primary
    @Published private(set) var trackChangeCount = 0
    @Published private(set) var battery: BatteryService.Reading?
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var devices: [BluetoothDevice] = []
    @Published private(set) var focus: FocusState?
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var eventDays: Set<Date> = []
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var calendarAccess = false
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var weatherError: String?
    @Published private(set) var volume: Double?
    @Published private(set) var muted = false
    @Published private(set) var brightness: Double?
    @Published private(set) var outputDeviceName: String?
    @Published private(set) var accessibilityGranted = Permissions.accessibility
    @Published private(set) var keyTapActive = false
    @Published private(set) var frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    @Published private(set) var activityDismissed = false
    @Published private(set) var cycledActivity: CompactActivity?
    @Published private(set) var dismissedEventIDs: Set<String> = []
    @Published var settingsError: String?

    var onOpenSettings: (() -> Void)?

    private let media = NowPlayingController()
    private let calendarService = CalendarService()
    private let weatherService = WeatherService()
    private let travel = TravelTimeService()
    private let keyTap = MediaKeyTap()
    private var cancellables: Set<AnyCancellable> = []
    private var alertGeneration = 0
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var lastPlaying = Date.distantPast
    private var recentActivity: CompactActivity = .nowPlaying
    private var artworkColorID: String?
    private var previousBattery: BatteryService.Reading?
    private var previousDevices: [BluetoothDevice]?
    private var previousFocus: FocusState?
    private var previousVolume: Double?
    private var previousMuted: Bool?
    private var previousBrightness: Double?
    private var previousOutputID: AudioDeviceID?
    private var leadNotified: Set<String> = []
    private var startNotified: Set<String> = []
    private var leaveNotified: Set<String> = []
    private var lastChimeHour: Int?
    private var lastCalendarLoad = Date.distantPast
    private var lastCalendarDay = Calendar.current.startOfDay(for: Date())

    init() {
        media.onChange = { [weak self] in self?.handleTrack($0) }
        calendarService.onChange = { [weak self] in self?.reloadCalendar() }
        weatherService.onUpdate = { [weak self] snapshot in
            self?.weather = snapshot
            self?.weatherError = nil
        }
        weatherService.onError = { [weak self] message in self?.weatherError = message }
        keyTap.handler = { [weak self] key, fine, isDown in
            MainActor.assumeIsolated { self?.handleKey(key, fine: fine, isDown: isDown) ?? false }
        }
        prefs.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        prefs.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in self?.preferenceChanged(key) }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.frontmostBundleID = bundleID }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lowPowerChanged() }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.prefs.playSoundOnLock == true { SoundPlayer.play(.lock) } }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.prefs.playSoundOnUnlock == true { SoundPlayer.play(.unlock) } }
        }

        Self.migrateLegacyDefaults()
        Self.importAlcoveDefaults()
        prefs.launchAtLogin = SMAppService.mainApp.status == .enabled
        startWeatherIfWanted()
        media.configure(enabled: prefs.enableNowPlaying, app: prefs.musicApp)
        updateKeyTap()
        reloadCalendar()
        refresh()
        refreshFast()
        lastChimeHour = Calendar.current.component(.hour, from: Date())
    }

    // MARK: Layout

    func size(for panel: PanelContext) -> CGSize {
        let notch = panel.geometry
        guard !panel.hidden else { return CGSize(width: notch.width, height: 0) }
        if expanded, expandedDisplay == panel.displayID {
            return CGSize(width: tab == .duo ? 620 : 470, height: notch.height + 146)
        }
        if let alert {
            if alert.style == .peek {
                return CGSize(width: max(notch.width + 170, 360), height: notch.height + 58)
            }
            return CGSize(width: notch.width + 2 * earWidth(for: alert), height: notch.height)
        }
        let bump: CGFloat = hoverDisplay == panel.displayID ? 1 : 0
        if compactActivity != nil {
            return CGSize(width: notch.width + 2 * compactEarWidth(notch) + 10 * bump, height: notch.height + 2 * bump)
        }
        if notch.visibleWhenIdle {
            return CGSize(width: notch.width + 12 * bump, height: notch.height + 3 * bump)
        }
        return CGSize(width: notch.width, height: 0)
    }

    func compactEarWidth(_ notch: NotchGeometry) -> CGFloat {
        compactActivity == .nowPlaying ? notch.height + 10 : notch.height + 22
    }

    private func earWidth(for alert: NotchAlert) -> CGFloat {
        switch alert.kind {
        case .volume, .brightness: alert.leading == nil ? 76 : 112
        case .battery: 92
        case .connectivity: 116
        case .focus: prefs.focusHideLabel ? 56 : 108
        default: 108
        }
    }

    // MARK: Activities

    var upcomingEvent: CalendarEvent? {
        let now = clock
        return events.first { event in
            !event.isAllDay && !dismissedEventIDs.contains(event.id) && event.end > now
                && event.start.timeIntervalSince(now) <= 3600
                && !(prefs.disableActivityDuringEvents && event.isOngoing)
        }
    }

    var todayEvents: [CalendarEvent] {
        events.filter { Calendar.current.isDateInToday($0.start) || ($0.start < Date() && $0.end > Date()) }
            .filter { !dismissedEventIDs.contains($0.id) }
    }

    var tomorrowEvents: [CalendarEvent] {
        events.filter { Calendar.current.isDateInTomorrow($0.start) && !dismissedEventIDs.contains($0.id) }
    }

    private var mediaActive: Bool {
        guard prefs.enableNowPlaying else { return false }
        if prefs.hideWhileSourceAppIsActive, let bundle = track?.bundleID, bundle == frontmostBundleID { return false }
        if prefs.forceEnableActivity { return true }
        guard let track else { return false }
        return track.isPlaying || clock.timeIntervalSince(lastPlaying) < prefs.idleDuration
    }

    private var calendarActive: Bool {
        prefs.enableCalendar && (upcomingEvent != nil || (prefs.forceEnableActivity && calendarAccess))
    }

    var compactActivity: CompactActivity? {
        guard !activityDismissed else { return nil }
        let mediaOn = mediaActive
        let calendarOn = calendarActive
        func available(_ activity: CompactActivity) -> Bool {
            switch activity {
            case .nowPlaying: mediaOn
            case .calendar: calendarOn
            case .duo: mediaOn && calendarOn
            }
        }
        if let cycledActivity, available(cycledActivity) { return cycledActivity }
        switch prefs.idleActivity {
        case .none: return nil
        case .nowPlaying: return mediaOn ? .nowPlaying : nil
        case .calendar: return calendarOn ? .calendar : nil
        case .duo: return mediaOn && calendarOn ? .duo : mediaOn ? .nowPlaying : calendarOn ? .calendar : nil
        case .mostRecent:
            if mediaOn && calendarOn { return recentActivity }
            return mediaOn ? .nowPlaying : calendarOn ? .calendar : nil
        }
    }

    var focusReplacesWaveform: Bool {
        prefs.replaceWaveformDuringFocus && focus?.matches(prefs.replaceWaveformFocusMode) == true
    }

    func cycleActivity() {
        let options: [CompactActivity] = [.nowPlaying, .calendar].filter {
            $0 == .nowPlaying ? mediaActive : calendarActive
        }
        guard options.count > 1, let current = compactActivity else { return }
        let index = options.firstIndex(of: current == .duo ? .nowPlaying : current) ?? 0
        cycledActivity = options[(index + 1) % options.count]
        haptic()
    }

    func setActivityDismissed(_ dismissed: Bool) {
        activityDismissed = dismissed
        haptic()
    }

    func dismissEvent(_ event: CalendarEvent) {
        dismissedEventIDs.insert(event.id)
    }

    // MARK: Expansion and hover

    func setExpanded(_ value: Bool, display: CGDirectDisplayID? = nil) {
        collapseWork?.cancel()
        hoverWork?.cancel()
        if value {
            expandedDisplay = display ?? hoverDisplay ?? expandedDisplay ?? BrightnessService.builtInDisplay ?? CGMainDisplayID()
            if !expanded { tab = defaultTab }
            if alert?.kind != .volume, alert?.kind != .brightness { alert = nil }
        }
        expanded = value
    }

    private var defaultTab: ExpandedTab {
        switch compactActivity {
        case .calendar: return .calendar
        case .duo: return .duo
        case .nowPlaying: return .nowPlaying
        case nil:
            switch prefs.idleActivity {
            case .calendar: return .calendar
            case .duo: return .duo
            default: return track == nil && calendarAccess && prefs.enableCalendar ? .calendar : .nowPlaying
            }
        }
    }

    func pointer(inside: Bool, display: CGDirectDisplayID) {
        if inside {
            collapseWork?.cancel()
            guard hoverDisplay != display else { return }
            hoverDisplay = display
            if prefs.expandOnHover, !expanded {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hoverDisplay == display else { return }
                    self.setExpanded(true, display: display)
                    self.haptic()
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + prefs.hoverDuration, execute: work)
            }
        } else if hoverDisplay == display {
            hoverDisplay = nil
            hoverWork?.cancel()
            if expanded, expandedDisplay == display { scheduleCollapse(after: 0.45) }
        }
    }

    /// Opens from the menu without the pointer: closes again if the pointer never arrives.
    func openFromMenu() {
        setExpanded(true)
        scheduleCollapse(after: 4)
    }

    func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverDisplay == nil else { return }
            self.expanded = false
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func haptic() {
        guard prefs.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Handles a trackpad swipe over the notch. Directions are physical finger movement.
    func swipe(horizontal: CGFloat, vertical: CGFloat) {
        let flip: CGFloat = prefs.naturalMovement ? 1 : -1
        let dx = horizontal * flip
        let dy = vertical * flip
        if abs(dx) > abs(dy) {
            guard prefs.swipeToSkip, track != nil else { return }
            send(dx < 0 ? .next : .previous)
            haptic()
            return
        }
        if dy > 0 {
            if activityDismissed, prefs.swipeToDismiss {
                setActivityDismissed(false)
            } else if !expanded, prefs.swipeToCycleActivity, compactActivity != nil,
                      [mediaActive, calendarActive].filter({ $0 }).count > 1 {
                cycleActivity()
            } else if !expanded, prefs.swipeToToggle {
                setExpanded(true)
                haptic()
            }
        } else {
            if expanded, prefs.swipeToToggle {
                setExpanded(false)
                haptic()
            } else if !expanded, prefs.swipeToDismiss, compactActivity != nil {
                setActivityDismissed(true)
            }
        }
    }

    // MARK: Alerts

    func show(_ next: NotchAlert, for duration: TimeInterval) {
        var next = next
        if let current = alert, current.kind == next.kind, current.style == next.style {
            next.id = current.id
        }
        alertGeneration += 1
        let generation = alertGeneration
        alert = next
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.alertGeneration == generation else { return }
            self.alert = nil
        }
    }

    func dismissAlert() {
        alertGeneration += 1
        alert = nil
    }

    func previewAlert() {
        show(NotchAlert(kind: .info, symbol: "sparkle", tint: .white, leading: "TopNotch", trailing: "Ready"), for: 2.5)
    }

    // MARK: Refresh

    /// Runs about once a second.
    func refresh() {
        clock = Date()
        if track?.isPlaying == true { lastPlaying = clock }
        refreshBattery()
        refreshDevices()
        refreshFocus()
        assign(\.accessibilityGranted, Permissions.accessibility)
        if prefs.replaceSystemHUD, !keyTap.isRunning, accessibilityGranted { updateKeyTap() }

        let today = Calendar.current.startOfDay(for: clock)
        if today != lastCalendarDay || clock.timeIntervalSince(lastCalendarLoad) > 60 {
            lastCalendarDay = today
            reloadCalendar()
        }
        checkCalendarAlerts()
        if prefs.showWeatherOnEmptyDay { weatherService.refreshIfNeeded() }
    }

    /// Polls volume and brightness so changes made outside TopNotch still show a HUD.
    func refreshFast() {
        let device = AudioOutput.defaultDevice()
        assign(\.outputDeviceName, device?.name)
        let currentVolume = device.flatMap { AudioOutput.volume($0.id) }
        let currentMuted = device.map { AudioOutput.isMuted($0.id) } ?? false
        assign(\.volume, currentVolume)
        assign(\.muted, currentMuted)
        if device?.id == previousOutputID, let previousVolume, let currentVolume,
           abs(previousVolume - currentVolume) > 0.001 || previousMuted != currentMuted {
            showVolumeHUD(device: device)
        }
        previousOutputID = device?.id
        previousVolume = currentVolume
        previousMuted = currentMuted

        let currentBrightness = BrightnessService.brightness()
        assign(\.brightness, currentBrightness)
        if let previousBrightness, let currentBrightness, abs(previousBrightness - currentBrightness) > 0.03 {
            showBrightnessHUD()
        }
        previousBrightness = currentBrightness
    }

    /// Assigns only when the value changed. Polls run several times a second, and every
    /// write to a published property redraws the notch even when nothing is different.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<TopNotchModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func refreshBattery() {
        guard let reading = BatteryService.reading() else { return }
        assign(\.battery, reading)
        defer { previousBattery = reading }
        guard prefs.enableBattery, let previous = previousBattery else { return }
        let percentText = prefs.hideBatteryPercentage ? nil : "\(reading.percent)%"
        if reading.pluggedIn, !previous.pluggedIn {
            show(NotchAlert(kind: .battery, symbol: "bolt.fill", tint: .green, leading: "Charging", trailing: percentText, batteryLevel: reading.percent, charging: true), for: prefs.batteryDuration)
        } else if prefs.warnOnLowBattery, !reading.pluggedIn,
                  previous.percent > prefs.lowBatteryThreshold, reading.percent <= prefs.lowBatteryThreshold {
            show(NotchAlert(kind: .battery, symbol: "battery.25percent", tint: .red, leading: "Low Battery", trailing: percentText, batteryLevel: reading.percent), for: prefs.batteryDuration + 1)
            if prefs.playSoundOnLowBattery { SoundPlayer.play(.lowBattery) }
        }
    }

    private func lowPowerChanged() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard prefs.enableBattery, prefs.notifyOnLowPowerMode else { return }
        show(NotchAlert(
            kind: .battery, symbol: "leaf.fill", tint: lowPowerMode ? .yellow : .white,
            leading: "Low Power", trailing: lowPowerMode ? "On" : "Off",
            batteryLevel: battery?.percent
        ), for: prefs.batteryDuration)
    }

    private func refreshDevices() {
        let current = BluetoothService.connectedDevices()
        assign(\.devices, current)
        defer { previousDevices = current }
        guard prefs.enableConnectivity, let previous = previousDevices else { return }
        if let added = current.first(where: { device in !previous.contains { $0.address == device.address } }) {
            show(NotchAlert(
                kind: .connectivity, symbol: added.symbol, leading: added.name,
                trailing: added.lowestBattery.map { "\($0)%" } ?? "Connected", batteryLevel: added.lowestBattery
            ), for: prefs.connectivityDuration)
        } else if let removed = previous.first(where: { device in !current.contains { $0.address == device.address } }) {
            show(NotchAlert(kind: .connectivity, symbol: removed.symbol, tint: .white.opacity(0.7), leading: removed.name, trailing: "Disconnected"), for: prefs.connectivityDuration)
        }
    }

    private func refreshFocus() {
        let current = FocusService.current()
        assign(\.focus, current)
        defer { previousFocus = current }
        guard prefs.enableFocus, let current, let previous = previousFocus, current.active != previous.active || current.name != previous.name else { return }
        let shown = current.active ? current : previous
        show(NotchAlert(
            kind: .focus, symbol: shown.symbol, tint: current.active ? Color(red: 0.55, green: 0.5, blue: 1) : .white.opacity(0.6),
            leading: prefs.focusHideLabel ? nil : (shown.name ?? "Focus"), trailing: current.active ? "On" : "Off"
        ), for: prefs.focusDuration)
        if current.active, current.isSleep, prefs.playSoundOnSleepFocus { SoundPlayer.play(.sleep) }
    }

    // MARK: Calendar

    func reloadCalendar() {
        lastCalendarLoad = Date()
        calendarAccess = calendarService.hasAccess
        guard calendarAccess else {
            events = []
            eventDays = []
            calendars = []
            return
        }
        calendars = calendarService.calendars()
        let disabled = Set(prefs.disabledCalendarIDs)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        events = calendarService.events(from: today, to: end, excluding: disabled)

        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) ?? today
        let gridStart = calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
        let gridEnd = calendar.date(byAdding: .day, value: 45, to: monthStart) ?? monthStart
        eventDays = Set(calendarService.events(from: gridStart, to: gridEnd, excluding: disabled).map { calendar.startOfDay(for: $0.start) })
        recentActivityFromCalendar()
    }

    private func recentActivityFromCalendar() {
        if let upcoming = upcomingEvent, upcoming.start.timeIntervalSinceNow <= Double(prefs.calendarLeadMinutes * 60) {
            recentActivity = .calendar
        }
    }

    func requestCalendar() {
        calendarService.requestAccess { [weak self] _ in self?.reloadCalendar() }
    }

    func setCalendar(_ id: String, enabled: Bool) {
        var disabled = Set(prefs.disabledCalendarIDs)
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        prefs.disabledCalendarIDs = disabled.sorted()
    }

    func showMonth(offset: Int) {
        displayedMonth = offset == 0 ? Date() : Calendar.current.date(byAdding: .month, value: offset, to: displayedMonth) ?? displayedMonth
        reloadCalendar()
    }

    private func checkCalendarAlerts() {
        let now = clock
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        if prefs.playHourlyChime, calendar.component(.minute, from: now) == 0, lastChimeHour != hour {
            SoundPlayer.play(.chime)
        }
        if calendar.component(.minute, from: now) == 0 { lastChimeHour = hour }

        guard prefs.enableCalendar else { return }
        for event in events where !event.isAllDay && !dismissedEventIDs.contains(event.id) {
            let untilStart = event.start.timeIntervalSince(now)
            if prefs.calendarPeekWhenStarting, untilStart <= 0, untilStart > -60, !startNotified.contains(event.id) {
                startNotified.insert(event.id)
                recentActivity = .calendar
                showEventPeek(event, subtitle: "Starting now")
                if prefs.playSoundOnEvent { SoundPlayer.play(.event) }
            } else if prefs.calendarPeekBeforeEvent, untilStart > 0, untilStart <= Double(prefs.calendarLeadMinutes * 60),
                      !leadNotified.contains(event.id) {
                leadNotified.insert(event.id)
                recentActivity = .calendar
                showEventPeek(event, subtitle: "In \(max(1, Int((untilStart / 60).rounded()))) min")
            }
            if prefs.notifyWhenTimeToLeave, untilStart > 0, !leaveNotified.contains(event.id),
               event.location != nil || event.geoLocation != nil {
                weatherService.requestLocationIfNeeded()
                if let origin = weatherService.latestLocation,
                   let travelTime = travel.estimate(for: event, from: origin, mode: prefs.timeToLeaveTransport) {
                    let leaveAt = event.start.addingTimeInterval(-travelTime - Double(prefs.timeToLeaveBuffer * 60))
                    if now >= leaveAt {
                        leaveNotified.insert(event.id)
                        let minutes = Int((travelTime / 60).rounded())
                        show(NotchAlert(
                            kind: .calendar, style: .peek, symbol: transportSymbol, tint: Color(nsColor: event.color),
                            title: "Time to leave", subtitle: "\(event.title) · \(minutes) min \(prefs.timeToLeaveTransport.title.lowercased())",
                            event: event
                        ), for: prefs.calendarPeekDuration + 3)
                        if prefs.playSoundOnEvent { SoundPlayer.play(.event) }
                    }
                }
            }
        }
    }

    private var transportSymbol: String {
        switch prefs.timeToLeaveTransport {
        case .drive: "car.fill"
        case .transit: "tram.fill"
        case .walk: "figure.walk"
        }
    }

    private func showEventPeek(_ event: CalendarEvent, subtitle: String) {
        guard !expanded else { return }
        show(NotchAlert(
            kind: .calendar, style: .peek, symbol: "calendar", tint: Color(nsColor: event.color),
            title: event.title, subtitle: subtitle, event: event
        ), for: prefs.calendarPeekDuration)
    }

    // MARK: Media

    private func handleTrack(_ next: NowPlaying?) {
        let previous = track
        track = next
        if next?.isPlaying == true { lastPlaying = Date() }
        if let next, next.id != artworkColorID || (next.artwork != nil && previous?.artwork == nil) {
            artworkColorID = next.id
            updateTrackColors(next.artwork)
        }
        guard let next, next.id != previous?.id else { return }
        trackChangeCount += 1
        activityDismissed = false
        recentActivity = .nowPlaying
        if previous != nil, prefs.mediaQuickPeek, next.isPlaying, !expanded, alert == nil || alert?.kind == .media {
            show(NotchAlert(
                kind: .media, style: .peek, symbol: "music.note", tint: trackTint,
                title: displayTitle(next), subtitle: next.artist, image: next.artwork
            ), for: prefs.mediaPeekDuration)
        }
    }

    private func updateTrackColors(_ artwork: NSImage?) {
        let average = artwork?.averageColor
        trackTint = average.map { Color(nsColor: $0) } ?? .white
        if let average {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            trackTintOnLight = saturation < 0.12
                ? .primary
                : Color(nsColor: NSColor(hue: hue, saturation: max(saturation, 0.55), brightness: min(brightness, 0.6), alpha: 1))
            trackSecondaryTint = Color(nsColor: NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: 1))
        } else {
            trackSecondaryTint = .white
            trackTintOnLight = .primary
        }
    }

    func displayTitle(_ track: NowPlaying) -> String {
        prefs.hideMediaTitleExtras ? MediaText.cleanTitle(track.title) : track.title
    }

    var mediaTint: Color {
        switch prefs.mediaColorStyle {
        case .artwork, .gradient: trackTint
        case .color: .accentColor
        case .mono: .white
        }
    }

    func mediaTint(for scheme: ColorScheme) -> Color {
        guard scheme == .light else { return mediaTint }
        switch prefs.mediaColorStyle {
        case .artwork, .gradient: return trackTintOnLight
        case .color: return .accentColor
        case .mono: return .primary
        }
    }

    func send(_ command: MediaCommand) {
        media.send(command)
    }

    func seek(to fraction: Double) {
        guard let duration = track?.duration else { return }
        media.seek(to: duration * min(max(fraction, 0), 1))
    }

    func copyTrack() {
        guard let track else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(track.link?.absoluteString ?? "\(track.title) — \(track.artist)", forType: .string)
    }

    func showSourceApp() {
        guard let bundle = track?.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: HUDs

    private func handleKey(_ key: MediaKey, fine: Bool, isDown: Bool) -> Bool {
        guard prefs.replaceSystemHUD else { return false }
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard prefs.enableVolume, let device = AudioOutput.defaultDevice(), AudioOutput.canSetVolume(device.id) else { return false }
            guard isDown else { return true }
            let step = fine ? 1.0 / 64 : 1.0 / 16
            let current = AudioOutput.volume(device.id) ?? 0
            switch key {
            case .volumeUp: AudioOutput.setVolume(((current / step).rounded() + 1) * step, on: device.id)
            case .volumeDown: AudioOutput.setVolume(((current / step).rounded() - 1) * step, on: device.id)
            default: AudioOutput.setMuted(!AudioOutput.isMuted(device.id), on: device.id)
            }
            if key != .mute { SoundPlayer.playVolumeFeedback() }
            volume = AudioOutput.volume(device.id)
            muted = AudioOutput.isMuted(device.id)
            previousVolume = volume
            previousMuted = muted
            showVolumeHUD(device: device)
            return true
        case .brightnessUp, .brightnessDown:
            guard prefs.enableBrightness, let current = BrightnessService.brightness() else { return false }
            guard isDown else { return true }
            let step = fine ? 1.0 / 64 : 1.0 / 16
            let next = ((current / step).rounded() + (key == .brightnessUp ? 1 : -1)) * step
            guard BrightnessService.setBrightness(next) else { return false }
            brightness = BrightnessService.brightness()
            previousBrightness = brightness
            showBrightnessHUD()
            return true
        }
    }

    private func showVolumeHUD(device: AudioOutput.Device?) {
        guard prefs.enableVolume, let volume else { return }
        let level = muted ? 0 : volume
        let symbol: String
        if device?.isHeadphones == true {
            symbol = devices.first { $0.name == device?.name }?.symbol ?? "headphones"
        } else if level == 0 {
            symbol = "speaker.slash.fill"
        } else {
            symbol = level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
        show(NotchAlert(
            kind: .volume, symbol: symbol,
            leading: prefs.outputDeviceLabel == .device ? device?.name : nil,
            trailing: prefs.hudShowPercentage ? "\(Int((level * 100).rounded()))" : nil,
            progress: level
        ), for: prefs.hudDuration)
    }

    private func showBrightnessHUD() {
        guard prefs.enableBrightness, let brightness else { return }
        show(NotchAlert(
            kind: .brightness, symbol: brightness < 0.5 ? "sun.min.fill" : "sun.max.fill",
            trailing: prefs.hudShowPercentage ? "\(Int((brightness * 100).rounded()))" : nil,
            progress: brightness
        ), for: prefs.hudDuration)
    }

    private func updateKeyTap() {
        if prefs.replaceSystemHUD {
            keyTapActive = keyTap.start()
        } else {
            keyTap.stop()
            keyTapActive = false
        }
    }

    // MARK: Settings

    private func preferenceChanged(_ key: String) {
        switch key {
        case "enableNowPlaying", "musicApp":
            media.configure(enabled: prefs.enableNowPlaying, app: prefs.musicApp)
        case "replaceSystemHUD":
            if prefs.replaceSystemHUD, !Permissions.accessibility { Permissions.requestAccessibility() }
            updateKeyTap()
        case "disabledCalendarIDs", "enableCalendar":
            reloadCalendar()
        case "showWeatherOnEmptyDay":
            weatherService.wantsWeather = prefs.showWeatherOnEmptyDay
            if prefs.showWeatherOnEmptyDay { weatherService.refreshIfNeeded() } else { weather = nil }
        case "notifyWhenTimeToLeave":
            if prefs.notifyWhenTimeToLeave { weatherService.requestLocationIfNeeded() }
        case "launchAtLogin":
            applyLaunchAtLogin()
        case "mediaColorStyle":
            objectWillChange.send()
        default:
            break
        }
    }

    private func applyLaunchAtLogin() {
        let wanted = prefs.launchAtLogin
        let enabled = SMAppService.mainApp.status == .enabled
        guard wanted != enabled else { return }
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
        let status = SMAppService.mainApp.status == .enabled
        if status != prefs.launchAtLogin {
            DispatchQueue.main.async { self.prefs.launchAtLogin = status }
        }
    }

    func requestFocusAccess() {
        FocusService.requestIntentsAccess { [weak self] in self?.refreshFocus() }
    }

    func requestLocation() {
        weatherService.requestLocationIfNeeded(force: true)
    }

    var locationAuthorized: Bool { weatherService.isAuthorized }

    /// Moves settings saved by TopNotch 0.3 to their current keys.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let renames = [
            "weatherEnabled": "showWeatherOnEmptyDay", "focusNotificationsEnabled": "enableFocus",
            "brightnessHUDEnabled": "enableBrightness", "volumeHUDEnabled": "enableVolume",
            "batteryNotificationsEnabled": "enableBattery", "connectivityNotificationsEnabled": "enableConnectivity",
            "calendarNotificationsEnabled": "calendarPeekBeforeEvent", "mediaControlsEnabled": "enableNowPlaying",
            "swipeGesturesEnabled": "swipeToToggle"
        ]
        for (old, new) in renames {
            if let value = defaults.object(forKey: old) {
                if defaults.object(forKey: new) == nil { defaults.set(value, forKey: new) }
                defaults.removeObject(forKey: old)
            }
        }
        if let threshold = defaults.object(forKey: "batteryLowThreshold") as? Int {
            if defaults.object(forKey: "lowBatteryThreshold") == nil {
                let choices = [5, 10, 15, 20, 25, 30]
                defaults.set(choices.min { abs($0 - threshold) < abs($1 - threshold) }, forKey: "lowBatteryThreshold")
            }
            defaults.removeObject(forKey: "batteryLowThreshold")
        }
        if let all = defaults.object(forKey: "showOnAllDisplays") as? Bool {
            if all, defaults.object(forKey: "showOnDisplay") == nil { defaults.set(DisplayTarget.allDisplays.rawValue, forKey: "showOnDisplay") }
            defaults.removeObject(forKey: "showOnAllDisplays")
        }
    }

    /// On first launch, adopts the matching settings of an installed Alcove so TopNotch behaves the same way.
    private static func importAlcoveDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importedAlcoveDefaults") else { return }
        defaults.set(true, forKey: "importedAlcoveDefaults")
        guard let alcove = UserDefaults(suiteName: "com.henrikruscon.Alcove") else { return }
        let keys = [
            "forceSimulatedNotch", "showOnDisplay", "idleActivity", "hideFromScreenCapture", "hideWhileGaming",
            "hideInFullscreen", "hideInMissionControl", "enableVolume", "enableBrightness", "enableCalendar",
            "musicApp", "expandOnHover", "haptics", "progressiveBlur", "contrastOutline"
        ]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = alcove.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    func startWeatherIfWanted() {
        weatherService.wantsWeather = prefs.showWeatherOnEmptyDay
        if prefs.showWeatherOnEmptyDay { weatherService.refreshIfNeeded() }
    }
}
