#include "AISpatialRenderers.h"
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static float clampf(float value, float lo, float hi) {
    return value < lo ? lo : value > hi ? hi : value;
}

void ASSpatialRenderConfigDefault(ASSpatialRenderConfig *config, ASSpatialRoute route) {
    if (!config) return;
    *config = (ASSpatialRenderConfig){
        .route = route, .intensity = 0.65f, .width = 0.75f, .depth = 0.45f,
        .center_protection = 0.75f, .bass_protection = 0.70f,
        .anti_phase_limit = 0.12f, .reflection_gain = 0.06f
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
        float reflection = clampf(config->reflection_gain, 0.0f, 0.15f) * amount;
        *left = (outMid * leftGain - outSide * 0.18f) * (1.0f - reflection) + outMid * reflection;
        *right = (outMid * rightGain + outSide * 0.18f) * (1.0f - reflection) + outMid * reflection;
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
