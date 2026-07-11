// ApolloPostFilters
//
// Reborn "Post Filters" — device-wide content filters that beef out Apollo's
// native Filters & Blocks screen. Three filter kinds (all configured on the
// native screen via ApolloFiltersBlocksInject.xm):
//
//   1. Per-subreddit KEYWORDS — hide posts in r/<sub> whose title/link contains
//      any configured word.
//   2. Per-subreddit FLAIRS — hide posts in r/<sub> whose flair label matches.
//   3. Subreddit-NAME substrings — hide any post whose subreddit name contains a
//      configured word (e.g. "circlejerk" hides r/carscirclejerk). The same names
//      are also filtered out of the search screen's subreddit suggestions (see the
//      _TtC6Apollo20SearchViewController hook below).
//
// Matching keys on the POST's own `link.subreddit`, so per-sub rules apply
// wherever that sub's posts appear (Home / All / the sub itself), mirroring how
// Apollo's native subreddit filters behave.
//
// Enforcement reuses the Community Highlights hide mechanism: hook the post cell
// nodes' -layoutSpecThatFits: and return a zero-size ASStackLayoutSpec to collapse
// the row to 0pt (keeps Apollo's `links` array + pagination intact — no IGListKit
// desync), and collapse the trailing ThickSeparatorCellNode so hidden posts don't
// leave stacked 8pt breaker gaps.
//
// Threading: the matcher reads the immutable ApolloState snapshots
// (sPostFilterSubreddits / sPostFilterNameSubstrings) off-main during Texture
// layout. Writes always swap in a fresh [copy] (see ApolloPostFilterStore), so a
// reader either sees the old or the new immutable container — never a mutating one.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloPostFilterStore.h"
#import "Tweak.h"
#import "UserDefaultConstants.h"

// RDKLink fields not declared on the shared interface in Tweak.h.
@interface RDKLink (ApolloPostFilters)
@property (copy, nonatomic) NSString *linkFlairText;
@property (retain, nonatomic) RDKLink *crosspostParent;
@end

// ASSizeRange ABI: { CGSize min; CGSize max; } — matches the arg of
// -layoutSpecThatFits: / -calculateLayoutThatFits:.
struct ApolloPFSizeRange { CGSize min; CGSize max; };

// Dummy interface so the ASStackLayoutSpec factory selector is known to the
// compiler (the real class is resolved at runtime via objc_getClass).
@interface ApolloPFStackSpec : NSObject
+ (instancetype)stackLayoutSpecWithDirection:(NSInteger)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(NSUInteger)justifyContent
                                  alignItems:(NSUInteger)alignItems
                                    children:(NSArray *)children;
@end

#pragma mark - Matcher

static BOOL ApolloPFContainsAnyTerm(NSString *haystackLower, NSArray<NSString *> *needlesLower) {
    if (haystackLower.length == 0 || needlesLower.count == 0) return NO;
    for (NSString *n in needlesLower) {
        if (n.length == 0) continue;
        if ([haystackLower rangeOfString:n].location != NSNotFound) return YES;
    }
    return NO;
}

// YES if a subreddit name contains any configured name-substring (the same test
// used for feed posts and search suggestions). Case-insensitive.
static BOOL ApolloPFSubredditNameBlocked(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return NO;
    NSArray<NSString *> *names = sPostFilterNameSubstrings;
    if (names.count == 0) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *frag in names) {
        if (frag.length > 0 && [lower rangeOfString:frag].location != NSNotFound) return YES;
    }
    return NO;
}

// The post's visible flair label, normalized via the SAME transform the store
// applies to typed flair filters (ApolloPostFilterStore normalizeFlair: — strips
// ":emoji:" snoomoji tokens, collapses whitespace, trims, lowercases) so an exact
// match lines up. Reddit post flairs frequently embed emoji tokens in the raw
// linkFlairText (e.g. r/soccer's ":n_media: Media"); only the trailing words
// render as the visible label. Falls back to linkFlairRichText text segments when
// linkFlairText is empty.
static NSString *ApolloPFNormalizedFlairLabel(id linkObj) {
    NSString *flair = nil;
    @try { flair = ((RDKLink *)linkObj).linkFlairText; } @catch (__unused id e) {}
    if (![flair isKindOfClass:[NSString class]] || flair.length == 0) {
        @try {
            id rich = [(NSObject *)linkObj valueForKey:@"linkFlairRichText"];
            if ([rich isKindOfClass:[NSArray class]]) {
                NSMutableString *acc = [NSMutableString string];
                for (id seg in (NSArray *)rich) {
                    if ([seg isKindOfClass:[NSDictionary class]]) {
                        id t = ((NSDictionary *)seg)[@"t"];
                        if ([t isKindOfClass:[NSString class]]) [acc appendString:(NSString *)t];
                    }
                }
                flair = acc;
            }
        } @catch (__unused id e) {}
    }
    return [ApolloPostFilterStore normalizeFlair:flair];
}

// Tests a single link object (top-level post or a crosspost parent) against the
// configured rules. Returns YES if it should be hidden.
static BOOL ApolloPFLinkMatchesRules(id linkObj) {
    Class linkCls = objc_getClass("RDKLink");
    if (!linkCls || ![linkObj isKindOfClass:linkCls]) return NO;
    RDKLink *link = (RDKLink *)linkObj;

    NSString *sub = nil;
    @try { sub = link.subreddit; } @catch (__unused id e) {}
    if (![sub isKindOfClass:[NSString class]] || sub.length == 0) return NO;
    NSString *subKey = sub.lowercaseString;

    // 1) Subreddit-name substring match (applies to any subreddit).
    if (ApolloPFSubredditNameBlocked(subKey)) return YES;

    // 2) Per-subreddit keyword / flair rules.
    NSDictionary *rules = sPostFilterSubreddits[subKey];
    if (![rules isKindOfClass:[NSDictionary class]]) return NO;

    NSArray<NSString *> *keywords = rules[@"keywords"];
    if ([keywords isKindOfClass:[NSArray class]] && keywords.count > 0) {
        NSString *title = nil; @try { title = link.title; } @catch (__unused id e) {}
        NSString *titleLower = [title isKindOfClass:[NSString class]] ? title.lowercaseString : @"";
        if (ApolloPFContainsAnyTerm(titleLower, keywords)) return YES;
        // Also test the link URL, mirroring Apollo's native "title, link, or flair".
        NSString *urlLower = @"";
        @try {
            NSURL *u = link.URL;
            if ([u isKindOfClass:[NSURL class]]) urlLower = u.absoluteString.lowercaseString ?: @"";
        } @catch (__unused id e) {}
        if (ApolloPFContainsAnyTerm(urlLower, keywords)) return YES;
    }

    NSArray<NSString *> *flairs = rules[@"flairs"];
    if ([flairs isKindOfClass:[NSArray class]] && flairs.count > 0) {
        NSString *flairLower = ApolloPFNormalizedFlairLabel(link);
        if (flairLower.length > 0) {
            for (NSString *f in flairs) {
                if (f.length > 0 && [f isEqualToString:flairLower]) return YES; // exact (visible) label match
            }
        }
    }
    return NO;
}

static BOOL ApolloPFShouldHideLink(id link) {
    if (!link) return NO;
    // Fast out: nothing configured (the common case).
    if (sPostFilterSubreddits.count == 0 && sPostFilterNameSubstrings.count == 0) return NO;
    if (ApolloPFLinkMatchesRules(link)) return YES;
    // Crosspost: also test the original post so a crosspost FROM a filtered sub
    // (or carrying the parent's title/flair) is filtered too.
    @try {
        RDKLink *parent = ((RDKLink *)link).crosspostParent;
        if (parent && ApolloPFLinkMatchesRules(parent)) return YES;
    } @catch (__unused id e) {}
    return NO;
}

#pragma mark - Cell / node helpers

static id ApolloPFIvarValueByName(id obj, const char *name) {
    if (!obj || !name) return nil;
    Class cls = object_getClass(obj);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(obj, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static BOOL ApolloPFCellShouldHide(id cell) {
    id link = ApolloPFIvarValueByName(cell, "link");
    return ApolloPFShouldHideLink(link);
}

// Zero-size layout spec used to collapse a hidden cell.
static id ApolloPFEmptySpec(void) {
    Class stackClass = objc_getClass("ASStackLayoutSpec");
    if (!stackClass) return nil;
    return [stackClass stackLayoutSpecWithDirection:0 spacing:0 justifyContent:0 alignItems:0 children:@[]];
}

// Zero a node's fixed style heights so an empty spec actually collapses it (the
// ThickSeparator bakes in an 8pt height). ASDimension = { NSInteger unit; CGFloat value }.
static void ApolloPFZeroNodeHeight(id node) {
    id style = [node respondsToSelector:@selector(style)] ? ((id (*)(id, SEL))objc_msgSend)(node, @selector(style)) : nil;
    if (!style) return;
    typedef struct { NSInteger unit; CGFloat value; } ApolloPFDim;
    ApolloPFDim zero = {1, 0.0}; // {ASDimensionUnitPoints, 0}
    if ([style respondsToSelector:@selector(setHeight:)])    ((void (*)(id, SEL, ApolloPFDim))objc_msgSend)(style, @selector(setHeight:), zero);
    if ([style respondsToSelector:@selector(setMinHeight:)]) ((void (*)(id, SEL, ApolloPFDim))objc_msgSend)(style, @selector(setMinHeight:), zero);
    if ([style respondsToSelector:@selector(setMaxHeight:)]) ((void (*)(id, SEL, ApolloPFDim))objc_msgSend)(style, @selector(setMaxHeight:), zero);
}

#pragma mark - Trailing-separator collapse
//
// Each post cell is followed by a ThickSeparatorCellNode. When we collapse a
// post to 0pt its separator stays (8pt), so a run of hidden posts would stack
// breaker gaps. We record each post's hide decision per owning table node (keyed
// by row), and the separator at row r collapses when the post at row r-1 is
// hidden. Records are updated both ways on every post layout so a row that stops
// being hidden (after a data reload) clears correctly.

static char kApolloPFHiddenRowsKey;
// Set on a table node when a post's hidden state actually changes, so a deferred
// main-thread pass can reconcile a trailing separator that measured before the post
// recorded its hidden row (Texture measures nodes concurrently, so order isn't
// guaranteed). Cleared by the reconcile pass.
static char kApolloPFSepDirtyKey;

static id ApolloPFOwningTableNode(id cellNode) {
    return [cellNode respondsToSelector:@selector(owningNode)] ? ((id (*)(id, SEL))objc_msgSend)(cellNode, @selector(owningNode)) : nil;
}
static NSInteger ApolloPFNodeRow(id cellNode) {
    if (![cellNode respondsToSelector:@selector(indexPath)]) return -1;
    NSIndexPath *ip = ((NSIndexPath *(*)(id, SEL))objc_msgSend)(cellNode, @selector(indexPath));
    return ip ? ip.row : -1;
}
// Caller holds @synchronized(owningTable). The set is associated with the stable
// owning table node and only mutated/emptied (never niled), so it can't be freed
// while an off-main layout reads it.
static NSMutableSet *ApolloPFHiddenRowsSet(id owningTable, BOOL create) {
    if (!owningTable) return nil;
    NSMutableSet *set = objc_getAssociatedObject(owningTable, &kApolloPFHiddenRowsKey);
    if (!set && create) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(owningTable, &kApolloPFHiddenRowsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}
static void ApolloPFUpdateHiddenRow(id postNode, BOOL hidden) {
    id owning = ApolloPFOwningTableNode(postNode);
    NSInteger row = ApolloPFNodeRow(postNode);
    if (!owning || row < 0) return;
    BOOL changed = NO;
    @synchronized(owning) {
        NSMutableSet *set = ApolloPFHiddenRowsSet(owning, YES);
        BOOL had = [set containsObject:@(row)];
        if (hidden && !had) { [set addObject:@(row)]; changed = YES; }
        else if (!hidden && had) { [set removeObject:@(row)]; changed = YES; }
    }
    // Flag for separator reconciliation only when the row's state actually flipped,
    // so the deferred pass runs at most once per real change (not every layout).
    if (changed) objc_setAssociatedObject(owning, &kApolloPFSepDirtyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL ApolloPFSeparatorShouldCollapse(id sepNode) {
    if (sPostFilterSubreddits.count == 0 && sPostFilterNameSubstrings.count == 0) return NO;
    NSInteger r = ApolloPFNodeRow(sepNode);
    if (r < 1) return NO;
    id owning = ApolloPFOwningTableNode(sepNode);
    if (!owning) return NO;
    @synchronized(owning) {
        NSMutableSet *set = ApolloPFHiddenRowsSet(owning, NO);
        return [set containsObject:@(r - 1)];
    }
}

#pragma mark - Live refresh

// Re-measure visible feeds after a settings change so the new rules take effect
// without requiring a scroll. relayoutItems on the ASTableNode forces a fresh
// layoutSpecThatFits: pass; reloadData on the table view is a belt-and-suspenders
// fallback for any plain UITableView.
static void ApolloPFReloadTableNode(id tableNode); // defined below

static void ApolloPFRefreshVisibleFeeds(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^__block walk)(UIView *) = nil;
        void (^localWalk)(UIView *) = ^(UIView *root) {
            if ([root isKindOfClass:[UITableView class]]) {
                UITableView *tv = (UITableView *)root;
                id node = nil;
                if ([tv respondsToSelector:@selector(tableNode)]) {
                    @try { node = ((id (*)(id, SEL))objc_msgSend)(tv, @selector(tableNode)); } @catch (__unused id e) {}
                }
                if (node) ApolloPFReloadTableNode(node);   // Texture feed: re-measure cells
                else @try { [tv reloadData]; } @catch (__unused id e) {} // plain UITableView fallback
            }
            for (UIView *sub in root.subviews) walk(sub);
        };
        walk = localWalk;
        // Union UIApplication.windows with the active scenes' windows — on iOS 26 a
        // scene app's visible window can be absent from UIApplication.windows, so the
        // immediate refresh would otherwise miss the currently-visible feed.
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        @try { for (UIWindow *w in [UIApplication sharedApplication].windows) if (w) [windows addObject:w]; } @catch (__unused id e) {}
        @try {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w && ![windows containsObject:w]) [windows addObject:w];
                }
            }
        } @catch (__unused id e) {}
        for (UIWindow *window in windows) walk(window);
        walk = nil;
    });
}

// Cross-tab live apply. A generation counter is bumped on every filter change.
// A feed that last laid out under an older generation re-measures on its next
// appearance — so adding a filter in Settings takes effect when you return to the
// feed tab, even though Texture caches layouts and a plain tab switch would
// otherwise keep stale cells. (The currently-visible feed is handled directly by
// ApolloPFRefreshVisibleFeeds above.)
static int sApolloPFGeneration = 0;
static const void *kApolloPFAppliedGenKey = &kApolloPFAppliedGenKey;

// Force a full re-measure of an ASTableNode's cells. reloadData re-runs every
// cell's layoutSpecThatFits: (where the matcher decides to collapse), which
// relayoutItems alone does not for already-measured/cached nodes. This is the
// reliable way to apply a filter change to an existing feed.
static void ApolloPFReloadTableNode(id tableNode) {
    if (tableNode && [tableNode respondsToSelector:@selector(reloadData)]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData)); } @catch (__unused id e) {}
    }
}

static void ApolloPFReloadTableNodeOfVC(id vc) {
    ApolloPFReloadTableNode(ApolloPFIvarValueByName(vc, "tableNode"));
}

#pragma mark - Separator reconciliation

// YES if any visible ThickSeparatorCellNode is still full-height even though its
// preceding row is hidden — i.e. the separator measured before the post recorded
// its hidden row and kept its 8pt height (the race). Main thread only.
static BOOL ApolloPFTableHasOrphanSeparator(id tableNode, UITableView *tv) {
    NSSet *hidden = nil;
    @synchronized(tableNode) {
        NSMutableSet *s = ApolloPFHiddenRowsSet(tableNode, NO);
        hidden = s ? [s copy] : nil;
    }
    if (hidden.count == 0) return NO;
    for (UITableViewCell *cell in tv.visibleCells) {
        id node = [cell respondsToSelector:@selector(node)] ? ((id (*)(id, SEL))objc_msgSend)(cell, @selector(node)) : nil;
        if (!node || ![NSStringFromClass([node class]) isEqualToString:@"Apollo.ThickSeparatorCellNode"]) continue;
        NSIndexPath *ip = [tv indexPathForCell:cell];
        if (!ip || ip.row < 1) continue;
        if (![hidden containsObject:@(ip.row - 1)]) continue;
        if (cell.bounds.size.height > 0.5) return YES; // should be collapsed but isn't
    }
    return NO;
}

// Deferred, idempotent: after a hidden-state change, re-measure the table ONCE — but
// only if an orphan separator actually exists. In the common (no-race) case nothing
// is re-measured, so there is no scroll jank; only when the race actually bit do we
// pay a single relayoutItems to collapse the stray 8pt gap.
static void ApolloPFReconcileSeparators(id vc) {
    if (sPostFilterSubreddits.count == 0 && sPostFilterNameSubstrings.count == 0) return;
    id tableNode = ApolloPFIvarValueByName(vc, "tableNode");
    if (!tableNode) return;
    if (![objc_getAssociatedObject(tableNode, &kApolloPFSepDirtyKey) boolValue]) return;
    UITableView *tv = nil;
    @try { if ([tableNode respondsToSelector:@selector(view)]) tv = (UITableView *)((id (*)(id, SEL))objc_msgSend)(tableNode, @selector(view)); } @catch (__unused id e) {}
    if (![tv isKindOfClass:[UITableView class]]) return;
    // Clear first; any further transition will re-set it and re-trigger us.
    objc_setAssociatedObject(tableNode, &kApolloPFSepDirtyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (ApolloPFTableHasOrphanSeparator(tableNode, tv)) {
        // relayoutItems re-lays out EVERY node in the feed synchronously on main —
        // the 0x8BADF00D watchdog class from #630. Bound it: foreground-active only
        // and at most once per 10s; a skipped pass leaves a cosmetic 8pt gap that
        // the next real change (which re-sets the dirty flag) or scroll heals.
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            static NSTimeInterval sLastPFRelayoutUptime = 0;
            NSTimeInterval now = CACurrentMediaTime();
            if (now - sLastPFRelayoutUptime > 10.0) {
                sLastPFRelayoutUptime = now;
                @try { if ([tableNode respondsToSelector:@selector(relayoutItems)]) ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(relayoutItems)); } @catch (__unused id e) {}
            }
        }
    }
}

#pragma mark - Cell hooks

%hook _TtC6Apollo17LargePostCellNode
- (id)layoutSpecThatFits:(struct ApolloPFSizeRange)constrainedSize {
    BOOL hide = ApolloPFCellShouldHide(self);
    ApolloPFUpdateHiddenRow(self, hide);
    if (hide) {
        id empty = ApolloPFEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (id)layoutSpecThatFits:(struct ApolloPFSizeRange)constrainedSize {
    BOOL hide = ApolloPFCellShouldHide(self);
    ApolloPFUpdateHiddenRow(self, hide);
    if (hide) {
        id empty = ApolloPFEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

// Collapse the separator trailing a hidden post. calculateLayoutThatFits: is
// where ThickSeparatorCellNode bakes its 8pt height, so override the measured
// size there; layoutSpecThatFits: is a backup. (Composes with Community
// Highlights' hooks on the same class — both call %orig, and either wanting to
// collapse wins.)
%hook _TtC6Apollo22ThickSeparatorCellNode
- (id)calculateLayoutThatFits:(struct ApolloPFSizeRange)constrainedSize {
    if (!ApolloPFSeparatorShouldCollapse(self)) return %orig;
    ApolloPFZeroNodeHeight(self);
    id layout = %orig;
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
- (id)layoutSpecThatFits:(struct ApolloPFSizeRange)constrainedSize {
    if (ApolloPFSeparatorShouldCollapse(self)) {
        ApolloPFZeroNodeHeight(self);
        id empty = ApolloPFEmptySpec();
        if (empty) return empty;
    }
    return %orig;
}
%end

// Re-measure a feed on appearance if filters changed since it last laid out.
%hook _TtC6Apollo19PostsViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (sPostFilterSubreddits.count == 0 && sPostFilterNameSubstrings.count == 0) return;
    NSNumber *applied = objc_getAssociatedObject(self, kApolloPFAppliedGenKey);
    objc_setAssociatedObject(self, kApolloPFAppliedGenKey, @(sApolloPFGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // First appearance under the current generation already measured with the live
    // rules; only force a re-measure when the generation actually advanced.
    if (applied && applied.intValue != sApolloPFGeneration) {
        ApolloPFReloadTableNodeOfVC(self);
    }
}
- (void)viewDidLayoutSubviews {
    %orig;
    ApolloPFReconcileSeparators(self);
}
%end

#pragma mark - Search filtering
//
// The name-substring filter should hide matching subreddits in search too. Two
// screens show subreddits:
//   • _TtC6Apollo20SearchViewController — the as-you-type suggestion list. Rows are
//     bare ApolloDefaultTableViewCell whose textLabel is the subreddit name (the
//     "Posts with …"/"Go to User …" action rows always contain spaces). Self-sizing
//     table, no heightForRow.
//   • _TtC6Apollo36SubredditSearchResultsViewController — the full "Subreddits with
//     X" results page. Rows are SubredditSearchResultTableViewCell backed by a Swift
//     [RDKSubreddit] array; it implements heightForRowAtIndexPath:.
//
// We must NOT change row COUNTS: this screen performs animated row insert/delete as
// you type, and a filtered numberOfRows desyncs UITableView's batch-update invariant
// (→ "invalid number of rows" exception). Instead we collapse a blocked row to 0pt
// height, leaving counts/indices identical to Apollo's. Gated on having name filters,
// so there is zero overhead otherwise.

// A fresh, invisible, 0-height cell used to collapse a blocked row in a self-sizing
// table without touching row counts.
static UITableViewCell *ApolloPFMakeCollapsedCell(void) {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.backgroundColor = [UIColor clearColor];
    c.contentView.backgroundColor = [UIColor clearColor];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.userInteractionEnabled = NO;
    c.separatorInset = UIEdgeInsetsMake(0, 100000, 0, 0); // push the separator off-screen
    NSLayoutConstraint *h = [c.contentView.heightAnchor constraintEqualToConstant:0.0];
    h.priority = UILayoutPriorityRequired - 1;
    h.active = YES;
    return c;
}

// The bare subreddit name shown by a search cell (subredditLabel for results cells,
// textLabel for suggestion cells), or nil if the row isn't a hide-able subreddit
// (e.g. a "Posts with …" action row — those contain whitespace; names never do).
static NSString *ApolloPFSubredditNameFromSearchCell(UITableViewCell *cell) {
    NSString *name = nil;
    SEL sel = @selector(subredditLabel);
    if ([cell respondsToSelector:sel]) {
        id l = ((id (*)(id, SEL))objc_msgSend)(cell, sel);
        if ([l isKindOfClass:[UILabel class]]) name = [(UILabel *)l text];
    }
    if (![name isKindOfClass:[NSString class]] || name.length == 0) name = cell.textLabel.text;
    if (![name isKindOfClass:[NSString class]]) return nil;
    NSString *t = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return nil;
    if ([t rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound) return nil; // action row
    if ([t hasPrefix:@"r/"] || [t hasPrefix:@"R/"]) t = [t substringFromIndex:2];
    return t;
}

// Suggestion list: collapse a blocked suggestion's cell (self-sizing → 0pt). Counts
// untouched.
%hook _TtC6Apollo20SearchViewController
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = %orig;
    if (sPostFilterNameSubstrings.count == 0) return cell;
    NSString *name = ApolloPFSubredditNameFromSearchCell(cell);
    if (name && ApolloPFSubredditNameBlocked(name)) return ApolloPFMakeCollapsedCell();
    return cell;
}
%end

// Full "Subreddits with X" results page: data is a Swift [RDKSubreddit] (ObjC
// objects, safely readable) and the VC sets explicit row heights, so collapse via
// heightForRow (which runs before cellForRow) and hide the cell content too.
static BOOL ApolloPFResultsRowBlocked(id vc, NSIndexPath *ip) {
    if (!ip || ip.section != 0) return NO;
    @try {
        id arr = ApolloPFIvarValueByName(vc, "subreddits");
        if (![arr isKindOfClass:[NSArray class]]) return NO;
        NSArray *subs = (NSArray *)arr;
        if (ip.row < 0 || ip.row >= (NSInteger)subs.count) return NO;
        id sub = subs[(NSUInteger)ip.row];
        Class subCls = objc_getClass("RDKSubreddit");
        if (!subCls || ![sub isKindOfClass:subCls] || ![sub respondsToSelector:@selector(name)]) return NO;
        NSString *name = ((NSString *(*)(id, SEL))objc_msgSend)(sub, @selector(name));
        return ApolloPFSubredditNameBlocked(name);
    } @catch (__unused id e) {
        return NO;
    }
}

%hook _TtC6Apollo36SubredditSearchResultsViewController
- (double)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (sPostFilterNameSubstrings.count > 0 && ApolloPFResultsRowBlocked(self, ip)) return 0.0;
    return %orig;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = %orig;
    if (sPostFilterNameSubstrings.count > 0) {
        BOOL blocked = ApolloPFResultsRowBlocked(self, ip);
        cell.hidden = blocked;          // explicit both ways so reused cells reset
        cell.contentView.hidden = blocked;
    }
    return cell;
}
%end

#pragma mark - Constructor

%ctor {
    %init(_TtC6Apollo17LargePostCellNode = objc_getClass("_TtC6Apollo17LargePostCellNode"),
          _TtC6Apollo19CompactPostCellNode = objc_getClass("_TtC6Apollo19CompactPostCellNode"),
          _TtC6Apollo22ThickSeparatorCellNode = objc_getClass("_TtC6Apollo22ThickSeparatorCellNode"),
          _TtC6Apollo19PostsViewController = objc_getClass("_TtC6Apollo19PostsViewController"),
          _TtC6Apollo20SearchViewController = objc_getClass("_TtC6Apollo20SearchViewController"),
          _TtC6Apollo36SubredditSearchResultsViewController = objc_getClass("_TtC6Apollo36SubredditSearchResultsViewController"));

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloPostFiltersChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        sApolloPFGeneration++;
        ApolloPFRefreshVisibleFeeds();
    }];
}
