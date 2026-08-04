// Opt-in sim-only diagnostics for the "just-posted comment renders blank"
// bug class (missing author/avatar/flair, score 0, epoch timestamp until
// reload — Reddit intermittently serves the legacy old-reddit write-response
// shape, 2026-08 even to OAuth clients). Build with:
//   APOLLO_COMMENT_DEBUG=1 scripts/run-in-sim.sh
// Logs, for /api/comment writes:
//   1. the outgoing request path + parameters (postPath:parameters:completion:)
//   2. the raw response body handed to the serializer
//   3. the parsed objects delivered to the submitComment completion, with the
//      fields the comment cell renders (author/created/score/fullname)
// Plus a legacy-response-shape simulator to exercise the repair while Reddit
// happens to be returning the modern shape: launch the app with
//   -ApolloSimulateLegacyCommentResponse YES
// (argument domain) and every modern /api/comment write response is converted
// back into the legacy {parent, content, contentText, …} shape before parsing.
// Compiled ONLY under APOLLO_SIM_BUILD + APOLLO_COMMENT_DEBUG (see Makefile) —
// never ships to devices.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

typedef void (^ApolloCommentDebugCompletion)(id objects, NSError *error);

// os_log clips a single message around 1KB; chunk long payloads.
static void ApolloCommentDebugLogChunked(NSString *tag, NSString *payload) {
    if (payload.length == 0) {
        ApolloLog(@"[CommentDebug] %@ (empty)", tag);
        return;
    }
    NSUInteger chunk = 700;
    NSUInteger count = (payload.length + chunk - 1) / chunk;
    for (NSUInteger i = 0; i < count; i++) {
        NSRange range = NSMakeRange(i * chunk, MIN(chunk, payload.length - i * chunk));
        ApolloLog(@"[CommentDebug] %@ [%lu/%lu] %@", tag, (unsigned long)(i + 1), (unsigned long)count,
                  [payload substringWithRange:range]);
    }
}

// KVC (valueForKey:) rather than objc_msgSend-as-id: several RDK getters
// (score, scoreHidden) return primitives, and retaining a raw BOOL crashes.
// KVC boxes primitives into NSNumber for free.
static NSString *ApolloCommentDebugString(id model, NSString *key) {
    if (![model respondsToSelector:NSSelectorFromString(key)]) return @"(no-sel)";
    id value = nil;
    @try { value = [model valueForKey:key]; }
    @catch (__unused NSException *e) { return @"(threw)"; }
    if (!value) return @"(nil)";
    return [NSString stringWithFormat:@"%@", value];
}

static NSString *ApolloCommentDebugDescribeModel(id model) {
    if (!model) return @"(nil model)";
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%@ %p", NSStringFromClass([model class]), model];
    [s appendFormat:@" fullname=%@", ApolloCommentDebugString(model, @"fullName")];
    [s appendFormat:@" author=%@", ApolloCommentDebugString(model, @"author")];
    [s appendFormat:@" createdUTC=%@", ApolloCommentDebugString(model, @"createdUTC")];
    [s appendFormat:@" score=%@", ApolloCommentDebugString(model, @"score")];
    [s appendFormat:@" scoreHidden=%@", ApolloCommentDebugString(model, @"scoreHidden")];
    [s appendFormat:@" subreddit=%@", ApolloCommentDebugString(model, @"subreddit")];
    NSString *body = ApolloCommentDebugString(model, @"body");
    [s appendFormat:@" bodyLen=%lu", (unsigned long)body.length];
    [s appendString:@">"];
    return s;
}

static ApolloCommentDebugCompletion ApolloCommentDebugWrapCompletion(NSString *label, ApolloCommentDebugCompletion completion) {
    if (!completion) {
        ApolloLog(@"[CommentDebug] %@ called with nil completion", label);
        return completion;
    }
    return ^(id objects, NSError *error) {
        ApolloLog(@"[CommentDebug] %@ completion: objectsClass=%@ count=%@ error=%@",
                  label, NSStringFromClass([objects class]),
                  [objects respondsToSelector:@selector(count)] ? @([objects count]) : @"n/a",
                  error);
        if ([objects isKindOfClass:[NSArray class]]) {
            for (id model in (NSArray *)objects) {
                ApolloLog(@"[CommentDebug] %@ parsed model: %@", label, ApolloCommentDebugDescribeModel(model));
            }
        } else if (objects) {
            ApolloLog(@"[CommentDebug] %@ parsed model (non-array): %@", label, ApolloCommentDebugDescribeModel(objects));
        }
        completion(objects, error);
    };
}

%hook RDKClient

- (id)postPath:(NSString *)path parameters:(id)parameters completion:(id)completion {
    if ([path isKindOfClass:[NSString class]] &&
        [path rangeOfString:@"api/comment"].location != NSNotFound) {
        ApolloCommentDebugLogChunked(@"postPath", [NSString stringWithFormat:@"%@ params=%@", path, parameters]);
    }
    return %orig;
}

- (id)submitComment:(id)body onLink:(id)link completion:(ApolloCommentDebugCompletion)completion {
    ApolloCommentDebugCompletion wrapped = ApolloCommentDebugWrapCompletion(@"submitComment:onLink:", completion);
    return %orig(body, link, wrapped);
}

- (id)submitComment:(id)body asReplyToComment:(id)parent completion:(ApolloCommentDebugCompletion)completion {
    ApolloCommentDebugCompletion wrapped = ApolloCommentDebugWrapCompletion(@"submitComment:asReplyToComment:", completion);
    return %orig(body, parent, wrapped);
}

- (id)submitComment:(id)body onThingWithFullName:(id)fullName completion:(ApolloCommentDebugCompletion)completion {
    ApolloCommentDebugCompletion wrapped = ApolloCommentDebugWrapCompletion(@"submitComment:onThingWithFullName:", completion);
    return %orig(body, fullName, wrapped);
}

%end

// Rebuilds a modern /api/comment response as the legacy old-reddit shape that
// Reddit intermittently serves (2026-08, OAuth included) — {parent, content,
// contentText, contentHTML, id, link, replies} with the data-* attributes the
// repair's extractors read. Lets the fix be exercised on the OAuth path while
// Reddit happens to be returning the modern shape. Enabled per-launch with
// `-ApolloSimulateLegacyCommentResponse YES` (argument domain).
static NSData *ApolloCommentDebugLegacyData(NSData *data) {
    if (data.length == 0) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *json = [root[@"json"] isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSArray *things = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"][@"things"] : nil;
    if (![things isKindOfClass:[NSArray class]] || things.count == 0) return nil;

    NSMutableArray *legacyThings = [NSMutableArray array];
    for (NSDictionary *thing in things) {
        NSDictionary *td = [thing isKindOfClass:[NSDictionary class]] ? thing[@"data"] : nil;
        NSString *body = [td[@"body"] isKindOfClass:[NSString class]] ? td[@"body"] : nil;
        if (!body) return nil; // already legacy or unexpected — don't simulate
        NSString *fullname = [NSString stringWithFormat:@"t1_%@", td[@"id"]];
        NSString *permalink = [td[@"permalink"] isKindOfClass:[NSString class]] ? td[@"permalink"]
            : [NSString stringWithFormat:@"/r/%@/comments/%@/x/%@/", td[@"subreddit"],
               [[td[@"link_id"] description] stringByReplacingOccurrencesOfString:@"t3_" withString:@""], td[@"id"]];
        NSString *content = [NSString stringWithFormat:
            @"<div class=\" thing id-%@ comment \" data-fullname=\"%@\" data-type=\"comment\" "
            @"data-subreddit=\"%@\" data-author=\"%@\" data-permalink=\"%@\">"
            @"<div class=\"md\"><p>%@</p></div></div>",
            fullname, fullname, td[@"subreddit"], td[@"author"], permalink, body];
        [legacyThings addObject:@{
            @"kind": @"t1",
            @"data": @{
                @"parent": td[@"parent_id"] ?: @"",
                @"content": content,
                @"contentText": body,
                @"contentHTML": td[@"body_html"] ?: @"",
                @"link": td[@"link_id"] ?: @"",
                @"replies": @"",
                @"id": fullname,
            },
        }];
    }
    NSDictionary *legacyRoot = @{ @"json": @{ @"errors": @[], @"data": @{ @"things": legacyThings } } };
    return [NSJSONSerialization dataWithJSONObject:legacyRoot options:0 error:NULL];
}

%hook RDKResponseSerializer

- (id)responseObjectForResponse:(NSURLResponse *)response data:(NSData *)data error:(NSError **)error {
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSString *path = http.URL.path ?: @"";
    BOOL isCommentWrite = [path rangeOfString:@"/api/comment"].location != NSNotFound;
    if (isCommentWrite && http.statusCode == 200 &&
        [[NSUserDefaults standardUserDefaults] boolForKey:@"ApolloSimulateLegacyCommentResponse"]) {
        NSData *legacy = ApolloCommentDebugLegacyData(data);
        if (legacy) {
            ApolloLog(@"[CommentDebug] SIMULATING legacy /api/comment response shape (%lu -> %lu bytes)",
                      (unsigned long)data.length, (unsigned long)legacy.length);
            data = legacy;
        }
    }
    id obj = %orig(response, data, error);
    if (isCommentWrite) {
        NSString *raw = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        ApolloCommentDebugLogChunked(
            [NSString stringWithFormat:@"/api/comment response status=%ld bytes=%lu", (long)http.statusCode, (unsigned long)data.length],
            raw ?: @"(binary/undecodable)");
    }
    return obj;
}

%end

%ctor {
    %init;
    ApolloLog(@"[CommentDebug] diagnostics module loaded");
}
