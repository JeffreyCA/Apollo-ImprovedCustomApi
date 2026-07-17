//
//  ApolloAISummary.xm
//  Apollo-Reborn
//
//  On-device AI summaries (Apple FoundationModels): a post summary at the
//  bottom of the post and a comment summary at the top of the comment list,
//  generated automatically when a post's comments open. Gated by the
//  `sEnableAISummaries` settings toggle (off by default) and only active when
//  the on-device model reports available.
//
//  The Swift-only FoundationModels API is reached through the
//  `ApolloFoundationModels` @objc bridge (ApolloFoundationModels.swift). We
//  resolve it via NSClassFromString so there is no link-time dependency on the
//  Swift-generated interop header.
//
//  The summaries are inserted into CommentsHeaderCellNode's layout. The post
//  summary follows Apollo's original post header content; the discussion
//  summary follows it, immediately before the first comment row.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloAISummary.h"
#import "ApolloThemeRuntime.h"
#import "ApolloState.h"
#import "Tweak.h"

#pragma mark - Texture declarations

typedef NS_ENUM(unsigned char, ApolloAIStackDirection) {
    ApolloAIStackDirectionHorizontal = 0,
    ApolloAIStackDirectionVertical = 1,
};

typedef NS_ENUM(unsigned char, ApolloAIStackJustifyContent) {
    ApolloAIStackJustifyContentStart = 0,
};

typedef NS_ENUM(unsigned char, ApolloAIStackAlignItems) {
    ApolloAIStackAlignItemsStart = 0,
    ApolloAIStackAlignItemsStretch = 3,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASInsetLayoutSpec;
@class ASBackgroundLayoutSpec;
@class ASDisplayNode;
@class ASTextNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)setNeedsLayout;
- (void)invalidateCalculatedLayout;
- (UIView *)view;
- (void)onDidLoad:(void (^)(__kindof ASDisplayNode *node))body;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat borderWidth;
@property (nullable, nonatomic) CGColorRef borderColor;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@end

@interface ASLayoutSpec : NSObject
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloAIStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloAIStackJustifyContent justifyContent;
@property (nonatomic) ApolloAIStackAlignItems alignItems;
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) NSUInteger alignContent;
@property (nonatomic) CGFloat lineSpacing;
@property (nullable, nonatomic) NSArray *children;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloAIStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloAIStackJustifyContent)justifyContent
                                  alignItems:(ApolloAIStackAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
@property (nonatomic) UIEdgeInsets insets;
@property (nullable, nonatomic) id child;
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASBackgroundLayoutSpec : ASLayoutSpec
+ (instancetype)backgroundLayoutSpecWithChild:(id)child background:(id)background;
@end

// ASSizeRange as emitted by Apollo's class-dumped headers.
struct ApolloAISizeRange { CGSize min; CGSize max; };

#pragma mark - FoundationModels bridge (declared, resolved at runtime)

// Mirrors the @objc surface of ApolloFoundationModels.swift. We never reference
// the class symbol directly (only via NSClassFromString), so this is a pure
// type declaration for clean message sends.
@interface ApolloFoundationModels : NSObject
+ (instancetype)shared;
- (NSInteger)availabilityStatus;
- (BOOL)isModelAvailable;
- (void)prepareSession:(NSString *)identifier instructions:(NSString *)instructions;
- (void)discardPreparedSession:(NSString *)identifier;
- (void)cancelRequest:(NSString *)identifier;
- (void)summarize:(NSString *)text
       identifier:(NSString *)identifier
     instructions:(NSString *)instructions
maximumResponseTokens:(NSInteger)maximumResponseTokens
        onPartial:(void (^)(NSString *partial))onPartial
       onComplete:(void (^)(NSString *final, NSError *error))onComplete;
@end

static ApolloFoundationModels *ApolloAIBridge(void) {
    Class cls = NSClassFromString(@"ApolloFoundationModels");
    if (!cls) return nil;
    return [cls shared];
}

#pragma mark - Tuning

// Keep prompts well within the on-device model's context window.
static const NSUInteger kApolloAIMaxPostChars = 1400;
// Below this many words a post body isn't worth summarizing: the generated
// summary (capped at kApolloAIPostResponseTokens, ~60 words) would be nearly as
// long as the post itself, defeating the purpose. Gating well above the summary
// length means a post summary is only offered when it actually condenses the
// post (~200 words -> roughly a third the length). Short posts and boilerplate
// megathreads get no card at all.
static const NSUInteger kApolloAIMinPostWords = 200;
static const NSUInteger kApolloAIMinComments = 5;
static const NSUInteger kApolloAIMinCommentChars = 500;
// The discussion summary is generated ONCE per page open, so we can afford to
// feed it a richer representative set for a better consensus on large threads.
// These caps stay well inside the on-device model's context window (~4k tokens);
// the comments are ranked first (score / OP / controversiality / depth) and the
// top ones up to these caps are used, so big threads still distil to a consensus.
static const NSUInteger kApolloAIMaxCommentChars = 3000;
static const NSUInteger kApolloAIMaxComments = 16;
static const NSUInteger kApolloAIMaxSingleCommentChars = 300;
static const NSInteger kApolloAIPostResponseTokens = 80;
// A touch more room than the post summary: the discussion has more ground to
// cover (consensus + a dissent), and 80 tokens was clipping the last sentence.
static const NSInteger kApolloAICommentResponseTokens = 110;
// The iOS Simulator runs FoundationModels on the CPU/GPU *without* the Neural
// Engine, so on-device generation is several times slower than real hardware —
// a busy thread (big post body + a dozen comments, post and discussion racing
// for the same model) can take 30s+ and would spuriously "time out" in the sim
// even though the identical request finishes in a few seconds on a device. Give
// the sim generous headroom; keep the device timeout tight, since a request that
// genuinely takes 30s on hardware is stuck, not slow.
#if APOLLO_SIM_BUILD
static const NSTimeInterval kApolloAIGenerationTimeout = 90.0;
#else
static const NSTimeInterval kApolloAIGenerationTimeout = 30.0;
#endif
// Bumped to 3 for the cache-entry timestamp format (age-based expiry). Older
// caches lack timestamps and are simply dropped on first launch (regenerable).
static NSString *const kApolloAICacheVersion = @"3";

static NSString *const kApolloAIPostInstructions =
    @"Summarize this Reddit post in 2 short plain sentences. State the main point "
    @"and what the poster asks, claims, or shares. No heading, Markdown, or added facts.";

static NSString *const kApolloAICommentInstructions =
    @"Summarize these Reddit comments in 2-3 short plain sentences. Cover the "
    @"consensus, useful details, and one notable disagreement if present. "
    @"Summarize commenters, not the post. No heading, Markdown, or added facts.";

// Link/article summaries: for an external-article link post we fetch the linked
// page, extract its readable prose, and summarize it in the post box (titled
// "Link summary"). Article prose is larger than a Reddit post, so it gets its own
// input cap and a touch more output room; still well inside the model's window.
static const NSUInteger kApolloAIMaxArticleChars = 3000;
static const NSInteger kApolloAIArticleResponseTokens = 110;
static const NSUInteger kApolloAIArticleFetchMaxBytes = 3 * 1024 * 1024;  // ignore huge pages
static const NSTimeInterval kApolloAIArticleFetchTimeout = 15.0;

static NSString *const kApolloAIArticleInstructions =
    @"Summarize this linked news article in 2-3 short plain sentences. State the "
    @"main topic and the key facts or points it reports. Summarize the article "
    @"itself, not website navigation or ads. No heading, Markdown, or added facts.";

// When a post has BOTH body text AND a linked article, summarize them together.
static const NSInteger kApolloAIBothResponseTokens = 150;
static NSString *const kApolloAIBothInstructions =
    @"You are given a Reddit post and the article it links to. Summarize BOTH "
    @"together in 3-4 short plain sentences: the post's point and the article's "
    @"key facts. No heading, Markdown, or added facts.";

#pragma mark - Per-session caches / in-flight guard

// fullName -> generated summary text. Survives re-opening the same thread.
static NSMutableDictionary<NSString *, NSString *> *sPostSummaryCache;
static NSMutableDictionary<NSString *, NSString *> *sCommentSummaryCache;
// fullName -> unix time (seconds) the post/comment summary was last generated.
// Drives age-based cache expiry so old (and stale-discussion) summaries are
// dropped rather than kept forever. One stamp per thread (refreshed when either
// of its summaries is regenerated).
static NSMutableDictionary<NSString *, NSNumber *> *sSummaryTimestamps;
// "post|fullName" / "comment|fullName" -> @(expanded). Remembers the open/closed
// state the user left each summary card in, so reopening a thread restores it
// rather than resetting to collapsed. In-memory (per app session); the cached
// summary itself persists to disk, the lightweight UI state does not.
static NSMutableDictionary<NSString *, NSNumber *> *sCardExpanded;
// Link/article summaries reuse the post box. sLinkSummaryPosts marks which posts
// are currently showing a LINK summary (vs a self-text post summary) so the title
// and layout position differ. sArticleTextCache memoises fetched+extracted
// article text per post for the session, so a concurrency retry doesn't re-fetch.
static NSMutableSet<NSString *> *sLinkSummaryPosts;
static NSMutableSet<NSString *> *sBothSummaryPosts;   // post box shows a combined post+article summary
// fullName -> the mode the CACHED post summary was generated under. Persisted so a
// cached summary is never reused under a different mode — e.g. a post-only summary
// must not be shown once the post is later detected as "both". Old caches lacking
// this default to Post(0); a Link/Both post then mismatches and regenerates.
typedef NS_ENUM(NSInteger, ApolloAIPostMode) {
    ApolloAIPostModePost = 0,   // self-text post summary
    ApolloAIPostModeLink = 1,   // external article only
    ApolloAIPostModeBoth = 2,   // post body + article
};
static NSMutableDictionary<NSString *, NSNumber *> *sPostSummaryMode;
static NSMutableDictionary<NSString *, NSString *> *sArticleTextCache;
static NSMutableDictionary<NSString *, NSNumber *> *sCommentSummarySourceCounts;
static NSMutableDictionary<NSString *, NSString *> *sCommentSummarySignatures;
// fullNames whose post / comment generation is currently running, so we don't
// kick off duplicate concurrent requests for the same thread.
static NSMutableSet<NSString *> *sPostInFlight;
static NSMutableSet<NSString *> *sCommentInFlight;
static NSMutableDictionary<NSString *, NSString *> *sPostRequestIDs;
static NSMutableDictionary<NSString *, NSString *> *sCommentRequestIDs;
// Header nodes are weak: they are only retained by Apollo/Texture while their
// rows exist. Generated text is applied to every live header for the same post.
static NSHashTable *sHeaderNodes;
static NSMapTable<NSString *, UIViewController *> *sControllerByFullName;
// Comments captured from CommentCellNode lifecycle hooks, keyed by post. This
// includes rows Texture creates below the fold and is more reliable than
// asking ASTableNode for nodes that have not yet entered its visible cache.
static NSMutableDictionary<NSString *, NSMutableArray *> *sCapturedComments;
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *sCapturedCommentKeys;
static __weak UIViewController *sVisibleCommentsController;
static NSMutableDictionary<NSString *, NSNumber *> *sLastPartialUIUpdate;
static NSMutableSet<NSString *> *sCommentGenerationScheduled;
// fullNames whose post / comment generation hit a hard error this session. We
// stop retrying them (the box shows the error) so the layout doesn't flicker
// loading<->error as the retry schedule and comment captures re-fire.
static NSMutableSet<NSString *> *sPostFailed;
static NSMutableSet<NSString *> *sCommentFailed;
// fullNames whose link/article post box is currently HIDDEN — the page had no
// usable prose to summarize (score-card / SPA / paywall stub), or the model
// couldn't summarize the little there was. Distinct from sPostFailed: a
// suppressed post shows NO box at all (not an error triangle), and we don't
// re-fetch it while it's on screen. Keeping it separate is essential — folding
// it into sPostFailed makes ApolloAIRestoreStateForHeader flip the hidden box
// back to the error triangle every time a header recycles. Like sPostFailed,
// it is cleared in viewDidDisappear, so each reopen gets a fresh attempt
// (a content-less page just re-hides; a transient failure recovers).
static NSMutableSet<NSString *> *sPostSuppressed;
// fullNames whose link/article post box shows a terminal "Nothing to summarize"
// card. The Tap-to-Summarize counterpart of sPostSuppressed: when the user
// explicitly TAPS an idle link card and the page turns out to have no usable
// prose, vanishing reads as a glitch, so we keep the card and say so instead of
// hiding it. (Automatic mode still uses sPostSuppressed and hides silently — the
// card was never requested there.) Like sPostSuppressed it is per-view and
// cleared in viewDidDisappear, so a reopen offers a fresh "Tap to summarize".
static NSMutableSet<NSString *> *sPostEmpty;
static NSMutableSet<NSString *> *sTimedOutRequests;
// "post|fullName" / "comment|fullName" keys for boxes the user TAPPED to generate
// while Tap-to-Summarize is on. The generation pass consumes the marker and
// proceeds instead of showing the idle "Tap to summarize" prompt.
static NSMutableSet<NSString *> *sTapRequested;

#pragma mark - Disk persistence (summaries survive app relaunches)

// Completed summaries are tiny strings keyed by Reddit fullName, so we persist
// them to a single plist and reload on launch — reopening a thread you have
// already summarized is then instant and costs no model time. The file lives in
// Caches (regenerable; the OS may purge it under storage pressure, which simply
// means those threads re-summarize once).
static const NSUInteger kApolloAIPersistMaxEntries = 600;
// Cached summaries older than this are dropped on launch. A discussion summary
// goes stale as a thread keeps getting replies, and a forever-cache only grows;
// a week keeps "reopen a thread I read recently" instant while bounding both.
// (Manual "Clear AI Cache" in settings still wipes everything immediately.)
static const NSTimeInterval kApolloAICacheMaxAge = 7 * 24 * 60 * 60;  // 7 days

static NSString *ApolloAISummariesCachePath(void) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    if (caches.length == 0) caches = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    return [caches stringByAppendingPathComponent:@"ApolloAISummaries.plist"];
}

static dispatch_queue_t ApolloAIPersistQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apollo-reborn.aisummary.persist", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Stamp a thread as freshly summarized (for age-based expiry). Called wherever a
// post or comment summary is written into the in-memory cache.
static void ApolloAIStampSummary(NSString *fullName) {
    if (fullName.length == 0 || !sSummaryTimestamps) return;
    sSummaryTimestamps[fullName] = @([[NSDate date] timeIntervalSince1970]);
}

// Remember / recall the open-closed state the user left a card in, so reopening a
// thread restores it. Keyed per thread and per card type (post vs comment).
static NSString *ApolloAICardExpandedKey(NSString *fullName, BOOL isPost) {
    if (fullName.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%@", isPost ? @"post" : @"comment", fullName];
}

static void ApolloAIRememberCardExpanded(NSString *fullName, BOOL isPost, BOOL expanded) {
    NSString *key = ApolloAICardExpandedKey(fullName, isPost);
    if (key && sCardExpanded) sCardExpanded[key] = @(expanded);
}

// @(YES)/@(NO) if the user has a remembered choice for this card, else nil.
static NSNumber *ApolloAIRememberedCardExpanded(NSString *fullName, BOOL isPost) {
    NSString *key = ApolloAICardExpandedKey(fullName, isPost);
    return (key && sCardExpanded) ? sCardExpanded[key] : nil;
}

// Drop in-memory cache entries whose summary is older than kApolloAICacheMaxAge
// (or has no timestamp). Operates on the live dictionaries; run once after load.
static void ApolloAIPruneExpiredSummaries(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableSet<NSString *> *names = [NSMutableSet setWithArray:sPostSummaryCache.allKeys];
    [names addObjectsFromArray:sCommentSummaryCache.allKeys];
    NSUInteger pruned = 0;
    for (NSString *name in names) {
        NSNumber *ts = sSummaryTimestamps[name];
        if (ts && (now - ts.doubleValue) <= kApolloAICacheMaxAge) continue;
        [sPostSummaryCache removeObjectForKey:name];
        [sCommentSummaryCache removeObjectForKey:name];
        [sPostSummaryMode removeObjectForKey:name];
        [sCommentSummarySourceCounts removeObjectForKey:name];
        [sCommentSummarySignatures removeObjectForKey:name];
        [sSummaryTimestamps removeObjectForKey:name];
        // Drop the per-thread side state for the same thread so these maps don't
        // accumulate stale entries for summaries that no longer exist:
        // sArticleTextCache (bare fullName, kilobytes each) and the remembered
        // card open/closed state (prefixed keys).
        [sArticleTextCache removeObjectForKey:name];
        [sCardExpanded removeObjectForKey:[@"post|" stringByAppendingString:name]];
        [sCardExpanded removeObjectForKey:[@"comment|" stringByAppendingString:name]];
        pruned++;
    }
    if (pruned > 0) {
        ApolloLog(@"[AISummary] pruned %lu summaries older than %.0f days",
                  (unsigned long)pruned, kApolloAICacheMaxAge / 86400.0);
    }
}

// Drop the oldest entries (by sSummaryTimestamps; missing = oldest) from `cache`
// until it is within `cap`. Replaces arbitrary allKeys.firstObject eviction.
static void ApolloAIEvictOldestEntries(NSMutableDictionary *cache, NSDictionary *timestamps, NSUInteger cap) {
    if (cache.count <= cap) return;
    NSArray<NSString *> *oldestFirst = [cache.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double ta = [timestamps[a] doubleValue], tb = [timestamps[b] doubleValue];
        if (ta < tb) return NSOrderedAscending;
        if (ta > tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSUInteger toRemove = cache.count - cap;
    for (NSUInteger i = 0; i < toRemove && i < oldestFirst.count; i++) {
        [cache removeObjectForKey:oldestFirst[i]];
    }
}

// Reads the persisted summaries into the in-memory caches. Caller must hold the
// once-guard (we only ever populate these dictionaries on the main thread).
static void ApolloAILoadPersistedSummaries(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:ApolloAISummariesCachePath()];
    if (![root isKindOfClass:[NSDictionary class]]) return;
    if (![root[@"version"] isEqualToString:kApolloAICacheVersion]) {
        ApolloLog(@"[AISummary] ignoring stale summary cache version %@", root[@"version"] ?: @"(none)");
        return;
    }
    NSDictionary *post = root[@"post"];
    NSDictionary *comment = root[@"comment"];
    NSDictionary *sourceCounts = root[@"commentSourceCounts"];
    NSDictionary *signatures = root[@"commentSignatures"];
    NSDictionary *postModes = root[@"postModes"];
    NSDictionary *timestamps = root[@"timestamps"];
    if ([post isKindOfClass:[NSDictionary class]]) [sPostSummaryCache addEntriesFromDictionary:post];
    if ([comment isKindOfClass:[NSDictionary class]]) [sCommentSummaryCache addEntriesFromDictionary:comment];
    if ([postModes isKindOfClass:[NSDictionary class]]) [sPostSummaryMode addEntriesFromDictionary:postModes];
    if ([sourceCounts isKindOfClass:[NSDictionary class]]) [sCommentSummarySourceCounts addEntriesFromDictionary:sourceCounts];
    if ([signatures isKindOfClass:[NSDictionary class]]) [sCommentSummarySignatures addEntriesFromDictionary:signatures];
    if ([timestamps isKindOfClass:[NSDictionary class]]) [sSummaryTimestamps addEntriesFromDictionary:timestamps];
    // Drop anything past its expiry before it's ever shown.
    ApolloAIPruneExpiredSummaries();
    ApolloLog(@"[AISummary] loaded %lu post / %lu comment summaries from disk",
              (unsigned long)sPostSummaryCache.count, (unsigned long)sCommentSummaryCache.count);
}

// Snapshots the caches on the main thread and writes them off-thread. Cheap to
// call after each completed summary (a thread completes at most twice).
static void ApolloAIPersistSummaries(void) {
    NSDictionary *postSnapshot = [sPostSummaryCache copy];
    NSDictionary *commentSnapshot = [sCommentSummaryCache copy];
    NSDictionary *sourceCountSnapshot = [sCommentSummarySourceCounts copy];
    NSDictionary *signatureSnapshot = [sCommentSummarySignatures copy];
    NSDictionary *postModeSnapshot = [sPostSummaryMode copy];
    NSDictionary *timestampSnapshot = [sSummaryTimestamps copy];
    dispatch_async(ApolloAIPersistQueue(), ^{
        NSMutableDictionary *post = [postSnapshot mutableCopy];
        NSMutableDictionary *comment = [commentSnapshot mutableCopy];
        NSMutableDictionary *timestamps = [timestampSnapshot mutableCopy];
        // Bound pathological growth, dropping the OLDEST summaries first (summaries
        // are ~a few hundred bytes each).
        ApolloAIEvictOldestEntries(post, timestamps, kApolloAIPersistMaxEntries);
        ApolloAIEvictOldestEntries(comment, timestamps, kApolloAIPersistMaxEntries);
        // Don't persist timestamps for threads no longer in either cache.
        NSMutableSet<NSString *> *live = [NSMutableSet setWithArray:post.allKeys];
        [live addObjectsFromArray:comment.allKeys];
        for (NSString *k in timestamps.allKeys) {
            if (![live containsObject:k]) [timestamps removeObjectForKey:k];
        }
        NSDictionary *root = @{
            @"version": kApolloAICacheVersion,
            @"post": post,
            @"comment": comment,
            @"commentSourceCounts": sourceCountSnapshot,
            @"commentSignatures": signatureSnapshot,
            @"postModes": postModeSnapshot ?: @{},
            @"timestamps": timestamps,
        };
        [root writeToFile:ApolloAISummariesCachePath() atomically:YES];
    });
}

static void ApolloAIEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sPostSummaryCache = [NSMutableDictionary dictionary];
        sCommentSummaryCache = [NSMutableDictionary dictionary];
        sSummaryTimestamps = [NSMutableDictionary dictionary];
        sCardExpanded = [NSMutableDictionary dictionary];
        sLinkSummaryPosts = [NSMutableSet set];
        sBothSummaryPosts = [NSMutableSet set];
        sPostSummaryMode = [NSMutableDictionary dictionary];
        sArticleTextCache = [NSMutableDictionary dictionary];
        sCommentSummarySourceCounts = [NSMutableDictionary dictionary];
        sCommentSummarySignatures = [NSMutableDictionary dictionary];
        sPostInFlight = [NSMutableSet set];
        sCommentInFlight = [NSMutableSet set];
        sPostRequestIDs = [NSMutableDictionary dictionary];
        sCommentRequestIDs = [NSMutableDictionary dictionary];
        sHeaderNodes = [NSHashTable weakObjectsHashTable];
        sControllerByFullName = [NSMapTable strongToWeakObjectsMapTable];
        sCapturedComments = [NSMutableDictionary dictionary];
        sCapturedCommentKeys = [NSMutableDictionary dictionary];
        sLastPartialUIUpdate = [NSMutableDictionary dictionary];
        sCommentGenerationScheduled = [NSMutableSet set];
        sPostFailed = [NSMutableSet set];
        sCommentFailed = [NSMutableSet set];
        sPostSuppressed = [NSMutableSet set];
        sPostEmpty = [NSMutableSet set];
        sTimedOutRequests = [NSMutableSet set];
        sTapRequested = [NSMutableSet set];
        ApolloAILoadPersistedSummaries();
    });
}

NSUInteger ApolloAIClearSummaryCache(void) {
    ApolloAIEnsureState();

    NSUInteger removed = sPostSummaryCache.count + sCommentSummaryCache.count;
    ApolloFoundationModels *bridge = ApolloAIBridge();
    for (NSString *requestID in sPostRequestIDs.allValues) {
        [bridge cancelRequest:requestID];
    }
    for (NSString *requestID in sCommentRequestIDs.allValues) {
        [bridge cancelRequest:requestID];
    }

    [sPostSummaryCache removeAllObjects];
    [sCommentSummaryCache removeAllObjects];
    [sSummaryTimestamps removeAllObjects];
    [sCardExpanded removeAllObjects];
    [sPostSummaryMode removeAllObjects];
    [sArticleTextCache removeAllObjects];
    [sCommentSummarySourceCounts removeAllObjects];
    [sCommentSummarySignatures removeAllObjects];
    [sCapturedComments removeAllObjects];
    [sCapturedCommentKeys removeAllObjects];
    [sPostInFlight removeAllObjects];
    [sCommentInFlight removeAllObjects];
    [sPostRequestIDs removeAllObjects];
    [sCommentRequestIDs removeAllObjects];
    [sLastPartialUIUpdate removeAllObjects];
    [sCommentGenerationScheduled removeAllObjects];
    [sPostFailed removeAllObjects];
    [sCommentFailed removeAllObjects];
    [sPostSuppressed removeAllObjects];
    [sPostEmpty removeAllObjects];
    [sTimedOutRequests removeAllObjects];
    [sTapRequested removeAllObjects];
    [sLinkSummaryPosts removeAllObjects];
    [sBothSummaryPosts removeAllObjects];

    // Serialize behind any pending cache write, then remove the final file so
    // an older queued snapshot cannot recreate it after this action returns.
    dispatch_sync(ApolloAIPersistQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:ApolloAISummariesCachePath() error:nil];
    });

    ApolloLog(@"[AISummary] cache cleared by user (%lu summaries removed)",
              (unsigned long)removed);
    return removed;
}

// The post box's current mode for this post, derived from the classification
// flags set in ApolloAIGenerateForController. Used to validate the cache: a cached
// summary is only reused if it was generated under the same mode.
static NSInteger ApolloAIDesiredPostMode(NSString *fullName) {
    if (fullName.length == 0) return ApolloAIPostModePost;
    if ([sBothSummaryPosts containsObject:fullName]) return ApolloAIPostModeBoth;
    if ([sLinkSummaryPosts containsObject:fullName]) return ApolloAIPostModeLink;
    return ApolloAIPostModePost;
}

#pragma mark - Runtime helpers (self-contained; mirror ApolloTranslation patterns)

static UITableView *ApolloAICommentsTableView(UIViewController *vc);
static id ApolloAICommentFromCellNode(id cellNode);
static void ApolloAIGenerateForController(UIViewController *vc);
static void ApolloAIPrepareForController(UIViewController *vc);
static void ApolloAIShowLoadingIfIdle(NSString *fullName, BOOL isPost);

static id ApolloAIGetIvarObject(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

// Swift Optional<ObjCClass> ivars do not consistently report an '@' runtime
// encoding. For known object ivars, object_getIvar is still the correct access
// path and avoids rejecting CommentsViewController.link before reading it.
static id ApolloAIKnownObjectIvar(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    if (!ivar) return nil;
    @try {
        return object_getIvar(obj, ivar);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// Reddit fullName ("t3_xxxx") for the post; falls back to a stable key.
static NSString *ApolloAILinkFullName(id link) {
    if (!link) return nil;
    SEL sels[] = { @selector(fullName), NSSelectorFromString(@"name"), NSSelectorFromString(@"identifier") };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        if ([link respondsToSelector:sels[i]]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(link, sels[i]);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
        }
    }
    return nil;
}

// Scan every `@`-typed ivar in an object's class hierarchy and return the first
// RDKLink found. Catches Swift-mangled / optional-wrapped ivar names that a
// fixed name list misses.
static id ApolloAIScanForLink(id obj) {
    if (!obj) return nil;
    Class rdkLink = NSClassFromString(@"RDKLink");
    if (!rdkLink) return nil;

    static const char *knownNames[] = {
        "link", "_link", "post", "_post", "currentLink", "currentPost", NULL
    };
    for (size_t i = 0; knownNames[i]; i++) {
        id value = ApolloAIKnownObjectIvar(obj, knownNames[i]);
        if ([value isKindOfClass:rdkLink]) return value;
    }

    for (Class cls = [obj class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(obj, ivars[i]); } @catch (__unused NSException *e) { continue; }
            if ([v isKindOfClass:rdkLink]) { free(ivars); return v; }
        }
        free(ivars);
    }
    return nil;
}

static NSArray *ApolloAIAvailableNodes(UIViewController *vc) {
    id tableNode = ApolloAIGetIvarObject(vc, "tableNode");
    UITableView *tableView = ApolloAICommentsTableView(vc);
    NSMutableArray *nodes = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    // AsyncDisplayKit retains a node for every row it has already loaded,
    // including preloaded rows below the fold; ask for those by index path.
    // We deliberately do NOT execute Texture's node block for rows it hasn't
    // built yet — that forces synchronous offscreen cell construction on the
    // main thread (the old code's biggest stall) and defeats lazy loading.
    // Comment bodies are captured from the cell lifecycle hooks instead, so the
    // already-loaded nodes here are only a supplementary source.
    SEL nodeForRowSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (tableNode && tableView && [tableNode respondsToSelector:nodeForRowSelector]) {
        NSInteger sectionCount = [tableView numberOfSections];
        for (NSInteger section = 0; section < sectionCount; section++) {
            NSInteger rowCount = [tableView numberOfRowsInSection:section];
            for (NSInteger row = 0; row < rowCount; row++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
                id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeForRowSelector, indexPath);
                if (!node) continue;
                NSValue *identity = [NSValue valueWithNonretainedObject:node];
                if ([seen containsObject:identity]) continue;
                [seen addObject:identity];
                [nodes addObject:node];
            }
        }
    }

    SEL visibleNodesSelector = NSSelectorFromString(@"visibleNodes");
    if (tableNode && [tableNode respondsToSelector:visibleNodesSelector]) {
        id visibleNodes = ((id (*)(id, SEL))objc_msgSend)(tableNode, visibleNodesSelector);
        if ([visibleNodes isKindOfClass:[NSArray class]]) {
            for (id node in visibleNodes) {
                NSValue *identity = [NSValue valueWithNonretainedObject:node];
                if ([seen containsObject:identity]) continue;
                [seen addObject:identity];
                [nodes addObject:node];
            }
        }
    }

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (![cell respondsToSelector:@selector(node)]) continue;
        id node = ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node));
        if (!node) continue;
        NSValue *identity = [NSValue valueWithNonretainedObject:node];
        if ([seen containsObject:identity]) continue;
        [seen addObject:identity];
        [nodes addObject:node];
    }
    return nodes;
}

// Per-controller memoization of the resolved link and its fullName. Both are
// stable for the lifetime of a comments controller, but the resolvers below are
// on the hot path (called from every comment cell's lifecycle hooks), so we
// cache the result on the controller the first time it resolves instead of
// re-scanning ivars / the loaded node set on every call.
static char kApolloAICachedLinkKey;
static char kApolloAICachedFullNameKey;
static char kApolloAIProvisionalPostRequestKey;
static char kApolloAIProvisionalCommentRequestKey;

// The RDKLink backing a comments view controller: first from the controller's
// own ivars, then (the reliable path) from the post header cell node, which
// always holds the link. Memoized on the controller once found.
static id ApolloAILinkFromController(UIViewController *vc) {
    if (!vc) return nil;
    id cached = objc_getAssociatedObject(vc, &kApolloAICachedLinkKey);
    if (cached) return cached;

    id link = ApolloAIScanForLink(vc);
    if (!link) {
        for (id cellNode in ApolloAIAvailableNodes(vc)) {
            // Skip comment cells; the header (post) cell node carries the link.
            if (ApolloAICommentFromCellNode(cellNode)) continue;
            link = ApolloAIScanForLink(cellNode);
            if (link) break;
        }
    }
    if (link) objc_setAssociatedObject(vc, &kApolloAICachedLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return link;
}

static UITableView *ApolloAIFindTableViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *t = ApolloAIFindTableViewInView(sub);
        if (t) return t;
    }
    return nil;
}

static UITableView *ApolloAICommentsTableView(UIViewController *vc) {
    id tableNode = ApolloAIGetIvarObject(vc, "tableNode");
    if (tableNode && [tableNode respondsToSelector:@selector(view)]) {
        UIView *v = ((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(view));
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    }
    return ApolloAIFindTableViewInView(vc.view);
}

// The RDKComment on a CommentCellNode (its `comment` ivar), or nil.
static id ApolloAICommentFromCellNode(id cellNode) {
    if (!cellNode) return nil;
    id comment = ApolloAIKnownObjectIvar(cellNode, "comment");
    Class rdkComment = NSClassFromString(@"RDKComment");
    if (!rdkComment || ![comment isKindOfClass:rdkComment]) return nil;
    return comment;
}

static NSString *ApolloAIStringSel(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSString *ApolloAINormalizeGeneratedSummary(NSString *summary) {
    if (![summary isKindOfClass:[NSString class]]) return nil;
    NSString *plain = [summary stringByReplacingOccurrencesOfString:@"**" withString:@""];
    plain = [plain stringByReplacingOccurrencesOfString:@"__" withString:@""];
    return [plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Remove input that costs context without helping a short summary. Keep this
// deterministic and conservative: ordinary prose and punctuation are preserved.
static NSString *ApolloAICleanInputText(NSString *text, NSUInteger maxLength) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;

    NSMutableArray<NSString *> *keptLines = [NSMutableArray array];
    BOOL inCodeBlock = NO;
    for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"```"]) {
            inCodeBlock = !inCodeBlock;
            continue;
        }
        if (inCodeBlock || [line hasPrefix:@">"] || line.length == 0) continue;
        [keptLines addObject:line];
    }

    NSString *clean = [keptLines componentsJoinedByString:@" "];
    NSError *regexError = nil;
    NSRegularExpression *urlRegex =
        [NSRegularExpression regularExpressionWithPattern:@"https?://\\S+"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&regexError];
    if (!regexError) {
        clean = [urlRegex stringByReplacingMatchesInString:clean
                                                   options:0
                                                     range:NSMakeRange(0, clean.length)
                                              withTemplate:@"[link]"];
    }
    clean = [clean stringByReplacingOccurrencesOfString:@"**" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"__" withString:@""];
    clean = [clean stringByReplacingOccurrencesOfString:@"~~" withString:@""];
    while ([clean containsString:@"  "]) {
        clean = [clean stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (maxLength > 0 && clean.length > maxLength) {
        clean = [[clean substringToIndex:maxLength]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return clean.length > 0 ? clean : nil;
}

static NSInteger ApolloAIIntegerSel(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

static NSString *ApolloAICommentDedupKey(id comment) {
    NSString *fullName = ApolloAIStringSel(comment, @selector(fullName));
    if (fullName.length > 0) return fullName;
    NSString *body = ApolloAIStringSel(comment, @selector(body));
    NSString *author = ApolloAIStringSel(comment, @selector(author)) ?: @"user";
    if (body.length == 0) return nil;
    return [NSString stringWithFormat:@"%@|%lu", author, (unsigned long)body.hash];
}

// A comment must be useful before it can be captured, counted, ranked, or make
// the discussion card appear. Filtering here prevents AutoModerator-only and
// deleted/removed threads from getting stuck in a permanent loading state.
static BOOL ApolloAICommentIsEligible(id comment) {
    if (!comment) return NO;
    NSString *author = [ApolloAIStringSel(comment, @selector(author))
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (author.length == 0 ||
        [author caseInsensitiveCompare:@"AutoModerator"] == NSOrderedSame ||
        [author caseInsensitiveCompare:@"[deleted]"] == NSOrderedSame) {
        return NO;
    }

    NSString *rawBody = ApolloAIStringSel(comment, @selector(body));
    if ([rawBody isEqualToString:@"[deleted]"] || [rawBody isEqualToString:@"[removed]"]) return NO;
    NSString *body = ApolloAICleanInputText(rawBody, kApolloAIMaxSingleCommentChars);
    return body.length >= 30;
}

static NSString *ApolloAIFullNameForController(UIViewController *vc) {
    if (!vc) return nil;
    NSString *cached = objc_getAssociatedObject(vc, &kApolloAICachedFullNameKey);
    if (cached.length > 0) return cached;
    NSString *fullName = ApolloAILinkFullName(ApolloAILinkFromController(vc));
    if (fullName.length > 0) {
        objc_setAssociatedObject(vc, &kApolloAICachedFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return fullName;
}

static void ApolloAICaptureCommentForController(id comment, UIViewController *vc) {
    if (!ApolloAICommentIsEligible(comment) || !vc) return;
    NSString *fullName = ApolloAIFullNameForController(vc);
    NSString *key = ApolloAICommentDedupKey(comment);
    if (fullName.length == 0 || key.length == 0) return;

    NSMutableArray *comments = sCapturedComments[fullName];
    if (!comments) {
        comments = [NSMutableArray array];
        sCapturedComments[fullName] = comments;
    }
    NSMutableSet *keys = sCapturedCommentKeys[fullName];
    if (!keys) {
        keys = [NSMutableSet set];
        sCapturedCommentKeys[fullName] = keys;
    }
    if ([keys containsObject:key]) return;
    [keys addObject:key];
    [comments addObject:comment];
    // Do not show a discussion card until there is enough material to synthesize.
    // Below this threshold, reading the comments directly is faster and clearer.
    if (sEnableAICommentSummaries && !sEnableTapToSummarize &&
        comments.count >= kApolloAIMinComments &&
        sCommentSummaryCache[fullName].length == 0 &&
        ![sCommentFailed containsObject:fullName]) {
        ApolloAIShowLoadingIfIdle(fullName, NO);
    }
    ApolloLog(@"[AISummary] captured comment %lu for %@", (unsigned long)comments.count, fullName);
}

static void ApolloAIAppendCommentText(id comment,
                                      NSMutableSet<NSString *> *seen,
                                      NSMutableString *joined,
                                      NSUInteger *count) {
    if (!ApolloAICommentIsEligible(comment) || !seen || !joined || !count) return;
    NSString *body = ApolloAICleanInputText(ApolloAIStringSel(comment, @selector(body)),
                                            kApolloAIMaxSingleCommentChars);
    if (body.length < 30) return;
    NSString *author = ApolloAIStringSel(comment, @selector(author)) ?: @"user";
    NSString *key = ApolloAICommentDedupKey(comment);
    if (key.length == 0 || [seen containsObject:key]) return;
    [seen addObject:key];

    NSInteger score = ApolloAIIntegerSel(comment, @selector(score));
    NSUInteger controversiality = (NSUInteger)MAX(0, ApolloAIIntegerSel(comment, @selector(controversiality)));
    NSString *linkAuthor = ApolloAIStringSel(comment, @selector(linkAuthor));
    BOOL isOP = linkAuthor.length > 0 && [author caseInsensitiveCompare:linkAuthor] == NSOrderedSame;
    NSString *kind = isOP ? @"OP" : (controversiality > 0 ? @"controversial" : @"comment");
    [joined appendFormat:@"[%@, score %ld] %@\n", kind, (long)score, body];
    (*count)++;
}

// Pull the RDKComment out of a comment row/model object — directly if it is
// one, otherwise via a `comment` accessor (cell models wrap it).
static id ApolloAIRDKCommentFromObject(id obj, Class rdkComment) {
    if (!obj || !rdkComment) return nil;
    if ([obj isKindOfClass:rdkComment]) return obj;
    if ([obj respondsToSelector:@selector(comment)]) {
        id c = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(comment));
        if ([c isKindOfClass:rdkComment]) return c;
    }
    return nil;
}

// Walk the comments controller's own ivars for the in-memory comment list
// Apollo already holds (the full fetched set), so we can summarize the instant
// the thread's data arrives instead of waiting for table cells to render — the
// main reason on-device felt slow next to a server that has the data in hand.
// Picks the array ivar with the most comment-bearing elements (best-effort).
static void ApolloAICollectCommentsFromDataModel(UIViewController *vc,
                                                 NSMutableArray *comments,
                                                 NSMutableSet<NSString *> *candidateKeys) {
    Class rdkComment = NSClassFromString(@"RDKComment");
    if (!rdkComment || !vc || !comments || !candidateKeys) return;

    NSArray *bestArray = nil;
    NSUInteger bestScore = 0;
    for (Class cls = [vc class]; cls && cls != [UIViewController class]; cls = class_getSuperclass(cls)) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        if (!ivars) continue;
        for (unsigned int i = 0; i < n; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(vc, ivars[i]); } @catch (__unused NSException *e) { continue; }
            NSArray *arr = nil;
            if ([value isKindOfClass:[NSArray class]]) arr = value;
            else if ([value isKindOfClass:[NSOrderedSet class]]) arr = [(NSOrderedSet *)value array];
            if (arr.count == 0) continue;
            NSUInteger score = 0, probe = MIN(arr.count, (NSUInteger)8);
            for (NSUInteger j = 0; j < probe; j++) {
                if (ApolloAIRDKCommentFromObject(arr[j], rdkComment)) score++;
            }
            if (score > bestScore) { bestScore = score; bestArray = arr; }
        }
        free(ivars);
    }
    if (bestScore == 0) return;

    for (id obj in bestArray) {
        id comment = ApolloAIRDKCommentFromObject(obj, rdkComment);
        NSString *key = ApolloAICommentDedupKey(comment);
        if (!ApolloAICommentIsEligible(comment) || key.length == 0 || [candidateKeys containsObject:key]) continue;
        [candidateKeys addObject:key];
        [comments addObject:comment];
    }
}

static NSInteger ApolloAICommentRank(id comment, NSUInteger originalIndex) {
    NSInteger score = ApolloAIIntegerSel(comment, @selector(score));
    NSUInteger controversiality = (NSUInteger)MAX(0, ApolloAIIntegerSel(comment, @selector(controversiality)));
    NSString *author = ApolloAIStringSel(comment, @selector(author));
    NSString *linkAuthor = ApolloAIStringSel(comment, @selector(linkAuthor));
    BOOL isOP = author.length > 0 && linkAuthor.length > 0 &&
        [author caseInsensitiveCompare:linkAuthor] == NSOrderedSame;
    NSInteger depth = MAX(0, ApolloAIIntegerSel(comment, @selector(depth)));

    // High-score comments carry consensus. OP and controversial comments add
    // useful diversity. Preserve a modest top-to-bottom bias and favor roots.
    NSInteger rank = MIN(MAX(score, -50), 5000);
    if (isOP) rank += 1400;
    if (controversiality > 0) rank += 700;
    rank -= MIN(depth, 8) * 70;
    rank -= MIN(originalIndex, (NSUInteger)100) * 3;
    return rank;
}

// Gather a compact representative set rather than the first N rendered rows.
// The model sees consensus (score), OP context, disagreement (controversiality),
// and some thread-order signal without paying for the full comment section.
static NSString *ApolloAIGatherCommentText(UIViewController *vc,
                                           NSUInteger *outCount,
                                           NSString **outSignature) {
    if (outCount) *outCount = 0;
    if (outSignature) *outSignature = nil;

    NSMutableSet<NSString *> *candidateKeys = [NSMutableSet set];
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableString *joined = [NSMutableString string];
    NSUInteger count = 0;

    NSString *fullName = ApolloAIFullNameForController(vc);

    ApolloAICollectCommentsFromDataModel(vc, candidates, candidateKeys);

    for (id comment in sCapturedComments[fullName] ?: @[]) {
        NSString *key = ApolloAICommentDedupKey(comment);
        if (!ApolloAICommentIsEligible(comment) || key.length == 0 || [candidateKeys containsObject:key]) continue;
        [candidateKeys addObject:key];
        [candidates addObject:comment];
    }

    if (candidates.count < 3) {
        for (id cellNode in ApolloAIAvailableNodes(vc)) {
            id comment = ApolloAICommentFromCellNode(cellNode);
            NSString *key = ApolloAICommentDedupKey(comment);
            if (!ApolloAICommentIsEligible(comment) || key.length == 0 || [candidateKeys containsObject:key]) continue;
            [candidateKeys addObject:key];
            [candidates addObject:comment];
        }
    }

    NSMapTable *originalIndexes = [NSMapTable weakToStrongObjectsMapTable];
    [candidates enumerateObjectsUsingBlock:^(id comment, NSUInteger idx, __unused BOOL *stop) {
        [originalIndexes setObject:@(idx) forKey:comment];
    }];
    [candidates sortUsingComparator:^NSComparisonResult(id a, id b) {
        NSInteger rankA = ApolloAICommentRank(a, [[originalIndexes objectForKey:a] unsignedIntegerValue]);
        NSInteger rankB = ApolloAICommentRank(b, [[originalIndexes objectForKey:b] unsignedIntegerValue]);
        if (rankA > rankB) return NSOrderedAscending;
        if (rankA < rankB) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSString *> *selectedKeys = [NSMutableArray array];
    for (id comment in candidates) {
        if (count >= kApolloAIMaxComments || joined.length >= kApolloAIMaxCommentChars) break;
        NSUInteger previousCount = count;
        ApolloAIAppendCommentText(comment, seen, joined, &count);
        if (count > previousCount) {
            NSString *key = ApolloAICommentDedupKey(comment);
            NSString *body = ApolloAIStringSel(comment, @selector(body)) ?: @"";
            [selectedKeys addObject:[NSString stringWithFormat:@"%@:%lu",
                                     key ?: @"unknown", (unsigned long)body.hash]];
        }
    }

    if (outCount) *outCount = count;
    if (outSignature && selectedKeys.count > 0) {
        *outSignature = [selectedKeys componentsJoinedByString:@"|"];
    }
    if (joined.length == 0) return nil;
    if (joined.length > kApolloAIMaxCommentChars) {
        return [joined substringToIndex:kApolloAIMaxCommentChars];
    }
    return joined;
}

// Number of whitespace-delimited words in (already-cleaned) text.
static NSUInteger ApolloAIWordCount(NSString *text) {
    if (text.length == 0) return 0;
    NSUInteger words = 0;
    for (NSString *piece in [text componentsSeparatedByCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (piece.length > 0) words++;
    }
    return words;
}

// Title + selftext for the post, or nil for non-self (link/image) posts or
// bodies too short to be worth summarizing.
static NSString *ApolloAIPostText(id link) {
    if (!link) return nil;
    BOOL isSelf = [link respondsToSelector:@selector(isSelfPostWithSelfText)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isSelfPostWithSelfText));

    NSString *title = ApolloAIStringSel(link, @selector(title)) ?: @"";
    NSString *selfText = isSelf ? (ApolloAIStringSel(link, @selector(selfText)) ?: @"") : @"";

    title = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    selfText = ApolloAICleanInputText(selfText, kApolloAIMaxPostChars) ?: @"";

    if (selfText.length == 0) return nil;  // nothing meaningful to summarize

    // Skip trivially short bodies. Summarizing one or two sentences yields a
    // "summary" about as long as the post — pointless, and (per user feedback)
    // it cluttered short posts with a redundant card. Gate on the body's word
    // count, not the title's: a long title shouldn't license summarizing a
    // one-line body.
    if (ApolloAIWordCount(selfText) < kApolloAIMinPostWords) return nil;

    if (title.length > 0) return [NSString stringWithFormat:@"Title: %@\nBody: %@", title, selfText];
    return selfText;
}

// A short, capped context block (post title + a snippet of the body, if any) so
// the comment summary knows the topic the discussion is responding to. Keeps
// the comment prompt grounded without spending much of the token budget on it.
static NSString *ApolloAIPostContextForComments(id link) {
    if (!link) return nil;
    NSString *title = [(ApolloAIStringSel(link, @selector(title)) ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) return nil;

    BOOL isSelf = [link respondsToSelector:@selector(isSelfPostWithSelfText)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isSelfPostWithSelfText));
    NSString *selfText = isSelf ? [(ApolloAIStringSel(link, @selector(selfText)) ?: @"")
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";

    NSMutableString *context = [NSMutableString stringWithFormat:@"Post title: %@\n", title];
    if (selfText.length > 0) {
        NSUInteger snippetMax = 160;
        NSString *snippet = selfText.length > snippetMax ? [selfText substringToIndex:snippetMax] : selfText;
        [context appendFormat:@"Post body: %@\n", snippet];
    }
    return context;
}

#pragma mark - Link/article summaries: detection, fetch, extraction

// URL-level article test: http(s), not a direct media file, not a blocklisted
// reddit/media/social host. Shared by pure-link detection and the selftext scan.
static BOOL ApolloAIURLIsArticleCandidate(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;

    // Direct media/file URLs.
    NSString *ext = url.pathExtension.lowercaseString ?: @"";
    static NSSet *mediaExts;
    static dispatch_once_t extOnce;
    dispatch_once(&extOnce, ^{
        mediaExts = [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"gif", @"gifv", @"webp",
                     @"bmp", @"mp4", @"webm", @"mov", @"m4v", @"mp3", @"pdf", nil];
    });
    if ([mediaExts containsObject:ext]) return NO;

    // Host blocklist: reddit-internal, media hosts, and platforms whose pages are
    // JS-rendered / login-gated and yield no useful article prose.
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if ([host hasPrefix:@"m."]) host = [host substringFromIndex:2];
    static NSArray *blocked;
    static dispatch_once_t hostOnce;
    dispatch_once(&hostOnce, ^{
        // Registrable domains only — the matcher below also catches any subdomain
        // (e.g. "twitch.tv" covers clips.twitch.tv; "redd.it" covers v.redd.it).
        // The runtime "no prose -> hide" fallback covers anything not listed here
        // (these clip hosts rotate domains/TLDs faster than a list can track).
        blocked = @[
            // Reddit-internal + Reddit media (Apollo renders these natively)
            @"reddit.com", @"redd.it", @"redditmedia.com",
            // Image / GIF / screenshot hosts — no article prose
            @"imgur.com", @"giphy.com", @"tenor.com", @"redgifs.com", @"gfycat.com",
            @"imgchest.com", @"flickr.com", @"ibb.co", @"postimg.cc", @"postimages.org",
            @"imgbb.com", @"prnt.sc", @"gyazo.com", @"imgflip.com",
            // Video / short-clip hosts (r/soccer goal clips etc.) — player-only pages
            @"youtube.com", @"youtu.be", @"twitch.tv", @"streamable.com", @"streamja.com",
            @"streamff.com", @"streamff.pro", @"streamff.live", @"streamff.io", @"streamff.net",
            @"streamff.co", @"streamin.one", @"streamin.me", @"streamin.link", @"streamye.com",
            @"streamwo.com", @"streamgg.com", @"streamvi.com", @"dubz.co", @"dubz.link",
            @"dubz.cc", @"dubz.one", @"dropr.co", @"sendvid.com", @"clippituser.tv",
            @"imgtc.com", @"streamtape.com", @"doodstream.com", @"vidoza.net", @"qu.ax",
            @"juststream.live", @"vidlii.com", @"fb.watch",
            // Social / micro-post platforms — content is self-contained + already
            // shown inline, and the pages are JS-rendered SPAs with no article body
            @"twitter.com", @"x.com", @"t.co", @"twimg.com", @"fixupx.com", @"fxtwitter.com",
            @"vxtwitter.com", @"nitter.net", @"bsky.app", @"bsky.social", @"threads.com",
            @"threads.net", @"instagram.com", @"tiktok.com", @"facebook.com", @"fb.com",
            @"tumblr.com", @"weibo.com", @"weibo.cn", @"vk.com", @"truthsocial.com",
            @"mastodon.social", @"mastodon.online", @"discordapp.com",
        ];
    });
    for (NSString *b in blocked) {
        if ([host isEqualToString:b] || [host hasSuffix:[@"." stringByAppendingString:b]]) return NO;
    }
    return YES;
}

// YES if `link`'s RDKLink.URL is an external article — not an image/gif/video/
// gallery, not a crosspost, not a reddit-internal or media host. RDKLink.URL is a
// real ObjC NSURL property, safe to read directly.
//
// NOTE: we deliberately do NOT bail on self-posts. A "link + text" post is a
// self-post (it has selftext) whose URL still points at an external article — that
// should be treated as an article (→ a Both summary). A PURE self-post's URL is
// just its own reddit.com permalink, which the host blocklist below rejects, so
// checking the URL for self-posts too is safe.
static BOOL ApolloAILinkIsArticle(id link) {
    if (!link) return NO;

    NSURL *url = nil;
    if ([link respondsToSelector:@selector(URL)]) {
        url = ((NSURL *(*)(id, SEL))objc_msgSend)(link, @selector(URL));
    }
    if (![url isKindOfClass:[NSURL class]]) return NO;

    // Media posts → no article prose to extract.
    if ([link respondsToSelector:@selector(mediaVideo)] &&
        ((id (*)(id, SEL))objc_msgSend)(link, @selector(mediaVideo))) return NO;
    if ([link respondsToSelector:@selector(galleryData)]) {
        id gallery = ((id (*)(id, SEL))objc_msgSend)(link, @selector(galleryData));
        if ([gallery isKindOfClass:[NSArray class]] && [(NSArray *)gallery count] > 0) return NO;
    }
    if ([link respondsToSelector:@selector(crosspostParent)] &&
        ((id (*)(id, SEL))objc_msgSend)(link, @selector(crosspostParent))) return NO;

    // post_hint that marks non-article content.
    NSString *hint = ApolloAIStringSel(link, @selector(hint)).lowercaseString;
    if (hint.length > 0 &&
        ([hint isEqualToString:@"image"] || [hint isEqualToString:@"hosted:video"] ||
         [hint isEqualToString:@"rich:video"] || [hint isEqualToString:@"gallery"] ||
         [hint isEqualToString:@"animated_gif"])) return NO;

    return ApolloAIURLIsArticleCandidate(url);
}

// First external-article URL inside a SELF post's body, or nil. Lets a thin
// self-post that's really "just sharing a link" get a Link summary of the article
// instead of a near-empty post summary.
static NSString *ApolloAIFirstArticleURLInSelfText(id link) {
    BOOL isSelf = [link respondsToSelector:@selector(isSelfPostWithSelfText)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(link, @selector(isSelfPostWithSelfText));
    if (!isSelf) return nil;
    NSString *selfText = ApolloAIStringSel(link, @selector(selfText));
    if (selfText.length == 0) return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    // Markdown links [text](url) first — the explicit "here's the article" shares.
    NSRegularExpression *md = [NSRegularExpression regularExpressionWithPattern:@"\\]\\((https?://[^)\\s]+)\\)" options:0 error:nil];
    for (NSTextCheckingResult *m in [md matchesInString:selfText options:0 range:NSMakeRange(0, selfText.length)]) {
        [candidates addObject:[selfText substringWithRange:[m rangeAtIndex:1]]];
    }
    // Then any bare URLs.
    NSRegularExpression *bare = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s)\\]]+" options:0 error:nil];
    for (NSTextCheckingResult *m in [bare matchesInString:selfText options:0 range:NSMakeRange(0, selfText.length)]) {
        [candidates addObject:[selfText substringWithRange:m.range]];
    }
    NSCharacterSet *trail = [NSCharacterSet characterSetWithCharactersInString:@".,;:)]\"'"];
    for (NSString *cand in candidates) {
        NSString *trimmed = [cand stringByTrimmingCharactersInSet:trail];
        if (ApolloAIURLIsArticleCandidate([NSURL URLWithString:trimmed])) return trimmed;
    }
    return nil;
}

// The external article URL associated with this post, or nil. A pure link post
// uses its own URL; a self-post uses the first article link found in its body.
// Returned regardless of how much body text there is — the caller decides the
// mode: no body -> Link summary; body present -> Both (post + article) summary.
static NSString *ApolloAIArticleURLForPost(id link) {
    if (ApolloAILinkIsArticle(link)) {
        NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(link, @selector(URL));
        if ([url isKindOfClass:[NSURL class]]) return url.absoluteString;
    }
    return ApolloAIFirstArticleURLInSelfText(link);
}

// Decode the HTML entities that show up in article prose. Self-contained (the
// link-preview fetcher's decoders are file-static and not linkable from here).
static NSString *ApolloAIDecodeHTMLEntities(NSString *s) {
    if (s.length == 0 || [s rangeOfString:@"&"].location == NSNotFound) return s;
    NSDictionary *named = @{
        @"&nbsp;": @" ", @"&lt;": @"<", @"&gt;": @">", @"&quot;": @"\"",
        @"&#39;": @"'", @"&apos;": @"'", @"&lsquo;": @"‘", @"&rsquo;": @"’",
        @"&ldquo;": @"“", @"&rdquo;": @"”", @"&ndash;": @"–",
        @"&mdash;": @"—", @"&hellip;": @"…",
    };
    for (NSString *k in named) s = [s stringByReplacingOccurrencesOfString:k withString:named[k]];
    // Numeric decimal entities (&#160; etc.).
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"&#(\\d{2,7});" options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    if (matches.count > 0) {
        NSMutableString *out = [s mutableCopy];
        for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
            NSInteger code = [[s substringWithRange:[m rangeAtIndex:1]] integerValue];
            if (code > 31 && code <= 0x10FFFF) {
                UTF32Char cp = (UTF32Char)code;
                NSString *rep = [[NSString alloc] initWithBytes:&cp length:sizeof(cp)
                                                       encoding:NSUTF32LittleEndianStringEncoding];
                if (rep) [out replaceCharactersInRange:m.range withString:rep];
            }
        }
        s = out;
    }
    return [s stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}

// Reader-mode source #1 (best): the schema.org JSON-LD that most publishers embed
// for SEO. `articleBody` is clean, already-decoded prose and is frequently present
// even when the visible DOM is paywalled or JS-rendered — so it's our most
// reliable way past paywalls/ad junk. Returns the longest articleBody (falling
// back to the longest description) found across all ld+json blocks, or nil.
static NSString *ApolloAIExtractJSONLD(NSString *html) {
    if (html.length == 0) return nil;
    NSRegularExpressionOptions dotAll =
        NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"<script[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>"
        options:dotAll error:nil];
    NSString *bestBody = nil;
    NSString *bestDesc = nil;
    for (NSTextCheckingResult *m in [re matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *json = [html substringWithRange:[m rangeAtIndex:1]];
        // Some pages wrap JSON-LD in CDATA / HTML comments — strip those markers.
        json = [json stringByReplacingOccurrencesOfString:@"<!--" withString:@" "];
        json = [json stringByReplacingOccurrencesOfString:@"-->" withString:@" "];
        json = [json stringByReplacingOccurrencesOfString:@"//<![CDATA[" withString:@" "];
        json = [json stringByReplacingOccurrencesOfString:@"<![CDATA[" withString:@" "];
        json = [json stringByReplacingOccurrencesOfString:@"]]>" withString:@" "];
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!obj) continue;
        // Walk arrays, @graph, mainEntity, and nested dicts collecting fields.
        NSMutableArray *stack = [NSMutableArray arrayWithObject:obj];
        NSUInteger guard = 0;
        while (stack.count > 0 && guard++ < 4000) {
            id node = stack.lastObject;
            [stack removeLastObject];
            if ([node isKindOfClass:[NSArray class]]) {
                [stack addObjectsFromArray:node];
            } else if ([node isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = node;
                id body = d[@"articleBody"];
                if ([body isKindOfClass:[NSString class]] && [(NSString *)body length] > bestBody.length) bestBody = body;
                id desc = d[@"description"];
                if ([desc isKindOfClass:[NSString class]] && [(NSString *)desc length] > bestDesc.length) bestDesc = desc;
                id graph = d[@"@graph"]; if (graph) [stack addObject:graph];
                id mainEntity = d[@"mainEntity"]; if (mainEntity) [stack addObject:mainEntity];
            }
        }
    }
    NSString *chosen = (bestBody.length >= 200) ? bestBody
                     : (bestBody.length >= bestDesc.length ? bestBody : bestDesc);
    if (chosen.length == 0) return nil;
    // articleBody is usually plain text but can carry inline HTML; clean it.
    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    chosen = [tagRe stringByReplacingMatchesInString:chosen options:0 range:NSMakeRange(0, chosen.length) withTemplate:@" "];
    return ApolloAIDecodeHTMLEntities(chosen);
}

// Pull the `content` of the first <meta> tag whose name/property equals `key`
// (attribute order varies, so try both layouts). Decoded + trimmed, or nil.
static NSString *ApolloAIMetaContent(NSString *html, NSString *key) {
    if (html.length == 0) return nil;
    NSString *k = [NSRegularExpression escapedPatternForString:key];
    // Capture the opening quote (group 1) and backreference it so the value
    // (group 2) runs to the MATCHING quote — a value containing the other quote
    // type (e.g. an apostrophe inside a double-quoted description) isn't truncated,
    // and a mismatched open/close pair isn't accepted.
    NSArray<NSString *> *patterns = @[
        [NSString stringWithFormat:@"<meta[^>]*\\b(?:property|name)\\s*=\\s*[\"']%@[\"'][^>]*\\bcontent\\s*=\\s*([\"'])(.*?)\\1", k],
        [NSString stringWithFormat:@"<meta[^>]*\\bcontent\\s*=\\s*([\"'])(.*?)\\1[^>]*\\b(?:property|name)\\s*=\\s*[\"']%@[\"']", k],
    ];
    NSRange scan = NSMakeRange(0, MIN(html.length, (NSUInteger)200000));
    for (NSString *pat in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat
            options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:scan];
        if (m) {
            NSString *c = [ApolloAIDecodeHTMLEntities([html substringWithRange:[m rangeAtIndex:2]])
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (c.length > 0) return c;
        }
    }
    return nil;
}

// Reader-mode source #3 (thin-page seed): a real og:/meta description beats
// summarizing leftover nav/cookie junk when the body can't be extracted.
static NSString *ApolloAIExtractMetaDescription(NSString *html) {
    for (NSString *key in @[@"og:description", @"twitter:description", @"description"]) {
        NSString *c = ApolloAIMetaContent(html, key);
        if (c.length > 0) return c;
    }
    return nil;
}

// The AMP version of an article is a stripped-down, ad-light, frequently
// un-paywalled page — a strong reader-mode fallback when the canonical page
// yields no prose. Returns the absolute amphtml URL, or nil.
static NSString *ApolloAIFindAMPURL(NSString *html, NSURL *base) {
    if (html.length == 0) return nil;
    // Quote (group 1) captured + backreferenced so the href (group 2) runs to
    // the matching quote, mirroring the meta-content extractor above.
    NSArray<NSString *> *patterns = @[
        @"<link[^>]*\\brel\\s*=\\s*[\"']amphtml[\"'][^>]*\\bhref\\s*=\\s*([\"'])(.+?)\\1",
        @"<link[^>]*\\bhref\\s*=\\s*([\"'])(.+?)\\1[^>]*\\brel\\s*=\\s*[\"']amphtml[\"']",
    ];
    NSRange scan = NSMakeRange(0, MIN(html.length, (NSUInteger)200000));
    for (NSString *pat in patterns) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat
            options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:scan];
        if (m) {
            NSString *href = ApolloAIDecodeHTMLEntities([html substringWithRange:[m rangeAtIndex:2]]);
            NSURL *abs = [NSURL URLWithString:href relativeToURL:base];
            return abs.absoluteURL.absoluteString ?: href;
        }
    }
    return nil;
}

// A small readability pass. Prefers, in order: JSON-LD articleBody (cleanest,
// paywall-resistant), then scraped <article>/<main> <p> prose, then a strip-all
// fallback, then a meta description for thin pages. Decodes entities, collapses
// whitespace, caps length.
static NSString *ApolloAIExtractArticleText(NSString *html) {
    if (html.length == 0) return nil;

    // Source #1: JSON-LD, computed over the FULL html (the block can sit late).
    NSString *jsonld = ApolloAIExtractJSONLD(html);

    // Bound regex cost for the DOM scrape; an article's body sits near the top.
    NSString *capped = html.length > 600000 ? [html substringToIndex:600000] : html;

    NSRegularExpressionOptions dotAll =
        NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators;

    NSRegularExpression *noise = [NSRegularExpression regularExpressionWithPattern:
        @"<(script|style|noscript|template|svg|head|nav|header|footer|aside|form|figure)\\b[^>]*>.*?</\\1>"
        options:dotAll error:nil];
    NSString *s = [noise stringByReplacingMatchesInString:capped options:0
                                                    range:NSMakeRange(0, capped.length) withTemplate:@" "];

    // Narrow to the main article region if the page marks one.
    NSString *scope = s;
    for (NSString *tag in @[@"article", @"main"]) {
        NSRegularExpression *open = [NSRegularExpression regularExpressionWithPattern:
            [NSString stringWithFormat:@"<%@\\b[^>]*>", tag] options:NSRegularExpressionCaseInsensitive error:nil];
        NSTextCheckingResult *o = [open firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (!o) continue;
        NSUInteger start = NSMaxRange(o.range);
        NSRange close = [s rangeOfString:[NSString stringWithFormat:@"</%@>", tag]
                                 options:(NSCaseInsensitiveSearch | NSBackwardsSearch)
                                   range:NSMakeRange(start, s.length - start)];
        NSUInteger end = (close.location != NSNotFound) ? close.location : s.length;
        if (end > start) { scope = [s substringWithRange:NSMakeRange(start, end - start)]; break; }
    }

    // Source #2: articles put body text in <p> tags; menus/chrome rarely do.
    NSMutableString *prose = [NSMutableString string];
    NSRegularExpression *pRe = [NSRegularExpression regularExpressionWithPattern:@"<p\\b[^>]*>(.*?)</p>" options:dotAll error:nil];
    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    for (NSTextCheckingResult *m in [pRe matchesInString:scope options:0 range:NSMakeRange(0, scope.length)]) {
        NSString *frag = [scope substringWithRange:[m rangeAtIndex:1]];
        frag = [tagRe stringByReplacingMatchesInString:frag options:0 range:NSMakeRange(0, frag.length) withTemplate:@" "];
        frag = [ApolloAIDecodeHTMLEntities(frag) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (frag.length >= 40) [prose appendFormat:@"%@\n", frag];
        if (prose.length >= kApolloAIMaxArticleChars) break;
    }

    // Prefer the richest source: JSON-LD articleBody wins when it's longer.
    NSString *source = @"prose";
    NSString *text = prose;
    if (jsonld.length > text.length) { text = jsonld; source = @"jsonld"; }

    // Still thin (SPA / clip page / paywall stub)? Try strip-all on the scope,
    // then a meta description — anything real beats nav junk.
    if (text.length < 200) {
        NSString *stripped = [tagRe stringByReplacingMatchesInString:scope options:0
                                                               range:NSMakeRange(0, scope.length) withTemplate:@" "];
        stripped = ApolloAIDecodeHTMLEntities(stripped);
        if (stripped.length > text.length) { text = stripped; source = @"strip"; }
    }
    if (text.length < 200) {
        NSString *meta = ApolloAIExtractMetaDescription(html);
        if (meta.length > text.length) { text = meta; source = @"meta"; }
    }

    NSRegularExpression *ws = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    text = [ws stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return nil;
    if (text.length > kApolloAIMaxArticleChars) text = [text substringToIndex:kApolloAIMaxArticleChars];
    ApolloLog(@"[AISummary] article extracted via %@ (%lu chars)", source, (unsigned long)text.length);
    return text;
}

// A real browser UA — some publishers serve a stub to non-browser agents.
static NSString *const kApolloAIBrowserUA =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
// Search-crawler UA. Many JavaScript single-page sites (live scoreboards and
// standings, some news SPAs) serve an empty shell to browsers but a fully
// server-rendered page to SEO crawlers. We use this ONLY as a fallback, when the
// normal browser fetch came back with no usable prose, so well-behaved sites are
// always tried as a browser first and a crawler-blocking site is no worse off.
static NSString *const kApolloAICrawlerUA =
    @"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)";

// Core single-URL fetch + extract. Calls back on URLSession's own queue (NOT the
// main thread) with the extracted prose, the raw html (for AMP discovery), and
// any error. The public wrapper below hops to main and adds the AMP / crawler
// fallbacks. Pass nil userAgent to use the default browser UA.
static void ApolloAIFetchAndExtract(NSURL *url, NSString *userAgent, void (^done)(NSString *text, NSString *html, NSError *error)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kApolloAIArticleFetchTimeout];
    [req setValue:(userAgent.length > 0 ? userAgent : kApolloAIBrowserUA)
        forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"text/html,application/xhtml+xml,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    [req setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *text = nil, *html = nil;
            NSError *outErr = error;
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            if (!error && http && http.statusCode >= 200 && http.statusCode < 300 &&
                data.length > 0 && data.length <= kApolloAIArticleFetchMaxBytes) {
                html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                if (html) text = ApolloAIExtractArticleText(html);
            } else if (!error && http && (http.statusCode < 200 || http.statusCode >= 300)) {
                outErr = [NSError errorWithDomain:@"ApolloAIArticle" code:http.statusCode userInfo:nil];
            }
            if (done) done(text, html, outErr);
        }];
    [task resume];
}

// Fetch the article URL off-thread and hand extracted prose back on the MAIN
// thread. When the canonical page yields little prose, fall back in order:
//   1. its advertised AMP version (usually clean, un-paywalled reader content), then
//   2. a refetch as a search crawler (SPA sites prerender full content for SEO bots,
//      e.g. fifa.com scoreboards/standings serve an empty shell to browsers).
// At most three network requests; neither fallback is re-followed.
static void ApolloAIFetchArticleText(NSString *urlString, void (^completion)(NSString *text, NSError *error)) {
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"ApolloAIArticle" code:400 userInfo:nil]);
        });
        return;
    }
    void (^deliver)(NSString *, NSError *) = ^(NSString *text, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(text, text.length > 0 ? nil
                : (err ?: [NSError errorWithDomain:@"ApolloAIArticle" code:204 userInfo:nil]));
        });
    };
    ApolloAIFetchAndExtract(url, kApolloAIBrowserUA, ^(NSString *text, NSString *html, NSError *err) {
        // Good enough as a normal browser fetch → done.
        if (text.length >= 200) { deliver(text, err); return; }

        // A genuine transport failure (no response at all — offline, DNS, timeout)
        // won't be helped by refetching and would just double the wasted work, so
        // bail. A non-2xx HTTP status (our "ApolloAIArticle" domain) is different:
        // some sites 403 a browser UA but serve crawlers fine, so let it fall through
        // to the crawler retry below.
        if (html.length == 0 && err && ![err.domain isEqualToString:@"ApolloAIArticle"]) {
            deliver(text, err);
            return;
        }

        // Last-resort crawler-UA refetch of the ORIGINAL url: keeps the best result
        // seen so far, since a fake-Googlebot may be blocked (then we're no worse off).
        void (^crawlerRetry)(NSString *) = ^(NSString *bestSoFar) {
            ApolloLog(@"[AISummary] thin extract (%lu chars) — retrying as crawler %@",
                      (unsigned long)bestSoFar.length, url.absoluteString);
            ApolloAIFetchAndExtract(url, kApolloAICrawlerUA, ^(NSString *botText, NSString *botHtml, NSError *botErr) {
                NSString *best = botText.length > bestSoFar.length ? botText : bestSoFar;
                deliver(best, best.length > 0 ? nil : (err ?: botErr));
            });
        };

        // Prefer an AMP version first if the (thin) page advertises one.
        NSString *amp = html.length > 0 ? ApolloAIFindAMPURL(html, url) : nil;
        NSURL *ampURL = amp.length > 0 ? [NSURL URLWithString:amp] : nil;
        if (ampURL && ![ampURL.absoluteString isEqualToString:url.absoluteString]) {
            ApolloLog(@"[AISummary] thin extract (%lu chars) — retrying via AMP %@", (unsigned long)text.length, amp);
            ApolloAIFetchAndExtract(ampURL, kApolloAIBrowserUA, ^(NSString *ampText, NSString *ampHtml, NSError *ampErr) {
                if (ampText.length >= 200) { deliver(ampText, nil); return; }
                crawlerRetry(ampText.length > text.length ? ampText : text);
            });
            return;
        }
        crawlerRetry(text);
    });
}

#pragma mark - Summary UI

// Per-box lifecycle state. The summary cards are always visible (in their
// loading state) the moment we know a box applies, rather than popping in when
// the text is ready; failures show an error inside the box instead of hiding it.
typedef NS_ENUM(NSInteger, ApolloAIBoxState) {
    ApolloAIBoxStateNone = 0,        // no box for this type (e.g. link post / no comments)
    ApolloAIBoxStateLoading,         // box visible, generating (shows streamed text or "Summarizing…")
    ApolloAIBoxStateReady,           // box visible, final summary shown
    ApolloAIBoxStateError,           // box visible, error message shown
    ApolloAIBoxStateTapToSummarize,  // box visible, idle — waiting for the user to tap to generate
    ApolloAIBoxStateEmpty,           // box visible, terminal — a tapped link had nothing to summarize
};

static char kApolloAIPostSummaryKey;        // ready/streamed summary text (post)
static char kApolloAICommentSummaryKey;     // ready/streamed summary text (comment)
static char kApolloAIPostStateKey;          // ApolloAIBoxState (post)
static char kApolloAICommentStateKey;       // ApolloAIBoxState (comment)
static char kApolloAIPostErrorKey;          // error message (post)
static char kApolloAICommentErrorKey;       // error message (comment)
static char kApolloAIPostSummaryNodeKey;
static char kApolloAICommentSummaryNodeKey;
static char kApolloAIHeaderFullNameKey;
static char kApolloAIPostSummaryBackgroundNodeKey;
static char kApolloAICommentSummaryBackgroundNodeKey;
static char kApolloAIPostExpandedKey;
static char kApolloAICommentExpandedKey;
// Set once the user has explicitly expanded/collapsed a box, so the "Open
// summaries automatically" setting never overrides a manual choice on a header.
static char kApolloAIPostExpandChoiceKey;
static char kApolloAICommentExpandChoiceKey;
// Set when the user taps an idle "Tap to summarize" card: the box stays collapsed
// while it generates (showing "· Summarizing…") and then opens itself once ready,
// even if the global "Open summaries automatically" setting is off — tapping is an
// explicit request to read this summary. Cleared like a one-shot by the expand.
static char kApolloAIPostExpandOnReadyKey;
static char kApolloAICommentExpandOnReadyKey;
static char kApolloAISummaryOwnerKey;
static char kApolloAISummaryIsPostKey;

static void ApolloAIForceHeaderRemeasure(NSString *fullName);
static void ApolloAIForceHeaderRemeasureForNode(id headerNode, NSString *fullName, NSInteger attemptsLeft);
static void ApolloAIRealizeHeaderNodeDisplay(id headerNode);
static void ApolloAIApplyRestoredState(id headerNode, NSString *fullName);

static UIColor *ApolloAISummaryThemeAccent(id headerNode) {
    NSString *fullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
    UIViewController *vc = [sControllerByFullName objectForKey:fullName];
    UIColor *accent = ApolloThemeAccentColor() ?: vc.viewIfLoaded.tintColor ?: UIColor.systemBlueColor;
    // Consumers take .CGColor on ASDK's background layout thread, where the
    // ambient trait collection is unspecified — resolve against the owning
    // view's traits now so light/dark can't flip per-thread.
    UITraitCollection *tc = vc.viewIfLoaded.traitCollection;
    return tc ? [accent resolvedColorWithTraitCollection:tc] : accent;
}

// A baseline-aligned SF Symbol as an attributed string, sized to `font` and
// tinted `tint`. Returns nil if the symbol is unavailable so callers can fall
// back to a plain glyph.
static NSAttributedString *ApolloAISymbolAttachment(NSString *symbolName, UIFont *font, UIColor *tint) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithFont:font];
        UIImage *image = [UIImage systemImageNamed:symbolName withConfiguration:cfg];
        if (image) {
            image = [image imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
            NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
            attachment.image = image;
            // Center the glyph on the font's cap height so it sits on the text
            // baseline rather than floating above it.
            CGFloat y = (font.capHeight - image.size.height) / 2.0;
            attachment.bounds = CGRectMake(0, y, image.size.width, image.size.height);
            return [NSAttributedString attributedStringWithAttachment:attachment];
        }
    }
    return nil;
}

static NSAttributedString *ApolloAISummaryAttributedText(NSString *title,
                                                         ApolloAIBoxState state,
                                                         NSString *bodyText,
                                                         BOOL expanded,
                                                         BOOL isPost,
                                                         NSUInteger sourceCount,
                                                         UIColor *accent) {
    if (state == ApolloAIBoxStateNone) return nil;

    UIColor *secondary = nil;
    UIColor *tertiary = nil;
    if (@available(iOS 13.0, *)) {
        secondary = UIColor.secondaryLabelColor;
        tertiary = UIColor.tertiaryLabelColor;
    } else {
        secondary = UIColor.darkGrayColor;
        tertiary = UIColor.grayColor;
    }
    UIColor *errorColor = UIColor.systemOrangeColor;

    accent = accent ?: UIColor.systemBlueColor;
    UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    UIFont *chevronFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIFont *captionFont = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    NSDictionary *titleAttributes = @{
        NSFontAttributeName: titleFont,
        NSForegroundColorAttributeName: accent,
    };
    NSDictionary *chevronAttributes = @{
        NSFontAttributeName: chevronFont,
        NSForegroundColorAttributeName: secondary,
    };
    NSDictionary *bodyAttributes = @{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
        NSForegroundColorAttributeName: state == ApolloAIBoxStateError ? errorColor : secondary,
    };
    NSDictionary *captionAttributes = @{
        NSFontAttributeName: captionFont,
        NSForegroundColorAttributeName: tertiary,
    };

    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];

    // Leading icon — native SF Symbol, glyph fallback for < iOS 13. The error
    // state swaps in a warning glyph tinted to match the body.
    NSString *symbolName = isPost ? @"sparkles" : @"text.bubble.fill";
    UIColor *iconTint = accent;
    if (state == ApolloAIBoxStateError) { symbolName = @"exclamationmark.triangle.fill"; iconTint = errorColor; }
    NSAttributedString *iconAttachment = ApolloAISymbolAttachment(symbolName, titleFont, iconTint);
    if (iconAttachment) {
        [result appendAttributedString:iconAttachment];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:titleAttributes]];
    } else {
        NSString *glyph = isPost ? @"✦  " : @"◉  ";
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:glyph attributes:titleAttributes]];
    }
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:titleAttributes]];
    if (state == ApolloAIBoxStateEmpty) {
        // Terminal "Nothing to summarize" card (a tapped link with no usable
        // prose). One muted line, no disclosure chevron, nothing to expand.
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ·  Nothing to summarize"
                                                                       attributes:chevronAttributes]];
        return result;
    }
    if (!expanded && state == ApolloAIBoxStateLoading) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ·  Summarizing…"
                                                                       attributes:chevronAttributes]];
    } else if (!expanded && state == ApolloAIBoxStateTapToSummarize) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  ·  Tap to summarize"
                                                                       attributes:chevronAttributes]];
    }

    // Trailing disclosure chevron — only when there's something to expand or
    // collapse: an expanded card, or a collapsed ready/error card. Collapsed
    // idle/loading cards rely on their "· Tap to summarize" / "· Summarizing…"
    // subtitle instead, which keeps the longest title (e.g. "Post & link summary")
    // on one line rather than wrapping the chevron onto a second row.
    BOOL showChevron = expanded || state == ApolloAIBoxStateReady || state == ApolloAIBoxStateError;
    if (showChevron) {
        NSAttributedString *chevronAttachment =
            ApolloAISymbolAttachment(expanded ? @"chevron.down" : @"chevron.right", chevronFont, secondary);
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:chevronAttributes]];
        if (chevronAttachment) {
            [result appendAttributedString:chevronAttachment];
        } else {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:expanded ? @"▾" : @"▸"
                                                                           attributes:chevronAttributes]];
        }
    }

    if (!expanded) return result;

    // Body (expanded). Loading shows streamed text if we have any, else a
    // placeholder; ready shows the summary + a trust caption; error shows the
    // message in the warning color.
    NSString *body = bodyText;
    if (state == ApolloAIBoxStateTapToSummarize) {
        body = isPost ? @"Tap to summarize this post." : @"Tap to summarize the discussion.";
    } else if (state == ApolloAIBoxStateLoading && body.length == 0) {
        body = isPost ? @"Summarizing…" : @"Summarizing discussion…";
    } else if (state == ApolloAIBoxStateError && body.length == 0) {
        body = @"Couldn't generate this summary.";
    }
    if (body.length > 0) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:bodyAttributes]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:body attributes:bodyAttributes]];
    }
    if (state == ApolloAIBoxStateReady) {
        // Quiet trust/expectation footer so the summary isn't mistaken for the
        // author's own words.
        NSString *caption = (!isPost && sourceCount > 0)
            ? [NSString stringWithFormat:@"\n\nAI-generated · Based on %lu representative comments · may be inaccurate",
                                         (unsigned long)sourceCount]
            : @"\n\nAI-generated · may be inaccurate";
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:caption
                                                                       attributes:captionAttributes]];
    }
    return result;
}

static void ApolloAIRenderSummaryNode(id headerNode, BOOL isPost);

static ASTextNode *ApolloAIEnsureSummaryNode(id headerNode, BOOL isPost) {
    const void *key = isPost ? &kApolloAIPostSummaryNodeKey : &kApolloAICommentSummaryNodeKey;
    ASTextNode *textNode = objc_getAssociatedObject(headerNode, key);
    if (textNode) return textNode;

    Class textNodeClass = NSClassFromString(@"ASTextNode");
    if (!textNodeClass) return nil;
    textNode = [[textNodeClass alloc] init];
    textNode.maximumNumberOfLines = 0;
    textNode.userInteractionEnabled = YES;
    objc_setAssociatedObject(textNode, &kApolloAISummaryOwnerKey, headerNode, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(textNode, &kApolloAISummaryIsPostKey, @(isPost), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ASTextNode *weakTextNode = textNode;
    [textNode onDidLoad:^(__kindof ASDisplayNode *node) {
        ASTextNode *strongTextNode = weakTextNode;
        id owner = objc_getAssociatedObject(strongTextNode, &kApolloAISummaryOwnerKey);
        if (!owner || !strongTextNode.view) return;
        SEL action = isPost ? NSSelectorFromString(@"apollo_togglePostSummary")
                            : NSSelectorFromString(@"apollo_toggleDiscussionSummary");
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:owner action:action];
        [strongTextNode.view addGestureRecognizer:tap];
        strongTextNode.view.accessibilityTraits |= UIAccessibilityTraitButton;
        strongTextNode.view.accessibilityLabel = isPost ? @"Post summary" : @"Discussion so far";
    }];
    [headerNode addSubnode:textNode];
    objc_setAssociatedObject(headerNode, key, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return textNode;
}

static ASDisplayNode *ApolloAIEnsureBackgroundNode(id headerNode, BOOL isPost) {
    const void *key = isPost ? &kApolloAIPostSummaryBackgroundNodeKey
                             : &kApolloAICommentSummaryBackgroundNodeKey;
    ASDisplayNode *background = objc_getAssociatedObject(headerNode, key);
    if (background) return background;

    background = [[NSClassFromString(@"ASDisplayNode") alloc] init];
    UIColor *accent = ApolloAISummaryThemeAccent(headerNode);
    background.backgroundColor = [accent colorWithAlphaComponent:0.10];
    background.cornerRadius = 12.0;
    background.clipsToBounds = YES;
    background.borderWidth = 0.5;
    background.borderColor = [accent colorWithAlphaComponent:0.24].CGColor;
    [headerNode addSubnode:background];
    objc_setAssociatedObject(headerNode, key, background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return background;
}

static ApolloAIBoxState ApolloAIGetBoxState(id headerNode, BOOL isPost) {
    const void *stateKey = isPost ? &kApolloAIPostStateKey : &kApolloAICommentStateKey;
    return (ApolloAIBoxState)[objc_getAssociatedObject(headerNode, stateKey) integerValue];
}

static void ApolloAIRenderSummaryNode(id headerNode, BOOL isPost) {
    if (!headerNode) return;
    const void *summaryKey = isPost ? &kApolloAIPostSummaryKey : &kApolloAICommentSummaryKey;
    const void *errorKey = isPost ? &kApolloAIPostErrorKey : &kApolloAICommentErrorKey;
    const void *expandedKey = isPost ? &kApolloAIPostExpandedKey : &kApolloAICommentExpandedKey;
    ApolloAIBoxState state = ApolloAIGetBoxState(headerNode, isPost);
    if (state == ApolloAIBoxStateNone) return;
    BOOL expanded = [objc_getAssociatedObject(headerNode, expandedKey) boolValue];
    NSString *body = state == ApolloAIBoxStateError
        ? objc_getAssociatedObject(headerNode, errorKey)
        : objc_getAssociatedObject(headerNode, summaryKey);
    NSString *fullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
    NSUInteger sourceCount = isPost ? 0 : [sCommentSummarySourceCounts[fullName] unsignedIntegerValue];
    ASTextNode *textNode = ApolloAIEnsureSummaryNode(headerNode, isPost);
    NSString *title;
    if (isPost) {
        // The post box shows one of three titles depending on what was summarized:
        // the post body, an external article, or both together.
        if (fullName.length > 0 && [sBothSummaryPosts containsObject:fullName]) {
            title = @"Post/Link summary";
        } else if (fullName.length > 0 && [sLinkSummaryPosts containsObject:fullName]) {
            title = @"Link summary";
        } else {
            title = @"Post summary";
        }
    } else {
        title = @"Discussion so far";
    }
    textNode.attributedText = ApolloAISummaryAttributedText(
        title, state, body, expanded, isPost, sourceCount, ApolloAISummaryThemeAccent(headerNode));
    // Clamp the chevron-less collapsed states (idle / loading / empty) to a single
    // line so a long title + "· Tap to summarize" subtitle can't wrap. Ready/Error
    // collapsed cards KEEP their trailing chevron, so leave them unclamped — at large
    // Dynamic Type they may wrap rather than tail-truncate (and clip) the chevron.
    // Expanded cards need the full body, so they're unclamped too.
    BOOL clampToOneLine = !expanded && state != ApolloAIBoxStateReady && state != ApolloAIBoxStateError;
    textNode.maximumNumberOfLines = clampToOneLine ? 1 : 0;

    // VoiceOver: read the title + current body (summary / status / error) and
    // announce the collapsed/expanded state. Setting the label on the view
    // overrides the text node default, which would read only the title glyphs.
    UIView *nodeView = textNode.view;
    if (nodeView) {
        if (state == ApolloAIBoxStateEmpty) {
            // Terminal, non-interactive card: don't announce it as an expandable button.
            nodeView.accessibilityTraits &= ~UIAccessibilityTraitButton;
            nodeView.accessibilityLabel = [NSString stringWithFormat:@"%@. Nothing to summarize.", title];
            nodeView.accessibilityHint = nil;
        } else {
            nodeView.accessibilityTraits |= UIAccessibilityTraitButton;
            NSString *spoken = body.length ? body : (state == ApolloAIBoxStateLoading ? @"Summarizing" : @"");
            nodeView.accessibilityLabel = expanded
                ? [NSString stringWithFormat:@"%@. %@", title, spoken]
                : [NSString stringWithFormat:@"%@, collapsed", title];
            nodeView.accessibilityHint = @"Double tap to expand or collapse";
        }
    }
}

// Single source of truth for a box: set its state (+ ready/streamed text or
// error message) and re-render. No-ops if nothing changed so we don't trigger
// redundant relayouts.
// Returns YES iff the box's state/text actually changed (so callers can issue
// exactly one row-height remeasure on a real change, and skip it on a no-op —
// which is what keeps scroll redisplay from re-measuring an unchanged header).
static BOOL ApolloAISetBoxState(id headerNode, BOOL isPost, ApolloAIBoxState state, NSString *text) {
    if (!headerNode) return NO;
    const void *stateKey = isPost ? &kApolloAIPostStateKey : &kApolloAICommentStateKey;
    const void *summaryKey = isPost ? &kApolloAIPostSummaryKey : &kApolloAICommentSummaryKey;
    const void *errorKey = isPost ? &kApolloAIPostErrorKey : &kApolloAICommentErrorKey;
    const void *textKey = (state == ApolloAIBoxStateError) ? errorKey : summaryKey;
    const void *expandedKey = isPost ? &kApolloAIPostExpandedKey : &kApolloAICommentExpandedKey;

    ApolloAIBoxState oldState = ApolloAIGetBoxState(headerNode, isPost);
    NSString *oldText = objc_getAssociatedObject(headerNode, textKey);
    if (oldState == state && (text == oldText || [text isEqualToString:oldText])) return NO;

    // Collapsed by default so opening a comments view remains visually stable.
    // Generation and streaming still begin immediately in the background; the
    // compact title shows "Summarizing…" until the result is ready. Once the
    // user toggles it, that explicit choice is preserved on this header.
    if (!objc_getAssociatedObject(headerNode, expandedKey)) {
        objc_setAssociatedObject(headerNode, expandedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Decide whether a (re)appearing READY card should open itself — only on a
    // fresh header the user hasn't toggled yet, and never during loading (so text
    // doesn't visibly stream into an already-open card). Precedence:
    //   1. A remembered open/closed choice for this thread's card (sCardExpanded),
    //      so a card reopens in exactly the state the user left it in.
    //   2. Otherwise the auto defaults: "Open Summaries Automatically" (when not in
    //      tap mode) or the per-header expand-on-ready intent set when the user
    //      tapped this idle card to generate it. (The two are mutually exclusive in
    //      settings; the tap-mode guard keeps tap winning regardless.)
    // We set the real expanded flag here (not lazily) so existing readers — incl.
    // the ApolloAIAnyHeaderExpanded guard the ready call sites use to remeasure —
    // stay correct and the row visibly opens.
    const void *choiceKey = isPost ? &kApolloAIPostExpandChoiceKey : &kApolloAICommentExpandChoiceKey;
    const void *expandOnReadyKey = isPost ? &kApolloAIPostExpandOnReadyKey : &kApolloAICommentExpandOnReadyKey;
    NSString *boxFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
    BOOL autoExpandedNow = NO;
    if (state == ApolloAIBoxStateReady &&
        ![objc_getAssociatedObject(headerNode, choiceKey) boolValue] &&
        ![objc_getAssociatedObject(headerNode, expandedKey) boolValue]) {
        NSNumber *remembered = ApolloAIRememberedCardExpanded(boxFullName, isPost);
        BOOL wantAutoOpen = (sEnableAIAutoExpandSummaries && !sEnableTapToSummarize) ||
            [objc_getAssociatedObject(headerNode, expandOnReadyKey) boolValue];
        if (remembered != nil) {
            // Restore exactly how the user left this card; their choice wins over
            // the auto defaults, so mark it as an explicit choice on this header.
            objc_setAssociatedObject(headerNode, choiceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(headerNode, expandOnReadyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (remembered.boolValue) {
                objc_setAssociatedObject(headerNode, expandedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                autoExpandedNow = YES;
            }
        } else if (wantAutoOpen) {
            objc_setAssociatedObject(headerNode, expandedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(headerNode, expandOnReadyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            autoExpandedNow = YES;
        }
        // Remember an auto/tap open so it reopens the same way next time.
        if (autoExpandedNow) ApolloAIRememberCardExpanded(boxFullName, isPost, YES);
    } else if (state == ApolloAIBoxStateError || state == ApolloAIBoxStateEmpty ||
               state == ApolloAIBoxStateNone) {
        // The "open when ready" intent is moot once the box reaches a terminal
        // non-ready state — consume the one-shot so a leftover flag can never
        // silently re-open a later success on this header.
        objc_setAssociatedObject(headerNode, expandOnReadyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(headerNode, stateKey, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(headerNode, textKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloAIEnsureSummaryNode(headerNode, isPost);
    ApolloAIEnsureBackgroundNode(headerNode, isPost);
    ApolloAIRenderSummaryNode(headerNode, isPost);
    [headerNode invalidateCalculatedLayout];
    [headerNode setNeedsLayout];
    // If auto-expand just opened a card whose row was already measured at the
    // collapsed height (a cached/restored summary reaching Ready via a caller that
    // has no remeasure guard of its own — e.g. ApolloAIRestoreStateForHeader or the
    // cache-hit branches in ApolloAIGenerateForController), the table still holds
    // the old row height. Re-query it so the card visibly grows; node invalidation
    // alone does not re-measure an already-laid-out row (see ApolloAIForceHeaderRemeasure).
    if (autoExpandedNow) {
        NSString *remeasureFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (remeasureFullName.length > 0) ApolloAIForceHeaderRemeasure(remeasureFullName);
    }
    return YES;
}

// Returns YES iff at least one matching header actually changed state, so the
// caller can remeasure exactly once on a real change.
static BOOL ApolloAISetBoxStateOnMatchingHeaders(NSString *fullName, BOOL isPost, ApolloAIBoxState state, NSString *text) {
    if (fullName.length == 0) return NO;
    BOOL changed = NO;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *headerFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (headerFullName.length == 0) {
            headerFullName = ApolloAILinkFullName(ApolloAIScanForLink(headerNode));
        }
        if ([headerFullName isEqualToString:fullName]) {
            if (ApolloAISetBoxState(headerNode, isPost, state, text)) changed = YES;
        }
    }
    return changed;
}

// Promote idle (none) boxes for this post to the loading state, without
// disturbing a box that is already loading/ready/errored (so we never wipe
// streamed text or downgrade a finished summary).
static void ApolloAIShowLoadingIfIdle(NSString *fullName, BOOL isPost) {
    if (fullName.length == 0) return;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *headerFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (![headerFullName isEqualToString:fullName]) continue;
        if (ApolloAIGetBoxState(headerNode, isPost) == ApolloAIBoxStateNone) {
            ApolloAISetBoxState(headerNode, isPost, ApolloAIBoxStateLoading, nil);
        }
    }
}

// Apply the current known state of a post to a (re)appearing header — used when
// a header cell loads mid-generation or is recycled, so it doesn't show a blank
// box. Mirrors the caches / in-flight / failed bookkeeping.
// Apply the post/comment box state from the caches/in-flight/captured bookkeeping
// onto a (re)appearing header. Split out of ApolloAIRestoreStateForHeader so the
// whole cascade can be DEFERRED off the cell's first layout pass (see below).
// Returns nothing; remeasures + realizes display once, only on a real change.
static void ApolloAIApplyRestoredState(id headerNode, NSString *fullName) {
    if (!headerNode || fullName.length == 0) return;
    BOOL changed = NO;
    if ([sPostSuppressed containsObject:fullName]) {
        // No usable article content — keep the box hidden on recycle. Must be
        // checked BEFORE sPostFailed, or a recycled header would surface the
        // error triangle for a post we deliberately hid.
        if (ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateNone, nil)) changed = YES;
    } else if ([sPostEmpty containsObject:fullName]) {
        // Tapped link with nothing to summarize — keep the "Nothing to summarize"
        // card on recycle (Tap-to-Summarize counterpart of sPostSuppressed).
        if (ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateEmpty, nil)) changed = YES;
    } else if (sPostSummaryCache[fullName].length > 0) {
        if (ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateReady, sPostSummaryCache[fullName])) changed = YES;
    } else if ([sPostFailed containsObject:fullName]) {
        if (ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateError, nil)) changed = YES;
    } else if ([sPostInFlight containsObject:fullName]) {
        if (ApolloAISetBoxState(headerNode, YES, ApolloAIBoxStateLoading, nil)) changed = YES;
    }
    if (sCommentSummaryCache[fullName].length > 0) {
        if (ApolloAISetBoxState(headerNode, NO, ApolloAIBoxStateReady, sCommentSummaryCache[fullName])) changed = YES;
    } else if ([sCommentFailed containsObject:fullName]) {
        if (ApolloAISetBoxState(headerNode, NO, ApolloAIBoxStateError, nil)) changed = YES;
    } else if ([sCommentInFlight containsObject:fullName]) {
        // A generation is genuinely running -> show the loading card.
        if (ApolloAISetBoxState(headerNode, NO, ApolloAIBoxStateLoading, nil)) changed = YES;
    } else if ([sCapturedComments[fullName] count] >= kApolloAIMinComments) {
        // Enough discussion captured, but nothing is in flight yet. The state to
        // restore depends on the mode, and MUST match what ApolloAIGenerateForController
        // would set (same predicate) or a recycled/reappearing header desyncs:
        //   • Auto mode: the generation pass drives it, so Loading is the correct
        //     placeholder while that kicks off.
        //   • Tap-to-Summarize, not yet tapped: the idle "Tap to summarize" prompt.
        //     Restoring Loading here was the bug — it left the discussion card stuck
        //     on "Summarizing…" forever, because no request is ever in flight until
        //     the user taps, and a Loading card isn't tappable-to-generate (the tap
        //     handler only starts generation from the TapToSummarize state), so the
        //     user was wedged with a spinner that never resolved.
        //   • Tap-to-Summarize, already tapped (key present, e.g. mid concurrency
        //     retry): keep Loading, since generation is pending.
        NSString *commentTapKey = [@"comment|" stringByAppendingString:fullName];
        BOOL awaitingTap = sEnableTapToSummarize && ![sTapRequested containsObject:commentTapKey];
        ApolloAIBoxState restored = awaitingTap ? ApolloAIBoxStateTapToSummarize
                                                : ApolloAIBoxStateLoading;
        if (ApolloAISetBoxState(headerNode, NO, restored, nil)) changed = YES;
    }
    if (changed) {
        // Re-query the row height AND force a real display pass (see
        // ApolloAIForceHeaderRemeasureForNode). Already on a later runloop turn
        // (this whole function is dispatched), so no re-entrancy concern.
        ApolloAIForceHeaderRemeasureForNode(headerNode, fullName, 2);
    }
}

// Apply the current known state of a post to a (re)appearing header — used when a
// header cell loads mid-generation or is recycled, so it doesn't show a blank box.
//
// #526 (round 2): we DEFER the whole state application to the next runloop turn
// instead of applying it synchronously here. RestoreStateForHeader runs from the
// header cell's didLoad/didEnterDisplayState DURING the push transition, before
// the fresh cell has had its first natural (boxless) layout + DISPLAY pass. On a
// cache hit, applying Ready synchronously injects the AI card into that very first
// pass: the row then measures TALL (the spec reserves the card's height) but the
// freshly-attached card/background subnodes — and the toolbar that shares the
// rebuilt lower stack — never get a display pass for that layout, so the lower
// half draws BLANK (the empty gap users reported; round 1's begin/endUpdates
// couldn't fix it because re-querying a cached height can't realize a missing
// layer). Deferring makes the cell measure + display boxless FIRST — exactly the
// known-good first-entry timing — then introduces the card a turn later on a live,
// displaying node, where ApplyRestoredState remeasures AND force-realizes display.
static void ApolloAIRestoreStateForHeader(id headerNode, NSString *fullName) {
    if (!headerNode || fullName.length == 0) return;
    __weak id weakHeader = headerNode;
    NSString *fn = [fullName copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        id strong = weakHeader;
        if (strong) ApolloAIApplyRestoredState(strong, fn);
    });
}

// Hide a post's link/article box: the linked page yielded no usable prose
// (score-card, JS-only SPA, paywall stub), or the model couldn't make a summary
// of what little there was. The user wants nothing rather than a scary
// "couldn't summarize" triangle on such links, so we mark the post suppressed
// (recycled headers stay hidden, no re-fetch while on screen) and clear the
// in-flight / failed / link-mode bookkeeping that could resurrect a box. The
// suppression is per-view — viewDidDisappear clears it, so a reopen re-attempts.
static void ApolloAISuppressLinkSummary(NSString *fullName) {
    if (fullName.length == 0) return;
    [sPostInFlight removeObject:fullName];
    [sPostRequestIDs removeObjectForKey:fullName];
    [sPostFailed removeObject:fullName];        // NOT an error — don't show the triangle
    [sBothSummaryPosts removeObject:fullName];
    if (sEnableTapToSummarize) {
        // Tap-to-Summarize: the user explicitly tapped this card, so silently
        // vanishing reads as a glitch (they asked for a summary and got nothing).
        // Keep the card and show a terminal "Nothing to summarize" instead. We
        // leave it in sLinkSummaryPosts so the card still reads "Link summary".
        [sPostEmpty addObject:fullName];
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateEmpty, nil);
    } else {
        // Automatic mode: the card was never requested, so hide it entirely (the
        // original behaviour — no error triangle, no re-fetch while on screen).
        [sLinkSummaryPosts removeObject:fullName];
        [sPostSuppressed addObject:fullName];
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateNone, nil);
    }
    ApolloAIForceHeaderRemeasure(fullName);     // re-lay-out the box now
}

// Short, user-facing message for a generation error shown inside the box. The
// bridge classifies thrown FoundationModels errors into stable codes (see
// ApolloFoundationModels.classify); we branch on those rather than on the
// localized text, which differs per language.
static NSString *ApolloAIFriendlyError(NSError *error) {
    switch (error.code) {
        case 1:
            return @"Apple Intelligence isn't enabled. Turn it on in Settings, and make sure your device and Siri language match a supported language.";
        case 2:
            return @"The on-device model is still downloading. Try again shortly.";
        case 7:
            return @"The model declined to summarize this content.";
        case 8:
            return @"This thread is too long to summarize on-device.";
        case 10:
            return @"Summaries aren't available for this language yet.";
        default:
            break;
    }
    // Last-resort fallback for an uncategorized error (e.g. a non-bridge NSError).
    NSString *d = error.localizedDescription ?: @"";
    if ([d localizedCaseInsensitiveContainsString:@"not enabled"])
        return @"Apple Intelligence isn't enabled. Turn it on in Settings, and make sure your device and Siri language match a supported language.";
    if ([d localizedCaseInsensitiveContainsString:@"download"])
        return @"The on-device model is still downloading. Try again shortly.";
    return @"Couldn't generate this summary.";
}

// Code 9 = rate-limited / concurrent-request throttling: the model is busy, not
// a hard failure, so the caller retries shortly instead of showing an error.
static BOOL ApolloAIErrorIsTransientConcurrency(NSError *error) {
    return error.code == 9;
}

// Force a header cell node's AI card/background subnodes (and the re-parented
// lower stack — toolbar, etc.) to actually DRAW. begin/endUpdates only re-queries
// the cached row HEIGHT; on re-entry the box state is applied before the fresh
// cell's first display pass, so the card subnodes get a reserved frame (the row
// measures TALL) but their backing layers are never realized for that display
// cycle → a tall, empty/undrawn gap (#526). A re-query cannot realize a missing
// layer; only a real top-down layout + display pass can. That is exactly what
// backgrounding→foregrounding does (which users found fixes it), reproduced here
// synchronously and scoped to the one header. Selectors resolved at runtime so we
// don't depend on private ASDisplayKit headers, and guarded so a node that isn't
// loaded yet is skipped rather than force-loaded.
static void ApolloAIRealizeHeaderNodeDisplay(id headerNode) {
    if (!headerNode) return;
    if ([headerNode respondsToSelector:@selector(isNodeLoaded)] &&
        !(((BOOL (*)(id, SEL))objc_msgSend)(headerNode, @selector(isNodeLoaded)))) return;
    if ([headerNode respondsToSelector:@selector(setNeedsLayout)])
        ((void (*)(id, SEL))objc_msgSend)(headerNode, @selector(setNeedsLayout));
    if ([headerNode respondsToSelector:@selector(layoutIfNeeded)])
        ((void (*)(id, SEL))objc_msgSend)(headerNode, @selector(layoutIfNeeded));
    if ([headerNode respondsToSelector:@selector(recursivelyEnsureDisplaySynchronously:)])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(headerNode, @selector(recursivelyEnsureDisplaySynchronously:), YES);
}

// Realize display on every live header for this post (used by the fullName-keyed
// remeasure path, which has no single node reference).
static void ApolloAIRealizeHeadersForFullName(NSString *fullName) {
    if (fullName.length == 0) return;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *hfn = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if ([hfn isEqualToString:fullName]) ApolloAIRealizeHeaderNodeDisplay(headerNode);
    }
}

static void ApolloAIForceHeaderRemeasure(NSString *fullName) {
    UIViewController *vc = [sControllerByFullName objectForKey:fullName];
    UITableView *tableView = ApolloAICommentsTableView(vc);
    if (!tableView) return;

    // Texture has already cached the row's old height. begin/end updates asks
    // the backing UITableView to query the node's newly invalidated layout, then
    // we force the affected header(s) to actually draw (see
    // ApolloAIRealizeHeaderNodeDisplay — fixes the tall-but-undrawn gap, #526).
    [tableView beginUpdates];
    [tableView endUpdates];
    ApolloAIRealizeHeadersForFullName(fullName);
    ApolloLog(@"[AISummary][UI] requested header remeasure+realize for %@", fullName);
}

// Resolve the comments UITableView straight from the header cell node's own view
// hierarchy. The header (an ASCellNode) is hosted inside its UITableView well
// before viewDidAppear registers the controller in sControllerByFullName — and
// re-entry restores the box from didLoad/didEnterDisplayState, DURING the push
// transition, when that registration hasn't happened yet. Resolving from the node
// makes the re-entry remeasure independent of controller registration timing,
// which is what makes the #526 fix deterministic rather than racy.
static UITableView *ApolloAITableViewForHeaderNode(id headerNode) {
    if (!headerNode || ![headerNode respondsToSelector:@selector(view)]) return nil;
    // Don't force a node to load its backing view just to look for a table.
    if ([headerNode respondsToSelector:@selector(isNodeLoaded)] &&
        !(((BOOL (*)(id, SEL))objc_msgSend)(headerNode, @selector(isNodeLoaded)))) return nil;
    UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(headerNode, @selector(view));
    for (UIView *cur = v; cur; cur = cur.superview) {
        if ([cur isKindOfClass:[UITableView class]]) return (UITableView *)cur;
    }
    return nil;
}

// Re-query a header's row height, finding the table from the NODE first (preferred,
// works mid-transition) and falling back to the controller map. Same begin/end
// updates mechanism as ApolloAIForceHeaderRemeasure: ApolloAISetBoxState only
// invalidates the node's calculated layout, NOT the UITableView's cached row
// height, so a box restored on re-entry would otherwise compose into a row sized
// for the old (boxless) content and render as an empty/clipped card (#526). If no
// table resolves yet (cell not attached AND controller not registered), retry on
// the next runloop turn — by then the cell is on screen — capped so it can't loop.
static void ApolloAIForceHeaderRemeasureForNode(id headerNode, NSString *fullName, NSInteger attemptsLeft) {
    if (!headerNode) return;
    UITableView *tableView = ApolloAITableViewForHeaderNode(headerNode);
    if (!tableView) {
        UIViewController *vc = [sControllerByFullName objectForKey:fullName];
        tableView = ApolloAICommentsTableView(vc);
    }
    if (!tableView) {
        if (attemptsLeft > 0) {
            __weak id weakHeader = headerNode;
            dispatch_async(dispatch_get_main_queue(), ^{
                id strong = weakHeader;
                if (strong) ApolloAIForceHeaderRemeasureForNode(strong, fullName, attemptsLeft - 1);
            });
        }
        return;
    }
    [tableView beginUpdates];
    [tableView endUpdates];
    // The actual #526 cure: re-querying the height above is not enough on
    // re-entry (the row is already TALL but the card/toolbar layers were never
    // drawn). Force a real top-down layout + display pass on this header.
    ApolloAIRealizeHeaderNodeDisplay(headerNode);
    ApolloLog(@"[AISummary][UI] re-entry remeasure+realize for %@ (table=%p)", fullName, tableView);
}

// Is any live header for this post currently showing the expanded body of the
// given summary type? If not, streaming text into it changes nothing visible
// (the collapsed card shows only its title), so we can skip the expensive
// full-table remeasure entirely while still keeping the cached text current.
static BOOL ApolloAIAnyHeaderExpanded(NSString *fullName, BOOL isPost) {
    if (fullName.length == 0) return NO;
    const void *expandedKey = isPost ? &kApolloAIPostExpandedKey : &kApolloAICommentExpandedKey;
    for (id headerNode in sHeaderNodes.allObjects) {
        NSString *headerFullName = objc_getAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey);
        if (![headerFullName isEqualToString:fullName]) continue;
        if ([objc_getAssociatedObject(headerNode, expandedKey) boolValue]) return YES;
    }
    return NO;
}

// Grow the box token-by-token as the model streams, so it feels responsive
// rather than sitting on a placeholder until done. Throttled, and the table
// remeasure only fires when the box is expanded (its height actually tracks the
// growing text), keeping the relayout churn in check.
static const BOOL kApolloAIStreamPartialsToUI = YES;

static void ApolloAIApplyStreamingPartial(NSString *fullName, BOOL isPost, NSString *partial) {
    if (!kApolloAIStreamPartialsToUI) return;
    if (fullName.length == 0 || partial.length < 40) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", isPost ? @"post" : @"comment", fullName];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval last = sLastPartialUIUpdate[key].doubleValue;
    if (last > 0 && now - last < 0.25) return;
    sLastPartialUIUpdate[key] = @(now);

    NSString *normalized = ApolloAINormalizeGeneratedSummary(partial);
    // Stream into the (already-visible) loading box. Only pay for a remeasure
    // when expanded, since the collapsed box height doesn't track the text.
    ApolloAISetBoxStateOnMatchingHeaders(fullName, isPost, ApolloAIBoxStateLoading, normalized);
    if (ApolloAIAnyHeaderExpanded(fullName, isPost)) {
        ApolloAIForceHeaderRemeasure(fullName);
    }
}

static void ApolloAIScheduleCommentGeneration(UIViewController *vc) {
    if (!vc || !sEnableAISummaries) return;
    NSString *fullName = ApolloAIFullNameForController(vc);
    if (fullName.length == 0 || [sCommentGenerationScheduled containsObject:fullName]) return;
    [sCommentGenerationScheduled addObject:fullName];

    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [sCommentGenerationScheduled removeObject:fullName];
        UIViewController *strongVC = weakVC;
        if (!strongVC || !strongVC.view.window) return;
        ApolloAIGenerateForController(strongVC);
    });
}

static void ApolloAIScheduleGenerationTimeout(NSString *fullName, BOOL isPost, NSString *requestID) {
    if (fullName.length == 0 || requestID.length == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kApolloAIGenerationTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSMutableSet *inFlight = isPost ? sPostInFlight : sCommentInFlight;
        NSMutableDictionary *requestIDs = isPost ? sPostRequestIDs : sCommentRequestIDs;
        if (![inFlight containsObject:fullName] ||
            ![requestIDs[fullName] isEqualToString:requestID]) return;
        [sTimedOutRequests addObject:requestID];
        [inFlight removeObject:fullName];
        [requestIDs removeObjectForKey:fullName];
        [(ApolloFoundationModels *)ApolloAIBridge() cancelRequest:requestID];
        // A pure link/article post that times out has nothing to show but the
        // article it couldn't fetch/summarize — hide it rather than leave a
        // triangle, same as a no-prose result.
        if (isPost && [sLinkSummaryPosts containsObject:fullName]) {
            ApolloLog(@"[AISummary] link summary timed out for %@ — hiding", fullName);
            ApolloAISuppressLinkSummary(fullName);
            return;
        }
        NSMutableSet *failed = isPost ? sPostFailed : sCommentFailed;
        [failed addObject:fullName];
        ApolloAISetBoxStateOnMatchingHeaders(
            fullName, isPost, ApolloAIBoxStateError,
            @"This summary took too long. Reopen the post to try again.");
        if (ApolloAIAnyHeaderExpanded(fullName, isPost)) {
            ApolloAIForceHeaderRemeasure(fullName);
        }
        ApolloLog(@"[AISummary] %@ summary timed out for %@",
                  isPost ? @"post" : @"comment", fullName);
    });
}

static void ApolloAIRegisterHeaderNodeForFullName(id headerNode, NSString *knownFullName) {
    if (!headerNode) return;
    ApolloAIEnsureState();
    [sHeaderNodes addObject:headerNode];

    NSString *fullName = knownFullName;
    if (fullName.length == 0) {
        fullName = ApolloAILinkFullName(ApolloAIScanForLink(headerNode));
    }
    if (fullName.length == 0) return;
    objc_setAssociatedObject(headerNode, &kApolloAIHeaderFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloAIRestoreStateForHeader(headerNode, fullName);
    ApolloLog(@"[AISummary][UI] registered header=%p fullName=%@ post=%lu comment=%lu",
              headerNode, fullName,
              (unsigned long)sPostSummaryCache[fullName].length,
              (unsigned long)sCommentSummaryCache[fullName].length);
}

static void ApolloAIRegisterHeaderNode(id headerNode) {
    ApolloAIRegisterHeaderNodeForFullName(headerNode, nil);
}

static id ApolloAISummaryLayoutSpec(id textNode, id backgroundNode) {
    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    Class backgroundClass = NSClassFromString(@"ASBackgroundLayoutSpec");
    if (!insetClass || !backgroundClass || !textNode || !backgroundNode) return nil;
    id inner = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(12.0, 14.0, 12.0, 14.0)
                                               child:textNode];
    id card = [backgroundClass backgroundLayoutSpecWithChild:inner background:backgroundNode];
    return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(8.0, 12.0, 8.0, 12.0)
                                           child:card];
}

// Rebuild a stack spec with new children, preserving its layout attributes.
static ASStackLayoutSpec *ApolloAIRebuildStack(ASStackLayoutSpec *stack, NSArray *children) {
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    ASStackLayoutSpec *s = [stackClass stackLayoutSpecWithDirection:stack.direction
                                                            spacing:stack.spacing
                                                     justifyContent:stack.justifyContent
                                                         alignItems:stack.alignItems
                                                           children:children];
    s.flexWrap = stack.flexWrap;
    s.alignContent = stack.alignContent;
    s.lineSpacing = stack.lineSpacing;
    return s;
}

// Insert the post/link/both summary spec at the right spot, recursing into nested
// stacks. Preference: directly AFTER the inline link-preview card (LinkButtonNode)
// — for a link/both post that puts the summary between the preview and the body;
// for a plain text post (no preview) just before the body MarkdownNode. Self-posts
// wrap their content (preview + body) in a nested ASStackLayoutSpec, so we must
// descend to find the anchor rather than only scanning the top level. Returns a
// rebuilt stack, or nil if no anchor was found anywhere.
static ASStackLayoutSpec *ApolloAIInsertPostSummary(ASStackLayoutSpec *stack, id spec, NSUInteger depth) {
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (![stack isKindOfClass:stackClass] || depth > 4) return nil;
    Class linkButtonClass = NSClassFromString(@"_TtC6Apollo14LinkButtonNode");
    Class markdownClass = NSClassFromString(@"_TtC6Apollo12MarkdownNode");
    NSArray *children = stack.children ?: @[];

    // 1) Directly below the inline link-preview card.
    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        if ((linkButtonClass && [c isKindOfClass:linkButtonClass]) ||
            [NSStringFromClass([c class]) isEqualToString:@"Apollo.LinkButtonNode"]) {
            NSMutableArray *m = [children mutableCopy];
            [m insertObject:spec atIndex:i + 1];
            return ApolloAIRebuildStack(stack, m);
        }
    }
    // 2) Just before the body markdown (plain text post: between title and body).
    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        if ((markdownClass && [c isKindOfClass:markdownClass]) ||
            [NSStringFromClass([c class]) isEqualToString:@"Apollo.MarkdownNode"]) {
            NSMutableArray *m = [children mutableCopy];
            [m insertObject:spec atIndex:i];
            return ApolloAIRebuildStack(stack, m);
        }
    }
    // 3) Descend into a nested content stack and splice the rebuilt child back in.
    for (NSUInteger i = 0; i < children.count; i++) {
        id c = children[i];
        if ([c isKindOfClass:stackClass]) {
            ASStackLayoutSpec *rebuilt = ApolloAIInsertPostSummary((ASStackLayoutSpec *)c, spec, depth + 1);
            if (rebuilt) {
                NSMutableArray *m = [children mutableCopy];
                m[i] = rebuilt;
                return ApolloAIRebuildStack(stack, m);
            }
        }
    }
    return nil;
}

static ASStackLayoutSpec *ApolloAICloneStackWithSummaries(ASStackLayoutSpec *originalStack,
                                                          id postSummarySpec,
                                                          id discussionSummarySpec) {
    if (!originalStack || (!postSummarySpec && !discussionSummarySpec)) return nil;
    ASStackLayoutSpec *working = originalStack;

    if (postSummarySpec) {
        ASStackLayoutSpec *rebuilt = ApolloAIInsertPostSummary(working, postSummarySpec, 0);
        if (rebuilt) {
            working = rebuilt;
        } else {
            // No preview/body anchor anywhere — place near the top, after the title.
            NSMutableArray *m = [working.children ?: @[] mutableCopy];
            [m insertObject:postSummarySpec atIndex:MIN((NSUInteger)1, m.count)];
            working = ApolloAIRebuildStack(working, m);
        }
    }

    // Discussion summary stays at the bottom of the post header, immediately
    // before the first comment.
    if (discussionSummarySpec) {
        NSMutableArray *m = [working.children ?: @[] mutableCopy];
        [m addObject:discussionSummarySpec];
        working = ApolloAIRebuildStack(working, m);
    }

    return working;
}

// Preserve Apollo's root width/inset semantics. The comments header currently
// returns ASInsetLayoutSpec -> ASStackLayoutSpec; recurse through inset wrappers
// and only replace the existing stack with a property-for-property clone.
static id ApolloAIPlaceSummariesPreservingRoot(id rootSpec,
                                               id postSummarySpec,
                                               id discussionSummarySpec) {
    if (!rootSpec || (!postSummarySpec && !discussionSummarySpec)) return nil;

    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (stackClass && [rootSpec isKindOfClass:stackClass]) {
        return ApolloAICloneStackWithSummaries((ASStackLayoutSpec *)rootSpec,
                                               postSummarySpec,
                                               discussionSummarySpec);
    }

    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    if (insetClass && [rootSpec isKindOfClass:insetClass]) {
        ASInsetLayoutSpec *originalInset = (ASInsetLayoutSpec *)rootSpec;
        id newChild = ApolloAIPlaceSummariesPreservingRoot(originalInset.child,
                                                           postSummarySpec,
                                                           discussionSummarySpec);
        if (!newChild) return nil;
        return [insetClass insetLayoutSpecWithInsets:originalInset.insets child:newChild];
    }

    return nil;
}

static void ApolloAILogLayoutChildrenOnce(id headerNode, id rootSpec) {
    static NSHashTable *loggedHeaders;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loggedHeaders = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (loggedHeaders) {
        if ([loggedHeaders containsObject:headerNode]) return;
        [loggedHeaders addObject:headerNode];
    }

    id current = rootSpec;
    NSUInteger depth = 0;
    Class insetClass = NSClassFromString(@"ASInsetLayoutSpec");
    while (insetClass && [current isKindOfClass:insetClass] && depth < 8) {
        current = ((ASInsetLayoutSpec *)current).child;
        depth++;
    }
    Class stackClass = NSClassFromString(@"ASStackLayoutSpec");
    if (![current isKindOfClass:stackClass]) {
        ApolloLog(@"[AISummary][layout] root=%@ unwrapped=%@",
                  NSStringFromClass([rootSpec class]), NSStringFromClass([current class]));
        return;
    }

    NSArray *children = ((ASStackLayoutSpec *)current).children ?: @[];
    NSMutableArray *classes = [NSMutableArray arrayWithCapacity:children.count];
    for (id child in children) {
        [classes addObject:NSStringFromClass([child class]) ?: @"nil"];
    }
    ApolloLog(@"[AISummary][layout] root=%@ insetDepth=%lu children=%@",
              NSStringFromClass([rootSpec class]), (unsigned long)depth, classes);
}

#pragma mark - Generation

static NSString *ApolloAIRequestIdentifier(NSString *fullName, BOOL isPost) {
    return [NSString stringWithFormat:@"%@|%@", isPost ? @"post" : @"comment", fullName ?: @"unknown"];
}

static NSString *ApolloAIProvisionalPostRequestIdentifier(UIViewController *vc) {
    NSString *existing = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
    if (existing.length > 0) return existing;
    NSString *identifier = [NSString stringWithFormat:@"post|controller-%p", vc];
    objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey,
                             identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return identifier;
}

static NSString *ApolloAIProvisionalCommentRequestIdentifier(UIViewController *vc) {
    NSString *existing = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
    if (existing.length > 0) return existing;
    NSString *identifier = [NSString stringWithFormat:@"comment|controller-%p", vc];
    objc_setAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey,
                             identifier, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return identifier;
}

// Called in viewWillAppear, before the header is on screen and before comments
// finish loading. This gives the actual instructed post session useful time to
// load model/guardrail assets. If there is no self-text, prepare the comments
// session instead.
static void ApolloAIPrepareForController(UIViewController *vc) {
    if (!vc || !sEnableAISummaries) return;
    ApolloFoundationModels *bridge = ApolloAIBridge();
    id link = ApolloAILinkFromController(vc);
    NSString *fullName = ApolloAILinkFullName(link);
    if (!bridge) return;

    // Apollo often has not attached the RDKLink yet at viewWillAppear. Prepare
    // a controller-scoped post session anyway; generation will either consume
    // it once the link resolves or discard it for a link/image post.
    if (!link || fullName.length == 0) {
        NSString *postID = ApolloAIProvisionalPostRequestIdentifier(vc);
        NSString *commentID = ApolloAIProvisionalCommentRequestIdentifier(vc);
        [bridge prepareSession:postID instructions:kApolloAIPostInstructions];
        [bridge prepareSession:commentID instructions:kApolloAICommentInstructions];
        ApolloLog(@"[AISummary] prepared provisional sessions post=%@ comment=%@", postID, commentID);
        return;
    }

    BOOL needsPost = sEnableAIPostSummaries &&
        ApolloAIPostText(link).length > 0 &&
        sPostSummaryCache[fullName].length == 0 &&
        ![sPostFailed containsObject:fullName];
    BOOL needsComments = sEnableAICommentSummaries &&
        sCommentSummaryCache[fullName].length == 0 &&
        ![sCommentFailed containsObject:fullName];
    if (needsPost) {
        [bridge prepareSession:ApolloAIRequestIdentifier(fullName, YES)
                  instructions:kApolloAIPostInstructions];
        ApolloLog(@"[AISummary] prepared POST session for %@", fullName);
    }
    if (needsComments) {
        [bridge prepareSession:ApolloAIRequestIdentifier(fullName, NO)
                  instructions:kApolloAICommentInstructions];
        ApolloLog(@"[AISummary] prepared COMMENT session for %@", fullName);
    }
}

// Summarize text into the post box with the given instructions/token budget.
// Used for the Link summary (article), the Both summary (post + article), and the
// Post-summary fallback when an article can't be fetched. Factored out so a
// transient-concurrency retry re-summarizes the cached text without re-fetching.
static void ApolloAISummarizeArticleText(NSString *fullName, NSString *requestID, NSString *text,
                                         NSString *instructions, NSInteger responseTokens) {
    ApolloFoundationModels *bridge = ApolloAIBridge();
    if (!bridge || fullName.length == 0 || text.length == 0) return;
    ApolloLog(@"[AISummary] generating link/article summary for %@ (%lu chars)…", fullName, (unsigned long)text.length);
    [bridge prepareSession:requestID instructions:instructions];
    [bridge summarize:text
           identifier:requestID
         instructions:instructions
maximumResponseTokens:responseTokens
            onPartial:^(NSString *partial) {
                ApolloAIApplyStreamingPartial(fullName, YES, partial);
            }
           onComplete:^(NSString *final, NSError *error) {
                [sPostInFlight removeObject:fullName];
                if ([sPostRequestIDs[fullName] isEqualToString:requestID]) {
                    [sPostRequestIDs removeObjectForKey:fullName];
                }
                if ([sTimedOutRequests containsObject:requestID]) {
                    [sTimedOutRequests removeObject:requestID];
                    return;
                }
                if (error.code == 6) return; // navigation cancellation
                final = ApolloAINormalizeGeneratedSummary(final);
                if (error || final.length == 0) {
                    if (ApolloAIErrorIsTransientConcurrency(error)) {
                        ApolloLog(@"[AISummary] link request deferred by model concurrency for %@", fullName);
                        UIViewController *controller = [sControllerByFullName objectForKey:fullName];
                        if (controller) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                ApolloAIGenerateForController(controller);
                            });
                        }
                        return;
                    }
                    // Pure link/article post (no body to fall back on): if the
                    // model can't summarize the little prose we scraped, the user
                    // wants nothing rather than a "couldn't summarize" triangle.
                    // Hide it. (Both / post-fallback summaries keep the error —
                    // there the post body itself is the thing that failed.)
                    if ([sLinkSummaryPosts containsObject:fullName]) {
                        ApolloLog(@"[AISummary] link summary unusable for %@ (%@) — hiding", fullName,
                                  error ? error.localizedDescription : @"empty");
                        ApolloAISuppressLinkSummary(fullName);
                        return;
                    }
                    [sPostFailed addObject:fullName];
                    NSString *msg = error ? ApolloAIFriendlyError(error) : @"The model returned an empty summary.";
                    ApolloLog(@"[AISummary] link summary error: %@", error ? error.localizedDescription : @"(empty)");
                    ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateError, msg);
                    if (ApolloAIAnyHeaderExpanded(fullName, YES)) {
                        ApolloAIForceHeaderRemeasure(fullName);
                    }
                    return;
                }
                sPostSummaryCache[fullName] = final;
                sPostSummaryMode[fullName] = @(ApolloAIDesiredPostMode(fullName));
                ApolloAIStampSummary(fullName);
                ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateReady, final);
                if (ApolloAIAnyHeaderExpanded(fullName, YES)) {
                    ApolloAIForceHeaderRemeasure(fullName);
                }
                ApolloAIPersistSummaries();
                // Never log generated text: exported diagnostics may be shared
                // publicly and summaries can contain private or sensitive content.
                ApolloLog(@"[AISummary] LINK summary DONE for %@ (%lu chars)",
                          fullName, (unsigned long)final.length);
            }];
}

// External-article link post: show the post box as a "Link summary", fetch the
// article (or reuse cached text), then summarize it. Shares the post box, cache,
// in-flight guard, timeout and request id with the self-text post summary, since a
// given post is one or the other — never both.
static void ApolloAIGenerateLinkSummaryForController(NSString *articleURL, NSString *fullName, NSString *postText) {
    ApolloFoundationModels *bridge = ApolloAIBridge();
    if (!bridge || fullName.length == 0 || articleURL.length == 0) return;

    [sPostInFlight addObject:fullName];
    ApolloAIShowLoadingIfIdle(fullName, YES);   // box visible immediately ("Link"/"Post & link summary")
    ApolloAIForceHeaderRemeasure(fullName);

    NSString *requestID = ApolloAIRequestIdentifier(fullName, YES);
    sPostRequestIDs[fullName] = requestID;
    ApolloAIScheduleGenerationTimeout(fullName, YES, requestID);   // covers fetch + generation

    // Summarize the fetched article — combined with the post body when there is
    // one ("Post & link" summary), otherwise the article alone ("Link" summary).
    void (^summarize)(NSString *) = ^(NSString *articleText) {
        if (postText.length > 0) {
            NSString *article = articleText.length > 2000 ? [articleText substringToIndex:2000] : articleText;
            NSString *combined = [NSString stringWithFormat:@"Post:\n%@\n\nLinked article:\n%@", postText, article];
            ApolloAISummarizeArticleText(fullName, requestID, combined,
                                         kApolloAIBothInstructions, kApolloAIBothResponseTokens);
        } else {
            ApolloAISummarizeArticleText(fullName, requestID, articleText,
                                         kApolloAIArticleInstructions, kApolloAIArticleResponseTokens);
        }
    };

    NSString *cachedText = sArticleTextCache[fullName];
    if (cachedText.length > 0) { summarize(cachedText); return; }

    ApolloLog(@"[AISummary] fetching article for %@ summary %@ (%@)…",
              postText.length > 0 ? @"POST+LINK" : @"LINK", fullName, articleURL);
    ApolloAIFetchArticleText(articleURL, ^(NSString *articleText, NSError *fetchError) {
        // Back on the main thread. Bail if this request was superseded (timed out
        // or the user navigated and a newer request took over).
        if (![sPostInFlight containsObject:fullName] ||
            ![sPostRequestIDs[fullName] isEqualToString:requestID]) {
            return;
        }
        if (fetchError || articleText.length < 200) {
            if (postText.length > 0) {
                // Couldn't read the article (clip page / SPA / paywall), but we DO
                // have the post body — fall back to a plain Post summary of it
                // rather than failing or hiding.
                [sBothSummaryPosts removeObject:fullName];
                [sLinkSummaryPosts removeObject:fullName];
                ApolloLog(@"[AISummary] article fetch failed for %@ — falling back to post summary (%@)", fullName,
                          fetchError ? fetchError.localizedDescription : @"too little text");
                ApolloAISummarizeArticleText(fullName, requestID, postText,
                                             kApolloAIPostInstructions, kApolloAIPostResponseTokens);
                return;
            }
            // No body either — a video-clip page (streamff/streamin/etc.), a
            // JS-rendered SPA (Bluesky/Twitter), a paywall, a bare score-card
            // (fifa.com match centre), and so on. Don't show an error card: just
            // HIDE the box, as if the post weren't a summarizable article, and
            // suppress it so we don't re-fetch every scroll or flip back to an
            // error triangle on header recycle.
            ApolloLog(@"[AISummary] no article prose for %@ — hiding link summary (%@)", fullName,
                      fetchError ? fetchError.localizedDescription : @"too little text");
            ApolloAISuppressLinkSummary(fullName);
            return;
        }
        sArticleTextCache[fullName] = articleText;
        summarize(articleText);
    });
}

static void ApolloAIGenerateForController(UIViewController *vc) {
    ApolloAIEnsureState();
    if (!sEnableAISummaries) return;

    ApolloFoundationModels *bridge = ApolloAIBridge();
    if (!bridge) { ApolloLog(@"[AISummary] bridge unavailable"); return; }
    // status 4 = FoundationModels framework absent (pre-iOS 26): genuinely
    // cannot run, so bail. For every other "unavailable" reason we DO NOT bail:
    // on iOS 27, `availabilityStatus` returns 1 (appleIntelligenceNotEnabled)
    // even when generation works fine (other clients summarize on the same
    // device), so we attempt anyway and let a real generation error be the gate.
    NSInteger status = [bridge availabilityStatus];
    if (status == 4) {
        ApolloLog(@"[AISummary] FoundationModels unavailable (status=4), skipping");
        return;
    }
    if (status != 0) {
        ApolloLog(@"[AISummary] availability reports status=%ld; attempting anyway (iOS 27 under-reports)", (long)status);
    }

    id link = ApolloAILinkFromController(vc);
    if (!link) { ApolloLog(@"[AISummary] no RDKLink on controller %@", [vc class]); return; }
    NSString *fullName = ApolloAILinkFullName(link);
    if (fullName.length == 0) fullName = [NSString stringWithFormat:@"_anon|%lu", (unsigned long)(uintptr_t)link];
    [sControllerByFullName setObject:vc forKey:fullName];

    // Bind the controller's authoritative link identity to the actual Texture
    // header node. Swift Optional ivar encodings can make a later header-only
    // link lookup fail even though this controller lookup succeeded.
    Class headerClass = NSClassFromString(@"_TtC6Apollo22CommentsHeaderCellNode");
    for (id node in ApolloAIAvailableNodes(vc)) {
        if (headerClass && [node isKindOfClass:headerClass]) {
            ApolloAIRegisterHeaderNodeForFullName(node, fullName);
        }
    }

    NSString *provisionalPostID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
    BOOL hasPostInput = ApolloAIPostText(link).length > 0;
    if (provisionalPostID.length > 0 &&
        (!hasPostInput || sPostSummaryCache[fullName].length > 0 || [sPostFailed containsObject:fullName])) {
        [bridge discardPreparedSession:provisionalPostID];
        objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    NSString *provisionalCommentID = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
    if (provisionalCommentID.length > 0 &&
        (sCommentSummaryCache[fullName].length > 0 || [sCommentFailed containsObject:fullName])) {
        [bridge discardPreparedSession:provisionalCommentID];
        objc_setAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    // ----- Post / Link / Both summary (shared post box) -----
    // The post box shows ONE of three things, decided by what the post contains:
    //   • body text only             -> "Post summary"        (summarize the body)
    //   • external article link only -> "Link summary"        (fetch + summarize article)
    //   • body AND an article link   -> "Post & link summary" (summarize both together)
    // A link post's article URL is its own URL; a self-post's is the first article
    // link in its body. One box + one cache serves all three.
    // Gated by the "Post & Link Summaries" sub-toggle.
    if (sEnableAIPostSummaries) {
    NSString *postText = ApolloAIPostText(link);            // substantial self-text body, or nil
    NSString *articleURL = ApolloAIArticleURLForPost(link); // pure-link URL or a link in the body
    BOOL haveBody = postText.length > 0;
    BOOL haveArticle = articleURL.length > 0;
    if (haveBody && haveArticle) {
        [sBothSummaryPosts addObject:fullName];
        [sLinkSummaryPosts removeObject:fullName];
    } else if (!haveBody && haveArticle) {
        [sLinkSummaryPosts addObject:fullName];
        [sBothSummaryPosts removeObject:fullName];
    } else {
        [sLinkSummaryPosts removeObject:fullName];
        [sBothSummaryPosts removeObject:fullName];
    }

    NSInteger desiredMode = ApolloAIDesiredPostMode(fullName);
    BOOL cacheValid = sPostSummaryCache[fullName].length > 0 &&
        [sPostSummaryMode[fullName] integerValue] == desiredMode;
    NSString *postTapKey = [@"post|" stringByAppendingString:fullName];
    if ([sPostSuppressed containsObject:fullName]) {
        // A pure-link post we already determined has no usable article content:
        // keep it hidden and never re-fetch or re-offer a "Tap to summarize"
        // prompt. (Self-text posts are never suppressed, so the body still
        // summarizes normally on a different post that happens to share nothing
        // here.)
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateNone, nil);
    } else if ([sPostEmpty containsObject:fullName]) {
        // Tapped (in Tap-to-Summarize mode) and found to have nothing to
        // summarize: keep the terminal "Nothing to summarize" card and don't
        // re-fetch or re-offer the tap prompt while it's on screen.
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateEmpty, nil);
    } else if (cacheValid) {
        // Cache HIT on re-entry: set Ready, then remeasure the row height if it
        // actually changed. Without this the row keeps the stale boxless height
        // Texture measured before the state was applied -> empty card (#526).
        if (ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateReady, sPostSummaryCache[fullName]))
            ApolloAIForceHeaderRemeasure(fullName);
    } else if (sEnableTapToSummarize && (haveBody || haveArticle) &&
               ![sTapRequested containsObject:postTapKey] &&
               ![sPostInFlight containsObject:fullName] && ![sPostFailed containsObject:fullName]) {
        // Tap-to-Summarize is on and the user hasn't tapped this card yet: show the
        // idle "Tap to summarize" prompt instead of generating automatically.
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateTapToSummarize, nil);
        ApolloAIForceHeaderRemeasure(fullName);
    } else if (![sPostInFlight containsObject:fullName] && ![sPostFailed containsObject:fullName]) {
        // Do NOT consume the tap request here — see the matching note in the comment
        // branch below. A concurrency-deferred retry must still re-drive generation
        // rather than fall back to the idle "Tap to summarize" prompt; the cacheValid /
        // in-flight / failed guards above short-circuit this gate on re-entry, and the
        // whole set is cleared with the caches on reset.
        // Drop a stale cache entry generated under a different mode (e.g. a
        // post-only summary cached before this post was detected as link/both).
        if (sPostSummaryCache[fullName].length > 0) {
            [sPostSummaryCache removeObjectForKey:fullName];
            [sPostSummaryMode removeObjectForKey:fullName];
        }
        if (haveArticle) {
            // Link-only or Both — both fetch the article (Both also folds in the
            // post body). Discard any provisional post session first.
            NSString *provisionalID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
            if (provisionalID.length > 0) {
                [bridge discardPreparedSession:provisionalID];
                objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
            ApolloAIGenerateLinkSummaryForController(articleURL, fullName, haveBody ? postText : nil);
        } else if (haveBody) {
            [sPostInFlight addObject:fullName];
            ApolloAIShowLoadingIfIdle(fullName, YES);   // box visible immediately
            ApolloAIForceHeaderRemeasure(fullName);
            ApolloLog(@"[AISummary] generating POST summary for %@ (%lu chars)…", fullName, (unsigned long)postText.length);
            NSString *requestID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
            if (requestID.length == 0) requestID = ApolloAIRequestIdentifier(fullName, YES);
            objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [bridge prepareSession:requestID instructions:kApolloAIPostInstructions];
            sPostRequestIDs[fullName] = requestID;
            ApolloAIScheduleGenerationTimeout(fullName, YES, requestID);
            [bridge summarize:postText
                   identifier:requestID
                 instructions:kApolloAIPostInstructions
       maximumResponseTokens:kApolloAIPostResponseTokens
                    onPartial:^(NSString *partial) {
                        ApolloAIApplyStreamingPartial(fullName, YES, partial);
                    }
                   onComplete:^(NSString *final, NSError *error) {
                        [sPostInFlight removeObject:fullName];
                        if ([sPostRequestIDs[fullName] isEqualToString:requestID]) {
                            [sPostRequestIDs removeObjectForKey:fullName];
                        }
                        if ([sTimedOutRequests containsObject:requestID]) {
                            [sTimedOutRequests removeObject:requestID];
                            return;
                        }
                        if (error.code == 6) return; // navigation cancellation
                        final = ApolloAINormalizeGeneratedSummary(final);
                        if (error || final.length == 0) {
                            if (ApolloAIErrorIsTransientConcurrency(error)) {
                                ApolloLog(@"[AISummary] post request deferred by model concurrency for %@", fullName);
                                UIViewController *controller = [sControllerByFullName objectForKey:fullName];
                                if (controller) {
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        ApolloAIGenerateForController(controller);
                                    });
                                }
                                return;
                            }
                            [sPostFailed addObject:fullName];
                            NSString *msg = error ? ApolloAIFriendlyError(error) : @"The model returned an empty summary.";
                            ApolloLog(@"[AISummary] post summary error: %@", error ? error.localizedDescription : @"(empty)");
                            ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateError, msg);
                            if (ApolloAIAnyHeaderExpanded(fullName, YES)) {
                                ApolloAIForceHeaderRemeasure(fullName);
                            }
                            return;
                        }
                        sPostSummaryCache[fullName] = final;
                        sPostSummaryMode[fullName] = @(ApolloAIDesiredPostMode(fullName));
                        ApolloAIStampSummary(fullName);
                        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateReady, final);
                        if (ApolloAIAnyHeaderExpanded(fullName, YES)) {
                            ApolloAIForceHeaderRemeasure(fullName);
                        }
                        ApolloAIPersistSummaries();
                        // Keep completion diagnostics without including generated
                        // Reddit content in the unified log or exported AI logs.
                        ApolloLog(@"[AISummary] POST summary DONE for %@ (%lu chars)",
                                  fullName, (unsigned long)final.length);
                    }];
        } else {
            // Neither summarizable body nor article link (image/video/media post,
            // or a too-short body with no link). Discard any provisional session.
            NSString *provisionalID = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
            if (provisionalID.length > 0) {
                [bridge discardPreparedSession:provisionalID];
                objc_setAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            }
            ApolloLog(@"[AISummary] nothing to summarize for %@", fullName);
        }
    }
    }   // end "Post & Link Summaries" sub-toggle gate

    // ----- Comment summary (LOCKED once generated) -----
    // A cached discussion summary ALWAYS wins: once it exists for this post we
    // show it and never re-harvest or regenerate. Previously the summary was
    // keyed on a "signature" of the representative comment set, which grew as
    // more comments scrolled into view — so scrolling silently changed the
    // summary text and the card height, shoving the scroll position up/down (the
    // "jitter"). Now the representative set is captured ONCE, from the full
    // loaded comment tree, summarized, and frozen for the session; only a fresh
    // page open (a new controller) restarts it.
    // Gated by the "Comment Summaries" sub-toggle.
    if (sEnableAICommentSummaries) {
    NSString *cachedCommentSummary = sCommentSummaryCache[fullName];
    if (cachedCommentSummary.length > 0) {
        // Cache HIT on re-entry: set Ready, then remeasure only on a real change,
        // matching the post branch above. Closes the comment side of #526.
        if (ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateReady, cachedCommentSummary))
            ApolloAIForceHeaderRemeasure(fullName);
    } else if (![sCommentInFlight containsObject:fullName] &&
               ![sCommentFailed containsObject:fullName]) {
        NSUInteger commentCount = 0;
        NSString *commentSignature = nil;
        NSString *commentText = ApolloAIGatherCommentText(vc, &commentCount, &commentSignature);
        ApolloLog(@"[AISummary] gathered %lu comments (%lu chars) for %@", (unsigned long)commentCount,
                  (unsigned long)commentText.length, fullName);
        BOOL hasEnoughDiscussion = commentCount >= kApolloAIMinComments &&
            commentText.length >= kApolloAIMinCommentChars;
        if (hasEnoughDiscussion) {
            NSString *commentTapKey = [@"comment|" stringByAppendingString:fullName];
            if (sEnableTapToSummarize && ![sTapRequested containsObject:commentTapKey]) {
            // Tap-to-Summarize is on and the user hasn't tapped: show the idle
            // "Tap to summarize" prompt instead of generating automatically.
            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateTapToSummarize, nil);
            ApolloAIForceHeaderRemeasure(fullName);
            } else {
            // Do NOT consume the tap request here. A transient-concurrency (code 9)
            // deferral clears sCommentInFlight and re-enters this function ~0.75s later;
            // if the key were already gone we'd fall back into the idle branch above and
            // silently revert to "Tap to summarize" instead of finishing the summary the
            // user asked for (common on posts that also have a post/link summary racing
            // for the on-device model). The key is harmless once generation starts: the
            // cache-hit / in-flight / failed guards all short-circuit before this gate on
            // re-entry, and the whole set is cleared with the caches on reset.
            ApolloAIShowLoadingIfIdle(fullName, NO);
            ApolloAIForceHeaderRemeasure(fullName);
            [sCommentInFlight addObject:fullName];
            // Ground the discussion summary in the post it is replying to.
            NSString *context = ApolloAIPostContextForComments(link);
            NSString *commentPrompt = context.length > 0
                ? [NSString stringWithFormat:@"%@\nComments:\n%@", context, commentText]
                : commentText;
            ApolloLog(@"[AISummary] generating COMMENT summary for %@…", fullName);
            NSString *requestID = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
            if (requestID.length == 0) requestID = ApolloAIRequestIdentifier(fullName, NO);
            objc_setAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [bridge prepareSession:requestID instructions:kApolloAICommentInstructions];
            sCommentRequestIDs[fullName] = requestID;
            ApolloAIScheduleGenerationTimeout(fullName, NO, requestID);
            [bridge summarize:commentPrompt
                   identifier:requestID
                 instructions:kApolloAICommentInstructions
       maximumResponseTokens:kApolloAICommentResponseTokens
                    onPartial:^(NSString *partial) {
                        ApolloAIApplyStreamingPartial(fullName, NO, partial);
                    }
                   onComplete:^(NSString *final, NSError *error) {
                        [sCommentInFlight removeObject:fullName];
                        if ([sCommentRequestIDs[fullName] isEqualToString:requestID]) {
                            [sCommentRequestIDs removeObjectForKey:fullName];
                        }
                        if ([sTimedOutRequests containsObject:requestID]) {
                            [sTimedOutRequests removeObject:requestID];
                            return;
                        }
                        if (error.code == 6) return; // navigation cancellation
                        final = ApolloAINormalizeGeneratedSummary(final);
                        if (error || final.length == 0) {
                            if (ApolloAIErrorIsTransientConcurrency(error)) {
                                ApolloLog(@"[AISummary] comment request deferred by model concurrency for %@", fullName);
                                UIViewController *controller = [sControllerByFullName objectForKey:fullName];
                                if (controller) {
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        ApolloAIGenerateForController(controller);
                                    });
                                }
                                return;
                            }
                            [sCommentFailed addObject:fullName];
                            NSString *msg = error ? ApolloAIFriendlyError(error) : @"The model returned an empty summary.";
                            ApolloLog(@"[AISummary] comment summary error: %@", error ? error.localizedDescription : @"(empty)");
                            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateError, msg);
                            if (ApolloAIAnyHeaderExpanded(fullName, NO)) {
                                ApolloAIForceHeaderRemeasure(fullName);
                            }
                            return;
                        }
                        sCommentSummaryCache[fullName] = final;
                        ApolloAIStampSummary(fullName);
                        sCommentSummarySourceCounts[fullName] = @(commentCount);
                        if (commentSignature.length > 0) {
                            sCommentSummarySignatures[fullName] = commentSignature;
                        }
                        ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateReady, final);
                        if (ApolloAIAnyHeaderExpanded(fullName, NO)) {
                            ApolloAIForceHeaderRemeasure(fullName);
                        }
                        ApolloAIPersistSummaries();
                        // The summary is cached; we no longer need the raw comments.
                        [sCapturedComments removeObjectForKey:fullName];
                        [sCapturedCommentKeys removeObjectForKey:fullName];
                        ApolloLog(@"[AISummary] COMMENT summary DONE for %@ (%lu chars)",
                                  fullName, (unsigned long)final.length);
                    }];
            }   // end Tap-to-Summarize else (generate)
        } else {
            // Small or low-content threads are faster to read directly. Never
            // leave a misleading loading card behind for them.
            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateNone, nil);
        }
    }
    }   // end "Comment Summaries" sub-toggle gate
}

#pragma mark - Diagnostics: comments table structure (informs UI placement)

static void ApolloAILogTableStructure(UIViewController *vc) {
    UITableView *tableView = ApolloAICommentsTableView(vc);
    NSArray *visibleNodes = ApolloAIAvailableNodes(vc);
    if (!tableView) {
        ApolloLog(@"[AISummary][struct] no UIKit table view; Texture visibleNodes=%lu firstNode=%@",
                  (unsigned long)visibleNodes.count,
                  visibleNodes.count ? NSStringFromClass([visibleNodes.firstObject class]) : @"(none)");
        return;
    }
    UIView *header = tableView.tableHeaderView;
    UIView *footer = tableView.tableFooterView;
    NSInteger sections = [tableView numberOfSections];
    NSInteger row0 = sections > 0 ? [tableView numberOfRowsInSection:0] : -1;

    NSString *row0NodeClass = @"(none)";
    NSArray<UITableViewCell *> *visible = [tableView visibleCells];
    if (visible.count > 0) {
        UITableViewCell *first = visible.firstObject;
        if ([first respondsToSelector:@selector(node)]) {
            id node = ((id (*)(id, SEL))objc_msgSend)(first, @selector(node));
            row0NodeClass = NSStringFromClass([node class]) ?: @"(nil node)";
        }
    }

    ApolloLog(@"[AISummary][struct] table=%@ headerView=%@ footerView=%@ sections=%ld rowsInSec0=%ld visibleCells=%lu firstNode=%@",
              NSStringFromClass([tableView class]),
              header ? NSStringFromClass([header class]) : @"nil",
              footer ? NSStringFromClass([footer class]) : @"nil",
              (long)sections, (long)row0, (unsigned long)visible.count, row0NodeClass);
}

#pragma mark - Hooks

%hook _TtC6Apollo22CommentsViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloAIEnsureState();
    if (sEnableAISummaries) sVisibleCommentsController = (UIViewController *)self;
    ApolloAIPrepareForController((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!sEnableAISummaries) return;
    sVisibleCommentsController = (UIViewController *)self;

    ApolloAILogTableStructure((UIViewController *)self);
    ApolloAIGenerateForController((UIViewController *)self);

    // Comments/post often aren't loaded yet at viewDidAppear (network fetch in
    // flight, no cells rendered). Re-run on a staggered schedule so late-
    // arriving cells get summarized without forcing the user to scroll. The
    // in-flight/cache guards in ApolloAIGenerateForController keep this from
    // generating more than once per thread.
    NSArray<NSNumber *> *retryDelays = @[ @1.5, @4.0, @8.0 ];
    for (NSNumber *delay in retryDelays) {
        __weak UIViewController *weakSelf = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isViewLoaded || !strongSelf.view.window) return;
            if (!sEnableAISummaries) return;
            ApolloAIGenerateForController(strongSelf);
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    UIViewController *vc = (UIViewController *)self;
    NSString *fullName = ApolloAIFullNameForController(vc);
    if (fullName.length > 0) {
        ApolloFoundationModels *bridge = ApolloAIBridge();
        NSString *activePostID = sPostRequestIDs[fullName] ?: ApolloAIRequestIdentifier(fullName, YES);
        NSString *activeCommentID = sCommentRequestIDs[fullName] ?: ApolloAIRequestIdentifier(fullName, NO);
        [bridge cancelRequest:activePostID];
        [bridge cancelRequest:activeCommentID];
        NSString *provisional = objc_getAssociatedObject(vc, &kApolloAIProvisionalPostRequestKey);
        if (provisional.length > 0) [bridge cancelRequest:provisional];
        NSString *provisionalComment = objc_getAssociatedObject(vc, &kApolloAIProvisionalCommentRequestKey);
        if (provisionalComment.length > 0) [bridge cancelRequest:provisionalComment];
        [sPostInFlight removeObject:fullName];
        [sCommentInFlight removeObject:fullName];
        [sPostRequestIDs removeObjectForKey:fullName];
        [sCommentRequestIDs removeObjectForKey:fullName];
        [sPostFailed removeObject:fullName];
        [sCommentFailed removeObject:fullName];
        // Suppression is per-view, exactly like sPostFailed above: a link we hid
        // because it had no usable prose (or failed transiently — model still
        // downloading, a flaky network, a slow fetch that timed out) gets a fresh
        // attempt the next time the post is opened. A genuinely content-less page
        // (fifa.com score card) simply re-fetches, re-detects "no prose" and
        // re-hides — cheap, and it never shows the error triangle — while a
        // transient failure recovers on reopen instead of staying hidden for the
        // whole session.
        [sPostSuppressed removeObject:fullName];
        [sPostEmpty removeObject:fullName];     // per-view, like sPostSuppressed
        // A Tap-to-Summarize request authorizes generation for THIS viewing only.
        // We no longer consume the key the instant generation starts (so a
        // concurrency-deferred retry within the same viewing can still finish — no
        // viewDidDisappear fires during its 0.75s wait), so clear it here instead,
        // alongside the in-flight/failed teardown above. Without this the key would
        // leak across viewings and a previously-tapped post would silently
        // regenerate on reopen without a fresh tap, defeating the point of the mode.
        [sTapRequested removeObject:[@"post|" stringByAppendingString:fullName]];
        [sTapRequested removeObject:[@"comment|" stringByAppendingString:fullName]];
        if (sPostSummaryCache[fullName].length == 0) {
            ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateNone, nil);
        }
        if (sCommentSummaryCache[fullName].length == 0) {
            ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateNone, nil);
        }
    }
    if (sVisibleCommentsController == (UIViewController *)self) {
        sVisibleCommentsController = nil;
    }
}

%end

// Apollo creates comment section controllers from the loaded CommentTree before
// Texture necessarily creates their cells. Capturing here removes the multi-
// second dependency on scrolling/preloading and is the primary fast path.
%hook _TtC6Apollo24CommentSectionController

- (id)init {
    id result = %orig;
    if (sEnableAISummaries) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = sVisibleCommentsController;
            id comment = MSHookIvar<id>((id)result, "comment");
            if (!vc || !ApolloAICommentIsEligible(comment)) return;
            ApolloAICaptureCommentForController(comment, vc);
            ApolloAIScheduleCommentGeneration(vc);
        });
    }
    return result;
}

- (void)modelObjectUpdatedNotificationReceived:(id)notification {
    %orig;
    if (!sEnableAISummaries) return;
    // Logos `self` is __unsafe_unretained; section controllers are torn down during
    // the very model-update storms this hook fires in (collapse deletions, live
    // updates). A raw capture here is the same use-after-free that crashed the
    // translation module's cell hooks (#630 round 5) — take a weak reference.
    __weak id weakSelf = (id)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id sectionController = weakSelf;
        if (!sectionController) return;
        UIViewController *vc = sVisibleCommentsController;
        Ivar commentIvar = class_getInstanceVariable(object_getClass(sectionController), "comment");
        id comment = commentIvar ? object_getIvar(sectionController, commentIvar) : nil;
        if (!vc || !ApolloAICommentIsEligible(comment)) return;
        ApolloAICaptureCommentForController(comment, vc);
        ApolloAIScheduleCommentGeneration(vc);
    });
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    if (!sEnableAISummaries) return;
    // Weak capture: comment cells die during collapse/scroll churn before the main
    // queue drains (#630 round-5 crash mechanism).
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) cellNode = weakSelf;
        if (!cellNode) return;
        UIViewController *vc = sVisibleCommentsController;
        id comment = ApolloAICommentFromCellNode((id)cellNode);
        if (!vc || !comment) return;
        ApolloAICaptureCommentForController(comment, vc);
        ApolloAIScheduleCommentGeneration(vc);
    });
}

- (void)didEnterPreloadState {
    %orig;
    if (!sEnableAISummaries) return;
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) cellNode = weakSelf;
        if (!cellNode) return;
        UIViewController *vc = sVisibleCommentsController;
        id comment = ApolloAICommentFromCellNode((id)cellNode);
        if (!vc || !comment) return;
        ApolloAICaptureCommentForController(comment, vc);
        ApolloAIScheduleCommentGeneration(vc);
    });
}

%end

%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)didLoad {
    %orig;
    if (!sEnableAISummaries) return;
    ApolloAIRegisterHeaderNode((id)self);
}

- (void)didEnterDisplayState {
    %orig;
    if (!sEnableAISummaries) return;
    ApolloAIRegisterHeaderNode((id)self);
}

%new
- (void)apollo_togglePostSummary {
    NSString *fullName = objc_getAssociatedObject((id)self, &kApolloAIHeaderFullNameKey);
    ApolloAIBoxState state = ApolloAIGetBoxState((id)self, YES);
    // The terminal "Nothing to summarize" card is informational only — non-interactive.
    if (state == ApolloAIBoxStateEmpty) return;
    // Tap-to-Summarize: an idle card generates on tap instead of expanding.
    if (state == ApolloAIBoxStateTapToSummarize) {
        // Keep the card collapsed while it generates (the title shows "· Summarizing…")
        // and open it automatically once the summary is fully ready — opening on tap
        // would make the text visibly stream into an already-expanded card.
        objc_setAssociatedObject((id)self, &kApolloAIPostExpandOnReadyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (fullName.length > 0) [sTapRequested addObject:[@"post|" stringByAppendingString:fullName]];
        ApolloAISetBoxStateOnMatchingHeaders(fullName, YES, ApolloAIBoxStateLoading, nil);
        ApolloAIForceHeaderRemeasure(fullName);
        UIViewController *vc = [sControllerByFullName objectForKey:fullName];
        if (vc) ApolloAIGenerateForController(vc);
        return;
    }
    BOOL expanded = [objc_getAssociatedObject((id)self, &kApolloAIPostExpandedKey) boolValue];
    objc_setAssociatedObject((id)self, &kApolloAIPostExpandedKey, @(!expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((id)self, &kApolloAIPostExpandChoiceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A manual expand/collapse supersedes any pending open-on-ready intent.
    objc_setAssociatedObject((id)self, &kApolloAIPostExpandOnReadyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Remember this so the card reopens in the same state next time.
    ApolloAIRememberCardExpanded(fullName, YES, !expanded);
    ApolloAIRenderSummaryNode((id)self, YES);
    [(ASDisplayNode *)(id)self invalidateCalculatedLayout];
    [(ASDisplayNode *)(id)self setNeedsLayout];
    ApolloAIForceHeaderRemeasure(fullName);
}

%new
- (void)apollo_toggleDiscussionSummary {
    NSString *fullName = objc_getAssociatedObject((id)self, &kApolloAIHeaderFullNameKey);
    ApolloAIBoxState state = ApolloAIGetBoxState((id)self, NO);
    // The terminal "Nothing to summarize" card is informational only — non-interactive.
    if (state == ApolloAIBoxStateEmpty) return;
    if (state == ApolloAIBoxStateTapToSummarize) {
        // Keep the card collapsed while it generates (the title shows "· Summarizing…")
        // and open it automatically once the summary is fully ready — opening on tap
        // would make the text visibly stream into an already-expanded card.
        objc_setAssociatedObject((id)self, &kApolloAICommentExpandOnReadyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (fullName.length > 0) [sTapRequested addObject:[@"comment|" stringByAppendingString:fullName]];
        ApolloAISetBoxStateOnMatchingHeaders(fullName, NO, ApolloAIBoxStateLoading, nil);
        ApolloAIForceHeaderRemeasure(fullName);
        UIViewController *vc = [sControllerByFullName objectForKey:fullName];
        if (vc) ApolloAIGenerateForController(vc);
        return;
    }
    BOOL expanded = [objc_getAssociatedObject((id)self, &kApolloAICommentExpandedKey) boolValue];
    objc_setAssociatedObject((id)self, &kApolloAICommentExpandedKey, @(!expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((id)self, &kApolloAICommentExpandChoiceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A manual expand/collapse supersedes any pending open-on-ready intent.
    objc_setAssociatedObject((id)self, &kApolloAICommentExpandOnReadyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Remember this so the card reopens in the same state next time.
    ApolloAIRememberCardExpanded(fullName, NO, !expanded);
    ApolloAIRenderSummaryNode((id)self, NO);
    [(ASDisplayNode *)(id)self invalidateCalculatedLayout];
    [(ASDisplayNode *)(id)self setNeedsLayout];
    ApolloAIForceHeaderRemeasure(fullName);
}

- (id)layoutSpecThatFits:(struct ApolloAISizeRange)constrainedSize {
    id originalSpec = %orig;
    if (!sEnableAISummaries) return originalSpec;
    ApolloAILogLayoutChildrenOnce((id)self, originalSpec);

    // Respect the sub-toggles at DISPLAY time too, so flipping one off hides an
    // already-generated/cached card (not just future ones) on the next layout pass.
    ApolloAIBoxState postState = sEnableAIPostSummaries ? ApolloAIGetBoxState((id)self, YES) : ApolloAIBoxStateNone;
    ApolloAIBoxState commentState = sEnableAICommentSummaries ? ApolloAIGetBoxState((id)self, NO) : ApolloAIBoxStateNone;
    if (postState == ApolloAIBoxStateNone && commentState == ApolloAIBoxStateNone) return originalSpec;
    ApolloLog(@"[AISummary][UI] composing header layout postState=%ld commentState=%ld",
              (long)postState, (long)commentState);

    id postSummarySpec = nil;
    id discussionSummarySpec = nil;
    if (postState != ApolloAIBoxStateNone) {
        ApolloAIEnsureSummaryNode((id)self, YES);
        ApolloAIEnsureBackgroundNode((id)self, YES);
        ApolloAIRenderSummaryNode((id)self, YES);
        postSummarySpec =
            ApolloAISummaryLayoutSpec(
                objc_getAssociatedObject((id)self, &kApolloAIPostSummaryNodeKey),
                objc_getAssociatedObject((id)self, &kApolloAIPostSummaryBackgroundNodeKey));
    }
    if (commentState != ApolloAIBoxStateNone) {
        ApolloAIEnsureSummaryNode((id)self, NO);
        ApolloAIEnsureBackgroundNode((id)self, NO);
        ApolloAIRenderSummaryNode((id)self, NO);
        discussionSummarySpec =
            ApolloAISummaryLayoutSpec(
                objc_getAssociatedObject((id)self, &kApolloAICommentSummaryNodeKey),
                objc_getAssociatedObject((id)self, &kApolloAICommentSummaryBackgroundNodeKey));
    }
    id newRoot = ApolloAIPlaceSummariesPreservingRoot(originalSpec,
                                                      postSummarySpec,
                                                      discussionSummarySpec);
    if (!newRoot) {
        ApolloLog(@"[AISummary][UI] incompatible header hierarchy rooted at %@; skipping summary injection",
                  NSStringFromClass([originalSpec class]));
        return originalSpec;
    }
    return newRoot;
}

%end

#if APOLLO_SIM_BUILD
// DEBUG ONLY — simulator builds only (gated by APOLLO_SIM_BUILD so it can never
// reach a device/release IPA): when the `AISummaryDebugURL` default is set to a
// reddit https URL, route Apollo to it shortly after launch using the app's own
// internal openURL path — no SpringBoard "Open in Apollo?" prompt. Lets the
// post/comment summary pipeline be exercised headlessly in the sim without UI
// tapping (idb HID is broken on Xcode 27 beta).
static void ApolloAIMaybeRouteDebugURL(void) {
    NSString *dbg = [[NSUserDefaults standardUserDefaults] stringForKey:@"AISummaryDebugURL"];
    if (dbg.length == 0) return;
    NSURL *url = [NSURL URLWithString:dbg];
    if (!url) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloLog(@"[AISummary][debug] routing to %@", dbg);
        ApolloRouteResolvedURLViaApolloScheme(url);
    });
}
#endif

%ctor {
    @autoreleasepool {
        ApolloAIEnsureState();
        ApolloFoundationModels *bridge = ApolloAIBridge();
        ApolloLog(@"[AISummary] loaded; bridge=%@ availabilityStatus=%ld",
                  bridge ? @"yes" : @"no", bridge ? (long)[bridge availabilityStatus] : -1);

#if APOLLO_SIM_BUILD
        ApolloAIMaybeRouteDebugURL();
#endif
    }
}
