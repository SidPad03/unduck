// Realtime DSP core for Unduck. Called from the Core Audio IOProc block.
// Everything here is realtime-safe: no allocation, no locks, no libc calls
// beyond math. Parameters are plain floats set from the UI thread (a benign
// relaxed race - a single scalar controlling gain - which is fine here).
#ifndef UNDUCK_RENDER_H
#define UNDUCK_RENDER_H

typedef struct UnduckRenderState {
    float sampleRate;
    float targetGain;     // desired linear gain (UI thread writes this)
    float currentGain;    // one-pole-smoothed gain (audio thread)
    float ceilingLinear;  // limiter ceiling in OUR (boosted) output domain
    float envelope;       // limiter gain-reduction state, 1.0 = no reduction
    // one-pole coefficients, derived from sampleRate once in unduck_init so the
    // callback never has to call expf():
    float gainCoeff;      // ~20 ms gain glide (no zipper)
    float atkCoeff;       // ~2 ms limiter attack
    float relCoeff;       // ~120 ms limiter release
    // published for the UI (audio thread writes, UI reads - relaxed, fine for meters):
    float peak;           // last block output peak (linear)
    float limitDB;        // last block max limiting applied (dB), for honest UI
} UnduckRenderState;

// One channel located inside an AudioBufferList.
//
// There is no single layout to code against: Core Audio hands out interleaved
// buffers on some devices and one buffer per channel on others, with anywhere
// from one channel (Bluetooth headset mode) to eight (a Studio Display's
// speaker array) - and the process tap has its own layout independent of the
// device's. So a channel is always addressed as base[frame * stride] and the
// caller resolves base/stride from the buffer list it was actually handed.
//
// stride is in floats: 1 for a dedicated (planar) buffer, N for a channel
// inside an N-channel interleaved buffer.
typedef struct UnduckSrc { const float* base; int stride; } UnduckSrc;
typedef struct UnduckDst { float*       base; int stride; } UnduckDst;

void unduck_init(UnduckRenderState* s, float sampleRate, float gainLinear, float ceilingLinear);
void unduck_set_gain(UnduckRenderState* s, float gainLinear);
void unduck_set_ceiling(UnduckRenderState* s, float ceilingLinear);

// Applies gain + limiting to a stereo source and writes it to a stereo sink.
// Realtime-safe.
//
// inR.base may be NULL for a mono source (the left channel feeds both sides);
// outR.base may be NULL for a mono sink (it gets the L+R downmix). A NULL
// inL.base renders silence, which still glides the gain and limiter state.
//
// inFrames and outFrames are separate because the tap and the output device can
// disagree about block size: only min(inFrames, outFrames) is rendered and any
// remaining output is written as silence, so the input is never over-read and
// the output never carries stale audio.
void unduck_render(UnduckRenderState* s,
                   UnduckSrc inL, UnduckSrc inR, int inFrames,
                   UnduckDst outL, UnduckDst outR, int outFrames);

#endif
