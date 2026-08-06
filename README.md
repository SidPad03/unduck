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

First launch: because it's ad-hoc signed (not notarized), macOS may block it once.
Right-click **Unduck** in Applications and choose **Open**, or run
`xattr -dr com.apple.quarantine /Applications/Unduck.app`. Requires macOS 26.1+.
Update later with `brew upgrade --cask unduck`.

(Prefer a plain download? Grab the `.dmg` from
[Releases](https://github.com/SidPad03/unduck/releases) and drag Unduck into Applications.)

## Status (honest)

Phase 0 measurement is **done and passed** (`docs/spike-results.md`): on macOS
26.5, FaceTime's duck is **~25 dB and static** (it doesn't track the far end's
speech), and a boosted signal survives Core Audio's float path. That's the green
light for the inverse-gain strategy this app implements.

- ✅ **Builds clean, packages to a `.pkg`, launches as a menu-bar agent.** (Verified locally.)
- ⚠️ **The live audio routing (tap → boost → re-inject during a real call) has
  not yet been verified on a call.** Core Audio process taps fail *silently* when
  a detail is off, so expect one debugging pass after the first real test. The
  known traps are already handled in code; see `Sources/Unduck/AudioRouter.swift`.

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
    AudioRouter.swift   process tap + private aggregate device + IOProc (fail-open teardown)
    CallDetector.swift  polls FaceTime mic activity, debounced
    AppModel.swift      state machine, settings, metering, launch-at-login, device-change rebuild
    Updater.swift       self-update via the GitHub releases API
    UnduckApp.swift     MenuBarExtra UI (Liquid Glass materials, media-boost slider, meter)
phase0/                 the throwaway go/no-go measurement tool (see phase0/README.md)
scripts/                icon + packaging + release helpers (bump-cask.sh)
.github/workflows/      build.yml (compile check) + release.yml (tag -> .dmg/.pkg release)
```

## Build from source

Needs Xcode Command Line Tools (`swiftc`); no Xcode, no Apple Developer account.

```bash
swift build            # compile
scripts/package.sh     # build + icon + Unduck.app + Unduck-<version>.pkg in dist/
```

## Install manually (DMG)

1. Download `Unduck-<version>.dmg` from the [Releases page](https://github.com/SidPad03/unduck/releases) (or build it below).
2. Open the `.dmg` and drag **Unduck** onto the **Applications** shortcut.
3. Because it's ad-hoc signed (personal use, not notarized), the first launch may be
   blocked as "unidentified developer" - right-click Unduck in Applications and choose
   **Open**, or clear quarantine:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Unduck.app
   ```

### First run
- On the first call, macOS prompts for **System Audio Recording** - allow it (this
  is what lets Unduck capture and re-inject media audio; it's never recorded or sent anywhere).
- **Show Unduck in** (in the popover): Menu Bar, Dock, or Both.
- Toggle **Launch at login** if you want it always on.
- Set **Media boost** to taste (defaults to ~25 dB, matching the measured duck).

## Updates

**Check for Updates…** in the menu (and a quiet check at launch) reads the
[GitHub releases API](https://api.github.com/repos/SidPad03/unduck/releases/latest),
compares the tag to the running version and - if newer - downloads the `.pkg` and
opens the macOS Installer. If a release has no `.pkg` attached it falls back to
the `.dmg`. Repo coordinates live in `Info.plist`
(`UnduckUpdateBase`/`Owner`/`Repo`), so a fork only has to change those.

The tag, the `VERSION` file and the bundle's `CFBundleShortVersionString` must all
agree - the release workflow enforces this, because a mismatch would leave the
updater offering an update the user already has, forever.

Why this and not Sparkle: Sparkle wants a Developer-ID-signed app, an EdDSA
keypair, and a zipped-app appcast - heavy for an ad-hoc-signed `.pkg`. If Unduck
ever goes notarized, switch to Sparkle.

## Building & releasing

CI runs on GitHub's **macOS** runners (`macos-26`). A SwiftUI + CoreAudio app
can't be cross-compiled - the Apple frameworks live only in the macOS SDK - which
is why the old self-hosted Linux runner couldn't build it.

- `.github/workflows/build.yml` - compiles and packages on every push and PR.
- `.github/workflows/release.yml` - on a `v*` tag, builds the `.app`, `.pkg` and
  `.dmg` from the tagged commit and attaches the `.pkg` + `.dmg` to a GitHub
  Release.

Installers are never committed; they're built from source by the tag that ships
them, so a release can't disagree with the code it claims to be.

### Releasing

```bash
echo 0.1.4 > VERSION
git commit -am "Release 0.1.4"
git tag v0.1.4
git push origin main --tags

scripts/bump-cask.sh 0.1.4    # so `brew install` stops serving the old build
```

The workflow fails fast if `VERSION` doesn't match the tag, and re-checks the
version baked into the built bundle - a mismatch would leave the in-app updater
offering an update the user already has. You can also run it from the **Actions**
tab, or:

```bash
gh workflow run release.yml -f version=0.1.4
```

Don't skip `bump-cask.sh`: the cask pins an exact version and sha256, so
`brew install --cask` keeps serving the previous build until the tap is updated.

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
- Non-interleaved float output assumed (built-in/USB/AirPods - the common case).
- Bluetooth-HFP output (AirPods used as the call mic) drops to phone quality and
  can't be helped - a documented dead zone.
- Screen-share audio, browser-hosted calls (Meet in the same browser as media),
  and dynamic-duck handling are out of scope for v1.
