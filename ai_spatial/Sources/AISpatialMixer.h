#ifndef AI_SPATIAL_MIXER_H
#define AI_SPATIAL_MIXER_H

#include "AISpatialRenderers.h"

#define AS_SPATIAL_MAX_ACTIVE_EVENTS 8u

typedef struct {
    ASSpatialRenderConfig renderer;
    float max_tail_seconds;
    uint32_t max_active_sources;
    float fade_seconds;
} ASSpatialMixerSettings;

typedef struct {
    uint64_t event_id;
    ASSpatialEventPlan plan;
    uint64_t effect_end_sample;
} ASSpatialScheduledEvent;

typedef struct {
    double sample_rate;
    ASSpatialScene scene;
    ASSpatialMixerSettings settings;
    ASSpatialScheduledEvent events[AS_SPATIAL_MAX_ACTIVE_EVENTS];
    uint32_t event_count;
    uint64_t epoch;
    uint64_t rendered_sample;
} ASSpatialMixer;

void ASSpatialMixerInit(ASSpatialMixer *mixer, double sample_rate, ASSpatialRoute route);
void ASSpatialMixerResetEpoch(ASSpatialMixer *mixer, uint64_t epoch, uint64_t sample);
bool ASSpatialMixerSchedule(ASSpatialMixer *mixer, const ASSpatialEventPlan *event);
void ASSpatialMixerProcess(ASSpatialMixer *mixer, uint64_t epoch, uint64_t start_sample,
                           size_t frames, const float *original_left, const float *original_right,
                           const float *vocal_left, const float *vocal_right,
                           const float *instrumental_left, const float *instrumental_right,
                           float *output_left, float *output_right);

#endif
