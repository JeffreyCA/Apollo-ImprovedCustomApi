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
// forever. This module lets the user hide them, entirely through Edit mode:
//
// 1. Data layer: -[RDKClient moderatedSubredditsWithPagination:completion:]
//    is wrapped so hidden subreddits never reach RedditListViewController —
//    except while the list is in Edit mode, when they're kept so the user
//    can see and unhide them. The MODERATOR section rebuilds naturally, so
//    row counts, the A-Z fast-scroll index, and edit mode stay consistent
//    with no index-path remapping.
// 2. Edit-mode UI: moderator rows natively get no edit control (Apollo has
//    no unsubscribe for moderated subs), leaving the left gutter free. We
//    place our own control there: a blue minus circle on visible rows
//    (tap = hide) and a green plus circle on hidden rows, which also render
//    faded (tap = unhide). Toggling updates the row in place; the list is
//    refetched when Edit mode ends so hidden rows disappear.
//
// The hidden list is stored in NSUserDefaults under
// UDKeyHiddenModeratorSubreddits as an array of display names, compared
// case-insensitively. Note: the list is global across Reddit accounts.

@interface RedditListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

// Lowercased names of every subreddit seen in the moderated-subreddits
// fetch (captured before filtering). Used only for diagnostics/crosschecks;
// the section header title is the actual gate for the toggle UI.
static NSMutableSet<NSString *> *sModeratedSubredditNames = nil;

// While the Subreddits list is in Edit mode, the moderated-subreddits fetch
// keeps hidden entries so they can be shown (faded) and unhidden inline.
static BOOL sIncludeHiddenInFetch = NO;

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

// MARK: - Data-layer filtering

// Filters hidden subreddits out of a moderated-subreddits listing page and
// records every name seen (pre-filter) for diagnostics. While the list is
// in Edit mode, hidden entries are kept so they can be unhidden inline.
static NSArray *ApolloHideModFilterModeratedCollection(NSArray *collection) {
    if (![collection isKindOfClass:[NSArray class]] || collection.count == 0) return collection;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:collection.count];
    NSUInteger removed = 0;
    for (id subreddit in collection) {
        NSString *name = nil;
        if ([subreddit respondsToSelector:@selector(name)]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
            if ([value isKindOfClass:[NSString class]]) name = value;
        }
        if (name.length > 0) {
            @synchronized (sModeratedSubredditNames) {
                [sModeratedSubredditNames addObject:name.lowercaseString];
            }
            if (!sIncludeHiddenInFetch && ApolloHideModNameIsHidden(name)) {
                removed++;
                continue;
            }
        }
        [filtered addObject:subreddit];
    }

    if (removed > 0) {
        ApolloLog(@"[HideModSubs] filtered %lu hidden subreddit(s) from moderated listing (%lu -> %lu)",
                  (unsigned long)removed, (unsigned long)collection.count, (unsigned long)filtered.count);
        return filtered;
    }
    return collection;
}

typedef void (^ApolloHideModListingCompletion)(NSArray *collection, id pagination, NSError *error);

%hook RDKClient

- (id)moderatedSubredditsWithPagination:(id)pagination completion:(ApolloHideModListingCompletion)completion {
    if (!completion) return %orig;
    ApolloHideModListingCompletion wrapped = ^(NSArray *collection, id page, NSError *error) {
        completion(ApolloHideModFilterModeratedCollection(collection), page, error);
    };
    return %orig(pagination, wrapped);
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

// Triggers the list's own pull-to-refresh path so it refetches subscriptions,
// multireddits, and moderated subreddits and rebuilds its sections — with the
// hidden list applied (or not, while editing) by the RDKClient hook above.
static void ApolloHideModRefreshList(UIViewController *viewController) {
    SEL refreshSelector = NSSelectorFromString(@"refreshControlActivated:");
    if (![viewController respondsToSelector:refreshSelector]) {
        ApolloLog(@"[HideModSubs] refreshControlActivated: missing on %@; list will refresh on next fetch",
                  NSStringFromClass([viewController class]));
        return;
    }

    // Prefer the controller's real refresh control; the Swift implementation
    // expects a non-nil sender, so fall back to a throwaway one.
    id refreshControl = ApolloHideModObjectIvar(viewController, "refreshControl");
    if (![refreshControl isKindOfClass:[UIRefreshControl class]]) refreshControl = [[UIRefreshControl alloc] init];
    ApolloLog(@"[HideModSubs] triggering native list refresh (includeHidden=%d)", (int)sIncludeHiddenInFetch);
    ((void (*)(id, SEL, id))objc_msgSend)(viewController, refreshSelector, refreshControl);
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
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = %orig;
    if (![cell isKindOfClass:[UITableViewCell class]]) return cell;

    NSString *sectionTitle = ApolloHideModSectionTitle(self, tableView, indexPath.section);
    BOOL isModeratorRow = [sectionTitle isEqualToString:@"MODERATOR"];
    NSString *name = isModeratorRow ? ApolloHideModLeftmostLabelText(cell.contentView ?: cell) : nil;

    if (isModeratorRow && name.length > 0) {
        @synchronized (sModeratedSubredditNames) {
            if (sModeratedSubredditNames.count > 0 && ![sModeratedSubredditNames containsObject:name.lowercaseString]) {
                ApolloLog(@"[HideModSubs] row '%@' is in MODERATOR section but missing from fetched moderated set", name);
            }
        }
    }

    ApolloHideModDecorateCell((UIViewController *)self, cell, isModeratorRow, tableView.isEditing, name);
    return cell;
}

// Entering Edit mode: include hidden subs in fetches, reload so moderator
// rows pick up their toggle buttons immediately, and refetch so hidden rows
// reappear. Leaving Edit mode: reverse all of it.
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    BOOL wasEditing = [(UIViewController *)self isEditing];
    %orig;
    if (wasEditing == editing) return;

    sIncludeHiddenInFetch = editing;
    ApolloLog(@"[HideModSubs] setEditing=%d hiddenCount=%lu", (int)editing, (unsigned long)ApolloHideModHiddenList().count);

    UITableView *tableView = ApolloHideModTableView((UIViewController *)self);
    [tableView reloadData];

    // Only hit the network when there are hidden rows to add or remove.
    if (ApolloHideModHiddenList().count > 0) {
        ApolloHideModRefreshList((UIViewController *)self);
    }
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
    // when Edit mode ends and the list refetches with filtering back on.
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
    sModeratedSubredditNames = [NSMutableSet set];

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
