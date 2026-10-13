#import "AISpatialDiagnostics.h"
#import "AISpatialZip.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#include <stdatomic.h>

NSNotificationName const AISpatialDiagnosticsDidChangeNotification = @"AISpatialDiagnosticsDidChangeNotification";
static const NSUInteger ASQueueEvents = 256, ASQueueBytes = 16 * 1024 * 1024;
static const NSUInteger ASDebugLimit = 48 * 1024 * 1024, ASLogLimit = 8 * 1024 * 1024;
#define ASCaptureRingCount 64u
#define ASCaptureMaxRawFrames 4096u
#define ASSpatialClipMaxFrames 240000u /* bounded five seconds at 48 kHz */
typedef struct {
    uint64_t block_id, sample_start;
    double sample_time, host_time, sample_rate;
    uint32_t frames, channels, bits, flags, interleaved, supported, raw_frames, raw_truncated;
    ASMetrics left, right;
} ASCaptureRecord;
static ASCaptureRecord gCaptureRing[ASCaptureRingCount];
// A bounded, preallocated ring keeps Full Trace copies out of the callback's
// filesystem path. The writer copies a slot before publishing it to the ring.
static float gCaptureRaw[ASCaptureRingCount][2][ASCaptureMaxRawFrames];
static _Atomic uint32_t gCaptureHead;
static _Atomic uint32_t gCaptureTail;
static _Atomic uint64_t gCaptureSequence;
static _Atomic uint64_t gCaptureDropped;
static _Atomic BOOL gCaptureEnabled;
static _Atomic BOOL gCaptureDetailed;
static _Atomic BOOL gCaptureRawEnabled;
static _Atomic BOOL gCaptureHookAvailable;
static _Atomic uint64_t gCaptureSampleCursor;
static float gSpatialOriginalClip[2][ASSpatialClipMaxFrames];
static float gSpatialProcessedClip[2][ASSpatialClipMaxFrames];
static _Atomic uint32_t gSpatialClipCursor;
static _Atomic uint32_t gSpatialClipRateBits;

static void ASCaptureClipOriginal(const float *left, const float *right, UInt32 frames) {
    if (!left || !right || !atomic_load_explicit(&gCaptureRawEnabled, memory_order_relaxed)) return;
    uint32_t start=atomic_load_explicit(&gSpatialClipCursor,memory_order_relaxed);
    if (start>=ASSpatialClipMaxFrames) return;
    uint32_t count=MIN(frames,(UInt32)ASSpatialClipMaxFrames-start);
    memcpy(gSpatialOriginalClip[0]+start,left,count*sizeof(float)); memcpy(gSpatialOriginalClip[1]+start,right,count*sizeof(float));
    atomic_fetch_add_explicit(&gSpatialClipCursor,count,memory_order_release);
}

void AISpatialDiagnosticsCaptureSpatialPCM(const float *left, const float *right, UInt32 frames, double sampleRate) {
    if (!left || !right || !frames || !atomic_load_explicit(&gCaptureRawEnabled,memory_order_relaxed)) return;
    uint32_t end=atomic_load_explicit(&gSpatialClipCursor,memory_order_acquire), count=MIN(frames,end);
    uint32_t start=end-count;
    memcpy(gSpatialProcessedClip[0]+start,left+frames-count,count*sizeof(float)); memcpy(gSpatialProcessedClip[1]+start,right+frames-count,count*sizeof(float));
    uint32_t bits=0; float r=(float)sampleRate; memcpy(&bits,&r,sizeof(bits)); atomic_store(&gSpatialClipRateBits,bits);
}

void AISpatialDiagnosticsSetRealtimeCaptureEnabled(BOOL enabled) {
    atomic_store_explicit(&gCaptureEnabled, enabled, memory_order_release);
    if (!enabled) atomic_store_explicit(&gCaptureSampleCursor, 0, memory_order_relaxed);
}
void AISpatialDiagnosticsSetRealtimeCaptureLevel(AISpatialDiagnosticsLevel level) {
    atomic_store_explicit(&gCaptureDetailed, level != AISpatialDiagnosticsLevelBasic, memory_order_release);
    atomic_store_explicit(&gCaptureRawEnabled, level == AISpatialDiagnosticsLevelFullTrace, memory_order_release);
}
void AISpatialDiagnosticsSetRealtimeCaptureHookAvailable(BOOL available) {
    atomic_store_explicit(&gCaptureHookAvailable, available, memory_order_release);
}

static double ASCaptureValue(const void *base, NSUInteger index, NSUInteger stride, BOOL isFloat, BOOL isSigned, NSUInteger bits) {
    double value = 0;
    if (isFloat && bits == 32) value = ((const float *)base)[index * stride];
    else if (isSigned && bits == 16) value = (double)((const int16_t *)base)[index * stride] / 32768.0;
    else if (isSigned && bits == 32) value = (double)((const int32_t *)base)[index * stride] / 2147483648.0;
    else value = NAN;
    return value;
}

void AISpatialDiagnosticsCapturePCM(const AudioBufferList *data, UInt32 frames,
                                    const AudioStreamBasicDescription *format,
                                    const AudioTimeStamp *timestamp) {
    if (!atomic_load_explicit(&gCaptureEnabled, memory_order_acquire) || !data || !format || !frames) return;
    uint32_t head = atomic_load_explicit(&gCaptureHead, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&gCaptureTail, memory_order_acquire);
    if (head - tail >= ASCaptureRingCount) { atomic_fetch_add_explicit(&gCaptureDropped, 1, memory_order_relaxed); return; }
    ASCaptureRecord record = {0};
    record.block_id = atomic_fetch_add_explicit(&gCaptureSequence, 1, memory_order_relaxed);
    record.frames = frames; record.channels = format->mChannelsPerFrame; record.bits = format->mBitsPerChannel;
    record.flags = format->mFormatFlags; record.interleaved = format->mFormatFlags & kAudioFormatFlagIsNonInterleaved ? 0 : 1;
    record.sample_rate = format->mSampleRate; record.sample_time = timestamp ? timestamp->mSampleTime : NAN; record.host_time = timestamp ? (double)timestamp->mHostTime : 0;
    record.sample_start = isfinite(record.sample_time) && record.sample_time >= 0 ? (uint64_t)record.sample_time : atomic_fetch_add_explicit(&gCaptureSampleCursor, frames, memory_order_relaxed);
    BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSigned = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    BOOL supportedEncoding = (isFloat && format->mBitsPerChannel == 32) || (isSigned && (format->mBitsPerChannel == 16 || format->mBitsPerChannel == 32));
    record.supported = supportedEncoding;
    BOOL collectDetailed = atomic_load_explicit(&gCaptureDetailed, memory_order_acquire);
    BOOL collectRaw = atomic_load_explicit(&gCaptureRawEnabled, memory_order_acquire) && supportedEncoding;
    uint32_t rawSlot = head % ASCaptureRingCount;
    uint32_t rawFrames = collectRaw ? MIN(frames, (UInt32)ASCaptureMaxRawFrames) : 0;
    record.raw_frames = rawFrames;
    record.raw_truncated = collectRaw && frames > rawFrames;
    if (collectDetailed && data->mNumberBuffers == 1) {
        const AudioBuffer *buffer = &data->mBuffers[0];
        NSUInteger channels = MAX((NSUInteger)buffer->mNumberChannels, (NSUInteger)format->mChannelsPerFrame);
        if (buffer->mData && channels) {
            NSUInteger bytes = MAX((NSUInteger)(format->mBitsPerChannel / 8), 1);
            for (UInt32 frame = 0; frame < frames; frame++) {
                const char *sample = (const char *)buffer->mData + (NSUInteger)frame * bytes * channels;
                double left = ASCaptureValue(sample, 0, 1, isFloat, isSigned, format->mBitsPerChannel);
                ASMetricsAdd(&record.left, left);
                if (rawFrames && frame < rawFrames) gCaptureRaw[rawSlot][0][frame] = (float)left;
                double right = channels > 1 ? ASCaptureValue(sample + bytes, 0, 1, isFloat, isSigned, format->mBitsPerChannel) : left;
                ASMetricsAdd(&record.right, right);
                if (rawFrames && frame < rawFrames) gCaptureRaw[rawSlot][1][frame] = (float)right;
            }
        }
    } else if (collectDetailed) {
        for (UInt32 frame = 0; frame < frames; frame++) {
            double left = data->mBuffers[0].mData ? ASCaptureValue(data->mBuffers[0].mData, frame, 1, isFloat, isSigned, format->mBitsPerChannel) : NAN;
            double right = data->mNumberBuffers > 1 && data->mBuffers[1].mData ? ASCaptureValue(data->mBuffers[1].mData, frame, 1, isFloat, isSigned, format->mBitsPerChannel) : left;
            ASMetricsAdd(&record.left, left); ASMetricsAdd(&record.right, right);
            if (rawFrames && frame < rawFrames) { gCaptureRaw[rawSlot][0][frame] = (float)left; gCaptureRaw[rawSlot][1][frame] = (float)right; }
        }
    }
    if (record.channels < 2 || (data->mNumberBuffers < 2 && data->mBuffers[0].mNumberChannels < 2)) {
        record.right = record.left;
        if (rawFrames) memcpy(gCaptureRaw[rawSlot][1], gCaptureRaw[rawSlot][0], rawFrames * sizeof(float));
    }
    if (rawFrames && (!data->mNumberBuffers || !data->mBuffers[0].mData)) record.raw_frames = 0;
    if (collectRaw && data->mNumberBuffers >= 2 && data->mBuffers[0].mData && data->mBuffers[1].mData && isFloat && format->mBitsPerChannel==32)
        ASCaptureClipOriginal((const float *)data->mBuffers[0].mData,(const float *)data->mBuffers[1].mData,frames);
    gCaptureRing[rawSlot] = record;
    atomic_store_explicit(&gCaptureHead, head + 1, memory_order_release);
}

NSString *AISpatialDiagnosticsLevelName(AISpatialDiagnosticsLevel level) {
    return level == AISpatialDiagnosticsLevelFullTrace ? @"Full Trace" : level == AISpatialDiagnosticsLevelDetailed ? @"Detailed" : @"Basic";
}
double AISpatialMonotonicSeconds(void) {
    static mach_timebase_info_data_t timebase; static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e9;
}
NSDictionary *AISpatialMemoryMeasurement(void) {
    task_vm_info_data_t info = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (result != KERN_SUCCESS) return @{ @"status": @"unavailable", @"reason": @"task_info failed", @"mach_error": @(result) };
    return @{ @"status": @"measured", @"physical_footprint_bytes": @(info.phys_footprint), @"resident_bytes": @(info.resident_size), @"scope": @"whole Spotify process, not isolated Core ML allocation" };
}
NSDictionary *AISpatialMetricsDictionary(ASMetrics m) {
    return @{ @"count": @(m.count), @"finite_count": @(m.finite), @"nan_count": @(m.nan), @"infinity_count": @(m.infinity),
        @"out_of_range_count": @(m.above_one), @"min": m.finite ? @(m.minimum) : (id)NSNull.null,
        @"max": m.finite ? @(m.maximum) : (id)NSNull.null, @"peak": @(m.peak), @"rms": @(ASRMS(m)),
        @"dc_offset": @(m.finite ? m.sum / m.finite : 0), @"above_one_meaning": @"potential conversion/playback risk; float PCM above +/-1 is not proof of an error" };
}
static ASMetrics ASMetricsMerge(ASMetrics a, ASMetrics b) {
    BOOL hadFinite = a.finite != 0;
    a.count += b.count; a.finite += b.finite; a.nan += b.nan; a.infinity += b.infinity; a.above_one += b.above_one;
    a.sum += b.sum; a.squares += b.squares; a.peak = MAX(a.peak, b.peak);
    if (b.finite) { if (!hadFinite) { a.minimum = b.minimum; a.maximum = b.maximum; } else { a.minimum = MIN(a.minimum, b.minimum); a.maximum = MAX(a.maximum, b.maximum); } }
    return a;
}
NSDictionary *AISpatialFloatStatistics(const float *v, NSUInteger n) { return AISpatialMetricsDictionary(ASMeasure(v,n,1)); }
NSString *AISpatialTensorTypeName(MLMultiArrayDataType t) {
    switch(t) { case MLMultiArrayDataTypeFloat32: return @"float32"; case MLMultiArrayDataTypeDouble: return @"float64"; case MLMultiArrayDataTypeFloat16: return @"float16"; case MLMultiArrayDataTypeInt32: return @"int32"; default: return @"unavailable"; }
}
static NSUInteger ASSize(MLMultiArrayDataType t) {
    switch(t) { case MLMultiArrayDataTypeDouble: return 8; case MLMultiArrayDataTypeFloat16: return 2; case MLMultiArrayDataTypeFloat32: case MLMultiArrayDataTypeInt32: return 4; default: return 0; }
}
NSData *AISpatialTensorData(MLMultiArray *array) {
    NSUInteger size = ASSize(array.dataType), rank = array.shape.count;
    if (!size || !rank || rank > 8 || array.count <= 0 || array.count > 4000000) return nil;
    size_t *shape = calloc(rank, sizeof(size_t)); size_t *strides = calloc(rank, sizeof(size_t));
    for(NSUInteger d=0;d<rank;d++) { shape[d]=[array.shape[d] unsignedIntegerValue]; strides[d]=[array.strides[d] unsignedIntegerValue]; }
    NSMutableData *canonical = [NSMutableData dataWithLength:(NSUInteger)array.count * size];
    __block BOOL valid=YES;
    [array getBytesWithHandler:^(const void *bytes, NSInteger length) {
        for(NSUInteger i=0;i<(NSUInteger)array.count;i++) {
            NSUInteger offset = ASTensorOffset(i,shape,strides,rank) * size;
            if (offset > (NSUInteger)length || size > (NSUInteger)length - offset) { valid=NO; break; }
            memcpy((char *)canonical.mutableBytes + i*size,(const char *)bytes+offset,size);
        }
    }];
    NSData *result = valid ? canonical : nil; free(shape); free(strides); return result;
}
NSString *AISpatialSHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *text=[NSMutableString string]; for(NSUInteger i=0;i<sizeof(digest);i++) [text appendFormat:@"%02x",digest[i]]; return text;
}
NSDictionary *AISpatialTensorStatistics(MLMultiArray *array) {
    if(!array) return @{ @"status": @"unavailable", @"reason": @"no tensor returned" };
    NSData *canonical = AISpatialTensorData(array); ASMetrics metrics={0};
    if(canonical) for(NSUInteger i=0;i<(NSUInteger)array.count;i++) {
        double value=0;
        switch(array.dataType) {
            case MLMultiArrayDataTypeDouble: value=((const double *)canonical.bytes)[i]; break;
            case MLMultiArrayDataTypeFloat32: value=((const float *)canonical.bytes)[i]; break;
            case MLMultiArrayDataTypeFloat16: value=ASHalfToDouble(((const uint16_t *)canonical.bytes)[i]); break;
            case MLMultiArrayDataTypeInt32: value=((const int32_t *)canonical.bytes)[i]; break;
            default: break;
        }
        ASMetricsAdd(&metrics,value);
    }
    NSMutableDictionary *result=[AISpatialMetricsDictionary(metrics) mutableCopy];
    [result addEntriesFromDictionary:@{ @"status": canonical ? @"measured" : @"unavailable", @"shape": array.shape, @"strides": array.strides,
        @"dtype": AISpatialTensorTypeName(array.dataType), @"element_count": @(array.count), @"byte_count": @(canonical.length),
        @"layout": @"logical C order; source strides respected", @"sha256": canonical ? AISpatialSHA256(canonical) : @"unavailable",
        @"checksum_scope": @"native dtype values in logical C order without padding; little endian" }];
    if(!canonical) result[@"reason"]=@"unsupported dtype/shape or invalid backing-buffer bounds";
    return result;
}
static NSString *ASUTC(void) { NSISO8601DateFormatter *f=[NSISO8601DateFormatter new]; f.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds; return [f stringFromDate:NSDate.date]; }
static NSString *ASCSV(id value) {
    if(!value || value==NSNull.null) return @"unavailable";
    NSString *s=[value isKindOfClass:NSString.class] ? value : [value description];
    return [NSString stringWithFormat:@"\"%@\"",[s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}
static NSArray *ASTimelineColumns(void) {
    return @[@"session_id",@"second",@"start_time",@"end_time",@"samples",@"windows_submitted",@"windows_completed",@"input_rms",@"input_peak",@"vocal_rms",@"vocal_peak",@"instrumental_rms",@"instrumental_peak",@"mix_rms",@"mix_peak",@"reconstruction_error_rms",@"mixture_gain",@"input_to_vocal_db",@"input_to_mix_db",@"above_one",@"nan_count",@"infinity_count",@"inference_min_ms",@"inference_avg_ms",@"inference_max_ms",@"inference_p95_ms",@"queue_wait_avg_ms",@"queue_depth_max",@"dropped_buffers",@"memory_bytes",@"memory_measurement_time",@"errors",@"warnings", @"source", @"stream_epoch", @"playback_position_seconds", @"playback_position_evidence", @"windows_formed", @"skipped_windows", @"streaming_callback_blocks", @"streaming_callback_frames", @"duplicate_callback_blocks", @"input_buffer_frames", @"output_buffer_frames", @"additional_latency_seconds", @"additional_latency_evidence", @"stem_drift_samples", @"underrun_frames", @"overflow_blocks", @"fallback_transitions", @"fallback_frames_this_second", @"stem_frames_this_second", @"spatial_events_scheduled", @"spatial_events_applied", @"spatial_events_rejected", @"spatial_events_cancelled", @"spatial_base_frames", @"spatial_changed_frames", @"spatial_delta_peak", @"spatial_delta_rms", @"rendered_stem_frames", @"rendered_fallback_frames", @"spatial_renderer", @"diagnostic_telemetry_dropped", @"thermal_state", @"temperature_celsius", @"stem_stats_scope", @"inference_scope"];
}
static NSString *ASRoot(void) { NSString *base=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject ?: NSTemporaryDirectory(); return [base stringByAppendingPathComponent:@"Croma/AI Spatial/Diagnostics"]; }
@interface AISpatialDiagnostics ()
@property(nonatomic,readwrite) AISpatialDiagnosticsLevel level;
@property(nonatomic,readwrite) BOOL recording;
@property(nonatomic,readwrite,copy) NSString *sessionID;
@property(nonatomic,readwrite,copy) NSURL *sessionDirectory;
@end

NSDictionary *AISpatialDiagnosticsStatusSnapshot(void) { return AISpatialDiagnostics.sharedDiagnostics.snapshot; }
void AISpatialDiagnosticsStart(void) { [AISpatialDiagnostics.sharedDiagnostics startRecording]; }
void AISpatialDiagnosticsStop(void) { [AISpatialDiagnostics.sharedDiagnostics stopRecording]; }
void AISpatialDiagnosticsSetLevelIndex(NSInteger level) {
    [AISpatialDiagnostics.sharedDiagnostics setLevel:(AISpatialDiagnosticsLevel)MAX(0, MIN(AISpatialDiagnosticsLevelFullTrace, level))];
}
void AISpatialDiagnosticsExport(BOOL includeDebug, void (^completion)(NSArray<NSURL *> *, NSError *)) {
    [AISpatialDiagnostics.sharedDiagnostics exportReportIncludingDebug:includeDebug completion:completion];
}
@implementation AISpatialDiagnostics {
    AISpatialDiagnosticsLevel _level;
    BOOL _recording;
    NSString *_sessionID;
    NSURL *_sessionDirectory;
    dispatch_queue_t _writer;
    NSMutableDictionary *_metadata;
    NSUInteger _pending, _pendingBytes, _dropped, _debugReserved, _debugWritten, _logBytes, _processed, _skipped, _warnings, _errors;
    double _deadline; BOOL _finished;
    NSString *_state;
    NSUInteger _captureDroppedBlocks;
    NSUInteger _captureSecond;
    size_t _captureSecondSamples;
    double _captureSecondRate;
    BOOL _captureSecondHasData;
    ASMetrics _captureSecondLeft, _captureSecondRight;
    dispatch_source_t _captureTimer;
    uint64_t _lastCaptureSample, _lastCaptureBlock, _captureBaseSample;
    BOOL _captureHasPrevious;
}
+ (instancetype)sharedDiagnostics { static AISpatialDiagnostics *d; static dispatch_once_t once; dispatch_once(&once,^{ d=[self new]; }); return d; }
- (instancetype)init {
    if((self=[super init])) { _writer=dispatch_queue_create("pw.chroma.ai-spatial.diagnostic-writer",DISPATCH_QUEUE_SERIAL); _level=MIN(MAX([[NSUserDefaults standardUserDefaults] integerForKey:@"pw.chroma.ai-spatial.diagnostics.level"],0),2); _state=@"Idle"; AISpatialDiagnosticsSetRealtimeCaptureLevel(_level); }
    return self;
}
- (AISpatialDiagnosticsLevel)level { @synchronized(self) { return _level; } }
- (BOOL)recording { @synchronized(self) { return _recording; } }
- (NSString *)sessionID { @synchronized(self) { return _sessionID; } }
- (NSURL *)sessionDirectory { @synchronized(self) { return _sessionDirectory; } }
- (void)notify { dispatch_async(dispatch_get_main_queue(),^{ [[NSNotificationCenter defaultCenter] postNotificationName:AISpatialDiagnosticsDidChangeNotification object:self]; }); }
- (NSDictionary *)snapshot {
    @synchronized(self) { return @{ @"session_id": _sessionID ?: @"unavailable", @"level": AISpatialDiagnosticsLevelName(_level), @"recording": @(_recording), @"state": _state ?: @"Idle", @"processed_windows": @(_processed), @"skipped_windows": @(_skipped), @"dropped_events": @(_dropped), @"dropped_capture_blocks": @(_captureDroppedBlocks), @"writer_queue_depth": @(_pending), @"writer_queue_bytes": @(_pendingBytes), @"log_bytes": @(_logBytes), @"debug_bytes": @(_debugWritten), @"warnings": @(_warnings), @"errors": @(_errors), @"remaining_seconds": @(MAX(0,_deadline-AISpatialMonotonicSeconds())) }; }
}
- (void)setLevel:(AISpatialDiagnosticsLevel)level {
    @synchronized(self) { if(_recording) return; _level=MIN(MAX(level,0),2); }
    AISpatialDiagnosticsSetRealtimeCaptureLevel(self.level);
    [[NSUserDefaults standardUserDefaults] setInteger:self.level forKey:@"pw.chroma.ai-spatial.diagnostics.level"]; [self notify];
}
- (void)writeJSON:(NSDictionary *)object toURL:(NSURL *)url { NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil]; [data writeToURL:url options:NSDataWritingAtomic error:nil]; }
- (void)append:(NSData *)data toURL:(NSURL *)url {
    if(!data.length) return;
    NSDictionary *attrs=[[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    if([attrs[NSFileSize] unsignedIntegerValue]+data.length > ASLogLimit) { @synchronized(self) { _dropped++; } return; }
    if(!attrs) [[NSFileManager defaultManager] createFileAtPath:url.path contents:nil attributes:nil];
    NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:url.path];
    @try { [file seekToEndOfFile]; [file writeData:data]; [file closeFile]; @synchronized(self) { _logBytes+=data.length; } }
    @catch(NSException *e) { @synchronized(self) { _errors++; _state=@"Diagnostic write failed"; } }
}
- (void)start:(BOOL)automatic {
    @synchronized(self) {
        if(_recording && !_finished) return;
        _recording=YES; _finished=NO; _sessionID=NSUUID.UUID.UUIDString.lowercaseString;
        _sessionDirectory=[NSURL fileURLWithPath:[ASRoot() stringByAppendingPathComponent:_sessionID] isDirectory:YES];
        _dropped=_captureDroppedBlocks=_debugReserved=_debugWritten=_logBytes=_processed=_skipped=_warnings=_errors=0;
        _deadline=AISpatialMonotonicSeconds()+(self.level==AISpatialDiagnosticsLevelFullTrace ? 90 : 120);
        _state=@"Recording";
        NSURL *dir=_sessionDirectory; NSString *session=_sessionID; AISpatialDiagnosticsLevel level=_level;
        dispatch_async(_writer,^{
            [[NSFileManager defaultManager] createDirectoryAtURL:[dir URLByAppendingPathComponent:@"debug"] withIntermediateDirectories:YES attributes:nil error:nil];
            BOOL hookAvailable = atomic_load_explicit(&gCaptureHookAvailable, memory_order_acquire);
            self->_metadata=[@{ @"schema_version": @1, @"session_id": session, @"started_at": ASUTC(), @"level": AISpatialDiagnosticsLevelName(level), @"source": automatic ? @"local_file" : @"pending", @"realtime_capture": @{ @"observer": @"AudioUnit post-render notification", @"enabled_only_while_recording": @YES, @"raw_pcm_dump": @"Full Trace only; bounded first five seconds; copied to a memory ring before asynchronous write", @"callback_hook_status": hookAvailable ? @"available" : @"unavailable; AudioOutputUnitStart import was not rebound" }, @"limits": @{ @"queue_events": @(ASQueueEvents), @"queue_bytes": @(ASQueueBytes), @"debug_bytes": @(ASDebugLimit), @"each_text_file_bytes": @(ASLogLimit), @"retained_sessions": @3, @"full_trace_max_wall_seconds": @90, @"test_audio_seconds": @30, @"dump_selection": @"first 5 seconds plus bounded anomaly neighborhood" }, @"evidence": @{ @"measured": @"PCM/tensor statistics, timestamps, call durations, checksums, task_info", @"derived": @"RMS, percentiles, residual errors, level ratios, relative time", @"configured": @"STFT, gains, thresholds, requested compute units", @"heuristic": @"all anomaly thresholds; warnings are not quality ground truth", @"unavailable": @"explicit reason accompanies unsupported metrics" } } mutableCopy];
            [self writeJSON:self->_metadata toURL:[dir URLByAppendingPathComponent:@"ai-spatial-metadata.json"]];
            [self writeJSON:self->_metadata toURL:[dir URLByAppendingPathComponent:@"spatial-summary.json"]];
            NSString *header=[[ASTimelineColumns() componentsJoinedByString:@","] stringByAppendingString:@"\n"];
            [self append:[header dataUsingEncoding:NSUTF8StringEncoding] toURL:[dir URLByAppendingPathComponent:@"ai-spatial-timeline.csv"]];
            NSArray *children=[[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:ASRoot()] includingPropertiesForKeys:@[NSURLCreationDateKey] options:0 error:nil];
            children=[children sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b) { NSDate *da,*db; [a getResourceValue:&da forKey:NSURLCreationDateKey error:nil]; [b getResourceValue:&db forKey:NSURLCreationDateKey error:nil]; return [db ?: NSDate.distantPast compare:da ?: NSDate.distantPast]; }];
            for(NSUInteger i=3;i<children.count;i++) if(![children[i] isEqual:dir]) [[NSFileManager defaultManager] removeItemAtURL:children[i] error:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((level==2 ? 90 : 120)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ if([self.sessionID isEqual:session] && self.recording) [self stopRecording]; });
        _captureHasPrevious=NO; _lastCaptureSample=0; _lastCaptureBlock=0; _captureBaseSample=0; _captureSecondHasData=NO; _captureSecondSamples=0; _captureSecondRate=0; _captureSecondLeft=(ASMetrics){0}; _captureSecondRight=(ASMetrics){0};
        atomic_store_explicit(&gSpatialClipCursor, 0, memory_order_release);
        atomic_store_explicit(&gSpatialClipRateBits, 0, memory_order_release);
        AISpatialDiagnosticsSetRealtimeCaptureLevel(level);
        AISpatialDiagnosticsSetRealtimeCaptureEnabled(YES);
        _captureTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_writer);
        dispatch_source_set_timer(_captureTimer,dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),50*NSEC_PER_MSEC,5*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(_captureTimer,^{ [self drainRealtimeCapture]; });
        dispatch_resume(_captureTimer);
    }
    [self recordStage:@"00" event:@"session_start" fields:@{}]; [self notify];
    if (!atomic_load_explicit(&gCaptureHookAvailable, memory_order_acquire)) {
        [self recordStage:@"Stage 01 - Spotify PCM Capture" event:@"unavailable" fields:@{ @"status": @"unavailable", @"reason": @"AudioOutputUnitStart import was not rebound in this Spotify build", @"raw_pcm": @"unavailable" }];
    }
}
- (void)startRecording { [self start:NO]; }
- (void)beginAutomaticSessionForTest { [self start:YES]; }
- (void)flushRealtimeSecond {
    if (!_captureSecondHasData) return;
    if (self.level != AISpatialDiagnosticsLevelBasic) {
        NSDictionary *left = AISpatialMetricsDictionary(_captureSecondLeft);
        NSDictionary *right = AISpatialMetricsDictionary(_captureSecondRight);
        NSDictionary *stereo = AISpatialMetricsDictionary(ASMetricsMerge(_captureSecondLeft, _captureSecondRight));
        NSDictionary *snapshot = [self snapshot];
        NSDictionary *memory = AISpatialMemoryMeasurement();
        id memoryBytes = memory[@"physical_footprint_bytes"] ?: @"unavailable";
        [self recordSecond:@{
            @"source": @"spotify_realtime_capture",
            @"second": @(_captureSecond), @"start_time": @((double)_captureSecond), @"end_time": @((double)_captureSecond + 1.0), @"samples": @(_captureSecondSamples),
            @"windows_submitted": @"unavailable; observer is metrics-only", @"windows_completed": @"unavailable; observer is metrics-only",
            @"input_rms": stereo[@"rms"] ?: @0, @"input_peak": stereo[@"peak"] ?: @0, @"input_left": left, @"input_right": right,
            @"vocal_rms": @"unavailable", @"vocal_peak": @"unavailable", @"instrumental_rms": @"unavailable", @"instrumental_peak": @"unavailable", @"mix_rms": @"unavailable", @"mix_peak": @"unavailable", @"reconstruction_error_rms": @"unavailable",
            @"above_one": @([stereo[@"out_of_range_count"] unsignedIntegerValue]), @"nan_count": @([stereo[@"nan_count"] unsignedIntegerValue]), @"infinity_count": @([stereo[@"infinity_count"] unsignedIntegerValue]),
            @"inference_min_ms": @"unavailable", @"inference_avg_ms": @"unavailable", @"inference_max_ms": @"unavailable", @"inference_p95_ms": @"unavailable", @"queue_wait_avg_ms": @"unavailable", @"queue_depth_max": @"unavailable", @"dropped_buffers": @(_captureDroppedBlocks),
            @"memory_bytes": memoryBytes, @"memory_measurement_status": memory[@"status"] ?: @"unavailable", @"memory_measurement_time": @"timeline emission; task_info whole-process measurement", @"errors": snapshot[@"errors"] ?: @0, @"warnings": snapshot[@"warnings"] ?: @0,
            @"realtime_boundary_assignment": @"whole callback block assigned by its first sample; see Stage 01 block timestamps",
            @"status": @"measured input only; model stages unavailable in live observer"
        }];
    }
    _captureSecondHasData = NO; _captureSecondSamples = 0; _captureSecondRate = 0; _captureSecondLeft = (ASMetrics){0}; _captureSecondRight = (ASMetrics){0};
}
- (void)drainRealtimeCapture {
    uint32_t tail=atomic_load_explicit(&gCaptureTail,memory_order_relaxed), head=atomic_load_explicit(&gCaptureHead,memory_order_acquire);
    uint64_t dropped=atomic_exchange_explicit(&gCaptureDropped,0,memory_order_acq_rel);
    if(dropped) { @synchronized(self) { _dropped += (NSUInteger)dropped; _captureDroppedBlocks += (NSUInteger)dropped; } [self recordStage:@"Stage 01 - Spotify PCM Capture" event:@"capture_queue_overflow" fields:@{ @"dropped_blocks":@(dropped), @"queue_capacity":@(ASCaptureRingCount) }]; }
    while(tail<head) {
        uint32_t rawSlot = tail % ASCaptureRingCount;
        ASCaptureRecord record=gCaptureRing[rawSlot];
        NSData *rawPCM = nil;
        if (record.raw_frames) {
            NSMutableData *interleaved = [NSMutableData dataWithLength:(NSUInteger)record.raw_frames * 2 * sizeof(float)];
            float *destination = interleaved.mutableBytes;
            for (NSUInteger frame = 0; frame < record.raw_frames; frame++) { destination[frame * 2] = gCaptureRaw[rawSlot][0][frame]; destination[frame * 2 + 1] = gCaptureRaw[rawSlot][1][frame]; }
            rawPCM = interleaved;
        }
        atomic_store_explicit(&gCaptureTail,tail+1,memory_order_release); tail++;
        BOOL firstCaptureBlock = !_captureHasPrevious;
        if (firstCaptureBlock) _captureBaseSample = record.sample_start;
        NSUInteger relativeOffset = record.sample_start >= _captureBaseSample ? (NSUInteger)(record.sample_start - _captureBaseSample) : 0;
        NSUInteger blockSecond = (NSUInteger)floor((double)relativeOffset / MAX(record.sample_rate, 1.0));
        if (_captureSecondHasData && blockSecond != _captureSecond) {
            [self flushRealtimeSecond];
        }
        if (!_captureSecondHasData) { _captureSecond = blockSecond; _captureSecondRate = record.sample_rate; _captureSecondHasData = YES; }
        _captureSecondSamples += record.frames; _captureSecondLeft = ASMetricsMerge(_captureSecondLeft, record.left); _captureSecondRight = ASMetricsMerge(_captureSecondRight, record.right);
        BOOL continuous=!_captureHasPrevious || record.sample_start==_lastCaptureSample;
        BOOL blockSequential=!_captureHasPrevious || record.block_id==_lastCaptureBlock+1;
        [self recordStage:@"Stage 01 - Spotify PCM Capture" event:@"pcm_block" fields:@{
            @"block_id":@(record.block_id), @"sample_start":@(record.sample_start), @"frames":@(record.frames), @"channels":@(record.channels), @"sample_rate":@(record.sample_rate), @"bit_depth":@(record.bits), @"format_flags":@(record.flags), @"layout":record.interleaved ? @"interleaved" : @"non-interleaved", @"sample_time":isfinite(record.sample_time)?@(record.sample_time):@"unavailable", @"host_time":record.host_time>0?@(record.host_time):@"unavailable", @"channel_0":AISpatialMetricsDictionary(record.left), @"channel_1":AISpatialMetricsDictionary(record.right), @"metrics_status":self.level == AISpatialDiagnosticsLevelBasic ? @"not_collected_at_basic" : @"measured", @"continuity":continuous?@"continuous":@"gap_or_overlap", @"block_sequence":blockSequential?@"sequential":@"missing_or_repeated", @"pcm_format":record.supported ? @"supported float32/signed16/signed32" : @"unavailable; unsupported PCM encoding", @"raw_pcm_dump":rawPCM ? @"scheduled Full Trace binary dump" : @"unavailable; enable Full Trace and use a supported PCM format"
        }];
        if (rawPCM) [self recordBinary:rawPCM kind:@"pcm-spotify" identifier:[NSString stringWithFormat:@"%llu", record.block_id] offset:relativeOffset sampleRate:record.sample_rate channels:2 metadata:@{ @"stage": @"01-Spotify PCM Capture", @"block_id": @(record.block_id), @"sample_start": @(record.sample_start), @"frames": @(record.raw_frames), @"truncated": @(record.raw_truncated), @"format": @"float32 interleaved canonical copy", @"raw_source": @"AudioUnit post-render observer; copied into bounded memory ring before asynchronous write" }];
        _captureHasPrevious=YES; _lastCaptureSample=record.sample_start+record.frames; _lastCaptureBlock=record.block_id;
    }
}
- (void)stopRecording {
    AISpatialDiagnosticsSetRealtimeCaptureEnabled(NO);
    if(_captureTimer) { dispatch_source_cancel(_captureTimer); _captureTimer=nil; }
    @synchronized(self) {
        if(!_recording) return;
        _state=@"Stopping"; NSURL *dir=_sessionDirectory;
        dispatch_async(_writer,^{
            [self drainRealtimeCapture];
            [self flushRealtimeSecond];
            NSUInteger droppedCaptureBlocks; @synchronized(self) { droppedCaptureBlocks = self->_captureDroppedBlocks; }
            [self->_metadata addEntriesFromDictionary:@{ @"ended_at": ASUTC(), @"counters": [self snapshot], @"realtime_capture": @{ @"metrics_only": @YES, @"queue_capacity": @(ASCaptureRingCount), @"dropped_blocks": @(droppedCaptureBlocks) } }];
            [self writeJSON:self->_metadata toURL:[dir URLByAppendingPathComponent:@"ai-spatial-metadata.json"]];
            @synchronized(self) { self->_recording=NO; self->_state=@"Stopped"; }
            [self notify];
        });
    }
    [self notify];
}
- (void)enqueueBytes:(NSUInteger)bytes work:(void (^)(NSURL *dir,NSString *session))work {
    @synchronized(self) {
        if(!_recording || AISpatialMonotonicSeconds()>_deadline) return;
        if(_pending>=ASQueueEvents || _pendingBytes+bytes>ASQueueBytes) { _dropped++; return; }
        _pending++; _pendingBytes+=bytes; NSURL *dir=_sessionDirectory; NSString *session=_sessionID;
        dispatch_async(_writer,^{ @autoreleasepool { work(dir,session); } @synchronized(self) { self->_pending--; self->_pendingBytes-=bytes; } });
    }
}
- (void)recordStage:(NSString *)stage event:(NSString *)event fields:(NSDictionary *)fields {
    BOOL anomaly=[event containsString:@"warning"] || [event containsString:@"anomaly"] || [event containsString:@"error"];
    if(anomaly) @synchronized(self) { if([event containsString:@"error"]) _errors++; else _warnings++; }
    if(self.level==0 && !anomaly && ![event containsString:@"complete"] && ![event containsString:@"start"] && ![event containsString:@"unavailable"]) return;
    NSString *utc=ASUTC(); double time=AISpatialMonotonicSeconds(); NSDictionary *copy=[fields copy];
    [self enqueueBytes:4096 work:^(NSURL *dir,NSString *session) {
        NSMutableDictionary *record=[@{ @"session_id":session,@"stage":stage,@"event":event,@"timestamp":utc,@"monotonic_seconds":@(time) } mutableCopy]; [record addEntriesFromDictionary:copy];
        NSData *json=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        if(!json) { @synchronized(self) { self->_errors++; } return; }
        NSMutableData *line=[json mutableCopy]; [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [self append:line toURL:[dir URLByAppendingPathComponent:@"ai-spatial-diagnostics.log"]];
        [self append:line toURL:[dir URLByAppendingPathComponent:@"spatial-diagnostics.log"]];
    }];
}
- (void)recordWindow:(NSDictionary *)fields processed:(BOOL)processed {
    @synchronized(self) { if(processed) _processed++; else _skipped++; }
    [self recordStage:@"Stage 03 - Windowing and Buffering" event:processed ? @"window_complete" : @"window_error" fields:fields];
}
- (void)recordSecond:(NSDictionary *)fields {
    if(self.level==0) return;
    NSDictionary *copy=[fields copy];
    [self enqueueBytes:4096 work:^(NSURL *dir,NSString *session) {
        NSMutableDictionary *row=[copy mutableCopy]; row[@"session_id"]=session; NSMutableArray *columns=[NSMutableArray array];
        for(NSString *key in ASTimelineColumns()) [columns addObject:ASCSV(row[key])];
        NSData *data=[[[columns componentsJoinedByString:@","] stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        [self append:data toURL:[dir URLByAppendingPathComponent:@"ai-spatial-timeline.csv"]];
        [self append:data toURL:[dir URLByAppendingPathComponent:@"spatial-timeline.csv"]];
    }];
    [self recordStage:@"Stage 10 - Final PCM / Export" event:@"second_summary" fields:fields];
}
- (void)recordBinary:(NSData *)data kind:(NSString *)kind identifier:(NSString *)identifier offset:(NSUInteger)offset sampleRate:(double)rate channels:(NSUInteger)channels metadata:(NSDictionary *)metadata {
    if(self.level!=2 || !data.length) return;
    BOOL anomaly=[metadata[@"anomaly_neighborhood"] boolValue];
    if(!anomaly && (double)offset/MAX(rate,1)>5.0) return;
    @synchronized(self) { if(!_recording) return; if(_debugReserved+data.length>ASDebugLimit) { _dropped++; return; } _debugReserved+=data.length; }
    NSString *name=[NSString stringWithFormat:@"%@-%@.bin",kind,identifier];
    if([name containsString:@"/"] || [name containsString:@".."] || name.length>160) return;
    [self enqueueBytes:data.length work:^(NSURL *dir,NSString *session) {
        NSError *error=nil; NSURL *debug=[dir URLByAppendingPathComponent:@"debug"];
        [data writeToURL:[debug URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error];
        if(error) { @synchronized(self) { self->_errors++; } return; }
        NSMutableDictionary *meta=[metadata mutableCopy]; [meta addEntriesFromDictionary:@{ @"session_id":session,@"kind":kind,@"identifier":identifier,@"bytes":@(data.length),@"sample_rate":@(rate),@"channels":@(channels),@"offset_samples":@(offset),@"relative_time":@(offset/MAX(rate,1)),@"byte_order":@"little endian",@"sha256":AISpatialSHA256(data) }];
        [self writeJSON:meta toURL:[debug URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]]];
        @synchronized(self) { self->_debugWritten+=data.length; }
    }];
}
- (void)recordFile:(NSURL *)file kind:(NSString *)kind identifier:(NSString *)identifier metadata:(NSDictionary *)metadata {
    if(self.level!=AISpatialDiagnosticsLevelFullTrace || !file || !kind.length || !identifier.length) return;
    NSDictionary *attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:file.path error:nil];
    NSUInteger bytes=[attributes[NSFileSize] unsignedIntegerValue];
    if(!bytes || bytes>ASDebugLimit) { @synchronized(self) { _dropped++; } return; }
    NSString *name=[NSString stringWithFormat:@"%@-%@.%@",kind,identifier,file.pathExtension.length ? file.pathExtension : @"bin"];
    if([name containsString:@"/"] || [name containsString:@".."] || name.length>160) return;
    @synchronized(self) { if(!_recording || _debugReserved+bytes>ASDebugLimit) { _dropped++; return; } _debugReserved+=bytes; }
    NSDictionary *copyMetadata=[metadata copy] ?: @{};
    [self enqueueBytes:bytes work:^(NSURL *dir,NSString *session) {
        NSError *error=nil; NSURL *debug=[dir URLByAppendingPathComponent:@"debug"];
        [[NSFileManager defaultManager] removeItemAtURL:[debug URLByAppendingPathComponent:name] error:nil];
        if(![[NSFileManager defaultManager] copyItemAtURL:file toURL:[debug URLByAppendingPathComponent:name] error:&error]) { @synchronized(self) { self->_errors++; } return; }
        NSMutableDictionary *meta=[copyMetadata mutableCopy]; [meta addEntriesFromDictionary:@{ @"session_id":session, @"kind":kind, @"identifier":identifier, @"bytes":@(bytes), @"sha256":AISpatialSHA256([NSData dataWithContentsOfURL:file] ?: NSData.data) }];
        [self writeJSON:meta toURL:[debug URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]]];
        @synchronized(self) { self->_debugWritten+=bytes; }
    }];
}
- (void)updateMetadata:(NSDictionary *)metadata {
    NSDictionary *copy=[metadata copy]; [self enqueueBytes:4096 work:^(NSURL *dir,NSString *session) { [self->_metadata addEntriesFromDictionary:copy]; [self writeJSON:self->_metadata toURL:[dir URLByAppendingPathComponent:@"ai-spatial-metadata.json"]]; }];
}
static NSData *ASSpatialWAV(const float *left, const float *right, NSUInteger frames, double rate) {
    if (!left || !right || !frames || rate <= 0) return nil;
    NSUInteger payload=frames*2*sizeof(float); NSMutableData *data=[NSMutableData dataWithLength:44+payload];
    uint8_t *p=data.mutableBytes; memcpy(p,"RIFF",4); uint32_t riff=(uint32_t)(36+payload); memcpy(p+4,&riff,4); memcpy(p+8,"WAVEfmt ",8);
    uint32_t fmtSize=16; uint16_t format=3, channels=2, bits=32, block=8; uint32_t hz=(uint32_t)llround(rate), bytesPerSec=hz*block;
    memcpy(p+16,&fmtSize,4); memcpy(p+20,&format,2); memcpy(p+22,&channels,2); memcpy(p+24,&hz,4); memcpy(p+28,&bytesPerSec,4); memcpy(p+32,&block,2); memcpy(p+34,&bits,2); memcpy(p+36,"data",4); uint32_t size=(uint32_t)payload; memcpy(p+40,&size,4);
    float *samples=(float *)(p+44); for(NSUInteger i=0;i<frames;i++){samples[i*2]=left[i];samples[i*2+1]=right[i];} return data;
}
- (void)writeSpatialClipsToDirectory:(NSURL *)dir {
    if (self.level != AISpatialDiagnosticsLevelFullTrace) return;
    NSUInteger frames=MIN((NSUInteger)atomic_load_explicit(&gSpatialClipCursor,memory_order_acquire),(NSUInteger)ASSpatialClipMaxFrames); if (!frames) return;
    uint32_t bits=atomic_load_explicit(&gSpatialClipRateBits,memory_order_acquire); float ratef=0; memcpy(&ratef,&bits,sizeof(ratef)); if (ratef<=0) ratef=48000;
    NSURL *clips=[dir URLByAppendingPathComponent:@"spatial-clips" isDirectory:YES]; [[NSFileManager defaultManager] createDirectoryAtURL:clips withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *original=ASSpatialWAV(gSpatialOriginalClip[0],gSpatialOriginalClip[1],frames,ratef), *spatial=ASSpatialWAV(gSpatialProcessedClip[0],gSpatialProcessedClip[1],frames,ratef);
    if (!original || !spatial) return;
    NSMutableData *difference=[NSMutableData dataWithLength:frames*2*sizeof(float)]; float *d=difference.mutableBytes; for(NSUInteger i=0;i<frames;i++){d[i*2]=gSpatialProcessedClip[0][i]-gSpatialOriginalClip[0][i];d[i*2+1]=gSpatialProcessedClip[1][i]-gSpatialOriginalClip[1][i];}
    NSData *foreground=difference;
    [original writeToURL:[clips URLByAppendingPathComponent:@"Original.wav"] options:NSDataWritingAtomic error:nil]; [spatial writeToURL:[clips URLByAppendingPathComponent:@"Spatial.wav"] options:NSDataWritingAtomic error:nil]; [difference writeToURL:[clips URLByAppendingPathComponent:@"Difference.wav"] options:NSDataWritingAtomic error:nil]; [foreground writeToURL:[clips URLByAppendingPathComponent:@"Event-Foreground.wav"] options:NSDataWritingAtomic error:nil];
}
- (void)finishTestWithMetadata:(NSDictionary *)metadata {
    [self updateMetadata:metadata]; [self recordStage:@"Stage 10 - Final PCM / Export" event:@"test_complete" fields:metadata];
    @synchronized(self) { _finished=YES; _state=@"Test complete"; }
    [self stopRecording]; [self notify];
}
- (void)clearLogs {
    [self stopRecording];
    @synchronized(self) {
        dispatch_async(_writer,^{ [[NSFileManager defaultManager] removeItemAtPath:ASRoot() error:nil]; });
        _sessionDirectory=nil; _sessionID=nil; _state=@"Cleared"; _logBytes=_debugWritten=_dropped=_captureDroppedBlocks=_processed=_skipped=_warnings=_errors=0;
    }
    [self notify];
}
- (void)exportReportIncludingDebug:(BOOL)debug completion:(void (^)(NSArray<NSURL *> *,NSError *))completion {
    NSURL *dir=self.sessionDirectory;
    if(!dir) { completion(nil,[NSError errorWithDomain:@"AISpatialDiagnostics" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Run a diagnostic test first."}]); return; }
    dispatch_async(_writer,^{
        NSMutableArray *files=[NSMutableArray array]; NSError *error=nil;
        // Reports contain no paths, user file names, PCM, tokens or tensor values.
        NSDictionary *snapshot=[self snapshot]; self->_metadata[@"counters"]=snapshot;
        [self writeJSON:self->_metadata toURL:[dir URLByAppendingPathComponent:@"ai-spatial-metadata.json"]];
        [self writeJSON:self->_metadata toURL:[dir URLByAppendingPathComponent:@"spatial-summary.json"]];
        [self writeSpatialClipsToDirectory:dir];
        for(NSString *name in @[@"ai-spatial-diagnostics.log",@"spatial-diagnostics.log",@"ai-spatial-timeline.csv",@"spatial-timeline.csv",@"ai-spatial-metadata.json",@"spatial-summary.json",@"accent-events.jsonl",@"spatial-events.jsonl",@"accent-events.csv"]) {
            NSURL *url=[dir URLByAppendingPathComponent:name]; if([[NSFileManager defaultManager] fileExistsAtPath:url.path]) [files addObject:url];
        }
        NSURL *clips=[dir URLByAppendingPathComponent:@"spatial-clips" isDirectory:YES];
        for (NSURL *url in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:clips includingPropertiesForKeys:nil options:0 error:nil]) if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) [files addObject:url];
        if(debug) {
            NSMutableArray *paths=[NSMutableArray array], *names=[NSMutableArray array];
            for(NSURL *url in files) { [paths addObject:url]; [names addObject:url.lastPathComponent]; }
            NSURL *debugDir=[dir URLByAppendingPathComponent:@"debug"];
            for(NSURL *url in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:debugDir includingPropertiesForKeys:nil options:0 error:nil]) {
                [paths addObject:url]; [names addObject:[@"debug" stringByAppendingPathComponent:url.lastPathComponent]];
            }
            const char **cPaths=calloc(paths.count,sizeof(char *)), **cNames=calloc(names.count,sizeof(char *));
            if(cPaths && cNames) {
                for(NSUInteger i=0;i<paths.count;i++) { cPaths[i]=[paths[i] fileSystemRepresentation]; cNames[i]=[names[i] UTF8String]; }
                NSURL *zip=[dir URLByAppendingPathComponent:@"ai-spatial-debug.zip"];
                if(ASZipCreate(zip.fileSystemRepresentation,cPaths,cNames,paths.count)) { [files removeAllObjects]; [files addObject:zip]; }
                else error=[NSError errorWithDomain:@"AISpatialDiagnostics" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Debug archive creation failed."}];
            } else error=[NSError errorWithDomain:@"AISpatialDiagnostics" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Not enough memory for archive index."}];
            free(cPaths); free(cNames);
        }
        dispatch_async(dispatch_get_main_queue(),^{ completion(error ? nil : files,error); });
    });
}
@end
