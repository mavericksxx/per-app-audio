# macos-per-app-volume-tool

Routes a single app's audio to an output device of your choice, at a volume of your
choice, while everything else on the system keeps playing on the default output.
macOS has no per-app volume mixer; this builds one on Core Audio process taps.

This repo is currently the **core engine plus a throwaway test harness**. The menu-bar
app it is meant to become does not exist yet.

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

This runs `swift build -c release`, assembles `build/PerAppVolumePOC.app` (Info.plist,
binary, PkgInfo), and codesigns it. The script picks up a Developer ID or Apple
Development identity automatically if one exists; on this machine none does, so it
signs **ad hoc**.

## Run the POC

```sh
open build/PerAppVolumePOC.app
```

Launch it as a bundle. `swift run`, or running `Contents/MacOS/PerAppVolumePOC`
directly, attributes the TCC grant to the terminal and every buffer comes back as
zeros with no error anywhere.

The window has: an app dropdown, an output-device dropdown, Start/Stop, a gain slider
(0–2), and a diagnostics line.

### Manual test

1. Start playing audio in an app (Spotify, a browser tab).
2. Launch the POC, pick that app and a *different* output device than the current
   default (e.g. system default = soundbar, route to MacBook Pro Speakers).
3. Press **Start**. macOS prompts for system audio recording the first time — allow it.
   If the prompt appears you may need to press Stop then Start again.
4. Expected: that app's audio moves to the chosen device and disappears from the
   default one. Everything else keeps playing on the default device.
5. Drag the gain slider — only the routed app's volume changes.
6. Press **Stop** — the app's audio returns to the default output.

### Reading the diagnostics line

`cb=… in=… ch=… frames=… out=… rms=… gain=…`

- `cb` climbing but `rms` pinned at `0.0000` while the app is audibly playing →
  the tap is delivering silence. Almost always TCC (permission denied, or a stale
  grant against a previous ad-hoc signature), or the wrong process was picked.
- `rms` moving but the destination speaker is silent → the output write or the
  device format is wrong, not the tap.
- `cb` not climbing at all → the IOProc never started.

If it stops prompting and just returns silence, remove the entry under **System
Settings → Privacy & Security → Screen & System Audio Recording → System Audio
Recording Only** and relaunch.

## Status and known limitations

- **Ad-hoc signing**: every rebuild changes the code signature, so the system audio
  permission grant resets and you get re-prompted. A real signing identity fixes this.
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
  the default device — by design here, but it means a future menu-bar app must keep the
  IOProc running the whole time the routed app is alive, not park it.
- **Browser helpers are separate entries.** Chrome's audio comes from
  `com.google.Chrome.helper`, not `com.google.Chrome`; pick the helper. All tabs in a
  Chromium browser share one audio process, so per-tab routing is not possible.
- **No device-change handling.** Changing sample rate, unplugging the destination
  device, or a Bluetooth format renegotiation will silently kill the route. Health
  listeners and rebuild-on-change are not implemented.
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
  AudioProcess.swift            audio process enumeration (bundle ID, PIDs, object IDs)
  Route.swift                   tap -> aggregate -> IOProc pipeline, gain, teardown
Sources/PerAppVolumePOC/        throwaway SwiftUI harness
Resources/Info.plist            bundle plist incl. NSAudioCaptureUsageDescription
Scripts/build-app.sh            build + assemble + codesign the .app
```

## References

Reference implementations are read from `references/` (not committed):

```sh
git clone https://github.com/RaidrDev/AudioRouter references/RaidrDev-AudioRouter
git clone https://github.com/insidegui/AudioCap references/insidegui-AudioCap
```

See `NOTICE` for what was adapted from each and under which license.
