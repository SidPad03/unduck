# Unduck - Phase 0 (`duckprobe`)

This is the **go/no-go tool** for the whole project. Before any real app gets
built, this answers the one question that decides whether Unduck is even
possible: **can FaceTime's audio "duck" be beaten, and is it static or dynamic?**

It's a throwaway command-line tool on purpose - it builds with `swiftc` (no full
Xcode, no Apple Developer account) and plays a 1 kHz tone at a level you control.

## Build & run

```bash
bash phase0/build.sh
./phase0/duckprobe
```

A tone starts playing immediately. Press `h` for commands, `q` to quit.
(`q` or Ctrl-C both stop the audio cleanly; if the process is killed, macOS
reclaims the audio automatically.)

## Commands

| key | does |
|---|---|
| `t` | toggle the tone |
| `+` / `-` | nudge gain ±1 dB |
| `+N` / `-N` | nudge ±N dB (e.g. `+6`) |
| `g <dB>` | set absolute extra gain (e.g. `g 20`) |
| `0` | reset gain to 0 dB |
| `b` | cycle baseline level −12 → −6 → −1 dBFS (headroom probe) |
| `v` | toggle **self-VPIO** - reproduce the duck locally (opens the mic) |
| `s` | status |
| `q` | quit |

## Test 1 - reproduce the duck locally (no call needed, ~2 min)

This proves the mechanism and tests inverse-gain **without** burning a FaceTime
call. It runs our *own* VoiceProcessingIO, which is what causes the duck.

1. Run `./phase0/duckprobe`. You hear the tone.
2. Press `v`. macOS will ask for **microphone** permission the first time - allow
   it (for your terminal). The tone should get **quieter** - that's the duck.
3. Press `+` repeatedly until the tone is back to its original loudness. **The
   number of dB you added ≈ the duck depth.** Note it.
4. Press `v` again to release VPIO. Notice how **abruptly** the tone jumps back
   up while it's still boosted - that's the release-transient hazard the real app
   has to guard against.
5. (Headroom) Press `b` to set baseline `−1 dBFS` (a hot, near-full-scale source),
   then boost again. If it distorts/clips immediately, that's the real limit on
   loud content the real app would have to warn about.

If the tone does **not** duck when you press `v`, write that down - it may mean
the effect is specific to FaceTime's configuration; go to Test 2.

## Test 2 - the real go/no-go (needs your friend on FaceTime, ~10 min)

This is the decisive one. **Use headphones or note you're on speakers** (the mic
will pick up the tone otherwise, but that's fine for measuring level).

1. Run `./phase0/duckprobe`. Tone playing, gain at 0. Listen to the baseline.
2. Start a **FaceTime** call to your friend. The tone should duck (get quieter).
   → **records the duck depth** (Q6). Note roughly how much, or boost to restore
   and read the dB.
3. Boost with `+` until the tone is back to normal loudness. Does it fully
   restore, or does it distort/clip before it gets there?
   → **records invertibility** (the core of strategy B).
4. **The decisive test.** Leave the tone steady at a comfortable level and ask
   your friend to **alternate ~5 seconds talking, ~5 seconds silent**, several
   times, while you listen to the tone:
   - Tone stays **flat** regardless → **STATIC duck → GO.** ✅
   - Tone **dips further when they talk** → **DYNAMIC duck → stop and reassess**
     (fixed inverse gain would pump). ⚠️
   → **records static vs dynamic** (Q1) - the whole ballgame.
5. While still on the call, switch your Mac's **output device** (built-in
   speakers ↔ any headphones/other output you have) and see if **any** device
   is *not* ducked.
   → if one escapes the duck entirely, the project collapses to "route there"
   and everything else is moot (Q7).

Write everything into `../docs/spike-results.md`.

## What the answers mean

| you observed | verdict |
|---|---|
| Some output device isn't ducked at all | Trivial win - route media there. Stop; tell me. |
| Duck is **static** + boosting restores level (some limiting on hot content OK) | **GO - build strategy B.** This is the expected result. |
| Duck is **dynamic** (tone dips when friend talks) | No clean fixed-gain win. Stop and reassess before building. |
| Boosted tone clips/distorts well before restoring | The float path doesn't survive the boost - B is compromised; tell me. |

## Not in this tool yet (deliberately)

- **Spike A** (route our output through VPIO to try for a duck-*exemption*) and
  **Spike C** (aggregate mic to stop VPIO engaging) - both reviews rated these
  unlikely (A = fidelity dead-end, C = premise likely false). I'll add quick
  probes for them **after** Test 1/2 confirm the core, so we don't gold-plate.
- **The real menu-bar app** (process tap, aggregate device, RenderEngine,
  Liquid Glass UI) - that gets built only once Test 2 returns **GO** and names
  the strategy, because its limiter, teardown, and even its architecture depend
  on the numbers you're about to measure.

Full plan + the review corrections:
`~/.claude/plans/unduck-technical-jiggly-coral.md`
