// Remember Comment Sort Per Post (issue #555)
//
// Apollo's only comment-sort memory is per-SUBREDDIT ("Remember Subreddit Sort" under
// Settings > Comments): change one post's comment sort and every post in that subreddit
// now opens with it. This module adds an opt-in per-POST memory: change the sort inside
// a post and reopening that same post restores it.
//
// MUTUAL EXCLUSIVITY with "Remember Subreddit Sort" (final semantics from PR #570's
// UX discussion with MSGuzy): both memories are fed by the exact same gesture — the
// sort menu inside a post — so with both toggles on a single pick cannot express
// whether the user meant "pin just this post" or "move the whole subreddit's sort";
// both-on is an inherent trap state. The two toggles are therefore an either/or:
//   - "Remember Post Sort" ON: a post whose sort you changed reopens on that sort
//     (the pre-viewDidLoad ivar write beats everything, suggested sort included);
//     every other post keeps Apollo's default chain (suggested > Default Sort —
//     the per-subreddit remember is off in this state, by exclusivity).
//   - Comments > "Remember Subreddit Sort" ON: stock Apollo behavior, untouched.
//   - Neither: stock default chain.
// Enforcement: enabling either toggle turns the other off (switch flip is animated
// on-screen — both rows sit adjacent in the same section), a %hook on NSUserDefaults
// setBool:forKey: catches the native switch being enabled, and launch/backup-restore
// normalize a stale both-on (from an older build's state) to per-post-wins. Apollo's
// native toggle key (UDKeyApolloRememberSubredditCommentsSort) is the ONLY native
// default this feature ever writes, and only in direct response to an explicit user
// toggle (or the both-on normalization). Earlier revisions tried per-post fully
// superseding the native store (read+write interception — read as "nothing remembers
// anymore") and then silent layering (both stores co-recording — read as "one post's
// change still leaks subreddit-wide"); the either/or is what makes every state
// self-explanatory. The "Remember Post Sort" toggle row is injected into Apollo's
// native Settings > General > Comments section, right under its sibling "Remember
// Subreddit Sort" (see the SettingsGeneralViewController hooks at the bottom of this
// file).
//
// How Apollo does it (RE'd from the current binary):
// - _TtC6Apollo22CommentsViewController holds `currentSort`, a Swift
//   Optional<RDKCommentSortingMethod> stored inline: Int64 raw at offset+0, is-nil flag
//   byte at offset+8 (bit0 set == .none). Raw values: 1 Top, 2 Best, 3 New, 4 Q&A,
//   5 Controversial, 6 Old, 7 Random, 8 Live Update (9 is RDKLink.suggestedSort's "none").
// - The initial sort is computed in the VC's Swift init (before viewDidLoad). viewDidLoad
//   kicks the first fetch, which uses a non-nil currentSort AS-IS — so writing the ivar
//   before %orig in viewDidLoad both overrides the init-time chain and feeds the first
//   fetch AND the sort-button icon setup. On URL-scheme/inbox opens (init(linkID:...))
//   the `link` ivar is nil until the first fetch returns; those opens keep native
//   behavior (no id to look up yet), while recording still works because the user can
//   only change sort after the load populates `link`.
// - Every user sort pick funnels through sortBarButtonItemTappedWithSender: -> option
//   closure -> currentSort ivar write -> reload via -[RDKClient
//   linkAndCommentsForLinkWithIdentifier:commentSort:pagination:completion:] (bare post
//   id, Live(8) sent to the network as New(3)). We "arm" on the button tap (capturing the
//   VC, its post id, and the pre-menu sort) and record on the very next reload for that
//   post when currentSort actually changed. Programmatic writes (init, loadComments'
//   nil-fallback, a SharePlay remote sort change) never follow a local tap, so they are
//   naturally excluded. The sort raw is read back from the VC ivar, NOT from the fetch's
//   commentSort argument, because of the Live(8)->New(3) network mapping.
// - Live Update (8) is deliberately never persisted, matching Apollo's own per-subreddit
//   remember (its 10s live timer only starts from the menu handler, so restoring 8 at
//   open would show the live icon without live behavior).
//
// Storage: standardUserDefaults dict under UDKeyPerPostCommentSortMapping —
// { bare post id : { "s": sort raw, "t": last-use unix time } }, LRU-capped at
// kPPCSMaxEntries (timestamps refresh on every apply/record; stalest entries are
// evicted first, mirroring ApolloLinkPreviewCache). Riding standardUserDefaults means
// the mapping is included in Backup/Restore Settings for free.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
@end

// Apollo's native Settings > General screen (the toggle row is injected into its
// Comments section, right under "Remember Subreddit Sort" — see the hooks below).
@interface SettingsGeneralViewController : UIViewController
@end

static NSString *const kPPCSSortKey = @"s";
static NSString *const kPPCSTimestampKey = @"t";
static const NSUInteger kPPCSMaxEntries = 500;

// MARK: - runtime helpers (superclass-chain ivar access, matches ApolloLiveCommentsFollow)

static id PPCSObjectIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static ptrdiff_t PPCSIvarOffset(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return ivar_getOffset(iv);
        cls = class_getSuperclass(cls);
    }
    return -1;
}

// Read currentSort (Optional<RDKCommentSortingMethod>: Int64 raw at +0, nil byte at +8).
// Returns NO when the optional is .none or the ivar can't be located.
static BOOL PPCSReadCurrentSort(id vc, int64_t *outRaw) {
    ptrdiff_t off = PPCSIvarOffset(vc, "currentSort");
    if (off < 0) return NO;
    const uint8_t *base = (const uint8_t *)(__bridge const void *)vc;
    if ((*(base + off + 8)) & 0x1) return NO;   // .none
    int64_t raw = 0;
    memcpy(&raw, base + off, sizeof(raw));
    if (outRaw) *outRaw = raw;
    return YES;
}

// Write currentSort = .some(raw). Bounds-checked against the instance size because a
// blind write is riskier than the reads the other modules do; on any layout surprise
// we bail and Apollo's native sort stands.
static BOOL PPCSWriteCurrentSort(id vc, int64_t raw) {
    ptrdiff_t off = PPCSIvarOffset(vc, "currentSort");
    if (off < 0) return NO;
    if ((size_t)(off + 9) > class_getInstanceSize(object_getClass(vc))) return NO;
    uint8_t *base = (uint8_t *)(__bridge void *)vc;
    memcpy(base + off, &raw, sizeof(raw));
    *(base + off + 8) = 0;                      // clear the is-nil flag byte
    return YES;
}

// Bare post id (e.g. "1abcde") from the VC's `link` ivar (RDKLink, a plain ObjC pointer
// per the class dump). This is the exact identifier the reload fetch is keyed with.
// nil on URL-scheme/inbox opens until the first fetch populates `link`.
static NSString *PPCSPostID(id vc) {
    id link = PPCSObjectIvar(vc, "link");
    if (!link || ![link respondsToSelector:@selector(identifier)]) return nil;
    NSString *identifier = ((NSString *(*)(id, SEL))objc_msgSend)(link, @selector(identifier));
    return ([identifier isKindOfClass:[NSString class]] && identifier.length > 0) ? identifier : nil;
}

static NSString *PPCSSortName(int64_t raw) {
    switch (raw) {
        case 1: return @"Top";
        case 2: return @"Best";
        case 3: return @"New";
        case 4: return @"Q&A";
        case 5: return @"Controversial";
        case 6: return @"Old";
        case 7: return @"Random";
        case 8: return @"Live Update";
        default: return @"?";
    }
}

// MARK: - the per-post mapping (standardUserDefaults, LRU-capped)

static NSDictionary *PPCSMapping(void) {
    NSDictionary *map = [[NSUserDefaults standardUserDefaults] dictionaryForKey:UDKeyPerPostCommentSortMapping];
    return [map isKindOfClass:[NSDictionary class]] ? map : nil;
}

// 0 == no saved sort for this post.
static int64_t PPCSSavedSortForPost(NSString *postID) {
    NSDictionary *entry = PPCSMapping()[postID];
    if (![entry isKindOfClass:[NSDictionary class]]) return 0;
    NSNumber *sort = entry[kPPCSSortKey];
    return [sort isKindOfClass:[NSNumber class]] ? sort.longLongValue : 0;
}

// Saves (or re-touches, when the value is unchanged — that refreshes the LRU timestamp)
// a post's sort, then evicts the stalest entries above the cap.
static void PPCSSaveSortForPost(NSString *postID, int64_t raw) {
    NSMutableDictionary *map = [PPCSMapping() mutableCopy] ?: [NSMutableDictionary dictionary];
    map[postID] = @{ kPPCSSortKey: @(raw), kPPCSTimestampKey: @([[NSDate date] timeIntervalSince1970]) };
    if (map.count > kPPCSMaxEntries) {
        NSArray *keysByAge = [map keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
            double ta = [a isKindOfClass:[NSDictionary class]] ? [((NSDictionary *)a)[kPPCSTimestampKey] doubleValue] : 0;
            double tb = [b isKindOfClass:[NSDictionary class]] ? [((NSDictionary *)b)[kPPCSTimestampKey] doubleValue] : 0;
            if (ta < tb) return NSOrderedAscending;
            if (ta > tb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSUInteger excess = map.count - kPPCSMaxEntries;
        [map removeObjectsForKeys:[keysByAge subarrayWithRange:NSMakeRange(0, excess)]];
        ApolloLog(@"[PerPostSort] pruned %lu stale entries (cap %lu)", (unsigned long)excess, (unsigned long)kPPCSMaxEntries);
    }
    [[NSUserDefaults standardUserDefaults] setObject:map forKey:UDKeyPerPostCommentSortMapping];
}

// MARK: - arm/record state
//
// Armed by the sort-button tap, consumed by the next reload fetch for that post.
// All of it runs on the main thread (button tap, menu action, UI-initiated fetch).

static __weak UIViewController *sPPCSArmedVC = nil;
static NSString *sPPCSArmedPostID = nil;
static int64_t sPPCSArmedBeforeRaw = 0;   // 0 == currentSort was .none when armed

static void PPCSDisarm(void) {
    sPPCSArmedVC = nil;
    sPPCSArmedPostID = nil;
    sPPCSArmedBeforeRaw = 0;
}

// MARK: - hooks

%hook _TtC6Apollo22CommentsViewController

// Apply a saved sort BEFORE %orig: the init-time sort chain already ran, and %orig is
// what kicks the first comments fetch (which uses a non-nil currentSort as-is) and sets
// up the sort-button icon — so this single early write covers data and UI both.
- (void)viewDidLoad {
    if (sPerPostCommentSort) {
        NSString *postID = PPCSPostID(self);
        int64_t saved = postID ? PPCSSavedSortForPost(postID) : 0;
        if (saved >= 1 && saved <= 7) {   // Live(8) is never stored; anything else is stale/garbage
            int64_t cur = 0;
            BOOL curSet = PPCSReadCurrentSort(self, &cur);
            if ((!curSet || cur != saved) && PPCSWriteCurrentSort(self, saved)) {
                ApolloLog(@"[PerPostSort] applied saved sort %@ to post %@ (was %@)",
                          PPCSSortName(saved), postID, curSet ? PPCSSortName(cur) : @"(nil)");
            }
            PPCSSaveSortForPost(postID, saved);   // touch the LRU timestamp
        }
    }
    %orig;
}

// Arm on the sort-button tap: capture this VC, its post id and the pre-menu sort. The
// pick itself lands in a Swift closure we can't hook; the reload fetch below is where
// the change is confirmed and recorded. Re-arms fresh on every tap; a dismissed menu
// leaves a stale arm that the next matching fetch consumes harmlessly (sort unchanged
// -> nothing recorded).
- (void)sortBarButtonItemTappedWithSender:(id)sender {
    if (sPerPostCommentSort) {
        NSString *postID = PPCSPostID(self);
        if (postID) {
            int64_t cur = 0;
            sPPCSArmedBeforeRaw = PPCSReadCurrentSort(self, &cur) ? cur : 0;
            sPPCSArmedVC = self;
            sPPCSArmedPostID = postID;
            ApolloLog(@"[PerPostSort] armed on post %@ (current %@)", postID, PPCSSortName(sPPCSArmedBeforeRaw));
        }
    }
    %orig;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (sPPCSArmedVC == self || !sPPCSArmedVC) PPCSDisarm();
}

%end

%hook RDKClient

// Every comments reload (including the one the sort pick triggers) funnels through here
// with the bare post id. If we're armed for this exact post and the VC's currentSort
// changed since the tap, that's the user's pick — record it. Any matching fetch consumes
// the arm, so a dismissed menu followed by pull-to-refresh records nothing.
// NOTE: commentSort is a scalar enum — it MUST be declared long long, not id (see
// ApolloChatsFilter for the crash that teaches this lesson).
- (id)linkAndCommentsForLinkWithIdentifier:(id)identifier commentSort:(long long)commentSort pagination:(id)pagination completion:(id)completion {
    if (sPerPostCommentSort && sPPCSArmedPostID) {
        UIViewController *armedVC = sPPCSArmedVC;
        if (!armedVC) {
            PPCSDisarm();   // VC deallocated under the arm
        } else if ([identifier isKindOfClass:[NSString class]] && [sPPCSArmedPostID isEqualToString:(NSString *)identifier]) {
            int64_t cur = 0;
            if (PPCSReadCurrentSort(armedVC, &cur) && cur != sPPCSArmedBeforeRaw) {
                if (cur >= 1 && cur <= 7) {
                    PPCSSaveSortForPost(sPPCSArmedPostID, cur);
                    ApolloLog(@"[PerPostSort] recorded sort %@ for post %@", PPCSSortName(cur), sPPCSArmedPostID);
                } else {
                    // Live Update: never persisted (see header comment). An existing saved
                    // sort is kept, matching Apollo's per-subreddit remember semantics.
                    ApolloLog(@"[PerPostSort] not persisting %@ for post %@", PPCSSortName(cur), sPPCSArmedPostID);
                }
            }
            PPCSDisarm();
        }
    }
    return %orig;
}

%end

// MARK: - Settings row (native Settings > General > Comments section)
//
// The toggle lives with its siblings (Default Sort / Remember Subreddit Sort /
// Ignore Suggested Sort) in Apollo's native General settings screen, injected
// right under "Remember Subreddit Sort" using the count-bump + index-shift
// pattern established by ApolloSettings.xm's Settings/About section injections.
//
// The anchor (section + row of "Remember Subreddit Sort" in the COMMENTS section)
// is discovered once per VC in viewDidLoad by peeking the data source directly:
// "Remember Subreddit Sort" appears in both the Posts and Comments sections, so
// the comments one is identified as the section that also contains the unique
// "Ignore Suggested Sort" row. If discovery finds nothing (relabeled rows, future
// binary), no row is injected and the native screen is untouched — the feature
// itself keeps working off the stored default.
//
// IMPORTANT: this screen is an Eureka FormViewController (Swift form library),
// and Eureka's delegate/dataSource methods index straight into its Section row
// array (`form[indexPath.section][indexPath.row]`) with NO bounds guard — an
// unmapped display index for the injected row is an instant NSRangeException
// (first hit: UITableView's estimated-height pass calling
// tableView:estimatedHeightForRowAtIndexPath:, which Eureka implements as a
// merged twin of heightForRowAt). So EVERY row-indexPath-taking method Eureka
// implements must be hooked and remapped. The set below is the complete
// `otool -oV` dump of _TtC6Eureka18FormViewController's tableView: selectors
// (frozen with the app binary; Apollo ships its own embedded Eureka). Policy:
//   - our injected row: answer inertly (NO/nil/None), borrow the anchor row's
//     answer for pure appearance queries (height, focus, indentation), and
//     swallow actions;
//   - rows BELOW ours: shift the incoming path up by one to its native index
//     (and shift any RETURNED index path back down into display space);
//   - everything else (other sections / rows above ours / other Eureka
//     screens, which never get an anchor): untouched pass-through.
// Section-only methods (headers/footers/titles) need no remap — section
// indices are unchanged.

static const void *kPPCSAnchorKey = &kPPCSAnchorKey;   // NSIndexPath: native path of "Remember Subreddit Sort" (Comments)
static BOOL sPPCSScanning = NO;                        // while YES, the table hooks below are pass-through
static __weak UIViewController *sPPCSSettingsVC = nil; // last-seen General screen, for the exclusivity cross-flip

static NSIndexPath *PPCSSettingsAnchor(id vc) {
    return objc_getAssociatedObject(vc, kPPCSAnchorKey);
}

static UITableView *PPCSSettingsTable(id vc) {
    id tv = PPCSObjectIvar(vc, "tableView");
    if ([tv isKindOfClass:[UITableView class]]) return (UITableView *)tv;
    // Subview-walk fallback (same as ApolloSettings.xm's About injection).
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:((UIViewController *)vc).view];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return nil;
}

// MARK: mutual exclusivity cross-flip (see the file header)
//
// Flips OUR row's switch off. Ours is a plain UITableViewCell + UISwitch whose state is
// re-read from defaults on every dequeue, so an animated setOn: is all it needs (the
// defaults write happens at the call site). Used when the native toggle gets enabled.
static void PPCSSetRowSwitchOff(UIViewController *vc, NSIndexPath *displayPath) {
    if (!vc || !displayPath || !vc.viewIfLoaded.window) return;
    UITableViewCell *cell = [PPCSSettingsTable(vc) cellForRowAtIndexPath:displayPath];
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        [(UISwitch *)cell.accessoryView setOn:NO animated:YES];
    }
}

// Turns the NATIVE "Remember Subreddit Sort" row off — and it must do so the way a user
// tap would: set the visible switch off, then fire its valueChanged action so Eureka
// processes a real value change (row.value -> false, Apollo's own onChange persists it).
// Writing the defaults key alone is NOT enough for this row: Eureka caches the value on
// its Row object and only fires onChange (and thus the defaults write our exclusivity
// hook listens for) when a toggle CHANGES that cached value. Force-writing defaults
// under it leaves the cache stuck at true, so the user's next enable tap compares
// true -> true, writes nothing, and the cross-flip silently stops working — exactly the
// "toggle them a few times and it stops switching the other off" report on PR #570.
// The direct defaults write stays as the authoritative fallback for when the row is off
// screen or the screen is gone (its next form build re-reads defaults anyway; a fresh
// build starts with a fresh cache, so no staleness survives the screen).
static void PPCSTurnNativeRememberSubredditSortOff(UIViewController *vc) {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyApolloRememberSubredditCommentsSort];
    NSIndexPath *anchor = PPCSSettingsAnchor(vc);
    if (!vc || !anchor || !vc.viewIfLoaded.window) return;
    UITableViewCell *cell = [PPCSSettingsTable(vc) cellForRowAtIndexPath:anchor];
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)cell.accessoryView;
        if (sw.isOn) {
            [sw setOn:NO animated:YES];
            [sw sendActionsForControlEvents:UIControlEventValueChanged];   // let Eureka see the change
        }
    }
}

static void PPCSDiscoverSettingsAnchor(id vc, UITableView *tv) {
    if (!tv || PPCSSettingsAnchor(vc)) return;
    sPPCSScanning = YES;
    @try {
        NSInteger sections = [(id<UITableViewDataSource>)vc numberOfSectionsInTableView:tv];
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger rows = [(id<UITableViewDataSource>)vc tableView:tv numberOfRowsInSection:s];
            NSInteger rememberRow = NSNotFound;
            BOOL hasIgnoreSuggested = NO;
            for (NSInteger r = 0; r < rows; r++) {
                UITableViewCell *cell = [(id<UITableViewDataSource>)vc tableView:tv
                                                            cellForRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
                NSString *t = cell.textLabel.text;
                if ([t isEqualToString:@"Remember Subreddit Sort"]) rememberRow = r;
                else if ([t isEqualToString:@"Ignore Suggested Sort"]) hasIgnoreSuggested = YES;
            }
            if (rememberRow != NSNotFound && hasIgnoreSuggested) {
                NSIndexPath *anchor = [NSIndexPath indexPathForRow:rememberRow inSection:s];
                objc_setAssociatedObject(vc, kPPCSAnchorKey, anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ApolloLog(@"[PerPostSort] settings anchor: Comments section %ld row %ld", (long)s, (long)rememberRow);
                break;
            }
        }
        if (!PPCSSettingsAnchor(vc)) ApolloLog(@"[PerPostSort] settings anchor not found, row not injected");
    } @catch (NSException *e) {
        ApolloLog(@"[PerPostSort] settings anchor scan threw: %@", e);
    }
    sPPCSScanning = NO;
}

// Classification of a DISPLAY index path against the injected row.
typedef NS_ENUM(int, PPCSRowKind) {
    PPCSRowPassthrough = 0,   // no anchor / other section / at-or-above the anchor
    PPCSRowOurs        = 1,   // the injected "Remember Post Sort" row
    PPCSRowShifted     = 2,   // a native row displayed one slot below its native index
};

static PPCSRowKind PPCSClassifyRow(id vc, NSIndexPath *ip, NSIndexPath *__strong *outNative) {
    if (sPPCSScanning || !ip) return PPCSRowPassthrough;
    NSIndexPath *a = PPCSSettingsAnchor(vc);
    if (!a || ip.section != a.section || ip.row <= a.row) return PPCSRowPassthrough;
    if (ip.row == a.row + 1) return PPCSRowOurs;
    if (outNative) *outNative = [NSIndexPath indexPathForRow:ip.row - 1 inSection:ip.section];
    return PPCSRowShifted;
}

// native -> display, for delegate methods that RETURN an index path.
static NSIndexPath *PPCSDisplayPath(id vc, NSIndexPath *native) {
    if (!native || sPPCSScanning) return native;
    NSIndexPath *a = PPCSSettingsAnchor(vc);
    if (!a || native.section != a.section || native.row <= a.row) return native;
    return [NSIndexPath indexPathForRow:native.row + 1 inSection:native.section];
}

// MARK: "Always Offer Translate" row hiding (single-owner, moved from ApolloSettings.xm)
//
// Apollo's native General > Other section contains an "Always Offer Translate" row that
// is redundant now that the tweak ships its own Translation feature; it is hidden by
// collapsing its height to 0 and skipping selection (the underlying Apollo setting is
// untouched). This used to be a second, independent %hook SettingsGeneralViewController
// in ApolloSettings.xm — but stacking two remappers on the same delegate methods is
// order-fragile (PR #570 review): Logos %ctor ordering across translation units decides
// which hook is outermost, the inner hook then receives index paths this module has
// already shifted to NATIVE space while its own bookkeeping assumes display space, and
// its height hook's [self tableView:cellForRowAtIndexPath:] peek re-enters the TOP of
// the chain where that native-space path gets interpreted as display space and shifted
// a second time. Owning both features in this one remapper keeps every path in DISPLAY
// space, so the set membership and the (still top-of-chain) peek stay consistent.
// This hiding is independent of the "Remember Post Sort" toggle and of whether the
// anchor row was discovered (with no anchor, display space == native space).
static NSString *const kPPCSAlwaysOfferTranslateLabel = @"Always Offer Translate";
static const void *kPPCSHiddenRowsKey = &kPPCSHiddenRowsKey;

// Display-space index paths of native rows this module hides on the General screen.
static NSMutableSet<NSIndexPath *> *PPCSHiddenRowsForTableView(UITableView *tableView) {
    NSMutableSet *set = objc_getAssociatedObject(tableView, kPPCSHiddenRowsKey);
    if (!set) {
        set = [NSMutableSet set];
        objc_setAssociatedObject(tableView, kPPCSHiddenRowsKey, set, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return set;
}

static BOOL PPCSIsHiddenLabelCell(UITableViewCell *cell) {
    NSString *text = cell.textLabel.text;
    return text != nil && [text isEqualToString:kPPCSAlwaysOfferTranslateLabel];
}

%hook SettingsGeneralViewController

- (void)viewDidLoad {
    %orig;
    sPPCSSettingsVC = self;
    PPCSDiscoverSettingsAnchor(self, PPCSSettingsTable(self));
}

// MARK: dataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger n = %orig;
    if (sPPCSScanning) return n;
    NSIndexPath *a = PPCSSettingsAnchor(self);
    return (a && section == a.section) ? n + 1 : n;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    UITableViewCell *cell = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: {
            // Borrow the anchor row for its theming (background, label font/color,
            // switch tint), but return our OWN cell with a distinct reuse identifier
            // so Eureka's dequeues can never recycle it into a native row. It can
            // never be a hidden native row, so skip the bookkeeping below.
            NSIndexPath *a = PPCSSettingsAnchor(self);
            UITableViewCell *donor = %orig(tableView, a);
            cell = [tableView dequeueReusableCellWithIdentifier:@"ApolloPerPostSortRow"];
            if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                     reuseIdentifier:@"ApolloPerPostSortRow"];
            cell.backgroundColor = donor.backgroundColor;
            cell.textLabel.font = donor.textLabel.font;
            cell.textLabel.textColor = donor.textLabel.textColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"Remember Post Sort";
            UISwitch *sw = [[UISwitch alloc] init];
            if ([donor.accessoryView isKindOfClass:[UISwitch class]]) {
                sw.onTintColor = ((UISwitch *)donor.accessoryView).onTintColor;
            }
            sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPerPostCommentSort];
            [sw addTarget:self action:@selector(apolloPerPostSortSwitchToggled:)
                 forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            return cell;
        }
        case PPCSRowShifted: cell = %orig(tableView, native); break;
        default: cell = %orig; break;
    }
    // Hidden-row bookkeeping in display space. Skipped during the anchor scan: its
    // pass-through paths stop matching display space the moment the row is injected,
    // and a stale native-space entry would hide whichever row later shifts onto it.
    if (!sPPCSScanning) {
        NSMutableSet *hidden = PPCSHiddenRowsForTableView(tableView);
        if (PPCSIsHiddenLabelCell(cell)) {
            [hidden addObject:indexPath];
            cell.hidden = YES;
            cell.contentView.hidden = YES;
        } else {
            [hidden removeObject:indexPath];
        }
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(NSInteger)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, editingStyle, native); return;
        default: %orig; return;
    }
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSIndexPath *srcNative = nil, *dstNative = nil;
    PPCSRowKind src = PPCSClassifyRow(self, sourceIndexPath, &srcNative);
    PPCSRowKind dst = PPCSClassifyRow(self, destinationIndexPath, &dstNative);
    if (src == PPCSRowOurs || dst == PPCSRowOurs) return;   // never movable, defensive
    %orig(tableView, src == PPCSRowShifted ? srcNative : sourceIndexPath,
                     dst == PPCSRowShifted ? dstNative : destinationIndexPath);
}

// MARK: heights

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!sPPCSScanning) {
        NSMutableSet *hidden = PPCSHiddenRowsForTableView(tableView);
        if ([hidden containsObject:indexPath]) return 0.0;
        // Peek at the cell to catch a to-be-hidden row before its first real height is
        // used (same approach the old ApolloSettings.xm hook took). The re-entrancy is
        // safe precisely because this module is the screen's ONLY remapper now: the
        // message dispatches to the top-of-chain cellForRowAtIndexPath: — the hook
        // above — which reads this same display-space path and does the hidden-set
        // bookkeeping itself.
        UITableViewCell *peek = [self tableView:tableView cellForRowAtIndexPath:indexPath];
        if (PPCSIsHiddenLabelCell(peek)) return 0.0;
    }
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return %orig(tableView, PPCSSettingsAnchor(self));   // same as the anchor switch row
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return %orig(tableView, PPCSSettingsAnchor(self));
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (NSInteger)tableView:(UITableView *)tableView indentationLevelForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return 0;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

// MARK: display lifecycle

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;   // our cell: fully styled from the donor already
        case PPCSRowShifted: %orig(tableView, cell, native); break;
        default: %orig; break;
    }
    if (PPCSIsHiddenLabelCell(cell)) {   // defensive re-hide after cell reuse
        cell.hidden = YES;
        cell.contentView.hidden = YES;
    }
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, cell, native); return;
        default: %orig; return;
    }
}

// MARK: selection / highlight

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;   // the switch is the control, the row itself is inert
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return nil;
        case PPCSRowShifted: return PPCSDisplayPath(self, %orig(tableView, native));
        default: return PPCSDisplayPath(self, %orig);
    }
}

- (NSIndexPath *)tableView:(UITableView *)tableView willDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return indexPath;
        case PPCSRowShifted: return PPCSDisplayPath(self, %orig(tableView, native));
        default: return PPCSDisplayPath(self, %orig);
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!sPPCSScanning && [PPCSHiddenRowsForTableView(tableView) containsObject:indexPath]) {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];   // hidden row: swallow the tap
        return;
    }
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: [tableView deselectRowAtIndexPath:indexPath animated:YES]; return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

// MARK: accessory / primary action / menus

- (NSInteger)tableView:(UITableView *)tableView accessoryTypeForRowWithIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return UITableViewCellAccessoryNone;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (BOOL)tableView:(UITableView *)tableView canPerformPrimaryActionForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView performPrimaryActionForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (BOOL)tableView:(UITableView *)tableView canPerformAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, action, native, sender);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView performAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, action, native, sender); return;
        default: %orig; return;
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (id)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return nil;
        case PPCSRowShifted: return %orig(tableView, native, point);
        default: return %orig;
    }
}

// MARK: editing / swipe actions

- (NSInteger)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return UITableViewCellEditingStyleNone;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (NSArray *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return nil;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (id)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return nil;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (id)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return nil;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (void)tableView:(UITableView *)tableView willBeginReorderingRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return nil;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    NSIndexPath *srcNative = nil, *dstNative = nil;
    PPCSRowKind src = PPCSClassifyRow(self, sourceIndexPath, &srcNative);
    PPCSRowKind dst = PPCSClassifyRow(self, proposedDestinationIndexPath, &dstNative);
    if (src == PPCSRowOurs || dst == PPCSRowOurs) return proposedDestinationIndexPath;   // never movable, defensive
    NSIndexPath *result = %orig(tableView, src == PPCSRowShifted ? srcNative : sourceIndexPath,
                                           dst == PPCSRowShifted ? dstNative : proposedDestinationIndexPath);
    return PPCSDisplayPath(self, result);
}

// MARK: focus / multi-select / spring loading

- (BOOL)tableView:(UITableView *)tableView canFocusRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return %orig(tableView, PPCSSettingsAnchor(self));   // focus parity with the anchor switch row
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (BOOL)tableView:(UITableView *)tableView selectionFollowsFocusForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native);
        default: return %orig;
    }
}

- (void)tableView:(UITableView *)tableView didBeginMultipleSelectionInteractionAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return;
        case PPCSRowShifted: %orig(tableView, native); return;
        default: %orig; return;
    }
}

- (BOOL)tableView:(UITableView *)tableView shouldSpringLoadRowAtIndexPath:(NSIndexPath *)indexPath withContext:(id)context {
    NSIndexPath *native = nil;
    switch (PPCSClassifyRow(self, indexPath, &native)) {
        case PPCSRowOurs: return NO;
        case PPCSRowShifted: return %orig(tableView, native, context);
        default: return %orig;
    }
}

%new
- (void)apolloPerPostSortSwitchToggled:(UISwitch *)sender {
    sPerPostCommentSort = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyPerPostCommentSort];
    ApolloLog(@"[PerPostSort] toggle -> %d", sender.isOn);
    // Exclusivity: enabling per-post turns the native per-subreddit remember off. The
    // anchor row is directly above this one, so the flip animates in plain sight.
    if (sender.isOn &&
        [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        PPCSTurnNativeRememberSubredditSortOff(self);
        ApolloLog(@"[PerPostSort] exclusivity: native Remember Subreddit Sort turned OFF");
    }
}

%end

// MARK: - exclusivity: the native switch being enabled turns per-post off
//
// The native Comments > "Remember Subreddit Sort" row is Apollo's own Eureka SwitchRow;
// its defaults write is the one reliable signal that the user enabled it. Swift's
// UserDefaults bindings box the Bool through setObject:forKey: (verified: the row's
// enable never reaches setBool:forKey:), but both entry points are covered in case a
// future binary changes the write path. Keyed strictly on Apollo's toggle key
// transitioning to YES while per-post is on — every write this file itself performs is
// either a different key or NO/false, so there is no recursion.

static void PPCSNativeRememberSubredditSortEnabled(NSUserDefaults *defaults) {
    sPerPostCommentSort = NO;
    [defaults setBool:NO forKey:UDKeyPerPostCommentSort];
    ApolloLog(@"[PerPostSort] exclusivity: native Remember Subreddit Sort enabled -> per-post OFF");
    UIViewController *vc = sPPCSSettingsVC;
    if (vc) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexPath *a = PPCSSettingsAnchor(vc);
            if (a) PPCSSetRowSwitchOff(vc, [NSIndexPath indexPathForRow:a.row + 1 inSection:a.section]);
        });
    }
}

%hook NSUserDefaults

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    %orig;
    if (value && sPerPostCommentSort && [key isKindOfClass:[NSString class]] &&
        [key isEqualToString:UDKeyApolloRememberSubredditCommentsSort]) {
        PPCSNativeRememberSubredditSortEnabled(self);
    }
}

- (void)setObject:(id)value forKey:(NSString *)key {
    %orig;
    if (sPerPostCommentSort && [key isKindOfClass:[NSString class]] &&
        [key isEqualToString:UDKeyApolloRememberSubredditCommentsSort] &&
        [value isKindOfClass:[NSNumber class]] && [(NSNumber *)value boolValue]) {
        PPCSNativeRememberSubredditSortEnabled(self);
    }
}

%end

%ctor {
    %init(SettingsGeneralViewController=objc_getClass("_TtC6Apollo29SettingsGeneralViewController"));
}
