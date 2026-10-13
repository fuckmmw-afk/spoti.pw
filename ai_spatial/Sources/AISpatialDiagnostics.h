#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <AudioToolbox/AudioToolbox.h>
#import "AISpatialMetrics.h"
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, AISpatialDiagnosticsLevel) { AISpatialDiagnosticsLevelBasic, AISpatialDiagnosticsLevelDetailed, AISpatialDiagnosticsLevelFullTrace };
FOUNDATION_EXPORT NSNotificationName const AISpatialDiagnosticsDidChangeNotification;
FOUNDATION_EXPORT NSString *AISpatialDiagnosticsLevelName(AISpatialDiagnosticsLevel level);
FOUNDATION_EXPORT NSDictionary *AISpatialMetricsDictionary(ASMetrics m);
FOUNDATION_EXPORT NSDictionary *AISpatialFloatStatistics(const float *values, NSUInteger count);
FOUNDATION_EXPORT NSDictionary *AISpatialTensorStatistics(MLMultiArray * _Nullable array);
FOUNDATION_EXPORT NSData * _Nullable AISpatialTensorData(MLMultiArray *array);
FOUNDATION_EXPORT NSString *AISpatialTensorTypeName(MLMultiArrayDataType type);
FOUNDATION_EXPORT NSString *AISpatialSHA256(NSData *data);
FOUNDATION_EXPORT double AISpatialMonotonicSeconds(void);
FOUNDATION_EXPORT NSDictionary *AISpatialMemoryMeasurement(void);
FOUNDATION_EXPORT void AISpatialDiagnosticsSetStreamingBridgeActive(BOOL active);
FOUNDATION_EXPORT void AISpatialDiagnosticsSetRealtimeCaptureEnabled(BOOL enabled);
FOUNDATION_EXPORT void AISpatialDiagnosticsSetRealtimeCaptureLevel(AISpatialDiagnosticsLevel level);
FOUNDATION_EXPORT void AISpatialDiagnosticsSetRealtimeCaptureHookAvailable(BOOL available);
FOUNDATION_EXPORT void AISpatialDiagnosticsCapturePCM(const AudioBufferList *data, UInt32 frames,
                                                       const AudioStreamBasicDescription *format,
                                                       const AudioTimeStamp *timestamp);
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureOriginalPCM(const float *left, const float *right,
                                                               UInt32 frames, double sampleRate, uint64_t sampleStart);
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureSpatialPCM(const float *left, const float *right,
                                                              UInt32 frames, double sampleRate);
// Captures the same buffer after the JamesDSP bridge has finished processing.
// This is the terminal audible PCM path used for Spatial.wav when available.
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureTerminalPCM(const float *left, const float *right,
                                                               UInt32 frames, double sampleRate);
FOUNDATION_EXPORT BOOL AISpatialDiagnosticsSynchronizedOutputActive(void);
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureSynchronizedOutput(const float *originalLeft, const float *originalRight,
    const float *preLeft, const float *preRight, const float *outputLeft, const float *outputRight,
    const float *foregroundLeft, const float *foregroundRight, UInt32 frames, double sampleRate,
    uint64_t outputSample, uint64_t epoch, UInt32 downstreamDelay);
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureEventForegroundPCM(const float *left, const float *right,
                                                                      UInt32 frames, double sampleRate);
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureEventForegroundDeltaPCM(const float *originalLeft, const float *originalRight,
                                                                           const float *spatialLeft, const float *spatialRight,
                                                                           UInt32 frames, double sampleRate);
FOUNDATION_EXPORT void AISpatialDiagnosticsCaptureEventForegroundFromSpatialPCM(const float *spatialLeft, const float *spatialRight,
                                                                                  UInt32 frames, double sampleRate);
FOUNDATION_EXPORT NSDictionary *AISpatialDiagnosticsStatusSnapshot(void);
FOUNDATION_EXPORT void AISpatialDiagnosticsStart(void);
FOUNDATION_EXPORT void AISpatialDiagnosticsStop(void);
FOUNDATION_EXPORT void AISpatialDiagnosticsSetLevelIndex(NSInteger level);
FOUNDATION_EXPORT void AISpatialDiagnosticsExport(BOOL includeDebug, void (^completion)(NSArray<NSURL *> * _Nullable files, NSError * _Nullable error));
@interface AISpatialDiagnostics : NSObject
+ (instancetype)sharedDiagnostics;
@property(nonatomic, readonly) AISpatialDiagnosticsLevel level;
@property(nonatomic, readonly) BOOL recording;
@property(nonatomic, readonly, copy, nullable) NSString *sessionID;
@property(nonatomic, readonly, copy, nullable) NSURL *sessionDirectory;
- (NSDictionary *)snapshot;
- (void)setLevel:(AISpatialDiagnosticsLevel)level;
- (void)startRecording;
- (void)beginAutomaticSessionForTest;
- (void)stopRecording;
- (void)clearLogs;
- (void)recordStage:(NSString *)stage event:(NSString *)event fields:(NSDictionary *)fields;
- (void)recordWindow:(NSDictionary *)fields processed:(BOOL)processed;
- (void)recordSecond:(NSDictionary *)fields;
// Only called on offline/analysis workers, never on a real-time callback.
- (void)recordBinary:(NSData *)data kind:(NSString *)kind identifier:(NSString *)identifier offset:(NSUInteger)offset sampleRate:(double)rate channels:(NSUInteger)channels metadata:(NSDictionary *)metadata;
- (void)recordFile:(NSURL *)file kind:(NSString *)kind identifier:(NSString *)identifier metadata:(NSDictionary *)metadata;
- (void)updateMetadata:(NSDictionary *)metadata;
- (void)finishTestWithMetadata:(NSDictionary *)metadata;
- (void)exportReportIncludingDebug:(BOOL)debug completion:(void (^)(NSArray<NSURL *> * _Nullable files, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
