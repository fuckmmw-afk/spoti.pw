#include "AISpatialEventExtraction.h"
#include <math.h>
#include <string.h>

static float clampf(float x, float lo, float hi) { return x < lo ? lo : x > hi ? hi : x; }
static float smooth(float x) { x = clampf(x, 0, 1); return x * x * (3.0f - 2.0f * x); }

bool ASExtractValidate(const ASExtractEvent *e, double rate, uint64_t epoch, uint64_t cursor) {
    if (!e || !isfinite(rate) || rate <= 0 || !e->selected || e->stream_epoch != epoch ||
        e->end_sample <= e->start_sample || e->start_sample < cursor || e->source > 1 ||
        !isfinite(e->priority) || !isfinite(e->intensity) || !isfinite(e->attack_seconds) ||
        !isfinite(e->release_seconds) || !isfinite(e->tail_seconds)) return false;
    return e->intensity >= 0 && e->intensity <= 1 && e->priority >= 0 &&
           e->attack_seconds >= 0 && e->release_seconds >= 0 && e->tail_seconds >= 0 &&
           e->attack_seconds <= 0.5 && e->release_seconds <= 0.5 && e->tail_seconds <= 0.45;
}

float ASExtractEnvelope(uint64_t sample, const ASExtractEvent *e, double rate) {
    if (!e || !isfinite(rate) || rate <= 0 || sample < e->start_sample) return 0;
    uint64_t bodyEnd = e->end_sample;
    uint64_t tail = (uint64_t)llround(clampf(e->tail_seconds, 0, .45f) * rate);
    uint64_t finish = bodyEnd > UINT64_MAX - tail ? UINT64_MAX : bodyEnd + tail;
    if (sample >= finish || finish <= e->start_sample) return 0;
    double length = (double)(finish - e->start_sample);
    double attack = fmin(fmax(e->attack_seconds, .002), length / rate * .5) * rate;
    double release = fmin(fmax(e->release_seconds, .002), length / rate * .5) * rate;
    float in = attack > 0 ? smooth((float)((sample - e->start_sample + 1) / attack)) : 1;
    float out = release > 0 ? smooth((float)((finish - sample) / release)) : 1;
    float tailGain = sample >= bodyEnd ? (float)((double)(finish - sample) / fmax((double)tail, 1.0)) : 1;
    return clampf(in * out * tailGain * clampf(e->intensity, 0, 1), 0, 1);
}

size_t ASExtractChooseWinners(const ASExtractEvent *events, size_t count, uint64_t sample,
                              uint8_t source, double rate, ASExtractWinner *winner,
                              size_t capacity) {
    if (!winner || !capacity || !events || !isfinite(rate) || rate <= 0) return 0;
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        const ASExtractEvent *e = &events[i];
        if (e->source != source || !e->selected) continue;
        float weight = ASExtractEnvelope(sample, e, rate);
        if (weight <= 0) continue;
        size_t at = n;
        while (at && winner[at - 1].priority < e->priority) at--;
        if (n < capacity) n++;
        else if (at >= capacity) continue;
        if (n <= capacity) {
            size_t last = n - 1;
            if (last >= capacity) last = capacity - 1;
            while (last > at) { winner[last] = winner[last - 1]; last--; }
            winner[at] = (ASExtractWinner){sample, e->event_id, weight, e->priority};
        }
    }
    return n;
}

void ASExtractForeground(const float *il, const float *ir, float *ol, float *or, size_t frames,
                         uint64_t start, const ASExtractEvent *event, double rate) {
    if (!ol || !or || !frames) return;
    for (size_t i = 0; i < frames; i++) {
        float w = ASExtractEnvelope(start + i, event, rate);
        float l = il ? il[i] : 0, r = ir ? ir[i] : 0;
        ol[i] = l * w; or[i] = r * w;
    }
}
