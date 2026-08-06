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
    // published for the UI (audio thread writes, UI reads - relaxed, fine for meters):
    float peak;           // last block output peak (linear)
    float limitDB;        // last block max limiting applied (dB), for honest UI
} UnduckRenderState;

void unduck_init(UnduckRenderState* s, float sampleRate, float gainLinear, float ceilingLinear);
void unduck_set_gain(UnduckRenderState* s, float gainLinear);
void unduck_set_ceiling(UnduckRenderState* s, float ceilingLinear);

// Non-interleaved float32, up to 2 channels in / 2 out. in1/out1 may be NULL.
// Writes gained + limited audio into out0/out1. Realtime-safe.
void unduck_render(UnduckRenderState* s,
                   const float* in0, const float* in1, int inCh,
                   float* out0, float* out1, int outCh,
                   int frames);

#endif
