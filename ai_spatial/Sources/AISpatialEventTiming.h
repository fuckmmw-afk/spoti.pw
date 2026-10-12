#ifndef AI_SPATIAL_EVENT_TIMING_H
#define AI_SPATIAL_EVENT_TIMING_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define AS_EVENT_DENSITY_CAPACITY 60u
#define AS_EVENT_SEEN_CAPACITY 128u

typedef enum {
    AS_EVENT_ACCEPT, AS_EVENT_STALE_EPOCH, AS_EVENT_DUPLICATE,
    AS_EVENT_LATE, AS_EVENT_DENSITY, AS_EVENT_INTERVAL, AS_EVENT_INVALID
} ASEventDecision;
typedef struct {
    uint64_t epoch, window_id, start, end;
    unsigned source;
} ASEventKey;
typedef struct {
    double selected_times[AS_EVENT_DENSITY_CAPACITY];
    size_t density_count;
    ASEventKey seen[AS_EVENT_SEEN_CAPACITY];
    size_t seen_count, seen_cursor;
    uint64_t epoch;
    bool has_epoch, has_last_selected;
    double last_selected_time;
    uint64_t last_selected_sample, last_selected_epoch;
} ASEventGate;

// Gate is analysis-queue owned. Epoch changes clear duplicate identities;
// rolling density/spacing use monotonic time and survive track/route/seek.
void ASEventGateInit(ASEventGate *gate);
void ASEventGateSetEpoch(ASEventGate *gate, uint64_t epoch);
uint64_t ASEventReadyDeadline(uint64_t start, uint64_t delay, uint64_t safety);
double ASEventSampleDeltaMS(uint64_t later, uint64_t earlier, double rate);
bool ASEventElapsedMS(double began, double ended, double *milliseconds);
ASEventDecision ASEventGateSelect(ASEventGate *gate, ASEventKey key,
                                 uint64_t actual_epoch, bool reset_pending,
                                 uint64_t input_cursor, uint64_t output_cursor,
                                 uint64_t delay, uint64_t safety,
                                 double now, unsigned limit, uint64_t min_interval_samples);
const char *ASEventDecisionName(ASEventDecision decision);
#endif
