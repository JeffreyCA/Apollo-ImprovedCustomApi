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
//   Row rendering on both the Liquid Glass UIMenu and the legacy
//   ActionController sheet is owned by ApolloActionMenu.{h,xm} — see that
//   header for the single-owner rationale. This spec is the one case that
//   can't be purely declarative on the glass path: rather than build a new
//   UIMenuElement, it CLONES "Public Sticky"/"Public Reply"'s own UIMenuElement
//   (title/image/attributes/attributedTitle color) via `buildElement`, so the
//   clone inherits the moderator-green tint ApolloNativeActionMenus.xm applies,
//   and wires its tap to arm a one-shot flag then run the ORIGINAL action's
//   handler — so the entire native compose flow runs unchanged. On the legacy
//   path the owner's shared row cell is used instead (via the declarative
//   `title`/`perform`/`legacyDismissesSheet` below), with `perform` re-running
//   row 0's own native tap handler through ApolloActionMenuInvokeNativeRow().
//
//   The RDKClient hook below rewrites type "public" → "public_as_subreddit" on
//   the SEND call while the flag is set, then consumes it. The flag stays armed
//   across the whole compose flow (the send happens inside call 1's async
//   completion) and is re-cleared whenever a fresh "Notify user via…" menu or
//   sheet is matched (see `matches` below), so a cancelled compose can never
//   leak into a later genuine "Public Sticky". Every other option/path is
//   untouched.
//
// Mod-only and additive: non-mods never see this menu; untouched options behave
// exactly like stock Apollo. No settings toggle.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloActionMenu.h"
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
// each time a fresh "Notify user via…" menu is matched so a cancelled compose
// can't leak into a later genuine "Public Sticky". UI is main-thread only, so a
// plain BOOL is sufficient.
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

#pragma mark - Type rewrite at the API boundary

// The swap happens on the SEND call (removal_link_message /
// removal_comment_message) — the one whose `type` Reddit honors — NOT on the
// reason-logging call (removal_reasons), which fires first and ignores `type`.
// The flag is consumed here (one-shot); it survives the async gap between the
// two calls because nothing else can rebuild the Notify menu mid-flow, and any
// abandoned compose is disarmed the next time a Notify menu/sheet is matched.
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

#pragma mark - Registration

%ctor {
    %init;

    ApolloActionMenuSpec *spec = [ApolloActionMenuSpec new];
    spec.identifier = @"PublicStickyAsSubreddit";
    // Legacy row has no icon in the original design; the native "Notify user
    // via…" rows are plain colored text, so the shared cell's icon stays empty
    // regardless (no non-nil `image` block needed).
    spec.legacyDismissesSheet = NO; // perform forwards into row 0's own handler, which self-dismisses.

    spec.matches = ^BOOL(id actionController, NSString *menuTitle) {
        (void)actionController;
        if (![menuTitle hasPrefix:kNotifyMenuTitlePrefix]) return NO;
        // Fresh Notify menu -> disarm. Memoized to run exactly once per sheet
        // instance (ApolloActionMenu.xm), which is the correct granularity: a
        // genuinely NEW sheet is what should disarm a stale intent, not every
        // rebuild of the SAME sheet.
        sSendNextRemovalAsSubreddit = NO;
        return YES;
    };

    // Legacy path only: title mirrors row 0's own rendered text (Apollo's rows
    // are custom-drawn, not built on UITableViewCell.textLabel) plus our suffix.
    spec.title = ^NSString *(id actionController, UITableViewCell *donor) {
        (void)actionController;
        NSString *base = ApolloActionMenuDonorLabelText(donor);
        if (base.length == 0) base = @"Public Sticky";
        return [base stringByAppendingString:kAsSubredditSuffix];
    };

    // Legacy path only: re-run row 0's own native handler — the exact compose
    // flow "Public Sticky"/"Public Reply" runs — after arming the flag that
    // makes the RDKClient hook above rewrite the removal type.
    spec.perform = ^(id actionController) {
        sSendNextRemovalAsSubreddit = YES;
        ApolloLog(@"[PublicStickyAsSub] (sheet) 'from Subreddit' tapped; arming + running row-0 flow");
        ApolloActionMenuInvokeNativeRow(actionController, 0);
    };

    // Glass path only: clone the native "Public Sticky"/"Public Reply"
    // UIMenuElement rather than building a new one, so the clone inherits
    // whatever styling (including the moderator-green tint) the real action
    // already carries, and its tap runs the REAL action's own handler.
    spec.buildElement = ^(id actionController, NSMutableArray<UIMenuElement *> *children) {
        (void)actionController;
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

        // Recover the original action's handler so ours can run the exact
        // native compose flow after arming the flag.
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

        // Match the original action's title color (Apollo tints these
        // moderator actions green via a private attributedTitle); copy
        // whatever color it has so our clone never looks out of place.
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
    };

    ApolloActionMenuRegister(spec);
    ApolloLog(@"[PublicStickyAsSub] Public Sticky as Subreddit spec registered");
}
