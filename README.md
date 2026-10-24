# TopNotch

A small native macOS notch app using the supplied `logo.png` as its app icon. The original [Alcove analysis](ALCOVE_REVERSE_ENGINEERING.md) informed this independent prototype; this is not the original application's source code.

## What works

- A compact panel centered at the top of the display. Click it to expand; hover expansion is optional. The expanded panel closes automatically shortly after the pointer leaves it.
- A menu bar item with Open, Settings, and Quit actions.
- Current track and play/pause/skip controls for a running Apple Music or Spotify app, using macOS Automation permission.
- Mac battery percentage and charging status.
- The next non-all-day calendar event after calendar access is granted.
- A display setting to show the panel on every connected screen.

The original app's system HUD replacement, weather, AirPods visualizations, browser media controls, lock-screen widgets, licensing, and updater are outside this small prototype.

## Build

Requires macOS 15 or newer and Apple Swift command-line tools. Full Xcode is not required.

```sh
./scripts/build-app.sh
open dist/TopNotch.app
```

The build script creates an ad-hoc signed `dist/TopNotch.app`. macOS may ask for Automation and Calendar permissions when those features are used. For distribution to other Macs without Gatekeeper warnings, sign and notarize it with your own Apple Developer ID.

## Privacy

This prototype has no server component or analytics. It reads battery and calendar data locally. Music/Spotify commands are sent through Apple Events. The app does not collect audio or screen contents.
