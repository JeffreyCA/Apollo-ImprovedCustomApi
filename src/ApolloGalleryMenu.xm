// ApolloGalleryMenu.xm
//
// Puts "Gallery View" in a subreddit or multireddit's nav-bar "..." menu, and
// opens ApolloGalleryViewController when it's picked.
//
// Apollo draws that menu two different ways, so the row has to be added twice:
//
//   • Liquid Glass — the tweak's own ApolloNativeActionMenus module converts
//     Apollo's ActionController sheet into a real UIKit UIMenu. It calls
//     ApolloInjectGalleryViewMenuItemIfNeeded() while building the children, the
//     same seam ApolloDeletedCommentsMenu and ApolloPublicStickyAsSubreddit use.
//     We insert an inline single-item section just below the leading "submit a
//     post" affordance, so the row reads as its own group without displacing
//     the composer that leads the menu.
//
//   • Everything else — the ActionController presents itself as a table sheet.
//     We append a row to the END of its data source and grow the presentation
//     frame by one row height so the taller table still fits, mirroring what
//     ApolloPublicStickyAsSubreddit does for the removal "Notify user via…"
//     sheet. Appending (rather than inserting at the top, where it would match
//     the glass menu) is forced: Apollo's own cellForRow calls
//     -dequeueReusableCellWithIdentifier:forIndexPath: with the index path it
//     was handed, and UIKit asserts if a shifted path is passed through, so the
//     native rows have to keep their own indices. (On Liquid Glass these hooks
//     still run, because the sheet is built before ApolloNativeActionMenus
//     hides and swaps it — harmless, since that view never reaches the screen
//     and the UIMenu is built from Apollo's Swift `actions` array, not from the
//     table.)
//
// Which sheet is ours: the "..." menu has no header title to match on, so we
// arm on -[PostsViewController moreOptionsBarButtonItemTappedWithSender:] and
// let the first ActionController built inside a short grace window claim the
// arm — the same one-shot claim ApolloDeletedCommentsMenu uses for the comments
// "..." menu. The claim is recorded on the controller so repeat builds of the
// same sheet re-inject, and no later, unrelated sheet can pick it up.
//
// Popular/All, profile feeds and search results never get the row: subreddit
// slugs and canonical multireddit paths are resolved by ApolloSubredditHeaders,
// whose helpers gate on Apollo's own PostsType tag.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloGalleryViewController.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloThemeRuntime.h"

// Defined in ApolloSubredditHeaders.xm — resolves the slug for a genuine
// single-subreddit feed, and nil for anything else (multireddit, Popular/All,
// profile/special feeds).
extern NSString *ApolloSubredditNameFromViewController(UIViewController *viewController);
extern NSString *ApolloMultiredditPathFromViewController(UIViewController *viewController);

static NSString *const kApolloGalleryMenuTitle = @"Gallery View";
static NSString *const kApolloGalleryMenuSymbol = @"square.grid.2x2";

// How long after the "..." tap an ActionController may still claim the arm.
static const CFTimeInterval kApolloGalleryMenuArmGraceSeconds = 1.5;

// The PostsViewController whose "..." was just tapped, and when.
static __weak UIViewController *sApolloGalleryArmedVC = nil;
static CFTimeInterval sApolloGalleryArmedAt = 0.0;

// Set on an ActionController once it has claimed the arm: an NSHashTable
// holding the owning PostsViewController weakly (a plain associated object
// would keep the view controller alive).
static char kApolloGalleryMenuOwnerKey;
// Row count the sheet reported before we appended ours, per controller.
static char kApolloGalleryMenuOrigRowCountKey;

#pragma mark - Claiming

// The PostsViewController this ActionController belongs to, claiming the
// pending arm the first time it's asked. Returns nil for every sheet that isn't
// the subreddit "..." menu.
static UIViewController *ApolloGalleryMenuOwnerForController(id actionController) {
    if (!actionController) return nil;

    NSHashTable *holder = objc_getAssociatedObject(actionController, &kApolloGalleryMenuOwnerKey);
    if (holder) return holder.anyObject;

    UIViewController *armed = sApolloGalleryArmedVC;
    if (!armed) return nil;
    if (CACurrentMediaTime() - sApolloGalleryArmedAt > kApolloGalleryMenuArmGraceSeconds) {
        sApolloGalleryArmedVC = nil;
        return nil;
    }

    holder = [NSHashTable weakObjectsHashTable];
    [holder addObject:armed];
    objc_setAssociatedObject(actionController, &kApolloGalleryMenuOwnerKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // One-shot: consumed here so a second sheet opened later can't also claim it.
    sApolloGalleryArmedVC = nil;
    return armed;
}

// Bare subreddit slug or canonical multireddit path for a claimed controller.
// Nil keeps Popular/All, profile sections, and every unrelated sheet untouched.
static NSString *ApolloGalleryMenuListingIdentifierForController(id actionController) {
    UIViewController *owner = ApolloGalleryMenuOwnerForController(actionController);
    if (!owner) return nil;
    return ApolloSubredditNameFromViewController(owner) ?: ApolloMultiredditPathFromViewController(owner);
}

static NSString *ApolloGalleryMenuSourceDescription(NSString *listingIdentifier) {
    if ([listingIdentifier hasPrefix:@"/user/"]) {
        NSString *name = [listingIdentifier pathComponents].lastObject ?: @"multireddit";
        return [@"m/" stringByAppendingString:name];
    }
    return listingIdentifier.length > 0 ? [@"r/" stringByAppendingString:listingIdentifier] : @"feed";
}

static void ApolloGalleryMenuOpenForController(id actionController) {
    UIViewController *owner = ApolloGalleryMenuOwnerForController(actionController);
    NSString *subreddit = owner ? ApolloSubredditNameFromViewController(owner) : nil;
    if (subreddit.length == 0 && owner) {
        // Keep the established presentation call below: PR #767 wraps that
        // exact call in the Liquid Glass dismissal completion, so a canonical
        // multireddit path automatically receives the same crash fix.
        subreddit = ApolloMultiredditPathFromViewController(owner);
    }
    if (subreddit.length == 0 || !owner) {
        ApolloLog(@"[GalleryMenu] Gallery View tapped but the subreddit could not be resolved");
        return;
    }

    dispatch_block_t openGallery = ^{
        [ApolloGalleryViewController presentGalleryForSubreddit:subreddit
                                             fromViewController:owner];
    };
    if (ApolloNativeActionMenuPerformAfterDismissal(actionController, openGallery)) {
        ApolloLog(@"[GalleryMenu] Waiting for the glass menu to dismiss before opening r/%@",
                  subreddit);
        return;
    }
    openGallery();
}

#pragma mark - Liquid Glass menu injection

// Where our section goes: after whatever "submit a post" affordance leads the
// menu, never above it. That affordance has two shapes in the wild — a plain
// "Submit Post" row (what stock Apollo's action list produces), and a leading
// inline UIMenu that renders as a small row of post-type icons (image / link /
// text) at the top of the menu. Skipping both keeps the composer where muscle
// memory expects it and puts Gallery View directly underneath.
static NSUInteger ApolloGalleryMenuInsertionIndex(NSArray<UIMenuElement *> *children) {
    NSUInteger index = 0;
    while (index < children.count) {
        UIMenuElement *element = children[index];
        if ([element isKindOfClass:[UIMenu class]]) { index++; continue; }
        if ([element isKindOfClass:[UIAction class]] &&
            [((UIAction *)element).title hasPrefix:@"Submit"]) { index++; continue; }
        break;
    }
    return index;
}

// Called from ApolloNativeActionMenuBuildMenu as it converts an ActionController
// into a UIMenu. No-op for every sheet that isn't a supported feed's "..." menu.
void ApolloInjectGalleryViewMenuItemIfNeeded(NSMutableArray *children, NSString *menuTitle, id actionController) {
    (void)menuTitle;
    if (![children isKindOfClass:[NSMutableArray class]] || children.count == 0) return;

    NSString *listingIdentifier = ApolloGalleryMenuListingIdentifierForController(actionController);
    if (listingIdentifier.length == 0) return;

    // The builder runs more than once per presentation; the claim persists on
    // the controller, so guard against inserting our section twice.
    for (UIMenuElement *element in children) {
        if ([element isKindOfClass:[UIMenu class]] &&
            [((UIMenu *)element).children.firstObject isKindOfClass:[UIAction class]] &&
            [((UIAction *)((UIMenu *)element).children.firstObject).title isEqualToString:kApolloGalleryMenuTitle]) {
            return;
        }
    }

    __weak id weakController = actionController;
    UIAction *action = [UIAction actionWithTitle:kApolloGalleryMenuTitle
                                           image:[UIImage systemImageNamed:kApolloGalleryMenuSymbol]
                                      identifier:nil
                                         handler:^(__unused __kindof UIAction *sender) {
        ApolloGalleryMenuOpenForController(weakController);
    }];

    // An inline single-item menu renders as its own separated group rather than
    // sitting inside the native rows.
    UIMenu *section = [UIMenu menuWithTitle:@""
                                      image:nil
                                 identifier:nil
                                    options:UIMenuOptionsDisplayInline
                                   children:@[action]];
    NSUInteger index = ApolloGalleryMenuInsertionIndex(children);
    [children insertObject:section atIndex:index];
    ApolloLog(@"[GalleryMenu] Injected '%@' for %@ at index %lu (glass menu)",
              kApolloGalleryMenuTitle, ApolloGalleryMenuSourceDescription(listingIdentifier),
              (unsigned long)index);
}

#pragma mark - Arming

%hook _TtC6Apollo19PostsViewController

- (void)moreOptionsBarButtonItemTappedWithSender:(id)sender {
    // Only arm for feeds a gallery makes sense for; that keeps every other
    // sheet (and every other feed type) completely untouched.
    UIViewController *viewController = (UIViewController *)self;
    NSString *listingIdentifier = ApolloSubredditNameFromViewController(viewController)
        ?: ApolloMultiredditPathFromViewController(viewController);
    if (listingIdentifier.length > 0) {
        sApolloGalleryArmedVC = (UIViewController *)self;
        sApolloGalleryArmedAt = CACurrentMediaTime();
    } else {
        sApolloGalleryArmedVC = nil;
    }
    %orig;
}

%end

#pragma mark - Action-sheet row injection (non-Liquid-Glass)

static NSInteger ApolloGalleryMenuOriginalRowCount(id actionController) {
    NSNumber *stored = objc_getAssociatedObject(actionController, &kApolloGalleryMenuOrigRowCountKey);
    return stored ? stored.integerValue : -1;
}

// Takes `id` so callers inside %hook blocks don't have to message a
// forward-declared Swift class (clang rejects -class on one).
static id ApolloGalleryMenuIvarObject(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// The sheet's own row height, asked of Apollo rather than guessed. 0 when it
// can't be determined.
static CGFloat ApolloGalleryMenuRowHeight(id actionController) {
    id tableView = ApolloGalleryMenuIvarObject(actionController, "tableView");
    if (![tableView isKindOfClass:[UITableView class]]) return 0.0;
    if (![actionController respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)]) return 0.0;
    @try {
        return [(id<UITableViewDelegate>)actionController
                    tableView:(UITableView *)tableView
                    heightForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

#pragma mark Row-0 styling capture

// Apollo's action-sheet rows are custom-built (icon + accent-tinted label at
// their own insets), so a stock UITableViewCell's textLabel lands in the wrong
// place with the wrong colour — under a dark custom theme it renders as an
// apparently blank row. Instead of guessing, mirror row 0: find its label and
// icon by walking the cell (rather than by ivar name, which isn't stable) and
// reuse their geometry and styling verbatim.
static UIView *ApolloGalleryMenuFirstSubviewOfClass(UIView *root, Class cls, BOOL requireLabelText) {
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:cls]) {
            if (!requireLabelText) return subview;
            if ([subview isKindOfClass:[UILabel class]] && ((UILabel *)subview).text.length > 0) return subview;
        }
        UIView *nested = ApolloGalleryMenuFirstSubviewOfClass(subview, cls, requireLabelText);
        if (nested) return nested;
    }
    return nil;
}

// Captured from row 0 the first time it builds. Frames are in the cell's own
// coordinate space; only the x/height parts are reused (our row has the same
// height, and the width comes from our own cell).
static UIColor *sApolloGalleryRowTitleColor = nil;
static UIFont *sApolloGalleryRowTitleFont = nil;
static NSTextAlignment sApolloGalleryRowTitleAlignment = NSTextAlignmentLeft;
static CGRect sApolloGalleryRowTitleFrame = CGRectZero;
static CGRect sApolloGalleryRowIconFrame = CGRectZero;
static UIColor *sApolloGalleryRowIconTint = nil;

static void ApolloGalleryMenuCaptureRowStyle(UITableViewCell *cell) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return;
    // Force a layout pass so the captured frames are real, not CGRectZero.
    [cell layoutIfNeeded];

    UILabel *label = (UILabel *)ApolloGalleryMenuFirstSubviewOfClass(cell, [UILabel class], YES);
    if (!label) return;
    sApolloGalleryRowTitleColor = label.textColor;
    sApolloGalleryRowTitleFont = label.font;
    sApolloGalleryRowTitleAlignment = label.textAlignment;
    sApolloGalleryRowTitleFrame = [label convertRect:label.bounds toView:cell];

    UIImageView *icon = (UIImageView *)ApolloGalleryMenuFirstSubviewOfClass(cell, [UIImageView class], NO);
    if (icon && icon.bounds.size.width > 1.0) {
        sApolloGalleryRowIconFrame = [icon convertRect:icon.bounds toView:cell];
        sApolloGalleryRowIconTint = icon.tintColor;
    }
    ApolloLog(@"[GalleryMenu] Captured sheet row style: title=%@ icon=%@",
              NSStringFromCGRect(sApolloGalleryRowTitleFrame), NSStringFromCGRect(sApolloGalleryRowIconFrame));
}

// Our appended row, laid out to match the captured native row.
@interface ApolloGalleryMenuRowCell : UITableViewCell
@property (nonatomic, strong) UILabel *rowTitleLabel;
@property (nonatomic, strong) UIImageView *rowIconView;
@end

@implementation ApolloGalleryMenuRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        // The accent is the right last resort: Apollo tints these rows with the
        // theme accent, so it matches even when the capture came up empty.
        UIColor *tint = sApolloGalleryRowTitleColor ?: ApolloThemeAccentColor() ?: UIColor.labelColor;

        _rowIconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:kApolloGalleryMenuSymbol]];
        _rowIconView.contentMode = UIViewContentModeScaleAspectFit;
        _rowIconView.tintColor = sApolloGalleryRowIconTint ?: tint;
        [self.contentView addSubview:_rowIconView];

        _rowTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _rowTitleLabel.text = kApolloGalleryMenuTitle;
        _rowTitleLabel.textColor = tint;
        _rowTitleLabel.font = sApolloGalleryRowTitleFont ?: [UIFont systemFontOfSize:17.0];
        _rowTitleLabel.textAlignment = sApolloGalleryRowTitleAlignment;
        [self.contentView addSubview:_rowTitleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;

    if (!CGRectIsEmpty(sApolloGalleryRowIconFrame)) {
        CGRect iconFrame = sApolloGalleryRowIconFrame;
        iconFrame.origin.y = (bounds.size.height - iconFrame.size.height) / 2.0;
        self.rowIconView.frame = iconFrame;
        self.rowIconView.hidden = NO;
    } else {
        self.rowIconView.hidden = YES;
    }

    CGFloat titleLeft = CGRectIsEmpty(sApolloGalleryRowTitleFrame) ? 16.0 : CGRectGetMinX(sApolloGalleryRowTitleFrame);
    CGFloat titleHeight = CGRectIsEmpty(sApolloGalleryRowTitleFrame) ? 22.0 : CGRectGetHeight(sApolloGalleryRowTitleFrame);
    self.rowTitleLabel.frame = CGRectMake(titleLeft,
                                          (bounds.size.height - titleHeight) / 2.0,
                                          MAX(0.0, bounds.size.width - titleLeft - 16.0),
                                          titleHeight);
}

@end

%hook _TtC6Apollo16ActionController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger count = %orig;
    NSString *listingIdentifier = ApolloGalleryMenuListingIdentifierForController(self);
    if (listingIdentifier.length == 0) return count;
    // Only the first section grows; Apollo's "..." sheet is single-section, but
    // being explicit keeps a multi-section sheet from sprouting extra rows.
    if (section != 0) return count;
    if (ApolloGalleryMenuOriginalRowCount(self) != count) {
        ApolloLog(@"[GalleryMenu] Added '%@' row for %@ (sheet, after %ld native rows)",
                  kApolloGalleryMenuTitle, ApolloGalleryMenuSourceDescription(listingIdentifier),
                  (long)count);
    }
    objc_setAssociatedObject(self, &kApolloGalleryMenuOrigRowCountKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return count + 1;
}

// Our row is the LAST row, never inserted in the middle: Apollo's own
// cellForRow calls -dequeueReusableCellWithIdentifier:forIndexPath: with the
// index path it was handed, and UIKit asserts if that doesn't match the row the
// table is currently asking for. So the native rows must keep their own indices
// and only an appended row is safe.
static BOOL ApolloGalleryMenuIsOurRow(id actionController, NSIndexPath *indexPath) {
    NSInteger originalCount = ApolloGalleryMenuOriginalRowCount(actionController);
    return originalCount >= 0 && indexPath.section == 0 && indexPath.row == originalCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloGalleryMenuIsOurRow(self, indexPath)) {
        UITableViewCell *cell = %orig;
        // Apollo's first row is our style reference; re-capture on every sheet
        // build so a theme change mid-session can't leave us on stale colours.
        if (ApolloGalleryMenuOriginalRowCount(self) >= 0 && indexPath.section == 0 && indexPath.row == 0) {
            ApolloGalleryMenuCaptureRowStyle(cell);
        }
        return cell;
    }

    // Built by hand with its own reuse identifier: dequeuing Apollo's cell class
    // for an index its data source doesn't know about is what throws.
    return [[ApolloGalleryMenuRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                           reuseIdentifier:@"ApolloGalleryViewRow"];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloGalleryMenuIsOurRow(self, indexPath)) return %orig;
    // Ask Apollo how tall its own rows are rather than guessing.
    return %orig(tableView, [NSIndexPath indexPathForRow:0 inSection:indexPath.section]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!ApolloGalleryMenuIsOurRow(self, indexPath)) { %orig; return; }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    __strong id actionController = self;
    // The sheet is modal over the subreddit; push only once it's gone.
    [(UIViewController *)self dismissViewControllerAnimated:YES completion:^{
        ApolloGalleryMenuOpenForController(actionController);
    }];
}

%end

// The sheet's height comes from Apollo's own row count, so it has to grow by a
// row or the extra row is clipped. Only the presentation frame is touched —
// growing the inner table view as well pushed its last row underneath the
// Cancel button, where it couldn't be scrolled into view.
%hook _TtC6Apollo38ActionControllerPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    UIViewController *presented = [(UIPresentationController *)self presentedViewController];
    if (frame.size.height <= 0.0 || !presented) return frame;
    NSInteger originalCount = ApolloGalleryMenuOriginalRowCount(presented);
    if (originalCount < 0) return frame;

    CGFloat rowHeight = ApolloGalleryMenuRowHeight(presented);
    if (rowHeight <= 0.0) return frame;

    frame.origin.y -= rowHeight;
    frame.size.height += rowHeight;
    return frame;
}

%end

%ctor {
    %init;
    ApolloLog(@"[GalleryMenu] Gallery View menu hooks installed");
}
