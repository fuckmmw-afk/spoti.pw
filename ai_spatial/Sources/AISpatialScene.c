#include "AISpatialScene.h"
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static float clampf(float value, float lo, float hi) {
    return value < lo ? lo : value > hi ? hi : value;
}

static float smoothstep(float t) {
    t = clampf(t, 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

void ASSpatialSceneInit(ASSpatialScene *scene, double rate) {
    if (!scene) return;
    memset(scene, 0, sizeof(*scene));
    scene->sample_rate = rate > 0.0 && isfinite(rate) ? rate : 44100.0;
    scene->next_source_id = 1;
}

bool ASSpatialSceneAddSource(ASSpatialScene *scene, ASSpatialStem stem,
                             ASSpatialPosition position, float distance,
                             float size, float gain, uint64_t *source_id) {
    if (!scene || scene->source_count >= AS_SPATIAL_MAX_SCENE_SOURCES || stem > ASSpatialStemInstrumental ||
        !isfinite(position.x) || !isfinite(position.y) || !isfinite(position.z) ||
        !isfinite(distance) || !isfinite(size) || !isfinite(gain)) return false;
    ASSpatialSource *source = &scene->sources[scene->source_count++];
    source->source_id = scene->next_source_id++;
    source->stem = stem;
    source->position.x = clampf(position.x, -1.0f, 1.0f);
    source->position.y = clampf(position.y, -1.0f, 1.0f);
    source->position.z = clampf(position.z, -1.0f, 1.0f);
    source->distance = clampf(distance, 0.0f, 4.0f);
    source->size = clampf(size, 0.0f, 1.0f);
    source->gain = clampf(gain, 0.0f, 2.0f);
    if (source_id) *source_id = source->source_id;
    return true;
}

float ASSpatialMotionDuration(const ASSpatialMotion *motion, float event_duration,
                              float max_tail_seconds) {
    if (!isfinite(event_duration) || event_duration <= 0) return 0;
    if (!motion) return event_duration;
    if (!isfinite(motion->duration_seconds) || !isfinite(motion->tail_seconds) ||
        !isfinite(max_tail_seconds)) return 0;
    float maximum = event_duration + clampf(max_tail_seconds, 0, .45f);
    float wanted = motion->duration_seconds > 0.01f ? motion->duration_seconds : event_duration;
    return clampf(wanted + clampf(motion->tail_seconds, 0, .45f), .002f, maximum);
}

bool ASSpatialScenePlanEvent(const ASSpatialScene *scene, const ASSpatialEventPlan *event,
                             ASSpatialEventPlan *planned) {
    if (!scene || !event || !planned || !event->selected || event->end_sample <= event->start_sample ||
        event->stem > ASSpatialStemInstrumental || event->motion.type > ASSpatialMotionReflection ||
        !isfinite(event->intensity) || !isfinite(event->priority) || !isfinite(event->motion.intensity) ||
        !isfinite(event->motion.direction)) return false;
    float eventDuration = (float)((double)(event->end_sample - event->start_sample) / scene->sample_rate);
    float duration = ASSpatialMotionDuration(&event->motion, eventDuration, .45f);
    if (duration <= 0) return false;
    *planned = *event;
    planned->intensity = clampf(event->intensity, 0, 1);
    planned->motion.intensity = clampf(event->motion.intensity, 0, 1);
    planned->motion.duration_seconds = duration;
    uint64_t length = (uint64_t)llround(duration * scene->sample_rate);
    planned->end_sample = event->start_sample > UINT64_MAX - length ? UINT64_MAX : event->start_sample + length;
    return planned->end_sample > planned->start_sample;
}

ASSpatialPosition ASSpatialMotionPosition(const ASSpatialSource *source,
                                          const ASSpatialMotion *motion,
                                          double seconds) {
    ASSpatialPosition base = source ? source->position : (ASSpatialPosition){0, -1, 0};
    if (!motion || !isfinite(seconds) || seconds <= 0 || !isfinite(motion->duration_seconds) ||
        motion->duration_seconds <= 0 || seconds >= motion->duration_seconds) return base;
    float u = smoothstep((float)(seconds / motion->duration_seconds));
    float amount = isfinite(motion->intensity) ? clampf(motion->intensity, 0, 1) : 0;
    float direction = motion->direction < 0 ? -1 : 1;
    float swing = sinf((float)(2 * M_PI) * u);
    float lift = sinf((float)M_PI * u); lift *= lift;
    switch (motion->type) {
        case ASSpatialMotionFlyby: base.x -= direction * amount * swing; break;
        case ASSpatialMotionArc:
            base.x -= direction * amount * swing;
            base.y += amount * .5f * lift; break;
        case ASSpatialMotionDepth: base.y += amount * lift; break;
        case ASSpatialMotionBloom:
            base.x += direction * amount * lift;
            base.z += .25f * amount * lift; break;
        case ASSpatialMotionSubtleShift: base.x += direction * amount * .18f * swing; break;
        case ASSpatialMotionReflection:
            base.x += direction * amount * .25f * lift;
            base.y += .25f * amount * lift; break;
    }
    base.x = clampf(base.x, -1, 1); base.y = clampf(base.y, -1, 1); base.z = clampf(base.z, -1, 1);
    return base;
}

float ASSpatialEnvelope(double seconds, float duration_seconds, float fade_seconds,
                        float intensity) {
    if (!isfinite(seconds) || !isfinite(duration_seconds) || !isfinite(fade_seconds) || !isfinite(intensity) || seconds < 0.0 || duration_seconds <= 0.0 || seconds > duration_seconds) return 0.0f;
    float fade = fminf(fmaxf(fade_seconds, 0.002f), duration_seconds * 0.5f);
    float in = smoothstep((float)(seconds / fade));
    float out = smoothstep((float)((duration_seconds - seconds) / fade));
    return clampf(in * out * clampf(intensity, 0.0f, 1.0f), 0.0f, 1.0f);
}
