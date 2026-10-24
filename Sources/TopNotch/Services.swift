import AppKit
import EventKit
import IOKit.ps

enum MediaSource: String {
    case music = "Music"
    case spotify = "Spotify"

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }
}

struct PlayingTrack {
    let source: MediaSource
    let title: String
    let artist: String
    let isPlaying: Bool
}

enum MediaService {
    static func currentTrack() -> PlayingTrack? {
        for source in [MediaSource.spotify, .music] {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == source.bundleID }) else { continue }
            let script = "tell application \"\(source.rawValue)\" to get (player state as text) & \"|||\" & (name of current track) & \"|||\" & (artist of current track)"
            var error: NSDictionary?
            guard let value = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
                  error == nil else { continue }
            let parts = value.components(separatedBy: "|||")
            guard parts.count == 3 else { continue }
            return PlayingTrack(source: source, title: parts[1], artist: parts[2], isPlaying: parts[0].lowercased() == "playing")
        }
        return nil
    }

    static func control(_ command: String, source: MediaSource?) {
        guard let source, ["playpause", "next track", "previous track"].contains(command) else { return }
        let script = "tell application \"\(source.rawValue)\" to \(command)"
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

enum BatteryService {
    static func level() -> (percent: Int, charging: Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return (Int((Double(current) / Double(maximum) * 100).rounded()), charging)
        }
        return nil
    }
}

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func nextEvent() -> EKEvent? {
        guard hasAccess else { return nil }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
            .first
    }
}
