#import "crash/ApolloCrashSanitizer.h"

// Hard limits applied before anything is offered for submission. Truncation
// order when the whole report would exceed the size cap: non-crashed threads
// lose frames first, then get dropped entirely; the crashed thread's frames
// (up to its cap) always survive.
static const NSUInteger kMaxSanitizedJSONBytes = 1024 * 1024;
static const NSUInteger kMaxThreads = 128;
static const NSUInteger kMaxFramesCrashedThread = 256;
static const NSUInteger kMaxFramesOtherThread = 64;
static const NSUInteger kMaxFramesOtherThreadTight = 16;
static const NSUInteger kMaxBinaryImages = 512;
static const NSUInteger kMaxReasonLength = 500;
static const NSUInteger kMaxRecentActions = 20;

static NSString *ARHexAddress(id value) {
    if (![value isKindOfClass:NSNumber.class]) return nil;
    return [NSString stringWithFormat:@"0x%016llx", [(NSNumber *)value unsignedLongLongValue]];
}

static NSNumber *ARNumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static NSString *ARString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *ARDict(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *ARArray(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

@implementation ApolloCrashSanitizer

#pragma mark - Redaction

+ (NSString *)sanitizedDiagnosticString:(NSString *)input {
    if (![input isKindOfClass:NSString.class] || input.length == 0) return nil;

    NSString *result = input;
    // Order matters: URLs first (they can contain r/… and u/… path segments),
    // then Reddit identifiers, then credentials.
    NSArray<NSArray<NSString *> *> *rules = @[
        @[ @"https?://[^\\s\\]\\[\\)\\(<>]+", @"<url>" ],
        @[ @"(?:^|(?<=\\s))/?r/[A-Za-z0-9_]+", @"<subreddit>" ],
        @[ @"(?:^|(?<=\\s))/?(?:u|user)/[A-Za-z0-9_-]+", @"<user>" ],
        @[ @"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", @"<email>" ],
        @[ @"(bearer\\s+)[A-Za-z0-9._~+/-]+=*", @"$1<redacted>" ],
        @[ @"(access_token|refresh_token|api[_-]?key|client[_-]?secret)[\"'=:\\s]+[^\\s,\"'}]+", @"$1=<redacted>" ],
    ];
    for (NSArray<NSString *> *rule in rules) {
        NSRegularExpression *regex =
            [NSRegularExpression regularExpressionWithPattern:rule[0]
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
        result = [regex stringByReplacingMatchesInString:result
                                                 options:0
                                                   range:NSMakeRange(0, result.length)
                                            withTemplate:rule[1]];
    }
    if (result.length > kMaxReasonLength) {
        result = [[result substringToIndex:kMaxReasonLength] stringByAppendingString:@"… <truncated>"];
    }
    return result;
}

#pragma mark - Sections

// The report store hands back report.timestamp as raw epoch MICROSECONDS
// (KSCrash's on-disk form; the RFC3339 string only appears in fixed/exported
// reports). Accept both and normalize to ISO8601 UTC.
+ (NSString *)iso8601TimestampFromRaw:(id)value {
    NSString *stringValue = ARString(value);
    if (stringValue) return stringValue;
    NSNumber *microseconds = ARNumber(value);
    if (!microseconds) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:microseconds.doubleValue / 1e6];
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
    });
    return [formatter stringFromDate:date];
}

// crash.error → outgoing "crash" section. Every field here is a reviewed,
// technical, non-content value; the only free-form strings pass through
// +sanitizedDiagnosticString.
+ (NSDictionary *)crashSectionFromRaw:(NSDictionary *)rawReport {
    NSDictionary *crash = ARDict(rawReport[@"crash"]);
    NSDictionary *error = ARDict(crash[@"error"]);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    out[@"timestamp"] = [self iso8601TimestampFromRaw:ARDict(rawReport[@"report"])[@"timestamp"]] ?: [NSNull null];
    out[@"category"] = ARString(error[@"type"]) ?: @"unknown";
    out[@"address"] = ARHexAddress(error[@"address"]) ?: [NSNull null];

    NSDictionary *nsexception = ARDict(error[@"nsexception"]);
    NSDictionary *cppException = ARDict(error[@"cpp_exception"]);
    NSString *exceptionName = ARString(nsexception[@"name"]) ?: ARString(cppException[@"name"]);
    out[@"exception_name"] = exceptionName ?: [NSNull null];
    out[@"sanitized_reason"] = [self sanitizedDiagnosticString:ARString(error[@"reason"])] ?: [NSNull null];

    NSDictionary *signal = ARDict(error[@"signal"]);
    if (signal) {
        out[@"signal"] = @{
            @"name": ARString(signal[@"name"]) ?: [NSNull null],
            @"code": ARNumber(signal[@"code"]) ?: [NSNull null],
            @"code_name": ARString(signal[@"code_name"]) ?: [NSNull null],
        };
    }
    NSDictionary *mach = ARDict(error[@"mach"]);
    if (mach) {
        out[@"mach_exception"] = @{
            @"exception": ARNumber(mach[@"exception"]) ?: [NSNull null],
            @"exception_name": ARString(mach[@"exception_name"]) ?: [NSNull null],
            @"code": ARNumber(mach[@"code"]) ?: [NSNull null],
            @"subcode": ARNumber(mach[@"subcode"]) ?: [NSNull null],
        };
    }

    // Likely-jetsam reports: numeric memory state only (level/pressure are
    // short enum strings like "critical").
    NSDictionary *memoryTermination = ARDict(error[@"memory_termination"]);
    if (memoryTermination) {
        NSMutableDictionary *memory = [NSMutableDictionary dictionary];
        for (NSString *key in @[ @"memory_footprint", @"memory_limit", @"memory_remaining" ]) {
            memory[key] = ARNumber(memoryTermination[key]) ?: [NSNull null];
        }
        for (NSString *key in @[ @"memory_level", @"memory_pressure" ]) {
            NSString *value = ARString(memoryTermination[key]);
            if (value.length > 0 && value.length <= 32) memory[key] = value;
        }
        out[@"memory_termination"] = memory;
    }

    // KSCrash's machine-generated diagnosis ("possible null pointer
    // dereference", zombie hints). Technical, but free-form — redact it.
    NSString *diagnosis = [self sanitizedDiagnosticString:ARString(crash[@"diagnosis"])];
    if (diagnosis) out[@"diagnosis"] = diagnosis;

    return out;
}

+ (NSDictionary *)environmentSectionFromRaw:(NSDictionary *)rawReport {
    NSDictionary *system = ARDict(rawReport[@"system"]);
    NSDictionary *apolloInfo = ARDict(ARDict(rawReport[@"user"])[@"apollo_reborn"]);
    return @{
        @"apollo_reborn_version": ARString(apolloInfo[@"version"]) ?: @"unknown",
        @"build_variant": ARString(apolloInfo[@"build_variant"]) ?: @"unknown",
        @"git_commit": ARString(apolloInfo[@"git_commit"]) ?: @"unknown",
        @"diagnostic_schema": ARNumber(apolloInfo[@"diagnostic_schema"]) ?: @1,
        @"ios_version": ARString(system[@"system_version"]) ?: [NSNull null],
        @"os_build": ARString(system[@"os_version"]) ?: [NSNull null],
        @"device_model": ARString(system[@"machine"]) ?: [NSNull null],
        @"architecture": ARString(system[@"cpu_arch"]) ?: [NSNull null],
        // Apollo's own version matters for matching the base IPA generation.
        @"app_version": ARString(system[@"CFBundleShortVersionString"]) ?: [NSNull null],
        @"app_build": ARString(system[@"CFBundleVersion"]) ?: [NSNull null],
    };
}

// Allowlisted frame: addresses + image/symbol names only. Never thread
// names, queue names, registers, stack memory, or notable addresses.
+ (NSDictionary *)sanitizedFrame:(NSDictionary *)frame {
    return @{
        @"instruction_address": ARHexAddress(frame[@"instruction_addr"]) ?: [NSNull null],
        @"object_address": ARHexAddress(frame[@"object_addr"]) ?: [NSNull null],
        @"object_name": [ARString(frame[@"object_name"]) lastPathComponent] ?: [NSNull null],
        @"symbol_address": ARHexAddress(frame[@"symbol_addr"]) ?: [NSNull null],
        @"symbol_name": ARString(frame[@"symbol_name"]) ?: [NSNull null],
    };
}

+ (NSArray<NSDictionary *> *)threadsSectionFromRaw:(NSDictionary *)rawReport
                                     maxOtherFrames:(NSUInteger)maxOtherFrames
                                    includeAllThreads:(BOOL)includeAllThreads
                                          truncated:(BOOL *)truncated {
    NSArray *threads = ARArray(ARDict(rawReport[@"crash"])[@"threads"]);
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSUInteger threadCount = 0;
    for (NSDictionary *thread in threads) {
        if (!ARDict(thread)) continue;
        BOOL crashed = [ARNumber(thread[@"crashed"]) boolValue];
        if (!crashed && !includeAllThreads) continue;
        if (threadCount >= kMaxThreads) { *truncated = YES; break; }

        NSArray *contents = ARArray(ARDict(thread[@"backtrace"])[@"contents"]);
        NSUInteger maxFrames = crashed ? kMaxFramesCrashedThread : maxOtherFrames;
        NSMutableArray *backtrace = [NSMutableArray arrayWithCapacity:MIN(contents.count, maxFrames)];
        for (NSDictionary *frame in contents) {
            if (!ARDict(frame)) continue;
            if (backtrace.count >= maxFrames) { *truncated = YES; break; }
            [backtrace addObject:[self sanitizedFrame:frame]];
        }

        NSMutableDictionary *outThread = [NSMutableDictionary dictionary];
        outThread[@"index"] = ARNumber(thread[@"index"]) ?: @(threadCount);
        outThread[@"crashed"] = @(crashed);
        outThread[@"current"] = @([ARNumber(thread[@"current_thread"]) boolValue]);
        outThread[@"backtrace"] = backtrace;
        NSNumber *skipped = ARNumber(ARDict(thread[@"backtrace"])[@"skipped"]);
        if (skipped.integerValue > 0) outThread[@"frames_skipped"] = skipped;
        [out addObject:outThread];
        threadCount++;
    }
    return out;
}

// Images referenced by kept frames come first so the cap can never cut the
// UUIDs needed to symbolicate what we kept. Paths collapse to filenames.
+ (NSArray<NSDictionary *> *)imagesSectionFromRaw:(NSDictionary *)rawReport
                                       forThreads:(NSArray<NSDictionary *> *)threads
                                        truncated:(BOOL *)truncated {
    NSMutableSet<NSString *> *referencedNames = [NSMutableSet set];
    for (NSDictionary *thread in threads) {
        for (NSDictionary *frame in thread[@"backtrace"]) {
            NSString *name = ARString(frame[@"object_name"]);
            if (name) [referencedNames addObject:name];
        }
    }

    NSMutableArray<NSDictionary *> *referenced = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *rest = [NSMutableArray array];
    for (NSDictionary *image in ARArray(rawReport[@"binary_images"])) {
        if (!ARDict(image)) continue;
        NSString *name = [ARString(image[@"name"]) lastPathComponent];
        NSDictionary *outImage = @{
            @"name": name ?: [NSNull null],
            @"load_address": ARHexAddress(image[@"image_addr"]) ?: [NSNull null],
            @"size": ARNumber(image[@"image_size"]) ?: [NSNull null],
            @"uuid": ARString(image[@"uuid"]) ?: [NSNull null],
            @"cpu_type": ARNumber(image[@"cpu_type"]) ?: [NSNull null],
            @"cpu_subtype": ARNumber(image[@"cpu_subtype"]) ?: [NSNull null],
        };
        if (name && [referencedNames containsObject:name]) {
            [referenced addObject:outImage];
        } else {
            [rest addObject:outImage];
        }
    }
    NSMutableArray *out = [referenced mutableCopy];
    for (NSDictionary *image in rest) {
        if (out.count >= kMaxBinaryImages) { *truncated = YES; break; }
        [out addObject:image];
    }
    if (out.count > kMaxBinaryImages) {
        *truncated = YES;
        [out removeObjectsInRange:NSMakeRange(kMaxBinaryImages, out.count - kMaxBinaryImages)];
    }
    return out;
}

+ (NSArray<NSDictionary *> *)recentActionsFromRaw:(NSDictionary *)rawReport {
    NSArray *actions = ARArray(ARDict(ARDict(rawReport[@"user"])[@"apollo_reborn"])[@"recent_actions"]);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *action in actions) {
        if (!ARDict(action) || out.count >= kMaxRecentActions) break;
        // Re-allowlist even our own data: only the enumerated event name and
        // its coarse age survive the round-trip through KSCrash userInfo.
        NSString *event = ARString(action[@"event"]);
        if (event.length == 0 || event.length > 40) continue;
        [out addObject:@{
            @"event": event,
            @"age_seconds": ARNumber(action[@"age_seconds"]) ?: [NSNull null],
        }];
    }
    return out;
}

#pragma mark - Assembly

+ (NSDictionary *)sanitizedReportFromKSCrashDictionary:(NSDictionary *)rawReport {
    if (!ARDict(rawReport) || !ARDict(rawReport[@"crash"])) return nil;

    BOOL truncated = NO;
    NSArray *threads = [self threadsSectionFromRaw:rawReport
                                    maxOtherFrames:kMaxFramesOtherThread
                                 includeAllThreads:YES
                                         truncated:&truncated];
    NSDictionary *report = [self assembleWithRaw:rawReport threads:threads truncated:truncated];

    // Size backstop: shrink non-crashed threads, then drop them entirely.
    if ([self encodedLength:report] > kMaxSanitizedJSONBytes) {
        threads = [self threadsSectionFromRaw:rawReport
                               maxOtherFrames:kMaxFramesOtherThreadTight
                            includeAllThreads:YES
                                    truncated:&truncated];
        truncated = YES;
        report = [self assembleWithRaw:rawReport threads:threads truncated:truncated];
    }
    if ([self encodedLength:report] > kMaxSanitizedJSONBytes) {
        threads = [self threadsSectionFromRaw:rawReport
                               maxOtherFrames:0
                            includeAllThreads:NO
                                    truncated:&truncated];
        report = [self assembleWithRaw:rawReport threads:threads truncated:YES];
    }
    return report;
}

+ (NSDictionary *)assembleWithRaw:(NSDictionary *)rawReport
                          threads:(NSArray *)threads
                        truncated:(BOOL)truncated {
    BOOL imagesTruncated = NO;
    NSArray *images = [self imagesSectionFromRaw:rawReport forThreads:threads truncated:&imagesTruncated];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"schema_version"] = @1;
    out[@"report_type"] = @"apollo_reborn_crash";
    out[@"crash"] = [self crashSectionFromRaw:rawReport];
    out[@"environment"] = [self environmentSectionFromRaw:rawReport];
    out[@"threads"] = threads;
    out[@"binary_images"] = images;
    out[@"recent_actions"] = [self recentActionsFromRaw:rawReport];
    if (truncated || imagesTruncated) out[@"truncated"] = @YES;
    return out;
}

+ (NSUInteger)encodedLength:(NSDictionary *)report {
    if (![NSJSONSerialization isValidJSONObject:report]) return NSUIntegerMax;
    return [NSJSONSerialization dataWithJSONObject:report options:0 error:nil].length;
}

#pragma mark - Presentation helpers

+ (NSDate *)crashDateFromSanitizedReport:(NSDictionary *)sanitizedReport {
    NSString *timestamp = ARString(ARDict(sanitizedReport[@"crash"])[@"timestamp"]);
    if (!timestamp) return nil;
    // The report store's fixer emits 6-digit fractional seconds
    // ("…T18:09:24.257055Z"), which NSISO8601DateFormatter's default options
    // reject (and its FractionalSeconds option only accepts milliseconds).
    // Strip the fraction before parsing.
    NSRange dot = [timestamp rangeOfString:@"."];
    if (dot.location != NSNotFound && [timestamp hasSuffix:@"Z"]) {
        timestamp = [[timestamp substringToIndex:dot.location] stringByAppendingString:@"Z"];
    }
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
    });
    return [formatter dateFromString:timestamp];
}

+ (NSString *)textSummaryForSanitizedReport:(NSDictionary *)sanitizedReport {
    NSDictionary *crash = ARDict(sanitizedReport[@"crash"]) ?: @{};
    NSDictionary *environment = ARDict(sanitizedReport[@"environment"]) ?: @{};
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    [lines addObject:@"Apollo Reborn crash report (sanitized)"];
    NSString *timestamp = ARString(crash[@"timestamp"]);
    if (timestamp) [lines addObject:[NSString stringWithFormat:@"Date: %@", timestamp]];
    [lines addObject:[NSString stringWithFormat:@"Type: %@%@",
                      ARString(crash[@"category"]) ?: @"unknown",
                      ARString(crash[@"exception_name"])
                          ? [NSString stringWithFormat:@" (%@)", crash[@"exception_name"]] : @""]];
    NSString *reason = ARString(crash[@"sanitized_reason"]);
    if (reason) [lines addObject:[NSString stringWithFormat:@"Reason: %@", reason]];
    NSString *diagnosis = ARString(crash[@"diagnosis"]);
    if (diagnosis) [lines addObject:[NSString stringWithFormat:@"Diagnosis: %@", diagnosis]];
    [lines addObject:[NSString stringWithFormat:@"Apollo Reborn: %@ (%@, %@)",
                      ARString(environment[@"apollo_reborn_version"]) ?: @"unknown",
                      ARString(environment[@"build_variant"]) ?: @"unknown",
                      ARString(environment[@"git_commit"]) ?: @"unknown"]];
    [lines addObject:[NSString stringWithFormat:@"iOS %@ on %@",
                      ARString(environment[@"ios_version"]) ?: @"?",
                      ARString(environment[@"device_model"]) ?: @"?"]];
    [lines addObject:@""];

    for (NSDictionary *thread in ARArray(sanitizedReport[@"threads"])) {
        if (![ARNumber(thread[@"crashed"]) boolValue]) continue;
        [lines addObject:[NSString stringWithFormat:@"Crashed thread (index %@):", thread[@"index"]]];
        NSUInteger frameIndex = 0;
        for (NSDictionary *frame in ARArray(thread[@"backtrace"])) {
            if (frameIndex >= 16) { [lines addObject:@"  …"]; break; }
            NSString *symbol = ARString(frame[@"symbol_name"]);
            [lines addObject:[NSString stringWithFormat:@"  %2lu %-28@ %@%@",
                              (unsigned long)frameIndex,
                              ARString(frame[@"object_name"]) ?: @"?",
                              ARString(frame[@"instruction_address"]) ?: @"?",
                              symbol ? [NSString stringWithFormat:@" (%@)", symbol] : @""]];
            frameIndex++;
        }
        break;
    }
    [lines addObject:@""];
    [lines addObject:@"Full allowlisted report: apollo-reborn-crash.json (addresses + binary UUIDs; symbolicated offline against release dSYMs)."];
    return [lines componentsJoinedByString:@"\n"];
}

@end
