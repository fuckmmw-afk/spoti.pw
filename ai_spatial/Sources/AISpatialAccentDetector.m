#import "AISpatialAccentDetector.h"
#import "AISpatialAccentCore.h"
#import "AISpatialDiagnostics.h"
#import "AISpatialLog.h"
#import <math.h>
#import <stdatomic.h>
#import <string.h>
#import <stdlib.h>

static const NSUInteger kAccentFeatureHopMilliseconds = 20;
static const NSUInteger kAccentMaxEvents = 512;
static NSString *const kAccentEnabledKey = @"pw.chroma.ai-spatial.accent-enabled";

@interface AISpatialAccentDetector () {
    dispatch_queue_t _analysisQueue;
    dispatch_queue_t _writerQueue;
    BOOL _enabled;
    uint64_t _epoch;
    BOOL _hasEpoch;
    NSUInteger _pending;
    uint64_t _eventCounter;
    NSString *_sessionID;
    NSMutableArray<NSDictionary *> *_events;
    NSMutableDictionary<NSString *, NSString *> *_manualLabels;
    ASAccentCoreContext _vocalContext;
    ASAccentCoreContext _instrumentalContext;
    NSUInteger _candidateCount;
    NSUInteger _selectedCount;
    NSUInteger _rejectedCount;
    NSUInteger _droppedBlocks;
    NSUInteger _cancelledEvents;
    double _processingTotal;
    NSUInteger _processingCount;
}
@end

static NSString *ASAccentDocumentsDirectory(void) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [base URLByAppendingPathComponent:@"AI Spatial/Accent" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir.path;
}

static NSString *ASAccentSessionID(void) {
    return [NSUUID UUID].UUIDString.lowercaseString;
}

@implementation AISpatialAccentDetector

+ (instancetype)sharedDetector {
    static AISpatialAccentDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ detector = [AISpatialAccentDetector new]; });
    return detector;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    [NSUserDefaults.standardUserDefaults registerDefaults:@{kAccentEnabledKey: @YES}];
    _enabled = [NSUserDefaults.standardUserDefaults boolForKey:kAccentEnabledKey];
    _analysisQueue = dispatch_queue_create("pw.chroma.ai-spatial.accent-analysis", DISPATCH_QUEUE_SERIAL);
    _writerQueue = dispatch_queue_create("pw.chroma.ai-spatial.accent-writer", DISPATCH_QUEUE_SERIAL);
    _sessionID = ASAccentSessionID();
    _events = [NSMutableArray arrayWithCapacity:kAccentMaxEvents];
    _manualLabels = [NSMutableDictionary dictionary];
    ASAccentCoreReset(&_vocalContext); ASAccentCoreReset(&_instrumentalContext);
    return self;
}

- (BOOL)enabled { @synchronized(self) { return _enabled; } }

- (void)setEnabled:(BOOL)enabled {
    @synchronized(self) { _enabled = enabled; }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kAccentEnabledKey];
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:enabled ? @"analysis_enabled" : @"analysis_disabled" fields:@{ @"reason": @"user_setting", @"engine": @"hybrid_acoustic_context" }];
}

- (void)reset {
    dispatch_async(_analysisQueue, ^{ @autoreleasepool {
        @synchronized(self) {
            self->_hasEpoch = NO; self->_epoch = 0; self->_events = [NSMutableArray arrayWithCapacity:kAccentMaxEvents];
            self->_candidateCount = self->_selectedCount = self->_rejectedCount = 0;
            self->_cancelledEvents = 0;
        }
        ASAccentCoreReset(&self->_vocalContext); ASAccentCoreReset(&self->_instrumentalContext);
        [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:@"schedule_reset" fields:@{ @"reason": @"explicit_stream_reset", @"stale_events": @"discarded" }];
    }});
}

- (void)resetForEpoch:(uint64_t)epoch start:(uint64_t)start rate:(double)rate {
    if (_hasEpoch && _epoch == epoch) return;
    if (_hasEpoch) _cancelledEvents += _events.count;
    _hasEpoch = YES; _epoch = epoch; _events = [NSMutableArray arrayWithCapacity:kAccentMaxEvents];
    ASAccentCoreReset(&_vocalContext); ASAccentCoreReset(&_instrumentalContext);
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:@"stream_epoch_reset" fields:@{
        @"stream_epoch": @(epoch), @"start_sample": @(start), @"sample_rate": @(rate), @"reason": @"track/seek/route boundary; prior schedule invalidated"
    }];
}

- (void)submitEpoch:(uint64_t)epoch windowID:(uint64_t)windowID startSample:(uint64_t)startSample sampleRate:(double)rate frames:(const ASStreamOutput *)frames count:(size_t)count availableSample:(uint64_t)availableSample {
    if (!frames || !count || rate <= 0 || !self.enabled) return;
    @synchronized(self) {
        if (_pending >= 8) { _droppedBlocks++; [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:@"analysis_overload" fields:@{ @"stream_epoch": @(epoch), @"window_id": @(windowID), @"reason": @"bounded_analysis_queue_full; optional detail dropped" }]; return; }
        _pending++;
    }
    ASStreamOutput *copy = calloc(count, sizeof(*copy));
    if (!copy) { @synchronized(self) { _pending--; _droppedBlocks++; } return; }
    memcpy(copy, frames, count * sizeof(*copy));
    dispatch_async(_analysisQueue, ^{ @autoreleasepool {
        double began = CFAbsoluteTimeGetCurrent();
        [self resetForEpoch:epoch start:startSample rate:rate];
        NSUInteger hop = MAX(1, (NSUInteger)llround(rate * kAccentFeatureHopMilliseconds / 1000.0));
        NSUInteger featureCount = (count + hop - 1) / hop;
        ASAccentFrame *vocal = calloc(featureCount, sizeof(*vocal));
        ASAccentFrame *instrumental = calloc(featureCount, sizeof(*instrumental));
        if (!vocal || !instrumental) { free(vocal); free(instrumental); free(copy); @synchronized(self) { self->_pending--; self->_droppedBlocks++; } return; }
        for (NSUInteger i = 0; i < featureCount; i++) {
            NSUInteger begin = i * hop, end = MIN(count, begin + hop), length = end - begin;
            double v2 = 0, i2 = 0, vf = 0, inf = 0; float vp = 0, ip = 0, vh = 0, ih = 0;
            for (NSUInteger j = begin; j < end; j++) {
                const ASStreamOutput f = copy[j];
                float va = .5f * (fabsf(f.vl) + fabsf(f.vr)), ia = .5f * (fabsf(f.il) + fabsf(f.ir));
                float vd = j > begin ? .5f * (fabsf(f.vl - copy[j - 1].vl) + fabsf(f.vr - copy[j - 1].vr)) : 0;
                float id = j > begin ? .5f * (fabsf(f.il - copy[j - 1].il) + fabsf(f.ir - copy[j - 1].ir)) : 0;
                v2 += (double)f.vl * f.vl + (double)f.vr * f.vr; i2 += (double)f.il * f.il + (double)f.ir * f.ir;
                vf += vd; inf += id; vp = fmaxf(vp, va); ip = fmaxf(ip, ia); vh += vd; ih += id;
            }
            ASStreamOutput anchor = copy[begin];
            vocal[i] = (ASAccentFrame){ anchor.sample, sqrtf((float)(v2 / MAX((NSUInteger)1, length * 2))), vp, (float)(vf / MAX((NSUInteger)1, length)), vh / MAX((NSUInteger)1, length) };
            instrumental[i] = (ASAccentFrame){ anchor.sample, sqrtf((float)(i2 / MAX((NSUInteger)1, length * 2))), ip, (float)(inf / MAX((NSUInteger)1, length)), ih / MAX((NSUInteger)1, length) };
        }
        ASAccentCoreEvent ve[32], ie[32];
        uint64_t latency = (uint64_t)llround(rate * AS_STREAM_DELAY_SECONDS);
        size_t vn = ASAccentCoreAnalyze(vocal, featureCount, rate, hop, ASAccentSourceVocal, availableSample, latency, &self->_vocalContext, ve, 32);
        size_t in = ASAccentCoreAnalyze(instrumental, featureCount, rate, hop, ASAccentSourceInstrumental, availableSample, latency, &self->_instrumentalContext, ie, 32);
        for (size_t i = 0; i < vn; i++) [self recordCoreEvent:ve[i] epoch:epoch windowID:windowID rate:rate availableSample:availableSample latency:latency frames:vocal featureCount:featureCount began:began];
        for (size_t i = 0; i < in; i++) [self recordCoreEvent:ie[i] epoch:epoch windowID:windowID rate:rate availableSample:availableSample latency:latency frames:instrumental featureCount:featureCount began:began];
        free(vocal); free(instrumental); free(copy);
        @synchronized(self) { self->_pending--; }
    }});
}

- (void)recordCoreEvent:(ASAccentCoreEvent)event epoch:(uint64_t)epoch windowID:(uint64_t)windowID rate:(double)rate availableSample:(uint64_t)availableSample latency:(uint64_t)latency frames:(const ASAccentFrame *)frames featureCount:(NSUInteger)featureCount began:(double)began {
    NSUInteger nearest = 0;
    uint64_t center = event.start_sample + (event.end_sample - event.start_sample) / 3;
    for (NSUInteger i = 1; i < featureCount; i++) if (llabs((long long)frames[i].sample - (long long)center) < llabs((long long)frames[nearest].sample - (long long)center)) nearest = i;
    ASAccentFrame feature = frames[nearest];
    NSString *eventID;
    NSDictionary *record;
    @synchronized(self) {
        eventID = [NSString stringWithFormat:@"accent-%@-%llu-%llu", _sessionID, epoch, ++_eventCounter];
        uint64_t safety = (uint64_t)llround(rate * .10);
        uint64_t deadline = event.end_sample + latency;
        if (deadline > safety) deadline -= safety; else deadline = 0;
        NSString *decision = event.selected ? @"selected" : @"rejected";
        NSString *type = [NSString stringWithUTF8String:ASAccentTypeName((ASAccentType)event.type)];
        record = @{
            @"event_id": eventID, @"session_id": _sessionID, @"stream_epoch": @(epoch), @"window_id": @(windowID),
            @"source": event.source == ASAccentSourceVocal ? @"vocals" : @"instrumental", @"type": type,
            @"sample_rate_hz": @(rate), @"start_sample": @(event.start_sample), @"end_sample": @(event.end_sample), @"start_time_seconds": @((double)event.start_sample / rate), @"end_time_seconds": @((double)event.end_sample / rate), @"duration_samples": @(event.end_sample - event.start_sample), @"duration_seconds": @((double)(event.end_sample - event.start_sample) / rate),
            @"classification_confidence": @(event.confidence), @"expressiveness_score": @(event.expressiveness), @"priority": @(event.priority),
            @"decision": decision, @"decision_reason": [NSString stringWithUTF8String:event.reason],
            @"ready_deadline_sample": @(deadline), @"ready_deadline_time_seconds": @((double)deadline / rate),
            @"available_sample_at_detection": @(availableSample), @"detected_monotonic_seconds": @(AISpatialMonotonicSeconds()), @"detection_latency_ms": @((AISpatialMonotonicSeconds() - began) * 1000.0),
            @"feature_rms": @(feature.rms), @"feature_peak": @(feature.peak), @"feature_flux": @(feature.flux), @"feature_high_frequency": @(feature.high_frequency),
            @"rhythmic_position_seconds": @((double)event.start_sample / rate), @"rhythmic_frame_phase": @(nearest % 4), @"deadline_status": strcmp(event.reason, "late_deadline") == 0 ? @"missed" : @"within_budget", @"analysis": @"adaptive envelope + flux + context ranking; no lyric dependency"
        };
        [_events addObject:record]; if (_events.count > kAccentMaxEvents) [_events removeObjectAtIndex:0];
        _candidateCount++; event.selected ? _selectedCount++ : _rejectedCount++;
        _processingCount++; _processingTotal += [record[@"detection_latency_ms"] doubleValue];
    }
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:event.selected ? @"event_selected" : @"event_rejected" fields:record];
    [self appendEventRecord:record];
}

- (void)appendEventRecord:(NSDictionary *)record {
    NSDictionary *copy = [record copy];
    dispatch_async(_writerQueue, ^{ @autoreleasepool {
        NSString *directory = AISpatialDiagnostics.sharedDiagnostics.sessionDirectory.path ?: ASAccentDocumentsDirectory();
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *jsonPath = [directory stringByAppendingPathComponent:@"accent-events.jsonl"];
        NSData *json = [NSJSONSerialization dataWithJSONObject:copy options:0 error:nil];
        if (json) { NSMutableData *line = [json mutableCopy]; [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:jsonPath]; if (!handle) { [line writeToFile:jsonPath atomically:YES]; } else { [handle seekToEndOfFile]; [handle writeData:line]; [handle closeFile]; } }
        NSString *csvPath = [directory stringByAppendingPathComponent:@"accent-events.csv"];
        if (![NSFileManager.defaultManager fileExistsAtPath:csvPath]) [@"event_id,session_id,stream_epoch,sample_rate_hz,source,type,start_sample,end_sample,start_time_seconds,end_time_seconds,confidence,expressiveness,priority,decision,reason,deadline_sample,deadline_status\n" writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *(^q)(id) = ^NSString *(id value) { NSString *s = [value description] ?: @""; return [NSString stringWithFormat:@"\"%@\"", [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]]; };
        NSString *row = [NSString stringWithFormat:@"%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@,%@\n", q(copy[@"event_id"]), q(copy[@"session_id"]), copy[@"stream_epoch"], copy[@"sample_rate_hz"], q(copy[@"source"]), q(copy[@"type"]), copy[@"start_sample"], copy[@"end_sample"], copy[@"start_time_seconds"], copy[@"end_time_seconds"], copy[@"classification_confidence"], copy[@"expressiveness_score"], copy[@"priority"], q(copy[@"decision"]), q(copy[@"decision_reason"]), copy[@"ready_deadline_sample"], q(copy[@"deadline_status"] )];
        NSFileHandle *csv = [NSFileHandle fileHandleForWritingAtPath:csvPath]; if (csv) { [csv seekToEndOfFile]; [csv writeData:[row dataUsingEncoding:NSUTF8StringEncoding]]; [csv closeFile]; }
    }});
}

- (NSDictionary *)snapshot {
    @synchronized(self) {
        NSMutableDictionary *types = [NSMutableDictionary dictionary];
        for (NSDictionary *event in _events) { NSString *type = event[@"type"]; types[type] = @([types[type] unsignedIntegerValue] + 1); }
        return @{ @"enabled": @(_enabled), @"session_id": _sessionID, @"stream_epoch": _hasEpoch ? @(_epoch) : @"none", @"candidates": @(_candidateCount), @"selected": @(_selectedCount), @"rejected": @(_rejectedCount), @"cancelled_stale_events": @(_cancelledEvents), @"dropped_analysis_blocks": @(_droppedBlocks), @"analysis_queue_depth": @(_pending), @"processing_avg_ms": _processingCount ? @(_processingTotal / _processingCount) : @0, @"type_distribution": types, @"manual_labels": [_manualLabels copy], @"policy": @{ @"target_density_per_minute": @"3-10 on dense material, advisory", @"minimum_interval_seconds": @0.35, @"max_selected_per_minute": @10, @"selection": @"rarity + contrast + novelty + context; repeated hits suppressed" } };
    }
}

- (NSArray<NSDictionary *> *)recentEvents {
    @synchronized(self) { return [_events copy]; }
}

- (void)setManualLabel:(NSString *)label forEventID:(NSString *)eventID {
    if (!label.length || !eventID.length) return;
    @synchronized(self) { _manualLabels[eventID] = label; }
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:@"manual_review" fields:@{ @"event_id": eventID, @"manual_label": label }];
}

- (void)recordManualMissedAtSample:(NSString *)sampleText source:(NSString *)source {
    [AISpatialDiagnostics.sharedDiagnostics recordStage:@"Accent Trace" event:@"manual_review" fields:@{ @"manual_label": @"missed", @"sample": sampleText ?: @"unknown", @"source": source ?: @"unknown", @"review_status": @"user_reported_missing_event" }];
}

- (NSArray<NSURL *> *)exportFiles:(NSError **)error {
    dispatch_sync(_writerQueue, ^{});
    NSString *directory = AISpatialDiagnostics.sharedDiagnostics.sessionDirectory.path ?: ASAccentDocumentsDirectory();
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSString *stamp = [NSString stringWithFormat:@"accent-export-%@", @((long long)(NSDate.date.timeIntervalSince1970 * 1000))];
    NSURL *out = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:stamp] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:out withIntermediateDirectories:YES attributes:nil error:error];
    for (NSString *name in @[@"accent-events.jsonl", @"accent-events.csv"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) { NSURL *dest = [out URLByAppendingPathComponent:name]; if (![NSFileManager.defaultManager copyItemAtPath:path toPath:dest.path error:error]) return nil; [files addObject:dest]; }
    }
    NSData *summary = [NSJSONSerialization dataWithJSONObject:self.snapshot options:NSJSONWritingPrettyPrinted error:error];
    if (summary) { NSURL *url = [out URLByAppendingPathComponent:@"accent-summary.json"]; if (![summary writeToURL:url options:NSDataWritingAtomic error:error]) return nil; [files addObject:url]; }
    if (!files.count && error) *error = [NSError errorWithDomain:@"AISpatialAccent" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No Accent Trace events are available yet."}];
    return files.count ? files : nil;
}

@end

void ASAccentDetectorSetEnabled(BOOL enabled) { [AISpatialAccentDetector.sharedDetector setEnabled:enabled]; }
BOOL ASAccentDetectorIsEnabled(void) { return AISpatialAccentDetector.sharedDetector.enabled; }
void ASAccentDetectorReset(void) { [AISpatialAccentDetector.sharedDetector reset]; }
void ASAccentDetectorSubmit(uint64_t epoch, uint64_t windowID, uint64_t startSample, double rate, const ASStreamOutput *frames, size_t count, uint64_t availableSample) { [AISpatialAccentDetector.sharedDetector submitEpoch:epoch windowID:windowID startSample:startSample sampleRate:rate frames:frames count:count availableSample:availableSample]; }
NSDictionary *ASAccentDetectorSnapshot(void) { return AISpatialAccentDetector.sharedDetector.snapshot; }
NSArray<NSDictionary *> *ASAccentDetectorRecentEvents(NSUInteger limit) { NSArray *events = AISpatialAccentDetector.sharedDetector.recentEvents; if (limit && events.count > limit) return [events subarrayWithRange:NSMakeRange(events.count - limit, limit)]; return events; }
void ASAccentDetectorSetManualLabel(NSString *eventID, NSString *label) { [AISpatialAccentDetector.sharedDetector setManualLabel:label forEventID:eventID]; }
void ASAccentDetectorRecordManualMissed(NSString *sampleText, NSString *source) { [AISpatialAccentDetector.sharedDetector recordManualMissedAtSample:sampleText source:source]; }
NSArray<NSURL *> *ASAccentDetectorExport(NSError **error) { return [AISpatialAccentDetector.sharedDetector exportFiles:error]; }
