#include "AISpatialStreamCore.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

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
    atomic_init(&c->epoch, 0); atomic_init(&c->reset_request, 1);
    atomic_init(&c->input_cursor, 0); atomic_init(&c->output_cursor, 0);
    atomic_init(&c->overflows, 0); atomic_init(&c->underruns, 0); atomic_init(&c->fallback_transitions, 0);
    atomic_init(&c->discontinuities, 0); atomic_init(&c->input_dropped, 0); atomic_init(&c->output_dropped, 0);
    atomic_init(&c->stale_outputs, 0); atomic_init(&c->requested_mode, 0); atomic_init(&c->active_mode, 0);
    atomic_init(&c->rate_bits, 0);
    c->vocal_gain = c->instrumental_gain = 1;
    return true;
}
void ASStreamDestroy(ASStreamCore *c) { free(c->input); free(c->output); free(c->history_l); free(c->history_r); }
void ASStreamRequestReset(ASStreamCore *c) { atomic_fetch_add_explicit(&c->reset_request, 1, memory_order_release); }
void ASStreamRequestMode(ASStreamCore *c, int mode) {
    if (mode >= 0 && mode <= 4) atomic_store_explicit(&c->requested_mode, mode, memory_order_release);
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
    }
    atomic_store_explicit(&c->active_mode, mode, memory_order_release);
    c->timestamp_valid = isfinite(st); c->expected_sample_time = st + n;
    bool supported = fabs(rate - 44100) < .5 || fabs(rate - 48000) < .5;
    uint64_t epoch = atomic_load_explicit(&c->epoch, memory_order_acquire);
    // An in-flight worker can publish at most one race-losing block after an
    // epoch boundary.  Bound stale-frame inspection per callback so that even
    // a malformed producer cannot turn render time into an unbounded drain.
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
        uint64_t source = position;
        if (mode >= 2 && supported) {
            if (offset < delay) { out_l = out_r = 0; }
            else {
                source = position - delay;
                float original_l = c->history_l[source % AS_STREAM_CAPACITY], original_r = c->history_r[source % AS_STREAM_CAPACITY];
                ASStreamOutput f;
                has_stems = pop_matching(c, epoch, source, &f, &staleDiscardBudget);
                if (has_stems && (!isfinite(f.vl) || !isfinite(f.vr) || !isfinite(f.il) || !isfinite(f.ir))) has_stems = false;
                fallback = !has_stems;
                c->stem_weight = approach(c->stem_weight, has_stems ? 1 : 0, fade_step);
                c->vocal_gain = approach(c->vocal_gain, mode == 4 ? 0 : 1, fade_step);
                c->instrumental_gain = approach(c->instrumental_gain, mode == 3 ? 0 : 1, fade_step);
                // Both sides of any blend have EXACTLY the same source index.
                float mix_l = has_stems ? f.vl * c->vocal_gain + f.il * c->instrumental_gain : original_l;
                float mix_r = has_stems ? f.vr * c->vocal_gain + f.ir * c->instrumental_gain : original_r;
                out_l = original_l + c->stem_weight * (mix_l - original_l);
                out_r = original_r + c->stem_weight * (mix_r - original_r);
                float startup_gain = fminf(1, (float)(offset - delay + 1) / (float)(rate * .005));
                out_l *= startup_gain; out_r *= startup_gain;
                c->began_output = true;
                atomic_store_explicit(&c->output_cursor, source + 1, memory_order_release);
                if (mode == 2 && startup_gain == 1) {
                    double e_l = out_l - original_l, e_r = out_r - original_r;
                    c->second.error_square += e_l * e_l + e_r * e_r;
                }
            }
        }
        if (fallback && !c->fallback) atomic_fetch_add_explicit(&c->fallback_transitions, 1, memory_order_relaxed);
        if (fallback) atomic_fetch_add_explicit(&c->underruns, 1, memory_order_relaxed);
        c->fallback = fallback;
        l[i] = out_l; r[i] = out_r;
        ASStreamTelemetry *s = &c->second;
        if (!s->input_frames) { s->epoch = epoch; s->start = position; s->rate = rate; s->mode = mode; s->sample_time = st + i; s->host_seconds = host; }
        s->end = position + 1; s->input_frames++; s->output_frames += c->began_output || mode < 2;
        s->stem_frames += has_stems; s->fallback_frames += fallback;
        s->input_square += (double)in_l * in_l + (double)in_r * in_r;
        s->input_peak = fmax(s->input_peak, fmax(fabs(in_l), fabs(in_r)));
        s->output_square += (double)out_l * out_l + (double)out_r * out_r;
        s->output_peak = fmax(s->output_peak, fmax(fabs(out_l), fabs(out_r)));
        if (s->input_frames >= (uint64_t)rate) publish_second(c);
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
