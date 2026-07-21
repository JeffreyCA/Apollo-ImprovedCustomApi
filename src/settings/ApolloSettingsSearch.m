#import "settings/ApolloSettingsSearch.h"

#import <objc/runtime.h>
#import <string.h>

#import "ApolloCommon.h"
#import "settings/ApolloSettingsForm.h"
#import "settings/ApolloSettingsRouter.h"
#import "settings/ApolloSettingsSearchNativeIndex.h"
#import "settings/ApolloSettingsTableViewController.h"

#pragma mark - Entry model

// One searchable row. Exactly one of routeId/nativePath is set:
//  - routeId: a Reborn screen (push via the route registry); rowTitle, when
//    set, is the row to scroll to and flash after the push.
//  - nativePath: labels of the rows to tap through from the Settings root
//    (empty = the root itself); rowTitle is the final row, either tapped
//    (pushesFinalRow, i.e. it discloses a screen) or scrolled to and flashed.
@interface ApolloSettingsSearchEntry : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *breadcrumb;
@property (nonatomic, copy) NSString *routeId;
@property (nonatomic, copy) NSArray<NSString *> *nativePath;
@property (nonatomic, copy) NSString *rowTitle;
@property (nonatomic, assign) BOOL pushesFinalRow;
// Native-style icon tile shown at the leading edge of the result row. Captured
// live from the real cell where the row has one, else inherited from the
// parent screen (see the icon resolution pass in the index build).
@property (nonatomic, strong) UIImage *iconImage;
@end

@implementation ApolloSettingsSearchEntry
@end

#pragma mark - Table scanning helpers

// First UILabel text in a view tree (fallback for custom cells whose title
// doesn't live in textLabel).
static NSString *ApolloSearchFirstLabelText(UIView *view) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            NSString *text = ((UILabel *)sub).text;
            if (text.length > 0) return text;
        }
        NSString *nested = ApolloSearchFirstLabelText(sub);
        if (nested) return nested;
    }
    return nil;
}

static NSString *ApolloSearchTitleOfCell(UITableViewCell *cell) {
    NSString *title = cell.textLabel.text;
    if (title.length > 0) return title;
    return ApolloSearchFirstLabelText(cell.contentView);
}

static UITableView *ApolloSearchTableInView(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *table = ApolloSearchTableInView(subview);
        if (table) return table;
    }
    return nil;
}

// The table view backing a settings screen: UITableViewController's own, a
// "tableView" ivar (the pattern Apollo's Swift VCs and ours both use), or the
// first UITableView anywhere in the view tree. Apollo's root table is nested
// under container views on newer UIKit, so checking direct children only made
// the search-results controller miss its theme donor and fall back to black.
static UITableView *ApolloSearchTableInViewController(UIViewController *vc) {
    if ([vc isKindOfClass:[UITableViewController class]]) return ((UITableViewController *)vc).tableView;
    Ivar ivar = class_getInstanceVariable([vc class], "tableView");
    if (ivar) {
        id value = object_getIvar(vc, ivar);
        if ([value isKindOfClass:[UITableView class]]) return value;
    }
    return ApolloSearchTableInView(vc.view);
}

// Visit every row the table's dataSource currently serves (display space, so
// remapped/hidden native rows and conditional form rows come out exactly as
// the user would see them).
static void ApolloSearchScanTable(UITableView *table,
                                  void (^visit)(NSIndexPath *indexPath, NSString *title, NSString *header, BOOL disclosure, UIImage *icon)) {
    id<UITableViewDataSource> dataSource = table.dataSource;
    if (!dataSource) return;

    NSInteger sections = 1;
    if ([dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
        sections = [dataSource numberOfSectionsInTableView:table];
    }
    for (NSInteger s = 0; s < sections; s++) {
        NSString *header = nil;
        if ([dataSource respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
            header = [dataSource tableView:table titleForHeaderInSection:s];
        }
        NSInteger rows = [dataSource tableView:table numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows; r++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:r inSection:s];
            UITableViewCell *cell = nil;
            @try {
                cell = [dataSource tableView:table cellForRowAtIndexPath:indexPath];
            } @catch (NSException *exception) {
                ApolloLog(@"[SettingsSearch] scan threw at %ld.%ld: %@", (long)s, (long)r, exception);
                continue;
            }
            if (!cell) continue;
            NSString *title = ApolloSearchTitleOfCell(cell);
            if (title.length == 0) continue;
            visit(indexPath, title, header, cell.accessoryType == UITableViewCellAccessoryDisclosureIndicator, cell.imageView.image);
        }
    }
}

// Find a row by its user-visible title, in display space. Trimmed,
// case-insensitive compare — labels sometimes carry stray whitespace.
static NSIndexPath *ApolloSearchFindRowTitled(UITableView *table, NSString *title) {
    __block NSIndexPath *found = nil;
    NSString *wanted = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    ApolloSearchScanTable(table, ^(NSIndexPath *indexPath, NSString *rowTitle, __unused NSString *header, __unused BOOL disclosure, __unused UIImage *icon) {
        if (found) return;
        NSString *trimmed = [rowTitle stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed compare:wanted options:NSCaseInsensitiveSearch] == NSOrderedSame) found = indexPath;
    });
    return found;
}

#pragma mark - Result icons

// Native settings sections aren't scanned live (they come from the static
// snapshot), so their icons are mapped here — mirroring Apollo's own root icons
// (ApolloRootSettingsIconForTitle) plus the Reborn hub — and rendered in the
// same tile style the Reborn cells use, so the result list reads as one set.
static UIImage *ApolloSearchMappedIconTile(NSString *title, UITraitCollection *traits) {
    static NSDictionary<NSString *, NSArray *> *map; // title.lower -> @[symbol, UIColor]
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"general":            @[ @"gearshape.fill",   UIColor.systemGrayColor ],
            @"appearance":         @[ @"paintbrush.fill",  UIColor.systemBlueColor ],
            @"notifications":      @[ @"bell.fill",        UIColor.systemRedColor ],
            @"passcode":           @[ @"lock.fill",        UIColor.systemPinkColor ],
            @"face id & passcode": @[ @"lock.fill",        UIColor.systemPinkColor ],
            @"filters & blocks":   @[ @"nosign",           UIColor.systemGreenColor ],
            @"gestures":           @[ @"hand.tap.fill",    UIColor.systemIndigoColor ],
            @"about":              @[ @"info.circle.fill", UIColor.systemGray2Color ],
            @"apollo ultra":       @[ @"star.circle.fill", UIColor.systemOrangeColor ],
            @"apollo reborn":      @[ @"key.fill",         UIColor.systemTealColor ],
        };
    });
    NSArray *meta = title.length ? map[title.lowercaseString] : nil;
    return meta ? ApolloSettingsIconTileImage(meta[0], meta[1], traits) : nil;
}

#pragma mark - Index build

static NSArray<ApolloSettingsSearchEntry *> *ApolloSettingsSearchBuildIndex(UITraitCollection *traits) {
    NSMutableArray<ApolloSettingsSearchEntry *> *entries = [NSMutableArray array];
    // title.lower -> the icon tile the row renders in the real settings UI,
    // captured live while scanning (covers every Reborn hub/screen row that has
    // one). Parent lookups resolve against this too.
    NSMutableDictionary<NSString *, UIImage *> *iconByTitle = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *registeredScreenTitles = [NSMutableSet set];
    for (NSString *routeId in ApolloSettingsRouteIds()) {
        NSString *title = ApolloSettingsRouteTitle(routeId).lowercaseString;
        if (title.length > 0) [registeredScreenTitles addObject:title];
    }

    // Reborn screens: scanned live so the index always reflects the rows a
    // user would actually find (conditional rows appear/disappear with their
    // flags). Instantiating + loading a screen runs its viewDidLoad, which for
    // these VCs is model construction plus at most a cache-priming request.
    for (NSString *routeId in ApolloSettingsRouteIds()) {
        NSString *screenTitle = ApolloSettingsRouteTitle(routeId);

        ApolloSettingsSearchEntry *screen = [[ApolloSettingsSearchEntry alloc] init];
        screen.title = screenTitle;
        screen.breadcrumb = ApolloSettingsRouteBreadcrumb(routeId) ?: @"Apollo Reborn";
        screen.routeId = routeId;
        [entries addObject:screen];

        UIViewController *vc = ApolloSettingsRouteInstantiate(routeId);
        @try {
            [vc loadViewIfNeeded];
        } @catch (NSException *exception) {
            ApolloLog(@"[SettingsSearch] load of '%@' threw: %@", routeId, exception);
            continue;
        }
        UITableView *table = ApolloSearchTableInViewController(vc);
        if (!table) continue;

        ApolloSearchScanTable(table, ^(__unused NSIndexPath *indexPath, NSString *title, NSString *header, BOOL disclosure, UIImage *icon) {
            // Record the row's real icon first — even for rows we won't add as
            // their own entry (a disclosure that's a registered destination),
            // because that's exactly where a screen's parent icon lives (e.g.
            // the hub's "Translation" row supplies the Translation screen icon).
            if (icon && title.length && !iconByTitle[title.lowercaseString]) {
                iconByTitle[title.lowercaseString] = icon;
            }
            if ([title compare:screenTitle options:NSCaseInsensitiveSearch] == NSOrderedSame) return;
            // A disclosure whose title is itself a registered destination is
            // already represented by that destination's screen entry. Keeping
            // both produces duplicate-looking results, and the weaker copy
            // merely opens the parent screen and flashes its disclosure row.
            if (disclosure && [registeredScreenTitles containsObject:title.lowercaseString]) return;
            ApolloSettingsSearchEntry *entry = [[ApolloSettingsSearchEntry alloc] init];
            entry.title = title;
            entry.breadcrumb = header.length > 0
                ? [NSString stringWithFormat:@"%@ → %@", screenTitle, header]
                : screenTitle;
            entry.routeId = routeId;
            entry.rowTitle = title;
            entry.iconImage = icon; // own icon if the row has one; else resolved below
            [entries addObject:entry];
        });
    }

    // Native rows: the generated crawl snapshot (see the header's provenance
    // note). Navigation is label-matched at selection time, so a moved row
    // degrades to "lands on its screen", never a wrong tap.
    for (NSArray *row in ApolloSettingsSearchNativeRows()) {
        // Reborn replaces this dead Apollo row with its Translation disclosure
        // in General → Other. Keeping the snapshot entry would return a result
        // that can no longer be found or flashed after navigation.
        if ([row[0] isEqualToString:@"Always Offer Translate"]) continue;
        // Reborn hides these three native General → Other rows and relocates
        // them onto its own screens (Open in App / Profiles) against the same
        // native keys — see ApolloSettingsNativeInjections.xm. The moved rows
        // are indexed from the live Reborn screen crawl above, so the snapshot
        // entries would navigate to a row that no longer exists.
        if ([row[0] isEqualToString:@"Open Links in"]) continue;
        if ([row[0] isEqualToString:@"Open Videos in YouTube App"]) continue;
        if ([row[0] isEqualToString:@"Hide Username on Tab Bar"]) continue;
        // Reborn owns the prominent Feature Requests entry (Apollo Reborn →
        // About → Fider board), already indexed from the live Reborn crawl.
        // The native About row now just opens a new-vs-archived chooser, so a
        // second "Feature Requests" result would look like a duplicate.
        if ([row[0] isEqualToString:@"Feature Requests"]) continue;
        ApolloSettingsSearchEntry *entry = [[ApolloSettingsSearchEntry alloc] init];
        entry.title = row[0];
        entry.breadcrumb = row[1];
        NSString *path = row[2];
        entry.nativePath = path.length > 0 ? [path componentsSeparatedByString:@"|"] : @[];
        entry.rowTitle = row[0];
        entry.pushesFinalRow = [row[3] boolValue];
        [entries addObject:entry];
    }

    // Runtime-injected leaf rows do not exist in the generated native crawl.
    // Disclosure injections are already represented by router entries above;
    // Color Flairs is the one injected switch with no dedicated screen/route.
    ApolloSettingsSearchEntry *colorFlairs = [[ApolloSettingsSearchEntry alloc] init];
    colorFlairs.title = @"Color Flairs";
    colorFlairs.breadcrumb = @"Appearance → Flair";
    colorFlairs.nativePath = @[ @"Appearance" ];
    colorFlairs.rowTitle = @"Color Flairs";
    [entries addObject:colorFlairs];

    // Resolve a leading icon for every result so the list is visually uniform:
    //   own row icon (captured above) → the parent screen/section's icon (by
    //   breadcrumb) → a neutral generic. Parent lookup consults both the live
    //   capture and the native map.
    UIImage *(^lookup)(NSString *) = ^UIImage *(NSString *name) {
        if (name.length == 0) return nil;
        return iconByTitle[name.lowercaseString] ?: ApolloSearchMappedIconTile(name, traits);
    };
    UIImage *generic = ApolloSettingsIconTileImage(@"magnifyingglass", UIColor.systemGray2Color, traits);
    for (ApolloSettingsSearchEntry *entry in entries) {
        if (entry.iconImage) continue;
        UIImage *icon = lookup(entry.title);              // the row/screen's own icon
        if (!icon && entry.breadcrumb.length) {
            NSArray<NSString *> *crumbs = [entry.breadcrumb componentsSeparatedByString:@" → "];
            icon = lookup(crumbs.firstObject);            // top-level parent (General, Apollo Reborn, …)
            if (!icon && crumbs.count > 1) icon = lookup(crumbs.lastObject); // nearest parent
        }
        entry.iconImage = icon ?: generic;
    }

    return entries;
}

#pragma mark - Matching

// Fold punctuation/diacritics to spaces once per comparison. Settings names
// contain hyphens, ampersands and curly punctuation, and users should not need
// to type those exactly ("pip" and acronym matching are handled below).
static NSString *ApolloSearchNormalized(NSString *string) {
    NSString *folded = [[string ?: @"" stringByFoldingWithOptions:NSDiacriticInsensitiveSearch
                                                            locale:NSLocale.currentLocale] lowercaseString];
    NSMutableString *result = [NSMutableString stringWithCapacity:folded.length];
    BOOL lastWasSpace = YES;
    for (NSUInteger i = 0; i < folded.length; i++) {
        unichar c = [folded characterAtIndex:i];
        if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) {
            [result appendFormat:@"%C", c];
            lastWasSpace = NO;
        } else if (!lastWasSpace) {
            [result appendString:@" "];
            lastWasSpace = YES;
        }
    }
    if ([result hasSuffix:@" "]) [result deleteCharactersInRange:NSMakeRange(result.length - 1, 1)];
    return result;
}

static NSArray<NSString *> *ApolloSearchWords(NSString *normalized) {
    if (normalized.length == 0) return @[];
    return [normalized componentsSeparatedByString:@" "];
}

// Bounded Levenshtein distance. We only accept one typo for normal-sized
// words, so abandon a row as soon as its cheapest candidate exceeds the cap.
// The search index is only a few hundred entries, but this keeps each keypress
// predictably cheap and avoids broad/noisy fuzzy results for short queries.
static NSUInteger ApolloSearchEditDistanceAtMost(NSString *a, NSString *b, NSUInteger limit) {
    if (a.length > b.length + limit || b.length > a.length + limit) return limit + 1;
    NSUInteger previous[b.length + 1], current[b.length + 1];
    for (NSUInteger j = 0; j <= b.length; j++) previous[j] = j;
    for (NSUInteger i = 1; i <= a.length; i++) {
        current[0] = i;
        NSUInteger rowMin = current[0];
        unichar ac = [a characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= b.length; j++) {
            NSUInteger substitution = previous[j - 1] + (ac == [b characterAtIndex:j - 1] ? 0 : 1);
            current[j] = MIN(MIN(previous[j] + 1, current[j - 1] + 1), substitution);
            rowMin = MIN(rowMin, current[j]);
        }
        if (rowMin > limit) return limit + 1;
        memcpy(previous, current, sizeof(NSUInteger) * (b.length + 1));
    }
    return previous[b.length];
}

static BOOL ApolloSearchTokenFuzzyMatchesWord(NSString *token, NSString *word) {
    if (token.length < 4 || word.length < 4) return NO;
    if ([word hasPrefix:token] || [token hasPrefix:word]) return YES;
    return ApolloSearchEditDistanceAtMost(token, word, 1) <= 1;
}

static NSInteger ApolloSearchScore(ApolloSettingsSearchEntry *entry, NSString *query) {
    static NSStringCompareOptions const opts = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSString *title = entry.title;

    NSInteger score = -1;
    if ([title rangeOfString:query options:opts | NSAnchoredSearch].location != NSNotFound) {
        score = 100;
    } else {
        NSRange inTitle = [title rangeOfString:query options:opts];
        if (inTitle.location != NSNotFound) {
            // Word-boundary prefix ranks above a mid-word hit.
            unichar before = [title characterAtIndex:inTitle.location - 1];
            score = [NSCharacterSet.alphanumericCharacterSet characterIsMember:before] ? 55 : 80;
        } else if ([entry.breadcrumb rangeOfString:query options:opts].location != NSNotFound) {
            score = 25;
        } else {
            // Multi-word query: every token must land somewhere in title+crumb.
            NSArray<NSString *> *tokens = [query componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *haystack = [NSString stringWithFormat:@"%@ %@", title, entry.breadcrumb];
            BOOL allLiteral = tokens.count >= 2;
            for (NSString *token in tokens) {
                if (token.length > 0 && [haystack rangeOfString:token options:opts].location == NSNotFound) {
                    allLiteral = NO;
                    break;
                }
            }
            if (allLiteral) {
                score = 40;
            } else {
                NSString *normalizedQuery = ApolloSearchNormalized(query);
                NSArray<NSString *> *queryWords = ApolloSearchWords(normalizedQuery);
                NSArray<NSString *> *haystackWords = ApolloSearchWords(ApolloSearchNormalized(haystack));

                // Initialisms are useful for settings vocabulary: "pip" finds
                // Picture-in-Picture and "api" finds Accounts & API Keys.
                NSMutableString *initials = [NSMutableString string];
                for (NSString *word in ApolloSearchWords(ApolloSearchNormalized(title))) {
                    if (word.length > 0) [initials appendString:[word substringToIndex:1]];
                }
                if (normalizedQuery.length >= 2 && [initials hasPrefix:normalizedQuery]) {
                    score = 48;
                } else {
                    BOOL allFuzzy = queryWords.count > 0;
                    for (NSString *token in queryWords) {
                        BOOL tokenMatched = NO;
                        for (NSString *word in haystackWords) {
                            if (ApolloSearchTokenFuzzyMatchesWord(token, word)) {
                                tokenMatched = YES;
                                break;
                            }
                        }
                        if (!tokenMatched) {
                            allFuzzy = NO;
                            break;
                        }
                    }
                    if (!allFuzzy) return -1;
                    score = 32;
                }
            }
        }
    }
    // Prefer the tweak's own rows ever so slightly on ties, and screens over
    // leaf rows of the same name.
    if (entry.routeId) score += 2;
    if (!entry.rowTitle || entry.pushesFinalRow) score += 1;
    return score;
}

#pragma mark - Navigation

static void ApolloSearchFlashRow(UITableView *table, NSIndexPath *indexPath) {
    [table scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [table selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [table deselectRowAtIndexPath:indexPath animated:YES];
        });
    });
}

// Land on the entry's final row in the (already visible) top view controller.
// Retries briefly — the just-pushed screen's table may still be loading.
static void ApolloSearchFinishOnTopOfNav(UINavigationController *nav, ApolloSettingsSearchEntry *entry, NSUInteger attempt) {
    UITableView *table = ApolloSearchTableInViewController(nav.topViewController);
    NSIndexPath *indexPath = table ? ApolloSearchFindRowTitled(table, entry.rowTitle) : nil;
    if (!indexPath) {
        if (attempt < 4) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSearchFinishOnTopOfNav(nav, entry, attempt + 1);
            });
        } else {
            // Fail soft: the screen is open, the row moved/hid — leave it there.
            ApolloLog(@"[SettingsSearch] row '%@' not found on %@", entry.rowTitle, nav.topViewController);
        }
        return;
    }
    if (entry.pushesFinalRow) {
        [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
    } else {
        ApolloSearchFlashRow(table, indexPath);
    }
}

// Tap through entry.nativePath from the Settings root, one nav push at a time.
static void ApolloSearchWalkNativePath(UINavigationController *nav, ApolloSettingsSearchEntry *entry, NSUInteger hop) {
    if (hop >= entry.nativePath.count) {
        ApolloSearchFinishOnTopOfNav(nav, entry, 0);
        return;
    }
    UITableView *table = ApolloSearchTableInViewController(nav.topViewController);
    NSIndexPath *indexPath = table ? ApolloSearchFindRowTitled(table, entry.nativePath[hop]) : nil;
    if (!indexPath) {
        ApolloLog(@"[SettingsSearch] hop '%@' not found on %@", entry.nativePath[hop], nav.topViewController);
        return;
    }
    [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSearchWalkNativePath(nav, entry, hop + 1);
    });
}

static void ApolloSettingsSearchOpenEntry(UIViewController *settingsVC, ApolloSettingsSearchEntry *entry) {
    UINavigationController *nav = settingsVC.navigationController;
    if (!nav) return;
    [nav popToViewController:settingsVC animated:NO];

    if (entry.routeId) {
        UIViewController *vc = ApolloSettingsRouteInstantiate(entry.routeId);
        if (!vc) return;
        [nav pushViewController:vc animated:YES];
        ApolloLog(@"[SettingsSearch] opened route '%@' (row '%@')", entry.routeId, entry.rowTitle);
        if (entry.rowTitle) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloSearchFinishOnTopOfNav(nav, entry, 0);
            });
        }
        return;
    }

    ApolloLog(@"[SettingsSearch] walking native path %@ → '%@'", entry.nativePath, entry.rowTitle);
    ApolloSearchWalkNativePath(nav, entry, 0);
}

#pragma mark - Results controller

@interface ApolloSettingsSearchResultsController : ApolloSettingsTableViewController <UISearchResultsUpdating, UISearchControllerDelegate>
@property (nonatomic, weak) UIViewController *settingsVC;
@property (nonatomic, weak) UISearchController *searchController;
@property (nonatomic, copy) NSArray<ApolloSettingsSearchEntry *> *index;
@property (nonatomic, copy) NSArray<ApolloSettingsSearchEntry *> *results;
// Result picked while the search UI was up; navigation runs from
// didDismissSearchController: — pushing any earlier lands inside the search
// dismissal transition and UIKit drops it ("while an existing transition or
// presentation is occurring").
@property (nonatomic, strong) ApolloSettingsSearchEntry *pendingEntry;
@end

@implementation ApolloSettingsSearchResultsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

// Search-results controllers are presented by UISearchController rather than
// pushed onto the navigation stack, so the normal "previous controller"
// lookup cannot find Apollo's Settings table. Point the shared theming layer at
// the root table explicitly so custom themes carry through to the background,
// separators, cells, disclosure indicators, and accent color.
- (UITableView *)apollo_sourceThemeTableView {
    return ApolloSearchTableInViewController(self.settingsVC);
}

// Rebuild on every search session, not once per launch: conditional rows
// (visible blocks, remapped native rows) change with the flags the user just
// toggled, and the scan is ~a dozen lightweight VC loads.
- (void)willPresentSearchController:(__unused UISearchController *)searchController {
    // UISearchController may load its results view before settingsVC is wired
    // up, so repeat the inherited-theme pass at presentation time when the
    // live root Settings table is guaranteed to exist.
    [self apollo_applyTheme];
    self.index = ApolloSettingsSearchBuildIndex(self.traitCollection);
    ApolloLog(@"[SettingsSearch] index built: %lu entries", (unsigned long)self.index.count);
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (query.length == 0) {
        self.results = @[];
        [self.tableView reloadData];
        return;
    }
    if (!self.index) self.index = ApolloSettingsSearchBuildIndex(self.traitCollection);

    NSMutableArray<NSDictionary *> *scored = [NSMutableArray array];
    for (ApolloSettingsSearchEntry *entry in self.index) {
        NSInteger score = ApolloSearchScore(entry, query);
        if (score > 0) [scored addObject:@{ @"e": entry, @"s": @(score) }];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"s"] integerValue], sb = [b[@"s"] integerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [((ApolloSettingsSearchEntry *)a[@"e"]).title
                caseInsensitiveCompare:((ApolloSettingsSearchEntry *)b[@"e"]).title];
    }];
    NSMutableArray<ApolloSettingsSearchEntry *> *results = [NSMutableArray array];
    for (NSDictionary *item in scored) {
        [results addObject:item[@"e"]];
        if (results.count >= 50) break;
    }
    self.results = results;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.results.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const reuseID = @"ApolloSettingsSearchResult";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    ApolloSettingsSearchEntry *entry = self.results[(NSUInteger)indexPath.row];
    cell.textLabel.text = entry.title;
    cell.detailTextLabel.text = entry.breadcrumb;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = entry.iconImage;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((NSUInteger)indexPath.row >= self.results.count) return;
    // Dismiss the search UI first; didDismissSearchController: navigates once
    // the dismissal transition has fully completed.
    self.pendingEntry = self.results[(NSUInteger)indexPath.row];
    self.searchController.active = NO;
}

- (void)didDismissSearchController:(__unused UISearchController *)searchController {
    ApolloSettingsSearchEntry *entry = self.pendingEntry;
    if (!entry) return;
    self.pendingEntry = nil;
    UIViewController *settingsVC = self.settingsVC;
    // Next runloop turn: let UIKit finish tearing down the presentation state
    // before we start pushing.
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSettingsSearchOpenEntry(settingsVC, entry);
    });
}

@end

#pragma mark - Attach


static char kApolloSettingsSearchAttachedKey;

void ApolloSettingsSearchAttach(UIViewController *settingsVC) {
    if (!settingsVC || objc_getAssociatedObject(settingsVC, &kApolloSettingsSearchAttachedKey)) return;

    ApolloSettingsSearchResultsController *results = [[ApolloSettingsSearchResultsController alloc] init];
    results.settingsVC = settingsVC;

    UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:results];
    searchController.searchResultsUpdater = results;
    searchController.delegate = results;
    searchController.searchBar.placeholder = @"Search Settings";
    searchController.obscuresBackgroundDuringPresentation = NO;
    results.searchController = searchController;

    settingsVC.navigationItem.searchController = searchController;
    // Native iOS behavior: the search bar lives in the large-title area and
    // scrolls away as the list scrolls up, revealing again on a scroll to the
    // top — rather than staying pinned under the nav bar.
    settingsVC.navigationItem.hidesSearchBarWhenScrolling = YES;
    settingsVC.definesPresentationContext = YES;

    objc_setAssociatedObject(settingsVC, &kApolloSettingsSearchAttachedKey, searchController, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // No custom pull-to-search affordance: with hidesSearchBarWhenScrolling the
    // system already reveals the bar on a scroll to the top, so a bespoke
    // overscroll gesture would fight that native reveal (it used to exist only
    // because the bar was pinned and never moved).

    ApolloLog(@"[SettingsSearch] attached to %@", settingsVC);
}
