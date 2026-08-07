#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

@interface RDKComment : NSObject
@property(nonatomic) BOOL stickied;
@property(nonatomic) BOOL collapsed;
@end

// iOS 26 + Liquid Glass bug:
// When a large comment subtree collapses near the top of CommentsViewController,
// some rows can briefly draw into the translucent nav/search area during the
// collapse animation.
//
// Fix:
// - Detect real collapsed-state changes on RDKComment.
// - Show temporary cover views for the duration of the collapse/expand
//   animation.
// - Keep those covers BELOW the visible nav/search controls so the Liquid Glass
//   chrome stays translucent while leaked comment content is hidden.
// - Only do this when the comments UI is near the top, where the bug is
//   actually visible.

static const void *kCommentsCollapseRootCoverViewKey = &kCommentsCollapseRootCoverViewKey;
static const void *kCommentsCollapseToolbarCoverViewKey = &kCommentsCollapseToolbarCoverViewKey;
static const void *kCommentsCollapseCoverGenerationKey = &kCommentsCollapseCoverGenerationKey;
static const void *kCommentsCollapseTopPinKey = &kCommentsCollapseTopPinKey;

// Slightly longer than the collapse animation.
static const NSTimeInterval kCommentsCollapseCoverDuration = 0.65;

// "Close enough to the top" scroll tolerance.
static const CGFloat kCommentsCollapseTopThreshold = 60.0;

// Minimum amount of toolbar/search area that must be visible below the nav bar.
static const CGFloat kCommentsCollapseToolbarVisibleMargin = 12.0;

static __weak UIViewController *sVisibleCommentsViewController = nil;
static UIView *GetCommentsToolbarHostView(UIViewController *viewController);

static id GetIvarObjectQuiet(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static UITableView *FindFirstTableViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }

    for (UIView *subview in view.subviews) {
        UITableView *tableView = FindFirstTableViewInView(subview);
        if (tableView) return tableView;
    }

    return nil;
}

static UITableView *GetCommentsTableView(UIViewController *viewController) {
    id tableNode = GetIvarObjectQuiet(viewController, "tableNode");
    if (tableNode) {
        SEL viewSelector = NSSelectorFromString(@"view");
        if ([tableNode respondsToSelector:viewSelector]) {
            UIView *tableNodeView = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSelector);
            if ([tableNodeView isKindOfClass:[UITableView class]]) {
                return (UITableView *)tableNodeView;
            }
        }
    }

    return FindFirstTableViewInView(viewController.view);
}

static CGFloat GetNavigationBarBottom(UIViewController *viewController) {
    UIView *rootView = viewController.view;
    if (!rootView) return 0.0;

    CGFloat navBarBottom = rootView.safeAreaInsets.top;
    UINavigationController *navigationController = viewController.navigationController;
    if (navigationController && !navigationController.navigationBarHidden) {
        UINavigationBar *navigationBar = navigationController.navigationBar;
        if (navigationBar && !navigationBar.hidden) {
            CGRect navigationBarFrame = [rootView convertRect:navigationBar.bounds fromView:navigationBar];
            navBarBottom = MAX(navBarBottom, CGRectGetMaxY(navigationBarFrame));
        }
    }

    return navBarBottom;
}

static CGFloat GetCommentsTableTopOffset(UITableView *tableView) {
    if (!tableView) return 0.0;

    UIEdgeInsets adjustedInsets = tableView.contentInset;
    if (@available(iOS 11.0, *)) {
        adjustedInsets = tableView.adjustedContentInset;
    }
    return -adjustedInsets.top;
}

static CGRect GetViewFrameInRootView(UIView *view, UIView *rootView) {
    if (!view || !rootView) return CGRectZero;
    if (view.superview) {
        return [rootView convertRect:view.frame fromView:view.superview];
    }
    return view.frame;
}

// Prefer the visible toolbar/search container as the "top state" signal, with
// contentOffset as a fallback.
static BOOL ShouldShowCollapseCoverForTopState(UIViewController *viewController, UITableView *tableView) {
    UIView *rootView = viewController.view;
    if (!rootView || !tableView) return NO;

    UIView *toolbarHostView = GetCommentsToolbarHostView(viewController);
    if (toolbarHostView && !toolbarHostView.hidden && toolbarHostView.alpha > 0.01) {
        CGRect toolbarFrame = GetViewFrameInRootView(toolbarHostView, rootView);
        CGFloat navBarBottom = GetNavigationBarBottom(viewController);
        if (CGRectGetMaxY(toolbarFrame) > (navBarBottom + kCommentsCollapseToolbarVisibleMargin) &&
            CGRectGetMinY(toolbarFrame) < CGRectGetHeight(rootView.bounds)) {
            return YES;
        }
    }

    return tableView.contentOffset.y <= (GetCommentsTableTopOffset(tableView) + kCommentsCollapseTopThreshold);
}


static UIColor *GetCommentsCoverColor(UIViewController *viewController, UITableView *tableView) {
    UIColor *color = tableView.backgroundColor;
    if (color) return color;

    if (@available(iOS 13.0, *)) {
        return [UIColor systemBackgroundColor];
    }
    return [UIColor blackColor];
}

static UIView *GetCommentsToolbarHostView(UIViewController *viewController) {
    UIView *upperToolbar = GetIvarObjectQuiet(viewController, "upperToolbar");
    if ([upperToolbar isKindOfClass:[UIView class]]) {
        return upperToolbar;
    }

    UIView *searchTextField = GetIvarObjectQuiet(viewController, "searchTextField");
    if ([searchTextField isKindOfClass:[UIView class]] &&
        [searchTextField.superview isKindOfClass:[UIView class]] &&
        searchTextField.superview != viewController.view) {
        return searchTextField.superview;
    }

    return nil;
}

static UIView *EnsureCommentsCoverView(UIViewController *viewController, const void *key, NSString *logLabel) {
    UIView *coverView = objc_getAssociatedObject(viewController, key);
    if (coverView) return coverView;

    // Apollo's normal comments screen is opaque, so a plain fill of the table's
    // own colour hides the leak invisibly. The media comments pane has no such
    // colour — its table is deliberately transparent over the sheet's glass —
    // so there the cover has to be a material instead. Host both cases in a
    // UIVisualEffectView and let StyleCommentsCollapseCover pick.
    coverView = [[UIVisualEffectView alloc] initWithEffect:nil];
    coverView.hidden = YES;
    coverView.userInteractionEnabled = NO;
    coverView.opaque = NO;
    objc_setAssociatedObject(viewController, key, coverView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[CommentsClip] Installed %@ cover", logLabel);
    return coverView;
}

// A transparent surface means the pane: cover with the same class of material a
// navigation bar shows once content scrolls under it, so the band reads as the
// chrome briefly picking up its scrolled state. It has to be this strong —
// systemThinMaterial left the leaked rows plainly readable through it, which is
// the whole bug.
static void StyleCommentsCollapseCover(UIView *cover, UIColor *coverColor, BOOL opaqueSurface) {
    if (![cover isKindOfClass:[UIVisualEffectView class]]) {
        cover.backgroundColor = coverColor;
        return;
    }
    UIVisualEffectView *effectView = (UIVisualEffectView *)cover;
    if (opaqueSurface) {
        effectView.effect = nil;
        effectView.contentView.backgroundColor = coverColor;
    } else {
        effectView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
        effectView.contentView.backgroundColor = UIColor.clearColor;
    }
}

static BOOL CommentsCoverSurfaceIsOpaque(UIViewController *viewController, UITableView *tableView) {
    UIColor *coverColor = GetCommentsCoverColor(viewController, tableView);
    UIColor *resolved = [coverColor resolvedColorWithTraitCollection:viewController.view.traitCollection];
    return CGColorGetAlpha(resolved.CGColor) > 0.001;
}

// Texture's collapse transaction can leave the list scrolled a row or so past
// its top rest, which slides the first surviving comment under the nav bar and
// search field and briefly exposes a stale row there. Nothing recovers that on
// its own until the animation settles, so while the collapse is running, hold
// the list at the rest position it started from. Writing only when the offset
// has actually drifted makes this converge in one pass instead of fighting the
// scroll view.
static void EnforceCommentsCollapseTopPin(UIViewController *viewController, UITableView *tableView) {
    if (![objc_getAssociatedObject(viewController, kCommentsCollapseTopPinKey) boolValue]) return;
    if (!tableView || !tableView.window) return;

    CGFloat topOffset = GetCommentsTableTopOffset(tableView);
    if (tableView.contentOffset.y <= topOffset + 0.5) return;
    ApolloLog(@"[CommentsClip] Pin top during collapse offset=%.1f -> %.1f",
              tableView.contentOffset.y, topOffset);
    [tableView setContentOffset:CGPointMake(tableView.contentOffset.x, topOffset) animated:NO];
}

// Keep the root and toolbar covers aligned with the current layout.
static void LayoutCommentsCollapseCover(UIViewController *viewController) {
    // NSISEngine isn't thread-safe; ASDK can call viewDidLayoutSubviews
    // off-main during deferred CA transaction flushes.
    if (![NSThread isMainThread]) return;

    UIView *rootView = viewController.view;
    UIView *rootCoverView = objc_getAssociatedObject(viewController, kCommentsCollapseRootCoverViewKey);
    UIView *toolbarCoverView = objc_getAssociatedObject(viewController, kCommentsCollapseToolbarCoverViewKey);
    if (!rootView || !rootView.window) return;
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;

    // The pin is about scroll position, not covers, so it runs before the
    // cover-visibility bail on every layout pass of a collapsing screen.
    EnforceCommentsCollapseTopPin(viewController, tableView);

    // Show path re-lays out covers on demand; nothing to do while hidden.
    BOOL hasVisibleCover = (rootCoverView && !rootCoverView.hidden) ||
                           (toolbarCoverView && !toolbarCoverView.hidden);
    if (!hasVisibleCover) return;

    CGFloat navBarBottom = GetNavigationBarBottom(viewController);
    UIColor *coverColor = GetCommentsCoverColor(viewController, tableView);
    BOOL opaqueSurface = CommentsCoverSurfaceIsOpaque(viewController, tableView);
    if (rootCoverView) {
        rootCoverView.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(rootView.bounds), navBarBottom);
        StyleCommentsCollapseCover(rootCoverView, coverColor, opaqueSurface);
        rootCoverView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    }

    UIView *toolbarHostView = GetCommentsToolbarHostView(viewController);
    UIView *searchTextField = GetIvarObjectQuiet(viewController, "searchTextField");
    if (rootCoverView) {
        if (rootCoverView.superview != rootView) {
            if (toolbarHostView && toolbarHostView.superview == rootView) {
                [rootView insertSubview:rootCoverView belowSubview:toolbarHostView];
            } else if ([searchTextField isKindOfClass:[UIView class]] && searchTextField.superview == rootView) {
                [rootView insertSubview:rootCoverView belowSubview:searchTextField];
            } else if (tableView.superview == rootView) {
                [rootView insertSubview:rootCoverView aboveSubview:tableView];
            } else {
                [rootView addSubview:rootCoverView];
            }
        } else if (toolbarHostView && toolbarHostView.superview == rootView) {
            [rootView insertSubview:rootCoverView belowSubview:toolbarHostView];
        } else if ([searchTextField isKindOfClass:[UIView class]] && searchTextField.superview == rootView) {
            [rootView insertSubview:rootCoverView belowSubview:searchTextField];
        }
    }

    if (toolbarCoverView && toolbarHostView) {
        toolbarCoverView.frame = toolbarHostView.bounds;
        StyleCommentsCollapseCover(toolbarCoverView, coverColor, opaqueSurface);
        toolbarCoverView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        if (toolbarCoverView.superview != toolbarHostView) {
            [toolbarCoverView removeFromSuperview];
            if ([searchTextField isKindOfClass:[UIView class]] && searchTextField.superview == toolbarHostView) {
                [toolbarHostView insertSubview:toolbarCoverView belowSubview:searchTextField];
            } else {
                [toolbarHostView insertSubview:toolbarCoverView atIndex:0];
            }
        } else if ([searchTextField isKindOfClass:[UIView class]] && searchTextField.superview == toolbarHostView) {
            [toolbarHostView insertSubview:toolbarCoverView belowSubview:searchTextField];
        } else {
            [toolbarHostView sendSubviewToBack:toolbarCoverView];
        }
    } else if (toolbarCoverView.superview) {
        [toolbarCoverView removeFromSuperview];
    }
}

static void HideCommentsCollapseCover(UIViewController *viewController, NSUInteger generation) {
    NSNumber *currentGeneration = objc_getAssociatedObject(viewController, kCommentsCollapseCoverGenerationKey);
    if ([currentGeneration unsignedIntegerValue] != generation) return;

    // Release the pin on the same generation clock as the covers, after one last
    // enforcement so the list settles exactly at rest.
    UITableView *tableView = GetCommentsTableView(viewController);
    EnforceCommentsCollapseTopPin(viewController, tableView);
    objc_setAssociatedObject(viewController, kCommentsCollapseTopPinKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *rootCoverView = objc_getAssociatedObject(viewController, kCommentsCollapseRootCoverViewKey);
    UIView *toolbarCoverView = objc_getAssociatedObject(viewController, kCommentsCollapseToolbarCoverViewKey);
    if (rootCoverView.hidden && (!toolbarCoverView || toolbarCoverView.hidden)) return;

    rootCoverView.hidden = YES;
    toolbarCoverView.hidden = YES;
    ApolloLog(@"[CommentsClip] Hide collapse cover generation=%lu", (unsigned long)generation);
}

static void ShowCommentsCollapseCover(NSString *reason) {
    if (!IsLiquidGlass()) return;

    UIViewController *viewController = sVisibleCommentsViewController;
    if (!viewController || !viewController.isViewLoaded || !viewController.view.window) return;

    // The media pane never needs the covers: its row updates run without row
    // animations (ApolloSwipeUpComments.xm's UITableView hooks), so there is
    // no leaked animation to hide — and a chrome-material band flashing over
    // the pane's glass would itself be the visual glitch.
    if (ApolloSwipeCommentsIsPaneCommentsController(viewController)) {
        ApolloLog(@"[CommentsClip] Skip collapse cover reason=%@: media pane", reason);
        return;
    }

    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;
    CGFloat topOffset = GetCommentsTableTopOffset(tableView);
    BOOL wasAtTop = tableView.contentOffset.y <= topOffset + kCommentsCollapseTopThreshold;
    if (!ShouldShowCollapseCoverForTopState(viewController, tableView)) {
        ApolloLog(@"[CommentsClip] Skip collapse cover reason=%@ offset=%.1f topOffset=%.1f",
                  reason,
                  tableView.contentOffset.y,
                  GetCommentsTableTopOffset(tableView));
        return;
    }

    NSUInteger generation = [objc_getAssociatedObject(viewController, kCommentsCollapseCoverGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(viewController, kCommentsCollapseCoverGenerationKey, @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // A list that started at rest must still be at rest when the animation
    // finishes, so hold it there for the whole collapse rather than correcting
    // it once at the end. Deeper scroll positions are left alone.
    if (wasAtTop) {
        objc_setAssociatedObject(viewController, kCommentsCollapseTopPinKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *rootCoverView = EnsureCommentsCoverView(viewController, kCommentsCollapseRootCoverViewKey, @"root collapse");
    UIView *toolbarCoverView = EnsureCommentsCoverView(viewController, kCommentsCollapseToolbarCoverViewKey, @"toolbar collapse");
    UIView *toolbarHostView = GetCommentsToolbarHostView(viewController);
    // Unhide before layout so the hidden-cover early-bail doesn't skip the
    // first layout pass.
    rootCoverView.hidden = NO;
    toolbarCoverView.hidden = (toolbarHostView == nil);
    LayoutCommentsCollapseCover(viewController);

    ApolloLog(@"[CommentsClip] Show collapse cover reason=%@ generation=%lu opaqueSurface=%d pinTop=%d navBottom=%.1f toolbarHost=%@ rootFrame=%@ toolbarFrame=%@ tableFrame=%@ tableBounds=%@",
              reason,
              (unsigned long)generation,
              (int)CommentsCoverSurfaceIsOpaque(viewController, tableView),
              (int)wasAtTop,
              GetNavigationBarBottom(viewController),
              NSStringFromClass([toolbarHostView class]),
              NSStringFromCGRect(rootCoverView.frame),
              NSStringFromCGRect(toolbarCoverView.frame),
              NSStringFromCGRect(tableView.frame),
              NSStringFromCGRect(tableView.bounds));

    // Re-enforce the pin every frame for the length of the animation. The
    // controller's own layout pass is not guaranteed to run while only the
    // table's content offset moves, and the generation check ends the chain the
    // moment a newer collapse (or the cover timeout) supersedes this one.
    if (wasAtTop) {
        __weak UIViewController *weakViewController = viewController;
        const NSTimeInterval frame = 1.0 / 60.0;
        for (NSUInteger step = 0; step * frame < kCommentsCollapseCoverDuration; step++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * frame * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *controller = weakViewController;
                if (!controller) return;
                NSNumber *current = objc_getAssociatedObject(controller, kCommentsCollapseCoverGenerationKey);
                if ([current unsignedIntegerValue] != generation) return;
                EnforceCommentsCollapseTopPin(controller, GetCommentsTableView(controller));
            });
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCommentsCollapseCoverDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HideCommentsCollapseCover(viewController, generation);
    });
}

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sVisibleCommentsViewController = (UIViewController *)self;
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (sVisibleCommentsViewController == (UIViewController *)self) {
        UIView *rootCoverView = objc_getAssociatedObject(self, kCommentsCollapseRootCoverViewKey);
        UIView *toolbarCoverView = objc_getAssociatedObject(self, kCommentsCollapseToolbarCoverViewKey);
        rootCoverView.hidden = YES;
        toolbarCoverView.hidden = YES;
        objc_setAssociatedObject(self, kCommentsCollapseTopPinKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sVisibleCommentsViewController = nil;
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    LayoutCommentsCollapseCover((UIViewController *)self);
}

%end

%hook RDKComment

- (void)setStickied:(BOOL)stickied {
    %orig;

    if (!stickied) return;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyCollapsePinnedComments]) return;
    if ([self collapsed]) return;

    MSHookIvar<BOOL>(self, "_collapsed") = YES;
}

- (void)setCollapsed:(BOOL)collapsed {
    BOOL wasCollapsed = [self collapsed];
    %orig;
    if (wasCollapsed != collapsed) {
        ShowCommentsCollapseCover(collapsed ? @"collapse" : @"expand");
    }
}

%end
