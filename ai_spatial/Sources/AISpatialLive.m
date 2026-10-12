#import "AISpatialSeparator.h"
#import "AISpatialSpectral.h"
#import "AISpatialStreamCore.h"
#import "AISpatialModelStore.h"
#import "AISpatialDiagnostics.h"
#import "AISpatialLog.h"
#import "AISpatialAccentDetector.h"
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
static _Atomic(uint64_t) gLastCallbackSampleBits;
static _Atomic(uint64_t) gLastCallbackHostBits;
static _Atomic(uint64_t) gLastCallbackRateBits;
static _Atomic(uint32_t) gLastCallbackFrames;
static mach_timebase_info_data_t gTimebase;
static const NSUInteger ASModelWindow = 88200, ASModelStep = 66150, ASModelOverlap = 22050;
static const NSUInteger ASMaxRouteWindow = 96000;
static NSString *ASModeName(int mode) { return @[@"Original", @"AI Shadow", @"AI Live", @"Vocals Only (test)", @"Instrumental Only (test)"][MIN(MAX(mode, 0), 4)]; }
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
    atomic_init(&gLastCallbackTicks, 0);
    atomic_init(&gStreamingCallbackBlocks, 0); atomic_init(&gStreamingCallbackFrames, 0); atomic_init(&gDuplicateCallbackBlocks, 0);
    atomic_init(&gLastCallbackSampleBits, 0); atomic_init(&gLastCallbackHostBits, 0); atomic_init(&gLastCallbackRateBits, 0); atomic_init(&gLastCallbackFrames, 0);
    atomic_init(&_processed, 0); atomic_init(&_skipped, 0); atomic_init(&_submitted, 0); atomic_init(&_cancelled, 0); atomic_init(&_formed, 0); atomic_init(&_processing, 0);
    for (NSUInteger n = 0; n < 2048; n++) _hann[n] = .5f - .5f * cosf((float)(2 * M_PI * n / 2048));
    _recent = [NSMutableArray array];
    NSInteger persistedMode = [NSUserDefaults.standardUserDefaults integerForKey:@"pw.chroma.ai-spatial.live-mode"];
    // Model verification is asynchronous during process launch.  Do not
    // restore an AI mode before the verified model is available; this avoids a
    // silent 2.75 s preroll after a restart and requires an explicit selection
    // once the UI reports the model ready.
    if (persistedMode != AISpatialLiveModeOriginal && !AISpatialModelStore.sharedStore.modelIsReady) {
        persistedMode = AISpatialLiveModeOriginal;
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"pw.chroma.ai-spatial.enabled"];
    }
    ASStreamRequestMode(core, (int)persistedMode);
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
        @"model": AISpatialModelStore.sharedStore.diagnosticMetadata
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
            @"accumulation_seconds": @2, @"stream_queue_wait_ms": @(fmax(0, (double)(cursor - start - _routeWindow) / _rate * 1000)), @"preparation_ms": @((preparationEnd - began) * 1000),
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
    if (AISpatialDiagnostics.sharedDiagnostics.recording) [self announceMetadata];
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
            @"additional_latency_seconds": s.mode >= 2 ? @(AS_STREAM_DELAY_SECONDS) : @0, @"additional_latency_evidence": @"measured output source index = input index - configured fixed delay; preroll outputs silence", @"stem_drift_samples": last[@"stem_drift_samples"] ?: @"unavailable", @"underrun_frames": @(s.underrun), @"overflow_blocks": @(s.overflow), @"fallback_transitions": @(s.fallback_transitions), @"fallback_frames_this_second": @(s.fallback_frames), @"stem_frames_this_second": @(s.stem_frames), @"dropped_buffers": status[@"input_dropped_frames"], @"diagnostic_telemetry_dropped": @(atomic_load(&gCore->telemetry_dropped)),
            @"memory_bytes": memory[@"physical_footprint_bytes"] ?: @"unavailable", @"memory_measurement_time": @"timeline emission; whole process task_info", @"thermal_state": @(NSProcessInfo.processInfo.thermalState), @"temperature_celsius": @"unavailable; no public iOS temperature API", @"errors": @0, @"warnings": s.fallback_frames ? @"synchronized fallback active; inspect deadline/model/window events" : @"none"
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
    return @{@"mode_name": ASModeName(mode), @"requested_mode_name": ASModeName(requested), @"mode": @(mode), @"requested_mode": @(requested), @"stream_epoch": @(atomic_load(&gCore->epoch)), @"sample_rate": @(rate), @"input_samples": @(atomic_load(&gCore->input_cursor)), @"output_sample_cursor": @(atomic_load(&gCore->output_cursor)), @"processed_windows": @(atomic_load(&_processed)), @"skipped_windows": @(atomic_load(&_skipped)), @"cancelled_windows": @(atomic_load(&_cancelled)), @"streaming_callback_blocks": @(atomic_load(&gStreamingCallbackBlocks)), @"streaming_callback_frames": @(atomic_load(&gStreamingCallbackFrames)), @"duplicate_callback_blocks": @(atomic_load(&gDuplicateCallbackBlocks)), @"queue_depth": @(atomic_load(&_processing)), @"input_buffer_frames": @(inputHead >= inputTail ? inputHead - inputTail : 0), @"output_buffer_frames": @(outputHead >= outputTail ? outputHead - outputTail : 0), @"latency_target_seconds": @(AS_STREAM_DELAY_SECONDS), @"processing_p95_ms": p95, @"sustainable_budget_ms": @1050, @"live_deadline_budget_ms": @750, @"underruns": @(atomic_load(&gCore->underruns)), @"overflows": @(atomic_load(&gCore->overflows)), @"fallbacks": @(atomic_load(&gCore->fallback_transitions)), @"input_dropped_frames": @(atomic_load(&gCore->input_dropped)), @"output_dropped_frames": @(atomic_load(&gCore->output_dropped)), @"last_window": last, @"state": mode != requested ? @"mode_pending_playback_boundary" : (rate && fabs(rate - 44100) > .5 && fabs(rate - 48000) > .5 ? @"fallback_unsupported_rate" : (mode == 0 ? @"Original" : @"running; confirm stems/deadlines in diagnostics"))};
}
@end
static AISpatialLivePipeline *gPipeline;
__attribute__((visibility("default"))) void AISpatialLiveSetMode(AISpatialLiveMode mode) {
    if (!gCore) return;
    ASStreamRequestMode(gCore, (int)mode);
    [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"pw.chroma.ai-spatial.live-mode"];
    uint64_t last = atomic_load(&gLastCallbackTicks);
    if (!last || ASTicksSeconds(mach_absolute_time() - last) > .5) { ASStreamRequestReset(gCore); ASAccentDetectorReset(); }
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Stage 02 - Streaming Buffer" event:@"mode_requested" fields:@{@"mode": ASModeName((int)mode), @"policy": @"delay changes take effect at playback boundary"}];
}
__attribute__((visibility("default"))) AISpatialLiveMode AISpatialLiveGetMode(void) { return gCore ? (AISpatialLiveMode)atomic_load(&gCore->requested_mode) : AISpatialLiveModeOriginal; }
__attribute__((visibility("default"))) void AISpatialLiveReset(double sampleRate) { if (gCore) ASStreamRequestReset(gCore); ASAccentDetectorReset(); }
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
    ASStreamRender(gCore, l, r, frames, rate, sampleTime, host);
}
__attribute__((visibility("default"))) NSDictionary *AISpatialLiveStatusSnapshot(void) { return gPipeline ? gPipeline.snapshot : @{@"mode_name": @"Original", @"state": @"uninitialized_allocation_failure"}; }
__attribute__((constructor)) static void AISpatialLiveInitialize(void) { mach_timebase_info(&gTimebase); gPipeline = [AISpatialLivePipeline new]; }
