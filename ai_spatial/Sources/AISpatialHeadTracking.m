#import "AISpatialHeadTracking.h"
#import <CoreMotion/CoreMotion.h>

@interface AISpatialHeadTracking ()
@property(nonatomic) CMHeadphoneMotionManager *manager;
@property(nonatomic) BOOL active;
@property(nonatomic) float yaw;
@end

@implementation AISpatialHeadTracking
+ (instancetype)shared { static AISpatialHeadTracking *s; static dispatch_once_t once; dispatch_once(&once, ^{ s=[self new]; }); return s; }
- (instancetype)init { if ((self=[super init])) { _manager=[CMHeadphoneMotionManager new]; } return self; }
- (BOOL)available { return _manager.isDeviceMotionAvailable; }
- (void)startIfAuthorized {
    if (!self.available || [CMHeadphoneMotionManager authorizationStatus] != CMAuthorizationStatusAuthorized) return;
    if (self.active) return;
    __weak typeof(self) weakSelf=self;
    [_manager startDeviceMotionUpdatesToQueue:[NSOperationQueue new] withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (error || !motion) return;
        __strong typeof(weakSelf) self=weakSelf; if (!self) return;
        self.yaw=(float)motion.attitude.yaw;
    }];
    self.active=YES;
}
- (void)stop { if (self.active) [_manager stopDeviceMotionUpdates]; self.active=NO; self.yaw=0; }
@end
