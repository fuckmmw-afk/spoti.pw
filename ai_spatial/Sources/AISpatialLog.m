#import "AISpatialLog.h"

static NSObject *gLogLock;

static NSString *AISpatialLogDirectory(void) {
    NSArray<NSString *> *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *base = library.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"Caches/Croma/AI Spatial"];
}

NSString *AISpatialLogPath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:AISpatialLogDirectory()
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil];
        path = [AISpatialLogDirectory() stringByAppendingPathComponent:@"diagnostics.log"];
    });
    return path;
}

void AISpatialLog(NSString *format, ...) {
    if (!format) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ gLogLock = [NSObject new]; });

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSString *line = [NSString stringWithFormat:@"%@ [ai-spatial] %@\n",
                      [formatter stringFromDate:[NSDate date]], message];
    @synchronized (gLogLock) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:AISpatialLogPath()];
        if (!handle) {
            [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:AISpatialLogPath() atomically:YES];
            return;
        }
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
}

NSData *AISpatialLogData(void) {
    @synchronized (gLogLock ?: [NSObject new]) {
        NSData *data = [NSData dataWithContentsOfFile:AISpatialLogPath()];
        return data ?: [NSData data];
    }
}
