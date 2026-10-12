#import <Foundation/Foundation.h>
#import "AISpatialStreamCore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void ASAccentDetectorSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL ASAccentDetectorIsEnabled(void);
FOUNDATION_EXPORT void ASAccentDetectorReset(void);
FOUNDATION_EXPORT void ASAccentDetectorSubmit(uint64_t epoch, uint64_t windowID,
                                               uint64_t startSample, double sampleRate,
                                               const ASStreamOutput *frames, size_t count,
                                               uint64_t availableSample);
FOUNDATION_EXPORT NSDictionary *ASAccentDetectorSnapshot(void);
FOUNDATION_EXPORT NSArray<NSDictionary *> *ASAccentDetectorRecentEvents(NSUInteger limit);
FOUNDATION_EXPORT void ASAccentDetectorSetManualLabel(NSString *eventID, NSString *label);
FOUNDATION_EXPORT void ASAccentDetectorRecordManualMissed(NSString *sampleText, NSString *source);
FOUNDATION_EXPORT NSArray<NSURL *> * _Nullable ASAccentDetectorExport(NSError **error);

@interface AISpatialAccentDetector : NSObject
+ (instancetype)sharedDetector;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) NSDictionary *snapshot;
@property(nonatomic, readonly) NSArray<NSDictionary *> *recentEvents;
- (void)setEnabled:(BOOL)enabled;
- (void)reset;
- (void)submitEpoch:(uint64_t)epoch windowID:(uint64_t)windowID startSample:(uint64_t)startSample sampleRate:(double)sampleRate frames:(const ASStreamOutput *)frames count:(size_t)count availableSample:(uint64_t)availableSample;
- (void)setManualLabel:(NSString *)label forEventID:(NSString *)eventID;
- (NSArray<NSURL *> * _Nullable)exportFiles:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
