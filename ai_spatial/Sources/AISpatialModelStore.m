#import "AISpatialModelStore.h"
#import "AISpatialLog.h"
#import "AISpatialDiagnostics.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const AISpatialModelStoreDidChangeNotification = @"AISpatialModelStoreDidChangeNotification";

static NSString *const kModelPage = @"https://huggingface.co/My-Name-Is-Jeff/vitrine-sing";
static NSString *const kModelRevision = @"f17db769d3dc066f4690e842f058a34b00593252";
static NSString *const kModelDirectory = @"separator-ane.mlmodelc";

static NSArray<NSDictionary<NSString *, id> *> *AISpatialManifest(void) {
    // This is a manifest of small metadata files and the model's remote checksums only.
    // No model bytes are present in the tweak or in a CI artifact.
    static NSArray *manifest;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manifest = @[
            @{ @"path": @"separator-ane.mlmodelc/analytics/coremldata.bin", @"size": @243, @"sha256": @"55f78aab64f5b1250ce4d6016dff23aee43fb97feb77bbceab4e36b3d9ccffb3" },
            @{ @"path": @"separator-ane.mlmodelc/coremldata.bin", @"size": @388, @"sha256": @"bcfd38a8b121681dfb9fdfe6f9d88ffb29068e0dd6d24d4012f4c3a7bdcbc81b" },
            @{ @"path": @"separator-ane.mlmodelc/metadata.json", @"size": @2333, @"sha256": @"101714d1a37ad29c70bf1705ec25ec99584c3cbce27f2245858ace06dacbfb44" },
            @{ @"path": @"separator-ane.mlmodelc/model.mil", @"size": @1346642, @"sha256": @"957024c1075fe331f7ca3410b8bf5e2f83a58c61763caf154729829ce0a92d08" },
            @{ @"path": @"separator-ane.mlmodelc/weights/weight.bin", @"size": @209077208, @"sha256": @"bb4a0effafb5121b9aaa5ea96371fa14d0d8dc30a5ae44a93e0c15a2f4077635" },
        ];
    });
    return manifest;
}

static NSString *AISpatialHexDigestAtURL(NSURL *url, NSError **error) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:error];
    if (!handle) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    while (true) {
        NSData *chunk = [handle readDataOfLength:1024 * 1024];
        if (!chunk.length) break;
        CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *AISpatialModelRoot(void) {
    NSArray *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *base = library.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"Application Support/Croma/AI Spatial/Models/vitrine-sing"];
}

@interface AISpatialModelStore () <NSURLSessionDownloadDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, readwrite) AISpatialModelStatus status;
@property(nonatomic, readwrite) double progress;
@property(nonatomic, readwrite, copy) NSString *statusText;
@property(nonatomic, readwrite, copy, nullable) NSString *lastError;
@property(nonatomic, readwrite, copy, nullable) NSURL *modelURL;
@property(nonatomic, readwrite) BOOL modelIsReady;
@end

@implementation AISpatialModelStore {
    dispatch_queue_t _queue;
    NSOperationQueue *_delegateQueue;
    NSURLSession *_session;
    NSURLSessionDownloadTask *_task;
    NSUInteger _fileIndex;
    int64_t _bytesDone;
    int64_t _totalBytes;
    BOOL _cancelRequested;
    MLModel *_model;
    NSUInteger _inferenceQueueDepth;
    NSDictionary *_lastInferenceMetrics;
}

+ (instancetype)sharedStore {
    static AISpatialModelStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [self new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("pw.chroma.ai-spatial.model", DISPATCH_QUEUE_SERIAL);
    _delegateQueue = [NSOperationQueue new];
    _delegateQueue.maxConcurrentOperationCount = 1;
    _status = AISpatialModelStatusNotInstalled;
    _statusText = @"Модель не скачана";
    _totalBytes = 0;
    for (NSDictionary *spec in AISpatialManifest()) _totalBytes += [spec[@"size"] longLongValue];
    [self loadModelIfInstalled];
    return self;
}

- (void)loadModelIfInstalled {
    dispatch_async(_queue, ^{ [self verifyInstalledModelLocked]; });
}

- (void)startDownload {
    dispatch_async(_queue, ^{
        if (_status == AISpatialModelStatusDownloading || _status == AISpatialModelStatusVerifying || _status == AISpatialModelStatusInstalling) return;
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18) {
            [self failLocked:@"Mel-Band RoFormer ANE требует iOS 18 или новее; скачивание не начато"];
            return;
        }
        _cancelRequested = NO;
        _modelIsReady = NO;
        _model = nil;
        _lastError = nil;
        _bytesDone = 0;
        _fileIndex = 0;
        [self setState:AISpatialModelStatusVerifying text:@"Проверка уже скачанных файлов" error:nil progress:0];
        [self ensureDirectoriesLocked];
        [self downloadNextFileLocked];
    });
}

- (void)cancelDownload {
    dispatch_async(_queue, ^{
        if (_status != AISpatialModelStatusDownloading && _status != AISpatialModelStatusVerifying &&
            _status != AISpatialModelStatusInstalling && _status != AISpatialModelStatusInitializing) return;
        _cancelRequested = YES;
        [_task cancel];
        [_session invalidateAndCancel];
        _task = nil;
        [self setState:AISpatialModelStatusCanceled text:@"Загрузка отменена" error:nil progress:_progress];
        AISpatialLog(@"download cancelled by user");
    });
}

- (void)retryDownload {
    [self startDownload];
}

- (void)deleteModel {
    dispatch_async(_queue, ^{
        _cancelRequested = YES;
        [_task cancel];
        [_session invalidateAndCancel];
        _task = nil;
        _model = nil;
        _modelURL = nil;
        _modelIsReady = NO;
        [[NSFileManager defaultManager] removeItemAtPath:AISpatialModelRoot() error:nil];
        [self setState:AISpatialModelStatusNotInstalled text:@"Модель удалена" error:nil progress:0];
        AISpatialLog(@"model deleted");
    });
}

- (void)ensureDirectoriesLocked {
    [[NSFileManager defaultManager] createDirectoryAtPath:AISpatialModelRoot()
                               withIntermediateDirectories:YES attributes:nil error:nil];
}

- (NSURL *)urlForSpec:(NSDictionary *)spec {
    NSString *escaped = [spec[@"path"] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *string = [NSString stringWithFormat:@"https://huggingface.co/My-Name-Is-Jeff/vitrine-sing/resolve/%@/%@?download=true", kModelRevision, escaped];
    return [NSURL URLWithString:string];
}

- (NSURL *)localURLForSpec:(NSDictionary *)spec {
    return [NSURL fileURLWithPath:[AISpatialModelRoot() stringByAppendingPathComponent:spec[@"path"]]];
}

- (BOOL)verifyFile:(NSDictionary *)spec error:(NSError **)error {
    NSURL *url = [self localURLForSpec:spec];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:error];
    if (!attributes || [attributes[NSFileSize] longLongValue] != [spec[@"size"] longLongValue]) return NO;
    NSString *digest = AISpatialHexDigestAtURL(url, error);
    if (!digest || ![digest.lowercaseString isEqualToString:[spec[@"sha256"] lowercaseString]]) {
        if (error) *error = [NSError errorWithDomain:@"AISpatialModel" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"SHA-256 mismatch for %@", spec[@"path"]]}];
        return NO;
    }
    return YES;
}

- (void)downloadNextFileLocked {
    if (_cancelRequested) return;
    NSArray *manifest = AISpatialManifest();
    while (_fileIndex < manifest.count) {
        NSDictionary *spec = manifest[_fileIndex];
        NSError *verifyError = nil;
        if ([self verifyFile:spec error:&verifyError]) {
            _bytesDone += [spec[@"size"] longLongValue];
            _fileIndex++;
            continue;
        }
        NSURL *local = [self localURLForSpec:spec];
        [[NSFileManager defaultManager] createDirectoryAtPath:local.URLByDeletingLastPathComponent.path withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:local error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:[NSURL fileURLWithPath:[local.path stringByAppendingString:@".part"]] error:nil];

        [self setState:AISpatialModelStatusDownloading text:[NSString stringWithFormat:@"Скачивание файла %lu из %lu", (unsigned long)_fileIndex + 1, (unsigned long)manifest.count] error:nil progress:(double)_bytesDone / (double)_totalBytes];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 60;
        configuration.timeoutIntervalForResource = 60 * 60;
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegateQueue];
        _task = [_session downloadTaskWithURL:[self urlForSpec:spec]];
        [_task resume];
        return;
    }
    [self finishVerificationAndLoadLocked];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    dispatch_async(_queue, ^{
        if (self->_cancelRequested || downloadTask != self->_task) return;
        int64_t expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : [AISpatialManifest()[self->_fileIndex][@"size"] longLongValue];
        double p = (double)(self->_bytesDone + MIN(totalBytesWritten, expected)) / (double)MAX(self->_totalBytes, 1);
        [self setState:AISpatialModelStatusDownloading text:self.statusText error:nil progress:p];
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    // The URL passed to this delegate method is owned by NSURLSession and is
    // removed as soon as this method returns. Stage it synchronously before
    // dispatching any work to the model serial queue.
    if (_cancelRequested || downloadTask != _task) return;
    NSDictionary *spec = AISpatialManifest()[_fileIndex];
    NSURL *local = [self localURLForSpec:spec];
    NSURL *part = [NSURL fileURLWithPath:[local.path stringByAppendingString:@".part"]];
    AISpatialLog(@"staging download callback: source=%@ destination=%@", location.lastPathComponent ?: @"(nil)", part.path);
    NSError *stageError = nil;
    NSString *parentPath = part.URLByDeletingLastPathComponent.path;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:parentPath
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&stageError]) {
        dispatch_async(_queue, ^{
            [self failLocked:[NSString stringWithFormat:@"Не удалось создать папку модели: %@", stageError.localizedDescription ?: @"unknown error"]];
        });
        return;
    }
    [[NSFileManager defaultManager] removeItemAtURL:part error:nil];
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:part error:&stageError]) {
        NSError *copyError = nil;
        if (![[NSFileManager defaultManager] copyItemAtURL:location toURL:part error:&copyError]) {
            NSString *detail = copyError.localizedDescription ?: stageError.localizedDescription ?: @"unknown error";
            dispatch_async(_queue, ^{
                [self failLocked:[NSString stringWithFormat:@"Не удалось сохранить файл: %@", detail]];
            });
            return;
        }
        [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
        AISpatialLog(@"download callback used copy fallback for %@", spec[@"path"]);
    }

    dispatch_async(_queue, ^{
        if (self->_cancelRequested || downloadTask != self->_task) return;
        NSError *error = nil;
        NSURL *localURL = [self localURLForSpec:spec];
        if (![[NSFileManager defaultManager] moveItemAtURL:part toURL:localURL error:&error]) {
            [self failLocked:[NSString stringWithFormat:@"Не удалось установить файл: %@", error.localizedDescription ?: @"unknown error"]];
            return;
        }
        if (![self verifyFile:spec error:&error]) {
            [[NSFileManager defaultManager] removeItemAtURL:localURL error:nil];
            [self failLocked:[NSString stringWithFormat:@"Проверка целостности не пройдена: %@", error.localizedDescription ?: @"SHA-256 mismatch"]];
            return;
        }
        self->_bytesDone += [spec[@"size"] longLongValue];
        self->_fileIndex++;
        [self->_session invalidateAndCancel];
        self->_session = nil;
        self->_task = nil;
        [self downloadNextFileLocked];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return;
    dispatch_async(_queue, ^{
        if (self->_cancelRequested || error.code == NSURLErrorCancelled) return;
        [self failLocked:[NSString stringWithFormat:@"Загрузка остановлена: %@", error.localizedDescription]];
    });
}

- (void)verifyInstalledModelLocked {
    [self setState:AISpatialModelStatusVerifying text:@"Проверка файлов модели" error:nil progress:0];
    int64_t done = 0;
    for (NSDictionary *spec in AISpatialManifest()) {
        NSError *error = nil;
        if (![self verifyFile:spec error:&error]) {
            [self setState:AISpatialModelStatusNotInstalled text:@"Модель не скачана" error:nil progress:0];
            return;
        }
        done += [spec[@"size"] longLongValue];
        [self setState:AISpatialModelStatusVerifying text:@"Проверка файлов модели" error:nil progress:(double)done / (double)_totalBytes];
    }
    [self finishVerificationAndLoadLocked];
}

- (void)finishVerificationAndLoadLocked {
    if (_cancelRequested) return;
    [self setState:AISpatialModelStatusInstalling text:@"Проверка совместимости Core ML" error:nil progress:1];
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18) {
        [self setState:AISpatialModelStatusInitializing text:@"Инициализация Neural Engine (первый запуск может быть долгим)" error:nil progress:1];
        NSURL *url = [NSURL fileURLWithPath:[AISpatialModelRoot() stringByAppendingPathComponent:kModelDirectory]];
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
        NSError *error = nil;
        MLModel *model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&error];
        if (!model) {
            [self failLocked:[NSString stringWithFormat:@"Core ML не загрузил модель: %@", error.localizedDescription ?: @"unknown error"]];
            return;
        }
        MLFeatureDescription *input = model.modelDescription.inputDescriptionsByName[@"spectrum"];
        MLFeatureDescription *output = model.modelDescription.outputDescriptionsByName[@"vocals_spectrum"];
        NSArray<NSNumber *> *shape = input.multiArrayConstraint.shape;
        NSArray<NSNumber *> *outputShape = output.multiArrayConstraint.shape;
        NSArray *expected = @[@1, @2050, @201, @2];
        if (!input || !output || input.type != MLFeatureTypeMultiArray || output.type != MLFeatureTypeMultiArray || ![shape isEqualToArray:expected] || ![outputShape isEqualToArray:expected]) {
            [self failLocked:@"Модель несовместима: ожидались spectrum/vocals_spectrum [1,2050,201,2]"];
            return;
        }
        _model = model;
        _modelURL = url;
        _modelIsReady = YES;
        _bytesDone = _totalBytes;
        [self setState:AISpatialModelStatusReady text:@"Модель готова к локальному разделению" error:nil progress:1];
        AISpatialLog(@"model ready; computeUnits=CPU_AND_NEURAL_ENGINE; model=%@", url.path);
        [[AISpatialDiagnostics sharedDiagnostics] updateMetadata:@{
            @"model": @{
                @"revision": kModelRevision,
                @"local_path": @"app-private model directory (redacted)",
                @"requested_compute_units": @"CPU_AND_NEURAL_ENGINE",
                @"provider_usage": @"unavailable; Core ML does not expose per-window CPU/GPU/ANE counters to this injected process",
                @"input_name": @"spectrum",
                @"output_name": @"vocals_spectrum",
                @"spectral_layout": @"dimension 1 = bin*2 + channel; dimension 3 = real/imaginary",
                @"output_semantics": @"complex vocal spectrum; instrumental is reconstructed as time-domain residual",
                @"input_shape": shape ?: @[],
                @"output_shape": outputShape ?: @[],
                @"input_dtype": AISpatialTensorTypeName(input.multiArrayConstraint.dataType),
                @"output_dtype": AISpatialTensorTypeName(output.multiArrayConstraint.dataType),
                @"manifest_revision": kModelRevision,
                @"ane_model_mil_sha256": @"957024c1075fe331f7ca3410b8bf5e2f83a58c61763caf154729829ce0a92d08",
                @"ane_weight_sha256": @"bb4a0effafb5121b9aaa5ea96371fa14d0d8dc30a5ae44a93e0c15a2f4077635",
            }
        }];
        [[AISpatialDiagnostics sharedDiagnostics] recordStage:@"Stage 06 - Core ML Inference" event:@"model_ready" fields:@{
            @"revision": kModelRevision,
            @"compute_units_requested": @"CPU_AND_NEURAL_ENGINE",
            @"provider_usage": @"unavailable",
            @"input_name": @"spectrum",
            @"output_name": @"vocals_spectrum",
            @"spectral_layout": @"dimension 1 = bin*2 + channel; dimension 3 = real/imaginary",
            @"output_semantics": @"complex vocal spectrum; instrumental is reconstructed as time-domain residual",
            @"shape": shape ?: @[],
            @"output_shape": outputShape ?: @[],
        }];
    } else {
        [self failLocked:@"Эта модель требует iOS 18 или новее"];
    }
}

- (void)predictSpectrum:(MLMultiArray *)spectrum completion:(void (^)(MLMultiArray *, NSError *))completion {
    [self predictSpectrum:spectrum windowID:0 completion:completion];
}

- (void)predictSpectrum:(MLMultiArray *)spectrum windowID:(NSUInteger)windowID completion:(void (^)(MLMultiArray *, NSError *))completion {
    [self predictSpectrum:spectrum windowID:windowID completionQueue:dispatch_get_main_queue() completion:completion];
}
- (void)predictStreamingSpectrum:(MLMultiArray *)spectrum windowID:(NSUInteger)windowID completion:(void (^)(MLMultiArray *, NSError *))completion {
    [self predictSpectrum:spectrum windowID:windowID completionQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) completion:completion];
}
- (void)predictSpectrum:(MLMultiArray *)spectrum windowID:(NSUInteger)windowID completionQueue:(dispatch_queue_t)completionQueue completion:(void (^)(MLMultiArray *, NSError *))completion {
    if (!completion) return;
    CFAbsoluteTime enqueuedAt = CFAbsoluteTimeGetCurrent();
    @synchronized (self) { _inferenceQueueDepth++; }
    dispatch_async(_queue, ^{
        CFAbsoluteTime queueStartedAt = CFAbsoluteTimeGetCurrent();
        NSUInteger queueDepth;
        @synchronized (self) {
            if (self->_inferenceQueueDepth > 0) self->_inferenceQueueDepth--;
            queueDepth = self->_inferenceQueueDepth;
        }
        double queueWaitMilliseconds = (queueStartedAt - enqueuedAt) * 1000.0;
        NSMutableDictionary *inputFields = [@{
            @"window_id": @(windowID),
            @"input_name": @"spectrum",
            @"shape": spectrum.shape ?: @[],
            @"strides": spectrum.strides ?: @[],
            @"dtype": AISpatialTensorTypeName(spectrum.dataType),
            @"queue_wait_ms": @(queueWaitMilliseconds),
            @"queue_depth": @(queueDepth),
        } mutableCopy];
        [inputFields addEntriesFromDictionary:AISpatialTensorStatistics(spectrum)];
        [[AISpatialDiagnostics sharedDiagnostics] recordStage:@"Stage 05 - Core ML Input" event:@"tensor_ready" fields:inputFields];
        if (!self->_model) {
            NSError *error = [NSError errorWithDomain:@"AISpatialModel" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Модель ещё не инициализирована"}];
            [[AISpatialDiagnostics sharedDiagnostics] recordStage:@"Stage 06 - Core ML Inference" event:@"error" fields:@{ @"window_id": @(windowID), @"error": error.localizedDescription ?: @"unavailable", @"queue_wait_ms": @(queueWaitMilliseconds) }];
            dispatch_async(completionQueue, ^{ completion(nil, error); });
            return;
        }
        CFAbsoluteTime inferenceStartedAt = CFAbsoluteTimeGetCurrent();
        NSDictionary *memoryBefore = AISpatialMemoryMeasurement();
        NSError *error = nil;
        MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"spectrum": spectrum } error:&error];
        id<MLFeatureProvider> result = provider ? [self->_model predictionFromFeatures:provider error:&error] : nil;
        MLMultiArray *vocals = [result featureValueForName:@"vocals_spectrum"].multiArrayValue;
        NSArray *expectedShape = @[@1, @2050, @201, @2];
        BOOL outputContractMatches = vocals && [vocals.shape isEqualToArray:expectedShape];
        if (vocals && !outputContractMatches && !error) {
            error = [NSError errorWithDomain:@"AISpatialModel" code:12 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Core ML output shape %@ does not match %@", vocals.shape, expectedShape]}];
        }
        double inferenceMilliseconds = (CFAbsoluteTimeGetCurrent() - inferenceStartedAt) * 1000.0;
        NSMutableDictionary *outputFields = [@{
            @"window_id": @(windowID),
            @"output_name": @"vocals_spectrum",
            @"queue_wait_ms": @(queueWaitMilliseconds),
            @"inference_ms": @(inferenceMilliseconds),
            @"queue_depth": @(queueDepth),
            @"status": vocals && !error ? @"completed" : @"failed",
            @"memory_before": memoryBefore,
            @"memory_after": AISpatialMemoryMeasurement(),
            @"contract_expected": expectedShape,
            @"contract_matches": @(outputContractMatches),
        } mutableCopy];
        [[AISpatialDiagnostics sharedDiagnostics] recordStage:@"Stage 06 - Core ML Inference" event:vocals && !error ? @"window_inference" : @"error" fields:@{
            @"window_id": @(windowID), @"queue_wait_ms": @(queueWaitMilliseconds), @"inference_ms": @(inferenceMilliseconds), @"queue_depth": @(queueDepth), @"status": vocals && !error ? @"completed" : @"failed", @"memory_before": memoryBefore, @"memory_after": AISpatialMemoryMeasurement(), @"error": error.localizedDescription ?: @"none"
        }];
        [outputFields addEntriesFromDictionary:AISpatialTensorStatistics(vocals)];
        @synchronized (self) { self->_lastInferenceMetrics = @{ @"window_id": @(windowID), @"queue_wait_ms": @(queueWaitMilliseconds), @"inference_ms": @(inferenceMilliseconds), @"queue_depth": @(queueDepth), @"status": vocals && !error ? @"completed" : @"failed" }; }
        [[AISpatialDiagnostics sharedDiagnostics] recordStage:@"Stage 07 - Core ML Output" event:vocals && !error ? @"window_complete" : @"error" fields:outputFields];
        dispatch_async(completionQueue, ^{ completion(vocals, error); });
    });
}

- (void)setState:(AISpatialModelStatus)status text:(NSString *)text error:(NSString *)error progress:(double)progress {
    AISpatialModelStatus previous;
    @synchronized (self) {
        previous = _status;
        _status = status;
        _statusText = [text copy] ?: @"";
        _lastError = [error copy];
        _progress = MIN(MAX(progress, 0), 1);
    }
    if (previous != status) AISpatialLog(@"state=%ld text=%@ progress=%.3f", (long)status, text ?: @"", progress);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AISpatialModelStoreDidChangeNotification object:self];
    });
}

- (void)failLocked:(NSString *)message {
    _model = nil;
    _modelURL = nil;
    _modelIsReady = NO;
    _cancelRequested = YES;
    [_task cancel];
    [_session invalidateAndCancel];
    _task = nil;
    AISpatialLog(@"error: %@", message);
    [self setState:AISpatialModelStatusFailed text:@"Ошибка модели" error:message progress:_progress];
}

- (AISpatialModelStatus)status { @synchronized (self) { return _status; } }
- (double)progress { @synchronized (self) { return _progress; } }
- (NSString *)statusText { @synchronized (self) { return [_statusText copy]; } }
- (NSString *)lastError { @synchronized (self) { return [_lastError copy]; } }
- (NSURL *)modelURL { @synchronized (self) { return [_modelURL copy]; } }
- (BOOL)modelIsReady { @synchronized (self) { return _modelIsReady; } }
- (NSUInteger)inferenceQueueDepth { @synchronized (self) { return _inferenceQueueDepth; } }
- (NSDictionary *)lastInferenceMetrics { @synchronized (self) { return [_lastInferenceMetrics copy] ?: @{}; } }

- (NSDictionary *)diagnosticMetadata {
    @synchronized (self) {
        if (!_model) return @{ @"status": @"not_ready", @"reason": _lastError ?: @"model is not initialized" };
        MLFeatureDescription *input = _model.modelDescription.inputDescriptionsByName[@"spectrum"];
        MLFeatureDescription *output = _model.modelDescription.outputDescriptionsByName[@"vocals_spectrum"];
        return @{ @"status": @"ready", @"revision": @"f17db769d3dc066f4690e842f058a34b00593252", @"local_path": @"app-private model directory (redacted)", @"requested_compute_units": @"CPU_AND_NEURAL_ENGINE", @"provider_usage": @"unavailable; Core ML does not expose per-window CPU/GPU/ANE counters", @"input_name": @"spectrum", @"output_name": @"vocals_spectrum", @"input_shape": input.multiArrayConstraint.shape ?: @[], @"output_shape": output.multiArrayConstraint.shape ?: @[], @"input_dtype": AISpatialTensorTypeName(input.multiArrayConstraint.dataType), @"output_dtype": AISpatialTensorTypeName(output.multiArrayConstraint.dataType), @"ane_model_mil_sha256": @"957024c1075fe331f7ca3410b8bf5e2f83a58c61763caf154729829ce0a92d08", @"ane_weight_sha256": @"bb4a0effafb5121b9aaa5ea96371fa14d0d8dc30a5ae44a93e0c15a2f4077635" };
    }
}

@end
