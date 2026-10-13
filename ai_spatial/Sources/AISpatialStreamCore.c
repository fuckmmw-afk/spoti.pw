#include "AISpatialStreamCore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

static uint32_t ASFloatBits(float value) { uint32_t bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static float ASBitsFloat(uint32_t bits) { float value; memcpy(&value, &bits, sizeof(value)); return value; }
static float ASSpatialClamp(float value, float lo, float hi) { return value < lo ? lo : value > hi ? hi : value; }

const char *ASStreamTraceStateName(unsigned state) {
    static const char *names[]={"scheduled","activated","rendered","mixed","submitted_to_output","completed","rejected"};
    return state<7?names[state]:"unknown";
}
const char *ASStreamTraceReasonName(unsigned reason) {
    static const char *names[]={"none","stream_epoch_changed","start_already_played","capacity","duplicate_event","no_synchronized_stem_frames","no_nonzero_foreground_delta","spatial_live_disabled_or_shadow","invalid_event","output_self_test_active"};
    return reason<10?names[reason]:"unknown";
}
static ASStreamEventTrace eventTrace(ASStreamCore *c, const ASStreamSpatialEvent *e, unsigned state, unsigned reason, uint64_t sample) {
    return (ASStreamEventTrace){e->event_id,e->epoch,sample,e->start_sample,e->end_sample,e->rendered_frames,e->mixed_frames,e->foreground_square,e->delta_square,state,reason,(unsigned)atomic_load(&c->spatial.route)};
}
static void trace(ASStreamCore *c, ASStreamEventTrace t) {
    uint64_t head=atomic_load_explicit(&c->trace_head,memory_order_relaxed);
    if (head-atomic_load_explicit(&c->trace_tail,memory_order_acquire)>=256) { atomic_fetch_add(&c->trace_dropped,1); return; }
    c->event_trace[head%256]=t; atomic_store_explicit(&c->trace_head,head+1,memory_order_release);
}
bool ASStreamPopEventTrace(ASStreamCore *c, ASStreamEventTrace *t) {
    uint64_t tail=atomic_load_explicit(&c->trace_tail,memory_order_relaxed);
    if (tail==atomic_load_explicit(&c->trace_head,memory_order_acquire)) return false;
    *t=c->event_trace[tail%256]; atomic_store_explicit(&c->trace_tail,tail+1,memory_order_release); return true;
}
void ASStreamSubmitTerminal(ASStreamCore *c, uint32_t frames) {
    atomic_fetch_add(&c->terminal_frames,frames);
    if (c->test.running || atomic_load(&c->test.phase)>0) atomic_fetch_add(&c->test.terminal_frames,frames);
    for(size_t i=0;i<c->terminal_pending_count;i++) {
        ASStreamEventTrace t=c->terminal_pending[i]; t.state=AS_TRACE_SUBMITTED;
        trace(c,t); atomic_fetch_add(&c->spatial.submitted_events,1);
    }
    c->terminal_pending_count=0;
}
void ASStreamStartOutputSelfTest(ASStreamCore *c) { if (c) atomic_store_explicit(&c->test.request,1,memory_order_release); }
void ASStreamStopOutputSelfTest(ASStreamCore *c) { if (c) atomic_store_explicit(&c->test.request,0,memory_order_release); }
bool ASStreamInit(ASStreamCore *c) {
    memset(c, 0, sizeof(*c));
    c->input = calloc(AS_STREAM_CAPACITY, sizeof(*c->input));
    c->output = calloc(AS_STREAM_CAPACITY, sizeof(*c->output));
    c->history_l = calloc(AS_STREAM_CAPACITY, sizeof(float));
    c->history_r = calloc(AS_STREAM_CAPACITY, sizeof(float));
    if (!c->input || !c->output || !c->history_l || !c->history_r) { ASStreamDestroy(c); return false; }
    atomic_init(&c->input_head, 0); atomic_init(&c->input_tail, 0);
    atomic_init(&c->output_head, 0); atomic_init(&c->output_tail, 0);
    atomic_init(&c->telemetry_head, 0); atomic_init(&c->telemetry_tail, 0); atomic_init(&c->telemetry_dropped, 0);
    atomic_init(&c->epoch, 0); atomic_init(&c->reset_request, 1); atomic_init(&c->applied_reset, 0);
    atomic_init(&c->input_cursor, 0); atomic_init(&c->output_cursor, 0);
    atomic_init(&c->overflows, 0); atomic_init(&c->underruns, 0); atomic_init(&c->fallback_transitions, 0);
    atomic_init(&c->discontinuities, 0); atomic_init(&c->input_dropped, 0); atomic_init(&c->output_dropped, 0);
    atomic_init(&c->stale_outputs, 0); atomic_init(&c->requested_mode, 0); atomic_init(&c->active_mode, 0);
    atomic_init(&c->spatial_applied, 0);
    atomic_init(&c->spatial_base_applied, 0);
    atomic_init(&c->spatial_nonzero_delta, 0); atomic_init(&c->spatial_delta_peak_bits, 0);
    atomic_init(&c->spatial_delta_rms_bits, 0);
    atomic_init(&c->rendered_stem_frames, 0); atomic_init(&c->rendered_fallback_frames, 0);
    atomic_init(&c->terminal_frames, 0);
    atomic_init(&c->rate_bits, 0);
    atomic_init(&c->spatial.event_head, 0); atomic_init(&c->spatial.event_tail, 0);
    atomic_init(&c->spatial.scheduled, 0); atomic_init(&c->spatial.rejected, 0); atomic_init(&c->spatial.cancelled, 0); atomic_init(&c->spatial.enabled, 0); atomic_init(&c->spatial.route, ASSpatialRouteUniversalStereo);
    atomic_init(&c->spatial.activated, 0); atomic_init(&c->spatial.rendered_events, 0); atomic_init(&c->spatial.mixed_events, 0);
    atomic_init(&c->spatial.submitted_events, 0); atomic_init(&c->spatial.completed_events, 0);
    atomic_init(&c->spatial.stale_epoch, 0); atomic_init(&c->spatial.late_events, 0);
    atomic_init(&c->spatial.capacity_rejected, 0); atomic_init(&c->spatial.duplicate_rejected, 0);
    atomic_init(&c->spatial.self_test, 0);
    atomic_init(&c->spatial.accent_motion, 1); atomic_init(&c->spatial.stereo_width, 1); atomic_init(&c->spatial.depth_enabled, 1); atomic_init(&c->spatial.reflections, 1); atomic_init(&c->spatial.hrtf, 1);
    atomic_init(&c->spatial.max_active, 3);
    atomic_init(&c->spatial.intensity_bits, ASFloatBits(.55f)); atomic_init(&c->spatial.width_bits, ASFloatBits(.65f)); atomic_init(&c->spatial.depth_bits, ASFloatBits(.40f));
    atomic_init(&c->spatial.center_bits, ASFloatBits(.75f)); atomic_init(&c->spatial.bass_bits, ASFloatBits(.70f)); atomic_init(&c->spatial.anti_phase_bits, ASFloatBits(.08f));
    atomic_init(&c->trace_head,0); atomic_init(&c->trace_tail,0); atomic_init(&c->trace_dropped,0);
    atomic_init(&c->test.request,0); atomic_init(&c->test.phase,0); atomic_init(&c->test.frames,0);
    atomic_init(&c->test.scheduled,0); atomic_init(&c->test.terminal_frames,0); atomic_init(&c->bypassed_frames,0);
    for(unsigned i=0;i<4;i++) { atomic_init(&c->renderer_frames[i],0); atomic_init(&c->test.renderer_frames[i],0); }
    for(unsigned i=0;i<3;i++) { atomic_init(&c->test.phase_frames[i],0); atomic_init(&c->test.changed[i],0); atomic_init(&c->test.square_nano[i],0); atomic_init(&c->test.peak_bits[i],0); }
    c->vocal_gain = c->instrumental_gain = 1;
    return true;
}
void ASStreamSpatialSetComponents(ASStreamCore *c, bool accent_motion, bool stereo_width,
                                  bool depth, bool reflections, bool hrtf) {
    if (!c) return;
    atomic_store_explicit(&c->spatial.accent_motion, accent_motion, memory_order_release);
    atomic_store_explicit(&c->spatial.stereo_width, stereo_width, memory_order_release);
    atomic_store_explicit(&c->spatial.depth_enabled, depth, memory_order_release);
    atomic_store_explicit(&c->spatial.reflections, reflections, memory_order_release);
    atomic_store_explicit(&c->spatial.hrtf, hrtf, memory_order_release);
}
void ASStreamSpatialSetMaxActive(ASStreamCore *c, unsigned max_active) {
    if (!c) return;
    atomic_store_explicit(&c->spatial.max_active, max_active < 1 ? 1 : max_active > 8 ? 8 : max_active, memory_order_release);
}
void ASStreamSpatialConfigure(ASStreamCore *c, ASSpatialRoute route, bool enabled,
                              float intensity, float width, float depth, float center,
                              float bass, float anti_phase) {
    if (!c) return;
    atomic_store_explicit(&c->spatial.route, route, memory_order_release);
    atomic_store_explicit(&c->spatial.intensity_bits, ASFloatBits(ASSpatialClamp(intensity,0,1)), memory_order_release);
    atomic_store_explicit(&c->spatial.width_bits, ASFloatBits(ASSpatialClamp(width,0,1)), memory_order_release);
    atomic_store_explicit(&c->spatial.depth_bits, ASFloatBits(ASSpatialClamp(depth,0,1)), memory_order_release);
    atomic_store_explicit(&c->spatial.center_bits, ASFloatBits(ASSpatialClamp(center,0,1)), memory_order_release);
    atomic_store_explicit(&c->spatial.bass_bits, ASFloatBits(ASSpatialClamp(bass,0,1)), memory_order_release);
    atomic_store_explicit(&c->spatial.anti_phase_bits, ASFloatBits(ASSpatialClamp(anti_phase,0,.25f)), memory_order_release);
    atomic_store_explicit(&c->spatial.enabled, enabled, memory_order_release);
}
int ASStreamSpatialScheduleReason(ASStreamCore *c, const ASStreamSpatialEvent *e) {
    if (!c || !e || e->end_sample<=e->start_sample || e->stem>1 || e->motion>ASSpatialMotionReflection ||
        !isfinite(e->priority) || !isfinite(e->intensity) || e->intensity<0 || e->intensity>1 ||
        !isfinite(e->direction) || !isfinite(e->attack_seconds) || !isfinite(e->release_seconds) || !isfinite(e->tail_seconds) ||
        e->attack_seconds<0 || e->release_seconds<0 || e->tail_seconds<0 || e->tail_seconds>.45f) return AS_REASON_INVALID;
    unsigned reason=AS_REASON_NONE;
    bool outputSelfTest=atomic_load(&c->test.request) && e->event_id>=UINT64_MAX-1024;
    /* The bounded C self-test uses reserved high event ids but still enters
       this same published scheduler. All ordinary detector ids are rejected
       while the detector is bypassed. */
    if (atomic_load(&c->test.request) && !outputSelfTest) reason=AS_REASON_SELF_TEST;
    else if (e->epoch!=atomic_load(&c->epoch) || atomic_load(&c->reset_request)!=atomic_load(&c->applied_reset)) reason=AS_REASON_EPOCH;
    else if (!outputSelfTest && !atomic_load(&c->spatial.self_test) && (!ASStreamSpatialLiveRequested(c) || !atomic_load(&c->spatial.enabled))) reason=AS_REASON_DISABLED;
    else if (e->start_sample<atomic_load(&c->output_cursor)) reason=AS_REASON_LATE;
    uint64_t head=atomic_load_explicit(&c->spatial.event_head,memory_order_relaxed),tail=atomic_load_explicit(&c->spatial.event_tail,memory_order_acquire);
    if (!reason && head-tail>=AS_STREAM_SPATIAL_SLOTS) reason=AS_REASON_CAPACITY;
    if (reason) { atomic_fetch_add(&c->spatial.rejected,1); return reason; }
    c->spatial.pending[head%AS_STREAM_SPATIAL_SLOTS]=*e;
    atomic_store_explicit(&c->spatial.event_head,head+1,memory_order_release); atomic_fetch_add(&c->spatial.scheduled,1); return AS_REASON_NONE;
}
bool ASStreamSpatialSchedule(ASStreamCore *c, const ASStreamSpatialEvent *e) { return ASStreamSpatialScheduleReason(c,e)==AS_REASON_NONE; }
void ASStreamSpatialClear(ASStreamCore *c, uint64_t epoch) {
    if (!c) return;
    for(size_t i=0;i<c->spatial.active_count;i++) trace(c,eventTrace(c,&c->spatial.active[i],AS_TRACE_REJECTED,AS_REASON_EPOCH,c->cursor));
    for(size_t i=0;i<c->spatial.waiting_count;i++) trace(c,eventTrace(c,&c->spatial.waiting[i],AS_TRACE_REJECTED,AS_REASON_EPOCH,c->cursor));
    atomic_fetch_add(&c->spatial.cancelled,c->spatial.active_count+c->spatial.waiting_count);
    atomic_fetch_add(&c->spatial.stale_epoch,c->spatial.active_count+c->spatial.waiting_count);
    c->spatial.active_count=c->spatial.waiting_count=0; c->spatial.active_epoch=epoch;
    /* Pending entries remain published until the consumer rejects them by epoch. */
}
void ASStreamSpatialSetSelfTest(ASStreamCore *c, bool enabled) { if (c) atomic_store(&c->spatial.self_test,enabled); }
static void enqueueWaiting(ASStreamCore *c, ASStreamSpatialEvent event, uint64_t epoch) {
    unsigned reason=event.epoch!=epoch?AS_REASON_EPOCH:event.start_sample<atomic_load(&c->output_cursor)?AS_REASON_LATE:AS_REASON_NONE;
    for(size_t i=0;i<c->spatial.active_count;i++) if(c->spatial.active[i].event_id==event.event_id) reason=AS_REASON_DUPLICATE;
    for(size_t i=0;i<c->spatial.waiting_count;i++) if(c->spatial.waiting[i].event_id==event.event_id) reason=AS_REASON_DUPLICATE;
    if (!reason && c->spatial.waiting_count>=AS_STREAM_SPATIAL_SLOTS) reason=AS_REASON_CAPACITY;
    if (reason) {
        trace(c,eventTrace(c,&event,AS_TRACE_REJECTED,reason,c->cursor)); atomic_fetch_add(&c->spatial.rejected,1);
        if(reason==AS_REASON_EPOCH) atomic_fetch_add(&c->spatial.stale_epoch,1);
        if(reason==AS_REASON_LATE) atomic_fetch_add(&c->spatial.late_events,1);
        if(reason==AS_REASON_DUPLICATE) atomic_fetch_add(&c->spatial.duplicate_rejected,1);
        if(reason==AS_REASON_CAPACITY) atomic_fetch_add(&c->spatial.capacity_rejected,1);
        return;
    }
    event.lifecycle_rendered=event.lifecycle_mixed=event.lifecycle_activated=0;
    event.rendered_frames=event.mixed_frames=0; event.foreground_square=event.delta_square=0;
    c->spatial.waiting[c->spatial.waiting_count++]=event;
    trace(c,eventTrace(c,&event,AS_TRACE_SCHEDULED,0,c->cursor));
}
static void ASStreamSpatialDrain(ASStreamCore *c, uint64_t epoch) {
    uint64_t tail=atomic_load_explicit(&c->spatial.event_tail,memory_order_relaxed),head=atomic_load_explicit(&c->spatial.event_head,memory_order_acquire);
    while(tail<head) { enqueueWaiting(c,c->spatial.pending[tail%AS_STREAM_SPATIAL_SLOTS],epoch); tail++; }
    atomic_store_explicit(&c->spatial.event_tail,tail,memory_order_release);
}
static void activateDue(ASStreamCore *c, uint64_t sample, double rate) {
    for(size_t i=0;i<c->spatial.active_count;) {
        ASStreamSpatialEvent *e=&c->spatial.active[i]; uint64_t end=e->end_sample+(uint64_t)llround(e->tail_seconds*rate);
        if (sample<end) { i++; continue; }
        unsigned reason=!e->rendered_frames?AS_REASON_NO_STEMS:!e->mixed_frames?AS_REASON_NO_DELTA:0;
        trace(c,eventTrace(c,e,AS_TRACE_COMPLETED,reason,sample)); atomic_fetch_add(&c->spatial.completed_events,1);
        c->spatial.active[i]=c->spatial.active[--c->spatial.active_count];
    }
    unsigned limit=atomic_load(&c->spatial.max_active); if(limit<1 || limit>8) limit=8;
    for(size_t i=0;i<c->spatial.waiting_count;) {
        ASStreamSpatialEvent e=c->spatial.waiting[i]; if(e.start_sample>sample) { i++; continue; }
        c->spatial.waiting[i]=c->spatial.waiting[--c->spatial.waiting_count];
        if (c->spatial.active_count>=limit || sample>=e.end_sample) {
            trace(c,eventTrace(c,&e,AS_TRACE_REJECTED,sample>=e.end_sample?AS_REASON_LATE:AS_REASON_CAPACITY,sample)); atomic_fetch_add(&c->spatial.rejected,1); continue;
        }
        e.lifecycle_activated=1; c->spatial.active[c->spatial.active_count++]=e;
        trace(c,eventTrace(c,&e,AS_TRACE_ACTIVATED,0,sample)); atomic_fetch_add(&c->spatial.activated,1);
    }
}
bool ASStreamReadClock(const ASStreamCore *c, ASStreamClock *clock) {
    if (!c || !clock) return false;
    uint64_t epoch = atomic_load_explicit(&c->epoch, memory_order_acquire);
    uint64_t reset = atomic_load_explicit(&c->reset_request, memory_order_acquire);
    uint64_t applied = atomic_load_explicit(&c->applied_reset, memory_order_acquire);
    clock->epoch = epoch;
    clock->input_cursor = atomic_load_explicit(&c->input_cursor, memory_order_acquire);
    clock->output_cursor = atomic_load_explicit(&c->output_cursor, memory_order_acquire);
    uint64_t rate_bits = atomic_load_explicit(&c->rate_bits, memory_order_acquire);
    memcpy(&clock->rate, &rate_bits, sizeof(clock->rate));
    clock->reset_pending = reset != applied;
    return epoch == atomic_load_explicit(&c->epoch, memory_order_acquire) &&
           reset == atomic_load_explicit(&c->reset_request, memory_order_acquire);
}
void ASStreamDestroy(ASStreamCore *c) { free(c->input); free(c->output); free(c->history_l); free(c->history_r); }
void ASStreamRequestReset(ASStreamCore *c) { atomic_fetch_add_explicit(&c->reset_request, 1, memory_order_release); }
void ASStreamRequestMode(ASStreamCore *c, int mode) {
    if (mode >= 0 && mode <= 4) atomic_store_explicit(&c->requested_mode, mode, memory_order_release);
}
bool ASStreamSpatialLiveRequested(const ASStreamCore *c) {
    return c && atomic_load_explicit(&c->requested_mode, memory_order_acquire) == 2;
}
bool ASStreamPopInput(ASStreamCore *c, ASStreamInput *f) {
    uint64_t tail = atomic_load_explicit(&c->input_tail, memory_order_relaxed);
    if (tail == atomic_load_explicit(&c->input_head, memory_order_acquire)) return false;
    *f = c->input[tail % AS_STREAM_CAPACITY];
    atomic_store_explicit(&c->input_tail, tail + 1, memory_order_release); return true;
}
bool ASStreamPushOutput(ASStreamCore *c, const ASStreamOutput *f, size_t n) {
    if (!n) return true;
    if (n > AS_STREAM_CAPACITY) {
        atomic_fetch_add_explicit(&c->output_dropped, n, memory_order_relaxed);
        return false;
    }
    uint64_t currentEpoch = atomic_load_explicit(&c->epoch, memory_order_acquire);
    if (!f || f[0].epoch != currentEpoch || f[n - 1].epoch != currentEpoch) {
        atomic_fetch_add_explicit(&c->output_dropped, n, memory_order_relaxed);
        atomic_fetch_add_explicit(&c->stale_outputs, n, memory_order_relaxed);
        return false;
    }
    uint64_t head = atomic_load_explicit(&c->output_head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&c->output_tail, memory_order_acquire);
    if (head - tail + n > AS_STREAM_CAPACITY) {
        atomic_fetch_add_explicit(&c->output_dropped, n, memory_order_relaxed); return false;
    }
    for (size_t i = 0; i < n; i++) c->output[(head + i) % AS_STREAM_CAPACITY] = f[i];
    // A seek or mode transition can race the worker after it has filled the
    // temporary block.  Do not publish an old-epoch block into the new ring.
    if (atomic_load_explicit(&c->epoch, memory_order_acquire) != currentEpoch) {
        atomic_fetch_add_explicit(&c->output_dropped, n, memory_order_relaxed);
        atomic_fetch_add_explicit(&c->stale_outputs, n, memory_order_relaxed);
        return false;
    }
    atomic_store_explicit(&c->output_head, head + n, memory_order_release); return true;
}
bool ASStreamPopTelemetry(ASStreamCore *c, ASStreamTelemetry *f) {
    uint64_t tail = atomic_load_explicit(&c->telemetry_tail, memory_order_relaxed);
    if (tail == atomic_load_explicit(&c->telemetry_head, memory_order_acquire)) return false;
    *f = c->telemetry[tail % AS_STREAM_TELEMETRY];
    atomic_store_explicit(&c->telemetry_tail, tail + 1, memory_order_release); return true;
}
static void publish_second(ASStreamCore *c) {
    ASStreamTelemetry *s = &c->second;
    if (!s->input_frames) return;
    atomic_store_explicit(&c->spatial_delta_peak_bits, ASFloatBits((float)s->spatial_delta_peak), memory_order_release);
    atomic_store_explicit(&c->spatial_delta_rms_bits,
        ASFloatBits((float)sqrt(s->spatial_delta_square / (2.0 * s->input_frames))), memory_order_release);
    s->overflow = atomic_load_explicit(&c->overflows, memory_order_relaxed);
    s->underrun = atomic_load_explicit(&c->underruns, memory_order_relaxed);
    s->fallback_transitions = atomic_load_explicit(&c->fallback_transitions, memory_order_relaxed);
    s->discontinuities = atomic_load_explicit(&c->discontinuities, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&c->telemetry_head, memory_order_relaxed);
    if (head - atomic_load_explicit(&c->telemetry_tail, memory_order_acquire) < AS_STREAM_TELEMETRY) {
        c->telemetry[head % AS_STREAM_TELEMETRY] = *s;
        atomic_store_explicit(&c->telemetry_head, head + 1, memory_order_release);
    } else atomic_fetch_add_explicit(&c->telemetry_dropped, 1, memory_order_relaxed);
    memset(s, 0, sizeof(*s));
}
static bool pop_matching(ASStreamCore *c, uint64_t epoch, uint64_t sample, ASStreamOutput *f, uint32_t *discardBudget) {
    uint64_t tail = atomic_load_explicit(&c->output_tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&c->output_head, memory_order_acquire);
    while (tail < head) {
        ASStreamOutput next = c->output[tail % AS_STREAM_CAPACITY];
        if (next.epoch > epoch || (next.epoch == epoch && next.sample > sample)) break;
        tail++;
        if (next.epoch == epoch && next.sample == sample) {
            *f = next; atomic_store_explicit(&c->output_tail, tail, memory_order_release); return true;
        }
        if (discardBudget && !*discardBudget) break;
        atomic_fetch_add_explicit(&c->stale_outputs, 1, memory_order_relaxed);
        if (discardBudget) (*discardBudget)--;
    }
    atomic_store_explicit(&c->output_tail, tail, memory_order_release); return false;
}
static float approach(float a, float b, float step) { return a < b ? fminf(b, a + step) : fmaxf(b, a - step); }
void ASStreamRender(ASStreamCore *c, float *l, float *r, uint32_t n, double rate, double st, double host) {
    if (!c || !c->input || !l || !r || !n || rate <= 0) return;
    bool testRequested=atomic_load_explicit(&c->test.request,memory_order_acquire)!=0;
    bool testBoundary=testRequested!=c->test.running;
    if (testBoundary) {
        c->test.running=testRequested;
        if (testRequested) {
            c->test.elapsed=0; c->test.rate=rate;
            atomic_store(&c->test.frames,0); atomic_store(&c->test.phase,1); atomic_store(&c->test.scheduled,0); atomic_store(&c->test.terminal_frames,0);
            for(unsigned k=0;k<3;k++) { atomic_store(&c->test.phase_frames[k],0); atomic_store(&c->test.changed[k],0); atomic_store(&c->test.square_nano[k],0); atomic_store(&c->test.peak_bits[k],0); }
            for(unsigned k=0;k<4;k++) atomic_store(&c->test.renderer_frames[k],0);
        } else if(atomic_load(&c->test.phase)!=4) atomic_store(&c->test.phase,0);
    }
    int requested = c->test.running?0:atomic_load_explicit(&c->requested_mode, memory_order_acquire);
    int mode = atomic_load_explicit(&c->active_mode, memory_order_relaxed);
    uint64_t reset = atomic_load_explicit(&c->reset_request, memory_order_acquire);
    bool discontinuity = isfinite(st) && c->timestamp_valid && fabs(st - c->expected_sample_time) > 1.5;
    bool boundary = testBoundary || reset != c->handled_reset || c->rate != rate || discontinuity;
    if (c->test.running && (c->test.rate!=rate || (!testBoundary && boundary))) {
        c->test.running=false; atomic_store(&c->test.request,0); atomic_store(&c->test.phase,0);
        requested=atomic_load(&c->requested_mode);
    }
    // Every mode-family change starts a new epoch.  This is also what makes
    // Original -> AI Live take effect: without the boundary the render side
    // would keep the old active mode forever.  Old input/output entries are
    // retained until their owner advances its cursor, then rejected by epoch;
    // no PCM from the previous position can be mixed into the new one.
    if (requested != mode) boundary = true;
    if (boundary) {
        publish_second(c);
        c->handled_reset = reset; c->epoch_start = c->cursor; c->rate = rate;
        uint64_t bits; memcpy(&bits, &rate, sizeof(bits)); atomic_store(&c->rate_bits, bits);
        atomic_fetch_add_explicit(&c->epoch, 1, memory_order_acq_rel);
        ASStreamSpatialClear(c, atomic_load_explicit(&c->epoch, memory_order_acquire));
        atomic_store_explicit(&c->spatial_delta_peak_bits, 0, memory_order_relaxed);
        atomic_store_explicit(&c->spatial_delta_rms_bits, 0, memory_order_relaxed);
        // All published frames belong to the previous epoch.  Discard them in
        // O(1) on the render side; the worker's epoch check prevents a stale
        // in-flight prediction from being published after this point.
        uint64_t oldOutputTail = atomic_load_explicit(&c->output_tail, memory_order_relaxed);
        uint64_t oldOutputHead = atomic_load_explicit(&c->output_head, memory_order_acquire);
        if (oldOutputHead > oldOutputTail) {
            atomic_fetch_add_explicit(&c->stale_outputs, oldOutputHead - oldOutputTail, memory_order_relaxed);
            atomic_store_explicit(&c->output_tail, oldOutputHead, memory_order_release);
        }
        if (discontinuity) atomic_fetch_add_explicit(&c->discontinuities, 1, memory_order_relaxed);
        mode = requested; c->stem_weight = 0; c->fallback = false; c->began_output = false;
        c->vocal_gain = mode == 4 ? 0 : 1; c->instrumental_gain = mode == 3 ? 0 : 1;
        atomic_store_explicit(&c->output_cursor, c->epoch_start, memory_order_release);
        atomic_store_explicit(&c->applied_reset, reset, memory_order_release);
    }
    atomic_store_explicit(&c->active_mode, mode, memory_order_release);
    c->timestamp_valid = isfinite(st); c->expected_sample_time = st + n;
    bool supported = fabs(rate - 44100) < .5 || fabs(rate - 48000) < .5;
    uint64_t epoch = atomic_load_explicit(&c->epoch, memory_order_acquire);
    // An in-flight worker can publish at most one race-losing block after an
    // epoch boundary.  Bound stale-frame inspection per callback so that even
    // a malformed producer cannot turn render time into an unbounded drain.
    ASStreamSpatialDrain(c, epoch);
    uint32_t staleDiscardBudget = 1024;
    uint64_t head = atomic_load_explicit(&c->input_head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&c->input_tail, memory_order_acquire);
    bool queue_input = mode != 0 && supported && head - tail + n <= AS_STREAM_CAPACITY;
    if (mode != 0 && supported && !queue_input) {
        atomic_fetch_add_explicit(&c->overflows, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&c->input_dropped, n, memory_order_relaxed);
    }
    const uint64_t delay = (uint64_t)llround(AS_STREAM_DELAY_SECONDS * rate);
    float fade_step = 1.f / (float)(rate * .02);
    for (uint32_t i = 0; i < n; i++) {
        uint64_t position = c->cursor++, offset = position - c->epoch_start;
        uint32_t slot = position % AS_STREAM_CAPACITY;
        float in_l = l[i], in_r = r[i];
        c->history_l[slot] = in_l; c->history_r[slot] = in_r;
        if (queue_input) c->input[(head + i) % AS_STREAM_CAPACITY] = (ASStreamInput){epoch, position, in_l, in_r};
        float out_l = in_l, out_r = in_r;
        bool has_stems = false, fallback = false;
        float reference_l = in_l, reference_r = in_r;
        bool spatial_frame = false, base_frame = false;
        uint64_t source = position;
        unsigned testPhase=c->test.running?(c->test.elapsed<(uint64_t)llround(2*rate)?1:c->test.elapsed<(uint64_t)llround(6*rate)?2:3):0;
        bool selfTest = testPhase==3 || atomic_load_explicit(&c->spatial.self_test, memory_order_acquire);
        if(testPhase==3) {
            uint64_t cStart=(uint64_t)llround(6*rate), gap=(uint64_t)llround(.65*rate);
            if((c->test.elapsed-cStart)%gap==0) {
                uint64_t id=(c->test.elapsed-cStart)/gap+1;
                ASStreamSpatialEvent e={.event_id=UINT64_MAX-id,.epoch=epoch,.start_sample=position+n+512,.end_sample=position+n+512+(uint64_t)llround(.28*rate),.stem=0,.motion=(uint8_t)(id%3),.priority=.95f,.intensity=.9f,.direction=(id%2?1:-1),.attack_seconds=.012f,.release_seconds=.03f,.tail_seconds=.04f};
                if (ASStreamSpatialSchedule(c,&e)) atomic_fetch_add(&c->test.scheduled,1);
            }
        }
        uint64_t audibleSource=selfTest?position:(mode>=2 && supported && offset>=delay?position-delay:position);
        /* Preroll has not consumed delayed source samples yet. */
        if (selfTest || mode<2 || !supported || offset>=delay) activateDue(c,audibleSource,rate);
        float foregroundL=0,foregroundR=0;
        if ((mode >= 2 && supported) || selfTest) {
            /* The analysis queue needs a preroll before a stem can be aligned.
             * Never turn that bounded wait into silence: preserve the exact
             * input sample until a same-epoch stem frame is available. */
            if (!selfTest && offset < delay) { out_l = in_l; out_r = in_r; fallback = true; }
            else {
                source = selfTest ? position : position - delay;
                float original_l = c->history_l[source % AS_STREAM_CAPACITY], original_r = c->history_r[source % AS_STREAM_CAPACITY];
                reference_l = original_l; reference_r = original_r;
                ASStreamOutput f={0};
                if (selfTest) {
                    f = (ASStreamOutput){ .epoch = epoch, .sample = source, .vl = original_l, .vr = original_r };
                    has_stems = true;
                } else {
                    has_stems = pop_matching(c, epoch, source, &f, &staleDiscardBudget);
                }
                if (has_stems && (!isfinite(f.vl) || !isfinite(f.vr) || !isfinite(f.il) || !isfinite(f.ir))) has_stems = false;
                fallback = !has_stems;
                c->stem_weight = approach(c->stem_weight, has_stems ? 1 : 0, fade_step);
                c->vocal_gain = approach(c->vocal_gain, mode == 4 ? 0 : 1, fade_step);
                c->instrumental_gain = approach(c->instrumental_gain, mode == 3 ? 0 : 1, fade_step);
                // Both sides of any blend have EXACTLY the same source index.
                // Spatial processing is a stem delta: Original already contains
                // the stem, so no source is added twice.
                float mix_vl=f.vl, mix_vr=f.vr, mix_il=f.il, mix_ir=f.ir;
                if (has_stems && (selfTest || (mode==2 && atomic_load_explicit(&c->spatial.enabled, memory_order_acquire) &&
                    atomic_load_explicit(&c->spatial.accent_motion, memory_order_acquire)))) {
                        ASSpatialRenderConfig cfg;
                    ASSpatialRenderConfigDefault(&cfg, (ASSpatialRoute)atomic_load_explicit(&c->spatial.route, memory_order_relaxed));
                    cfg.intensity=ASBitsFloat(atomic_load_explicit(&c->spatial.intensity_bits,memory_order_relaxed));
                    cfg.width=ASBitsFloat(atomic_load_explicit(&c->spatial.width_bits,memory_order_relaxed));
                    cfg.depth=ASBitsFloat(atomic_load_explicit(&c->spatial.depth_bits,memory_order_relaxed));
                    cfg.center_protection=ASBitsFloat(atomic_load_explicit(&c->spatial.center_bits,memory_order_relaxed));
                    cfg.bass_protection=ASBitsFloat(atomic_load_explicit(&c->spatial.bass_bits,memory_order_relaxed));
                    cfg.anti_phase_limit=ASBitsFloat(atomic_load_explicit(&c->spatial.anti_phase_bits,memory_order_relaxed));
                    cfg.width *= atomic_load_explicit(&c->spatial.stereo_width, memory_order_relaxed) ? 1.0f : 0.08f;
                    if (!atomic_load_explicit(&c->spatial.depth_enabled, memory_order_relaxed)) cfg.depth = 0;
                    cfg.reflection_enabled = atomic_load_explicit(&c->spatial.reflections, memory_order_relaxed);
                    cfg.hrtf_enabled = atomic_load_explicit(&c->spatial.hrtf, memory_order_relaxed);
                    if(testPhase==3) {
                        ASSpatialRenderConfigDefault(&cfg,(ASSpatialRoute)atomic_load(&c->spatial.route));
                        cfg.intensity=.9f; cfg.width=.95f; cfg.depth=.5f;
                    }
                    ASStreamSpatialEvent bestVocal={0}, bestInstrumental={0};
                    ASStreamSpatialEvent *bestVocalRef=NULL, *bestInstrumentalRef=NULL;
                    bool haveVocal=false, haveInstrumental=false;
                    for (size_t si=0; si<c->spatial.active_count; si++) {
                        ASStreamSpatialEvent *active = &c->spatial.active[si];
                        ASStreamSpatialEvent ev=*active;
                        if (ev.epoch!=epoch || source<ev.start_sample || source>=ev.end_sample+(uint64_t)llround(ev.tail_seconds*rate)) continue;
                        if (ev.stem==ASSpatialStemVocal) { if (!haveVocal || ev.priority>bestVocal.priority) { bestVocal=ev; bestVocalRef=active; } haveVocal=true; }
                        else { if (!haveInstrumental || ev.priority>bestInstrumental.priority) { bestInstrumental=ev; bestInstrumentalRef=active; } haveInstrumental=true; }
                    }
                    for (unsigned selectedStem=0; selectedStem<2; selectedStem++) {
                        bool have=selectedStem==0?haveVocal:haveInstrumental;
                        if (!have) continue;
                        ASStreamSpatialEvent ev=selectedStem==0?bestVocal:bestInstrumental;
                        ASStreamSpatialEvent *active = selectedStem==0 ? bestVocalRef : bestInstrumentalRef;
                        if (!active) continue;
                        double elapsed=(double)(source-ev.start_sample)/rate;
                        ASSpatialSource spatialSource={.stem=(ASSpatialStem)ev.stem,.position={0,-1,0},.distance=0,.size=.4f,.gain=1};
                        float gestureDuration=(float)((double)(ev.end_sample-ev.start_sample)/rate);
                        ASSpatialMotion motion={.type=(ASSpatialMotionType)ev.motion,.intensity=ev.intensity,.direction=ev.direction,.duration_seconds=gestureDuration,.tail_seconds=ev.tail_seconds};
                        ASSpatialPosition position=ASSpatialMotionPosition(&spatialSource,&motion,elapsed);
                        ASExtractEvent extract={.event_id=ev.event_id,.stream_epoch=ev.epoch,.start_sample=ev.start_sample,.end_sample=ev.end_sample,.source=ev.stem,.priority=ev.priority,.intensity=ev.intensity,.attack_seconds=ev.attack_seconds,.release_seconds=ev.release_seconds,.tail_seconds=ev.tail_seconds,.selected=true};
                        float env=ASExtractEnvelope(source,&extract,rate), sl=0, sr=0;
                        if (env<=0) continue;
                        float srcL=ev.stem==0?f.vl:f.il, srcR=ev.stem==0?f.vr:f.ir;
                        foregroundL+=srcL*env; foregroundR+=srcR*env;
                        active->foreground_square+=(double)(srcL*env)*(srcL*env)+(double)(srcR*env)*(srcR*env);
                        active->rendered_frames++;
                        if (env > 0 && !active->lifecycle_rendered) {
                            active->lifecycle_rendered = 1;
                            atomic_fetch_add_explicit(&c->spatial.rendered_events,1,memory_order_relaxed);
                            trace(c,eventTrace(c,active,AS_TRACE_RENDERED,0,source));
                        }
                        if (ev.stem==ASSpatialStemVocal) { ASSpatialRenderStereo(&cfg,position,f.vl,f.vr,env,&sl,&sr); mix_vl += sl-f.vl; mix_vr += sr-f.vr; }
                        else { ASSpatialRenderStereo(&cfg,position,f.il,f.ir,env,&sl,&sr); mix_il += sl-f.il; mix_ir += sr-f.ir; }
                        atomic_fetch_add_explicit(&c->spatial_applied, 1, memory_order_relaxed);
                        atomic_fetch_add(&c->renderer_frames[cfg.route],1);
                        spatial_frame = true;
                        float eventDelta = fabsf(sl - (ev.stem == ASSpatialStemVocal ? f.vl : f.il)) + fabsf(sr - (ev.stem == ASSpatialStemVocal ? f.vr : f.ir));
                        active->delta_square+=(double)(sl-srcL)*(sl-srcL)+(double)(sr-srcR)*(sr-srcR);
                        if(eventDelta>1e-7f) active->mixed_frames++;
                        if (eventDelta > 1e-7f && !active->lifecycle_mixed) {
                            active->lifecycle_mixed = 1;
                            atomic_fetch_add_explicit(&c->spatial.mixed_events,1,memory_order_relaxed);
                            trace(c,eventTrace(c,active,AS_TRACE_MIXED,0,source));
                            if(c->terminal_pending_count<16) c->terminal_pending[c->terminal_pending_count++]=eventTrace(c,active,AS_TRACE_SUBMITTED,0,source);
                        }
                    }
                }
                float mix_l = has_stems ? mix_vl * c->vocal_gain + mix_il * c->instrumental_gain : original_l;
                float mix_r = has_stems ? mix_vr * c->vocal_gain + mix_ir * c->instrumental_gain : original_r;
                /* Live keeps a stable, low-risk base scene even between sparse
                 * accent events. This is the audible part of Stereo Width: it
                 * widens the reconstructed mid/side pair only in Live, while
                 * Original and Shadow remain bit-for-bit on the existing path. */
                if (!selfTest && has_stems && mode == 2 && atomic_load_explicit(&c->spatial.enabled, memory_order_acquire) &&
                    atomic_load_explicit(&c->spatial.stereo_width, memory_order_relaxed)) {
                    float width=ASBitsFloat(atomic_load_explicit(&c->spatial.width_bits,memory_order_relaxed));
                    float intensity=ASBitsFloat(atomic_load_explicit(&c->spatial.intensity_bits,memory_order_relaxed));
                    ASSpatialRoute route=(ASSpatialRoute)atomic_load_explicit(&c->spatial.route,memory_order_relaxed);
                    if (route != ASSpatialRouteMonoSafe && width > 0 && intensity > 0) {
                        float mid=.5f*(mix_l+mix_r), side=.5f*(mix_l-mix_r);
                        float center=ASBitsFloat(atomic_load_explicit(&c->spatial.center_bits,memory_order_relaxed));
                        float gain=1.0f + .35f*width*intensity*(1.0f-.35f*ASSpatialClamp(center,0,1));
                        side*=ASSpatialClamp(gain,1.0f,1.35f);
                        mix_l=mid+side; mix_r=mid-side;
                        atomic_fetch_add_explicit(&c->spatial_base_applied,1,memory_order_relaxed);
                        base_frame = true;
                    }
                }
                out_l = original_l + c->stem_weight * (mix_l - original_l);
                out_r = original_r + c->stem_weight * (mix_r - original_r);
                /* Align the delayed analysis path over 20 ms.  The first
                 * sample remains the live original, then it crossfades to the
                 * same-index delayed result; this avoids both the old silent
                 * preroll and a discontinuity at the latency boundary. */
                float align = selfTest?1:(float)(offset - delay + 1) / (float)fmax(rate * .02, 1.0);
                align = align < 0 ? 0 : align > 1 ? 1 : align;
                align = align * align * (3.0f - 2.0f * align);
                out_l = in_l + align * (out_l - in_l);
                out_r = in_r + align * (out_r - in_r);
                reference_l = in_l + align * (reference_l - in_l);
                reference_r = in_r + align * (reference_r - in_r);
                c->began_output = true;
                atomic_store_explicit(&c->output_cursor, source + 1, memory_order_release);
                if (mode == 2 && align >= 1) {
                    double e_l = out_l - original_l, e_r = out_r - original_r;
                    c->second.error_square += e_l * e_l + e_r * e_r;
                }
            }
        }
        if (fallback && !c->fallback) atomic_fetch_add_explicit(&c->fallback_transitions, 1, memory_order_relaxed);
        if (fallback) atomic_fetch_add_explicit(&c->underruns, 1, memory_order_relaxed);
        c->fallback = fallback;
        if(testPhase==1) {
            double t=(double)c->test.elapsed/rate;
            float ramp=fminf(1,(float)fmin(t/.02,(2-t)/.02));
            float pan=.8f*sinf((float)(2*M_PI*t*.7));
            out_l=in_l*(1-ramp*(.22f+.20f*pan)); out_r=in_r*(1-ramp*(.22f-.20f*pan));
        } else if(testPhase==2) {
            double t=(double)c->test.elapsed/rate-2;
            unsigned route=(unsigned)t; if(route>3) route=3;
            ASSpatialRenderConfig cfg; ASSpatialRenderConfigDefault(&cfg,(ASSpatialRoute)route);
            cfg.intensity=.9f; cfg.width=.95f; cfg.depth=.5f;
            ASSpatialMotion motion={.type=(ASSpatialMotionType)(route%3),.intensity=.9f,.direction=1,.duration_seconds=1};
            ASSpatialSource src={.position={0,-1,0},.gain=1};
            ASSpatialPosition p=ASSpatialMotionPosition(&src,&motion,t-floor(t));
            float env=ASSpatialEnvelope(t-floor(t),1,.02f,.9f);
            ASSpatialRenderStereo(&cfg,p,in_l,in_r,env,&out_l,&out_r);
            atomic_fetch_add(&c->test.renderer_frames[route],1); atomic_fetch_add(&c->renderer_frames[route],1); spatial_frame=true;
        }
        if(!isfinite(out_l)||!isfinite(out_r)) { out_l=reference_l; out_r=reference_r; fallback=true; }
        l[i] = out_l; r[i] = out_r;
        if(c->reference_left) c->reference_left[i]=reference_l;
        if(c->reference_right) c->reference_right[i]=reference_r;
        if(c->foreground_left) c->foreground_left[i]=foregroundL;
        if(c->foreground_right) c->foreground_right[i]=foregroundR;
        if(mode<2 || !supported) atomic_store(&c->output_cursor,position+1);
        if(!spatial_frame && !base_frame) atomic_fetch_add(&c->bypassed_frames,1);
        if(testPhase) {
            float dl=out_l-reference_l, dr=out_r-reference_r;
            uint64_t square=(uint64_t)llround(((double)dl*dl+(double)dr*dr)*1e9);
            atomic_fetch_add(&c->test.square_nano[testPhase-1],square);
            atomic_fetch_add(&c->test.changed[testPhase-1],fabsf(dl)>1e-7f || fabsf(dr)>1e-7f);
            float peak=fmaxf(fabsf(dl),fabsf(dr));
            if(peak>ASBitsFloat(atomic_load(&c->test.peak_bits[testPhase-1]))) atomic_store(&c->test.peak_bits[testPhase-1],ASFloatBits(peak));
            atomic_fetch_add(&c->test.phase_frames[testPhase-1],1); atomic_fetch_add(&c->test.frames,1);
            atomic_store(&c->test.phase,testPhase); c->test.elapsed++;
            if(c->test.elapsed>=(uint64_t)llround(8.5*rate)) {
                c->test.running=false; atomic_store(&c->test.phase,4); atomic_store(&c->test.request,0);
                ASStreamSpatialClear(c,epoch); /* no test event can outlive its finite run */
                ASStreamRequestReset(c);
            }
        }
        if ((mode == 2 && has_stems) || testPhase) {
            float dl=out_l-reference_l, dr=out_r-reference_r;
            float delta=fmaxf(fabsf(dl),fabsf(dr));
            if (delta > 1e-6f) atomic_fetch_add_explicit(&c->spatial_nonzero_delta,1,memory_order_relaxed);
            c->second.spatial_delta_peak=fmax(c->second.spatial_delta_peak,delta);
            c->second.spatial_delta_square+=(double)dl*dl+(double)dr*dr;
            c->second.spatial_changed_frames += delta > 1e-6f;
        }
        ASStreamTelemetry *s = &c->second;
        if (!s->input_frames) { s->epoch = epoch; s->start = position; s->rate = rate; s->mode = mode; s->sample_time = st + i; s->host_seconds = host; }
        s->end = position + 1; s->input_frames++; s->output_frames += c->began_output || mode < 2;
        s->stem_frames += has_stems; s->fallback_frames += fallback;
        s->spatial_frames += spatial_frame; s->spatial_base_frames += base_frame;
        s->spatial_renderer_frames += spatial_frame;
        s->bypassed_frames += !spatial_frame && !base_frame;
        s->fallback_output_frames += fallback;
        s->actual_renderer = atomic_load_explicit(&c->spatial.route, memory_order_relaxed);
        s->spatial_live = mode == 2 && atomic_load_explicit(&c->spatial.enabled, memory_order_relaxed);
        if (has_stems) atomic_fetch_add_explicit(&c->rendered_stem_frames,1,memory_order_relaxed);
        if (fallback) atomic_fetch_add_explicit(&c->rendered_fallback_frames,1,memory_order_relaxed);
        s->input_square += (double)in_l * in_l + (double)in_r * in_r;
        s->input_peak = fmax(s->input_peak, fmax(fabs(in_l), fabs(in_r)));
        s->output_square += (double)out_l * out_l + (double)out_r * out_r;
        s->output_peak = fmax(s->output_peak, fmax(fabs(out_l), fabs(out_r)));
        if (s->input_frames >= (uint64_t)rate) publish_second(c);
    }
    activateDue(c,atomic_load(&c->output_cursor),rate);
    if (queue_input) atomic_store_explicit(&c->input_head, head + n, memory_order_release);
    atomic_store_explicit(&c->input_cursor, c->cursor, memory_order_release);
}
float ASStreamBlend(size_t n, size_t length, size_t overlap, bool previous) {
    if (previous && n < overlap) return (float)(n + 1) / (float)(overlap + 1);
    if (n >= length - overlap) return (float)(length - n) / (float)(overlap + 1);
    return 1;
}
// Bounded, deterministic 48-tap Hann-windowed sinc; analysis worker only.
// Absolute sample phase is fixed by the window start (1.5 s is integral at both rates).
void ASStreamResample(const float *in, size_t count, double from, float *out, size_t wanted, double to) {
    if (!out || !wanted) return;
    if (!in || !count || from <= 0 || to <= 0 || !isfinite(from) || !isfinite(to)) {
        memset(out, 0, wanted * sizeof(float));
        return;
    }
    if (from == to && count == wanted) { memcpy(out, in, count * sizeof(float)); return; }
    double cutoff = fmin(1, to / from) * .95;
    for (size_t i = 0; i < wanted; i++) {
        double x = i * from / to, sum = 0, weight = 0;
        int64_t center = (int64_t)floor(x);
        for (int tap = -23; tap <= 24; tap++) {
            int64_t at = center + tap;
            double d = x - at;
            if (fabs(d) >= 24) continue;
            double sinc = fabs(d) < 1e-9 ? cutoff : sin(M_PI * cutoff * d) / (M_PI * d);
            double w = sinc * (.5 + .5 * cos(M_PI * d / 24));
            // reflected endpoint extension, matching the separator's convention
            if (at < 0) at = -at;
            if ((uint64_t)at >= count) at = 2 * (int64_t)count - 2 - at;
            if (at < 0) at = 0;
            sum += in[at] * w; weight += w;
        }
        out[i] = fabs(weight) > 1e-12 ? (float)(sum / weight) : 0.0f;
    }
}
