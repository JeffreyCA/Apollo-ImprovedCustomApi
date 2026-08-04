#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Converts a raw KSCrash report dictionary into the Apollo-owned shareable
// representation. Strictly an ALLOWLIST: fields are copied because they were
// individually reviewed, never because they weren't blocklisted — an upstream
// KSCrash schema addition can therefore never leak into an outgoing report.
//
// Explicitly absent from the output: Reddit account data, subreddit names,
// post/comment content or IDs, search terms, URLs, OAuth/API secrets, the
// bundle identifier, container paths, device hashes, locale and timezone,
// thread/queue names, raw stack memory, and anything introspected.
@interface ApolloCrashSanitizer : NSObject

// nil when the raw report is structurally unusable.
+ (nullable NSDictionary *)sanitizedReportFromKSCrashDictionary:(NSDictionary *)rawReport;

// Short human-readable summary (type, environment, crashed-thread frames).
+ (NSString *)textSummaryForSanitizedReport:(NSDictionary *)sanitizedReport;

+ (nullable NSDate *)crashDateFromSanitizedReport:(NSDictionary *)sanitizedReport;

// Aggressive redaction for free-form diagnostic strings (exception reasons,
// diagnoses): URLs, r/…, u/…, emails, bearer/token values, 500-char cap.
// Returns nil for empty input. Exposed for reuse and testability.
+ (nullable NSString *)sanitizedDiagnosticString:(nullable NSString *)input;

@end

NS_ASSUME_NONNULL_END
