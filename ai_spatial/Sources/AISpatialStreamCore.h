#ifndef AI_SPATIAL_STREAM_CORE_H
#define AI_SPATIAL_STREAM_CORE_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include "AISpatialScene.h"
#include "AISpatialRenderers.h"
#define AS_STREAM_CAPACITY 262144u
#define AS_STREAM_TELEMETRY 128u
#define AS_STREAM_DELAY_SECONDS 2.75
#define AS_STREAM_SPATIAL_SLOTS 32u
// Single render producer/consumer and single analysis worker. No memory in these
// queues is reused before the other owner publishes its read cursor.
typedef struct { uint64_t epoch, sample; float l, r; } ASStreamInput;
// A completed frame keeps the window/block identity as well as its absolute
// sample index.  The render side matches only epoch + sample; block_id is
// retained for diagnostics and exported trace correlation.
typedef struct { uint64_t epoch, block_id, sample; float vl, vr, il, ir; } ASStreamOutput;
typedef struct {
    uint64_t event_id, epoch, start_sample, end_sample;
    uint8_t stem, motion;
    float priority, intensity, direction;
} ASStreamSpatialEvent;
typedef struct {
    ASStreamSpatialEvent pending[AS_STREAM_SPATIAL_SLOTS];
    _Atomic(uint64_t) event_head, event_tail;
    ASStreamSpatialEvent active[8]; // render-owned; producer never modifies
    size_t active_count;
    uint64_t active_epoch;
    _Atomic(uint64_t) scheduled, rejected, cancelled;
    _Atomic(int) enabled, route;
    _Atomic(uint32_t) intensity_bits, width_bits, depth_bits, center_bits, bass_bits, anti_phase_bits;
} ASStreamSpatialState;
typedef struct {
    uint64_t epoch, start, end, input_frames, output_frames, stem_frames, fallback_frames;
    uint64_t overflow, underrun, fallback_transitions, discontinuities;
    double rate, input_square, input_peak, output_square, output_peak, error_square;
    double sample_time, host_seconds;
    int mode;
} ASStreamTelemetry;
typedef struct {
    ASStreamInput *input;
    ASStreamOutput *output;
    float *history_l, *history_r;
    ASStreamTelemetry telemetry[AS_STREAM_TELEMETRY];
    _Atomic(uint64_t) input_head, input_tail, output_head, output_tail;
    _Atomic(uint64_t) telemetry_head, telemetry_tail, telemetry_dropped;
    _Atomic(uint64_t) epoch, reset_request, applied_reset, input_cursor, output_cursor;
    _Atomic(uint64_t) overflows, underruns, fallback_transitions, discontinuities;
    _Atomic(uint64_t) input_dropped, output_dropped, stale_outputs;
    _Atomic(uint64_t) spatial_applied;
    ASStreamSpatialState spatial;
    _Atomic(int) requested_mode, active_mode;
    _Atomic(uint64_t) rate_bits;
    // Render-owned state below. Other threads request boundaries, never clear it.
    uint64_t cursor, epoch_start, handled_reset;
    double rate, expected_sample_time;
    bool timestamp_valid, fallback, began_output;
    float stem_weight, vocal_gain, instrumental_gain;
    ASStreamTelemetry second;
} ASStreamCore;
typedef struct {
    uint64_t epoch, input_cursor, output_cursor;
    double rate;
    bool reset_pending;
} ASStreamClock;
bool ASStreamReadClock(const ASStreamCore *core, ASStreamClock *clock);
void ASStreamSpatialConfigure(ASStreamCore *core, ASSpatialRoute route, bool enabled,
                              float intensity, float width, float depth, float center,
                              float bass, float anti_phase);
bool ASStreamSpatialSchedule(ASStreamCore *core, const ASStreamSpatialEvent *event);
void ASStreamSpatialClear(ASStreamCore *core, uint64_t epoch);
bool ASStreamInit(ASStreamCore *core);
void ASStreamDestroy(ASStreamCore *core); // only after both owners have stopped
void ASStreamRequestReset(ASStreamCore *core);
void ASStreamRequestMode(ASStreamCore *core, int mode);
void ASStreamRender(ASStreamCore *core, float *l, float *r, uint32_t frames,
                    double rate, double sample_time, double host_seconds);
bool ASStreamPopInput(ASStreamCore *core, ASStreamInput *frame);
bool ASStreamPushOutput(ASStreamCore *core, const ASStreamOutput *frames, size_t count);
bool ASStreamPopTelemetry(ASStreamCore *core, ASStreamTelemetry *row);
float ASStreamBlend(size_t index, size_t length, size_t overlap, bool has_previous);
void ASStreamResample(const float *in, size_t input_count, double input_rate,
                       float *out, size_t output_count, double output_rate);
#endif
