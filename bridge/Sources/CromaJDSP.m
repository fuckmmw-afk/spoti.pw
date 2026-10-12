#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import "SGRebind.h"
#import "SGDSPEngine.h"

// Croma already ships the Audio effects page and writes the same preference keys as Spoti.pw.
// This bridge supplies only the missing render engine, so it can be loaded alongside the existing tweak.
static NSString *const kMaster = @"spotifyglass.dsp";
static NSString *const kPostGain = @"spotifyglass.dsp.postGain";
static NSString *const kLimiterThreshold = @"spotifyglass.dsp.limiterThreshold";
static NSString *const kLimiterRelease = @"spotifyglass.dsp.limiterRelease";
static NSString *const kCompander = @"spotifyglass.dsp.compander";
static NSString *const kCompanderTime = @"spotifyglass.dsp.compander.time";
static NSString *const kCompanderGranularity = @"spotifyglass.dsp.compander.granularity";
static NSString *const kCompanderTransform = @"spotifyglass.dsp.compander.transform";
static NSString *const kCompanderGains = @"spotifyglass.dsp.compander.gains";
static NSString *const kBass = @"spotifyglass.dsp.bass";
static NSString *const kBassGain = @"spotifyglass.dsp.bass.gain";
static NSString *const kEQ = @"spotifyglass.dsp.eq";
static NSString *const kEQFilter = @"spotifyglass.dsp.eq.filter";
static NSString *const kEQInterpolation = @"spotifyglass.dsp.eq.interpolation";
static NSString *const kEQGains = @"spotifyglass.dsp.eq.gains";
static NSString *const kGEQ = @"spotifyglass.dsp.geq";
static NSString *const kGEQNodes = @"spotifyglass.dsp.geq.nodes";
static NSString *const kConvolver = @"spotifyglass.dsp.convolver";
static NSString *const kConvolverFile = @"spotifyglass.dsp.convolver.file";
static NSString *const kConvolverMode = @"spotifyglass.dsp.convolver.mode";
static NSString *const kConvolverWaveEdit = @"spotifyglass.dsp.convolver.waveEdit";
static NSString *const kDDC = @"spotifyglass.dsp.ddc";
static NSString *const kDDCFile = @"spotifyglass.dsp.ddc.file";
static NSString *const kLiveprog = @"spotifyglass.dsp.liveprog";
static NSString *const kLiveprogFile = @"spotifyglass.dsp.liveprog.file";
static NSString *const kReverb = @"spotifyglass.dsp.reverb";
static NSString *const kReverbPreset = @"spotifyglass.dsp.reverb.preset";
static NSString *const kWide = @"spotifyglass.dsp.wide";
static NSString *const kWideLevel = @"spotifyglass.dsp.wide.level";
static NSString *const kCrossfeed = @"spotifyglass.dsp.crossfeed";
static NSString *const kCrossfeedMode = @"spotifyglass.dsp.crossfeed.mode";
static NSString *const kTube = @"spotifyglass.dsp.tube";
static NSString *const kTubeDrive = @"spotifyglass.dsp.tube.drive";

static _Atomic(SGDSPEngine *) gEngine;
static atomic_bool gEnabled;
static atomic_uint_fast64_t gLayout;
static atomic_uint_fast64_t gRateBits;
static dispatch_queue_t gConfigQueue;
static OSStatus (*gAudioOutputUnitStart)(AudioUnit);
// Optional AI Spatial bridge.  It is resolved dynamically so the JamesDSP
// dylib remains usable when the AI tweak is absent or its model is unavailable.
typedef void (*AISpatialLiveProcessFn)(float *left, float *right, UInt32 frames, double sampleRate, const AudioTimeStamp *timestamp);
typedef void (*AISpatialLiveResetFn)(double sampleRate);
static _Atomic(AISpatialLiveProcessFn) gAISpatialLiveProcess;
static _Atomic(AISpatialLiveResetFn) gAISpatialLiveReset;
// The AI tweak can use its own post-render observer as a compatibility
// fallback when this bridge was not loaded or Spotify no longer imports
// AudioOutputUnitStart.  Export a small readiness query so the two observers
// do not process the same block twice when both hooks are present.
__attribute__((visibility("default"), used)) BOOL CromaJDSPAIStreamingBridgeActive(void) {
    uint64_t rateBits = atomic_load_explicit(&gRateBits, memory_order_acquire);
    double rate = 0;
    memcpy(&rate, &rateBits, sizeof(rate));
    return gAudioOutputUnitStart != NULL && rate > 0 && atomic_load_explicit(&gAISpatialLiveProcess, memory_order_acquire) != NULL;
}
static void *resolveAISpatialSymbol(const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol) return symbol;
    // Injected tweaks may be loaded RTLD_LOCAL, so RTLD_DEFAULT is not
    // guaranteed to see an exported symbol from aispatial.dylib. Resolve the
    // already-loaded image explicitly during startup/format setup (never from
    // the render callback).
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, "aispatial")) continue;
        void *handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) continue;
        symbol = dlsym(handle, name);
        if (symbol) return symbol;
    }
    return NULL;
}
static void resolveAISpatialBridge(void) {
    AISpatialLiveProcessFn process = atomic_load_explicit(&gAISpatialLiveProcess, memory_order_acquire);
    if (!process) {
        process = (AISpatialLiveProcessFn)resolveAISpatialSymbol("AISpatialLiveProcessStereo");
        if (process) atomic_store_explicit(&gAISpatialLiveProcess, process, memory_order_release);
    }
    AISpatialLiveResetFn reset = atomic_load_explicit(&gAISpatialLiveReset, memory_order_acquire);
    if (!reset) {
        reset = (AISpatialLiveResetFn)resolveAISpatialSymbol("AISpatialLiveReset");
        if (reset) atomic_store_explicit(&gAISpatialLiveReset, reset, memory_order_release);
    }
}
// The JamesDSP setters rebuild filter state.  Reapplying them from the polling timer
// clears bass delay lines and causes an audible thump, so remember the last settings.
static NSString *gAppliedSettings;
static BOOL gAppliedEnabled;
static BOOL gHasAppliedEnabled;

static NSArray<NSString *> *settingsKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            kMaster, kPostGain, kLimiterThreshold, kLimiterRelease,
            kCompander, kCompanderTime, kCompanderGranularity, kCompanderTransform, kCompanderGains,
            kBass, kBassGain, kEQ, kEQFilter, kEQInterpolation, kEQGains,
            kGEQ, kGEQNodes, kConvolver, kConvolverFile, kConvolverMode, kConvolverWaveEdit,
            kDDC, kDDCFile, kLiveprog, kLiveprogFile, kReverb, kReverbPreset,
            kWide, kWideLevel, kCrossfeed, kCrossfeedMode, kTube, kTubeDrive,
        ];
    });
    return keys;
}

static NSString *settingsSignature(NSUserDefaults *defaults) {
    NSMutableString *signature = [NSMutableString string];
    for (NSString *key in settingsKeys()) {
        id value = [defaults objectForKey:key];
        [signature appendFormat:@"%@=%@\n", key, value ? [value description] : @"<nil>"];
    }
    return signature;
}

static double getDouble(NSUserDefaults *defaults, NSString *key, double fallback) {
    id value = [defaults objectForKey:key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static BOOL getBool(NSUserDefaults *defaults, NSString *key) {
    id value = [defaults objectForKey:key];
    return value ? [value boolValue] : NO;
}

static NSArray<NSNumber *> *getGains(NSUserDefaults *defaults, NSString *key, NSUInteger count) {
    id value = [defaults objectForKey:key];
    if ([value isKindOfClass:NSArray.class]) return value;
    if (![value isKindOfClass:NSString.class]) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (NSString *part in [(NSString *)value componentsSeparatedByString:@";"]) {
        if (part.length) [result addObject:@(part.doubleValue)];
    }
    while (result.count < count) [result addObject:@0];
    return result;
}

static NSString *libraryPath(NSString *kind, NSString *name) {
    if (!name.length) return nil;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // Imported Android settings can contain "DDC/" or "Liveprog/" already.
    name = name.lastPathComponent;
    return [[documents stringByAppendingPathComponent:@"spoti.pw/JamesDSP"] stringByAppendingPathComponent:
            [kind stringByAppendingPathComponent:name]];
}

static void readGains(NSUserDefaults *defaults, NSString *key, double *out, NSUInteger count) {
    NSArray *values = getGains(defaults, key, count);
    for (NSUInteger i = 0; i < count; i++) out[i] = i < values.count ? [values[i] doubleValue] : 0;
}

static void applySettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL enabled = getBool(defaults, (NSString *)kMaster);
    atomic_store_explicit(&gEnabled, enabled, memory_order_release);
    SGDSPEngine *engine = atomic_load_explicit(&gEngine, memory_order_acquire);
    if (!engine) return;
    BOOL enabledChanged = !gHasAppliedEnabled || gAppliedEnabled != enabled;
    NSString *signature = settingsSignature(defaults);
    if (gAppliedSettings && [gAppliedSettings isEqualToString:signature]) return;

    SGDSPEngineSetOutput(engine, getDouble(defaults, (NSString *)kPostGain, 0),
                         getDouble(defaults, (NSString *)kLimiterThreshold, -0.1),
                         getDouble(defaults, (NSString *)kLimiterRelease, 60));

    double compander[7], eq[15];
    readGains(defaults, (NSString *)kCompanderGains, compander, 7);
    SGDSPEngineSetCompander(engine, getBool(defaults, (NSString *)kCompander),
                            getDouble(defaults, (NSString *)kCompanderTime, 0.22),
                            (int)getDouble(defaults, (NSString *)kCompanderGranularity, 2),
                            (int)getDouble(defaults, (NSString *)kCompanderTransform, 0),
                            (double[]){95, 180, 350, 700, 1400, 3000, 7500}, compander);
    SGDSPEngineSetBassBoost(engine, getBool(defaults, (NSString *)kBass), getDouble(defaults, (NSString *)kBassGain, 0));
    readGains(defaults, (NSString *)kEQGains, eq, 15);
    SGDSPEngineSetEqualizer(engine, getBool(defaults, (NSString *)kEQ),
                            (int)getDouble(defaults, (NSString *)kEQFilter, 0),
                            (int)getDouble(defaults, (NSString *)kEQInterpolation, 0),
                            (double[]){25,40,63,100,160,250,400,630,1000,1600,2500,4000,6300,10000,16000}, eq);

    NSString *nodes = [defaults objectForKey:(NSString *)kGEQNodes];
    if (![nodes isKindOfClass:NSString.class]) nodes = @"GraphicEQ: 0.0 0.0;";
    char error[256] = {0};
    SGDSPEngineSetGraphicEq(engine, getBool(defaults, (NSString *)kGEQ), nodes.UTF8String, error, sizeof error);
    NSString *convolverName = [defaults objectForKey:kConvolverFile];
    NSString *convolverPath = libraryPath(@"Convolver", convolverName);
    NSString *waveEdit = [defaults objectForKey:kConvolverWaveEdit];
    SGDSPEngineSetConvolver(engine, getBool(defaults, kConvolver) && convolverPath.length, convolverPath.UTF8String,
                            (int)getDouble(defaults, kConvolverMode, 0),
                            [waveEdit isKindOfClass:NSString.class] ? waveEdit.UTF8String : "-80;-100;0;0;0;0",
                            error, sizeof error);
    NSString *ddcName = [defaults objectForKey:kDDCFile];
    NSString *ddcText = [NSString stringWithContentsOfFile:libraryPath(@"DDC", ddcName) encoding:NSUTF8StringEncoding error:nil];
    SGDSPEngineSetDDC(engine, getBool(defaults, kDDC) && ddcText.length, ddcText.UTF8String, error, sizeof error);
    NSString *liveprogName = [defaults objectForKey:kLiveprogFile];
    NSString *liveprogText = [NSString stringWithContentsOfFile:libraryPath(@"Liveprog", liveprogName) encoding:NSUTF8StringEncoding error:nil];
    SGDSPEngineSetLiveprog(engine, getBool(defaults, kLiveprog) && liveprogText.length, liveprogText.UTF8String, error, sizeof error);
    SGDSPEngineSetReverb(engine, getBool(defaults, (NSString *)kReverb), (int)getDouble(defaults, (NSString *)kReverbPreset, 9));
    SGDSPEngineSetStereoWide(engine, getBool(defaults, (NSString *)kWide), getDouble(defaults, (NSString *)kWideLevel, 60));
    SGDSPEngineSetCrossfeed(engine, getBool(defaults, (NSString *)kCrossfeed), (int)getDouble(defaults, (NSString *)kCrossfeedMode, 5));
    SGDSPEngineSetTube(engine, getBool(defaults, (NSString *)kTube), getDouble(defaults, (NSString *)kTubeDrive, 2));
    if (enabledChanged) SGDSPEngineRestart(engine);
    gAppliedSettings = [signature copy];
    gAppliedEnabled = enabled;
    gHasAppliedEnabled = YES;
}

static inline float readSample(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) return ((const float *)data)[index];
    if (bytes == 4) {
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    return (float)((const int16_t *)data)[index] / 32768.0f;
}

static inline void writeSample(void *data, UInt32 index, float value, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) {
        ((float *)data)[index] = value;
        return;
    }
    value = fmaxf(-1, fminf(1, value));
    if (bytes == 4) {
        double scale = fraction ? (double)(1u << fraction) : 2147483647.0;
        ((int32_t *)data)[index] = (int32_t)(value * scale);
    } else {
        ((int16_t *)data)[index] = (int16_t)(value * 32767.0f);
    }
}

static float gLeft[4096], gRight[4096];

static BOOL processBuffers(SGDSPEngine *engine, AudioUnitRenderActionFlags *flags, UInt32 frames, AudioBufferList *data, const AudioTimeStamp *timestamp) {
    uint64_t layout = atomic_load_explicit(&gLayout, memory_order_relaxed);
    UInt32 formatFlags = (UInt32)layout, channels = (UInt32)(layout >> 32) & 0xffff, bytes = (UInt32)(layout >> 48);
    uint64_t rateBits = atomic_load_explicit(&gRateBits, memory_order_relaxed);
    double sampleRate = 0;
    memcpy(&sampleRate, &rateBits, sizeof sampleRate);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    if ((bytes != 2 && bytes != 4) || channels < 1) return NO;

    UInt32 needed = frames * bytes * (split ? 1 : channels);
    BOOL fits = split ? data->mNumberBuffers >= channels : data->mNumberBuffers == 1;
    for (UInt32 b = 0; fits && b < (split ? channels : 1); b++) {
        fits = data->mBuffers[b].mData && data->mBuffers[b].mDataByteSize >= needed;
    }
    if (!fits) return NO;

    BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;
    BOOL loud = NO;
    if (split && isFloat && bytes == 4 && channels >= 2) {
        float *left = data->mBuffers[0].mData, *right = data->mBuffers[1].mData;
        if (silent) {
            memset(left, 0, frames * sizeof(float));
            memset(right, 0, frames * sizeof(float));
        }
        AISpatialLiveProcessFn aiProcess = atomic_load_explicit(&gAISpatialLiveProcess, memory_order_acquire);
        if (aiProcess) aiProcess(left, right, frames, sampleRate, timestamp);
        if (engine) SGDSPEngineProcess(engine, left, right, frames);
        loud = !silent;
    } else {
        for (UInt32 done = 0; done < frames;) {
            UInt32 count = MIN(frames - done, (UInt32)4096);
            const void *first = data->mBuffers[0].mData;
            const void *second = split && channels > 1 ? data->mBuffers[1].mData : first;
            UInt32 stride = split ? 1 : channels, secondOffset = !split && channels > 1 ? 1 : 0;
            for (UInt32 i = 0; i < count; i++) {
                UInt32 at = (done + i) * stride;
                gLeft[i] = silent ? 0 : readSample(first, at, bytes, isFloat, fraction);
                gRight[i] = silent ? 0 : readSample(second, at + secondOffset, bytes, isFloat, fraction);
            }
            AISpatialLiveProcessFn aiProcess = atomic_load_explicit(&gAISpatialLiveProcess, memory_order_acquire);
            if (aiProcess) {
                AudioTimeStamp chunkTimestamp;
                const AudioTimeStamp *chunkTimestampPointer = timestamp;
                if (timestamp) {
                    chunkTimestamp = *timestamp;
                    if (chunkTimestamp.mFlags & kAudioTimeStampSampleTimeValid) chunkTimestamp.mSampleTime += done;
                    chunkTimestampPointer = &chunkTimestamp;
                }
                aiProcess(gLeft, gRight, count, sampleRate, chunkTimestampPointer);
            }
            if (engine) SGDSPEngineProcess(engine, gLeft, gRight, count);
            loud = loud || !silent;
            void *firstOut = data->mBuffers[0].mData;
            void *secondOut = split && channels > 1 ? data->mBuffers[1].mData : firstOut;
            for (UInt32 i = 0; i < count; i++) {
                UInt32 at = (done + i) * stride;
                if (channels == 1) {
                    writeSample(firstOut, at, 0.5f * (gLeft[i] + gRight[i]), bytes, isFloat, fraction);
                } else {
                    writeSample(firstOut, at, gLeft[i], bytes, isFloat, fraction);
                    writeSample(secondOut, at + secondOffset, gRight[i], bytes, isFloat, fraction);
                }
            }
            done += count;
        }
    }
    if (loud) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    return YES;
}

static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                         UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    AISpatialLiveProcessFn aiProcess = atomic_load_explicit(&gAISpatialLiveProcess, memory_order_acquire);
    BOOL effectsEnabled = atomic_load_explicit(&gEnabled, memory_order_acquire);
    if (!effectsEnabled && !aiProcess) return noErr;
    SGDSPEngine *engine = atomic_load_explicit(&gEngine, memory_order_acquire);
    // AI can remain enabled while JamesDSP is explicitly bypassed.  Do not
    // send that block through the engine in that case: SGDSPEngineProcess has
    // its own one-block pipeline, so calling it while disabled would silently
    // add JamesDSP latency and violate the user's bypass setting.
    if (!effectsEnabled) engine = NULL;
    uint64_t rateBits = atomic_load_explicit(&gRateBits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &rateBits, sizeof rate);
    if (rate <= 0) return noErr;
    if (engine && SGDSPEngineSampleRate(engine) != rate) engine = NULL;
    if (!engine && !aiProcess) return noErr;
    processBuffers(engine, flags, frames, data, timestamp);
    return noErr;
}

static void updateFormat(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (!unit || AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) != noErr ||
        description.componentType != kAudioUnitType_Output || description.componentSubType != kAudioUnitSubType_RemoteIO) return;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size) != noErr ||
        format.mFormatID != kAudioFormatLinearPCM || (format.mBitsPerChannel != 16 && format.mBitsPerChannel != 32) ||
        format.mSampleRate <= 0 || format.mChannelsPerFrame < 1) {
        atomic_store(&gLayout, 0);
        atomic_store(&gRateBits, 0);
        return;
    }
    UInt32 bytes = format.mBitsPerChannel / 8;
    atomic_store(&gLayout, (uint64_t)format.mFormatFlags | (uint64_t)(format.mChannelsPerFrame & 0xffff) << 32 | (uint64_t)bytes << 48);
    uint64_t rateBits;
    memcpy(&rateBits, &format.mSampleRate, sizeof rateBits);
    atomic_store(&gRateBits, rateBits);
    resolveAISpatialBridge();
    AISpatialLiveResetFn aiReset = atomic_load_explicit(&gAISpatialLiveReset, memory_order_acquire);
    if (aiReset) aiReset(format.mSampleRate);
    dispatch_async(gConfigQueue, ^{
        SGDSPEngine *old = atomic_load(&gEngine);
        if (!old || SGDSPEngineSampleRate(old) != format.mSampleRate) {
            SGDSPEngine *fresh = SGDSPEngineCreate(format.mSampleRate);
            if (!fresh) { NSLog(@"[chroma-jdsp] could not create engine at %.0f Hz", format.mSampleRate); return; }
            atomic_store(&gEngine, fresh);
            gAppliedSettings = nil;
            NSLog(@"[chroma-jdsp] engine ready at %.0f Hz", format.mSampleRate);
            // The render callback may still hold the previous pointer for this block. Keep old engines
            // alive for the process lifetime; this is rare (only an audio-route rate change) and avoids
            // freeing memory while the real-time callback is between its atomic load and process call.
        }
        applySettings();
    });
}

static void formatChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) {
    if (property == kAudioUnitProperty_StreamFormat && scope == kAudioUnitScope_Output && element == 0) updateFormat(unit);
}

static void attach(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (!unit || AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) != noErr ||
        description.componentType != kAudioUnitType_Output || description.componentSubType != kAudioUnitSubType_RemoteIO) return;
    AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat, formatChanged, NULL);
    AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, NULL);
    updateFormat(unit);
    AudioUnitRemoveRenderNotify(unit, rendered, NULL);
    AudioUnitAddRenderNotify(unit, rendered, NULL);
}

static OSStatus startOutput(AudioUnit unit) {
    resolveAISpatialBridge();
    OSStatus status = gAudioOutputUnitStart ? gAudioOutputUnitStart(unit) : -1;
    if (status == noErr) {
        attach(unit);
        resolveAISpatialBridge();
        AISpatialLiveResetFn aiReset = atomic_load_explicit(&gAISpatialLiveReset, memory_order_acquire);
        SGDSPEngine *engine = atomic_load_explicit(&gEngine, memory_order_acquire);
        if (aiReset && engine) aiReset(SGDSPEngineSampleRate(engine));
    }
    return status;
}

__attribute__((constructor)) static void chromaJDSPInit(void) {
    gConfigQueue = dispatch_queue_create("pw.chroma.jdsp", DISPATCH_QUEUE_SERIAL);
    if (!SGRebindImport("AudioOutputUnitStart", (void *)startOutput, (void **)&gAudioOutputUnitStart) || !gAudioOutputUnitStart) {
        NSLog(@"[chroma-jdsp] Spotify does not import AudioOutputUnitStart");
        return;
    }
    dispatch_async(gConfigQueue, ^{ applySettings(); });
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(gConfigQueue, ^{ applySettings(); });
    }];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gConfigQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(timer, ^{ resolveAISpatialBridge(); applySettings(); });
    dispatch_resume(timer);
    NSLog(@"[chroma-jdsp] sound effects bridge loaded");
}
