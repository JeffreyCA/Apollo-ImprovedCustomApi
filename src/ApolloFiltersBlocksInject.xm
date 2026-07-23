// ApolloFiltersBlocksInject
//
// Beefs out Apollo's native Filters & Blocks screen
// (_TtC6Apollo29SettingsFiltersViewController) by APPENDING two Reborn sections
// below the native Keywords / Subreddits / Users sections:
//
//   • SUBREDDIT-SPECIFIC FILTERS — a list of configured subreddits; tap one to
//     open ApolloSubredditFilterDetailViewController and manage its keyword/flair
//     lists, plus an "Add Subreddit..." row.
//   • FILTER SUBREDDITS BY NAME — a list of name substrings (hide any subreddit
//     whose name contains the word), plus an "Add Word..." row.
//   • TAG FILTERS — the global Enable/NSFW/Spoiler switches plus a
//     "Per-Subreddit Overrides" disclosure (settings IA restructure: Tag
//     Filters is a filter, so it lives here now instead of a top-level
//     Settings row; the switches write the same defaults the old screen did).
//
// Native sections are left fully intact (we append, so their indices never shift;
// every native section/row routes straight to %orig). Cells are borrowed from a
// native row so they inherit Apollo's exact theme; our section headers/footers are
// self-sizing label views. Enforcement lives in ApolloPostFilters.xm; storage in
// ApolloPostFilterStore.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloPostFilterStore.h"
#import "ApolloState.h"
#import "ApolloSubredditFilterDetailViewController.h"
#import "TagFiltersViewController.h"
#import "UserDefaultConstants.h"

// Native Filters & Blocks screen (Apollo.SettingsFiltersViewController). Declared
// for the compiler so our self-calls (the dataSource method + the %new helpers
// below) type-check; the real class is hooked/resolved at runtime.
@interface _TtC6Apollo29SettingsFiltersViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (NSInteger)apollo_pfNativeSectionCount:(UITableView *)tableView;
- (void)apollo_pfOpenDetailForSubreddit:(NSString *)sub fromTable:(UITableView *)tableView;
- (void)apollo_pfPromptAddSubredditFromTable:(UITableView *)tableView;
- (void)apollo_pfPromptAddNameFromTable:(UITableView *)tableView;
- (UITableViewCell *)apollo_pfBlockedToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded;
- (void)apollo_pfRefreshBlockedToggleCount:(UITableView *)tableView;
- (void)apollo_pfSetBlockedExpanded:(BOOL)expanded table:(UITableView *)tableView;
- (UITableViewCell *)apollo_tfCellForTable:(UITableView *)tableView row:(NSInteger)row;
- (void)apollo_tfEnableChanged:(UISwitch *)sw;
- (void)apollo_tfNSFWChanged:(UISwitch *)sw;
- (void)apollo_tfSpoilerChanged:(UISwitch *)sw;
- (void)apollo_tfOpenOverrides;
@end

// Number of Reborn sections appended after the native ones.
static const NSInteger kApolloPFExtraSections = 3;

// Rows of the appended Tag Filters section (always 4; static).
enum {
    ApolloTFRowEnable = 0,
    ApolloTFRowNSFW,
    ApolloTFRowSpoiler,
    ApolloTFRowOverrides,
    ApolloTFRowCount,
};

// Collapsible native Blocked Users section (the last native section): collapsed by
// default to a single tappable "Blocked Users (N)" row so a long block list doesn't
// bloat the page. Expanding shows Apollo's own rows (Add User + swipe-delete) FIRST,
// unchanged at their native indices, then appends our own "Blocked Users (N)" row at
// the BOTTOM as a "tap to collapse" control — so the whole thing reads as one
// continuous group and native editing stays intact (we never re-map native indices,
// we only add a trailing row).
static const void *kApolloPFBlockedExpandedKey   = &kApolloPFBlockedExpandedKey;   // NSNumber BOOL on the VC
static const void *kApolloPFBlockedNativeCountKey = &kApolloPFBlockedNativeCountKey; // NSNumber on the VC (rows incl. Add)
static const void *kApolloPFBlockedTableKey       = &kApolloPFBlockedTableKey;       // UITableView (ASSIGN) on the VC

// Our "Blocked Users (N)" toggle is row 0 of the blocked section and Apollo's own
// rows follow at display index 1..nativeCount (so it all reads as ONE rounded group).
//
// Apollo detects its "Add User" row as `row == [tableView numberOfRowsInSection:] - 1`
// — using the TABLE's displayed (inflated, +1) count — and otherwise indexes its
// blockedUsers array by `row`. So we map each DISPLAY row to the index we feed Apollo:
// the Add row (display == nativeCount, the last) keeps its index so it stays "last"
// and Apollo's Add detection fires; every user row shifts back by 1 to line up with
// blockedUsers[]. nativeCount is Apollo's own row count (users + Add), cached below.
static inline NSInteger ApolloPFBlockedApolloRow(NSInteger displayRow, NSInteger nativeCount) {
    return (displayRow >= nativeCount) ? displayRow : (displayRow - 1);
}

#pragma mark - Section header / footer views (self-sizing)

static UIView *ApolloPFSectionHeaderView(NSString *title) {
    UIView *container = [[UIView alloc] init];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = title.uppercaseString;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:18.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];
    return container;
}

static UIView *ApolloPFSectionFooterView(NSString *text) {
    UIView *container = [[UIView alloc] init];
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:6.0],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];
    return container;
}

#pragma mark - Hook

%hook _TtC6Apollo29SettingsFiltersViewController

// origCount: our numberOfSectionsInTableView: returns native + kApolloPFExtraSections,
// so subtracting it back yields the native count without needing %orig outside the
// numberOfSections hook.
%new
- (NSInteger)apollo_pfNativeSectionCount:(UITableView *)tableView {
    return [self numberOfSectionsInTableView:tableView] - kApolloPFExtraSections;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return %orig + kApolloPFExtraSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        if (native > 0 && section == native - 1) {
            NSInteger n = %orig; // Apollo's own count (blocked users + "Add User")
            objc_setAssociatedObject(self, kApolloPFBlockedNativeCountKey, @(n), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, kApolloPFBlockedTableKey, tableView, OBJC_ASSOCIATION_ASSIGN);
            // Collapsed: just our toggle (1). Expanded: toggle + Apollo's n rows.
            return [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue] ? (n + 1) : 1;
        }
        return %orig;
    }
    if (section == native) return (NSInteger)[ApolloPostFilterStore allSubreddits].count + 1;     // + Add
    if (section == native + 1) return (NSInteger)[ApolloPostFilterStore nameSubstrings].count + 1; // + Add
    return ApolloTFRowCount; // Tag Filters (static)
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            BOOL expanded = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
            // Row 0 is always our "Blocked Users (N)" toggle cell (collapsed: only row).
            if (indexPath.row == 0) return [self apollo_pfBlockedToggleCellForTable:tableView showingExpanded:expanded];
            // Apollo's cellForRow indexes its model by row (Add = last DATA index), so
            // every native row just shifts back by 1 past our toggle.
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }

    if (indexPath.section == native + 2) return [self apollo_tfCellForTable:tableView row:indexPath.row];

    BOOL isSubSection = (indexPath.section == native);
    NSArray<NSString *> *items = isSubSection ? [ApolloPostFilterStore allSubreddits]
                                              : [ApolloPostFilterStore nameSubstrings];
    BOOL isAddRow = ((NSUInteger)indexPath.row >= items.count);

    // Borrow a native cell (the "Add" row of section 0) so we inherit Apollo's
    // exact theme — background, fonts, and the accent text color used for Add rows.
    NSInteger nativeRows0 = [self tableView:tableView numberOfRowsInSection:0];
    NSIndexPath *borrow = [NSIndexPath indexPathForRow:MAX((NSInteger)0, nativeRows0 - 1) inSection:0];
    UITableViewCell *cell = %orig(tableView, borrow);
    cell.imageView.image = nil;
    cell.accessoryView = nil;

    if (isAddRow) {
        cell.textLabel.text = isSubSection ? @"Add Subreddit..." : @"Add Word...";
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // Keep the borrowed accent text color (this IS a native Add cell).
    } else {
        NSString *item = items[indexPath.row];
        cell.textLabel.textColor = [UIColor labelColor]; // override accent → normal item text
        if (isSubSection) {
            cell.textLabel.text = [NSString stringWithFormat:@"r/%@", item];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = item;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        if (native > 0 && section == native - 1) {
            // No header — our "Blocked Users (N)" toggle is row 0 of the section, so the
            // toggle + its users read as one continuous rounded group.
            return [[UIView alloc] init];
        }
        return %orig;
    }
    NSString *title;
    if (section == native) title = @"Subreddit-Specific Filters";
    else if (section == native + 1) title = @"Filter Subreddits by Name";
    else title = @"Tag Filters";
    return ApolloPFSectionHeaderView(title);
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (section < native) {
        // Always the native footer — collapsed AND expanded — so it never appears/
        // disappears during the toggle (which made its text flash to the left edge for
        // a frame as it re-laid-out). It just slides down as the rows expand.
        return %orig;
    }
    NSString *text;
    if (section == native) {
        text = @"Hide posts in a specific subreddit by title keyword or post flair. Tap a subreddit to configure. Applies on this device.";
    } else if (section == native + 1) {
        text = @"Hide any subreddit whose name contains one of these words, in feeds and in search (e.g. 'circlejerk' hides r/carscirclejerk). Applies on this device.";
    } else {
        text = @"Filtered posts are covered with a frosted blur over the post's title and thumbnail. Tap the blur to confirm and reveal the post.";
    }
    return ApolloPFSectionFooterView(text);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            // Row 0 = our toggle: flip expanded/collapsed.
            if (indexPath.row == 0) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                BOOL expanded = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
                [self apollo_pfSetBlockedExpanded:!expanded table:tableView];
                return;
            }
            // Apollo's own row (incl. Add User) — mapped so Apollo handles it correctly.
            NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
            NSInteger apolloRow = ApolloPFBlockedApolloRow(indexPath.row, nativeCount);
            %orig(tableView, [NSIndexPath indexPathForRow:apolloRow inSection:indexPath.section]);
            return;
        }
        %orig; return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == native) {
        NSArray<NSString *> *subs = [ApolloPostFilterStore allSubreddits];
        if ((NSUInteger)indexPath.row < subs.count) {
            [self apollo_pfOpenDetailForSubreddit:subs[indexPath.row] fromTable:tableView];
        } else {
            [self apollo_pfPromptAddSubredditFromTable:tableView];
        }
    } else if (indexPath.section == native + 1) {
        NSArray<NSString *> *names = [ApolloPostFilterStore nameSubstrings];
        if ((NSUInteger)indexPath.row >= names.count) {
            [self apollo_pfPromptAddNameFromTable:tableView];
        }
        // Existing name rows: no detail; remove via swipe / Edit.
    } else if (indexPath.row == ApolloTFRowOverrides) {
        [self apollo_tfOpenOverrides];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            if (indexPath.row == 0) return NO; // our toggle row
            NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
            if (indexPath.row >= nativeCount) return NO; // Apollo's "Add User" row (last)
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    if (indexPath.section == native + 2) return NO; // Tag Filters rows are static
    NSArray<NSString *> *items = (indexPath.section == native) ? [ApolloPostFilterStore allSubreddits]
                                                              : [ApolloPostFilterStore nameSubstrings];
    return (NSUInteger)indexPath.row < items.count; // item rows deletable; Add row not
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1) {
            if (indexPath.row == 0) return NO; // our toggle row
            NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
            if (indexPath.row >= nativeCount) return NO; // Apollo's "Add User" row (last)
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1 && indexPath.row >= 1) {
            // Only a user row reaches here (the Add row is non-editable); it maps to
            // Apollo's blockedUsers[] index = display row - 1.
            %orig(tableView, editingStyle, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
            // Refresh our toggle row's "(N)" count after Apollo settles the delete.
            __weak UITableView *wt = tableView;
            __weak typeof(self) ws = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [ws apollo_pfRefreshBlockedToggleCount:wt]; });
            return;
        }
        %orig; return;
    }
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section == native + 2) return; // Tag Filters rows are static
    BOOL isSubSection = (indexPath.section == native);
    NSArray<NSString *> *items = isSubSection ? [ApolloPostFilterStore allSubreddits]
                                              : [ApolloPostFilterStore nameSubstrings];
    if ((NSUInteger)indexPath.row >= items.count) return;
    NSString *item = items[indexPath.row];
    if (isSubSection) [ApolloPostFilterStore removeSubreddit:item];
    else [ApolloPostFilterStore removeNameSubstring:item];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (indexPath.section < native) {
        if (native > 0 && indexPath.section == native - 1 && indexPath.row >= 1) {
            return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section]);
        }
        return %orig;
    }
    return @"Delete";
}

#pragma mark - Added actions

%new
- (void)apollo_pfOpenDetailForSubreddit:(NSString *)sub fromTable:(UITableView *)tableView {
    ApolloSubredditFilterDetailViewController *detail = [[ApolloSubredditFilterDetailViewController alloc] initWithSubreddit:sub];
    __weak UITableView *weakTable = tableView;
    detail.onChange = ^{ [weakTable reloadData]; };
    UIViewController *selfVC = (UIViewController *)self;
    if (selfVC.navigationController) {
        [selfVC.navigationController pushViewController:detail animated:YES];
    } else {
        [selfVC presentViewController:[[UINavigationController alloc] initWithRootViewController:detail] animated:YES completion:nil];
    }
}

%new
- (void)apollo_pfPromptAddSubredditFromTable:(UITableView *)tableView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Filter a Subreddit"
                                                                  message:@"Enter the subreddit to configure (without r/). You'll then add keywords or flairs to hide in it."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"funny";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *sub = [ApolloPostFilterStore normalizeSubreddit:weakAlert.textFields.firstObject.text];
        if (sub.length == 0) return;
        [ApolloPostFilterStore ensureSubreddit:sub];
        [tableView reloadData];
        [self apollo_pfOpenDetailForSubreddit:sub fromTable:tableView];
    }]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

%new
- (void)apollo_pfPromptAddNameFromTable:(UITableView *)tableView {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Filter Subreddits by Name"
                                                                  message:@"Enter a word. Any subreddit whose name contains it is hidden from feeds and search (e.g. 'circlejerk' hides r/carscirclejerk)."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"circlejerk";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *term = [ApolloPostFilterStore normalizeTerm:weakAlert.textFields.firstObject.text];
        if (term.length == 0) return;
        [ApolloPostFilterStore addNameSubstring:term];
        [tableView reloadData];
    }]];
    [(UIViewController *)self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Tag Filters section

// Switch/disclosure cells for the appended Tag Filters section. Fresh cells per
// call (like TagFiltersViewController's own — this table reloads wholesale, no
// per-row reuse to go stale). Theming borrows the same probe row the Blocked
// Users toggle uses.
%new
- (UITableViewCell *)apollo_tfCellForTable:(UITableView *)tableView row:(NSInteger)row {
    UITableViewCell *cell;
    if (row == ApolloTFRowOverrides) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Per-Subreddit Overrides";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.enabled = sTagFilterEnabled;
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        switch (row) {
            case ApolloTFRowEnable:
                cell.textLabel.text = @"Enable Tag Filters";
                sw.on = sTagFilterEnabled;
                [sw addTarget:self action:@selector(apollo_tfEnableChanged:) forControlEvents:UIControlEventValueChanged];
                break;
            case ApolloTFRowNSFW:
                cell.textLabel.text = @"NSFW";
                sw.on = sTagFilterNSFW;
                sw.enabled = sTagFilterEnabled;
                cell.textLabel.enabled = sTagFilterEnabled;
                [sw addTarget:self action:@selector(apollo_tfNSFWChanged:) forControlEvents:UIControlEventValueChanged];
                break;
            case ApolloTFRowSpoiler:
            default:
                cell.textLabel.text = @"Spoiler";
                sw.on = sTagFilterSpoiler;
                sw.enabled = sTagFilterEnabled;
                cell.textLabel.enabled = sTagFilterEnabled;
                [sw addTarget:self action:@selector(apollo_tfSpoilerChanged:) forControlEvents:UIControlEventValueChanged];
                break;
        }
        cell.accessoryView = sw;
    }
    @try {   // borrow the native theme (background); labels stay label-color
        UITableViewCell *probe = [self tableView:tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIColor *c = probe.backgroundColor ?: probe.contentView.backgroundColor;
        if (c && CGColorGetAlpha(c.CGColor) > 0.01) cell.backgroundColor = c;
    } @catch (__unused id e) {}
    return cell;
}

%new
- (void)apollo_tfEnableChanged:(UISwitch *)sw {
    sTagFilterEnabled = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterEnabled];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
    // Re-gate the NSFW/Spoiler/Overrides rows' enabled look.
    UITableView *t = objc_getAssociatedObject(self, kApolloPFBlockedTableKey);
    if ([t isKindOfClass:[UITableView class]]) {
        NSInteger section = [self apollo_pfNativeSectionCount:t] + 2;
        @try { [t reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationNone]; } @catch (__unused id e) {}
    }
}

%new
- (void)apollo_tfNSFWChanged:(UISwitch *)sw {
    sTagFilterNSFW = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterNSFW];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
}

%new
- (void)apollo_tfSpoilerChanged:(UISwitch *)sw {
    sTagFilterSpoiler = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterSpoiler];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
}

%new
- (void)apollo_tfOpenOverrides {
    TagFiltersViewController *vc = [[TagFiltersViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.overridesOnly = YES;
    UIViewController *selfVC = (UIViewController *)self;
    if (selfVC.navigationController) {
        [selfVC.navigationController pushViewController:vc animated:YES];
    } else {
        [selfVC presentViewController:[[UINavigationController alloc] initWithRootViewController:vc] animated:YES completion:nil];
    }
}

#pragma mark - Collapsible Blocked Users toggle

// Row 0 of the Blocked Users section: our themed "Blocked Users (N)" toggle cell, so
// the toggle and the users below it read as ONE continuous rounded group. It is OUR
// OWN cell (dedicated reuse id) so its chevron never leaks onto Apollo's recycled
// cells. Collapsed shows a disclosure chevron (tap to expand); expanded shows a down
// chevron (tap to collapse). The count is read LIVE from Apollo's native row count.
%new
- (UITableViewCell *)apollo_pfBlockedToggleCellForTable:(UITableView *)tableView showingExpanded:(BOOL)showingExpanded {
    NSInteger nativeRows = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
    NSInteger count = MAX((NSInteger)0, nativeRows - 1); // exclude the "Add User" row

    static NSString *const kReuse = @"ApolloPFBlockedUsersToggle";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kReuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kReuse];

    @try {
        UITableViewCell *probe = [self tableView:tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        UIColor *c = probe.backgroundColor ?: probe.contentView.backgroundColor;
        if (c && CGColorGetAlpha(c.CGColor) > 0.01) cell.backgroundColor = c;
    } @catch (__unused id e) {}

    cell.textLabel.text = [NSString stringWithFormat:@"Blocked Users (%ld)", (long)count];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    // Set BOTH accessory slots explicitly so a recycled instance never carries the
    // other state's accessory.
    if (showingExpanded) {
        cell.accessoryType = UITableViewCellAccessoryNone;
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"chevron.down"] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold]]];
        chevron.tintColor = [UIColor secondaryLabelColor];
        [chevron sizeToFit];
        cell.accessoryView = chevron;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

// Re-render just the toggle row so its "(N)" count tracks Apollo's blocked list after
// an unblock (Apollo's delete is async; this catches the count up without disturbing
// the rest of the section).
%new
- (void)apollo_pfRefreshBlockedToggleCount:(UITableView *)tableView {
    if (![tableView isKindOfClass:[UITableView class]]) return;
    if (![objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue]) return;
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (native <= 0) return;
    NSIndexPath *toggle = [NSIndexPath indexPathForRow:0 inSection:native - 1];
    @try { [tableView reloadRowsAtIndexPaths:@[toggle] withRowAnimation:UITableViewRowAnimationNone]; } @catch (__unused id e) {}
}

%new
- (void)apollo_pfSetBlockedExpanded:(BOOL)expanded table:(UITableView *)tableView {
    BOOL was = [objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue];
    objc_setAssociatedObject(self, kApolloPFBlockedExpandedKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![tableView isKindOfClass:[UITableView class]]) return;
    NSInteger native = [self apollo_pfNativeSectionCount:tableView];
    if (native <= 0) return;
    NSInteger section = native - 1;
    NSInteger nativeCount = [objc_getAssociatedObject(self, kApolloPFBlockedNativeCountKey) integerValue];
    // Animate only Apollo's rows (indices 1..nativeCount) in/out — NOT a full
    // reloadSections — so the section's header/footer aren't re-laid-out (that re-layout
    // was flashing the footer text to the left edge for a frame). Row 0 (our toggle)
    // stays put; we just reload it to flip its chevron.
    if (was == expanded || nativeCount <= 0) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    NSMutableArray<NSIndexPath *> *rows = [NSMutableArray arrayWithCapacity:nativeCount];
    for (NSInteger i = 1; i <= nativeCount; i++) [rows addObject:[NSIndexPath indexPathForRow:i inSection:section]];
    @try {
        [tableView beginUpdates];
        if (expanded) [tableView insertRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
        else          [tableView deleteRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
        [tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:section]] withRowAnimation:UITableViewRowAnimationNone];
        [tableView endUpdates];
    } @catch (__unused id e) {
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

// When the user taps the nav-bar Edit button while Blocked Users is collapsed, the lone
// toggle row isn't editable and (selection-during-edit being off) can't be tapped to
// expand — a dead end. Auto-expand on entering edit mode so the blocked rows are
// present and deletable. (Review finding.)
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;
    if (editing && ![objc_getAssociatedObject(self, kApolloPFBlockedExpandedKey) boolValue]) {
        UITableView *t = objc_getAssociatedObject(self, kApolloPFBlockedTableKey);
        if ([t isKindOfClass:[UITableView class]]) [self apollo_pfSetBlockedExpanded:YES table:t];
    }
}

%end

%ctor {
    %init(_TtC6Apollo29SettingsFiltersViewController = objc_getClass("_TtC6Apollo29SettingsFiltersViewController"));
}
