# macos-per-app-volume-tool

Routes a single app's audio to an output device of your choice, at a volume of your
choice, while everything else on the system keeps playing on the default output.
macOS has no per-app volume mixer; this builds one on Core Audio process taps.

It ships as a **menu-bar app**: no Dock icon, no window. Click the speaker icon, pick an
output device next to an app, and the route starts immediately.

## Features

- **Menu-bar only** (`LSUIElement`), a `MenuBarExtra` popover.
- **Immediate apply** — picking a device for an app starts the route right away; picking a
  different one switches it (brief gap while the old pipeline is torn down). There is no
  Start button.
- **Now Playing section** — apps actively producing output (via
  `kAudioProcessPropertyIsRunningOutput`) and every routed app sit at the top of the list;
  everything else that has an audio process object is below.
- **Search field** filters by app name or bundle ID.
- **Per-app volume slider**, 0–200%, default 100%, applied live with a ~20 ms ramp.
- **Per-app ✕** tears the route down, so the app falls back to the system default output.
- **Reset All** does that for every route.
- **Auto-fallback on device disconnect** — a `kAudioHardwarePropertyDevices` /
  `kAudioHardwarePropertyDefaultOutputDevice` listener (debounced 400 ms) tears down any
  route whose destination UID has vanished, and macOS moves the app back to the default.
- **Cleanup when a routed app quits** — the `NSWorkspace` termination notification, plus a
  running-apps check on every refresh, drops the route.

## How it works

Per routed app:

1. A **process tap** (`AudioHardwareCreateProcessTap`) over every audio process object
   belonging to the chosen app, with `muteBehavior = .mutedWhenTapped` — so the app goes
   silent on its normal output for as long as we are reading the tap.
2. A **private aggregate device** containing both the destination output device (as the
   main sub-device) and the tap. The tap must be in the *creation dictionary*; attaching
   it afterwards silently does nothing.
3. One **IOProc** on that aggregate: tapped audio arrives as input, the destination
   device is the output, in the same callback. Gain is applied there with a ~20 ms ramp
   so slider drags don't zipper.

The render block is real-time safe: no allocation, no locks, no ARC, no `self` capture.
It shares a single heap `RenderState` struct with the control thread through an
`UnsafeMutablePointer` captured by value.

## Requirements

- macOS 14.4+ (developed and built on macOS 26.x with the Xcode 26 toolchain)
- Xcode command line tools

## Build

```sh
./Scripts/build-app.sh
```

This runs `swift build -c release`, assembles `build/PerAppAudio.app` (Info.plist,
binary, PkgInfo), and codesigns it. The script picks up a Developer ID or Apple
Development identity automatically if one exists; on this machine none does, so it
signs **ad hoc**.

## Run

```sh
open build/PerAppAudio.app
```

Launch it as a bundle. `swift run`, or running `Contents/MacOS/PerAppAudio`
directly, attributes the TCC grant to the terminal and every buffer comes back as
zeros with no error anywhere.

There is no window and no Dock icon — look for the speaker icon in the menu bar. Quit
from the **Quit** button in the popover (which tears every route down first).

### Manual test

1. Start playing audio in an app (Spotify, a browser tab).
2. Click the menu-bar icon. The playing app should be under **Now Playing**.
3. Pick a *different* output device than the current default in that app's dropdown
   (e.g. system default = soundbar, route to MacBook Pro Speakers). The route starts
   immediately. macOS prompts for system audio recording the first time — allow it,
   then re-pick the device (the first attempt runs before the grant exists).
4. Expected: that app's audio moves to the chosen device and disappears from the
   default one. Everything else keeps playing on the default device.
5. Drag that row's slider — only the routed app's volume changes.
6. Pick a different device in the same dropdown — the audio moves there after a
   short gap.
7. Click the row's **✕** — audio returns to the default output.
8. **Reset All** does the same for every route at once.
9. Route to a Bluetooth speaker, then power it off — within a second the row's route
   disappears and the app is back on the default output.
10. Route an app, then quit that app — the row and its route go away.

If the app is audibly silent everywhere while routed, TCC denied the tap: remove the
entry under **System Settings → Privacy & Security → Screen & System Audio Recording
→ System Audio Recording Only** and relaunch.

## Status and known limitations

- **Ad-hoc signing**: every rebuild changes the code signature, so the system audio
  permission grant resets and you get re-prompted. A real signing identity fixes this.
  Changing the bundle ID (as this phase did, `dev.perappvolume.poc` →
  `dev.perappvolume.app`) resets it too.
- **No persistence**: routes live only as long as the app runs. There is no
  launch-at-login, no settings window, and no saved configuration.
- **A device that briefly drops reads as a disconnect.** The reconcile tears down any
  route whose destination UID is not in the device list; a Bluetooth speaker that
  renegotiates or blips off will lose its route rather than reattach. The 400 ms debounce
  narrows the window but does not close it. Re-pick the device to restore the route.
- **The pipeline runs; the audible result is unverified.** Tap creation, format check,
  aggregate creation, IOProc start, the render block and teardown were all exercised
  against live hardware (routing Firefox to the built-in speakers): callbacks fired
  steadily at `in=1 ch=2 frames=512 out=2`, and teardown left no leaked aggregate
  device. `rms` was `0.0000` throughout, which is exactly what an unsigned test binary
  should produce — TCC denies system audio capture silently and hands back zero-filled
  buffers. Confirming that real audio comes out the other end needs the permission
  grant and a human listening.
- **Tap buffer picked by energy.** The tap is not necessarily input buffer 0: composite
  output devices (powered speakers with a line-in, USB I/O boxes) add their own input
  streams. The render block picks the highest-energy input buffer. A live, loud line-in
  on the destination device would beat the tapped app and get re-rendered.
- **Mute only holds while the IOProc reads.** Stopping the route hands the audio back to
  the default device — which is exactly what ✕ / Reset All / a disconnect rely on. It
  also means the IOProc runs the whole time a route exists; it is never parked.
- **Browser helpers are separate entries.** Chrome's audio comes from
  `com.google.Chrome.helper`, not `com.google.Chrome`; pick the helper. All tabs in a
  Chromium browser share one audio process, so per-tab routing is not possible.
- **No format-change healing.** A destination device that changes sample rate or
  renegotiates its format mid-route will silently kill the audio. Only *disappearance* is
  handled (by teardown); sample-rate/`StreamConfiguration` health listeners and
  rebuild-on-change are not implemented.
- **macOS 26.x tap bug**: taps have been reported to start returning all-zero buffers
  after some minutes, needing a full tap + aggregate rebuild. Not handled.
- macOS 26's `CATapDescription.bundleIDs` / `processRestoreEnabled` (which would let you
  pre-configure a route for an app that isn't running) are deliberately unused.
- `kAudioAggregateDeviceTapAutoStartKey` is deliberately **not** set, unlike the
  reference implementations. With it, the aggregate waits for the tap's first audio
  before running the IOProc, which would make the callback counter useless as a
  "did the pipeline start" signal. A shipping build probably wants it on.

## Layout

```
Sources/AudioRoutingEngine/     core engine
  CoreAudioProperties.swift     AudioObjectID property-read helpers
  AudioOutputDevice.swift       output device enumeration (id, UID, name)
  AudioProcess.swift            audio process enumeration (bundle ID, PIDs, object IDs,
                                is-playing)
  Route.swift                   tap -> aggregate -> IOProc pipeline, gain, teardown
Sources/PerAppAudio/            menu-bar app
  RouteManager.swift            active routes, app/device lists, listeners, reconcile
  MenuBarApp.swift              MenuBarExtra popover, search, rows, sliders
Resources/Info.plist            bundle plist incl. LSUIElement + NSAudioCaptureUsageDescription
Scripts/build-app.sh            build + assemble + codesign the .app
```

## References

Reference implementations are read from `references/` (not committed):

```sh
git clone https://github.com/RaidrDev/AudioRouter references/RaidrDev-AudioRouter
git clone https://github.com/insidegui/AudioCap references/insidegui-AudioCap
```

See `NOTICE` for what was adapted from each and under which license.
