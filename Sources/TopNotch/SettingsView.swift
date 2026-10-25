import AppKit
import CoreBluetooth
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, battery, connectivity, focus, display, sound, nowPlaying, calendar, fileTray, lockScreen, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .battery: "Battery"
        case .connectivity: "Connectivity"
        case .focus: "Focus"
        case .display: "Display"
        case .sound: "Sound"
        case .nowPlaying: "Now Playing"
        case .calendar: "Calendar"
        case .fileTray: "File Tray"
        case .lockScreen: "Lock Screen"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .battery: "battery.100percent.bolt"
        case .connectivity: "airpods"
        case .focus: "moon.fill"
        case .display: "sun.max.fill"
        case .sound: "speaker.wave.2.fill"
        case .nowPlaying: "play.fill"
        case .calendar: "calendar"
        case .fileTray: "tray.fill"
        case .lockScreen: "lock.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .battery: .green
        case .connectivity: .blue
        case .focus: .indigo
        case .display: .yellow
        case .sound: .pink
        case .nowPlaying: .red
        case .calendar: .orange
        case .fileTray: .teal
        case .lockScreen: .blue
        case .about: .gray
        }
    }

    static let notifications: [SettingsPage] = [.battery, .connectivity, .focus, .display, .sound]
    static let liveActivities: [SettingsPage] = [.nowPlaying, .calendar, .fileTray]
}

struct SettingsView: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences
    @State private var selection: SettingsPage? = .general

    init(model: TopNotchModel) {
        self.model = model
        prefs = model.prefs
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                row(.general)
                Section("Notifications") { ForEach(SettingsPage.notifications) { row($0) } }
                Section("Live Activities") { ForEach(SettingsPage.liveActivities) { row($0) } }
                Section { row(.lockScreen); row(.about) }
            }
            .navigationSplitViewColumnWidth(196)
        } detail: {
            page(selection ?? .general)
                .formStyle(.grouped)
                .navigationTitle((selection ?? .general).title)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private func row(_ page: SettingsPage) -> some View {
        Label {
            HStack {
                Text(page.title)
                if page == .fileTray {
                    Spacer()
                    Text("Soon").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: page.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(page.color.gradient, in: RoundedRectangle(cornerRadius: 5))
        }
        .tag(page)
    }

    @ViewBuilder
    private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .general: GeneralSettings(model: model, prefs: prefs)
        case .battery: BatterySettings(model: model, prefs: prefs)
        case .connectivity: ConnectivitySettings(model: model, prefs: prefs)
        case .focus: FocusSettings(model: model, prefs: prefs)
        case .display: HUDSettings(model: model, prefs: prefs, kind: .display)
        case .sound: HUDSettings(model: model, prefs: prefs, kind: .sound)
        case .nowPlaying: NowPlayingSettings(model: model, prefs: prefs)
        case .calendar: CalendarSettings(model: model, prefs: prefs)
        case .fileTray: FileTraySettings()
        case .lockScreen: LockScreenSettings(prefs: prefs)
        case .about: AboutSettings()
        }
    }
}

private struct SecondsSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 1...10
    var step = 0.5

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step).frame(width: 180)
                Text(value < 10 ? String(format: "%.1fs", value) : "\(Int(value))s")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                Picker("Display on", selection: $prefs.showOnDisplay) {
                    ForEach(DisplayTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if prefs.showOnDisplay == .specificDisplay {
                    Picker("Display", selection: $prefs.selectedDisplayName) {
                        ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                    }
                }
                Toggle("Hide in fullscreen", isOn: $prefs.hideInFullscreen)
                Toggle("Hide in mission control", isOn: $prefs.hideInMissionControl)
                Toggle("Hide while gaming", isOn: $prefs.hideWhileGaming)
                Toggle("Hide from screen capture", isOn: $prefs.hideFromScreenCapture)
                Toggle("Hide menu bar icon", isOn: $prefs.hideMenuBarIcon)
            } footer: {
                if prefs.hideMenuBarIcon {
                    Text("Right-click the notch, or open TopNotch again from Finder, to reach Settings.")
                }
            }

            Section("Idle Activity") {
                Picker("Activity", selection: $prefs.idleActivity) {
                    ForEach(IdleActivity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SecondsSlider(title: "Idle duration", value: $prefs.idleDuration, range: 5...120, step: 5)
                Toggle("Force enable activity", isOn: $prefs.forceEnableActivity)
            }

            Section("Behaviour") {
                Toggle("Contrast outline", isOn: $prefs.contrastOutline)
                Toggle("Progressive blur", isOn: $prefs.progressiveBlur)
                Toggle("Haptic feedback", isOn: $prefs.haptics)
                Toggle(isOn: $prefs.expandOnHover) {
                    Text("Expand on hover")
                    Text("Disables certain interactions")
                }
                if prefs.expandOnHover {
                    SecondsSlider(title: "Hover duration", value: $prefs.hoverDuration, range: 0.1...1.5, step: 0.1)
                }
            }

            Section("Gestures") {
                Toggle("Swipe to toggle open", isOn: $prefs.swipeToToggle)
                Toggle("Swipe to skip media", isOn: $prefs.swipeToSkip)
                Toggle(isOn: $prefs.swipeToCycleActivity) {
                    Text("Swipe to cycle activity")
                    Text("Swipe down to cycle activity")
                }
                Toggle(isOn: $prefs.swipeToDismiss) {
                    Text("Swipe to dismiss activity")
                    Text("Swipe vertically to toggle activity")
                }
                Toggle("Natural movement", isOn: $prefs.naturalMovement)
            }

            Section {
                Toggle("Force simulated notch", isOn: $prefs.forceSimulatedNotch)
                LabeledContent("Notch width") {
                    HStack {
                        Slider(value: $prefs.notchWidth, in: 140...280, step: 2).frame(width: 180)
                        Text("\(Int(prefs.notchWidth))").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Notch height") {
                    HStack {
                        Slider(value: $prefs.notchHeight, in: 0...44, step: 1).frame(width: 180)
                        Text(prefs.notchHeight == 0 ? "Auto" : "\(Int(prefs.notchHeight))").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Tuning")
            } footer: {
                Text("Width and height apply to the simulated notch on displays without one.")
            }

            PermissionsSection(model: model)

            Section {
                Button("Preview Notch Alert") { model.previewAlert() }
                if let error = model.settingsError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
        }
    }
}

struct PermissionsSection: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        Section("Permissions") {
            PermissionRow(
                title: "Accessibility", detail: "Replaces the system volume and brightness HUDs and reads Focus names.",
                granted: model.accessibilityGranted,
                action: { Permissions.requestAccessibility(); Permissions.openPrivacyPane("Privacy_Accessibility") }
            )
            PermissionRow(
                title: "Calendar", detail: "Shows your upcoming events.",
                granted: model.calendarAccess, action: { model.requestCalendar() }
            )
            PermissionRow(
                title: "Bluetooth", detail: "Shows connected audio devices and their battery.",
                granted: BluetoothService.authorized,
                action: { Permissions.openPrivacyPane("Privacy_Bluetooth") }
            )
            PermissionRow(
                title: "Location", detail: "Used for weather and time to leave.",
                granted: model.locationAuthorized, action: { model.requestLocation() }
            )
            PermissionRow(
                title: "Full Disk Access", detail: "Optional. Lets TopNotch read the active Focus mode name.",
                granted: FocusService.canReadModeNames,
                action: { Permissions.openPrivacyPane("Privacy_AllFiles") }
            )
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Ask Permission…", action: action)
            }
        }
    }
}

struct BatterySettings: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Battery", isOn: $prefs.enableBattery)
                SecondsSlider(title: "Duration", value: $prefs.batteryDuration)
                Toggle("Hide percentage", isOn: $prefs.hideBatteryPercentage)
                Toggle("Notify on low power mode", isOn: $prefs.notifyOnLowPowerMode)
            } footer: {
                Text(model.battery.map { "Currently \($0.percent)%\($0.charging ? ", charging" : $0.pluggedIn ? ", plugged in" : "")\(model.lowPowerMode ? " · Low Power Mode" : "")" } ?? "No battery detected.")
            }
            Section {
                Toggle("Warn on low battery", isOn: $prefs.warnOnLowBattery)
                LabeledContent("Low battery threshold") {
                    Picker("", selection: $prefs.lowBatteryThreshold) {
                        ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                Toggle("Play sound on low battery", isOn: $prefs.playSoundOnLowBattery)
            }
            .disabled(!prefs.enableBattery)
        }
    }
}

struct ConnectivitySettings: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Connectivity", isOn: $prefs.enableConnectivity)
                SecondsSlider(title: "Duration", value: $prefs.connectivityDuration)
            }
            Section("Connected Devices") {
                if model.devices.isEmpty {
                    Text("No paired Bluetooth devices are connected.").foregroundStyle(.secondary)
                }
                ForEach(model.devices, id: \.address) { device in
                    HStack {
                        Label(device.name, systemImage: device.symbol)
                        Spacer()
                        Text(batteryText(device)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func batteryText(_ device: BluetoothDevice) -> String {
        var parts: [String] = []
        if let left = device.batteryLeft { parts.append("L \(left)%") }
        if let right = device.batteryRight { parts.append("R \(right)%") }
        if let single = device.batterySingle { parts.append("\(single)%") }
        if let battery = device.batteryCase { parts.append("Case \(battery)%") }
        return parts.joined(separator: " · ")
    }
}

struct FocusSettings: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Focus", isOn: $prefs.enableFocus)
                SecondsSlider(title: "Duration", value: $prefs.focusDuration)
                Toggle("Hide label", isOn: $prefs.focusHideLabel)
                Toggle("Play sound on sleep focus", isOn: $prefs.playSoundOnSleepFocus)
            } footer: {
                Text(statusText)
            }
            Section {
                Toggle("Replace waveform during focus", isOn: $prefs.replaceWaveformDuringFocus)
                Picker("When focus is", selection: $prefs.replaceWaveformFocusMode) {
                    ForEach(FocusFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!prefs.replaceWaveformDuringFocus)
            }
        }
    }

    private var statusText: String {
        guard let focus = model.focus else {
            return "Grant Full Disk Access or Accessibility in General › Permissions so TopNotch can see Focus changes."
        }
        let source = FocusService.canReadModeNames ? "" : " Mode names come from the Control Center menu bar item; grant Full Disk Access for full detail."
        return (focus.active ? "\(focus.name ?? "Focus") is on." : "Focus is off.") + source
    }
}

struct HUDSettings: View {
    enum Kind { case display, sound }

    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences
    let kind: Kind

    var body: some View {
        Form {
            Section {
                if kind == .display {
                    Toggle("Display", isOn: $prefs.enableBrightness)
                    LabeledContent("Brightness", value: model.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable for this display")
                } else {
                    Toggle("Sound", isOn: $prefs.enableVolume)
                    Picker("Output device", selection: $prefs.outputDeviceLabel) {
                        ForEach(OutputDeviceLabel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Volume", value: model.volume.map { model.muted ? "Muted" : "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable for this output")
                    if let name = model.outputDeviceName { LabeledContent("Output", value: name) }
                }
            }
            Section {
                Toggle(isOn: $prefs.replaceSystemHUD) {
                    Text("Replace system HUD")
                    Text(model.keyTapActive ? "TopNotch handles the volume and brightness keys." : model.accessibilityGranted ? "Turn on to handle the volume and brightness keys." : "Requires Accessibility permission.")
                }
                if prefs.replaceSystemHUD, !model.accessibilityGranted {
                    Button("Open Accessibility Settings…") {
                        Permissions.requestAccessibility()
                        Permissions.openPrivacyPane("Privacy_Accessibility")
                    }
                }
            } header: {
                Text("HUDs")
            } footer: {
                Text("These HUD settings are linked between Display and Sound. Without replacing the system HUD, TopNotch still shows changes alongside macOS's own indicator.")
            }
            Section {
                SecondsSlider(title: "Duration", value: $prefs.hudDuration, range: 0.5...5)
                Toggle("Show percentage", isOn: $prefs.hudShowPercentage)
                Picker("Progress style", selection: $prefs.hudProgressStyle) {
                    ForEach(HUDProgressStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Speed", selection: $prefs.hudSpeed) {
                    ForEach(HUDSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }
}

struct NowPlayingSettings: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Now Playing", isOn: $prefs.enableNowPlaying)
                Picker("Source", selection: $prefs.musicApp) {
                    ForEach(MusicApp.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(prefs.musicApp == .system
                     ? "System follows whatever is playing, including browsers and podcast apps."
                     : "\(prefs.musicApp.title) takes priority; browsers and other apps show when \(prefs.musicApp.title) isn't playing. macOS asks for Automation permission the first time TopNotch reads or controls \(prefs.musicApp.title).")
            }
            Section("Appearance") {
                Picker("Color", selection: $prefs.mediaColorStyle) {
                    ForEach(MediaColorStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Extra control", selection: $prefs.mediaExtraControl) {
                    ForEach(MediaExtraControl.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Disable compact waveform", isOn: $prefs.disableCompactWaveform)
                Toggle("Disable artwork flip", isOn: $prefs.disableArtworkFlip)
                Toggle("Hide media title extras", isOn: $prefs.hideMediaTitleExtras)
                Toggle("Hide while source app is active", isOn: $prefs.hideWhileSourceAppIsActive)
            }
            Section("Quick Peek") {
                Toggle("When media changes", isOn: $prefs.mediaQuickPeek)
                SecondsSlider(title: "Peek duration", value: $prefs.mediaPeekDuration)
                    .disabled(!prefs.mediaQuickPeek)
            }
            Section {
                if let track = model.track {
                    LabeledContent("Playing", value: "\(track.title) — \(track.artist)")
                    if let app = track.appName { LabeledContent("From", value: app) }
                } else {
                    Text("Nothing is playing.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CalendarSettings: View {
    @ObservedObject var model: TopNotchModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Calendar", isOn: $prefs.enableCalendar)
                if !model.calendarAccess {
                    Button("Allow Calendar Access…") { model.requestCalendar() }
                }
                Toggle("Always show month view", isOn: $prefs.alwaysShowMonthView)
                Toggle("Use calendar color", isOn: $prefs.useCalendarColor)
                Toggle("Use event indicators", isOn: $prefs.useEventIndicators)
                Toggle("Disable activity during events", isOn: $prefs.disableActivityDuringEvents)
                Toggle("Show weather on empty day", isOn: $prefs.showWeatherOnEmptyDay)
            } footer: {
                if prefs.showWeatherOnEmptyDay {
                    Text(model.weatherError ?? "Weather sends your approximate location to Open-Meteo, at most every 20 minutes.")
                }
            }
            Section("Quick Peek") {
                Toggle("Before event starts", isOn: $prefs.calendarPeekBeforeEvent)
                Picker("Time before event", selection: $prefs.calendarLeadMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!prefs.calendarPeekBeforeEvent)
                Toggle("When event is starting", isOn: $prefs.calendarPeekWhenStarting)
                SecondsSlider(title: "Peek duration", value: $prefs.calendarPeekDuration, range: 2...15)
            }
            Section("Sounds") {
                Toggle("Play sound on calendar event", isOn: $prefs.playSoundOnEvent)
                Toggle("Play hourly chime", isOn: $prefs.playHourlyChime)
            }
            Section {
                Toggle("Notify when time to leave", isOn: $prefs.notifyWhenTimeToLeave)
                Group {
                    Picker("Transport", selection: $prefs.timeToLeaveTransport) {
                        ForEach(TransportMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Leave buffer", selection: $prefs.timeToLeaveBuffer) {
                        ForEach([0, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                }
                .disabled(!prefs.notifyWhenTimeToLeave)
            } footer: {
                Text("Uses your location and Apple Maps travel estimates for events with a location.")
            }
            if !model.calendars.isEmpty {
                Section("Calendars") {
                    ForEach(model.calendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { !prefs.disabledCalendarIDs.contains(calendar.id) },
                            set: { model.setCalendar(calendar.id, enabled: $0) }
                        )) {
                            HStack(spacing: 8) {
                                Circle().fill(Color(nsColor: calendar.color)).frame(width: 9, height: 9)
                                Text(calendar.title)
                                Text(calendar.subscribed ? "\(calendar.source) · Subscribed" : calendar.source)
                                    .foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct FileTraySettings: View {
    var body: some View {
        Form {
            Section {
                Label("File Tray is coming soon.", systemImage: "tray")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Alcove also lists this tab as Soon and keeps it disabled.")
            }
        }
    }
}

struct LockScreenSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Play sound on lock", isOn: $prefs.playSoundOnLock)
                Toggle("Play sound on unlock", isOn: $prefs.playSoundOnUnlock)
            } footer: {
                Text("Lock Screen widgets are not available yet. Drawing above the macOS lock screen needs private window-server APIs that this build does not use.")
            }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            if let path = Bundle.main.path(forResource: "TopNotchLogo", ofType: "png"),
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            Text("TopNotch").font(.system(size: 28, weight: .semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                .foregroundStyle(.secondary)
            Text("An independent native macOS notch app. Activity data stays on this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Modeled on Alcove's features. It contains none of Alcove's code, sounds, or 3D assets.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: TopNotchModel
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if let path = Bundle.main.path(forResource: "TopNotchLogo", ofType: "png"),
               let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            Text("Welcome to TopNotch").font(.system(size: 24, weight: .semibold))
            Text("Alerts, music and your next meeting appear in the notch and move out of the way when you're done.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 10) {
                Label("Click the notch to open the expanded view", systemImage: "hand.tap")
                Label("Swipe vertically over the notch to open or close it", systemImage: "arrow.up.and.down")
                Label("Swipe horizontally to skip tracks", systemImage: "arrow.left.and.right")
                Label("Right-click for media, calendar and Settings", systemImage: "contextualmenu.and.cursorarrow")
            }
            .font(.callout)
            Form { PermissionsSection(model: model) }
                .formStyle(.grouped)
                .frame(height: 300)
            Button("Get Started", action: finish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 560)
    }
}
