import Combine
import Foundation

protocol PrefValue {
    init?(pref: Any)
    var pref: Any { get }
}

extension Bool: PrefValue {
    init?(pref: Any) { guard let value = pref as? Bool else { return nil }; self = value }
    var pref: Any { self }
}

extension Int: PrefValue {
    init?(pref: Any) { guard let value = pref as? Int else { return nil }; self = value }
    var pref: Any { self }
}

extension Double: PrefValue {
    init?(pref: Any) { guard let value = pref as? Double else { return nil }; self = value }
    var pref: Any { self }
}

extension String: PrefValue {
    init?(pref: Any) { guard let value = pref as? String else { return nil }; self = value }
    var pref: Any { self }
}

extension Array: PrefValue where Element == String {
    init?(pref: Any) { guard let value = pref as? [String] else { return nil }; self = value }
    var pref: Any { self }
}

extension PrefValue where Self: RawRepresentable, RawValue == String {
    init?(pref: Any) {
        guard let raw = pref as? String, let value = Self(rawValue: raw) else { return nil }
        self = value
    }
    var pref: Any { rawValue }
}

/// Stores a preference in UserDefaults and notifies the owning `Preferences` object.
@propertyWrapper
struct Pref<Value: PrefValue> {
    let key: String
    let defaultValue: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    @available(*, unavailable, message: "Pref is only available on Preferences")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript(
        _enclosingInstance instance: Preferences,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Preferences, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Preferences, Pref<Value>>
    ) -> Value {
        get {
            let storage = instance[keyPath: storageKeyPath]
            return UserDefaults.standard.object(forKey: storage.key).flatMap(Value.init(pref:)) ?? storage.defaultValue
        }
        set {
            let key = instance[keyPath: storageKeyPath].key
            instance.objectWillChange.send()
            UserDefaults.standard.set(newValue.pref, forKey: key)
            instance.changed.send(key)
        }
    }
}

enum DisplayTarget: String, CaseIterable, PrefValue {
    case allDisplays, builtInDisplay, mainScreen, specificDisplay

    var title: String {
        switch self {
        case .allDisplays: "All displays"
        case .builtInDisplay: "Built-in display"
        case .mainScreen: "Main display"
        case .specificDisplay: "Selected display"
        }
    }
}

enum IdleActivity: String, CaseIterable, PrefValue {
    case none, nowPlaying, calendar, duo, mostRecent

    var title: String {
        switch self {
        case .none: "None"
        case .nowPlaying: "Playing"
        case .calendar: "Calendar"
        case .duo: "Duo"
        case .mostRecent: "Most Recent"
        }
    }
}

enum MusicApp: String, CaseIterable, PrefValue {
    case system, music, spotify

    var title: String {
        switch self {
        case .system: "System"
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
}

enum MediaColorStyle: String, CaseIterable, PrefValue {
    case artwork, color, gradient, mono

    var title: String {
        switch self {
        case .artwork: "Artwork"
        case .color: "Colored"
        case .gradient: "Gradient"
        case .mono: "Monochrome"
        }
    }
}

enum MediaExtraControl: String, CaseIterable, PrefValue {
    case none, shuffle, `repeat`, copy

    var title: String {
        switch self {
        case .none: "None"
        case .shuffle: "Shuffle"
        case .repeat: "Repeat"
        case .copy: "Copy"
        }
    }
}

enum HUDProgressStyle: String, CaseIterable, PrefValue {
    case white, accent, stylized, glow

    var title: String {
        switch self {
        case .white: "White"
        case .accent: "Accent"
        case .stylized: "Stylized"
        case .glow: "Glow"
        }
    }
}

enum HUDSpeed: String, CaseIterable, PrefValue {
    case instant, fast, smooth

    var title: String {
        switch self {
        case .instant: "Instant"
        case .fast: "Fast"
        case .smooth: "Smooth"
        }
    }
}

enum OutputDeviceLabel: String, CaseIterable, PrefValue {
    case speaker, device

    var title: String {
        switch self {
        case .speaker: "Show symbol"
        case .device: "Show device"
        }
    }
}

enum TransportMode: String, CaseIterable, PrefValue {
    case drive, transit, walk

    var title: String {
        switch self {
        case .drive: "Driving"
        case .transit: "Transit"
        case .walk: "Walking"
        }
    }
}

enum FocusFilter: String, CaseIterable, PrefValue {
    case any, sleep, doNotDisturb, work, personal

    var title: String {
        switch self {
        case .any: "Any"
        case .sleep: "Sleep"
        case .doNotDisturb: "Do Not Disturb"
        case .work: "Work"
        case .personal: "Personal"
        }
    }
}

/// User preferences. Key names follow Alcove's where an equivalent setting exists.
final class Preferences: ObservableObject {
    let changed = PassthroughSubject<String, Never>()

    // General
    @Pref("launchAtLogin") var launchAtLogin = false
    @Pref("showOnDisplay") var showOnDisplay = DisplayTarget.builtInDisplay
    @Pref("selectedDisplayName") var selectedDisplayName = ""
    @Pref("hideFromScreenCapture") var hideFromScreenCapture = false
    @Pref("hideInFullscreen") var hideInFullscreen = true
    @Pref("hideInMissionControl") var hideInMissionControl = false
    @Pref("hideWhileGaming") var hideWhileGaming = false
    @Pref("hideMenuBarIcon") var hideMenuBarIcon = false
    @Pref("forceSimulatedNotch") var forceSimulatedNotch = false
    @Pref("notchWidth") var notchWidth = 190.0
    @Pref("notchHeight") var notchHeight = 0.0
    @Pref("idleActivity") var idleActivity = IdleActivity.mostRecent
    @Pref("idleDuration") var idleDuration = 30.0
    @Pref("forceEnableActivity") var forceEnableActivity = false
    @Pref("contrastOutline") var contrastOutline = false
    @Pref("progressiveBlur") var progressiveBlur = true
    @Pref("haptics") var haptics = true
    @Pref("expandOnHover") var expandOnHover = false
    @Pref("hoverDuration") var hoverDuration = 0.3
    @Pref("swipeToToggle") var swipeToToggle = true
    @Pref("swipeToSkip") var swipeToSkip = true
    @Pref("swipeToCycleActivity") var swipeToCycleActivity = false
    @Pref("swipeToDismiss") var swipeToDismiss = true
    @Pref("naturalMovement") var naturalMovement = true
    @Pref("hasCompletedOnboarding") var hasCompletedOnboarding = false

    // HUDs
    @Pref("replaceSystemHUD") var replaceSystemHUD = false
    @Pref("enableVolume") var enableVolume = true
    @Pref("enableBrightness") var enableBrightness = true
    @Pref("hudDuration") var hudDuration = 1.5
    @Pref("hudShowPercentage") var hudShowPercentage = false
    @Pref("hudProgressStyle") var hudProgressStyle = HUDProgressStyle.white
    @Pref("hudSpeed") var hudSpeed = HUDSpeed.smooth
    @Pref("outputDeviceLabel") var outputDeviceLabel = OutputDeviceLabel.speaker

    // Battery
    @Pref("enableBattery") var enableBattery = true
    @Pref("batteryDuration") var batteryDuration = 3.0
    @Pref("hideBatteryPercentage") var hideBatteryPercentage = false
    @Pref("warnOnLowBattery") var warnOnLowBattery = true
    @Pref("lowBatteryThreshold") var lowBatteryThreshold = 10
    @Pref("playSoundOnLowBattery") var playSoundOnLowBattery = true
    @Pref("notifyOnLowPowerMode") var notifyOnLowPowerMode = true

    // Connectivity
    @Pref("enableConnectivity") var enableConnectivity = true
    @Pref("connectivityDuration") var connectivityDuration = 3.0

    // Focus
    @Pref("enableFocus") var enableFocus = true
    @Pref("focusDuration") var focusDuration = 2.5
    @Pref("focusHideLabel") var focusHideLabel = false
    @Pref("playSoundOnSleepFocus") var playSoundOnSleepFocus = false
    @Pref("replaceWaveformDuringFocus") var replaceWaveformDuringFocus = false
    @Pref("replaceWaveformFocusMode") var replaceWaveformFocusMode = FocusFilter.any

    // Now Playing
    @Pref("enableNowPlaying") var enableNowPlaying = true
    @Pref("musicApp") var musicApp = MusicApp.system
    @Pref("mediaColorStyle") var mediaColorStyle = MediaColorStyle.artwork
    @Pref("mediaExtraControl") var mediaExtraControl = MediaExtraControl.none
    @Pref("disableCompactWaveform") var disableCompactWaveform = false
    @Pref("disableArtworkFlip") var disableArtworkFlip = false
    @Pref("hideMediaTitleExtras") var hideMediaTitleExtras = false
    @Pref("hideWhileSourceAppIsActive") var hideWhileSourceAppIsActive = false
    @Pref("mediaQuickPeek") var mediaQuickPeek = true
    @Pref("mediaPeekDuration") var mediaPeekDuration = 2.5

    // Calendar
    @Pref("enableCalendar") var enableCalendar = true
    @Pref("disabledCalendarIDs") var disabledCalendarIDs: [String] = []
    @Pref("alwaysShowMonthView") var alwaysShowMonthView = false
    @Pref("useCalendarColor") var useCalendarColor = true
    @Pref("useEventIndicators") var useEventIndicators = true
    @Pref("disableActivityDuringEvents") var disableActivityDuringEvents = false
    @Pref("showWeatherOnEmptyDay") var showWeatherOnEmptyDay = false
    @Pref("calendarPeekBeforeEvent") var calendarPeekBeforeEvent = true
    @Pref("calendarLeadMinutes") var calendarLeadMinutes = 5
    @Pref("calendarPeekWhenStarting") var calendarPeekWhenStarting = true
    @Pref("calendarPeekDuration") var calendarPeekDuration = 5.0
    @Pref("playSoundOnEvent") var playSoundOnEvent = false
    @Pref("playHourlyChime") var playHourlyChime = false
    @Pref("notifyWhenTimeToLeave") var notifyWhenTimeToLeave = false
    @Pref("timeToLeaveTransport") var timeToLeaveTransport = TransportMode.drive
    @Pref("timeToLeaveBuffer") var timeToLeaveBuffer = 5

    // Lock screen
    @Pref("playSoundOnLock") var playSoundOnLock = false
    @Pref("playSoundOnUnlock") var playSoundOnUnlock = false
}
