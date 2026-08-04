#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One pending local crash report, loaded and already sanitized. The raw
// KSCrash dictionary never leaves ApolloCrashManager/ApolloCrashSanitizer —
// every consumer (review UI, export, web form) sees only this allowlisted
// representation.
@interface ApolloPendingCrashReport : NSObject

@property (nonatomic, assign) int64_t reportID;
@property (nonatomic, strong, nullable) NSDate *crashDate;
// "signal" | "mach" | "nsexception" | "cpp_exception" | "memory_termination" | "user" | "unknown"
@property (nonatomic, copy) NSString *crashCategory;
@property (nonatomic, copy, nullable) NSString *exceptionName;
@property (nonatomic, copy, nullable) NSString *sanitizedReason;
// The full allowlisted outgoing report (JSON-safe).
@property (nonatomic, copy) NSDictionary *sanitizedDictionary;
// Short human-readable summary (crash type + top frames) for lists/summary.txt.
@property (nonatomic, copy) NSString *humanReadableSummary;

// Pretty-printed JSON of sanitizedDictionary (what "View Technical Report"
// shows and what gets attached to the form).
- (NSString *)sanitizedJSONString;

@end

// Owns the KSCrash recording layer: installs it with the privacy-locked
// configuration, and fronts the local report store (enumerate / load+sanitize
// / delete). Recording is LOCAL ONLY — no sink, no filters, no transmission
// path exists in the compiled modules.
@interface ApolloCrashManager : NSObject

@property (class, nonatomic, readonly) ApolloCrashManager *sharedManager;

@property (nonatomic, readonly, getter=isInstalled) BOOL installed;
@property (nonatomic, readonly) NSArray<NSNumber *> *pendingReportIDs;
@property (nonatomic, readonly) NSInteger pendingReportCount;
// YES when KSCrash detected that the previous launch ended in a crash.
@property (nonatomic, readonly) BOOL crashedLastLaunch;

// Install the recorder unless the user disabled UDKeyCrashCaptureEnabled.
// Must run before Apollo's own code executes (%ctor); KSCrash cannot be
// reconfigured afterwards without a process restart.
- (void)installCrashRecorderIfEnabled;

// Load + sanitize one report. Returns nil (and sets error) when the report
// is missing or cannot be represented safely.
- (nullable ApolloPendingCrashReport *)pendingReportForID:(int64_t)reportID
                                                    error:(NSError *_Nullable *_Nullable)error;

- (void)deleteReportWithID:(int64_t)reportID;
- (void)deleteAllReports;

// Re-publish KSCrash userInfo as base build metadata + the given enumerated
// recent-actions array (from ApolloCrashContext). JSON-safe values only.
- (void)publishUserInfoWithRecentActions:(NSArray<NSDictionary *> *)recentActions;

@end

NS_ASSUME_NONNULL_END
