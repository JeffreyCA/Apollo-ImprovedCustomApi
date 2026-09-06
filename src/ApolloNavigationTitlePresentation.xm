#import "ApolloNavigationTitlePresentation.h"
#import "ApolloNavigationActions.h"
#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

// UIKit may hide the title to fit the uncollapsed action group. Host a native
// title control outside that allocator, preserving the item's original custom
// view, actions and interactions rather than cloning or replacing them.
static char kApolloTitlePresentationOwnerKey;
static char kApolloTitlePresentationItemOwnerKey;
static char kApolloTitlePresentationItemTokenKey;
static char kApolloTitlePresentationOwnedKey;
static char kApolloTitlePresentationSourceKey;
static NSUInteger sApolloTitlePresentationWriteDepth;

static BOOL ApolloTitlePresentationAvailable(void) {
    // IsLiquidGlass checks the linked SDK; also require a glass-capable OS.
    return IsLiquidGlass() && objc_getClass("UIGlassEffect") != Nil &&
        objc_getClass("_UINavigationBarTitleControl") != Nil;
}

@interface _UINavigationBarTitleControl : UIControl
@end

@class ApolloTitlePresentationOwner;

@interface ApolloTitlePresentationOwnerBox : NSObject
@property (nonatomic, weak) ApolloTitlePresentationOwner *owner;
@end
@implementation ApolloTitlePresentationOwnerBox
@end

@interface ApolloTitlePresentationSource : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) ApolloTitlePresentationOwner *owner;
@property (nonatomic, strong) id navigationItemToken;
@property (nonatomic) CGFloat nativeAlpha;
@property (nonatomic) BOOL nativeHidden;
@property (nonatomic) BOOL nativeInteraction;
@property (nonatomic) BOOL nativeAccessibilityHidden;
@property (nonatomic, copy) NSDictionary *attributes;
@property (nonatomic, copy) id menuProvider;
@property (nonatomic, strong) id documentProperties;
@property (nonatomic, strong) UIView *customView;
@property (nonatomic, copy) NSAttributedString *attributedTitle;
@end
@implementation ApolloTitlePresentationSource
@end

@interface ApolloTitlePresentationOwner : NSObject
@property (nonatomic, weak) UINavigationBar *bar;
@property (nonatomic, weak) UINavigationItem *item;
@property (nonatomic, strong) UIView *control;
@property (nonatomic, strong) NSMutableArray<ApolloTitlePresentationSource *> *sources;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *placementConstraints;
@property (nonatomic, strong) NSLayoutConstraint *topConstraint;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) UIView *customView;
@property (nonatomic) CGRect customOriginalFrame;
@property (nonatomic) BOOL customOriginalTAMIC;
@property (nonatomic) UIViewAutoresizing customOriginalAutoresizingMask;
@property (nonatomic, copy) NSDictionary *appliedAttributes;
@property (nonatomic, copy) id appliedMenu;
@property (nonatomic, strong) id appliedDocument;
@property (nonatomic, copy) NSAttributedString *appliedTitle;
@property (nonatomic, strong) UIFont *appliedPreferredFont;
@property (nonatomic, strong) id<UIViewControllerTransitionCoordinator> pendingTransition;
@property (nonatomic, weak) id<UIViewControllerTransitionCoordinator> completedTransition;
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL scheduled;
@property (nonatomic) BOOL refreshing;
@property (nonatomic, copy) NSString *lastHostDiagnostic;
- (instancetype)initWithBar:(UINavigationBar *)bar;
- (void)scheduleRefresh;
- (void)refresh;
- (void)resetPresentation;
- (void)restoreSource:(ApolloTitlePresentationSource *)source;
- (ApolloTitlePresentationSource *)captureSource:(UIView *)view;
@end

static id ApolloTitlePresentationRead(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static id ApolloTitlePresentationItemToken(UINavigationItem *item) {
    if (!item) return nil;
    id token = objc_getAssociatedObject(item, &kApolloTitlePresentationItemTokenKey);
    if (!token) {
        token = [NSObject new];
        objc_setAssociatedObject(item, &kApolloTitlePresentationItemTokenKey, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return token;
}

static id ApolloTitlePresentationReadOrCaptured(id object, NSString *name, id captured) {
    SEL selector = NSSelectorFromString(name);
    // A supported getter's nil clears the value; never replay stale metadata.
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : captured;
}

static NSAttributedString *ApolloTitlePresentationSourceTitle(ApolloTitlePresentationSource *source) {
    UIView *view = source.view;
    BOOL hasAttributedGetter = [view respondsToSelector:NSSelectorFromString(@"attributedTitle")];
    NSAttributedString *title = ApolloTitlePresentationReadOrCaptured(view, @"attributedTitle", source.attributedTitle);
    if (hasAttributedGetter && title) return title;
    if ([view respondsToSelector:NSSelectorFromString(@"title")]) {
        NSString *plain = ApolloTitlePresentationRead(view, @"title");
        // Preserve matching formatting, but honor direct plaintext updates.
        if ([plain isKindOfClass:NSString.class]) {
            return [title.string isEqualToString:plain] ? title : [[NSAttributedString alloc] initWithString:plain];
        }
        return nil;
    }
    return title;
}

static BOOL ApolloTitlePresentationEqual(id left, id right) {
    return left == right || [left isEqual:right];
}

static BOOL ApolloTitlePresentationIsControl(UIView *view) {
    Class cls = NSClassFromString(@"_UINavigationBarTitleControl");
    return cls && [view isKindOfClass:cls];
}

static UINavigationController *ApolloTitlePresentationNavigation(UINavigationBar *bar) {
    for (UIResponder *responder = bar; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class] &&
            ((UINavigationController *)responder).navigationBar == bar) {
            return (UINavigationController *)responder;
        }
    }
    return nil;
}

static BOOL ApolloTitlePresentationIsAppNavigation(UINavigationController *navigation) {
    if ([NSStringFromClass(navigation.class) hasPrefix:@"Apollo."]) return YES;
    const char *image = class_getImageName(navigation.topViewController.class);
    if (!image) return NO;
    return [[NSString stringWithUTF8String:image] hasPrefix:NSBundle.mainBundle.bundlePath] ||
        strstr(image, "ApolloReborn") != NULL;
}

static UIView *ApolloTitlePresentationSourceAncestor(UIView *custom) {
    // Follow the custom view even if UIKit detached its title subtree.
    for (UIView *view = custom.superview; view; view = view.superview) {
        if (ApolloTitlePresentationIsControl(view) &&
            !ApolloNavigationTitlePresentationOwnsControl(view)) return view;
    }
    return nil;
}

static BOOL ApolloTitlePresentationVisible(UIView *view, UINavigationBar *bar) {
    if (!view.window || ![view isDescendantOfView:bar]) return NO;
    for (UIView *ancestor = view; ancestor && ancestor != bar; ancestor = ancestor.superview) {
        ApolloTitlePresentationSource *state = objc_getAssociatedObject(ancestor, &kApolloTitlePresentationSourceKey);
        CGFloat alpha = state ? state.nativeAlpha : ancestor.alpha;
        BOOL hidden = state ? state.nativeHidden : ancestor.hidden;
        if (hidden || alpha <= 0.01) return NO;
    }
    return YES;
}

static UIView *ApolloTitlePresentationHost(UINavigationBar *bar) {
    Class hostClass = NSClassFromString(@"_UINavigationBarHostedViewContainer");
    if (!hostClass || CGRectGetWidth(bar.bounds) <= 0) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *view = queue[index];
        if (ApolloTitlePresentationIsControl(view)) continue;
        if ([view isKindOfClass:hostClass] && view.userInteractionEnabled &&
            ApolloTitlePresentationVisible(view, bar)) {
            CGRect rect = [view convertRect:view.bounds toView:bar];
            // Use the full-width plane below the actions, not narrower wrappers
            // whose width UIKit allocates from the action group.
            if (!CGRectIsNull(rect) && !CGRectIsInfinite(rect) && !CGRectIsEmpty(rect) &&
                CGRectGetMinX(rect) <= CGRectGetMinX(bar.bounds) + 1.0 &&
                CGRectGetMaxX(rect) >= CGRectGetMaxX(bar.bounds) - 1.0 &&
                CGRectIntersectsRect(rect, bar.bounds)) return view;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static NSArray<UIView *> *ApolloTitlePresentationVisibleSources(UINavigationBar *bar, UINavigationItem *item) {
    NSMutableArray<UIView *> *result = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
    NSAttributedString *itemAttributed = ApolloTitlePresentationRead(item, @"attributedTitle");
    NSString *expectedTitle = itemAttributed.string ?: item.title ?: @"";
    for (NSUInteger index = 0; index < queue.count; index++) {
        UIView *view = queue[index];
        if (ApolloNavigationTitlePresentationOwnsControl(view)) continue;
        if (ApolloTitlePresentationIsControl(view)) {
            if (!ApolloTitlePresentationVisible(view, bar)) continue;
            ApolloTitlePresentationSource *state = objc_getAssociatedObject(view, &kApolloTitlePresentationSourceKey);
            UIView *custom = state ? state.customView : ApolloTitlePresentationRead(view, @"titleView");
            NSString *title = state ? ApolloTitlePresentationSourceTitle(state).string : ApolloTitlePresentationRead(view, @"title");
            if (item.titleView ? custom == item.titleView : (!custom && [title ?: @"" isEqualToString:expectedTitle])) {
                [result addObject:view];
            }
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return result;
}

static SEL ApolloTitlePresentationConfigureSelector(void) {
    return NSSelectorFromString(@"setTitleAttributes:titleMenuProvider:documentProperties:titleView:attributedTitle:");
}

static void ApolloTitlePresentationConfigure(UIView *control, NSDictionary *attributes,
                                             id menu, id document, UIView *custom,
                                             NSAttributedString *title) {
    sApolloTitlePresentationWriteDepth++;
    ((BOOL (*)(id, SEL, id, id, id, id, id))objc_msgSend)(control,
        ApolloTitlePresentationConfigureSelector(), attributes, menu, document, custom, title);
    [control setNeedsUpdateConstraints];
    [control updateConstraintsIfNeeded];
    sApolloTitlePresentationWriteDepth--;
}

static void ApolloTitlePresentationDetachCustom(UIView *source) {
    if (!source || ![source respondsToSelector:NSSelectorFromString(@"setTitleView:")]) return;
    sApolloTitlePresentationWriteDepth++;
    ((void (*)(id, SEL, id))objc_msgSend)(source, NSSelectorFromString(@"setTitleView:"), nil);
    // Tear down _UITAMICAdaptorView before transfer; otherwise it keeps writing
    // the custom view's frame after reparenting.
    [source setNeedsUpdateConstraints];
    [source updateConstraintsIfNeeded];
    sApolloTitlePresentationWriteDepth--;
}

@implementation ApolloTitlePresentationOwner

- (instancetype)initWithBar:(UINavigationBar *)bar {
    self = [super init];
    if (!self) return nil;
    _bar = bar;
    _sources = [NSMutableArray array];
    return self;
}

- (void)dealloc {
    [self resetPresentation];
}

- (void)scheduleRefresh {
    if (self.scheduled) return;
    self.scheduled = YES;
    __weak ApolloTitlePresentationOwner *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloTitlePresentationOwner *owner = weakSelf;
        if (!owner) return;
        owner.scheduled = NO;
        [owner refresh];
    });
}

- (ApolloTitlePresentationSource *)captureSource:(UIView *)view {
    if (!view || view == self.control) return nil;
    ApolloTitlePresentationSource *state = objc_getAssociatedObject(view, &kApolloTitlePresentationSourceKey);
    if (state && state.owner != self) [state.owner restoreSource:state];
    state = objc_getAssociatedObject(view, &kApolloTitlePresentationSourceKey);
    if (state) return state;
    state = [ApolloTitlePresentationSource new];
    state.view = view;
    state.owner = self;
    state.navigationItemToken = ApolloTitlePresentationItemToken(self.item);
    state.nativeAlpha = view.alpha;
    state.nativeHidden = view.hidden;
    state.nativeInteraction = view.userInteractionEnabled;
    state.nativeAccessibilityHidden = view.accessibilityElementsHidden;
    state.attributes = ApolloTitlePresentationRead(view, @"titleAttributes");
    state.menuProvider = ApolloTitlePresentationRead(view, @"titleMenuProvider");
    state.documentProperties = ApolloTitlePresentationRead(view, @"documentProperties");
    state.customView = ApolloTitlePresentationRead(view, @"titleView");
    state.attributedTitle = ApolloTitlePresentationRead(view, @"attributedTitle");
    if (!state.attributedTitle) {
        NSString *plainTitle = ApolloTitlePresentationRead(view, @"title");
        if ([plainTitle isKindOfClass:NSString.class]) {
            state.attributedTitle = [[NSAttributedString alloc] initWithString:plainTitle];
        }
    }
    objc_setAssociatedObject(view, &kApolloTitlePresentationSourceKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.sources addObject:state];
    return state;
}

- (void)restoreSource:(ApolloTitlePresentationSource *)state {
    UIView *view = state.view;
    if (!view) return;
    if (objc_getAssociatedObject(view, &kApolloTitlePresentationSourceKey) != state) return;
    objc_setAssociatedObject(view, &kApolloTitlePresentationSourceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sApolloTitlePresentationWriteDepth++;
    // Restore only titleView; preserve native metadata updates made while hidden.
    SEL setTitleView = NSSelectorFromString(@"setTitleView:");
    if ([view respondsToSelector:setTitleView] &&
        ApolloTitlePresentationRead(view, @"titleView") != state.customView) {
        ((void (*)(id, SEL, id))objc_msgSend)(view, setTitleView, state.customView);
        [view setNeedsUpdateConstraints];
        [view updateConstraintsIfNeeded];
    }
    view.alpha = state.nativeAlpha;
    view.hidden = state.nativeHidden;
    view.userInteractionEnabled = state.nativeInteraction;
    view.accessibilityElementsHidden = state.nativeAccessibilityHidden;
    sApolloTitlePresentationWriteDepth--;
}

- (void)resetPresentation {
    self.ready = NO;
    // Release our adaptor before the native control reclaims the custom view.
    ApolloTitlePresentationDetachCustom(self.control);
    [NSLayoutConstraint deactivateConstraints:self.placementConstraints];
    self.placementConstraints = nil;
    self.topConstraint = nil;
    self.heightConstraint = nil;
    [self.control removeFromSuperview];
    self.control = nil;
    if (self.customView) {
        self.customView.translatesAutoresizingMaskIntoConstraints = self.customOriginalTAMIC;
        self.customView.autoresizingMask = self.customOriginalAutoresizingMask;
        self.customView.frame = self.customOriginalFrame;
    }
    for (ApolloTitlePresentationSource *state in [self.sources copy]) [self restoreSource:state];
    [self.sources removeAllObjects];
    ApolloTitlePresentationOwnerBox *box = objc_getAssociatedObject(self.item, &kApolloTitlePresentationItemOwnerKey);
    if (box.owner == self) box.owner = nil;
    self.customView = nil;
    self.item = nil;
    self.appliedAttributes = nil;
    self.appliedMenu = nil;
    self.appliedDocument = nil;
    self.appliedTitle = nil;
    self.appliedPreferredFont = nil;
}

- (void)refresh {
    if (self.refreshing) return;
    UINavigationBar *bar = self.bar;
    UINavigationController *navigation = ApolloTitlePresentationNavigation(bar);
    UIViewController *top = navigation.topViewController;
    UINavigationItem *item = bar.topItem;
    id<UIViewControllerTransitionCoordinator> transition = top.transitionCoordinator;
    BOOL transitioning = transition.isAnimated && transition != self.completedTransition;
    if (!ApolloTitlePresentationAvailable() || !bar.window || !item ||
        !ApolloTitlePresentationIsAppNavigation(navigation) ||
        ApolloNavigationTitleContainsNativeSearchSurface(item.titleView)) {
        BOOL wasReady = self.ready;
        [self resetPresentation];
        if (wasReady) ApolloNavigationTitlesRefreshBar(bar);
        return;
    }
    if (transitioning) {
        if (self.pendingTransition != transition) {
            self.pendingTransition = transition;
            __weak ApolloTitlePresentationOwner *weakSelf = self;
            __weak id<UIViewControllerTransitionCoordinator> weakTransition = transition;
            [transition animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                ApolloTitlePresentationOwner *owner = weakSelf;
                id<UIViewControllerTransitionCoordinator> completed = weakTransition;
                if (!owner || owner.pendingTransition != completed) return;
                owner.completedTransition = completed;
                owner.pendingTransition = nil;
                [owner scheduleRefresh];
            }];
        }
    }
    // Keep the centered outgoing title until UIKit promotes the incoming item.
    if (item != top.navigationItem) return;
    if (!transitioning) self.pendingTransition = nil;
    UIView *presentationHost = ApolloTitlePresentationHost(bar);
    if (!presentationHost) {
        if (transitioning && self.ready) return;
        NSString *diagnostic = [NSString stringWithFormat:@"%@ host unavailable", NSStringFromClass(top.class)];
        if (![diagnostic isEqualToString:self.lastHostDiagnostic]) {
            self.lastHostDiagnostic = diagnostic;
            ApolloLog(@"[NavigationTitlePresentation] %@; retaining native title", diagnostic);
        }
        BOOL wasReady = self.ready;
        [self resetPresentation];
        if (wasReady) ApolloNavigationTitlesRefreshBar(bar);
        // Retry on the next layout; hosting at bar root would cover the actions.
        return;
    }
    self.refreshing = YES;
    id itemToken = ApolloTitlePresentationItemToken(item);

    BOOL itemChanged = item != self.item;
    BOOL newItem = itemChanged || item.titleView != self.customView;
    BOOL changed = newItem;
    if (newItem) {
        // A new-comments title can be replaced after loading. For the same item,
        // retain its control, placement and glass even after the push completes.
        BOOL retainOutgoing = self.item && self.control && (transitioning || !itemChanged);
        if (retainOutgoing) {
            ApolloTitlePresentationOwnerBox *oldBox = objc_getAssociatedObject(self.item,
                &kApolloTitlePresentationItemOwnerKey);
            if (oldBox.owner == self) oldBox.owner = nil;
            // Keep outgoing sources suppressed until transition copies detach;
            // reuse this centered control for the incoming configuration.
            ApolloTitlePresentationDetachCustom(self.control);
            if (self.customView) {
                self.customView.translatesAutoresizingMaskIntoConstraints = self.customOriginalTAMIC;
                self.customView.autoresizingMask = self.customOriginalAutoresizingMask;
                self.customView.frame = self.customOriginalFrame;
            }
            self.customView = nil;
            self.appliedAttributes = nil;
            self.appliedMenu = nil;
            self.appliedDocument = nil;
            self.appliedTitle = nil;
            self.appliedPreferredFont = nil;
        } else {
            [self resetPresentation];
        }
        self.item = item;
        self.customView = item.titleView;
        self.customOriginalFrame = self.customView.frame;
        self.customOriginalTAMIC = self.customView.translatesAutoresizingMaskIntoConstraints;
        self.customOriginalAutoresizingMask = self.customView.autoresizingMask;
        ApolloTitlePresentationOwnerBox *box = [ApolloTitlePresentationOwnerBox new];
        box.owner = self;
        objc_setAssociatedObject(item, &kApolloTitlePresentationItemOwnerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (ApolloTitlePresentationSource *source in [self.sources copy]) {
        if (!source.view) {
            [self.sources removeObject:source];
        } else if (!source.navigationItemToken ||
                   (!transitioning && source.navigationItemToken != itemToken)) {
            [self restoreSource:source];
            [self.sources removeObject:source];
        }
    }
    UIView *ancestor = ApolloTitlePresentationSourceAncestor(self.customView);
    if (ancestor) {
        NSUInteger count = self.sources.count;
        [self captureSource:ancestor];
        changed |= self.sources.count != count;
    }
    for (UIView *source in ApolloTitlePresentationVisibleSources(bar, item)) {
        NSUInteger count = self.sources.count;
        [self captureSource:source];
        changed |= self.sources.count != count;
    }
    ApolloTitlePresentationSource *source = nil;
    for (ApolloTitlePresentationSource *candidate in self.sources.reverseObjectEnumerator) {
        if (candidate.navigationItemToken == itemToken) { source = candidate; break; }
    }

    NSDictionary *sourceAttributes = ApolloTitlePresentationReadOrCaptured(source.view, @"titleAttributes", source.attributes);
    NSAttributedString *sourceTitle = ApolloTitlePresentationSourceTitle(source);
    NSMutableDictionary *attributes = [sourceAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
    [attributes addEntriesFromDictionary:bar.titleTextAttributes ?: @{}];
    UIFont *preferredFont = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline compatibleWithTraitCollection:bar.traitCollection];
    if (!attributes[NSFontAttributeName]) attributes[NSFontAttributeName] = preferredFont;
    if (!attributes[NSForegroundColorAttributeName]) attributes[NSForegroundColorAttributeName] = UIColor.labelColor;
    // The source control owns resolved metadata, including nil. Use the item
    // only when no source was captured.
    id menu = source ? ApolloTitlePresentationReadOrCaptured(source.view, @"titleMenuProvider", source.menuProvider)
        : ApolloTitlePresentationRead(item, @"titleMenuProvider");
    id document = source ? ApolloTitlePresentationReadOrCaptured(source.view, @"documentProperties", source.documentProperties)
        : ApolloTitlePresentationRead(item, @"documentProperties");
    NSAttributedString *title = ApolloTitlePresentationRead(item, @"attributedTitle");
    // The attributed item title wins; preserve source formatting only for matching text.
    if (!title && [sourceTitle.string isEqualToString:item.title ?: @""]) title = sourceTitle;
    if (!title) title = [[NSAttributedString alloc] initWithString:item.title ?: @""];
    if (!self.customView && title.length == 0 && !menu && !document) {
        [self resetPresentation];
        self.refreshing = NO;
        return;
    }

    BOOL configurationChanged = !self.control || !ApolloTitlePresentationEqual(attributes, self.appliedAttributes) ||
        menu != self.appliedMenu || document != self.appliedDocument ||
        !ApolloTitlePresentationEqual(title, self.appliedTitle) ||
        !ApolloTitlePresentationEqual(preferredFont, self.appliedPreferredFont);
    if (!self.control) {
        Class cls = NSClassFromString(@"_UINavigationBarTitleControl");
        UIView *control = [[cls alloc] initWithFrame:CGRectMake(0, 0, 1, 21)];
        if (!control || ![control respondsToSelector:ApolloTitlePresentationConfigureSelector()]) {
            [self resetPresentation];
            self.refreshing = NO;
            return;
        }
        objc_setAssociatedObject(control, &kApolloTitlePresentationOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        control.translatesAutoresizingMaskIntoConstraints = NO;
        self.control = control;
    }

    // Detach all native adaptors for this custom view. Setter hooks keep them
    // detached until teardown, including during offscreen updates.
    if (self.customView) {
        for (ApolloTitlePresentationSource *state in self.sources) {
            if (ApolloTitlePresentationRead(state.view, @"titleView") == self.customView) {
                ApolloTitlePresentationDetachCustom(state.view);
            }
        }
    }
    if (configurationChanged || (self.customView && ![self.customView isDescendantOfView:self.control])) {
        ApolloTitlePresentationConfigure(self.control, attributes, menu, document, self.customView, title);
        SEL setContentAlpha = NSSelectorFromString(@"setContentAlpha:");
        if ([self.control respondsToSelector:setContentAlpha]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(self.control, setContentAlpha, 1.0);
        }
        self.appliedAttributes = attributes;
        self.appliedMenu = menu;
        self.appliedDocument = document;
        self.appliedTitle = title;
        self.appliedPreferredFont = preferredFont;
        changed = YES;
    }

    CGFloat height = self.customView.intrinsicContentSize.height;
    if (!isfinite(height) || height <= 0) height = CGRectGetHeight(source.view.bounds);
    if (!isfinite(height) || height <= 0) height = CGRectGetHeight(self.customView.bounds);
    if (!isfinite(height) || height <= 0) height = ((UIFont *)attributes[NSFontAttributeName]).lineHeight;
    height = MIN(44.0, MAX(1.0, ceil(height)));
    CGRect actionsFrame = ApolloNavigationActionsCollapsedFrame(bar);
    CGFloat centerY = CGRectGetMinY(bar.bounds) + MIN(CGRectGetHeight(bar.bounds), 44.0) / 2.0;
    if (!CGRectIsNull(actionsFrame) && !CGRectIsEmpty(actionsFrame)) {
        centerY = CGRectGetMidY(actionsFrame);
    } else {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:bar];
        for (NSUInteger index = 0; index < queue.count; index++) {
            UIView *view = queue[index];
            if (view == self.control || view.hidden || view.alpha <= 0.01) continue;
            if ([NSStringFromClass(view.class) containsString:@"NavigationBarPlatterView"]) {
                CGRect rect = [view convertRect:view.bounds toView:bar];
                if (!CGRectIsEmpty(rect)) { centerY = CGRectGetMidY(rect); break; }
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }
    CGFloat topOffset = centerY - CGRectGetMinY(bar.bounds) - height / 2.0;
    if (self.control.superview != presentationHost) {
        [NSLayoutConstraint deactivateConstraints:self.placementConstraints];
        [presentationHost addSubview:self.control];
        self.topConstraint = [self.control.topAnchor constraintEqualToAnchor:bar.topAnchor constant:topOffset];
        self.heightConstraint = [self.control.heightAnchor constraintEqualToConstant:height];
        self.placementConstraints = @[
            [self.control.centerXAnchor constraintEqualToAnchor:bar.centerXAnchor],
            self.topConstraint, self.heightConstraint
        ];
        // The glass controller's priority-999 constraint owns the fitted width.
        [NSLayoutConstraint activateConstraints:self.placementConstraints];
        changed = YES;
    } else {
        if (fabs(self.topConstraint.constant - topOffset) > 0.1) {
            self.topConstraint.constant = topOffset;
            changed = YES;
        }
        if (fabs(self.heightConstraint.constant - height) > 0.1) {
            self.heightConstraint.constant = height;
            changed = YES;
        }
    }

    // Reattaching the hosted plane can deactivate bar constraints without
    // changing this control's parent. Restore missing constraints outside layout.
    for (NSLayoutConstraint *constraint in self.placementConstraints) {
        if (!constraint.active) {
            constraint.active = YES;
            changed = YES;
        }
    }

    // Moving into the window may create a deferred adaptor; update before
    // checking whether the custom view was adopted.
    [self.control updateConstraintsIfNeeded];
    BOOL customReady = !self.customView || [self.customView isDescendantOfView:self.control];
    self.ready = self.control.window == bar.window && customReady;
    if (self.ready) {
        sApolloTitlePresentationWriteDepth++;
        for (ApolloTitlePresentationSource *state in self.sources) {
            UIView *view = state.view;
            if (view.alpha != 0) view.alpha = 0;
            if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
            if (!view.accessibilityElementsHidden) view.accessibilityElementsHidden = YES;
        }
        sApolloTitlePresentationWriteDepth--;
    } else {
        [self resetPresentation];
    }
    if (self.ready && (newItem || configurationChanged)) {
        // Fit immediately so a new multiline title never shows the old JumpBar offset.
        ApolloNavigationTitleGlassRefreshContent(self.control, !itemChanged);
    }
    self.refreshing = NO;
    NSString *diagnostic = [NSString stringWithFormat:@"%@ host=%@ ready=%d sources=%lu",
        NSStringFromClass(top.class), NSStringFromClass(presentationHost.class), self.ready, (unsigned long)self.sources.count];
    if (![diagnostic isEqualToString:self.lastHostDiagnostic]) {
        self.lastHostDiagnostic = diagnostic;
        ApolloLog(@"[NavigationTitlePresentation] %@", diagnostic);
    }
    if (changed) {
        [bar setNeedsLayout];
        ApolloNavigationTitlesRefreshBar(bar);
        ApolloLogDebug(@"[NavigationTitlePresentation] %@ native title ready=%d custom=%d sources=%lu",
            NSStringFromClass(top.class), self.ready, self.customView != nil, (unsigned long)self.sources.count);
    }
}
@end

void ApolloNavigationTitlePresentationRefresh(UINavigationBar *bar) {
    if (!bar || !ApolloTitlePresentationAvailable()) return;
    ApolloTitlePresentationOwner *owner = objc_getAssociatedObject(bar, &kApolloTitlePresentationOwnerKey);
    if (!owner) {
        owner = [[ApolloTitlePresentationOwner alloc] initWithBar:bar];
        objc_setAssociatedObject(bar, &kApolloTitlePresentationOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [owner scheduleRefresh];
}

BOOL ApolloNavigationTitlePresentationOwnsControl(UIView *control) {
    return [objc_getAssociatedObject(control, &kApolloTitlePresentationOwnedKey) boolValue];
}

BOOL ApolloNavigationTitlePresentationSuppressesControl(UIView *control) {
    ApolloTitlePresentationSource *source = objc_getAssociatedObject(control, &kApolloTitlePresentationSourceKey);
    return source.owner.ready;
}

static void ApolloTitlePresentationItemChanged(UINavigationItem *item) {
    ApolloTitlePresentationOwnerBox *box = objc_getAssociatedObject(item, &kApolloTitlePresentationItemOwnerKey);
    [box.owner scheduleRefresh];
}

%group ApolloTitlePresentationHooks
%hook _UINavigationBarTitleControl
- (void)setTitleView:(UIView *)view {
    ApolloTitlePresentationSource *source = sApolloTitlePresentationWriteDepth ? nil :
        objc_getAssociatedObject(self, &kApolloTitlePresentationSourceKey);
    if (source) {
        source.customView = view;
        %orig(source.owner.ready ? nil : view);
        [source.owner scheduleRefresh];
        return;
    }
    %orig(view);
}
- (BOOL)setTitleAttributes:(NSDictionary *)attributes titleMenuProvider:(id)menu
        documentProperties:(id)document titleView:(UIView *)view attributedTitle:(NSAttributedString *)title {
    ApolloTitlePresentationSource *source = sApolloTitlePresentationWriteDepth ? nil :
        objc_getAssociatedObject(self, &kApolloTitlePresentationSourceKey);
    if (source) {
        source.attributes = attributes;
        source.menuProvider = menu;
        source.documentProperties = document;
        source.customView = view;
        source.attributedTitle = title;
        // Nested setters must not replace the captured view with our forwarded nil.
        sApolloTitlePresentationWriteDepth++;
        BOOL changed = %orig(attributes, menu, document, source.owner.ready ? nil : view, title);
        sApolloTitlePresentationWriteDepth--;
        [source.owner scheduleRefresh];
        return changed;
    }
    return %orig(attributes, menu, document, view, title);
}
- (void)setAlpha:(CGFloat)alpha {
    ApolloTitlePresentationSource *source = sApolloTitlePresentationWriteDepth ? nil :
        objc_getAssociatedObject(self, &kApolloTitlePresentationSourceKey);
    if (source) {
        source.nativeAlpha = alpha;
        %orig(source.owner.ready ? 0.0 : alpha);
        return;
    }
    %orig(alpha);
}
- (void)setHidden:(BOOL)hidden {
    ApolloTitlePresentationSource *source = sApolloTitlePresentationWriteDepth ? nil :
        objc_getAssociatedObject(self, &kApolloTitlePresentationSourceKey);
    if (source) source.nativeHidden = hidden;
    %orig(hidden);
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    ApolloTitlePresentationSource *source = sApolloTitlePresentationWriteDepth ? nil :
        objc_getAssociatedObject(self, &kApolloTitlePresentationSourceKey);
    if (source) {
        source.nativeInteraction = enabled;
        %orig(source.owner.ready ? NO : enabled);
        return;
    }
    %orig(enabled);
}
- (void)setAccessibilityElementsHidden:(BOOL)hidden {
    ApolloTitlePresentationSource *source = sApolloTitlePresentationWriteDepth ? nil :
        objc_getAssociatedObject(self, &kApolloTitlePresentationSourceKey);
    if (source) {
        source.nativeAccessibilityHidden = hidden;
        %orig(source.owner.ready ? YES : hidden);
        return;
    }
    %orig(hidden);
}
%end

%hook UINavigationItem
- (void)setTitle:(NSString *)title {
    %orig(title);
    ApolloTitlePresentationItemChanged(self);
}
- (void)setTitleView:(UIView *)view {
    %orig(view);
    ApolloTitlePresentationItemChanged(self);
}
- (void)setAttributedTitle:(NSAttributedString *)title {
    %orig(title);
    ApolloTitlePresentationItemChanged(self);
}
- (void)setTitleMenuProvider:(id)provider {
    %orig(provider);
    ApolloTitlePresentationItemChanged(self);
}
- (void)setDocumentProperties:(id)document {
    %orig(document);
    ApolloTitlePresentationItemChanged(self);
}
%end

%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    UINavigationController *navigation = self.navigationController;
    UINavigationBar *bar = navigation.navigationBar;
    if (!bar || !ApolloTitlePresentationIsAppNavigation(navigation)) return;
    ApolloNavigationTitlePresentationRefresh(bar);
    ApolloTitlePresentationOwner *owner = objc_getAssociatedObject(bar,
        &kApolloTitlePresentationOwnerKey);
    if (navigation.topViewController == self && bar.topItem == self.navigationItem) [owner refresh];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    UINavigationBar *bar = self.navigationController.navigationBar;
    ApolloTitlePresentationOwner *owner = objc_getAssociatedObject(bar, &kApolloTitlePresentationOwnerKey);
    if (self.navigationController.topViewController == self) {
        owner.completedTransition = self.transitionCoordinator;
        owner.pendingTransition = nil;
        ApolloNavigationTitlePresentationRefresh(bar);
    }
}
%end

%hook UINavigationBar
- (void)didMoveToWindow {
    %orig;
    ApolloTitlePresentationOwner *owner = objc_getAssociatedObject(self, &kApolloTitlePresentationOwnerKey);
    if (!self.window) [owner resetPresentation];
    else ApolloNavigationTitlePresentationRefresh(self);
}
- (void)setTitleTextAttributes:(NSDictionary *)attributes {
    %orig(attributes);
    ApolloNavigationTitlePresentationRefresh(self);
}
%end
%end

%ctor {
    Class cls = NSClassFromString(@"_UINavigationBarTitleControl");
    if (ApolloTitlePresentationAvailable() && [cls instancesRespondToSelector:ApolloTitlePresentationConfigureSelector()]) {
        %init(ApolloTitlePresentationHooks);
        ApolloLog(@"[NavigationTitlePresentation] Native title ownership hooks installed");
    }
}
