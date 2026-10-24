# Alcove and TopNotch feature parity

This ledger compares the installed Alcove 1.7.7 with TopNotch 0.4.0. Alcove's settings list comes from its shipped `Localizable.strings` and its saved preferences (`com.henrikruscon.Alcove`); its notch window is excluded from screen capture, so animation timing and exact pixel sizes are approximations. The earlier [static analysis](ALCOVE_REVERSE_ENGINEERING.md) identifies the shipped code and resources.

TopNotch uses Alcove's preference key names where an equivalent exists, and on first launch copies the matching values from an installed Alcove (display, simulated notch, idle activity, capture hiding, gaming, HUD and calendar switches, music source).

## Status

**Verified** means exercised on this Mac (MacBookAir10,1, macOS 26.6.2, built-in 1440×900 display with no notch). **Rendered** means the SwiftUI view was rendered offscreen and inspected. **Compiled** means built but not exercised end to end.

| Alcove area | TopNotch 0.4.0 | Status | Remaining difference |
| --- | --- | --- | --- |
| Notch shape, compact ears, expanded view | Black notch silhouette with flared top corners; compact activities grow into ears; spring transitions; hover bump; expanded view with Now Playing, Calendar and Duo tabs | Rendered; app launch verified | Exact Alcove curves and timings not measured. |
| Display on (all / built-in / main / selected), simulated notch, tuning | All four targets; force simulated notch; width and height tuning; hardware notch detection from the safe area | Compiled; app launch verified (screen capture was unavailable, so the notch was not seen on screen) | — |
| Hide in fullscreen / Mission Control / while gaming / from screen capture; hide menu bar icon; launch at login | All implemented (fullscreen by window bounds, Mission Control via transient window behaviour, gaming by app category) | Compiled | Gaming detection uses the app's declared category, not Game Mode. |
| Idle activity (None, Playing, Calendar, Duo, Most Recent), idle duration, force enable | Implemented | Compiled | — |
| Behaviour: contrast outline, progressive blur, haptics, expand on hover, hover duration | Implemented; progressive blur fades the edges of scrolling content | Compiled | Alcove's blur may differ visually. |
| Gestures: toggle open, skip media, cycle activity, dismiss activity, natural movement | Trackpad swipes over the notch | Compiled | — |
| Now Playing: System, Music, Spotify sources | System source reads MediaRemote through a helper loaded into `/usr/bin/perl` (macOS 15.4+ blocks it for third-party apps); Music and Spotify through Apple Events | **Verified**: the bundled helper streamed Music's title, artist, duration and elapsed time; the app starts and stops the helper | Browser tab focusing is not implemented. |
| Artwork, colour styles, artwork flip, compact waveform, title extras, hide while source active, quick peek, extra control | Implemented; colours come from the artwork's average colour | Rendered (without artwork) | The waveform is animated, not live audio. |
| Live waveform (audio capture) | Not implemented | — | Needs a Core Audio process tap and audio capture permission. |
| Volume and brightness HUDs: replace system HUD, duration, percentage, progress style, speed, output device | Key tap replaces the system HUD (Accessibility); otherwise TopNotch mirrors changes. Brightness uses DisplayServices | Rendered; DisplayServices brightness read verified | Key tap needs Accessibility, which must be re-granted after each ad-hoc rebuild. Decibel style and BetterDisplay integration are absent. |
| Battery: charging, low battery, low power mode, hide percentage, sound | Implemented | Rendered | Uses system sounds, not Alcove's. |
| Connectivity: device alerts, AirPods battery | Connect and disconnect alerts with device symbols and AirPods/Beats battery levels | Rendered | 3D model animations are Alcove's assets and are not included. |
| Focus: alerts, mode names, sleep sound, replace waveform | Mode names from the Do Not Disturb database (Full Disk Access) or Control Center's menu bar item (Accessibility); Intents as a fallback | Rendered | Without either permission, Focus changes are not visible. |
| Calendar: month view, week strip, colours, indicators, calendar filters, join links, open in Calendar, dismiss, quick peeks, sounds, hourly chime, weather on empty day, time to leave | Implemented; time to leave uses MapKit travel estimates | Rendered (access-off state) | Not exercised with live events in this session. |
| Lock Screen widgets | Lock and unlock sounds only | Compiled | Widgets above the lock screen need private window-server APIs. |
| Onboarding and permissions | Welcome window with gestures and a permission list; permissions also in General | Compiled; Settings window opened without error | — |
| File Tray | Listed as Soon | — | Alcove also disables it. |
| Licensing and updates | Not implemented | — | Distribution features of the commercial app. |

## Observed Alcove settings

- General: launch at login, display selection, hide in fullscreen/Mission Control/gaming/screen capture, hide menu bar icon, idle activity, contrast outline, progressive blur, haptics, hover expansion, gestures, notch tuning.
- Notifications: battery, connectivity, Focus, display, and sound each have their own switches, durations, and related controls; the HUDs share linked settings.
- Live Activities: Now Playing and Calendar have quick-peek options; File Tray is disabled and marked Soon.
- Lock Screen: battery, connectivity, Focus, Calendar, Now Playing and Weather widgets with style controls, plus lock/unlock sounds.

No Alcove setting was changed for this work. TopNotch includes none of Alcove's code, sounds, or 3D model videos.
