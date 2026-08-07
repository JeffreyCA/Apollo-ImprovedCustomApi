#import "ApolloCommentVoteInsights.h"

#include <limits.h>
#include <math.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"

static NSString *const kApolloCommentInsightsErrorDomain = @"ApolloCommentVoteInsights";
static NSTimeInterval const kApolloCommentInsightsCacheLifetime = 120.0;
static NSString *const kApolloCommentInsightsDesktopUA =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
     @"(KHTML, like Gecko) Version/17.0 Safari/605.1.15";

@interface ApolloCommentVoteInsight ()
@property (nonatomic) double upvotePercent;
@property (nonatomic) long long reportedUpvotes;
@property (nonatomic) BOOL reportedUpvotesAreAbbreviated;
@property (nonatomic, strong) NSDate *fetchedAt;
@end

@implementation ApolloCommentVoteInsight
@end

@interface ApolloCommentInsightFailure : NSObject
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) NSDate *expiresAt;
@end

@implementation ApolloCommentInsightFailure
@end


static NSString *ApolloCommentInsightsNormalizedUsername(NSString *username) {
    return [[username ?: @"" stringByTrimmingCharactersInSet:
             NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}

static NSString *ApolloCommentInsightsNormalizedFullName(NSString *fullName) {
    NSString *value = [[fullName ?: @"" stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (![value hasPrefix:@"t1_"] || value.length <= 3 || value.length > 67) return nil;
    NSString *identifier = [value substringFromIndex:3];
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789"].invertedSet;
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound ? value : nil;
}

static ApolloWebSessionEntry *ApolloCommentInsightsSession(NSString *author) {
    NSString *active = ApolloCommentInsightsNormalizedUsername(ApolloActiveAccountUsername());
    NSString *owner = ApolloCommentInsightsNormalizedUsername(author);
    if (active.length == 0 || ![active isEqualToString:owner]) return nil;
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(active);
    return session.cookieHeader.length > 0 ? session : nil;
}

static BOOL ApolloCommentInsightsOwnerIsActive(NSString *author) {
    NSString *active = ApolloCommentInsightsNormalizedUsername(ApolloActiveAccountUsername());
    NSString *owner = ApolloCommentInsightsNormalizedUsername(author);
    return active.length > 0 && [active isEqualToString:owner];
}

static NSString *ApolloCommentInsightsCacheKey(NSString *commentID, NSString *author) {
    NSString *owner = ApolloCommentInsightsNormalizedUsername(author);
    return commentID.length > 0 && owner.length > 0
        ? [NSString stringWithFormat:@"%@|%@", owner, commentID] : nil;
}

BOOL ApolloCommentVoteInsightsEligible(NSString *fullName, NSString *author) {
    return ApolloCommentInsightsNormalizedFullName(fullName).length > 0 &&
           ApolloCommentInsightsOwnerIsActive(author);
}

static NSError *ApolloCommentInsightsError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:kApolloCommentInsightsErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: description ?: @"Reddit did not return comment insights."
    }];
}

static NSError *ApolloCommentInsightsTransportError(NSError *error) {
    if (!error) return nil;
    NSString *message = nil;
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorCannotFindHost:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorInternationalRoamingOff:
            case NSURLErrorDataNotAllowed:
                message = @"Comment Insights needs an internet connection. Check your connection and try again.";
                break;
            case NSURLErrorTimedOut:
                message = @"Reddit took too long to return Comment Insights. Try again shortly.";
                break;
            default:
                break;
        }
    }
    if (message.length == 0) return error;
    return [NSError errorWithDomain:kApolloCommentInsightsErrorDomain code:error.code userInfo:@{
        NSLocalizedDescriptionKey: message,
        NSUnderlyingErrorKey: error,
    }];
}

static long long ApolloCommentInsightsInteger(NSString *value, BOOL *outAbbreviated) {
    NSString *normalized = [[[value ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"," withString:@""];
    normalized = [[normalized stringByReplacingOccurrencesOfString:@"\u00a0" withString:@""]
        stringByReplacingOccurrencesOfString:@" " withString:@""];
    normalized = [[normalized stringByReplacingOccurrencesOfString:@"'" withString:@""]
        stringByReplacingOccurrencesOfString:@"’" withString:@""];
    double multiplier = 1.0;
    if ([normalized hasSuffix:@"k"]) multiplier = 1000.0;
    else if ([normalized hasSuffix:@"m"]) multiplier = 1000000.0;
    else if ([normalized hasSuffix:@"b"]) multiplier = 1000000000.0;
    if (multiplier != 1.0) normalized = [normalized substringToIndex:normalized.length - 1];
    if (outAbbreviated) *outAbbreviated = multiplier != 1.0;
    NSScanner *scanner = [NSScanner scannerWithString:normalized];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double parsed = 0.0;
    if (![scanner scanDouble:&parsed] || !scanner.isAtEnd) return -1;
    double result = parsed * multiplier;
    // (double)LLONG_MAX rounds up to 2^63, which llround cannot represent.
    // A strict bound avoids invoking it outside its domain on malformed markup.
    return isfinite(result) && result >= 0.0 && result < (double)LLONG_MAX ? llround(result) : -1;
}

// Restrict extraction to the server-rendered Engagement card. The surrounding
// page also contains the comment preview and assorted vote controls; scanning
// the whole document risks treating one of those accessibility labels as the
// author's insight count after a Reddit markup change.
static NSString *ApolloCommentInsightsEngagementHTML(NSString *html) {
    if (html.length == 0) return nil;
    NSRange marker = NSMakeRange(NSNotFound, 0);
    NSRange sectionStart = NSMakeRange(NSNotFound, 0);
    NSString *containerTag = nil;
    NSUInteger cursor = 0;
    while (cursor < html.length) {
        NSRange searchRange = NSMakeRange(cursor, html.length - cursor);
        marker = [html rangeOfString:@"engagement-section"
                             options:NSCaseInsensitiveSearch range:searchRange];
        if (marker.location == NSNotFound) break;
        NSRange prefix = NSMakeRange(0, marker.location);
        NSRange sectionCandidate = [html rangeOfString:@"<section"
                                               options:(NSBackwardsSearch | NSCaseInsensitiveSearch) range:prefix];
        NSRange divCandidate = [html rangeOfString:@"<div"
                                           options:(NSBackwardsSearch | NSCaseInsensitiveSearch) range:prefix];
        if (divCandidate.location != NSNotFound &&
            (sectionCandidate.location == NSNotFound || divCandidate.location > sectionCandidate.location)) {
            sectionStart = divCandidate;
            containerTag = @"div";
        } else {
            sectionStart = sectionCandidate;
            containerTag = @"section";
        }
        // Ignore marker mentions in scripts/templates far away from a real card.
        BOOL markerIsInOpeningTag = NO;
        if (sectionStart.location != NSNotFound && marker.location >= sectionStart.location) {
            NSRange openingPrefix = NSMakeRange(sectionStart.location,
                                                marker.location - sectionStart.location);
            markerIsInOpeningTag = [html rangeOfString:@">" options:0 range:openingPrefix].location
                == NSNotFound;
        }
        if (markerIsInOpeningTag && marker.location - sectionStart.location <= 10000) break;
        cursor = NSMaxRange(marker);
        sectionStart = NSMakeRange(NSNotFound, 0);
        containerTag = nil;
    }
    if (marker.location == NSNotFound) return nil;
    if (sectionStart.location == NSNotFound) return nil;
    // Balance nested <section> tags instead of stopping at the first close tag;
    // Reddit occasionally nests responsive cards inside the Engagement section.
    NSUInteger limit = MIN(html.length, sectionStart.location + 100000);
    NSUInteger scan = sectionStart.location;
    NSUInteger end = limit;
    NSInteger depth = 0;
    NSString *openToken = [@"<" stringByAppendingString:containerTag];
    NSString *closeToken = [NSString stringWithFormat:@"</%@>", containerTag];
    while (scan < limit) {
        NSRange remaining = NSMakeRange(scan, limit - scan);
        NSRange open = [html rangeOfString:openToken
                                  options:NSCaseInsensitiveSearch range:remaining];
        NSRange close = [html rangeOfString:closeToken
                                   options:NSCaseInsensitiveSearch range:remaining];
        if (close.location == NSNotFound) break;
        if (open.location != NSNotFound && open.location < close.location) {
            depth++;
            scan = NSMaxRange(open);
        } else {
            depth--;
            scan = NSMaxRange(close);
            if (depth == 0) {
                end = scan;
                break;
            }
        }
    }
    if (end <= sectionStart.location || end - sectionStart.location > 100000) return nil;
    return [html substringWithRange:NSMakeRange(sectionStart.location, end - sectionStart.location)];
}

static ApolloCommentVoteInsight *ApolloCommentInsightsParseHTML(NSString *html) {
    NSString *engagement = ApolloCommentInsightsEngagementHTML(html);
    if (engagement.length == 0) return nil;

    static NSRegularExpression *ratioRE, *ratioLeadingRE, *upvotesRE, *upvotesLeadingRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ratioRE = [NSRegularExpression regularExpressionWithPattern:
            @"aria-label\\s*=\\s*['\"]\\s*([0-9]{1,3}(?:\\.[0-9]+)?)\\s*%\\s*upvote\\s+ratio\\s*['\"]"
            options:NSRegularExpressionCaseInsensitive error:nil];
        ratioLeadingRE = [NSRegularExpression regularExpressionWithPattern:
            @"aria-label\\s*=\\s*['\"]\\s*upvote\\s+ratio\\s*:?\\s*([0-9]{1,3}(?:\\.[0-9]+)?)\\s*%\\s*['\"]"
            options:NSRegularExpressionCaseInsensitive error:nil];
        upvotesRE = [NSRegularExpression regularExpressionWithPattern:
            @"aria-label\\s*=\\s*['\"]\\s*([0-9][0-9,. '\u00a0’]*\\s*[kmb]?)\\s+upvotes?\\s*['\"]"
            options:NSRegularExpressionCaseInsensitive error:nil];
        upvotesLeadingRE = [NSRegularExpression regularExpressionWithPattern:
            @"aria-label\\s*=\\s*['\"]\\s*upvotes?\\s*:?\\s*([0-9][0-9,. '\u00a0’]*\\s*[kmb]?)\\s*['\"]"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });

    NSRange fullRange = NSMakeRange(0, engagement.length);
    double percent = -1.0;
    NSTextCheckingResult *ratioMatch = [ratioRE firstMatchInString:engagement options:0 range:fullRange];
    if (!ratioMatch) {
        ratioMatch = [ratioLeadingRE firstMatchInString:engagement options:0 range:fullRange];
    }
    if (ratioMatch && [ratioMatch rangeAtIndex:1].location != NSNotFound) {
        percent = [[engagement substringWithRange:[ratioMatch rangeAtIndex:1]] doubleValue];
        if (!isfinite(percent) || percent < 0.0 || percent > 100.0) percent = -1.0;
    }

    long long reportedUpvotes = -1;
    BOOL abbreviated = NO;
    NSTextCheckingResult *upvotesMatch = [upvotesRE firstMatchInString:engagement options:0 range:fullRange];
    if (!upvotesMatch) {
        upvotesMatch = [upvotesLeadingRE firstMatchInString:engagement options:0 range:fullRange];
    }
    if (upvotesMatch && [upvotesMatch rangeAtIndex:1].location != NSNotFound) {
        reportedUpvotes = ApolloCommentInsightsInteger(
            [engagement substringWithRange:[upvotesMatch rangeAtIndex:1]], &abbreviated);
    }
    if (percent < 0.0 && reportedUpvotes < 0) return nil;

    ApolloCommentVoteInsight *result = [ApolloCommentVoteInsight new];
    result.upvotePercent = percent;
    result.reportedUpvotes = reportedUpvotes;
    result.reportedUpvotesAreAbbreviated = abbreviated;
    result.fetchedAt = [NSDate date];
    return result;
}

#if APOLLO_SIM_BUILD
BOOL ApolloCommentVoteInsightsRunParserSelfTests(void) {
    NSString *(^page)(NSString *) = ^NSString *(NSString *fields) {
        return [NSString stringWithFormat:
            @"<shreddit-app><section data-testid='engagement-section'>%@</section></shreddit-app>",
            fields];
    };
    ApolloCommentVoteInsight *decimal = ApolloCommentInsightsParseHTML(page(
        @"<i aria-label=\"25 upvotes\"></i><i aria-label=\"87.9% upvote ratio\"></i>"));
    ApolloCommentVoteInsight *spaced = ApolloCommentInsightsParseHTML(page(
        @"<i aria-label = '1.2k upvotes'></i><i aria-label = '60 % upvote ratio'></i>"));
    ApolloCommentVoteInsight *countOnly = ApolloCommentInsightsParseHTML(page(
        @"<i aria-label='7 upvotes'></i>"));
    ApolloCommentVoteInsight *zeroRatio = ApolloCommentInsightsParseHTML(page(
        @"<i aria-label='0% upvote ratio'></i>"));
    ApolloCommentVoteInsight *leadingLabels = ApolloCommentInsightsParseHTML(page(
        @"<i aria-label='Upvotes: 42'></i><i aria-label='Upvote Ratio: 75.5%'></i>"));
    ApolloCommentVoteInsight *divCard = ApolloCommentInsightsParseHTML(
        @"<shreddit-app><div data-testid='engagement-section'><div><i aria-label='3 upvotes'></i></div>"
        @"<i aria-label='66.7% upvote ratio'></i></div></shreddit-app>");
    ApolloCommentVoteInsight *invalid = ApolloCommentInsightsParseHTML(page(
        @"<i aria-label='votes unavailable'></i>"));
    return decimal.reportedUpvotes == 25 && fabs(decimal.upvotePercent - 87.9) < 0.001 &&
           spaced.reportedUpvotes == 1200 && spaced.reportedUpvotesAreAbbreviated &&
           fabs(spaced.upvotePercent - 60.0) < 0.001 &&
           countOnly.reportedUpvotes == 7 && countOnly.upvotePercent < 0.0 &&
           zeroRatio.reportedUpvotes < 0 && zeroRatio.upvotePercent == 0.0 &&
           leadingLabels.reportedUpvotes == 42 &&
           fabs(leadingLabels.upvotePercent - 75.5) < 0.001 &&
           divCard.reportedUpvotes == 3 && fabs(divCard.upvotePercent - 66.7) < 0.001 &&
           invalid == nil;
}

// Keep parser diagnostics narrowly scoped to public, vote-related accessibility
// labels. This reveals Reddit markup variants without logging cookies, account
// state, comment text, or the full response body.
static NSString *ApolloCommentInsightsVoteLabelDiagnostics(NSString *html) {
    NSString *engagement = ApolloCommentInsightsEngagementHTML(html);
    if (engagement.length == 0) return @"none";
    static NSRegularExpression *labelRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        labelRE = [NSRegularExpression regularExpressionWithPattern:
            @"aria-label\\s*=\\s*['\"]([^'\"]{1,120})['\"]"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSRange range = NSMakeRange(0, engagement.length);
    [labelRE enumerateMatchesInString:engagement options:0 range:range
                           usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        if (!match || [match rangeAtIndex:1].location == NSNotFound) return;
        NSString *label = [engagement substringWithRange:[match rangeAtIndex:1]];
        if ([label rangeOfString:@"vote" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [labels addObject:label];
            if (labels.count >= 8) *stop = YES;
        }
    }];
    return labels.count ? [labels componentsJoinedByString:@" | "] : @"none";
}
#endif

static NSCache<NSString *, ApolloCommentVoteInsight *> *ApolloCommentInsightsCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 100;
    });
    return cache;
}

static NSCache<NSString *, ApolloCommentInsightFailure *> *ApolloCommentInsightsFailureCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 100;
    });
    return cache;
}

static NSTimeInterval ApolloCommentInsightsFailureLifetime(NSError *error) {
    if (!error || ([error.domain isEqualToString:NSURLErrorDomain] &&
                   error.code == NSURLErrorCancelled)) return 0.0;
    if ([error.domain isEqualToString:kApolloCommentInsightsErrorDomain]) {
        if (error.code == 429) return 30.0;
        if (error.code == 401 || error.code == 403) return 15.0;
        if (error.code >= 500 && error.code <= 599) return 5.0;
    }
    // Long enough for the 120ms warmup and 350ms presentation fetch to share
    // one failure, short enough that a restored connection/session retries soon.
    return 4.0;
}

static ApolloCommentVoteInsight *ApolloCommentInsightsFreshCachedInsight(NSString *cacheKey) {
    ApolloCommentVoteInsight *cached = [ApolloCommentInsightsCache() objectForKey:cacheKey];
    if (!cached) return nil;
    NSTimeInterval age = -cached.fetchedAt.timeIntervalSinceNow;
    // A partial parse is still useful, but retry it sooner in case a temporarily
    // omitted field returns on the next server render.
    NSTimeInterval lifetime = cached.upvotePercent >= 0.0 && cached.reportedUpvotes >= 0
        ? kApolloCommentInsightsCacheLifetime : 30.0;
    if (age >= 0.0 && age <= lifetime) return cached;
    [ApolloCommentInsightsCache() removeObjectForKey:cacheKey];
    return nil;
}

static NSError *ApolloCommentInsightsFreshCachedError(NSString *cacheKey) {
    ApolloCommentInsightFailure *failure = [ApolloCommentInsightsFailureCache() objectForKey:cacheKey];
    if (failure && [failure.expiresAt timeIntervalSinceNow] > 0.0) return failure.error;
    if (failure) [ApolloCommentInsightsFailureCache() removeObjectForKey:cacheKey];
    return nil;
}

static NSMutableDictionary<NSString *, NSMutableArray<void (^)(ApolloCommentVoteInsight *, NSError *)> *> *
ApolloCommentInsightsWaiters(void) {
    static NSMutableDictionary *waiters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ waiters = [NSMutableDictionary dictionary]; });
    return waiters;
}

// Badge Book's direct path uses one process-lifetime ephemeral session: cookie
// auth rides only on each request, Set-Cookie is discarded, parsing stays off
// main, and a resource timeout provides a real wall-clock cap even if Reddit
// slow-drips bytes forever.
static NSURLSession *ApolloCommentInsightsDirectSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil;
        configuration.HTTPShouldSetCookies = NO;
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 20.0;
        configuration.HTTPMaximumConnectionsPerHost = 2;
        configuration.HTTPAdditionalHeaders = @{ @"Accept-Language": @"en-US,en;q=0.9" };
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static void ApolloCommentInsightsFinish(NSString *cacheKey, ApolloCommentVoteInsight *insight,
                                        NSError *error) {
    NSArray *callbacks = nil;
    @synchronized (ApolloCommentInsightsWaiters()) {
        // Publish the result while holding the same lock used to create an
        // in-flight entry. Otherwise a caller can miss the cache between waiter
        // removal and cache insertion and launch a duplicate request.
        if (insight) {
            [ApolloCommentInsightsCache() setObject:insight forKey:cacheKey];
            [ApolloCommentInsightsFailureCache() removeObjectForKey:cacheKey];
        } else {
            NSTimeInterval lifetime = ApolloCommentInsightsFailureLifetime(error);
            if (lifetime > 0.0) {
                ApolloCommentInsightFailure *failure = [ApolloCommentInsightFailure new];
                failure.error = error;
                failure.expiresAt = [NSDate dateWithTimeIntervalSinceNow:lifetime];
                [ApolloCommentInsightsFailureCache() setObject:failure forKey:cacheKey];
            }
        }
        callbacks = [ApolloCommentInsightsWaiters()[cacheKey] copy];
        [ApolloCommentInsightsWaiters() removeObjectForKey:cacheKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^callback)(ApolloCommentVoteInsight *, NSError *) in callbacks) {
            callback(insight, error);
        }
    });
}

void ApolloFetchCommentVoteInsight(NSString *fullName, NSString *author,
                                   void (^completion)(ApolloCommentVoteInsight *, NSError *)) {
    if (!completion) return;
    NSString *commentID = ApolloCommentInsightsNormalizedFullName(fullName);
    NSString *cacheKey = ApolloCommentInsightsCacheKey(commentID, author);
    if (commentID.length == 0 || cacheKey.length == 0 ||
        !ApolloCommentInsightsOwnerIsActive(author)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, ApolloCommentInsightsError(1,
                @"Comment insights are available only for your own comments when Reddit web features are signed in."));
        });
        return;
    }

    ApolloCommentVoteInsight *cached = ApolloCommentInsightsFreshCachedInsight(cacheKey);
    if (cached) {
        ApolloLog(@"[CommentInsights][perf] %@ served from memory cache", commentID);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }
    NSError *cachedError = ApolloCommentInsightsFreshCachedError(cacheKey);
    if (cachedError) {
        ApolloLog(@"[CommentInsights][perf] %@ served recent failure", commentID);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, cachedError); });
        return;
    }

    BOOL shouldStart = NO;
    @synchronized (ApolloCommentInsightsWaiters()) {
        // Close the miss/register race with a request that completed after the
        // optimistic cache read above but before this lock was acquired.
        cached = ApolloCommentInsightsFreshCachedInsight(cacheKey);
        cachedError = cached ? nil : ApolloCommentInsightsFreshCachedError(cacheKey);
        if (!cached && !cachedError) {
            NSMutableArray *callbacks = ApolloCommentInsightsWaiters()[cacheKey];
            if (!callbacks) {
                callbacks = [NSMutableArray array];
                ApolloCommentInsightsWaiters()[cacheKey] = callbacks;
                shouldStart = YES;
            }
            [callbacks addObject:[completion copy]];
        }
    }
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached, nil); });
        return;
    }
    if (cachedError) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, cachedError); });
        return;
    }
    if (!shouldStart) {
        ApolloLog(@"[CommentInsights][perf] %@ joined in-flight request", commentID);
        return;
    }

    // Only the request owner pays the keychain read. Cache hits and callers
    // coalesced behind an in-flight request never load/copy the cookie at all.
    ApolloWebSessionEntry *webSession = ApolloCommentInsightsSession(author);
    if (webSession.cookieHeader.length == 0) {
        ApolloCommentInsightsFinish(cacheKey, nil, ApolloCommentInsightsError(1,
            @"The Reddit web session is unavailable. Sign in to Reddit web features again."));
        return;
    }

    NSString *urlString = [@"https://www.reddit.com/commentstats/" stringByAppendingString:commentID];
    NSURL *baseURL = [NSURL URLWithString:urlString];
    NSURL *URL = ApolloWebJSONProbeURL(baseURL) ?: baseURL;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    [request setValue:webSession.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:@"text/html,application/xhtml+xml" forHTTPHeaderField:@"Accept"];
    [request setValue:kApolloCommentInsightsDesktopUA forHTTPHeaderField:@"User-Agent"];

    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    ApolloLog(@"[CommentInsights] fetching %@ for signed-in author", commentID);
    [[ApolloCommentInsightsDirectSession() dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        double elapsed = CFAbsoluteTimeGetCurrent() - startedAt;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        BOOL oversized = data.length > 3 * 1024 * 1024;
        NSString *html = status >= 200 && status < 300 && data.length > 0 && !oversized
            ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!html && status >= 200 && status < 300 && data.length > 0 && !oversized) {
            html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        BOOL appShell = html.length > 0 &&
            [html rangeOfString:@"<shreddit-app" options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL engagement = html.length > 0 &&
            [html rangeOfString:@"engagement-section" options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL verification = html.length > 0 &&
            ([html rangeOfString:@"Please wait for verification"
                         options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [html rangeOfString:@"challenge-platform"
                         options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [html rangeOfString:@"cf-chl-"
                         options:NSCaseInsensitiveSearch].location != NSNotFound);
        NSURL *finalURL = response.URL;
        BOOL redirectedToLogin = [finalURL.host.lowercaseString containsString:@"accounts.reddit.com"] ||
            [finalURL.path.lowercaseString hasPrefix:@"/login"];
        ApolloCommentVoteInsight *insight = !networkError && status >= 200 && status < 300
            ? ApolloCommentInsightsParseHTML(html) : nil;
        NSError *error = ApolloCommentInsightsTransportError(networkError);
        if (!error && !ApolloCommentInsightsOwnerIsActive(author)) {
            insight = nil;
            error = ApolloCommentInsightsError(1004,
                @"The active Reddit account changed while Comment Insights was loading. Try again on the current account.");
        }
        if (!error && !insight) {
            NSString *message = nil;
            if (oversized) {
                message = @"Reddit returned an unexpectedly large Comment Insights page, so it was not processed.";
            } else if (status == 401 || status == 403 || redirectedToLogin) {
                message = @"The Reddit web session expired. Sign in to Reddit web features again.";
            } else if (status == 429) {
                message = @"Reddit is temporarily rate limiting Comment Insights. Try again shortly.";
            } else if (verification) {
                message = @"Reddit requested browser verification. Try again shortly or refresh the Reddit web session in Polls settings.";
            } else if (status >= 500) {
                message = @"Reddit's Comment Insights service is temporarily unavailable. Try again shortly.";
            } else if (status >= 200 && status < 300 && engagement) {
                message = @"Reddit returned Comment Insights, but its vote fields were not recognized. Reddit may have changed the page format.";
            } else if (status >= 200 && status < 300 && data.length == 0) {
                message = @"Reddit returned an empty Comment Insights response. Try again shortly.";
            } else if (status == 404 || status == 410) {
                message = @"Reddit does not provide Comment Insights for this comment.";
            } else {
                message = @"Reddit did not provide a usable vote breakdown for this comment.";
            }
            error = ApolloCommentInsightsError(status ?: 1003, message);
        }
        if (insight) {
            ApolloLog(@"[CommentInsights][perf] %@ %.2fs %ldKB ratio=%.1f%% upvotes=%lld",
                      commentID, elapsed, (long)data.length / 1024,
                      insight.upvotePercent, insight.reportedUpvotes);
        } else {
            ApolloLog(@"[CommentInsights] %@ failed %.2fs http=%ld err=%ld %ldKB shell=%d engagement=%d verify=%d",
                      commentID, elapsed, (long)status, (long)error.code,
                      (long)data.length / 1024, appShell, engagement, verification);
#if APOLLO_SIM_BUILD
            if (status == 200 && engagement) {
                ApolloLog(@"[CommentInsights][parser] %@ labels=%@", commentID,
                          ApolloCommentInsightsVoteLabelDiagnostics(html));
            }
#endif
        }
        ApolloCommentInsightsFinish(cacheKey, insight, error);
    }] resume];
}
