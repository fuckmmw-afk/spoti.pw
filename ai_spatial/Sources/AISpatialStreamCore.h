#ifndef AI_SPATIAL_STREAM_CORE_H
#define AI_SPATIAL_STREAM_CORE_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include "AISpatialScene.h"
#include "AISpatialRenderers.h"
#include "AISpatialEventExtraction.h"
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
    float attack_seconds, release_seconds, tail_seconds;
    /* Render-owner lifecycle bits.  They are deliberately part of the event
       copy so the producer never touches render state after publication. */
    uint8_t lifecycle_rendered, lifecycle_mixed, lifecycle_activated;
    uint64_t rendered_frames, mixed_frames;
    double foreground_square, delta_square;
} ASStreamSpatialEvent;
typedef struct {
    ASStreamSpatialEvent pending[AS_STREAM_SPATIAL_SLOTS];
    _Atomic(uint64_t) event_head, event_tail;
    ASStreamSpatialEvent active[8]; // render-owned; producer never modifies
    size_t active_count;
    ASStreamSpatialEvent waiting[AS_STREAM_SPATIAL_SLOTS];
    size_t waiting_count;
    uint64_t active_epoch;
    _Atomic(uint64_t) scheduled, rejected, cancelled;
    _Atomic(uint64_t) activated, rendered_events, mixed_events, submitted_events, completed_events;
    _Atomic(uint64_t) stale_epoch, late_events, capacity_rejected, duplicate_rejected;
    _Atomic(int) enabled, route;
    _Atomic(uint32_t) intensity_bits, width_bits, depth_bits, center_bits, bass_bits, anti_phase_bits;
    _Atomic(int) accent_motion, stereo_width, depth_enabled, reflections, hrtf;
    _Atomic(unsigned) max_active;
    _Atomic(int) self_test;
} ASStreamSpatialState;
typedef struct {
    uint64_t epoch, start, end, input_frames, output_frames, stem_frames, fallback_frames;
    uint64_t overflow, underrun, fallback_transitions, discontinuities;
    uint64_t spatial_frames, spatial_changed_frames, spatial_base_frames;
    uint64_t spatial_renderer_frames, bypassed_frames, fallback_output_frames;
    double spatial_delta_square, spatial_delta_peak;
    double rate, input_square, input_peak, output_square, output_peak, error_square;
    double sample_time, host_seconds;
    int mode, actual_renderer;
    bool spatial_live;
} ASStreamTelemetry;
typedef struct {
    uint64_t event_id, epoch, sample, start, end, rendered_frames, mixed_frames;
    double foreground_square, delta_square;
    unsigned state, reason, renderer;
} ASStreamEventTrace;
enum { AS_TRACE_SCHEDULED, AS_TRACE_ACTIVATED, AS_TRACE_RENDERED, AS_TRACE_MIXED, AS_TRACE_SUBMITTED, AS_TRACE_COMPLETED, AS_TRACE_REJECTED };
enum { AS_REASON_NONE, AS_REASON_EPOCH, AS_REASON_LATE, AS_REASON_CAPACITY, AS_REASON_DUPLICATE, AS_REASON_NO_STEMS, AS_REASON_NO_DELTA, AS_REASON_DISABLED, AS_REASON_INVALID, AS_REASON_SELF_TEST };
typedef enum {
    AS_SELF_TEST_IDLE = 0,
    AS_SELF_TEST_RUNNING = 1,
    AS_SELF_TEST_PASSED = 2,
    AS_SELF_TEST_FAILED = 3,
    AS_SELF_TEST_CANCELLED = 4,
} ASOutputSelfTestStatus;
typedef enum {
    AS_SELF_TEST_REASON_NONE = 0,
    AS_SELF_TEST_REASON_EXPLICIT_CANCEL = 1,
    AS_SELF_TEST_REASON_STREAM_RESET = 2,
    AS_SELF_TEST_REASON_TIMESTAMP_DISCONTINUITY = 3,
    AS_SELF_TEST_REASON_RATE_CHANGED = 4,
    AS_SELF_TEST_REASON_TERMINAL_OUTPUT_MISSING = 5,
    AS_SELF_TEST_REASON_PHASE_ZERO_FRAMES = 6,
    AS_SELF_TEST_REASON_RENDERER_ZERO_FRAMES = 7,
    AS_SELF_TEST_REASON_EVENT_LIFECYCLE_INCOMPLETE = 8,
} ASOutputSelfTestReason;
typedef struct {
    _Atomic(int) request, phase;
    _Atomic(int) status, reason;
    _Atomic(uint64_t) frames, phase_frames[3], changed[3], square_nano[3], renderer_frames[4];
    _Atomic(uint32_t) peak_bits[3];
    _Atomic(uint64_t) scheduled, terminal_frames;
    _Atomic(uint64_t) baseline_rendered_events, baseline_mixed_events, baseline_submitted_events, baseline_completed_events;
    bool running;
    uint64_t elapsed;
    double rate;
} ASOutputSelfTest;
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
    _Atomic(uint64_t) spatial_base_applied;
    _Atomic(uint64_t) spatial_nonzero_delta;
    _Atomic(uint32_t) spatial_delta_peak_bits;
    _Atomic(uint32_t) spatial_delta_rms_bits;
    _Atomic(uint64_t) rendered_stem_frames, rendered_fallback_frames;
    _Atomic(uint64_t) terminal_frames;
    ASStreamSpatialState spatial;
    ASOutputSelfTest test;
    ASStreamEventTrace event_trace[256], terminal_pending[16];
    _Atomic(uint64_t) trace_head, trace_tail, trace_dropped;
    size_t terminal_pending_count;
    _Atomic(uint64_t) renderer_frames[4], bypassed_frames;
    float *reference_left, *reference_right, *foreground_left, *foreground_right; /* optional callback-owned taps */
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
bool ASStreamSpatialLiveRequested(const ASStreamCore *core);
void ASStreamSpatialConfigure(ASStreamCore *core, ASSpatialRoute route, bool enabled,
                              float intensity, float width, float depth, float center,
                              float bass, float anti_phase);
void ASStreamSpatialSetComponents(ASStreamCore *core, bool accent_motion, bool stereo_width,
                                  bool depth, bool reflections, bool hrtf);
void ASStreamSpatialSetMaxActive(ASStreamCore *core, unsigned max_active);
bool ASStreamSpatialSchedule(ASStreamCore *core, const ASStreamSpatialEvent *event);
void ASStreamSpatialClear(ASStreamCore *core, uint64_t epoch);
void ASStreamSpatialSetSelfTest(ASStreamCore *core, bool enabled);
void ASStreamStartOutputSelfTest(ASStreamCore *core);
void ASStreamStopOutputSelfTest(ASStreamCore *core);
void ASStreamCancelOutputSelfTest(ASStreamCore *core, ASOutputSelfTestReason reason);
void ASStreamSubmitTerminal(ASStreamCore *core, uint32_t frames);
const char *ASOutputSelfTestStatusName(int status);
const char *ASOutputSelfTestReasonName(int reason);
bool ASStreamPopEventTrace(ASStreamCore *core, ASStreamEventTrace *trace);
int ASStreamSpatialScheduleReason(ASStreamCore *core, const ASStreamSpatialEvent *event);
const char *ASStreamTraceStateName(unsigned state);
const char *ASStreamTraceReasonName(unsigned reason);
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
