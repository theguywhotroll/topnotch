import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CoreBluetooth
import EventKit
import Intents
import IOBluetooth
import IOKit.ps

enum BatteryService {
    struct Reading: Equatable {
        let percent: Int
        let charging: Bool
        let pluggedIn: Bool
    }

    static func reading() -> Reading? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return Reading(percent: Int((Double(current) / Double(maximum) * 100).rounded()), charging: charging, pluggedIn: pluggedIn)
        }
        return nil
    }
}

enum AudioOutput {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let isBluetooth: Bool
        let isHeadphones: Bool
    }

    static func defaultDevice() -> Device? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        let nameValue = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr
            ? name?.takeRetainedValue() as String? : nil

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE

        var dataSource: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        let headphonesJack = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &dataSource) == noErr && dataSource == 0x6864706E // 'hdpn'

        return Device(id: device, name: nameValue ?? "Output", isBluetooth: bluetooth, isHeadphones: bluetooth || headphonesJack)
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    static func volume(_ device: AudioDeviceID) -> Double? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value != 0
    }

    static func canSetVolume(_ device: AudioDeviceID) -> Bool {
        var address = volumeAddress()
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    static func setVolume(_ value: Double, on device: AudioDeviceID) {
        var address = volumeAddress()
        var volume = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if volume > 0, isMuted(device) { setMuted(false, on: device) }
    }

    static func setMuted(_ muted: Bool, on device: AudioDeviceID) {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

/// Built-in display brightness through the private DisplayServices framework, which works on Apple silicon.
enum BrightnessService {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getter: GetFn? = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setter: SetFn? = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func brightness() -> Double? {
        guard let getter, let display = builtInDisplay else { return nil }
        var value: Float = 0
        guard getter(display, &value) == 0 else { return nil }
        return Double(value)
    }

    static func setBrightness(_ value: Double) -> Bool {
        guard let setter, let display = builtInDisplay else { return false }
        return setter(display, Float(min(max(value, 0), 1))) == 0
    }
}

struct BluetoothDevice: Equatable {
    let address: String
    let name: String
    let symbol: String
    let batteryLeft: Int?
    let batteryRight: Int?
    let batteryCase: Int?
    let batterySingle: Int?

    var lowestBattery: Int? {
        [batteryLeft, batteryRight, batterySingle].compactMap { $0 }.min()
    }
}

enum BluetoothService {
    static var authorized: Bool { CBManager.authorization == .allowedAlways }

    static func connectedDevices() -> [BluetoothDevice] {
        guard CBManager.authorization != .denied else { return [] }
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.filter { $0.isConnected() }.map { device in
            BluetoothDevice(
                address: device.addressString ?? device.name ?? "",
                name: device.name ?? "Bluetooth device",
                symbol: symbol(for: device),
                batteryLeft: battery(device, "batteryPercentLeft"),
                batteryRight: battery(device, "batteryPercentRight"),
                batteryCase: battery(device, "batteryPercentCase"),
                batterySingle: battery(device, "batteryPercentSingle") ?? battery(device, "batteryPercentCombined")
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// AirPods and Beats expose battery levels through undocumented IOBluetoothDevice properties.
    private static func battery(_ device: IOBluetoothDevice, _ selector: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(selector)),
              let value = device.value(forKey: selector) as? Int, value > 0, value <= 100 else { return nil }
        return value
    }

    private static func symbol(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            return device.deviceClassMinor == UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker) ? "hifispeaker.fill" : "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
            if name.contains("mouse") { return "magicmouse.fill" }
            if name.contains("keyboard") { return "keyboard.fill" }
            return "gamecontroller.fill"
        case UInt32(kBluetoothDeviceClassMajorPhone):
            return "iphone"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}

struct FocusState: Equatable {
    let active: Bool
    let name: String?
    let symbol: String
    let identifier: String?

    var isSleep: Bool { identifier?.contains("sleep") == true || name == "Sleep" }

    func matches(_ filter: FocusFilter) -> Bool {
        guard active else { return false }
        switch filter {
        case .any: return true
        case .sleep: return isSleep
        case .doNotDisturb: return identifier?.hasSuffix(".default") == true || name == "Do Not Disturb"
        case .work: return identifier?.contains("work") == true || name == "Work"
        case .personal: return identifier?.contains("personal") == true || name == "Personal"
        }
    }
}

/// Focus status. Mode names come from the Do Not Disturb database when TopNotch has Full Disk Access,
/// otherwise from Control Center's menu bar item through Accessibility, then from Intents.
enum FocusService {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    static var canReadModeNames: Bool {
        FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("Assertions.json").path)
    }

    static func current() -> FocusState? {
        if let state = fromDatabase() { return state }
        if let state = fromMenuBar() { return state }
        if INFocusStatusCenter.default.authorizationStatus == .authorized,
           let focused = INFocusStatusCenter.default.focusStatus.isFocused {
            return FocusState(active: focused, name: nil, symbol: "moon.fill", identifier: nil)
        }
        return nil
    }

    static func requestIntentsAccess(_ completion: @escaping () -> Void) {
        INFocusStatusCenter.default.requestAuthorization { _ in DispatchQueue.main.async { completion() } }
    }

    private static func fromDatabase() -> FocusState? {
        guard let assertions = json("Assertions.json") else { return nil }
        let records = ((assertions["data"] as? [[String: Any]])?.first?["storeAssertionRecords"] as? [[String: Any]]) ?? []
        guard let identifier = records.compactMap({ ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }).last else {
            return FocusState(active: false, name: nil, symbol: "moon", identifier: nil)
        }
        let configurations = (json("ModeConfigurations.json")?["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any]
        let mode = (configurations?[identifier] as? [String: Any])?["mode"] as? [String: Any]
        let name = mode?["name"] as? String ?? defaultName(identifier)
        let symbol = mode?["symbolImageName"] as? String ?? defaultSymbol(identifier)
        return FocusState(active: true, name: name, symbol: symbol, identifier: identifier)
    }

    private static func json(_ file: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func fromMenuBar() -> FocusState? {
        guard AXIsProcessTrusted(),
              let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else { return nil }
        let app = AXUIElementCreateApplication(controlCenter.processIdentifier)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
              let bar = extras, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        for item in children as? [AXUIElement] ?? [] {
            var identifier: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXIdentifierAttribute as CFString, &identifier)
            guard (identifier as? String)?.contains("focus") == true else { continue }
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXDescriptionAttribute as CFString, &description)
            let text = description as? String ?? ""
            let name = text.components(separatedBy: ",").dropFirst().first?.trimmingCharacters(in: .whitespaces)
            return FocusState(active: true, name: name, symbol: name.map(symbolForName) ?? "moon.fill", identifier: nil)
        }
        return FocusState(active: false, name: nil, symbol: "moon", identifier: nil)
    }

    private static func defaultName(_ identifier: String) -> String {
        let key = identifier.components(separatedBy: ".").last ?? ""
        return [
            "default": "Do Not Disturb", "sleep": "Sleep", "driving": "Driving", "workout": "Fitness",
            "fitness": "Fitness", "reading": "Reading", "gaming": "Gaming", "mindfulness": "Mindfulness",
            "personal": "Personal", "work": "Work", "reduceinterruptions": "Reduce Interruptions"
        ][key.lowercased()] ?? "Focus"
    }

    private static func defaultSymbol(_ identifier: String) -> String {
        symbolForName(defaultName(identifier))
    }

    private static func symbolForName(_ name: String) -> String {
        switch name {
        case "Sleep": "bed.double.fill"
        case "Driving": "car.fill"
        case "Fitness": "figure.run"
        case "Reading": "book.fill"
        case "Gaming": "gamecontroller.fill"
        case "Mindfulness": "apple.meditate"
        case "Personal": "person.fill"
        case "Work": "briefcase.fill"
        case "Reduce Interruptions": "apple.intelligence"
        default: "moon.fill"
        }
    }
}

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: NSColor
    let location: String?
    let geoLocation: CLLocationCoordinateValue?
    let joinURL: URL?
    let calendarItemID: String

    var isOngoing: Bool { start <= Date() && end > Date() }

    var joinServiceName: String? {
        guard let host = joinURL?.host?.lowercased() else { return nil }
        if host.contains("zoom") { return "Zoom" }
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("facetime") { return "FaceTime" }
        if host.contains("slack") { return "Slack" }
        return "Meeting"
    }
}

struct CLLocationCoordinateValue: Equatable {
    let latitude: Double
    let longitude: Double
}

struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let source: String
    let color: NSColor
    let subscribed: Bool
}

@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "slack.com"]

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    var onChange: (() -> Void)?

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func calendars() -> [CalendarInfo] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, color: $0.color, subscribed: $0.type == .subscription || $0.type == .birthday)
        }
        .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func events(from start: Date, to end: Date, excluding disabled: Set<String>) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        let calendars = store.calendars(for: .event).filter { !disabled.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { event in
                CalendarEvent(
                    id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: event.calendar.color,
                    location: event.location?.isEmpty == false ? event.location : nil,
                    geoLocation: event.structuredLocation?.geoLocation.map { CLLocationCoordinateValue(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                    joinURL: Self.joinURL(for: event),
                    calendarItemID: event.calendarItemIdentifier
                )
            }
    }

    private static func joinURL(for event: EKEvent) -> URL? {
        let candidates = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in candidates {
            let range = NSRange(text.startIndex..., in: text)
            for match in linkDetector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    static func openInCalendar(_ event: CalendarEvent) {
        let encoded = event.calendarItemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? event.calendarItemID
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum SoundPlayer {
    enum Cue: String {
        case lowBattery = "Funk"
        case event = "Glass"
        case chime = "Tink"
        case lock = "Pop"
        case unlock = "Purr"
        case sleep = "Submarine"
        case notice = "Hero"
    }

    static func play(_ cue: Cue) {
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    /// Mirrors the "Play feedback when volume is changed" system setting.
    static func playVolumeFeedback() {
        guard UserDefaults(suiteName: "NSGlobalDomain")?.integer(forKey: "com.apple.sound.beep.feedback") == 1 else { return }
        let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum WindowEnvironment {
    /// True when the frontmost app has a window covering the whole display, as fullscreen apps and games do.
    static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        guard let displayID = screen.displayID,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
              frontmost.bundleIdentifier != "com.apple.finder" else { return false }
        let bounds = CGDisplayBounds(displayID)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == frontmost.processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let rectDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: rectDictionary) else { return false }
            return rect.equalTo(bounds)
        }
    }

    static var frontmostIsGame: Bool {
        guard let url = NSWorkspace.shared.frontmostApplication?.bundleURL,
              let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String else { return false }
        return category.contains("games")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }

    /// The hardware notch size, when the display has one.
    var hardwareNotch: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    var menuBarHeight: CGFloat {
        let height = frame.maxY - visibleFrame.maxY
        return height > 0 ? height : 24
    }
}
