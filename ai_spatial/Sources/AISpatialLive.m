#import "AISpatialSeparator.h"
#import "AISpatialSpectral.h"
#import "AISpatialStreamCore.h"
#import "AISpatialModelStore.h"
#import "AISpatialDiagnostics.h"
#import "AISpatialLog.h"
#import "AISpatialAccentDetector.h"
#import "AISpatialAccentCore.h"
#import "AISpatialConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <math.h>

static ASStreamCore *gCore;
static _Atomic(uint64_t) gLastCallbackTicks;
static _Atomic(uint64_t) gStreamingCallbackBlocks;
static _Atomic(uint64_t) gStreamingCallbackFrames;
static _Atomic(uint64_t) gDuplicateCallbackBlocks;
static _Atomic(uint64_t) gSpatialScheduled;
static _Atomic(uint64_t) gLastCallbackSampleBits;
static _Atomic(uint64_t) gLastCallbackHostBits;
static _Atomic(uint64_t) gLastCallbackRateBits;
static _Atomic(uint32_t) gLastCallbackFrames;
static mach_timebase_info_data_t gTimebase;
static const NSUInteger ASModelWindow = 88200, ASModelStep = 66150, ASModelOverlap = 22050;
static const NSUInteger ASMaxRouteWindow = 96000;
static NSString *ASModeName(int mode) { return @[@"Original", @"AI Shadow", @"AI Live", @"Vocals Only (test)", @"Instrumental Only (test)"][MIN(MAX(mode, 0), 4)]; }
static NSString *ASRouteName(int route) { return @[@"Headphones binaural", @"Speakers", @"Universal Stereo", @"Mono / Safe Fallback"][MIN(MAX(route,0),3)]; }
static NSString *ASProfileName(NSInteger profile) { return @[@"Headphones", @"Speakers", @"Universal", @"Bluetooth", @"AirPlay", @"Universal Safe"][MIN(MAX(profile,0),5)]; }
typedef NS_ENUM(int, ASSpatialSelfTestPhase) {
    ASSpatialSelfTestIdle = 0,
    ASSpatialSelfTestOutputPath = 1,
    ASSpatialSelfTestRenderer = 2,
    ASSpatialSelfTestEventIntegration = 3,
    ASSpatialSelfTestComplete = 4,
};
static _Atomic(int) gSelfTestPhase;
static _Atomic(uint64_t) gSelfTestPhaseFrames;
static _Atomic(uint64_t) gSelfTestTotalFrames;
static _Atomic(uint64_t) gSelfTestChangedFrames;
static _Atomic(uint64_t) gSelfTestChangedSquare;
static _Atomic(uint32_t) gSelfTestChangedPeakBits;
static _Atomic(uint64_t) gSelfTestRendererFrames[4];
static _Atomic(uint64_t) gSelfTestEventsScheduled;
static _Atomic(uint64_t) gSelfTestPreviousMode;
static _Atomic(bool) gSelfTestPreviousAccent;
static _Atomic(uint64_t) gSelfTestNextEventSample;
static _Atomic(uint64_t) gSelfTestEventID;
static _Atomic(uint64_t) gTerminalFrames;
static _Atomic(bool) gSelfTestTerminationPending;
static _Atomic(uint64_t) gSelfTestP1ChangedFrames, gSelfTestP2ChangedFrames;
static _Atomic(uint32_t) gSelfTestCaptureFrames, gSelfTestCapturePhase;
static float gSelfTestP0Left[4096], gSelfTestP0Right[4096], gSelfTestP1Left[4096], gSelfTestP1Right[4096];
static float gSelfTestBeforeLeft[4096], gSelfTestBeforeRight[4096];

static void ASStoreFloatBits(_Atomic(uint32_t) *slot, float value) { uint32_t bits; memcpy(&bits, &value, sizeof(bits)); atomic_store_explicit(slot, bits, memory_order_relaxed); }
static float ASLoadFloatBits(_Atomic(uint32_t) *slot) { uint32_t bits=atomic_load_explicit(slot,memory_order_relaxed); float value; memcpy(&value,&bits,sizeof(value)); return value; }
static const char *ASSelfTestPhaseName(int phase) {
    switch (phase) { case ASSpatialSelfTestOutputPath: return "Output Path Test"; case ASSpatialSelfTestRenderer: return "Renderer Test"; case ASSpatialSelfTestEventIntegration: return "Event Integration Test"; case ASSpatialSelfTestComplete: return "Complete"; default: return "Idle"; }
}
static ASSpatialRoute ASConfiguredRoute(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:ASConfigRouteAuto]) {
        AVAudioSessionRouteDescription *route=AVAudioSession.sharedInstance.currentRoute;
        AVAudioSessionPortDescription *port=route.outputs.firstObject;
        NSString *uid=port.UID.length ? [port.UID stringByReplacingOccurrencesOfString:@"/" withString:@"_"] : nil;
        NSString *profileKey=uid.length ? [NSString stringWithFormat:@"spotifyglass.ai-spatial.device.%@.route",uid] : nil;
        NSNumber *remembered=profileKey ? [NSUserDefaults.standardUserDefaults objectForKey:profileKey] : nil;
        if (remembered && remembered.integerValue >= ASSpatialRouteHeadphones && remembered.integerValue <= ASSpatialRouteMonoSafe) return (ASSpatialRoute)remembered.integerValue;
        NSString *type=port.portType;
        ASSpatialRoute detected=ASSpatialRouteMonoSafe;
        if ([type isEqualToString:AVAudioSessionPortHeadphones]) detected=ASSpatialRouteHeadphones;
        else if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker] || [type isEqualToString:AVAudioSessionPortAirPlay] || [type isEqualToString:AVAudioSessionPortHDMI] || [type isEqualToString:AVAudioSessionPortLineOut] || [type isEqualToString:AVAudioSessionPortUSBAudio]) detected=ASSpatialRouteSpeakers;
        if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] || [type isEqualToString:AVAudioSessionPortBluetoothHFP] || [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            NSString *name=port.portName.lowercaseString;
            detected=([name containsString:@"airpods"] || [name containsString:@"beats"] || [name containsString:@"buds"]) ? ASSpatialRouteHeadphones : ASSpatialRouteUniversalStereo;
        }
        if (profileKey) [NSUserDefaults.standardUserDefaults setInteger:detected forKey:profileKey];
        return detected;
    }
    NSInteger route=[NSUserDefaults.standardUserDefaults integerForKey:ASConfigRoute];
    return route>=0 && route<=ASSpatialRouteMonoSafe ? (ASSpatialRoute)route : ASSpatialRouteUniversalStereo;
}
static void ASConfigureSpatial(ASStreamCore *core, BOOL enabled) {
    if (!core) return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    /* The selected playback mode is the authoritative enable gate. Older UI
     * paths wrote the legacy key only, which otherwise left Live silently
     * disabled even while the switch looked enabled. Original/Shadow call
     * this with `enabled == NO`, so they remain unchanged. */
    bool spatialEnabled = AS_SPATIAL_BUILD_PHASE >= 5 && enabled;
    ASStreamSpatialConfigure(core, ASConfiguredRoute(), spatialEnabled,
        [d doubleForKey:ASConfigIntensity], [d doubleForKey:ASConfigWidth], [d doubleForKey:ASConfigDepth],
        [d doubleForKey:ASConfigCenterProtection], [d doubleForKey:ASConfigBassProtection], [d doubleForKey:ASConfigAntiPhaseLimit]);
    ASStreamSpatialSetComponents(core,
        [d boolForKey:ASConfigAccentMotion], [d boolForKey:ASConfigStereoWidthEnabled],
        [d boolForKey:ASConfigDepthEnabled], [d boolForKey:ASConfigReflectionsEnabled],
        [d boolForKey:ASConfigHRTFEnabled]);
    ASStreamSpatialSetMaxActive(core, (unsigned)[d integerForKey:ASConfigMaxActiveSources]);
}
static double ASTicksSeconds(uint64_t ticks) { return (double)ticks * gTimebase.numer / gTimebase.denom / 1e9; }
static BOOL ASIsDuplicateCallback(UInt32 frames, double rate, const AudioTimeStamp *ts) {
    if (!ts || !(ts->mFlags & kAudioTimeStampSampleTimeValid) || !(ts->mFlags & kAudioTimeStampHostTimeValid) || !isfinite(ts->mSampleTime) || !ts->mHostTime) return NO;
    uint64_t sampleBits = 0, hostBits = 0, rateBits = 0;
    memcpy(&sampleBits, &ts->mSampleTime, sizeof(sampleBits));
    hostBits = ts->mHostTime;
    memcpy(&rateBits, &rate, sizeof(rateBits));
    uint64_t oldSample = atomic_load_explicit(&gLastCallbackSampleBits, memory_order_acquire);
    uint64_t oldHost = atomic_load_explicit(&gLastCallbackHostBits, memory_order_acquire);
    uint64_t oldRate = atomic_load_explicit(&gLastCallbackRateBits, memory_order_acquire);
    uint32_t oldFrames = atomic_load_explicit(&gLastCallbackFrames, memory_order_acquire);
    if (oldSample == sampleBits && oldHost == hostBits && oldRate == rateBits && oldFrames == frames) return YES;
    atomic_store_explicit(&gLastCallbackHostBits, hostBits, memory_order_release);
    atomic_store_explicit(&gLastCallbackRateBits, rateBits, memory_order_release);
    atomic_store_explicit(&gLastCallbackFrames, frames, memory_order_release);
    atomic_store_explicit(&gLastCallbackSampleBits, sampleBits, memory_order_release);
    return NO;
}

@interface AISpatialLivePipeline : NSObject
- (NSDictionary *)snapshot;
- (void)announceMetadata;
@end
@implementation AISpatialLivePipeline {
    dispatch_queue_t _worker;
    dispatch_source_t _workerTimer, _diagnosticTimer;
    FFTSetup _fft;
    float *_hann, *_routeL, *_routeR, *_modelL, *_modelR, *_vocalL, *_vocalR;
    float *_routeVocalL, *_routeVocalR, *_overlapL, *_overlapR, *_overlapWeight;
    ASStreamOutput *_stepOutput;
    uint64_t _epoch, _start, _expected;
    NSUInteger _fill, _routeWindow, _step, _overlap;
    double _rate;
    BOOL _previous, _announced;
    _Atomic(uint64_t) _processed, _skipped, _submitted, _cancelled, _formed;
    _Atomic(int) _processing;
    NSMutableArray<NSDictionary *> *_recent;
    NSDictionary *_lastWindow;
    double _trackPosition, _trackRate, _trackObserved;
    BOOL _trackPositionAvailable;
    NSString *_trackKey;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    ASStreamCore *core = calloc(1, sizeof(*core));
    if (!core || !ASStreamInit(core)) { free(core); return nil; }
    _routeL = calloc(ASMaxRouteWindow, sizeof(float)); _routeR = calloc(ASMaxRouteWindow, sizeof(float));
    _modelL = calloc(ASModelWindow, sizeof(float)); _modelR = calloc(ASModelWindow, sizeof(float));
    _vocalL = calloc(ASModelWindow, sizeof(float)); _vocalR = calloc(ASModelWindow, sizeof(float));
    _routeVocalL = calloc(ASMaxRouteWindow, sizeof(float)); _routeVocalR = calloc(ASMaxRouteWindow, sizeof(float));
    _overlapL = calloc(ASMaxRouteWindow / 4, sizeof(float)); _overlapR = calloc(ASMaxRouteWindow / 4, sizeof(float));
    _overlapWeight = calloc(ASMaxRouteWindow / 4, sizeof(float)); _stepOutput = calloc(ASMaxRouteWindow, sizeof(ASStreamOutput));
    _hann = calloc(2048, sizeof(float)); _fft = vDSP_create_fftsetup(11, kFFTRadix2);
    if (!_routeL || !_routeR || !_modelL || !_modelR || !_vocalL || !_vocalR || !_routeVocalL || !_routeVocalR || !_overlapL || !_overlapR || !_overlapWeight || !_stepOutput || !_hann || !_fft) {
        // Initial allocation failure leaves Original playback intact; no hook calls into a partial core.
        ASStreamDestroy(core); free(core);
        free(_routeL); free(_routeR); free(_modelL); free(_modelR); free(_vocalL); free(_vocalR);
        free(_routeVocalL); free(_routeVocalR); free(_overlapL); free(_overlapR); free(_overlapWeight); free(_stepOutput); free(_hann);
        if (_fft) vDSP_destroy_fftsetup(_fft);
        return nil;
    }
    gCore = core;
    ASAccentDetectorAttachStream(core);
    atomic_init(&gLastCallbackTicks, 0);
    atomic_init(&gStreamingCallbackBlocks, 0); atomic_init(&gStreamingCallbackFrames, 0); atomic_init(&gDuplicateCallbackBlocks, 0);
    atomic_init(&gSpatialScheduled, 0);
    atomic_init(&gLastCallbackSampleBits, 0); atomic_init(&gLastCallbackHostBits, 0); atomic_init(&gLastCallbackRateBits, 0); atomic_init(&gLastCallbackFrames, 0);
    atomic_init(&_processed, 0); atomic_init(&_skipped, 0); atomic_init(&_submitted, 0); atomic_init(&_cancelled, 0); atomic_init(&_formed, 0); atomic_init(&_processing, 0);
    atomic_init(&gSelfTestPhase, ASSpatialSelfTestIdle); atomic_init(&gSelfTestPhaseFrames, 0); atomic_init(&gSelfTestTotalFrames, 0);
    atomic_init(&gSelfTestChangedFrames, 0); atomic_init(&gSelfTestChangedSquare, 0); atomic_init(&gSelfTestChangedPeakBits, 0);
    for (unsigned i=0;i<4;i++) atomic_init(&gSelfTestRendererFrames[i],0);
    atomic_init(&gSelfTestEventsScheduled,0); atomic_init(&gSelfTestPreviousMode,0); atomic_init(&gSelfTestPreviousAccent,false);
    atomic_init(&gSelfTestNextEventSample,0); atomic_init(&gSelfTestEventID,0); atomic_init(&gTerminalFrames,0);
    atomic_init(&gSelfTestTerminationPending,false);
    atomic_init(&gSelfTestP1ChangedFrames,0); atomic_init(&gSelfTestP2ChangedFrames,0);
    atomic_init(&gSelfTestCaptureFrames,0); atomic_init(&gSelfTestCapturePhase,0);
    for (NSUInteger n = 0; n < 2048; n++) _hann[n] = .5f - .5f * cosf((float)(2 * M_PI * n / 2048));
    _recent = [NSMutableArray array];
    ASConfigMigrateAndRegister();
    NSInteger persistedMode = [NSUserDefaults.standardUserDefaults integerForKey:ASConfigBackendMode];
    /* croma keeps Diagnostic as a user-facing mode; the audio backend uses
       Shadow so diagnostics never make PCM audible. */
    // Model verification is asynchronous during process launch.  Do not
    // restore an AI mode before the verified model is available; this avoids a
    // silent 2.75 s preroll after a restart and requires an explicit selection
    // once the UI reports the model ready.
    if (persistedMode != AISpatialLiveModeOriginal && !AISpatialModelStore.sharedStore.modelIsReady) {
        persistedMode = AISpatialLiveModeOriginal;
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:ASConfigEngineEnabled];
    }
    ASStreamRequestMode(core, (int)persistedMode);
    ASConfigureSpatial(core, persistedMode == AISpatialLiveModeLive);
    _worker = dispatch_queue_create("pw.chroma.ai-spatial.stream-worker", DISPATCH_QUEUE_SERIAL);
    _workerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _worker);
    dispatch_source_set_timer(_workerTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_workerTimer, ^{ @autoreleasepool { [self drainInput]; } });
    dispatch_resume(_workerTimer);
    dispatch_queue_t diagnosticsQueue = dispatch_queue_create("pw.chroma.ai-spatial.stream-metrics", DISPATCH_QUEUE_SERIAL);
    _diagnosticTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, diagnosticsQueue);
    dispatch_source_set_timer(_diagnosticTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_diagnosticTimer, ^{ @autoreleasepool { [self observePlaybackBoundary]; [self drainTelemetry]; } });
    dispatch_resume(_diagnosticTimer);
    for (NSNotificationName name in @[AVAudioSessionRouteChangeNotification, AVAudioSessionInterruptionNotification, AVAudioSessionMediaServicesWereResetNotification, AVAudioSessionMediaServicesWereLostNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            ASStreamRequestReset(core);
            ASAccentDetectorReset();
            ASConfigureSpatial(core, atomic_load(&core->requested_mode) == AISpatialLiveModeLive);
            [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Stage 02 - Streaming Buffer" event:@"audio_session_boundary" fields:@{@"reason": note.name, @"policy": @"invalidate epoch; discard stale inference; rebuild from new PCM"}];
        }];
    }
    return self;
}
- (void)announceMetadata {
    [AISpatialDiagnostics.sharedDiagnostics updateMetadata:@{@"streaming": @{
        @"stage": @2, @"architecture": @"Spotify PCM -> SPSC ring -> shared Stage 01 STFT/Core ML/ISTFT -> synchronous stems -> mixer -> JamesDSP once",
        @"model_rate_hz": @44100, @"route_rates_hz": @[@44100, @48000], @"window_samples_model": @(ASModelWindow), @"step_samples_model": @(ASModelStep), @"overlap_samples_model": @(ASModelOverlap),
        @"configured_delay_seconds": @(AS_STREAM_DELAY_SECONDS), @"ring_capacity_frames": @(AS_STREAM_CAPACITY), @"max_inflight_predictions": @1,
        @"resampler": @"worker-only 48-tap Hann-windowed sinc, fixed phase; 44.1 kHz passthrough; 48 kHz vocals converted back before source - vocals",
        @"fallback": @"render-owned original history at exactly the output sample index, same epoch, same rate",
        @"mode_transitions": @"20 ms same-position stem gain ramps; immediate/delayed family switches pending until start/stop/seek/track/route boundary",
        @"cpu_gpu_ane_actual": @"unavailable; public Core ML does not expose per-prediction provider counters in this injected process",
        @"absolute_track_position": @"MPNowPlayingInfoCenter elapsed time when provided; extrapolated between observations; audio sample index remains measured",
        @"bridge_fallback": @"if CromaJDSP bridge is absent, the Stage 01 post-render observer feeds float32 non-interleaved stereo into the same AI entry point; timestamp/frame dedupe prevents double processing",
        @"model": AISpatialModelStore.sharedStore.diagnosticMetadata,
        @"spatial_engine_version": @"stage04-b-f-1",
        @"build_phase": @(AS_SPATIAL_BUILD_PHASE),
        @"deterministic_test_mode": @([NSUserDefaults.standardUserDefaults boolForKey:ASConfigDeterministic]),
        @"preset_profile": @([NSUserDefaults.standardUserDefaults integerForKey:ASConfigProfile]),
        @"preset_profile_name": ASProfileName([NSUserDefaults.standardUserDefaults integerForKey:ASConfigProfile]),
        @"actual_renderer_type": gCore ? ASRouteName(atomic_load_explicit(&gCore->spatial.route,memory_order_acquire)) : @"unavailable",
        @"actual_renderer_instance": @{
            @"renderer_enum": gCore ? @(atomic_load_explicit(&gCore->spatial.route,memory_order_acquire)) : @-1,
            @"renderer_name": gCore ? ASRouteName(atomic_load_explicit(&gCore->spatial.route,memory_order_acquire)) : @"unavailable",
            @"frames_processed": gCore ? @(atomic_load(&gCore->renderer_frames[0])+atomic_load(&gCore->renderer_frames[1])+atomic_load(&gCore->renderer_frames[2])+atomic_load(&gCore->renderer_frames[3])) : @0
        },
        @"route_selection_reason": [NSUserDefaults.standardUserDefaults boolForKey:ASConfigRouteAuto] ? @"automatic_output_route_detection; profile is a tuning preset" : @"manual_renderer_route",
        @"renderer_parameters": @{
            @"intensity": @([NSUserDefaults.standardUserDefaults doubleForKey:ASConfigIntensity]),
            @"width": @([NSUserDefaults.standardUserDefaults doubleForKey:ASConfigWidth]),
            @"depth": @([NSUserDefaults.standardUserDefaults doubleForKey:ASConfigDepth]),
            @"accent_density": @([NSUserDefaults.standardUserDefaults doubleForKey:ASConfigAccentRate])
        },
        @"component_status": @{
            @"accent_detector": ASAccentDetectorSnapshot() ?: @{},
            @"spatial_gate": @{@"enabled": gCore ? @(atomic_load(&gCore->spatial.enabled)) : @NO, @"receiving_data": @(gCore && atomic_load(&gStreamingCallbackFrames)>0), @"blocked_reason": (gCore && atomic_load(&gCore->spatial.enabled)) ? [NSNull null] : @"spatial_gate_disabled"},
            @"event_scheduler": @{@"enabled": gCore ? @(atomic_load(&gCore->spatial.enabled)) : @NO, @"receiving_data": @(gCore && atomic_load(&gCore->spatial.scheduled)>0), @"blocked_reason": (gCore && atomic_load(&gCore->spatial.scheduled)>0) ? [NSNull null] : @"no_events_scheduled"},
            @"renderer": @{@"enabled": gCore ? @YES : @NO, @"receiving_data": gCore ? @(atomic_load(&gCore->renderer_frames[0])+atomic_load(&gCore->renderer_frames[1])+atomic_load(&gCore->renderer_frames[2])+atomic_load(&gCore->renderer_frames[3])>0) : @NO}
        },
        @"jamesdsp_version": @"existing bridge; runtime engine reports settings through JamesDSP status"
    }}];
}
- (void)resetWorkerFor:(ASStreamInput)frame rate:(double)rate {
    _epoch = frame.epoch; _start = frame.sample; _expected = frame.sample; _fill = 0; _previous = NO; _rate = rate;
    // Keep the route buffers within their fixed allocation even when an
    // audio route reports a small clock-rate offset (for example 48000.4 Hz).
    _routeWindow = MIN(ASMaxRouteWindow, MAX((NSUInteger)1, (NSUInteger)llround(rate * 2)));
    _step = _routeWindow * 3 / 4; _overlap = _routeWindow - _step;
    memset(_overlapL, 0, ASMaxRouteWindow / 4 * sizeof(float)); memset(_overlapR, 0, ASMaxRouteWindow / 4 * sizeof(float)); memset(_overlapWeight, 0, ASMaxRouteWindow / 4 * sizeof(float));
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Stage 03 - Windowing and Buffering" event:@"epoch_reset" fields:@{@"stream_epoch": @(_epoch), @"start_sample": @(_start), @"sample_rate": @(rate), @"reason": @"boundary or missing input sample; no cross-epoch output"}];
}
- (void)drainInput {
    ASStreamInput f; NSUInteger drained = 0;
    while (drained++ < AS_STREAM_CAPACITY && ASStreamPopInput(gCore, &f)) {
        uint64_t epoch = atomic_load_explicit(&gCore->epoch, memory_order_acquire);
        if (f.epoch != epoch) continue;
        uint64_t bits = atomic_load(&gCore->rate_bits); double rate; memcpy(&rate, &bits, sizeof(rate));
        if (fabs(rate - 44100) > .5 && fabs(rate - 48000) > .5) continue;
        if (f.epoch != _epoch || f.sample != _expected) [self resetWorkerFor:f rate:rate];
        _routeL[_fill] = f.l; _routeR[_fill] = f.r; _fill++; _expected = f.sample + 1;
        if (_fill == _routeWindow) {
            [self processWindow];
            memmove(_routeL, _routeL + _step, _overlap * sizeof(float)); memmove(_routeR, _routeR + _step, _overlap * sizeof(float));
            _fill = _overlap; _start += _step;
        }
    }
}
- (void)processWindow {
    uint64_t epoch = _epoch, start = _start;
    NSUInteger windowID = (NSUInteger)atomic_fetch_add(&_formed, 1);
    AISpatialDiagnostics *d = AISpatialDiagnostics.sharedDiagnostics;
    double began = AISpatialMonotonicSeconds();
    uint64_t cursor = atomic_load(&gCore->input_cursor), outputCursor = atomic_load(&gCore->output_cursor);
    if (atomic_load(&gCore->active_mode) >= 2 && start + _step <= outputCursor) {
        atomic_fetch_add(&_skipped, 1); _previous = NO;
        [d recordWindow:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"start_sample": @(start), @"end_sample": @(start + _routeWindow), @"status": @"skipped_deadline", @"reason": @"all output samples already played using synchronized original fallback"} processed:NO]; return;
    }
    if (!AISpatialModelStore.sharedStore.modelIsReady) { atomic_fetch_add(&_skipped, 1); _previous = NO; return; }
    atomic_store(&_processing, 1);
    ASStreamResample(_routeL, _routeWindow, _rate, _modelL, ASModelWindow, 44100);
    ASStreamResample(_routeR, _routeWindow, _rate, _modelR, ASModelWindow, 44100);
    NSDictionary *inputL = AISpatialFloatStatistics(_modelL, ASModelWindow), *inputR = AISpatialFloatStatistics(_modelR, ASModelWindow);
    [d recordStage:@"Stage 02 - Input Preparation" event:@"stream_window_prepared" fields:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"start_sample": @(start), @"route_sample_rate": @(_rate), @"model_sample_rate": @44100, @"input_frames": @(_routeWindow), @"output_frames": @(ASModelWindow), @"gain": @1, @"normalization": @"none", @"left": inputL, @"right": inputR}];
    [d recordStage:@"Stage 03 - Windowing and Buffering" event:@"stream_window_started" fields:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"start_sample": @(start), @"end_sample": @(start + _routeWindow), @"window_samples": @(_routeWindow), @"step_samples": @(_step), @"overlap_samples": @(_overlap), @"input_buffer_frames": @(cursor > start ? cursor - start : 0)}];
    NSError *error = nil;
    MLMultiArray *spectrum = [[MLMultiArray alloc] initWithShape:@[@1, @2050, @201, @2] dataType:MLMultiArrayDataTypeFloat32 error:&error];
    BOOL validInput = ![inputL[@"nan_count"] unsignedIntegerValue] && ![inputR[@"nan_count"] unsignedIntegerValue] && ![inputL[@"infinity_count"] unsignedIntegerValue] && ![inputR[@"infinity_count"] unsignedIntegerValue];
    __block MLMultiArray *output = nil; __block NSError *predictionError = nil;
    double preparationEnd = began, inferenceWait = 0, reconstructionStart = 0;
    NSDictionary *metrics = @{};
    if (spectrum && validInput) {
        memset(spectrum.dataPointer, 0, spectrum.count * sizeof(float));
        AISpatialFillSpectrum(spectrum, _modelL, _modelR, 0, ASModelWindow); AISpatialFillSpectrum(spectrum, _modelL, _modelR, 1, ASModelWindow);
        [d recordStage:@"Stage 04 - STFT / Spectral Preparation" event:@"stream_spectrum" fields:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"fft_size": @2048, @"hop_length": @441, @"window_type": @"periodic Hann; centered reflected; Stage 01 shared code", @"normalization": @"unchanged Stage 01 packed real FFT convention", @"tensor": AISpatialTensorStatistics(spectrum)}];
        preparationEnd = AISpatialMonotonicSeconds();
        dispatch_semaphore_t signal = dispatch_semaphore_create(0);
        atomic_fetch_add(&_submitted, 1);
        [AISpatialModelStore.sharedStore predictStreamingSpectrum:spectrum windowID:windowID completion:^(MLMultiArray *o, NSError *e) { output = o; predictionError = e; dispatch_semaphore_signal(signal); }];
        // Only this serial worker waits. Core ML is not cancellable; at most one
        // request exists, and its result is rejected after any epoch change.
        dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
        inferenceWait = AISpatialMonotonicSeconds() - preparationEnd;
        metrics = AISpatialModelStore.sharedStore.lastInferenceMetrics;
    }
    if (epoch != atomic_load_explicit(&gCore->epoch, memory_order_acquire)) {
        atomic_fetch_add(&_cancelled, 1); atomic_store(&_processing, 0); _previous = NO;
        [d recordWindow:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"start_sample": @(start), @"status": @"cancelled_stale_epoch", @"inference_wait_ms": @(inferenceWait * 1000)} processed:NO]; return;
    }
    reconstructionStart = AISpatialMonotonicSeconds();
    BOOL okay = output && !predictionError && validInput;
    memset(_vocalL, 0, ASModelWindow * sizeof(float)); memset(_vocalR, 0, ASModelWindow * sizeof(float));
    if (okay) {
        AISpatialInverseWindow(output, 0, _vocalL, ASModelWindow, _fft, _hann); AISpatialInverseWindow(output, 1, _vocalR, ASModelWindow, _fft, _hann);
        ASStreamResample(_vocalL, ASModelWindow, 44100, _routeVocalL, _routeWindow, _rate); ASStreamResample(_vocalR, ASModelWindow, 44100, _routeVocalR, _routeWindow, _rate);
        for (NSUInteger i = 0; i < _routeWindow; i++) if (!isfinite(_routeVocalL[i]) || !isfinite(_routeVocalR[i])) { okay = NO; break; }
    }
    if (!okay) { atomic_fetch_add(&_skipped, 1); _previous = NO; }
    else {
        double inSquare = 0, vocalSquare = 0, instrumentalSquare = 0, errorSquare = 0;
        double inPeak = 0, vPeak = 0, iPeak = 0, mixPeak = 0;
        NSUInteger aboveOne = 0;
        for (NSUInteger i = 0; i < _step; i++) {
            float w = ASStreamBlend(i, _routeWindow, _overlap, _previous);
            float vl = _routeVocalL[i] * w, vr = _routeVocalR[i] * w;
            if (_previous && i < _overlap) { vl += _overlapL[i]; vr += _overlapR[i]; w += _overlapWeight[i]; }
            vl /= w; vr /= w;
            float il = _routeL[i] - vl, ir = _routeR[i] - vr, ml = vl + il, mr = vr + ir;
            _stepOutput[i] = (ASStreamOutput){epoch, windowID, start + i, vl, vr, il, ir};
            inSquare += (double)_routeL[i] * _routeL[i] + (double)_routeR[i] * _routeR[i];
            vocalSquare += (double)vl * vl + (double)vr * vr; instrumentalSquare += (double)il * il + (double)ir * ir;
            double el = ml - _routeL[i], er = mr - _routeR[i]; errorSquare += el * el + er * er;
            inPeak = fmax(inPeak, fmax(fabs(_routeL[i]), fabs(_routeR[i]))); vPeak = fmax(vPeak, fmax(fabs(vl), fabs(vr))); iPeak = fmax(iPeak, fmax(fabs(il), fabs(ir))); mixPeak = fmax(mixPeak, fmax(fabs(ml), fabs(mr)));
            aboveOne += fabs(vl) > 1; aboveOne += fabs(vr) > 1; aboveOne += fabs(il) > 1; aboveOne += fabs(ir) > 1;
        }
        for (NSUInteger i = 0; i < _overlap; i++) {
            float w = ASStreamBlend(_step + i, _routeWindow, _overlap, _previous);
            _overlapL[i] = _routeVocalL[_step + i] * w; _overlapR[i] = _routeVocalR[_step + i] * w; _overlapWeight[i] = w;
        }
        _previous = YES;
        BOOL pushed = atomic_load(&gCore->active_mode) == 1 || ASStreamPushOutput(gCore, _stepOutput, _step);
        uint64_t inputNow = atomic_load(&gCore->input_cursor);
        // Accent analysis consumes the exact synchronized post-ISTFT stems on
        // the existing worker path. It only creates an event schedule; it
        // never writes to the render buffers and never changes JamesDSP.
        ASAccentDetectorSubmit(epoch, windowID, start, _rate, _stepOutput, _step, inputNow);
        atomic_fetch_add(&_processed, 1);
        double done = AISpatialMonotonicSeconds(), divisor = 2 * _step;
        NSDictionary *report = @{
            @"stream_epoch": @(epoch), @"window_id": @(windowID), @"start_sample": @(start), @"end_sample": @(start + _routeWindow), @"output_end_sample": @(start + _step), @"sample_rate": @(_rate),
            @"input_rms": @(sqrt(inSquare / divisor)), @"input_peak": @(inPeak), @"vocal_rms": @(sqrt(vocalSquare / divisor)), @"vocal_peak": @(vPeak), @"instrumental_rms": @(sqrt(instrumentalSquare / divisor)), @"instrumental_peak": @(iPeak), @"mix_peak": @(mixPeak), @"reconstruction_error_rms": @(sqrt(errorSquare / divisor)), @"above_one": @(aboveOne),
            @"accumulation_seconds": @2, @"stream_queue_wait_ms": @(fmax(0, (double)(cursor >= start + _routeWindow ? cursor - start - _routeWindow : 0) / _rate * 1000)), @"preparation_ms": @((preparationEnd - began) * 1000),
            @"queue_wait_ms": metrics[@"queue_wait_ms"] ?: @"unavailable", @"inference_ms": metrics[@"inference_ms"] ?: @"unavailable", @"completion_wait_ms": @(inferenceWait * 1000), @"reconstruction_ms": @((done - reconstructionStart) * 1000), @"processing_total_ms": @((done - began) * 1000),
            @"ready_latency_seconds": @((double)(inputNow - start) / _rate), @"output_buffering_budget_seconds": @(AS_STREAM_DELAY_SECONDS - (double)(inputNow - start) / _rate),
            @"stem_drift_samples": @0, @"stem_drift_status": @"derived: both stems written to a single frame with same epoch/index", @"status": pushed ? @"completed" : @"output_overflow_fallback", @"worker_started_monotonic": @(began), @"worker_completed_monotonic": @(done), @"evidence": @"measured sample indices, clocks and PCM sums; configured accumulation/delay; derived RMS and deadline budget"
        };
        @synchronized(self) { _lastWindow = report; [_recent addObject:report]; if (_recent.count > 256) [_recent removeObjectAtIndex:0]; }
        [d recordWindow:report processed:YES];
        [d recordStage:@"Stage 08 - Inverse STFT" event:@"stream_overlap_add" fields:report];
        [d recordStage:@"Stage 09 - Instrumental Reconstruction" event:@"stream_mix_check" fields:report];
        if (d.level == AISpatialDiagnosticsLevelFullTrace && d.recording && windowID < 4) {
            NSString *identifier = [NSString stringWithFormat:@"%llu-%lu", epoch, (unsigned long)windowID];
            NSMutableData *pcm = [NSMutableData dataWithLength:_step * 2 * sizeof(float)]; float *p = pcm.mutableBytes;
            for (NSUInteger i = 0; i < _step; i++) { p[2*i] = _stepOutput[i].vl; p[2*i+1] = _stepOutput[i].vr; }
            [d recordBinary:pcm kind:@"pcm-stream-vocals" identifier:identifier offset:start sampleRate:_rate channels:2 metadata:report];
            NSMutableData *instrumental = [NSMutableData dataWithLength:_step * 2 * sizeof(float)]; p = instrumental.mutableBytes;
            for (NSUInteger i = 0; i < _step; i++) { p[2*i] = _stepOutput[i].il; p[2*i+1] = _stepOutput[i].ir; }
            [d recordBinary:instrumental kind:@"pcm-stream-instrumental" identifier:identifier offset:start sampleRate:_rate channels:2 metadata:report];
            NSData *tensorInput = AISpatialTensorData(spectrum), *tensorOutput = AISpatialTensorData(output);
            if (tensorInput) [d recordBinary:tensorInput kind:@"tensor-stream-input" identifier:identifier offset:start sampleRate:_rate channels:2 metadata:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"shape": spectrum.shape, @"dtype": AISpatialTensorTypeName(spectrum.dataType), @"strides": spectrum.strides}];
            if (tensorOutput) [d recordBinary:tensorOutput kind:@"tensor-stream-output" identifier:identifier offset:start sampleRate:_rate channels:2 metadata:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"shape": output.shape, @"dtype": AISpatialTensorTypeName(output.dataType), @"strides": output.strides}];
        }
    }
    if (!okay) [d recordWindow:@{@"stream_epoch": @(epoch), @"window_id": @(windowID), @"start_sample": @(start), @"end_sample": @(start + _routeWindow), @"status": @"failed_fallback_original", @"error": predictionError.localizedDescription ?: error.localizedDescription ?: @"non-finite input/output or unavailable model"} processed:NO];
    atomic_store(&_processing, 0);
}
- (void)observePlaybackBoundary {
    // Public metadata only; neither track names nor identifiers are exported.
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    NSNumber *position = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber *playbackRate = info[MPNowPlayingInfoPropertyPlaybackRate];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", info[MPMediaItemPropertyPersistentID] ?: @"", info[MPMediaItemPropertyTitle] ?: @"", info[MPMediaItemPropertyArtist] ?: @""];
    double now = AISpatialMonotonicSeconds();
    BOOL changed = _trackKey && ![_trackKey isEqualToString:key];
    double expected = _trackPosition + (now - _trackObserved) * _trackRate;
    BOOL seek = position && _trackPositionAvailable && fabs(position.doubleValue - expected) > 1.25;
    if (changed || seek) {
        ASStreamRequestReset(gCore);
        ASAccentDetectorReset();
        [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Stage 02 - Streaming Buffer" event:@"playback_boundary" fields:@{@"reason": changed ? @"track_metadata_changed" : @"elapsed_position_discontinuity", @"detection": @"observed public now-playing metadata; 1-second polling", @"elapsed_seconds": position ?: @"unavailable"}];
    }
    _trackKey = key; _trackPositionAvailable = position != nil;
    _trackPosition = position.doubleValue; _trackRate = playbackRate ? playbackRate.doubleValue : 0; _trackObserved = now;
}
- (void)drainTelemetry {
    if (gCore) {
        int testStatus = atomic_load_explicit(&gCore->test.status, memory_order_acquire);
        if (atomic_load_explicit(&gSelfTestTerminationPending, memory_order_acquire) ||
            (testStatus == AS_SELF_TEST_PASSED || testStatus == AS_SELF_TEST_FAILED || testStatus == AS_SELF_TEST_CANCELLED)) {
            atomic_store_explicit(&gSelfTestTerminationPending, false, memory_order_release);
            AISpatialLiveStopSpatialSelfTest();
        }
    }
    if (AISpatialDiagnostics.sharedDiagnostics.recording) [self announceMetadata];
    if (AISpatialDiagnostics.sharedDiagnostics.recording) {
        ASStreamEventTrace trace;
        while (ASStreamPopEventTrace(gCore, &trace)) {
            [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Spatial Trace" event:@"event_lifecycle" fields:@{
                @"event_id": @(trace.event_id), @"stream_epoch": @(trace.epoch), @"sample": @(trace.sample),
                @"start_sample": @(trace.start), @"end_sample": @(trace.end),
                @"state": [NSString stringWithUTF8String:ASStreamTraceStateName(trace.state)], @"reason": [NSString stringWithUTF8String:ASStreamTraceReasonName(trace.reason)],
                @"rendered_frames": @(trace.rendered_frames), @"mixed_frames": @(trace.mixed_frames),
                @"foreground_square": @(trace.foreground_square), @"delta_square": @(trace.delta_square),
                @"renderer": @(trace.renderer), @"renderer_name": ASRouteName(trace.renderer)
            }];
        }
    }
    ASStreamTelemetry s;
    while (ASStreamPopTelemetry(gCore, &s)) {
        if (!AISpatialDiagnostics.sharedDiagnostics.recording) continue;
        NSArray<NSDictionary *> *recent;
        @synchronized(self) { recent = [_recent copy]; }
        NSMutableArray<NSNumber *> *times = [NSMutableArray array]; double qsum = 0;
        NSDictionary *last = nil;
        for (NSDictionary *r in recent) {
            if ([r[@"stream_epoch"] unsignedLongLongValue] != s.epoch) continue;
            last = r;
            if ([r[@"output_end_sample"] unsignedLongLongValue] > s.start && [r[@"start_sample"] unsignedLongLongValue] < s.end) {
                [times addObject:r[@"processing_total_ms"]]; qsum += [r[@"queue_wait_ms"] doubleValue];
            }
        }
        NSArray *sorted = [times sortedArrayUsingSelector:@selector(compare:)]; double tsum = 0;
        for (NSNumber *t in sorted) tsum += t.doubleValue;
        NSDictionary *status = self.snapshot, *memory = AISpatialMemoryMeasurement();
        [AISpatialDiagnostics.sharedDiagnostics recordSecond:@{
            @"source": @"spotify_streaming", @"stream_epoch": @(s.epoch), @"second": @((NSUInteger)(s.start / s.rate)), @"start_time": @(s.start / s.rate), @"end_time": @(s.end / s.rate), @"samples": @(s.input_frames),
            @"playback_position_seconds": _trackPositionAvailable ? @(_trackPosition) : @"unavailable; no public elapsed metadata", @"playback_position_evidence": @"observed metadata at timeline emission; sample-index time is measured",
            @"windows_submitted": @(atomic_load(&_submitted)), @"windows_completed": @(atomic_load(&_processed)), @"windows_formed": @(atomic_load(&_formed)), @"skipped_windows": @(atomic_load(&_skipped)),
            @"streaming_callback_blocks": @(atomic_load(&gStreamingCallbackBlocks)), @"streaming_callback_frames": @(atomic_load(&gStreamingCallbackFrames)), @"duplicate_callback_blocks": @(atomic_load(&gDuplicateCallbackBlocks)),
            @"input_rms": @(sqrt(s.input_square / (2 * s.input_frames))), @"input_peak": @(s.input_peak), @"mix_rms": @(sqrt(s.output_square / (2 * s.input_frames))), @"mix_peak": @(s.output_peak),
            @"vocal_rms": last[@"vocal_rms"] ?: @"unavailable", @"vocal_peak": last[@"vocal_peak"] ?: @"unavailable", @"instrumental_rms": last[@"instrumental_rms"] ?: @"unavailable", @"instrumental_peak": last[@"instrumental_peak"] ?: @"unavailable", @"stem_stats_scope": @"last completed 1.5-second output step; see window records for exact sample range",
            @"reconstruction_error_rms": s.mode == 2 && s.output_frames ? @(sqrt(s.error_square / (2 * s.output_frames))) : @"unavailable; mode or preroll", @"above_one": last[@"above_one"] ?: @"unavailable", @"nan_count": @"unavailable; see per-window stats", @"infinity_count": @"unavailable; see per-window stats",
            @"inference_min_ms": sorted.count ? sorted.firstObject : @"unavailable", @"inference_avg_ms": sorted.count ? @(tsum / sorted.count) : @"unavailable", @"inference_max_ms": sorted.count ? sorted.lastObject : @"unavailable", @"inference_p95_ms": sorted.count >= 20 ? sorted[(NSUInteger)floor(.95 * (sorted.count - 1))] : @"unavailable; fewer than 20 steps in second", @"inference_scope": @"total processing step, including resampling/STFT/queue/inference/ISTFT",
            @"queue_wait_avg_ms": sorted.count ? @(qsum / sorted.count) : @"unavailable", @"queue_depth_max": status[@"queue_depth"], @"input_buffer_frames": status[@"input_buffer_frames"], @"output_buffer_frames": status[@"output_buffer_frames"],
            @"additional_latency_seconds": s.mode >= 2 ? @(AS_STREAM_DELAY_SECONDS) : @0, @"additional_latency_evidence": @"measured output source index = input index - configured fixed delay; 20 ms original-to-delayed crossfade avoids a silent preroll", @"stem_drift_samples": last[@"stem_drift_samples"] ?: @"unavailable", @"underrun_frames": @(s.underrun), @"overflow_blocks": @(s.overflow), @"fallback_transitions": @(s.fallback_transitions), @"fallback_frames_this_second": @(s.fallback_frames), @"stem_frames_this_second": @(s.stem_frames), @"spatial_events_scheduled": @(atomic_load(&gSpatialScheduled)), @"spatial_events_applied": @(atomic_load(&gCore->spatial_applied)), @"spatial_events_rejected": @(atomic_load(&gCore->spatial.rejected)), @"spatial_events_cancelled": @(atomic_load(&gCore->spatial.cancelled)), @"spatial_base_frames": @(s.spatial_base_frames), @"spatial_changed_frames": @(s.spatial_changed_frames), @"spatial_delta_peak": @(s.spatial_delta_peak), @"spatial_delta_rms": @(s.input_frames ? sqrt(s.spatial_delta_square / (2 * s.input_frames)) : 0), @"rendered_stem_frames": status[@"rendered_stem_frames"], @"rendered_fallback_frames": status[@"rendered_fallback_frames"], @"spatial_renderer": status[@"spatial_route"] ?: @"unavailable", @"dropped_buffers": status[@"input_dropped_frames"], @"diagnostic_telemetry_dropped": @(atomic_load(&gCore->telemetry_dropped)),
            @"memory_bytes": memory[@"physical_footprint_bytes"] ?: @"unavailable", @"memory_measurement_time": @"timeline emission; whole process task_info", @"thermal_state": @(NSProcessInfo.processInfo.thermalState), @"temperature_celsius": @"unavailable; no public iOS temperature API", @"events_detected": ASAccentDetectorSnapshot()[@"candidates"] ?: @0, @"events_selected": ASAccentDetectorSnapshot()[@"selected"] ?: @0, @"events_scheduled": @(atomic_load(&gSpatialScheduled)), @"events_scheduled_total": @(atomic_load(&gSpatialScheduled)), @"events_activated": @(atomic_load(&gCore->spatial.activated)), @"events_rendered": @(atomic_load(&gCore->spatial.rendered_events)), @"events_mixed": @(atomic_load(&gCore->spatial.mixed_events)), @"events_submitted_to_output": @(atomic_load(&gCore->spatial.submitted_events)), @"events_completed": @(atomic_load(&gCore->spatial.completed_events)), @"events_rejected": @(atomic_load(&gCore->spatial.rejected)), @"events_cancelled_stale_epoch": @(atomic_load(&gCore->spatial.stale_epoch)), @"events_cancelled_late": @(atomic_load(&gCore->spatial.late_events)), @"events_rejected_capacity": @(atomic_load(&gCore->spatial.capacity_rejected)), @"events_rejected_duplicate": @(atomic_load(&gCore->spatial.duplicate_rejected)), @"frames_spatial_renderer_this_second": @(s.spatial_renderer_frames), @"frames_bypassed_this_second": @(s.bypassed_frames), @"frames_fallback_output_this_second": @(s.fallback_output_frames), @"frames_spatial_renderer_total": status[@"frames_spatial_renderer_total"] ?: @0, @"frames_bypassed_total": status[@"frames_bypassed_total"] ?: @0, @"frames_fallback_output_total": status[@"frames_fallback_output_total"] ?: @0, @"actual_renderer_type": ASRouteName(s.actual_renderer), @"selected_profile_id": @([NSUserDefaults.standardUserDefaults integerForKey:ASConfigProfile]), @"selected_profile_name": ASProfileName([NSUserDefaults.standardUserDefaults integerForKey:ASConfigProfile]), @"actual_spatial_live": @(s.spatial_live), @"current_stream_epoch": @(s.epoch), @"terminal_output_frames": @(atomic_load(&gTerminalFrames)), @"self_test": AISpatialLiveSelfTestStatusSnapshot(), @"event_trace_dropped": status[@"event_trace_dropped"] ?: @0, @"errors": @0, @"warnings": s.fallback_frames ? @"synchronized fallback active; inspect deadline/model/window events" : @"none"
        }];
    }
}
- (NSDictionary *)snapshot {
    uint64_t inputHead = atomic_load(&gCore->input_head), inputTail = atomic_load(&gCore->input_tail), outputHead = atomic_load(&gCore->output_head), outputTail = atomic_load(&gCore->output_tail);
    int mode = atomic_load(&gCore->active_mode), requested = atomic_load(&gCore->requested_mode);
    uint64_t bits = atomic_load(&gCore->rate_bits); double rate; memcpy(&rate, &bits, sizeof(rate));
    NSDictionary *last; NSArray *recent; @synchronized(self) { last = _lastWindow ?: @{}; recent = [_recent copy]; }
    NSMutableArray *times = [NSMutableArray array]; for (NSDictionary *r in recent) [times addObject:r[@"processing_total_ms"]]; [times sortUsingSelector:@selector(compare:)];
    id p95 = times.count >= 20 ? times[(NSUInteger)floor(.95 * (times.count - 1))] : @"unavailable; fewer than 20 processing steps";
    AVAudioSessionPortDescription *currentPort=AVAudioSession.sharedInstance.currentRoute.outputs.firstObject;
    uint32_t deltaBits=atomic_load(&gCore->spatial_delta_peak_bits), rmsBits=atomic_load(&gCore->spatial_delta_rms_bits);
    float deltaPeak=0, deltaRMS=0; memcpy(&deltaPeak,&deltaBits,sizeof(deltaPeak)); memcpy(&deltaRMS,&rmsBits,sizeof(deltaRMS));
    NSMutableDictionary *result=[@{@"mode_name": ASModeName(mode), @"requested_mode_name": ASModeName(requested), @"mode": @(mode), @"requested_mode": @(requested), @"stream_epoch": @(atomic_load(&gCore->epoch)), @"sample_rate": @(rate), @"input_samples": @(atomic_load(&gCore->input_cursor)), @"output_sample_cursor": @(atomic_load(&gCore->output_cursor)), @"processed_windows": @(atomic_load(&_processed)), @"skipped_windows": @(atomic_load(&_skipped)), @"cancelled_windows": @(atomic_load(&_cancelled)), @"streaming_callback_blocks": @(atomic_load(&gStreamingCallbackBlocks)), @"streaming_callback_frames": @(atomic_load(&gStreamingCallbackFrames)), @"duplicate_callback_blocks": @(atomic_load(&gDuplicateCallbackBlocks)), @"spatial_enabled": @(atomic_load(&gCore->spatial.enabled)), @"spatial_route": @(atomic_load(&gCore->spatial.route)), @"route_uid": currentPort.UID ?: @"unavailable", @"route_name": currentPort.portName ?: @"unavailable", @"route_type": currentPort.portType ?: @"unavailable", @"spatial_scheduled": @(atomic_load(&gSpatialScheduled)), @"spatial_applied": @(atomic_load(&gCore->spatial_applied)), @"spatial_base_applied": @(atomic_load(&gCore->spatial_base_applied)), @"spatial_nonzero_delta_samples": @(atomic_load(&gCore->spatial_nonzero_delta)), @"spatial_delta_peak": @(deltaPeak), @"spatial_delta_rms": @(deltaRMS), @"rendered_stem_frames": @(atomic_load(&gCore->rendered_stem_frames)), @"rendered_fallback_frames": @(atomic_load(&gCore->rendered_fallback_frames)), @"queue_depth": @(atomic_load(&_processing)), @"input_buffer_frames": @(inputHead >= inputTail ? inputHead - inputTail : 0), @"output_buffer_frames": @(outputHead >= outputTail ? outputHead - outputTail : 0), @"latency_target_seconds": @(AS_STREAM_DELAY_SECONDS), @"processing_p95_ms": p95, @"sustainable_budget_ms": @1050, @"underruns": @(atomic_load(&gCore->underruns)), @"overflows": @(atomic_load(&gCore->overflows)), @"fallbacks": @(atomic_load(&gCore->fallback_transitions)), @"input_dropped_frames": @(atomic_load(&gCore->input_dropped)), @"output_dropped_frames": @(atomic_load(&gCore->output_dropped)), @"last_window": last, @"state": mode != requested ? @"mode_pending_playback_boundary" : (rate && fabs(rate - 44100) > .5 && fabs(rate - 48000) > .5 ? @"fallback_unsupported_rate" : (mode == 0 ? @"Original" : @"running; confirm stems/deadlines in diagnostics"))} mutableCopy];
    uint64_t rendererTotal=0; for(unsigned i=0;i<4;i++) rendererTotal += atomic_load(&gCore->renderer_frames[i]);
    result[@"frames_spatial_renderer_total"]=@(rendererTotal);
    result[@"frames_bypassed_total"]=@(atomic_load(&gCore->bypassed_frames));
    result[@"frames_fallback_output_total"]=@(atomic_load(&gCore->rendered_fallback_frames));
    result[@"event_trace_dropped"]=@(atomic_load(&gCore->trace_dropped));
    NSMutableDictionary *rendererFrames=[NSMutableDictionary dictionary];
    for(unsigned i=0;i<4;i++) rendererFrames[[NSString stringWithFormat:@"%u",i]]=@(atomic_load(&gCore->renderer_frames[i]));
    result[@"renderer_frames_total"]=rendererFrames;
    result[@"selected_profile_id"]=@([NSUserDefaults.standardUserDefaults integerForKey:ASConfigProfile]);
    result[@"selected_profile_name"]=ASProfileName([NSUserDefaults.standardUserDefaults integerForKey:ASConfigProfile]);
    return result;
}
@end
static AISpatialLivePipeline *gPipeline;
__attribute__((visibility("default"))) void AISpatialLiveSetMode(AISpatialLiveMode mode) {
    if (!gCore) return;
    ASStreamRequestMode(gCore, (int)mode);
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:ASConfigBackendMode];
    [NSUserDefaults.standardUserDefaults setBool:mode != AISpatialLiveModeOriginal forKey:ASConfigEngineEnabled];
    ASConfigureSpatial(gCore, mode == AISpatialLiveModeLive);
    uint64_t last = atomic_load(&gLastCallbackTicks);
    if (!last || ASTicksSeconds(mach_absolute_time() - last) > .5) { ASStreamRequestReset(gCore); ASAccentDetectorReset(); }
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Stage 02 - Streaming Buffer" event:@"mode_requested" fields:@{@"mode": ASModeName((int)mode), @"policy": @"delay changes take effect at playback boundary"}];
}
__attribute__((visibility("default"))) void AISpatialLiveScheduleAccent(uint64_t eventID, uint64_t epoch,
        uint64_t start, uint64_t end, uint8_t stem, uint8_t type, float priority, float intensity, float direction) {
    if (AS_SPATIAL_BUILD_PHASE < 5 || !gCore || end <= start) return;
    float variety=(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigMotionVariety]; variety=variety<0?0:variety>1?1:variety;
    ASSpatialMotionType selectedMotion=(type==ASAccentVocalShout || type==ASAccentInstrumentalSoundEffect) ? ASSpatialMotionFlyby :
        (type==ASAccentVocalPauseContrast || type==ASAccentInstrumentalPauseTexture ? ASSpatialMotionDepth :
         (type==ASAccentVocalPhraseStart ? ASSpatialMotionArc : ASSpatialMotionSubtleShift));
    if (variety < .25f) selectedMotion=ASSpatialMotionSubtleShift;
    else if (variety > .8f && type==ASAccentVocalAdlib) selectedMotion=ASSpatialMotionBloom;
    ASStreamSpatialEvent event={.event_id=eventID,.epoch=epoch,.start_sample=start,.end_sample=end,
        .stem=stem,.motion=(uint8_t)selectedMotion,
        .priority=priority,.intensity=intensity,.direction=direction,
        .attack_seconds=.012f,.release_seconds=.024f,.tail_seconds=.035f};
    int scheduleReason=ASStreamSpatialScheduleReason(gCore, &event);
    BOOL scheduled=scheduleReason==AS_REASON_NONE;
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Spatial Trace" event:scheduled ? @"event_scheduled" : @"event_rejected" fields:@{
        @"event_id": @(eventID), @"stream_epoch": @(epoch), @"source": stem == ASAccentSourceVocal ? @"vocals" : @"instrumental",
        @"start_sample": @(start), @"end_sample": @(end), @"motion": @(event.motion), @"motion_reason": @"accent type + priority + source mapping",
        @"priority": @(priority), @"intensity": @(intensity), @"direction": @(direction), @"attack_seconds": @(event.attack_seconds),
        @"release_seconds": @(event.release_seconds), @"tail_seconds": @(event.tail_seconds), @"renderer": @(atomic_load(&gCore->spatial.route)),
        @"queue_scheduled": @(atomic_load(&gCore->spatial.scheduled)), @"queue_rejected": @(atomic_load(&gCore->spatial.rejected)),
        @"schedule_reason": [NSString stringWithUTF8String:ASStreamTraceReasonName(scheduleReason)]
    }];
    if (scheduled) atomic_fetch_add_explicit(&gSpatialScheduled, 1, memory_order_relaxed);
}
__attribute__((visibility("default"))) AISpatialLiveMode AISpatialLiveGetMode(void) { return gCore ? (AISpatialLiveMode)atomic_load(&gCore->requested_mode) : AISpatialLiveModeOriginal; }
__attribute__((visibility("default"))) void AISpatialLiveRefreshConfiguration(void) {
    /* Configuration changes arrive before the render boundary commits the
     * requested mode. Reading active_mode here could immediately turn Live
     * spatial processing back off, leaving the UI on Live with a disabled
     * renderer. Use the requested mode; the render callback will apply the
     * epoch transition safely on its next block. */
    if (gCore) ASConfigureSpatial(gCore, ASStreamSpatialLiveRequested(gCore));
}
__attribute__((visibility("default"))) void AISpatialLiveReset(double sampleRate) { if (gCore) ASStreamRequestReset(gCore); ASAccentDetectorReset(); }

__attribute__((unused)) static void ASSelfTestAccumulate(const float *beforeL, const float *beforeR, const float *afterL, const float *afterR, uint32_t frames) {
    uint64_t square=0, changed=0; float peak=0;
    for (uint32_t i=0;i<frames;i++) {
        float dl=afterL[i]-beforeL[i], dr=afterR[i]-beforeR[i];
        float d=fmaxf(fabsf(dl),fabsf(dr));
        if (d>1e-7f) changed++;
        square += (uint64_t)llround((double)dl*dl*1e9) + (uint64_t)llround((double)dr*dr*1e9);
        peak=fmaxf(peak,d);
    }
    atomic_fetch_add_explicit(&gSelfTestChangedFrames,changed,memory_order_relaxed);
    atomic_fetch_add_explicit(&gSelfTestChangedSquare,square,memory_order_relaxed);
    float old=ASLoadFloatBits(&gSelfTestChangedPeakBits); if (peak>old) ASStoreFloatBits(&gSelfTestChangedPeakBits,peak);
    atomic_fetch_add_explicit(&gSelfTestTotalFrames,frames,memory_order_relaxed);
}

__attribute__((unused)) static void ASSelfTestOutputPath(float *left, float *right, uint32_t frames, double rate) {
    uint64_t base=atomic_load_explicit(&gSelfTestPhaseFrames,memory_order_relaxed);
    if (frames>4096) return;
    memcpy(gSelfTestBeforeLeft,left,frames*sizeof(float)); memcpy(gSelfTestBeforeRight,right,frames*sizeof(float));
    for(uint32_t i=0;i<frames;i++) {
        float pan=0.82f*sinf((float)(2.0*M_PI*((double)(base+i)/fmax(rate,1.0))*0.7));
        float leftGain=0.84f-0.12f*pan, rightGain=0.84f+0.12f*pan;
        left[i]*=leftGain; right[i]*=rightGain;
    }
    ASSelfTestAccumulate(gSelfTestBeforeLeft,gSelfTestBeforeRight,left,right,frames);
}

__attribute__((unused)) static void ASSelfTestRenderer(float *left, float *right, uint32_t frames, double rate) {
    uint64_t base=atomic_load_explicit(&gSelfTestPhaseFrames,memory_order_relaxed);
    unsigned route=MIN(3u,(unsigned)((double)base/fmax(rate,1.0)));
    atomic_fetch_add_explicit(&gSelfTestRendererFrames[route],frames,memory_order_relaxed);
    if (frames>4096) return;
    memcpy(gSelfTestBeforeLeft,left,frames*sizeof(float)); memcpy(gSelfTestBeforeRight,right,frames*sizeof(float));
    ASSpatialRenderConfig cfg; ASSpatialRenderConfigDefault(&cfg,(ASSpatialRoute)route);
    cfg.intensity=.9f; cfg.width=.95f; cfg.depth=.55f; cfg.center_protection=.55f; cfg.bass_protection=.8f;
    for(uint32_t i=0;i<frames;i++) {
        double seconds=(double)(base+i)/fmax(rate,1.0); float u=fmodf((float)seconds,1.0f);
        ASSpatialPosition p={.x=sinf((float)(2*M_PI*u)),.y=-.5f+.35f*sinf((float)(M_PI*u)),.z=.15f*cosf((float)(2*M_PI*u))};
        float l=left[i],r=right[i]; ASSpatialRenderStereo(&cfg,p,l,r,.9f,&left[i],&right[i]);
    }
    ASSelfTestAccumulate(gSelfTestBeforeLeft,gSelfTestBeforeRight,left,right,frames);
}

__attribute__((unused)) static void ASSelfTestMaybeAdvance(double rate) {
    int phase=atomic_load_explicit(&gSelfTestPhase,memory_order_acquire);
    uint64_t duration=(uint64_t)llround(rate*(phase==ASSpatialSelfTestOutputPath?2.0:phase==ASSpatialSelfTestRenderer?4.0:2.5));
    if (phase>=ASSpatialSelfTestOutputPath && phase<=ASSpatialSelfTestEventIntegration && atomic_load_explicit(&gSelfTestPhaseFrames,memory_order_relaxed)>=duration) {
        atomic_store_explicit(&gSelfTestPhase,phase+1,memory_order_release); atomic_store_explicit(&gSelfTestPhaseFrames,0,memory_order_release);
        if (phase+1==ASSpatialSelfTestEventIntegration) { atomic_store_explicit(&gSelfTestNextEventSample,0,memory_order_release); ASStreamSpatialSetSelfTest(gCore,true); }
        if (phase+1==ASSpatialSelfTestComplete) [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Spatial Self-Test" event:@"self_test_complete" fields:[AISpatialLiveSelfTestStatusSnapshot() copy]];
    }
}

__attribute__((visibility("default"))) void AISpatialLiveStartSpatialSelfTest(void) {
    if (!gCore || atomic_load_explicit(&gSelfTestPhase,memory_order_acquire)!=ASSpatialSelfTestIdle) return;
    atomic_store_explicit(&gSelfTestPreviousMode,atomic_load_explicit(&gCore->requested_mode,memory_order_acquire),memory_order_release);
    atomic_store_explicit(&gSelfTestPreviousAccent,ASAccentDetectorIsEnabled(),memory_order_release);
    ASAccentDetectorSetEnabled(NO); ASAccentDetectorReset(); ASStreamRequestReset(gCore);
    ASStreamStartOutputSelfTest(gCore);
    ASStreamSpatialConfigure(gCore,ASConfiguredRoute(),true,(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigIntensity],(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigWidth],(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigDepth],(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigCenterProtection],(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigBassProtection],(float)[NSUserDefaults.standardUserDefaults doubleForKey:ASConfigAntiPhaseLimit]);
    atomic_store_explicit(&gSelfTestPhaseFrames,0,memory_order_release); atomic_store_explicit(&gSelfTestTotalFrames,0,memory_order_release); atomic_store_explicit(&gSelfTestChangedFrames,0,memory_order_release); atomic_store_explicit(&gSelfTestChangedSquare,0,memory_order_release); ASStoreFloatBits(&gSelfTestChangedPeakBits,0);
    for(unsigned i=0;i<4;i++) atomic_store_explicit(&gSelfTestRendererFrames[i],0,memory_order_release);
    atomic_store_explicit(&gSelfTestEventsScheduled,0,memory_order_release); atomic_store_explicit(&gSelfTestNextEventSample,0,memory_order_release); atomic_store_explicit(&gSelfTestEventID,0,memory_order_release);
    atomic_store_explicit(&gSelfTestTerminationPending,false,memory_order_release);
    atomic_store_explicit(&gSelfTestP1ChangedFrames,0,memory_order_release);
    atomic_store_explicit(&gSelfTestP2ChangedFrames,0,memory_order_release);
    atomic_store_explicit(&gSelfTestCaptureFrames,0,memory_order_release);
    atomic_store_explicit(&gSelfTestCapturePhase,0,memory_order_release);
    atomic_store_explicit(&gSelfTestPhase,ASSpatialSelfTestOutputPath,memory_order_release);
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Spatial Self-Test" event:@"self_test_start" fields:@{ @"sequence": @[@"Output Path Test", @"Renderer Test", @"Event Integration Test"], @"duration_seconds": @8.5, @"accent_detector": @"bypassed", @"jamesdsp": @"unchanged" }];
}

__attribute__((visibility("default"))) void AISpatialLiveStopSpatialSelfTest(void) {
    int phase=atomic_exchange_explicit(&gSelfTestPhase,ASSpatialSelfTestIdle,memory_order_acq_rel); if (phase==ASSpatialSelfTestIdle) return;
    ASStreamStopOutputSelfTest(gCore); ASStreamSpatialSetSelfTest(gCore,false); ASStreamRequestReset(gCore); ASAccentDetectorSetEnabled(atomic_load_explicit(&gSelfTestPreviousAccent,memory_order_acquire));
    AISpatialLiveMode previous=(AISpatialLiveMode)atomic_load_explicit(&gSelfTestPreviousMode,memory_order_acquire); ASConfigureSpatial(gCore,previous==AISpatialLiveModeLive);
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Spatial Self-Test" event:@"self_test_stop" fields:AISpatialLiveSelfTestStatusSnapshot()];
}

__attribute__((visibility("default"))) NSDictionary *AISpatialLiveSelfTestStatusSnapshot(void) {
    uint64_t frames=gCore?atomic_load_explicit(&gCore->test.frames,memory_order_relaxed):0, changed=0, square=0;
    if(gCore) for(unsigned i=0;i<3;i++){ changed+=atomic_load_explicit(&gCore->test.changed[i],memory_order_relaxed); square+=atomic_load_explicit(&gCore->test.square_nano[i],memory_order_relaxed); }
    int phase=gCore?atomic_load_explicit(&gCore->test.phase,memory_order_acquire):0;
    int testStatus=gCore?atomic_load_explicit(&gCore->test.status,memory_order_acquire):AS_SELF_TEST_IDLE;
    int testReason=gCore?atomic_load_explicit(&gCore->test.reason,memory_order_acquire):AS_SELF_TEST_REASON_NONE;
    NSString *statusName=[NSString stringWithUTF8String:ASOutputSelfTestStatusName(testStatus)];
    NSString *reasonName=[NSString stringWithUTF8String:ASOutputSelfTestReasonName(testReason)];
    NSString *phaseName=[NSString stringWithUTF8String:ASSelfTestPhaseName(phase)];
    NSString *phaseDetail=phaseName;
    if (testStatus==AS_SELF_TEST_FAILED || testStatus==AS_SELF_TEST_CANCELLED) phaseName=statusName;
    if (testStatus==AS_SELF_TEST_PASSED) phaseName=@"PASSED";
    float peak=0; if(gCore) for(unsigned i=0;i<3;i++) peak=fmaxf(peak,ASLoadFloatBits(&gCore->test.peak_bits[i]));
    NSMutableDictionary *result=[@{ @"phase":phaseName, @"phase_detail":phaseDetail, @"status":statusName, @"result":statusName, @"reason":reasonName, @"phase_frames":@(phase>0&&phase<=3?atomic_load_explicit(&gCore->test.phase_frames[phase-1],memory_order_relaxed):0), @"total_frames":@(frames), @"changed_frames":@(changed), @"changed_percent":@(frames?100.0*(double)changed/(double)(frames*2):0), @"delta_rms":@(frames?sqrt((double)square/(double)(frames*2)/1e9):0), @"delta_peak":@(peak), @"events_scheduled":@(gCore?atomic_load_explicit(&gCore->test.scheduled,memory_order_relaxed):0), @"stream_epoch":@(gCore?atomic_load_explicit(&gCore->epoch,memory_order_acquire):0), @"actual_renderer":(gCore?ASRouteName(atomic_load_explicit(&gCore->spatial.route,memory_order_acquire)): @"unavailable"), @"terminal_frames":@(gCore?atomic_load_explicit(&gCore->test.terminal_frames,memory_order_relaxed):0), @"P1_changed_frames":@(atomic_load_explicit(&gSelfTestP1ChangedFrames,memory_order_relaxed)), @"P2_changed_frames":@(atomic_load_explicit(&gSelfTestP2ChangedFrames,memory_order_relaxed)), @"output_path_pass":@(atomic_load_explicit(&gSelfTestP1ChangedFrames,memory_order_relaxed)>0 && atomic_load_explicit(&gSelfTestP2ChangedFrames,memory_order_relaxed)>0) } mutableCopy];
    for(unsigned i=0;i<3;i++) {
        result[[NSString stringWithFormat:@"phase_%u_frames",i+1]]=@(gCore?atomic_load_explicit(&gCore->test.phase_frames[i],memory_order_relaxed):0);
        result[[NSString stringWithFormat:@"phase_%u_changed_frames",i+1]]=@(gCore?atomic_load_explicit(&gCore->test.changed[i],memory_order_relaxed):0);
    }
    for(unsigned i=0;i<4;i++) result[[NSString stringWithFormat:@"renderer_%u_frames",i]]=@(gCore?atomic_load_explicit(&gCore->test.renderer_frames[i],memory_order_relaxed):0);
    return result;
}

__attribute__((visibility("default"))) void AISpatialLiveRecordTerminalStereo(float *left, float *right, uint32_t frames, double sampleRate) {
    (void)sampleRate;
    atomic_fetch_add_explicit(&gTerminalFrames,frames,memory_order_relaxed);
    uint32_t captured=atomic_load_explicit(&gSelfTestCaptureFrames,memory_order_acquire);
    if (left && right && captured && captured==frames && atomic_load_explicit(&gSelfTestCapturePhase,memory_order_acquire)==1) {
        uint64_t changed=0;
        for (uint32_t i=0;i<captured;i++) changed += fabsf(left[i]-gSelfTestP0Left[i])>1e-7f || fabsf(right[i]-gSelfTestP0Right[i])>1e-7f;
        atomic_fetch_add_explicit(&gSelfTestP2ChangedFrames,changed,memory_order_relaxed);
    }
    if(gCore) ASStreamSubmitTerminal(gCore,frames);
    if(!AISpatialDiagnosticsSynchronizedOutputActive()) AISpatialDiagnosticsCaptureTerminalPCM(left,right,frames,sampleRate);
}

__attribute__((visibility("default"))) void AISpatialLiveProcessStereo(float *l, float *r, uint32_t frames, double rate, const AudioTimeStamp *ts) {
    if (ASIsDuplicateCallback(frames, rate, ts)) { atomic_fetch_add_explicit(&gDuplicateCallbackBlocks, 1, memory_order_relaxed); return; }
    atomic_fetch_add_explicit(&gStreamingCallbackBlocks, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&gStreamingCallbackFrames, frames, memory_order_relaxed);
    if (!gCore) return;
    atomic_store_explicit(&gLastCallbackTicks, mach_absolute_time(), memory_order_relaxed);
    AISpatialDiagnosticsSetStreamingBridgeActive(YES);
    // Canonical pre-AI/pre-JamesDSP capture from the SAME callback. No allocation.
    struct { UInt32 count; AudioBuffer buffers[2]; } capture = {2, {{1, frames * sizeof(float), l}, {1, frames * sizeof(float), r}}};
    AudioStreamBasicDescription format = {rate, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked, 0, 1, sizeof(float), 2, 32, 0};
    AISpatialDiagnosticsCapturePCM((AudioBufferList *)&capture, frames, &format, ts);
    double sampleTime = ts && (ts->mFlags & kAudioTimeStampSampleTimeValid) ? ts->mSampleTime : NAN;
    double host = ts && (ts->mFlags & kAudioTimeStampHostTimeValid) ? ASTicksSeconds(ts->mHostTime) : NAN;
    int capturePhase=atomic_load_explicit(&gCore->test.phase,memory_order_acquire);
    uint32_t captureFrames=(capturePhase==1 && frames<=4096) ? frames : 0;
    if (captureFrames) {
        memcpy(gSelfTestP0Left,l,captureFrames*sizeof(float)); memcpy(gSelfTestP0Right,r,captureFrames*sizeof(float));
    }
    ASStreamRender(gCore, l, r, frames, rate, sampleTime, host);
    if (captureFrames) {
        uint64_t changed=0;
        memcpy(gSelfTestP1Left,l,captureFrames*sizeof(float)); memcpy(gSelfTestP1Right,r,captureFrames*sizeof(float));
        for (uint32_t i=0;i<captureFrames;i++) changed += fabsf(gSelfTestP1Left[i]-gSelfTestP0Left[i])>1e-7f || fabsf(gSelfTestP1Right[i]-gSelfTestP0Right[i])>1e-7f;
        atomic_fetch_add_explicit(&gSelfTestP1ChangedFrames,changed,memory_order_relaxed);
        atomic_store_explicit(&gSelfTestCaptureFrames,captureFrames,memory_order_release);
        atomic_store_explicit(&gSelfTestCapturePhase,1,memory_order_release);
    } else {
        atomic_store_explicit(&gSelfTestCaptureFrames,0,memory_order_release);
        atomic_store_explicit(&gSelfTestCapturePhase,0,memory_order_release);
    }
    int testStatus=atomic_load_explicit(&gCore->test.status,memory_order_acquire);
    if (testStatus==AS_SELF_TEST_PASSED || testStatus==AS_SELF_TEST_FAILED || testStatus==AS_SELF_TEST_CANCELLED) {
        /* Restoration touches Foundation/UserDefaults and is deferred to the
           diagnostics queue. The render callback only publishes a marker. */
        atomic_store_explicit(&gSelfTestTerminationPending,true,memory_order_release);
    }
    /* Full Trace keeps a bounded post-spatial clip for local A/B export. It
       is disabled for Basic/Detailed and never performs I/O on this callback. */
    if(!AISpatialDiagnosticsSynchronizedOutputActive()) {
        AISpatialDiagnosticsCaptureSpatialPCM(l, r, frames, rate);
        AISpatialDiagnosticsCaptureEventForegroundFromSpatialPCM(l, r, frames, rate);
    }
}
__attribute__((visibility("default"))) NSDictionary *AISpatialLiveStatusSnapshot(void) {
    NSDictionary *base=gPipeline ? gPipeline.snapshot : @{@"mode_name": @"Original", @"state": @"uninitialized_allocation_failure"};
    NSMutableDictionary *result=[base mutableCopy];
    result[@"self_test"]=AISpatialLiveSelfTestStatusSnapshot();
    result[@"actual_renderer"]=gCore ? ASRouteName(atomic_load_explicit(&gCore->spatial.route,memory_order_acquire)) : @"unavailable";
    result[@"terminal_frames"]=@(atomic_load_explicit(&gTerminalFrames,memory_order_relaxed));
    result[@"terminal_output_bridge"] = @{@"enabled": @YES, @"running": @(atomic_load_explicit(&gTerminalFrames,memory_order_relaxed)>0), @"receiving_data": @(atomic_load_explicit(&gTerminalFrames,memory_order_relaxed)>0), @"blocked_reason": atomic_load_explicit(&gTerminalFrames,memory_order_relaxed)>0 ? [NSNull null] : @"no_terminal_audio_callback"};
    result[@"spatial_events_activated"]=gCore ? @(atomic_load_explicit(&gCore->spatial.activated,memory_order_relaxed)) : @0;
    result[@"spatial_events_rendered"]=gCore ? @(atomic_load_explicit(&gCore->spatial.rendered_events,memory_order_relaxed)) : @0;
    result[@"spatial_events_mixed"]=gCore ? @(atomic_load_explicit(&gCore->spatial.mixed_events,memory_order_relaxed)) : @0;
    result[@"spatial_events_submitted"]=gCore ? @(atomic_load_explicit(&gCore->spatial.submitted_events,memory_order_relaxed)) : @0;
    result[@"spatial_events_completed"]=gCore ? @(atomic_load_explicit(&gCore->spatial.completed_events,memory_order_relaxed)) : @0;
    result[@"spatial_events_stale_epoch"]=gCore ? @(atomic_load_explicit(&gCore->spatial.stale_epoch,memory_order_relaxed)) : @0;
    result[@"spatial_events_late"]=gCore ? @(atomic_load_explicit(&gCore->spatial.late_events,memory_order_relaxed)) : @0;
    result[@"spatial_events_capacity_rejected"]=gCore ? @(atomic_load_explicit(&gCore->spatial.capacity_rejected,memory_order_relaxed)) : @0;
    result[@"spatial_events_duplicate_rejected"]=gCore ? @(atomic_load_explicit(&gCore->spatial.duplicate_rejected,memory_order_relaxed)) : @0;
    result[@"frames_spatial_renderer_total"]=gCore ? @(atomic_load_explicit(&gCore->renderer_frames[0],memory_order_relaxed)+atomic_load_explicit(&gCore->renderer_frames[1],memory_order_relaxed)+atomic_load_explicit(&gCore->renderer_frames[2],memory_order_relaxed)+atomic_load_explicit(&gCore->renderer_frames[3],memory_order_relaxed)) : @0;
    result[@"frames_bypassed_total"]=gCore ? @(atomic_load_explicit(&gCore->bypassed_frames,memory_order_relaxed)) : @0;
    result[@"frames_fallback_output_total"]=gCore ? @(atomic_load_explicit(&gCore->rendered_fallback_frames,memory_order_relaxed)) : @0;
    result[@"event_trace_dropped"]=gCore ? @(atomic_load_explicit(&gCore->trace_dropped,memory_order_relaxed)) : @0;
    NSDictionary *accent=ASAccentDetectorSnapshot() ?: @{};
    uint64_t rendererFrames=gCore ? atomic_load(&gCore->renderer_frames[0])+atomic_load(&gCore->renderer_frames[1])+atomic_load(&gCore->renderer_frames[2])+atomic_load(&gCore->renderer_frames[3]) : 0;
    uint64_t baseFrames=gCore ? atomic_load(&gCore->spatial_base_applied) : 0;
    BOOL configuredLive=gCore && atomic_load(&gCore->active_mode)==AISpatialLiveModeLive && atomic_load(&gCore->spatial.enabled);
    BOOL actualProcessing=configuredLive && (rendererFrames || baseFrames);
    NSString *spatialBlocked = !configuredLive ? @"spatial_live_not_configured" :
        (!rendererFrames && !baseFrames ? @"no_spatial_frames_processed" : nil);
    NSString *schedulerBlocked = !gCore || !atomic_load(&gCore->spatial.enabled) ? @"spatial_gate_disabled" :
        (!atomic_load(&gCore->spatial.scheduled) && !atomic_load(&gCore->spatial.activated) ? @"no_events_scheduled" : nil);
    NSString *rendererBlocked = !gCore || !configuredLive ? @"spatial_live_not_configured" :
        (!rendererFrames && !baseFrames ? @"renderer_received_no_eligible_frames" : nil);
    result[@"actual_spatial_live"]=@(actualProcessing);
    result[@"configured_spatial_live"]=@(configuredLive);
    result[@"component_status"]=@{
        @"accent_detector": @{@"enabled": accent[@"enabled"] ?: @NO, @"running": accent[@"running"] ?: @NO, @"receiving_data": accent[@"receiving_data"] ?: @NO, @"blocked_reason": accent[@"blocked_reason"] ?: [NSNull null]},
        @"spatial_gate": @{@"enabled": gCore ? @(atomic_load(&gCore->spatial.enabled)) : @NO, @"running": @(actualProcessing), @"receiving_data": @(gCore && atomic_load(&gStreamingCallbackFrames)>0), @"blocked_reason": spatialBlocked ?: [NSNull null]},
        @"event_scheduler": @{@"enabled": gCore ? @(atomic_load(&gCore->spatial.enabled)) : @NO, @"running": @(gCore && atomic_load(&gCore->spatial.activated)>0), @"receiving_data": @(gCore && atomic_load(&gCore->spatial.scheduled)>0), @"blocked_reason": schedulerBlocked ?: [NSNull null]},
        @"renderer": @{@"enabled": gCore ? @YES : @NO, @"running": @(rendererFrames>0), @"receiving_data": @(rendererFrames>0 || baseFrames>0), @"blocked_reason": rendererBlocked ?: [NSNull null]},
        @"output_bridge": result[@"terminal_output_bridge"]
    };
    result[@"renderer_instance"]=@{@"enum": gCore ? @(atomic_load(&gCore->spatial.route)) : @-1, @"name": gCore ? ASRouteName(atomic_load(&gCore->spatial.route)) : @"unavailable", @"frames_processed": @(rendererFrames), @"base_scene_frames": @(baseFrames), @"active": @(rendererFrames>0 || baseFrames>0)};
    result[@"route_selection_reason"]=[NSUserDefaults.standardUserDefaults boolForKey:ASConfigRouteAuto] ? @"automatic_output_route_detection; profile is a tuning preset" : @"manual_renderer_route";
    return result;
}
__attribute__((constructor)) static void AISpatialLiveInitialize(void) { mach_timebase_info(&gTimebase); gPipeline = [AISpatialLivePipeline new]; }
