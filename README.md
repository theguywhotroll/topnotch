# TopNotch

A native macOS notch app modeled on Alcove, using the supplied `logo.png` as its icon. The [Alcove analysis](ALCOVE_REVERSE_ENGINEERING.md) informed this independent implementation; it contains none of Alcove's code or assets.

## What works

- A black notch at the top of the display that grows into compact activities, alerts, quick peeks, and an expanded view. Displays without a notch get a simulated one with adjustable width and height.
- Click the notch to expand it, or turn on hover expansion. Swipe over it with two fingers to open or close, skip tracks, cycle or dismiss activities. Right-click for media, calendar and Settings actions.
- Now Playing from any app (System source), or from Music or Spotify directly: artwork, progress and seeking, playback controls, artwork-tinted waveform, and a quick peek when the track changes.
- Volume and brightness HUDs. With Accessibility permission, TopNotch handles the volume and brightness keys and replaces the system HUD.
- Charging, low battery and Low Power Mode alerts; Bluetooth connection alerts with AirPods battery levels; Focus alerts with mode names.
- Calendar: today and tomorrow, week strip or month view, calendar colours and filters, Join buttons for Zoom/Meet/Teams/Webex links, reminders before and at the start of events, hourly chime, time to leave, and weather on empty days.
- Settings organised like Alcove's (General, Notifications, Live Activities, Lock Screen, About), and a first-launch welcome window. On first launch TopNotch copies matching settings from an installed Alcove.

See [FEATURE_PARITY.md](FEATURE_PARITY.md) for what differs from Alcove and what has been verified.

## Build

Requires macOS 15 or newer and the Apple command-line tools (Swift and clang). Full Xcode is not required.

```sh
./scripts/build-app.sh
open dist/TopNotch.app
```

The build script creates an ad-hoc signed `dist/TopNotch.app`, including `libTopNotchMedia.dylib`, the helper that reads the system now-playing state. macOS asks for feature permissions when needed. Ad-hoc signatures change on every build, so macOS may ask again for Accessibility after rebuilding. To distribute to other Macs, sign and notarize with your own Developer ID.

## Privacy

TopNotch has no server component or analytics. Battery, audio, display, Bluetooth, Focus and calendar data are read locally. The System media source runs a small helper inside Apple's `/usr/bin/perl` because macOS only lets Apple-signed processes read MediaRemote; it exits with TopNotch. Weather sends approximate coordinates to Open-Meteo, and time to leave asks Apple Maps for travel times; leave those features off to avoid the requests. TopNotch does not capture audio or screen contents.
