# Alcove macOS app: static reverse engineering

## Artifact and method

- Input: `/Users/gripadmin/Downloads/Alcove.dmg`, SHA-256 `17c481ffa9af91fc76e2ba9995f96750538bf171e5eb2be602c07255f4d944e5`.
- The read-only mounted image contains `Alcove.app`. Its bundle identifier is `com.henrikruscon.Alcove`, version `1.7.7` (build `199`), with a declared minimum of macOS 15.0.
- The main executable is a 13,627,728-byte universal Mach-O containing `arm64` and `x86_64` slices. It is a native Swift application using AppKit and SwiftUI, not an Electron application.
- The app is signed by Developer ID Application: Henrik Ruscon (`287NUTSP69`), has a stapled notarization ticket, and passes `codesign --verify --deep --strict` on this machine. This verifies the mounted bytes against their signature; it is not a broader security audit.
- REA `inspect_artifact` inventoried the app bundle with complete container-entry coverage: Evidence `ev_3801d1979804ee9e0848f0c755f5268290b46012b2ae4d97a79e000451fe6789`. The inventory reports 63 distinct nodes and 64 occurrences. The installed REA CLI is version 6.7.0. Its MCP registration is absent in this session, and no native decompiler provider is configured, so function-level behavior remains unverified.

## App structure

`LSUIElement = true` marks Alcove as an agent-style macOS app without a conventional Dock presence. Its named classes include `NotchPanel`, `NotchBackdropPanel`, `NotchController`, `NotchCoordinator`, `NotchExpandedView`, `NotchQuickPeekView`, and `NotchSwipeMonitor`. These support a strong inference that a custom panel at the display notch coordinates compact, expanded, peek, and gesture states. The exact window levels, timing, and state transitions require runtime observation or decompilation.

The bundle contains `AlcoveHelper.xpc`, an application XPC service whose declared identifier is `com.apple.controlcenter.AlcoveHelper`. The main binary contains `XPCManager`, and the helper contains XPC listener and BetterDisplay request names. The exact messages between them have not been traced.

## Feature map

| Area | Shipped evidence | Supported conclusion |
| --- | --- | --- |
| Media | `MediaManager`, `MusicController`, `BrowserController`, `MediaKeyManager`; private `MediaRemote` linkage; Music/Spotify/Safari/Chrome/Dia Apple Events exceptions; playback and source menu labels | The app presents and controls media from system, music app, and browser sources. Source selection and command routing remain untraced. |
| Audio visualization | `AudioManager`, `NSWaveformView`, AVFoundation/CoreAudio linkage; audio capture permission string; `Use live waveform` setting | Live waveform is an offered feature. Its capture pipeline and processing are unknown. |
| Calendar and weather | `CalendarManager`, `CalendarController`, `WeatherManager`; EventKit/WeatherKit linkage; calendar/location entitlements; event, time-to-leave, and weather settings | Calendar events and weather are designed for notch and lock-screen presentation. Timing and data flow are unverified. |
| Battery and connectivity | `BatteryManager`, `BluetoothController`, `ConnectivityManager`; CoreBluetooth/IOBluetooth/IOKit linkage; bundled AirPods model videos | Battery and connected audio device alerts are implemented or prepared. Exact device polling and animations are unverified. |
| System HUDs | `VolumeManager`, `BrightnessManager`, `SoundManager`; private `DisplayServices` linkage; accessibility onboarding text about replacing system HUDs | Alcove intends to replace or augment volume/brightness system HUDs. The interception mechanism needs deeper analysis. |
| Focus and lock screen | `FocusManager`, `LockController`, `LockPanel`, `GameManager`; focus, lock-screen, and gaming settings | There are dedicated presentation rules for focus, lock, and gaming states. Exact detection and rendering are unverified. |
| Updates and licensing | `UpdateManager`, `LicenseManager`, `LicenseAPI`; `api.tryalcove.com`, `api.tryalcove.com/updates/latest`, purchase/recovery URLs; 72-hour trial and three-device labels | The binary contains update and license flows. The URLs are static strings; no network exchange was observed. |

The settings also expose display targeting, notch size, a simulated notch, hover expansion, horizontal and vertical gestures, haptics, progressive blur, screen-capture hiding, fullscreen/Mission Control hiding, launch at login, and HUD timing/styles. A `File Tray` tab and `FileTraySettingsView` exist, but the inspected text does not establish a working file-tray feature.

## System access and dependencies

The app declares Apple Events, calendar, location, WeatherKit, network client, and keychain access entitlements; `com.apple.security.app-sandbox` is `false`. The Info.plist includes usage descriptions for Apple Events, audio capture, Bluetooth, calendar, local network, and location. Apple Events exceptions name Spotify, Music, Safari, Chrome, and Dia. Its dynamic links include private macOS `MediaRemote` and `DisplayServices` frameworks, which may affect compatibility across OS releases.

Strings in the main executable name BetterDisplay's bundle identifier and notification/request names. The XPC helper also contains `com.betterdisplay.BetterDisplay.request`. This supports a BetterDisplay integration hypothesis, but the precise conditions and behavior were not observed.

## Evidence limits and next investigation

This pass inspected shipped files, plist declarations, localization text, Swift/Objective-C metadata strings, dynamic library linkage, code signatures, and REA's package inventory. It did **not** launch Alcove, exercise permissions, capture traffic, or decompile functions. Names and UI strings show what the binary contains; they do not prove a feature's full runtime behavior.

The highest-value next pass is a bounded runtime capture of onboarding, compact/expanded notch states, media changes, HUD replacement, and Settings, followed by focused native decompilation of `NotchCoordinator`, `MediaManager`, `VolumeManager`, and `XPCManager` once a provider is available. Preserve this DMG hash when comparing future builds.
