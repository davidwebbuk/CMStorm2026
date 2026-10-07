# CMStorm Lights

A small macOS menu bar app that switches on the backlight of **CM Storm keyboards** (Devastator, Octane, Quick Fire Rapid-i style boards and the many rebadged "SINO WEALTH" keyboards) on current Macs.

It's a modern take on [gholker/led-backlight-cmstorm](https://github.com/gholker/led-backlight-cmstorm) and [jafework/CMStorm](https://github.com/jafework/CMStorm). Neither has been updated for Apple silicon or for recent macOS privacy rules.

- Native Swift/SwiftUI, universal binary (Apple silicon and Intel)
- macOS 13 Ventura or later, including macOS 26
- Lives in the menu bar, with no Dock icon

## Why the lights don't work on a Mac

These keyboards wire the backlight to the **Scroll Lock LED**. Windows turns that LED on when you press Scroll Lock. macOS has no Scroll Lock, so it never does. macOS also rewrites the keyboard's LED state whenever Caps Lock changes, the Mac wakes, or the keyboard is plugged in, which switches the backlight off again.

CMStorm Lights sets the Scroll Lock LED through IOKit's HID Manager. It then reapplies it after each of those events, so the lights stay on.

## Features

- **Keyboard Lights** on/off (⌘L in the menu). The state is remembered between launches.
- **Scroll Lock key toggles lights**: press Scroll Lock on the keyboard to toggle the backlight, as on Windows. The app also stops macOS treating that key press as "dim the display" (see Troubleshooting).
- **Keyboards**: lists every external keyboard that has LEDs, and lets you include or exclude each one. Built-in MacBook keyboards are always left alone.
- **Backlight LED**: Scroll Lock by default. If your board is a rebadge that uses a different LED, choose Num Lock, Caps Lock, Compose, Kana or All LEDs.
- **Keep Lights On**: reapplies the state every 3 seconds, for keyboards that still switch off now and then.
- **Launch at Login**.

## Install

1. Download `CMStormLights.zip` from the [Releases](https://github.com/davidwebbuk/CMStorm2026/releases) page, or from the latest successful run on the [Actions](https://github.com/davidwebbuk/CMStorm2026/actions/workflows/build.yml) tab under *Artifacts*.
2. Unzip it and move **CMStorm Lights.app** to `/Applications`.
3. The app is ad-hoc signed, not notarised, so macOS will block it on first launch. Either:
   - open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, or
   - run `xattr -dr com.apple.quarantine "/Applications/CMStorm Lights.app"` in Terminal.
4. Launch it. macOS will ask for **Input Monitoring** permission. Allow it in **System Settings → Privacy & Security → Input Monitoring**, then choose **Relaunch CMStorm Lights** from the menu bar icon (💡).

Input Monitoring is needed because macOS only lets apps open a keyboard's HID interface with this permission, even just to set its LEDs. The app does not log or record keystrokes. It only watches for the Scroll Lock and Caps Lock keys, so it can toggle the lights and reapply them.

## Build from source

You need Xcode 15 or later (or the matching Command Line Tools) on macOS 13 or later.

```sh
./scripts/build-app.sh
open "build/CMStorm Lights.app"
```

This produces `build/CMStorm Lights.app` and `build/CMStormLights.zip`. To sign with your own Developer ID, set `CODESIGN_IDENTITY="Developer ID Application: …"` first.

During development you can run it straight from SwiftPM with `swift run`. Bear in mind that macOS grants the Input Monitoring permission to whichever binary asks for it, which will be Terminal in that case.

Every push builds the app on GitHub Actions. Pushing a tag such as `v1.0.0` also publishes a release with the zip attached.

## Troubleshooting

- **Lights don't come on.** Check that the keyboard appears under *Keyboards* in the menu and that Input Monitoring is granted. Try a different **Backlight LED**: some boards use Num Lock instead.
- **Permission granted but nothing happens.** Use **Relaunch CMStorm Lights**. macOS often applies the new permission only after a restart of the app.
- **Permission stopped working after an update.** Ad-hoc signed builds get a new signature on every build, so macOS treats each one as a new app. Remove *CMStorm Lights* from the Input Monitoring list, add it again, and relaunch.
- **Lights go off when I press Caps Lock or after sleep.** The app reapplies the state after both events. If your keyboard still drops it, switch on **Keep Lights On**.
- **Scroll Lock also dims my display.** macOS treats Scroll Lock as F14, which is its "decrease display brightness" key. While **Scroll Lock Key Toggles Lights** is on, the app remaps Scroll Lock to F20 (which does nothing) on the CM Storm keyboard only. Other keyboards keep F14 brightness. The remap is undone when you quit, turn the option off or exclude the keyboard. If it still dims, the menu will show an error; as a fallback, untick "Decrease display brightness" in **System Settings → Keyboard → Keyboard Shortcuts → Display**.

## Project layout

```
Package.swift                       SwiftPM package (macOS 13+)
Sources/CMStormLights/
  CMStormLightsApp.swift            Menu bar UI (SwiftUI MenuBarExtra)
  KeyboardLightController.swift     HID Manager, permissions, reapply logic, settings
  Keyboard.swift                    Wrapper for one keyboard and its LED elements
  LEDTarget.swift                   Which LED drives the backlight
  ScrollLockRemapper.swift          Stops Scroll Lock acting as F14 (brightness down)
Resources/Info.plist                App bundle metadata (LSUIElement menu bar app)
scripts/build-app.sh                Builds, bundles, signs and zips the .app
scripts/make-icon.swift             Renders the app icon at build time
.github/workflows/build.yml         CI build and tagged releases
```
