// ApolloFollowingSection — a dedicated FOLLOWING section in the Subreddits list
// for followed users (the "u_<name>" profile subreddits Reddit mixes into your
// subscriptions), plus user-configurable ordering of the Favorites /
// Multireddits / Moderator / Following sections.
//
// ============================ How the list works =============================
// (all of this verified in Hopper against the current Apollo binary)
//
//   Apollo.RedditListViewController's table has a FIXED section layout:
//     native 0      = feed shortcuts (Home / Popular / All / Moderator Posts)
//     native 1      = FAVORITES      (NSUserDefaults "FavoriteSubreddits")
//     native 2      = MULTIREDDITS   (multireddits ivar; + inline expansion rows)
//     native 3      = MODERATOR      (currentUser.moderatedSubreddits)
//     native 4..4+N = A–Z/#          (sectionedSubreddits ivar, [[String]],
//                                     one inner array per UILocalizedIndexedCollation
//                                     section, each sorted; empty sections have a
//                                     nil header + 0 rows, so they're invisible)
//   numberOfSections is ALWAYS collation.sectionTitles.count + 4.
//   Followed users are plain entries in the A–Z sections whose subscription
//   name starts with "u_" (they sort by username via -subredditSortNamer).
//
// ================================ The design =================================
// Pure VIEW-LAYER virtualization. Apollo's model is never touched; every one
// of its table dataSource/delegate methods is wrapped and index paths are
// translated between the VISIBLE layout and Apollo's NATIVE layout:
//
//   visible 0            = native 0 (feed shortcuts — never moved; PR #988
//                          keys its replacement rows off section 0)
//   visible 1..K         = the special sections in the user's chosen order.
//                          "following" is a SYNTHETIC slot with no native
//                          section; its rows are the u_ entries, each of which
//                          still has a real native (collation) index path.
//   visible K+1..        = the collation sections, with u_ rows compressed out.
//
// Because every visible row (including rows of the synthetic section) maps to
// a real native index path, ALL row-level behavior is Apollo's own via %orig:
// cells, navigation, context menus, swipe-to-unsubscribe (which for u_ subs is
// Apollo's own unfollow flow), and the favorite star.
//
// Two flows need extra care because they don't take index paths as arguments:
//
//  * favoriteSubredditButtonTapped: / multiredditExpandButtonTapped: resolve
//    the tapped row themselves via -[UITableView indexPathForRowAtPoint:]
//    (visible space) and then interpret it against the native model (e.g. the
//    literal `section == 1` favorites check). While those handlers run we open
//    a "point window": indexPathForRowAtPoint: results are translated
//    visible -> native so Apollo's model logic sees the coordinates it
//    expects.
//  * Inside those same handlers Apollo imperatively animates rows
//    (insert/delete/reloadRowsAtIndexPaths:) with MODEL-space paths. During
//    the window those calls are translated native -> visible. For the
//    unfavorite delete we recompute the favorites row from the tapped name the
//    same way ApolloSubredditIndexPolish's off-by-one correction does, so the
//    two modules converge on the same answer regardless of hook order.
//
// Everything else Apollo does to this table is reloadData (unsubscribe commits,
// model refreshes), which is remap-safe: our mapping is invalidated in a
// reloadData hook before the table re-queries anything.
//
// When "Separate Followed Users" is OFF and the section order is the default,
// every hook is a straight %orig passthrough (one static + pointer check), so
// the module is inert for anyone not using the feature.
//
// ============================ Reading the model ==============================
// The u_ rows' native positions come from the sectionedSubreddits ivar. It's a
// Swift [[String]]?; we never write it, and we read it using only ABI-frozen
// layout (arm64 Swift stable ABI: native array storage = count at +0x10,
// elements from +0x20; String = 2 words) plus the official
// String._bridgeToObjectiveC entry point from libswiftFoundation for the
// actual string values — no hand-rolled string decoding. Any anomaly (tagged
// pointers where none are expected, absurd counts, missing symbols) makes the
// walk return nil and the feature quietly deactivates for that launch.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

#import "ApolloCommon.h"
#import "ApolloFollowingSection.h"
#import "UserDefaultConstants.h"

@interface RedditListViewController : UIViewController // Apollo.RedditListViewController
@end

// Native section indices (fixed, verified in Hopper; 0 = the feed shortcuts).
static const NSInteger kApolloNativeSectionFavorites   = 1;
static const NSInteger kApolloNativeSectionMultireddit = 2;
static const NSInteger kApolloNativeSectionModerator   = 3;
static const NSInteger kApolloNativeSectionCollation   = 4; // first A–Z section

// Marker for "the synthetic FOLLOWING section" in visible->native translation.
static const NSInteger kApolloFollowingSyntheticSection = -2;

// Section order tokens (persisted in UDKeySubredditSectionOrder).
NSString *const ApolloSubredditSectionTokenFavorites    = @"favorites";
NSString *const ApolloSubredditSectionTokenMultireddits = @"multireddits";
NSString *const ApolloSubredditSectionTokenModerator    = @"moderator";
NSString *const ApolloSubredditSectionTokenFollowing    = @"following";

#define kApolloSectionTokenFavorites   ApolloSubredditSectionTokenFavorites
#define kApolloSectionTokenMultireddit ApolloSubredditSectionTokenMultireddits
#define kApolloSectionTokenModerator   ApolloSubredditSectionTokenModerator
#define kApolloSectionTokenFollowing   ApolloSubredditSectionTokenFollowing

NSString *ApolloSubredditSectionDisplayName(NSString *token) {
    if ([token isEqualToString:ApolloSubredditSectionTokenFavorites])    return @"Favorites";
    if ([token isEqualToString:ApolloSubredditSectionTokenMultireddits]) return @"Multireddits";
    if ([token isEqualToString:ApolloSubredditSectionTokenModerator])    return @"Moderator";
    if ([token isEqualToString:ApolloSubredditSectionTokenFollowing])    return @"Following";
    return token;
}

#pragma mark - Config

static BOOL sApolloFollowingSeparate = NO;
static NSArray<NSString *> *sApolloSectionOrderTokens = nil; // resolved, valid, complete
static NSInteger sApolloFollowingConfigGeneration = 0;      // bumped on every settings change

NSArray<NSString *> *ApolloSubredditSectionsDefaultOrder(void) {
    return @[ kApolloSectionTokenFavorites,
              kApolloSectionTokenMultireddit,
              kApolloSectionTokenModerator,
              kApolloSectionTokenFollowing ];
}

// Sanitizes whatever is stored into a complete, duplicate-free token order.
NSArray<NSString *> *ApolloSubredditSectionsResolvedOrder(void) {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] stringArrayForKey:UDKeySubredditSectionOrder];
    NSArray<NSString *> *defaults = ApolloSubredditSectionsDefaultOrder();
    NSMutableArray<NSString *> *resolved = [NSMutableArray arrayWithCapacity:4];
    for (NSString *token in stored) {
        if ([defaults containsObject:token] && ![resolved containsObject:token]) [resolved addObject:token];
    }
    for (NSString *token in defaults) {
        if (![resolved containsObject:token]) [resolved addObject:token];
    }
    return resolved;
}

static void ApolloFollowingReloadConfig(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    sApolloFollowingSeparate = [defaults boolForKey:UDKeySeparateFollowedUsers];
    sApolloSectionOrderTokens = ApolloSubredditSectionsResolvedOrder();
    sApolloFollowingConfigGeneration++;
}

// Whether the user's section order (ignoring the following slot) differs from
// the default — i.e. the remap would still have work to do with separation
// unavailable.
static BOOL ApolloFollowingRemapWantedWithoutSeparation(void) {
    NSArray<NSString *> *defaultsOrder = ApolloSubredditSectionsDefaultOrder();
    // With separation off the following token is ignored, so compare the
    // first three meaningful entries only.
    NSUInteger slot = 0;
    for (NSString *token in sApolloSectionOrderTokens) {
        if ([token isEqualToString:kApolloSectionTokenFollowing]) continue;
        NSUInteger defaultSlot = 0;
        for (NSString *defToken in defaultsOrder) {
            if ([defToken isEqualToString:kApolloSectionTokenFollowing]) continue;
            if ([defToken isEqualToString:token]) break;
            defaultSlot++;
        }
        if (defaultSlot != slot) return YES;
        slot++;
    }
    return NO;
}

// The remap layer only engages when it changes anything.
static BOOL ApolloFollowingRemapWanted(void) {
    return sApolloFollowingSeparate || ApolloFollowingRemapWantedWithoutSeparation();
}

#pragma mark - Swift array reading (read-only, ABI-frozen layout)

typedef void *(*ApolloSwiftStringBridgeFn)(uint64_t word0, uint64_t word1);

static ApolloSwiftStringBridgeFn ApolloFollowingStringBridge(void) {
    static ApolloSwiftStringBridgeFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // (extension in Foundation):Swift.String._bridgeToObjectiveC() -> NSString
        // Returns an owned (+1) NSString; self is passed in x0/x1 (confirmed
        // against Apollo's own compiled calls to the same symbol).
        fn = (ApolloSwiftStringBridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
        if (!fn) ApolloLog(@"[FollowingSection] String bridge symbol missing — feature disabled");
    });
    return fn;
}

// A Swift bridge-object word that is a plain native storage pointer has none
// of the tag bits set. Anything else (Cocoa-backed, tagged) is unexpected for
// arrays Apollo builds natively — bail and let the feature deactivate.
static BOOL ApolloFollowingPointerLooksLikeNativeStorage(uintptr_t word) {
    if (word == 0) return NO;
    if (word & 0xC000000000000001ULL) return NO;
    if (word & 0x7ULL) return NO; // storage objects are 8-byte aligned
    return YES;
}

static ptrdiff_t ApolloFollowingSectionedSubredditsOffset(void) {
    static ptrdiff_t offset = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("_TtC6Apollo24RedditListViewController");
        Ivar ivar = cls ? class_getInstanceVariable(cls, "sectionedSubreddits") : NULL;
        offset = ivar ? ivar_getOffset(ivar) : -1;
        if (offset < 0) ApolloLog(@"[FollowingSection] sectionedSubreddits ivar not found — feature disabled");
    });
    return offset;
}

// Raw pointer of the outer array storage (also the mapping cache key), or 0.
static uintptr_t ApolloFollowingOuterStorageWord(UIViewController *listVC) {
    ptrdiff_t offset = ApolloFollowingSectionedSubredditsOffset();
    if (offset < 0 || !listVC) return 0;
    return *(uintptr_t *)((uint8_t *)(__bridge void *)listVC + offset);
}

// Walks sectionedSubreddits into NSArray<NSArray<NSString *> *>. nil on any
// anomaly (never partially wrong data).
static NSArray<NSArray<NSString *> *> *ApolloFollowingReadSectionedSubreddits(UIViewController *listVC) {
    ApolloSwiftStringBridgeFn bridge = ApolloFollowingStringBridge();
    if (!bridge) return nil;

    uintptr_t outerWord = ApolloFollowingOuterStorageWord(listVC);
    if (outerWord == 0) return nil; // Optional.none — model not built yet
    if (!ApolloFollowingPointerLooksLikeNativeStorage(outerWord)) {
        ApolloLog(@"[FollowingSection] outer storage word 0x%lx not native — bailing", (unsigned long)outerWord);
        return nil;
    }

    int64_t outerCount = *(int64_t *)(outerWord + 0x10);
    if (outerCount < 0 || outerCount > 512) {
        ApolloLog(@"[FollowingSection] implausible outer count %lld — bailing", (long long)outerCount);
        return nil;
    }

    NSMutableArray<NSArray<NSString *> *> *sections = [NSMutableArray arrayWithCapacity:(NSUInteger)outerCount];
    for (int64_t sectionIdx = 0; sectionIdx < outerCount; sectionIdx++) {
        uintptr_t innerWord = *(uintptr_t *)(outerWord + 0x20 + (uintptr_t)sectionIdx * 8);
        if (!ApolloFollowingPointerLooksLikeNativeStorage(innerWord)) {
            ApolloLog(@"[FollowingSection] inner storage word not native at %lld — bailing", (long long)sectionIdx);
            return nil;
        }
        int64_t innerCount = *(int64_t *)(innerWord + 0x10);
        if (innerCount < 0 || innerCount > 100000) {
            ApolloLog(@"[FollowingSection] implausible inner count %lld — bailing", (long long)innerCount);
            return nil;
        }
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:(NSUInteger)innerCount];
        for (int64_t rowIdx = 0; rowIdx < innerCount; rowIdx++) {
            uintptr_t elementBase = innerWord + 0x20 + (uintptr_t)rowIdx * 16;
            uint64_t word0 = *(uint64_t *)elementBase;
            uint64_t word1 = *(uint64_t *)(elementBase + 8);
            void *bridged = bridge(word0, word1); // +1
            NSString *name = bridged ? (__bridge_transfer NSString *)bridged : nil;
            if (![name isKindOfClass:[NSString class]]) {
                ApolloLog(@"[FollowingSection] bridged element not a string — bailing");
                return nil;
            }
            [names addObject:name];
        }
        [sections addObject:names];
    }
    NSUInteger total = 0;
    for (NSArray<NSString *> *sectionNames in sections) total += sectionNames.count;
    ApolloLog(@"[FollowingSection] walked %lu subscription names across %lu sections",
              (unsigned long)total, (unsigned long)sections.count);
    return sections;
}

static BOOL ApolloFollowingNameIsFollowedUser(NSString *name) {
    if (name.length <= 2) return NO;
    NSString *lower = name.lowercaseString;
    // Apollo's subscription names carry followed users as "u/<name>" (verified
    // in-sim against a live account); Reddit's raw API form is "u_<name>" —
    // accept both so a format change upstream doesn't silently break this.
    return [lower hasPrefix:@"u/"] || [lower hasPrefix:@"u_"];
}

#pragma mark - The mapping

@interface ApolloFollowingEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger nativeSection;
@property (nonatomic) NSInteger nativeRow;
@end
@implementation ApolloFollowingEntry
@end

// One immutable snapshot of the visible<->native layout. Rebuilt lazily when
// the model pointer or the config generation changes, and dropped in the
// table's reloadData hook.
@interface ApolloFollowingMap : NSObject
@property (nonatomic) BOOL active;                        // remap engaged at all
@property (nonatomic) BOOL hasSyntheticSection;           // separation on
@property (nonatomic) uintptr_t modelWord;                // cache key
@property (nonatomic) NSInteger configGeneration;         // cache key
@property (nonatomic) NSInteger collationSectionCount;
// Special slots in visible order (values: native section numbers, or
// kApolloFollowingSyntheticSection). Count is 3 or 4.
@property (nonatomic, copy) NSArray<NSNumber *> *specialSlots;
// Per collation section (index 0 == native section 4): ascending native rows
// occupied by u_ entries.
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *hiddenRows;
// The u_ entries in the synthetic section's display order.
@property (nonatomic, copy) NSArray<ApolloFollowingEntry *> *entries;
// Full per-section names (native order) for name resolution during windows.
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *sectionNames;
@end
@implementation ApolloFollowingMap
@end

static char kApolloFollowingMapKey;

static ApolloFollowingMap *ApolloFollowingBuildMap(UIViewController *listVC) {
    ApolloFollowingMap *map = [ApolloFollowingMap new];
    map.configGeneration = sApolloFollowingConfigGeneration;
    map.modelWord = ApolloFollowingOuterStorageWord(listVC);
    map.active = NO;
    map.hasSyntheticSection = NO;

    if (!ApolloFollowingRemapWanted()) return map; // inert snapshot

    // The collation section count is structural (Apollo's numberOfSections is
    // ALWAYS collation.sectionTitles.count + 4, regardless of content), so it
    // comes from the collation itself — the model walk only supplies the u_
    // row positions.
    NSInteger collationCount = (NSInteger)[[[UILocalizedIndexedCollation currentCollation] sectionTitles] count];
    map.collationSectionCount = collationCount;

    NSArray<NSArray<NSString *> *> *sections = nil;
    if (sApolloFollowingSeparate) {
        sections = ApolloFollowingReadSectionedSubreddits(listVC);
        if (sections && (NSInteger)sections.count != collationCount) {
            ApolloLog(@"[FollowingSection] walked %lu sections but collation has %ld — ignoring walk",
                      (unsigned long)sections.count, (long)collationCount);
            sections = nil;
        }
        if (!sections && !ApolloFollowingRemapWantedWithoutSeparation()) {
            // Separation is the only reason to remap and the model is not
            // readable (or not built yet): stay inert rather than showing an
            // empty FOLLOWING section that can't be populated.
            return map;
        }
    }
    map.sectionNames = sections ?: @[];
    BOOL separationEffective = sApolloFollowingSeparate && sections != nil;

    // Find the u_ rows.
    NSMutableArray<NSArray<NSNumber *> *> *hidden = [NSMutableArray arrayWithCapacity:sections.count];
    NSMutableArray<ApolloFollowingEntry *> *found = [NSMutableArray array];
    for (NSUInteger c = 0; c < sections.count; c++) {
        NSMutableArray<NSNumber *> *rowsHere = [NSMutableArray array];
        NSArray<NSString *> *names = sections[c];
        for (NSUInteger r = 0; r < names.count; r++) {
            if (!separationEffective) break;
            if (ApolloFollowingNameIsFollowedUser(names[r])) {
                [rowsHere addObject:@(r)];
                ApolloFollowingEntry *entry = [ApolloFollowingEntry new];
                entry.name = names[r];
                entry.nativeSection = kApolloNativeSectionCollation + (NSInteger)c;
                entry.nativeRow = (NSInteger)r;
                [found addObject:entry];
            }
        }
        [hidden addObject:rowsHere];
    }
    map.hiddenRows = hidden;

    // Order the synthetic section: saved order first (case-insensitive name
    // match), then any new followed users in their natural (alphabetical)
    // order.
    NSArray<NSString *> *savedOrder = [[NSUserDefaults standardUserDefaults] stringArrayForKey:UDKeyFollowedUsersOrder];
    if (savedOrder.count > 0 && found.count > 1) {
        NSMutableDictionary<NSString *, NSNumber *> *position = [NSMutableDictionary dictionaryWithCapacity:savedOrder.count];
        for (NSUInteger i = 0; i < savedOrder.count; i++) {
            position[savedOrder[i].lowercaseString] = @(i);
        }
        NSUInteger naturalBase = savedOrder.count;
        NSArray<ApolloFollowingEntry *> *natural = [found copy];
        [found sortUsingComparator:^NSComparisonResult(ApolloFollowingEntry *a, ApolloFollowingEntry *b) {
            NSNumber *pa = position[a.name.lowercaseString];
            NSNumber *pb = position[b.name.lowercaseString];
            NSUInteger ia = pa ? pa.unsignedIntegerValue : naturalBase + [natural indexOfObjectIdenticalTo:a];
            NSUInteger ib = pb ? pb.unsignedIntegerValue : naturalBase + [natural indexOfObjectIdenticalTo:b];
            if (ia == ib) return NSOrderedSame;
            return ia < ib ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    map.entries = found;

    // Special slots in the user's order.
    NSMutableArray<NSNumber *> *slots = [NSMutableArray arrayWithCapacity:4];
    for (NSString *token in sApolloSectionOrderTokens) {
        if ([token isEqualToString:kApolloSectionTokenFavorites]) {
            [slots addObject:@(kApolloNativeSectionFavorites)];
        } else if ([token isEqualToString:kApolloSectionTokenMultireddit]) {
            [slots addObject:@(kApolloNativeSectionMultireddit)];
        } else if ([token isEqualToString:kApolloSectionTokenModerator]) {
            [slots addObject:@(kApolloNativeSectionModerator)];
        } else if ([token isEqualToString:kApolloSectionTokenFollowing]) {
            if (separationEffective) [slots addObject:@(kApolloFollowingSyntheticSection)];
        }
    }
    map.specialSlots = slots;
    map.hasSyntheticSection = [slots containsObject:@(kApolloFollowingSyntheticSection)];
    map.active = YES;
    return map;
}

// The current mapping for a list VC, rebuilt when stale. Main-thread only
// (all callers are table dataSource/delegate paths or main-queue observers).
static ApolloFollowingMap *ApolloFollowingMapFor(UIViewController *listVC) {
    ApolloFollowingMap *map = objc_getAssociatedObject(listVC, &kApolloFollowingMapKey);
    uintptr_t currentWord = ApolloFollowingOuterStorageWord(listVC);
    if (!map || map.modelWord != currentWord || map.configGeneration != sApolloFollowingConfigGeneration) {
        map = ApolloFollowingBuildMap(listVC);
        objc_setAssociatedObject(listVC, &kApolloFollowingMapKey, map, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (map.active) {
            ApolloLog(@"[FollowingSection] map rebuilt: %lu followed users, %lu special slots, %ld collation sections",
                      (unsigned long)map.entries.count, (unsigned long)map.specialSlots.count,
                      (long)map.collationSectionCount);
        }
    }
    return map;
}

static void ApolloFollowingInvalidateMap(UIViewController *listVC) {
    if (listVC) objc_setAssociatedObject(listVC, &kApolloFollowingMapKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Translation primitives

// visible section -> native section (or synthetic marker / NSNotFound).
static NSInteger ApolloFollowingNativeSectionForVisible(ApolloFollowingMap *map, NSInteger visibleSection) {
    if (visibleSection == 0) return 0;
    NSInteger specials = (NSInteger)map.specialSlots.count;
    if (visibleSection <= specials) return map.specialSlots[(NSUInteger)(visibleSection - 1)].integerValue;
    NSInteger collationIndex = visibleSection - 1 - specials;
    if (collationIndex < 0 || collationIndex >= map.collationSectionCount) return NSNotFound;
    return kApolloNativeSectionCollation + collationIndex;
}

// native section -> visible section (synthetic marker allowed as input).
static NSInteger ApolloFollowingVisibleSectionForNative(ApolloFollowingMap *map, NSInteger nativeSection) {
    if (nativeSection == 0) return 0;
    NSUInteger slotIdx = [map.specialSlots indexOfObject:@(nativeSection)];
    if (slotIdx != NSNotFound) return 1 + (NSInteger)slotIdx;
    if (nativeSection >= kApolloNativeSectionCollation) {
        return 1 + (NSInteger)map.specialSlots.count + (nativeSection - kApolloNativeSectionCollation);
    }
    return NSNotFound;
}

static NSInteger ApolloFollowingSyntheticVisibleSection(ApolloFollowingMap *map) {
    return ApolloFollowingVisibleSectionForNative(map, kApolloFollowingSyntheticSection);
}

// Hidden-row bookkeeping for one collation section (index relative to native 4).
static NSArray<NSNumber *> *ApolloFollowingHiddenRowsForNative(ApolloFollowingMap *map, NSInteger nativeSection) {
    NSInteger idx = nativeSection - kApolloNativeSectionCollation;
    if (idx < 0 || idx >= (NSInteger)map.hiddenRows.count) return @[];
    return map.hiddenRows[(NSUInteger)idx];
}

static NSInteger ApolloFollowingNativeRowForVisible(ApolloFollowingMap *map, NSInteger nativeSection, NSInteger visibleRow) {
    NSInteger nativeRow = visibleRow;
    for (NSNumber *hidden in ApolloFollowingHiddenRowsForNative(map, nativeSection)) {
        if (hidden.integerValue <= nativeRow) nativeRow++;
        else break;
    }
    return nativeRow;
}

static NSInteger ApolloFollowingVisibleRowForNative(ApolloFollowingMap *map, NSInteger nativeSection, NSInteger nativeRow) {
    NSInteger below = 0;
    for (NSNumber *hidden in ApolloFollowingHiddenRowsForNative(map, nativeSection)) {
        if (hidden.integerValue < nativeRow) below++;
        else break;
    }
    return nativeRow - below;
}

// visible path -> native path. nil when the visible path has no native
// equivalent (never expected for on-screen rows; callers guard).
static NSIndexPath *ApolloFollowingNativePathForVisible(ApolloFollowingMap *map, NSIndexPath *visiblePath) {
    if (!visiblePath) return nil;
    NSInteger nativeSection = ApolloFollowingNativeSectionForVisible(map, visiblePath.section);
    if (nativeSection == NSNotFound) return nil;
    if (nativeSection == kApolloFollowingSyntheticSection) {
        if (visiblePath.row < 0 || visiblePath.row >= (NSInteger)map.entries.count) return nil;
        ApolloFollowingEntry *entry = map.entries[(NSUInteger)visiblePath.row];
        return [NSIndexPath indexPathForRow:entry.nativeRow inSection:entry.nativeSection];
    }
    if (nativeSection >= kApolloNativeSectionCollation) {
        return [NSIndexPath indexPathForRow:ApolloFollowingNativeRowForVisible(map, nativeSection, visiblePath.row)
                                  inSection:nativeSection];
    }
    return [NSIndexPath indexPathForRow:visiblePath.row inSection:nativeSection];
}

// native path -> visible path. u_ rows resolve into the synthetic section.
static NSIndexPath *ApolloFollowingVisiblePathForNative(ApolloFollowingMap *map, NSIndexPath *nativePath) {
    if (!nativePath) return nil;
    NSInteger nativeSection = nativePath.section;
    if (nativeSection >= kApolloNativeSectionCollation) {
        NSArray<NSNumber *> *hidden = ApolloFollowingHiddenRowsForNative(map, nativeSection);
        if ([hidden containsObject:@(nativePath.row)]) {
            // A u_ row: locate it in the synthetic section.
            for (NSUInteger i = 0; i < map.entries.count; i++) {
                ApolloFollowingEntry *entry = map.entries[i];
                if (entry.nativeSection == nativeSection && entry.nativeRow == nativePath.row) {
                    return [NSIndexPath indexPathForRow:(NSInteger)i
                                              inSection:ApolloFollowingSyntheticVisibleSection(map)];
                }
            }
            return nil;
        }
        NSInteger visibleSection = ApolloFollowingVisibleSectionForNative(map, nativeSection);
        if (visibleSection == NSNotFound) return nil;
        return [NSIndexPath indexPathForRow:ApolloFollowingVisibleRowForNative(map, nativeSection, nativePath.row)
                                  inSection:visibleSection];
    }
    NSInteger visibleSection = ApolloFollowingVisibleSectionForNative(map, nativeSection);
    if (visibleSection == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:nativePath.row inSection:visibleSection];
}

// YES when a collation section still has native rows but every one of them is
// a u_ entry claimed by the FOLLOWING section — its header must collapse.
static BOOL ApolloFollowingCollationSectionCollapsed(ApolloFollowingMap *map, NSInteger nativeSection) {
    NSInteger idx = nativeSection - kApolloNativeSectionCollation;
    if (idx < 0 || idx >= (NSInteger)map.sectionNames.count) return NO;
    NSInteger total = (NSInteger)[map.sectionNames[(NSUInteger)idx] count];
    NSInteger hidden = (NSInteger)ApolloFollowingHiddenRowsForNative(map, nativeSection).count;
    return total > 0 && total - hidden <= 0;
}

// Name shown for / stored under a native path, for the favorite-delete row
// convergence. Only needs favorites + collation coverage.
static NSString *ApolloFollowingNameAtNativePath(ApolloFollowingMap *map, NSIndexPath *nativePath) {
    if (!nativePath) return nil;
    if (nativePath.section == kApolloNativeSectionFavorites) {
        NSArray *favorites = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"FavoriteSubreddits"];
        if (nativePath.row >= 0 && nativePath.row < (NSInteger)favorites.count) return favorites[(NSUInteger)nativePath.row];
        return nil;
    }
    NSInteger collationIdx = nativePath.section - kApolloNativeSectionCollation;
    if (collationIdx >= 0 && collationIdx < (NSInteger)map.sectionNames.count) {
        NSArray<NSString *> *names = map.sectionNames[(NSUInteger)collationIdx];
        if (nativePath.row >= 0 && nativePath.row < (NSInteger)names.count) return names[(NSUInteger)nativePath.row];
    }
    return nil;
}

#pragma mark - Shared state

static Class sApolloRedditListClass = Nil;

// The most recent live list VC/table (there is one Subreddits screen; keep it
// weakly so config changes can refresh it).
static __weak UIViewController *sApolloFollowingListVC = nil;

// Point window: open while favoriteSubredditButtonTapped: /
// multiredditExpandButtonTapped: run, so indexPathForRowAtPoint: and the
// imperative row mutations translate. Main-thread-only state (both handlers
// are UI callbacks and do their table work synchronously).
static NSUInteger sApolloFollowingWindowDepth = 0;
static __unsafe_unretained UITableView *sApolloFollowingWindowTable = nil;
static NSString *sApolloFollowingWindowTappedName = nil;    // resolved on translate
static NSArray<NSString *> *sApolloFollowingWindowFavorites = nil; // pre-mutation favorites

static BOOL ApolloFollowingTableIsList(UITableView *tableView) {
    if (!tableView || !sApolloRedditListClass) return NO;
    id dataSource = tableView.dataSource;
    return [dataSource isKindOfClass:sApolloRedditListClass];
}

// Whether a return address lies inside the Apollo main executable's __TEXT
// segment. Apollo's own code only ever addresses this table in its NATIVE
// (model) index space — including from async completions like the subreddit
// icon download check, which look the cell up by the index path captured at
// configure time. Everything else (UIKit, this tweak's other modules) speaks
// the VISIBLE layout. The caller's image is therefore the translation
// discriminator for the UITableView-level hooks below.
static BOOL ApolloFollowingCallerIsApolloBinary(void *returnAddress) {
    static uintptr_t textStart = 0;
    static uintptr_t textEnd = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!header || header->filetype != MH_EXECUTE) continue;
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            const struct load_command *cmd = (const struct load_command *)(header + 1);
            for (uint32_t c = 0; c < header->ncmds; c++) {
                if (cmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segment = (const struct segment_command_64 *)cmd;
                    if (strcmp(segment->segname, SEG_TEXT) == 0) {
                        textStart = (uintptr_t)(segment->vmaddr + (uintptr_t)slide);
                        textEnd = textStart + (uintptr_t)segment->vmsize;
                        break;
                    }
                }
                cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
            }
            break;
        }
        ApolloLog(@"[FollowingSection] Apollo __TEXT range 0x%lx..0x%lx", (unsigned long)textStart, (unsigned long)textEnd);
    });
    uintptr_t addr = (uintptr_t)returnAddress;
    return textStart != 0 && addr >= textStart && addr < textEnd;
}

static ApolloFollowingMap *ApolloFollowingActiveMapForTable(UITableView *tableView);

// The list VC's table. ApolloTableViewController's `tableView` is a Swift
// stored property with no guaranteed ObjC getter, but ObjC-class-typed Swift
// stored properties are real runtime ivars — read it that way (same approach
// as ApolloHideModSubreddits/ApolloMultiredditEdit).
static UITableView *ApolloFollowingTableViewOf(UIViewController *listVC) {
    if (!listVC) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(listVC), "tableView");
    UITableView *tableView = ivar ? object_getIvar(listVC, ivar) : nil;
    return [tableView isKindOfClass:[UITableView class]] ? tableView : nil;
}

// Remap-awareness bridge for ApolloHideModSubreddits / ApolloMultiredditEdit —
// see ApolloFollowingSection.h.
NSString *ApolloFollowingCanonicalTitleForNativeSection(UITableView *tableView, NSInteger nativeSection) {
    ApolloFollowingMap *map = ApolloFollowingActiveMapForTable(tableView);
    if (!map) return nil;
    switch (nativeSection) {
        case kApolloNativeSectionFavorites:   return @"FAVORITES";
        case kApolloNativeSectionMultireddit: return @"MULTIREDDITS";
        case kApolloNativeSectionModerator:   return @"MODERATOR";
        default:                              return @"";
    }
}

static ApolloFollowingMap *ApolloFollowingActiveMapForTable(UITableView *tableView) {
    if (!ApolloFollowingTableIsList(tableView)) return nil;
    UIViewController *vc = (UIViewController *)tableView.dataSource;
    ApolloFollowingMap *map = ApolloFollowingMapFor(vc);
    return map.active ? map : nil;
}

// The mapping the table is CURRENTLY PRESENTING — the associated snapshot,
// deliberately NOT rebuilt even if Apollo's model has since changed. UIKit's
// batch-update contract wants delete/reload paths in the PRE-update layout;
// Apollo's animated unsubscribe (sub_100643894: remove name -> rebuild
// sectionedSubreddits -> beginUpdates/deleteRows/endUpdates) mutates the model
// BEFORE registering the delete, so a fresh map here would already be
// post-update and mistranslate the outgoing row (the device crash behind this:
// UITableView's Invalid_Number_Of_Rows_In_Section assertion).
static ApolloFollowingMap *ApolloFollowingPresentedMapForTable(UITableView *tableView) {
    if (!ApolloFollowingTableIsList(tableView)) return nil;
    UIViewController *vc = (UIViewController *)tableView.dataSource;
    ApolloFollowingMap *map = objc_getAssociatedObject(vc, &kApolloFollowingMapKey);
    if (!map) map = ApolloFollowingMapFor(vc); // nothing presented yet
    return map.active ? map : nil;
}

#pragma mark - The list VC hooks

%group ApolloFollowingList

%hook RedditListViewController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    sApolloFollowingListVC = (UIViewController *)self;
    NSInteger native = %orig;
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return native;
    return map.hasSyntheticSection ? native + 1 : native;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSInteger nativeSection = ApolloFollowingNativeSectionForVisible(map, section);
    if (nativeSection == kApolloFollowingSyntheticSection) return (NSInteger)map.entries.count;
    if (nativeSection == NSNotFound) return 0;
    NSInteger nativeCount = %orig(tableView, nativeSection);
    if (nativeSection >= kApolloNativeSectionCollation) {
        NSInteger hiddenCount = (NSInteger)ApolloFollowingHiddenRowsForNative(map, nativeSection).count;
        NSInteger visibleCount = nativeCount - hiddenCount;
        if (visibleCount < 0) {
            // Stale mapping (model shrank without a reload reaching us yet).
            ApolloLog(@"[FollowingSection] negative visible count in native %ld — clamping", (long)nativeSection);
            visibleCount = 0;
        }
        return visibleCount;
    }
    return nativeCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) {
        ApolloLog(@"[FollowingSection] cellForRow: no native path for %ld/%ld", (long)indexPath.section, (long)indexPath.row);
        return %orig; // fail soft: let Apollo interpret the visible path
    }
    return %orig(tableView, nativePath);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSInteger nativeSection = ApolloFollowingNativeSectionForVisible(map, section);
    if (nativeSection == kApolloFollowingSyntheticSection) {
        if (map.entries.count == 0) return 0.0;
        // Borrow the height Apollo uses for the first entry's own (non-empty)
        // native section, so the band matches every other section exactly.
        return %orig(tableView, map.entries.firstObject.nativeSection);
    }
    if (nativeSection == NSNotFound) return 0.0;
    // A collation section whose only rows were u_ entries must fully collapse
    // even though Apollo still counts its native rows.
    if (ApolloFollowingCollationSectionCollapsed(map, nativeSection)) return 0.0;
    return %orig(tableView, nativeSection);
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSInteger nativeSection = ApolloFollowingNativeSectionForVisible(map, section);
    if (nativeSection == kApolloFollowingSyntheticSection) {
        if (map.entries.count == 0) return nil;
        // Donor trick: MODERATOR (native 3) always yields a fully-styled
        // RecreatedTableSectionHeaderView regardless of its row count (its
        // title is unconditional), so build one and retitle it. The class's
        // sizeThatFits:/layoutSubviews only consult the label, so setting the
        // label text and re-fitting is sufficient.
        UIView *header = %orig(tableView, kApolloNativeSectionModerator);
        if (!header) return nil;
        Ivar labelIvar = class_getInstanceVariable(object_getClass(header), "label");
        UILabel *label = labelIvar ? object_getIvar(header, labelIvar) : nil;
        if ([label isKindOfClass:[UILabel class]]) {
            label.text = @"FOLLOWING";
            [header sizeToFit];
        } else {
            ApolloLog(@"[FollowingSection] donor header label not found (class %@)", NSStringFromClass(object_getClass(header)));
        }
        return header;
    }
    if (nativeSection == NSNotFound) return nil;
    if (ApolloFollowingCollationSectionCollapsed(map, nativeSection)) return nil;
    return %orig(tableView, nativeSection);
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView {
    NSArray *native = %orig;
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active || native.count < 4) return native;
    // native[0..3] are the four special glyphs, native[4..] the letters.
    NSMutableArray *titles = [NSMutableArray arrayWithCapacity:native.count + 1];
    [titles addObject:native[0]];
    for (NSNumber *slot in map.specialSlots) {
        NSInteger nativeSection = slot.integerValue;
        if (nativeSection == kApolloFollowingSyntheticSection) {
            [titles addObject:@"@"]; // the FOLLOWING scrub glyph
        } else if (nativeSection >= 1 && nativeSection <= 3) {
            [titles addObject:native[(NSUInteger)nativeSection]];
        }
    }
    [titles addObjectsFromArray:[native subarrayWithRange:NSMakeRange(4, native.count - 4)]];
    return titles;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    // While the remap is engaged this answer is computed directly in visible
    // space rather than via %orig. The native implementation has a
    // preventSectionIndexTitlesFromWorking veto that answers NSNotFound and
    // schedules a deferred scroll 100ms later — and that deferred scroll
    // targets NATIVE section numbers straight on the table, which would land
    // on the wrong visible section under the remap. The custom index overlay
    // (ApolloSubredditIndexPolish) scrolls synchronously from this return
    // value, so a direct visible-space answer is both correct and simpler.
    NSInteger specials = (NSInteger)map.specialSlots.count;
    if (index <= 0) return 0;
    if (index <= specials) return index; // visible slots 1..K, in display order
    NSInteger letterOrdinal = index - specials - 1;
    if (letterOrdinal >= map.collationSectionCount) return NSNotFound;
    return 1 + specials + letterOrdinal;
}

// ---- Row-level methods: pure path translation --------------------------------

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) { %orig; return; }
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    ApolloLog(@"[FollowingSection] didSelect visible %ld/%ld -> native %ld/%ld",
              (long)indexPath.section, (long)indexPath.row,
              (long)(nativePath ? nativePath.section : -1), (long)(nativePath ? nativePath.row : -1));
    if (!nativePath) { %orig; return; }
    %orig(tableView, nativePath);
}

- (id)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) return %orig;
    return %orig(tableView, nativePath, point);
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) return %orig;
    return %orig(tableView, nativePath);
}

- (NSInteger)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) return %orig;
    return %orig(tableView, nativePath);
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) return %orig;
    return %orig(tableView, nativePath);
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) return %orig;
    return %orig(tableView, nativePath);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(NSInteger)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) { %orig; return; }
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) { %orig; return; }
    // Apollo's commit paths end in reloadData (never row animations), so the
    // translated native path is all that's needed here.
    %orig(tableView, editingStyle, nativePath);
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) { %orig; return; }
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) { %orig; return; }
    %orig(tableView, nativePath);
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active || !indexPath) { %orig; return; }
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) { %orig; return; }
    %orig(tableView, nativePath);
}

// ---- Reordering --------------------------------------------------------------

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSInteger nativeSection = ApolloFollowingNativeSectionForVisible(map, indexPath.section);
    if (nativeSection == kApolloFollowingSyntheticSection) return map.entries.count > 1;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, indexPath);
    if (!nativePath) return %orig;
    return %orig(tableView, nativePath);
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) return %orig;
    NSInteger sourceNativeSection = ApolloFollowingNativeSectionForVisible(map, sourceIndexPath.section);
    if (sourceNativeSection == kApolloFollowingSyntheticSection) {
        // Clamp within the synthetic section.
        if (proposedDestinationIndexPath.section == sourceIndexPath.section) return proposedDestinationIndexPath;
        NSInteger row = proposedDestinationIndexPath.section < sourceIndexPath.section ? 0 : MAX((NSInteger)map.entries.count - 1, 0);
        return [NSIndexPath indexPathForRow:row inSection:sourceIndexPath.section];
    }
    NSIndexPath *nativeSource = ApolloFollowingNativePathForVisible(map, sourceIndexPath);
    NSIndexPath *nativeProposed = ApolloFollowingNativePathForVisible(map, proposedDestinationIndexPath);
    if (!nativeSource || !nativeProposed) return %orig;
    NSIndexPath *nativeResult = %orig(tableView, nativeSource, nativeProposed);
    NSIndexPath *visibleResult = ApolloFollowingVisiblePathForNative(map, nativeResult);
    return visibleResult ?: proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
    ApolloFollowingMap *map = ApolloFollowingMapFor((UIViewController *)self);
    if (!map.active) { %orig; return; }
    NSInteger fromNativeSection = ApolloFollowingNativeSectionForVisible(map, fromIndexPath.section);
    if (fromNativeSection == kApolloFollowingSyntheticSection) {
        // A reorder inside the FOLLOWING section: persist the new order and
        // update the live snapshot in place (UIKit has already moved the row —
        // no reload needed, and the model pointer hasn't changed).
        NSInteger fromRow = fromIndexPath.row;
        NSInteger toRow = toIndexPath.row;
        if (fromRow < 0 || fromRow >= (NSInteger)map.entries.count ||
            toRow < 0 || toRow >= (NSInteger)map.entries.count || fromRow == toRow) return;
        NSMutableArray<ApolloFollowingEntry *> *entries = [map.entries mutableCopy];
        ApolloFollowingEntry *moved = entries[(NSUInteger)fromRow];
        [entries removeObjectAtIndex:(NSUInteger)fromRow];
        [entries insertObject:moved atIndex:(NSUInteger)toRow];
        map.entries = entries;
        NSMutableArray<NSString *> *order = [NSMutableArray arrayWithCapacity:entries.count];
        for (ApolloFollowingEntry *entry in entries) [order addObject:entry.name];
        [[NSUserDefaults standardUserDefaults] setObject:order forKey:UDKeyFollowedUsersOrder];
        ApolloLog(@"[FollowingSection] reordered following: %@ -> row %ld", moved.name, (long)toRow);
        return;
    }
    NSIndexPath *nativeFrom = ApolloFollowingNativePathForVisible(map, fromIndexPath);
    NSIndexPath *nativeTo = ApolloFollowingNativePathForVisible(map, toIndexPath);
    if (!nativeFrom || !nativeTo) { %orig; return; }
    %orig(tableView, nativeFrom, nativeTo);
}

// ---- The point-window handlers ----------------------------------------------

- (void)favoriteSubredditButtonTapped:(id)sender {
    UITableView *tableView = ApolloFollowingTableViewOf((UIViewController *)self);
    ApolloFollowingMap *map = tableView ? ApolloFollowingActiveMapForTable(tableView) : nil;
    if (!map) { %orig; return; }
    sApolloFollowingWindowDepth++;
    sApolloFollowingWindowTable = tableView;
    sApolloFollowingWindowTappedName = nil;
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] stringArrayForKey:@"FavoriteSubreddits"];
    sApolloFollowingWindowFavorites = [favorites isKindOfClass:[NSArray class]] ? favorites : @[];
    %orig;
    if (sApolloFollowingWindowDepth > 0) sApolloFollowingWindowDepth--;
    if (sApolloFollowingWindowDepth == 0) {
        sApolloFollowingWindowTable = nil;
        sApolloFollowingWindowTappedName = nil;
        sApolloFollowingWindowFavorites = nil;
    }
}

- (void)multiredditExpandButtonTapped:(id)sender {
    UITableView *tableView = ApolloFollowingTableViewOf((UIViewController *)self);
    ApolloFollowingMap *map = tableView ? ApolloFollowingActiveMapForTable(tableView) : nil;
    if (!map) { %orig; return; }
    sApolloFollowingWindowDepth++;
    sApolloFollowingWindowTable = tableView;
    %orig;
    if (sApolloFollowingWindowDepth > 0) sApolloFollowingWindowDepth--;
    if (sApolloFollowingWindowDepth == 0) {
        sApolloFollowingWindowTable = nil;
        sApolloFollowingWindowTappedName = nil;
        sApolloFollowingWindowFavorites = nil;
    }
}

%end

%end // group ApolloFollowingList

#pragma mark - UITableView hooks (scoped to the list's table)

%group ApolloFollowingTable

%hook UITableView

- (void)reloadData {
    if (ApolloFollowingTableIsList((UITableView *)self)) {
        // Invalidate BEFORE %orig so the re-query sees a fresh mapping.
        ApolloFollowingInvalidateMap((UIViewController *)((UITableView *)self).dataSource);
    }
    %orig;
}

- (NSIndexPath *)indexPathForRowAtPoint:(CGPoint)point {
    NSIndexPath *visible = %orig;
    void *caller = __builtin_return_address(0);
    BOOL windowActive = sApolloFollowingWindowDepth > 0 && (UITableView *)self == sApolloFollowingWindowTable;
    if (!windowActive && !ApolloFollowingCallerIsApolloBinary(caller)) return visible;
    ApolloFollowingMap *map = ApolloFollowingActiveMapForTable((UITableView *)self);
    if (!map || !visible) return visible;
    NSIndexPath *nativePath = ApolloFollowingNativePathForVisible(map, visible);
    if (!nativePath) return visible;
    // Remember the tapped name for the favorite-delete row convergence.
    if (windowActive) sApolloFollowingWindowTappedName = ApolloFollowingNameAtNativePath(map, nativePath);
    if (nativePath.section != visible.section || nativePath.row != visible.row) {
        ApolloLog(@"[FollowingSection] point translate %ld/%ld -> %ld/%ld (%@)",
                  (long)visible.section, (long)visible.row,
                  (long)nativePath.section, (long)nativePath.row,
                  ApolloFollowingNameAtNativePath(map, nativePath) ?: @"?");
    }
    return nativePath;
}

// Apollo's async subreddit-icon pipeline captures a (native) index path when a
// cell is configured and, when the download check completes, looks the cell up
// with -cellForRowAtIndexPath: to paint the icon. Translate that lookup so
// icons land on the right visible rows. Only Apollo's own calls are model
// space — UIKit and this tweak's other modules pass visible paths.
- (UITableViewCell *)cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    void *caller = __builtin_return_address(0);
    if (!ApolloFollowingCallerIsApolloBinary(caller)) return %orig;
    ApolloFollowingMap *map = ApolloFollowingActiveMapForTable((UITableView *)self);
    if (!map || !indexPath) return %orig;
    NSIndexPath *visible = ApolloFollowingVisiblePathForNative(map, indexPath);
    if (!visible) return %orig;
    if (visible.section != indexPath.section || visible.row != indexPath.row) {
        ApolloLog(@"[FollowingSection] cell lookup native %ld/%ld -> visible %ld/%ld (caller %p)",
                  (long)indexPath.section, (long)indexPath.row, (long)visible.section, (long)visible.row, caller);
    }
    return %orig(visible);
}

// Translate Apollo's model-space row mutations back into visible space. Apollo
// registers these both synchronously inside the point windows (favorite star,
// multireddit expand) and from dispatched blocks: the animated unsubscribe /
// unfollow (sub_100643894) removes the name from subscribedSubreddits,
// REBUILDS sectionedSubreddits, then runs beginUpdates / deleteRows(passed
// path) / endUpdates on the main queue.
//
// Per UIKit's batch-update contract, DELETE and RELOAD paths are interpreted
// against the PRE-update layout — so they translate through the PRESENTED map
// (never rebuilt here, even though Apollo has already swapped its model; a
// fresh map no longer contains the removed row and mistranslates it, which is
// what crashed the 2026-08-25 device build with UITableView's
// Invalid_Number_Of_Rows_In_Section assertion when unfollowing from the list).
// After registering a delete the presented snapshot is dropped so endUpdates'
// row-count queries rebuild from the fresh model. INSERT paths speak the
// POST-update layout and rebuild first (below).
//
// For the star window's single-row favorites delete, the row is additionally
// recomputed from the tapped name against the pre-mutation favorites snapshot —
// the same answer ApolloSubredditIndexPolish's off-by-one correction produces,
// so the two hooks converge in either install order.
- (void)deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    // No caller gate here (unlike the lookup hooks above): row mutations on
    // this table only ever ORIGINATE in Apollo's model-space code — UIKit
    // never self-registers them and the tweak's other modules only rewrite
    // in-flight paths — and the originating call can reach us through another
    // module's hook on the same selector, which would defeat a return-address
    // check (it did: the unfollow crash fix below never engaged behind
    // ApolloSubredditIndexPolish's outer deleteRows hook).
    BOOL windowActive = sApolloFollowingWindowDepth > 0 && (UITableView *)self == sApolloFollowingWindowTable;
    ApolloFollowingMap *map = ApolloFollowingPresentedMapForTable((UITableView *)self);
    if (!map) { %orig; return; }
    NSMutableArray<NSIndexPath *> *translated = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSIndexPath *nativePath in indexPaths) {
        NSIndexPath *effectiveNative = nativePath;
        if (windowActive &&
            nativePath.section == kApolloNativeSectionFavorites &&
            indexPaths.count == 1 &&
            sApolloFollowingWindowTappedName.length > 0) {
            NSUInteger correctRow = NSNotFound;
            NSArray<NSString *> *preFavorites = sApolloFollowingWindowFavorites;
            correctRow = [preFavorites indexOfObject:sApolloFollowingWindowTappedName];
            if (correctRow == NSNotFound) {
                for (NSUInteger i = 0; i < preFavorites.count; i++) {
                    if ([preFavorites[i] caseInsensitiveCompare:sApolloFollowingWindowTappedName] == NSOrderedSame) { correctRow = i; break; }
                }
            }
            if (correctRow != NSNotFound && (NSInteger)correctRow != nativePath.row) {
                ApolloLog(@"[FollowingSection] favorite delete row %ld -> %lu (%@)",
                          (long)nativePath.row, (unsigned long)correctRow, sApolloFollowingWindowTappedName);
                effectiveNative = [NSIndexPath indexPathForRow:(NSInteger)correctRow inSection:kApolloNativeSectionFavorites];
            }
        }
        NSIndexPath *visible = ApolloFollowingVisiblePathForNative(map, effectiveNative);
        if (visible && (visible.section != effectiveNative.section || visible.row != effectiveNative.row)) {
            ApolloLog(@"[FollowingSection] delete translate %ld/%ld -> %ld/%ld",
                      (long)effectiveNative.section, (long)effectiveNative.row,
                      (long)visible.section, (long)visible.row);
        }
        [translated addObject:visible ?: effectiveNative];
    }
    // The model behind this delete may already be post-update — drop the
    // presented snapshot so endUpdates' count queries see the fresh state.
    ApolloFollowingInvalidateMap((UIViewController *)((UITableView *)self).dataSource);
    %orig(translated, animation);
}

- (void)insertRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    if (!ApolloFollowingTableIsList((UITableView *)self)) { %orig; return; }
    // Inserts speak the POST-update layout: rebuild from the current model
    // first (Apollo mutates its model before registering the animation), so a
    // newly added u/ profile resolves straight into the FOLLOWING section and
    // collation rows get the compressed row index of the fresh layout.
    ApolloFollowingInvalidateMap((UIViewController *)((UITableView *)self).dataSource);
    ApolloFollowingMap *map = ApolloFollowingActiveMapForTable((UITableView *)self);
    if (!map) { %orig; return; }
    NSMutableArray<NSIndexPath *> *translated = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSIndexPath *nativePath in indexPaths) {
        NSIndexPath *visible = ApolloFollowingVisiblePathForNative(map, nativePath);
        if (visible && (visible.section != nativePath.section || visible.row != nativePath.row)) {
            ApolloLog(@"[FollowingSection] insert translate %ld/%ld -> %ld/%ld",
                      (long)nativePath.section, (long)nativePath.row,
                      (long)visible.section, (long)visible.row);
        }
        [translated addObject:visible ?: nativePath];
    }
    %orig(translated, animation);
}

- (void)reloadRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    // Only Apollo's own reloads carry model-space paths. The tweak's other
    // modules pass visible ones (ApolloSubredditIndexPolish's delayed star
    // refresh reloads the rows it found via indexPathForCell:), so gate the
    // translation the same way indexPathForRowAtPoint: does. The return
    // address is a safe discriminator on this selector: this module's
    // constructor runs last, so its hook is the outermost one here and %orig
    // only descends into ApolloSwipeUpComments' pass-through. The point
    // windows remain the fallback for Apollo's synchronous star/expand reloads.
    BOOL windowActive = sApolloFollowingWindowDepth > 0 && (UITableView *)self == sApolloFollowingWindowTable;
    if (!windowActive && !ApolloFollowingCallerIsApolloBinary(__builtin_return_address(0))) { %orig; return; }
    ApolloFollowingMap *map = ApolloFollowingPresentedMapForTable((UITableView *)self);
    if (!map) { %orig; return; }
    NSMutableArray<NSIndexPath *> *translated = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSIndexPath *nativePath in indexPaths) {
        NSIndexPath *visible = ApolloFollowingVisiblePathForNative(map, nativePath);
        if (visible && (visible.section != nativePath.section || visible.row != nativePath.row)) {
            ApolloLog(@"[FollowingSection] reload translate %ld/%ld -> %ld/%ld",
                      (long)nativePath.section, (long)nativePath.row,
                      (long)visible.section, (long)visible.row);
        }
        [translated addObject:visible ?: nativePath];
    }
    %orig(translated, animation);
}

%end

%end // group ApolloFollowingTable

#pragma mark - Settings changes

static void ApolloFollowingSettingsChanged(void) {
    ApolloFollowingReloadConfig();
    UIViewController *listVC = sApolloFollowingListVC;
    if (!listVC) return;
    ApolloFollowingInvalidateMap(listVC);
    UITableView *tableView = ApolloFollowingTableViewOf(listVC);
    if (tableView) {
        [tableView reloadData];
        ApolloLog(@"[FollowingSection] settings changed — list reloaded");
    }
}

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        sApolloRedditListClass = objc_getClass("_TtC6Apollo24RedditListViewController");
        if (!sApolloRedditListClass) {
            ApolloLog(@"[FollowingSection] RedditListViewController class missing — module inactive");
            return;
        }
        ApolloFollowingReloadConfig();
        %init(ApolloFollowingList, RedditListViewController = sApolloRedditListClass);
        %init(ApolloFollowingTable);
        [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditSectionsChangedNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            ApolloFollowingSettingsChanged();
        }];
        ApolloLog(@"[FollowingSection] hooks installed (separate=%d, order=%@)",
                  sApolloFollowingSeparate, [sApolloSectionOrderTokens componentsJoinedByString:@","]);
    }
}
