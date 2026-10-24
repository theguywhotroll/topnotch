import AppKit

struct NowPlaying {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double?
    var elapsed: Double?
    var timestamp: Date
    var isPlaying: Bool
    var bundleID: String?
    var artwork: NSImage?
    var link: URL?

    func elapsed(at date: Date) -> Double? {
        guard let elapsed else { return nil }
        let current = isPlaying ? elapsed + date.timeIntervalSince(timestamp) : elapsed
        return duration.map { min(max(current, 0), $0) } ?? max(current, 0)
    }

    var appName: String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var appIcon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum MediaCommand {
    case play, pause, togglePlayPause, next, previous, shuffle, `repeat`

    /// MRMediaRemoteCommand values.
    var remoteValue: Int {
        switch self {
        case .play: 0
        case .pause: 1
        case .togglePlayPause: 2
        case .next: 4
        case .previous: 5
        case .shuffle: 6
        case .repeat: 7
        }
    }
}

/// Publishes the current track from the system now-playing source or from Music/Spotify directly.
@MainActor
final class NowPlayingController {
    var onChange: ((NowPlaying?) -> Void)?
    private(set) var current: NowPlaying?
    private var app: MusicApp = .system
    private var enabled = false
    private var bridge: Process?
    private var bridgeInput: FileHandle?
    private var bridgeOutput: FileHandle?
    private var bridgeBuffer = Data()
    private var bridgeRestarts = 0
    private var pollTimer: Timer?
    private let scriptQueue = DispatchQueue(label: "topnotch.applescript")
    private var artworkTrackID: String?
    private var artworkImage: NSImage?

    func configure(enabled: Bool, app: MusicApp) {
        guard enabled != self.enabled || app != self.app else { return }
        self.enabled = enabled
        self.app = app
        stop()
        guard enabled else { return publish(nil) }
        if app == .system, startBridge() { return }
        startPolling()
    }

    func send(_ command: MediaCommand) {
        if bridge != nil {
            write("c \(command.remoteValue)")
            return
        }
        guard let source = scriptSource else { return }
        scriptQueue.async { AppleScriptMedia.control(command, source: source) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    func seek(to seconds: Double) {
        if bridge != nil {
            write("s \(seconds)")
        } else if let source = scriptSource {
            scriptQueue.async { AppleScriptMedia.seek(seconds, source: source) }
        }
        if var track = current {
            track.elapsed = seconds
            track.timestamp = Date()
            publish(track)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeOutput = nil
        bridgeInput?.closeFile()
        bridge?.terminationHandler = nil
        bridge?.terminate()
        bridge = nil
        bridgeInput = nil
        bridgeBuffer.removeAll()
    }

    private var scriptSource: AppleScriptMedia.Source? {
        switch app {
        case .spotify: .spotify
        case .music: .music
        case .system:
            switch current?.bundleID {
            case "com.spotify.client": .spotify
            case "com.apple.Music": .music
            default: nil
            }
        }
    }

    private func publish(_ track: NowPlaying?) {
        current = track
        onChange?(track)
    }

    // MARK: System source

    private func startBridge() -> Bool {
        guard let script = Bundle.main.path(forResource: "media-bridge", ofType: "pl"),
              let library = Bundle.main.path(forResource: "libTopNotchMedia", ofType: "dylib") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, library]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.bridgeDidExit() }
        }
        do {
            try process.run()
        } catch {
            return false
        }
        bridge = process
        bridgeInput = input.fileHandleForWriting
        bridgeOutput = output.fileHandleForReading
        return true
    }

    private func bridgeDidExit() {
        bridgeOutput?.readabilityHandler = nil
        bridgeOutput = nil
        bridge = nil
        bridgeInput = nil
        guard enabled, app == .system else { return }
        bridgeRestarts += 1
        if bridgeRestarts <= 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.enabled, self.app == .system, self.bridge == nil else { return }
                if !self.startBridge() { self.startPolling() }
            }
        } else {
            startPolling()
        }
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? bridgeInput?.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        bridgeBuffer.append(data)
        while let newline = bridgeBuffer.firstIndex(of: 0x0A) {
            let line = bridgeBuffer.subdata(in: bridgeBuffer.startIndex..<newline)
            bridgeBuffer.removeSubrange(bridgeBuffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            bridgeRestarts = 0
            publish(Self.track(from: object, previous: current))
        }
    }

    private static func track(from object: [String: Any], previous: NowPlaying?) -> NowPlaying? {
        guard let title = object["title"] as? String, !title.isEmpty else { return nil }
        let artist = object["artist"] as? String ?? ""
        let id = object["id"] as? String ?? "\(title)|\(artist)"
        var artwork: NSImage?
        if let encoded = object["artwork"] as? String {
            if previous?.id == id, let existing = previous?.artwork {
                artwork = existing
            } else if let data = Data(base64Encoded: encoded) {
                artwork = NSImage(data: data)
            }
        }
        let rate = object["playbackrate"] as? Double
        return NowPlaying(
            id: id,
            title: title,
            artist: artist,
            album: object["album"] as? String ?? "",
            duration: (object["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil },
            elapsed: object["elapsedtime"] as? Double,
            timestamp: (object["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date(),
            isPlaying: (object["playing"] as? Bool ?? false) || (rate ?? 0) > 0,
            bundleID: object["bundle"] as? String,
            artwork: artwork,
            link: nil
        )
    }

    // MARK: Music and Spotify via Apple Events

    private func startPolling() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let sources: [AppleScriptMedia.Source]
        switch app {
        case .music: sources = [.music]
        case .spotify: sources = [.spotify]
        case .system: sources = [.spotify, .music]
        }
        let knownArtworkID = artworkTrackID
        scriptQueue.async { [weak self] in
            var result: (AppleScriptMedia.Snapshot, AppleScriptMedia.Source)?
            for source in sources {
                if let snapshot = AppleScriptMedia.snapshot(source) {
                    result = (snapshot, source)
                    if snapshot.isPlaying { break }
                }
            }
            var artwork: NSImage?
            if let (snapshot, source) = result, snapshot.id != knownArtworkID {
                artwork = AppleScriptMedia.artwork(source, artworkURL: snapshot.artworkURL)
            }
            DispatchQueue.main.async {
                guard let self, self.pollTimer != nil else { return }
                guard let (snapshot, source) = result else { return self.publish(nil) }
                if snapshot.id != self.artworkTrackID {
                    self.artworkTrackID = snapshot.id
                    self.artworkImage = artwork
                }
                self.publish(NowPlaying(
                    id: snapshot.id,
                    title: snapshot.title,
                    artist: snapshot.artist,
                    album: snapshot.album,
                    duration: snapshot.duration,
                    elapsed: snapshot.position,
                    timestamp: Date(),
                    isPlaying: snapshot.isPlaying,
                    bundleID: source.bundleID,
                    artwork: self.artworkImage,
                    link: snapshot.link
                ))
            }
        }
    }
}

enum AppleScriptMedia {
    enum Source: String {
        case music = "Music"
        case spotify = "Spotify"

        var bundleID: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }
    }

    struct Snapshot {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double?
        let position: Double?
        let isPlaying: Bool
        let artworkURL: URL?
        let link: URL?
    }

    private static let separator = "|||"

    static func snapshot(_ source: Source) -> Snapshot? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty == false else { return nil }
        let fields: String
        switch source {
        case .music:
            fields = "(player state as text) & s & (name of current track) & s & (artist of current track) & s & (album of current track) & s & (duration of current track) & s & (player position) & s & (persistent ID of current track) & s & \"\" & s & \"\""
        case .spotify:
            fields = "(player state as text) & s & (name of current track) & s & (artist of current track) & s & (album of current track) & s & ((duration of current track) / 1000) & s & (player position) & s & (id of current track) & s & (artwork url of current track) & s & (spotify url of current track)"
        }
        let script = "tell application \"\(source.rawValue)\"\nset s to \"\(separator)\"\nreturn \(fields)\nend tell"
        guard let value = run(script)?.stringValue else { return nil }
        let parts = value.components(separatedBy: separator)
        guard parts.count == 9, !parts[1].isEmpty else { return nil }
        let link: URL?
        if parts[8].hasPrefix("spotify:track:") {
            link = URL(string: "https://open.spotify.com/track/" + parts[8].dropFirst("spotify:track:".count))
        } else {
            link = nil
        }
        return Snapshot(
            id: parts[6].isEmpty ? "\(parts[1])|\(parts[2])" : parts[6],
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: Double(parts[4].replacingOccurrences(of: ",", with: ".")),
            position: Double(parts[5].replacingOccurrences(of: ",", with: ".")),
            isPlaying: parts[0].lowercased() == "playing",
            artworkURL: URL(string: parts[7]),
            link: link
        )
    }

    static func artwork(_ source: Source, artworkURL: URL?) -> NSImage? {
        switch source {
        case .music:
            guard let data = run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data else { return nil }
            return NSImage(data: data)
        case .spotify:
            guard let artworkURL, let data = try? Data(contentsOf: artworkURL) else { return nil }
            return NSImage(data: data)
        }
    }

    static func control(_ command: MediaCommand, source: Source) {
        let statement: String
        switch (command, source) {
        case (.play, _): statement = "play"
        case (.pause, _): statement = "pause"
        case (.togglePlayPause, _): statement = "playpause"
        case (.next, _): statement = "next track"
        case (.previous, _): statement = "previous track"
        case (.shuffle, .music): statement = "set shuffle enabled to not shuffle enabled"
        case (.shuffle, .spotify): statement = "set shuffling to not shuffling"
        case (.repeat, .music): statement = "if song repeat is off then\nset song repeat to all\nelse if song repeat is all then\nset song repeat to one\nelse\nset song repeat to off\nend if"
        case (.repeat, .spotify): statement = "set repeating to not repeating"
        }
        _ = run("tell application \"\(source.rawValue)\"\n\(statement)\nend tell")
    }

    static func seek(_ seconds: Double, source: Source) {
        _ = run("tell application \"\(source.rawValue)\" to set player position to \(seconds)")
    }

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}

enum MediaText {
    private static let extras = [
        #"\s*[\(\[](?:[^\)\]]*\b(?:remaster(?:ed)?|live|version|edit|mono|stereo|deluxe|bonus|official|video|audio|lyrics?|explicit|clean|feat\.?|ft\.?)\b[^\)\]]*)[\)\]]"#,
        #"\s+-\s+(?:single|ep|\d{4}\s+remaster(?:ed)?|remaster(?:ed)?(?:\s+\d{4})?|radio edit)$"#
    ]

    static func cleanTitle(_ title: String) -> String {
        var result = title
        for pattern in extras {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.isEmpty ? title : result
    }
}

extension NSImage {
    /// The average color of the image, brightened slightly so it stays visible on black.
    var averageColor: NSColor? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(saturation * 1.15, 1), brightness: max(brightness, 0.72), alpha: 1)
    }
}
