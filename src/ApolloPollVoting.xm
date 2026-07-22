#import "ApolloCommon.h"
#import "ApolloAccountCredentials.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "ApolloThemeRuntime.h"
#import "ApolloState.h"
#import "UIWindow+Apollo.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <limits.h>

#if APOLLO_SIM_BUILD
#define ApolloPollDiagnosticLog(format, ...) \
    ApolloLog(@"[PollVoting][diag]" format, ##__VA_ARGS__)
#else
#define ApolloPollDiagnosticLog(format, ...) do {} while (0)
#endif

// Master gate for the whole Polls feature (voting + creation). Backed by the
// cached sPollsFeatureEnabled global (loaded at launch, updated live by the
// Polls settings toggle) rather than an NSUserDefaults read, since the poll
// node's layoutSubviews hook calls this on a warm path.
BOOL ApolloPollsFeatureEnabled(void) {
    return sPollsFeatureEnabled;
}

// Minimal declarations avoid importing the generated class-dump header graph,
// which redeclares Foundation protocols under newer SDKs.
@class RDKPoll;
@interface RDKLink : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, readonly) NSString *fullName;
@property (nonatomic, strong) RDKPoll *poll;
@end
@interface RDKPollOption : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) long long voteCount;
@end
@interface RDKPoll : NSObject
@property (nonatomic, strong) NSArray<RDKPollOption *> *options;
@property (nonatomic) long long totalVoteCount;
@property (nonatomic, copy) NSString *userSelectionIdentifier;
- (BOOL)hasPollEnded;
@end
@interface NSObject (ApolloPollVotingRuntime)
- (void)modelObjectUpdatedNotificationReceived:(id)notification;
// Texture's UIView (AsyncDisplayKit) category: _ASDisplayView -> its node.
- (id)asyncdisplaykit_node;
- (UIView *)view;
- (void)didLoad;
- (void)setNeedsLayout;
@end

// Reddit's website uses this named same-origin mutation. Keep the private
// operation name in one place so a server-side rename fails cleanly.
static NSString *const kApolloPollVoteOperation = @"UpdatePostPollVoteState";
// v2 contained optimistic votes which could survive rejected mutations.  v3
// contains confirmed votes only and intentionally starts with a clean store.
static NSString *const kApolloPollLocalVotesKey = @"ApolloPollLocalVotes.v3";
// Apollo's original poll handler persists HasViewedFirstPoll before presenting
// its one-time explanation. Users returning from native polls may therefore
// skip straight to the legacy browser unless we restore that boundary once.
static NSString *const kApolloPollLegacyFlowRestoredKey =
    @"ApolloPollLegacyFlowRestored.v1";

static void ApolloPollPrepareOriginalFlowIfNeeded(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kApolloPollLegacyFlowRestoredKey]) return;

    // A confirmed-vote cache proves this installation actually used the
    // native feature. Do not make every long-time Apollo user re-read Apollo's
    // legacy explanation merely because native polls remain off by default.
    NSDictionary *confirmedVotes = [defaults dictionaryForKey:kApolloPollLocalVotesKey];
    if (confirmedVotes.count == 0) return;

    [defaults removeObjectForKey:@"HasViewedFirstPoll"];
    [defaults setBool:YES forKey:kApolloPollLegacyFlowRestoredKey];
    ApolloLog(@"[PollVoting] restored Apollo's original one-time poll explanation");
}

// RDKLink decoding is not confined to the main thread. Keep the small
// confirmed-vote cache synchronized and resident instead of repeatedly
// decoding the whole defaults dictionary from hot model hooks. The cache
// contains no cookie/token material, only account/post/option identifiers.
static NSObject *ApolloPollLocalVotesLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary *sApolloPollLocalVotes;

static NSMutableDictionary *ApolloPollLocalVotesLocked(void) {
    if (!sApolloPollLocalVotes) {
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
            dictionaryForKey:kApolloPollLocalVotesKey];
        sApolloPollLocalVotes = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];

        NSTimeInterval cutoff = [NSDate date].timeIntervalSince1970 - 90.0 * 24.0 * 60.0 * 60.0;
        for (NSString *savedKey in [sApolloPollLocalVotes.allKeys copy]) {
            NSDictionary *entry = [sApolloPollLocalVotes[savedKey] isKindOfClass:NSDictionary.class]
                ? sApolloPollLocalVotes[savedKey] : nil;
            NSString *option = [entry[@"option"] isKindOfClass:NSString.class] ? entry[@"option"] : nil;
            NSNumber *savedAt = [entry[@"savedAt"] isKindOfClass:NSNumber.class]
                ? entry[@"savedAt"] : nil;
            if (!entry || option.length == 0 || savedAt.doubleValue < cutoff) {
                [sApolloPollLocalVotes removeObjectForKey:savedKey];
            }
        }
    }
    return sApolloPollLocalVotes;
}

static NSString *ApolloPollCacheKey(NSString *username, NSString *postID) {
    if (username.length == 0 || postID.length == 0) return nil;
    NSString *normalizedUsername = [[username lowercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *normalizedPostID = [[postID lowercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([normalizedPostID hasPrefix:@"t3_"]) {
        normalizedPostID = [normalizedPostID substringFromIndex:3];
    }
    if (normalizedUsername.length == 0 || normalizedPostID.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", normalizedUsername, normalizedPostID];
}

static NSString *ApolloPollCanonicalBaseIDString(NSString *identifier) {
    NSString *baseID = [[identifier ?: @"" lowercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([baseID hasPrefix:@"t3_"]) baseID = [baseID substringFromIndex:3];
    if (baseID.length == 0) return nil;
    static NSRegularExpression *validID;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        validID = [NSRegularExpression regularExpressionWithPattern:@"^[a-z0-9]+$"
                                                            options:0 error:nil];
    });
    return [validID firstMatchInString:baseID options:0
                                  range:NSMakeRange(0, baseID.length)] ? baseID : nil;
}

static NSString *ApolloPollCanonicalBaseID(RDKLink *link) {
    return ApolloPollCanonicalBaseIDString(link.identifier);
}

static void ApolloPollRememberVote(NSString *username, NSString *postID, NSString *optionID) {
    NSString *key = ApolloPollCacheKey(username, postID);
    if (!key || optionID.length == 0) return;
    @synchronized (ApolloPollLocalVotesLock()) {
        NSMutableDictionary *votes = ApolloPollLocalVotesLocked();
        NSDictionary *existing = [votes[key] isKindOfClass:NSDictionary.class] ? votes[key] : nil;
        if ([existing[@"option"] isEqualToString:optionID]) return;
        if (votes.count >= 500) {
            NSArray *oldest = [votes keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"savedAt"] compare:b[@"savedAt"]];
            }];
            NSUInteger removeCount = votes.count - 499;
            for (NSUInteger i = 0; i < removeCount; i++) [votes removeObjectForKey:oldest[i]];
        }
        votes[key] = @{ @"option": optionID, @"savedAt": @([NSDate date].timeIntervalSince1970) };
        [[NSUserDefaults standardUserDefaults] setObject:[votes copy] forKey:kApolloPollLocalVotesKey];
    }
}

static void ApolloPollForgetVote(NSString *username, NSString *postID) {
    NSString *key = ApolloPollCacheKey(username, postID);
    if (!key) return;
    @synchronized (ApolloPollLocalVotesLock()) {
        NSMutableDictionary *votes = ApolloPollLocalVotesLocked();
        if (!votes[key]) return;
        [votes removeObjectForKey:key];
        [[NSUserDefaults standardUserDefaults] setObject:[votes copy] forKey:kApolloPollLocalVotesKey];
    }
}

static NSString *ApolloPollRememberedVote(NSString *username, NSString *postID) {
    NSString *key = ApolloPollCacheKey(username, postID);
    if (!key) return nil;
    @synchronized (ApolloPollLocalVotesLock()) {
        NSDictionary *entry = ApolloPollLocalVotesLocked()[key];
        NSString *option = [entry isKindOfClass:NSDictionary.class] ? entry[@"option"] : nil;
        return [option isKindOfClass:NSString.class] ? option : nil;
    }
}

static UIViewController *ApolloPollPresenter(void);
static UIViewController *ApolloPollCommentsController(void);
static id ApolloPollObjectIvar(id object, const char *name);
static UIView *ApolloPollNodeView(id node);
static void ApolloPollRenderCurrentVote(id pollNode);
static void ApolloPollScheduleAuthoritativeRefreshes(NSString *postID, NSString *username,
                                                      NSUInteger sequence);
static NSMapTable<NSString *, id> *sApolloPollHeadersByPostID;
static NSString *sApolloPollDiagnosticPostID;
static NSUInteger sApolloPollDiagnosticSequence;
static NSUInteger sApolloPollVerifiedSequence;
static double sApolloPollDiagnosticStartedMs;

static NSObject *ApolloPollDiagnosticStateLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL ApolloPollDiagnosticMatchesPostID(NSString *postID) {
    NSString *canonical = ApolloPollCanonicalBaseIDString(postID);
    if (canonical.length == 0) return NO;
    @synchronized (ApolloPollDiagnosticStateLock()) {
        return [canonical isEqualToString:sApolloPollDiagnosticPostID];
    }
}

#if APOLLO_SIM_BUILD
static double ApolloPollDiagnosticElapsedMs(void) {
    @synchronized (ApolloPollDiagnosticStateLock()) {
        return sApolloPollDiagnosticStartedMs > 0.0
            ? ApolloPerfNowMs() - sApolloPollDiagnosticStartedMs : 0.0;
    }
}

static NSString *ApolloPollPointer(id object) {
    return object ? [NSString stringWithFormat:@"%p", object] : @"nil";
}

static void ApolloPollLogPoll(NSString *stage, NSString *linkID, id linkObject, RDKPoll *poll) {
    if (!poll) {
        ApolloPollDiagnosticLog(@"[+%.1fms] %@ link=%@(%@) poll=nil",
                  ApolloPollDiagnosticElapsedMs(), stage, linkID ?: @"(nil)",
                  ApolloPollPointer(linkObject));
        return;
    }
    NSMutableArray<NSString *> *counts = [NSMutableArray arrayWithCapacity:poll.options.count];
    long long sum = 0;
    for (RDKPollOption *option in poll.options) {
        [counts addObject:[NSString stringWithFormat:@"%@=%lld(%@)",
            option.identifier ?: @"?", option.voteCount, ApolloPollPointer(option)]];
        sum += option.voteCount;
    }
    ApolloPollDiagnosticLog(@"[+%.1fms] %@ link=%@(%@) poll=%@ selection=%@ ended=%@ total=%lld sum=%lld options=%@",
              ApolloPollDiagnosticElapsedMs(), stage, linkID ?: @"(nil)",
              ApolloPollPointer(linkObject), ApolloPollPointer(poll),
              poll.userSelectionIdentifier ?: @"(nil)", poll.hasPollEnded ? @"YES" : @"NO",
              poll.totalVoteCount, sum, counts);
}

static void ApolloPollLogModel(NSString *stage, RDKLink *link) {
    ApolloPollLogPoll(stage, link.identifier, link, link.poll);
}
#else
#define ApolloPollLogPoll(...) do {} while (0)
#define ApolloPollLogModel(...) do {} while (0)
#endif

static BOOL ApolloPollHasAuthoritativeCounts(RDKPoll *poll) {
    if (!poll || poll.options.count == 0 || poll.userSelectionIdentifier.length == 0 ||
        poll.totalVoteCount <= 0) return NO;
    long long sum = 0;
    for (RDKPollOption *option in poll.options) {
        if (option.voteCount < 0 || sum > LLONG_MAX - option.voteCount) return NO;
        sum += option.voteCount;
    }
    return sum == poll.totalVoteCount;
}

// A completed comments fetch constructs an authoritative RDKLink on a worker
// queue. Hand that replacement directly to the mounted header's native section
// controller—the object that owns header reconstruction in Apollo's original
// post-Safari poll flow. Broadcasting the notification or calling the comments
// view controller misses this owner and leaves the old Swift PollNode mounted.
static void ApolloPollPublishAuthoritativeLink(RDKLink *newLink) {
    if (!newLink.identifier.length || !ApolloPollDiagnosticMatchesPostID(newLink.identifier) ||
        !ApolloPollHasAuthoritativeCounts(newLink.poll)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ApolloPollDiagnosticMatchesPostID(newLink.identifier)) return;
        NSString *remembered = ApolloPollRememberedVote(ApolloActiveAccountUsername(),
                                                         newLink.identifier);
        if (remembered.length == 0 ||
            ![remembered isEqualToString:newLink.poll.userSelectionIdentifier]) return;
        NSString *baseID = ApolloPollCanonicalBaseID(newLink);
        id header = [sApolloPollHeadersByPostID objectForKey:baseID];
        id sectionController = ApolloPollObjectIvar(header, "actionDelegate");
#if APOLLO_SIM_BUILD
        id sectionDelegate = ApolloPollObjectIvar(sectionController, "delegate");
#endif
        Class sectionClass = objc_getClass("_TtC6Apollo31CommentsHeaderSectionController");
        RDKLink *mountedLink = ApolloPollObjectIvar(sectionController, "link");
        ApolloPollDiagnosticLog(@"[+%.1fms] authoritative publish lookup post=%@ newLink=%@ header=%@ section=%@ sectionDelegate=%@ mountedLink=%@",
                  ApolloPollDiagnosticElapsedMs(), newLink.identifier,
                  ApolloPollPointer(newLink), ApolloPollPointer(header),
                  ApolloPollPointer(sectionController), ApolloPollPointer(sectionDelegate),
                  ApolloPollPointer(mountedLink));
        if (!sectionController || ![sectionController isKindOfClass:sectionClass] ||
            !mountedLink || ![ApolloPollCanonicalBaseID(mountedLink) isEqualToString:baseID]) {
            ApolloPollDiagnosticLog(@" authoritative counts arrived without matching mounted header post=%@ headerClass=%@ sectionClass=%@ mountedID=%@",
                      newLink.identifier, NSStringFromClass([header class]),
                      NSStringFromClass([sectionController class]), mountedLink.identifier);
            return;
        }
        ApolloPollLogModel(@"publishing authoritative link through header section", newLink);
        NSNotification *notification = [NSNotification
            notificationWithName:@"com.christianselig.ModelObjectUpdated"
            object:mountedLink userInfo:@{ @"newModel": newLink }];
        ((void (*)(id, SEL, id))objc_msgSend)(sectionController,
            @selector(modelObjectUpdatedNotificationReceived:), notification);
    });
}

// Apollo's original Safari poll flow refreshes the comments screen after the
// browser closes. That round trip is important for more than the checkmark:
// Reddit omits every option's vote_count from an unvoted poll, even though it
// still supplies total_vote_count. Our optimistic model therefore contains the
// total plus only the one local increment, which renders as 0%, 0%, ... 2%.
// Keep the instant optimistic transition, then hand back to Apollo's existing
// comments refresh once Reddit confirms the mutation so RDKPoll is rebuilt
// from the authoritative, now-voted response.
static BOOL ApolloPollRefreshAuthoritativeModel(NSString *postID, NSString *username) {
    NSString *activeUsername = ApolloActiveAccountUsername();
    if (username.length > 0 && (activeUsername.length == 0 ||
        [activeUsername caseInsensitiveCompare:username] != NSOrderedSame)) {
        ApolloPollDiagnosticLog(@" authoritative refresh skipped because the active account changed");
        return NO;
    }
    UIViewController *target = ApolloPollCommentsController();
    if (![target respondsToSelector:@selector(refreshControlActivatedWithSender:)]) {
#if APOLLO_SIM_BUILD
        UIViewController *presenter = ApolloPollPresenter();
        ApolloPollDiagnosticLog(@" authoritative refresh unavailable presenter=%@(%@) target=%@(%@)",
                  presenter, ApolloPollPointer(presenter), target, ApolloPollPointer(target));
#endif
        return NO;
    }
    id refreshControl = ApolloPollObjectIvar(target, "refreshControl");
    RDKLink *targetLink = ApolloPollObjectIvar(target, "link");
    NSString *expectedBaseID = ApolloPollCanonicalBaseIDString(postID);
    if (expectedBaseID.length > 0 &&
        ![ApolloPollCanonicalBaseID(targetLink) isEqualToString:expectedBaseID]) {
        ApolloPollDiagnosticLog(@" authoritative refresh skipped because the visible post changed");
        return NO;
    }
    if (!refreshControl) {
        ApolloPollDiagnosticLog(@" authoritative refresh control unavailable target=%@", target);
        return NO;
    }
    if ([refreshControl respondsToSelector:@selector(isRefreshing)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(refreshControl, @selector(isRefreshing))) {
        ApolloPollDiagnosticLog(@" authoritative refresh skipped while a native refresh is already active");
        return NO;
    }
#if APOLLO_SIM_BUILD
    id listAdapter = ApolloPollObjectIvar(target, "listAdapter");
    ApolloPollDiagnosticLog(@"[+%.1fms] requesting Apollo native post-vote refresh target=%@(%@) control=%@(%@) listAdapter=%@(%@)",
              ApolloPollDiagnosticElapsedMs(), target, ApolloPollPointer(target),
              refreshControl, ApolloPollPointer(refreshControl), listAdapter,
              ApolloPollPointer(listAdapter));
#endif
    ApolloPollLogModel(@"comments model before refresh request", targetLink);
    // Hopper: -refreshControlActivatedWithSender: retains its argument and
    // immediately enters sub_1006ff674, Apollo's real comments fetch routine.
    // The sender is otherwise irrelevant, so call the known entry point
    // directly and log it below rather than approximating UIKit target/action.
    ((void (*)(id, SEL, id))objc_msgSend)(target,
        @selector(refreshControlActivatedWithSender:), refreshControl);
    return YES;
}

@interface ApolloPollVoteRequest : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, strong) NSURLSession *URLSession;
@property (nonatomic, copy) NSString *postID;
@property (nonatomic, copy) NSString *optionID;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *csrfToken;
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic, copy) void (^completion)(BOOL success, NSString *message);
@property (nonatomic, copy) NSString *diagnosticID;
@property (nonatomic) double startedAtMs;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL mutationAccepted;
@end

static NSMutableSet<ApolloPollVoteRequest *> *sApolloPollVoteRequests;
static NSMutableSet<NSString *> *sApolloPollVotesInFlight;
static const void *kApolloPollLastTouchPointKey = &kApolloPollLastTouchPointKey;
static const void *kApolloPollHighlightedViewKey = &kApolloPollHighlightedViewKey;
static const void *kApolloPollHighlightOriginalColorKey = &kApolloPollHighlightOriginalColorKey;

static NSObject *ApolloPollInFlightLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL ApolloPollReserveInFlight(NSString *key) {
    if (key.length == 0) return NO;
    @synchronized (ApolloPollInFlightLock()) {
        if (!sApolloPollVotesInFlight) sApolloPollVotesInFlight = [NSMutableSet set];
        if ([sApolloPollVotesInFlight containsObject:key]) return NO;
        [sApolloPollVotesInFlight addObject:key];
        return YES;
    }
}

static void ApolloPollEndInFlight(NSString *key) {
    if (key.length == 0) return;
    @synchronized (ApolloPollInFlightLock()) {
        [sApolloPollVotesInFlight removeObject:key];
    }
}

static BOOL ApolloPollIsInFlight(NSString *key) {
    if (key.length == 0) return NO;
    @synchronized (ApolloPollInFlightLock()) {
        return [sApolloPollVotesInFlight containsObject:key];
    }
}

#if APOLLO_SIM_BUILD
static NSUInteger ApolloPollInFlightCount(void) {
    @synchronized (ApolloPollInFlightLock()) {
        return sApolloPollVotesInFlight.count;
    }
}
#endif

static NSDictionary<NSString *, NSString *> *ApolloPollCookiePairs(NSString *header) {
    NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
    for (NSString *component in [header componentsSeparatedByString:@";"]) {
        NSRange equals = [component rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *name = [[component substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [component substringFromIndex:equals.location + 1];
        if (name.length > 0) pairs[name] = value;
    }
    return pairs;
}

@implementation ApolloPollVoteRequest

- (void)synchronizeAuthenticatedPollThenFinish {
    // The vote mutation only returns { ok, errors }; Reddit's web client gets
    // the result bars from Shreddit's post state instead. Fetching that same
    // authenticated post is also the synchronization barrier between the vote
    // mutation and Reddit's eventually-consistent OAuth listing response.
    NSString *baseID = ApolloPollCanonicalBaseIDString(self.postID);
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] authenticated Shreddit synchronization request begin post=%@ session=%@",
              self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs, baseID,
              ApolloPollPointer(self.URLSession));
    NSString *URLString = [NSString stringWithFormat:
        @"https://www.reddit.com/comments/%@?limit=1&depth=0&sort=top", baseID ?: @""];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:URLString]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
    [request setValue:self.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"text/html,application/xhtml+xml" forHTTPHeaderField:@"Accept"];
    [[self.URLSession dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, __unused NSURLResponse *response,
                            __unused NSError *error) {
#if APOLLO_SIM_BUILD
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error) {
            ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] post-vote HTTPS sync failed post=%@ status=%ld domain=%@ code=%ld description=%@",
                      self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs, baseID,
                      (long)status, error.domain, (long)error.code, error.localizedDescription);
        } else {
            ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] post-vote HTTPS sync completed post=%@ status=%ld bytes=%lu",
                      self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs, baseID,
                      (long)status, (unsigned long)data.length);
        }
#endif
        // The mutation itself was explicitly accepted. This request is a
        // synchronization barrier, not a second success condition; bounded
        // native verification below still handles a transient fetch failure.
        [self finish:YES message:nil];
    }] resume];
}

- (void)startWithSession:(ApolloWebSessionEntry *)session {
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] request start request=%@ post=%@ option=%@ session=%@ usernamePresent=%@",
              self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
              ApolloPollPointer(self), self.postID, self.optionID,
              ApolloPollPointer(session), self.username.length ? @"YES" : @"NO");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ApolloPollVoteRequest *strongSelf = weakSelf;
        if (strongSelf && !strongSelf.finished) {
            ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] request timeout fired",
                      strongSelf.diagnosticID, ApolloPerfNowMs() - strongSelf.startedAtMs);
            [strongSelf finish:NO message:@"Reddit took too long to respond. The vote may still have been recorded; check the poll before retrying."];
        }
    });
    NSDictionary *pairs = ApolloPollCookiePairs(session.cookieHeader);
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] parsed web session cookieCount=%lu cookieNames=%@ csrfPresent=%@",
              self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
              (unsigned long)pairs.count, [pairs.allKeys sortedArrayUsingSelector:@selector(compare:)],
              [pairs[@"csrf_token"] length] ? @"YES" : @"NO");
    self.csrfToken = pairs[@"csrf_token"] ?: @"";
    self.cookieHeader = session.cookieHeader ?: @"";
    if (self.csrfToken.length == 0) {
        ApolloLog(@"[PollVoting] vote request failed stage=csrf");
        [self finish:NO message:@"The Reddit session has no CSRF token."];
        return;
    }

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 15.0;
    configuration.timeoutIntervalForResource = 20.0;
    self.URLSession = [NSURLSession sessionWithConfiguration:configuration delegate:self
                                               delegateQueue:NSOperationQueue.mainQueue];
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] isolated direct HTTPS session created session=%@; dispatching mutation immediately",
              self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
              ApolloPollPointer(self.URLSession));

    NSDictionary *input = @{ @"postId": self.postID, @"optionId": self.optionID };
    NSDictionary *body = @{ @"operation": kApolloPollVoteOperation,
                            @"variables": @{ @"input": input },
                            @"csrf_token": self.csrfToken };
    NSError *serializationError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0
                                                     error:&serializationError];
    if (!data) {
        ApolloLog(@"[PollVoting] vote request failed stage=serialization errorDomain=%@ code=%ld",
                  serializationError.domain, (long)serializationError.code);
        [self finish:NO message:@"Apollo could not prepare the poll vote."];
        return;
    }
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] GraphQL mutation dispatch operation=%@ post=%@ option=%@ jsonBytes=%lu",
              self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
              kApolloPollVoteOperation, self.postID, self.optionID, (unsigned long)data.length);
    NSMutableURLRequest *mutation = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.reddit.com/svc/shreddit/graphql"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    mutation.HTTPMethod = @"POST";
    mutation.HTTPBody = data;
    [mutation setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [mutation setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [mutation setValue:self.csrfToken forHTTPHeaderField:@"X-Csrf-Token"];
    [mutation setValue:self.cookieHeader forHTTPHeaderField:@"Cookie"];
    [mutation setValue:@"https://www.reddit.com" forHTTPHeaderField:@"Origin"];
    NSString *baseID = ApolloPollCanonicalBaseIDString(self.postID);
    [mutation setValue:[NSString stringWithFormat:@"https://www.reddit.com/comments/%@", baseID]
     forHTTPHeaderField:@"Referer"];
    [[self.URLSession dataTaskWithRequest:mutation
        completionHandler:^(NSData *responseData, NSURLResponse *URLResponse, NSError *error) {
        if (error) {
            ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] GraphQL HTTPS completion failed errorDomain=%@ errorCode=%ld description=%@",
                      self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
                      error.domain, (long)error.code, error.localizedDescription);
            [self finish:NO message:error.localizedDescription ?: @"Reddit did not return a response."];
            return;
        }
        id responseObject = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
        NSDictionary *response = [responseObject isKindOfClass:NSDictionary.class] ? responseObject : nil;
        NSInteger status = [URLResponse isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)URLResponse).statusCode : 0;
        id vote = [response valueForKeyPath:@"data.updatePostPollVoteState"];
        // Reddit currently returns { ok: true, errors: null }; older variants
        // returned a bare Boolean.  Invalid/no-op votes can still be HTTP 200,
        // so require an explicit true result rather than mere non-null data.
        BOOL mutationAccepted = NO;
        if ([vote isKindOfClass:NSNumber.class]) {
            mutationAccepted = [vote boolValue];
        } else if ([vote isKindOfClass:NSDictionary.class]) {
            id payloadErrors = vote[@"errors"];
            BOOL hasPayloadErrors = payloadErrors && payloadErrors != NSNull.null &&
                (![payloadErrors respondsToSelector:@selector(count)] || [payloadErrors count] > 0);
            id acceptedValue = vote[@"ok"];
            mutationAccepted = [acceptedValue isKindOfClass:NSNumber.class] &&
                [acceptedValue boolValue] && !hasPayloadErrors;
        }
        id topErrors = response[@"errors"];
        BOOL hasTopErrors = topErrors && topErrors != NSNull.null &&
            (![topErrors respondsToSelector:@selector(count)] || [topErrors count] > 0);
        BOOL ok = status >= 200 && status < 300 && mutationAccepted && !hasTopErrors;
        ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] GraphQL response status=%ld bodyBytes=%lu responseClass=%@ voteClass=%@ accepted=%@ topErrors=%@ overallOK=%@",
                  self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs, (long)status,
                  (unsigned long)responseData.length,
                  NSStringFromClass([response class]), NSStringFromClass([vote class]),
                  mutationAccepted ? @"YES" : @"NO", hasTopErrors ? @"YES" : @"NO",
                  ok ? @"YES" : @"NO");
        NSString *message = nil;
        if (!ok) {
            NSString *serverMessage = nil;
            if ([topErrors isKindOfClass:NSArray.class] && [topErrors count] > 0) {
                id first = [topErrors firstObject];
                if ([first isKindOfClass:NSDictionary.class] && [first[@"message"] isKindOfClass:NSString.class]) serverMessage = first[@"message"];
            }
            if (status == 429) message = @"Reddit is rate limiting votes. Wait a moment before trying again.";
            else if (status == 401) {
                ApolloWebSessionRemove(self.username);
                message = @"The Reddit web session expired. Sign in again and retry.";
            }
            else if (status == 403) {
                // A 403 can mean an ended/locked poll or a rejected action, not
                // necessarily an expired login. Do not destructively remove a
                // primary API-key-free session based on this endpoint alone.
                message = serverMessage ?: @"Reddit did not authorize this vote. Refresh the poll and try again.";
            }
            else message = serverMessage ?: (status >= 200 && status < 300
                ? @"Reddit did not confirm the poll vote."
                : [NSString stringWithFormat:@"Reddit returned HTTP %ld.", (long)status]);
            ApolloLog(@"[PollVoting] vote request failed stage=response status=%ld", (long)status);
        }
        if (ok) {
            // Race the first native current-link fetch against Reddit's web
            // consistency probe. On the common fast path the listing backend
            // already sees the accepted vote and real percentages can render
            // ~300 ms sooner. If it is still stale, the authenticated post
            // probe and verified retry schedule below remain the source of
            // truth; this speculative fetch never fabricates aggregate counts.
            NSString *confirmedBaseID = ApolloPollCanonicalBaseIDString(self.postID);
            self.mutationAccepted = YES;
            ApolloPollRememberVote(self.username, confirmedBaseID, self.optionID);
            ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] mutation accepted; racing early native authoritative fetch post=%@",
                      self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
                      confirmedBaseID);
            ApolloPollRefreshAuthoritativeModel(confirmedBaseID, self.username);
            [self synchronizeAuthenticatedPollThenFinish];
        } else {
            [self finish:NO message:message];
        }
    }] resume];
}

- (void)finish:(BOOL)success message:(NSString *)message {
    if (self.finished) {
        ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] duplicate finish ignored success=%@",
                  self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
                  success ? @"YES" : @"NO");
        return;
    }
    // Once Reddit explicitly accepted the mutation, failures in the optional
    // synchronization probe must never roll the UI/cache back to "unvoted".
    // The accepted POST is the commit point; native verified retries can still
    // recover aggregate results if the probe times out or is interrupted.
    if (self.mutationAccepted && !success) {
        success = YES;
        message = nil;
    }
    self.finished = YES;
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] request finish success=%@ messagePresent=%@ completion=%@ session=%@",
              self.diagnosticID, ApolloPerfNowMs() - self.startedAtMs,
              success ? @"YES" : @"NO", message.length ? @"YES" : @"NO",
              self.completion ? @"YES" : @"NO", ApolloPollPointer(self.URLSession));
    void (^completion)(BOOL, NSString *) = self.completion;
    self.completion = nil;
    if (completion) completion(success, message);
    [self.URLSession invalidateAndCancel];
    self.URLSession = nil;
    self.cookieHeader = nil;
    self.csrfToken = nil;
    [sApolloPollVoteRequests removeObject:self];
}

// Never allow a manually supplied Cookie header to follow an unexpected
// cross-origin redirect. Both endpoints are fixed HTTPS reddit.com URLs; a
// redirect elsewhere is either an auth/challenge flow or a server change and
// should fail closed rather than risk forwarding a live account session.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response
         newRequest:(NSURLRequest *)request
  completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSURL *URL = request.URL;
    BOOL trusted = [URL.scheme.lowercaseString isEqualToString:@"https"] &&
        [URL.host.lowercaseString isEqualToString:@"www.reddit.com"];
    if (!trusted) {
        ApolloLog(@"[PollVoting] blocked unexpected cross-origin redirect during vote request");
    }
    completionHandler(trusted ? request : nil);
}
@end

static UIViewController *ApolloPollPresenter(void) {
    NSArray<UIWindow *> *windows = ApolloAllWindows();
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) return window.visibleViewController;
    }
    return windows.firstObject.visibleViewController;
}

static UIViewController *ApolloPollCommentsController(void) {
    Class commentsClass = objc_getClass("_TtC6Apollo22CommentsViewController");
    UIViewController *target = ApolloPollPresenter();
    while (target && commentsClass && ![target isKindOfClass:commentsClass]) {
        target = target.parentViewController;
    }
    return [target isKindOfClass:commentsClass] ? target : nil;
}

static void ApolloPollShowError(UIViewController *presenter, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Vote"
        message:message ?: @"Reddit rejected the poll vote. You can still vote on reddit.com."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static id ApolloPollObjectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static long long ApolloPollIntegerIvar(id object, const char *name) {
    if (!object) return 0;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return 0;
    const char *type = ivar_getTypeEncoding(ivar);
    const uint8_t *bytes = (const uint8_t *)(__bridge const void *)object;
    if (type && (type[0] == 'q' || type[0] == 'Q')) {
        long long value = 0;
        memcpy(&value, bytes + ivar_getOffset(ivar), sizeof(value));
        return value;
    }
    if (type && (type[0] == 'i' || type[0] == 'I')) {
        int value = 0;
        memcpy(&value, bytes + ivar_getOffset(ivar), sizeof(value));
        return value;
    }
    return 0;
}

static void ApolloPollValidateResultViews(UIView *view, Class resultClass, RDKPoll *poll,
                                          NSUInteger *resultCount, BOOL *allValid) {
    id node = [view respondsToSelector:@selector(asyncdisplaykit_node)]
        ? [view asyncdisplaykit_node] : nil;
    if (node && [node isKindOfClass:resultClass]) {
        *resultCount += 1;
        RDKPollOption *option = ApolloPollObjectIvar(node, "option");
        if (!option || ApolloPollIntegerIvar(node, "totalVotesInPoll") != poll.totalVoteCount) {
            *allValid = NO;
        }
        BOOL foundMatchingOption = NO;
        for (RDKPollOption *modelOption in poll.options) {
            if ([modelOption.identifier isEqualToString:option.identifier] &&
                modelOption.voteCount == option.voteCount) {
                foundMatchingOption = YES;
                break;
            }
        }
        if (!foundMatchingOption) *allValid = NO;
    }
    for (UIView *subview in view.subviews) {
        ApolloPollValidateResultViews(subview, resultClass, poll, resultCount, allValid);
    }
}

// Verification is deliberately against the mounted result rows, not merely a
// newly decoded RDKLink. The regression was exactly that the model could be
// authoritative while the old PollResultNodes remained on screen. A refresh
// attempt is complete only when every visible row snapshots the same total and
// option count as the authoritative PollNode model.
static BOOL ApolloPollVisibleStateIsAuthoritative(NSString *postID) {
    if (!ApolloPollDiagnosticMatchesPostID(postID)) return NO;
    NSString *canonical = ApolloPollCanonicalBaseIDString(postID);
    id header = [sApolloPollHeadersByPostID objectForKey:canonical];
    id pollNode = ApolloPollObjectIvar(header, "pollNode");
    RDKPoll *poll = ApolloPollObjectIvar(pollNode, "poll");
    UIView *pollView = ApolloPollNodeView(pollNode);
    if (!pollView.window || !ApolloPollHasAuthoritativeCounts(poll)) return NO;
    NSUInteger resultCount = 0;
    BOOL allValid = YES;
    ApolloPollValidateResultViews(pollView, objc_getClass("_TtC6Apollo14PollResultNode"),
                                  poll, &resultCount, &allValid);
    return allValid && resultCount == poll.options.count && resultCount > 0;
}

static void ApolloPollScheduleAuthoritativeRefreshes(NSString *postID, NSString *username,
                                                      NSUInteger sequence) {
    // Reddit's OAuth listing can briefly trail the accepted web mutation. The
    // authenticated Shreddit fetch removes most of that race; these bounded,
    // serialized retries cover the remaining propagation window and stop as
    // soon as the actual mounted result rows carry authoritative snapshots.
    NSArray<NSNumber *> *delays = @[ @0.0, @0.8, @1.8, @3.2, @5.0 ];
    [delays enumerateObjectsUsingBlock:^(NSNumber *delay, NSUInteger attempt, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *activeUsername = ApolloActiveAccountUsername();
            if (sequence != sApolloPollDiagnosticSequence ||
                sequence == sApolloPollVerifiedSequence ||
                !ApolloPollDiagnosticMatchesPostID(postID) ||
                activeUsername.length == 0 ||
                [activeUsername caseInsensitiveCompare:username] != NSOrderedSame) return;
            if (ApolloPollVisibleStateIsAuthoritative(postID)) {
                sApolloPollVerifiedSequence = sequence;
                ApolloPollDiagnosticLog(@"[+%.1fms] automatic authoritative verification satisfied before attempt=%lu post=%@",
                          ApolloPollDiagnosticElapsedMs(), (unsigned long)(attempt + 1), postID);
                return;
            }
            ApolloPollDiagnosticLog(@"[+%.1fms] automatic authoritative refresh attempt=%lu/%lu post=%@ visibleStateStillStale=YES",
                      ApolloPollDiagnosticElapsedMs(), (unsigned long)(attempt + 1),
                      (unsigned long)delays.count, postID);
            ApolloPollRefreshAuthoritativeModel(postID, username);
        });
    }];
}

static UIView *ApolloPollNodeView(id node) {
    return [node respondsToSelector:@selector(view)] ? [node view] : nil;
}

// The PollOptionNode whose row contains `point` (in the poll view's coordinate
// space). Option rows are direct subnodes of the PollNode stack, but recurse
// one container level in case a future Apollo build wraps them.
static RDKPollOption *ApolloPollOptionAtPoint(UIView *containerView, CGPoint point, NSUInteger depth) {
    Class optionClass = objc_getClass("_TtC6Apollo14PollOptionNode");
    for (UIView *row in containerView.subviews) {
        if (!CGRectContainsPoint(row.frame, point)) continue;
        id node = [row respondsToSelector:@selector(asyncdisplaykit_node)] ? [row asyncdisplaykit_node] : nil;
        if (node && [node isKindOfClass:optionClass]) {
            return ApolloPollObjectIvar(node, "option");
        }
        if (depth > 0) {
            RDKPollOption *nested = ApolloPollOptionAtPoint(row, [containerView convertPoint:point toView:row], depth - 1);
            if (nested) return nested;
        }
    }
    return nil;
}

static UIView *ApolloPollOptionViewAtPoint(UIView *pollView, CGPoint point) {
    UIView *hit = [pollView hitTest:point withEvent:nil];
    Class optionClass = objc_getClass("_TtC6Apollo14PollOptionNode");
    while (hit && hit != pollView) {
        id node = [hit respondsToSelector:@selector(asyncdisplaykit_node)] ? [hit asyncdisplaykit_node] : nil;
        if (node && [node isKindOfClass:optionClass]) return hit;
        hit = hit.superview;
    }
    return nil;
}

static void ApolloPollClearTouchHighlight(id pollNode) {
    UIView *row = objc_getAssociatedObject(pollNode, kApolloPollHighlightedViewKey);
    id original = objc_getAssociatedObject(pollNode, kApolloPollHighlightOriginalColorKey);
    if (row) row.backgroundColor = original == NSNull.null ? nil : original;
    objc_setAssociatedObject(pollNode, kApolloPollHighlightedViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pollNode, kApolloPollHighlightOriginalColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Consume the touch point recorded by the PollNode touchesEnded hook and map
// it to the option row it landed on. Returns nil for taps outside the rows and
// for touchless activations (VoiceOver sends the control action directly).
static RDKPollOption *ApolloPollConsumeTappedOption(id pollNode) {
    NSValue *pointValue = objc_getAssociatedObject(pollNode, kApolloPollLastTouchPointKey);
    objc_setAssociatedObject(pollNode, kApolloPollLastTouchPointKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *pollView = ApolloPollNodeView(pollNode);
    if (!pointValue || !pollView) return nil;
    return ApolloPollOptionAtPoint(pollView, pointValue.CGPointValue, 1);
}

// Apollo builds the poll's "N Votes · Closes in …" title once in PollNode's
// Swift init and never refreshes it: didLoad (also the model-updated
// reconfigure path) rebuilds only the option/results rows, and
// layoutSpecThatFits: just arranges existing nodes. Without this, the count
// line keeps the pre-vote number until the post is fetched fresh. Rewrite just
// the leading count in place, keeping the string's attributes; if a future
// Apollo build changes the format, the regex misses and this no-ops.
static void ApolloPollRefreshVoteCountTitle(id pollNode) {
    RDKPoll *poll = ApolloPollObjectIvar(pollNode, "poll");
    id titleNode = ApolloPollObjectIvar(pollNode, "titleNode");
    NSAttributedString *title = [titleNode respondsToSelector:@selector(attributedText)]
        ? [titleNode attributedText] : nil;
    if (!poll || title.length == 0) return;
    static NSRegularExpression *countPattern;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        countPattern = [NSRegularExpression
            regularExpressionWithPattern:@"^[\\d.,]+[KkMm]?\\s+Votes?" options:0 error:nil];
    });
    NSTextCheckingResult *match = [countPattern firstMatchInString:title.string options:0
                                                             range:NSMakeRange(0, title.length)];
    if (!match) return;
    long long total = poll.totalVoteCount;
    NSString *replacement = [NSString stringWithFormat:@"%lld %@", total,
                             total == 1 ? @"Vote" : @"Votes"];
    NSMutableAttributedString *updated = [title mutableCopy];
    [updated replaceCharactersInRange:match.range withString:replacement];
    [titleNode setAttributedText:updated];
}

// Some Apollo/Reddit responses carry the current user's selection but omit
// aggregate counts (totalVoteCount and option voteCount are both zero). That
// combination is impossible for a displayed voted poll and produces the
// misleading "0 Votes" footer. Preserve the server-confirmed selection and
// make the local minimum internally consistent until a full aggregate arrives.
static void ApolloPollNormalizeSelectedCounts(RDKPoll *poll) {
    if (!poll || poll.userSelectionIdentifier.length == 0) return;
    RDKPollOption *selected = nil;
    for (RDKPollOption *option in poll.options) {
        if ([option.identifier isEqualToString:poll.userSelectionIdentifier]) {
            selected = option;
            break;
        }
    }
    if (!selected) return;
    if (selected.voteCount < 1) selected.voteCount = 1;
    if (poll.totalVoteCount < selected.voteCount) poll.totalVoteCount = selected.voteCount;
}

static void ApolloPollReconcilePoll(RDKPoll *poll, NSString *postID, NSString *username) {
    if (!poll || username.length == 0 || postID.length == 0) return;
    // A non-empty server selection is authoritative and refreshes our cache.
    if (poll.userSelectionIdentifier.length > 0) {
        NSString *key = ApolloPollCacheKey(username, postID);
        if (!ApolloPollIsInFlight(key)) {
            ApolloPollRememberVote(username, postID, poll.userSelectionIdentifier);
        }
        ApolloPollNormalizeSelectedCounts(poll);
        return;
    }
    NSString *remembered = ApolloPollRememberedVote(username, postID);
    if (remembered.length == 0) return;
    for (RDKPollOption *option in poll.options) {
        if ([option.identifier isEqualToString:remembered]) {
            poll.userSelectionIdentifier = remembered;
            ApolloPollNormalizeSelectedCounts(poll);
            return;
        }
    }
}

static void ApolloPollReconcileRememberedVote(RDKLink *link, NSString *username) {
    ApolloPollReconcilePoll(link.poll, link.identifier, username);
}

static void ApolloPollRenderCurrentVote(id pollNode) {
    if (!pollNode) return;
    ApolloPollNormalizeSelectedCounts(ApolloPollObjectIvar(pollNode, "poll"));
    if ([pollNode respondsToSelector:@selector(didLoad)]) {
        [pollNode didLoad];
        [pollNode setNeedsLayout];
    }
    ApolloPollRefreshVoteCountTitle(pollNode);
}

// Section controllers deliberately ignore an update whose `newModel` is the
// same object.  Publish a copy as soon as the local model changes, rather than
// waiting for Reddit's response: PollNode decides whether to build option rows
// or checked result rows at construction time, so merely changing `poll` on
// the old node cannot transition it to the voted presentation.
static void ApolloPollPublishLinkUpdate(RDKLink *link, id pollNode) {
    if (!link) return;
    RDKLink *newLink = [(id)link copy];
    if (ApolloPollDiagnosticMatchesPostID(link.identifier)) {
        ApolloPollDiagnosticLog(@"[+%.1fms] optimistic publish link=%@ copy=%@ pollNode=%@ copySame=%@",
                  ApolloPollDiagnosticElapsedMs(), ApolloPollPointer(link),
                  ApolloPollPointer(newLink), ApolloPollPointer(pollNode),
                  newLink == link ? @"YES" : @"NO");
        ApolloPollLogModel(@"optimistic publish source", link);
        ApolloPollLogModel(@"optimistic publish copy", newLink);
    }
    if (newLink) {
        if ([pollNode respondsToSelector:@selector(modelObjectUpdatedNotificationReceived:)]) {
            NSNotification *notification = [NSNotification notificationWithName:@"com.christianselig.ModelObjectUpdated"
                                                                             object:link
                                                                           userInfo:@{ @"newModel": newLink }];
            [pollNode modelObjectUpdatedNotificationReceived:notification];
            if (ApolloPollDiagnosticMatchesPostID(link.identifier)) {
                ApolloPollDiagnosticLog(@"[+%.1fms] direct PollNode model update callback returned node=%@",
                          ApolloPollDiagnosticElapsedMs(), ApolloPollPointer(pollNode));
            }
        }
        [NSNotificationCenter.defaultCenter
            postNotificationName:@"com.christianselig.ModelObjectUpdated" object:link
                        userInfo:@{ @"newModel": newLink }];
    }
    // The notification replaces feed/header cells.  This covers the currently
    // mounted node too until its section controller consumes the update.
    ApolloPollRenderCurrentVote(pollNode);
}

static void ApolloPollRollbackPoll(RDKPoll *poll, NSString *optionID) {
    if (!poll || optionID.length == 0 ||
        ![poll.userSelectionIdentifier isEqualToString:optionID]) return;
    for (RDKPollOption *candidate in poll.options) {
        if ([candidate.identifier isEqualToString:optionID]) {
            candidate.voteCount = MAX(0, candidate.voteCount - 1);
            break;
        }
    }
    poll.totalVoteCount = MAX(0, poll.totalVoteCount - 1);
    poll.userSelectionIdentifier = nil;
}

// Optimistic publication can replace and release the original RDKLink before
// the network callback. Roll back every still-reachable snapshot—the original
// model, mounted PollNode, and current header model—then rebuild the mounted
// UI from the newest link. This keeps a rejected vote from leaving a phantom
// checkmark just because a weak pre-request model disappeared.
static void ApolloPollRollbackOptimisticVote(NSString *postID, RDKLink *originalLink,
                                             id originalPollNode, NSString *optionID) {
    NSString *baseID = ApolloPollCanonicalBaseIDString(postID);
    id header = [sApolloPollHeadersByPostID objectForKey:baseID];
    RDKLink *currentLink = ApolloPollObjectIvar(header, "link");
    id currentPollNode = ApolloPollObjectIvar(header, "pollNode");
    if (![ApolloPollCanonicalBaseID(currentLink) isEqualToString:baseID]) {
        currentLink = nil;
        currentPollNode = nil;
    }

    RDKPoll *originalPoll = originalLink.poll;
    RDKPoll *originalNodePoll = ApolloPollObjectIvar(originalPollNode, "poll");
    RDKPoll *currentPoll = currentLink.poll;
    RDKPoll *currentNodePoll = ApolloPollObjectIvar(currentPollNode, "poll");
    ApolloPollRollbackPoll(originalPoll, optionID);
    if (originalNodePoll != originalPoll) ApolloPollRollbackPoll(originalNodePoll, optionID);
    if (currentPoll != originalPoll && currentPoll != originalNodePoll) {
        ApolloPollRollbackPoll(currentPoll, optionID);
    }
    if (currentNodePoll != originalPoll && currentNodePoll != originalNodePoll &&
        currentNodePoll != currentPoll) {
        ApolloPollRollbackPoll(currentNodePoll, optionID);
    }

    RDKLink *publishLink = currentLink ?: originalLink;
    id publishNode = currentPollNode ?: originalPollNode;
    if (publishLink) ApolloPollPublishLinkUpdate(publishLink, publishNode);
    else ApolloPollRenderCurrentVote(publishNode);
}

static void ApolloPollCastVote(RDKLink *link, RDKPollOption *option,
                               ApolloWebSessionEntry *session, NSString *username, id pollNode,
                               NSUInteger voteSequence, double voteStartedAtMs) {
    NSString *baseID = ApolloPollCanonicalBaseID(link);
    if (baseID.length == 0 || option.identifier.length == 0) {
        ApolloLog(@"[PollVoting] vote rejected invalid local identifiers");
        ApolloPollShowError(ApolloPollPresenter(), @"Apollo could not identify this poll post.");
        return;
    }
    // RDKLink.fullName can format missing backing fields as the non-empty
    // literal "(null)_(null)".  Never use it as a wire identifier.
    NSString *postID = [@"t3_" stringByAppendingString:baseID];
    NSString *inFlightKey = ApolloPollCacheKey(username, baseID);
    if (inFlightKey.length == 0 || !ApolloPollIsInFlight(inFlightKey)) return;

    ApolloPollVoteRequest *request = [ApolloPollVoteRequest new];
    request.postID = postID;
    request.optionID = option.identifier;
    request.username = username;
    request.startedAtMs = voteStartedAtMs;
    request.diagnosticID = [NSString stringWithFormat:@"%@-%lu", baseID,
                            (unsigned long)voteSequence];
    NSString *linkIdentifier = [baseID copy];
    __weak RDKLink *weakLink = link;
    __weak id weakPollNode = pollNode;
#if APOLLO_SIM_BUILD
    NSString *diagnosticID = request.diagnosticID;
    double requestStartedAtMs = request.startedAtMs;
#endif
    request.completion = ^(BOOL success, NSString *message) {
        ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] completion entered success=%@ weakLink=%@ weakPollNode=%@ nodeView=%@ nodeWindow=%@ inFlightBefore=%lu",
                  diagnosticID, ApolloPerfNowMs() - requestStartedAtMs,
                  success ? @"YES" : @"NO", ApolloPollPointer(weakLink),
                  ApolloPollPointer(weakPollNode), ApolloPollPointer(ApolloPollNodeView(weakPollNode)),
                  ApolloPollPointer(ApolloPollNodeView(weakPollNode).window),
                  (unsigned long)ApolloPollInFlightCount());
        ApolloPollEndInFlight(inFlightKey);
        RDKLink *strongLink = weakLink;
        ApolloPollLogModel(@"request completion weak link model", strongLink);
        if (!success) {
            ApolloPollForgetVote(username, linkIdentifier);
            ApolloPollRollbackOptimisticVote(linkIdentifier, strongLink, weakPollNode,
                                             option.identifier);
            id header = [sApolloPollHeadersByPostID objectForKey:linkIdentifier];
            RDKLink *mountedLink = ApolloPollObjectIvar(header, "link");
            id mountedPollNode = [ApolloPollCanonicalBaseID(mountedLink)
                isEqualToString:linkIdentifier] ? ApolloPollObjectIvar(header, "pollNode") : nil;
            UIView *nodeView = ApolloPollNodeView(mountedPollNode ?: weakPollNode);
            if (nodeView.window) {
                UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
                [feedback notificationOccurred:UINotificationFeedbackTypeError];
                ApolloPollShowError(ApolloPollPresenter(), message);
            }
            return;
        }
        // Cache only a mutation Reddit explicitly accepted.  This cache exists
        // to bridge Apollo's OAuth models, which sometimes omit the web
        // account's user_selection; it must never manufacture a server vote.
        ApolloPollRememberVote(username, linkIdentifier, option.identifier);
        ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] confirmed vote cached option=%@; beginning native refresh",
                  diagnosticID, ApolloPerfNowMs() - requestStartedAtMs, option.identifier);

        // Normally `finish` runs after the authenticated Shreddit post fetch
        // crosses Reddit's post-vote consistency boundary. If that optional
        // probe fails, the accepted mutation remains committed and the same
        // bounded native verification schedule takes over.
        // Do not depend on `weakLink` here: the optimistic model notification
        // intentionally replaces that RDKLink and may release it before the
        // network callback. The visible comments controller is the refresh
        // owner and remains valid independently.
        ApolloPollScheduleAuthoritativeRefreshes(linkIdentifier, username, voteSequence);
    };
    if (!sApolloPollVoteRequests) sApolloPollVoteRequests = [NSMutableSet set];
    [sApolloPollVoteRequests addObject:request];
    ApolloPollDiagnosticLog(@"[req=%@ +%.1fms] request retained activeRequests=%lu inFlight=%lu link=%@ pollNode=%@ session=%@",
              request.diagnosticID, ApolloPerfNowMs() - request.startedAtMs,
              (unsigned long)sApolloPollVoteRequests.count,
              (unsigned long)ApolloPollInFlightCount(), ApolloPollPointer(link),
              ApolloPollPointer(pollNode), ApolloPollPointer(session));
    [request startWithSession:session];
}

static void ApolloPollBeginVote(RDKLink *link, RDKPollOption *option, NSString *username, id pollNode) {
    RDKPoll *poll = link.poll;
    if (!poll || poll.userSelectionIdentifier.length > 0) return;
    NSString *baseID = ApolloPollCanonicalBaseID(link);
    if (baseID.length == 0 || option.identifier.length == 0 || option.identifier.length > 256) {
        ApolloLog(@"[PollVoting] vote rejected invalid local identifiers");
        ApolloPollShowError(ApolloPollPresenter(), @"Apollo could not identify this poll post.");
        return;
    }
    NSString *inFlightKey = ApolloPollCacheKey(username, baseID);
    // Reserve before mutating/publishing the optimistic model. RDKLink decode
    // hooks can run during that publication; without this marker they can
    // mistake the local checkmark for a server-confirmed selection and persist
    // it if the app is killed before Reddit replies.
    if (!ApolloPollReserveInFlight(inFlightKey)) return;

    NSUInteger voteSequence;
    double voteStartedAtMs = ApolloPerfNowMs();
    @synchronized (ApolloPollDiagnosticStateLock()) {
        sApolloPollDiagnosticPostID = [baseID copy];
        sApolloPollDiagnosticSequence += 1;
        sApolloPollVerifiedSequence = 0;
        sApolloPollDiagnosticStartedMs = voteStartedAtMs;
        voteSequence = sApolloPollDiagnosticSequence;
    }
    ApolloPollDiagnosticLog(@"[+0.0ms] ===== VOTE TRACE BEGIN sequence=%lu post=%@ option=%@ link=%@ poll=%@ pollNode=%@ pollView=%@ window=%@ header=%@ =====",
              (unsigned long)voteSequence, baseID,
              option.identifier, ApolloPollPointer(link), ApolloPollPointer(poll),
              ApolloPollPointer(pollNode), ApolloPollPointer(ApolloPollNodeView(pollNode)),
              ApolloPollPointer(ApolloPollNodeView(pollNode).window),
              ApolloPollPointer([sApolloPollHeadersByPostID objectForKey:baseID]));
    ApolloPollLogModel(@"tap before optimistic mutation", link);

    // Optimistic UI: selecting an option behaves like checking a control.
    // Network latency is no longer part of the interaction feedback path.
    poll.userSelectionIdentifier = option.identifier;
    option.voteCount += 1;
    poll.totalVoteCount += 1;
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    ApolloPollLogModel(@"tap after optimistic mutation before publish", link);
    ApolloPollPublishLinkUpdate(link, pollNode);

    void (^continueVote)(ApolloWebSessionEntry *) = ^(ApolloWebSessionEntry *session) {
        if (!session) {
            ApolloPollEndInFlight(inFlightKey);
            ApolloPollForgetVote(username, link.identifier);
            ApolloPollRollbackOptimisticVote(baseID, link, pollNode, option.identifier);
            if (ApolloPollNodeView(pollNode).window) {
                ApolloPollShowError(ApolloPollPresenter(), @"A Reddit web session is required to vote in polls.");
            }
            return;
        }
        ApolloPollCastVote(link, option, session, username, pollNode,
                           voteSequence, voteStartedAtMs);
    };
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(username);
    ApolloPollDiagnosticLog(@"[+%.1fms] web session lookup result=%@ session=%@",
              ApolloPollDiagnosticElapsedMs(), session ? @"found" : @"missing",
              ApolloPollPointer(session));
    if (session) { continueVote(session); return; }

    // First vote on an OAuth account: harvest a matching reddit.com cookie
    // session once, then vote silently forever after.
    ApolloWebSessionLoginViewController *login = [ApolloWebSessionLoginViewController
        loginControllerForUsername:username completion:^(BOOL success) {
            if (success) {
                continueVote(ApolloWebSessionPollFor(username));
                return;
            }
            // Cancelling the one-time cookie harvest must also cancel the
            // optimistic selection; otherwise the checked result is left on
            // screen despite no vote ever having been sent.
            ApolloPollEndInFlight(inFlightKey);
            ApolloPollForgetVote(username, link.identifier);
            ApolloPollRollbackOptimisticVote(baseID, link, pollNode, option.identifier);
        }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    UIViewController *presenter = ApolloPollPresenter();
    if (presenter) {
        [presenter presentViewController:nav animated:YES completion:nil];
    } else {
        ApolloPollEndInFlight(inFlightKey);
        ApolloPollRollbackOptimisticVote(baseID, link, pollNode, option.identifier);
    }
}

// Assistive technologies can invoke ASControlNode's action without delivering
// the touch point used to identify a row. Preserve inline voting for that path
// with an explicit accessible option list. Ordinary title/footer taps continue
// to Apollo's native action and never see this controller.
static void ApolloPollPresentAccessibilityPicker(id pollNode, RDKLink *link,
                                                 NSString *username) {
    RDKPoll *poll = link.poll;
    UIViewController *presenter = ApolloPollPresenter();
    if (!presenter || poll.options.count == 0) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Vote in Poll"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (RDKPollOption *option in poll.options) {
        if (option.text.length == 0 || option.identifier.length == 0) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:option.text
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            ApolloPollBeginVote(link, option, username, pollNode);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    UIView *sourceView = ApolloPollNodeView(pollNode) ?: presenter.view;
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

// PollNode is an ASControlNode: Apollo registers pollNodeTappedWithSender: for
// its TouchUpInside event, and taps anywhere inside the poll — option rows
// included, since plain option subnodes bubble touches up the responder chain —
// fire that action. ASControlNode sends the action synchronously from
// touchesEnded, so recording the lift point here lets the action hook below
// resolve which option row was tapped. No per-row recognizers needed.
%hook _TtC6Apollo8PollNode
- (void)layoutSubviews {
    %orig;
    if (!ApolloPollsFeatureEnabled()) return;
    if (!ApolloThemeRuntimeIsActive()) return;
    UIColor *card = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground);
    UIView *pollView = ApolloPollNodeView(self);
    if (card && pollView) pollView.backgroundColor = card;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!ApolloPollsFeatureEnabled()) { %orig; return; }
    ApolloPollClearTouchHighlight(self);
    UITouch *touch = [touches anyObject];
    UIView *pollView = ApolloPollNodeView(self);
    UIView *row = touch && pollView
        ? ApolloPollOptionViewAtPoint(pollView, [touch locationInView:pollView]) : nil;
    if (row) {
        objc_setAssociatedObject(self, kApolloPollHighlightOriginalColorKey,
            row.backgroundColor ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        row.backgroundColor = [(ApolloThemeAccentColor() ?: row.tintColor) colorWithAlphaComponent:0.16];
        // Retain until touchesEnded: its synchronous action can rebuild the
        // PollNode and release the old option views before we clear the state.
        objc_setAssociatedObject(self, kApolloPollHighlightedViewKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!ApolloPollsFeatureEnabled()) { %orig; return; }
    UITouch *touch = [touches anyObject];
    UIView *view = ApolloPollNodeView(self);
    if (touch && view) {
        CGPoint point = [touch locationInView:view];
        objc_setAssociatedObject(self, kApolloPollLastTouchPointKey,
            [NSValue valueWithCGPoint:point], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#if APOLLO_SIM_BUILD
        RDKPollOption *hitOption = ApolloPollOptionAtPoint(view, point, 1);
        ApolloPollDiagnosticLog(@" PollNode touch ended node=%@ point=%@ hitOption=%@",
                  ApolloPollPointer(self), NSStringFromCGPoint(point),
                  hitOption.identifier ?: @"none/footer");
#endif
    }
    %orig;
    ApolloPollClearTouchHighlight(self);
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    %orig;
    objc_setAssociatedObject(self, kApolloPollLastTouchPointKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloPollClearTouchHighlight(self);
}
%end

// Reconcile at the model boundary, before CommentsHeaderCellNode's Swift
// initializer snapshots link.poll into its immutable pollNode. Restoring from
// didLoad is too late: by then PollNode has already chosen optionNodes instead
// of resultsNodes, which is why the success state appeared only after a manual
// refresh created another header.
%hook RDKLink
- (void)setPoll:(RDKPoll *)poll {
#if APOLLO_SIM_BUILD
    BOOL active = ApolloPollsFeatureEnabled() &&
        ApolloPollDiagnosticMatchesPostID(self.identifier);
#else
    BOOL active = NO;
#endif
    if (active) {
        ApolloPollLogModel(@"RDKLink setPoll BEFORE", self);
        ApolloPollLogPoll(@"RDKLink setPoll incoming", self.identifier, self, poll);
    }
    %orig(poll);
    if (!ApolloPollsFeatureEnabled()) return;
    if (self.poll) ApolloPollReconcileRememberedVote(self, ApolloActiveAccountUsername());
    if (active) {
        ApolloPollLogModel(@"RDKLink setPoll AFTER reconcile", self);
    }
    ApolloPollPublishAuthoritativeLink(self);
}

- (void)setIdentifier:(NSString *)identifier {
#if APOLLO_SIM_BUILD
    BOOL active = ApolloPollsFeatureEnabled() &&
        (ApolloPollDiagnosticMatchesPostID(identifier) ||
         ApolloPollDiagnosticMatchesPostID(self.identifier));
#else
    BOOL active = NO;
#endif
    if (active) {
        ApolloPollDiagnosticLog(@"[+%.1fms] RDKLink setIdentifier BEFORE self=%@ old=%@ incoming=%@ poll=%@ thread=%@",
                  ApolloPollDiagnosticElapsedMs(), ApolloPollPointer(self), self.identifier,
                  identifier, ApolloPollPointer(self.poll), NSThread.currentThread);
        ApolloPollLogModel(@"RDKLink setIdentifier model BEFORE", self);
    }
    %orig(identifier);
    if (!ApolloPollsFeatureEnabled()) return;
    // JSON/model decoding may assign poll before identifier. Reconcile again
    // once the stable post key becomes available; the helper is idempotent.
    if (self.poll) {
        ApolloPollReconcileRememberedVote(self, ApolloActiveAccountUsername());
        if (active) ApolloPollLogModel(@"RDKLink setIdentifier AFTER reconcile", self);
        ApolloPollPublishAuthoritativeLink(self);
    }
}
%end

// The selector is implemented by CommentsHeaderCellNode (in its Apollo Swift
// extension), not CommentsHeaderSectionController. The cell's actionDelegate is
// the section controller and owns the model refresh method used after voting.
%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didLoad {
    if (!ApolloPollsFeatureEnabled()) { %orig; return; }
    // Reconcile before Apollo constructs/configures the mounted poll UI. A
    // navigation round trip creates a new RDKLink/RDKPoll, so fixing only the
    // old PollNode can never persist across that boundary.
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    ApolloPollReconcileRememberedVote(link, ApolloActiveAccountUsername());
    %orig;
    if (link.identifier.length > 0) {
        if (!sApolloPollHeadersByPostID) {
            sApolloPollHeadersByPostID = [NSMapTable strongToWeakObjectsMapTable];
        }
        NSString *baseID = ApolloPollCanonicalBaseID(link);
        if (baseID.length > 0) [sApolloPollHeadersByPostID setObject:self forKey:baseID];
    }
    id pollNode = ApolloPollObjectIvar(self, "pollNode");
    // PollNode may retain a copy made during the header's initializer rather
    // than the exact RDKPoll currently attached to link. Reconcile both sides
    // of that boundary before asking the mounted node to rebuild its rows.
    RDKPoll *nodePoll = ApolloPollObjectIvar(pollNode, "poll");
    NSString *selectionBefore = [nodePoll.userSelectionIdentifier copy];
    long long totalBefore = nodePoll.totalVoteCount;
    long long optionSumBefore = 0;
    for (RDKPollOption *option in nodePoll.options) optionSumBefore += option.voteCount;
    ApolloPollReconcilePoll(nodePoll, link.identifier, ApolloActiveAccountUsername());
    long long optionSumAfter = 0;
    for (RDKPollOption *option in nodePoll.options) optionSumAfter += option.voteCount;
    BOOL modelChanged = !((selectionBefore == nodePoll.userSelectionIdentifier) ||
                          [selectionBefore isEqualToString:nodePoll.userSelectionIdentifier]) ||
        totalBefore != nodePoll.totalVoteCount || optionSumBefore != optionSumAfter;
    // Header didLoad already loaded the PollNode once. Re-enter its model
    // configuration only when reconciliation actually changed the snapshot;
    // ordinary unvoted/authoritative polls avoid a redundant full row rebuild.
    if (modelChanged) ApolloPollRenderCurrentVote(pollNode);
}

- (void)pollNodeTappedWithSender:(id)sender {
    if (!ApolloPollsFeatureEnabled()) {
        ApolloPollPrepareOriginalFlowIfNeeded();
        %orig;
        return;
    }
    RDKLink *link = MSHookIvar<RDKLink *>(self, "link");
    RDKPoll *poll = link.poll;
    ApolloPollReconcileRememberedVote(link, ApolloActiveAccountUsername());
    if (!poll) { %orig; return; }

    id pollNode = sender;
    if (![pollNode isKindOfClass:objc_getClass("_TtC6Apollo8PollNode")]) {
        pollNode = ApolloPollObjectIvar(self, "pollNode");
    }
    RDKPollOption *option = ApolloPollConsumeTappedOption(pollNode);
    // Apollo's original action is still useful for an ended/already-voted
    // poll's native result presentation. Its legacy "open Reddit to vote"
    // modal is only reachable for an active unvoted poll, which the native
    // feature owns completely below.
    if (poll.hasPollEnded || poll.userSelectionIdentifier.length > 0) {
        %orig;
        return;
    }

    NSString *username = ApolloActiveAccountUsername();
    if (option) {
        ApolloPollDiagnosticLog(@" poll action resolved option post=%@ link=%@ pollNode=%@ option=%@(%@)",
                  link.identifier, ApolloPollPointer(link), ApolloPollPointer(pollNode),
                  option.identifier, ApolloPollPointer(option));
        if (username.length == 0) {
            ApolloPollShowError(ApolloPollPresenter(), @"Sign in to a Reddit account to vote in polls.");
            return;
        }
        ApolloPollBeginVote(link, option, username, pollNode);
    } else {
        // The whole legacy PollNode is one control, so Apollo routes taps on
        // "N Votes · Closes in …" through the same action that used to present
        // its web-voting modal. Under native polls that metadata is deliberately
        // inert. Only touchless assistive-tech activation needs an option list.
        ApolloPollDiagnosticLog(@" poll action ignored metadata/accessibility path post=%@ link=%@ pollNode=%@",
                  link.identifier, ApolloPollPointer(link), ApolloPollPointer(pollNode));
        if (UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning()) {
            if (username.length > 0) {
                ApolloPollPresentAccessibilityPicker(pollNode, link, username);
            } else {
                ApolloPollShowError(ApolloPollPresenter(), @"Sign in to a Reddit account to vote in polls.");
            }
        }
    }
}
%end

%ctor {}
