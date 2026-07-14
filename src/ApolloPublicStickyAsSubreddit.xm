// ApolloPublicStickyAsSubreddit.xm
//
// Issue #515: add a 4th post-removal notify option, "Public Sticky from
// Subreddit", that posts the stickied removal comment AS the subreddit
// (u/<Sub>-ModTeam) instead of from the moderator's personal account.
//
// Background (all native Apollo, reverse-engineered from the binary):
//
//   When a mod removes a post and adds a removal reason, Apollo presents a
//   "Notify user via…" menu with three options:
//       "Public Sticky"            (or "Public Reply" for a comment)
//       "Mod Mail from Subreddit"
//       "Mod Mail from You"
//   Picking one walks a short compose flow (message → optional private mod
//   note → submit) that fires TWO RDKClient calls in sequence:
//
//     1. -[RDKClient addRemovalReasonToRemovedThingWithFullName:title:message:
//          type:reasonID:modNote:completion:]
//        POST `api/v1/modactions/removal_reasons` — LOGS the removal reason
//        (reason_id + mod_note). Reddit ignores the `type` here.
//     2. From 1.'s success completion:
//        -[RDKClient sendRemovalReasonForRemovedThingWithFullName:type:title:
//          message:completion:]
//        POST `api/v1/modactions/removal_link_message` (posts) or
//        `…/removal_comment_message` (comments, fullname `t1*`) with
//        item_id/type/title/message — this is what actually SENDS the
//        notification. type = "public" makes REDDIT post the stickied comment
//        (authored by the caller); "private"/"private_exposed" send modmail.
//
//   Reddit's message endpoint (confirmed via PRAW) accepts a FOURTH `type` the
//   three options never use:
//       "public_as_subreddit" -> Reddit posts the sticky as u/<Sub>-ModTeam.
//   So the feature = the same send call with that type. (An earlier revision
//   swapped the `type` on call 1 — the reason-LOGGING endpoint, where Reddit
//   ignores it — so the comment still posted as the moderator. The swap must
//   happen on call 2.)
//
// How the option is added:
//
//   On iOS 26 the tweak's own ApolloNativeActionMenus module converts Apollo's
//   ActionController action sheets into native UIKit context menus
//   (UIMenu/UIAction) — so the "Notify user via…" sheet renders as a UIMenu.
//   `ApolloNativeActionMenuBuildMenu` calls
//   ApolloInjectPublicStickyAsSubredditIfNeeded() (this file) as it builds that
//   menu; for the "Notify user via…" menu we append a 4th UIAction that clones
//   the "Public Sticky"/"Public Reply" action (inheriting its styling) and, on
//   tap, arms a one-shot flag and runs the ORIGINAL action's handler — so the
//   entire native compose flow runs unchanged. Without Liquid Glass the same
//   row is added to the original ActionController table sheet (see the
//   action-sheet section below).
//
//   The RDKClient hook below rewrites type "public" → "public_as_subreddit" on
//   the SEND call while the flag is set, then consumes it. The flag stays armed
//   across the whole compose flow (the send happens inside call 1's async
//   completion) and is re-cleared whenever a fresh "Notify user via…" menu or
//   sheet is built, so a cancelled compose can never leak into a later genuine
//   "Public Sticky". Every other option/path is untouched.
//
// Mod-only and additive: non-mods never see this menu; untouched options behave
// exactly like stock Apollo. No settings toggle.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

// Title prefix of the menu we augment (ellipsis is U+2026; matched with
// hasPrefix so the exact trailing glyph never matters).
static NSString *const kNotifyMenuTitlePrefix = @"Notify user via";

// Title prefix of the action we clone ("Public Sticky" / "Public Reply").
static NSString *const kPublicActionPrefix = @"Public ";

// Suffix that labels (and marks) our injected action.
static NSString *const kAsSubredditSuffix = @" from Subreddit";

// Reddit removal-message `type` values.
static NSString *const kTypePublic            = @"public";
static NSString *const kTypePublicAsSubreddit = @"public_as_subreddit";

// One-shot flag: the next removal submission should go out as the subreddit.
// Armed when our injected action fires; consumed by the RDKClient hook; reset
// each time the "Notify user via…" menu is rebuilt so a cancelled compose can't
// leak into a later genuine "Public Sticky". UI is main-thread only, so a plain
// BOOL is sufficient.
static BOOL sSendNextRemovalAsSubreddit = NO;

#pragma mark - Runtime helper

// Read an object-typed ivar by name, walking the superclass chain. Used to
// recover a UIAction's private handler block so our injected action can run it.
static id PSObjectIvar(id obj, const char *name) {
    Class cls = obj ? object_getClass(obj) : Nil;
    while (cls) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return object_getIvar(obj, iv);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

#pragma mark - Non-Liquid-Glass action-sheet support

// Without Liquid Glass, ApolloNativeActionMenus does NOT convert the sheet to a
// UIMenu, so Apollo presents its real `ActionController` table sheet. We add the
// 4th option there too. Two problems beyond the data source: (1) the sheet
// self-sizes from the controller's own row count (textActions.count), not from
// numberOfRows, so an appended row clips; (2) UITableView throws if cellForRow
// dequeues a foreign indexPath. So we append the row at the end (no remap), build
// its cell by hand with its OWN indexPath, and grow BOTH the presentation frame
// (frameOfPresentedViewInContainerView) and the inner tableView frame
// (viewDidLayoutSubviews) by one row height.

// Original row count of the current Notify sheet (set in numberOfRows); our row
// is appended at this index.
static NSInteger sSheetOrigRowCount = -1;
// Row-0 styling captured as the real rows build, mirrored onto our cell.
static NSString *sSheetBaseTitle = nil;   // "Public Sticky" / "Public Reply"
static UIColor  *sSheetTitleColor = nil;
static UIFont   *sSheetTitleFont = nil;
static NSTextAlignment sSheetTitleAlign = NSTextAlignmentCenter;

// Is this ActionController the removal "Notify user via…" action sheet? Its own
// `tableView:titleForHeaderInSection:` returns the header String (and ignores
// both args), so it's a safe probe.
static BOOL PSIsNotifyActionSheet(id actionController) {
    if (![actionController respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) return NO;
    UITableView *tv = (UITableView *)PSObjectIvar(actionController, "tableView");
    NSString *header = nil;
    @try {
        header = [(id<UITableViewDataSource>)actionController tableView:tv titleForHeaderInSection:0];
    } @catch (__unused NSException *e) {
        return NO;
    }
    return [header isKindOfClass:[NSString class]] && [header hasPrefix:kNotifyMenuTitlePrefix];
}

// Height of one row in the Notify sheet (row 0), used to grow the sheet/table.
static CGFloat PSNotifyRowHeight(id actionController) {
    UITableView *tv = (UITableView *)PSObjectIvar(actionController, "tableView");
    if (![tv isKindOfClass:[UITableView class]]) return 0;
    @try {
        return [(id<UITableViewDelegate>)actionController
                    tableView:tv heightForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    } @catch (__unused NSException *e) {
        return 0;
    }
}

#pragma mark - Menu injection (called from ApolloNativeActionMenuBuildMenu)

// If `menuTitle` is the removal "Notify user via…" menu, append a
// "… from Subreddit" UIAction right after the existing "Public Sticky"/"Public
// Reply" action. The injected action arms the flag, then invokes the original
// action's handler (which runs Apollo's native compose+submit flow); the
// RDKClient hook then rewrites the removal type. No-op for every other menu.
void ApolloInjectPublicStickyAsSubredditIfNeeded(NSMutableArray *children, NSString *menuTitle) {
    if (![menuTitle isKindOfClass:[NSString class]] ||
        ![menuTitle hasPrefix:kNotifyMenuTitlePrefix]) {
        return;
    }
    if (![children isKindOfClass:[NSMutableArray class]]) return;

    // Fresh Notify menu -> disarm, so a previously-cancelled "as subreddit"
    // intent never leaks into a genuine "Public Sticky" chosen later.
    sSendNextRemovalAsSubreddit = NO;

    // Locate the "Public Sticky"/"Public Reply" action to clone. Our injected
    // action is identified by BOTH the "Public " prefix AND the " from
    // Subreddit" suffix — checking the suffix alone would false-match the
    // existing "Mod Mail from Subreddit" option and abort.
    UIAction *publicAction = nil;
    NSUInteger publicIndex = NSNotFound;
    for (NSUInteger i = 0; i < children.count; i++) {
        UIMenuElement *e = children[i];
        if (![e isKindOfClass:[UIAction class]]) continue;
        NSString *t = ((UIAction *)e).title;
        if (![t hasPrefix:kPublicActionPrefix]) continue;
        if ([t hasSuffix:kAsSubredditSuffix]) return; // our action already present
        if (!publicAction) {
            publicAction = (UIAction *)e;
            publicIndex = i;
        }
    }
    if (!publicAction) {
        ApolloLog(@"[PublicStickyAsSub] Notify menu found but no 'Public …' action; leaving as-is");
        return;
    }

    // Recover the original action's handler so ours can run the exact native
    // compose flow after arming the flag.
    void (^publicHandler)(UIAction *) = (void (^)(UIAction *))PSObjectIvar(publicAction, "_handler");
    NSString *newTitle = [publicAction.title stringByAppendingString:kAsSubredditSuffix];

    UIAction *injected =
        [UIAction actionWithTitle:newTitle
                            image:publicAction.image
                       identifier:nil
                          handler:^(__unused __kindof UIAction *action) {
            ApolloLog(@"[PublicStickyAsSub] '%@' tapped; arming + running native public-sticky flow", newTitle);
            sSendNextRemovalAsSubreddit = YES;
            if (publicHandler) {
                publicHandler(publicAction);
            } else {
                ApolloLog(@"[PublicStickyAsSub] WARN: original 'Public …' handler was nil");
            }
        }];
    injected.attributes = publicAction.attributes;

    // Match the original action's title color (Apollo tints these moderator
    // actions green via a private attributedTitle); copy whatever color it has
    // so our clone never looks out of place, in any menu style.
    NSAttributedString *origAttributed = nil;
    @try {
        origAttributed = [publicAction valueForKey:@"attributedTitle"];
    } @catch (__unused NSException *e) {
        origAttributed = (NSAttributedString *)PSObjectIvar(publicAction, "_attributedTitle");
    }
    if ([origAttributed isKindOfClass:[NSAttributedString class]] && origAttributed.length > 0) {
        UIColor *color = [origAttributed attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        if (color && [injected respondsToSelector:@selector(setAttributedTitle:)]) {
            NSAttributedString *attr = [[NSAttributedString alloc] initWithString:newTitle
                                                                      attributes:@{NSForegroundColorAttributeName: color}];
            ((void (*)(id, SEL, id))objc_msgSend)(injected, @selector(setAttributedTitle:), attr);
        }
    }

    [children insertObject:injected atIndex:publicIndex + 1];
    ApolloLog(@"[PublicStickyAsSub] injected '%@' into Notify menu (now %lu items)",
              newTitle, (unsigned long)children.count);
}

#pragma mark - Action-sheet row injection (non-Liquid-Glass)

%hook _TtC6Apollo16ActionController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger n = %orig;
    if (PSIsNotifyActionSheet(self)) {
        sSheetOrigRowCount = n;            // our row is appended at this index
        sSendNextRemovalAsSubreddit = NO;  // fresh sheet display -> disarm
        n += 1;
    }
    return n;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!PSIsNotifyActionSheet(self)) return %orig;

    if (indexPath.row != sSheetOrigRowCount) {
        // Real row — build normally (correct indexPath, no remap). Capture row
        // 0's styling to mirror on our row.
        UITableViewCell *cell = %orig;
        if (indexPath.row == 0) {
            UILabel *label = (UILabel *)PSObjectIvar(cell, "actionTitleLabel");
            if ([label isKindOfClass:[UILabel class]]) {
                sSheetBaseTitle  = [label.text copy];
                sSheetTitleColor = label.textColor;
                sSheetTitleFont  = label.font;
                sSheetTitleAlign = label.textAlignment;
            }
        }
        return cell;
    }

    // Our appended row — built by hand with ITS OWN indexPath (no foreign
    // dequeue, so no exception), styled to match row 0.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:@"ApolloPublicStickyAsSubRow"];
    cell.backgroundColor = [UIColor clearColor];
    NSString *base = sSheetBaseTitle.length ? sSheetBaseTitle : @"Public Sticky";
    cell.textLabel.text = [base stringByAppendingString:kAsSubredditSuffix];
    cell.textLabel.textAlignment = sSheetTitleAlign;
    if (sSheetTitleFont)  cell.textLabel.font = sSheetTitleFont;
    if (sSheetTitleColor) cell.textLabel.textColor = sSheetTitleColor;
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!PSIsNotifyActionSheet(self)) return %orig;
    NSIndexPath *src = (indexPath.row == sSheetOrigRowCount)
        ? [NSIndexPath indexPathForRow:0 inSection:indexPath.section]
        : indexPath;
    return %orig(tableView, src);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!PSIsNotifyActionSheet(self) || indexPath.row != sSheetOrigRowCount) { %orig; return; }
    // Our appended row: arm the flag, then run row 0's native handler.
    sSendNextRemovalAsSubreddit = YES;
    ApolloLog(@"[PublicStickyAsSub] (sheet) 'from Subreddit' tapped; arming + running row-0 flow");
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    %orig(tableView, [NSIndexPath indexPathForRow:0 inSection:indexPath.section]);
}

// The inner tableView is sized from the controller's own row count, so grow it
// by one row so our appended row isn't clipped within the table.
- (void)viewDidLayoutSubviews {
    %orig;
    if (!PSIsNotifyActionSheet(self)) return;
    UITableView *tv = (UITableView *)PSObjectIvar(self, "tableView");
    if (![tv isKindOfClass:[UITableView class]]) return;
    CGFloat rh = PSNotifyRowHeight(self);
    if (rh <= 0) return;
    CGRect f = tv.frame;
    f.size.height += rh;
    tv.frame = f;
}

%end

// The bottom sheet's overall frame is computed from the controller's row count
// too; grow it upward by one row so the taller table fits.
%hook _TtC6Apollo38ActionControllerPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect f = %orig;
    UIViewController *avc = [(UIPresentationController *)self presentedViewController];
    if (f.size.height > 0 && PSIsNotifyActionSheet(avc)) {
        CGFloat rh = PSNotifyRowHeight(avc);
        if (rh > 0) {
            f.origin.y -= rh;     // grow upward (bottom sheet)
            f.size.height += rh;
        }
    }
    return f;
}

%end

#pragma mark - Type rewrite at the API boundary

// The swap happens on the SEND call (removal_link_message /
// removal_comment_message) — the one whose `type` Reddit honors — NOT on the
// reason-logging call (removal_reasons), which fires first and ignores `type`.
// The flag is consumed here (one-shot); it survives the async gap between the
// two calls because nothing else can rebuild the Notify menu mid-flow, and any
// abandoned compose is disarmed the next time a Notify menu/sheet is built.
%hook RDKClient

- (id)sendRemovalReasonForRemovedThingWithFullName:(id)fullName
                                              type:(id)type
                                             title:(id)title
                                           message:(id)message
                                        completion:(id)completion {
    if (sSendNextRemovalAsSubreddit) {
        sSendNextRemovalAsSubreddit = NO; // consume regardless, one-shot
        if ([type isKindOfClass:[NSString class]] && [type isEqualToString:kTypePublic]) {
            ApolloLog(@"[PublicStickyAsSub] rewriting removal-message type 'public' -> 'public_as_subreddit' for %@", fullName);
            type = kTypePublicAsSubreddit;
        } else {
            ApolloLog(@"[PublicStickyAsSub] flag set but send type was %@ (not 'public'); left unchanged", type);
        }
    }
    // Explicit args: bare %orig would re-pass the ORIGINAL captured `type`,
    // discarding our rewrite (see CLAUDE.md Logos note).
    return %orig(fullName, type, title, message, completion);
}

%end
