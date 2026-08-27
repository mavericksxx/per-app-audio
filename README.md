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
- **Routes persist** — every route you set is saved (bundle ID → device UID, gain) and
  restored at the next launch. Only ✕ or Reset All forgets one; quitting does not.
- **Reattach on disconnect** — a `kAudioHardwarePropertyDevices` /
  `kAudioHardwarePropertyDefaultOutputDevice` listener (debounced 400 ms) tears down any
  route whose destination UID has vanished, so macOS moves the app back to the default —
  but the route stays *pending* (greyed in the row) and comes back on its own when the
  device reappears. Same for an app that quits and relaunches.
- **Zero-buffer watchdog** — a route whose tap stops delivering audio while the app is
  still playing is rebuilt automatically, capped at one rebuild per 30 s and three
  strikes. See the macOS 26 tap bug below.
- **Launch at login** — an `SMAppService.mainApp` toggle in the footer.

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

## Install

This is the normal way to use the app.

```sh
./Scripts/install.sh
```

It builds, quits a running copy gracefully (which tears its routes down and saves
gains), replaces `/Applications/PerAppAudio.app`, and launches it from there. Run it
again after any code change — that is the whole update procedure.

### Get a signing identity first (once)

Without a stable signing identity the app is signed **ad hoc**, and every rebuild
produces a different code signature, so macOS treats each build as a new app and
re-prompts for **System Audio Recording**. A free Apple ID fixes this — no paid
developer program needed:

1. Xcode → Settings → Accounts, add your Apple ID with **+**.
2. Select the account, click **Manage Certificates…**.
3. Click **+** → **Apple Development**, then close.

`build-app.sh` picks the identity up on its own, preferring a *Developer ID
Application* cert over *Apple Development* if both exist. Nothing to configure.

With a real identity the bundle's designated requirement is its *identity* rather than
a per-build hash:

```
designated => identifier "dev.perappvolume.app" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: you (TEAMID)" ...
```

Every rebuild satisfies that same requirement, so the audio permission grant survives
updates instead of resetting. Ad-hoc builds have no such anchor and cannot.

> Switching from ad-hoc to a real cert changes the signature once. Delete the stale
> entry under **System Settings → Privacy & Security → Screen & System Audio Recording
> → System Audio Recording Only** before relaunching, or you will chase a denial that
> is really just a leftover row.

**Launch at login** needs the `/Applications` copy: `SMAppService` refuses to register
a bundle sitting in `build/`, and generally refuses an ad-hoc-signed one too. Installed
from `/Applications` with a real identity, both conditions are satisfied.

If `/Applications` is not writable the script falls back to `~/Applications` and says
so. Launch at login may still refuse a bundle outside `/Applications`.

## Build only

```sh
./Scripts/build-app.sh
```

This runs `swift build -c release`, assembles `build/PerAppAudio.app` (Info.plist,
binary, PkgInfo), and codesigns it — without installing. Useful for a quick compile
check; prefer `install.sh` for anything you actually intend to run.

## Run

```sh
open /Applications/PerAppAudio.app
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
9. Route to a Bluetooth speaker, then power it off — within a second the app is back on
   the default output and the row shows the speaker greyed, "… disconnected". Power the
   speaker back on: the route re-establishes itself within a few seconds.
10. Route an app, then quit that app — the row shows "Waiting for …". Relaunch it and
    start playing: the route comes back.
11. Quit PerAppAudio from the footer and relaunch it: the routes you set are restored,
    at the gains you set.
12. Leave a route playing for 10+ minutes. If the tap goes silent, the watchdog rebuilds
    it within ~10 s (one brief gap on the default device); check
    `log show --last 30m --predicate 'subsystem BEGINSWITH "dev.perappvolume"'`.
13. Run `./Scripts/install.sh` so the app runs from `/Applications`, then toggle
    **Launch at login** and confirm it appears under System Settings → General → Login
    Items. `SMAppService` refuses to register a bundle sitting in `build/`, and generally
    refuses an ad-hoc-signed one; in either case the toggle stays off (by design) with
    the reason in the log.

If the app is audibly silent everywhere while routed, TCC denied the tap: remove the
entry under **System Settings → Privacy & Security → Screen & System Audio Recording
→ System Audio Recording Only** and relaunch.

## Status and known limitations

- **Signing**: builds on this machine now use a free **Apple Development** identity, so
  the designated requirement is identity-based and the system audio permission grant is
  expected to survive rebuilds (verified: the designated requirement is byte-identical
  across rebuilds and pins no per-build hash; a grant actually outliving many updates
  has not been watched over time yet).
  Without an identity the build falls back to ad-hoc, and the grant resets on every
  rebuild. Changing the bundle ID (as an earlier phase did, `dev.perappvolume.poc` →
  `dev.perappvolume.app`) resets it either way. An Apple Development cert expires after
  a year; renewing it in Xcode keeps the same common name, so the requirement holds.
- **Not notarized.** Fine on the machine that built it. Another Mac would get a
  Gatekeeper block, since an Apple Development cert is not a distribution cert.
- **Persistence is UserDefaults, and it is desired state.** One JSON blob under `routes`
  in `dev.perappvolume.app`. There is still no settings window. A saved route for an app
  that is not running keeps a row in the popover, so a long-forgotten route is visible
  rather than silent.
- **A route that fails to start stays failed.** Restore-at-launch (and the login-item
  path especially, since device enumeration and aggregate creation are flakiest right
  after boot) can hit a transient `AudioHardwareCreateAggregateDevice` failure; the row
  then shows the error until you re-pick the device. Reconcile deliberately never retries
  a failed start on its own, so a genuinely broken route cannot become a rebuild loop.
- **A device that briefly drops still tears the route down** — it now comes back on its
  own instead of being lost, but there is an audible gap on the default output while it
  is away, and the 400 ms debounce does not cover a blip shorter than that.
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
- **macOS 26.x tap bug**: taps can start returning all-zero buffers after some minutes,
  needing a full tap + aggregate rebuild. The watchdog handles this, but only by the
  symptom (`kAudioProcessPropertyIsRunningOutput` true, callbacks still arriving, no
  callback carrying energy for 8 s) — it cannot tell that bug apart from a missing
  permission grant or a genuinely silent app, which is why it only ever arms on a tap
  that has already delivered audio, why it rebuilds at most three times, and why the row
  note after that says nothing about the cause. **Unverified**: no zero-buffer episode
  has been observed and healed on real hardware yet.
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
Scripts/install.sh              build, then replace and launch /Applications/PerAppAudio.app
```

## References

Reference implementations are read from `references/` (not committed):

```sh
git clone https://github.com/RaidrDev/AudioRouter references/RaidrDev-AudioRouter
git clone https://github.com/insidegui/AudioCap references/insidegui-AudioCap
```

See `NOTICE` for what was adapted from each and under which license.
