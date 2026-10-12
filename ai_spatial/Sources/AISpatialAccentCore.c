#include "AISpatialAccentCore.h"
#include <math.h>
#include <string.h>

static float clamp01(float x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }
const char *ASAccentTypeName(ASAccentType type) {
    switch (type) {
        case ASAccentVocalPhraseStart: return "vocal_phrase_start";
        case ASAccentVocalAttack: return "vocal_attack";
        case ASAccentVocalSyllableEnding: return "vocal_syllable_ending";
        case ASAccentVocalShout: return "vocal_shout";
        case ASAccentVocalAdlib: return "vocal_adlib_candidate";
        case ASAccentVocalPauseContrast: return "vocal_pause_contrast";
        case ASAccentInstrumentalAttack: return "instrumental_attack";
        case ASAccentInstrumentalSynthInsert: return "synth_insert";
        case ASAccentInstrumentalPercussionContrast: return "percussion_contrast";
        case ASAccentInstrumentalSoundEffect: return "sound_effect";
        case ASAccentInstrumentalPauseTexture: return "instrumental_pause_texture";
        default: return "unknown";
    }
}

void ASAccentCoreReset(ASAccentCoreContext *context) {
    if (context) memset(context, 0, sizeof(*context));
}

static bool is_local_max(const ASAccentFrame *f, size_t i, size_t n) {
    float v = f[i].rms + .65f * f[i].flux;
    if (i && v < f[i - 1].rms + .65f * f[i - 1].flux) return false;
    if (i + 1 < n && v < f[i + 1].rms + .65f * f[i + 1].flux) return false;
    return true;
}

static void set_reason(ASAccentCoreEvent *e, const char *reason) {
    strncpy(e->reason, reason, sizeof(e->reason) - 1);
    e->reason[sizeof(e->reason) - 1] = '\0';
}

size_t ASAccentCoreAnalyze(const ASAccentFrame *frames, size_t count,
                           double rate, uint32_t hop, ASAccentSource source,
                           uint64_t available, uint64_t latency,
                           ASAccentCoreContext *c, ASAccentCoreEvent *events,
                           size_t capacity) {
    if (!frames || !count || !c || !events || !capacity || rate <= 0 || !hop) return 0;
    float mean = 0, meanFlux = 0, variance = 0, fluxVariance = 0;
    float maxRMS = 0, maxPeak = 0, maxHF = 0;
    for (size_t i = 0; i < count; i++) {
        mean += frames[i].rms; meanFlux += frames[i].flux;
        maxRMS = fmaxf(maxRMS, frames[i].rms); maxPeak = fmaxf(maxPeak, frames[i].peak);
        maxHF = fmaxf(maxHF, frames[i].high_frequency);
    }
    mean /= (float)count; meanFlux /= (float)count;
    for (size_t i = 0; i < count; i++) {
        float d = frames[i].rms - mean, df = frames[i].flux - meanFlux;
        variance += d * d; fluxVariance += df * df;
    }
    float sd = sqrtf(variance / (float)count) + 1e-6f;
    float fluxSD = sqrtf(fluxVariance / (float)count) + 1e-6f;
    float rmsThreshold = fmaxf(mean * 1.18f, mean + .48f * sd);
    float fluxThreshold = meanFlux + .62f * fluxSD;
    size_t out = 0;
    for (size_t i = 0; i < count && out < capacity; i++) {
        const ASAccentFrame *f = &frames[i];
        bool loud = f->rms >= rmsThreshold;
        bool transient = f->flux >= fluxThreshold && is_local_max(frames, i, count);
        bool pauseContrast = c->has_previous && c->previous_rms > mean + .35f * sd && f->rms < mean * .52f;
        if (!((loud && transient) || (loud && is_local_max(frames, i, count)) || pauseContrast)) continue;
        /* Collapse a single attack spread over adjacent analysis frames. */
        if (out && f->sample <= events[out - 1].end_sample + (uint64_t)(.08 * rate)) {
            ASAccentCoreEvent *old = &events[out - 1];
            float oldValue = old->expressiveness;
            float value = clamp01(.58f * (f->rms - mean) / (3 * sd) + .42f * (f->flux - meanFlux) / (3 * fluxSD));
            if (value > oldValue) {
                old->start_sample = f->sample > (uint64_t)(.04 * rate) ? f->sample - (uint64_t)(.04 * rate) : 0;
                old->end_sample = f->sample + (uint64_t)(.12 * rate);
                old->expressiveness = value;
            }
            continue;
        }
        ASAccentCoreEvent *e = &events[out++];
        memset(e, 0, sizeof(*e));
        e->source = (uint8_t)source;
        e->start_sample = f->sample > (uint64_t)(.04 * rate) ? f->sample - (uint64_t)(.04 * rate) : 0;
        e->end_sample = f->sample + (uint64_t)(pauseContrast ? .16 * rate : .12 * rate);
        float contrast = clamp01((f->rms - mean) / (3.0f * sd));
        float novelty = clamp01((f->flux - meanFlux) / (3.0f * fluxSD));
        float air = maxHF > 1e-6f ? clamp01(f->high_frequency / maxHF) : 0;
        e->expressiveness = clamp01(.45f * contrast + .35f * novelty + .20f * air);
        e->confidence = clamp01(.48f + .30f * contrast + .22f * novelty);
        if (source == ASAccentSourceVocal) {
            if (pauseContrast) e->type = ASAccentVocalPauseContrast;
            else if (f->peak > f->rms * 2.8f && contrast > .55f) e->type = ASAccentVocalShout;
            else if (e->end_sample - e->start_sample < (uint64_t)(.22 * rate) && air > .55f) e->type = ASAccentVocalAdlib;
            else if (c->has_previous && c->previous_rms < mean * .72f) e->type = ASAccentVocalPhraseStart;
            else if (f->flux > fluxThreshold * 1.25f) e->type = ASAccentVocalAttack;
            else e->type = ASAccentVocalSyllableEnding;
        } else {
            if (pauseContrast) e->type = ASAccentInstrumentalPauseTexture;
            else if (air > .72f && novelty > .55f) e->type = ASAccentInstrumentalSoundEffect;
            else if (air > .50f && contrast > .42f) e->type = ASAccentInstrumentalSynthInsert;
            else if (novelty > .60f) e->type = ASAccentInstrumentalPercussionContrast;
            else e->type = ASAccentInstrumentalAttack;
        }
        float priority = clamp01(.70f * e->expressiveness + .30f * e->confidence);
        /* Rarity and context are explicit parts of ranking. Repeated blocks do not
           receive a bonus simply because they are loud. */
        bool sameRepeat = false;
        if (c->last_selected_sample && e->start_sample > c->last_selected_sample) {
            uint64_t interval = e->start_sample - c->last_selected_sample;
            if (c->repeat_interval && interval > c->repeat_interval * 7 / 10 && interval < c->repeat_interval * 13 / 10) sameRepeat = true;
            if (sameRepeat) { c->repeat_count++; c->repeat_interval = (c->repeat_interval * 3 + interval) / 4; }
            else { c->repeat_interval = interval; c->repeat_count = 1; }
        }
        if (!c->density_window_start || e->start_sample - c->density_window_start >= (uint64_t)rate * 60) {
            c->density_window_start = e->start_sample; c->density_count = 0;
        }
        e->priority = priority + (source == ASAccentSourceVocal ? .025f : 0);
        bool selected = e->priority >= .46f;
        const char *reason = "below_adaptive_priority";
        if (selected && c->last_selected_sample && e->start_sample - c->last_selected_sample < (uint64_t)(.35 * rate)) {
            selected = false; reason = "minimum_interval";
        } else if (selected && c->repeat_count >= 2 && e->priority < c->previous_selected_score + .14f) {
            selected = false; reason = "periodic_repetition_suppressed";
        } else if (selected && c->density_count >= 10) {
            selected = false; reason = "density_limit";
        } else {
            uint64_t safety = (uint64_t)(.10 * rate);
            uint64_t deadline = e->end_sample + latency;
            if (deadline > safety) deadline -= safety; else deadline = 0;
            if (selected && available > deadline) {
            selected = false; reason = "late_deadline";
            }
        }
        e->selected = selected;
        if (selected) {
            c->previous_selected_sample = c->last_selected_sample;
            c->last_selected_sample = e->start_sample;
            c->previous_selected_score = e->priority;
            c->density_count++;
            set_reason(e, source == ASAccentSourceVocal ? "rare_contextual_vocal_accent" : "rare_contextual_instrumental_accent");
        } else set_reason(e, reason);
    }
    c->previous_rms = frames[count - 1].rms; c->has_previous = true;
    return out;
}
