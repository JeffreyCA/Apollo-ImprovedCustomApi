#import "ApolloNavigationActions.h"
#import "ApolloNavigationActionsDiscovery.h"
#import "ApolloNativeActionMenus.h"
#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// Use the pill's spring for glyphs without changing button frames,
// which translation measures when inserting its globe.
static const NSTimeInterval kActionsAnimationDuration = 0.36;
static CASpringAnimation *ApolloActionsSpring(NSString *keyPath) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:keyPath];
    spring.mass = 1;
    spring.stiffness = 644;
    spring.damping = 2 * 0.78 * sqrt(spring.stiffness);
    spring.duration = kActionsAnimationDuration;
    return spring;
}

// Each page owns one strip and glass surface. Never hide native ancestors,
// save their transient alpha, or duplicate the More glyph.
static char kActionsOwnerKey;
static char kActionsControllerKey;
static char kActionsRefreshKey;
static char kActionsStandardItemKey;
static char kActionsStandardMoreKey;
static char kActionsScrollOwnerKey;
static NSUInteger sActionsModelWriteDepth;
@class ApolloNavigationActionsOwner;

@interface ApolloNavigationActionsControllerBox : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end
@implementation ApolloNavigationActionsControllerBox
@end

@interface ApolloNavigationActionsScrollOwnerBox : NSObject
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@end
@implementation ApolloNavigationActionsScrollOwnerBox
@end

// The item's customView contains its glass and original buttons/targets/menus.
// Its trailing-anchored viewport resizes while More stays fixed in the window.
@interface ApolloNavigationActionsStrip : UIControl
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIVisualEffectView *surface;
@property (nonatomic, weak) UIButton *more;
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@property (nonatomic, weak) UIBarButtonItem *barItem;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@property (nonatomic) CGFloat expandedWidth;
@property (nonatomic) CGFloat moreMidX;
@property (nonatomic) BOOL expanded;
@property (nonatomic) BOOL originalAccessibilityHidden;
@property (nonatomic, strong) NSHashTable<CALayer *> *animatedIconLayers;
@property (nonatomic, copy) NSString *iconMotionKey;
@property (nonatomic, copy) NSString *iconOpacityKey;
- (instancetype)initWithContent:(UIView *)content more:(UIButton *)more;
- (void)remeasure;
- (void)applyExpanded:(BOOL)expanded;
- (void)publishSize;
- (void)displayExpanded:(BOOL)expanded;
- (void)animateIconsExpanded:(BOOL)expanded entering:(BOOL)entering;
- (void)removeIconAnimations;
@end

@interface ApolloNavigationActionsStandardItem : NSObject
@property (nonatomic, weak) UIBarButtonItem *item;
@property (nonatomic, weak) ApolloNavigationActionsOwner *owner;
@property (nonatomic) BOOL hidden;
@end
@implementation ApolloNavigationActionsStandardItem
@end

@interface ApolloNavigationActionsOwner : NSObject
@property (nonatomic, weak) UINavigationItem *item;
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, strong) NSArray<ApolloNavigationActionsStrip *> *strips;
@property (nonatomic, strong) NSMutableArray<ApolloNavigationActionsStandardItem *> *standardItems;
@property (nonatomic, weak) UIBarButtonItem *moreItem;
@property (nonatomic, strong) UIBarButtonItem *inboxDisclosure;
@property (nonatomic, copy) UIAction *nativePrimaryAction;
@property (nonatomic, copy) UIMenu *nativeMenu;
@property (nonatomic, strong) UIViewPropertyAnimator *animator;
@property (nonatomic, strong) NSHashTable<UIPanGestureRecognizer *> *pans;
@property (nonatomic, weak) UIView *scrollRegistrationRoot;
@property (nonatomic, weak) UIGestureRecognizer *backGesture;
@property (nonatomic, strong) id resignObserver;
@property (nonatomic) BOOL expanded;
@property (nonatomic) BOOL preparing;
@property (nonatomic) BOOL needsGeometryTransition;
@property (nonatomic) BOOL geometryDeferred;
@property (nonatomic) BOOL needsAnimationSettlement;
- (void)prepareItems:(NSArray<UIBarButtonItem *> *)items;
- (BOOL)deferGeometryUpdate;
- (void)publishExpandedState;
- (void)settleAnimationIfNeeded;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)watchScrollViews;
- (void)scrolled:(UIPanGestureRecognizer *)pan;
- (void)restoreStandardItems;
- (void)applyStandardExpanded:(BOOL)expanded;
@end

static BOOL ApolloActionsMoreName(NSString *name) {
    NSString *lower = name.lowercaseString;
    // Matching "options" would mistake moderatorOptionsButtonTapped for More.
    return [lower containsString:@"more"] || [lower containsString:@"ellipsis"];
}

static UIButton *ApolloActionsFindMore(UIView *root) {
    if ([root isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)root;
        if (ApolloActionsMoreName(button.accessibilityLabel)) return button;
        for (id target in button.allTargets) {
            for (NSString *action in [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
                if (ApolloActionsMoreName(action)) return button;
            }
        }
    }
    for (UIView *child in root.subviews) {
        UIButton *more = ApolloActionsFindMore(child);
        if (more) return more;
    }
    return nil;
}

static NSUInteger ApolloActionsControlCount(UIView *root) {
    if ([root isKindOfClass:UIControl.class]) return 1;
    NSUInteger count = 0;
    for (UIView *child in root.subviews) count += ApolloActionsControlCount(child);
    return count;
}

static void ApolloActionsSetPrimaryAction(UIBarButtonItem *item, UIAction *action) {
    // Preserve Apollo's artwork/title when UIKit copies the action's metadata.
    UIImage *image = item.image;
    NSString *title = item.title;
    item.primaryAction = action;
    item.image = image;
    item.title = title;
}

UIView *ApolloNavigationActionsContentView(UIBarButtonItem *item) {
    UIView *view = item.customView;
    return [view isKindOfClass:ApolloNavigationActionsStrip.class]
        ? ((ApolloNavigationActionsStrip *)view).content : view;
}

UIView *ApolloNavigationActionsMenuSourceView(UIView *action) {
    for (UIView *view = action; view; view = view.superview) {
        if ([view isKindOfClass:ApolloNavigationActionsStrip.class]) {
            return ((ApolloNavigationActionsStrip *)view).surface;
        }
    }
    return nil;
}

@implementation ApolloNavigationActionsStrip
- (instancetype)initWithContent:(UIView *)content more:(UIButton *)more {
    self = [super initWithFrame:CGRectMake(0, 0, 44, 44)];
    if (!self) return nil;
    _content = content;
    _more = more;
    _originalAccessibilityHidden = content.accessibilityElementsHidden;
    _animatedIconLayers = [NSHashTable weakObjectsHashTable];
    _iconMotionKey = [NSString stringWithFormat:@"ApolloReborn.actions.motion.%p", self];
    _iconOpacityKey = [NSString stringWithFormat:@"ApolloReborn.actions.opacity.%p", self];
    self.clipsToBounds = NO;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    UIVisualEffect *effect = ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, NSSelectorFromString(@"effectWithStyle:"), 0);
    self.surface = [[UIVisualEffectView alloc] initWithEffect:effect];
    self.surface.frame = self.bounds;
    self.surface.clipsToBounds = YES;
    self.surface.layer.cornerRadius = 22;
    Class cornerClass = NSClassFromString(@"UICornerConfiguration");
    SEL capsule = NSSelectorFromString(@"capsuleConfiguration");
    SEL setter = NSSelectorFromString(@"setCornerConfiguration:");
    if ([cornerClass respondsToSelector:capsule] && [self.surface respondsToSelector:setter]) {
        id configuration = ((id (*)(id, SEL))objc_msgSend)(cornerClass, capsule);
        ((void (*)(id, SEL, id))objc_msgSend)(self.surface, setter, configuration);
    }
    [self addSubview:self.surface];
    self.widthConstraint = [self.widthAnchor constraintEqualToConstant:44];
    self.widthConstraint.active = YES;
    [self addTarget:self action:@selector(reveal:) forControlEvents:UIControlEventTouchUpInside];
    self.accessibilityLabel = @"Show navigation actions";
    self.accessibilityHint = @"Expands the page's buttons. Scrolling closes them.";
    [self remeasure];
    [self applyExpanded:NO];
    return self;
}
- (BOOL)deferGeometryForNativeMenu {
    if (!ApolloNativeActionMenuOwnsNavigationSurface(self.surface)) return NO;
    [self.owner deferGeometryUpdate];
    return YES;
}
- (void)remeasure {
    if ([self deferGeometryForNativeMenu]) return;
    // Measure the full source, including late globes, not the clipped viewport.
    CGRect moreFrame = [self.more convertRect:self.more.bounds toView:self.content];
    BOOL changed = fabs(self.moreMidX - CGRectGetMidX(moreFrame)) > 0.01;
    self.moreMidX = CGRectGetMidX(moreFrame);
    self.expandedWidth = MAX(44, ceil(self.moreMidX + 22));
    CGFloat width = self.expanded ? self.expandedWidth : 44;
    if (fabs(self.widthConstraint.constant - width) > 0.01) {
        self.widthConstraint.constant = width;
        [self invalidateIntrinsicContentSize];
        changed = YES;
    }
    if (changed) [self setNeedsLayout];
}
- (CGSize)intrinsicContentSize {
    return CGSizeMake(self.expanded ? self.expandedWidth : 44, 44);
}
- (CGSize)sizeThatFits:(CGSize)size { return self.intrinsicContentSize; }
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size { return self.intrinsicContentSize; }
- (CGSize)systemLayoutSizeFittingSize:(CGSize)size withHorizontalFittingPriority:(UILayoutPriority)horizontal verticalFittingPriority:(UILayoutPriority)vertical {
    return self.intrinsicContentSize;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if ([self deferGeometryForNativeMenu]) return;
    // Async host resizing must preserve the surface's right edge and animated width.
    CGRect glassFrame = self.surface.frame;
    glassFrame.origin = CGPointMake(self.bounds.size.width - glassFrame.size.width, (self.bounds.size.height - 44) / 2);
    if (!CGRectEqualToRect(self.surface.frame, glassFrame)) self.surface.frame = glassFrame;
    [self layoutContent];
}
- (void)layoutContent {
    if ([self deferGeometryForNativeMenu]) return;
    CGSize size = self.content.bounds.size;
    CGRect frame = CGRectMake(self.surface.bounds.size.width - 22 - self.moreMidX,
        (44 - size.height) / 2, size.width, size.height);
    if (!CGRectEqualToRect(self.content.frame, frame)) self.content.frame = frame;
}
- (void)publishSize {
    if ([self deferGeometryForNativeMenu]) return;
    self.barItem.width = self.intrinsicContentSize.width;
    CGRect frame = self.frame;
    frame.size = self.intrinsicContentSize;
    self.frame = frame;
    [self layoutIfNeeded];
}
- (void)displayExpanded:(BOOL)expanded {
    if ([self deferGeometryForNativeMenu]) return;
    CGFloat width = expanded ? self.expandedWidth : 44;
    self.surface.frame = CGRectMake(self.bounds.size.width - width, (self.bounds.size.height - 44) / 2, width, 44);
    [self layoutContent];
}
- (void)animateIconsExpanded:(BOOL)expanded entering:(BOOL)entering {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:self.content];
    NSHashTable<CALayer *> *liveLayers = [NSHashTable weakObjectsHashTable];
    for (NSUInteger i = 0; i < queue.count; i++) {
        UIView *view = queue[i];
        if (view == self.more) continue; // The one original More never animates.
        if (![view isKindOfClass:UIButton.class]) {
            [queue addObjectsFromArray:view.subviews];
            continue;
        }
        UIButton *button = (id)view;
        UIImageView *glyph = button.imageView;
        if (!glyph.image) continue;
        CALayer *layer = glyph.layer;
        [liveLayers addObject:layer];
        CGFloat distance = self.moreMidX - CGRectGetMidX([button convertRect:button.bounds toView:self.content]);
        // Drift from the disclosure side, but don't cross into the More glyph.
        CGFloat offset = MIN(18, MAX(0, distance - 32));
        BOOL continuing = [layer animationForKey:self.iconMotionKey] != nil;
        CALayer *presentation = layer.presentationLayer;
        CGFloat fromX = (expanded && entering) ? offset : 0;
        CGFloat fromOpacity = (expanded && entering) ? -1 : 0;
        if (continuing && presentation) {
            fromX = [[presentation valueForKeyPath:@"transform.translation.x"] doubleValue] -
                [[layer valueForKeyPath:@"transform.translation.x"] doubleValue];
            fromOpacity = presentation.opacity - layer.opacity;
        }
        CASpringAnimation *motion = ApolloActionsSpring(@"transform.translation.x");
        motion.additive = YES;
        motion.fromValue = @(fromX);
        motion.toValue = @(expanded ? 0 : offset);
        CASpringAnimation *opacity = ApolloActionsSpring(@"opacity");
        opacity.additive = YES;
        opacity.fromValue = @(fromOpacity);
        opacity.toValue = @(expanded ? 0 : -1);
        // Hold until completion clips the strip, then remove both animations.
        // Leave model visibility/transform untouched for navigation and app snapshots.
        for (CAAnimation *animation in @[motion, opacity]) {
            animation.fillMode = kCAFillModeForwards;
            animation.removedOnCompletion = NO;
        }
        [layer addAnimation:motion forKey:self.iconMotionKey];
        [layer addAnimation:opacity forKey:self.iconOpacityKey];
    }
    for (CALayer *layer in self.animatedIconLayers) {
        if ([liveLayers containsObject:layer]) continue;
        [layer removeAnimationForKey:self.iconMotionKey];
        [layer removeAnimationForKey:self.iconOpacityKey];
    }
    self.animatedIconLayers = liveLayers;
}
- (void)removeIconAnimations {
    for (CALayer *layer in self.animatedIconLayers) {
        [layer removeAnimationForKey:self.iconMotionKey];
        [layer removeAnimationForKey:self.iconOpacityKey];
    }
    [self.animatedIconLayers removeAllObjects];
}
- (void)applyExpanded:(BOOL)expanded {
    if ([self deferGeometryForNativeMenu]) return;
    self.expanded = expanded;
    self.isAccessibilityElement = !expanded;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.content.accessibilityElementsHidden = expanded ? self.originalAccessibilityHidden : YES;
    [self remeasure];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Keep drawing the real More; route taps to Apollo only after expansion settles.
    return hit && (!self.expanded || self.owner.animator) ? self : hit;
}
- (BOOL)accessibilityActivate { [self.owner setExpanded:YES animated:YES]; return YES; }
- (void)reveal:(id)sender { [self.owner setExpanded:YES animated:YES]; }
- (void)dealloc {
    [self removeIconAnimations];
    if (self.content.superview == self.surface.contentView) self.content.accessibilityElementsHidden = self.originalAccessibilityHidden;
}
@end

static UINavigationController *ApolloActionsNavigation(UINavigationBar *bar) {
    for (UIResponder *responder = bar.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) return (id)responder;
    }
    return nil;
}

static BOOL ApolloActionsAppController(UIViewController *controller) {
    return [NSStringFromClass(controller.class) hasPrefix:@"Apollo."] ||
        [NSStringFromClass(controller.navigationController.class) hasPrefix:@"Apollo."];
}

static ApolloNavigationActionsOwner *ApolloActionsOwner(UINavigationItem *item, BOOL create) {
    if (!item) return nil;
    ApolloNavigationActionsOwner *owner = objc_getAssociatedObject(item, &kActionsOwnerKey);
    if (!owner && create) {
        owner = [ApolloNavigationActionsOwner new];
        owner.item = item;
        objc_setAssociatedObject(item, &kActionsOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (box.controller) owner.controller = box.controller;
    return owner;
}

static void ApolloActionsSetScrollOwner(UIPanGestureRecognizer *pan, ApolloNavigationActionsOwner *owner) {
    ApolloNavigationActionsScrollOwnerBox *box = objc_getAssociatedObject(pan, &kActionsScrollOwnerKey);
    ApolloNavigationActionsOwner *previous = box.owner;
    if (previous == owner) return;
    if (previous) {
        [pan removeTarget:previous action:@selector(scrolled:)];
        [previous.pans removeObject:pan];
    }
    if (owner) {
        if (!box) box = [ApolloNavigationActionsScrollOwnerBox new];
        box.owner = owner;
        [pan addTarget:owner action:@selector(scrolled:)];
        [owner.pans addObject:pan];
    }
    objc_setAssociatedObject(pan, &kActionsScrollOwnerKey, owner ? box : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloActionsUpdateScrollOwner(UIScrollView *scrollView) {
    ApolloNavigationActionsOwner *owner = nil;
    if (scrollView.window) {
        // Incoming pages can attach before becoming topViewController.
        // Walk past child controllers to find the actual page owner.
        for (UIResponder *responder = scrollView.nextResponder; responder; responder = responder.nextResponder) {
            if (![responder isKindOfClass:UIViewController.class]) continue;
            owner = ApolloActionsOwner(((UIViewController *)responder).navigationItem, NO);
            if (owner) break;
        }
    }
    ApolloActionsSetScrollOwner(scrollView.panGestureRecognizer, owner);
}

static NSArray<UIBarButtonItem *> *ApolloActionsInboxItems(UINavigationItem *item, NSArray<UIBarButtonItem *> *items) {
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (!IsLiquidGlass() || ![NSStringFromClass(box.controller.class) isEqual:@"Apollo.InboxViewController"]) return items;
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(item, YES);
    NSMutableArray *native = [items mutableCopy] ?: [NSMutableArray array];
    if (owner.inboxDisclosure) [native removeObjectIdenticalTo:owner.inboxDisclosure];
    // Inbox compose/selection modes and lone actions need no added disclosure.
    if (box.controller.isEditing || native.count < 2) return native;
    NSUInteger actionable = 0;
    for (UIBarButtonItem *candidate in native) {
        if (ApolloActionsMoreName(candidate.accessibilityLabel) ||
            ApolloActionsMoreName(NSStringFromSelector(candidate.action))) return native;
        if (candidate.customView || [candidate.title isEqualToString:@"Cancel"] ||
            [candidate.title isEqualToString:@"Done"] || [candidate.title isEqualToString:@"Edit"]) return native;
        ApolloNavigationActionsStandardItem *state = objc_getAssociatedObject(candidate, &kActionsStandardItemKey);
        BOOL nativeHidden = state ? state.hidden : candidate.hidden;
        if (!nativeHidden && (candidate.action || candidate.primaryAction || candidate.menu)) actionable++;
    }
    if (actionable < 2) return native;
    if (!owner.inboxDisclosure) {
        UIImage *image = [[UIImage imageNamed:@"option-more" inBundle:NSBundle.mainBundle compatibleWithTraitCollection:box.controller.traitCollection]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if (!image) return native;
        __weak ApolloNavigationActionsOwner *weakOwner = owner;
        owner.inboxDisclosure = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:nil action:nil];
        owner.inboxDisclosure.accessibilityLabel = @"More Options";
        // Inbox has no native More menu; this button closes the expanded group.
        owner.inboxDisclosure.primaryAction = [UIAction actionWithTitle:@"" image:image identifier:nil handler:^(__unused UIAction *action) {
            [weakOwner setExpanded:NO animated:YES];
        }];
    }
    [native insertObject:owner.inboxDisclosure atIndex:0];
    return native;
}

@implementation ApolloNavigationActionsOwner
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _standardItems = [NSMutableArray array];
    _pans = [NSHashTable weakObjectsHashTable];
    __weak typeof(self) weakSelf = self;
    _resignObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            // Finish our animation without retaining UIKit's transient hidden/alpha state.
            [weakSelf setExpanded:NO animated:NO];
        }];
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self.resignObserver];
    for (UIPanGestureRecognizer *pan in self.pans) [pan removeTarget:self action:@selector(scrolled:)];
    [self.backGesture removeTarget:self action:@selector(backGestureChanged:)];
    [self restoreStandardItems];
}
- (void)restoreStandardItems {
    sActionsModelWriteDepth++;
    for (ApolloNavigationActionsStandardItem *state in self.standardItems) {
        state.item.hidden = state.hidden;
        objc_setAssociatedObject(state.item, &kActionsStandardItemKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self.standardItems removeAllObjects];
    if (self.moreItem) {
        objc_setAssociatedObject(self.moreItem, &kActionsStandardMoreKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloActionsSetPrimaryAction(self.moreItem, self.nativePrimaryAction);
        self.moreItem.menu = self.nativeMenu;
    }
    self.moreItem = nil;
    self.nativeMenu = nil;
    self.nativePrimaryAction = nil;
    sActionsModelWriteDepth--;
}
- (BOOL)deferGeometryUpdate {
    for (ApolloNavigationActionsStrip *strip in self.strips) {
        if (!ApolloNativeActionMenuOwnsNavigationSurface(strip.surface)) continue;
        if (!self.geometryDeferred) {
            self.geometryDeferred = YES;
            __weak typeof(self) weakSelf = self;
            ApolloNativeActionMenuDeferNavigationUpdate(strip.surface, @"navigation-actions.geometry", ^{
                ApolloNavigationActionsOwner *owner = weakSelf;
                if (!owner) return;
                owner.geometryDeferred = NO;
                // Setters may run during the menu; use the latest items on release.
                [owner prepareItems:owner.item.rightBarButtonItems];
                // A spring may have finished during native ownership; publish
                // its final width and remove held glyph animations as well.
                [owner settleAnimationIfNeeded];
            });
        }
        return YES;
    }
    return NO;
}
- (void)prepareItems:(NSArray<UIBarButtonItem *> *)items {
    if (self.preparing) return;
    // Freeze all geometry and icon cleanup while UIKit owns the surface,
    // including late action insertion and overlapping menu sessions.
    if ([self deferGeometryUpdate]) return;
    self.preparing = YES;
    BOOL retargetAnimation = NO;
    NSMutableArray *strips = [NSMutableArray array];
    for (UIBarButtonItem *item in items) {
        UIView *source = ApolloNavigationActionsContentView(item);
        ApolloNavigationActionsStrip *strip = [item.customView isKindOfClass:ApolloNavigationActionsStrip.class]
            ? (id)item.customView : nil;
        UIButton *more = strip.more ?: ApolloActionsFindMore(source);
        if (!strip && more && ApolloActionsControlCount(source) > 1) {
            strip = [[ApolloNavigationActionsStrip alloc] initWithContent:source more:more];
            item.customView = strip;
            // setCustomView: detaches the old view even if reparented; adopt it afterward.
            [strip.surface.contentView addSubview:source];
            // Hide the item's default glass, not ancestor views, to avoid double glass.
            if (@available(iOS 26.0, *)) item.hidesSharedBackground = YES;
            // Match native transitions without sharing views between pages.
            if (@available(iOS 26.0, *)) {
                if (!item.identifier) item.identifier = @"ApolloReborn.navigation-actions";
            }
            ApolloLog(@"[NavigationActions] Installed native item strip on %@", NSStringFromClass(self.controller.class));
        }
        if (strip) {
            strip.owner = self;
            strip.barItem = item;
            CGFloat previousWidth = strip.expandedWidth;
            CGFloat previousMoreMidX = strip.moreMidX;
            if (!self.animator) {
                [strip applyExpanded:self.expanded];
                // Animate late slots from the current pill/title presentation,
                // rather than publishing the new width immediately.
                if (self.expanded && fabs(previousWidth - strip.expandedWidth) > 0.01) {
                    self.needsGeometryTransition = YES;
                    retargetAnimation = YES;
                } else {
                    [strip displayExpanded:self.expanded];
                }
            } else {
                [strip remeasure];
                retargetAnimation |= fabs(previousWidth - strip.expandedWidth) > 0.01 ||
                    fabs(previousMoreMidX - strip.moreMidX) > 0.01 || ![self.strips containsObject:strip];
            }
            [strips addObject:strip];
        }
    }
    retargetAnimation |= self.animator && self.strips.count != strips.count;
    // Buttons may move to a new container while UIKit retains the outgoing strip.
    // Remove their old effects immediately.
    for (ApolloNavigationActionsStrip *oldStrip in self.strips) {
        if (![strips containsObject:oldStrip]) [oldStrip removeIconAnimations];
    }
    self.strips = strips;
    // Non-custom items use item.hidden; lone actions and pages without More stay native.
    UIBarButtonItem *more = items.firstObject;
    BOOL standard = strips.count == 0 && items.count > 1 && !more.customView &&
        (ApolloActionsMoreName(more.accessibilityLabel) || ApolloActionsMoreName(NSStringFromSelector(more.action)));
    BOOL same = standard && more == self.moreItem && self.standardItems.count == items.count - 1;
    if (same) {
        for (NSUInteger i = 1; i < items.count; i++) if (self.standardItems[i - 1].item != items[i]) same = NO;
    }
    if (!same) {
        [self restoreStandardItems];
        if (standard) {
            self.moreItem = more;
            self.nativeMenu = more.menu;
            self.nativePrimaryAction = more.primaryAction;
            ApolloNavigationActionsStandardItem *moreState = [ApolloNavigationActionsStandardItem new];
            moreState.item = more; moreState.owner = self;
            objc_setAssociatedObject(more, &kActionsStandardMoreKey, moreState, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (NSUInteger i = 1; i < items.count; i++) {
                ApolloNavigationActionsStandardItem *state = [ApolloNavigationActionsStandardItem new];
                state.item = items[i]; state.owner = self; state.hidden = items[i].hidden;
                objc_setAssociatedObject(items[i], &kActionsStandardItemKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self.standardItems addObject:state];
            }
            if (@available(iOS 26.0, *)) {
                if (!more.identifier) more.identifier = @"ApolloReborn.navigation-actions";
            }
            [self applyStandardExpanded:self.expanded];
        }
    }
    self.preparing = NO;
    // Retarget mid-reveal source updates from the current presentation to avoid a snap.
    if (retargetAnimation) [self setExpanded:self.expanded animated:YES];
}
- (void)applyStandardExpanded:(BOOL)expanded {
    sActionsModelWriteDepth++;
    for (ApolloNavigationActionsStandardItem *state in self.standardItems) state.item.hidden = state.hidden || !expanded;
    UIBarButtonItem *more = self.moreItem;
    if (more) {
        if (expanded) {
            ApolloActionsSetPrimaryAction(more, self.nativePrimaryAction);
            more.menu = self.nativeMenu;
        } else {
            UIImage *image = more.image;
            NSString *title = more.title;
            __weak typeof(self) weakSelf = self;
            more.menu = nil;
            ApolloActionsSetPrimaryAction(more, [UIAction actionWithTitle:title ?: @"" image:image identifier:nil
                handler:^(__unused UIAction *action) { [weakSelf setExpanded:YES animated:YES]; }]);
        }
    }
    sActionsModelWriteDepth--;
}
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (self.expanded == expanded && !self.animator && !self.needsGeometryTransition &&
        !self.needsAnimationSettlement) return;
    if (!expanded) {
        __weak typeof(self) weakSelf = self;
        for (ApolloNavigationActionsStrip *strip in self.strips) {
            if (ApolloNativeActionMenuDeferNavigationCollapse(strip.surface, ^{
                ApolloNavigationActionsOwner *owner = weakSelf;
                BOOL visible = owner.controller.navigationController.navigationBar.topItem == owner.item;
                // A final pan Changed may already have started collapse; don't restart it.
                if (owner.expanded) [owner setExpanded:NO animated:animated && visible];
            })) return;
        }
    } else {
        for (ApolloNavigationActionsStrip *strip in self.strips) {
            __weak typeof(self) weakSelf = self;
            if (ApolloNativeActionMenuDeferNavigationUpdate(strip.surface, @"navigation-actions.expansion", ^{
                ApolloNavigationActionsOwner *owner = weakSelf;
                BOOL visible = owner.controller.navigationController.navigationBar.topItem == owner.item;
                [owner setExpanded:YES animated:animated && visible];
            })) return;
        }
    }
    self.needsGeometryTransition = NO;
    // Supersede deferred settlement so it cannot snap or clean up this new transition.
    self.needsAnimationSettlement = NO;
    // Reversals begin from presentation state, not a guessed endpoint.
    UIViewPropertyAnimator *previous = self.animator;
    BOOL entering = !self.expanded || previous != nil;
    self.animator = nil;
    [previous stopAnimation:NO];
    [previous finishAnimationAtPosition:UIViewAnimatingPositionCurrent];
    if (self.strips.count == 0 && !self.moreItem) {
        self.expanded = NO;
        return;
    }
    UINavigationBar *bar = self.controller.navigationController.navigationBar;
    // Resetting an outgoing item must not move or lay out the new page's title.
    if (bar.topItem != self.item) bar = nil;
    [bar layoutIfNeeded];
    ApolloNavigationTitleActionsWillChange(bar);
    self.expanded = expanded;
    if (animated && bar.window && !UIAccessibilityIsReduceMotionEnabled()) {
        // Reserve hit-test space before reveal; shrink it only after collapse.
        // Glass and content share a lightly underdamped spring, keeping More
        // pinned throughout the bounce without exposing the host's width jump.
        CASpringAnimation *spring = ApolloActionsSpring(nil);
        UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithMass:spring.mass
            stiffness:spring.stiffness damping:spring.damping initialVelocity:CGVectorMake(0, 0)];
        UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:kActionsAnimationDuration
            timingParameters:timing];
        self.animator = animator;
        if (expanded) [UIView performWithoutAnimation:^{ [self publishExpandedState]; }];
        [animator addAnimations:^{
            for (ApolloNavigationActionsStrip *strip in self.strips) [strip displayExpanded:expanded];
            [self applyStandardExpanded:expanded];
        }];
        __weak typeof(self) weakSelf = self;
        __weak UIViewPropertyAnimator *weakAnimator = animator;
        [animator addCompletion:^(__unused UIViewAnimatingPosition position) {
            ApolloNavigationActionsOwner *owner = weakSelf;
            if (!owner || owner.animator != weakAnimator) return;
            owner.animator = nil;
            // A menu may acquire the source mid-spring; defer the entire settlement.
            owner.needsAnimationSettlement = YES;
            [owner settleAnimationIfNeeded];
        }];
        [animator startAnimation];
        for (ApolloNavigationActionsStrip *strip in self.strips) [strip animateIconsExpanded:expanded entering:entering];
        ApolloNavigationTitleActionsDidChange(bar, spring);
    } else {
        self.needsAnimationSettlement = YES;
        [UIView performWithoutAnimation:^{
            [self settleAnimationIfNeeded];
            [self applyStandardExpanded:expanded];
        }];
        ApolloNavigationTitleActionsDidChange(bar, nil);
    }
    if (expanded) [self watchScrollViews];
    ApolloLog(@"[NavigationActions] %@ %@", NSStringFromClass(self.controller.class), expanded ? @"expanded" : @"collapsed");
}
- (void)publishExpandedState {
    if ([self deferGeometryUpdate]) return;
    for (ApolloNavigationActionsStrip *strip in self.strips) {
        [strip applyExpanded:self.expanded];
        [strip publishSize];
    }
    // iOS 27's SwiftUI host caches custom-item width until the navigation model
    // changes. Reuse current identities, including any late native replacement.
    [self.item setRightBarButtonItems:self.item.rightBarButtonItems animated:NO];
    UINavigationBar *bar = self.controller.navigationController.navigationBar;
    if (bar.topItem != self.item) return; // Never drive the page we navigated to.
    [bar setNeedsLayout];
    [bar layoutIfNeeded];
}
- (void)settleAnimationIfNeeded {
    if (!self.needsAnimationSettlement || self.animator || [self deferGeometryUpdate]) return;
    self.needsAnimationSettlement = NO;
    [UIView performWithoutAnimation:^{
        // Queued updates may replace items or start a spring; use live state.
        [self publishExpandedState];
        if (self.animator) return;
        // Publishing can synchronously open another menu; defer cleanup again.
        if ([self deferGeometryUpdate]) {
            self.needsAnimationSettlement = YES;
            return;
        }
        for (ApolloNavigationActionsStrip *strip in self.strips) {
            [strip displayExpanded:self.expanded];
            [strip removeIconAnimations];
        }
    }];
}
- (void)watchScrollViews {
    if (!self.controller.isViewLoaded) return;
    UIGestureRecognizer *backGesture = self.controller.navigationController.interactivePopGestureRecognizer;
    if (backGesture != self.backGesture) {
        [self.backGesture removeTarget:self action:@selector(backGestureChanged:)];
        self.backGesture = backGesture;
        [backGesture addTarget:self action:@selector(backGestureChanged:)];
    }
    UIView *root = self.controller.view;
    if (root == self.scrollRegistrationRoot) return;
    // Scan once per page; attachment hooks register later scroll views.
    // Expanding must not rescan loaded post/comment cells.
    for (UIPanGestureRecognizer *pan in self.pans.allObjects) {
        ApolloActionsSetScrollOwner(pan, nil);
    }
    [self.pans removeAllObjects];
    self.scrollRegistrationRoot = root;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger i = 0; i < queue.count; i++) {
        UIView *view = queue[i];
        if ([view isKindOfClass:UIScrollView.class]) {
            ApolloActionsUpdateScrollOwner((UIScrollView *)view);
        }
        [queue addObjectsFromArray:view.subviews];
    }
}
- (void)scrolled:(UIPanGestureRecognizer *)pan {
    if (self.expanded && (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged)) {
        [self setExpanded:NO animated:YES];
    }
}
- (void)backGestureChanged:(UIGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) [self setExpanded:NO animated:NO];
}
@end

static void ApolloActionsPrepare(UINavigationItem *item, NSArray *items) {
    if (!IsLiquidGlass()) return;
    ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
    if (!box.controller || !ApolloActionsAppController(box.controller)) return;
    [ApolloActionsOwner(item, YES) prepareItems:items];
}

void ApolloNavigationActionsRefresh(UINavigationBar *bar) {
    if (!bar || !IsLiquidGlass() || [objc_getAssociatedObject(bar, &kActionsRefreshKey) boolValue]) return;
    objc_setAssociatedObject(bar, &kActionsRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UINavigationBar *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationBar *bar = weakBar;
        if (!bar) return;
        objc_setAssociatedObject(bar, &kActionsRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIViewController *top = ApolloActionsNavigation(bar).topViewController;
        if (!top || bar.topItem != top.navigationItem) return;
        ApolloActionsPrepare(top.navigationItem, top.navigationItem.rightBarButtonItems);
    });
}

CGRect ApolloNavigationActionsCollapsedFrame(UINavigationBar *bar) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(bar.topItem, NO);
    for (ApolloNavigationActionsStrip *strip in owner.strips) {
        if (![strip isDescendantOfView:bar]) continue;
        CGRect rect = [strip convertRect:strip.bounds toView:bar];
        return CGRectMake(CGRectGetMaxX(rect) - 44, CGRectGetMidY(rect) - 22, 44, 44);
    }
    if (owner.moreItem) {
        UIView *view = ApolloNavigationActionsItemViewCandidates(owner.moreItem).lastObject;
        if ([view isDescendantOfView:bar]) {
            CGRect rect = [view convertRect:view.bounds toView:bar];
            return CGRectMake(CGRectGetMidX(rect) - 22, CGRectGetMidY(rect) - 22, 44, 44);
        }
    }
    return CGRectNull;
}

CGRect ApolloNavigationActionsExpandedFrame(UINavigationBar *bar) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(bar.topItem, NO);
    if (!owner.expanded) return CGRectNull;
    CGRect result = CGRectNull;
    for (ApolloNavigationActionsStrip *strip in owner.strips) {
        if (![strip isDescendantOfView:bar]) continue;
        CGRect rect = [strip convertRect:strip.bounds toView:bar];
        // Model endpoint, not the spring's per-frame glass width. More is
        // trailing-anchored in either state, including interrupted collapse.
        rect = CGRectMake(CGRectGetMaxX(rect) - strip.expandedWidth,
            CGRectGetMidY(rect) - 22, strip.expandedWidth, 44);
        result = CGRectIsNull(result) ? rect : CGRectUnion(result, rect);
    }
    if (owner.moreItem) {
        for (UIBarButtonItem *item in owner.item.rightBarButtonItems) {
            if (item.hidden) continue;
            UIView *view = ApolloNavigationActionsItemViewCandidates(item).lastObject;
            if (![view isDescendantOfView:bar]) continue;
            CGRect rect = [view convertRect:view.bounds toView:bar];
            if (CGRectIsEmpty(rect)) continue;
            result = CGRectIsNull(result) ? rect : CGRectUnion(result, rect);
        }
    }
    return result;
}

NSArray<UIView *> *ApolloNavigationActionsManagedRoots(UINavigationBar *bar) {
    ApolloNavigationActionsOwner *owner = ApolloActionsOwner(bar.topItem, NO);
    if (owner.strips.count == 0 && !owner.moreItem) return @[];
    return ApolloNavigationActionsDiscoverGroups(bar, bar.topItem);
}

%group ApolloNavigationActionsHooks
%hook UIViewController
- (UINavigationItem *)navigationItem {
    UINavigationItem *item = %orig;
    if (IsLiquidGlass() && ApolloActionsAppController(self)) {
        ApolloNavigationActionsControllerBox *box = objc_getAssociatedObject(item, &kActionsControllerKey);
        if (!box) {
            box = [ApolloNavigationActionsControllerBox new];
            objc_setAssociatedObject(item, &kActionsControllerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        box.controller = self;
    }
    return item;
}
- (void)viewWillAppear:(BOOL)animated {
    ApolloActionsPrepare(self.navigationItem, self.navigationItem.rightBarButtonItems);
    %orig(animated);
    ApolloActionsPrepare(self.navigationItem, self.navigationItem.rightBarButtonItems);
}
- (void)viewWillDisappear:(BOOL)animated {
    [ApolloActionsOwner(self.navigationItem, NO) setExpanded:NO animated:NO];
    %orig(animated);
}
%end

%hook UINavigationItem
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items {
    items = ApolloActionsInboxItems(self, items);
    ApolloActionsPrepare(self, items);
    %orig(items);
    ApolloActionsPrepare(self, self.rightBarButtonItems);
}
- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated {
    items = ApolloActionsInboxItems(self, items);
    ApolloActionsPrepare(self, items);
    %orig(items, animated);
    ApolloActionsPrepare(self, self.rightBarButtonItems);
}
- (void)setRightBarButtonItem:(UIBarButtonItem *)item {
    ApolloActionsPrepare(self, item ? @[item] : @[]);
    %orig(item);
    ApolloActionsPrepare(self, self.rightBarButtonItems);
}
- (void)setRightBarButtonItem:(UIBarButtonItem *)item animated:(BOOL)animated {
    ApolloActionsPrepare(self, item ? @[item] : @[]);
    %orig(item, animated);
    ApolloActionsPrepare(self, self.rightBarButtonItems);
}
%end

%hook UIBarButtonItem
- (void)setMenu:(UIMenu *)menu {
    ApolloNavigationActionsStandardItem *state = sActionsModelWriteDepth ? nil : objc_getAssociatedObject(self, &kActionsStandardMoreKey);
    if (state.owner) {
        state.owner.nativeMenu = menu;
        UIMenu *effectiveMenu = state.owner.expanded ? menu : nil;
        %orig(effectiveMenu);
    } else {
        %orig(menu);
    }
}
- (void)setPrimaryAction:(UIAction *)action {
    ApolloNavigationActionsStandardItem *state = sActionsModelWriteDepth ? nil : objc_getAssociatedObject(self, &kActionsStandardMoreKey);
    if (state.owner) state.owner.nativePrimaryAction = action;
    %orig(action);
    if (state.owner && !state.owner.expanded) [state.owner applyStandardExpanded:NO];
}
- (void)setHidden:(BOOL)hidden {
    ApolloNavigationActionsStandardItem *state = sActionsModelWriteDepth ? nil : objc_getAssociatedObject(self, &kActionsStandardItemKey);
    if (state) {
        state.hidden = hidden;
        BOOL effectiveHidden = hidden || !state.owner.expanded;
        %orig(effectiveHidden);
    } else {
        %orig(hidden);
    }
}
%end

%hook UIScrollView
- (void)didMoveToWindow {
    %orig;
    if (IsLiquidGlass()) ApolloActionsUpdateScrollOwner(self);
}
- (void)didMoveToSuperview {
    %orig;
    // Reparenting inside the same window need not change window membership.
    if (IsLiquidGlass()) ApolloActionsUpdateScrollOwner(self);
}
%end

%hook UINavigationController
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    [ApolloActionsOwner(self.topViewController.navigationItem, NO) setExpanded:NO animated:NO];
    ApolloActionsPrepare(controller.navigationItem, controller.navigationItem.rightBarButtonItems);
    %orig(controller, animated);
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    [ApolloActionsOwner(self.topViewController.navigationItem, NO) setExpanded:NO animated:NO];
    return %orig(animated);
}
- (NSArray *)popToViewController:(UIViewController *)controller animated:(BOOL)animated {
    [ApolloActionsOwner(self.topViewController.navigationItem, NO) setExpanded:NO animated:NO];
    return %orig(controller, animated);
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    [ApolloActionsOwner(self.topViewController.navigationItem, NO) setExpanded:NO animated:NO];
    return %orig(animated);
}
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated {
    [ApolloActionsOwner(self.topViewController.navigationItem, NO) setExpanded:NO animated:NO];
    for (UIViewController *controller in controllers) ApolloActionsPrepare(controller.navigationItem, controller.navigationItem.rightBarButtonItems);
    %orig(controllers, animated);
}
%end
%end

%ctor {
    if (@available(iOS 26.0, *)) {
        %init(ApolloNavigationActionsHooks);
        ApolloLog(@"[NavigationActions] Page-owned native strip hooks installed");
    }
}
