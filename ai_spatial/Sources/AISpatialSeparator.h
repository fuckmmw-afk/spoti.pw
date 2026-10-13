#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface AISpatialSeparator : NSObject

+ (instancetype)sharedSeparator;

// Runs the first 30 seconds (or the whole file when shorter) as an offline test.
// It never attaches to an audio unit and therefore does not intercept or alter
// JamesDSP/Spotify playback.
- (void)runTestWithAudioURL:(NSURL *)url
                 completion:(void (^)(NSURL * _Nullable vocalsURL,
                                      NSURL * _Nullable instrumentalURL,
                                      NSError * _Nullable error))completion;

@end

// Stage 02 streaming bridge.  The functions below are intentionally C-callable:
// the existing JamesDSP render hook resolves them dynamically and invokes the
// AI stage before it calls JamesDSP.  The render-side function only copies into
// bounded preallocated rings and reads already completed samples; Core ML runs
// on the worker queue.
typedef NS_ENUM(NSInteger, AISpatialLiveMode) {
    AISpatialLiveModeOriginal = 0,
    AISpatialLiveModeShadow = 1,
    AISpatialLiveModeLive = 2,
    AISpatialLiveModeVocalsOnly = 3,
    AISpatialLiveModeInstrumentalOnly = 4,
};

FOUNDATION_EXPORT void AISpatialLiveSetMode(AISpatialLiveMode mode);
FOUNDATION_EXPORT AISpatialLiveMode AISpatialLiveGetMode(void);
FOUNDATION_EXPORT void AISpatialLiveReset(double sampleRate);
FOUNDATION_EXPORT void AISpatialLiveProcessStereo(float *left, float *right, uint32_t frames,
                                                   double sampleRate,
                                                   const AudioTimeStamp *timestamp);
FOUNDATION_EXPORT NSDictionary *AISpatialLiveStatusSnapshot(void);
FOUNDATION_EXPORT void AISpatialLiveStartSpatialSelfTest(void);
FOUNDATION_EXPORT void AISpatialLiveStopSpatialSelfTest(void);
FOUNDATION_EXPORT NSDictionary *AISpatialLiveSelfTestStatusSnapshot(void);
FOUNDATION_EXPORT void AISpatialLiveRecordTerminalStereo(float *left, float *right, uint32_t frames,
                                                         double sampleRate);

NS_ASSUME_NONNULL_END
