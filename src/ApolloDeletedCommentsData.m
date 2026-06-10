#import "ApolloDeletedCommentsData.h"

#import <objc/message.h>
#import <objc/runtime.h>

#ifdef APOLLO_DELETED_COMMENTS_TESTING
#define ApolloLog(fmt, ...) NSLog((fmt), ##__VA_ARGS__)
BOOL sShowDeletedComments = YES;
BOOL sTapToRevealDeletedComments = NO;
#else
#import "ApolloCommon.h"
#import "ApolloState.h"
#endif

NSString *const ApolloDeletedCommentsObservedThreadNotification = @"ApolloDeletedCommentsObservedThreadNotification";

static const void *kApolloDeletedCommentsResponseDataKey = &kApolloDeletedCommentsResponseDataKey;
static NSMutableSet<NSString *> *sApolloDeletedCommentsDelegateTransformerInstalledClasses = nil;
static NSString *sApolloDeletedCommentsLastObservedLinkFullName = nil;
static NSDate *sApolloDeletedCommentsLastObservedLinkDate = nil;
static NSMutableDictionary<NSString *, NSString *> *sApolloDeletedCommentsRecoveredReasonsByFullName = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRecoveredBodyKeys = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRevealedFullNames = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRevealedBodyKeys = nil;
static NSObject *sApolloDeletedCommentsRegistryLock = nil;
static NSObject *sApolloDeletedCommentsArcticLock = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *sApolloDeletedCommentsArcticCache = nil;
static NSMutableDictionary<NSString *, NSMutableArray *> *sApolloDeletedCommentsArcticInflight = nil;
static NSDate *sApolloDeletedCommentsArcticCooldownUntil = nil;

static NSString *const ApolloDeletedCommentsMarkerKey = @"apollo_recovered_deleted_comment";
static NSString *const ApolloDeletedCommentsReasonKey = @"apollo_recovered_deleted_reason";
static NSString *const ApolloDeletedCommentsReasonUserDeleted = @"user_deleted";
static NSString *const ApolloDeletedCommentsReasonModeratorRemoved = @"moderator_removed";
static NSString *const ApolloDeletedCommentsArcticCacheCommentsKey = @"comments";
static NSString *const ApolloDeletedCommentsArcticCacheExpiryKey = @"expires";

static NSTimeInterval const ApolloDeletedCommentsArcticPatchTimeout = 1.5;
static NSTimeInterval const ApolloDeletedCommentsArcticSuccessCacheTTL = 600.0;
static NSTimeInterval const ApolloDeletedCommentsArcticEmptyCacheTTL = 60.0;
static NSTimeInterval const ApolloDeletedCommentsArcticErrorCooldown = 30.0;
static NSTimeInterval const ApolloDeletedCommentsArcticRateLimitCooldown = 60.0;
static NSInteger const ApolloDeletedCommentsArcticLowRemainingThreshold = 3;
static NSUInteger const ApolloDeletedCommentsArcticMaxExactBatches = 2;

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s);
static NSString *ApolloDeletedCommentsUnescapedHTMLText(NSString *s);

#pragma mark - RecoveredCommentRegistry

static NSObject *ApolloDeletedCommentsRegistryLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sApolloDeletedCommentsRegistryLock = [NSObject new];
    });
    return sApolloDeletedCommentsRegistryLock;
}

static NSString *ApolloDeletedCommentsRegistryBodyKey(NSString *author, NSString *body) {
    NSString *trimmedBody = ApolloDeletedCommentsTrimmedString(body);
    if (trimmedBody.length == 0) return nil;
    NSString *trimmedAuthor = ApolloDeletedCommentsTrimmedString(author) ?: @"";
    return [NSString stringWithFormat:@"%@\n%lu\n%@", trimmedAuthor, (unsigned long)trimmedBody.length, trimmedBody];
}

void ApolloDeletedCommentsRegisterRecoveredComment(NSString *fullName, NSString *reason) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRecoveredReasonsByFullName) {
            sApolloDeletedCommentsRecoveredReasonsByFullName = [NSMutableDictionary dictionary];
        }
        sApolloDeletedCommentsRecoveredReasonsByFullName[fullName] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    }
}

static void ApolloDeletedCommentsRegisterRecoveredBody(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRecoveredBodyKeys) {
            sApolloDeletedCommentsRecoveredBodyKeys = [NSMutableSet set];
        }
        [sApolloDeletedCommentsRecoveredBodyKeys addObject:key];
    }
}

BOOL ApolloDeletedCommentsIsRecoveredComment(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsRecoveredReasonsByFullName[fullName] != nil;
    }
}

BOOL ApolloDeletedCommentsIsRecoveredCommentBody(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRecoveredBodyKeys containsObject:key];
    }
}

BOOL ApolloDeletedCommentsIsCommentRevealed(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRevealedFullNames containsObject:fullName];
    }
}

BOOL ApolloDeletedCommentsIsCommentBodyRevealed(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRevealedBodyKeys containsObject:key];
    }
}

void ApolloDeletedCommentsMarkCommentRevealed(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRevealedFullNames) {
            sApolloDeletedCommentsRevealedFullNames = [NSMutableSet set];
        }
        [sApolloDeletedCommentsRevealedFullNames addObject:fullName];
    }
}

void ApolloDeletedCommentsMarkCommentBodyRevealed(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRevealedBodyKeys) {
            sApolloDeletedCommentsRevealedBodyKeys = [NSMutableSet set];
        }
        [sApolloDeletedCommentsRevealedBodyKeys addObject:key];
    }
}

#pragma mark - RequestClassifier

static BOOL ApolloDeletedCommentsIsRedditHost(NSString *host) {
    NSString *lowerHost = [host lowercaseString];
    return [lowerHost isEqualToString:@"oauth.reddit.com"] ||
           [lowerHost isEqualToString:@"www.reddit.com"] ||
           [lowerHost isEqualToString:@"old.reddit.com"] ||
           [lowerHost isEqualToString:@"reddit.com"] ||
           [lowerHost hasSuffix:@".reddit.com"];
}

static NSString *ApolloDeletedCommentsNormalizeLinkID(NSString *identifier) {
    NSString *trimmed = [identifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if ([trimmed rangeOfString:@","].location != NSNotFound) return nil;
    if ([trimmed hasPrefix:@"t3_"] && trimmed.length > 3) return trimmed;
    if ([trimmed hasPrefix:@"t1_"] ||
        [trimmed hasPrefix:@"t2_"] ||
        [trimmed hasPrefix:@"t4_"] ||
        [trimmed hasPrefix:@"t5_"] ||
        [trimmed hasPrefix:@"t6_"]) return nil;
    return [@"t3_" stringByAppendingString:trimmed];
}

static NSString *ApolloDeletedCommentsLinkFullNameFromRedditURL(NSURL *url) {
    if (!url || !ApolloDeletedCommentsIsRedditHost(url.host)) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        NSString *name = [item.name lowercaseString];
        if (![name isEqualToString:@"id"] &&
            ![name isEqualToString:@"link_id"] &&
            ![name isEqualToString:@"article"] &&
            ![name isEqualToString:@"link"]) {
            continue;
        }
        NSString *fullName = ApolloDeletedCommentsNormalizeLinkID(item.value);
        if (fullName.length > 0) return fullName;
    }

    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = [parts[i] lowercaseString];
        if (![part isEqualToString:@"comments"] && ![part isEqualToString:@"comments.json"]) continue;
        if (i + 1 >= parts.count) continue;
        NSString *candidate = parts[i + 1];
        if ([candidate hasSuffix:@".json"]) candidate = [candidate stringByDeletingPathExtension];
        NSString *fullName = ApolloDeletedCommentsNormalizeLinkID(candidate);
        if (fullName.length > 0) return fullName;
    }
    return nil;
}

static NSString *ApolloDeletedCommentsRecentObservedLinkFullName(void) {
    if (sApolloDeletedCommentsLastObservedLinkFullName.length == 0 || !sApolloDeletedCommentsLastObservedLinkDate) return nil;
    if ([[NSDate date] timeIntervalSinceDate:sApolloDeletedCommentsLastObservedLinkDate] > 45.0) return nil;
    return sApolloDeletedCommentsLastObservedLinkFullName;
}

static NSString *ApolloDeletedCommentsLinkFullNameForRequest(NSURLRequest *request) {
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length > 0) return fullName;
    if (!ApolloDeletedCommentsIsRedditHost(request.URL.host)) return nil;
    return ApolloDeletedCommentsRecentObservedLinkFullName();
}

static BOOL ApolloDeletedCommentsRequestLooksLikeCommentsPayload(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url) return NO;

    NSString *path = [[url path] lowercaseString] ?: @"";
    if ([path rangeOfString:@"/comments/"].location != NSNotFound ||
        [path hasSuffix:@"/comments.json"] ||
        [path rangeOfString:@"/api/morechildren"].location != NSNotFound) {
        return YES;
    }

    return NO;
}

static BOOL ApolloDeletedCommentsIsMoreChildrenRequest(NSURLRequest *request) {
    NSString *path = [[request.URL path] lowercaseString] ?: @"";
    return [path rangeOfString:@"/api/morechildren"].location != NSNotFound;
}

static BOOL ApolloDeletedCommentsShouldTransformRequest(NSURLRequest *request) {
    if (!sShowDeletedComments || !request.URL || !ApolloDeletedCommentsIsRedditHost(request.URL.host)) return NO;
    if (!ApolloDeletedCommentsRequestLooksLikeCommentsPayload(request)) return NO;
    return ApolloDeletedCommentsLinkFullNameForRequest(request).length > 0;
}

static BOOL ApolloDeletedCommentsShouldTransformTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    return ApolloDeletedCommentsShouldTransformRequest(task.originalRequest) ||
           ApolloDeletedCommentsShouldTransformRequest(task.currentRequest);
}

void ApolloDeletedCommentsHandleRequestObservation(NSURLRequest *request, NSString *source) {
    if (!sShowDeletedComments) return;
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length == 0) return;

    BOOL changed = ![sApolloDeletedCommentsLastObservedLinkFullName isEqualToString:fullName];
    sApolloDeletedCommentsLastObservedLinkFullName = [fullName copy];
    sApolloDeletedCommentsLastObservedLinkDate = [NSDate date];
    if (changed) {
        ApolloLog(@"[DeletedComments] Observed Reddit comments request %@ (%@)", fullName, source ?: @"unknown");
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloDeletedCommentsObservedThreadNotification
                                                            object:nil
                                                          userInfo:@{@"fullName": fullName}];
    });
}

#pragma mark - RecoveredCommentPolicy

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloDeletedCommentsBodyLooksDeleted(NSString *body) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return YES;
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"[removed]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"removed"]) return YES;
    if ([trimmed isEqualToString:@"removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"removed by mod"]) return YES;
    if ([trimmed isEqualToString:@"removed by reddit"]) return YES;
    if ([trimmed isEqualToString:@"comment removed by moderator"]) return YES;
    if ([trimmed isEqualToString:@"comment removed by reddit"]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment :("]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment"]) return YES;
    if ([trimmed rangeOfString:@"removed by moderator"].location != NSNotFound && trimmed.length < 80) return YES;
    if ([trimmed rangeOfString:@"user deleted comment"].location != NSNotFound && trimmed.length < 80) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsCommentDataLooksDeleted(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return NO;
    NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
    if (ApolloDeletedCommentsBodyLooksDeleted(body)) return YES;

    NSString *bodyHTML = [data[@"body_html"] isKindOfClass:[NSString class]] ? data[@"body_html"] : nil;
    if (bodyHTML.length == 0) return NO;
    NSString *htmlText = ApolloDeletedCommentsUnescapedHTMLText(bodyHTML);
    return [htmlText rangeOfString:@"[removed]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [htmlText rangeOfString:@"[deleted]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [htmlText rangeOfString:@"Removed by moderator" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [htmlText rangeOfString:@"User deleted comment" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *ApolloDeletedCommentsCommentFullName(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [data[@"name"] isKindOfClass:[NSString class]] ? data[@"name"] : nil;
    if ([name hasPrefix:@"t1_"]) return name;
    NSString *identifier = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : nil;
    if (identifier.length == 0) return nil;
    return [identifier hasPrefix:@"t1_"] ? identifier : [@"t1_" stringByAppendingString:identifier];
}

static NSArray<NSString *> *ApolloDeletedCommentsSplitIDs(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @[];

    NSMutableArray<NSString *> *fullNames = [NSMutableArray array];
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@","];
    for (NSString *part in parts) {
        NSString *identifier = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (identifier.length == 0) continue;
        NSString *fullName = [identifier hasPrefix:@"t1_"] ? identifier : [@"t1_" stringByAppendingString:identifier];
        [fullNames addObject:fullName];
    }
    return fullNames;
}

static void ApolloDeletedCommentsAddFormValue(NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *params, NSString *name, NSString *value) {
    if (name.length == 0 || value.length == 0) return;
    NSString *decodedName = [name stringByRemovingPercentEncoding] ?: name;
    NSString *decodedValue = [value stringByRemovingPercentEncoding] ?: value;
    if (!params[decodedName]) params[decodedName] = [NSMutableArray array];
    [params[decodedName] addObject:decodedValue];
}

static NSDictionary<NSString *, NSArray<NSString *> *> *ApolloDeletedCommentsRequestParameters(NSURLRequest *request) {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *params = [NSMutableDictionary dictionary];

    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        ApolloDeletedCommentsAddFormValue(params, item.name, item.value);
    }

    NSData *body = request.HTTPBody;
    if (body.length > 0) {
        NSString *bodyString = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        for (NSString *pair in [bodyString componentsSeparatedByString:@"&"]) {
            if (pair.length == 0) continue;
            NSRange separator = [pair rangeOfString:@"="];
            NSString *name = separator.location == NSNotFound ? pair : [pair substringToIndex:separator.location];
            NSString *value = separator.location == NSNotFound ? @"" : [pair substringFromIndex:separator.location + 1];
            ApolloDeletedCommentsAddFormValue(params, name, value);
        }
    }

    NSMutableDictionary<NSString *, NSArray<NSString *> *> *immutableParams = [NSMutableDictionary dictionary];
    for (NSString *key in params) immutableParams[key] = [params[key] copy];
    return immutableParams;
}

static NSArray<NSString *> *ApolloDeletedCommentsRequestedMoreChildren(NSURLRequest *request) {
    if (!ApolloDeletedCommentsIsMoreChildrenRequest(request)) return @[];

    NSDictionary<NSString *, NSArray<NSString *> *> *params = ApolloDeletedCommentsRequestParameters(request);
    NSMutableArray<NSString *> *fullNames = [NSMutableArray array];
    for (NSString *value in params[@"children"] ?: @[]) {
        [fullNames addObjectsFromArray:ApolloDeletedCommentsSplitIDs(value)];
    }
    return fullNames;
}

static NSString *ApolloDeletedCommentsEscapeHTML(NSString *s) {
    NSMutableString *escaped = [s ?: @"" mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString *ApolloDeletedCommentsUnescapedHTMLText(NSString *s) {
    NSMutableString *text = [s ?: @"" mutableCopy];
    [text replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&quot;" withString:@"\"" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&#39;" withString:@"'" options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, text.length)];
    return text;
}

static BOOL ApolloDeletedCommentsBodyLooksUserDeleted(NSString *body) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(body) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed isEqualToString:@"[deleted]"]) return YES;
    if ([trimmed isEqualToString:@"deleted"]) return YES;
    if ([trimmed isEqualToString:@"user deleted comment :("]) return YES;
    if ([trimmed rangeOfString:@"user deleted comment"].location != NSNotFound) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsArchivedWasDeleted(NSDictionary *archived) {
    if (![archived isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *metadata = [archived[@"_meta"] isKindOfClass:[NSDictionary class]] ? archived[@"_meta"] : nil;
    if ([metadata[@"was_deleted_later"] respondsToSelector:@selector(boolValue)] && [metadata[@"was_deleted_later"] boolValue]) return YES;
    NSString *removalType = [metadata[@"removal_type"] isKindOfClass:[NSString class]] ? metadata[@"removal_type"] : nil;
    if (removalType.length > 0) return YES;
    NSString *removedByCategory = [archived[@"removed_by_category"] isKindOfClass:[NSString class]] ? archived[@"removed_by_category"] : nil;
    if (removedByCategory.length > 0) return YES;
    if (archived[@"banned_by"] && archived[@"banned_by"] != (id)[NSNull null]) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsArchivedIsRecoverableDeleted(NSDictionary *archived) {
    if (!ApolloDeletedCommentsArchivedWasDeleted(archived)) return NO;
    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    return body.length > 0 && !ApolloDeletedCommentsBodyLooksDeleted(body);
}

static NSString *ApolloDeletedCommentsReasonForCurrentBody(NSString *body, NSString *bodyHTML) {
    if (ApolloDeletedCommentsBodyLooksUserDeleted(body)) return ApolloDeletedCommentsReasonUserDeleted;
    if (ApolloDeletedCommentsBodyLooksUserDeleted(ApolloDeletedCommentsUnescapedHTMLText(bodyHTML))) return ApolloDeletedCommentsReasonUserDeleted;
    return ApolloDeletedCommentsReasonModeratorRemoved;
}

static NSString *ApolloDeletedCommentsReasonForArchived(NSDictionary *archived) {
    NSDictionary *metadata = [archived[@"_meta"] isKindOfClass:[NSDictionary class]] ? archived[@"_meta"] : nil;
    NSString *removalType = [metadata[@"removal_type"] isKindOfClass:[NSString class]] ? [metadata[@"removal_type"] lowercaseString] : nil;
    if ([removalType rangeOfString:@"delete"].location != NSNotFound) return ApolloDeletedCommentsReasonUserDeleted;
    return ApolloDeletedCommentsReasonModeratorRemoved;
}

static NSString *ApolloDeletedCommentsBadgeLabelForReason(NSString *reason) {
    if ([reason isEqualToString:ApolloDeletedCommentsReasonUserDeleted]) return @"deleted by user";
    return @"removed by mod";
}

static NSString *ApolloDeletedCommentsRedditBodyHTML(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;

    NSMutableArray<NSString *> *htmlParagraphs = [NSMutableArray array];
    for (NSString *paragraph in [trimmed componentsSeparatedByString:@"\n\n"]) {
        NSString *p = ApolloDeletedCommentsTrimmedString(paragraph);
        if (p.length == 0) continue;
        NSString *escaped = ApolloDeletedCommentsEscapeHTML(p);
        escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"];
        [htmlParagraphs addObject:[NSString stringWithFormat:@"<p>%@</p>", escaped]];
    }
    if (htmlParagraphs.count == 0) return nil;

    NSString *html = [NSString stringWithFormat:@"<div class=\"md\">%@\n</div>", [htmlParagraphs componentsJoinedByString:@"\n"]];
    return ApolloDeletedCommentsEscapeHTML(html);
}

static NSString *ApolloDeletedCommentsSpoilerMarkdownBody(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;
    return [NSString stringWithFormat:@">!%@!<", trimmed];
}

static NSString *ApolloDeletedCommentsRedditSpoilerBodyHTML(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;

    NSString *escaped = ApolloDeletedCommentsEscapeHTML(trimmed);
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"];
    return [NSString stringWithFormat:@"<!-- SC_OFF --><div class=\"md\"><p><span class=\"md-spoiler-text\">%@</span></p>\n</div><!-- SC_ON -->", escaped];
}

static void ApolloDeletedCommentsSetRecoveredBody(NSMutableDictionary *data, NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return;

    NSString *displayBody = sTapToRevealDeletedComments ? ApolloDeletedCommentsSpoilerMarkdownBody(trimmed) : trimmed;
    data[@"body"] = displayBody.length > 0 ? displayBody : trimmed;

    NSString *bodyHTML = sTapToRevealDeletedComments ? ApolloDeletedCommentsRedditSpoilerBodyHTML(trimmed) : ApolloDeletedCommentsRedditBodyHTML(trimmed);
    if (bodyHTML.length > 0) data[@"body_html"] = bodyHTML;
}

static void ApolloDeletedCommentsApplyNeutralVoteMetadata(NSMutableDictionary *data) {
    data[@"likes"] = [NSNull null];
    data[@"vote"] = [NSNull null];
    data[@"user_vote"] = @0;
    data[@"voted"] = @NO;
}

static void ApolloDeletedCommentsApplyRecoveredMetadata(NSMutableDictionary *data, NSString *reason) {
    NSString *label = ApolloDeletedCommentsBadgeLabelForReason(reason);
    NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
    NSString *author = [data[@"author"] isKindOfClass:[NSString class]] ? data[@"author"] : nil;
    NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
    data[ApolloDeletedCommentsMarkerKey] = @YES;
    data[ApolloDeletedCommentsReasonKey] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    data[@"author_flair_text"] = label.length > 0 ? label : @"removed by mod";
    data[@"author_flair_css_class"] = @"recovered-deleted";
    data[@"author_flair_type"] = @"text";
    data[@"author_flair_richtext"] = @[];
    ApolloDeletedCommentsApplyNeutralVoteMetadata(data);
    ApolloDeletedCommentsRegisterRecoveredComment(fullName, reason);
    ApolloDeletedCommentsRegisterRecoveredBody(author, body);
}

static void ApolloDeletedCommentsClearRemovalMetadata(NSMutableDictionary *data) {
    [data removeObjectForKey:@"removed_by_category"];
    [data removeObjectForKey:@"banned_by"];
    [data removeObjectForKey:@"approved_by"];
    [data removeObjectForKey:@"mod_note"];
    [data removeObjectForKey:@"mod_reason_by"];
    [data removeObjectForKey:@"mod_reason_title"];
    [data removeObjectForKey:@"removal_reason"];
    [data removeObjectForKey:@"ban_note"];
    [data removeObjectForKey:@"ban_info"];

    data[@"collapsed"] = @NO;
    data[@"collapsed_because_crowd_control"] = @NO;
    data[@"collapsed_reason"] = [NSNull null];
    data[@"collapsed_reason_code"] = [NSNull null];
}

static void ApolloDeletedCommentsFlattenArcticChildren(NSArray *children, NSMutableDictionary<NSString *, NSDictionary *> *commentsByFullName) {
    if (![children isKindOfClass:[NSArray class]]) return;
    for (id child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = (NSDictionary *)child;
        NSString *kind = [entry[@"kind"] isKindOfClass:[NSString class]] ? entry[@"kind"] : nil;
        NSDictionary *data = [entry[@"data"] isKindOfClass:[NSDictionary class]] ? entry[@"data"] : nil;
        if (![kind isEqualToString:@"t1"] || !data) continue;

        NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
        if (fullName.length > 0) commentsByFullName[fullName] = data;

        NSDictionary *replies = [data[@"replies"] isKindOfClass:[NSDictionary class]] ? data[@"replies"] : nil;
        NSDictionary *replyData = [replies[@"data"] isKindOfClass:[NSDictionary class]] ? replies[@"data"] : nil;
        NSArray *replyChildren = [replyData[@"children"] isKindOfClass:[NSArray class]] ? replyData[@"children"] : nil;
        ApolloDeletedCommentsFlattenArcticChildren(replyChildren, commentsByFullName);
    }
}

static NSDictionary<NSString *, NSDictionary *> *ApolloDeletedCommentsArcticCommentMapFromRoot(id root) {
    NSArray *children = nil;
    if ([root isKindOfClass:[NSDictionary class]]) {
        id data = ((NSDictionary *)root)[@"data"];
        if ([data isKindOfClass:[NSArray class]]) {
            children = data;
        } else if ([data isKindOfClass:[NSDictionary class]]) {
            id listingChildren = ((NSDictionary *)data)[@"children"];
            if ([listingChildren isKindOfClass:[NSArray class]]) children = listingChildren;
        }
    }
    if (![children isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *comments = [NSMutableDictionary dictionary];
    ApolloDeletedCommentsFlattenArcticChildren(children, comments);
    return comments.count > 0 ? comments : nil;
}

static NSDictionary<NSString *, NSDictionary *> *ApolloDeletedCommentsArcticCommentMapFromFlatData(id root) {
    NSArray *commentsArray = nil;
    if ([root isKindOfClass:[NSDictionary class]]) {
        id data = ((NSDictionary *)root)[@"data"];
        if ([data isKindOfClass:[NSArray class]]) commentsArray = data;
    } else if ([root isKindOfClass:[NSArray class]]) {
        commentsArray = root;
    }
    if (![commentsArray isKindOfClass:[NSArray class]]) return nil;

    NSMutableDictionary *comments = [NSMutableDictionary dictionary];
    for (id entry in commentsArray) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *fullName = ApolloDeletedCommentsCommentFullName(entry);
        if (fullName.length > 0) comments[fullName] = entry;
    }
    return comments.count > 0 ? comments : nil;
}

static NSObject *ApolloDeletedCommentsArcticLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sApolloDeletedCommentsArcticLock = [NSObject new];
    });
    return sApolloDeletedCommentsArcticLock;
}

static BOOL ApolloDeletedCommentsArcticIsCoolingDown(void) {
    @synchronized(ApolloDeletedCommentsArcticLock()) {
        if (!sApolloDeletedCommentsArcticCooldownUntil) return NO;
        if ([sApolloDeletedCommentsArcticCooldownUntil timeIntervalSinceNow] <= 0.0) {
            sApolloDeletedCommentsArcticCooldownUntil = nil;
            return NO;
        }
        return YES;
    }
}

static void ApolloDeletedCommentsArcticBeginCooldown(NSTimeInterval seconds, NSString *reason) {
    if (seconds <= 0.0) return;
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    @synchronized(ApolloDeletedCommentsArcticLock()) {
        if (!sApolloDeletedCommentsArcticCooldownUntil ||
            [sApolloDeletedCommentsArcticCooldownUntil timeIntervalSinceDate:until] < 0.0) {
            sApolloDeletedCommentsArcticCooldownUntil = until;
        }
    }
    ApolloLog(@"[DeletedComments] Arctic cooldown for %.0fs (%@)", seconds, reason ?: @"unknown");
}

static NSInteger ApolloDeletedCommentsIntegerHeader(NSHTTPURLResponse *http, NSString *name, NSInteger fallback) {
    id value = http.allHeaderFields[name];
    if (!value) {
        NSString *lowerName = [name lowercaseString];
        for (id key in http.allHeaderFields) {
            if ([[[key description] lowercaseString] isEqualToString:lowerName]) {
                value = http.allHeaderFields[key];
                break;
            }
        }
    }
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return fallback;
}

static BOOL ApolloDeletedCommentsArcticResponseShouldCooldown(NSInteger statusCode, NSInteger remaining) {
    if (statusCode == 429) return YES;
    return remaining != NSIntegerMax && remaining <= ApolloDeletedCommentsArcticLowRemainingThreshold;
}

static void ApolloDeletedCommentsRecordArcticResponse(NSHTTPURLResponse *http, NSError *error) {
    if (error) {
        ApolloDeletedCommentsArcticBeginCooldown(ApolloDeletedCommentsArcticErrorCooldown, error.localizedDescription ?: @"network error");
        return;
    }

    NSInteger statusCode = http ? http.statusCode : 0;
    if (statusCode == 429) {
        NSInteger reset = ApolloDeletedCommentsIntegerHeader(http, @"X-RateLimit-Reset", ApolloDeletedCommentsArcticRateLimitCooldown);
        ApolloDeletedCommentsArcticBeginCooldown(MAX((NSTimeInterval)reset, ApolloDeletedCommentsArcticRateLimitCooldown), @"rate limited");
        return;
    }

    NSInteger remaining = ApolloDeletedCommentsIntegerHeader(http, @"X-RateLimit-Remaining", NSIntegerMax);
    if (ApolloDeletedCommentsArcticResponseShouldCooldown(statusCode, remaining)) {
        NSInteger reset = ApolloDeletedCommentsIntegerHeader(http, @"X-RateLimit-Reset", ApolloDeletedCommentsArcticRateLimitCooldown);
        ApolloDeletedCommentsArcticBeginCooldown(MAX((NSTimeInterval)reset, ApolloDeletedCommentsArcticRateLimitCooldown), @"low remaining quota");
    }
}

static NSDictionary<NSString *, NSDictionary *> *ApolloDeletedCommentsCachedArcticComments(NSString *linkFullName) {
    if (linkFullName.length == 0) return nil;
    @synchronized(ApolloDeletedCommentsArcticLock()) {
        NSDictionary *entry = sApolloDeletedCommentsArcticCache[linkFullName];
        NSDate *expires = [entry[ApolloDeletedCommentsArcticCacheExpiryKey] isKindOfClass:[NSDate class]] ? entry[ApolloDeletedCommentsArcticCacheExpiryKey] : nil;
        if (!entry || !expires || [expires timeIntervalSinceNow] <= 0.0) {
            if (entry) [sApolloDeletedCommentsArcticCache removeObjectForKey:linkFullName];
            return nil;
        }
        id comments = entry[ApolloDeletedCommentsArcticCacheCommentsKey];
        return [comments isKindOfClass:[NSDictionary class]] ? comments : @{};
    }
}

static void ApolloDeletedCommentsStoreArcticComments(NSString *linkFullName, NSDictionary<NSString *, NSDictionary *> *comments, NSTimeInterval ttl) {
    if (linkFullName.length == 0 || ttl <= 0.0) return;
    @synchronized(ApolloDeletedCommentsArcticLock()) {
        if (!sApolloDeletedCommentsArcticCache) sApolloDeletedCommentsArcticCache = [NSMutableDictionary dictionary];
        sApolloDeletedCommentsArcticCache[linkFullName] = @{
            ApolloDeletedCommentsArcticCacheCommentsKey: comments ?: @{},
            ApolloDeletedCommentsArcticCacheExpiryKey: [NSDate dateWithTimeIntervalSinceNow:ttl],
        };
    }
}

static void ApolloDeletedCommentsFinishInflightArcticFetch(NSString *linkFullName, NSDictionary<NSString *, NSDictionary *> *comments) {
    NSArray *completions = nil;
    @synchronized(ApolloDeletedCommentsArcticLock()) {
        completions = [sApolloDeletedCommentsArcticInflight[linkFullName] copy];
        [sApolloDeletedCommentsArcticInflight removeObjectForKey:linkFullName];
    }
    for (id block in completions) {
        void (^completion)(NSDictionary<NSString *, NSDictionary *> *) = block;
        completion(comments ?: @{});
    }
}

static void ApolloDeletedCommentsFetchArcticComments(NSString *linkFullName, void (^completion)(NSDictionary<NSString *, NSDictionary *> *comments)) {
    if (linkFullName.length == 0) {
        completion(nil);
        return;
    }

    NSDictionary *cached = ApolloDeletedCommentsCachedArcticComments(linkFullName);
    if (cached) {
        completion(cached);
        return;
    }

    if (ApolloDeletedCommentsArcticIsCoolingDown()) {
        completion(@{});
        return;
    }

    @synchronized(ApolloDeletedCommentsArcticLock()) {
        if (!sApolloDeletedCommentsArcticInflight) sApolloDeletedCommentsArcticInflight = [NSMutableDictionary dictionary];
        NSMutableArray *waiting = sApolloDeletedCommentsArcticInflight[linkFullName];
        if (waiting) {
            [waiting addObject:[completion copy]];
            return;
        }
        sApolloDeletedCommentsArcticInflight[linkFullName] = [NSMutableArray arrayWithObject:[completion copy]];
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/api/comments/tree"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"link_id" value:linkFullName],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"5000"],
        [NSURLQueryItem queryItemWithName:@"start_depth" value:@"20"],
        [NSURLQueryItem queryItemWithName:@"start_breadth" value:@"50"],
        [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
    ];
    NSURL *url = components.URL;
    if (!url) {
        ApolloDeletedCommentsFinishInflightArcticFetch(linkFullName, @{});
        return;
    }

    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
    urlRequest.timeoutInterval = 10.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *comments = nil;
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        ApolloDeletedCommentsRecordArcticResponse(http, error);
        if (!error && data.length > 0) {
            if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                comments = ApolloDeletedCommentsArcticCommentMapFromRoot(root);
            }
        }
        ApolloDeletedCommentsStoreArcticComments(linkFullName, comments ?: @{}, comments.count > 0 ? ApolloDeletedCommentsArcticSuccessCacheTTL : ApolloDeletedCommentsArcticEmptyCacheTTL);
        ApolloDeletedCommentsFinishInflightArcticFetch(linkFullName, comments ?: @{});
    }];
    [task resume];
}

static NSArray<NSArray<NSString *> *> *ApolloDeletedCommentsBatches(NSArray<NSString *> *values, NSUInteger batchSize) {
    if (values.count == 0 || batchSize == 0) return @[];
    NSMutableArray *batches = [NSMutableArray array];
    for (NSUInteger i = 0; i < values.count; i += batchSize) {
        NSUInteger count = MIN(batchSize, values.count - i);
        [batches addObject:[values subarrayWithRange:NSMakeRange(i, count)]];
    }
    return batches;
}

static void ApolloDeletedCommentsFetchArcticCommentsByFullNames(NSArray<NSString *> *fullNames,
                                                                void (^completion)(NSDictionary<NSString *, NSDictionary *> *comments)) {
    if (fullNames.count == 0) {
        completion(@{});
        return;
    }
    if (ApolloDeletedCommentsArcticIsCoolingDown()) {
        completion(@{});
        return;
    }

    NSMutableOrderedSet<NSString *> *baseIDs = [NSMutableOrderedSet orderedSet];
    for (NSString *fullName in fullNames) {
        if (![fullName isKindOfClass:[NSString class]] || ![fullName hasPrefix:@"t1_"] || fullName.length <= 3) continue;
        [baseIDs addObject:[fullName substringFromIndex:3]];
    }
    if (baseIDs.count == 0) {
        completion(@{});
        return;
    }

    NSArray<NSArray<NSString *> *> *allBatches = ApolloDeletedCommentsBatches(baseIDs.array, 250);
    NSArray<NSArray<NSString *> *> *batches = allBatches.count > ApolloDeletedCommentsArcticMaxExactBatches ? [allBatches subarrayWithRange:NSMakeRange(0, ApolloDeletedCommentsArcticMaxExactBatches)] : allBatches;
    NSMutableDictionary<NSString *, NSDictionary *> *merged = [NSMutableDictionary dictionary];
    __block NSUInteger nextIndex = 0;
    __block void (^fetchNext)(void) = nil;
    fetchNext = ^{
        if (nextIndex >= batches.count) {
            completion([merged copy]);
            fetchNext = nil;
            return;
        }

        NSArray<NSString *> *batch = batches[nextIndex++];
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://arctic-shift.photon-reddit.com/api/comments/ids"];
        components.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"ids" value:[batch componentsJoinedByString:@","]],
            [NSURLQueryItem queryItemWithName:@"md2html" value:@"false"],
        ];
        NSURL *url = components.URL;
        if (!url) {
            fetchNext();
            return;
        }

        NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
        urlRequest.timeoutInterval = 10.0;

        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:urlRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            ApolloDeletedCommentsRecordArcticResponse(http, error);
            if (!error && data.length > 0) {
                if (!http || (http.statusCode >= 200 && http.statusCode < 300)) {
                    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSDictionary *comments = ApolloDeletedCommentsArcticCommentMapFromFlatData(root);
                    if (comments.count > 0) [merged addEntriesFromDictionary:comments];
                }
            }
            fetchNext();
        }];
        [task resume];
    };
    fetchNext();
}

static void ApolloDeletedCommentsCollectVisibleCommentNames(id node, NSMutableSet<NSString *> *names) {
    if (!node || !names) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSDictionary *data = [dict[@"data"] isKindOfClass:[NSDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data) {
            NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
            if (fullName.length > 0) [names addObject:fullName];
        }
        for (id value in [dict allValues]) ApolloDeletedCommentsCollectVisibleCommentNames(value, names);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) ApolloDeletedCommentsCollectVisibleCommentNames(value, names);
    }
}

static void ApolloDeletedCommentsAddLookupTarget(NSMutableOrderedSet<NSString *> *targets, NSString *fullName) {
    if (![targets isKindOfClass:[NSMutableOrderedSet class]]) return;
    if (![fullName isKindOfClass:[NSString class]] || ![fullName hasPrefix:@"t1_"] || fullName.length <= 3) return;
    [targets addObject:fullName];
}

static void ApolloDeletedCommentsCollectExactLookupTargets(id node,
                                                           NSDictionary<NSString *, NSDictionary *> *arcticComments,
                                                           NSMutableOrderedSet<NSString *> *targets) {
    if (!node || !targets) return;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSDictionary *data = [dict[@"data"] isKindOfClass:[NSDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data) {
            NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
            NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
            NSString *archivedBody = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
            if (ApolloDeletedCommentsCommentDataLooksDeleted(data) &&
                (archivedBody.length == 0 || ApolloDeletedCommentsBodyLooksDeleted(archivedBody))) {
                ApolloDeletedCommentsAddLookupTarget(targets, fullName);
            }
        } else if ([kind isEqualToString:@"more"] && data) {
            NSArray *children = [data[@"children"] isKindOfClass:[NSArray class]] ? data[@"children"] : nil;
            for (id childID in children ?: @[]) {
                NSString *identifier = nil;
                if ([childID isKindOfClass:[NSString class]]) identifier = childID;
                else if ([childID respondsToSelector:@selector(stringValue)]) identifier = [childID stringValue];
                NSString *fullName = [identifier hasPrefix:@"t1_"] ? identifier : (identifier.length > 0 ? [@"t1_" stringByAppendingString:identifier] : nil);
                NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
                if (!archived || ApolloDeletedCommentsArchivedWasDeleted(archived)) {
                    ApolloDeletedCommentsAddLookupTarget(targets, fullName);
                }
            }
        }

        for (id value in [dict allValues]) ApolloDeletedCommentsCollectExactLookupTargets(value, arcticComments, targets);
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) ApolloDeletedCommentsCollectExactLookupTargets(value, arcticComments, targets);
    }
}

static NSMutableDictionary *ApolloDeletedCommentsThingFromArchived(NSDictionary *archived, NSString *reason) {
    if (![archived isKindOfClass:[NSDictionary class]]) return nil;
    NSString *fullName = ApolloDeletedCommentsCommentFullName(archived);
    NSString *identifier = [archived[@"id"] isKindOfClass:[NSString class]] ? archived[@"id"] : nil;
    if (identifier.length == 0 && [fullName hasPrefix:@"t1_"]) identifier = [fullName substringFromIndex:3];

    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    if (identifier.length == 0 || body.length == 0 || ApolloDeletedCommentsBodyLooksDeleted(body)) return nil;

    NSString *author = [archived[@"author"] isKindOfClass:[NSString class]] ? archived[@"author"] : @"[deleted]";
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    data[@"id"] = identifier;
    data[@"name"] = fullName ?: [@"t1_" stringByAppendingString:identifier];
    data[@"author"] = author.length > 0 ? author : @"[deleted]";
    ApolloDeletedCommentsSetRecoveredBody(data, body);
    data[@"parent_id"] = [archived[@"parent_id"] isKindOfClass:[NSString class]] ? archived[@"parent_id"] : @"";
    data[@"link_id"] = [archived[@"link_id"] isKindOfClass:[NSString class]] ? archived[@"link_id"] : @"";
    data[@"subreddit"] = [archived[@"subreddit"] isKindOfClass:[NSString class]] ? archived[@"subreddit"] : @"";
    data[@"subreddit_id"] = [archived[@"subreddit_id"] isKindOfClass:[NSString class]] ? archived[@"subreddit_id"] : @"";
    data[@"permalink"] = [archived[@"permalink"] isKindOfClass:[NSString class]] ? archived[@"permalink"] : @"";
    data[@"score"] = [archived[@"score"] respondsToSelector:@selector(integerValue)] ? archived[@"score"] : @0;
    data[@"ups"] = data[@"score"];
    data[@"downs"] = @0;
    data[@"created_utc"] = [archived[@"created_utc"] respondsToSelector:@selector(doubleValue)] ? archived[@"created_utc"] : @0;
    data[@"created"] = data[@"created_utc"];
    data[@"replies"] = @"";
    data[@"saved"] = @NO;
    data[@"stickied"] = @NO;
    data[@"is_submitter"] = @NO;
    data[@"score_hidden"] = @NO;
    data[@"controversiality"] = @0;
    data[@"archived"] = @NO;
    data[@"locked"] = @NO;
    data[@"distinguished"] = [NSNull null];
    data[@"edited"] = @NO;
    data[@"gilded"] = @0;
    ApolloDeletedCommentsApplyRecoveredMetadata(data, reason);
    ApolloDeletedCommentsClearRemovalMetadata(data);
    return [@{@"kind": @"t1", @"data": data} mutableCopy];
}

typedef struct {
    NSUInteger t1Count;
    NSUInteger deletedLookingCount;
    NSUInteger archivedMatchCount;
    NSUInteger recoverableCount;
    NSUInteger unrecoverableCount;
    NSUInteger insertedFromMoreCount;
    NSUInteger requestedMoreCount;
    NSUInteger returnedRequestedMoreCount;
    NSUInteger insertedMissingMoreCount;
    NSUInteger skippedMissingWithoutDeletionEvidenceCount;
    NSUInteger exactLookupCount;
    NSUInteger exactMatchCount;
    NSUInteger overlayInsertedCount;
    NSUInteger overlayRecoverableCount;
} ApolloDeletedCommentsPatchStats;

static NSDictionary<NSString *, NSArray<NSDictionary *> *> *ApolloDeletedCommentsRecoverableChildrenByParent(NSDictionary<NSString *, NSDictionary *> *arcticComments,
                                                                                                            ApolloDeletedCommentsPatchStats *stats) {
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *childrenByParent = [NSMutableDictionary dictionary];
    for (NSString *fullName in arcticComments) {
        NSDictionary *archived = arcticComments[fullName];
        if (!ApolloDeletedCommentsArchivedIsRecoverableDeleted(archived)) continue;
        NSString *parentID = [archived[@"parent_id"] isKindOfClass:[NSString class]] ? archived[@"parent_id"] : nil;
        if (parentID.length == 0) continue;
        if (!childrenByParent[parentID]) childrenByParent[parentID] = [NSMutableArray array];
        [childrenByParent[parentID] addObject:archived];
        if (stats) stats->overlayRecoverableCount++;
    }

    NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *sortedChildren = [NSMutableDictionary dictionary];
    for (NSString *parentID in childrenByParent) {
        NSArray<NSDictionary *> *children = [childrenByParent[parentID] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSTimeInterval aTime = [a[@"created_utc"] respondsToSelector:@selector(doubleValue)] ? [a[@"created_utc"] doubleValue] : 0;
            NSTimeInterval bTime = [b[@"created_utc"] respondsToSelector:@selector(doubleValue)] ? [b[@"created_utc"] doubleValue] : 0;
            if (aTime < bTime) return NSOrderedAscending;
            if (aTime > bTime) return NSOrderedDescending;
            NSString *aName = ApolloDeletedCommentsCommentFullName(a) ?: @"";
            NSString *bName = ApolloDeletedCommentsCommentFullName(b) ?: @"";
            return [aName compare:bName];
        }];
        sortedChildren[parentID] = children;
    }
    return sortedChildren;
}

static NSUInteger ApolloDeletedCommentsOverlayArchivedChildrenForParent(NSMutableArray *children,
                                                                        NSString *parentFullName,
                                                                        NSDictionary<NSString *, NSArray<NSDictionary *> *> *childrenByParent,
                                                                        NSMutableSet<NSString *> *visibleNames,
                                                                        ApolloDeletedCommentsPatchStats *stats) {
    if (![children isKindOfClass:[NSMutableArray class]] || parentFullName.length == 0) return 0;
    NSArray<NSDictionary *> *archivedChildren = childrenByParent[parentFullName];
    if (archivedChildren.count == 0) return 0;

    NSMutableArray *inserted = [NSMutableArray array];
    for (NSDictionary *archived in archivedChildren) {
        NSString *fullName = ApolloDeletedCommentsCommentFullName(archived);
        if (fullName.length == 0 || [visibleNames containsObject:fullName]) continue;
        NSMutableDictionary *thing = ApolloDeletedCommentsThingFromArchived(archived, ApolloDeletedCommentsReasonForArchived(archived));
        if (!thing) continue;
        [inserted addObject:thing];
        [visibleNames addObject:fullName];
    }

    if (inserted.count == 0) return 0;
    [children addObjectsFromArray:inserted];
    if (stats) stats->overlayInsertedCount += inserted.count;
    return inserted.count;
}

static NSMutableArray *ApolloDeletedCommentsMutableRepliesChildrenForCommentData(NSMutableDictionary *data) {
    if (![data isKindOfClass:[NSMutableDictionary class]]) return nil;
    id replies = data[@"replies"];
    if ([replies isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *replyData = [((NSMutableDictionary *)replies)[@"data"] isKindOfClass:[NSMutableDictionary class]] ? ((NSMutableDictionary *)replies)[@"data"] : nil;
        NSMutableArray *children = [replyData[@"children"] isKindOfClass:[NSMutableArray class]] ? replyData[@"children"] : nil;
        if (children) return children;
    }

    NSMutableArray *children = [NSMutableArray array];
    data[@"replies"] = [@{
        @"kind": @"Listing",
        @"data": [@{
            @"after": [NSNull null],
            @"before": [NSNull null],
            @"children": children,
            @"dist": @0,
            @"modhash": @"",
        } mutableCopy],
    } mutableCopy];
    return children;
}

static NSUInteger ApolloDeletedCommentsOverlayArchivedDeletedComments(id node,
                                                                      NSString *linkFullName,
                                                                      NSDictionary<NSString *, NSArray<NSDictionary *> *> *childrenByParent,
                                                                      NSMutableSet<NSString *> *visibleNames,
                                                                      ApolloDeletedCommentsPatchStats *stats) {
    if (!node || childrenByParent.count == 0) return 0;
    NSUInteger inserted = 0;

    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data) {
            NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
            if (fullName.length > 0 && childrenByParent[fullName].count > 0) {
                NSMutableArray *replyChildren = ApolloDeletedCommentsMutableRepliesChildrenForCommentData(data);
                inserted += ApolloDeletedCommentsOverlayArchivedChildrenForParent(replyChildren, fullName, childrenByParent, visibleNames, stats);
            }
        }

        for (id value in [dict allValues]) {
            inserted += ApolloDeletedCommentsOverlayArchivedDeletedComments(value, linkFullName, childrenByParent, visibleNames, stats);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        NSArray *snapshot = [(NSArray *)node copy];
        for (id value in snapshot) {
            inserted += ApolloDeletedCommentsOverlayArchivedDeletedComments(value, linkFullName, childrenByParent, visibleNames, stats);
        }
    }
    return inserted;
}

static NSUInteger ApolloDeletedCommentsPatchRedditJSONNode(id node, NSDictionary<NSString *, NSDictionary *> *arcticComments, NSMutableSet<NSString *> *visibleNames, ApolloDeletedCommentsPatchStats *stats) {
    if (!node || !arcticComments) return 0;
    NSUInteger patched = 0;

    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data) {
            if (stats) stats->t1Count++;
            NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
            NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
            if (archived && stats) stats->archivedMatchCount++;
            NSString *archivedBody = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
            NSString *currentBody = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
            NSString *currentBodyHTML = [data[@"body_html"] isKindOfClass:[NSString class]] ? data[@"body_html"] : nil;
            BOOL currentLooksDeleted = ApolloDeletedCommentsCommentDataLooksDeleted(data);
            if (currentLooksDeleted && stats) stats->deletedLookingCount++;
            if (currentLooksDeleted && archivedBody.length > 0 && !ApolloDeletedCommentsBodyLooksDeleted(archivedBody)) {
                if (stats) stats->recoverableCount++;
                NSString *author = [archived[@"author"] isKindOfClass:[NSString class]] ? archived[@"author"] : nil;
                ApolloDeletedCommentsSetRecoveredBody(data, archivedBody);
                if (author.length > 0) data[@"author"] = author;
                if ([archived[@"created_utc"] respondsToSelector:@selector(doubleValue)]) data[@"created_utc"] = archived[@"created_utc"];
                if ([archived[@"score"] respondsToSelector:@selector(integerValue)]) data[@"score"] = archived[@"score"];
                NSString *reason = ApolloDeletedCommentsReasonForCurrentBody(currentBody, currentBodyHTML);
                ApolloDeletedCommentsApplyRecoveredMetadata(data, reason);
                ApolloDeletedCommentsClearRemovalMetadata(data);
                ApolloLog(@"[DeletedComments] Recovered visible deleted comment %@", fullName ?: @"unknown");
                patched++;
            } else if (currentLooksDeleted && stats) {
                stats->unrecoverableCount++;
            }
        }

        for (id value in [dict allValues]) {
            patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
        }
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *array = (NSMutableArray *)node;
        for (NSUInteger i = 0; i < array.count; i++) {
            id value = array[i];
            if ([value isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *dict = (NSMutableDictionary *)value;
                NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
                NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
                NSMutableArray *children = [data[@"children"] isKindOfClass:[NSMutableArray class]] ? data[@"children"] : nil;
                if ([kind isEqualToString:@"more"] && children.count > 0) {
                    NSUInteger originalMoreCount = [data[@"count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [data[@"count"] unsignedIntegerValue] : children.count;
                    NSMutableArray *expanded = [NSMutableArray array];
                    NSMutableArray *remainingChildren = [NSMutableArray array];
                    for (id childID in children) {
                        NSString *identifier = nil;
                        if ([childID isKindOfClass:[NSString class]]) identifier = childID;
                        else if ([childID respondsToSelector:@selector(stringValue)]) identifier = [childID stringValue];
                        NSString *fullName = [identifier hasPrefix:@"t1_"] ? identifier : (identifier.length > 0 ? [@"t1_" stringByAppendingString:identifier] : nil);
                        NSDictionary *archived = fullName.length > 0 ? arcticComments[fullName] : nil;
                        if (fullName.length > 0 &&
                            ![visibleNames containsObject:fullName] &&
                            ApolloDeletedCommentsArchivedWasDeleted(archived)) {
                            NSMutableDictionary *thing = ApolloDeletedCommentsThingFromArchived(archived, ApolloDeletedCommentsReasonForArchived(archived));
                            if (thing) {
                                [expanded addObject:thing];
                                [visibleNames addObject:fullName];
                                if (stats) stats->insertedFromMoreCount++;
                                continue;
                            }
                        }
                        [remainingChildren addObject:childID];
                    }
                    if (expanded.count > 0) {
                        if (remainingChildren.count > 0) {
                            [children setArray:remainingChildren];
                            NSUInteger adjustedCount = originalMoreCount > expanded.count ? originalMoreCount - expanded.count : remainingChildren.count;
                            if (adjustedCount < remainingChildren.count) adjustedCount = remainingChildren.count;
                            data[@"count"] = @(adjustedCount);
                            NSString *firstRemainingID = [remainingChildren.firstObject isKindOfClass:[NSString class]] ? remainingChildren.firstObject : nil;
                            if (firstRemainingID.length > 0) {
                                data[@"id"] = firstRemainingID;
                                data[@"name"] = [firstRemainingID hasPrefix:@"t1_"] ? firstRemainingID : [@"t1_" stringByAppendingString:firstRemainingID];
                            }
                            [array insertObjects:expanded atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(i, expanded.count)]];
                            patched += expanded.count;
                            i += expanded.count;
                        } else {
                            [array replaceObjectsInRange:NSMakeRange(i, 1)
                                               withObjectsFromArray:expanded];
                            patched += expanded.count;
                            i += expanded.count - 1;
                        }
                        continue;
                    }
                }
            }
            patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) patched += ApolloDeletedCommentsPatchRedditJSONNode(value, arcticComments, visibleNames, stats);
    }
    return patched;
}

static NSMutableArray *ApolloDeletedCommentsPreferredInsertionArray(id node) {
    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
        NSMutableArray *children = [data[@"children"] isKindOfClass:[NSMutableArray class]] ? data[@"children"] : nil;
        if ([kind isEqualToString:@"Listing"] && children) return children;

        NSMutableDictionary *json = [dict[@"json"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"json"] : nil;
        NSMutableDictionary *jsonData = [json[@"data"] isKindOfClass:[NSMutableDictionary class]] ? json[@"data"] : nil;
        NSMutableArray *things = [jsonData[@"things"] isKindOfClass:[NSMutableArray class]] ? jsonData[@"things"] : nil;
        if (things) return things;

        for (id value in [dict allValues]) {
            NSMutableArray *array = ApolloDeletedCommentsPreferredInsertionArray(value);
            if (array) return array;
        }
    } else if ([node isKindOfClass:[NSMutableArray class]]) {
        for (id value in (NSArray *)node) {
            NSMutableArray *array = ApolloDeletedCommentsPreferredInsertionArray(value);
            if (array) return array;
        }
    }
    return nil;
}

static NSUInteger ApolloDeletedCommentsInsertMissingMoreChildren(id root,
                                                                 NSURLRequest *request,
                                                                 NSDictionary<NSString *, NSDictionary *> *arcticComments,
                                                                 NSMutableSet<NSString *> *visibleNames,
                                                                 ApolloDeletedCommentsPatchStats *stats) {
    NSArray<NSString *> *requested = ApolloDeletedCommentsRequestedMoreChildren(request);
    if (requested.count == 0) return 0;
    if (stats) stats->requestedMoreCount += requested.count;
    if (requested.count > 100) {
        ApolloLog(@"[DeletedComments] Skipping missing morechildren synthesis for bulk request (%lu requested)",
                  (unsigned long)requested.count);
        return 0;
    }

    NSMutableArray *insertionArray = ApolloDeletedCommentsPreferredInsertionArray(root);
    if (!insertionArray) return 0;

    NSMutableSet<NSString *> *seenRequested = [NSMutableSet set];
    NSMutableArray *inserted = [NSMutableArray array];
    for (NSString *fullName in requested) {
        if (fullName.length == 0 || [seenRequested containsObject:fullName]) continue;
        [seenRequested addObject:fullName];

        if ([visibleNames containsObject:fullName]) {
            if (stats) stats->returnedRequestedMoreCount++;
            continue;
        }

        NSDictionary *archived = arcticComments[fullName];
        NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
        if (body.length == 0 || ApolloDeletedCommentsBodyLooksDeleted(body)) continue;
        if (!ApolloDeletedCommentsArchivedWasDeleted(archived)) {
            if (stats) stats->skippedMissingWithoutDeletionEvidenceCount++;
            continue;
        }

        NSMutableDictionary *thing = ApolloDeletedCommentsThingFromArchived(archived, ApolloDeletedCommentsReasonForArchived(archived));
        if (!thing) continue;

        [inserted addObject:thing];
        [visibleNames addObject:fullName];
    }

    if (inserted.count == 0) return 0;
    [insertionArray addObjectsFromArray:inserted];
    if (stats) stats->insertedMissingMoreCount += inserted.count;
    return inserted.count;
}

static void ApolloDeletedCommentsPatchResponseAsync(NSData *data, NSURLRequest *request, void (^completion)(NSData *patchedData)) {
    NSString *linkFullName = sShowDeletedComments ? ApolloDeletedCommentsLinkFullNameForRequest(request) : nil;
    if (linkFullName.length == 0 || data.length == 0) {
        completion(data);
        return;
    }

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (!root) {
        completion(data);
        return;
    }

    NSObject *completionLock = [NSObject new];
    __block BOOL didComplete = NO;
    void (^completeOnce)(NSData *) = ^(NSData *patchedData) {
        BOOL shouldComplete = NO;
        @synchronized(completionLock) {
            if (!didComplete) {
                didComplete = YES;
                shouldComplete = YES;
            }
        }
        if (shouldComplete) completion(patchedData.length > 0 ? patchedData : data);
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloDeletedCommentsArcticPatchTimeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL timedOut = NO;
        @synchronized(completionLock) {
            timedOut = !didComplete;
        }
        if (timedOut) {
            ApolloLog(@"[DeletedComments] Arctic patch timed out for %@; delivering original Reddit comments", linkFullName);
            ApolloDeletedCommentsArcticBeginCooldown(ApolloDeletedCommentsArcticErrorCooldown, @"patch timeout");
            completeOnce(data);
        }
    });

    void (^applyPatchWithComments)(NSDictionary<NSString *, NSDictionary *> *, NSUInteger, NSUInteger) = ^(NSDictionary<NSString *, NSDictionary *> *mergedComments, NSUInteger exactLookupCount, NSUInteger exactMatchedCount) {
        if (mergedComments.count == 0) {
            completeOnce(data);
            return;
        }

        NSMutableSet<NSString *> *visibleNames = [NSMutableSet set];
        ApolloDeletedCommentsCollectVisibleCommentNames(root, visibleNames);
        ApolloDeletedCommentsPatchStats stats = {0};
        stats.exactLookupCount = exactLookupCount;
        stats.exactMatchCount = exactMatchedCount;
        NSDictionary<NSString *, NSArray<NSDictionary *> *> *childrenByParent = ApolloDeletedCommentsRecoverableChildrenByParent(mergedComments, &stats);
        NSUInteger patched = ApolloDeletedCommentsOverlayArchivedDeletedComments(root, linkFullName, childrenByParent, visibleNames, &stats);
        patched += ApolloDeletedCommentsPatchRedditJSONNode(root, mergedComments, visibleNames, &stats);
        patched += ApolloDeletedCommentsInsertMissingMoreChildren(root, request, mergedComments, visibleNames, &stats);
        if (patched == 0) {
            ApolloLog(@"[DeletedComments] Response patch found no deleted comments to replace for %@ url=%@ (t1=%lu deletedLooking=%lu archivedMatches=%lu recoverable=%lu unrecoverable=%lu overlayInserted=%lu overlayRecoverable=%lu insertedMore=%lu requestedMore=%lu returnedRequested=%lu insertedMissing=%lu skippedMissingNoDelete=%lu exactLookup=%lu exactMatches=%lu archived=%lu)",
                      linkFullName,
                      request.URL.absoluteString ?: @"",
                      (unsigned long)stats.t1Count,
                      (unsigned long)stats.deletedLookingCount,
                      (unsigned long)stats.archivedMatchCount,
                      (unsigned long)stats.recoverableCount,
                      (unsigned long)stats.unrecoverableCount,
                      (unsigned long)stats.overlayInsertedCount,
                      (unsigned long)stats.overlayRecoverableCount,
                      (unsigned long)stats.insertedFromMoreCount,
                      (unsigned long)stats.requestedMoreCount,
                      (unsigned long)stats.returnedRequestedMoreCount,
                      (unsigned long)stats.insertedMissingMoreCount,
                      (unsigned long)stats.skippedMissingWithoutDeletionEvidenceCount,
                      (unsigned long)stats.exactLookupCount,
                      (unsigned long)stats.exactMatchCount,
                      (unsigned long)mergedComments.count);
            completeOnce(data);
            return;
        }

        NSData *patchedData = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
        if (patchedData.length == 0) {
            completeOnce(data);
            return;
        }
        ApolloLog(@"[DeletedComments] Patched Reddit comments response for %@ (%lu comments, visible=%lu, unrecoverable=%lu, overlayInserted=%lu, overlayRecoverable=%lu, insertedMore=%lu, requestedMore=%lu, returnedRequested=%lu, insertedMissing=%lu, skippedMissingNoDelete=%lu, exactLookup=%lu, exactMatches=%lu)",
                  linkFullName,
                  (unsigned long)patched,
                  (unsigned long)stats.recoverableCount,
                  (unsigned long)stats.unrecoverableCount,
                  (unsigned long)stats.overlayInsertedCount,
                  (unsigned long)stats.overlayRecoverableCount,
                  (unsigned long)stats.insertedFromMoreCount,
                  (unsigned long)stats.requestedMoreCount,
                  (unsigned long)stats.returnedRequestedMoreCount,
                  (unsigned long)stats.insertedMissingMoreCount,
                  (unsigned long)stats.skippedMissingWithoutDeletionEvidenceCount,
                  (unsigned long)stats.exactLookupCount,
                  (unsigned long)stats.exactMatchCount);
        completeOnce(patchedData);
    };

    NSArray<NSString *> *requestedMoreChildren = ApolloDeletedCommentsRequestedMoreChildren(request);
    if (ApolloDeletedCommentsIsMoreChildrenRequest(request) && requestedMoreChildren.count > 0) {
        NSMutableOrderedSet<NSString *> *moreTargets = [NSMutableOrderedSet orderedSet];
        for (NSString *fullName in requestedMoreChildren) {
            ApolloDeletedCommentsAddLookupTarget(moreTargets, fullName);
        }
        ApolloDeletedCommentsFetchArcticCommentsByFullNames(moreTargets.array, ^(NSDictionary<NSString *, NSDictionary *> *exactComments) {
            applyPatchWithComments(exactComments ?: @{}, moreTargets.count, exactComments.count);
        });
        return;
    }

    ApolloDeletedCommentsFetchArcticComments(linkFullName, ^(NSDictionary<NSString *, NSDictionary *> *comments) {
        if (comments.count == 0) {
            completeOnce(data);
            return;
        }

        NSMutableDictionary<NSString *, NSDictionary *> *mergedComments = [comments mutableCopy];
        NSMutableOrderedSet<NSString *> *exactTargets = [NSMutableOrderedSet orderedSet];
        ApolloDeletedCommentsCollectExactLookupTargets(root, mergedComments, exactTargets);
        for (NSString *fullName in requestedMoreChildren) {
            ApolloDeletedCommentsAddLookupTarget(exactTargets, fullName);
        }
        __block NSUInteger exactMatchedCount = 0;

        if (exactTargets.count == 0) {
            applyPatchWithComments(mergedComments, exactTargets.count, exactMatchedCount);
            return;
        }

        ApolloDeletedCommentsFetchArcticCommentsByFullNames(exactTargets.array, ^(NSDictionary<NSString *, NSDictionary *> *exactComments) {
            exactMatchedCount = exactComments.count;
            if (exactComments.count > 0) [mergedComments addEntriesFromDictionary:exactComments];
            applyPatchWithComments(mergedComments, exactTargets.count, exactMatchedCount);
        });
    });
}

#pragma mark - CompletionFacade

ApolloDeletedCommentsURLSessionCompletion ApolloDeletedCommentsMaybeWrapCompletion(NSURLRequest *request, ApolloDeletedCommentsURLSessionCompletion completion) {
    if (!completion || !ApolloDeletedCommentsShouldTransformRequest(request)) return completion;

    ApolloDeletedCommentsURLSessionCompletion wrapped = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || data.length == 0) {
            completion(data, response, error);
            return;
        }
        ApolloDeletedCommentsPatchResponseAsync(data, request, ^(NSData *patchedData) {
            completion(patchedData.length > 0 ? patchedData : data, response, error);
        });
    };
    return [wrapped copy];
}

#pragma mark - DelegateResponseTransformer

static void ApolloDeletedCommentsInstallResponseTransformerForDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    NSString *classKey = NSStringFromClass(cls);

    @synchronized ([NSURLSession class]) {
        if (!sApolloDeletedCommentsDelegateTransformerInstalledClasses) sApolloDeletedCommentsDelegateTransformerInstalledClasses = [NSMutableSet set];
        if ([sApolloDeletedCommentsDelegateTransformerInstalledClasses containsObject:classKey]) return;
        [sApolloDeletedCommentsDelegateTransformerInstalledClasses addObject:classKey];
    }

    SEL didReceiveDataSelector = @selector(URLSession:dataTask:didReceiveData:);
    Method didReceiveDataMethod = class_getInstanceMethod(cls, didReceiveDataSelector);
    IMP originalDidReceiveDataIMP = didReceiveDataMethod ? method_getImplementation(didReceiveDataMethod) : NULL;
    const char *didReceiveDataTypes = didReceiveDataMethod ? method_getTypeEncoding(didReceiveDataMethod) : "v@:@@@";
    IMP didReceiveDataIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data) {
        if (sShowDeletedComments && ApolloDeletedCommentsShouldTransformTask(dataTask) && data.length > 0) {
            NSMutableData *buffered = objc_getAssociatedObject(dataTask, kApolloDeletedCommentsResponseDataKey);
            if (!buffered) {
                buffered = [NSMutableData data];
                objc_setAssociatedObject(dataTask, kApolloDeletedCommentsResponseDataKey, buffered, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [buffered appendData:data];
            return;
        }
        if (originalDidReceiveDataIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, dataTask, data);
        }
    });
    class_replaceMethod(cls, didReceiveDataSelector, didReceiveDataIMP, didReceiveDataTypes);

    SEL didCompleteSelector = @selector(URLSession:task:didCompleteWithError:);
    Method didCompleteMethod = class_getInstanceMethod(cls, didCompleteSelector);
    IMP originalDidCompleteIMP = didCompleteMethod ? method_getImplementation(didCompleteMethod) : NULL;
    const char *didCompleteTypes = didCompleteMethod ? method_getTypeEncoding(didCompleteMethod) : "v@:@@@";

    void (^deliverOriginal)(NSURLSession *, NSURLSessionTask *, NSData *, NSError *, id) = ^(NSURLSession *session, NSURLSessionTask *task, NSData *data, NSError *error, id selfObject) {
        void (^run)(void) = ^{
            if (data.length > 0 && originalDidReceiveDataIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))originalDidReceiveDataIMP)(selfObject, didReceiveDataSelector, session, (NSURLSessionDataTask *)task, data);
            }
            if (originalDidCompleteIMP) {
                ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
            }
        };
        NSOperationQueue *delegateQueue = session.delegateQueue;
        if (delegateQueue) {
            [delegateQueue addOperationWithBlock:run];
        } else {
            run();
        }
    };

    IMP didCompleteIMP = imp_implementationWithBlock(^(id selfObject, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
        if (sShowDeletedComments && ApolloDeletedCommentsShouldTransformTask(task)) {
            NSMutableData *buffered = objc_getAssociatedObject(task, kApolloDeletedCommentsResponseDataKey);
            objc_setAssociatedObject(task, kApolloDeletedCommentsResponseDataKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSURLRequest *request = task.originalRequest ?: task.currentRequest;
            if (buffered.length > 0 && !error) {
                ApolloDeletedCommentsPatchResponseAsync(buffered, request, ^(NSData *patchedData) {
                    deliverOriginal(session, task, patchedData.length > 0 ? patchedData : buffered, error, selfObject);
                });
                return;
            }
        }

        if (originalDidCompleteIMP) {
            ((void (*)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *))originalDidCompleteIMP)(selfObject, didCompleteSelector, session, task, error);
        }
    });
    class_replaceMethod(cls, didCompleteSelector, didCompleteIMP, didCompleteTypes);

    ApolloLog(@"[DeletedComments] Installed comments response transformer on delegate class %@", classKey);
}

void ApolloDeletedCommentsInstallDelegateTransformerIfNeeded(NSURLSession *session, NSURLRequest *request) {
    if (!ApolloDeletedCommentsShouldTransformRequest(request)) return;
    ApolloDeletedCommentsInstallResponseTransformerForDelegate(session.delegate);
}

#ifdef APOLLO_DELETED_COMMENTS_TESTING
NSString *ApolloDeletedCommentsTestLinkFullNameFromRedditURL(NSURL *url) {
    return ApolloDeletedCommentsLinkFullNameFromRedditURL(url);
}

BOOL ApolloDeletedCommentsTestBodyLooksDeleted(NSString *body, NSString *bodyHTML) {
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    if (body) data[@"body"] = body;
    if (bodyHTML) data[@"body_html"] = bodyHTML;
    return ApolloDeletedCommentsCommentDataLooksDeleted(data);
}

NSUInteger ApolloDeletedCommentsTestPatchRedditJSONRoot(id root, NSDictionary<NSString *, NSDictionary *> *archivedComments) {
    NSMutableSet<NSString *> *visibleNames = [NSMutableSet set];
    ApolloDeletedCommentsCollectVisibleCommentNames(root, visibleNames);
    ApolloDeletedCommentsPatchStats stats = {0};
    return ApolloDeletedCommentsPatchRedditJSONNode(root, archivedComments, visibleNames, &stats);
}

BOOL ApolloDeletedCommentsTestArcticResponseShouldCooldown(NSInteger statusCode, NSInteger remaining) {
    return ApolloDeletedCommentsArcticResponseShouldCooldown(statusCode, remaining);
}
#endif
