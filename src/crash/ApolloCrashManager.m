#import "crash/ApolloCrashManager.h"

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"
// Relative path on purpose: a plain "Version.h" can resolve to Theos's
// vendored lowercase version.h from this subdirectory.
#import "../Version.h"
#import "crash/ApolloCrashSanitizer.h"

// KSCrash recording layer only (namespaced to KSCrash_ApolloReborn — see
// Makefile). No sinks/installations/filters are compiled into the dylib.
#import "KSCrash.h"
#import "KSCrashConfiguration.h"
#import "KSCrashMonitorType.h"
#import "KSCrashReport.h"
#import "KSCrashReportStore.h"

@implementation ApolloPendingCrashReport

- (NSString *)sanitizedJSONString {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.sanitizedDictionary ?: @{}
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

@end

@implementation ApolloCrashManager {
    BOOL _installed;
    NSDictionary *_baseUserInfo;
}

+ (instancetype)sharedManager {
    static ApolloCrashManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (BOOL)isInstalled {
    return _installed;
}

- (NSString *)crashStoragePath {
    // Library/Caches: diagnostic + disposable. Not backed up, survives
    // restarts, cleared on reinstall, and iOS may purge it under storage
    // pressure — all acceptable for local crash reports.
    NSArray<NSString *> *cachePaths =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheRoot = cachePaths.firstObject ?: NSTemporaryDirectory();
    return [cacheRoot stringByAppendingPathComponent:@"ApolloReborn/LocalCrashReports"];
}

- (void)installCrashRecorderIfEnabled {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // Explicit objectForKey check: install runs in %ctor and must not depend
    // on registerDefaults having run first. Absent value == default ON
    // (capture is local-only; nothing is ever transmitted automatically).
    if ([defaults objectForKey:UDKeyCrashCaptureEnabled] &&
        ![defaults boolForKey:UDKeyCrashCaptureEnabled]) {
        ApolloLog(@"[CrashCapture] local crash recording disabled by user");
        return;
    }

    KSCrashConfiguration *configuration = [[KSCrashConfiguration alloc] init];
    configuration.installPath = [self crashStoragePath];

    configuration.reportStoreConfiguration.appName = @"ApolloReborn";
    // A handful of pending reports is plenty; dozens of stale crashes have no
    // diagnostic value and just accumulate risk surface.
    configuration.reportStoreConfiguration.maxReportCount = 3;
    // Reports are deleted ONLY by explicit user action or after the report
    // site confirms a submission that included the crash attachment.
    configuration.reportStoreConfiguration.reportCleanupPolicy = KSCrashReportCleanupPolicyNever;

    configuration.monitors =
        KSCrashMonitorTypeMachException |
        KSCrashMonitorTypeSignal |
        KSCrashMonitorTypeCPPException |
        KSCrashMonitorTypeNSException |
        KSCrashMonitorTypeSystem |
        KSCrashMonitorTypeApplicationState |
        KSCrashMonitorTypeMemoryTermination;

    // Explicit privacy and stability choices. Memory introspection is the one
    // that matters most: it records ObjC objects and C strings referenced by
    // registers/stack — i.e. arbitrary user content — so it stays off even
    // though off is the upstream default (an upstream default change must not
    // silently broaden collection). Queue-name search can crash the crashed
    // process; the deadlock watchdog is experimental; SIGTERM is noisy;
    // console capture would duplicate the (separately consented) debug log.
    configuration.enableMemoryIntrospection = NO;
    configuration.enableQueueNameSearch = NO;
    configuration.addConsoleLogToReport = NO;
    configuration.printPreviousLogOnStartup = NO;
    configuration.deadlockWatchdogInterval = 0;
    configuration.enableSigTermMonitoring = NO;
    // __cxa_throw interposition rewrites a process-global C function. In our
    // injected environment (host app + other tweaks may unwind C++ anywhere)
    // that is a stability risk we don't need: the C++ exception monitor still
    // catches std::terminate without it, just with a shallower stack.
    configuration.enableSwapCxaThrow = NO;

    _baseUserInfo = [self buildBaseUserInfo];
    configuration.userInfoJSON = @{ @"apollo_reborn": _baseUserInfo };

    NSError *error = nil;
    BOOL installed = [[KSCrash sharedInstance] installWithConfiguration:configuration error:&error];
    _installed = installed;
    if (!installed) {
        ApolloLog(@"[CrashCapture] KSCrash installation failed: %@",
                  error.localizedDescription ?: @"unknown error");
        return;
    }

    [self configureStorageProtection];
    ApolloLog(@"[CrashCapture] local crash recording installed (%ld pending report(s))",
              (long)self.pendingReportCount);
}

- (NSDictionary *)buildBaseUserInfo {
    NSString *version = @TWEAK_VERSION;
    if ([version hasPrefix:@"v"]) version = [version substringFromIndex:1];
    return @{
        @"diagnostic_schema": @1,
        @"version": version ?: @"unknown",
        @"build_variant": ApolloBuildVariant() ?: @"unknown",
#ifdef APOLLO_GIT_COMMIT
        @"git_commit": @APOLLO_GIT_COMMIT,
#else
        @"git_commit": @"unknown",
#endif
    };
}

- (void)configureStorageProtection {
    [[NSFileManager defaultManager]
              createDirectoryAtPath:[self crashStoragePath]
        withIntermediateDirectories:YES
                         attributes:@{ NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication }
                              error:nil];
}

#pragma mark - Report store

- (KSCrashReportStore *)reportStore {
    return _installed ? [KSCrash sharedInstance].reportStore : nil;
}

- (NSArray<NSNumber *> *)pendingReportIDs {
    return [self reportStore].reportIDs ?: @[];
}

- (NSInteger)pendingReportCount {
    return self.pendingReportIDs.count;
}

- (BOOL)crashedLastLaunch {
    return _installed && [KSCrash sharedInstance].crashedLastLaunch;
}

- (ApolloPendingCrashReport *)pendingReportForID:(int64_t)reportID error:(NSError **)error {
    KSCrashReportDictionary *rawReport = [[self reportStore] reportForID:reportID];
    if (![rawReport isKindOfClass:[KSCrashReportDictionary class]] || !rawReport.value) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloCrashCapture"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                     @"The local crash report could not be read." }];
        }
        return nil;
    }

    NSDictionary *sanitized = [ApolloCrashSanitizer sanitizedReportFromKSCrashDictionary:rawReport.value];
    if (!sanitized) {
        if (error) {
            *error = [NSError errorWithDomain:@"ApolloCrashCapture"
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                     @"The local crash report could not be represented safely." }];
        }
        return nil;
    }

    ApolloPendingCrashReport *result = [[ApolloPendingCrashReport alloc] init];
    result.reportID = reportID;
    result.sanitizedDictionary = sanitized;
    result.crashDate = [ApolloCrashSanitizer crashDateFromSanitizedReport:sanitized];
    result.crashCategory = sanitized[@"crash"][@"category"] ?: @"unknown";
    result.exceptionName = sanitized[@"crash"][@"exception_name"];
    result.sanitizedReason = sanitized[@"crash"][@"sanitized_reason"];
    result.humanReadableSummary = [ApolloCrashSanitizer textSummaryForSanitizedReport:sanitized];
    return result;
}

- (void)deleteReportWithID:(int64_t)reportID {
    [[self reportStore] deleteReportWithID:reportID];
    ApolloLog(@"[CrashCapture] deleted local report %lld", reportID);
}

- (void)deleteAllReports {
    [[self reportStore] deleteAllReports];
    ApolloLog(@"[CrashCapture] deleted all local reports");
}

#pragma mark - userInfo

- (void)publishUserInfoWithRecentActions:(NSArray<NSDictionary *> *)recentActions {
    if (!_installed) return;
    NSMutableDictionary *info = [(_baseUserInfo ?: @{}) mutableCopy];
    info[@"recent_actions"] = recentActions ?: @[];
    [KSCrash sharedInstance].userInfo = @{ @"apollo_reborn": info };
}

@end
