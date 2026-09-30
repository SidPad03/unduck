# Unduck

A macOS menu-bar utility that restores normal media volume during FaceTime and
other VoIP calls. It works around the system-wide audio ducking caused by the
VoiceProcessingIO audio unit, using a Core Audio process tap to re-inject media
audio at a level you control while leaving the call audio untouched.

> Not the web project of the same name (the DuckDuckGo `!bang` redirector). This
> is a native macOS app.

## Install (Homebrew)

```bash
brew install --cask SidPad03/tap/unduck
```

Releases are signed with a Developer ID and notarized by Apple, so Unduck opens
like any other app. (Releases up to 0.1.7 were ad-hoc signed; for one of those,
right-click **Unduck** in Applications and choose **Open**, or run
`xattr -dr com.apple.quarantine /Applications/Unduck.app`.) Requires macOS 26.1+.
Update later with `brew upgrade --cask unduck`.

(Prefer a plain download? Grab the `.dmg` from
[Releases](https://github.com/SidPad03/unduck/releases) and drag Unduck into Applications.)

## Status (honest)

Phase 0 measurement is **done and passed** (`docs/spike-results.md`): on macOS
26.5, FaceTime's duck is **~25 dB and static** (it doesn't track the far end's
speech), and a boosted signal survives Core Audio's float path. That's the green
light for the inverse-gain strategy this app implements.

- ✅ **Builds clean, packages to a `.pkg`, launches as a menu-bar agent.** (Verified locally.)
- ✅ **Plays correctly on outputs other than the built-in speakers.** Up to
  v0.1.6 anything else (a display, AirPlay, Bluetooth, headphones) came out
  garbled, because the IOProc assumed one buffer layout and got another. Fixed
  and covered by tests; see *Output device layouts* below.
- ⚠️ **The live audio routing (tap → boost → re-inject during a real call) has
  not yet been verified end-to-end on a call.** Core Audio process taps fail
  *silently* when a detail is off, so expect one debugging pass after the first
  real test. The known traps are handled in code; see `Sources/Unduck/AudioRouter.swift`.

## What it does

While a FaceTime call is active, Unduck taps every app's audio *except* the call,
mutes the originals, and replays them boosted by ~the duck depth so they land back
at a normal level after the system attenuates them. The caller's voice stays on
the excluded, unducked path. A duck-aware limiter keeps loud content from clipping
(with an honest "Limiting N dB" readout in the UI).

## Architecture

```
Sources/
  CUnduckRender/        realtime DSP in C (gain smoothing + limiter) - no ARC on the audio thread
  Unduck/
    CoreAudio.swift     defensive HAL property wrappers
    BufferGeometry.swift  locates a channel in any AudioBufferList layout
    AudioRouter.swift   process tap + private aggregate device + IOProc (fail-open teardown)
    CallDetector.swift  polls FaceTime mic activity, debounced
    AppModel.swift      state machine, settings, metering, launch-at-login, device/format-change rebuild
    Updater.swift       self-update via the GitHub releases API
    UnduckApp.swift     MenuBarExtra UI (Liquid Glass materials, media-boost slider, meter)
Resources/              Unduck.entitlements (hardened-runtime audio input)
Tests/UnduckTests/      buffer geometry + DSP core against real device layouts
phase0/                 the throwaway go/no-go measurement tool (see phase0/README.md)
scripts/                icon + packaging + signing + release helpers (bump-cask.sh)
.github/workflows/      build.yml (compile check) + release.yml (push to main -> signed, notarized release)
```

### Output device layouts

There is no single buffer layout to code against, and assuming one is what broke
every output except the built-in speakers before v0.1.7. Measured on macOS 26:

| device                 | IOProc buffers        | rate     |
| ---------------------- | --------------------- | -------- |
| MacBook Pro speakers   | 1 x 2ch interleaved   | 48 kHz   |
| Studio Display speakers| 1 x 8ch interleaved   | 48 kHz   |
| the process tap        | 1 x 2ch interleaved   | 48 kHz   |

So `BufferGeometry.swift` resolves each channel's base pointer and stride from
the buffer list it was actually handed, frames are `bytes / (channels * 4)`, media
goes to the channels the device reports in `kAudioDevicePropertyPreferredChannelsForStereo`,
and every other channel is zeroed (Core Audio does not hand over cleared output
buffers). The tap's format is read-only and fixed at creation, so a device that
changes rate or channel count in place - routine for Bluetooth and AirPlay -
rebuilds the whole graph.

## Build from source

Needs Xcode Command Line Tools (`swiftc`); no Xcode, no Apple Developer account.

```bash
swift build            # compile
scripts/package.sh     # build + icon + Unduck.app + Unduck-<version>.pkg in dist/
```

`package.sh` signs with the Developer ID certificates in your keychain when it
finds them, and ad-hoc otherwise, so a build without an Apple account still works.

`swift test` needs the test frameworks, which ship with Xcode rather than the
command-line tools. With both installed and the CLT selected:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Install manually (DMG)

1. Download `Unduck-<version>.dmg` from the [Releases page](https://github.com/SidPad03/unduck/releases) (or build it below).
2. Open the `.dmg` and drag **Unduck** onto the **Applications** shortcut.
3. Launch it. Releases are notarized, so there is no Gatekeeper warning. An
   ad-hoc build (0.1.7 and earlier, or one built without a Developer ID) is
   blocked as "unidentified developer" the first time - right-click Unduck in
   Applications and choose **Open**, or clear quarantine:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Unduck.app
   ```

Moving from an ad-hoc build to a signed one, macOS asks for **System Audio
Recording** once more: it grants permissions to a signature, and the signature
changed. After that the Developer ID signature stays the same across updates, so
it won't ask again.

### First run
- On the first call, macOS prompts for **System Audio Recording** - allow it (this
  is what lets Unduck capture and re-inject media audio; it's never recorded or sent anywhere).
- **Show Unduck in** (in the popover): Menu Bar, Dock, or Both.
- Toggle **Launch at login** if you want it always on.
- Set **Media boost** to taste (defaults to ~25 dB, matching the measured duck).

## Updates

**Check for Updates…** in the menu (and a quiet check at launch) reads the
[GitHub releases API](https://api.github.com/repos/SidPad03/unduck/releases/latest)
and compares the tag to the running version. If it's newer, one click updates in
place: Unduck downloads the `.dmg`, replaces its own bundle, and restarts. No
installer wizard and no admin prompt.

How the swap works: the DMG is mounted, the new `Unduck.app` is copied out and
checked (its version must match the tag, its signature must verify, and a
Developer ID build only accepts an update signed by the same team), then a
small script waits for Unduck to quit, swaps the bundle and relaunches it. If the
copy fails the old version is moved back, so a failed update can't leave you
without an app.

It falls back to downloading and opening the `.pkg` when a release has no `.dmg`,
or when the app lives somewhere it can't rewrite without privileges. Repo
coordinates live in `Info.plist` (`UnduckUpdateBase`/`Owner`/`Repo`), so a fork
only has to change those.

The tag and the bundle's `CFBundleShortVersionString` must agree - the release
workflow decides the version once and builds with it, because a mismatch would
leave the updater offering an update the user already has, forever.

Why this and not Sparkle: Sparkle wants a Developer-ID-signed app, an EdDSA
keypair, and a zipped-app appcast. That was too heavy while releases were
ad-hoc signed. Now that they're notarized, Sparkle is an option, but this updater
works and already refuses a download signed by another team.

## Building & releasing

CI runs on GitHub's **macOS** runners (`macos-26`). A SwiftUI + CoreAudio app
can't be cross-compiled - the Apple frameworks live only in the macOS SDK - which
is why the old self-hosted Linux runner couldn't build it.

- `.github/workflows/build.yml` - compiles and packages on every push and PR.
- `.github/workflows/release.yml` - on every push to `main` that changes the app,
  tests, builds, signs, notarizes and publishes the next release, then updates
  the Homebrew cask. Nothing to do by hand.

Installers are never committed; they're built from source by the commit that
ships them, so a release can't disagree with the code it claims to be.

### Signing secrets

`release.yml` signs and notarizes when these repository secrets exist, and falls
back to an ad-hoc release (and says so in the notes) when they don't:

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE` | base64 of one `.p12` holding both the **Developer ID Application** and **Developer ID Installer** identities |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12`'s export password |
| `APPLE_ID` | the Apple Account email used for notarization |
| `APPLE_PASSWORD` | an app-specific password for it (account.apple.com → Sign-In and Security) |
| `APPLE_TEAM_ID` | the 10-character team ID |

To sign and notarize a release locally instead, store the credentials once, then
build with `NOTARIZE=1`:

```bash
xcrun notarytool store-credentials notary --apple-id <email> --team-id <TEAMID>
NOTARIZE=1 NOTARY_PROFILE=notary scripts/build-dmg.sh 0.1.8
```

### Releasing

Merge (or push) to `main`. When the push touches the app - `Sources/`,
`Package.swift`, `Resources/`, `VERSION` or the packaging scripts - `release.yml`:

1. picks the version: the next patch after the newest `v*` tag (0.1.8 -> 0.1.9);
2. runs the tests, then builds the `.app`, `.pkg` and `.dmg` with that version;
3. signs them with the Developer ID and notarizes them with Apple;
4. publishes the GitHub Release, which creates the `v<version>` tag on that commit;
5. points `sidpad03/tap/unduck` at the new DMG, through the `HOMEBREW_TAP_SSH_KEY`
   deploy key on the tap repository.

Docs and test-only changes don't release. For a minor or major bump, put the new
version in `VERSION` (`echo 0.2.0 > VERSION`) and push - a `VERSION` newer than
the newest tag is used as-is. To release by hand, run the workflow from the
**Actions** tab, optionally with a version:

```bash
gh workflow run release.yml -f version=0.2.0
```

`scripts/bump-cask.sh` still updates the cask from your Mac, if the workflow's
cask step ever can't.

### Building locally

```bash
scripts/build-dmg.sh [version]   # -> dist/Unduck-<version>.dmg (+ .pkg via package.sh)
scripts/package.sh   [version]   # -> dist/Unduck.app + dist/Unduck-<version>.pkg
```

## Phase 0 tool

`phase0/duckprobe` is the standalone measurement tool that produced the go/no-go
decision. Kept for re-measuring on new OS builds. See `phase0/README.md`.

## Known limits (v1, personal-use scope)

- FaceTime only (add bundle IDs in `CallDetector.swift`).
- Bluetooth-HFP output (AirPods used as the call mic) drops to phone quality and
  can't be helped - a documented dead zone.
- Screen-share audio, browser-hosted calls (Meet in the same browser as media),
  and dynamic-duck handling are out of scope for v1.
