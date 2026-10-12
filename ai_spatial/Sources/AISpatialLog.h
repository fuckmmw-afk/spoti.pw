#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *AISpatialLogPath(void);
FOUNDATION_EXPORT void AISpatialLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT NSData *AISpatialLogData(void);
