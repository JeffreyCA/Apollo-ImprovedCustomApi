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
// self-explanatory. The "Remember Post Sort" toggle row lives in Apollo's native
// Settings > General > Comments section, right under its sibling "Remember Subreddit
// Sort" — registered with ApolloSettingsGeneralTable (the screen's single geometry
// owner); this module only supplies the row's cell and owns its semantics. See the
// Settings row section at the bottom of this file.
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
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSettingsGeneralTable.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
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

// MARK: - Settings row (registered with ApolloSettingsGeneralTable)
//
// The toggle lives with its siblings (Default Sort / Remember Subreddit Sort /
// Ignore Suggested Sort) in Apollo's native General settings screen. All table
// geometry — anchor discovery, index remapping, the display<->native row map,
// the delegate proxy — is owned by settings/ApolloSettingsGeneralTable.xm; this
// module registers WHAT to inject (the factory below) and owns the row's
// semantics: the defaults write and the exclusivity cross-flips. PR #570
// originally hosted the whole remapper here, which conflated the sort feature
// with screen infrastructure and left ApolloHideNativeOpenInAppRows.xm as a
// second, link-order-fragile hook stack on the same class (review finding).

static NSString *const kPPCSAnchorTitle = @"Remember Subreddit Sort";
static NSString *const kPPCSSectionMarkerTitle = @"Ignore Suggested Sort";

// The injected row's switch (weak: the cell is cached per screen instance via an
// associated object; when the screen dies these go nil). Used by the reverse
// cross-flip — the native toggle being enabled flips ours off, animated.
static __weak UISwitch *sPPCSRowSwitch = nil;

static void PPCSTurnNativeRememberSubredditSortOff(UIViewController *vc);

// Toggle target: a plain object rather than a %new method — the row is
// tweak-owned and the settings VC class belongs to the neutral module now.
@interface PPCSToggleTarget : NSObject
- (void)perPostSortSwitchToggled:(UISwitch *)sender;
@end

@implementation PPCSToggleTarget
- (void)perPostSortSwitchToggled:(UISwitch *)sender {
    sPerPostCommentSort = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeyPerPostCommentSort];
    ApolloLog(@"[PerPostSort] toggle -> %d", sender.isOn);
    // Exclusivity: enabling per-post turns the native per-subreddit remember off. The
    // anchor row is directly above this one, so the flip animates in plain sight.
    if (sender.isOn &&
        [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyApolloRememberSubredditCommentsSort]) {
        PPCSTurnNativeRememberSubredditSortOff(ApolloGeneralTableActiveVC());
        ApolloLog(@"[PerPostSort] exclusivity: native Remember Subreddit Sort turned OFF");
    }
}
@end

static PPCSToggleTarget *sPPCSToggleTarget = nil;

// Factory for the "Remember Post Sort" row: builds the cell once per screen
// instance, then restyles it from the live donor (anchor) cell and re-reads the
// switch state from defaults on every dequeue, so the cell never goes stale.
static const void *kPPCSRowCellKey = &kPPCSRowCellKey;

static UITableViewCell *PPCSBuildSettingsRow(UIViewController *vc, UITableViewCell *donor) {
    UITableViewCell *cell = objc_getAssociatedObject(vc, kPPCSRowCellKey);
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (!cell || ![sw isKindOfClass:[UISwitch class]]) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"Remember Post Sort";
        sw = [[UISwitch alloc] init];
        [sw addTarget:sPPCSToggleTarget action:@selector(perPostSortSwitchToggled:)
     forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        objc_setAssociatedObject(vc, kPPCSRowCellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (donor) {   // borrow the sibling switch row's live theming
        cell.backgroundColor = donor.backgroundColor;
        cell.textLabel.font = donor.textLabel.font;
        cell.textLabel.textColor = donor.textLabel.textColor;
    }
    UISwitch *donorSwitch = [donor.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)donor.accessoryView : nil;
    sw.onTintColor = donorSwitch.onTintColor ?: ApolloThemeAccentColor();
    sw.on = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyPerPostCommentSort];
    sPPCSRowSwitch = sw;
    return cell;
}

// MARK: mutual exclusivity cross-flip (see the file header)

// Flips OUR row's switch off (animated). State is re-read from defaults on every
// factory call above, so the visible switch is the only thing to fix here; the
// defaults write happens at the call site.
static void PPCSSetRowSwitchOff(void) {
    UISwitch *sw = sPPCSRowSwitch;
    if (sw.window) [sw setOn:NO animated:YES];
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
    UITableViewCell *cell = ApolloGeneralTableVisibleCellForTitle(vc, kPPCSAnchorTitle);
    if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)cell.accessoryView;
        if (sw.isOn) {
            [sw setOn:NO animated:YES];
            [sw sendActionsForControlEvents:UIControlEventValueChanged];   // let Eureka see the change
        }
    }
}

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
    dispatch_async(dispatch_get_main_queue(), ^{
        PPCSSetRowSwitchOff();
    });
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
    %init;
    sPPCSToggleTarget = [PPCSToggleTarget new];
    ApolloGeneralTableInjectRow(kPPCSAnchorTitle, kPPCSSectionMarkerTitle,
        ^UITableViewCell *(UIViewController *vc, UITableViewCell *donor) {
            return PPCSBuildSettingsRow(vc, donor);
        });
}
