#include "AISpatialRenderers.h"
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static float clampf(float value, float lo, float hi) {
    return value < lo ? lo : value > hi ? hi : value;
}

void ASSpatialHRTFReset(ASSpatialHRTFState *state) { if (state) memset(state, 0, sizeof(*state)); }

void ASSpatialHRTFProcess(ASSpatialHRTFState *state, float source_left, float source_right,
                          float azimuth, float distance, float gain, float *left, float *right) {
    if (!left || !right) return;
    if (!state || !isfinite(azimuth) || !isfinite(distance) || !isfinite(gain)) { *left=source_left; *right=source_right; return; }
    azimuth=clampf(azimuth,-1,1); distance=clampf(distance,0,4); gain=clampf(gain,0,1);
    unsigned c=state->cursor++ & 7u;
    state->history_left[c]=source_left; state->history_right[c]=source_right;
    float pan=(azimuth+1)*.5f;
    float nearGain=1.0f/(1.0f+.22f*distance), farGain=nearGain*(.72f+.28f*(1-fabsf(azimuth)));
    /* Eight taps are a small minimum-phase HRTF measured-style approximation;
       coefficients are smooth in azimuth and contain a bounded ITD. */
    unsigned itd=(unsigned)lrintf(fabsf(azimuth)*3.0f);
    float l=0,r=0;
    for (unsigned tap=0;tap<8;tap++) {
        unsigned li=(c+8-tap+(azimuth>0?itd:0))&7u, ri=(c+8-tap+(azimuth<0?itd:0))&7u;
        float w=expf(-.55f*(float)tap)*(tap==0?.72f:.28f/7.0f);
        l += state->history_left[li]*w; r += state->history_right[ri]*w;
    }
    float mid=.5f*(l+r), side=.5f*(l-r);
    float outL=mid*(nearGain*(1-pan)+farGain*pan)+side*.16f;
    float outR=mid*(farGain*(1-pan)+nearGain*pan)-side*.16f;
    *left=source_left+gain*(outL-source_left); *right=source_right+gain*(outR-source_right);
}

void ASSpatialRenderConfigDefault(ASSpatialRenderConfig *config, ASSpatialRoute route) {
    if (!config) return;
    *config = (ASSpatialRenderConfig){
        .route = route, .intensity = 0.65f, .width = 0.75f, .depth = 0.45f,
        .center_protection = 0.75f, .bass_protection = 0.70f,
        .anti_phase_limit = 0.12f, .reflection_gain = 0.06f,
        .reflection_enabled = true, .hrtf_enabled = true
    };
    if (route == ASSpatialRouteMonoSafe) {
        config->width = 0.0f; config->depth = 0.0f; config->reflection_gain = 0.0f;
    } else if (route == ASSpatialRouteSpeakers) {
        config->width = 0.60f; config->anti_phase_limit = 0.08f;
    }
}

void ASSpatialRenderStereo(const ASSpatialRenderConfig *config, ASSpatialPosition position,
                           float source_left, float source_right, float effect_gain,
                           float *left, float *right) {
    if (!left || !right) return;
    ASSpatialRenderConfig fallback;
    if (!config) { ASSpatialRenderConfigDefault(&fallback, ASSpatialRouteUniversalStereo); config = &fallback; }
    float amount = clampf(config->intensity * effect_gain, 0.0f, 1.0f);
    if (amount <= 0 || !isfinite(amount) || !isfinite(source_left) || !isfinite(source_right)) {
        *left=source_left; *right=source_right; return;
    }
    float pan = clampf(position.x, -1.0f, 1.0f) * clampf(config->width, 0.0f, 1.0f);
    /* Distance attenuates the accent, while depth remains a scene cue. */
    float distance = sqrtf(position.x * position.x + position.y * position.y + position.z * position.z);
    float distanceGain = 1.0f / (1.0f + clampf(distance, 0.0f, 3.0f) * clampf(config->depth, 0.0f, 1.0f));
    float mid = 0.5f * (source_left + source_right);
    float side = 0.5f * (source_left - source_right);
    if (config->route == ASSpatialRouteMonoSafe) {
        float mono = mid * distanceGain;
        *left = source_left + amount*(mono-source_left); *right = source_right + amount*(mono-source_right);
        return;
    }
    float spread = clampf(amount * (0.5f + 0.5f * fabsf(pan)), 0.0f, 1.0f);
    float outMid = mid * distanceGain;
    float outSide = side * (1.0f - 0.35f * amount) + outMid * pan * spread;
    if (config->route == ASSpatialRouteHeadphones) {
        /* Compact pinna-independent binaural baseline: equal-power ILD,
           crossfeed and a small controllable reflection. AirPods head tracking
           is optional and therefore never part of this path. */
        float angle = clampf(pan, -1.0f, 1.0f);
        float leftGain = cosf((angle + 1.0f) * (float)M_PI * 0.25f);
        float rightGain = sinf((angle + 1.0f) * (float)M_PI * 0.25f);
        float reflection = (config->reflection_enabled ? clampf(config->reflection_gain, 0.0f, 0.15f) : 0) * amount;
        /* A compact, deterministic HRTF approximation: equal-power ITD/ILD
         * cues with pinna-safe crossfeed. It is intentionally bounded so the
         * vocal centre and treble survive inexpensive Bluetooth paths. */
        float hrtf = config->hrtf_enabled ? 1.0f : 0.0f;
        *left = (outMid * (hrtf * leftGain + (1.0f-hrtf)*.707f) - outSide * (.18f*hrtf)) * (1.0f - reflection) + outMid * reflection;
        *right = (outMid * (hrtf * rightGain + (1.0f-hrtf)*.707f) + outSide * (.18f*hrtf)) * (1.0f - reflection) + outMid * reflection;
    } else {
        if (config->route == ASSpatialRouteSpeakers) outSide = clampf(outSide, -fabsf(outMid) * config->anti_phase_limit - 0.25f, fabsf(outMid) * config->anti_phase_limit + 0.25f);
        *left = outMid + outSide;
        *right = outMid - outSide;
    }
    /* Do not move a protected centre or destroy low-end energy when a caller
       asks for a strong scene. These limits apply to the spatial delta; the
       original stem remains in the mixer. */
    float centre = clampf(config->center_protection, 0.0f, 1.0f);
    float protectedMid = mid * distanceGain;
    *left = *left * (1.0f - centre * 0.35f) + protectedMid * centre * 0.35f;
    *right = *right * (1.0f - centre * 0.35f) + protectedMid * centre * 0.35f;
    float bassGuard = clampf(config->bass_protection, 0.0f, 1.0f);
    *left = *left * (1.0f - 0.12f * bassGuard) + source_left * 0.12f * bassGuard;
    *right = *right * (1.0f - 0.12f * bassGuard) + source_right * 0.12f * bassGuard;
    // Envelope/intensity controls the delta, including distance and reflections.
    // It must reach exact identity at both boundaries and at zero intensity.
    *left = source_left + amount * (*left - source_left);
    *right = source_right + amount * (*right - source_right);
}

static void ASRenderRoute(const ASSpatialRenderConfig *base, ASSpatialRoute route, ASSpatialPosition p,
                          float l, float r, float gain, float *outL, float *outR) {
    ASSpatialRenderConfig local; if (base) local=*base; else ASSpatialRenderConfigDefault(&local,route); local.route=route;
    ASSpatialRenderStereo(&local,p,l,r,gain,outL,outR);
}
void ASSpatialRenderHeadphones(const ASSpatialRenderConfig *c, ASSpatialPosition p,float l,float r,float g,float *oL,float *oR){ASRenderRoute(c,ASSpatialRouteHeadphones,p,l,r,g,oL,oR);}
void ASSpatialRenderSpeakers(const ASSpatialRenderConfig *c, ASSpatialPosition p,float l,float r,float g,float *oL,float *oR){ASRenderRoute(c,ASSpatialRouteSpeakers,p,l,r,g,oL,oR);}
void ASSpatialRenderUniversalStereo(const ASSpatialRenderConfig *c, ASSpatialPosition p,float l,float r,float g,float *oL,float *oR){ASRenderRoute(c,ASSpatialRouteUniversalStereo,p,l,r,g,oL,oR);}
void ASSpatialRenderMonoSafe(const ASSpatialRenderConfig *c, ASSpatialPosition p,float l,float r,float g,float *oL,float *oR){ASRenderRoute(c,ASSpatialRouteMonoSafe,p,l,r,g,oL,oR);}
