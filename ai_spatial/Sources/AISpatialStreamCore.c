#include "AISpatialStreamCore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

static uint32_t ASFloatBits(float value) { uint32_t bits; memcpy(&bits, &value, sizeof(bits)); return bits; }
static float ASBitsFloat(uint32_t bits) { float value; memcpy(&value, &bits, sizeof(value)); return value; }
static float ASSpatialClamp(float value, float lo, float hi) { return value < lo ? lo : value > hi ? hi : value; }

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
bool ASStreamSpatialSchedule(ASStreamCore *c, const ASStreamSpatialEvent *event) {
    if (!c) return false;
    if (!event || event->end_sample <= event->start_sample || event->stem > ASSpatialStemInstrumental ||
        event->motion > ASSpatialMotionReflection || !isfinite(event->priority) || !isfinite(event->intensity) ||
        !isfinite(event->direction) || !isfinite(event->attack_seconds) || !isfinite(event->release_seconds) ||
        !isfinite(event->tail_seconds) || event->attack_seconds < 0 || event->release_seconds < 0 ||
        event->tail_seconds < 0 || event->tail_seconds > .45f) {
        atomic_fetch_add_explicit(&c->spatial.rejected,1,memory_order_relaxed); return false;
    }
    if (event->epoch != atomic_load_explicit(&c->epoch, memory_order_acquire)) {
        atomic_fetch_add_explicit(&c->spatial.rejected,1,memory_order_relaxed);
        atomic_fetch_add_explicit(&c->spatial.stale_epoch,1,memory_order_relaxed); return false;
    }
    // One Accent producer and one render consumer. Publish after copying, and
    // never reuse a slot until the render consumer releases its tail.
    uint64_t head=atomic_load_explicit(&c->spatial.event_head,memory_order_relaxed);
    uint64_t tail=atomic_load_explicit(&c->spatial.event_tail,memory_order_acquire);
    if (head-tail >= AS_STREAM_SPATIAL_SLOTS) {
        atomic_fetch_add_explicit(&c->spatial.rejected,1,memory_order_relaxed); return false;
    }
    c->spatial.pending[head % AS_STREAM_SPATIAL_SLOTS]=*event;
    atomic_store_explicit(&c->spatial.event_head,head+1,memory_order_release);
    atomic_fetch_add_explicit(&c->spatial.scheduled,1,memory_order_relaxed);
    return true;
}
void ASStreamSpatialClear(ASStreamCore *c, uint64_t epoch) {
    if (!c) return;
    // A boundary owns both queues. Leaving pending entries behind made the
    // next epoch spend its first callbacks rejecting stale events and hid the
    // real reason an accent never reached the renderer.
    atomic_fetch_add_explicit(&c->spatial.cancelled,c->spatial.active_count,memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&c->spatial.event_head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&c->spatial.event_tail, memory_order_relaxed);
    if (head > tail) atomic_fetch_add_explicit(&c->spatial.cancelled, head - tail, memory_order_relaxed);
    atomic_store_explicit(&c->spatial.event_tail, head, memory_order_release);
    c->spatial.active_count=0; c->spatial.active_epoch=epoch;
}
void ASStreamSpatialSetSelfTest(ASStreamCore *c, bool enabled) {
    if (!c) return;
    atomic_store_explicit(&c->spatial.self_test, enabled, memory_order_release);
}
static void ASStreamSpatialDrain(ASStreamCore *c, uint64_t epoch) {
    uint64_t tail=atomic_load_explicit(&c->spatial.event_tail,memory_order_relaxed);
    uint64_t head=atomic_load_explicit(&c->spatial.event_head,memory_order_acquire);
    for (unsigned budget=0;tail<head && budget<AS_STREAM_SPATIAL_SLOTS;budget++,tail++) {
        ASStreamSpatialEvent event=c->spatial.pending[tail % AS_STREAM_SPATIAL_SLOTS];
        if (event.epoch!=epoch) {
            atomic_fetch_add_explicit(&c->spatial.cancelled,1,memory_order_relaxed);
            atomic_fetch_add_explicit(&c->spatial.stale_epoch,1,memory_order_relaxed); continue;
        }
        if (event.start_sample<atomic_load_explicit(&c->output_cursor,memory_order_relaxed)) {
            atomic_fetch_add_explicit(&c->spatial.cancelled,1,memory_order_relaxed);
            atomic_fetch_add_explicit(&c->spatial.late_events,1,memory_order_relaxed); continue;
        }
        bool duplicate=false;
        for(size_t i=0;i<c->spatial.active_count;i++) if(c->spatial.active[i].event_id==event.event_id) duplicate=true;
        unsigned maxActive=atomic_load_explicit(&c->spatial.max_active,memory_order_relaxed); if (maxActive<1 || maxActive>8) maxActive=8;
        if (duplicate || c->spatial.active_count>=maxActive) {
            atomic_fetch_add_explicit(&c->spatial.rejected,1,memory_order_relaxed);
            if (duplicate) atomic_fetch_add_explicit(&c->spatial.duplicate_rejected,1,memory_order_relaxed);
            else atomic_fetch_add_explicit(&c->spatial.capacity_rejected,1,memory_order_relaxed);
            continue;
        }
        event.lifecycle_rendered = 0; event.lifecycle_mixed = 0;
        c->spatial.active[c->spatial.active_count++]=event;
        atomic_fetch_add_explicit(&c->spatial.activated,1,memory_order_relaxed);
    }
    atomic_store_explicit(&c->spatial.event_tail,tail,memory_order_release);
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
    int requested = atomic_load_explicit(&c->requested_mode, memory_order_acquire);
    int mode = atomic_load_explicit(&c->active_mode, memory_order_relaxed);
    uint64_t reset = atomic_load_explicit(&c->reset_request, memory_order_acquire);
    bool discontinuity = isfinite(st) && c->timestamp_valid && fabs(st - c->expected_sample_time) > 1.5;
    bool boundary = reset != c->handled_reset || c->rate != rate || discontinuity;
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
        atomic_store_explicit(&c->spatial_applied, 0, memory_order_relaxed);
        atomic_store_explicit(&c->spatial_base_applied, 0, memory_order_relaxed);
        atomic_store_explicit(&c->spatial_nonzero_delta, 0, memory_order_relaxed);
        atomic_store_explicit(&c->spatial_delta_peak_bits, 0, memory_order_relaxed);
        atomic_store_explicit(&c->spatial_delta_rms_bits, 0, memory_order_relaxed);
        atomic_store_explicit(&c->rendered_stem_frames, 0, memory_order_relaxed);
        atomic_store_explicit(&c->rendered_fallback_frames, 0, memory_order_relaxed);
        atomic_store_explicit(&c->terminal_frames, 0, memory_order_relaxed);
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
        bool selfTest = atomic_load_explicit(&c->spatial.self_test, memory_order_acquire);
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
                if (has_stems && atomic_load_explicit(&c->spatial.enabled, memory_order_acquire) &&
                    atomic_load_explicit(&c->spatial.accent_motion, memory_order_acquire)) {
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
                    ASStreamSpatialEvent bestVocal={0}, bestInstrumental={0};
                    ASStreamSpatialEvent *bestVocalRef=NULL, *bestInstrumentalRef=NULL;
                    bool haveVocal=false, haveInstrumental=false;
                    for (size_t si=0; si<c->spatial.active_count; si++) {
                        ASStreamSpatialEvent *active = &c->spatial.active[si];
                        ASStreamSpatialEvent ev=*active;
                        if (ev.epoch!=epoch || source<ev.start_sample || source>=ev.end_sample) continue;
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
                        if (env > 0 && !active->lifecycle_rendered) {
                            active->lifecycle_rendered = 1;
                            atomic_fetch_add_explicit(&c->spatial.rendered_events,1,memory_order_relaxed);
                        }
                        if (ev.stem==ASSpatialStemVocal) { ASSpatialRenderStereo(&cfg,position,f.vl,f.vr,env,&sl,&sr); mix_vl += sl-f.vl; mix_vr += sr-f.vr; }
                        else { ASSpatialRenderStereo(&cfg,position,f.il,f.ir,env,&sl,&sr); mix_il += sl-f.il; mix_ir += sr-f.ir; }
                        atomic_fetch_add_explicit(&c->spatial_applied, 1, memory_order_relaxed);
                        spatial_frame = true;
                        float eventDelta = fabsf(sl - (ev.stem == ASSpatialStemVocal ? f.vl : f.il)) + fabsf(sr - (ev.stem == ASSpatialStemVocal ? f.vr : f.ir));
                        if (eventDelta > 1e-7f && !active->lifecycle_mixed) {
                            active->lifecycle_mixed = 1;
                            atomic_fetch_add_explicit(&c->spatial.mixed_events,1,memory_order_relaxed);
                            atomic_fetch_add_explicit(&c->spatial.submitted_events,1,memory_order_relaxed);
                        }
                    }
                }
                float mix_l = has_stems ? mix_vl * c->vocal_gain + mix_il * c->instrumental_gain : original_l;
                float mix_r = has_stems ? mix_vr * c->vocal_gain + mix_ir * c->instrumental_gain : original_r;
                /* Live keeps a stable, low-risk base scene even between sparse
                 * accent events. This is the audible part of Stereo Width: it
                 * widens the reconstructed mid/side pair only in Live, while
                 * Original and Shadow remain bit-for-bit on the existing path. */
                if (has_stems && mode == 2 && atomic_load_explicit(&c->spatial.enabled, memory_order_acquire) &&
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
                float align = (float)(offset - delay + 1) / (float)fmax(rate * .02, 1.0);
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
        l[i] = out_l; r[i] = out_r;
        if (mode == 2 && has_stems) {
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
        if (has_stems) atomic_fetch_add_explicit(&c->rendered_stem_frames,1,memory_order_relaxed);
        if (fallback) atomic_fetch_add_explicit(&c->rendered_fallback_frames,1,memory_order_relaxed);
        s->input_square += (double)in_l * in_l + (double)in_r * in_r;
        s->input_peak = fmax(s->input_peak, fmax(fabs(in_l), fabs(in_r)));
        s->output_square += (double)out_l * out_l + (double)out_r * out_r;
        s->output_peak = fmax(s->output_peak, fmax(fabs(out_l), fabs(out_r)));
        if (s->input_frames >= (uint64_t)rate) publish_second(c);
    }
    uint64_t played=atomic_load_explicit(&c->output_cursor,memory_order_relaxed);
    for(size_t i=0;i<c->spatial.active_count;) {
        uint64_t tail=(uint64_t)llround(fmaxf(c->spatial.active[i].tail_seconds,0)*rate);
        if(c->spatial.active[i].end_sample + tail <= played) {
            atomic_fetch_add_explicit(&c->spatial.completed_events,1,memory_order_relaxed);
            c->spatial.active[i]=c->spatial.active[--c->spatial.active_count];
        }
        else i++;
    }
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
