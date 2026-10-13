#import "AISpatialSeparator.h"
#import "AISpatialModelStore.h"
#import "AISpatialLog.h"
#import "AISpatialDiagnostics.h"
#import "AISpatialSpectral.h"
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <mach/mach.h>

// This is the spectral contract of separator-ane.mlmodelc.  The first tensor
// dimension interleaves the two audio channels for each bin; the last
// dimension is the real/imaginary pair.  It is not a magnitude tensor.
static const NSUInteger kFFTSize = 2048;
static const NSUInteger kBins = 1025;
static const NSUInteger kFrames = 201;
static const NSUInteger kHop = 441;
static const double kSampleRate = 44100.0;
static const double kTestDurationSeconds = 30.0;
static const NSUInteger kWindowSamples = (kFrames - 1) * kHop;
// The reference Sing worker advances a two-second model window by 1.5 s.
static const NSUInteger kInferenceStep = (kWindowSamples * 3) / 4;

static NSError *AISpatialError(NSString *message) {
    return [NSError errorWithDomain:@"AISpatialSeparator" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSUInteger AISpatialTensorOffset(MLMultiArray *array, NSUInteger bin, NSUInteger frame, NSUInteger channel, NSUInteger component) {
    // Model layout: [1, bin*2 + channel, frame, real/imag].  Use the actual
    // strides because the ANE output can be a non-contiguous Float16 array.
    NSUInteger channelBin = bin * 2 + channel;
    if (array.strides.count == 4) {
        return channelBin * array.strides[1].unsignedIntegerValue +
               frame * array.strides[2].unsignedIntegerValue +
               component * array.strides[3].unsignedIntegerValue;
    }
    return ((channelBin * kFrames + frame) * 2) + component;
}

static NSUInteger AISpatialReflectIndex(NSInteger index, NSUInteger length) {
    if (length < 2) return 0;
    if (index < 0) return (NSUInteger)(-index);
    if ((NSUInteger)index >= length) return (NSUInteger)(2 * (NSInteger)length - 2 - index);
    return (NSUInteger)index;
}

static NSDictionary *AISpatialAudioFormatInfo(AVAudioFormat *format) {
    const AudioStreamBasicDescription *description = format.streamDescription;
    NSString *layout = format.isInterleaved ? @"interleaved" : @"non-interleaved";
    return @{
        @"sample_rate": @(format.sampleRate),
        @"channels": @(format.channelCount),
        @"bit_depth": @(description ? description->mBitsPerChannel : 0),
        @"bytes_per_frame": @(description ? description->mBytesPerFrame : 0),
        @"format_id": @(description ? description->mFormatID : 0),
        @"common_format": @(format.commonFormat),
        @"pcm_format": format.commonFormat == AVAudioPCMFormatFloat32 ? @"float32" : @"unavailable",
        @"layout": layout,
        @"interleaved": @(format.isInterleaved),
    };
}

static NSUInteger AISpatialCurrentMemoryBytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? (NSUInteger)info.resident_size : 0;
}

static double AISpatialPercentile(NSArray<NSNumber *> *values, double percentile) {
    if (!values.count) return 0;
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    double position = percentile * (sorted.count - 1);
    NSUInteger lower = (NSUInteger)floor(position);
    NSUInteger upper = MIN(lower + 1, sorted.count - 1);
    double fraction = position - lower;
    return [sorted[lower] doubleValue] + ([sorted[upper] doubleValue] - [sorted[lower] doubleValue]) * fraction;
}

static BOOL AISpatialReadWindow(NSURL *url, float **leftOut, float **rightOut, NSUInteger *lengthOut,
                                NSDictionary **formatInfoOut, NSError **errorOut) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:errorOut];
    if (!file) return NO;
    AVAudioFormat *format = file.processingFormat;
    if (format.sampleRate <= 0 || format.channelCount == 0) {
        if (errorOut) *errorOut = AISpatialError(@"Не удалось определить формат тестового аудио");
        return NO;
    }
    NSUInteger wanted = (NSUInteger)ceil(kTestDurationSeconds * kSampleRate);
    AVAudioFormat *target = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:2];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:format toFormat:target];
    if (!converter) {
        if (errorOut) *errorOut = AISpatialError(@"Не удалось подготовить конвертер аудио");
        return NO;
    }
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:(AVAudioFrameCount)wanted];
    __block NSError *readError = nil;
    __block BOOL endOfFile = NO;
    AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer *(AVAudioPacketCount packetCount, AVAudioConverterInputStatus *outStatus) {
        if (endOfFile || file.framePosition >= file.length) {
            *outStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        AVAudioFrameCount request = (AVAudioFrameCount)MIN((uint64_t)packetCount, file.length - file.framePosition);
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:request];
        if (![file readIntoBuffer:input error:&readError]) {
            endOfFile = YES;
            *outStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        if (input.frameLength == 0) {
            endOfFile = YES;
            *outStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return input;
    };
    NSError *convertError = nil;
    [converter convertToBuffer:buffer error:&convertError withInputFromBlock:inputBlock];
    if (readError || convertError) {
        if (errorOut) *errorOut = readError ?: convertError;
        return NO;
    }
    NSUInteger length = buffer.frameLength;
    if (length == 0) {
        if (errorOut) *errorOut = AISpatialError(@"Тестовый аудиофайл не содержит PCM-данных");
        return NO;
    }
    float *left = calloc(length, sizeof(float));
    float *right = calloc(length, sizeof(float));
    if (!left || !right) {
        free(left); free(right);
        if (errorOut) *errorOut = AISpatialError(@"Недостаточно памяти для тестового окна");
        return NO;
    }
    const float *sourceLeft = buffer.floatChannelData[0];
    const float *sourceRight = buffer.floatChannelData[1];
    memcpy(left, sourceLeft, length * sizeof(float));
    memcpy(right, sourceRight, length * sizeof(float));
    *leftOut = left;
    *rightOut = right;
    *lengthOut = length;
    if (formatInfoOut) {
        *formatInfoOut = @{
            @"source": AISpatialAudioFormatInfo(format),
            @"converted": AISpatialAudioFormatInfo(target),
            @"input_file_frames": @(file.length),
            @"output_samples": @(length),
            @"expected_output_samples_from_rate": @(round((double)file.length * kSampleRate / format.sampleRate)),
            @"sample_count_difference": @((NSInteger)length - (NSInteger)round((double)file.length * kSampleRate / format.sampleRate)),
            @"resampling": @((fabs(format.sampleRate - kSampleRate) > 0.01) || format.channelCount != 2),
            @"normalization": @"none; source PCM copied after AVAudioConverter",
        };
    }
    return YES;
}

static void AISpatialCopyWindow(const float *source, NSUInteger sourceLength, NSUInteger offset, float *window) {
    memset(window, 0, kWindowSamples * sizeof(float));
    if (offset >= sourceLength) return;
    NSUInteger count = MIN(kWindowSamples, sourceLength - offset);
    memcpy(window, source + offset, count * sizeof(float));
}

static NSDictionary *AISpatialStereoRangeStats(const float *left, const float *right, NSUInteger offset, NSUInteger count) {
    NSDictionary *leftStats = AISpatialFloatStatistics(left + offset, count);
    NSDictionary *rightStats = AISpatialFloatStatistics(right + offset, count);
    NSUInteger finite = [leftStats[@"finite_count"] unsignedIntegerValue] + [rightStats[@"finite_count"] unsignedIntegerValue];
    NSUInteger nan = [leftStats[@"nan_count"] unsignedIntegerValue] + [rightStats[@"nan_count"] unsignedIntegerValue];
    NSUInteger infinity = [leftStats[@"infinity_count"] unsignedIntegerValue] + [rightStats[@"infinity_count"] unsignedIntegerValue];
    NSUInteger aboveOne = [leftStats[@"out_of_range_count"] unsignedIntegerValue] + [rightStats[@"out_of_range_count"] unsignedIntegerValue];
    double leftRMS = [leftStats[@"rms"] doubleValue], rightRMS = [rightStats[@"rms"] doubleValue];
    double dc = ([leftStats[@"dc_offset"] doubleValue] + [rightStats[@"dc_offset"] doubleValue]) / 2.0;
    id minValue = leftStats[@"min"] == [NSNull null] || rightStats[@"min"] == [NSNull null] ? (id)[NSNull null] : @(MIN([leftStats[@"min"] doubleValue], [rightStats[@"min"] doubleValue]));
    id maxValue = leftStats[@"max"] == [NSNull null] || rightStats[@"max"] == [NSNull null] ? (id)[NSNull null] : @(MAX([leftStats[@"max"] doubleValue], [rightStats[@"max"] doubleValue]));
    return @{ @"samples": @(count), @"channels": @2, @"finite_count": @(finite), @"nan_count": @(nan),
              @"infinity_count": @(infinity), @"out_of_range_count": @(aboveOne), @"min": minValue,
              @"max": maxValue, @"peak": @(MAX([leftStats[@"peak"] doubleValue], [rightStats[@"peak"] doubleValue])),
              @"rms": @(sqrt((leftRMS * leftRMS + rightRMS * rightRMS) / 2.0)), @"dc_offset": @(dc) };
}

static NSData *AISpatialInterleavedFloatData(const float *left, const float *right, NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count * 2 * sizeof(float)];
    float *destination = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) { destination[i * 2] = left[i]; destination[i * 2 + 1] = right[i]; }
    return data;
}

static NSDictionary *AISpatialWindowStats(const float *left, const float *right, NSUInteger count) {
    NSDictionary *leftStats = AISpatialFloatStatistics(left, count);
    NSDictionary *rightStats = AISpatialFloatStatistics(right, count);
    return @{ @"left": leftStats, @"right": rightStats, @"stereo": AISpatialStereoRangeStats(left, right, 0, count) };
}

void AISpatialFillSpectrum(MLMultiArray *array, const float *left, const float *right, NSUInteger channel, NSUInteger length) {
    FFTSetup setup = vDSP_create_fftsetup(11, kFFTRadix2);
    float *window = calloc(kFFTSize, sizeof(float));
    float *real = calloc(kFFTSize, sizeof(float));
    float *imag = calloc(kFFTSize, sizeof(float));
    for (NSUInteger n = 0; n < kFFTSize; n++) {
        // Periodic Hann, matching the Python/Swift reference implementation.
        window[n] = 0.5f - 0.5f * cosf((float)(2.0 * M_PI * (double)n / (double)kFFTSize));
    }
    DSPSplitComplex split = { real, imag };
    for (NSUInteger frame = 0; frame < kFrames; frame++) {
        const float *source = channel == 0 ? left : right;
        NSInteger start = (NSInteger)(frame * kHop) - (NSInteger)(kFFTSize / 2);
        for (NSUInteger n = 0; n < kFFTSize; n++) {
            NSUInteger reflected = AISpatialReflectIndex(start + (NSInteger)n, length);
            real[n] = source[reflected] * window[n];
        }
        memset(imag, 0, kFFTSize * sizeof(float));
        vDSP_ctoz((DSPComplex *)real, 2, &split, 1, kFFTSize / 2);
        vDSP_fft_zrip(setup, &split, 1, 11, FFT_FORWARD);
        for (NSUInteger frequency = 0; frequency < kBins; frequency++) {
            float re = 0;
            float im = 0;
            if (frequency == 0) {
                re = split.realp[0];
            } else if (frequency == kFFTSize / 2) {
                re = split.imagp[0];
            } else if (frequency < kFFTSize / 2) {
                re = split.realp[frequency];
                im = split.imagp[frequency];
            }
            // The model consumes the unscaled complex spectrum.  The first
            // dimension interleaves left/right for each bin and the last
            // dimension stores real then imaginary components.
            ((float *)array.dataPointer)[AISpatialTensorOffset(array, frequency, frame, channel, 0)] = re;
            ((float *)array.dataPointer)[AISpatialTensorOffset(array, frequency, frame, channel, 1)] = im;
        }
    }
    free(window); free(real); free(imag);
    vDSP_destroy_fftsetup(setup);
}

static float AISpatialArrayValue(MLMultiArray *array, NSUInteger bin, NSUInteger frame, NSUInteger channel, NSUInteger component) {
    NSUInteger offset = AISpatialTensorOffset(array, bin, frame, channel, component);
    if (array.dataType == MLMultiArrayDataTypeFloat32) return ((float *)array.dataPointer)[offset];
    if (array.dataType == MLMultiArrayDataTypeDouble) return (float)((double *)array.dataPointer)[offset];
    if (array.dataType == MLMultiArrayDataTypeFloat16) return (float)ASHalfToDouble(((uint16_t *)array.dataPointer)[offset]);
    return [[array objectAtIndexedSubscript:(NSInteger)offset] floatValue];
}

void AISpatialInverseWindow(MLMultiArray *source, NSUInteger channel, float *output, NSUInteger length,
                                   FFTSetup setup, const float *window) {
    float *real = calloc(kFFTSize, sizeof(float));
    float *imag = calloc(kFFTSize, sizeof(float));
    float *time = calloc(kFFTSize, sizeof(float));
    float *accumulator = calloc(kFFTSize + length, sizeof(float));
    float *windowNormalization = calloc(kFFTSize + length, sizeof(float));
    DSPSplitComplex split = { real, imag };
    if (!real || !imag || !time || !accumulator || !windowNormalization) {
        free(real); free(imag); free(time); free(accumulator); free(windowNormalization);
        return;
    }
    for (NSUInteger frame = 0; frame < kFrames; frame++) {
        NSUInteger start = frame * kHop;
        for (NSUInteger n = 0; n < kFFTSize; n++) windowNormalization[start + n] += window[n] * window[n];
    }
    for (NSUInteger frame = 0; frame < kFrames; frame++) {
        memset(real, 0, kFFTSize * sizeof(float));
        memset(imag, 0, kFFTSize * sizeof(float));
        for (NSUInteger frequency = 0; frequency < kBins; frequency++) {
            float re = AISpatialArrayValue(source, frequency, frame, channel, 0);
            float im = AISpatialArrayValue(source, frequency, frame, channel, 1);
            if (frequency == 0) real[0] = re;
            else if (frequency == kFFTSize / 2) imag[0] = re;
            else if (frequency < kFFTSize / 2) { real[frequency] = re; imag[frequency] = im; }
        }
        // The model output is a complex spectrum.  vDSP's packed real FFT
        // representation keeps DC in realp[0], Nyquist in imagp[0], and the
        // remaining positive-frequency real/imaginary pairs in the two arrays.
        vDSP_fft_zrip(setup, &split, 1, 11, FFT_INVERSE);
        vDSP_ztoc(&split, 1, (DSPComplex *)time, 2, kFFTSize / 2);
        // vDSP_fft_zrip uses the packed real-FFT convention.  Its inverse
        // produces 2*N times the mathematical real signal, unlike the
        // out-of-place vDSP_DFT used by the Swift reference implementation.
        // Dividing by N leaves the decoded stem exactly 2x too loud; the
        // residual then contains an audible inverted copy of the vocal.
        float scale = 1.0f / (2.0f * (float)kFFTSize);
        vDSP_vsmul(time, 1, &scale, time, 1, kFFTSize);
        NSUInteger start = frame * kHop;
        for (NSUInteger n = 0; n < kFFTSize; n++) accumulator[start + n] += time[n] * window[n];
    }
    // Centered STFT: the first and last half-FFT are reflected during encode,
    // and removed here after overlap-add.  This is the same crop used by Sing.
    NSUInteger pad = kFFTSize / 2;
    for (NSUInteger n = 0; n < length; n++) {
        NSUInteger at = n + pad;
        output[n] = accumulator[at] / fmaxf(windowNormalization[at], 1e-8f);
    }
    free(real); free(imag); free(time); free(accumulator); free(windowNormalization);
}

static NSURL *AISpatialWriteWAV(NSURL *directory, NSString *name, const float *left, const float *right, NSUInteger length, NSError **error) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:2];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:length];
    buffer.frameLength = length;
    memcpy(buffer.floatChannelData[0], left, length * sizeof(float));
    memcpy(buffer.floatChannelData[1], right, length * sizeof(float));
    NSURL *url = [directory URLByAppendingPathComponent:name];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:format.settings commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:error];
    if (!file || ![file writeFromBuffer:buffer error:error]) return nil;
    return url;
}

static NSDictionary *AISpatialVerifyWAV(NSURL *url, const float *expectedLeft, const float *expectedRight, NSUInteger expectedLength, NSError **error) {
    if (!url) return @{ @"status": @"unavailable", @"reason": @"file was not written" };
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:error];
    if (!file) return @{ @"status": @"unavailable", @"reason": (error && *error) ? [*error localizedDescription] : @"readback failed" };
    AVAudioFormat *format = file.processingFormat;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)file.length];
    if (![file readIntoBuffer:buffer error:error] || !buffer.floatChannelData) return @{ @"status": @"unavailable", @"reason": (error && *error) ? [*error localizedDescription] : @"PCM readback failed" };
    const float *actualRight = buffer.floatChannelData[MIN((NSUInteger)1, (NSUInteger)format.channelCount - 1)];
    NSDictionary *stats = AISpatialWindowStats(buffer.floatChannelData[0], actualRight, buffer.frameLength);
    double maximumDifference = 0;
    if (expectedLeft && expectedRight && expectedLength == buffer.frameLength) {
        for (NSUInteger i = 0; i < expectedLength; i++) { maximumDifference = MAX(maximumDifference, fabs((double)expectedLeft[i] - buffer.floatChannelData[0][i])); maximumDifference = MAX(maximumDifference, fabs((double)expectedRight[i] - actualRight[i])); }
    }
    return @{ @"status": @"measured", @"format": AISpatialAudioFormatInfo(format), @"samples": @(buffer.frameLength), @"stats": stats[@"stereo"], @"max_abs_difference_from_export_buffer": @(maximumDifference), @"float_amplitude_preserved": expectedLeft && expectedRight && expectedLength == buffer.frameLength ? @(maximumDifference <= 1e-6) : @"unavailable" };
}

@implementation AISpatialSeparator

+ (instancetype)sharedSeparator {
    static AISpatialSeparator *separator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ separator = [self new]; });
    return separator;
}

- (void)runTestWithAudioURL:(NSURL *)url completion:(void (^)(NSURL *, NSURL *, NSError *))completion {
    if (!completion) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AISpatialDiagnostics *diagnostics = AISpatialDiagnostics.sharedDiagnostics;
        AISpatialModelStore *modelStore = AISpatialModelStore.sharedStore;
        if (!modelStore.modelIsReady) {
            NSError *error = AISpatialError(@"Сначала скачайте и инициализируйте модель");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, error); });
            return;
        }
        [diagnostics beginAutomaticSessionForTest];
        [diagnostics updateMetadata:@{
            @"model": modelStore.diagnosticMetadata,
            @"test": @{ @"input_file_name": @"redacted", @"input_file_name_sha256": AISpatialSHA256([(url.lastPathComponent ?: @"unavailable") dataUsingEncoding:NSUTF8StringEncoding]), @"requested_duration_seconds": @(kTestDurationSeconds),
                         @"source": @"user-selected local audio file; Spotify realtime capture is a separate metrics-only Stage 01 observer" },
            @"stages": @{ @"01_spotify_pcm_capture": @"unavailable for this offline picker input; use Diagnostics recording during Spotify playback for measured blocks", @"02_input_preparation": @"measured", @"03_windowing": @"measured", @"04_stft": @"measured", @"05_coreml_input": @"measured", @"06_inference": @"measured by Core ML call", @"07_coreml_output": @"measured", @"08_inverse_stft": @"measured", @"09_instrumental": @"measured", @"10_export": @"measured" }
        }];
        [diagnostics recordStage:@"Stage 01 - Spotify PCM Capture" event:@"unavailable" fields:@{
            @"status": @"unavailable",
            @"reason": @"This offline test does not attach to Spotify or JamesDSP real-time audio callbacks",
            @"source": @"UIDocumentPicker local file",
            @"timestamps": @"unavailable",
            @"continuity": @"not_applicable_offline",
        }];
        float *left = NULL, *right = NULL;
        NSUInteger length = 0;
        NSDictionary *formatInfo = nil;
        NSError *error = nil;
        if (!AISpatialReadWindow(url, &left, &right, &length, &formatInfo, &error)) {
            AISpatialLog(@"test input rejected: %@", error.localizedDescription);
            [diagnostics recordStage:@"Stage 02 - Input Preparation" event:@"error" fields:@{ @"error": error.localizedDescription ?: @"unavailable" }];
            [diagnostics finishTestWithMetadata:@{ @"result": @"failed", @"error": error.localizedDescription ?: @"unavailable" }];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, error); });
            return;
        }
        NSDictionary *inputStats = AISpatialWindowStats(left, right, length);
        NSMutableDictionary *preparationFields = [@{ @"format": formatInfo ?: @{}, @"input_left": inputStats[@"left"], @"input_right": inputStats[@"right"], @"input_stereo": inputStats[@"stereo"] } mutableCopy];
        [diagnostics recordStage:@"Stage 02 - Input Preparation" event:@"converted_pcm" fields:preparationFields];
        [diagnostics recordStage:@"Stage 02 - Input Preparation" event:@"anomaly_check" fields:@{
            @"nan_count": @([inputStats[@"stereo"][@"nan_count"] unsignedIntegerValue]), @"infinity_count": @([inputStats[@"stereo"][@"infinity_count"] unsignedIntegerValue]),
            @"out_of_range_count": @([inputStats[@"stereo"][@"out_of_range_count"] unsignedIntegerValue]), @"normalization": @"none" }];
        if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
            NSData *inputDump = AISpatialInterleavedFloatData(left, right, MIN(length, (NSUInteger)(5.0 * kSampleRate)));
            [diagnostics recordBinary:inputDump kind:@"pcm-input" identifier:@"source" offset:0 sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"02-Input Preparation", @"format": @"float32 interleaved", @"source": @"local file" }];
        }
        NSMutableArray<NSNumber *> *windowStarts = [NSMutableArray array];
        NSUInteger step = MAX((NSUInteger)1, kInferenceStep);
        if (length <= kWindowSamples) {
            [windowStarts addObject:@0];
        } else {
            NSUInteger start = 0;
            NSUInteger finalStart = length - kWindowSamples;
            while (YES) {
                [windowStarts addObject:@(start)];
                if (start >= finalStart) break;
                NSUInteger next = start + step;
                if (next >= finalStart) {
                    if (finalStart != start) [windowStarts addObject:@(finalStart)];
                    break;
                }
                start = next;
            }
        }

        AISpatialLog(@"offline test started; duration=%.2fs windows=%lu window=%.2fs step=%.2fs",
                     (double)length / kSampleRate, (unsigned long)windowStarts.count,
                     (double)kWindowSamples / kSampleRate, (double)step / kSampleRate);
        [diagnostics recordStage:@"Stage 03 - Windowing and Buffering" event:@"plan" fields:@{
            @"duration_seconds": @((double)length / kSampleRate), @"window_count": @(windowStarts.count), @"window_samples": @(kWindowSamples),
            @"hop_samples": @(kHop), @"overlap_samples": @(kWindowSamples - kInferenceStep), @"overlap_ratio": @((double)(kWindowSamples - kInferenceStep) / kWindowSamples),
            @"window_function": @"periodic Hann", @"queue_limit": @256, @"dropped_buffers": @0, @"dropped_buffers_status": @"not_applicable_offline"
        }];

        FFTSetup setup = vDSP_create_fftsetup(11, kFFTRadix2);
        float *window = calloc(kFFTSize, sizeof(float));
        float *vocalsLeft = calloc(length, sizeof(float));
        float *vocalsRight = calloc(length, sizeof(float));
        float *instrumentalLeft = calloc(length, sizeof(float));
        float *instrumentalRight = calloc(length, sizeof(float));
        float *normalization = calloc(length, sizeof(float));
        if (!setup || !window || !vocalsLeft || !vocalsRight || !instrumentalLeft || !instrumentalRight || !normalization) {
            free(left); free(right); free(window); free(vocalsLeft); free(vocalsRight);
            free(instrumentalLeft); free(instrumentalRight); free(normalization);
            if (setup) vDSP_destroy_fftsetup(setup);
            error = AISpatialError(@"Недостаточно памяти для 30-секундного теста");
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, error); });
            return;
        }
        for (NSUInteger n = 0; n < kFFTSize; n++) {
            window[n] = 0.5f - 0.5f * cosf((float)(2.0 * M_PI * (double)n / (double)kFFTSize));
        }

        BOOL succeeded = YES;
        NSError *failure = nil;
        NSMutableArray<NSDictionary *> *windowReports = [NSMutableArray arrayWithCapacity:windowStarts.count];
        NSMutableArray<NSNumber *> *allInferenceTimes = [NSMutableArray arrayWithCapacity:windowStarts.count];
        for (NSUInteger windowID = 0; windowID < windowStarts.count; windowID++) {
            @autoreleasepool {
                NSUInteger outputOffset = windowStarts[windowID].unsignedIntegerValue;
                double windowStartTime = (double)outputOffset / kSampleRate;
                float *windowLeft = calloc(kWindowSamples, sizeof(float));
                float *windowRight = calloc(kWindowSamples, sizeof(float));
                if (!windowLeft || !windowRight) {
                    free(windowLeft); free(windowRight);
                    failure = AISpatialError(@"Недостаточно памяти для окна теста");
                    [diagnostics recordWindow:@{ @"window_id": @(windowID), @"start_sample": @(outputOffset), @"status": @"skipped", @"error": failure.localizedDescription } processed:NO];
                    succeeded = NO;
                    break;
                }
                AISpatialCopyWindow(left, length, outputOffset, windowLeft);
                AISpatialCopyWindow(right, length, outputOffset, windowRight);
                NSDictionary *windowInputStats = AISpatialWindowStats(windowLeft, windowRight, kWindowSamples);
                [diagnostics recordStage:@"Stage 03 - Windowing and Buffering" event:@"window_started" fields:@{
                    @"window_id": @(windowID), @"start_sample": @(outputOffset), @"start_time": @(windowStartTime), @"end_time": @(windowStartTime + (double)kWindowSamples / kSampleRate),
                    @"window_samples": @(kWindowSamples), @"hop_samples": @(kHop), @"overlap_samples": @(kWindowSamples - step), @"accumulated_samples": @(MIN(outputOffset + kWindowSamples, length)),
                    @"input_stats": windowInputStats[@"stereo"], @"queue_depth": @(modelStore.inferenceQueueDepth)
                }];
                if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
                    NSData *windowDump = AISpatialInterleavedFloatData(windowLeft, windowRight, kWindowSamples);
                    [diagnostics recordBinary:windowDump kind:@"pcm-window" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"03-Windowing and Buffering", @"window_id": @(windowID), @"window_start_seconds": @(windowStartTime), @"window_samples": @(kWindowSamples) }];
                }

                NSError *windowError = nil;
                MLMultiArray *spectrum = [[MLMultiArray alloc] initWithShape:@[@1, @(kBins * 2), @(kFrames), @2]
                                                                      dataType:MLMultiArrayDataTypeFloat32
                                                                         error:&windowError];
                if (!spectrum) {
                    free(windowLeft); free(windowRight);
                    failure = windowError ?: AISpatialError(@"Не удалось создать входной спектр");
                    [diagnostics recordWindow:@{ @"window_id": @(windowID), @"start_sample": @(outputOffset), @"status": @"skipped", @"error": failure.localizedDescription } processed:NO];
                    succeeded = NO;
                    break;
                }
                memset(spectrum.dataPointer, 0, spectrum.count * sizeof(float));
                AISpatialFillSpectrum(spectrum, windowLeft, windowRight, 0, kWindowSamples);
                AISpatialFillSpectrum(spectrum, windowLeft, windowRight, 1, kWindowSamples);
                NSDictionary *spectrumStats = AISpatialTensorStatistics(spectrum);
                [diagnostics recordStage:@"Stage 04 - STFT / Spectral Preparation" event:@"spectrum_ready" fields:@{
                    @"window_id": @(windowID), @"fft_size": @(kFFTSize), @"hop_length": @(kHop), @"window_type": @"periodic Hann",
                    @"normalization": @"unscaled complex FFT; centered periodic Hann with reflected boundaries", @"shape": spectrum.shape ?: @[], @"strides": spectrum.strides ?: @[],
                    @"channel_order": @"dimension 1 interleaves left/right per frequency bin", @"complex_layout": @"dimension 3: real=0, imaginary=1", @"stats": spectrumStats
                }];
                [diagnostics recordStage:@"Stage 05 - Core ML Input" event:@"tensor_prepared" fields:@{
                    @"window_id": @(windowID), @"input_name": @"spectrum", @"shape": spectrum.shape ?: @[], @"strides": spectrum.strides ?: @[],
                    @"dtype": AISpatialTensorTypeName(spectrum.dataType), @"normalization": @"none; unscaled complex spectrum", @"stats": spectrumStats,
                    @"contract_expected": @[@1, @2050, @201, @2], @"contract_matches": @([spectrum.shape isEqualToArray:@[@1, @2050, @201, @2]])
                }];
                if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
                    NSData *tensorDump = AISpatialTensorData(spectrum);
                    [diagnostics recordBinary:tensorDump kind:@"tensor-input" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"05-Core ML Input", @"window_id": @(windowID), @"shape": spectrum.shape ?: @[], @"dtype": AISpatialTensorTypeName(spectrum.dataType), @"checksum": AISpatialTensorStatistics(spectrum)[@"sha256"] ?: @"unavailable" }];
                }

                __block MLMultiArray *vocals = nil;
                __block NSError *predictionError = nil;
                dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
                CFAbsoluteTime inferenceWaitStarted = CFAbsoluteTimeGetCurrent();
                [modelStore predictSpectrum:spectrum windowID:windowID completion:^(MLMultiArray *predictedVocals, NSError *predictedError) {
                    vocals = predictedVocals;
                    predictionError = predictedError;
                    dispatch_semaphore_signal(semaphore);
                }];
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                double inferenceElapsed = (CFAbsoluteTimeGetCurrent() - inferenceWaitStarted) * 1000.0;
                [allInferenceTimes addObject:@(inferenceElapsed)];
                NSDictionary *inferenceMetrics = modelStore.lastInferenceMetrics;
                double queueWaitMilliseconds = [inferenceMetrics[@"queue_wait_ms"] doubleValue];
                double measuredInferenceMilliseconds = [inferenceMetrics[@"inference_ms"] doubleValue] > 0 ? [inferenceMetrics[@"inference_ms"] doubleValue] : inferenceElapsed;
                [allInferenceTimes removeLastObject];
                [allInferenceTimes addObject:@(measuredInferenceMilliseconds)];
                if (!vocals || predictionError) {
                    free(windowLeft); free(windowRight);
                    failure = predictionError ?: AISpatialError(@"Core ML не вернул vocals_spectrum");
                    AISpatialLog(@"test prediction failed at %.2fs: %@", (double)outputOffset / kSampleRate, failure.localizedDescription);
                    [diagnostics recordWindow:@{ @"window_id": @(windowID), @"start_sample": @(outputOffset), @"end_sample": @(MIN(outputOffset + kWindowSamples, length)), @"status": @"failed", @"inference_ms": @(inferenceElapsed), @"error": failure.localizedDescription } processed:NO];
                    succeeded = NO;
                    break;
                }
                NSDictionary *outputStats = AISpatialTensorStatistics(vocals);
                if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
                    NSData *tensorDump = AISpatialTensorData(vocals);
                    [diagnostics recordBinary:tensorDump kind:@"tensor-output" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"07-Core ML Output", @"window_id": @(windowID), @"shape": vocals.shape ?: @[], @"dtype": AISpatialTensorTypeName(vocals.dataType), @"checksum": AISpatialTensorStatistics(vocals)[@"sha256"] ?: @"unavailable" }];
                }

                float *localVocalsLeft = calloc(kWindowSamples, sizeof(float));
                float *localVocalsRight = calloc(kWindowSamples, sizeof(float));
                float *localInstrumentalLeft = calloc(kWindowSamples, sizeof(float));
                float *localInstrumentalRight = calloc(kWindowSamples, sizeof(float));
                if (!localVocalsLeft || !localVocalsRight || !localInstrumentalLeft || !localInstrumentalRight) {
                    free(localVocalsLeft); free(localVocalsRight); free(localInstrumentalLeft); free(localInstrumentalRight);
                    free(windowLeft); free(windowRight);
                    failure = AISpatialError(@"Недостаточно памяти для inverse STFT окна");
                    [diagnostics recordWindow:@{ @"window_id": @(windowID), @"start_sample": @(outputOffset), @"status": @"failed", @"error": failure.localizedDescription } processed:NO];
                    succeeded = NO;
                    break;
                }
                AISpatialInverseWindow(vocals, 0, localVocalsLeft, kWindowSamples, setup, window);
                AISpatialInverseWindow(vocals, 1, localVocalsRight, kWindowSamples, setup, window);
                // Keep a per-window residual for diagnostics.  The final
                // instrumental is computed from the fully reconstructed
                // source below, which guarantees vocals + instrumental = input.
                for (NSUInteger n = 0; n < kWindowSamples; n++) {
                    localInstrumentalLeft[n] = windowLeft[n] - localVocalsLeft[n];
                    localInstrumentalRight[n] = windowRight[n] - localVocalsRight[n];
                }
                NSDictionary *localVocalStats = AISpatialWindowStats(localVocalsLeft, localVocalsRight, kWindowSamples);
                NSDictionary *localInstrumentalStats = AISpatialWindowStats(localInstrumentalLeft, localInstrumentalRight, kWindowSamples);
                BOOL windowAnomaly = [outputStats[@"nan_count"] unsignedIntegerValue] || [outputStats[@"infinity_count"] unsignedIntegerValue] || [localVocalStats[@"stereo"][@"nan_count"] unsignedIntegerValue] || [localInstrumentalStats[@"stereo"][@"nan_count"] unsignedIntegerValue] || [localVocalStats[@"stereo"][@"peak"] doubleValue] > 2.0 || [localInstrumentalStats[@"stereo"][@"peak"] doubleValue] > 2.0;
                if (windowAnomaly) {
                    [diagnostics recordStage:@"Stage 08 - Inverse STFT" event:@"anomaly" fields:@{ @"window_id": @(windowID), @"start_time": @(windowStartTime), @"reason": @"non-finite or peak above heuristic 2.0", @"output_tensor_stats": outputStats, @"vocal_stats": localVocalStats[@"stereo"], @"instrumental_stats": localInstrumentalStats[@"stereo"], @"neighbor_dump": @"current window retained when Full Trace is enabled" }];
                    if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
                        [diagnostics recordBinary:AISpatialInterleavedFloatData(localVocalsLeft, localVocalsRight, kWindowSamples) kind:@"pcm-anomaly-vocals" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"08-Inverse STFT", @"window_id": @(windowID), @"anomaly_neighborhood": @YES }];
                        [diagnostics recordBinary:AISpatialInterleavedFloatData(localInstrumentalLeft, localInstrumentalRight, kWindowSamples) kind:@"pcm-anomaly-instrumental" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"09-Instrumental Reconstruction", @"window_id": @(windowID), @"anomaly_neighborhood": @YES }];
                    }
                }
                [diagnostics recordStage:@"Stage 08 - Inverse STFT" event:@"window_reconstructed" fields:@{
                    @"window_id": @(windowID), @"fft_size": @(kFFTSize), @"hop_length": @(kHop), @"window_function": @"periodic Hann",
                    @"overlap_add": @YES, @"normalization": @"vDSP real-FFT inverse 1/(2N), per-window squared-Hann weight, then linear 1.5-second chunk overlap blend", @"vocal_stats": localVocalStats[@"stereo"], @"instrumental_stats": localInstrumentalStats[@"stereo"],
                    @"edge_handling": @"reflected STFT boundaries; zero-padded final model window"
                }];
                if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
                    [diagnostics recordBinary:AISpatialInterleavedFloatData(localVocalsLeft, localVocalsRight, kWindowSamples) kind:@"pcm-inverse-vocals" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"08-Inverse STFT", @"window_id": @(windowID) }];
                    [diagnostics recordBinary:AISpatialInterleavedFloatData(localInstrumentalLeft, localInstrumentalRight, kWindowSamples) kind:@"pcm-inverse-instrumental" identifier:[NSString stringWithFormat:@"%lu", (unsigned long)windowID] offset:outputOffset sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"09-Instrumental Reconstruction", @"window_id": @(windowID) }];
                }
                BOOL hasPreviousWindow = windowID > 0;
                BOOL hasNextWindow = windowID + 1 < windowStarts.count;
                NSUInteger previousOverlap = 0, nextOverlap = 0;
                if (hasPreviousWindow) {
                    NSUInteger previousStart = windowStarts[windowID - 1].unsignedIntegerValue;
                    previousOverlap = previousStart + kWindowSamples > outputOffset ? previousStart + kWindowSamples - outputOffset : 0;
                }
                if (hasNextWindow) {
                    NSUInteger nextStart = windowStarts[windowID + 1].unsignedIntegerValue;
                    nextOverlap = outputOffset + kWindowSamples > nextStart ? outputOffset + kWindowSamples - nextStart : 0;
                }
                NSUInteger copyCount = MIN(kWindowSamples, length - outputOffset);
                for (NSUInteger n = 0; n < copyCount; n++) {
                    float blend = 1.0f;
                    if (hasPreviousWindow && n < previousOverlap) {
                        blend = (float)(n + 1) / (float)(previousOverlap + 1);
                    } else if (hasNextWindow && n >= kWindowSamples - nextOverlap) {
                        blend = (float)(kWindowSamples - n) / (float)(nextOverlap + 1);
                    }
                    normalization[outputOffset + n] += blend;
                    vocalsLeft[outputOffset + n] += localVocalsLeft[n] * blend;
                    vocalsRight[outputOffset + n] += localVocalsRight[n] * blend;
                }
                [diagnostics recordStage:@"Stage 09 - Instrumental Reconstruction" event:@"residual_reconstruction" fields:@{
                    @"window_id": @(windowID), @"algorithm": @"diagnostic residual = source PCM - decoded complex vocal spectrum; final residual is computed after overlap-add", @"time_alignment": @"same window offset and channel order as vocals", @"vocal_output_stats": localVocalStats[@"stereo"], @"instrumental_output_stats": localInstrumentalStats[@"stereo"], @"out_of_range_count": @([localInstrumentalStats[@"stereo"][@"out_of_range_count"] unsignedIntegerValue])
                }];
                [windowReports addObject:@{ @"window_id": @(windowID), @"start_sample": @(outputOffset), @"end_sample": @(MIN(outputOffset + kWindowSamples, length)), @"start_time": @(windowStartTime), @"end_time": @(MIN(outputOffset + kWindowSamples, length) / kSampleRate), @"queue_wait_ms": @(queueWaitMilliseconds), @"inference_ms": @(measuredInferenceMilliseconds), @"completion_wait_ms": @(inferenceElapsed), @"status": @"completed" }];
                [diagnostics recordWindow:@{ @"window_id": @(windowID), @"start_sample": @(outputOffset), @"end_sample": @(MIN(outputOffset + kWindowSamples, length)), @"start_time": @(windowStartTime), @"end_time": @(MIN(outputOffset + kWindowSamples, length) / kSampleRate), @"window_samples": @(kWindowSamples), @"hop_samples": @(kHop), @"overlap_samples": @(kWindowSamples - step), @"status": @"completed", @"queue_wait_ms": @(queueWaitMilliseconds), @"inference_ms": @(measuredInferenceMilliseconds), @"completion_wait_ms": @(inferenceElapsed), @"input_rms": windowInputStats[@"stereo"][@"rms"], @"input_peak": windowInputStats[@"stereo"][@"peak"], @"input_nan": windowInputStats[@"stereo"][@"nan_count"], @"input_infinity": windowInputStats[@"stereo"][@"infinity_count"], @"output_rms": localVocalStats[@"stereo"][@"rms"], @"output_peak": localVocalStats[@"stereo"][@"peak"], @"output_nan": outputStats[@"nan_count"], @"output_infinity": outputStats[@"infinity_count"] } processed:YES];
                free(localVocalsLeft); free(localVocalsRight); free(localInstrumentalLeft); free(localInstrumentalRight);
                free(windowLeft); free(windowRight);
            }
        }

        if (!succeeded) {
            free(left); free(right); free(vocalsLeft); free(vocalsRight);
            free(instrumentalLeft); free(instrumentalRight); free(normalization); free(window);
            vDSP_destroy_fftsetup(setup);
            [diagnostics recordStage:@"Stage 06 - Core ML Inference" event:@"error" fields:@{ @"error": failure.localizedDescription ?: @"unavailable" }];
            [diagnostics finishTestWithMetadata:@{ @"result": @"failed", @"error": failure.localizedDescription ?: @"unavailable" }];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, failure); });
            return;
        }

        for (NSUInteger i = 0; i < length; i++) {
            if (normalization[i] > 1e-6f) {
                vocalsLeft[i] /= normalization[i]; vocalsRight[i] /= normalization[i];
            } else {
                vocalsLeft[i] = 0; vocalsRight[i] = 0;
            }
            // Mel-Band RoFormer returns the vocal *complex spectrum*.  The
            // instrumental is the time-domain residual, as in the reference
            // Sing worker, rather than a second gain mask over the source.
            instrumentalLeft[i] = left[i] - vocalsLeft[i];
            instrumentalRight[i] = right[i] - vocalsRight[i];
        }
        NSUInteger secondCount = (NSUInteger)ceil((double)length / kSampleRate);
        double previousInputRMS = 0;
        for (NSUInteger second = 0; second < secondCount; second++) {
            NSUInteger offset = (NSUInteger)(second * kSampleRate);
            NSUInteger count = MIN((NSUInteger)kSampleRate, length - offset);
            NSDictionary *secondInput = AISpatialStereoRangeStats(left, right, offset, count);
            NSDictionary *secondVocals = AISpatialStereoRangeStats(vocalsLeft, vocalsRight, offset, count);
            NSDictionary *secondInstrumental = AISpatialStereoRangeStats(instrumentalLeft, instrumentalRight, offset, count);
            float *mixLeft = calloc(count, sizeof(float));
            float *mixRight = calloc(count, sizeof(float));
            float *errorLeft = calloc(count, sizeof(float));
            float *errorRight = calloc(count, sizeof(float));
            for (NSUInteger i = 0; i < count; i++) {
                mixLeft[i] = vocalsLeft[offset + i] + instrumentalLeft[offset + i];
                mixRight[i] = vocalsRight[offset + i] + instrumentalRight[offset + i];
                errorLeft[i] = mixLeft[i] - left[offset + i]; errorRight[i] = mixRight[i] - right[offset + i];
            }
            NSDictionary *mixStats = AISpatialStereoRangeStats(mixLeft, mixRight, 0, count);
            NSDictionary *errorStats = AISpatialStereoRangeStats(errorLeft, errorRight, 0, count);
            NSMutableArray<NSNumber *> *secondInferenceTimes = [NSMutableArray array];
            NSMutableArray<NSNumber *> *secondQueueWaitTimes = [NSMutableArray array];
            NSUInteger submitted = 0, completed = 0;
            for (NSDictionary *report in windowReports) {
                NSUInteger reportSecond = (NSUInteger)floor([report[@"start_time"] doubleValue]);
                if (reportSecond == second) { submitted++; if ([report[@"status"] isEqualToString:@"completed"]) { completed++; [secondInferenceTimes addObject:report[@"inference_ms"]]; [secondQueueWaitTimes addObject:report[@"queue_wait_ms"] ?: @0]; } }
            }
            BOOL quietWarning = [secondInput[@"rms"] doubleValue] > 0.0001 && [secondVocals[@"rms"] doubleValue] < [secondInput[@"rms"] doubleValue] * 0.05;
            BOOL jumpWarning = previousInputRMS > 0.0001 && ([secondInput[@"rms"] doubleValue] > previousInputRMS * 4.0 || [secondInput[@"rms"] doubleValue] < previousInputRMS * 0.25);
            NSUInteger memoryBytes = AISpatialCurrentMemoryBytes();
            NSMutableDictionary *secondFields = [@{
                @"second": @(second), @"start_time": @((double)offset / kSampleRate), @"end_time": @((double)(offset + count) / kSampleRate), @"samples": @(count),
                @"windows_submitted": @(submitted), @"windows_completed": @(completed), @"input_rms": secondInput[@"rms"], @"input_peak": secondInput[@"peak"],
                @"vocal_rms": secondVocals[@"rms"], @"vocal_peak": secondVocals[@"peak"], @"instrumental_rms": secondInstrumental[@"rms"], @"instrumental_peak": secondInstrumental[@"peak"],
                @"mix_rms": mixStats[@"rms"], @"mix_peak": mixStats[@"peak"], @"reconstruction_error_rms": errorStats[@"rms"],
                @"above_one": @([secondInput[@"out_of_range_count"] unsignedIntegerValue] + [secondVocals[@"out_of_range_count"] unsignedIntegerValue] + [secondInstrumental[@"out_of_range_count"] unsignedIntegerValue]),
                @"nan_count": @([secondInput[@"nan_count"] unsignedIntegerValue] + [secondVocals[@"nan_count"] unsignedIntegerValue] + [secondInstrumental[@"nan_count"] unsignedIntegerValue]),
                @"infinity_count": @([secondInput[@"infinity_count"] unsignedIntegerValue] + [secondVocals[@"infinity_count"] unsignedIntegerValue] + [secondInstrumental[@"infinity_count"] unsignedIntegerValue]),
                @"inference_min_ms": secondInferenceTimes.count ? [secondInferenceTimes valueForKeyPath:@"@min.doubleValue"] : @0,
                @"inference_avg_ms": secondInferenceTimes.count ? @([[secondInferenceTimes valueForKeyPath:@"@avg.doubleValue"] doubleValue]) : @0,
                @"inference_max_ms": secondInferenceTimes.count ? [secondInferenceTimes valueForKeyPath:@"@max.doubleValue"] : @0,
                @"inference_p95_ms": @(AISpatialPercentile(secondInferenceTimes, 0.95)), @"queue_wait_avg_ms": secondQueueWaitTimes.count ? @([[secondQueueWaitTimes valueForKeyPath:@"@avg.doubleValue"] doubleValue]) : @0, @"queue_depth_max": @(modelStore.inferenceQueueDepth), @"dropped_buffers": @0,
                @"memory_bytes": memoryBytes ? @(memoryBytes) : @"unavailable", @"memory_measurement_status": memoryBytes ? @"measured" : @"unavailable; task_info failed", @"errors": diagnostics.snapshot[@"errors"] ?: @0, @"warnings": diagnostics.snapshot[@"warnings"] ?: @(quietWarning || jumpWarning ? 1 : 0),
                @"dropped_buffers_status": @"not_applicable_offline", @"vocal_quiet_warning": @(quietWarning), @"rms_jump_warning": @(jumpWarning),
                @"mixture_gain": [secondInput[@"rms"] doubleValue] > 0 ? @([mixStats[@"rms"] doubleValue] / [secondInput[@"rms"] doubleValue]) : [NSNull null],
                @"input_to_vocal_db": [secondInput[@"rms"] doubleValue] > 0 && [secondVocals[@"rms"] doubleValue] > 0 ? @(20.0 * log10([secondVocals[@"rms"] doubleValue] / [secondInput[@"rms"] doubleValue])) : [NSNull null],
                @"input_to_mix_db": [secondInput[@"rms"] doubleValue] > 0 && [mixStats[@"rms"] doubleValue] > 0 ? @(20.0 * log10([mixStats[@"rms"] doubleValue] / [secondInput[@"rms"] doubleValue])) : [NSNull null],
                @"memory_measurement_time": @"timeline emission; task_info whole-process measurement", @"warning_basis": quietWarning ? @"heuristic: vocal RMS below 5% of input RMS" : (jumpWarning ? @"heuristic: input RMS changed by >4x between seconds" : @"none")
            } mutableCopy];
            [diagnostics recordSecond:secondFields];
            if (quietWarning || jumpWarning || [errorStats[@"rms"] doubleValue] > 0.01) {
                [diagnostics recordStage:@"Stage 10 - Final PCM / Export" event:@"anomaly" fields:@{ @"second": @(second), @"quiet_vocal": @(quietWarning), @"rms_jump": @(jumpWarning), @"reconstruction_error_rms": errorStats[@"rms"], @"warning_basis": secondFields[@"warning_basis"] }];
            }
            previousInputRMS = [secondInput[@"rms"] doubleValue];
            free(mixLeft); free(mixRight); free(errorLeft); free(errorRight);
        }
        NSDictionary *finalInput = AISpatialStereoRangeStats(left, right, 0, length);
        NSDictionary *finalVocals = AISpatialStereoRangeStats(vocalsLeft, vocalsRight, 0, length);
        NSDictionary *finalInstrumental = AISpatialStereoRangeStats(instrumentalLeft, instrumentalRight, 0, length);
        float reconstructionSum = 0;
        NSUInteger reconstructionCount = 0;
        for (NSUInteger i = 0; i < length; i++) {
            float dl = vocalsLeft[i] + instrumentalLeft[i] - left[i];
            float dr = vocalsRight[i] + instrumentalRight[i] - right[i];
            reconstructionSum += dl * dl + dr * dr;
            reconstructionCount += 2;
        }
        double reconstructionRMS = reconstructionCount ? sqrt((double)reconstructionSum / reconstructionCount) : 0;
        [diagnostics recordStage:@"Stage 08 - Inverse STFT" event:@"overlap_add_complete" fields:@{ @"restored_samples": @(length), @"normalization": @"vDSP real-FFT inverse 1/(2N), per-window squared-Hann normalization plus linear chunk overlap blend", @"final_vocal_stats": finalVocals, @"final_instrumental_stats": finalInstrumental }];
        [diagnostics recordStage:@"Stage 09 - Instrumental Reconstruction" event:@"mix_check" fields:@{ @"algorithm": @"instrumental = original PCM - overlap-added decoded vocal PCM", @"input_stats": finalInput, @"vocal_stats": finalVocals, @"instrumental_stats": finalInstrumental, @"reconstruction_error_rms": @(reconstructionRMS), @"reconstruction_error_status": reconstructionRMS <= 0.01 ? @"within_heuristic_threshold" : @"warning" }];
        NSArray *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *base = [(library.firstObject ?: NSTemporaryDirectory()) stringByAppendingPathComponent:@"Application Support/Croma/AI Spatial/Test Output"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *directory = [NSURL fileURLWithPath:base isDirectory:YES];
        NSError *writeError = nil;
        NSURL *vocalURL = AISpatialWriteWAV(directory, @"test-vocals.wav", vocalsLeft, vocalsRight, length, &writeError);
        NSURL *instrumentalURL = AISpatialWriteWAV(directory, @"test-instrumental.wav", instrumentalLeft, instrumentalRight, length, &writeError);
        NSError *vocalReadbackError = nil, *instrumentalReadbackError = nil;
        NSDictionary *vocalReadback = AISpatialVerifyWAV(vocalURL, vocalsLeft, vocalsRight, length, &vocalReadbackError);
        NSDictionary *instrumentalReadback = AISpatialVerifyWAV(instrumentalURL, instrumentalLeft, instrumentalRight, length, &instrumentalReadbackError);
        [diagnostics recordStage:@"Stage 10 - Final PCM / Export" event:@"wav_readback" fields:@{ @"vocals": vocalReadback, @"instrumental": instrumentalReadback, @"samples_expected": @(length), @"sample_count_match": @([vocalReadback[@"samples"] unsignedIntegerValue] == length && [instrumentalReadback[@"samples"] unsignedIntegerValue] == length), @"write_error": writeError.localizedDescription ?: @"none", @"readback_error": vocalReadbackError.localizedDescription ?: instrumentalReadbackError.localizedDescription ?: @"none" }];
        [diagnostics recordFile:vocalURL kind:@"wav-vocals" identifier:@"final" metadata:@{ @"stage": @"10-Final PCM / Export", @"selection": @"full 30-second test output; optional Full Trace archive only" }];
        [diagnostics recordFile:instrumentalURL kind:@"wav-instrumental" identifier:@"final" metadata:@{ @"stage": @"10-Final PCM / Export", @"selection": @"full 30-second test output; optional Full Trace archive only" }];
        if (diagnostics.level == AISpatialDiagnosticsLevelFullTrace) {
            [diagnostics recordBinary:AISpatialInterleavedFloatData(vocalsLeft, vocalsRight, MIN(length, (NSUInteger)(5.0 * kSampleRate))) kind:@"pcm-final-vocals" identifier:@"final" offset:0 sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"10-Final PCM / Export", @"format": @"float32 interleaved", @"duration_seconds": @(MIN(length, (NSUInteger)(5.0 * kSampleRate)) / kSampleRate) }];
            [diagnostics recordBinary:AISpatialInterleavedFloatData(instrumentalLeft, instrumentalRight, MIN(length, (NSUInteger)(5.0 * kSampleRate))) kind:@"pcm-final-instrumental" identifier:@"final" offset:0 sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"10-Final PCM / Export", @"format": @"float32 interleaved", @"duration_seconds": @(MIN(length, (NSUInteger)(5.0 * kSampleRate)) / kSampleRate) }];
            NSUInteger mixCount = MIN(length, (NSUInteger)(5.0 * kSampleRate));
            float *mixLeft = calloc(mixCount, sizeof(float)); float *mixRight = calloc(mixCount, sizeof(float));
            if (mixLeft && mixRight) {
                for (NSUInteger i = 0; i < mixCount; i++) { mixLeft[i] = vocalsLeft[i] + instrumentalLeft[i]; mixRight[i] = vocalsRight[i] + instrumentalRight[i]; }
                [diagnostics recordBinary:AISpatialInterleavedFloatData(mixLeft, mixRight, mixCount) kind:@"pcm-reconstructed" identifier:@"final" offset:0 sampleRate:kSampleRate channels:2 metadata:@{ @"stage": @"10-Final PCM / Export", @"format": @"float32 interleaved", @"duration_seconds": @(mixCount / kSampleRate), @"operation": @"vocals + instrumental" }];
            }
            free(mixLeft); free(mixRight);
        }
        [diagnostics updateMetadata:@{
            @"result": vocalURL && instrumentalURL ? @"success" : @"failed",
            @"duration_seconds": @((double)length / kSampleRate), @"sample_rate": @(kSampleRate), @"channels": @2, @"samples_written": @(length),
            @"input_stats": finalInput, @"vocals_stats": finalVocals, @"instrumental_stats": finalInstrumental, @"reconstruction_error_rms": @(reconstructionRMS),
            @"inference": @{ @"windows": @(windowStarts.count), @"completed": @(windowReports.count), @"min_ms": allInferenceTimes.count ? [allInferenceTimes valueForKeyPath:@"@min.doubleValue"] : @0, @"avg_ms": allInferenceTimes.count ? @([[allInferenceTimes valueForKeyPath:@"@avg.doubleValue"] doubleValue]) : @0, @"max_ms": allInferenceTimes.count ? [allInferenceTimes valueForKeyPath:@"@max.doubleValue"] : @0, @"p95_ms": @(AISpatialPercentile(allInferenceTimes, 0.95)) },
            @"export": @{ @"vocal_file": vocalURL ? @"test-vocals.wav" : @"unavailable", @"instrumental_file": instrumentalURL ? @"test-instrumental.wav" : @"unavailable", @"wav_format": @"float32 non-interleaved, 44100 Hz stereo", @"vocal_readback": vocalReadback, @"instrumental_readback": instrumentalReadback }
        }];
        AISpatialLog(@"offline test complete; duration=%.2fs windows=%lu input=%@ vocals=%@ instrumental=%@",
                     (double)length / kSampleRate, (unsigned long)windowStarts.count,
                     url.lastPathComponent, vocalURL.path, instrumentalURL.path);
        free(left); free(right); free(vocalsLeft); free(vocalsRight);
        free(instrumentalLeft); free(instrumentalRight); free(normalization); free(window);
        vDSP_destroy_fftsetup(setup);
        [diagnostics finishTestWithMetadata:@{ @"export_completed": @(vocalURL && instrumentalURL) }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!vocalURL || !instrumentalURL) completion(nil, nil, writeError ?: AISpatialError(@"Не удалось записать WAV"));
            else completion(vocalURL, instrumentalURL, nil);
        });
    });
}

@end
