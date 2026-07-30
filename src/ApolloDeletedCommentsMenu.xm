// Deleted-comments shortcut in the comments "..." menu + passive per-thread mode.
//
// Adds a "Show Deleted Comments" / "Hide Deleted Comments" item to the comments
// view's overflow menu. Liquid Glass uses the native UIMenu assembled by
// ApolloNativeActionMenus.xm; Standard/pre-Liquid-Glass builds append an
// equivalent row to Apollo's legacy ActionController table.
//
// Two behaviors, decided by the "Passive Deleted Comments" setting:
//   - Passive OFF: the item is a plain shortcut for the global Show Deleted
//     Comments toggle (with the same slowdown warning the settings switch shows).
//   - Passive ON (and global toggle off): the item turns recovery on for THIS
//     post's thread only, via a thread override in ApolloDeletedCommentsData.
//     The override dies when the last comments view showing that post is popped
//     or dismissed, so the next thread starts with recovery off again.
//
// After either toggle the thread is re-fetched through Apollo's own
// pull-to-refresh action so the recovered (or re-hidden) comments appear
// without leaving the screen.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

static NSString *const kApolloDCMenuShowTitle = @"Show Deleted Comments";
static NSString *const kApolloDCMenuHideTitle = @"Hide Deleted Comments";

// The comments VC currently presenting its "..." menu. Armed in the tap hook
// below; menu construction happens synchronously inside that tap (see
// ApolloNativeActionMenus' Begin/EndCapture bracket), but a short grace window
// keeps this robust if UIKit ever defers a runloop turn. The FIRST menu built
// while armed consumes the arm (the ActionController gets tagged with the
// owning VC below), so a different menu opened moments later can never pick
// up the item.
static __weak id sApolloDCMenuArmedVC = nil;
static CFAbsoluteTime sApolloDCMenuArmedAt = 0;

// Tag on the ActionController that IS the comments "..." menu: a weak-objects
// hash table holding the owning CommentsViewController (a plain weak assoc
// isn't possible with objc_setAssociatedObject).
static char kApolloDCMenuOwnerVCKey;
// Row count before our appended legacy ActionController row.
static char kApolloDCMenuOrigRowCountKey;

// linkFullName key -> weak set of CommentsViewController instances currently
// showing that post's thread. Main-thread only. When the last live VC for an
// overridden link leaves, the override is cleared.
static NSMutableDictionary<NSString *, NSHashTable *> *sApolloDCOverrideVCsByLink = nil;

// Every live CommentsViewController (weak, self-cleaning). Needed when an
// override is enabled from a nested "Continue this thread" push: the ancestor
// VCs showing the same post must be tracked too, or popping the nested VC
// would clear the override out from under the still-visible ancestor.
static NSHashTable *sApolloDCAllCommentsVCs = nil;

#pragma mark - Helpers

static id ApolloDCMenuIvarObject(id object, const char *name) {
    if (!object || !name) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(object, ivar);
    }
    return nil;
}

// Resolve and permanently tag the ActionController presenting the armed
// comments menu. Both the Liquid Glass UIMenu builder and the legacy table
// sheet use this same one-shot claim, whichever asks first.
static id ApolloDCMenuOwnerForController(id actionController) {
    if (!actionController) return nil;
    NSHashTable *holder = objc_getAssociatedObject(actionController, &kApolloDCMenuOwnerVCKey);
    if (holder) return holder.anyObject;

    id vc = sApolloDCMenuArmedVC;
    if (!vc) return nil;
    if (CFAbsoluteTimeGetCurrent() - sApolloDCMenuArmedAt > 1.5) {
        sApolloDCMenuArmedVC = nil;
        return nil;
    }

    holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:vc];
    objc_setAssociatedObject(actionController, &kApolloDCMenuOwnerVCKey,
                             holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sApolloDCMenuArmedVC = nil;
    return vc;
}

// Post fullName (t3_xxx, lowercased) for a CommentsViewController, from its
// RDKLink ivar. Nil until the first fetch completes (URL-scheme opens), but by
// the time the "..." menu is usable the link is loaded.
static NSString *ApolloDCMenuLinkKeyForVC(id vc) {
    id link = ApolloDCMenuIvarObject(vc, "link");
    if (!link) return nil;
    NSString *fullName = nil;
    if ([link respondsToSelector:@selector(fullName)]) {
        fullName = ((NSString *(*)(id, SEL))objc_msgSend)(link, @selector(fullName));
    }
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) {
        if ([link respondsToSelector:@selector(identifier)]) {
            NSString *identifier = ((NSString *(*)(id, SEL))objc_msgSend)(link, @selector(identifier));
            if ([identifier isKindOfClass:[NSString class]] && identifier.length > 0) {
                fullName = [@"t3_" stringByAppendingString:identifier];
            }
        }
    }
    if (![fullName isKindOfClass:[NSString class]] || fullName.length == 0) return nil;
    return [fullName lowercaseString];
}

static void ApolloDCMenuTrackVC(NSString *key, id vc) {
    if (key.length == 0 || !vc) return;
    if (!sApolloDCOverrideVCsByLink) sApolloDCOverrideVCsByLink = [NSMutableDictionary dictionary];
    NSHashTable *table = sApolloDCOverrideVCsByLink[key];
    if (!table) {
        table = [NSHashTable weakObjectsHashTable];
        sApolloDCOverrideVCsByLink[key] = table;
    }
    [table addObject:vc];
}

static void ApolloDCMenuUntrackVCAndMaybeClear(NSString *key, id vc) {
    if (key.length == 0) return;
    NSHashTable *table = sApolloDCOverrideVCsByLink[key];
    if (vc) [table removeObject:vc];
    if (table.allObjects.count == 0) {
        [sApolloDCOverrideVCsByLink removeObjectForKey:key];
        ApolloDeletedCommentsSetThreadOverride(key, NO);
        ApolloLog(@"[DeletedCommentsMenu] Cleared per-thread override for %@ (last thread view left)", key);
    }
}

// Self-heal: an override whose every VC deallocated without a clean pop (e.g.
// a torn-down navigation stack) would linger forever; drop those.
static void ApolloDCMenuSweepDeadOverrides(void) {
    if (sApolloDCOverrideVCsByLink.count == 0) return;
    for (NSString *key in sApolloDCOverrideVCsByLink.allKeys) {
        if ([sApolloDCOverrideVCsByLink[key] allObjects].count == 0) {
            ApolloDCMenuUntrackVCAndMaybeClear(key, nil);
        }
    }
}

// Re-fetch the thread through Apollo's own pull-to-refresh action so the
// recovered (or re-hidden) comments appear in place.
static void ApolloDCMenuRefreshComments(id vc) {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([vc respondsToSelector:@selector(refreshControlActivatedWithSender:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(refreshControlActivatedWithSender:), nil);
            ApolloLog(@"[DeletedCommentsMenu] Triggered comments refresh after toggle");
        } else {
            ApolloLog(@"[DeletedCommentsMenu] WARN: refreshControlActivatedWithSender: missing; pull to refresh manually");
        }
    });
}

static void ApolloDCMenuPresentSlowdownWarning(id vc) {
    // Give the context menu's dismissal animation a beat before presenting.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *host = (UIViewController *)vc;
        if (![host isKindOfClass:[UIViewController class]] || !host.viewLoaded || !host.view.window) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚠️ WARNING"
                                                                       message:@"This feature can slow down comment loading. If you notice comments loading slowly, turn this feature off."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter = host.presentedViewController ?: host;
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void ApolloDCMenuHandleToggle(id vc, NSString *linkKey, BOOL wasEffective) {
    if (wasEffective) {
        if (linkKey.length > 0 && ApolloDeletedCommentsHasThreadOverride(linkKey)) {
            [sApolloDCOverrideVCsByLink removeObjectForKey:linkKey];
            ApolloDeletedCommentsSetThreadOverride(linkKey, NO);
        }
        if (sShowDeletedComments) {
            sShowDeletedComments = NO;
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyShowDeletedComments];
            ApolloLog(@"[DeletedCommentsMenu] Global Show Deleted Comments turned OFF from comments menu");
        }
    } else if (sPassiveDeletedComments) {
        // Never set an override without a live VC to hang it on — it could
        // never be cleared (nothing would ever untrack it).
        if (!vc) {
            ApolloLog(@"[DeletedCommentsMenu] WARN: comments VC gone before toggle; ignoring");
            return;
        }
        ApolloDeletedCommentsSetThreadOverride(linkKey, YES);
        ApolloDCMenuTrackVC(linkKey, vc);
        // Track ancestor/sibling comments views of the SAME post (nested
        // "Continue this thread" pushes) so popping the one that enabled the
        // override doesn't clear it while another is still on the stack.
        for (id other in sApolloDCAllCommentsVCs.allObjects) {
            if (other != vc && [ApolloDCMenuLinkKeyForVC(other) isEqualToString:linkKey]) {
                ApolloDCMenuTrackVC(linkKey, other);
            }
        }
        ApolloLog(@"[DeletedCommentsMenu] Passive per-thread override ON for %@", linkKey);
    } else {
        sShowDeletedComments = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UDKeyShowDeletedComments];
        ApolloLog(@"[DeletedCommentsMenu] Global Show Deleted Comments turned ON from comments menu");
        ApolloDCMenuPresentSlowdownWarning(vc);
    }
    ApolloDCMenuRefreshComments(vc);
}

#pragma mark - Menu injection (called from ApolloNativeActionMenuBuildMenu)

void ApolloInjectDeletedCommentsMenuItemIfNeeded(NSMutableArray *children, NSString *menuTitle, id actionController) {
    (void)menuTitle;
    if (!children || children.count == 0) return;

    // Re-builds of an already-claimed "..." menu (the builder runs more than
    // once per presentation) reuse the tag; otherwise the FIRST menu built
    // while armed claims the armed VC and consumes the arm, so a different
    // menu opened within the grace window can never pick up the item.
    id vc = ApolloDCMenuOwnerForController(actionController);
    if (!vc) return;

    NSString *linkKey = ApolloDCMenuLinkKeyForVC(vc);
    BOOL passive = sPassiveDeletedComments && !sShowDeletedComments;
    // Per-thread toggling needs a post to key the override on.
    if (passive && linkKey.length == 0) return;

    BOOL effective = sShowDeletedComments || (linkKey.length > 0 && ApolloDeletedCommentsHasThreadOverride(linkKey));
    NSString *title = effective ? kApolloDCMenuHideTitle : kApolloDCMenuShowTitle;
    UIImage *image = [UIImage systemImageNamed:(effective ? @"eye.slash" : @"eye")];

    __weak id weakVC = vc;
    UIAction *toggle = [UIAction actionWithTitle:title
                                           image:image
                                      identifier:nil
                                         handler:^(__unused __kindof UIAction *action) {
        ApolloDCMenuHandleToggle(weakVC, linkKey, effective);
    }];
    [children addObject:toggle];
    ApolloLog(@"[DeletedCommentsMenu] Injected '%@' (passive=%d, link=%@)", title, passive, linkKey ?: @"-");
}

#pragma mark - CommentsViewController lifecycle

%hook _TtC6Apollo22CommentsViewController

- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    sApolloDCMenuArmedVC = self;
    sApolloDCMenuArmedAt = CFAbsoluteTimeGetCurrent();
    %orig;
    // The arm is consumed by the first menu build (see the injection function);
    // the timestamp grace window expires it if no menu was built at all.
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!sApolloDCAllCommentsVCs) sApolloDCAllCommentsVCs = [NSHashTable weakObjectsHashTable];
    [sApolloDCAllCommentsVCs addObject:self];
    ApolloDCMenuSweepDeadOverrides();
    NSString *linkKey = ApolloDCMenuLinkKeyForVC(self);
    if (linkKey.length > 0 && ApolloDeletedCommentsHasThreadOverride(linkKey)) {
        // Nested "Continue this thread" pushes of the same post keep the
        // override alive until the whole thread is left.
        ApolloDCMenuTrackVC(linkKey, self);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // Only a pop/dismissal means the user left the thread; presentations
    // (media viewer, share sheet) and pushes deeper must not clear anything.
    UIViewController *vc = (UIViewController *)self;
    BOOL leaving = [vc isMovingFromParentViewController] ||
                   [vc isBeingDismissed] ||
                   [vc.navigationController isBeingDismissed];
    if (!leaving) return;
    NSString *linkKey = ApolloDCMenuLinkKeyForVC(self);
    if (linkKey.length == 0 || !ApolloDeletedCommentsHasThreadOverride(linkKey)) return;
    ApolloDCMenuUntrackVCAndMaybeClear(linkKey, self);
}

%end

#pragma mark - Legacy ActionController row (Standard / pre-Liquid-Glass)

// Apollo's non-Liquid-Glass overflow menu is an ActionController-backed table
// sheet. Keep every native row at its original index and append ours: Apollo's
// own cell builder dequeues with the supplied index path and will assert if
// native rows are shifted.
static NSInteger ApolloDCMenuOriginalRowCount(id actionController) {
    NSNumber *stored = objc_getAssociatedObject(actionController, &kApolloDCMenuOrigRowCountKey);
    return stored ? stored.integerValue : -1;
}

static BOOL ApolloDCMenuResolveState(id actionController, id *outVC,
                                     NSString **outLinkKey, BOOL *outEffective) {
    id vc = ApolloDCMenuOwnerForController(actionController);
    if (!vc) return NO;
    NSString *linkKey = ApolloDCMenuLinkKeyForVC(vc);
    BOOL passive = sPassiveDeletedComments && !sShowDeletedComments;
    if (passive && linkKey.length == 0) return NO;
    BOOL effective = sShowDeletedComments ||
        (linkKey.length > 0 && ApolloDeletedCommentsHasThreadOverride(linkKey));
    if (outVC) *outVC = vc;
    if (outLinkKey) *outLinkKey = linkKey;
    if (outEffective) *outEffective = effective;
    return YES;
}

static BOOL ApolloDCMenuIsLegacyRow(id actionController, NSIndexPath *indexPath) {
    NSInteger originalCount = ApolloDCMenuOriginalRowCount(actionController);
    return originalCount >= 0 && indexPath.section == 0 && indexPath.row == originalCount;
}

static CGFloat ApolloDCMenuLegacyRowHeight(id actionController) {
    id tableView = ApolloDCMenuIvarObject(actionController, "tableView");
    if (![tableView isKindOfClass:[UITableView class]] ||
        ![actionController respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)]) {
        return 0.0;
    }
    @try {
        return [(id<UITableViewDelegate>)actionController
                    tableView:(UITableView *)tableView
                    heightForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

// Apollo's sheet rows use custom labels/icons rather than UITableViewCell's
// stock textLabel geometry. Capture row 0 and mirror its presentation so the
// appended row remains readable under stock and custom themes.
static UIView *ApolloDCMenuFirstSubviewOfClass(UIView *root, Class cls, BOOL requireText) {
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:cls]) {
            if (!requireText) return subview;
            if ([subview isKindOfClass:[UILabel class]] &&
                ((UILabel *)subview).text.length > 0) {
                return subview;
            }
        }
        UIView *nested = ApolloDCMenuFirstSubviewOfClass(subview, cls, requireText);
        if (nested) return nested;
    }
    return nil;
}

static UIColor *sApolloDCMenuTitleColor = nil;
static UIFont *sApolloDCMenuTitleFont = nil;
static NSTextAlignment sApolloDCMenuTitleAlignment = NSTextAlignmentLeft;
static CGRect sApolloDCMenuTitleFrame = CGRectZero;
static CGRect sApolloDCMenuIconFrame = CGRectZero;
static UIColor *sApolloDCMenuIconTint = nil;

static void ApolloDCMenuCaptureLegacyRowStyle(UITableViewCell *cell) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return;
    [cell layoutIfNeeded];
    UILabel *label =
        (UILabel *)ApolloDCMenuFirstSubviewOfClass(cell, [UILabel class], YES);
    if (!label) return;
    sApolloDCMenuTitleColor = label.textColor;
    sApolloDCMenuTitleFont = label.font;
    sApolloDCMenuTitleAlignment = label.textAlignment;
    sApolloDCMenuTitleFrame = [label convertRect:label.bounds toView:cell];

    UIImageView *icon =
        (UIImageView *)ApolloDCMenuFirstSubviewOfClass(cell, [UIImageView class], NO);
    if (icon.bounds.size.width > 1.0) {
        sApolloDCMenuIconFrame = [icon convertRect:icon.bounds toView:cell];
        sApolloDCMenuIconTint = icon.tintColor;
    }
}

@interface ApolloDeletedCommentsMenuRowCell : UITableViewCell
@property (nonatomic, strong) UILabel *apolloTitleLabel;
@property (nonatomic, strong) UIImageView *apolloIconView;
- (void)configureEffective:(BOOL)effective;
@end

@implementation ApolloDeletedCommentsMenuRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        UIColor *accent =
            sApolloDCMenuTitleColor ?: ApolloThemeAccentColor() ?: UIColor.labelColor;

        _apolloIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _apolloIconView.contentMode = UIViewContentModeScaleAspectFit;
        _apolloIconView.tintColor = sApolloDCMenuIconTint ?: accent;
        [self.contentView addSubview:_apolloIconView];

        _apolloTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _apolloTitleLabel.textColor = accent;
        _apolloTitleLabel.font = sApolloDCMenuTitleFont ?: [UIFont systemFontOfSize:17.0];
        _apolloTitleLabel.textAlignment = sApolloDCMenuTitleAlignment;
        [self.contentView addSubview:_apolloTitleLabel];
    }
    return self;
}

- (void)configureEffective:(BOOL)effective {
    self.apolloTitleLabel.text =
        effective ? kApolloDCMenuHideTitle : kApolloDCMenuShowTitle;
    self.apolloIconView.image =
        [UIImage systemImageNamed:(effective ? @"eye.slash" : @"eye")];
    self.accessibilityLabel = self.apolloTitleLabel.text;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;
    if (!CGRectIsEmpty(sApolloDCMenuIconFrame)) {
        CGRect iconFrame = sApolloDCMenuIconFrame;
        iconFrame.origin.y = (bounds.size.height - iconFrame.size.height) / 2.0;
        self.apolloIconView.frame = iconFrame;
        self.apolloIconView.hidden = NO;
    } else {
        self.apolloIconView.hidden = YES;
    }

    CGFloat left = CGRectIsEmpty(sApolloDCMenuTitleFrame)
        ? 16.0
        : CGRectGetMinX(sApolloDCMenuTitleFrame);
    CGFloat height = CGRectIsEmpty(sApolloDCMenuTitleFrame)
        ? 22.0
        : CGRectGetHeight(sApolloDCMenuTitleFrame);
    self.apolloTitleLabel.frame =
        CGRectMake(left, (bounds.size.height - height) / 2.0,
                   MAX(0.0, bounds.size.width - left - 16.0), height);
}

@end

%hook _TtC6Apollo16ActionController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger count = %orig;
    if (section != 0 || !ApolloDCMenuResolveState(self, NULL, NULL, NULL)) return count;
    objc_setAssociatedObject(self, &kApolloDCMenuOrigRowCountKey,
                             @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return count + 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloDCMenuIsLegacyRow(self, indexPath)) {
        UITableViewCell *cell = %orig;
        if (ApolloDCMenuOriginalRowCount(self) >= 0 &&
            indexPath.section == 0 && indexPath.row == 0) {
            ApolloDCMenuCaptureLegacyRowStyle(cell);
        }
        return cell;
    }

    BOOL effective = NO;
    BOOL hasOwner = ApolloDCMenuResolveState(self, NULL, NULL, &effective);
    ApolloDeletedCommentsMenuRowCell *cell =
        [[ApolloDeletedCommentsMenuRowCell alloc]
            initWithStyle:UITableViewCellStyleDefault
          reuseIdentifier:@"ApolloDeletedCommentsMenuRow"];
    [cell configureEffective:effective];
    // UITableView requires a non-nil cell for every row previously reported by
    // the data source. The presenting comments controller should stay alive for
    // the sheet's lifetime, but if UIKit asks during teardown after that weak
    // owner disappears, return an inert row rather than violating the contract.
    if (!hasOwner) {
        cell.userInteractionEnabled = NO;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloDCMenuIsLegacyRow(self, indexPath)) return %orig;
    return %orig(tableView, [NSIndexPath indexPathForRow:0 inSection:indexPath.section]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloDCMenuIsLegacyRow(self, indexPath)) {
        %orig;
        return;
    }

    id vc = nil;
    NSString *linkKey = nil;
    BOOL effective = NO;
    if (!ApolloDCMenuResolveState(self, &vc, &linkKey, &effective)) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [(UIViewController *)self dismissViewControllerAnimated:YES completion:^{
        ApolloDCMenuHandleToggle(vc, linkKey, effective);
    }];
}

%end

// Apollo sizes the sheet from its original data-source row count. Grow only
// the presentation frame so the appended row is reachable above Cancel.
%hook _TtC6Apollo38ActionControllerPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    UIViewController *presented =
        [(UIPresentationController *)self presentedViewController];
    if (frame.size.height <= 0.0 || ApolloDCMenuOriginalRowCount(presented) < 0) {
        return frame;
    }
    CGFloat rowHeight = ApolloDCMenuLegacyRowHeight(presented);
    if (rowHeight <= 0.0) return frame;
    frame.origin.y -= rowHeight;
    frame.size.height += rowHeight;
    return frame;
}

%end
