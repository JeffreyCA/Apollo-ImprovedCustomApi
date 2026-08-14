// ApolloActionMenu — see ApolloActionMenu.h for the ownership contract this
// module exists to enforce (single owner of _TtC6Apollo16ActionController's
// table geometry and ActionControllerPresentationController's frame, on both
// the Liquid Glass and legacy-sheet rendering paths).
//
// THE REGISTRY: feature modules call ApolloActionMenuRegister() from their
// %ctor with an ApolloActionMenuSpec. Read lazily, so %ctor/Makefile link order
// never matters (mirrors src/settings/ApolloSettingsGeneralTable.xm's registry).
//
// PER-CONTROLLER SLOTS: ApolloActionMenuSlotsForController() runs every spec's
// `matches` exactly once per actionController instance, on whichever call site
// asks first (glass's ApolloActionMenuInjectMenuElements, or any of the legacy
// table hooks below), and memoizes the result via an associated object. This is
// deliberately NOT a side effect of tableView:numberOfRowsInSection: — the
// presentation-controller frame hook needs the matched spec count before the
// table has necessarily reloaded, and computing on demand instead of on that
// one call site removes the order dependency entirely.
//
// THE DONOR CELL: an injected row's declarative title/image blocks receive the
// LIVE row-0 cell as `donor` on the legacy path, fetched by calling the
// controller's own (real, un-hooked-for-row-0) cellForRowAtIndexPath: — never
// captured opportunistically off whatever row happened to build first. Same
// technique as ApolloSettingsGeneralTable.xm's factory(vc, donor).
//
// GEOMETRY: legacy rows are always appended after the last native row (Apollo's
// own cellForRow dequeues with the index path it's handed; UIKit asserts if a
// native row's index shifts) and the presented sheet's frame grows by
// rowHeight * matchedSpecCount. Nothing here grows the inner tableView's own
// frame — an earlier version of this feature set (ApolloPublicStickyAsSubreddit)
// did that via viewDidLayoutSubviews and it visibly ate the gap Apollo leaves
// between the rows card and the Cancel button (confirmed on-device); Gallery's
// and DeletedComments' outer-frame-only growth was correct all along.

#import "ApolloActionMenu.h"
#import "ApolloCommon.h"
#import "ApolloSwiftRuntime.h"
#import "ApolloThemeRuntime.h"

#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - Registry

@implementation ApolloActionMenuSpec
@end

static NSMutableArray<ApolloActionMenuSpec *> *sApolloActionMenuRegistry;

void ApolloActionMenuRegister(ApolloActionMenuSpec *spec) {
    if (!spec.identifier.length || !spec.matches || !spec.perform) {
        ApolloLog(@"[ActionMenu] Refusing to register an incomplete spec (%@)", spec.identifier);
        return;
    }
    if (!sApolloActionMenuRegistry) sApolloActionMenuRegistry = [NSMutableArray array];
    [sApolloActionMenuRegistry addObject:spec];
}

#pragma mark - Per-controller slot memoization

@interface ApolloActionMenuSlotState : NSObject
@property (nonatomic, copy) NSArray<ApolloActionMenuSpec *> *specs; // matched, ordered
@property (nonatomic, assign) NSInteger nativeRowCount; // -1 until numberOfRows(section 0) has run
// A standalone (never dequeued, never added to any table) snapshot cell
// carrying row 0's captured text/font/color/frame, rebuilt every time row 0
// naturally renders. NOT a live cell — see ApolloActionMenuCaptureDonorSnapshot
// for why an injected row's cellForRow can never fetch row 0 "live".
@property (nonatomic, strong) UITableViewCell *donorSnapshot;
@end
@implementation ApolloActionMenuSlotState
- (instancetype)init {
    self = [super init];
    if (self) _nativeRowCount = -1;
    return self;
}
@end

static const void *kApolloActionMenuSlotStateKey = &kApolloActionMenuSlotStateKey;

// Apollo's own actionsDescription Swift string for the sheet, falling back to
// probing titleForHeaderInSection: the way ApolloPublicStickyAsSubreddit used to
// on every delegate call — here it only runs once, at memoization time.
static NSString *ApolloActionMenuTitleForController(id controller) {
    NSString *title = ApolloReadSwiftStringIvar(controller, "actionsDescription");
    if (title.length > 0) return title;

    if ([controller respondsToSelector:@selector(tableView:titleForHeaderInSection:)]) {
        UITableView *tableView = ApolloReadObjectIvar(controller, "tableView");
        @try {
            NSString *header = [(id<UITableViewDataSource>)controller tableView:tableView
                                                       titleForHeaderInSection:0];
            if ([header isKindOfClass:[NSString class]]) return header;
        } @catch (__unused NSException *exception) {
        }
    }
    return @"";
}

// menuTitleHint: pass the already-known title from the glass path to skip the
// re-derivation above; pass nil from the legacy hooks (memoized either way, so
// this only ever runs once per controller regardless).
static ApolloActionMenuSlotState *ApolloActionMenuSlotsForController(id controller, NSString *menuTitleHint) {
    if (!controller) return nil;

    ApolloActionMenuSlotState *state = objc_getAssociatedObject(controller, kApolloActionMenuSlotStateKey);
    if (state) return state;

    NSString *menuTitle = menuTitleHint.length > 0 ? menuTitleHint : ApolloActionMenuTitleForController(controller);

    NSMutableArray<ApolloActionMenuSpec *> *matched = [NSMutableArray array];
    for (ApolloActionMenuSpec *spec in sApolloActionMenuRegistry) {
        BOOL (^matches)(id, NSString *) = spec.matches;
        if (!matches) continue;
        @try {
            if (matches(controller, menuTitle)) [matched addObject:spec];
        } @catch (NSException *exception) {
            ApolloLog(@"[ActionMenu] spec '%@' matches: threw %@", spec.identifier, exception);
        }
    }
    [matched sortUsingComparator:^NSComparisonResult(ApolloActionMenuSpec *a, ApolloActionMenuSpec *b) {
        if (a.order != b.order) return a.order < b.order ? NSOrderedAscending : NSOrderedDescending;
        return [a.identifier compare:b.identifier];
    }];

    state = [ApolloActionMenuSlotState new];
    state.specs = matched;
    objc_setAssociatedObject(controller, kApolloActionMenuSlotStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (matched.count > 0) {
        ApolloLog(@"[ActionMenu] %lu spec(s) matched '%@': %@", (unsigned long)matched.count, menuTitle,
                  [matched valueForKey:@"identifier"]);
    }
    return state;
}

static CGFloat ApolloActionMenuNativeRowHeight(id controller) {
    id tableView = ApolloReadObjectIvar(controller, "tableView");
    if (![tableView isKindOfClass:[UITableView class]]) return 0.0;
    if (![controller respondsToSelector:@selector(tableView:heightForRowAtIndexPath:)]) return 0.0;
    @try {
        return [(id<UITableViewDelegate>)controller tableView:(UITableView *)tableView
                                    heightForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    } @catch (__unused NSException *exception) {
        return 0.0;
    }
}

#pragma mark - Legacy path: donor-styled lookalike cell

static UIView *ApolloActionMenuFirstSubviewOfClass(UIView *root, Class cls, BOOL requireLabelText) {
    for (UIView *subview in root.subviews) {
        if ([subview isKindOfClass:cls]) {
            if (!requireLabelText) return subview;
            if ([subview isKindOfClass:[UILabel class]] && ((UILabel *)subview).text.length > 0) return subview;
        }
        UIView *nested = ApolloActionMenuFirstSubviewOfClass(subview, cls, requireLabelText);
        if (nested) return nested;
    }
    return nil;
}

@interface ApolloActionMenuRowCell : UITableViewCell
@property (nonatomic, strong) UILabel *apolloTitleLabel;
@property (nonatomic, strong) UIImageView *apolloIconView;
@property (nonatomic, assign) CGRect apolloTitleFrame;
@property (nonatomic, assign) CGRect apolloIconFrame;
@end

@implementation ApolloActionMenuRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.contentView.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;

        _apolloIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _apolloIconView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_apolloIconView];

        _apolloTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_apolloTitleLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.contentView.bounds;

    if (!CGRectIsEmpty(self.apolloIconFrame)) {
        CGRect iconFrame = self.apolloIconFrame;
        iconFrame.origin.y = (bounds.size.height - iconFrame.size.height) / 2.0;
        self.apolloIconView.frame = iconFrame;
        self.apolloIconView.hidden = NO;
    } else {
        self.apolloIconView.hidden = YES;
    }

    CGFloat titleLeft = CGRectIsEmpty(self.apolloTitleFrame) ? 16.0 : CGRectGetMinX(self.apolloTitleFrame);
    CGFloat titleHeight = CGRectIsEmpty(self.apolloTitleFrame) ? 22.0 : CGRectGetHeight(self.apolloTitleFrame);
    self.apolloTitleLabel.frame = CGRectMake(titleLeft,
                                             (bounds.size.height - titleHeight) / 2.0,
                                             MAX(0.0, bounds.size.width - titleLeft - 16.0),
                                             titleHeight);
}

@end

// Snapshots row 0's rendered text/style into a standalone UITableViewCell that
// is never dequeued and never added to any table — just a carrier
// ApolloActionMenuFirstSubviewOfClass / ApolloActionMenuDonorLabelText can walk
// exactly like a live cell.
//
// This exists because an injected row's cellForRowAtIndexPath: CANNOT fetch a
// "live" row-0 cell by calling %orig with row 0's index path: Apollo's cell
// builder calls -[UITableView dequeueReusableCellWithIdentifier:forIndexPath:],
// and that method asserts if the index path it's given doesn't match whatever
// row the table's internal state currently believes it's preparing — which,
// mid-build of the INJECTED row, is never row 0. Doing that crashed with
// NSInternalInconsistencyException the moment a subreddit "..." sheet's Gallery
// View row (or any injected row) was built. So the ONLY safe capture point is
// the table's own natural, non-reentrant ask for row 0 itself — see the
// cellForRowAtIndexPath: hook below, which calls this only from that ask.
static UITableViewCell *ApolloActionMenuCaptureDonorSnapshot(UITableViewCell *realRow0Cell) {
    if (![realRow0Cell isKindOfClass:[UITableViewCell class]]) return nil;
    [realRow0Cell layoutIfNeeded];

    UILabel *label = (UILabel *)ApolloActionMenuFirstSubviewOfClass(realRow0Cell, [UILabel class], YES);
    UIImageView *icon = (UIImageView *)ApolloActionMenuFirstSubviewOfClass(realRow0Cell, [UIImageView class], NO);
    if (!label && !icon) return nil;

    UITableViewCell *snapshot = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (label) {
        UILabel *snapshotLabel = [[UILabel alloc] initWithFrame:[label convertRect:label.bounds toView:realRow0Cell]];
        snapshotLabel.text = label.text;
        snapshotLabel.textColor = label.textColor;
        snapshotLabel.font = label.font;
        snapshotLabel.textAlignment = label.textAlignment;
        [snapshot.contentView addSubview:snapshotLabel];
    }
    if (icon && icon.bounds.size.width > 1.0) {
        UIImageView *snapshotIcon = [[UIImageView alloc] initWithFrame:[icon convertRect:icon.bounds toView:realRow0Cell]];
        snapshotIcon.tintColor = icon.tintColor;
        [snapshot.contentView addSubview:snapshotIcon];
    }
    return snapshot;
}

// Style captured from the donor (Apollo's own row-0 cell — custom-drawn icon +
// accent-tinted label at its own insets, so a stock UITableViewCell.textLabel
// would land in the wrong place with the wrong color) and applied to `cell`.
static void ApolloActionMenuConfigureRowCell(ApolloActionMenuRowCell *cell, NSString *title,
                                             UIImage *image, UITableViewCell *donor) {
    UIColor *titleColor = nil;
    UIFont *titleFont = nil;
    NSTextAlignment alignment = NSTextAlignmentLeft;
    CGRect titleFrame = CGRectZero;
    CGRect iconFrame = CGRectZero;
    UIColor *iconTint = nil;

    if ([donor isKindOfClass:[UITableViewCell class]]) {
        [donor layoutIfNeeded];
        UILabel *label = (UILabel *)ApolloActionMenuFirstSubviewOfClass(donor, [UILabel class], YES);
        if (label) {
            titleColor = label.textColor;
            titleFont = label.font;
            alignment = label.textAlignment;
            titleFrame = [label convertRect:label.bounds toView:donor];
        }
        UIImageView *icon = (UIImageView *)ApolloActionMenuFirstSubviewOfClass(donor, [UIImageView class], NO);
        if (icon && icon.bounds.size.width > 1.0) {
            iconFrame = [icon convertRect:icon.bounds toView:donor];
            iconTint = icon.tintColor;
        }
    }

    // The accent is the right last resort: Apollo tints these rows with the
    // theme accent, so it matches even when the donor capture came up empty.
    UIColor *tint = titleColor ?: ApolloThemeAccentColor() ?: UIColor.labelColor;

    cell.apolloTitleLabel.text = title;
    cell.apolloTitleLabel.textColor = tint;
    cell.apolloTitleLabel.font = titleFont ?: [UIFont systemFontOfSize:17.0];
    cell.apolloTitleLabel.textAlignment = alignment;
    cell.apolloIconView.image = image;
    cell.apolloIconView.tintColor = iconTint ?: tint;
    cell.apolloTitleFrame = titleFrame;
    cell.apolloIconFrame = iconFrame;
    cell.accessibilityLabel = title;
    [cell setNeedsLayout];
}

NSString *ApolloActionMenuDonorLabelText(UITableViewCell *donor) {
    if (![donor isKindOfClass:[UITableViewCell class]]) return nil;
    UILabel *label = (UILabel *)ApolloActionMenuFirstSubviewOfClass(donor, [UILabel class], YES);
    return label.text;
}

#pragma mark - Legacy path: invoking a native row's own handler

void ApolloActionMenuInvokeNativeRow(id actionController, NSInteger row) {
    if (!actionController) return;
    if (![actionController respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        ApolloLog(@"[ActionMenu] Cannot invoke native row %ld — no didSelectRowAtIndexPath:", (long)row);
        return;
    }
    UITableView *tableView = ApolloReadObjectIvar(actionController, "tableView");
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:0];
    // Re-enters this file's own didSelectRowAtIndexPath: hook below at `row`,
    // which — being a native index, not an injected slot — falls straight
    // through to %orig. Deliberately a plain dispatch, not
    // ApolloNativeActionMenuSelectRow's "invoking" flag (ApolloNativeActionMenus.xm,
    // glass-only): the legacy sheet is genuinely on screen and must actually
    // dismiss when the native handler dismisses it.
    ((void (*)(id, SEL, id, id))objc_msgSend)(actionController, @selector(tableView:didSelectRowAtIndexPath:),
                                              tableView, indexPath);
}

#pragma mark - Glass path

static NSUInteger ApolloActionMenuLeadingSubmitAffordanceIndex(NSArray<UIMenuElement *> *children) {
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

void ApolloActionMenuInjectMenuElements(NSMutableArray<UIMenuElement *> *children,
                                        NSString *menuTitle,
                                        id actionController) {
    if (![children isKindOfClass:[NSMutableArray class]] || !actionController) return;

    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(actionController, menuTitle);
    if (state.specs.count == 0) return;

    for (ApolloActionMenuSpec *spec in state.specs) {
        @try {
            if (spec.buildElement) {
                spec.buildElement(actionController, children);
                continue;
            }

            NSString *title = spec.title ? spec.title(actionController, nil) : nil;
            if (title.length == 0) continue;
            UIImage *image = spec.image ? spec.image(actionController, nil) : nil;

            void (^perform)(id) = spec.perform;
            UIAction *action = [UIAction actionWithTitle:title
                                                    image:image
                                               identifier:nil
                                                  handler:^(__unused __kindof UIAction *sender) {
                if (perform) perform(actionController);
            }];

            UIMenuElement *element = action;
            if (spec.inlineSection) {
                element = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                        options:UIMenuOptionsDisplayInline children:@[action]];
            }

            NSUInteger index = (spec.placement == ApolloActionMenuPlacementAfterLeadingSubmitAffordance)
                ? ApolloActionMenuLeadingSubmitAffordanceIndex(children)
                : children.count;
            [children insertObject:element atIndex:MIN(index, children.count)];
        } @catch (NSException *exception) {
            ApolloLog(@"[ActionMenu] spec '%@' build threw: %@", spec.identifier, exception);
        }
    }
}

#pragma mark - Legacy path: the single table/geometry owner

%hook _TtC6Apollo16ActionController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger nativeCount = %orig;
    if (section != 0) return nativeCount;

    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(self, nil);
    state.nativeRowCount = nativeCount;
    if (state.specs.count == 0) return nativeCount;
    return nativeCount + (NSInteger)state.specs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(self, nil);
    NSInteger nativeCount = state.nativeRowCount;

    if (state.specs.count == 0 || indexPath.section != 0 || nativeCount < 0 || indexPath.row < nativeCount) {
        UITableViewCell *cell = %orig;
        // Opportunistically snapshot row 0's real rendered style/text — the ONLY
        // safe way to get a donor for the injected rows below. This must run on
        // UIKit's OWN, non-reentrant ask for row 0; see
        // ApolloActionMenuCaptureDonorSnapshot for why an injected row's own
        // cellForRow can never re-invoke %orig for row 0 (it crashes). Captured
        // fresh every time row 0 builds so a live theme change never leaves the
        // snapshot stale.
        if (state.specs.count > 0 && indexPath.row == 0) {
            state.donorSnapshot = ApolloActionMenuCaptureDonorSnapshot(cell);
        }
        return cell;
    }

    NSInteger slotIndex = indexPath.row - nativeCount;
    if (slotIndex < 0 || (NSUInteger)slotIndex >= state.specs.count) return %orig; // fail-soft, shouldn't happen

    ApolloActionMenuSpec *spec = state.specs[(NSUInteger)slotIndex];
    // nil until row 0 has naturally rendered at least once (e.g. a restored
    // scroll position skipping straight past it) — every consumer already
    // falls back gracefully on a nil donor.
    UITableViewCell *donor = state.donorSnapshot;

    NSString *title = spec.title ? spec.title(self, donor) : nil;
    if (title.length == 0) {
        // Fail-soft: UIKit's non-nil-cell contract applies to every spec, not
        // just the ones whose state happens to still resolve.
        UITableViewCell *inert = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                          reuseIdentifier:@"ApolloActionMenuInert"];
        inert.userInteractionEnabled = NO;
        inert.selectionStyle = UITableViewCellSelectionStyleNone;
        return inert;
    }
    UIImage *image = spec.image ? spec.image(self, donor) : nil;

    ApolloActionMenuRowCell *cell = [[ApolloActionMenuRowCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                                    reuseIdentifier:spec.identifier];
    ApolloActionMenuConfigureRowCell(cell, title, image, donor);
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(self, nil);
    NSInteger nativeCount = state.nativeRowCount;

    if (state.specs.count == 0 || indexPath.section != 0 || nativeCount < 0 || indexPath.row < nativeCount) {
        return %orig;
    }
    // Ask Apollo how tall its own rows are rather than guessing.
    return %orig(tableView, [NSIndexPath indexPathForRow:0 inSection:0]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(self, nil);
    NSInteger nativeCount = state.nativeRowCount;

    if (state.specs.count == 0 || indexPath.section != 0 || nativeCount < 0 || indexPath.row < nativeCount) {
        %orig;
        return;
    }

    NSInteger slotIndex = indexPath.row - nativeCount;
    if (slotIndex < 0 || (NSUInteger)slotIndex >= state.specs.count) {
        // Keep the Logos directive on its own line. Logos 2.4.1 consumes the
        // remainder of a line containing %orig, which previously dropped the
        // return and closing brace from generated Objective-C++.
        %orig;
        return;
    }

    ApolloActionMenuSpec *spec = state.specs[(NSUInteger)slotIndex];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    __strong id strongSelf = self;
    void (^perform)(id) = spec.perform;
    if (spec.legacyDismissesSheet) {
        [(UIViewController *)self dismissViewControllerAnimated:YES completion:^{
            if (perform) perform(strongSelf);
        }];
    } else if (perform) {
        perform(strongSelf);
    }
}

%end

%hook _TtC6Apollo38ActionControllerPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    UIViewController *presented = [(UIPresentationController *)self presentedViewController];
    if (frame.size.height <= 0.0 || !presented) return frame;

    ApolloActionMenuSlotState *state = ApolloActionMenuSlotsForController(presented, nil);
    if (state.specs.count == 0) return frame;

    CGFloat rowHeight = ApolloActionMenuNativeRowHeight(presented);
    if (rowHeight <= 0.0) return frame;

    CGFloat growth = rowHeight * (CGFloat)state.specs.count;
    frame.origin.y -= growth;
    frame.size.height += growth;
    return frame;
}

%end

%ctor {
    %init;
    ApolloLog(@"[ActionMenu] Action-menu registry hooks installed");
}
