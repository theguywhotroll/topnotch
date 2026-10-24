import SwiftUI

private enum Palette {
    static let background = Color(red: 0.055, green: 0.061, blue: 0.075)
    static let surface = Color(red: 0.12, green: 0.13, blue: 0.16)
    static let muted = Color(red: 0.63, green: 0.65, blue: 0.70)
    static let accent = Color(red: 0.78, green: 0.84, blue: 1.0)
}

struct NotchView: View {
    @ObservedObject var model: TopNotchModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.expanded { expandedView } else { compactView }
        }
        .foregroundStyle(.white)
        .background(Palette.background, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: model.expanded ? 25 : 18, bottomTrailingRadius: model.expanded ? 25 : 18, topTrailingRadius: 8))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: model.expanded ? 25 : 18, bottomTrailingRadius: model.expanded ? 25 : 18, topTrailingRadius: 8)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .onHover { hovering in
            if hovering && model.expandOnHover { model.expanded = true }
        }
        .accessibilityElement(children: .contain)
    }

    private var compactView: some View {
        Button {
            model.expanded = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: model.track?.isPlaying == true ? "waveform" : "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(model.track?.title ?? "TopNotch")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let percent = model.batteryPercent {
                    Text("\(percent)%")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16)
            .frame(width: 240, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open TopNotch")
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("TOPNOTCH")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Open settings")
                Button { model.expanded = false } label: { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Close TopNotch")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.surface)
                    Image(systemName: model.track == nil ? "music.note" : "waveform")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.accent)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.track?.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(model.track.map { "\($0.artist) · \($0.source.rawValue)" } ?? "Start music in Music or Spotify")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 20) {
                Spacer()
                mediaButton("backward.fill", label: "Previous track", command: "previous track")
                mediaButton(model.track?.isPlaying == true ? "pause.fill" : "play.fill", label: model.track?.isPlaying == true ? "Pause" : "Play", command: "playpause")
                mediaButton("forward.fill", label: "Next track", command: "next track")
                Spacer()
            }
            .frame(height: 26)

            Rectangle().fill(.white.opacity(0.10)).frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.eventTitle ?? (model.calendarAccess ? "No upcoming events" : "Calendar access is off"))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if let date = model.eventDate {
                        Text(date, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                if let percent = model.batteryPercent {
                    Image(systemName: model.batteryCharging ? "battery.100percent.bolt" : "battery.100percent")
                    Text("\(percent)%").font(.system(size: 11, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: 384, height: 226)
    }

    private func mediaButton(_ symbol: String, label: String, command: String) -> some View {
        Button { model.media(command) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(model.track == nil)
        .accessibilityLabel(label)
    }
}

struct SettingsView: View {
    @ObservedObject var model: TopNotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("TopNotch").font(.system(size: 30, weight: .semibold))
                Text("A quiet space around your Mac’s notch.")
                    .foregroundStyle(.secondary)
            }
            GroupBox("Behavior") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Expand when pointer hovers over the notch", isOn: $model.expandOnHover)
                    Toggle("Show on all displays", isOn: $model.showOnAllDisplays)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Connections") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Image(systemName: "calendar")
                        Text(model.calendarAccess ? "Calendar connected" : "Calendar access is off")
                        Spacer()
                        if !model.calendarAccess { Button("Enable") { model.requestCalendar() } }
                    }
                    Text("Music and Spotify are checked only while they are running. macOS may ask for Automation access when you use media controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            Spacer()
            Text("Open source recreation · v0.2.0")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 490, height: 360)
    }
}
