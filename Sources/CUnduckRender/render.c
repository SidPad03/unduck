#include "render.h"
#include <math.h>

void unduck_init(UnduckRenderState* s, float sampleRate, float gainLinear, float ceilingLinear) {
    s->sampleRate   = sampleRate > 0.0f ? sampleRate : 48000.0f;
    s->targetGain   = gainLinear;
    s->currentGain  = gainLinear;
    s->ceilingLinear = ceilingLinear;
    s->envelope     = 1.0f;
    s->peak         = 0.0f;
    s->limitDB      = 0.0f;
}

void unduck_set_gain(UnduckRenderState* s, float gainLinear)      { s->targetGain = gainLinear; }
void unduck_set_ceiling(UnduckRenderState* s, float ceilingLinear){ s->ceilingLinear = ceilingLinear; }

void unduck_render(UnduckRenderState* s,
                   const float* in0, const float* in1, int inCh,
                   float* out0, float* out1, int outCh,
                   int frames) {
    const float sr = s->sampleRate;
    // one-pole time constants (computed per-block; a few expf() per callback is free)
    const float gainCoeff = 1.0f - expf(-1.0f / (0.020f * sr)); // ~20 ms gain glide (no zipper)
    const float atkCoeff  = 1.0f - expf(-1.0f / (0.002f * sr)); // ~2 ms limiter attack
    const float relCoeff  = 1.0f - expf(-1.0f / (0.120f * sr)); // ~120 ms limiter release
    const float ceiling   = s->ceilingLinear > 1e-6f ? s->ceilingLinear : 1e-6f;

    float g   = s->currentGain;
    const float tg = s->targetGain;
    float env = s->envelope;
    float blockPeak = 0.0f;
    float minEnv = 1.0f;

    for (int i = 0; i < frames; ++i) {
        g += (tg - g) * gainCoeff;

        const float l = in0 ? in0[i] : 0.0f;
        const float r = (inCh >= 2 && in1) ? in1[i] : l;

        float bl = l * g;
        float br = r * g;

        // peak limiter: keep our (pre-system-duck) output at/below the ceiling so
        // that after the system attenuates it, the final level lands under 0 dBFS.
        float amax = fabsf(bl) > fabsf(br) ? fabsf(bl) : fabsf(br);
        float desired = 1.0f;
        if (amax > ceiling) desired = ceiling / amax;
        if (desired < env) env += (desired - env) * atkCoeff;   // fast attack
        else               env += (desired - env) * relCoeff;   // slow release
        if (env < minEnv) minEnv = env;

        const float ol = bl * env;
        const float orr = br * env;
        if (out0) out0[i] = ol;
        if (outCh >= 2 && out1) out1[i] = orr;

        const float op = fabsf(ol) > fabsf(orr) ? fabsf(ol) : fabsf(orr);
        if (op > blockPeak) blockPeak = op;
    }

    s->currentGain = g;
    s->envelope    = env;
    s->peak        = blockPeak;
    s->limitDB     = (minEnv < 1.0f && minEnv > 1e-6f) ? (-20.0f * log10f(minEnv)) : 0.0f;
}
