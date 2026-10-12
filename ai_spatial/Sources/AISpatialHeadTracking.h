#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Optional adapter.  Spatial playback never depends on it: when unavailable
 * the renderer remains a static scene and no permission prompt is generated. */
@interface AISpatialHeadTracking : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) float yaw;
- (void)startIfAuthorized;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
