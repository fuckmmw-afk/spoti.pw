#include "AISpatialMixer.h"
#include <math.h>
#include <string.h>

static float clampf(float value, float lo, float hi) {
    return value < lo ? lo : value > hi ? hi : value;
}

static float softclip(float value) {
    if (!isfinite(value)) return 0.0f;
    return tanhf(value * 0.92f) / tanhf(0.92f);
}

void ASSpatialMixerInit(ASSpatialMixer *mixer, double rate, ASSpatialRoute route) {
    if (!mixer) return;
    memset(mixer, 0, sizeof(*mixer));
    mixer->sample_rate = rate > 0 && isfinite(rate) ? rate : 44100.0;
    ASSpatialSceneInit(&mixer->scene, mixer->sample_rate);
    ASSpatialRenderConfigDefault(&mixer->settings.renderer, route);
    mixer->settings.max_tail_seconds = 0.45f;
    mixer->settings.max_active_sources = 3;
    mixer->settings.fade_seconds = 0.018f;
}

void ASSpatialMixerResetEpoch(ASSpatialMixer *mixer, uint64_t epoch, uint64_t sample) {
    if (!mixer) return;
    mixer->epoch = epoch;
    mixer->rendered_sample = sample;
    mixer->event_count = 0;
}

bool ASSpatialMixerSchedule(ASSpatialMixer *mixer, const ASSpatialEventPlan *event) {
    if (!mixer || !event || !event->selected || event->stream_epoch != mixer->epoch) return false;
    ASSpatialEventPlan plan;
    if (!ASSpatialScenePlanEvent(&mixer->scene, event, &plan)) return false;
    uint32_t limit = mixer->settings.max_active_sources;
    if (!limit || limit > AS_SPATIAL_MAX_ACTIVE_EVENTS) limit = AS_SPATIAL_MAX_ACTIVE_EVENTS;
    /* A new high-priority event may replace the weakest pending event. */
    if (mixer->event_count >= limit) {
        uint32_t weakest = 0;
        for (uint32_t i = 1; i < mixer->event_count; i++) if (mixer->events[i].plan.priority < mixer->events[weakest].plan.priority) weakest = i;
        if (plan.priority <= mixer->events[weakest].plan.priority) return false;
        mixer->events[weakest] = (ASSpatialScheduledEvent){plan.event_id, plan, plan.end_sample};
        return true;
    }
    mixer->events[mixer->event_count++] = (ASSpatialScheduledEvent){plan.event_id, plan, plan.end_sample};
    return true;
}

static const ASSpatialScheduledEvent *bestEvent(const ASSpatialMixer *mixer, uint64_t sample,
                                                ASSpatialStem stem) {
    const ASSpatialScheduledEvent *best = NULL;
    for (uint32_t i = 0; i < mixer->event_count; i++) {
        const ASSpatialScheduledEvent *event = &mixer->events[i];
        if (event->plan.stream_epoch != mixer->epoch || event->plan.stem != stem || sample < event->plan.start_sample || sample >= event->effect_end_sample) continue;
        if (!best || event->plan.priority > best->plan.priority) best = event;
    }
    return best;
}

void ASSpatialMixerProcess(ASSpatialMixer *mixer, uint64_t epoch, uint64_t start_sample,
                           size_t frames, const float *original_left, const float *original_right,
                           const float *vocal_left, const float *vocal_right,
                           const float *instrumental_left, const float *instrumental_right,
                           float *output_left, float *output_right) {
    if (!mixer || !output_left || !output_right || !frames) return;
    if (epoch != mixer->epoch) ASSpatialMixerResetEpoch(mixer, epoch, start_sample);
    for (size_t i = 0; i < frames; i++) {
        uint64_t sample = start_sample + i;
        float outL = original_left ? original_left[i] : 0.0f;
        float outR = original_right ? original_right[i] : 0.0f;
        bool spatialized = false;
        const ASSpatialScheduledEvent *vocal = bestEvent(mixer, sample, ASSpatialStemVocal);
        const ASSpatialScheduledEvent *instrumental = bestEvent(mixer, sample, ASSpatialStemInstrumental);
        const ASSpatialScheduledEvent *event = vocal ? vocal : instrumental;
        const float *srcL = vocal ? vocal_left : instrumental_left;
        const float *srcR = vocal ? vocal_right : instrumental_right;
        if (event && srcL && srcR) {
            double elapsed = (double)(sample - event->plan.start_sample) / mixer->sample_rate;
            double duration = (double)(event->effect_end_sample - event->plan.start_sample) / mixer->sample_rate;
            float envelope = ASSpatialEnvelope(elapsed, (float)duration, mixer->settings.fade_seconds, event->plan.intensity);
            spatialized = envelope > 0.0f;
            ASSpatialSource source = {0};
            source.stem = event->plan.stem;
            source.position = (ASSpatialPosition){0, -1, 0};
            for (size_t s = 0; s < mixer->scene.source_count; s++) if (mixer->scene.sources[s].stem == event->plan.stem) { source = mixer->scene.sources[s]; break; }
            ASSpatialPosition position = ASSpatialMotionPosition(&source, &event->plan.motion, elapsed);
            float spatialL = 0, spatialR = 0;
            ASSpatialRenderStereo(&mixer->settings.renderer, position, srcL[i], srcR[i], envelope, &spatialL, &spatialR);
            /* Delta replacement is the key invariant: the selected stem is
               already present in Original, so only its spatial difference is
               mixed back. This prevents doubled vocals/instrumentals. */
            float deltaL = spatialL - srcL[i], deltaR = spatialR - srcR[i];
            float protection = event->plan.stem == ASSpatialStemVocal ? mixer->settings.renderer.center_protection : mixer->settings.renderer.bass_protection;
            float deltaGain = 1.0f - 0.18f * clampf(protection, 0, 1);
            outL += deltaL * deltaGain;
            outR += deltaR * deltaGain;
        }
        /* With no active effect, preserve the PCM bit-for-bit. This is both
           the Original/Shadow invariant and the safest failure path. */
        output_left[i] = spatialized ? softclip(clampf(outL, -1.0f, 1.0f)) : outL;
        output_right[i] = spatialized ? softclip(clampf(outR, -1.0f, 1.0f)) : outR;
    }
    mixer->rendered_sample = start_sample + frames;
    for (uint32_t i = 0; i < mixer->event_count; ) {
        if (mixer->events[i].effect_end_sample <= mixer->rendered_sample) {
            mixer->events[i] = mixer->events[--mixer->event_count];
        } else i++;
    }
}
