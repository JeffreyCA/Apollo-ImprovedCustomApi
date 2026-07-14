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
NSString *const ApolloDeletedCommentsArcticCacheUpdatedNotification = @"ApolloDeletedCommentsArcticCacheUpdatedNotification";

static const void *kApolloDeletedCommentsResponseDataKey = &kApolloDeletedCommentsResponseDataKey;
static NSMutableSet<NSString *> *sApolloDeletedCommentsDelegateTransformerInstalledClasses = nil;
static NSString *sApolloDeletedCommentsLastObservedLinkFullName = nil;
static NSDate *sApolloDeletedCommentsLastObservedLinkDate = nil;
static NSMutableDictionary<NSString *, NSString *> *sApolloDeletedCommentsRecoveredReasonsByFullName = nil;
static NSMutableDictionary<NSString *, NSString *> *sApolloDeletedCommentsPlaceholderReasonsByFullName = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *sApolloDeletedCommentsArchivedByFullName = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRecoveredBodyKeys = nil;
static NSMutableDictionary<NSString *, NSString *> *sApolloDeletedCommentsRecoveredReasonsByBodyKey = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRevealedFullNames = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsRevealedBodyKeys = nil;
static NSObject *sApolloDeletedCommentsRegistryLock = nil;
static NSObject *sApolloDeletedCommentsArcticLock = nil;
static NSMutableDictionary<NSString *, NSDictionary *> *sApolloDeletedCommentsArcticCache = nil;
static NSMutableDictionary<NSString *, NSMutableArray *> *sApolloDeletedCommentsArcticInflight = nil;
static NSDate *sApolloDeletedCommentsArcticCooldownUntil = nil;
static NSMutableSet<NSString *> *sApolloDeletedCommentsThreadOverrides = nil;

static NSString *const ApolloDeletedCommentsMarkerKey = @"apollo_recovered_deleted_comment";
static NSString *const ApolloDeletedCommentsReasonKey = @"apollo_recovered_deleted_reason";
static NSString *const ApolloDeletedCommentsPlaceholderMarkerKey = @"apollo_deleted_comment_placeholder";
static NSString *const ApolloDeletedCommentsPlaceholderReasonKey = @"apollo_deleted_comment_placeholder_reason";
static NSString *const ApolloDeletedCommentsReasonUserDeleted = @"user_deleted";
static NSString *const ApolloDeletedCommentsReasonModeratorRemoved = @"moderator_removed";
static NSString *const ApolloDeletedCommentsArcticCacheCommentsKey = @"comments";
static NSString *const ApolloDeletedCommentsArcticCacheExpiryKey = @"expires";

static NSTimeInterval const ApolloDeletedCommentsArcticSuccessCacheTTL = 600.0;
static NSTimeInterval const ApolloDeletedCommentsArcticEmptyCacheTTL = 60.0;
static NSTimeInterval const ApolloDeletedCommentsArcticErrorCooldown = 30.0;
static NSTimeInterval const ApolloDeletedCommentsArcticRateLimitCooldown = 60.0;
static NSTimeInterval const ApolloDeletedCommentsInitialRecoveryWait = 2.0;
static NSInteger const ApolloDeletedCommentsArcticLowRemainingThreshold = 3;

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s);
static NSString *ApolloDeletedCommentsUnescapedHTMLText(NSString *s);
static NSString *ApolloDeletedCommentsNormalizeLinkID(NSString *identifier);
static NSString *ApolloDeletedCommentsCommentFullName(NSDictionary *data);
static NSString *ApolloDeletedCommentsReasonForArchived(NSDictionary *archived);
static BOOL ApolloDeletedCommentsBodyLooksDeleted(NSString *body);
static void ApolloDeletedCommentsWarmArcticCacheForLink(NSString *linkFullName, NSString *source);

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

#pragma mark - ThreadOverrides

// Per-thread overrides for "Passive Deleted Comments": each entry is a post
// fullName (t3_xxx) whose comment thread has recovery turned on from the
// comments "..." menu while the global toggle is off. In-memory only — leaving
// the thread clears its entry (ApolloDeletedCommentsMenu.xm) and nothing
// survives relaunch by design.

static NSString *ApolloDeletedCommentsOverrideKeyForLink(NSString *linkFullName) {
    if (![linkFullName isKindOfClass:[NSString class]]) return nil;
    return [ApolloDeletedCommentsNormalizeLinkID(linkFullName) lowercaseString];
}

void ApolloDeletedCommentsSetThreadOverride(NSString *linkFullName, BOOL enabled) {
    NSString *key = ApolloDeletedCommentsOverrideKeyForLink(linkFullName);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (enabled) {
            if (!sApolloDeletedCommentsThreadOverrides) {
                sApolloDeletedCommentsThreadOverrides = [NSMutableSet set];
            }
            [sApolloDeletedCommentsThreadOverrides addObject:key];
        } else {
            [sApolloDeletedCommentsThreadOverrides removeObject:key];
        }
    }
    ApolloLog(@"[DeletedComments] Thread override %@ for %@", enabled ? @"ON" : @"OFF", key);
}

BOOL ApolloDeletedCommentsHasThreadOverride(NSString *linkFullName) {
    NSString *key = ApolloDeletedCommentsOverrideKeyForLink(linkFullName);
    if (key.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsThreadOverrides containsObject:key];
    }
}

// Master gate: the machinery runs when the global toggle is on OR any thread
// override is active. Cell/registry-level code uses this coarse form; the
// network entry points below additionally gate per-link so only overridden
// threads fetch and patch while the global toggle is off.
BOOL ApolloDeletedCommentsFeatureActive(void) {
    if (sShowDeletedComments) return YES;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsThreadOverrides.count > 0;
    }
}

BOOL ApolloDeletedCommentsActiveForLink(NSString *linkFullName) {
    if (sShowDeletedComments) return YES;
    return ApolloDeletedCommentsHasThreadOverride(linkFullName);
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

void ApolloDeletedCommentsRegisterDeletedPlaceholder(NSString *fullName, NSString *reason) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsPlaceholderReasonsByFullName) {
            sApolloDeletedCommentsPlaceholderReasonsByFullName = [NSMutableDictionary dictionary];
        }
        sApolloDeletedCommentsPlaceholderReasonsByFullName[fullName] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    }
}

BOOL ApolloDeletedCommentsIsDeletedPlaceholder(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsPlaceholderReasonsByFullName[fullName] != nil;
    }
}

NSString *ApolloDeletedCommentsDeletedPlaceholderReason(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return nil;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsPlaceholderReasonsByFullName[fullName];
    }
}

static void ApolloDeletedCommentsStoreArchivedCommentsByFullName(NSDictionary<NSString *, NSDictionary *> *comments) {
    if (comments.count == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsArchivedByFullName) {
            sApolloDeletedCommentsArchivedByFullName = [NSMutableDictionary dictionary];
        }
        for (NSString *fullName in comments) {
            NSDictionary *archived = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
            if ([fullName isKindOfClass:[NSString class]] && fullName.length > 0 && archived) {
                sApolloDeletedCommentsArchivedByFullName[fullName] = archived;
            }
        }
    }
}

NSDictionary *ApolloDeletedCommentsCachedArchivedComment(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return nil;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsArchivedByFullName[fullName] copy];
    }
}

static void ApolloDeletedCommentsRegisterRecoveredBody(NSString *author, NSString *body, NSString *reason) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (!sApolloDeletedCommentsRecoveredBodyKeys) {
            sApolloDeletedCommentsRecoveredBodyKeys = [NSMutableSet set];
        }
        if (!sApolloDeletedCommentsRecoveredReasonsByBodyKey) {
            sApolloDeletedCommentsRecoveredReasonsByBodyKey = [NSMutableDictionary dictionary];
        }
        [sApolloDeletedCommentsRecoveredBodyKeys addObject:key];
        sApolloDeletedCommentsRecoveredReasonsByBodyKey[key] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    }
}

BOOL ApolloDeletedCommentsIsRecoveredComment(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsRecoveredReasonsByFullName[fullName] != nil;
    }
}

NSString *ApolloDeletedCommentsRecoveredReasonForComment(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return nil;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return sApolloDeletedCommentsRecoveredReasonsByFullName[fullName];
    }
}

BOOL ApolloDeletedCommentsIsRecoveredCommentBody(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return NO;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        return [sApolloDeletedCommentsRecoveredBodyKeys containsObject:key];
    }
}

NSString *ApolloDeletedCommentsRecoveredReasonForCommentBody(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return nil;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        if (![sApolloDeletedCommentsRecoveredBodyKeys containsObject:key]) return nil;
        return sApolloDeletedCommentsRecoveredReasonsByBodyKey[key] ?: ApolloDeletedCommentsReasonModeratorRemoved;
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

void ApolloDeletedCommentsUnmarkCommentRevealed(NSString *fullName) {
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        [sApolloDeletedCommentsRevealedFullNames removeObject:fullName];
    }
}

void ApolloDeletedCommentsUnmarkCommentBodyRevealed(NSString *author, NSString *body) {
    NSString *key = ApolloDeletedCommentsRegistryBodyKey(author, body);
    if (key.length == 0) return;
    @synchronized(ApolloDeletedCommentsRegistryLock()) {
        [sApolloDeletedCommentsRevealedBodyKeys removeObject:key];
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
    if (!ApolloDeletedCommentsFeatureActive() || !request.URL || !ApolloDeletedCommentsIsRedditHost(request.URL.host)) return NO;
    if (!ApolloDeletedCommentsRequestLooksLikeCommentsPayload(request)) return NO;
    NSString *linkFullName = ApolloDeletedCommentsLinkFullNameForRequest(request);
    return linkFullName.length > 0 && ApolloDeletedCommentsActiveForLink(linkFullName);
}

static BOOL ApolloDeletedCommentsShouldTransformTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]]) return NO;
    return ApolloDeletedCommentsShouldTransformRequest(task.originalRequest) ||
           ApolloDeletedCommentsShouldTransformRequest(task.currentRequest);
}

void ApolloDeletedCommentsHandleRequestObservation(NSURLRequest *request, NSString *source) {
    if (!ApolloDeletedCommentsFeatureActive()) return;
    NSString *fullName = ApolloDeletedCommentsLinkFullNameFromRedditURL(request.URL);
    if (fullName.length == 0) return;

    // Track EVERY observed thread (not just gated ones) so the 45s
    // morechildren fallback in ApolloDeletedCommentsLinkFullNameForRequest
    // always points at the thread the user is actually in — otherwise a
    // non-overridden thread's "load more comments" (whose URL has no link id)
    // would be misattributed to a previously overridden thread.
    BOOL changed = ![sApolloDeletedCommentsLastObservedLinkFullName isEqualToString:fullName];
    sApolloDeletedCommentsLastObservedLinkFullName = [fullName copy];
    sApolloDeletedCommentsLastObservedLinkDate = [NSDate date];
    if (changed) {
        ApolloLog(@"[DeletedComments] Observed Reddit comments request %@ (%@)", fullName, source ?: @"unknown");
    }

    // Only gated threads warm the archive and notify.
    if (!ApolloDeletedCommentsActiveForLink(fullName)) return;

    if (!ApolloDeletedCommentsIsMoreChildrenRequest(request)) {
        ApolloDeletedCommentsWarmArcticCacheForLink(fullName, source ?: @"request observation");
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

static BOOL ApolloDeletedCommentsAuthorLooksDeleted(NSString *author) {
    NSString *trimmed = [[ApolloDeletedCommentsTrimmedString(author) ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [trimmed isEqualToString:@"[deleted]"] ||
           [trimmed isEqualToString:@"[removed]"] ||
           [trimmed isEqualToString:@"deleted"] ||
           [trimmed isEqualToString:@"removed"];
}

static BOOL ApolloDeletedCommentsDataHasRemovalMetadata(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return NO;
    NSString *removedByCategory = [data[@"removed_by_category"] isKindOfClass:[NSString class]] ? data[@"removed_by_category"] : nil;
    if (removedByCategory.length > 0) return YES;
    if (data[@"banned_by"] && data[@"banned_by"] != (id)[NSNull null]) return YES;
    NSString *collapsedReasonCode = [data[@"collapsed_reason_code"] isKindOfClass:[NSString class]] ? data[@"collapsed_reason_code"] : nil;
    if (collapsedReasonCode.length > 0 &&
        [collapsedReasonCode rangeOfString:@"removed" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if (collapsedReasonCode.length > 0 &&
        [collapsedReasonCode rangeOfString:@"deleted" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL ApolloDeletedCommentsCommentDataLooksDeleted(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return NO;
    NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
    NSString *trimmedBody = ApolloDeletedCommentsTrimmedString(body);
    if (trimmedBody.length > 0 && ApolloDeletedCommentsBodyLooksDeleted(body)) return YES;

    NSString *bodyHTML = [data[@"body_html"] isKindOfClass:[NSString class]] ? data[@"body_html"] : nil;
    if (trimmedBody.length == 0 && bodyHTML.length > 0) {
        NSString *htmlText = ApolloDeletedCommentsUnescapedHTMLText(bodyHTML);
        if ([htmlText rangeOfString:@"[removed]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [htmlText rangeOfString:@"[deleted]" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [htmlText rangeOfString:@"Removed by moderator" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [htmlText rangeOfString:@"User deleted comment" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    if (trimmedBody.length == 0) {
        NSString *author = [data[@"author"] isKindOfClass:[NSString class]] ? data[@"author"] : nil;
        return ApolloDeletedCommentsAuthorLooksDeleted(author) || ApolloDeletedCommentsDataHasRemovalMetadata(data);
    }
    return NO;
}

static NSString *ApolloDeletedCommentsCommentFullName(NSDictionary *data) {
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = [data[@"name"] isKindOfClass:[NSString class]] ? data[@"name"] : nil;
    if ([name hasPrefix:@"t1_"]) return name;
    NSString *identifier = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : nil;
    if (identifier.length == 0) return nil;
    return [identifier hasPrefix:@"t1_"] ? identifier : [@"t1_" stringByAppendingString:identifier];
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

NSString *ApolloDeletedCommentsDisplayLabelForReason(NSString *reason) {
    if ([reason isEqualToString:ApolloDeletedCommentsReasonUserDeleted]) return @"DELETED BY USER";
    return @"REMOVED BY MOD";
}

// Convert the common inline Markdown that recovered comment bodies carry into the
// real HTML tags Reddit's body_html would contain, so Apollo's renderer shows links
// and bold instead of the literal "[text](url)" / "**text**" source. Runs on text that
// is ALREADY HTML-escaped, so the markers ([](), **) are intact while the content is
// safe; the tags we emit are re-encoded by RedditBodyHTML's final escape (Apollo
// unescapes once and parses). Scoped to http(s) links to avoid false matches.
static NSString *ApolloDeletedCommentsApplyInlineMarkdownHTML(NSString *escaped) {
    if (escaped.length == 0) return escaped;
    NSString *result = escaped;

    static NSRegularExpression *linkRe = nil;
    static dispatch_once_t linkOnce;
    dispatch_once(&linkOnce, ^{
        linkRe = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]\\n]+)\\]\\((https?://[^)\\s]+)\\)"
                                                           options:0 error:nil];
    });
    result = [linkRe stringByReplacingMatchesInString:result options:0
                                                range:NSMakeRange(0, result.length)
                                         withTemplate:@"<a href=\"$2\">$1</a>"];

    static NSRegularExpression *boldRe = nil;
    static dispatch_once_t boldOnce;
    dispatch_once(&boldOnce, ^{
        boldRe = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*([^*\\n]+)\\*\\*"
                                                           options:0 error:nil];
    });
    result = [boldRe stringByReplacingMatchesInString:result options:0
                                                range:NSMakeRange(0, result.length)
                                         withTemplate:@"<strong>$1</strong>"];
    return result;
}

NSString *ApolloDeletedCommentsRedditBodyHTML(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return nil;

    NSMutableArray<NSString *> *htmlParagraphs = [NSMutableArray array];
    for (NSString *paragraph in [trimmed componentsSeparatedByString:@"\n\n"]) {
        NSString *p = ApolloDeletedCommentsTrimmedString(paragraph);
        if (p.length == 0) continue;
        NSString *escaped = ApolloDeletedCommentsEscapeHTML(p);
        escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br/>"];
        escaped = ApolloDeletedCommentsApplyInlineMarkdownHTML(escaped);
        [htmlParagraphs addObject:[NSString stringWithFormat:@"<p>%@</p>", escaped]];
    }
    if (htmlParagraphs.count == 0) return nil;

    NSString *html = [NSString stringWithFormat:@"<div class=\"md\">%@\n</div>", [htmlParagraphs componentsJoinedByString:@"\n"]];
    return ApolloDeletedCommentsEscapeHTML(html);
}

static void ApolloDeletedCommentsSetRecoveredBody(NSMutableDictionary *data, NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return;

    data[@"body"] = trimmed;
    NSString *bodyHTML = ApolloDeletedCommentsRedditBodyHTML(trimmed);
    if (bodyHTML.length > 0) data[@"body_html"] = bodyHTML;
}

static void ApolloDeletedCommentsHideRecoveredBodyForTapToReveal(NSMutableDictionary *data, NSString *reason) {
    if (!sTapToRevealDeletedComments || !data) return;
    NSString *label = ApolloDeletedCommentsDisplayLabelForReason(reason);
    if (label.length == 0) return;

    data[@"body"] = label;
    NSString *bodyHTML = ApolloDeletedCommentsRedditBodyHTML(label);
    if (bodyHTML.length > 0) data[@"body_html"] = bodyHTML;
}

static void ApolloDeletedCommentsSetObjectValue(id object, SEL selector, id value) {
    if (!object || !selector || !value || ![object respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    } @catch (__unused NSException *e) {}
}

static void ApolloDeletedCommentsSetObjectBoolValue(id object, SEL selector, BOOL value) {
    if (!object || !selector || ![object respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    } @catch (__unused NSException *e) {}
}

static void ApolloDeletedCommentsSetObjectLongLongValue(id object, SEL selector, long long value) {
    if (!object || !selector || ![object respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL, long long))objc_msgSend)(object, selector, value);
    } @catch (__unused NSException *e) {}
}

BOOL ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject(id comment, NSDictionary *archived, NSString *reason) {
    if (!comment || ![archived isKindOfClass:[NSDictionary class]]) return NO;

    NSString *fullName = ApolloDeletedCommentsCommentFullName(archived);
    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    if (fullName.length == 0 || body.length == 0 || ApolloDeletedCommentsBodyLooksDeleted(body)) return NO;

    NSString *author = [archived[@"author"] isKindOfClass:[NSString class]] ? archived[@"author"] : nil;
    NSString *bodyHTML = ApolloDeletedCommentsRedditBodyHTML(body);
    NSString *resolvedReason = reason.length > 0 ? reason : ApolloDeletedCommentsReasonForArchived(archived);

    ApolloDeletedCommentsSetObjectValue(comment, @selector(setBody:), body);
    if (bodyHTML.length > 0) ApolloDeletedCommentsSetObjectValue(comment, @selector(setBodyHTML:), bodyHTML);
    if (author.length > 0) ApolloDeletedCommentsSetObjectValue(comment, @selector(setAuthor:), author);
    if ([archived[@"score"] respondsToSelector:@selector(longLongValue)]) {
        ApolloDeletedCommentsSetObjectLongLongValue(comment, @selector(setScore:), [archived[@"score"] longLongValue]);
    }

    ApolloDeletedCommentsSetObjectBoolValue(comment, @selector(setRemoved:), NO);
    ApolloDeletedCommentsSetObjectBoolValue(comment, @selector(setSpam:), NO);
    ApolloDeletedCommentsSetObjectValue(comment, @selector(setBannedBy:), @"");
    ApolloDeletedCommentsSetObjectValue(comment, @selector(setCollapsedReasonCode:), @"");

    ApolloDeletedCommentsRegisterRecoveredComment(fullName, resolvedReason);
    ApolloDeletedCommentsRegisterRecoveredBody(author, body, resolvedReason);
    return YES;
}

static void ApolloDeletedCommentsApplyNeutralVoteMetadata(NSMutableDictionary *data) {
    data[@"likes"] = [NSNull null];
    data[@"vote"] = [NSNull null];
    data[@"user_vote"] = @0;
    data[@"voted"] = @NO;
}

static void ApolloDeletedCommentsApplyRecoveredMetadata(NSMutableDictionary *data, NSString *reason) {
    NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
    NSString *author = [data[@"author"] isKindOfClass:[NSString class]] ? data[@"author"] : nil;
    NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
    data[ApolloDeletedCommentsMarkerKey] = @YES;
    data[ApolloDeletedCommentsReasonKey] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    ApolloDeletedCommentsApplyNeutralVoteMetadata(data);
    ApolloDeletedCommentsRegisterRecoveredComment(fullName, reason);
    ApolloDeletedCommentsRegisterRecoveredBody(author, body, reason);
}

static void ApolloDeletedCommentsApplyPlaceholderMetadata(NSMutableDictionary *data, NSString *reason) {
    NSString *fullName = ApolloDeletedCommentsCommentFullName(data);
    data[ApolloDeletedCommentsPlaceholderMarkerKey] = @YES;
    data[ApolloDeletedCommentsPlaceholderReasonKey] = reason.length > 0 ? reason : ApolloDeletedCommentsReasonModeratorRemoved;
    ApolloDeletedCommentsRegisterDeletedPlaceholder(fullName, reason);
}

static NSUInteger ApolloDeletedCommentsMarkDeletedPlaceholdersInJSONNode(id node) {
    if (!node) return 0;
    NSUInteger marked = 0;
    if ([node isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)node;
        NSString *kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : nil;
        NSMutableDictionary *data = [dict[@"data"] isKindOfClass:[NSMutableDictionary class]] ? dict[@"data"] : nil;
        if ([kind isEqualToString:@"t1"] && data && ApolloDeletedCommentsCommentDataLooksDeleted(data)) {
            NSString *body = [data[@"body"] isKindOfClass:[NSString class]] ? data[@"body"] : nil;
            NSString *bodyHTML = [data[@"body_html"] isKindOfClass:[NSString class]] ? data[@"body_html"] : nil;
            ApolloDeletedCommentsApplyPlaceholderMetadata(data, ApolloDeletedCommentsReasonForCurrentBody(body, bodyHTML));
            marked++;
        }
        for (id value in [dict allValues]) {
            marked += ApolloDeletedCommentsMarkDeletedPlaceholdersInJSONNode(value);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)node) {
            marked += ApolloDeletedCommentsMarkDeletedPlaceholdersInJSONNode(value);
        }
    }
    return marked;
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
    NSDictionary *storedComments = comments ?: @{};
    ApolloDeletedCommentsStoreArchivedCommentsByFullName(storedComments);
    @synchronized(ApolloDeletedCommentsArcticLock()) {
        if (!sApolloDeletedCommentsArcticCache) sApolloDeletedCommentsArcticCache = [NSMutableDictionary dictionary];
        sApolloDeletedCommentsArcticCache[linkFullName] = @{
            ApolloDeletedCommentsArcticCacheCommentsKey: storedComments,
            ApolloDeletedCommentsArcticCacheExpiryKey: [NSDate dateWithTimeIntervalSinceNow:ttl],
        };
    }
    if (storedComments.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloDeletedCommentsArcticCacheUpdatedNotification
                                                                object:nil
                                                              userInfo:@{@"linkFullName": linkFullName, @"comments": storedComments}];
        });
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

static void ApolloDeletedCommentsWarmArcticCacheForLink(NSString *linkFullName, NSString *source) {
    if (linkFullName.length == 0) return;
    if (ApolloDeletedCommentsCachedArcticComments(linkFullName) != nil) return;
    if (ApolloDeletedCommentsArcticIsCoolingDown()) return;

#ifdef APOLLO_DELETED_COMMENTS_TESTING
    (void)source;
#else
    NSString *capturedLinkFullName = [linkFullName copy];
    NSString *capturedSource = [source copy] ?: @"unknown";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ApolloLog(@"[DeletedComments] Warming Arctic cache for %@ (%@)", capturedLinkFullName, capturedSource);
        ApolloDeletedCommentsFetchArcticComments(capturedLinkFullName, ^(__unused NSDictionary<NSString *, NSDictionary *> *comments) {});
    });
#endif
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

static NSMutableDictionary *ApolloDeletedCommentsThingFromArchived(NSDictionary *archived, NSString *reason) {
    if (![archived isKindOfClass:[NSDictionary class]]) return nil;
    NSString *fullName = ApolloDeletedCommentsCommentFullName(archived);
    NSString *identifier = [archived[@"id"] isKindOfClass:[NSString class]] ? archived[@"id"] : nil;
    if (identifier.length == 0 && [fullName hasPrefix:@"t1_"]) identifier = [fullName substringFromIndex:3];

    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    if (identifier.length == 0 || body.length == 0 || ApolloDeletedCommentsBodyLooksDeleted(body)) return nil;
    if (fullName.length > 0) {
        ApolloDeletedCommentsStoreArchivedCommentsByFullName(@{fullName: archived});
    }

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
    ApolloDeletedCommentsHideRecoveredBodyForTapToReveal(data, reason);
    return [@{@"kind": @"t1", @"data": data} mutableCopy];
}

typedef struct {
    NSUInteger t1Count;
    NSUInteger deletedLookingCount;
    NSUInteger archivedMatchCount;
    NSUInteger recoverableCount;
    NSUInteger unrecoverableCount;
    NSUInteger insertedFromMoreCount;
} ApolloDeletedCommentsPatchStats;

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
                if (fullName.length > 0) {
                    ApolloDeletedCommentsStoreArchivedCommentsByFullName(@{fullName: archived});
                }
                ApolloDeletedCommentsSetRecoveredBody(data, archivedBody);
                if (author.length > 0) data[@"author"] = author;
                if ([archived[@"created_utc"] respondsToSelector:@selector(doubleValue)]) data[@"created_utc"] = archived[@"created_utc"];
                if ([archived[@"score"] respondsToSelector:@selector(integerValue)]) data[@"score"] = archived[@"score"];
                NSString *reason = ApolloDeletedCommentsReasonForCurrentBody(currentBody, currentBodyHTML);
                ApolloDeletedCommentsApplyRecoveredMetadata(data, reason);
                ApolloDeletedCommentsClearRemovalMetadata(data);
                ApolloDeletedCommentsHideRecoveredBodyForTapToReveal(data, reason);
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

static NSUInteger ApolloDeletedCommentsPatchRootWithCachedComments(id root,
                                                                   NSString *linkFullName,
                                                                   NSDictionary<NSString *, NSDictionary *> *comments) {
    if (!root || comments.count == 0) return 0;

    NSMutableSet<NSString *> *visibleNames = [NSMutableSet set];
    ApolloDeletedCommentsCollectVisibleCommentNames(root, visibleNames);
    ApolloDeletedCommentsPatchStats stats = {0};
    NSUInteger patched = ApolloDeletedCommentsPatchRedditJSONNode(root, comments, visibleNames, &stats);
    if (patched > 0) {
        ApolloLog(@"[DeletedComments] Applied cached recovery for %@ (%lu comments, visible=%lu, unrecoverable=%lu, insertedMore=%lu)",
                  linkFullName ?: @"unknown",
                  (unsigned long)patched,
                  (unsigned long)stats.recoverableCount,
                  (unsigned long)stats.unrecoverableCount,
                  (unsigned long)stats.insertedFromMoreCount);
    }
    return patched;
}

static NSData *ApolloDeletedCommentsSerializedResponseData(id root, NSData *fallbackData, NSUInteger changed) {
    if (changed == 0) return fallbackData;
    NSData *patchedData = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    return patchedData.length > 0 ? patchedData : fallbackData;
}

static NSData *__attribute__((unused)) ApolloDeletedCommentsPatchResponseImmediate(NSData *data, NSURLRequest *request) {
    NSString *linkFullName = ApolloDeletedCommentsLinkFullNameForRequest(request);
    if (!ApolloDeletedCommentsActiveForLink(linkFullName)) linkFullName = nil;
    if (linkFullName.length == 0 || data.length == 0) {
        return data;
    }

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (!root) {
        return data;
    }

    NSUInteger changed = ApolloDeletedCommentsMarkDeletedPlaceholdersInJSONNode(root);
    NSDictionary<NSString *, NSDictionary *> *cached = ApolloDeletedCommentsCachedArcticComments(linkFullName);
    if (cached.count > 0) {
        changed += ApolloDeletedCommentsPatchRootWithCachedComments(root, linkFullName, cached);
    }

    if (cached == nil && changed > 0 && !ApolloDeletedCommentsIsMoreChildrenRequest(request)) {
#ifndef APOLLO_DELETED_COMMENTS_TESTING
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            ApolloDeletedCommentsFetchArcticComments(linkFullName, ^(__unused NSDictionary<NSString *, NSDictionary *> *comments) {});
        });
#endif
    }

    return ApolloDeletedCommentsSerializedResponseData(root, data, changed);
}

static void ApolloDeletedCommentsPatchResponseAsync(NSData *data, NSURLRequest *request, void (^completion)(NSData *patchedData)) {
    NSString *linkFullName = ApolloDeletedCommentsLinkFullNameForRequest(request);
    if (!ApolloDeletedCommentsActiveForLink(linkFullName)) linkFullName = nil;
    if (linkFullName.length == 0 || data.length == 0) {
        completion(data);
        return;
    }

    id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (!root) {
        completion(data);
        return;
    }

    NSUInteger changed = ApolloDeletedCommentsMarkDeletedPlaceholdersInJSONNode(root);
    NSDictionary<NSString *, NSDictionary *> *cached = ApolloDeletedCommentsCachedArcticComments(linkFullName);
    if (cached.count > 0) {
        changed += ApolloDeletedCommentsPatchRootWithCachedComments(root, linkFullName, cached);
        completion(ApolloDeletedCommentsSerializedResponseData(root, data, changed));
        return;
    }

    BOOL shouldWaitForArctic = changed > 0 &&
                               cached == nil &&
                               !ApolloDeletedCommentsIsMoreChildrenRequest(request) &&
                               !ApolloDeletedCommentsArcticIsCoolingDown();
    if (!shouldWaitForArctic) {
        completion(ApolloDeletedCommentsSerializedResponseData(root, data, changed));
        return;
    }

#ifdef APOLLO_DELETED_COMMENTS_TESTING
    completion(ApolloDeletedCommentsSerializedResponseData(root, data, changed));
#else
    __block BOOL finished = NO;
    NSObject *finishLock = [NSObject new];

    void (^finish)(NSDictionary<NSString *, NSDictionary *> *) = ^(NSDictionary<NSString *, NSDictionary *> *comments) {
        @synchronized (finishLock) {
            if (finished) return;
            finished = YES;
        }

        NSUInteger finalChanged = changed;
        if (comments.count > 0) {
            finalChanged += ApolloDeletedCommentsPatchRootWithCachedComments(root, linkFullName, comments);
        }
        completion(ApolloDeletedCommentsSerializedResponseData(root, data, finalChanged));
    };

    ApolloDeletedCommentsFetchArcticComments(linkFullName, ^(NSDictionary<NSString *, NSDictionary *> *comments) {
        finish(comments);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ApolloDeletedCommentsInitialRecoveryWait * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        finish(nil);
    });
#endif
}

#pragma mark - CompletionFacade

ApolloDeletedCommentsURLSessionCompletion ApolloDeletedCommentsMaybeWrapCompletion(NSURLRequest *request, ApolloDeletedCommentsURLSessionCompletion completion) {
    if (!completion || !ApolloDeletedCommentsShouldTransformRequest(request)) return completion;

    if (!ApolloDeletedCommentsIsMoreChildrenRequest(request)) {
        ApolloDeletedCommentsWarmArcticCacheForLink(ApolloDeletedCommentsLinkFullNameForRequest(request), @"completion wrapper");
    }

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
        // Once a task starts buffering, keep buffering even if the gate flips
        // off mid-flight (a passive per-thread override can clear at any time,
        // e.g. when the thread is popped) — otherwise the head of the response
        // would be withheld from the original delegate and the tail delivered
        // raw, corrupting the payload. didComplete below delivers by buffer
        // presence for the same reason.
        NSMutableData *buffered = objc_getAssociatedObject(dataTask, kApolloDeletedCommentsResponseDataKey);
        BOOL shouldBuffer = buffered != nil ||
            (ApolloDeletedCommentsFeatureActive() && ApolloDeletedCommentsShouldTransformTask(dataTask));
        if (shouldBuffer && data.length > 0) {
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
        // Deliver by buffer presence, NOT by re-evaluating the gate: if the
        // per-thread override cleared while this task was in flight, the
        // buffered bytes must still reach the original delegate (the patch
        // call below no-ops for a link whose gate is off, so the payload is
        // delivered verbatim).
        NSMutableData *buffered = objc_getAssociatedObject(task, kApolloDeletedCommentsResponseDataKey);
        if (buffered) {
            objc_setAssociatedObject(task, kApolloDeletedCommentsResponseDataKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSURLRequest *request = task.originalRequest ?: task.currentRequest;
            if (buffered.length > 0) {
                if (error) {
                    deliverOriginal(session, task, buffered, error, selfObject);
                    return;
                }
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
    if (!ApolloDeletedCommentsIsMoreChildrenRequest(request)) {
        ApolloDeletedCommentsWarmArcticCacheForLink(ApolloDeletedCommentsLinkFullNameForRequest(request), @"delegate transformer");
    }
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

NSString *ApolloDeletedCommentsTestDisplayLabelForReason(NSString *reason) {
    return ApolloDeletedCommentsDisplayLabelForReason(reason);
}

NSUInteger ApolloDeletedCommentsTestMarkDeletedPlaceholdersInRoot(id root) {
    return ApolloDeletedCommentsMarkDeletedPlaceholdersInJSONNode(root);
}

NSData *ApolloDeletedCommentsTestPatchResponseImmediate(NSData *data, NSURLRequest *request) {
    return ApolloDeletedCommentsPatchResponseImmediate(data, request);
}
#endif
