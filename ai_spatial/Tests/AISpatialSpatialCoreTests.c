#include "AISpatialScene.h"
#include "AISpatialRenderers.h"
#include "AISpatialEventTiming.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void scene_test(void) {
    ASSpatialScene scene;
    ASSpatialSceneInit(&scene, 48000);
    uint64_t id;
    assert(!ASSpatialSceneAddSource(&scene, ASSpatialStemVocal, (ASSpatialPosition){NAN, 0, 0}, 1, .3f, 1, &id));
    assert(ASSpatialSceneAddSource(&scene, ASSpatialStemVocal, (ASSpatialPosition){0, -1, 0}, 1, .3f, 1, &id));
    assert(id == 1 && scene.source_count == 1);
    for (unsigned type = 0; type <= ASSpatialMotionReflection; type++) {
        ASSpatialEventPlan event = {.event_id=7, .stream_epoch=4, .start_sample=48000, .end_sample=50400,
            .stem=ASSpatialStemVocal, .priority=.8f, .intensity=.75f, .selected=true,
            .motion={(ASSpatialMotionType)type, 1, 1, .18f, .3f}};
        ASSpatialEventPlan planned;
        assert(ASSpatialScenePlanEvent(&scene, &event, &planned));
        assert(planned.end_sample > planned.start_sample);
        assert((double)(planned.end_sample - event.end_sample) / 48000 <= .4501);
        double duration = planned.motion.duration_seconds;
        ASSpatialPosition prev = ASSpatialMotionPosition(&scene.sources[0], &planned.motion, 0);
        for (unsigned i=1; i<=1000; i++) {
            ASSpatialPosition next = ASSpatialMotionPosition(&scene.sources[0], &planned.motion, duration*i/1000);
            assert(isfinite(next.x) && fabsf(next.x)<=1 && fabsf(next.y)<=1 && fabsf(next.z)<=1);
            assert(fabsf(next.x-prev.x)<.02f && fabsf(next.y-prev.y)<.02f && fabsf(next.z-prev.z)<.02f);
            prev=next;
        }
        assert(fabsf(prev.x-scene.sources[0].position.x)<1e-6f);
    }
    assert(ASSpatialEnvelope(-1, .2f, .02f, 1)==0);
    assert(ASSpatialEnvelope(0, .2f, .02f, 1)==0);
    assert(ASSpatialEnvelope(.1, .2f, .02f, 1)==1);
    assert(ASSpatialEnvelope(.2f, .2f, .02f, 1)==0);
    assert(ASSpatialEnvelope(NAN, .2f, .02f, 1)==0);
    assert(ASSpatialEnvelope(.1, .2f, .02f, 0)==0);
}
static void clocks_test(void) {
    double ms = -1;
    assert(ASEventElapsedMS(1000,1000.25,&ms) && ms==250);
    assert(!ASEventElapsedMS(1000,999,&ms));
    assert(!ASEventElapsedMS(NAN,999,&ms));
    assert(ASEventSampleDeltaMS(100,200,1000)==-100);
    assert(ASEventReadyDeadline(0,2750,100)==2650);
    assert(ASEventReadyDeadline(UINT64_MAX-10,100,5)==UINT64_MAX-5);
}
static void renderer_test(void) {
    float l=0,r=0; ASSpatialRenderConfig cfg;
    ASSpatialRenderConfigDefault(&cfg, ASSpatialRouteMonoSafe);
    ASSpatialRenderStereo(&cfg,(ASSpatialPosition){.8f,0,0},.4f,-.2f,1,&l,&r);
    assert(fabsf(l-r) < .25f); /* mono-safe remains correlated */
    cfg.route=ASSpatialRouteSpeakers; cfg.intensity=0;
    ASSpatialRenderStereo(&cfg,(ASSpatialPosition){1,0,0},.4f,-.2f,1,&l,&r);
    assert(l==.4f && r==-.2f); /* zero intensity is exact identity */
    ASSpatialHRTFState h; ASSpatialHRTFReset(&h);
    ASSpatialHRTFProcess(&h,.4f,.4f,.8f,.5f,1,&l,&r);
    assert(isfinite(l) && isfinite(r) && fabsf(l)<=1 && fabsf(r)<=1);
}
static void scheduler_test(double rate) {
    ASEventGate g; ASEventGateInit(&g); ASEventGateSetEpoch(&g,2);
    uint64_t delay=(uint64_t)llround(2.75*rate), safety=(uint64_t)llround(.1*rate);
    ASEventKey key={2,1,100000,101000,0};
    uint64_t deadline=ASEventReadyDeadline(key.start,delay,safety);
    assert(ASEventGateSelect(&g,key,2,false,deadline,0,delay,safety,100,10,0)==AS_EVENT_ACCEPT);
    assert(ASEventGateSelect(&g,key,2,false,deadline,0,delay,safety,101,10,0)==AS_EVENT_DUPLICATE);
    key.start+=5000; key.end+=5000;
    deadline=ASEventReadyDeadline(key.start,delay,safety);
    assert(ASEventGateSelect(&g,key,2,false,deadline+1,0,delay,safety,102,10,0)==AS_EVENT_LATE);
    key.start+=5000; key.end+=5000;
    assert(ASEventGateSelect(&g,key,2,false,0,key.start+1,delay,safety,103,10,0)==AS_EVENT_LATE);
    key.start+=5000; key.end+=5000;
    assert(ASEventGateSelect(&g,key,3,false,0,0,delay,safety,104,10,0)==AS_EVENT_STALE_EPOCH);
    assert(ASEventGateSelect(&g,key,2,true,0,0,delay,safety,104,10,0)==AS_EVENT_STALE_EPOCH);
    ASEventGateSetEpoch(&g,3);
    assert(ASEventGateSelect(&g,key,3,false,0,0,delay,safety,104,10,0)==AS_EVENT_STALE_EPOCH);
    key.epoch=3;
    assert(ASEventGateSelect(&g,key,3,false,0,0,delay,safety,104,10,0)==AS_EVENT_ACCEPT);
}
static void rolling_density_test(void) {
    ASEventGate g; ASEventGateInit(&g); ASEventGateSetEpoch(&g,1);
    unsigned selected=0;
    for (unsigned i=0;i<20;i++) {
        // Twenty candidates from both stems in 12 seconds: total <= ten.
        ASEventKey key={1,i,i*1000,i*1000+100,i%2};
        ASEventDecision d=ASEventGateSelect(&g,key,1,false,0,0,100000,0,100+i*.6,10,0);
        selected+=d==AS_EVENT_ACCEPT;
        if (i>=10) assert(d==AS_EVENT_DENSITY);
    }
    assert(selected==10);
    // Route changes must not replenish the session's rolling budget.
    ASEventGateSetEpoch(&g,2);
    ASEventKey key={2,1,30000,30100,0};
    assert(ASEventGateSelect(&g,key,2,false,0,0,100000,0,159.999,10,0)==AS_EVENT_DENSITY);
    key.start++; key.end++;
    assert(ASEventGateSelect(&g,key,2,false,0,0,100000,0,160,10,0)==AS_EVENT_ACCEPT);
    key.start++; key.end++;
    assert(ASEventGateSelect(&g,key,2,false,0,0,100000,0,160.1,10,0)==AS_EVENT_DENSITY);
}
int main(void) {
    scene_test(); clocks_test(); renderer_test(); scheduler_test(44100); scheduler_test(48000); rolling_density_test();
    puts("AISpatialSpatialCoreTests: OK (scene, smooth motion, envelopes, clocks, deadlines, epoch, duplicates, rolling density)");
}
