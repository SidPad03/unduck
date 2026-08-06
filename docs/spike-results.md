# Unduck - Phase 0 spike results

## Environment
- macOS build: **26.5.2 (25F84)**, Apple Silicon
- Measurement: by ear
- Date: 2026-08-02

## Test 1 - local self-VPIO (no call)
- Our own VPIO reproduced a duck, but **shallow (~2 dB)** - restored with 2× `+`.
- Interpretation: a default third-party VPIO ducks lightly; FaceTime uses a much
  deeper ducking configuration (see Test 2). Not a concern; expected.

## Test 2 - real FaceTime call (with friend) - THE DECISION
- Duck confirmed on a real call: **yes**
- Duck depth (by ear): **~25 dB** (restored by boosting to +25 dB extra →
  composite source **+13 dBFS**, i.e. ~13 dB above digital full scale).
- **Float-path survival: CONFIRMED.** The boosted tone went well above 0 dBFS in
  the float path and still came back to normal loudness - so Core Audio carries
  >1.0 samples and applies the duck downstream. This was the big uncertainty for
  whether strategy B can recover loud audio. Good sign.
- **STATIC vs DYNAMIC: STATIC.** Tone stayed "pretty consistent" while the friend
  alternated talking and silent → the duck does NOT track the far end's speech →
  fixed inverse gain will not pump. ← **This is the go/no-go, and it passed.**
- Escape-device check: not tested.

### Pending confirmation (minor, shapes the limiter)
- At +25 dB, was the tone back to ~original loudness, or louder? (pins exact depth)
- At that boost, did it sound clean or start distorting? (real headroom on loud content)

## Decision (§4.5)
- [x] **Static + invertible → GO, build strategy B (inverse gain).**
- Duck is deep (~25 dB), so real near-full-scale music will need a duck-aware
  limiter (a few dB of limiting on loud passages) - the documented caveat, now
  more relevant given the depth.
- Next: build Milestone 1 (headless real-media router) → then the menu-bar app.
