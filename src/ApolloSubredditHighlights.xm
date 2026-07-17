// ApolloSubredditHighlights.xm
//
// Adds a horizontally-scrolling "Community Highlights" carousel to the top of a
// subreddit's post feed, mirroring new-Reddit / the official app. Moderators
// pin posts ("community highlights" / sticky posts); Reddit exposes them via the
// REST/OAuth listing as `stickied` posts (the OAuth token can't reach the
// GraphQL endpoint the first-party apps use for the richer up-to-6 carousel, so
// we render the stickied posts the REST API does return — historically the same
// first two slots old-Reddit shows).
//
// Data: a small `/r/{sub}/hot?limit=...` fetch filtered to `stickied` posts
// (sort-independent — highlights show on every feed sort, just like the site),
// keyed + cached by subreddit. We deliberately do NOT read Apollo's in-memory
// `links` array: it's a Swift `[RDKLink]` value type (fragile raw layout) and is
// empty on new/top/rising sorts.
//
// Surface: installed as the feed UITableView's `tableHeaderView`, so it scrolls
// away with the content (matching the site) and needs no datasource/IGListKit
// surgery. ApolloSubredditHeaders.xm owns that same slot when "Show Subreddit
// Headers" is ON, and only marks/wraps tables when that toggle is on — so while
// it is OFF the slot is free and we own it with zero conflict. Coexistence with
// that feature (both ON) is handled separately; here we defer to it.
//
// Gated behind the Settings → Subreddits → Community Highlights mode: Off
// disables it, Partial uses only the REST result, and Full adds the web upgrade.

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloState.h"
#import "ApolloCommon.h"
#import "ApolloSubredditHighlights.h"

#pragma mark - Minimal runtime interfaces

@interface RDKSubreddit : NSObject
- (NSString *)name;
@property (retain, nonatomic) NSURL *communityIconURL;
@property (retain, nonatomic) NSURL *iconImageURL;
@end

@interface RDKLinkLite : NSObject  // minimal view of RDKLink for de-dup
@property (nonatomic) BOOL stickied;
@property (copy, nonatomic) NSString *subreddit;
@property (copy, nonatomic) NSString *fullName;
@end

// ASSizeRange (matches ASDisplayKit's struct layout).
struct ApolloHLSizeRange { CGSize min; CGSize max; };

@interface ApolloHLLayoutSpec : NSObject @end
@interface ApolloHLStackSpec : ApolloHLLayoutSpec
+ (instancetype)stackLayoutSpecWithDirection:(NSInteger)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(NSUInteger)justifyContent
                                  alignItems:(NSUInteger)alignItems
                                    children:(NSArray *)children;
@end

#pragma mark - Tunables

static CGFloat const kApolloHLCardWidth = 160.0;
static CGFloat const kApolloHLCardHeight = 120.0;
static CGFloat const kApolloHLCardSpacing = 10.0;
static CGFloat const kApolloHLSidePadding = 16.0;
static CGFloat const kApolloHLTitleRowHeight = 26.0;
static CGFloat const kApolloHLTopPadding = 6.0;
// Small gap between the cards and the kept ThickSeparator below — just enough to lift
// the cards off the breaker (at 0 they look almost glued to it). Kept small on purpose:
// unlike a post's internal bottom inset (which is opaque, part of the post block), this
// gap is empty space, so a large value reads as a fat band/"line" rather than breathing
// room. Mirrors the carousel's top padding for symmetry.
static CGFloat const kApolloHLBottomPadding = 6.0;
static NSInteger const kApolloHLFetchLimit = 15;
// The full set comes from a rendered Reddit page, but there is no reason to leave
// the rendered DOM sitting idle for a fixed three seconds before looking at it.
// Probe as soon as navigation finishes (plus this short fallback timer for pages
// whose navigation delegate callback races their client-side render), then poll
// cheaply until the same overall timeout the old 3s + 8x2s loop allowed.
static NSTimeInterval const kApolloHLWebInitialPollDelay = 0.20;
static NSTimeInterval const kApolloHLWebPollInterval = 0.50;
// A just-finished page can briefly expose only its first couple of cards before
// the client render fills the carousel. More than two proves the upgrade is ready;
// for a genuinely small set, keep the old three-second settling window so an early
// partial DOM can never make us miss later cards.
static NSTimeInterval const kApolloHLWebSmallSetSettleDelay = 3.0;
static NSTimeInterval const kApolloHLWebTimeout = 18.0;
// Freshness window: a cached carousel is reused as-is for this long. Returning to a
// subreddit after the window elapses kicks a quiet background re-poll (stale-while-
// revalidate) that rebuilds ONLY if the pinned set actually changed. Keeps navigation
// cheap (no refetch on every visit) while picking up a mod's pin change on its own;
// pull-to-refresh always forces an immediate refresh regardless of this window.
static NSTimeInterval const kApolloHLCacheTTL = 120.0;

#pragma mark - Associated-object keys

static const void *kApolloHLCarouselKey       = &kApolloHLCarouselKey;       // carousel UIView on the VC
static const void *kApolloHLWrapperKey         = &kApolloHLWrapperKey;        // wrapper UIView on the VC
static const void *kApolloHLOriginalHeaderKey  = &kApolloHLOriginalHeaderKey; // pre-existing tableHeaderView
static const void *kApolloHLSubredditKey       = &kApolloHLSubredditKey;      // NSString subreddit currently shown
static const void *kApolloHLSignatureKey       = &kApolloHLSignatureKey;      // NSString carousel-content signature
static const void *kApolloHLManagedTableKey    = &kApolloHLManagedTableKey;   // BOOL on the UITableView
static const void *kApolloHLManagedVCKey       = &kApolloHLManagedVCKey;      // weak-ish VC on the table
static const void *kApolloHLRewrapInProgressKey = &kApolloHLRewrapInProgressKey; // BOOL guard on the table
static const void *kApolloHLWrapperMarkerKey   = &kApolloHLWrapperMarkerKey;  // BOOL on the wrapper view
static const void *kApolloHLTeardownMarkerKey  = &kApolloHLTeardownMarkerKey; // BOOL on the VC
static const void *kApolloHLActiveSubKey       = &kApolloHLActiveSubKey;      // NSString sub added to the hide-set by this VC
static const void *kApolloHLContainerKey       = &kApolloHLContainerKey;      // ApolloHLHeaderContainerView on the VC (headers-on coexistence)
static char kApolloHLHiddenRowsKey;            // NSMutableSet<NSNumber*> of de-duped sticky rows, per ASTableNode
static char kApolloHLStickyCountKey;           // NSNumber (REST sticky count N) per feed ASTableNode — breaker rule
static char kApolloHLSwitchPendingKey;         // BOOL on the VC — an in-place-switch re-install is already scheduled

#pragma mark - Subreddit detection (adapted from ApolloSubredditHeaders.xm)

static BOOL ApolloHLIsLikelyObjectPointer(id value) {
    if (!value) return NO;
    uintptr_t addr = (uintptr_t)(__bridge void *)value;
#if __arm64__
    if (addr & 0x1) return YES; // tagged pointer
#endif
    if (addr < 0x100000000ULL || addr > 0x8000000000ULL) return NO;
    return YES;
}

static id ApolloHLTypedIvar(id object, NSString *name, Class expectedClass) {
    if (!object || name.length == 0 || !expectedClass) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *raw = NULL;
        memcpy(&raw, (uint8_t *)(__bridge void *)object + offset, sizeof(raw));
        id value = (__bridge id)raw;
        if (!ApolloHLIsLikelyObjectPointer(value)) return nil;
        @try {
            return [value isKindOfClass:expectedClass] ? value : nil;
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

// PostsType case tag lives at offset 0x20 of the `currentPostsType` Swift-enum
// ivar; 0 = named single subreddit, 5 = random (both backed by one subreddit).
static const ptrdiff_t kApolloHLPostsTypeTagOffset = 0x20;
static BOOL ApolloHLPostsTypeTag(id viewController, uint8_t *tag) {
    Ivar ivar = class_getInstanceVariable([viewController class], "currentPostsType");
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t value = 0;
    memcpy(&value, (uint8_t *)(__bridge void *)viewController + offset + kApolloHLPostsTypeTagOffset, sizeof(value));
    if (tag) *tag = value;
    return YES;
}

static NSString *ApolloHLNormalizedName(NSString *subredditName) {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    NSArray<NSString *> *blocked = @[@"home", @"popular", @"all", @"search", @"profile",
                                     @"settings", @"inbox", @"friends", @"mod"];
    if ([blocked containsObject:clean.lowercaseString]) return nil;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    if ([clean rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return clean;
}

static NSString *ApolloHLSubredditName(UIViewController *viewController) {
    if (!viewController) return nil;
    uint8_t tag = 0;
    BOOL haveTag = ApolloHLPostsTypeTag(viewController, &tag);
    if (haveTag && tag != 0 && tag != 5) return nil; // multireddit / special feed
    // Reddit subreddit names are canonically lowercase; the nav-title fallback can
    // carry display casing ("Apple"). Lowercase the result so every comparison and
    // cache key is consistent (the authoritative `currentSubreddit.name` and the
    // title fallback then always agree).
    id subreddit = ApolloHLTypedIvar(viewController, @"currentSubreddit", objc_getClass("RDKSubreddit"));
    if (subreddit && [subreddit respondsToSelector:@selector(name)]) {
        id nameValue = ((id (*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
        if ([nameValue isKindOfClass:[NSString class]]) {
            NSString *normalized = ApolloHLNormalizedName(nameValue);
            if (normalized.length) return normalized.lowercaseString;
        }
    }
    if (haveTag) {
        NSString *title = viewController.navigationItem.title;
        if (title.length == 0) title = viewController.title;
        NSString *normalized = ApolloHLNormalizedName(title);
        return normalized.lowercaseString;
    }
    return nil;
}

static BOOL ApolloHLShouldSkipViewController(UIViewController *viewController) {
    if (!viewController) return YES;
    if ([objc_getAssociatedObject(viewController, kApolloHLTeardownMarkerKey) boolValue]) return YES;
    if (viewController.isMovingFromParentViewController || viewController.isBeingDismissed) return YES;
    if (viewController.parentViewController == nil && viewController.presentingViewController == nil && viewController.view.window == nil) {
        return YES;
    }
    return NO;
}

static UIView *ApolloHLFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloHLFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

static UITableView *ApolloHLFindTableView(UIViewController *viewController) {
    if ([viewController respondsToSelector:@selector(tableView)]) {
        UITableView *(*msgSend)(id, SEL) = (UITableView *(*)(id, SEL))objc_msgSend;
        id tableView = msgSend(viewController, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }
    return (UITableView *)ApolloHLFindSubviewOfClass(viewController.view, [UITableView class]);
}

// Reload the feed's ASTableNode (used only on the rare path where we need to
// restore inline stickied cells we optimistically collapsed).
static void ApolloHLReloadFeed(UIViewController *vc) {
    id tableNode = ApolloHLTypedIvar(vc, @"tableNode", objc_getClass("ASTableNode"));
    if (tableNode && [tableNode respondsToSelector:@selector(reloadData)]) {
        ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData));
    }
}

#pragma mark - Data model

@interface ApolloHLItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *permalink;   // "/r/sub/comments/..."
@property (nonatomic, copy) NSString *fullName;    // "t3_xxxx"
@property (nonatomic, copy) NSString *flairText;
@property (nonatomic) long long numComments;
@property (nonatomic, strong) NSURL *thumbnailURL;
@property (nonatomic) BOOL isSpoiler;
@end
@implementation ApolloHLItem
@end

#pragma mark - Highlights fetch (cached, main-queue-only cache)

// subreddit (lowercase) -> NSArray<ApolloHLItem*>. An empty array means "fetched,
// nothing pinned" (a negative cache so we don't refetch every layout pass).
static NSMutableDictionary<NSString *, NSArray<ApolloHLItem *> *> *ApolloHLCache(void) {
    static NSMutableDictionary *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}
// The displayed cache can be upgraded to the full web set. Keep the latest pure
// REST result separately so changing the setting from Full to Partial can remove
// the extra cards immediately without another request or app restart.
static NSMutableDictionary<NSString *, NSArray<ApolloHLItem *> *> *ApolloHLRestCache(void) {
    static NSMutableDictionary *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}
static NSMutableSet<NSString *> *ApolloHLInFlight(void) {
    static NSMutableSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

// Lowercased subreddits whose foreground single-subreddit feed should collapse
// inline stickied cells (the carousel shows them instead). Set SYNCHRONOUSLY in
// ApolloHLInstall (before cells lay out) so de-dup needs no async re-layout on a
// cold load; cleared on teardown or if the fetch turns up nothing to show.
static NSMutableSet<NSString *> *ApolloHLHideSubs(void) {
    static NSMutableSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

// Subreddits where we actually collapsed at least one inline stickied cell — so
// the empty/failed-fetch path only forces a feed reload (to restore them) when
// something was hidden, never on the common "no pinned posts" subreddit.
static NSMutableSet<NSString *> *ApolloHLDidCollapseSubs(void) {
    static NSMutableSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

// THREAD SAFETY: both sets above are touched from the MAIN thread (ApolloHLInstall /
// Teardown / ClearDeDup / header substitute) AND from Texture's background layout queue
// (ApolloHLShouldHideCell + ApolloHLSeparatorShouldCollapse run inside the cell-node
// layoutSpecThatFits:/calculateLayoutThatFits: hooks). Plain NSMutableSet is not
// thread-safe, so EVERY read/mutate of these two globals must go through the locked
// accessors below — never touch ApolloHLHideSubs()/ApolloHLDidCollapseSubs() directly.
// One shared lock guards both (they're only ever touched independently, so a single lock
// can't deadlock; @synchronized is recursive, and these helpers acquire no other lock).
static id ApolloHLDeDupLock(void) {
    static id token; static dispatch_once_t once;
    dispatch_once(&once, ^{ token = [NSObject new]; });
    return token;
}
static BOOL ApolloHLHideSubsContains(NSString *sub) {
    if (sub.length == 0) return NO;
    @synchronized(ApolloHLDeDupLock()) { return [ApolloHLHideSubs() containsObject:sub]; }
}
static BOOL ApolloHLHideSubsIsEmpty(void) {
    @synchronized(ApolloHLDeDupLock()) { return ApolloHLHideSubs().count == 0; }
}
static void ApolloHLHideSubsAdd(NSString *sub) {
    if (sub.length == 0) return;
    @synchronized(ApolloHLDeDupLock()) { [ApolloHLHideSubs() addObject:sub]; }
}
static void ApolloHLHideSubsRemove(NSString *sub) {
    if (sub.length == 0) return;
    @synchronized(ApolloHLDeDupLock()) { [ApolloHLHideSubs() removeObject:sub]; }
}
static BOOL ApolloHLDidCollapseContains(NSString *sub) {
    if (sub.length == 0) return NO;
    @synchronized(ApolloHLDeDupLock()) { return [ApolloHLDidCollapseSubs() containsObject:sub]; }
}
static void ApolloHLDidCollapseAdd(NSString *sub) {
    if (sub.length == 0) return;
    @synchronized(ApolloHLDeDupLock()) { [ApolloHLDidCollapseSubs() addObject:sub]; }
}
static void ApolloHLDidCollapseRemove(NSString *sub) {
    if (sub.length == 0) return;
    @synchronized(ApolloHLDeDupLock()) { [ApolloHLDidCollapseSubs() removeObject:sub]; }
}

// Lowercased subreddit -> number of leading stickied posts the REST `hot` fetch
// returned (= the number of inline cells we de-dup). Set ONLY from the REST parse
// (never the web upgrade, which inflates the carousel beyond the inline stickies),
// so the separators can keep exactly the LAST orphan as the single breaker without
// racing the cell layout. Survives across the web upgrade.
static NSMutableDictionary<NSString *, NSNumber *> *ApolloHLStickyCount(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// subreddit -> NSDate of the last successful REST fetch (freshness TTL), and the
// content signature of that REST result (to detect when the pinned set changes so a
// background re-poll only rebuilds on a real change). Both keyed lowercased.
static NSMutableDictionary<NSString *, NSDate *> *ApolloHLFetchTime(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}
static NSMutableDictionary<NSString *, NSString *> *ApolloHLRestSig(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

#pragma mark - Per-subreddit collapsed state (persisted)

// The user can tap the "Community Highlights" header to collapse the carousel to
// just its title bar; the choice is remembered per subreddit across launches
// (mirrors the Reddit website's collapsible highlights). Runtime-mutated state, so
// it lives directly in standardUserDefaults (no settings toggle / registerDefaults).
static NSString *const kApolloHLCollapsedSubsKey = @"CollapsedSubredditHighlights";

static NSMutableSet<NSString *> *ApolloHLCollapsedSet(void) {
    static NSMutableSet *set; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kApolloHLCollapsedSubsKey];
        set = [saved isKindOfClass:[NSArray class]] ? [NSMutableSet setWithArray:saved] : [NSMutableSet set];
    });
    return set;
}

static BOOL ApolloHLIsCollapsed(NSString *sub) {
    return sub.length > 0 && [ApolloHLCollapsedSet() containsObject:sub.lowercaseString];
}

static void ApolloHLSetCollapsed(NSString *sub, BOOL collapsed) {
    NSString *key = sub.lowercaseString;
    if (key.length == 0) return;
    NSMutableSet *set = ApolloHLCollapsedSet();
    if (collapsed) [set addObject:key]; else [set removeObject:key];
    [[NSUserDefaults standardUserDefaults] setObject:set.allObjects forKey:kApolloHLCollapsedSubsKey];
}

static NSString *ApolloHLStringValue(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }

// "/r/sub/comments/<id>/slug/" -> "<id>" (matches API + web permalinks).
static NSString *ApolloHLPostIDFromPermalink(NSString *permalink) {
    if (permalink.length == 0) return nil;
    NSArray<NSString *> *parts = [permalink componentsSeparatedByString:@"/"];
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if ([parts[i] isEqualToString:@"comments"]) return parts[i + 1];
    }
    return nil;
}

// Strip subreddit-emoji :tokens: from flair text for display (e.g. r/soccer's
// ":n_discussion: Daily Discussion").
static NSString *ApolloHLStripEmojiTokens(NSString *raw) {
    if (raw.length == 0) return raw;
    static NSRegularExpression *regex; static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = [NSRegularExpression regularExpressionWithPattern:@":[A-Za-z0-9_+-]+:" options:0 error:NULL]; });
    NSString *s = [regex stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s containsString:@"  "]) s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return s.length > 0 ? s : raw;
}

static NSURL *ApolloHLThumbnailFromPostData(NSDictionary *d) {
    // Prefer a real preview image; fall back to thumbnail when it's an http URL.
    NSDictionary *preview = [d[@"preview"] isKindOfClass:[NSDictionary class]] ? d[@"preview"] : nil;
    NSArray *images = [preview[@"images"] isKindOfClass:[NSArray class]] ? preview[@"images"] : nil;
    NSDictionary *first = images.firstObject;
    if ([first isKindOfClass:[NSDictionary class]]) {
        // A resolution close to the card thumbnail is lighter than `source`.
        NSArray *resolutions = [first[@"resolutions"] isKindOfClass:[NSArray class]] ? first[@"resolutions"] : nil;
        for (NSDictionary *res in resolutions) {
            if (![res isKindOfClass:[NSDictionary class]]) continue;
            NSNumber *w = res[@"width"];
            if ([w isKindOfClass:[NSNumber class]] && w.doubleValue >= 108.0) {
                NSString *u = ApolloHLStringValue(res[@"url"]);
                if (u.length) return [NSURL URLWithString:u];
            }
        }
        NSDictionary *source = [first[@"source"] isKindOfClass:[NSDictionary class]] ? first[@"source"] : nil;
        NSString *su = ApolloHLStringValue(source[@"url"]);
        if (su.length) return [NSURL URLWithString:su];
    }
    NSString *thumb = ApolloHLStringValue(d[@"thumbnail"]);
    if ([thumb hasPrefix:@"http"]) return [NSURL URLWithString:thumb];
    return nil;
}

// Builds one carousel item from a t3 post's `data` dict. No stickied filter — the
// caller decides (the hot listing keeps only stickied; /api/info keeps everything).
static ApolloHLItem *ApolloHLItemFromPostData(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSString *title = ApolloHLStringValue(d[@"title"]);
    NSString *permalink = ApolloHLStringValue(d[@"permalink"]);
    if (title.length == 0 || permalink.length == 0) return nil;
    ApolloHLItem *item = [[ApolloHLItem alloc] init];
    item.title = title;
    item.permalink = permalink;
    item.fullName = ApolloHLStringValue(d[@"name"]);
    item.flairText = ApolloHLStringValue(d[@"link_flair_text"]);
    NSNumber *nc = d[@"num_comments"];
    item.numComments = [nc isKindOfClass:[NSNumber class]] ? nc.longLongValue : 0;
    item.thumbnailURL = ApolloHLThumbnailFromPostData(d);
    item.isSpoiler = [d[@"spoiler"] respondsToSelector:@selector(boolValue)] && [d[@"spoiler"] boolValue];
    return item;
}

static NSArray<ApolloHLItem *> *ApolloHLParseListing(NSDictionary *root) {
    NSDictionary *data = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    NSArray *children = [data[@"children"] isKindOfClass:[NSArray class]] ? data[@"children"] : nil;
    NSMutableArray<ApolloHLItem *> *items = [NSMutableArray array];
    for (NSDictionary *child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
        if (!d) continue;
        BOOL stickied = [d[@"stickied"] respondsToSelector:@selector(boolValue)] && [d[@"stickied"] boolValue];
        if (!stickied) continue;
        ApolloHLItem *item = ApolloHLItemFromPostData(d);
        if (item) [items addObject:item];
    }
    return items;
}

// Maps t3 fullname -> item for an /api/info Listing response (no stickied filter).
static NSDictionary<NSString *, ApolloHLItem *> *ApolloHLParseInfoListing(NSDictionary *root) {
    NSDictionary *data = [root[@"data"] isKindOfClass:[NSDictionary class]] ? root[@"data"] : nil;
    NSArray *children = [data[@"children"] isKindOfClass:[NSArray class]] ? data[@"children"] : nil;
    NSMutableDictionary<NSString *, ApolloHLItem *> *map = [NSMutableDictionary dictionary];
    for (NSDictionary *child in children) {
        if (![child isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = [child[@"data"] isKindOfClass:[NSDictionary class]] ? child[@"data"] : nil;
        ApolloHLItem *item = ApolloHLItemFromPostData(d);
        if (item.fullName.length) map[item.fullName] = item;
    }
    return map;
}

// Harvests the FULL highlights set (up to 6) via a hidden WKWebView — the only
// path past Reddit's JS bot-challenge that blocks direct fetches. Loads the
// new-Reddit subreddit page (logged out — highlights are public), waits for the
// challenge to clear + the carousel to render, then scrapes title/permalink/
// thumbnail from the DOM. Calls `done` on the main queue (empty array on
// fail/timeout). Used only by the Full setting; callers cache the result and gate
// it behind sCommunityHighlightsWeb.
@interface ApolloHLWebFetch : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *sub;
@property (nonatomic, copy) void (^done)(NSArray<ApolloHLItem *> *items);
@property (nonatomic) int polls;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic, strong) NSArray<ApolloHLItem *> *bestItems;
@property (nonatomic) BOOL pollScheduled;
@property (nonatomic) BOOL evaluationInFlight;
// Reddit can hydrate a larger carousel progressively. Once a probe first sees
// more than the REST-sized two cards, take one confirming probe before finishing
// so bestItems can grow to the complete set without restoring the old 3s delay.
@property (nonatomic) BOOL awaitingLargeSetConfirmation;
@end
@implementation ApolloHLWebFetch

// A single non-persistent (in-memory) WKWebsiteDataStore, reused for every
// highlights scrape this app session.
//
// Why isolate the scrape from the app's shared cookies: Reddit serves the *old*
// reddit layout at www.reddit.com whenever the logged-in session belongs to an
// account whose "Use new Reddit as my default experience" preference is disabled.
// Apollo's OAuth login runs through a www.reddit.com web view, so that account's
// session + old-reddit preference land in the SHARED default WKWebsiteDataStore.
// Old reddit renders none of the "Community Highlights" carousel markup this
// scraper looks for, so the web upgrade silently finds nothing and the carousel
// stays stuck on just the two stickied posts the REST listing returns — exactly
// the "only got the first 2 posts" symptom. The poison is sticky too: deleting
// the Apollo account never clears WebKit cookies, so only deleting the whole app
// cleared it. (Same root cause as the Social Links scrape fixed in #496; reported
// there by @Uranosphaerite as also affecting Community Highlights / #463.)
//
// A logged-out, in-memory store sidesteps all of it: with no account session
// Reddit serves its default (new/shreddit) experience — which DOES carry the
// highlights carousel — so the scrape can neither poison nor be poisoned by the
// user's browsing session, and it resets each launch. Shared (not per-scrape) so
// Reddit's JS bot-challenge cookie warms once per session rather than cold on
// every subreddit. Highlights are public, so no login is needed.
+ (WKWebsiteDataStore *)apollo_scrapeDataStore {
    static WKWebsiteDataStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [WKWebsiteDataStore nonPersistentDataStore]; });
    return store;
}

- (void)startForSub:(NSString *)sub completion:(void (^)(NSArray<ApolloHLItem *> *))done {
    self.sub = sub; self.done = done; self.polls = 0;
    self.startedAt = [NSDate date]; self.bestItems = nil; self.pollScheduled = NO; self.evaluationInFlight = NO;
    self.awaitingLargeSetConfirmation = NO;
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    if (!win) { [self finish:nil]; return; }
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [ApolloHLWebFetch apollo_scrapeDataStore];
    self.web = [[WKWebView alloc] initWithFrame:win.bounds configuration:config];
    self.web.navigationDelegate = self;
    self.web.alpha = 0.011; self.web.userInteractionEnabled = NO;
    [win insertSubview:self.web atIndex:0];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/", sub]]]];
    ApolloLog(@"[Highlights][web] loading r/%@ for full highlights", sub);
    [self pollAfter:kApolloHLWebInitialPollDelay];
}
- (void)pollAfter:(double)delay {
    // didFinishNavigation and the fallback timer can both ask for a probe. Keep
    // exactly one scheduled probe and one evaluateJavaScript call at a time so
    // faster polling never stacks work in WebKit.
    if (!self.web || self.pollScheduled) return;
    self.pollScheduled = YES;
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ws.pollScheduled = NO;
        [ws poll];
    });
}
- (void)poll {
    if (!self.web || self.evaluationInFlight) return;
    NSTimeInterval elapsed = self.startedAt ? -self.startedAt.timeIntervalSinceNow : 0.0;
    if (elapsed >= kApolloHLWebTimeout) {
        ApolloLog(@"[Highlights][web] r/%@ timed out after %.1fs (%d probes)", self.sub, elapsed, self.polls);
        [self finish:self.bestItems ?: @[]];
        return;
    }
    self.evaluationInFlight = YES;
    self.polls++;
    NSString *js = @"(function(){"
        "var all=document.querySelectorAll('*'),heading=null;"
        "for(var i=0;i<all.length;i++){var e=all[i];if(e.children.length===0&&(e.textContent||'').trim().toLowerCase()==='community highlights'){heading=e;break;}}"
        "if(!heading)return JSON.stringify({n:0});"
        "var c=heading;for(var d=0;d<7&&c.parentElement;d++){c=c.parentElement;if(c.querySelectorAll('a[href*=\"/comments/\"]').length>=1)break;}"
        "var links=c.querySelectorAll('a[href*=\"/comments/\"]');var seen={},out=[];"
        "for(var j=0;j<links.length;j++){var l=links[j];var h=(l.getAttribute('href')||'').split('?')[0];if(!h||seen[h])continue;var t=(l.textContent||'').trim().split('\\n')[0].trim();if(!t)continue;seen[h]=1;"
        "var img=l.querySelector('img');var src=img?(img.getAttribute('src')||img.getAttribute('data-src')||''):'';"
        "out.push({t:t.substring(0,140),h:h,img:src});}"
        "return JSON.stringify({n:out.length,items:out});})()";
    __weak typeof(self) ws = self;
    [self.web evaluateJavaScript:js completionHandler:^(id res, NSError *e) {
        ApolloHLWebFetch *ss = ws;
        if (!ss) return;
        ss.evaluationInFlight = NO;
        if (!ss.web) return;
        NSArray<ApolloHLItem *> *items = [ApolloHLWebFetch parseItems:res];
        if (items.count > ss.bestItems.count) ss.bestItems = items;
        NSTimeInterval now = ss.startedAt ? -ss.startedAt.timeIntervalSinceNow : 0.0;
        if (ss.bestItems.count > 2 && !ss.awaitingLargeSetConfirmation && now < kApolloHLWebTimeout) {
            ss.awaitingLargeSetConfirmation = YES;
            ApolloLog(@"[Highlights][web] r/%@ found %lu highlights in %.2fs; confirming once for progressive hydration",
                      ss.sub, (unsigned long)ss.bestItems.count, now);
            [ss pollAfter:kApolloHLWebPollInterval];
        } else if (ss.bestItems.count > 2 || (ss.bestItems.count > 0 && now >= kApolloHLWebSmallSetSettleDelay)) {
            ApolloLog(@"[Highlights][web] r/%@ extracted %lu highlights in %.2fs (probe#%d)", ss.sub, (unsigned long)ss.bestItems.count, now, ss.polls);
            [ss finish:ss.bestItems];
        } else if (now >= kApolloHLWebTimeout) {
            ApolloLog(@"[Highlights][web] r/%@ timed out after %.1fs (%d probes, last error=%@)", ss.sub, now, ss.polls, e.localizedDescription ?: @"nil");
            [ss finish:ss.bestItems ?: @[]];
        } else {
            [ss pollAfter:kApolloHLWebPollInterval];
        }
    }];
}
+ (NSArray<ApolloHLItem *> *)parseItems:(id)res {
    if (![res isKindOfClass:[NSString class]]) return @[];
    NSData *d = [(NSString *)res dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSArray *arr = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : nil;
    NSMutableArray<ApolloHLItem *> *out = [NSMutableArray array];
    for (NSDictionary *it in arr) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = ApolloHLStringValue(it[@"t"]), *h = ApolloHLStringValue(it[@"h"]);
        if (t.length == 0 || h.length == 0) continue;
        ApolloHLItem *item = [[ApolloHLItem alloc] init];
        item.title = t;
        item.permalink = h;
        NSString *img = ApolloHLStringValue(it[@"img"]);
        // Skip the subreddit profile icon (shown for text-post highlights) — that's
        // not a real thumbnail; let those render as plain text cards.
        if ([img hasPrefix:@"http"] && [img rangeOfString:@"profileIcon" options:NSCaseInsensitiveSearch].location == NSNotFound)
            item.thumbnailURL = [NSURL URLWithString:img];
        [out addObject:item];
        if (out.count >= 6) break;
    }
    return out;
}
- (void)finish:(NSArray<ApolloHLItem *> *)items {
    if (self.web) { self.web.navigationDelegate = nil; [self.web removeFromSuperview]; self.web = nil; }
    self.pollScheduled = NO; self.evaluationInFlight = NO; self.awaitingLargeSetConfirmation = NO;
    self.startedAt = nil; self.bestItems = nil;
    void (^d)(NSArray *) = self.done; self.done = nil;
    if (d) d(items ?: @[]);
}
- (void)cancel {
    self.done = nil;
    if (self.web) {
        self.web.navigationDelegate = nil;
        [self.web stopLoading];
        [self.web removeFromSuperview];
        self.web = nil;
    }
    self.pollScheduled = NO; self.evaluationInFlight = NO; self.awaitingLargeSetConfirmation = NO;
    self.startedAt = nil; self.bestItems = nil;
}
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
    // On a warm WebKit process the full carousel is often present immediately.
    // Probe now instead of waiting for the fallback timer; if Reddit still has
    // client-side work to do, the regular poll loop continues unchanged.
    if (wv == self.web) [self poll];
}
@end

static NSString *ApolloHLItemsContentSig(NSArray<ApolloHLItem *> *items); // defined with ApolloHLSignature

// Fetches the subreddit's stickied posts and calls completion on the main queue
// with the (possibly empty) item array. Caches the result. completion may be nil
// (warm the cache only).
static void ApolloHLFetchHighlights(NSString *subredditName, BOOL force, void (^completion)(NSArray<ApolloHLItem *> *items)) {
    NSString *key = subredditName.lowercaseString;
    if (key.length == 0) { if (completion) completion(@[]); return; }

    // force = bypass the cache hit (a freshness re-poll) but still de-dupe against an
    // in-flight request so concurrent triggers don't stack network calls.
    if (!force) {
        NSArray<ApolloHLItem *> *cached = ApolloHLCache()[key];
        if (cached) { if (completion) completion(cached); return; }
    }
    if ([ApolloHLInFlight() containsObject:key]) { if (completion) completion(nil); return; }
    [ApolloHLInFlight() addObject:key];

    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    NSString *escaped = [subredditName stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: subredditName;
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/hot?limit=%ld&raw_json=1", escaped, (long)kApolloHLFetchLimit]
        : [NSString stringWithFormat:@"https://www.reddit.com/r/%@/hot.json?limit=%ld&raw_json=1", escaped, (long)kApolloHLFetchLimit];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15.0;
    if (token.length > 0) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloHighlights/1.0") forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : -1;
        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray<ApolloHLItem *> *items = [json isKindOfClass:[NSDictionary class]] ? ApolloHLParseListing(json) : @[];
        ApolloLog(@"[Highlights] fetch r/%@ status=%ld stickied=%lu err=%@", subredditName,
                  (long)status, (unsigned long)items.count, error.localizedDescription ?: @"nil");
        dispatch_async(dispatch_get_main_queue(), ^{
            [ApolloHLInFlight() removeObject:key];
            // Only cache a successful response (200 / parsed). On error, leave it
            // uncached so a later layout pass can retry.
            // A non-force fetch populates the displayed cache. A force fetch (freshness
            // re-poll) must NOT overwrite it — the cache holds the possibly web-upgraded
            // set on display; the refresh caller rebuilds via ApplyItems only on a real
            // change, so a failed web re-run can't silently downgrade the carousel.
            NSArray<ApolloHLItem *> *completionItems = items;
            if (!force && (status == 200 || items.count > 0)) {
                // The web page can now finish very quickly on a warm WebKit process.
                // If it wins the race and has already installed the full set, do not
                // let this slower REST response downgrade the cache/carousel to two.
                NSArray<ApolloHLItem *> *displayed = ApolloHLCache()[key];
                if (!displayed || !sCommunityHighlightsWeb || displayed.count <= items.count) ApolloHLCache()[key] = items;
                completionItems = ApolloHLCache()[key] ?: items;
            }
            // Record the inline-sticky count (REST only) for the breaker rule + the
            // freshness timestamp/signature for the stale-while-revalidate re-poll.
            if (status == 200) {
                ApolloHLRestCache()[key] = items;
                ApolloHLStickyCount()[key] = @(items.count);
                ApolloHLFetchTime()[key] = [NSDate date];
                ApolloHLRestSig()[key] = ApolloHLItemsContentSig(items);
            }
            if (completion) completion(completionItems);
        });
    }] resume];
}

#pragma mark - Thumbnail image loader

static NSCache<NSString *, UIImage *> *ApolloHLImageCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 120; });
    return cache;
}

static void ApolloHLLoadImage(NSURL *url, void (^completion)(UIImage *image)) {
    if (!url || !completion) { if (completion) completion(nil); return; }
    NSString *key = url.absoluteString;
    UIImage *cached = [ApolloHLImageCache() objectForKey:key];
    if (cached) { completion(cached); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 15.0;
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloHighlights/1.0") forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data] : nil;
        if (image) [ApolloHLImageCache() setObject:image forKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
    }] resume];
}

// Heavy gaussian blur for spoiler thumbnails — obscures the image content while
// keeping its colours (a real CIGaussianBlur, not a frosted material overlay), so
// a spoiler card reads as "blurred photo" like the Reddit website. Radius scales
// with the source pixel width so the blur stays heavy regardless of thumbnail size.
static UIImage *ApolloHLSpoilerBlur(UIImage *image) {
    if (!image || !image.CGImage) return image;
    CIImage *ci = [CIImage imageWithCGImage:image.CGImage];
    CIImage *clamped = [ci imageByClampingToExtent]; // avoid transparent blurred edges
    CGFloat radius = MAX(18.0, MIN(60.0, (CGFloat)CGImageGetWidth(image.CGImage) * 0.06));
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:clamped forKey:kCIInputImageKey];
    [blur setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *out = blur.outputImage;
    if (!out) return image;
    static CIContext *ctx; static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [ctx createCGImage:out fromRect:ci.extent];
    if (!cg) return image;
    UIImage *result = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return result;
}

#pragma mark - Card view

// Cards are plain UIViews driven by a tap GESTURE (not UIControls). A tap
// recognizer coexists with the scroll view's pan, so a horizontal drag scrolls
// the carousel; UIControls swallow the drag and the carousel can't move.
@interface ApolloHLCardView : UIView
@property (nonatomic, copy) NSString *permalink;
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, copy) NSString *thumbToken; // guards async image reuse
@end
@implementation ApolloHLCardView @end

static UIColor *ApolloHLCardFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.10]
            : [UIColor colorWithWhite:0.0 alpha:0.06];
    }];
}

static NSShadow *ApolloHLTextShadow(void) {
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    shadow.shadowOffset = CGSizeMake(0, 1);
    shadow.shadowBlurRadius = 3.0;
    return shadow;
}

static ApolloHLCardView *ApolloHLBuildCard(ApolloHLItem *item) {
    CGFloat W = kApolloHLCardWidth, H = kApolloHLCardHeight, pad = 10.0;
    ApolloHLCardView *card = [[ApolloHLCardView alloc] initWithFrame:CGRectMake(0, 0, W, H)];
    card.permalink = item.permalink;
    card.layer.cornerRadius = 14.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    // Fully touch-transparent: every touch (drag OR tap) falls straight through
    // to the scroll view, so the WHOLE card body scrolls. A single tap recognizer
    // on the scroll view (below) hit-tests which card was tapped by frame.
    card.userInteractionEnabled = NO;

    BOOL hasImage = item.thumbnailURL != nil;
    BOOL spoiler = item.isSpoiler;
    if (hasImage) {
        // Image fills the whole card as a background.
        UIImageView *bg = [[UIImageView alloc] initWithFrame:card.bounds];
        bg.contentMode = UIViewContentModeScaleAspectFill;
        bg.clipsToBounds = YES;
        bg.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        bg.userInteractionEnabled = NO;
        [card addSubview:bg];
        card.thumbView = bg;

        // Normal cards get a light frosted blur so the overlaid text reads. Spoiler
        // cards instead get a HEAVY gaussian blur of the image itself (applied below
        // on load), so we skip the frosted material to keep the blurred photo vivid.
        if (!spoiler) {
            UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
            blur.frame = card.bounds;
            blur.alpha = 0.8;
            blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blur.userInteractionEnabled = NO;
            [card addSubview:blur];
        }

        // Extra darkening at the top (title) and bottom (meta); spoiler cards darken
        // the middle a little more so the title reads over the blurred photo.
        UIView *scrim = [[UIView alloc] initWithFrame:card.bounds];
        scrim.userInteractionEnabled = NO;
        CAGradientLayer *grad = [CAGradientLayer layer];
        grad.frame = CGRectMake(0, 0, W, H);
        grad.colors = @[ (id)[UIColor colorWithWhite:0 alpha:0.55].CGColor,
                         (id)[UIColor colorWithWhite:0 alpha:(spoiler ? 0.30 : 0.08)].CGColor,
                         (id)[UIColor colorWithWhite:0 alpha:(spoiler ? 0.45 : 0.38)].CGColor ];
        grad.locations = @[@0.0, @0.5, @1.0];
        [scrim.layer addSublayer:grad];
        [card addSubview:scrim];

        NSString *token = item.thumbnailURL.absoluteString;
        card.thumbToken = token;
        __weak ApolloHLCardView *weakCard = card;
        ApolloHLLoadImage(item.thumbnailURL, ^(UIImage *image) {
            ApolloHLCardView *strongCard = weakCard;
            if (!image || !strongCard || ![strongCard.thumbToken isEqualToString:token]) return;
            if (spoiler) {
                // Heavy-blur off the main thread (the card may scroll meanwhile).
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    UIImage *blurred = ApolloHLSpoilerBlur(image);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ApolloHLCardView *sc = weakCard;
                        if (sc && [sc.thumbToken isEqualToString:token]) sc.thumbView.image = blurred;
                    });
                });
            } else {
                strongCard.thumbView.image = image;
            }
        });
    } else {
        card.backgroundColor = ApolloHLCardFillColor();
    }

    // Spoiler badge (top-left) so the user knows why the image is obscured.
    CGFloat titleTop = pad;
    if (spoiler) {
        CGFloat badgeH = 18.0, iconSize = 11.0, gap = 3.0, hpad = 6.0;
        UILabel *sl = [[UILabel alloc] init];
        sl.text = @"SPOILER";
        sl.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightBold];
        sl.textColor = UIColor.whiteColor;
        [sl sizeToFit];
        CGFloat textW = ceil(sl.bounds.size.width);
        UIView *badge = [[UIView alloc] initWithFrame:CGRectMake(pad, pad, hpad + iconSize + gap + textW + hpad, badgeH)];
        badge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        badge.layer.cornerRadius = badgeH / 2.0;
        badge.clipsToBounds = YES;
        badge.userInteractionEnabled = NO;
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"eye.slash.fill"]];
        icon.tintColor = UIColor.whiteColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.frame = CGRectMake(hpad, (badgeH - iconSize) / 2.0, iconSize, iconSize);
        [badge addSubview:icon];
        sl.frame = CGRectMake(hpad + iconSize + gap, (badgeH - sl.bounds.size.height) / 2.0, textW, sl.bounds.size.height);
        [badge addSubview:sl];
        [card addSubview:badge];
        titleTop = pad + badgeH + 4.0;
    }

    // Title — top-aligned, white over an image, label color on a plain card.
    UILabel *title = [[UILabel alloc] init];
    title.numberOfLines = 4;
    title.userInteractionEnabled = NO;
    NSMutableDictionary *attrs = [@{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: hasImage ? UIColor.whiteColor : UIColor.labelColor,
    } mutableCopy];
    if (hasImage) attrs[NSShadowAttributeName] = ApolloHLTextShadow();
    title.attributedText = [[NSAttributedString alloc] initWithString:item.title attributes:attrs];
    CGSize tfit = [title sizeThatFits:CGSizeMake(W - pad * 2, H - titleTop - 16.0)];
    title.frame = CGRectMake(pad, titleTop, W - pad * 2, MIN(tfit.height, H - titleTop - 16.0));
    [card addSubview:title];

    // Meta (flair or comment count) bottom-left.
    NSString *flair = ApolloHLStripEmojiTokens(item.flairText);
    NSString *meta = flair.length ? flair
                   : (item.numComments > 0 ? [NSString stringWithFormat:@"%lld comments", item.numComments] : nil);
    if (meta.length) {
        UILabel *metaLabel = [[UILabel alloc] init];
        metaLabel.userInteractionEnabled = NO;
        NSMutableDictionary *mattrs = [@{
            NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: hasImage ? [UIColor colorWithWhite:1.0 alpha:0.95] : UIColor.secondaryLabelColor,
        } mutableCopy];
        if (hasImage) mattrs[NSShadowAttributeName] = ApolloHLTextShadow();
        metaLabel.attributedText = [[NSAttributedString alloc] initWithString:meta attributes:mattrs];
        metaLabel.frame = CGRectMake(pad, H - pad - 15.0, W - pad * 2, 16.0);
        [card addSubview:metaLabel];
    }
    return card;
}

#pragma mark - Carousel view

// The cards are UIControls; UIScrollView's default touchesShouldCancelInContentView:
// returns NO for UIControl subviews, so a drag that starts on a card is swallowed
// as a tap and the carousel never scrolls. Returning YES lets a drag take over.
// A UIScrollView IS its own pan gesture's delegate (and forbids replacing it —
// setting panGestureRecognizer.delegate throws). So we subclass and implement the
// simultaneous-recognition delegate method here: it lets the carousel's horizontal
// pan recognize ALONGSIDE the feed table's vertical pan, so a horizontal drag is
// never swallowed by the table (the cause of the "only certain spots scroll"
// flakiness). The other delegate methods stay UIScrollView's own.
@interface ApolloHLCarouselScrollView : UIScrollView <UIGestureRecognizerDelegate, UIScrollViewDelegate>
// The feed scroll view whose vertical pan we've paused for the duration of a
// horizontal carousel drag (weak so a torn-down feed can't dangle).
@property (nonatomic, weak) UIScrollView *ahlLockedFeed;
@end
@implementation ApolloHLCarouselScrollView
- (BOOL)touchesShouldCancelInContentView:(UIView *)view { return YES; }
// Coexist with the feed's vertical scroll (also a UIScrollView pan) so vertical
// drags still scroll the feed — but NOT with the nav's back-swipe (handled below).
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [other.view isKindOfClass:[UIScrollView class]];
}
// Make the navigation controller's swipe-to-go-back pan (a non-scrollview pan /
// screen-edge pan on an ancestor) WAIT for our horizontal scroll to fail. A
// sideways swipe then scrolls the carousel; it only falls through to "go back"
// when our scroll can't move (e.g. already at the end). This is the fix for the
// back-swipe stealing horizontal drags over the carousel.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (g != self.panGestureRecognizer) return NO;
    if (![other isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
    if ([other.view isKindOfClass:[UIScrollView class]]) return NO; // feed table — coexist instead
    return YES; // nav back-swipe pan must fail for our scroll to win
}
// The delegate method above isn't re-consulted when the carousel is REBUILT (e.g.
// the web upgrade swaps in a new scroll view), so the new pan loses priority and
// the back-swipe steals horizontal drags again. Re-establish it explicitly every
// time we (re)enter a window: make every ancestor back-swipe pan require OUR pan
// to fail (only affects touches actually on the carousel).
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) { [self ahlUnlockFeed]; return; } // torn down mid-drag — never leave the feed locked
    for (UIView *v = self.superview; v != nil; v = v.superview) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == self.panGestureRecognizer) continue;
            if ([g isKindOfClass:[UIPanGestureRecognizer class]] && ![g.view isKindOfClass:[UIScrollView class]]) {
                [g requireGestureRecognizerToFail:self.panGestureRecognizer];
            }
        }
    }
}

// Horizontal-scroll LOCK: simultaneous recognition (above) is what stops the feed
// table from swallowing horizontal swipes — but it also lets the feed scroll
// vertically at the same time, so an unsteady thumb bounces the whole page while
// swiping the cards. To fix that we pause the feed's vertical pan for the duration
// of a carousel drag (we're the scroll view's own UIScrollViewDelegate). The drag
// only begins once the carousel commits to horizontal movement, so a purely
// vertical drag that started on the carousel still scrolls the feed normally.
- (UIScrollView *)ahlEnclosingFeedScrollView {
    for (UIView *v = self.superview; v != nil; v = v.superview) {
        if ([v isKindOfClass:[UIScrollView class]]) return (UIScrollView *)v; // nearest ancestor = the feed
    }
    return nil;
}
- (void)ahlUnlockFeed {
    UIScrollView *feed = self.ahlLockedFeed;
    if (feed) { feed.panGestureRecognizer.enabled = YES; self.ahlLockedFeed = nil; }
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != self || self.ahlLockedFeed) return;
    // Only lock for a horizontal-dominant drag; a vertical drag that began on the
    // carousel should still scroll the feed.
    CGPoint t = [self.panGestureRecognizer translationInView:self];
    if (fabs(t.x) < fabs(t.y)) return;
    UIScrollView *feed = [self ahlEnclosingFeedScrollView];
    if (feed && feed.panGestureRecognizer.enabled) {
        feed.panGestureRecognizer.enabled = NO; // cancels any in-flight vertical scroll, blocks new ones
        self.ahlLockedFeed = feed;
    }
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == self) [self ahlUnlockFeed]; // finger up -> no touch can bounce the feed; release immediately
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == self) [self ahlUnlockFeed]; // backstop
}
// If THIS carousel is removed mid-drag — e.g. the web upgrade or a collapse toggle
// rebuilds it while the user is swiping — release our feed lock as we leave the
// window, so the feed's vertical scroll can never be left permanently disabled
// (the replacement scroll view has no reference to the old lock).
- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
    if (!newWindow) [self ahlUnlockFeed];
}
@end

static void ApolloHLToggleCollapsed(NSString *sub); // fwd (defined after ApplyItems)

@interface ApolloHLCarouselView : UIView
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic, copy) NSString *subreddit; // for the collapse toggle
@end
@implementation ApolloHLCarouselView
// Tapping the title row toggles (and persists) the collapsed state for this sub.
- (void)headerTapped:(UITapGestureRecognizer *)gesture {
    if (self.subreddit.length) ApolloHLToggleCollapsed(self.subreddit);
}
// Single tap recognizer lives on the scroll view; find the card under the tap.
- (void)cardTapped:(UITapGestureRecognizer *)gesture {
    UIScrollView *sv = self.scrollView;
    if (!sv) return;
    CGPoint p = [gesture locationInView:sv];
    NSString *permalink = nil;
    for (UIView *v in sv.subviews) {
        if ([v isKindOfClass:[ApolloHLCardView class]] && CGRectContainsPoint(v.frame, p)) {
            permalink = ((ApolloHLCardView *)v).permalink;
            break;
        }
    }
    if (permalink.length == 0) return;
    NSString *full = [permalink hasPrefix:@"http"] ? permalink
                   : [NSString stringWithFormat:@"https://reddit.com%@", permalink];
    NSURL *url = [NSURL URLWithString:full];
    if (!url) return;
    ApolloLog(@"[Highlights] card tapped -> %@", full);
    ApolloRouteResolvedURLViaApolloScheme(url);
}
@end

// Presentation signature includes metadata as well as post identity. The fast web
// path intentionally paints titles/links before /api/info enrichment returns; once
// thumbnails/flair/comment counts arrive, this signature makes the second ApplyItems
// call rebuild those same cards with their richer presentation.
static NSString *ApolloHLItemsPresentationSig(NSArray<ApolloHLItem *> *items) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (ApolloHLItem *it in items) {
        [parts addObject:[NSString stringWithFormat:@"%@\x1F%@\x1F%@\x1F%@\x1F%lld\x1F%d",
                          it.fullName ?: it.permalink ?: @"?",
                          it.title ?: @"",
                          it.thumbnailURL.absoluteString ?: @"",
                          it.flairText ?: @"",
                          it.numComments,
                          it.isSpoiler]];
    }
    return [parts componentsJoinedByString:@"\x1E"];
}

// A stable signature for a set of items PLUS the collapse state, so we rebuild
// when either the content, its presentation metadata, or collapsed state changes.
static NSString *ApolloHLSignature(NSString *sub, NSArray<ApolloHLItem *> *items) {
    NSString *state = ApolloHLIsCollapsed(sub) ? @"C|" : @"E|";
    return [state stringByAppendingString:ApolloHLItemsPresentationSig(items)];
}

// Content-only signature (no collapse-state prefix) used to detect when a subreddit's
// pinned set actually changes between fetches — so a background re-poll rebuilds only
// on a real change, not on every poll.
static NSString *ApolloHLItemsContentSig(NSArray<ApolloHLItem *> *items) {
    NSMutableArray *ids = [NSMutableArray array];
    for (ApolloHLItem *it in items) [ids addObject:(it.fullName ?: it.permalink ?: @"?")];
    return [ids componentsJoinedByString:@"|"];
}

static CGFloat ApolloHLCarouselHeight(void) {
    return kApolloHLTitleRowHeight + kApolloHLTopPadding + kApolloHLCardHeight + kApolloHLBottomPadding;
}

static ApolloHLCarouselView *ApolloHLBuildCarousel(NSString *sub, NSArray<ApolloHLItem *> *items, CGFloat width) {
    if (items.count == 0) return nil;
    BOOL collapsed = ApolloHLIsCollapsed(sub);
    CGFloat height = collapsed ? (kApolloHLTitleRowHeight + 8.0) : ApolloHLCarouselHeight();
    ApolloHLCarouselView *view = [[ApolloHLCarouselView alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    view.backgroundColor = [UIColor clearColor];
    view.subreddit = sub.lowercaseString;
    view.signature = ApolloHLSignature(sub, items);

    // Section title row: pin glyph + "Community Highlights" + collapse chevron.
    UIImageView *pin = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pin.fill"]];
    pin.tintColor = UIColor.secondaryLabelColor;
    pin.contentMode = UIViewContentModeScaleAspectFit;
    pin.frame = CGRectMake(kApolloHLSidePadding, 6.0, 12.0, 14.0);
    [view addSubview:pin];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(kApolloHLSidePadding + 18.0, 2.0, width - kApolloHLSidePadding * 2 - 18.0 - 20.0, kApolloHLTitleRowHeight - 2.0)];
    titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = UIColor.secondaryLabelColor;
    titleLabel.text = @"Community Highlights";
    [view addSubview:titleLabel];

    // Chevron at the trailing edge: up = expanded (tap to collapse), down = collapsed.
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(collapsed ? @"chevron.down" : @"chevron.up")]];
    chevron.tintColor = UIColor.secondaryLabelColor;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.frame = CGRectMake(width - kApolloHLSidePadding - 13.0, 7.0, 13.0, 11.0);
    [view addSubview:chevron];

    // Transparent tap target over the whole title row toggles collapse.
    UIView *headerTap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, kApolloHLTitleRowHeight)];
    headerTap.backgroundColor = [UIColor clearColor];
    [headerTap addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:view action:@selector(headerTapped:)]];
    [view addSubview:headerTap];

    if (collapsed) return view; // just the title bar; no scroller or cards

    // Horizontal scroller of cards.
    CGFloat scrollY = kApolloHLTitleRowHeight + kApolloHLTopPadding;
    UIScrollView *scroll = [[ApolloHLCarouselScrollView alloc] initWithFrame:CGRectMake(0, scrollY, width, kApolloHLCardHeight)];
    scroll.showsHorizontalScrollIndicator = NO;
    scroll.alwaysBounceHorizontal = YES;
    scroll.clipsToBounds = NO;
    scroll.delaysContentTouches = NO;
    scroll.directionalLockEnabled = YES;
    scroll.delegate = (ApolloHLCarouselScrollView *)scroll; // self-delegate for the horizontal-scroll lock
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:view action:@selector(cardTapped:)];
    [scroll addGestureRecognizer:tap];
    [view addSubview:scroll];
    view.scrollView = scroll;

    CGFloat x = kApolloHLSidePadding;
    for (ApolloHLItem *item in items) {
        ApolloHLCardView *card = ApolloHLBuildCard(item);
        card.frame = CGRectMake(x, 0, kApolloHLCardWidth, kApolloHLCardHeight);
        [scroll addSubview:card];
        x += kApolloHLCardWidth + kApolloHLCardSpacing;
    }
    x = x - kApolloHLCardSpacing + kApolloHLSidePadding; // trailing inset
    scroll.contentSize = CGSizeMake(x, kApolloHLCardHeight);

    return view;
}

static void ApolloHLForEachPostsVC(void (^block)(UIViewController *postsVC)); // fwd

// A subreddit turned out to have nothing to show (no pinned posts, or the fetch
// failed): stop de-duplicating it and, only if we'd actually collapsed cells,
// reload the feed to restore them.
static void ApolloHLClearDeDup(NSString *subreddit) {
    NSString *sub = subreddit.lowercaseString;
    if (!ApolloHLHideSubsContains(sub)) return;
    ApolloHLHideSubsRemove(sub);
    // Best-effort corrective reload: restore the inline stickies only if we actually
    // collapsed any. Each set op is individually locked (no corruption), but the
    // contains-then-remove isn't atomic across calls, so a rare main/background interleave
    // could skip this one reload — harmless, the next relayout/teardown self-heals it.
    if (ApolloHLDidCollapseContains(sub)) {
        ApolloHLDidCollapseRemove(sub);
        ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
            if ([ApolloHLSubredditName(postsVC) isEqualToString:sub]) ApolloHLReloadFeed(postsVC);
        });
    }
}

#pragma mark - Coexistence: host the carousel inside the subreddit-header wrapper

// Stacks the carousel above Apollo's real "original header" so the headers
// module can treat the whole thing as its original-header slot (its existing
// layout sizes/positions it). The carousel may be absent until data lands.
@interface ApolloHLHeaderContainerView : UIView
@property (nonatomic, strong) UIView *hlCarouselView; // nil until data arrives
@property (nonatomic, strong) UIView *realOriginal;   // Apollo's real header (may be nil)
@property (nonatomic, copy) NSString *subreddit;
- (void)installCarousel:(UIView *)carousel;
- (void)resizeToFit;
@end
@implementation ApolloHLHeaderContainerView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, y = 0;
    if (self.hlCarouselView) {
        self.hlCarouselView.frame = CGRectMake(0, y, w, self.hlCarouselView.frame.size.height);
        y += self.hlCarouselView.frame.size.height;
    }
    if (self.realOriginal) {
        self.realOriginal.frame = CGRectMake(0, y, w, self.realOriginal.frame.size.height);
    }
}
- (void)resizeToFit {
    CGFloat cH = self.hlCarouselView ? self.hlCarouselView.frame.size.height : 0;
    CGFloat roH = self.realOriginal ? self.realOriginal.frame.size.height : 0;
    CGRect f = self.frame; f.size.height = cH + roH; self.frame = f;
    [self setNeedsLayout];
}
- (void)installCarousel:(UIView *)carousel {
    if (self.hlCarouselView == carousel) return;
    [self.hlCarouselView removeFromSuperview];
    self.hlCarouselView = carousel;
    if (carousel) [self addSubview:carousel];
    [self resizeToFit];
}
@end

static void ApolloHLApplyStickyCountToTable(UIViewController *vc, NSString *subreddit); // defined near ApolloHLInstall

UIView *ApolloHLHeaderOriginalSubstitute(NSString *subreddit, UIViewController *hostVC, UIView *realOriginalHeader, CGFloat width) {
    if (!sCommunityHighlights || subreddit.length == 0) return realOriginalHeader;
    NSString *sub = subreddit.lowercaseString;
    if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;

    // De-dup membership now (the header installs before cells render).
    ApolloHLHideSubsAdd(sub);
    if (hostVC) objc_setAssociatedObject(hostVC, kApolloHLActiveSubKey, sub, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Don't nest containers across rebuilds — recover the true original.
    UIView *realOriginal = realOriginalHeader;
    if ([realOriginalHeader isKindOfClass:[ApolloHLHeaderContainerView class]]) {
        realOriginal = ((ApolloHLHeaderContainerView *)realOriginalHeader).realOriginal;
    }

    ApolloHLHeaderContainerView *container =
        [[ApolloHLHeaderContainerView alloc] initWithFrame:CGRectMake(0, 0, width, realOriginal ? realOriginal.frame.size.height : 0)];
    container.subreddit = sub;
    container.realOriginal = realOriginal;
    if (realOriginal) [container addSubview:realOriginal];
    if (hostVC) objc_setAssociatedObject(hostVC, kApolloHLContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSArray<ApolloHLItem *> *items = ApolloHLCache()[sub];
    if (items.count > 0) {
        [container installCarousel:ApolloHLBuildCarousel(sub, items, width)];
    } else if (items == nil) {
        CGFloat fetchWidth = width;
        ApolloHLFetchHighlights(sub, NO, ^(NSArray<ApolloHLItem *> *fetched) {
            if (fetched == nil) return;
            if (fetched.count == 0) { ApolloHLClearDeDup(sub); return; }
            // Populate any live containers for this sub, then re-measure the
            // (now taller) header so the feed sits below the carousel.
            ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
                if (![ApolloHLSubredditName(postsVC) isEqualToString:sub]) return;
                ApolloHLHeaderContainerView *c = objc_getAssociatedObject(postsVC, kApolloHLContainerKey);
                if (![c isKindOfClass:[ApolloHLHeaderContainerView class]] || c.hlCarouselView) return;
                CGFloat w = c.bounds.size.width > 0 ? c.bounds.size.width : fetchWidth;
                [c installCarousel:ApolloHLBuildCarousel(sub, fetched, w)];
                ApolloHLApplyStickyCountToTable(postsVC, sub); // headers mode: publish N now that the REST fetch landed
                UIView *wrapper = c.superview;
                UITableView *tv = ApolloHLFindTableView(postsVC);
                if (wrapper && tv && tv.tableHeaderView == wrapper) {
                    CGRect wf = wrapper.frame;
                    wf.size.height = CGRectGetMaxY(c.frame);
                    wrapper.frame = wf;
                    [tv setTableHeaderView:wrapper]; // force the table to re-read the header height
                }
            });
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloHLDataReadyNotification object:nil];
        });
    }
    [container resizeToFit];
    return container;
}

#pragma mark - tableHeaderView install / teardown

static UIView *ApolloHLBuildWrapper(ApolloHLCarouselView *carousel, UIView *originalHeader, CGFloat width) {
    if (!carousel) return nil;
    CGFloat carouselHeight = carousel.frame.size.height;
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    UIView *wrapper = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, carouselHeight + originalHeight)];
    wrapper.backgroundColor = [UIColor clearColor];
    objc_setAssociatedObject(wrapper, kApolloHLWrapperMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    carousel.frame = CGRectMake(0, 0, width, carouselHeight);
    [wrapper addSubview:carousel];
    if (originalHeader) {
        originalHeader.frame = CGRectMake(0, carouselHeight, width, originalHeight);
        [wrapper addSubview:originalHeader];
    }
    return wrapper;
}

// Remove the standalone-managed tableHeaderView (carousel) and restore Apollo's
// native header. Does NOT touch de-dup state (the hide-set) — used both by full
// teardown and when handing placement over to the subreddit-headers feature.
static void ApolloHLRestoreStandaloneHeader(UIViewController *vc) {
    UITableView *tableView = ApolloHLFindTableView(vc);
    UIView *wrapper = objc_getAssociatedObject(vc, kApolloHLWrapperKey);
    UIView *originalHeader = objc_getAssociatedObject(vc, kApolloHLOriginalHeaderKey);

    if (tableView && wrapper && tableView.tableHeaderView == wrapper) {
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = originalHeader;
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloHLManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloHLManagedVCKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(vc, kApolloHLCarouselKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLWrapperKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLSubredditKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLSignatureKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void ApolloHLTeardown(UIViewController *vc, BOOL restoreNativeHeader) {
    if (!vc) return;

    // Stop de-duplicating this VC's subreddit.
    NSString *activeSub = objc_getAssociatedObject(vc, kApolloHLActiveSubKey);
    if (activeSub.length) {
        ApolloHLHideSubsRemove(activeSub);
        ApolloHLDidCollapseRemove(activeSub);
        objc_setAssociatedObject(vc, kApolloHLActiveSubKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    objc_setAssociatedObject(vc, kApolloHLContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Clear the per-table de-duped-sticky rows so the next sub's separators can't
    // self-collapse against stale rows. EMPTY it (don't free the set) under the same
    // owningTable lock — an off-main layout pass may be reading it concurrently.
    id tableNode = ApolloHLTypedIvar(vc, @"tableNode", objc_getClass("ASTableNode"));
    if (tableNode) @synchronized(tableNode) {
        [(NSMutableSet *)objc_getAssociatedObject(tableNode, &kApolloHLHiddenRowsKey) removeAllObjects];
    }
    ApolloHLRestoreStandaloneHeader(vc);
}

// Mid-search predicate from ApolloSearchInPlace.xm (same dylib): YES while this feed table is showing
// search results for a non-empty query, so we must not re-attach/scroll its carousel back to the top.
extern BOOL ApolloFeedSearchIsActiveQuery(UIScrollView *tv);

// Keep a just-re-attached standalone carousel pinned to the feed top while the search dismiss finishes.
// The dismiss animates BOTH the content inset (the search field restoring) and the offset back over a
// device-dependent duration (the sim is much faster than a real device — see the memory's issues 2/2b),
// so a single scroll mis-lands: read too early (before the field's inset grows back) and we over-scroll
// the carousel up behind the nav, hiding the field. Instead re-pin to the CURRENT -inset.top every ~0.1s
// for up to ~0.8s, so the carousel tracks the field as its inset grows and ends just below it. Aborts
// permanently the moment the user takes over the scroll (tracking/dragging/decelerating) or a search
// re-activates. Non-animated (instant) so the per-tick re-pin reads as one smooth settle, and re-reads the
// table weakly so it never retains it across the delays.
static void ApolloHLPinCarouselToTop(UITableView *tv, int attempt) {
    if (!tv || attempt > 8) return;
    if (tv.tracking || tv.dragging || tv.decelerating) return;     // user took over → stop
    if (ApolloFeedSearchIsActiveQuery((UIScrollView *)tv)) return;  // search re-activated → leave results up
    CGFloat top = -tv.adjustedContentInset.top;
    if (tv.contentOffset.y > top + 0.5) {
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, top) animated:NO];
    }
    __weak UITableView *weakTV = tv;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloHLPinCarouselToTop(weakTV, attempt + 1);
    });
}

static void ApolloHLInstallCarousel(UIViewController *vc, UITableView *tableView, NSArray<ApolloHLItem *> *items, NSString *subreddit) {
    if (items.count == 0) {
        // Nothing pinned — make sure we aren't leaving a stale carousel up.
        if (objc_getAssociatedObject(vc, kApolloHLWrapperKey)) ApolloHLTeardown(vc, YES);
        return;
    }
    NSString *signature = ApolloHLSignature(subreddit, items);
    NSString *storedSubreddit = objc_getAssociatedObject(vc, kApolloHLSubredditKey);
    NSString *storedSignature = objc_getAssociatedObject(vc, kApolloHLSignatureKey);
    UIView *wrapper = objc_getAssociatedObject(vc, kApolloHLWrapperKey);

    BOOL sameContent = [storedSubreddit isEqualToString:subreddit] && [storedSignature isEqualToString:signature];
    if (sameContent && wrapper && tableView.tableHeaderView == wrapper) {
        // Already installed and current — UNLESS the wrapper has been detached from the window while the
        // table is on-screen. Apollo's in-place feed search removes the tableHeaderView from the view
        // hierarchy to show results, but leaves the `tableHeaderView` PROPERTY pointing at our wrapper, so
        // on dismiss every re-install short-circuits here and the carousel never comes back (it's set but
        // unrendered → a blank gap). Detect that and force a re-attach: nil then re-set under the rewrap
        // guard so the table re-adds + lays out the header. STANDALONE carousel only (Subreddit Headers
        // off): when headers are on, the carousel is hosted inside the headers wrapper and the search
        // module owns that chrome, so re-seating + scrolling here would scroll the banner off. And skip
        // entirely while a search is ACTIVE with a query (results are showing) — re-attaching + scrolling
        // to the top then would yank the user's results away; the carousel should only come back once the
        // search ends (dismiss) or the query is cleared to empty.
        if (sShowSubredditHeaders || !(tableView.window && !wrapper.window) ||
            ApolloFeedSearchIsActiveQuery((UIScrollView *)tableView)) {
            return; // headers-hosted, attached/off-screen, or mid-search → nothing to do
        }
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = nil;
        tableView.tableHeaderView = wrapper;
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The feed is still scrolled where the search results were, so the just-re-attached carousel sits
        // above the viewport (behind the field). Pin it back to the top so it's visible again — tracking the
        // still-restoring inset so it lands just below the field instead of over-scrolling behind the nav.
        ApolloHLPinCarouselToTop(tableView, 0);
        ApolloLog(@"[Highlights] re-attached detached carousel r/%@", subreddit);
        return;
    }

    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : UIScreen.mainScreen.bounds.size.width;

    if (sameContent && wrapper) {
        // Carousel exists but isn't the live header (Apollo swapped it). Re-seat.
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = wrapper;
        objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloHLManagedTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloHLManagedVCKey, vc, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    // Build fresh.
    ApolloHLCarouselView *carousel = ApolloHLBuildCarousel(subreddit, items, width);
    if (!carousel) return;

    UIView *currentHeader = tableView.tableHeaderView;
    // On a REBUILD (collapse toggle, web upgrade) the live header is already OUR
    // marked wrapper — recover Apollo's real header from storage rather than
    // dropping it (otherwise the native header is permanently lost). On a first
    // install the live header is Apollo's own, so adopt it directly.
    BOOL currentIsOurWrapper = currentHeader && objc_getAssociatedObject(currentHeader, kApolloHLWrapperMarkerKey);
    UIView *originalHeader = currentIsOurWrapper ? objc_getAssociatedObject(vc, kApolloHLOriginalHeaderKey) : currentHeader;
    UIView *newWrapper = ApolloHLBuildWrapper(carousel, originalHeader, width);

    objc_setAssociatedObject(vc, kApolloHLCarouselKey, carousel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLWrapperKey, newWrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLSubredditKey, subreddit, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLSignatureKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);

    objc_setAssociatedObject(tableView, kApolloHLManagedTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tableView, kApolloHLManagedVCKey, vc, OBJC_ASSOCIATION_ASSIGN);

    objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    tableView.tableHeaderView = newWrapper;
    objc_setAssociatedObject(tableView, kApolloHLRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloLog(@"[Highlights] installed carousel r/%@ items=%lu width=%.0f", subreddit, (unsigned long)items.count, width);
}

// Collect all live root view controllers across every connected window scene
// (iOS 13+/scene apps; UIApplication.windows alone can miss the active scene).
static NSArray<UIViewController *> *ApolloHLRootViewControllers(void) {
    NSMutableArray<UIViewController *> *roots = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.rootViewController) [roots addObject:window.rootViewController];
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.rootViewController && ![roots containsObject:window.rootViewController]) {
            [roots addObject:window.rootViewController];
        }
    }
    return roots;
}

// Walk the live VC hierarchy and invoke `block` for every PostsViewController.
static void ApolloHLForEachPostsVC(void (^block)(UIViewController *postsVC)) {
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    if (!postsClass || !block) return;
    NSMutableArray<UIViewController *> *stack = [[ApolloHLRootViewControllers() mutableCopy] ?: [NSMutableArray array] mutableCopy];
    NSMutableSet *seen = [NSMutableSet set];
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        if (!vc || [seen containsObject:@((uintptr_t)vc)]) continue;
        [seen addObject:@((uintptr_t)vc)];
        if ([vc isKindOfClass:postsClass]) block(vc);
        [stack addObjectsFromArray:vc.childViewControllers];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
    }
}

#pragma mark - Web upgrade (full highlights via hidden WebView)

// Subreddits whose web-fetch has completed (so we don't re-run the heavy WebView)
// and those currently fetching.
static NSMutableSet<NSString *> *ApolloHLWebDone(void) {
    static NSMutableSet *s; static dispatch_once_t o; dispatch_once(&o, ^{ s = [NSMutableSet set]; }); return s;
}
static NSMutableDictionary<NSString *, ApolloHLWebFetch *> *ApolloHLWebFetchers(void) {
    static NSMutableDictionary *d; static dispatch_once_t o; dispatch_once(&o, ^{ d = [NSMutableDictionary dictionary]; }); return d;
}

// Rebuild the carousel(s) for `sub` with a new (fuller) item set — used when the
// WebView upgrade lands. Handles both placement modes.
static void ApolloHLApplyItems(NSString *sub, NSArray<ApolloHLItem *> *items) {
    if (sub.length == 0 || items.count == 0) return;
    ApolloHLCache()[sub] = items;
    ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
        if (ApolloHLShouldSkipViewController(postsVC)) return;
        if (![ApolloHLSubredditName(postsVC) isEqualToString:sub]) return;
        if (!sShowSubredditHeaders) {
            UITableView *tv = ApolloHLFindTableView(postsVC);
            if (tv) ApolloHLInstallCarousel(postsVC, tv, items, sub); // signature change → rebuilds
        } else {
            ApolloHLHeaderContainerView *c = objc_getAssociatedObject(postsVC, kApolloHLContainerKey);
            if (![c isKindOfClass:[ApolloHLHeaderContainerView class]]) return;
            CGFloat w = c.bounds.size.width > 0 ? c.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
            [c installCarousel:ApolloHLBuildCarousel(sub, items, w)];
            UIView *wrapper = c.superview;
            UITableView *tv = ApolloHLFindTableView(postsVC);
            if (wrapper && tv && tv.tableHeaderView == wrapper) {
                CGRect wf = wrapper.frame; wf.size.height = CGRectGetMaxY(c.frame); wrapper.frame = wf;
                [tv setTableHeaderView:wrapper];
            }
        }
    });
}

// Flip the persisted collapse state for `sub` and rebuild its live carousel(s).
// The collapse state is part of the carousel signature, so ApplyItems' standalone
// path rebuilds (instead of early-returning on unchanged content); the headers path
// always rebuilds + re-measures. De-dup is left intact, so collapsing just hides the
// cards behind the title bar (the highlights don't reappear inline), matching the web.
static void ApolloHLToggleCollapsed(NSString *sub) {
    NSString *key = sub.lowercaseString;
    if (key.length == 0) return;
    BOOL now = !ApolloHLIsCollapsed(key);
    ApolloHLSetCollapsed(key, now);
    ApolloLog(@"[Highlights] %@ r/%@", now ? @"collapsed" : @"expanded", key);
    NSArray<ApolloHLItem *> *items = ApolloHLCache()[key];
    if (items.count > 0) ApolloHLApplyItems(key, items);
}

// The WebView reliably gives us the LIST of highlights (titles + permalinks, in
// order) but its DOM thumbnails are lazy-loaded/unreliable for cards scrolled off
// screen. So we don't trust the DOM image: we take the post ids from the web set
// and batch-fetch each post's real data via the API's /api/info endpoint — the same
// reliable source that gives the first 2 their crisp thumbnails. Thumbnail/flair/
// comment-count are filled from /api/info, then the API stickied cache, then the
// web DOM as a last resort. Web order is preserved. `completion` runs on main.
static void ApolloHLMergeMetadata(NSArray<ApolloHLItem *> *webItems,
                                  NSArray<ApolloHLItem *> *apiItems,
                                  NSDictionary<NSString *, ApolloHLItem *> *infoMap) {
    NSMutableDictionary<NSString *, ApolloHLItem *> *apiByID = [NSMutableDictionary dictionary];
    for (ApolloHLItem *a in apiItems) {
        NSString *pid = ApolloHLPostIDFromPermalink(a.permalink);
        if (pid.length) apiByID[pid] = a;
    }
    for (ApolloHLItem *w in webItems) {
        NSString *pid = ApolloHLPostIDFromPermalink(w.permalink);
        ApolloHLItem *info = pid.length ? infoMap[[@"t3_" stringByAppendingString:pid]] : nil;
        ApolloHLItem *api = pid.length ? apiByID[pid] : nil;
        if (!w.fullName.length) w.fullName = info.fullName ?: api.fullName;
        if (!w.thumbnailURL) w.thumbnailURL = info.thumbnailURL ?: api.thumbnailURL;
        if (!w.flairText.length) w.flairText = info.flairText ?: api.flairText;
        if (w.numComments == 0) w.numComments = info ? info.numComments : (api ? api.numComments : 0);
        if (!w.isSpoiler) w.isSpoiler = info ? info.isSpoiler : (api ? api.isSpoiler : NO);
    }
}

static void ApolloHLEnrichViaInfo(NSArray<ApolloHLItem *> *webItems, NSArray<ApolloHLItem *> *apiItems, void (^completion)(NSArray<ApolloHLItem *> *)) {
    NSMutableArray<NSString *> *fullnames = [NSMutableArray array];
    for (ApolloHLItem *w in webItems) {
        NSString *pid = ApolloHLPostIDFromPermalink(w.permalink);
        if (pid.length) [fullnames addObject:[@"t3_" stringByAppendingString:pid]];
    }

    void (^finish)(NSDictionary<NSString *, ApolloHLItem *> *) = ^(NSDictionary<NSString *, ApolloHLItem *> *infoMap) {
        // `items` may already be the live main-queue cache because the fast path
        // paints it before enrichment. Keep both mutation and callback on main.
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloHLMergeMetadata(webItems, apiItems, infoMap);
            completion(webItems);
        });
    };

    if (fullnames.count == 0) { finish(@{}); return; }
    NSString *idParam = [fullnames componentsJoinedByString:@","];
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/api/info?id=%@&raw_json=1", idParam]
        : [NSString stringWithFormat:@"https://www.reddit.com/api/info.json?id=%@&raw_json=1", idParam];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15.0;
    if (token.length > 0) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloHighlights/1.0") forHTTPHeaderField:@"User-Agent"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : -1;
        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary<NSString *, ApolloHLItem *> *infoMap = [json isKindOfClass:[NSDictionary class]] ? ApolloHLParseInfoListing(json) : @{};
        ApolloLog(@"[Highlights] info enrich status=%ld ids=%lu resolved=%lu", (long)status, (unsigned long)fullnames.count, (unsigned long)infoMap.count);
        finish(infoMap);
    }] resume];
}

// If enabled, kick a one-time hidden-WebView fetch of the FULL highlights for the
// sub and upgrade the carousel when it lands (only if it found more than the API).
static void ApolloHLMaybeWebUpgrade(NSString *subreddit) {
    if (!sCommunityHighlights || !sCommunityHighlightsWeb) return;
    NSString *sub = subreddit.lowercaseString;
    if (sub.length == 0 || [ApolloHLWebDone() containsObject:sub] || ApolloHLWebFetchers()[sub]) return;
    ApolloHLWebFetch *fetch = [[ApolloHLWebFetch alloc] init];
    ApolloHLWebFetchers()[sub] = fetch;
    [fetch startForSub:sub completion:^(NSArray<ApolloHLItem *> *items) {
        [ApolloHLWebFetchers() removeObjectForKey:sub];
        // The user may have changed Full to Partial/Off while WebKit was still
        // rendering. Never let that stale completion restore the full set.
        if (!sCommunityHighlights || !sCommunityHighlightsWeb) return;
        [ApolloHLWebDone() addObject:sub];
        NSArray<ApolloHLItem *> *apiItems = ApolloHLRestCache()[sub] ?: ApolloHLCache()[sub];
        if (items.count == 0) return; // web found nothing

        // The DOM already has the authoritative order, titles, and links. Merge
        // whatever metadata the fast REST result already knows, then show the full
        // list immediately instead of blocking all extra cards on another network
        // round trip. Missing off-screen thumbnails/details arrive just below.
        ApolloHLMergeMetadata(items, apiItems, @{});
        NSArray<ApolloHLItem *> *cur = ApolloHLCache()[sub];
        BOOL grew = items.count > cur.count;
        BOOL differs = ![ApolloHLItemsContentSig(items) isEqualToString:ApolloHLItemsContentSig(cur)];
        if (grew || differs) {
            ApolloLog(@"[Highlights] fast web upgrade r/%@: %lu → %lu (enriching asynchronously)", sub, (unsigned long)cur.count, (unsigned long)items.count);
            ApolloHLApplyItems(sub, items);
        }

        NSString *preEnrichmentSig = ApolloHLItemsPresentationSig(items);
        // Enrich the already-visible list with reliable /api/info thumbnails. A
        // presentation-signature change rebuilds the cards, while an identical
        // response is a no-op and cannot cause a visible flash.
        ApolloHLEnrichViaInfo(items, apiItems, ^(NSArray<ApolloHLItem *> *enriched) {
            if (!sCommunityHighlights || !sCommunityHighlightsWeb) return;
            BOOL metadataChanged = ![ApolloHLItemsPresentationSig(enriched) isEqualToString:preEnrichmentSig];
            NSArray<ApolloHLItem *> *shown = ApolloHLCache()[sub];
            BOOL setChanged = ![ApolloHLItemsContentSig(enriched) isEqualToString:ApolloHLItemsContentSig(shown)];
            if (metadataChanged || setChanged) {
                ApolloLog(@"[Highlights] web enrichment r/%@ applied (metadataChanged=%d setChanged=%d)", sub, metadataChanged, setChanged);
                ApolloHLApplyItems(sub, enriched);
            }
        });
    }];
}

// Re-fetch a subreddit's highlights and update the carousel ONLY when the pinned set
// actually changed. Cheap REST re-poll; rebuilds on a content change; re-runs the heavy
// web upgrade when the set changed (or always, for an explicit pull-to-refresh). If a
// mod removed every highlight, tears the carousel down. `alwaysWeb` = an explicit
// refresh (re-harvest the web set even if the REST stickies are unchanged).
static void ApolloHLRefreshSub(NSString *subreddit, BOOL alwaysWeb) {
    if (!sCommunityHighlights) return;
    NSString *key = subreddit.lowercaseString;
    if (key.length == 0) return;
    NSString *oldSig = ApolloHLRestSig()[key];
    ApolloHLFetchHighlights(subreddit, YES, ^(NSArray<ApolloHLItem *> *freshREST) {
        if (freshREST == nil) return; // an in-flight request is already refreshing this sub
        BOOL changed = oldSig && ![ApolloHLItemsContentSig(freshREST) isEqualToString:oldSig];

        if (freshREST.count == 0) {
            // All highlights unpinned — remove the carousel (both placement modes) and
            // stop de-duping (the inline stickies, if any, return).
            if (!changed) return;
            ApolloLog(@"[Highlights] r/%@ all highlights removed → tearing down carousel", subreddit);
            ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
                if (![ApolloHLSubredditName(postsVC) isEqualToString:key]) return;
                if (!sShowSubredditHeaders) {
                    UITableView *tv = ApolloHLFindTableView(postsVC);
                    if (tv) ApolloHLInstallCarousel(postsVC, tv, @[], subreddit); // tears down our header
                } else {
                    ApolloHLHeaderContainerView *c = objc_getAssociatedObject(postsVC, kApolloHLContainerKey);
                    if (![c isKindOfClass:[ApolloHLHeaderContainerView class]]) return;
                    [c installCarousel:nil];
                    UIView *wrapper = c.superview;
                    UITableView *tv = ApolloHLFindTableView(postsVC);
                    if (wrapper && tv && tv.tableHeaderView == wrapper) {
                        CGRect wf = wrapper.frame; wf.size.height = CGRectGetMaxY(c.frame); wrapper.frame = wf;
                        [tv setTableHeaderView:wrapper];
                    }
                }
            });
            ApolloHLClearDeDup(subreddit);
            return;
        }

        if (changed) {
            ApolloLog(@"[Highlights] r/%@ pinned set changed on refresh → rebuild", subreddit);
            ApolloHLApplyItems(subreddit, freshREST); // cache := fresh REST + rebuild (both modes)
        }
        if (sCommunityHighlightsWeb && (changed || alwaysWeb)) {
            // Re-harvest the full web set; it re-applies if it differs from what's shown.
            [ApolloHLWebDone() removeObject:key];
            [ApolloHLWebFetchers() removeObjectForKey:key];
            ApolloHLMaybeWebUpgrade(subreddit);
        }
    });
}

// If the cached highlights for `subreddit` have aged past the freshness window, kick a
// quiet background re-poll (stale-while-revalidate). Called from ApolloHLInstall with an
// already-resolved sub (viewWillAppear is too early — the sub isn't set yet). Bounded to
// one refetch per window: the refetch stamps a fresh time, so it won't re-trigger until
// the window elapses again — so revisiting OR sitting on a sub stays cheap.
static void ApolloHLMaybeRefreshStale(NSString *subreddit) {
    NSString *key = subreddit.lowercaseString;
    if (!ApolloHLCache()[key]) return; // nothing cached yet → the normal fetch path handles it
    NSDate *ft = ApolloHLFetchTime()[key];
    if (ft && [[NSDate date] timeIntervalSinceDate:ft] > kApolloHLCacheTTL) {
        ApolloLog(@"[Highlights] r/%@ cache stale (>%.0fs) → background refresh", subreddit, kApolloHLCacheTTL);
        ApolloHLRefreshSub(subreddit, NO);
    }
}

static char kApolloHLSepScheduledKey; // per-VC guard: which sub we've scheduled separator passes for
static void ApolloHLCollapseOrphanSeparators(UIViewController *vc); // defined with the de-dup helpers

// Publish the REST sticky count N onto the feed's ASTableNode so the separators can
// keep exactly the LAST orphan as the breaker (race-free; see ShouldCollapse). When N
// first becomes known (or changes), force a re-measure so a cold-load fallback that
// collapsed the wrong separator is corrected. No-op when N is unchanged, so warm loads
// (N already published before cells measure) never re-measure.
static void ApolloHLApplyStickyCountToTable(UIViewController *vc, NSString *subreddit) {
    id tableNode = ApolloHLTypedIvar(vc, @"tableNode", objc_getClass("ASTableNode"));
    NSNumber *stickyN = ApolloHLStickyCount()[subreddit.lowercaseString];
    if (!tableNode || !stickyN) return;
    NSNumber *prev = objc_getAssociatedObject(tableNode, &kApolloHLStickyCountKey);
    if ([prev isEqualToNumber:stickyN]) return;
    objc_setAssociatedObject(tableNode, &kApolloHLStickyCountKey, stickyN, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The cold-load fallback collapses exactly the first separator (row 1) — correct
    // only for the common 2-sticky feed. When N differs (a single sticky that lost its
    // breaker, or 3+ that kept an orphan), the already-measured separators are wrong and
    // Texture won't re-measure them via relayoutItems alone (it reuses the cached size),
    // so reload to re-run the exact rule. N==2 needs nothing — the fallback already matched,
    // so the common case never reloads (no flash).
    if (stickyN.integerValue != 2 && [tableNode respondsToSelector:@selector(reloadData)]) {
        ApolloLog(@"[Highlights] r/%@ sticky count N=%@ → reload to fix breaker", subreddit, stickyN);
        ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData));
    }
}

static void ApolloHLInstall(UIViewController *vc) {
    if (!vc) return;

    // Fully off → tear everything down (carousel + de-dup).
    if (!sCommunityHighlights) {
        if (objc_getAssociatedObject(vc, kApolloHLWrapperKey) || objc_getAssociatedObject(vc, kApolloHLActiveSubKey)) ApolloHLTeardown(vc, YES);
        return;
    }
    if (ApolloHLShouldSkipViewController(vc)) return;

    NSString *subreddit = ApolloHLSubredditName(vc);
    if (subreddit.length == 0) {
        if (objc_getAssociatedObject(vc, kApolloHLWrapperKey) || objc_getAssociatedObject(vc, kApolloHLActiveSubKey)) ApolloHLTeardown(vc, YES);
        return;
    }

    UITableView *tableView = ApolloHLFindTableView(vc);
    if (!tableView) return;

    // Tell this feed's separators how many leading stickies will collapse, so the
    // breaker (the LAST orphan separator) is kept race-free. The count is known
    // synchronously from the cached REST fetch on warm loads — before cells measure —
    // so the breaker is correct on the first frame. On a cold first load it isn't
    // known yet; the separators fall back to the common-case rule and the reactive
    // pass + post-fetch re-install correct them (masked by the carousel popping in).
    ApolloHLApplyStickyCountToTable(vc, subreddit);

    // Freshness: if the cached carousel has aged out, quietly re-poll in the background
    // (rebuilds only if the pinned set actually changed). Runs in both placement modes.
    ApolloHLMaybeRefreshStale(subreddit);

    // De-dup collapses the leading stickied posts but leaves their trailing
    // separators, doubling the breaker below the carousel. Collapse the orphaned
    // ones — deferred so we never relayout mid-layout-pass (handles refresh /
    // scroll-back-to-top) and a few scheduled passes once per sub-visit for the cold
    // load before the cells have laid out.
    {
        NSString *sub0 = subreddit;
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
                if ([ApolloHLSubredditName(postsVC) isEqualToString:sub0]) ApolloHLCollapseOrphanSeparators(postsVC);
            });
        });
        NSString *scheduledFor = objc_getAssociatedObject(vc, &kApolloHLSepScheduledKey);
        if (![scheduledFor isEqualToString:subreddit]) {
            objc_setAssociatedObject(vc, &kApolloHLSepScheduledKey, subreddit, OBJC_ASSOCIATION_COPY_NONATOMIC);
            NSString *sub = subreddit;
            void (^pass)(void) = ^{
                ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
                    if ([ApolloHLSubredditName(postsVC) isEqualToString:sub]) ApolloHLCollapseOrphanSeparators(postsVC);
                });
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), pass);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), pass);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), pass);
        }
    }

    // Subreddit changed under a reused controller — drop old state.
    NSString *storedActive = objc_getAssociatedObject(vc, kApolloHLActiveSubKey);
    if (storedActive.length && ![storedActive isEqualToString:subreddit]) {
        ApolloHLTeardown(vc, YES);
    }

    // Mark this subreddit's foreground feed for inline de-duplication NOW (before
    // its cells lay out), so the pinned posts collapse on first layout instead of
    // flashing then collapsing once the async carousel data lands. Done in BOTH
    // placement modes (standalone tableHeaderView, or hosted in the headers wrapper).
    ApolloHLHideSubsAdd(subreddit);
    objc_setAssociatedObject(vc, kApolloHLActiveSubKey, subreddit, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Opt-in: harvest the full highlights set (>2) via a hidden WebView, once per
    // sub. The fast API carousel shows immediately; this upgrades it when it lands.
    ApolloHLMaybeWebUpgrade(subreddit);

    // When the subreddit-headers feature is enabled it hosts the carousel inside
    // its wrapper (ApolloHLHeaderOriginalSubstitute), so we only manage de-dup
    // here — make sure no standalone wrapper of ours lingers and defer placement.
    if (sShowSubredditHeaders) {
        if (objc_getAssociatedObject(vc, kApolloHLWrapperKey)) ApolloHLRestoreStandaloneHeader(vc);
        return;
    }

    NSString *key = subreddit.lowercaseString;
    NSArray<ApolloHLItem *> *cached = ApolloHLCache()[key];
    if (cached) {
        ApolloHLInstallCarousel(vc, tableView, cached, subreddit);
        return;
    }

    // No data yet — fetch once, then install on whichever PostsViewController is
    // currently showing this subreddit (the VC that kicked the fetch may have
    // been replaced, and layout may have settled, so don't rely on it).
    ApolloHLFetchHighlights(subreddit, NO, ^(NSArray<ApolloHLItem *> *items) {
        if (items == nil) return; // an in-flight dedupe call, ignore
        if (!sCommunityHighlights || sShowSubredditHeaders) return;
        if (items.count == 0) { ApolloHLClearDeDup(subreddit); return; }
        ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
            if (ApolloHLShouldSkipViewController(postsVC)) return;
            if (![ApolloHLSubredditName(postsVC) isEqualToString:subreddit]) return;
            UITableView *tv = ApolloHLFindTableView(postsVC);
            if (tv) ApolloHLInstallCarousel(postsVC, tv, items, subreddit);
            ApolloHLApplyStickyCountToTable(postsVC, subreddit); // N now known from this fetch
        });
    });
}

#pragma mark - Auto-scroll-past-header suppression

// Apollo auto-scrolls past its tableHeaderView once posts load. Block ONLY the
// scroll whose target Y matches our wrapper's height (its signature), while at
// the top and not user-dragging — every other scroll passes through.
static BOOL ApolloHLShouldBlockOffset(UITableView *tableView, CGPoint newOffset) {
    if (![objc_getAssociatedObject(tableView, kApolloHLManagedTableKey) boolValue]) return NO;
    UIView *header = tableView.tableHeaderView;
    if (!header || !objc_getAssociatedObject(header, kApolloHLWrapperMarkerKey)) return NO;
    if (tableView.tracking || tableView.dragging || tableView.decelerating) return NO;
    CGFloat topY = -tableView.adjustedContentInset.top;
    BOOL atTop = (tableView.contentOffset.y - topY) <= 0.5;
    if (!atTop) return NO;
    CGFloat targetDelta = newOffset.y - topY;
    return fabs(targetDelta - header.frame.size.height) < 5.0;
}

#pragma mark - Inline de-duplication (collapse stickied cells the carousel covers)

// A post cell should be hidden inline when its subreddit's foreground feed is
// showing the carousel. Gated on `stickied` (only set in a post's own subreddit
// listing, not Home/All) AND the subreddit being an active highlights feed, so
// Home/multireddit feeds and non-pinned posts are never touched. The hide-set is
// synchronous (no async carousel dependency) → cells collapse on first layout.
static BOOL ApolloHLShouldHideCell(id cellNode) {
    if (!sCommunityHighlights) return NO;
    if (ApolloHLHideSubsIsEmpty()) return NO;
    RDKLinkLite *link = (RDKLinkLite *)ApolloHLTypedIvar(cellNode, @"link", objc_getClass("RDKLink"));
    if (!link || ![link respondsToSelector:@selector(stickied)] || !link.stickied) return NO;
    NSString *sub = link.subreddit.lowercaseString;
    if (sub.length == 0 || !ApolloHLHideSubsContains(sub)) return NO;
    ApolloHLDidCollapseAdd(sub);
    return YES;
}

// Zero-size layout spec used to collapse a hidden cell.
static id ApolloHLEmptySpec(void) {
    Class stackClass = objc_getClass("ASStackLayoutSpec");
    if (!stackClass) return nil;
    return [stackClass stackLayoutSpecWithDirection:0 spacing:0 justifyContent:0 alignItems:0 children:@[]];
}

// Every Apollo post cell is followed by a ThickSeparatorCellNode (the 8pt breaker
// with top+bottom hairlines). When we de-dup the leading stickied posts (collapsing
// them to 0), their trailing separators stay — so the carousel→feed boundary gets a
// DOUBLED breaker (extra hairline) vs the single post→post one. Collapse all but the
// LAST separator in that leading sticky run, so one clean breaker remains.
// ASTableNode does not reuse cell nodes, so a flag set on a separator node is stable.
static char kApolloHLSepCollapseKey;

static BOOL ApolloHLNodeIsSeparator(id node) {
    return node && [NSStringFromClass([node class]) isEqualToString:@"Apollo.ThickSeparatorCellNode"];
}
static BOOL ApolloHLNodeIsPostCell(id node) {
    NSString *c = node ? NSStringFromClass([node class]) : nil;
    return [c isEqualToString:@"Apollo.LargePostCellNode"] || [c isEqualToString:@"Apollo.CompactPostCellNode"];
}

// Zero a node's fixed style.height so an empty layoutSpec actually collapses it
// (the separator has a hard-coded 8pt height that overrides the spec). ASDimension
// = {NSInteger unit; CGFloat value}; unit 1 = ASDimensionUnitPoints.
static void ApolloHLZeroNodeHeight(id node) {
    id style = [node respondsToSelector:@selector(style)] ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(style)) : nil;
    if (!style) return;
    typedef struct { NSInteger unit; CGFloat value; } ApolloHLDim;
    ApolloHLDim zero = {1, 0.0}; // {ASDimensionUnitPoints, 0}
    // Clamp every height input: the node may derive 8pt from minHeight/maxHeight or a
    // preferredSize rather than `height`, so zero them all (maxHeight=0 forces ≤0).
    if ([style respondsToSelector:@selector(setHeight:)])    ((void (*)(id, SEL, ApolloHLDim))objc_msgSend)(style, @selector(setHeight:), zero);
    if ([style respondsToSelector:@selector(setMinHeight:)]) ((void (*)(id, SEL, ApolloHLDim))objc_msgSend)(style, @selector(setMinHeight:), zero);
    if ([style respondsToSelector:@selector(setMaxHeight:)]) ((void (*)(id, SEL, ApolloHLDim))objc_msgSend)(style, @selector(setMaxHeight:), zero);
}

// FLASH-FREE first-layout collapse. The reactive pass above only runs AFTER cells
// lay out, so the breaker briefly shows thick before correcting. Instead, the post
// hook records each de-duped sticky's ROW in a per-ASTableNode set (indexPath +
// owningNode are both available during node layout — safe, unlike raw ivar access),
// and the separator collapses itself on its FIRST layout when it sits BETWEEN two
// recorded stickies. The last sticky's separator (row below is a real post) is kept
// as the single breaker. (kApolloHLHiddenRowsKey declared up top so teardown can clear it.)

static id ApolloHLOwningTableNode(id cellNode) {
    id me = (id)cellNode;
    return [me respondsToSelector:@selector(owningNode)] ? ((id (*)(id, SEL))objc_msgSend)(me, @selector(owningNode)) : nil;
}
static NSInteger ApolloHLNodeRow(id cellNode) {
    id me = (id)cellNode;
    if (![me respondsToSelector:@selector(indexPath)]) return -1;
    NSIndexPath *ip = ((NSIndexPath *(*)(id, SEL))objc_msgSend)(me, @selector(indexPath));
    return ip ? ip.row : -1;
}
// Caller MUST hold @synchronized(owningTable). The set is associated with the
// owningTable for its whole lifetime and only ever EMPTIED (never niled), so it
// can't be freed while an off-main layout is reading it.
static NSMutableSet *ApolloHLHiddenRowsSet(id owningTable, BOOL create) {
    if (!owningTable) return nil;
    NSMutableSet *set = objc_getAssociatedObject(owningTable, &kApolloHLHiddenRowsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(owningTable, &kApolloHLHiddenRowsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}
static void ApolloHLRecordHiddenStickyRow(id postNode) {
    id owning = ApolloHLOwningTableNode(postNode);
    NSInteger row = ApolloHLNodeRow(postNode);
    if (!owning || row < 0) return;
    @synchronized(owning) { [ApolloHLHiddenRowsSet(owning, YES) addObject:@(row)]; } // lock the stable owningTable, not the set
}
static BOOL ApolloHLSeparatorShouldCollapse(id sepNode) {
    if ([objc_getAssociatedObject(sepNode, &kApolloHLSepCollapseKey) boolValue]) return YES; // reactive pass
    if (!sCommunityHighlights || ApolloHLHideSubsIsEmpty()) return NO;
    NSInteger r = ApolloHLNodeRow(sepNode);
    if (r < 1) return NO;
    id owning = ApolloHLOwningTableNode(sepNode);
    // Race-free exact rule when the inline-sticky count N is known (warm loads):
    // stickies occupy rows 0..2N-1; their separators are the odd rows 1,3,…,2N-1; the
    // breaker is the LAST one (row 2N-1). Collapse every separator before it. This is
    // correct for any N from the FIRST measure — including N==1 (2N-1==1, so r<1 is
    // false and the lone separator is kept as the breaker).
    NSNumber *n = owning ? objc_getAssociatedObject(owning, &kApolloHLStickyCountKey) : nil;
    if (n) {
        NSInteger N = n.integerValue;
        return N >= 1 && r < (2 * N - 1);
    }
    // N not known yet (cold first load, before the REST fetch lands). Fall back to the
    // common 2-sticky case: collapse the first orphan (row 1) race-free. The reactive
    // pass + the post-fetch re-install fix any other count once N is known.
    return r == 1;
}

static void ApolloHLCollapseOrphanSeparators(UIViewController *vc) {
    if (!sCommunityHighlights || ApolloHLHideSubsIsEmpty()) return;
    UITableView *tv = ApolloHLFindTableView(vc);
    if (!tv) return;
    NSArray<UITableViewCell *> *cells = [tv.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UITableViewCell *a, UITableViewCell *b) {
        NSIndexPath *ia = [tv indexPathForCell:a], *ib = [tv indexPathForCell:b];
        if (!ia || !ib) return NSOrderedSame;
        return [ia compare:ib];
    }];
    if (cells.count == 0) return;
    NSInteger firstRow = [tv indexPathForCell:cells.firstObject].row;
    if (firstRow != 0) return; // only when the feed top is visible

    // Collect the separators in the leading run of de-duped stickies (until the first real post).
    NSMutableArray *runSeps = [NSMutableArray array];
    for (UITableViewCell *c in cells) {
        id node = [c respondsToSelector:@selector(node)] ? ((id (*)(id, SEL))objc_msgSend)(c, @selector(node)) : nil;
        if (!node) continue;
        if (ApolloHLNodeIsSeparator(node)) { [runSeps addObject:node]; continue; }
        if (ApolloHLNodeIsPostCell(node)) {
            if (ApolloHLShouldHideCell(node)) continue; // still a hidden sticky
            break;                                       // first real post → run ends
        }
    }
    // Keep the last separator (the breaker before the first real post); collapse the rest.
    BOOL changed = NO;
    for (NSUInteger i = 0; i + 1 < runSeps.count; i++) {
        id node = runSeps[i];
        if (![objc_getAssociatedObject(node, &kApolloHLSepCollapseKey) boolValue]) {
            objc_setAssociatedObject(node, &kApolloHLSepCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloHLZeroNodeHeight(node);
            if ([node respondsToSelector:@selector(setNeedsLayout)]) ((void (*)(id, SEL))objc_msgSend)(node, @selector(setNeedsLayout));
            changed = YES;
        }
    }
    if (changed) {
        // relayoutItems re-lays out EVERY node in the feed synchronously on main —
        // multi-second work on a long-scrolled feed, the 0x8BADF00D watchdog class
        // from #630. Bound it: foreground-active only (Inactive is the snapshot
        // window) and at most once per 10s; a skipped pass just leaves the breaker
        // thick until the next scroll re-measures it, which is cosmetic.
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            static NSTimeInterval sLastHLRelayoutUptime = 0;
            NSTimeInterval now = CACurrentMediaTime();
            if (now - sLastHLRelayoutUptime > 10.0) {
                sLastHLRelayoutUptime = now;
                id tableNode = ApolloHLTypedIvar(vc, @"tableNode", objc_getClass("ASTableNode"));
                if ([tableNode respondsToSelector:@selector(relayoutItems)]) ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(relayoutItems));
                // relayoutItems re-measures but the shrink doesn't paint until the next
                // layout pass (otherwise the breaker stays thick until the user scrolls) —
                // force the table to apply it now.
                [tv setNeedsLayout];
                [tv layoutIfNeeded];
            }
        }
    }
}

#pragma mark - Hooks

%hook UITableView

// Catch an in-place subreddit switch (the nav-title "jump bar": tap the sub name,
// type another sub) under a REUSED PostsViewController. On that path Apollo swaps
// the feed's contents in place — the table re-lays-out repeatedly — but the VC's
// viewDidLayoutSubviews (which drives ApolloHLInstall) does NOT fire, so the
// standalone carousel keeps showing the PREVIOUS sub's highlights on the new feed.
// The feed table's own layoutSubviews DOES fire throughout the switch, so detect
// the stale carousel here and re-run install. Only managed feed tables (those
// currently hosting our carousel) are inspected — a single associated-object read
// short-circuits every other UITableView in the app.
- (void)layoutSubviews {
    %orig;
    if (!sCommunityHighlights || sShowSubredditHeaders) return;
    if (![objc_getAssociatedObject(self, kApolloHLManagedTableKey) boolValue]) return;
    UIViewController *vc = objc_getAssociatedObject(self, kApolloHLManagedVCKey);
    if (!vc) return;
    NSString *installed = objc_getAssociatedObject(vc, kApolloHLSubredditKey); // carousel's sub
    if (installed.length == 0) return;
    NSString *current = ApolloHLSubredditName(vc); // nil for special feeds (all/home/popular/…)
    if ([installed isEqualToString:current]) return; // still the same sub → nothing to do
    // The VC now shows a different sub (or a special feed) than the installed carousel.
    // Re-run install on the next runloop turn — NOT inline: ApolloHLInstall sets
    // tableHeaderView, which would re-enter layoutSubviews. Guard so a single
    // re-install is scheduled per switch rather than one per layout pass.
    if ([objc_getAssociatedObject(vc, &kApolloHLSwitchPendingKey) boolValue]) return;
    objc_setAssociatedObject(vc, &kApolloHLSwitchPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakVC = vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC) return;
        objc_setAssociatedObject(strongVC, &kApolloHLSwitchPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[Highlights] in-place subreddit switch → rebuilding carousel for %@", ApolloHLSubredditName(strongVC) ?: @"(special feed)");
        ApolloHLInstall(strongVC);
    });
}

- (void)setTableHeaderView:(UIView *)tableHeaderView {
    if (![objc_getAssociatedObject(self, kApolloHLManagedTableKey) boolValue]) { %orig; return; }
    if ([objc_getAssociatedObject(self, kApolloHLRewrapInProgressKey) boolValue]) { %orig; return; }
    // Already our wrapper — nothing to do.
    if (tableHeaderView && objc_getAssociatedObject(tableHeaderView, kApolloHLWrapperMarkerKey)) { %orig; return; }
    if (!sCommunityHighlights || sShowSubredditHeaders) { %orig; return; }

    UIViewController *vc = objc_getAssociatedObject(self, kApolloHLManagedVCKey);
    ApolloHLCarouselView *carousel = objc_getAssociatedObject(vc, kApolloHLCarouselKey);
    if (!vc || !carousel) { %orig; return; }

    // Re-wrap: stack our carousel above whatever Apollo is installing.
    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    UIView *wrapper = ApolloHLBuildWrapper(carousel, tableHeaderView, width);
    objc_setAssociatedObject(vc, kApolloHLWrapperKey, wrapper, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, kApolloHLOriginalHeaderKey, tableHeaderView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(wrapper);
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    if ([self isKindOfClass:[UITableView class]] &&
        ApolloHLShouldBlockOffset((UITableView *)self, contentOffset)) {
        return;
    }
    %orig;
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if ([self isKindOfClass:[UITableView class]] &&
        ApolloHLShouldBlockOffset((UITableView *)self, contentOffset)) {
        return;
    }
    %orig;
}

%end

// Collapse the inline cell for a pinned post that the carousel already shows.
%hook _TtC6Apollo17LargePostCellNode
- (id)layoutSpecThatFits:(struct ApolloHLSizeRange)constrainedSize {
    if (ApolloHLShouldHideCell(self)) {
        ApolloHLRecordHiddenStickyRow(self); // feeds the r>=3 fallback path
        id empty = ApolloHLEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloHLSizeRange)constrainedSize {
    if (ApolloHLShouldHideCell(self)) {
        ApolloHLRecordHiddenStickyRow(self);
        id empty = ApolloHLEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

// Collapse the orphaned breaker(s) left behind when a leading stickied post is
// de-duped (flag set by ApolloHLCollapseOrphanSeparators), so the carousel→feed
// breaker matches the single post→post one instead of doubling up.
%hook _TtC6Apollo22ThickSeparatorCellNode
// Zero the fixed style.height BEFORE the measure runs — setting it inside
// layoutSpecThatFits is too late (the first measure already used the built-in 8pt,
// so the breaker only shrank on a later re-measure/scroll).
- (id)calculateLayoutThatFits:(struct ApolloHLSizeRange)constrainedSize {
    if (!ApolloHLSeparatorShouldCollapse(self)) return %orig;
    ApolloHLZeroNodeHeight(self);
    id layout = %orig;
    // DEFINITIVE collapse: the node's measured size IS whatever calculateLayoutThatFits
    // returns, so override it directly. style/spec zeroing alone is ignored by
    // ThickSeparatorCellNode (it bakes in its 8pt height), so returning a 0-height
    // ASLayout for the same element is the only thing that genuinely collapses the cell.
    if (layout) {
        CGSize s = ((CGSize (*)(id, SEL))objc_msgSend)(layout, @selector(size));
        if (s.height > 0.0) {
            Class ASLayoutCls = objc_getClass("ASLayout");
            if (ASLayoutCls) {
                id zero = ((id (*)(id, SEL, id, CGSize))objc_msgSend)(ASLayoutCls, @selector(layoutWithLayoutElement:size:), self, CGSizeMake(s.width, 0.0));
                if (zero) return zero;
            }
        }
    }
    return layout;
}
- (id)layoutSpecThatFits:(struct ApolloHLSizeRange)constrainedSize {
    if (ApolloHLSeparatorShouldCollapse(self)) {
        ApolloHLZeroNodeHeight(self);
        id empty = ApolloHLEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloHLInstall((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloHLInstall((UIViewController *)self); // also runs the stale-cache freshness check
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloHLInstall((UIViewController *)self);
}

// Pull-to-refresh: always force a fresh fetch of the highlights (REST + re-harvest the
// web set), so an explicit refresh updates the carousel immediately — matching the feed
// the user just pulled to reload.
- (void)refreshControlActivatedWithSender:(id)sender {
    %orig;
    if (!sCommunityHighlights) return;
    NSString *sub = ApolloHLSubredditName((UIViewController *)self);
    if (sub.length) {
        ApolloLog(@"[Highlights] r/%@ pull-to-refresh → force refresh", sub);
        ApolloHLRefreshSub(sub, YES);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloHLInstall((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    BOOL leaving = [(UIViewController *)self isMovingFromParentViewController] || [(UIViewController *)self isBeingDismissed];
    %orig(animated);
    if (leaving) ApolloHLTeardown((UIViewController *)self, YES);
}

%end

#pragma mark - Constructor

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloCommunityHighlightsToggleChangedNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        NSMutableSet<NSString *> *visibleSubs = [NSMutableSet set];
        ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
            NSString *sub = ApolloHLSubredditName(postsVC);
            if (sub.length) [visibleSubs addObject:sub];
        });

        if (!sCommunityHighlightsWeb) {
            // Partial and Off must stop a Full-mode scrape already in progress.
            // cancel deliberately drops its completion so it cannot repopulate
            // the carousel after the mode changed.
            NSArray<ApolloHLWebFetch *> *fetches = ApolloHLWebFetchers().allValues;
            [ApolloHLWebFetchers() removeAllObjects];
            for (ApolloHLWebFetch *fetch in fetches) [fetch cancel];
            [ApolloHLWebDone() removeAllObjects];
        } else {
            // Full selected after Partial: allow each visible subreddit to run a
            // fresh web upgrade even if it completed earlier in this app session.
            for (NSString *sub in visibleSubs) [ApolloHLWebDone() removeObject:sub];
        }

        if (sCommunityHighlights && !sCommunityHighlightsWeb) {
            // The display cache outlives its feed controller. Reset every cached
            // subreddit, not just the currently visible ones, so revisiting a sub
            // after Full → Partial cannot reinstall its session-old web set.
            for (NSString *sub in ApolloHLCache().allKeys) {
                NSArray<ApolloHLItem *> *restItems = ApolloHLRestCache()[sub];
                if (restItems) ApolloHLCache()[sub] = restItems;
                else [ApolloHLCache() removeObjectForKey:sub];
            }

            // Apply/fetch only for live feeds. Every Full load begins with the
            // same REST request Partial uses, so most visible subs update at once.
            for (NSString *sub in visibleSubs) {
                NSArray<ApolloHLItem *> *restItems = ApolloHLRestCache()[sub];
                if (restItems) {
                    if (restItems.count > 0) ApolloHLApplyItems(sub, restItems);
                    else ApolloHLClearDeDup(sub);
                    continue;
                }

                // An extremely early change can beat the first REST response.
                // Force one if needed; the in-flight guard prevents duplicates.
                ApolloHLFetchHighlights(sub, YES, ^(NSArray<ApolloHLItem *> *freshREST) {
                    if (!freshREST || !sCommunityHighlights || sCommunityHighlightsWeb) return;
                    // Preserve the fetcher's failure semantics: an empty result
                    // stays uncached so a transient error can retry later instead
                    // of becoming a session-long "nothing pinned" negative cache.
                    if (freshREST.count > 0) {
                        ApolloHLCache()[sub] = freshREST;
                        ApolloHLApplyItems(sub, freshREST);
                    } else {
                        ApolloHLClearDeDup(sub);
                    }
                    ApolloHLForEachPostsVC(^(UIViewController *liveVC) {
                        if (![ApolloHLSubredditName(liveVC) isEqualToString:sub]) return;
                        ApolloHLInstall(liveVC);
                        ApolloHLReloadFeed(liveVC);
                    });
                });
            }
        }

        // Install/teardown + re-layout every feed controller so all three modes
        // apply live (cells laid out under the old mode need remeasurement too).
        ApolloHLForEachPostsVC(^(UIViewController *postsVC) {
            ApolloHLInstall(postsVC);
            ApolloHLReloadFeed(postsVC);
        });
    }];
}
