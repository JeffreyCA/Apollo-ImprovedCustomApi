#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

// MARK: - Hide Moderated Subreddits
//
// Reddit offers no way to leave or delete some dead subreddits you moderate,
// so they're stuck in the MODERATOR section of Apollo's Subreddits list
// forever. This module lets the user hide them from that list, entirely
// through Edit mode, WITHOUT touching the moderator powers you have on those
// subreddits when you actually visit them.
//
// Why the display filter has to be this surgical
// ----------------------------------------------
// Apollo has a single source of truth for "which subreddits do I moderate":
// the `RDKUser.moderatedSubreddits` array. The Subreddits list populates it —
// `RedditListViewController.fetchSubredditData()` assigns the moderated-subs
// fetch result straight into `currentUser.moderatedSubreddits` — and then the
// list reads that very property back to build its MODERATOR section (row count,
// header height, each cell, taps, the context menu all call the getter).
//
// Crucially, the SAME property is what gates moderator powers everywhere else:
// PostsViewController / CommentsViewController decide whether to show the mod
// toolbar by checking `currentUser.moderatedSubreddits`, the inbox colours mod
// mail from it, etc. (~50 read sites across the app).
//
// The original version of this feature (PR #424) hid rows by filtering the
// data layer — wrapping `-[RDKClient moderatedSubredditsWithPagination:
// completion:]` so hidden subs never reached the list. But that fetch result
// is exactly what gets stored into `currentUser.moderatedSubreddits`, so the
// filter shrank the shared source of truth: hide every sub you moderate and
// the app concludes you moderate nothing — no mod badge, no mod tools when you
// open those subreddits. (Reported: "Hiding them all removed moderator
// badge/access to options in subreddits you're a mod on.")
//
// The fix keeps `moderatedSubreddits` complete (mod powers intact) and instead
// filters only the GETTER, and only while the Subreddits list's own table
// methods are running:
//
// 1. The data layer is left untouched, so `currentUser.moderatedSubreddits`
//    always holds the full Reddit-reported set. Every moderator-power check
//    app-wide sees the real list.
// 2. `-[RDKUser moderatedSubreddits]` is hooked. It returns the full array
//    everywhere EXCEPT inside the Subreddits list's row-SIZING/BUILDING table
//    methods (numberOfRows, heightForHeader, cellForRow), where it returns the
//    array with hidden subs removed. A thread-local depth counter, bumped only
//    around those methods' `%orig`, scopes the filtering precisely (and keeps
//    background mod-power checks on other threads unaffected).
// 3. In Edit mode the filter is bypassed so hidden rows reappear (faded, with
//    a green plus circle) and can be unhidden inline.
//
// Because numberOfRows, heightForHeader and cellForRow all read the same
// filtered getter, the MODERATOR section's row count, header and cells stay
// consistent automatically — when every moderated sub is hidden the section
// collapses to nothing. Toggling Edit mode just reloads the table; no network
// refetch is needed.
//
// The methods that NAVIGATE off a row (didSelect, contextMenu) are kept OUT of
// the filter window: navigating pushes a view controller whose mod-toolbar gate
// reads `moderatedSubreddits` synchronously during the push, so doing it under
// the filter would drop mod tools for a sub you moderate-but-hid yet reached
// from another section. They instead translate the tapped (filtered) row to its
// full-list index and run `%orig` at depth 0, so resolution stays correct while
// the navigation always sees the complete list (see
// ApolloHideModResolveModeratorIndexPath).
//
// The hidden list is stored in NSUserDefaults under
// UDKeyHiddenModeratorSubreddits as an array of display names, compared
// case-insensitively. Note: the list is global across Reddit accounts.

@interface RedditListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

// Minimal surface for the model class whose getter we scope. RDKUser is always
// present in Apollo; a forward declaration is enough for the %hook.
@interface RDKUser : NSObject
- (NSArray *)moderatedSubreddits;
@end

// Thread-local nesting depth of "we are currently inside a Subreddits-list
// table method that reads moderatedSubreddits for display." The getter only
// filters when this is > 0, so every other reader (moderator-power checks,
// inbox, jump bar, background work) sees the complete list. Thread-local so a
// mod-power check running on another thread is never caught by the window.
static __thread NSInteger sListFilterDepth = 0;

// While the Subreddits list is in Edit mode the filter is bypassed entirely so
// hidden rows are shown (faded) and can be unhidden. Set on the main thread in
// setEditing:; read by the getter.
static BOOL sShowHiddenForEditing = NO;

// Tag + associated keys for the per-cell hide/unhide button.
static const NSInteger kApolloHideModButtonTag = 0x484D53; // 'HMS'
static char kApolloHideModButtonNameKey;

// MARK: - Hidden list persistence

static NSArray<NSString *> *ApolloHideModHiddenList(void) {
    NSArray *list = [[NSUserDefaults standardUserDefaults] stringArrayForKey:UDKeyHiddenModeratorSubreddits];
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

static void ApolloHideModSetHiddenList(NSArray<NSString *> *list) {
    [[NSUserDefaults standardUserDefaults] setObject:(list ?: @[]) forKey:UDKeyHiddenModeratorSubreddits];
    ApolloLog(@"[HideModSubs] hidden list now has %lu entries", (unsigned long)list.count);
}

static BOOL ApolloHideModNameIsHidden(NSString *name) {
    if (name.length == 0) return NO;
    for (NSString *hidden in ApolloHideModHiddenList()) {
        if ([hidden caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    }
    return NO;
}

static void ApolloHideModAddHidden(NSString *name) {
    if (name.length == 0 || ApolloHideModNameIsHidden(name)) return;
    NSMutableArray *list = [ApolloHideModHiddenList() mutableCopy];
    [list addObject:name];
    ApolloHideModSetHiddenList(list);
    ApolloLog(@"[HideModSubs] hid subreddit %@", name);
}

static void ApolloHideModRemoveHidden(NSString *name) {
    if (name.length == 0) return;
    NSMutableArray *list = [ApolloHideModHiddenList() mutableCopy];
    NSUInteger before = list.count;
    for (NSUInteger idx = list.count; idx > 0; idx--) {
        if ([list[idx - 1] caseInsensitiveCompare:name] == NSOrderedSame) [list removeObjectAtIndex:idx - 1];
    }
    if (list.count != before) {
        ApolloHideModSetHiddenList(list);
        ApolloLog(@"[HideModSubs] unhid subreddit %@", name);
    }
}

// MARK: - Getter-level display filter

// The display name of one entry in moderatedSubreddits. Entries are RDKSubreddit
// objects (they respond to -name); fall back to treating the entry as a plain
// name string just in case the model ever changes.
static NSString *ApolloHideModNameForEntry(id entry) {
    if ([entry respondsToSelector:@selector(name)]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(entry, @selector(name));
        if ([value isKindOfClass:[NSString class]]) return value;
    }
    if ([entry isKindOfClass:[NSString class]]) return entry;
    return nil;
}

// Returns the moderated-subreddits array with hidden entries removed. Returns
// the input unchanged when nothing is hidden, so the common case allocates
// nothing.
static NSArray *ApolloHideModFilteredList(NSArray *full) {
    if (![full isKindOfClass:[NSArray class]] || full.count == 0) return full;
    if (ApolloHideModHiddenList().count == 0) return full;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:full.count];
    for (id entry in full) {
        NSString *name = ApolloHideModNameForEntry(entry);
        if (name.length > 0 && ApolloHideModNameIsHidden(name)) continue;
        [filtered addObject:entry];
    }
    if (filtered.count == full.count) return full;
    return filtered;
}

%hook RDKUser

// Source of truth for moderator powers app-wide. Return the full list normally;
// return the hidden-filtered list ONLY while the Subreddits list is reading it
// for display and we're not in Edit mode. This hides the rows without ever
// telling the rest of the app you moderate fewer subreddits.
- (NSArray *)moderatedSubreddits {
    NSArray *full = %orig;
    if (sListFilterDepth <= 0 || sShowHiddenForEditing) return full;
    return ApolloHideModFilteredList(full);
}

%end

// MARK: - Subreddits list UI helpers

// Leftmost non-empty UILabel in a view tree. Subreddit list cells contain the
// title label, an icon image, and the favorite star control — the title is
// the only (and leftmost) label. Section headers contain just the title label.
static NSString *ApolloHideModLeftmostLabelText(UIView *root) {
    if (!root) return nil;

    UILabel *best = nil;
    CGFloat bestX = CGFLOAT_MAX;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)candidate;
            NSString *text = [label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) {
                CGFloat minX = CGRectGetMinX([label convertRect:label.bounds toView:root]);
                if (minX < bestX) {
                    best = label;
                    bestX = minX;
                }
            }
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    return [best.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Resolves a section's header title (uppercased) by checking the visible
// header first, then asking the delegate to build one.
static NSString *ApolloHideModSectionTitle(id delegate, UITableView *tableView, NSInteger section) {
    if (!tableView || section < 0 || section >= tableView.numberOfSections) return nil;

    UIView *header = [tableView headerViewForSection:section];
    if (!header && [delegate respondsToSelector:@selector(tableView:viewForHeaderInSection:)]) {
        header = [delegate tableView:tableView viewForHeaderInSection:section];
    }
    NSString *text = ApolloHideModLeftmostLabelText(header);
    return text.length > 0 ? text.uppercaseString : nil;
}

static id ApolloHideModObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static UITableView *ApolloHideModTableView(UIViewController *viewController) {
    UITableView *tableView = (UITableView *)ApolloHideModObjectIvar(viewController, "tableView");
    return [tableView isKindOfClass:[UITableView class]] ? tableView : nil;
}

// MARK: - Index remap for navigation/context-menu taps

// The current user's FULL (unfiltered) moderated-subreddits list. Called only at
// filter depth 0, so the hooked getter returns the complete array — the same
// object the Subreddits list's MODERATOR rows are built from (the list reads
// currentUser.moderatedSubreddits, and currentUser is the shared client's).
static NSArray *ApolloHideModCurrentModeratedSubreddits(void) {
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass || ![clientClass respondsToSelector:@selector(sharedClient)]) return nil;
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(sharedClient));
    if (![client respondsToSelector:@selector(currentUser)]) return nil;
    id user = ((id (*)(id, SEL))objc_msgSend)(client, @selector(currentUser));
    if (![user respondsToSelector:@selector(moderatedSubreddits)]) return nil;
    id list = ((id (*)(id, SEL))objc_msgSend)(user, @selector(moderatedSubreddits));
    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

// Translate a MODERATOR-section index path from "position among the visible
// (hidden-filtered) rows" to "position in the full moderatedSubreddits array".
//
// This lets the row-resolving methods (didSelect / contextMenu) run their %orig
// at filter depth 0 instead of inside the display-scope window. That matters
// because Apollo resolves the moderator row as `moderatedSubreddits[row]` and
// then navigates: a tap pushes the subreddit's posts view controller, and UIKit
// runs that controller's viewDidLoad/viewWillAppear: synchronously inside
// pushViewController:. Those gate the moderator toolbar on
// currentUser.moderatedSubreddits, so if the push ran under the filter window
// the freshly opened sub could lose its mod tools — the very bug this PR fixes —
// for a sub you moderate, have hidden, but are still subscribed to (so it stays
// reachable from the alphabetical section while hidden). Running at depth 0 keeps
// every such check on the complete list; remapping keeps resolution correct.
//
// Returns the input unchanged for any row that needs no translation: non-
// MODERATOR sections (Apollo resolves those from its sectionedSubreddits model,
// already aligned to the full data and never filtered), Edit mode (filter
// bypassed, rows already the full list), nothing hidden, or anything we can't
// resolve — in which case the conservative fallback is the original index path.
static NSIndexPath *ApolloHideModResolveModeratorIndexPath(id viewController, UITableView *tableView, NSIndexPath *indexPath) {
    if (!indexPath || sShowHiddenForEditing) return indexPath;
    if (ApolloHideModHiddenList().count == 0) return indexPath;
    if (![ApolloHideModSectionTitle(viewController, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) return indexPath;

    NSArray *full = ApolloHideModCurrentModeratedSubreddits();
    NSArray *filtered = ApolloHideModFilteredList(full);
    if (filtered == full) return indexPath; // nothing hidden among the moderated subs

    NSInteger visibleRow = indexPath.row;
    if (visibleRow < 0 || visibleRow >= (NSInteger)filtered.count) return indexPath;

    id target = filtered[visibleRow];
    NSUInteger fullIndex = [full indexOfObjectIdenticalTo:target];
    if (fullIndex == NSNotFound) fullIndex = [full indexOfObject:target];
    if (fullIndex == NSNotFound || (NSInteger)fullIndex == visibleRow) return indexPath;

    ApolloLog(@"[HideModSubs] remap moderator row %ld -> %lu (full list) so navigation keeps mod powers",
              (long)visibleRow, (unsigned long)fullIndex);
    return [NSIndexPath indexPathForRow:(NSInteger)fullIndex inSection:indexPath.section];
}

// MARK: - Edit-mode hide/unhide control

// Hide/unhide glyph drawn by hand so the visible circle is exactly 22pt —
// the same diameter as the native red delete control. SF Symbols proved
// unusable here: their point size is a font metric (renders ~15% larger)
// and their images carry transparent padding (renders smaller when fitted),
// so explicit geometry is the only way to actually match the native circle.
static UIImage *ApolloHideModGlyph(BOOL hidden) {
    static UIImage *sHideGlyph = nil;
    static UIImage *sUnhideGlyph = nil;
    UIImage *__strong *slot = hidden ? &sUnhideGlyph : &sHideGlyph;
    if (!*slot) {
        CGFloat diameter = 22.0;
        // Bar proportions matched to the native delete circle's minus glyph.
        CGFloat barLength = 11.0;
        CGFloat barThickness = 2.5;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter, diameter)];
        UIImage *drawn = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [(hidden ? [UIColor systemGreenColor] : [UIColor systemBlueColor]) setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, diameter, diameter)] fill];

            [[UIColor whiteColor] setFill];
            UIBezierPath *horizontalBar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake((diameter - barLength) / 2.0,
                                                                                             (diameter - barThickness) / 2.0,
                                                                                             barLength, barThickness)
                                                                     cornerRadius:barThickness / 2.0];
            [horizontalBar fill];
            if (hidden) {
                UIBezierPath *verticalBar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake((diameter - barThickness) / 2.0,
                                                                                               (diameter - barLength) / 2.0,
                                                                                               barThickness, barLength)
                                                                       cornerRadius:barThickness / 2.0];
                [verticalBar fill];
            }
        }];
        *slot = [drawn imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    return *slot;
}

// Applies (or strips) the hide/unhide control and faded look on one cell.
// Called from cellForRowAtIndexPath for every row, so reused cells always
// end up in a consistent state without a prepareForReuse hook.
//
// The button lives on the cell itself, NOT contentView: moderator rows are
// made editable (canEditRow hook below) so UIKit indents contentView to the
// right exactly like the delete-circle rows, and the button occupies the
// gutter that indent exposes — matching the native edit-control position.
static void ApolloHideModDecorateCell(UIViewController *viewController, UITableViewCell *cell,
                                      BOOL isModeratorRow, BOOL editing, NSString *name) {
    UIButton *button = (UIButton *)[cell viewWithTag:kApolloHideModButtonTag];

    if (!isModeratorRow || !editing || name.length == 0) {
        if (button) [button removeFromSuperview];
        cell.contentView.alpha = 1.0;
        return;
    }

    BOOL hidden = ApolloHideModNameIsHidden(name);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kApolloHideModButtonTag;
        // The tap target spans the whole left gutter and full row height so
        // the control is as easy to hit as the native red delete circle;
        // the 22pt glyph centers within it, landing at the native position.
        // Newly created cells may not have real bounds yet; assume Apollo's
        // standard 58pt row and let autoresizing track the real height.
        CGFloat rowHeight = cell.bounds.size.height >= 30.0 ? cell.bounds.size.height : 58.0;
        // Tap target: the entire gutter from the screen edge to the subreddit
        // icon, full row height. The glyph centers itself at x=30, right where
        // the native red circle sits.
        button.frame = CGRectMake(0.0, 0.0, 60.0, rowHeight);
        button.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        [cell addSubview:button];
    }

    // UIKit reshuffles cell subviews during edit-mode transitions and can
    // land contentView on top of the button, silently eating taps. Re-assert
    // the button as frontmost every time the cell is (re)configured.
    [cell bringSubviewToFront:button];

    [button setImage:ApolloHideModGlyph(hidden) forState:UIControlStateNormal];

    // Fire on touch-down: registers the instant the finger lands instead of
    // waiting for touch-up, so the control never feels like it dropped a tap.
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [button addTarget:viewController action:NSSelectorFromString(@"apolloHideModToggleTapped:") forControlEvents:UIControlEventTouchDown];
    objc_setAssociatedObject(button, &kApolloHideModButtonNameKey, name, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Hidden rows render faded so it's obvious they won't appear outside
    // Edit mode. The button sits outside contentView, so it stays opaque.
    cell.contentView.alpha = hidden ? 0.4 : 1.0;

    ApolloLog(@"[HideModSubs] decorated moderator row '%@' hidden=%d", name, (int)hidden);
}

// MARK: - Subreddits list hooks

%group ApolloHideModList

%hook RedditListViewController

// One-shot environment dump so user logs show whether the table wiring is
// what we expect (delegate/dataSource identity, edit state).
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UITableView *tableView = ApolloHideModTableView((UIViewController *)self);
    if (!tableView) {
        ApolloLog(@"[HideModSubs] diag: tableView ivar missing on %@", NSStringFromClass([self class]));
        return;
    }
    ApolloLog(@"[HideModSubs] diag: table=%p delegate=%@%@ dataSource=%@%@ editing=%d hiddenCount=%lu",
              tableView,
              NSStringFromClass([tableView.delegate class]), tableView.delegate == (id)self ? @"(self)" : @"",
              NSStringFromClass([tableView.dataSource class]), tableView.dataSource == (id)self ? @"(self)" : @"",
              (int)tableView.isEditing,
              (unsigned long)ApolloHideModHiddenList().count);
}

// --- Display-scope window ---
// These data-source/delegate methods read currentUser.moderatedSubreddits
// (directly or via Apollo's inlined helpers) to SIZE and BUILD the MODERATOR
// section. Bumping the thread-local depth around %orig makes the getter return
// the hidden-filtered list for the whole of that work, so row count, header
// height and cells all agree. Outside this window — and on any other thread —
// the getter returns the full list, so moderator powers are never affected.
//
// Note: the methods that also NAVIGATE off a row (didSelect, contextMenu) are
// deliberately NOT in this window. They run %orig at depth 0 against a remapped
// index path instead — see ApolloHideModResolveModeratorIndexPath for why
// pushing a view controller under the filter would reintroduce the mod-tools bug.

- (long long)tableView:(UITableView *)tableView numberOfRowsInSection:(long long)section {
    sListFilterDepth++;
    long long result = %orig;
    sListFilterDepth--;
    return result;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(long long)section {
    sListFilterDepth++;
    CGFloat result = %orig;
    sListFilterDepth--;
    return result;
}

// Taps and context menus must NOT run inside the display-scope window: they
// resolve `moderatedSubreddits[row]` and then navigate, and the push runs the
// opened subreddit's mod-power check synchronously (see
// ApolloHideModResolveModeratorIndexPath). So instead of bumping the depth we
// translate the visible (filtered) row to its full-list index and let %orig
// resolve + navigate at depth 0, where every mod check sees the complete list.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *resolved = ApolloHideModResolveModeratorIndexPath(self, tableView, indexPath);
    if (resolved != indexPath) {
        // %orig is about to act on a different (full-list) index path, so clear
        // the user's visible selection ourselves — otherwise the row they
        // actually tapped would stay highlighted.
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
    }
    %orig(tableView, resolved);
}

- (id)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSIndexPath *resolved = ApolloHideModResolveModeratorIndexPath(self, tableView, indexPath);
    return %orig(tableView, resolved, point);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    sListFilterDepth++;
    %orig;
    sListFilterDepth--;
}

// Moderator rows natively can't be edited (no unsubscribe for moderated
// subs), so UIKit would not indent them in Edit mode and our gutter button
// would overlap the subreddit icon. Marking them editable with editing
// style None makes UIKit indent the content exactly like the delete-circle
// rows, while drawing no native control of its own.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL original = %orig;
    if (!original && [ApolloHideModSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) {
        return YES;
    }
    return original;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([ApolloHideModSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) {
        return UITableViewCellEditingStyleNone;
    }
    return %orig;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([ApolloHideModSectionTitle(self, tableView, indexPath.section) isEqualToString:@"MODERATOR"]) {
        return YES;
    }
    return %orig;
}

// Decorate every cell on the way out: moderator rows get the hide/unhide
// control while editing, everything else gets any stale control stripped.
// The %orig is run inside the display-scope window so the filtered getter
// produces the right row content; decoration afterwards only reads the cell.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    sListFilterDepth++;
    UITableViewCell *cell = %orig;
    sListFilterDepth--;
    if (![cell isKindOfClass:[UITableViewCell class]]) return cell;

    NSString *sectionTitle = ApolloHideModSectionTitle(self, tableView, indexPath.section);
    BOOL isModeratorRow = [sectionTitle isEqualToString:@"MODERATOR"];
    NSString *name = isModeratorRow ? ApolloHideModLeftmostLabelText(cell.contentView ?: cell) : nil;

    ApolloHideModDecorateCell((UIViewController *)self, cell, isModeratorRow, tableView.isEditing, name);
    return cell;
}

// Entering Edit mode: bypass the display filter so hidden rows reappear, and
// reload so the rows (and their hide/unhide buttons) update immediately.
// Leaving Edit mode: re-enable the filter and reload so hidden rows vanish.
// No network refetch is needed — the rows are driven by the now-complete
// moderatedSubreddits property through the scoped getter.
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    BOOL wasEditing = [(UIViewController *)self isEditing];
    %orig;
    if (wasEditing == editing) return;

    sShowHiddenForEditing = editing;
    ApolloLog(@"[HideModSubs] setEditing=%d hiddenCount=%lu", (int)editing, (unsigned long)ApolloHideModHiddenList().count);

    UITableView *tableView = ApolloHideModTableView((UIViewController *)self);
    [tableView reloadData];
}

%new
- (void)apolloHideModToggleTapped:(UIButton *)sender {
    NSString *name = objc_getAssociatedObject(sender, &kApolloHideModButtonNameKey);
    if (name.length == 0) return;

    BOOL wasHidden = ApolloHideModNameIsHidden(name);
    if (wasHidden) {
        ApolloHideModRemoveHidden(name);
    } else {
        ApolloHideModAddHidden(name);
    }

    // Re-style the tapped row in place; the row only actually disappears
    // when Edit mode ends and the filtered getter takes effect on reload.
    UIView *view = sender;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    if (view) {
        ApolloHideModDecorateCell((UIViewController *)self, (UITableViewCell *)view, YES, YES, name);
    }
    ApolloLog(@"[HideModSubs] toggled '%@' -> hidden=%d", name, (int)!wasHidden);
}

%end

%end // ApolloHideModList

%ctor {
    %init;

    Class listClass = objc_getClass("Apollo.RedditListViewController");
    if (!listClass) listClass = NSClassFromString(@"Apollo.RedditListViewController");
    if (listClass) {
        %init(ApolloHideModList, RedditListViewController = listClass);
        ApolloLog(@"[HideModSubs] list hooks installed on %@", NSStringFromClass(listClass));
    } else {
        ApolloLog(@"[HideModSubs] RedditListViewController class missing; Hide UI unavailable");
    }
}
