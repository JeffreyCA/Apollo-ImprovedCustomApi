#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import <QuartzCore/QuartzCore.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <OSLog/OSLog.h>
#import <os/lock.h>
#import <Security/Security.h>

#pragma mark - Security dictionaries

CFDictionaryRef ApolloCreateGenericPasswordIdentity(CFStringRef service,
                                                     CFStringRef account) {
    const void *keys[] = { kSecClass, kSecAttrService, kSecAttrAccount };
    const void *values[] = { kSecClassGenericPassword, service, account };
    return CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
}

CFDictionaryRef ApolloCreateGenericPasswordDataQuery(CFStringRef service,
                                                      CFStringRef account) {
    // kSecMatchLimitOne is the default, so spelling it out only makes the
    // dictionary larger and costs another retain/hash during construction.
    const void *keys[] = { kSecClass, kSecAttrService, kSecAttrAccount, kSecReturnData };
    const void *values[] = { kSecClassGenericPassword, service, account, kCFBooleanTrue };
    return CFDictionaryCreate(kCFAllocatorDefault, keys, values, 4,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
}

static CFDictionaryRef ApolloCreateGenericPasswordDataAdd(CFStringRef service,
                                                           CFStringRef account,
                                                           NSData *data,
                                                           CFStringRef accessible) CF_RETURNS_RETAINED {
    const void *keys[] = {
        kSecClass, kSecAttrService, kSecAttrAccount, kSecValueData, kSecAttrAccessible,
    };
    const void *values[] = {
        kSecClassGenericPassword, service, account, (__bridge CFDataRef)data, accessible,
    };
    return CFDictionaryCreate(kCFAllocatorDefault, keys, values, 5,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
}

OSStatus ApolloUpsertGenericPasswordData(CFStringRef service,
                                         CFStringRef account,
                                         NSData *data,
                                         CFStringRef accessible) {
    CFDictionaryRef identity = ApolloCreateGenericPasswordIdentity(service, account);
    NSDictionary *update = @{ (__bridge id)kSecValueData: data };
    OSStatus status = SecItemUpdate(identity, (__bridge CFDictionaryRef)update);
    if (status == errSecItemNotFound) {
        CFDictionaryRef add =
            ApolloCreateGenericPasswordDataAdd(service, account, data, accessible);
        status = SecItemAdd(add, NULL);
        CFRelease(add);
        // Another writer may have inserted the item between our update and
        // add. Retry the update once so that benign race still succeeds.
        if (status == errSecDuplicateItem) {
            status = SecItemUpdate(identity, (__bridge CFDictionaryRef)update);
        }
    }
    CFRelease(identity);
    return status;
}

#pragma mark - Logging

static NSDate *sProcessStartDate = nil;

os_log_t ApolloFixLog(void) {
    static os_log_t log = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("apollofix", "tweak");
        sProcessStartDate = [NSDate date];
    });
    return log;
}

#pragma mark - Row-measure re-entrancy guard

// See ApolloCommon.h. Main-thread only: row-height queries are delivered on
// the main thread, and the recursion this guards against exists only there
// (background Texture measures never sit inside UIKit row-data validation).
// Off-main callers get NO / no-op so they behave exactly as before.
static NSInteger sApolloRowMeasureDepth = 0;

BOOL ApolloRowMeasureInProgress(void) {
    return [NSThread isMainThread] && sApolloRowMeasureDepth > 0;
}

void ApolloRowMeasureWillBegin(void) {
    if (![NSThread isMainThread]) return;
    sApolloRowMeasureDepth++;
    // A depth beyond 1 means a geometry query escaped into a measure pass and
    // UIKit re-entered row validation — the #831/#833 stack-overflow geometry.
    // The guards should make this unreachable; log loudly (but bounded) if a
    // new edge ever appears so field reports pinpoint it.
    static NSInteger sLoggedNestedMeasures = 0;
    if (sApolloRowMeasureDepth > 1 && sLoggedNestedMeasures < 8) {
        sLoggedNestedMeasures++;
        ApolloLog(@"[RowMeasure] NESTED row-height pass (depth %ld) - a table geometry call leaked into a measure pass", (long)sApolloRowMeasureDepth);
    }
}

void ApolloRowMeasureDidEnd(void) {
    if (![NSThread isMainThread]) return;
    if (sApolloRowMeasureDepth > 0) sApolloRowMeasureDepth--;
}

#pragma mark - Persistent login diagnostics (cross-launch)

// The os_log export (ApolloCollectLogs) only sees the current process, so a force-quit
// sign-out discards the session that actually wiped the account. To make that case
// diagnosable, the login-persistence tags ([KeychainTrace], [AccountSnapshot],
// [KeychainSelfHeal], [KeychainMirror]) are ALSO appended to a file in the app container that
// survives relaunch. The exporter prepends this file, so a user's Export Debug Logs carries the
// prior session even after a force-quit. Bounded to a tail so it can't grow without limit;
// file-protected at rest (it can contain account-item byte lengths, never values or tokens).
static NSString *ApolloLoginDiagLogPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]
                stringByAppendingPathComponent:@"ApolloLoginDiag.log"];
}

static const NSUInteger kApolloPersistentDiagMaxBytes = 256 * 1024; // ~256KB tail is plenty of sessions
// When trimming, drop back to this (not just under the cap) so the next ~64KB of lines don't each
// re-trigger a full read+rewrite of the file. Without the headroom, once the buffer is at capacity
// every single append would rewrite the whole file — expensive on the keychain hot path.
static const NSUInteger kApolloPersistentDiagTrimTo = 192 * 1024;

static void ApolloAppendPersistentDiag(NSString *line, NSString *path) {
    if (![line isKindOfClass:[NSString class]] || line.length == 0) return;
    static dispatch_queue_t queue = nil;
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The list-layout diag can fire from inside setContentInset: during a
        // scroll frame, so the file I/O must never run on the caller's thread.
        // A serial utility queue keeps line order without blocking anyone; the
        // only loss window is lines still queued at a hard crash (~ms), which
        // the os_log copy of every line still covers.
        queue = dispatch_queue_create("com.apollo.reborn.persistent-diag",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    // Stamp on the calling thread so the timestamp is the event time, not the
    // (slightly later) write time. NSDateFormatter is thread-safe on iOS 7+.
    NSString *stamped = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    dispatch_async(queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [fm createFileAtPath:path contents:nil
                          attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
                fh = [NSFileHandle fileHandleForWritingAtPath:path];
            }
            if (fh) {
                unsigned long long end = [fh seekToEndOfFile];
                [fh writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
                // Trim to the tail when it grows past the cap: reload, keep the last N bytes from a
                // line boundary, rewrite. Cheap because it only fires occasionally.
                if (end + stamped.length > kApolloPersistentDiagMaxBytes) {
                    NSData *all = [NSData dataWithContentsOfFile:path];
                    if (all.length > kApolloPersistentDiagMaxBytes) {
                        NSData *tail = [all subdataWithRange:NSMakeRange(all.length - kApolloPersistentDiagTrimTo, kApolloPersistentDiagTrimTo)];
                        NSString *tailStr = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
                        NSRange nl = [tailStr rangeOfString:@"\n"];
                        if (nl.location != NSNotFound && nl.location + 1 < tailStr.length) {
                            tailStr = [tailStr substringFromIndex:nl.location + 1];
                        }
                        [tailStr writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    }
                }
            }
        } @catch (__unused NSException *e) {
            // Diagnostics must never take the app down; a lost line is acceptable.
        }
    });
}

void ApolloAppendLoginDiag(NSString *line) {
    ApolloAppendPersistentDiag(line, ApolloLoginDiagLogPath());
}

static NSString *ApolloListLayoutDiagLogPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library"]
                stringByAppendingPathComponent:@"ApolloListLayoutDiag.log"];
}

void ApolloAppendListLayoutDiag(NSString *line) {
    ApolloAppendPersistentDiag(line, ApolloListLayoutDiagLogPath());
}

#pragma mark - Liquid Glass tab bar morph state (private-ivar reads)

// Single-slot Ivar caches: Apollo runs one tab bar class and one visual
// provider class per process, and these reads sit on scroll-frame paths
// (ApolloAutoHideTabBar's upward-reveal detection, the list bottom-inset
// guard), where repeated class_getInstanceVariable lookups would pay a
// runtime-lock toll per frame. Main-thread only, so plain statics suffice.
static id ApolloTabBarVisualProvider(UITabBar *tabBar) {
    if (!tabBar) return nil;
    static Class barClass = Nil;
    static Ivar providerIvar = NULL;
    Class cls = object_getClass(tabBar);
    if (cls != barClass) {
        providerIvar = class_getInstanceVariable(cls, "_visualProvider");
        barClass = cls;
    }
    return providerIvar ? object_getIvar(tabBar, providerIvar) : nil;
}

NSInteger ApolloTabBarVisualMorphTarget(UITabBar *tabBar, BOOL *known) {
    if (known) *known = NO;
    id provider = ApolloTabBarVisualProvider(tabBar);
    if (!provider) return NSNotFound;

    static Class providerClass = Nil;
    static Ivar targetIvar = NULL;
    static BOOL encodingIsInteger = NO;
    Class cls = object_getClass(provider);
    if (cls != providerClass) {
        targetIvar = class_getInstanceVariable(cls, "_currentMorphTarget");
        const char *encoding = targetIvar ? ivar_getTypeEncoding(targetIvar) : NULL;
        encodingIsInteger = encoding && (encoding[0] == 'q' || encoding[0] == 'Q');
        providerClass = cls;
    }
    if (!targetIvar || !encodingIsInteger) return NSNotFound;

    NSInteger target = NSNotFound;
    memcpy(&target,
           (const uint8_t *)(__bridge const void *)provider + ivar_getOffset(targetIvar),
           sizeof(target));
    if (known) *known = YES;
    return target;
}

BOOL ApolloTabBarVisualProviderBoolIvar(UITabBar *tabBar, const char *name, BOOL *known) {
    if (known) *known = NO;
    if (!name) return NO;
    id provider = ApolloTabBarVisualProvider(tabBar);
    if (!provider) return NO;

    // Cache keyed on (class, name pointer): the name is a string literal at
    // every call site, so pointer identity is stable; a rare miss on an equal
    // but distinct literal just re-runs the lookup.
    static Class providerClass = Nil;
    static const char *cachedName = NULL;
    static Ivar boolIvar = NULL;
    Class cls = object_getClass(provider);
    if (cls != providerClass || name != cachedName) {
        boolIvar = class_getInstanceVariable(cls, name);
        providerClass = cls;
        cachedName = name;
    }
    if (!boolIvar) return NO;

    // Swift stored Bools carry no useful ObjC type encoding (RuntimeBrowser
    // shows `void`); UIKit's own code reads and writes exactly one byte at the
    // exported ivar offset, so mirror that representation.
    uint8_t value = 0;
    memcpy(&value,
           (const uint8_t *)(__bridge const void *)provider + ivar_getOffset(boolIvar),
           sizeof(value));
    if (known) *known = YES;
    return (value & 1) != 0;
}

// The prior/persistent diagnostics tail, for the exporter to prepend. Empty string if none.
static NSString *ApolloPersistentLoginDiagnostics(void) {
    NSString *contents = [NSString stringWithContentsOfFile:ApolloLoginDiagLogPath()
                                                   encoding:NSUTF8StringEncoding error:nil];
    return contents.length ? contents : @"";
}

static NSString *ApolloPersistentListLayoutDiagnostics(void) {
    NSString *contents = [NSString stringWithContentsOfFile:ApolloListLayoutDiagLogPath()
                                                   encoding:NSUTF8StringEncoding error:nil];
    return contents.length ? contents : @"";
}

static NSString *ApolloCollectLogsFiltered(BOOL aiOnly) {
    if (@available(iOS 15.0, *)) {
        NSError *error = nil;
        OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];
        if (!store) {
            return [NSString stringWithFormat:@"Failed to open log store: %@", error.localizedDescription];
        }

        NSDate *startDate = sProcessStartDate ?: [NSDate distantPast];
        OSLogPosition *position = [store positionWithDate:startDate];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"subsystem == %@", @"apollofix"];

        NSArray<OSLogEntryLog *> *entries = (NSArray *)[[store entriesEnumeratorWithOptions:0
                                                                                  position:position
                                                                                 predicate:predicate
                                                                                     error:&error] allObjects];
        if (!entries) {
            return [NSString stringWithFormat:@"Failed to enumerate logs: %@", error.localizedDescription];
        }

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";

        NSMutableArray<OSLogEntryLog *> *filteredEntries = [NSMutableArray array];
        for (OSLogEntryLog *entry in entries) {
            if (![entry isKindOfClass:[OSLogEntryLog class]]) continue;
            if (!aiOnly ||
                [entry.category isEqualToString:@"AISummary"] ||
                [entry.composedMessage containsString:@"[AISummary]"] ||
                [entry.composedMessage containsString:@"[ApolloAISettings]"]) {
                [filteredEntries addObject:entry];
            }
        }

        // The cross-launch login-diagnostics tail (prior sessions too) — prepended for the full
        // log so a force-quit sign-out is still diagnosable. Not included in the AI-only export.
        NSString *persistentLogin = aiOnly ? @"" : ApolloPersistentLoginDiagnostics();
        NSString *persistentListLayout = aiOnly ? @"" : ApolloPersistentListLayoutDiagnostics();

        if (filteredEntries.count == 0 && persistentLogin.length == 0 && persistentListLayout.length == 0) {
            return aiOnly
                ? @"No Apollo AI log entries found since app launch."
                : @"No [ApolloFix] log entries found since app launch.";
        }

        NSMutableString *output = [NSMutableString new];
        if (persistentListLayout.length) {
            [output appendString:@"===== Persistent list/tab-bar diagnostics (spans previous sessions; survives force-quit) =====\n"];
            [output appendString:persistentListLayout];
            if (![persistentListLayout hasSuffix:@"\n"]) [output appendString:@"\n"];
        }
        if (persistentLogin.length) {
            [output appendString:@"===== Persistent login diagnostics (spans previous sessions; survives force-quit) =====\n"];
            [output appendString:persistentLogin];
            if (![persistentLogin hasSuffix:@"\n"]) [output appendString:@"\n"];
        }
        if (persistentListLayout.length || persistentLogin.length) {
            [output appendString:@"===== Current session ([ApolloFix] os_log) =====\n"];
        }
        [output appendFormat:@"%@ — %@ (%lu entries)\n\n",
            aiOnly ? @"Apollo AI Logs" : @"ApolloFix Logs",
            [NSDateFormatter localizedStringFromDate:[NSDate date]
                                           dateStyle:NSDateFormatterMediumStyle
                                           timeStyle:NSDateFormatterShortStyle],
            (unsigned long)filteredEntries.count];

        for (OSLogEntryLog *entry in filteredEntries) {
            [output appendFormat:@"[%@] %@\n", [formatter stringFromDate:entry.date], entry.composedMessage];
        }

        return output;
    }

    return @"Log export requires iOS 15+.";
}

NSString *ApolloCollectLogs(void) {
    return ApolloCollectLogsFiltered(NO);
}

NSString *ApolloCollectAILogs(void) {
    return ApolloCollectLogsFiltered(YES);
}

#pragma mark - Bounded data requests

static NSString *const kApolloBoundedDataErrorDomain = @"ApolloBoundedData";

@interface ApolloBoundedDataRecord : NSObject
@property (nonatomic) NSUInteger maximumBytes;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) NSError *failure;
@property (nonatomic, copy) ApolloBoundedDataResponseValidator responseValidator;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, copy) ApolloBoundedDataCompletion completion;
@end

@implementation ApolloBoundedDataRecord
@end

@interface ApolloBoundedDataCoordinator : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ApolloBoundedDataRecord *> *records;
+ (instancetype)sharedCoordinator;
- (NSURLSessionDataTask *)startRequest:(NSURLRequest *)request
                          maximumBytes:(NSUInteger)maximumBytes
                     responseValidator:(ApolloBoundedDataResponseValidator)responseValidator
                       completionQueue:(dispatch_queue_t)completionQueue
                            completion:(ApolloBoundedDataCompletion)completion;
@end

@implementation ApolloBoundedDataCoordinator

+ (instancetype)sharedCoordinator {
    static ApolloBoundedDataCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ coordinator = [ApolloBoundedDataCoordinator new]; });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _records = [NSMutableDictionary dictionary];
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.name = @"com.apolloreborn.bounded-data";
        queue.maxConcurrentOperationCount = 1;
        queue.qualityOfService = NSQualityOfServiceUtility;
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];
    }
    return self;
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:kApolloBoundedDataErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"The response could not be loaded"}];
}

- (NSURLSessionDataTask *)startRequest:(NSURLRequest *)request
                          maximumBytes:(NSUInteger)maximumBytes
                     responseValidator:(ApolloBoundedDataResponseValidator)responseValidator
                       completionQueue:(dispatch_queue_t)completionQueue
                            completion:(ApolloBoundedDataCompletion)completion {
    if (![request isKindOfClass:[NSURLRequest class]] || !request.URL || maximumBytes == 0 || !completion) {
        if (completion) {
            dispatch_async(completionQueue ?: dispatch_get_main_queue(), ^{
                completion(nil, nil, [self errorWithCode:1 description:@"Invalid bounded-data request"]);
            });
        }
        return nil;
    }

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    ApolloBoundedDataRecord *record = [ApolloBoundedDataRecord new];
    record.maximumBytes = maximumBytes;
    record.data = [NSMutableData data];
    record.responseValidator = [responseValidator copy];
    record.completionQueue = completionQueue ?: dispatch_get_main_queue();
    record.completion = [completion copy];
    @synchronized (self) { self.records[@(task.taskIdentifier)] = record; }
    [task resume];
    return task;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveResponse:(NSURLResponse *)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    ApolloBoundedDataRecord *record = nil;
    @synchronized (self) { record = self.records[@(dataTask.taskIdentifier)]; }
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    record.response = http;

    NSError *failure = nil;
    if (!record || !http || http.statusCode < 200 || http.statusCode >= 300) {
        failure = [self errorWithCode:2 description:@"The server returned an HTTP error"];
    } else if (response.expectedContentLength > 0 &&
               (unsigned long long)response.expectedContentLength > record.maximumBytes) {
        failure = [self errorWithCode:3 description:@"The response exceeded its size limit"];
    } else if (record.responseValidator) {
        failure = record.responseValidator(http);
    }

    if (failure) {
        record.failure = failure;
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    ApolloBoundedDataRecord *record = nil;
    @synchronized (self) { record = self.records[@(dataTask.taskIdentifier)]; }
    if (!record || record.failure || data.length == 0) return;
    if (data.length > record.maximumBytes - MIN(record.data.length, record.maximumBytes)) {
        record.failure = [self errorWithCode:4 description:@"The response exceeded its size limit"];
        [dataTask cancel];
        return;
    }
    [record.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    ApolloBoundedDataRecord *record = nil;
    @synchronized (self) {
        NSNumber *key = @(task.taskIdentifier);
        record = self.records[key];
        [self.records removeObjectForKey:key];
    }
    if (!record) return;

    NSData *result = !record.failure && !error ? [record.data copy] : nil;
    NSError *finalError = record.failure ?: error;
    ApolloBoundedDataCompletion completion = record.completion;
    NSHTTPURLResponse *response = record.response;
    dispatch_async(record.completionQueue ?: dispatch_get_main_queue(), ^{
        completion(result, response, finalError);
    });
}

@end

NSURLSessionDataTask *ApolloStartBoundedDataRequest(NSURLRequest *request,
                                                    NSUInteger maximumBytes,
                                                    ApolloBoundedDataResponseValidator responseValidator,
                                                    dispatch_queue_t completionQueue,
                                                    ApolloBoundedDataCompletion completion) {
    return [[ApolloBoundedDataCoordinator sharedCoordinator] startRequest:request
                                                              maximumBytes:maximumBytes
                                                         responseValidator:responseValidator
                                                           completionQueue:completionQueue
                                                                completion:completion];
}

// Get the SDK version from the main binary's LC_BUILD_VERSION load command
// Returns 0 if not found, otherwise packed version (major << 16 | minor << 8 | patch)
static uint32_t GetLinkedSDKVersion(void) {
    // Find the main executable by filetype instead of assuming image index 0.
    // In the simulator the injected tweak dylib can occupy index 0, which made
    // IsLiquidGlass() read the dylib's own SDK (always current) instead of
    // Apollo's — masking every legacy (non-glass) code path during sim testing.
    const struct mach_header_64 *header = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *h = _dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            header = (const struct mach_header_64 *)h;
            break;
        }
    }
    if (!header) header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header) return 0;

    uintptr_t cursor = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *cmd = (struct load_command *)cursor;
        if (cmd->cmd == LC_BUILD_VERSION) {
            struct build_version_command *buildCmd = (struct build_version_command *)cmd;
            return buildCmd->sdk;
        }
        cursor += cmd->cmdsize;
    }
    return 0;
}

// Check if Liquid Glass is active by checking if the app binary was linked against iOS 26+ SDK
BOOL IsLiquidGlass(void) {
    static BOOL checked = NO;
    static BOOL available = NO;

    if (!checked) {
        checked = YES;
        // BOOL isiOS26Runtime = (objc_getClass("_UITabButton") != nil);
        // if (!isiOS26Runtime) {
        //     ApolloLog(@"[IsLiquidGlass] iOS 26+ runtime not detected");
        //     available = NO;
        //     return available;
        // }

        // iOS 26 SDK version = 19.0 = 0x00130000 (major 19 in high 16 bits)
        // SDK version format: major << 16 | minor << 8 | patch
        uint32_t sdkVersion = GetLinkedSDKVersion();
        uint32_t sdkMajor = (sdkVersion >> 16) & 0xFFFF;
        available = (sdkMajor >= 19);

        ApolloLog(@"[IsLiquidGlass] SDK version: 0x%08X (major: %u), linked for iOS 26+: %@",
                  sdkVersion, sdkMajor, available ? @"YES" : @"NO");
    }

    return available;
}

// --- Liquid Glass trailing-cluster reservation (see ApolloCommon.h) ---
// Plain associated storage on the navigation item; the recenter in
// ApolloLiquidGlass.xm is the only reader and sole inset writer.
static char kApolloNavItemTrailingHoldKey;
static char kApolloNavItemTrailingInsetKey;

void ApolloNavItemSetTrailingReservationHold(UINavigationItem *item, BOOL hold) {
    if (!item) return;
    objc_setAssociatedObject(item, &kApolloNavItemTrailingHoldKey,
                             hold ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloNavItemTrailingReservationHold(UINavigationItem *item) {
    return [objc_getAssociatedObject(item, &kApolloNavItemTrailingHoldKey) boolValue];
}

void ApolloNavItemNoteTrailingContentInset(UINavigationItem *item, CGFloat inset) {
    if (!item || inset <= 0) return;
    objc_setAssociatedObject(item, &kApolloNavItemTrailingInsetKey,
                             @(inset), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

CGFloat ApolloNavItemTrailingContentInset(UINavigationItem *item) {
    return [objc_getAssociatedObject(item, &kApolloNavItemTrailingInsetKey) doubleValue];
}

// Route a URL through Apollo's own URL handler, bypassing iOS URL dispatch.
//
// On iOS 13+ with scenes, the SceneDelegate owns the tabBarController while
// the AppDelegate's ivar is nil. The AppDelegate's application:openURL:options:
// handler (sub_100161d08) reads AppDelegate.tabBarController for navigation,
// so we ensure it has a reference before calling.
static BOOL ApolloRouteURLThroughUIApplication(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }

    UIApplication *application = [UIApplication sharedApplication];
    id<UIApplicationDelegate> appDelegate = [application delegate];

    if (![appDelegate respondsToSelector:@selector(application:openURL:options:)]) {
        return NO;
    }

    // Ensure AppDelegate.tabBarController is populated
    @try {
        Ivar appTabBarIvar = class_getInstanceVariable([appDelegate class], "tabBarController");
        if (appTabBarIvar && !object_getIvar(appDelegate, appTabBarIvar)) {
            for (UIScene *scene in application.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                id sceneDelegate = [(UIWindowScene *)scene delegate];
                if (!sceneDelegate) continue;
                Ivar sceneTabBarIvar = class_getInstanceVariable([sceneDelegate class], "tabBarController");
                if (!sceneTabBarIvar) continue;
                id sceneTabBar = object_getIvar(sceneDelegate, sceneTabBarIvar);
                if (sceneTabBar) {
                    ApolloLog(@"[ApolloRouteURL] Copying SceneDelegate tabBarController to AppDelegate");
                    object_setIvar(appDelegate, appTabBarIvar, sceneTabBar);
                    break;
                }
            }
        }
    } @catch (NSException *e) {
        ApolloLog(@"[ApolloRouteURL] Failed to copy tabBarController: %@", e);
    }

    // Call the app delegate's URL handler directly — stays in-process,
    // never hits iOS's URL scheme dispatch.
    @try {
        BOOL (*msgSend)(id, SEL, id, id, id) = (BOOL (*)(id, SEL, id, id, id))objc_msgSend;
        msgSend(appDelegate, @selector(application:openURL:options:), application, url, @{});
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[ApolloRouteURL] application:openURL:options: threw: %@", exception);
        return NO;
    }
}

// Public wrapper: route a reddit URL through Apollo's own handler so posts,
// comments, subreddits and users open the native views. Returns NO when the
// handler is unavailable, so callers can fall back to a web view.
BOOL ApolloRouteURLThroughApp(NSURL *url) {
    return ApolloRouteURLThroughUIApplication(url);
}

NSURL *ApolloURLByConvertingResolvedURLToApolloScheme(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return nil;
    }

    NSString *host = [[components host] lowercaseString];
    if (![host isKindOfClass:[NSString class]] || host.length == 0) {
        return nil;
    }

    // Accept reddit.com and real subdomains only. A bare suffix test also
    // matches unrelated lookalikes such as notreddit.com, which must stay on
    // the external-web path instead of being rewritten into an Apollo deep link.
    if ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) {
        components.host = @"reddit.com";
    } else if ([host isEqualToString:@"redd.it"]) {
        // Only bare redd.it is the post shortener. i.redd.it, v.redd.it and
        // preview.redd.it are media/CDN hosts and cannot identify a post.
        NSArray<NSString *> *rawSegments = [components.path componentsSeparatedByString:@"/"];
        NSMutableArray<NSString *> *segments = [NSMutableArray array];
        for (NSString *segment in rawSegments) {
            if (segment.length > 0) {
                [segments addObject:segment];
            }
        }
        if (segments.count != 1) {
            return nil;
        }
        components.host = @"reddit.com";
        components.path = [@"/comments/" stringByAppendingString:segments.firstObject];
    } else {
        return nil;
    }

    components.scheme = @"apollo";
    if ([components.query isKindOfClass:[NSString class]] && components.query.length == 0) {
        components.query = nil;
    }

    ApolloLog(@"[ApolloURLByConvertingResolvedURLToApolloScheme] Converted URL: %@", components.URL);
    return components.URL;
}

BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *resolvedURL) {
    NSURL *apolloURL = ApolloURLByConvertingResolvedURLToApolloScheme(resolvedURL);
    if (![apolloURL isKindOfClass:[NSURL class]]) {
        return NO;
    }
    return ApolloRouteURLThroughUIApplication(apolloURL);
}

#pragma mark - Settings Theme Inheritance

static UITableView *ApolloFindTableViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *tableView = ApolloFindTableViewInView(subview);
        if (tableView) return tableView;
    }
    return nil;
}

UITableView *ApolloInheritedSettingsThemeSourceTableView(UITableViewController *controller) {
    if (!controller) return nil;

    NSArray<UIViewController *> *stack = controller.navigationController.viewControllers;
    UIViewController *stackController = controller;
    NSUInteger index = [stack indexOfObject:stackController];
    while (index == NSNotFound && stackController.parentViewController) {
        stackController = stackController.parentViewController;
        index = [stack indexOfObject:stackController];
    }
    if (index == NSNotFound || index == 0) return nil;

    UIViewController *source = stack[index - 1];
    if ([source respondsToSelector:@selector(tableView)]) {
        id tableView = ((id (*)(id, SEL))objc_msgSend)(source, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }

    return ApolloFindTableViewInView(source.view);
}

BOOL ApolloThemeSourceTableIsStale(UITableView *sourceTable) {
    return sourceTable == nil || sourceTable.window == nil;
}

static UIColor *ApolloVisibleBackgroundColorForTable(UITableView *tableView,
                                                      UITraitCollection *traits) {
    // Immersive profile/subreddit screens deliberately make their table clear
    // and render the backdrop behind it. A pushed tweak-owned screen still
    // needs an opaque transition surface, so inherit the first visible
    // ancestor color instead of propagating clearColor into the destination.
    for (UIView *view = tableView; view; view = view.superview) {
        UIColor *color = view.backgroundColor;
        if (!color) continue;
        UIColor *resolved = [color resolvedColorWithTraitCollection:traits ?: view.traitCollection];
        if (resolved && CGColorGetAlpha(resolved.CGColor) >= 0.99) return color;
    }
    return nil;
}

void ApolloApplyInheritedSettingsTableTheme(UITableViewController *controller) {
    if (!controller) return;

    UITableView *source = ApolloInheritedSettingsThemeSourceTableView(controller);
    BOOL stale = ApolloThemeSourceTableIsStale(source);
    UIColor *backgroundColor = (stale ? nil
        : ApolloVisibleBackgroundColorForTable(source, controller.traitCollection))
        ?: ApolloThemePageBackgroundColor() ?: controller.tableView.backgroundColor;
    controller.view.backgroundColor = backgroundColor;
    controller.tableView.backgroundColor = backgroundColor;
    controller.tableView.separatorColor = ApolloThemeSeparatorColor()
        ?: [UIColor opaqueSeparatorColor];
}

#pragma mark - LinkButtonNode URL extraction

// Extract URL string from a LinkButtonNode, with iOS 26 fallback.
// On iOS < 26 the Swift URL struct's first field was an NSURL*, so the ObjC getter
// returned a usable NSURL. On iOS 26, Foundation.URL's internal layout changed
// (swift-foundation #1238) and ObjC access no longer works. We fall back to reading
// the urlTextNode's attributedText — a plain ObjC ASTextNode displaying the URL string.
NSString *ApolloGetLinkButtonNodeURLString(id linkButtonNode) {
    if (!linkButtonNode) {
        return nil;
    }

    // Primary path: try ObjC getter + absoluteString (works on iOS < 26)
    @try {
        SEL getter = @selector(url);
        if ([linkButtonNode respondsToSelector:getter]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(linkButtonNode, getter);
            if (value && value != [NSNull null] && [value respondsToSelector:@selector(absoluteString)]) {
                NSString *str = [value absoluteString];
                if ([str isKindOfClass:[NSString class]] && str.length > 0) {
                    return str;
                }
            }
        }
    } @catch (NSException *e) {
    }

    // iOS 26 fallback: read the displayed URL text from the urlTextNode ivar.
    // attributedText stores the full string (truncation is visual only).
    // The displayed text typically omits the scheme, so we prepend "https://"
    // if needed.
    @try {
        Ivar ivar = class_getInstanceVariable([linkButtonNode class], "urlTextNode");
        id urlTextNode = ivar ? object_getIvar(linkButtonNode, ivar) : nil;
        if (urlTextNode && [urlTextNode respondsToSelector:@selector(attributedText)]) {
            NSString *text = [[urlTextNode attributedText] string];
            if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                if (![text hasPrefix:@"http://"] && ![text hasPrefix:@"https://"]) {
                    text = [@"https://" stringByAppendingString:text];
                }
                return text;
            }
        }
    } @catch (NSException *e) {
    }

    return nil;
}

#pragma mark - Junk link-card titles

BOOL ApolloIsJunkNumericTitle(NSString *title) {
    if (![title isKindOfClass:[NSString class]]) return NO;

    NSString *trimmed = [title stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;

    // Must contain no letters anywhere...
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
        return NO;
    }
    // ...but at least one digit (targets numeric-ID titles, while leaving
    // emoji-only or punctuation-only titles untouched).
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound) {
        return NO;
    }

    // The title is now letter-free with at least one digit, but that still
    // covers numbers a user would legitimately want to keep: a year ("2024",
    // "1917"), a short number ("300"), a date ("9/11"), or a phone-number page
    // ("1-800-273-8255"). Only substitute when it actually looks like a scraped
    // internal-ID dump rather than a plausible real title — i.e. either:
    //   * a single long run of digits (timestamps, opaque IDs), or
    //   * several whitespace-separated all-numeric tokens (the fifa.com
    //     match-center "285023 289273 400021448" pattern).
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];

    NSUInteger longestRun = 0, currentRun = 0, totalDigits = 0;
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        if ([digits characterIsMember:[trimmed characterAtIndex:i]]) {
            currentRun++;
            totalDigits++;
            if (currentRun > longestRun) longestRun = currentRun;
        } else {
            currentRun = 0;
        }
    }
    // A run this long is not a year/date/short number; it's an ID or timestamp.
    if (longestRun >= 7) return YES;

    NSUInteger numericTokens = 0;
    for (NSString *token in [trimmed componentsSeparatedByCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (token.length == 0) continue;
        if ([token rangeOfCharacterFromSet:[digits invertedSet]].location == NSNotFound) {
            numericTokens++; // token is purely digits
        }
    }
    // Multiple bare numeric tokens (with enough digits to not be, say, "12 34")
    // is the multi-ID dump shape, not a real headline.
    if (numericTokens >= 2 && totalDigits >= 6) return YES;

    return NO;
}

NSString *ApolloWebsiteNameFromHost(NSString *host) {
    if (host.length == 0) return nil;

    host = host.lowercaseString;
    while ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (host.length == 0) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *p in [host componentsSeparatedByString:@"."]) {
        if (p.length > 0) [parts addObject:p];
    }
    NSUInteger n = parts.count;
    if (n == 0) return nil;

    NSString *label;
    if (n == 1) {
        label = parts[0];
    } else {
        static NSSet *ccSLDs = nil; // second-level labels under country-code TLDs
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            ccSLDs = [NSSet setWithArray:@[@"co", @"com", @"org", @"net", @"gov",
                                           @"edu", @"ac", @"gob", @"go", @"or", @"ne"]];
        });
        NSString *last = parts[n - 1];
        NSString *secondLast = parts[n - 2];
        if (n >= 3 && last.length == 2 && [ccSLDs containsObject:secondLast]) {
            label = parts[n - 3];
        } else {
            label = parts[n - 2];
        }
    }
    if (label.length == 0) return nil;

    // Needs at least one letter, otherwise we'd just swap digits for digits.
    if ([label rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) {
        return nil;
    }

    // Short labels are almost always acronyms (FIFA, ESPN, BBC, TIME); longer
    // ones read better title-cased.
    if (label.length <= 4) {
        return label.uppercaseString;
    }
    NSString *first = [[label substringToIndex:1] uppercaseString];
    return [first stringByAppendingString:[label substringFromIndex:1]];
}

UIImage *ApolloEmojiSettingsIcon(NSString *emoji, UIColor *backgroundColor, CGFloat size) {
    if (emoji.length == 0) return nil;
    if (size <= 0.0) size = 29.0;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect bounds = CGRectMake(0, 0, size, size);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:6.0];
        UIColor *fill = backgroundColor ?: [UIColor secondarySystemFillColor];
        [fill setFill];
        [path fill];

        [[UIColor separatorColor] setStroke];
        path.lineWidth = 0.5;
        [path stroke];

        UIFont *font = [UIFont systemFontOfSize:size * 0.58];
        NSDictionary *attrs = @{NSFontAttributeName: font};
        CGSize textSize = [emoji sizeWithAttributes:attrs];
        CGPoint origin = CGPointMake((size - textSize.width) / 2.0, (size - textSize.height) / 2.0 - 0.5);
        [emoji drawAtPoint:origin withAttributes:attrs];
    }];
}

NSAttributedString *ApolloSymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithFont:font];
        UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:config];
        if (!image) return nil;
        image = [image imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = image;
        // Center the glyph on the font's cap height so it sits on the text
        // baseline rather than floating above it.
        CGFloat y = (font.capHeight - image.size.height) / 2.0;
        attachment.bounds = CGRectMake(0, y, image.size.width, image.size.height);
        return [NSAttributedString attributedStringWithAttachment:attachment];
    }
    return nil;
}

static NSString *ApolloBundledResourcePNGPath(NSString *resourceName) {
    return ApolloBundledResourcePath(resourceName, @"png");
}

NSString *ApolloBundledResourcePath(NSString *baseName, NSString *extension) {
    if (baseName.length == 0) return nil;

    NSBundle *mainBundle = [NSBundle mainBundle];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // inject-deb-local.sh: loose files in <App>.app/ApolloRebornResources/
    NSString *path = [mainBundle pathForResource:baseName
                                          ofType:extension
                                     inDirectory:@"ApolloRebornResources"];
    if (path.length > 0 && [fileManager fileExistsAtPath:path]) {
        return path;
    }

    // cyan / azule / Sideloadly deb fuse: <App>.app/ApolloReborn.bundle/
    NSString *innerBundlePath = [mainBundle.bundlePath stringByAppendingPathComponent:@"ApolloReborn.bundle"];
    NSBundle *innerBundle = [NSBundle bundleWithPath:innerBundlePath];
    path = [innerBundle pathForResource:baseName ofType:extension];
    if (path.length > 0 && [fileManager fileExistsAtPath:path]) {
        return path;
    }

    // Loose at .app root
    path = [mainBundle pathForResource:baseName ofType:extension];
    if (path.length > 0 && [fileManager fileExistsAtPath:path]) {
        return path;
    }

    // Jailbreak (rootful + rootless)
    NSArray<NSString *> *bundleRoots = @[
        @"/Library/Application Support/ApolloReborn/ApolloReborn.bundle",
        @"/var/jb/Library/Application Support/ApolloReborn/ApolloReborn.bundle",
    ];
    for (NSString *root in bundleRoots) {
        NSBundle *resourceBundle = [NSBundle bundleWithPath:root];
        path = [resourceBundle pathForResource:baseName ofType:extension];
        if (path.length > 0 && [fileManager fileExistsAtPath:path]) return path;
    }

    NSString *fileName = extension.length > 0
        ? [baseName stringByAppendingPathExtension:extension]
        : baseName;
    NSArray<NSString *> *supportRoots = @[
        @"/Library/Application Support/ApolloReborn",
        @"/var/jb/Library/Application Support/ApolloReborn",
    ];
    for (NSString *root in supportRoots) {
        path = [root stringByAppendingPathComponent:fileName];
        if ([fileManager fileExistsAtPath:path]) return path;
    }
    return nil;
}

NSString *ApolloBuildVariant(void) {
    // 1. IPA variants: stamped into Info.plist by build_release_variants.sh.
    NSString *stamped = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"ARBuildVariant"];
    if ([stamped isKindOfClass:NSString.class] && stamped.length) return stamped;

    // 2. Jailbroken .deb installs (no repackaged Info.plist to carry
    //    ARBuildVariant): read the ARVariant.txt marker stamped into
    //    ApolloReborn.bundle by the Makefile's before-package hook — "deb-rootful"
    //    or "deb-rootless" per THEOS_PACKAGE_SCHEME — resolved across the rootful
    //    (/Library/...) and rootless (/var/jb/...) install layouts.
    NSString *markerPath = ApolloBundledResourcePath(@"ARVariant", @"txt");
    if (markerPath) {
        NSString *m = [[NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:NULL]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (m.length) return m;
    }
    return @"unknown";
}

static UIImage *ApolloCachedBundledPNGNamed(NSString *resourceName) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    UIImage *cached = cache[resourceName];
    if (cached) return cached;

    NSString *path = ApolloBundledResourcePNGPath(resourceName);
    if (path.length == 0) return nil;

    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image) cache[resourceName] = image;
    return image;
}

UIImage *ApolloBundledPDFTemplateImage(NSString *baseName, CGSize maxSize) {
    if (baseName.length == 0) return nil;

    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    NSString *key = [NSString stringWithFormat:@"%@|%.2fx%.2f", baseName, maxSize.width, maxSize.height];
    @synchronized (cache) {
        UIImage *cached = cache[key];
        if (cached) return cached;
    }

    NSString *path = ApolloBundledResourcePath(baseName, @"pdf");
    if (path.length == 0) return nil;

    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path]);
    if (!document) {
        ApolloLog(@"[Common] Bundled PDF %@ failed to open at %@", baseName, path);
        return nil;
    }

    // Page 1 only: these are single-artboard icon exports, not documents.
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    CGRect box = page ? CGPDFPageGetBoxRect(page, kCGPDFCropBox) : CGRectZero;
    if (!page || box.size.width <= 0.0 || box.size.height <= 0.0) {
        CGPDFDocumentRelease(document);
        ApolloLog(@"[Common] Bundled PDF %@ has no usable first page", baseName);
        return nil;
    }

    CGSize size = box.size;
    if (maxSize.width > 0.0 && maxSize.height > 0.0) {
        CGFloat fit = MIN(maxSize.width / size.width, maxSize.height / size.height);
        // Only ever scale down — upscaling a small icon to fill the box would
        // make it heavier than the ones it sits next to.
        if (fit < 1.0) size = CGSizeMake(round(size.width * fit), round(size.height * fit));
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        // PDF space is y-up with the crop box's own origin; UIKit's context is
        // y-down from (0,0), so flip and shift the page into it.
        CGContextTranslateCTM(context, 0.0, size.height);
        CGContextScaleCTM(context, size.width / box.size.width, -size.height / box.size.height);
        CGContextTranslateCTM(context, -box.origin.x, -box.origin.y);
        CGContextDrawPDFPage(context, page);
    }];
    CGPDFDocumentRelease(document);
    if (!image) return nil;

    // Contributed icons are drawn in Apollo blue; template mode keeps only the
    // alpha so the row tints with the active theme accent like every other icon.
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    @synchronized (cache) {
        cache[key] = image;
    }
    return image;
}

static UIImage *ApolloRoundedPNGSettingsIcon(UIImage *source, CGFloat size) {
    if (!source) return nil;
    if (size <= 0.0) size = 29.0;

    CGFloat cornerRadius = MIN(6.0, size * 0.21);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:cornerRadius] addClip];
        [source drawInRect:CGRectMake(0, 0, size, size)];
    }];
}

UIImage *ApolloBuyMeACoffeeSettingsIcon(CGFloat size) {
    UIImage *icon = ApolloRoundedPNGSettingsIcon(ApolloCachedBundledPNGNamed(@"buymeacoffee-icon"), size);
    if (icon) return icon;
    return ApolloEmojiSettingsIcon(@"☕️", [UIColor colorWithRed:0.98 green:0.74 blue:0.02 alpha:1.0], size > 0.0 ? size : 29.0);
}

UIImage *ApolloRebornOptionsSettingsIcon(CGFloat size) {
    return ApolloRoundedPNGSettingsIcon(ApolloCachedBundledPNGNamed(@"apollo-reborn-options-icon"), size);
}

#pragma mark - In-app browser

static NSURL *sLastPresentedBrowserURL = nil;
static NSTimeInterval sLastPresentedBrowserTime = 0;

static NSURL *ApolloNormalizedWebURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components || components.host.length == 0) return url;

    if (components.scheme.length == 0) {
        components.scheme = @"https";
    }

    NSString *host = components.host.lowercaseString;
    if ([host hasPrefix:@"www."]) {
        host = [host substringFromIndex:4];
    }
    components.host = host;

    return components.URL ?: url;
}

static BOOL ApolloViewControllerIsInAppBrowser(UIViewController *viewController) {
    if (!viewController) return NO;

    NSString *className = NSStringFromClass([viewController class]);
    if ([className containsString:@"ApolloSafariViewController"]) return YES;
    if ([className containsString:@"SFSafariViewController"]) return YES;
    return NO;
}

static BOOL ApolloShouldSkipDuplicateBrowserPresent(NSURL *url) {
    if (!url) return YES;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (sLastPresentedBrowserURL &&
        [sLastPresentedBrowserURL.absoluteString isEqualToString:url.absoluteString] &&
        (now - sLastPresentedBrowserTime) < 0.5) {
        return YES;
    }
    return NO;
}

static void ApolloRecordBrowserPresent(NSURL *url) {
    sLastPresentedBrowserURL = url;
    sLastPresentedBrowserTime = CFAbsoluteTimeGetCurrent();
}

static UIViewController *ApolloApolloSafariBrowserForURL(NSURL *url) {
    Class apolloSafariClass = NSClassFromString(@"_TtC6Apollo26ApolloSafariViewController");
    if (!apolloSafariClass) return nil;

    id alloced = [apolloSafariClass alloc];
    SEL initSel = NSSelectorFromString(@"initWithURL:");
    if (![alloced respondsToSelector:initSel]) return nil;

    id (*msgSend)(id, SEL, NSURL *) = (id (*)(id, SEL, NSURL *))objc_msgSend;
    return msgSend(alloced, initSel, url);
}

void ApolloPresentWebURLFromViewController(UIViewController *presenter, NSURL *url) {
    if (!presenter || !url) return;

    NSURL *normalizedURL = ApolloNormalizedWebURL(url);
    if (!normalizedURL) return;

    if (ApolloShouldSkipDuplicateBrowserPresent(normalizedURL)) {
        ApolloLog(@"[Browser] skip duplicate present url=%@", normalizedURL.absoluteString);
        return;
    }

    UIViewController *existingPresentation = presenter.presentedViewController;
    if (ApolloViewControllerIsInAppBrowser(existingPresentation)) {
        ApolloLog(@"[Browser] dismissing existing browser before present url=%@", normalizedURL.absoluteString);
        [presenter dismissViewControllerAnimated:NO completion:^{
            ApolloPresentWebURLFromViewController(presenter, normalizedURL);
        }];
        return;
    }

    ApolloLog(@"[Browser] present url=%@ presenter=%@ alreadyPresented=%@",
              normalizedURL.absoluteString,
              NSStringFromClass([presenter class]),
              existingPresentation ? NSStringFromClass([existingPresentation class]) : @"(none)");

    UIViewController *browser = ApolloApolloSafariBrowserForURL(normalizedURL);
    if (browser) {
        ApolloRecordBrowserPresent(normalizedURL);
        [presenter presentViewController:browser animated:YES completion:nil];
        return;
    }

    ApolloLog(@"[Browser] fallback openURL url=%@", normalizedURL.absoluteString);
    ApolloRecordBrowserPresent(normalizedURL);
    [[UIApplication sharedApplication] openURL:normalizedURL options:@{} completionHandler:nil];
}

BOOL ApolloIsSystemShareComposeController(UIViewController *controller) {
    if (![controller isKindOfClass:[UIViewController class]]) return NO;
    // Apple's out-of-process compose controllers whose class names collide with
    // Apollo's "...ComposeViewController" suffix matchers. Treating them as
    // Apollo composers crashes the GIF/composer machinery (issue #366).
    static const char *kSystemComposeClassNames[] = {
        "MFMessageComposeViewController",
        "MFMailComposeViewController",
        "SLComposeViewController",
    };
    for (size_t i = 0; i < sizeof(kSystemComposeClassNames) / sizeof(kSystemComposeClassNames[0]); i++) {
        Class cls = objc_getClass(kSystemComposeClassNames[i]);
        if (cls && [controller isKindOfClass:cls]) return YES;
    }
    return NO;
}

NSArray<UIWindow *> *ApolloAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}

static UIViewController *ApolloTabBarControllerIvarOn(id object) {
    if (!object) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable([object class], "tabBarController");
        id value = ivar ? object_getIvar(object, ivar) : nil;
        return [value isKindOfClass:[UIViewController class]] ? value : nil;
    } @catch (NSException *exception) {
        ApolloLog(@"[Common] Failed reading tabBarController ivar on %@: %@", object, exception);
        return nil;
    }
}

static UIViewController *ApolloTabBarControllerForWindowScene(UIWindowScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class]) return nil;

    UIViewController *fromDelegate = ApolloTabBarControllerIvarOn(scene.delegate);
    if (fromDelegate) return fromDelegate;

    // Prefer the key window, then visible normal-level windows. A scene may
    // also own transient keyboard/alert windows whose roots are unrelated to
    // Apollo's tab hierarchy.
    NSMutableArray<UIWindow *> *ordered = [NSMutableArray array];
    for (UIWindow *window in scene.windows) if (window.isKeyWindow) [ordered addObject:window];
    for (UIWindow *window in scene.windows) {
        if (![ordered containsObject:window] && !window.hidden &&
            window.windowLevel == UIWindowLevelNormal) [ordered addObject:window];
    }
    for (UIWindow *window in scene.windows) {
        if (![ordered containsObject:window]) [ordered addObject:window];
    }
    for (UIWindow *window in ordered) {
        UIViewController *root = window.rootViewController;
        if ([root isKindOfClass:UITabBarController.class]) return root;
        if ([root.presentedViewController isKindOfClass:UITabBarController.class]) {
            return root.presentedViewController;
        }
    }
    return nil;
}

UIViewController *ApolloMainTabBarControllerForScene(UIWindowScene *originatingScene) {
    UIViewController *originating = ApolloTabBarControllerForWindowScene(originatingScene);
    if (originating) return originating;

    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIScene *> *scenes = application.connectedScenes.allObjects;

    // Prefer a foreground-active scene with a key window. Enumerating the
    // connectedScenes set directly is unordered and can send an action into a
    // background or external-display window when more than one scene exists.
    for (UIScene *candidate in scenes) {
        if (![candidate isKindOfClass:UIWindowScene.class] ||
            candidate.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *windowScene = (UIWindowScene *)candidate;
        BOOL hasKeyWindow = NO;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) { hasKeyWindow = YES; break; }
        }
        if (!hasKeyWindow) continue;
        UIViewController *controller = ApolloTabBarControllerForWindowScene(windowScene);
        if (controller) return controller;
    }
    for (UIScene *candidate in scenes) {
        if (![candidate isKindOfClass:UIWindowScene.class] ||
            candidate.activationState != UISceneActivationStateForegroundActive) continue;
        UIViewController *controller = ApolloTabBarControllerForWindowScene((UIWindowScene *)candidate);
        if (controller) return controller;
    }
    for (UIScene *candidate in scenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        UIViewController *controller = ApolloTabBarControllerForWindowScene((UIWindowScene *)candidate);
        if (controller) return controller;
    }
    return ApolloTabBarControllerIvarOn(application.delegate);
}

UIViewController *ApolloMainTabBarController(void) {
    return ApolloMainTabBarControllerForScene(nil);
}

// ApolloCommon is included by nearly every file, so it must not import the pane
// module. The pane nevertheless has to be the authority for its real navigation
// controllers: UIKit wraps our plain secondary host in another navigation
// controller, and `viewControllerForColumn:` can therefore return either that
// wrapper or the host rather than Apollo's navigation controller nested inside
// it. Ask for the pane's public column accessor dynamically first, then retain a
// plain-UIKit fallback for split controllers that do not belong to this feature.
static UINavigationController *ApolloNavigationControllerForSplitColumn(UISplitViewController *split,
                                                                        UISplitViewControllerColumn column) {
    SEL paneAccessor = NSSelectorFromString(@"apollo_navigationControllerForColumn:");
    if ([split respondsToSelector:paneAccessor]) {
        @try {
            // ApolloPaneColumn intentionally uses the same 0/1/2 values as
            // UISplitViewControllerColumn for primary/supplementary/secondary.
            // Keep the call scalar so this common module needs no ipad/ import.
            id result = ((id (*)(id, SEL, NSInteger))objc_msgSend)(split, paneAccessor, (NSInteger)column);
            if ([result isKindOfClass:[UINavigationController class]]) {
                return (UINavigationController *)result;
            }
            ApolloLog(@"[Common] pane column %ld returned non-navigation controller %@",
                      (long)column, result ? NSStringFromClass([result class]) : @"nil");
        } @catch (NSException *exception) {
            ApolloLog(@"[Common] pane navigation accessor threw on %@ column %ld: %@",
                      split, (long)column, exception);
        }
    }

    UIViewController *columnController = nil;
    if ([split respondsToSelector:@selector(viewControllerForColumn:)]) {
        @try {
            columnController = [split viewControllerForColumn:column];
        } @catch (NSException *exception) {
            ApolloLog(@"[Common] viewControllerForColumn: threw on %@: %@", split, exception);
        }
    }
    // A split controller built with the legacy `viewControllers` API answers nil
    // for every column. Fall back to positional lookup so such a controller
    // still resolves instead of silently returning nothing.
    if (!columnController) {
        NSArray<UIViewController *> *children = split.viewControllers;
        NSUInteger index = (column == UISplitViewControllerColumnSecondary) ? 1 : 0;
        if (index < children.count) columnController = children[index];
    }
    return [columnController isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)columnController
        : nil;
}

BOOL ApolloViewControllerContains(UIViewController *ancestor, UIViewController *descendant) {
    if (!ancestor || !descendant) return NO;
    for (UIViewController *node = descendant; node != nil; node = node.parentViewController) {
        if (node == ancestor) return YES;
    }
    return NO;
}

BOOL ApolloSelectTabContainingViewController(UITabBarController *tabBarController,
                                             UIViewController *descendant) {
    if (![tabBarController isKindOfClass:[UITabBarController class]] || !descendant) return NO;

    // Climb to whichever ancestor is the tab bar controller's own child: that is
    // the navigation controller itself in the stock layout, and the enclosing
    // split view controller under the pane layout.
    for (UIViewController *node = descendant; node != nil; node = node.parentViewController) {
        if (node.parentViewController == tabBarController) {
            tabBarController.selectedViewController = node;
            return YES;
        }
    }
    ApolloLog(@"[Common] %@ is not inside any tab of %@; selection unchanged",
              NSStringFromClass([descendant class]), NSStringFromClass([tabBarController class]));
    return NO;
}

UIViewController *ApolloContentColumnForSplitViewController(UISplitViewController *split) {
    if (![split isKindOfClass:[UISplitViewController class]]) return split;

    SEL preferred = NSSelectorFromString(@"apollo_preferredContentColumnController");
    if ([split respondsToSelector:preferred]) {
        @try {
            UIViewController *column = ((UIViewController *(*)(id, SEL))objc_msgSend)(split, preferred);
            if (column) return column;
        } @catch (NSException *exception) {
            ApolloLog(@"[Common] preferred content column threw on %@: %@", split, exception);
        }
    }

    // Any other split view controller: the trailing column is the detail one.
    UIViewController *fallback = split.viewControllers.lastObject ?: split.viewControllers.firstObject;
    return fallback ?: split;
}

UINavigationController *ApolloNavigationControllerForTabChild(UIViewController *child) {
    if (!child) return nil;
    if ([child isKindOfClass:[UINavigationController class]]) return (UINavigationController *)child;
    if ([child isKindOfClass:[UISplitViewController class]]) {
        return ApolloNavigationControllerForSplitColumn((UISplitViewController *)child,
                                                        UISplitViewControllerColumnPrimary);
    }
    // Not a container we recognize — fall back to the controller's own
    // navigation controller, which covers a plain view controller hosted
    // directly in a tab.
    return child.navigationController;
}

NSArray<UINavigationController *> *ApolloAllNavigationControllersForTabChild(UIViewController *child) {
    if (!child) return @[];

    if ([child isKindOfClass:[UISplitViewController class]]) {
        UISplitViewController *split = (UISplitViewController *)child;
        NSMutableArray<UINavigationController *> *navs = [NSMutableArray arrayWithCapacity:3];
        const UISplitViewControllerColumn columns[] = {
            UISplitViewControllerColumnPrimary,
            UISplitViewControllerColumnSupplementary,
            UISplitViewControllerColumnSecondary,
        };
        for (size_t i = 0; i < sizeof(columns) / sizeof(columns[0]); i++) {
            UINavigationController *nav = ApolloNavigationControllerForSplitColumn(split, columns[i]);
            // A two-column install answers the same controller for more than one
            // column; de-duplicate so walkers do not visit a stack twice.
            if (nav && ![navs containsObject:nav]) [navs addObject:nav];
        }
        return navs;
    }

    UINavigationController *nav = ApolloNavigationControllerForTabChild(child);
    return nav ? @[ nav ] : @[];
}

#pragma mark - Color Helpers

UIColor *ApolloColorFromHexString(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (clean.length != 6) return nil;
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0
                           green:((value >> 8) & 0xFF) / 255.0
                            blue:(value & 0xFF) / 255.0
                           alpha:1.0];
}

NSString *ApolloHexStringFromColor(UIColor *color) {
    if (![color isKindOfClass:[UIColor class]]) return nil;
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return nil;
    r = MIN(MAX(r, 0.0), 1.0);
    g = MIN(MAX(g, 0.0), 1.0);
    b = MIN(MAX(b, 0.0), 1.0);
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)lround(r * 255.0), (int)lround(g * 255.0), (int)lround(b * 255.0)];
}

BOOL ApolloColorIsLight(UIColor *color) {
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![color isKindOfClass:[UIColor class]] || ![color getRed:&r green:&g blue:&b alpha:&a]) {
        return YES;
    }
    // Rec.601 perceptual luminance. Bright fills (yellow, mint, lime) land high
    // and want dark text; saturated blues/purples land low and want white text.
    CGFloat luminance = 0.299 * r + 0.587 * g + 0.114 * b;
    return luminance >= 0.6;
}

UIColor *ApolloLinkPreviewPresetColor(NSInteger preset) {
    switch (preset) {
        case ApolloLinkPreviewCardColorGray:     return [UIColor colorWithWhite:0.56 alpha:1.0];
        case ApolloLinkPreviewCardColorRed:      return [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0];
        case ApolloLinkPreviewCardColorOrange:   return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorYellow:   return [UIColor colorWithRed:1.00 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorGreen:    return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        case ApolloLinkPreviewCardColorMint:     return [UIColor colorWithRed:0.00 green:0.78 blue:0.75 alpha:1.0];
        case ApolloLinkPreviewCardColorTeal:     return [UIColor colorWithRed:0.19 green:0.69 blue:0.78 alpha:1.0];
        case ApolloLinkPreviewCardColorCyan:     return [UIColor colorWithRed:0.20 green:0.68 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorBlue:     return [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0];
        case ApolloLinkPreviewCardColorIndigo:   return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
        case ApolloLinkPreviewCardColorPurple:   return [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1.0];
        case ApolloLinkPreviewCardColorPink:     return [UIColor colorWithRed:1.00 green:0.18 blue:0.33 alpha:1.0];
        case ApolloLinkPreviewCardColorBrown:    return [UIColor colorWithRed:0.64 green:0.52 blue:0.37 alpha:1.0];
        case ApolloLinkPreviewCardColorCoral:    return [UIColor colorWithRed:1.00 green:0.50 blue:0.31 alpha:1.0];
        case ApolloLinkPreviewCardColorLime:     return [UIColor colorWithRed:0.60 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorOlive:    return [UIColor colorWithRed:0.50 green:0.60 blue:0.20 alpha:1.0];
        case ApolloLinkPreviewCardColorLavender: return [UIColor colorWithRed:0.56 green:0.45 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorSlate:    return [UIColor colorWithRed:0.35 green:0.43 blue:0.50 alpha:1.0];
        case ApolloLinkPreviewCardColorNeutral:
        default:                                 return [UIColor colorWithWhite:0.72 alpha:1.0];
    }
}

uint32_t ApolloPackedColorFromHexString(NSString *hex) {
    UIColor *color = ApolloColorFromHexString(hex);
    if (!color) return 0;
    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return 0;
    uint32_t R = (uint32_t)lround(MIN(MAX(r, 0.0), 1.0) * 255.0);
    uint32_t G = (uint32_t)lround(MIN(MAX(g, 0.0), 1.0) * 255.0);
    uint32_t B = (uint32_t)lround(MIN(MAX(b, 0.0), 1.0) * 255.0);
    return (1u << 24) | (R << 16) | (G << 8) | B;
}

void ApolloSetLinkPreviewCardColorHex(NSString *hex) {
    UIColor *color = ApolloColorFromHexString(hex);
    // Canonicalize to "RRGGBB" uppercase so persistence + UI display stay tidy.
    sLinkPreviewCardColorHex = color ? ApolloHexStringFromColor(color) : nil;
    // Background renderers consume only this self-contained packed value; the
    // NSString remains main-thread settings state.
    __atomic_store_n(&sLinkPreviewCardColorPacked,
                     color ? ApolloPackedColorFromHexString(sLinkPreviewCardColorHex) : 0,
                     __ATOMIC_RELAXED);
}

double ApolloPerfNowMs(void) {
    return CACurrentMediaTime() * 1000.0;
}

// --- Tweak-UI text node marker -------------------------------------------
// Content scans (translation's post-body candidate walk, etc.) must never
// treat tweak-drawn text as user content. One shared assoc key, set at node
// creation by whichever module draws the UI.
static char kApolloTweakUITextNodeKey;

void ApolloMarkTweakUITextNode(id node) {
    if (!node) return;
    objc_setAssociatedObject(node, &kApolloTweakUITextNodeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloTextNodeIsTweakUI(id node) {
    if (!node) return NO;
    return [objc_getAssociatedObject(node, &kApolloTweakUITextNodeKey) boolValue];
}
