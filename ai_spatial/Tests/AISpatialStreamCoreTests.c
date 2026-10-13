#include "AISpatialStreamCore.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void test_blend_and_resample(void) {
    assert(ASStreamBlend(0, 100, 25, false) == 1.0f);
    assert(ASStreamBlend(99, 100, 25, false) > 0.0f);
    assert(ASStreamBlend(0, 100, 25, true) > 0.0f);
    assert(ASStreamBlend(0, 100, 25, true) < ASStreamBlend(24, 100, 25, true));

    float input[97], output[193];
    for (size_t i = 0; i < 97; i++) input[i] = 0.25f;
    ASStreamResample(input, 97, 44100, output, 193, 48000);
    for (size_t i = 0; i < 193; i++) assert(fabsf(output[i] - 0.25f) < 0.002f);

    float identity[97];
    ASStreamResample(input, 97, 44100, identity, 97, 44100);
    assert(memcmp(input, identity, sizeof(input)) == 0);
}

static void test_output_ring(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamOutput one = { .epoch = 0, .block_id = 4, .sample = 123, .vl = .1f, .vr = .2f, .il = .2f, .ir = .3f };
    assert(ASStreamPushOutput(&core, &one, 1));
    /* The public ring API rejects an entire block when capacity is exceeded. */
    assert(ASStreamPushOutput(&core, &one, AS_STREAM_CAPACITY + 1) == false);
    assert(atomic_load(&core.output_dropped) == AS_STREAM_CAPACITY + 1);
    ASStreamDestroy(&core);
}

static void render_block(ASStreamCore *core, size_t start, size_t count, float *left, float *right) {
    for (size_t i = 0; i < count; i++) {
        left[i] = 0.15f + (float)((start + i) % 1000) * 0.0001f;
        right[i] = -0.10f + (float)((start + i) % 700) * 0.0001f;
    }
    ASStreamRender(core, left, right, (uint32_t)count, 44100.0, NAN, NAN);
}

static void test_mode_transition_and_synchronised_fallback(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    float left[512], right[512];
    render_block(&core, 0, 512, left, right);
    assert(atomic_load(&core.active_mode) == 0);

    ASStreamRequestMode(&core, 2); /* Original -> AI Live must commit at the next render boundary. */
    const size_t delay = (size_t)llround(AS_STREAM_DELAY_SECONDS * 44100.0);
    size_t total = delay + 44100 / 10;
    size_t position = 512;
    float *observed = calloc(total, sizeof(float));
    float *observedR = calloc(total, sizeof(float));
    assert(observed && observedR);
    size_t written = 0;
    while (written < total) {
        size_t n = total - written > 512 ? 512 : total - written;
        render_block(&core, position, n, left, right);
        memcpy(observed + written, left, n * sizeof(float));
        memcpy(observedR + written, right, n * sizeof(float));
        written += n; position += n;
    }
    assert(atomic_load(&core.active_mode) == 2);
    /* Preroll must remain audible while the worker catches up. */
    size_t startupSource = 512 + delay - 1;
    float startupExpected = 0.15f + (float)(startupSource % 1000) * 0.0001f;
    assert(fabsf(observed[delay - 1] - startupExpected) < 1e-6f);
    size_t check = delay + 44100 / 20 + 100;
    size_t source = 512 + check - delay;
    float expectedL = 0.15f + (float)((source % 1000)) * 0.0001f;
    float expectedR = -0.10f + (float)((source % 700)) * 0.0001f;
    assert(fabsf(observed[check] - expectedL) < 1e-6f);
    assert(fabsf(observedR[check] - expectedR) < 1e-6f);
    free(observed); free(observedR);
    ASStreamDestroy(&core);
}

static void test_synchronised_stem_frame(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamRequestMode(&core, 2);
    float left[1] = { 0.4f }, right[1] = { -0.2f };
    ASStreamRender(&core, left, right, 1, 44100.0, NAN, NAN);
    uint64_t epoch = atomic_load(&core.epoch);
    const size_t stemFrames = 5000;
    ASStreamOutput *stems = calloc(stemFrames, sizeof(*stems));
    assert(stems);
    for (size_t i = 0; i < stemFrames; i++) stems[i] = (ASStreamOutput){ .epoch = epoch, .block_id = 9, .sample = i, .vl = 0.2f, .vr = -0.1f, .il = 0.1f, .ir = -0.05f };
    assert(ASStreamPushOutput(&core, stems, stemFrames));
    free(stems);

    const size_t delay = (size_t)llround(AS_STREAM_DELAY_SECONDS * 44100.0);
    float blockL[512], blockR[512];
    size_t position = 1;
    bool observed = false;
    size_t target = delay + 1000;
    while (position <= target) {
        size_t n = target + 1 - position > 512 ? 512 : target + 1 - position;
        memset(blockL, 0, sizeof(blockL)); memset(blockR, 0, sizeof(blockR));
        ASStreamRender(&core, blockL, blockR, (uint32_t)n, 44100.0, NAN, NAN);
        if (position <= target && target < position + n) {
            size_t index = target - position;
            /* The synchronized vocal+instrumental frame reconstructs the
               original sample at the exact delayed source index. */
            assert(fabsf(blockL[index] - 0.3f) < 1e-5f);
            assert(fabsf(blockR[index] + 0.15f) < 1e-5f);
            observed = true;
        }
        position += n;
    }
    assert(observed);
    ASStreamDestroy(&core);
}

static void test_reset_discards_previous_epoch_output(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamRequestMode(&core, 2);
    float left[64] = {0}, right[64] = {0};
    ASStreamRender(&core, left, right, 64, 44100.0, NAN, NAN);
    uint64_t oldEpoch = atomic_load(&core.epoch);
    ASStreamOutput frame = { .epoch = oldEpoch, .block_id = 1, .sample = 0, .vl = .1f, .vr = .1f, .il = .1f, .ir = .1f };
    assert(ASStreamPushOutput(&core, &frame, 1));
    uint64_t oldHead = atomic_load(&core.output_head);
    ASStreamRequestReset(&core);
    ASStreamRender(&core, left, right, 64, 44100.0, NAN, NAN);
    assert(atomic_load(&core.epoch) != oldEpoch);
    assert(atomic_load(&core.output_tail) == atomic_load(&core.output_head));
    assert(atomic_load(&core.stale_outputs) >= oldHead);
    ASStreamDestroy(&core);
}

static void test_timestamp_discontinuity_starts_new_epoch(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamRequestMode(&core, 1);
    float left[64] = {0}, right[64] = {0};
    ASStreamRender(&core, left, right, 64, 44100.0, 0.0, NAN);
    uint64_t firstEpoch = atomic_load(&core.epoch);
    ASStreamRender(&core, left, right, 64, 44100.0, 4096.0, NAN);
    assert(atomic_load(&core.epoch) != firstEpoch);
    assert(atomic_load(&core.discontinuities) == 1);
    ASStreamDestroy(&core);
}

static void test_bounded_input_overflow(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamRequestMode(&core, 1); /* Shadow queues PCM but keeps the source audible. */
    float left[1024], right[1024];
    size_t position = 0;
    while (position < AS_STREAM_CAPACITY + 1024) {
        size_t n = (AS_STREAM_CAPACITY + 1024 - position > 1024) ? 1024 : AS_STREAM_CAPACITY + 1024 - position;
        render_block(&core, position, n, left, right);
        position += n;
    }
    assert(atomic_load(&core.overflows) > 0);
    assert(atomic_load(&core.input_dropped) > 0);
    ASStreamDestroy(&core);
}

static void test_spatial_event_is_future_stem_delta(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamRequestMode(&core, 2);
    ASStreamSpatialConfigure(&core, ASSpatialRouteUniversalStereo, true, .8f, .9f, .4f, .7f, .8f, .08f);
    float firstL[1] = {.3f}, firstR[1] = {.3f};
    ASStreamRender(&core, firstL, firstR, 1, 44100, NAN, NAN);
    uint64_t epoch = atomic_load(&core.epoch);
    ASStreamOutput *stems = calloc(400, sizeof(*stems)); assert(stems);
    for (size_t i=0;i<400;i++) stems[i]=(ASStreamOutput){epoch, 1, i, .2f, .2f, .1f, .1f};
    assert(ASStreamPushOutput(&core, stems, 400)); free(stems);
    ASStreamSpatialEvent event={77, epoch, 0, 250, ASSpatialStemVocal, ASSpatialMotionFlyby, .9f, .9f, 1};
    assert(ASStreamSpatialSchedule(&core, &event));
    const size_t delay=(size_t)llround(AS_STREAM_DELAY_SECONDS*44100);
    float left[512], right[512]; size_t position=1; bool changed=false;
    while (position < delay+180) {
        size_t count=(delay+180-position)>512?512:(delay+180-position);
        for(size_t i=0;i<count;i++){left[i]=right[i]=.3f;}
        ASStreamRender(&core,left,right,(uint32_t)count,44100,NAN,NAN);
        for(size_t i=0;i<count;i++) if (position+i >= delay+30 && position+i < delay+150 && fabsf(left[i]-.3f)>1e-4f) changed=true;
        position+=count;
    }
    assert(changed); assert(atomic_load(&core.spatial_applied)>0);
    assert(atomic_load(&core.spatial_base_applied)>0);
    ASStreamDestroy(&core);
}

static void test_live_base_scene_changes_stem_mix_without_event(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamRequestMode(&core, 2);
    ASStreamSpatialConfigure(&core, ASSpatialRouteUniversalStereo, true, .8f, .9f, .4f, .7f, .8f, .08f);
    ASStreamSpatialSetComponents(&core, true, true, true, true, true);
    float firstL[1] = {.3f}, firstR[1] = {.2f};
    ASStreamRender(&core, firstL, firstR, 1, 44100, NAN, NAN);
    uint64_t epoch = atomic_load(&core.epoch);
    const size_t stemFrames = 400;
    ASStreamOutput *stems = calloc(stemFrames, sizeof(*stems)); assert(stems);
    for (size_t i = 0; i < stemFrames; i++) {
        /* The source mix is (.30, .20), but it has a measurable side signal. */
        stems[i] = (ASStreamOutput){epoch, 2, i, .20f, .10f, .10f, .10f};
    }
    assert(ASStreamPushOutput(&core, stems, stemFrames)); free(stems);
    const size_t delay = (size_t)llround(AS_STREAM_DELAY_SECONDS * 44100);
    float left[512], right[512]; size_t position = 1; bool changed = false;
    while (position < delay + 180) {
        size_t count = (delay + 180 - position) > 512 ? 512 : delay + 180 - position;
        for (size_t i = 0; i < count; i++) { left[i] = .3f; right[i] = .2f; }
        ASStreamRender(&core, left, right, (uint32_t)count, 44100, NAN, NAN);
        for (size_t i = 0; i < count; i++) {
            if (position + i >= delay + 30 && fabsf(left[i] - .3f) > 1e-4f) changed = true;
        }
        position += count;
    }
    assert(changed);
    assert(atomic_load(&core.spatial_applied) == 0);
    assert(atomic_load(&core.spatial_base_applied) > 0);
    assert(atomic_load(&core.spatial_nonzero_delta) > 0);
    ASStreamDestroy(&core);
}

static void test_spatial_self_test_scheduler_path(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamSpatialConfigure(&core, ASSpatialRouteUniversalStereo, true, .9f, .95f, .5f, .55f, .8f, .08f);
    ASStreamSpatialSetSelfTest(&core, true);
    float left[64], right[64];
    for (size_t i=0;i<16;i++) left[i]=right[i]=.25f;
    ASStreamRender(&core,left,right,16,44100,NAN,NAN);
    uint64_t epoch=atomic_load(&core.epoch);
    ASStreamSpatialEvent event={.event_id=901,.epoch=epoch,.start_sample=24,.end_sample=180,.stem=ASSpatialStemVocal,.motion=ASSpatialMotionArc,.priority=.95f,.intensity=.9f,.direction=1,.attack_seconds=.01f,.release_seconds=.02f,.tail_seconds=.01f};
    assert(ASStreamSpatialSchedule(&core,&event));
    bool changed=false;
    for (size_t block=0; block<12; block++) {
        for (size_t i=0;i<64;i++) left[i]=right[i]=.25f;
        ASStreamRender(&core,left,right,64,44100,NAN,NAN);
        for (size_t i=0;i<64;i++) if (fabsf(left[i]-.25f)>1e-5f || fabsf(right[i]-.25f)>1e-5f) changed=true;
    }
    assert(changed);
    assert(atomic_load(&core.spatial.scheduled)==1);
    assert(atomic_load(&core.spatial.activated)==1);
    assert(atomic_load(&core.spatial.rendered_events)==1);
    assert(atomic_load(&core.spatial.mixed_events)==1);
    ASStreamSubmitTerminal(&core, 12 * 64);
    assert(atomic_load(&core.spatial.submitted_events)==1);
    assert(atomic_load(&core.spatial.completed_events)==1);
    assert(atomic_load(&core.spatial_applied)>0);
    ASStreamDestroy(&core);
}

static void test_output_self_test_path(void) {
    ASStreamCore core;
    assert(ASStreamInit(&core));
    ASStreamSpatialConfigure(&core, ASSpatialRouteUniversalStereo, true, .8f, .9f, .4f, .7f, .8f, .08f);
    ASStreamStartOutputSelfTest(&core);
    float left[512], right[512];
    const size_t total=(size_t)llround(8.5*44100.0);
    size_t rendered=0; bool changed=false;
    while (rendered<total) {
        size_t n=total-rendered>512?512:total-rendered;
        for(size_t i=0;i<n;i++) { left[i]=.25f; right[i]=.12f; }
        ASStreamRender(&core,left,right,(uint32_t)n,44100,NAN,NAN);
        for(size_t i=0;i<n;i++) if(fabsf(left[i]-.25f)>1e-5f || fabsf(right[i]-.12f)>1e-5f) changed=true;
        ASStreamSubmitTerminal(&core,(uint32_t)n);
        rendered+=n;
    }
    assert(changed);
    assert(atomic_load(&core.test.phase)==4);
    assert(atomic_load(&core.test.changed[0])>0);
    for(unsigned route=0;route<4;route++) assert(atomic_load(&core.test.renderer_frames[route])>0);
    assert(atomic_load(&core.test.scheduled)>0);
    assert(atomic_load(&core.spatial.rendered_events)>0);
    assert(atomic_load(&core.spatial.mixed_events)>0);
    assert(atomic_load(&core.spatial.submitted_events)>0);
    assert(atomic_load(&core.test.terminal_frames)==total);
    ASStreamDestroy(&core);
}

int main(void) {
    test_blend_and_resample();
    test_output_ring();
    test_mode_transition_and_synchronised_fallback();
    test_synchronised_stem_frame();
    test_reset_discards_previous_epoch_output();
    test_timestamp_discontinuity_starts_new_epoch();
    test_bounded_input_overflow();
    test_spatial_event_is_future_stem_delta();
    test_live_base_scene_changes_stem_mix_without_event();
    test_spatial_self_test_scheduler_path();
    test_output_self_test_path();
    puts("AISpatialStreamCoreTests: ok");
    return 0;
}
