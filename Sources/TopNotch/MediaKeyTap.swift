import AppKit

enum MediaKey {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

/// Intercepts the volume and brightness keys so TopNotch can show its own HUD instead of the system's.
/// Requires Accessibility permission.
final class MediaKeyTap {
    /// Return true to consume the key event. `fine` is set when Option and Shift are held.
    /// Only key-down events should change anything; key-up asks whether the press was handled.
    var handler: ((MediaKey, _ fine: Bool, _ isDown: Bool) -> Bool)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = nsEvent.data1
        let code = (data & 0xFFFF0000) >> 16
        let isDown = ((data & 0xFF00) >> 8) == 0x0A
        let key: MediaKey
        switch code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        default: return Unmanaged.passUnretained(event)
        }
        let fine = nsEvent.modifierFlags.contains([.option, .shift])
        // The tap's run loop source is on the main run loop, so this runs on the main thread.
        guard let handler, handler(key, fine, isDown) else { return Unmanaged.passUnretained(event) }
        return nil
    }
}
