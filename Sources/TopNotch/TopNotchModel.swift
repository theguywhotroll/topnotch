import AppKit
import Combine
import EventKit

@MainActor
final class TopNotchModel: ObservableObject {
    @Published var expanded = false { didSet { onExpansionChange?() } }
    @Published var track: PlayingTrack?
    @Published var batteryPercent: Int?
    @Published var batteryCharging = false
    @Published var eventTitle: String?
    @Published var eventDate: Date?
    @Published var calendarAccess = false
    @Published var expandOnHover = UserDefaults.standard.bool(forKey: "expandOnHover") {
        didSet { UserDefaults.standard.set(expandOnHover, forKey: "expandOnHover") }
    }
    @Published var showOnAllDisplays = UserDefaults.standard.bool(forKey: "showOnAllDisplays") {
        didSet {
            UserDefaults.standard.set(showOnAllDisplays, forKey: "showOnAllDisplays")
            onDisplayChange?()
        }
    }
    var onExpansionChange: (() -> Void)?
    var onDisplayChange: (() -> Void)?
    private let calendar = CalendarService()

    init() { refresh() }

    func refresh() {
        track = MediaService.currentTrack()
        if let battery = BatteryService.level() {
            batteryPercent = battery.percent
            batteryCharging = battery.charging
        }
        calendarAccess = calendar.hasAccess
        let event = calendar.nextEvent()
        eventTitle = event?.title
        eventDate = event?.startDate
    }

    func requestCalendar() { calendar.requestAccess { [weak self] _ in self?.refresh() } }

    func media(_ command: String) {
        MediaService.control(command, source: track?.source)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }
}
