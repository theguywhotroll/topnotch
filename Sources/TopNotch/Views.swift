import SwiftUI

/// Colors derived from `.primary`, so they suit both the black notch and the light expanded panel.
enum Palette {
    static let muted = Color.primary.opacity(0.55)
    static let faint = Color.primary.opacity(0.14)
    static let surface = Color.primary.opacity(0.08)
}

/// Opening grows with a little overshoot; closing settles without one, like Alcove.
enum NotchMotion {
    static let open = Animation.spring(response: 0.46, dampingFraction: 0.76)
    static let close = Animation.spring(response: 0.36, dampingFraction: 0.92)
    static let content = Animation.spring(response: 0.34, dampingFraction: 0.9)
}

/// A blur of whatever is behind the panel, used for the light expanded notch.
struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The notch silhouette: concave curves where it meets the top edge and rounded lower corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, rect.height / 2, (rect.width - 2 * top) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

extension TopNotchModel {
    func isExpanded(on panel: PanelContext) -> Bool {
        expanded && expandedDisplay == panel.displayID && !panel.hidden
    }

    func topRadius(on panel: PanelContext) -> CGFloat {
        isExpanded(on: panel) ? 14 : 6
    }

    /// The drawn size, including the flared top corners.
    func shapeSize(on panel: PanelContext) -> CGSize {
        let size = size(for: panel)
        return CGSize(width: size.width + 2 * topRadius(on: panel), height: size.height)
    }
}

struct NotchRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The system appearance; the panel itself never forces one.
    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject var model: TopNotchModel
    @ObservedObject var panel: PanelContext

    var body: some View {
        let size = model.shapeSize(on: panel)
        let expanded = model.isExpanded(on: panel)
        // The closed notch stays black to match the hardware; only the open panel follows Light mode.
        let light = expanded && systemScheme == .light
        let shape = NotchShape(topRadius: model.topRadius(on: panel), bottomRadius: expanded ? 26 : min(size.height / 2.4, 14))
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if systemScheme == .light {
                    FrostedBackground()
                }
                Color.black.opacity(light ? 0 : 1)
                content
                    .padding(.horizontal, model.topRadius(on: panel))
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay {
                if model.prefs.contrastOutline, size.height > 0 {
                    shape.stroke(Color.white.opacity(0.22), lineWidth: 1)
                } else if light {
                    shape.stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                }
            }
            // Shadowing just the outline is far cheaper than shadowing the clipped content every frame.
            .background {
                shape.fill(light ? Color.white : Color.black)
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(expanded ? (light ? 0.22 : 0.45) : 0), radius: 18, y: 6)
            }
            .contentShape(shape)
            .onTapGesture {
                if !expanded {
                    model.setExpanded(true, display: panel.displayID)
                    model.haptic()
                }
            }
            .contextMenu { NotchMenu(model: model) }
            .animation(reduceMotion ? nil : expanded ? NotchMotion.open : NotchMotion.close, value: size)
            .animation(reduceMotion ? nil : expanded ? NotchMotion.open : NotchMotion.close, value: expanded)
            .animation(reduceMotion ? nil : NotchMotion.content, value: model.alert?.id)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        let notch = panel.geometry
        if model.isExpanded(on: panel) {
            ExpandedView(model: model, notch: notch)
                .environment(\.colorScheme, systemScheme)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top)).combined(with: AnyTransition(.blurReplace))
                        .animation(NotchMotion.content.delay(0.06)),
                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).animation(.easeOut(duration: 0.14))
                ))
        } else if let alert = model.alert, !panel.hidden {
            Group {
                if alert.style == .peek {
                    PeekView(model: model, alert: alert, notch: notch)
                } else {
                    AlertEarsView(model: model, alert: alert, notch: notch)
                }
            }
            .id(alert.id)
            .transition(.opacity.combined(with: .blurReplace))
        } else if let activity = model.compactActivity, !panel.hidden {
            CompactActivityView(model: model, activity: activity, notch: notch)
                .transition(.opacity.combined(with: .blurReplace))
        }
    }
}

struct NotchMenu: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        if let track = model.track {
            Button(track.isPlaying ? "Pause" : "Play") { model.send(.togglePlayPause) }
            Button("Next") { model.send(.next) }
            Button("Previous") { model.send(.previous) }
            Button(track.link == nil ? "Copy" : "Copy Link") { model.copyTrack() }
            if let name = track.appName { Button("Show in \(name)") { model.showSourceApp() } }
            Divider()
        }
        if let event = model.upcomingEvent {
            if let url = event.joinURL, let service = event.joinServiceName {
                Button("Join \(service)") { NSWorkspace.shared.open(url) }
            }
            Button("Open in Calendar") { CalendarService.openInCalendar(event) }
            Button("Dismiss Event") { model.dismissEvent(event) }
            Divider()
        }
        Button("Settings…") { model.onOpenSettings?() }
        Button("Quit TopNotch") { NSApp.terminate(nil) }
    }
}

// MARK: Compact

struct CompactActivityView: View {
    @ObservedObject var model: TopNotchModel
    let activity: CompactActivity
    let notch: NotchGeometry

    var body: some View {
        let ear = model.compactEarWidth(notch)
        HStack(spacing: 0) {
            leading.frame(width: ear, height: notch.height)
            Spacer(minLength: notch.width)
            trailing.frame(width: ear, height: notch.height)
        }
        .frame(height: notch.height)
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .nowPlaying, .duo:
            ArtworkView(model: model, size: notch.height - 8, radius: 5)
        case .calendar:
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(eventColor)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .nowPlaying:
            if model.focusReplacesWaveform, let focus = model.focus {
                Image(systemName: focus.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 1))
            } else if !model.prefs.disableCompactWaveform {
                WaveformView(model: model, playing: model.track?.isPlaying == true)
                    .frame(width: 18, height: 12)
            }
        case .calendar, .duo:
            Text(model.upcomingEvent.map { CompactTime.until($0.start, now: model.clock) } ?? "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(eventColor)
                .lineLimit(1)
        }
    }

    private var eventColor: Color {
        guard model.prefs.useCalendarColor, let event = model.upcomingEvent else { return .white }
        return Color(nsColor: event.color)
    }
}

enum CompactTime {
    static func until(_ date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ArtworkView: View {
    @ObservedObject var model: TopNotchModel
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image = model.track?.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: radius).fill(Palette.surface)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .rotation3DEffect(.degrees(model.prefs.disableArtworkFlip ? 0 : Double(model.trackChangeCount) * 360), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(response: 0.6, dampingFraction: 0.75), value: model.trackChangeCount)
        .opacity(model.track?.isPlaying == false ? 0.75 : 1)
    }
}

struct WaveformView: View {
    @ObservedObject var model: TopNotchModel
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .frame(width: 2.5, height: max(3, geometry.size.height * level(index, time)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(fill)
    }

    private func level(_ index: Int, _ time: TimeInterval) -> CGFloat {
        guard playing else { return 0.25 }
        let speeds = [5.1, 7.3, 6.2, 8.4]
        let phases = [0.0, 1.3, 2.1, 0.7]
        let wave = sin(time * speeds[index] + phases[index]) * 0.5 + 0.5
        let wobble = sin(time * speeds[3 - index] * 0.43) * 0.5 + 0.5
        return CGFloat(0.25 + 0.75 * (wave * 0.7 + wobble * 0.3))
    }

    private var fill: AnyShapeStyle {
        if model.prefs.mediaColorStyle == .gradient {
            return AnyShapeStyle(LinearGradient(colors: [model.trackTint, model.trackSecondaryTint], startPoint: .bottom, endPoint: .top))
        }
        return AnyShapeStyle(model.mediaTint)
    }
}

// MARK: Alerts

struct AlertEarsView: View {
    @ObservedObject var model: TopNotchModel
    let alert: NotchAlert
    let notch: NotchGeometry

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: alert.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(alert.tint)
                    .contentTransition(.symbolEffect(.replace))
                if let leading = alert.leading {
                    Text(leading)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            Spacer(minLength: notch.width)
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                if let progress = alert.progress {
                    HUDBar(model: model, progress: progress)
                        .frame(width: alert.trailing == nil ? 52 : 40, height: 5)
                }
                if let trailing = alert.trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(alert.progress == nil ? alert.tint : .white)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                if let level = alert.batteryLevel {
                    BatteryGlyph(level: level, charging: alert.charging, low: level <= model.prefs.lowBatteryThreshold)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: notch.height)
    }
}

struct HUDBar: View {
    @ObservedObject var model: TopNotchModel
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.faint)
                Capsule()
                    .fill(fill)
                    .frame(width: max(0, geometry.size.width * min(max(progress, 0), 1)))
                    .shadow(color: model.prefs.hudProgressStyle == .glow ? .white.opacity(0.9) : .clear, radius: 4)
            }
        }
        .animation(animation, value: progress)
    }

    private var fill: AnyShapeStyle {
        switch model.prefs.hudProgressStyle {
        case .white, .glow: AnyShapeStyle(Color.white)
        case .accent: AnyShapeStyle(Color.accentColor)
        case .stylized: AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.55), .white], startPoint: .leading, endPoint: .trailing))
        }
    }

    private var animation: Animation? {
        switch model.prefs.hudSpeed {
        case .instant: nil
        case .fast: .easeOut(duration: 0.08)
        case .smooth: .spring(response: 0.25, dampingFraction: 0.85)
        }
    }
}

struct BatteryGlyph: View {
    let level: Int
    var charging = false
    var low = false

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(charging ? Color.green : low ? Color.red : Color.primary)
                    .frame(width: max(2, 18 * CGFloat(min(max(level, 0), 100)) / 100))
                    .padding(2)
            }
            .frame(width: 24, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.4)).frame(width: 1.5, height: 4)
        }
        .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
    }
}

struct PeekView: View {
    @ObservedObject var model: TopNotchModel
    let alert: NotchAlert
    let notch: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 11) {
                if let image = alert.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: alert.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(alert.tint)
                        .frame(width: 36, height: 36)
                        .background(alert.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(alert.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if alert.kind == .media {
                    WaveformView(model: model, playing: true).frame(width: 18, height: 14)
                } else if let event = alert.event, let url = event.joinURL {
                    Button("Join") { NSWorkspace.shared.open(url) }
                        .buttonStyle(PillButtonStyle(tint: alert.tint))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(tint.opacity(configuration.isPressed ? 0.35 : 0.22), in: Capsule())
            .foregroundStyle(.primary)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: Expanded

struct ExpandedView: View {
    @ObservedObject var model: TopNotchModel
    let notch: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: notch.height)
            Group {
                switch model.tab {
                case .nowPlaying:
                    MediaPanel(model: model, compact: false)
                case .calendar:
                    CalendarPanel(model: model, showGrid: true)
                case .duo:
                    HStack(spacing: 16) {
                        MediaPanel(model: model, compact: true)
                        Rectangle().fill(Palette.faint).frame(width: 1)
                        CalendarPanel(model: model, showGrid: false)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ForEach(ExpandedTab.allCases, id: \.self) { tab in
                Button { model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.tab == tab ? Color.primary : Palette.muted)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
            }
            Spacer(minLength: notch.width + 8)
            if let battery = model.battery {
                if !model.prefs.hideBatteryPercentage {
                    Text("\(battery.percent)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
                BatteryGlyph(level: battery.percent, charging: battery.charging, low: battery.percent <= model.prefs.lowBatteryThreshold)
                    .scaleEffect(0.85)
            }
            Button { model.onOpenSettings?() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Settings")
        }
    }
}

struct MediaPanel: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: TopNotchModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(model: model, size: compact ? 62 : 82, radius: 13)
                    .onTapGesture { model.showSourceApp() }
                if let icon = model.track?.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22).offset(x: 6, y: 6)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.track.map(model.displayTitle) ?? "Not Playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(model.track.map { $0.artist.isEmpty ? ($0.appName ?? "") : $0.artist } ?? "Play something to see it here")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                if let track = model.track, track.duration != nil {
                    Scrubber(model: model, track: track)
                } else if model.track != nil {
                    Text("Live").font(.system(size: 10, weight: .bold)).foregroundStyle(model.mediaTint(for: scheme))
                }
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: compact ? 14 : 22) {
            if !compact { extraControl }
            control("backward.fill", label: "Previous") { model.send(.previous) }
            control(model.track?.isPlaying == true ? "pause.fill" : "play.fill", label: model.track?.isPlaying == true ? "Pause" : "Play", size: 20) {
                model.send(.togglePlayPause)
            }
            control("forward.fill", label: "Next") { model.send(.next) }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
        .disabled(model.track == nil)
        .opacity(model.track == nil ? 0.4 : 1)
    }

    @ViewBuilder
    private var extraControl: some View {
        switch model.prefs.mediaExtraControl {
        case .none: EmptyView()
        case .shuffle: control("shuffle", label: "Shuffle", size: 13) { model.send(.shuffle) }
        case .repeat: control("repeat", label: "Repeat", size: 13) { model.send(.repeat) }
        case .copy: control("doc.on.doc", label: "Copy", size: 13) { model.copyTrack() }
        }
    }

    private func control(_ symbol: String, label: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
    }
}

struct Scrubber: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: TopNotchModel
    let track: NowPlaying
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = track.duration ?? 1
            let elapsed = track.elapsed(at: context.date) ?? 0
            let fraction = dragFraction ?? (duration > 0 ? elapsed / duration : 0)
            HStack(spacing: 7) {
                Text(CompactTime.duration(dragFraction.map { $0 * duration } ?? elapsed))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.faint)
                        Capsule().fill(model.mediaTint(for: scheme))
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                    .frame(height: dragFraction == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in dragFraction = min(max(value.location.x / geometry.size.width, 0), 1) }
                        .onEnded { _ in
                            if let dragFraction { model.seek(to: dragFraction) }
                            dragFraction = nil
                        })
                }
                .frame(height: 12)
                Text("-" + CompactTime.duration(duration - (dragFraction.map { $0 * duration } ?? elapsed)))
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.muted)
            .animation(.easeOut(duration: 0.12), value: dragFraction == nil)
        }
    }
}

struct CalendarPanel: View {
    @ObservedObject var model: TopNotchModel
    let showGrid: Bool

    var body: some View {
        if !model.calendarAccess {
            VStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 22)).foregroundStyle(Palette.muted)
                Text("Calendar access is off").font(.system(size: 12, weight: .semibold))
                Button("Allow Access") { model.requestCalendar() }.buttonStyle(PillButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showGrid && model.prefs.alwaysShowMonthView {
            HStack(alignment: .top, spacing: 16) {
                MonthGrid(model: model).frame(width: 168)
                EventList(model: model)
            }
        } else if showGrid {
            VStack(spacing: 8) {
                WeekStrip(model: model)
                EventList(model: model)
            }
        } else {
            EventList(model: model)
        }
    }
}

struct WeekStrip: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: model.clock)
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                let isToday = calendar.isDate(day, inSameDayAs: today)
                VStack(spacing: 3) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    Text(day.formatted(.dateTime.day()))
                        .font(.system(size: 11, weight: isToday ? .bold : .medium, design: .rounded))
                        .frame(width: 22, height: 22)
                        .background(isToday ? Color.accentColor : .clear, in: Circle())
                    Circle()
                        .fill(model.prefs.useEventIndicators && model.eventDays.contains(day) ? Palette.muted : .clear)
                        .frame(width: 3, height: 3)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct MonthGrid: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: model.displayedMonth)) ?? model.displayedMonth
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        VStack(spacing: 4) {
            HStack {
                Text(monthStart.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.showMonth(offset: -1) } label: { Image(systemName: "chevron.left") }
                Button { model.showMonth(offset: 0) } label: { Image(systemName: "circle.fill").font(.system(size: 5)) }
                Button { model.showMonth(offset: 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(IconButtonStyle())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Palette.muted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(ordered[index]).font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                ForEach(0..<(leading + days), id: \.self) { index in
                    if index < leading {
                        Color.clear.frame(height: 15)
                    } else {
                        let day = calendar.date(byAdding: .day, value: index - leading, to: monthStart) ?? monthStart
                        let isToday = calendar.isDateInToday(day)
                        Text("\(index - leading + 1)")
                            .font(.system(size: 9, weight: isToday ? .bold : .regular, design: .rounded))
                            .frame(width: 16, height: 15)
                            .background(isToday ? Color.accentColor : .clear, in: Circle())
                            .overlay(alignment: .bottom) {
                                if model.prefs.useEventIndicators, !isToday, model.eventDays.contains(day) {
                                    Circle().fill(Palette.muted).frame(width: 2.5, height: 2.5).offset(y: 2)
                                }
                            }
                    }
                }
            }
        }
    }
}

struct EventList: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        let today = model.todayEvents.filter { $0.isAllDay || $0.end > model.clock }
        let tomorrow = model.tomorrowEvents
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                if today.isEmpty {
                    emptyDay
                } else {
                    ForEach(today) { EventRow(model: model, event: $0) }
                }
                if !tomorrow.isEmpty {
                    Text("TMRW")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 4)
                    ForEach(tomorrow.prefix(4)) { EventRow(model: model, event: $0) }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .mask {
            if model.prefs.progressiveBlur {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.88), .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            } else {
                Rectangle()
            }
        }
    }

    @ViewBuilder
    private var emptyDay: some View {
        HStack(spacing: 10) {
            if model.prefs.showWeatherOnEmptyDay, let weather = model.weather {
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your day is clear").font(.system(size: 12, weight: .semibold))
                    Text("\(weather.temperatureCelsius)° · \(weather.condition)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            } else {
                Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(Palette.muted)
                Text(model.events.isEmpty ? "Your day is clear" : "No more events today")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.vertical, 4)
    }
}

struct EventRow: View {
    @ObservedObject var model: TopNotchModel
    let event: CalendarEvent

    var body: some View {
        let tint = model.prefs.useCalendarColor ? Color(nsColor: event.color) : Color.accentColor
        HStack(spacing: 8) {
            Capsule().fill(tint).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(timeText).font(.system(size: 10)).foregroundStyle(event.isOngoing ? tint : Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url = event.joinURL {
                Button("Join") { NSWorkspace.shared.open(url) }.buttonStyle(PillButtonStyle(tint: tint))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { CalendarService.openInCalendar(event) }
        .contextMenu {
            if let url = event.joinURL, let service = event.joinServiceName {
                Button("Join \(service)") { NSWorkspace.shared.open(url) }
            }
            Button("Open in Calendar") { CalendarService.openInCalendar(event) }
            Button("Dismiss Event") { model.dismissEvent(event) }
        }
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        if event.isOngoing { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        let range = "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        return event.location.map { "\(range) · \($0)" } ?? range
    }
}
