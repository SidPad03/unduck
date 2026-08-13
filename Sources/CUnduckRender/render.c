#include "render.h"
#include <math.h>

// Coefficient for a one-pole filter that settles in roughly `seconds`.
static float one_pole_coeff(float seconds, float sampleRate) {
    return 1.0f - expf(-1.0f / (seconds * sampleRate));
}

void unduck_init(UnduckRenderState* s, float sampleRate, float gainLinear, float ceilingLinear) {
    const float sr = sampleRate > 0.0f ? sampleRate : 48000.0f;
    s->sampleRate    = sr;
    s->targetGain    = gainLinear;
    s->currentGain   = gainLinear;
    s->ceilingLinear = ceilingLinear;
    s->envelope      = 1.0f;
    s->gainCoeff     = one_pole_coeff(0.020f, sr);
    s->atkCoeff      = one_pole_coeff(0.002f, sr);
    s->relCoeff      = one_pole_coeff(0.120f, sr);
    s->peak          = 0.0f;
    s->limitDB       = 0.0f;
}

void unduck_set_gain(UnduckRenderState* s, float gainLinear)      { s->targetGain = gainLinear; }
void unduck_set_ceiling(UnduckRenderState* s, float ceilingLinear){ s->ceilingLinear = ceilingLinear; }

void unduck_render(UnduckRenderState* s,
                   UnduckSrc inL, UnduckSrc inR, int inFrames,
                   UnduckDst outL, UnduckDst outR, int outFrames) {
    if (!outL.base || outFrames <= 0) return;

    const int monoOut = (outR.base == 0);
    const int monoIn  = (inR.base  == 0);

    int n = inFrames < outFrames ? inFrames : outFrames;
    if (n < 0) n = 0;

    const float gainCoeff = s->gainCoeff;
    const float atkCoeff  = s->atkCoeff;
    const float relCoeff  = s->relCoeff;
    const float ceiling   = s->ceilingLinear > 1e-6f ? s->ceilingLinear : 1e-6f;

    float g = s->currentGain;
    const float tg = s->targetGain;
    float env = s->envelope;
    float blockPeak = 0.0f;
    float minEnv = 1.0f;

    for (int i = 0; i < n; ++i) {
        g += (tg - g) * gainCoeff;

        const float l = inL.base ? inL.base[(long)i * inL.stride] : 0.0f;
        const float r = monoIn ? l : inR.base[(long)i * inR.stride];

        float bl = l * g;
        float br = r * g;
        // A mono sink gets the downmix rather than half the programme material.
        if (monoOut) { bl = 0.5f * (bl + br); br = bl; }

        // peak limiter: keep our (pre-system-duck) output at/below the ceiling so
        // that after the system attenuates it, the final level lands under 0 dBFS.
        const float al = fabsf(bl);
        const float ar = fabsf(br);
        const float amax = al > ar ? al : ar;

        const float desired = amax > ceiling ? ceiling / amax : 1.0f;
        env += (desired - env) * (desired < env ? atkCoeff : relCoeff);  // fast attack, slow release
        if (env < minEnv) minEnv = env;

        outL.base[(long)i * outL.stride] = bl * env;
        if (!monoOut) outR.base[(long)i * outR.stride] = br * env;

        // env is non-negative, so the post-limiter peak is just amax scaled by it.
        const float op = amax * env;
        if (op > blockPeak) blockPeak = op;
    }

    // Whatever the tap did not cover: silence, not the buffer's previous contents.
    for (int i = n; i < outFrames; ++i) {
        outL.base[(long)i * outL.stride] = 0.0f;
        if (!monoOut) outR.base[(long)i * outR.stride] = 0.0f;
    }

    s->currentGain = g;
    s->envelope    = env;
    s->peak        = blockPeak;
    s->limitDB     = (minEnv < 1.0f && minEnv > 1e-6f) ? (-20.0f * log10f(minEnv)) : 0.0f;
}
