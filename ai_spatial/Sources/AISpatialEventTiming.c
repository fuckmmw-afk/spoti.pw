#include "AISpatialEventTiming.h"
#include <math.h>
#include <string.h>

void ASEventGateInit(ASEventGate *gate) { if (gate) memset(gate, 0, sizeof(*gate)); }
void ASEventGateSetEpoch(ASEventGate *gate, uint64_t epoch) {
    if (!gate || (gate->has_epoch && gate->epoch == epoch)) return;
    gate->epoch = epoch; gate->has_epoch = true;
    gate->seen_count = gate->seen_cursor = 0;
}
uint64_t ASEventReadyDeadline(uint64_t start, uint64_t delay, uint64_t safety) {
    // Ready BEFORE the first extracted sample reaches playback, not its end.
    uint64_t deadline = start > UINT64_MAX - delay ? UINT64_MAX : start + delay;
    return deadline > safety ? deadline - safety : 0;
}
double ASEventSampleDeltaMS(uint64_t later, uint64_t earlier, double rate) {
    if (!isfinite(rate) || rate <= 0) return NAN;
    double magnitude = (double)(later >= earlier ? later - earlier : earlier - later);
    return (later >= earlier ? magnitude : -magnitude) * 1000.0 / rate;
}
bool ASEventElapsedMS(double began, double ended, double *milliseconds) {
    if (!milliseconds || !isfinite(began) || !isfinite(ended) || ended < began) return false;
    *milliseconds = (ended - began) * 1000.0;
    return isfinite(*milliseconds);
}
static bool equal(ASEventKey a, ASEventKey b) {
    // window id is trace metadata; overlapping windows must not duplicate audio.
    return a.epoch == b.epoch && a.start == b.start && a.end == b.end && a.source == b.source;
}
ASEventDecision ASEventGateSelect(ASEventGate *g, ASEventKey key,
                                 uint64_t actual_epoch, bool reset_pending,
                                 uint64_t input_cursor, uint64_t output_cursor,
                                 uint64_t delay, uint64_t safety,
                                 double now, unsigned limit, uint64_t min_interval_samples) {
    if (!g || !isfinite(now) || now < 0 || !limit || limit > AS_EVENT_DENSITY_CAPACITY ||
        key.end <= key.start || key.source > 1)
        return AS_EVENT_INVALID;
    if (reset_pending || key.epoch != actual_epoch || !g->has_epoch || g->epoch != actual_epoch)
        return AS_EVENT_STALE_EPOCH;
    if (g->has_last_selected && now < g->last_selected_time) return AS_EVENT_INVALID;
    for (size_t i = 0; i < g->seen_count; i++) if (equal(g->seen[i], key)) return AS_EVENT_DUPLICATE;
    g->seen[g->seen_cursor] = key;
    g->seen_cursor = (g->seen_cursor + 1) % AS_EVENT_SEEN_CAPACITY;
    if (g->seen_count < AS_EVENT_SEEN_CAPACITY) g->seen_count++;
    if (input_cursor > ASEventReadyDeadline(key.start, delay, safety) || output_cursor > key.start)
        return AS_EVENT_LATE;
    // A sliding window, shared by both stems; no burst across fixed buckets.
    size_t kept = 0;
    for (size_t i = 0; i < g->density_count; i++) {
        if (now - g->selected_times[i] < 60.0) g->selected_times[kept++] = g->selected_times[i];
    }
    g->density_count = kept;
    if (kept >= limit) return AS_EVENT_DENSITY;
    if (g->has_last_selected && g->last_selected_epoch == key.epoch &&
        (key.start <= g->last_selected_sample || key.start - g->last_selected_sample < min_interval_samples)) return AS_EVENT_INTERVAL;
    g->selected_times[g->density_count++] = now;
    g->last_selected_time = now; g->last_selected_sample = key.start;
    g->last_selected_epoch = key.epoch; g->has_last_selected = true;
    return AS_EVENT_ACCEPT;
}
const char *ASEventDecisionName(ASEventDecision d) {
    switch (d) {
        case AS_EVENT_ACCEPT: return "accepted";
        case AS_EVENT_STALE_EPOCH: return "stale_epoch";
        case AS_EVENT_DUPLICATE: return "duplicate_event";
        case AS_EVENT_LATE: return "late_start_deadline";
        case AS_EVENT_DENSITY: return "global_rolling_density_limit";
        case AS_EVENT_INTERVAL: return "global_minimum_interval";
        default: return "invalid_timeline";
    }
}
