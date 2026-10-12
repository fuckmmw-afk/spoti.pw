#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AISpatialModelStatus) {
    AISpatialModelStatusNotInstalled = 0,
    AISpatialModelStatusVerifying,
    AISpatialModelStatusDownloading,
    AISpatialModelStatusInstalling,
    AISpatialModelStatusInitializing,
    AISpatialModelStatusReady,
    AISpatialModelStatusCanceled,
    AISpatialModelStatusFailed,
};

FOUNDATION_EXPORT NSNotificationName const AISpatialModelStoreDidChangeNotification;
FOUNDATION_EXPORT NSDictionary *AISpatialModelStatusSnapshot(void);
FOUNDATION_EXPORT void AISpatialModelStartDownload(void);
FOUNDATION_EXPORT void AISpatialModelCancelDownload(void);

@interface AISpatialModelStore : NSObject

+ (instancetype)sharedStore;

@property(nonatomic, readonly) AISpatialModelStatus status;
@property(nonatomic, readonly) double progress;
@property(nonatomic, readonly, copy) NSString *statusText;
@property(nonatomic, readonly, copy, nullable) NSString *lastError;
@property(nonatomic, readonly, copy, nullable) NSURL *modelURL;
@property(nonatomic, readonly) BOOL modelIsReady;
@property(nonatomic, readonly) NSUInteger inferenceQueueDepth;
@property(nonatomic, readonly, copy) NSDictionary *lastInferenceMetrics;

- (NSDictionary *)diagnosticMetadata;
// Streaming completion never depends on the main/UI queue.
- (void)predictStreamingSpectrum:(MLMultiArray *)spectrum windowID:(NSUInteger)windowID
                     completion:(void (^)(MLMultiArray * _Nullable vocals, NSError * _Nullable error))completion;

- (void)startDownload;
- (void)cancelDownload;
- (void)retryDownload;
- (void)deleteModel;
- (void)loadModelIfInstalled;

// The model is used only through this store. JamesDSP does not participate in this call.
- (void)predictSpectrum:(MLMultiArray *)spectrum
             completion:(void (^)(MLMultiArray * _Nullable vocals, NSError * _Nullable error))completion;
- (void)predictSpectrum:(MLMultiArray *)spectrum
               windowID:(NSUInteger)windowID
             completion:(void (^)(MLMultiArray * _Nullable vocals, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
