// ApolloPaneRouter.xm
//
// Decides which column a pushed view controller belongs in, and redirects it
// there. This is the only file that changes where navigation lands.
//
// ALLOWLIST, NEVER BLOCKLIST. Only classes named in kPaneRoutes are moved;
// everything else pushes in place, exactly as it does today. Apollo ships ~90
// view controllers and the tweak adds its own, so an allowlist is the only
// default that cannot silently break a screen nobody thought about.
//
// WHY HOOK THE OBJC SHIM. `-[ApolloNavigationController pushViewController:
// animated:]` is a thin Objective-C shim over one Swift body (sub_10015c720,
// recovered with Hopper). Logos hooks the shim, so returning early means
// Apollo's Swift body never runs on the wrong navigation controller. That body
// also **silently drops a push when the controller is already in the stack** —
// which is why a reroute must never leave the controller in the source stack,
// and why we re-home it with setViewControllers: rather than splicing arrays.
//
// Full design + RE notes: docs/ipad-pane-layout-plan.md

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "ApolloPaneForwardHistory.h"
#import "ApolloPaneLayout.h"
#import "ApolloPaneRouting.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloCommon.h"
#import "../ApolloDirectChatWeb.h"

extern "C" {
void *ApolloSwiftListAdapterModelIdentifier(
    const void *objectsStorage, NSInteger section, NSInteger row);
void *ApolloSwiftListAdapterIndexPathForModelIdentifier(
    const void *mappingStorage, const void *tokenObject);
}

// Bound to Apollo's Swift navigation-controller class in %ctor. Hooking
// UINavigationController itself misses callers that enter through Apollo's
// override (including Reborn settings deep links); the override's ObjC shim is
// the single production push entry point recovered in the design RE.
@interface ApolloPaneNavigationController : UINavigationController
@end

@interface ApolloPanePostsViewController : UIViewController
@end

@interface ApolloPaneSettingsViewController : UIViewController
@end

@interface ApolloPaneInboxListViewController : UIViewController
@end

@interface ApolloPaneListAdapter : NSObject
@end

@interface ApolloPaneTableNode : NSObject
@end

// Re-entrancy guard: our own re-homing must never be re-classified. Main thread
// only, like every UIKit navigation call this hook sits on.
static BOOL sPaneRouterReentrant = NO;
static NSUInteger sPaneRouterPopHookDepth = 0;
static __weak UINavigationController *sPaneRouterDeferredCompactNavigationController = nil;
static __weak UIViewController *sPaneRouterDeferredCompactViewController = nil;
static id sPaneRouterPendingMasterSelectionIntent = nil;
static __weak UIViewController *sPaneRouterPendingMasterSelectionSource = nil;
static id sPaneRouterReplayedMasterSelectionIntent = nil;

static const void *ApolloPaneMasterSelectionAXMarkerKey(void) {
    return NSSelectorFromString(@"apollo_masterSelectionAddedAXSelectedTrait");
}

static void *ApolloPaneSwiftWeakSlot(id object, const char *name) {
    if (!object || !name) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NULL;
    return (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
}

static id ApolloPaneLoadSwiftWeak(id object, const char *name) {
    typedef void *(*LoadStrongFunction)(void *slot);
    static LoadStrongFunction loadStrong;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loadStrong = (LoadStrongFunction)dlsym(
            RTLD_DEFAULT, "swift_unknownObjectWeakLoadStrong");
    });
    void *slot = ApolloPaneSwiftWeakSlot(object, name);
    void *value = slot && loadStrong ? loadStrong(slot) : NULL;
    return value ? CFBridgingRelease(value) : nil;
}

static const void *ApolloPaneSwiftIvarStorage(id object, const char *name) {
    if (!object || !name) return NULL;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return NULL;
    ptrdiff_t offset = ivar_getOffset(ivar);
    size_t instanceSize = class_getInstanceSize(object_getClass(object));
    if (offset <= 0 || (size_t)offset + sizeof(void *) > instanceSize) return NULL;
    return (const uint8_t *)(__bridge const void *)object + offset;
}

static id ApolloPaneListAdapterModelIdentifier(id adapter, NSIndexPath *indexPath) {
    if (!NSThread.isMainThread || !indexPath) return nil;
    const void *objectsStorage = ApolloPaneSwiftIvarStorage(adapter, "objects");
    void *identifier = objectsStorage
        ? ApolloSwiftListAdapterModelIdentifier(
            objectsStorage, indexPath.section, indexPath.row)
        : NULL;
    return identifier ? CFBridgingRelease(identifier) : nil;
}

static NSIndexPath *ApolloPaneListAdapterIndexPath(id adapter, id identifier) {
    if (!NSThread.isMainThread || !identifier) return nil;
    const void *mappingStorage = ApolloPaneSwiftIvarStorage(
        adapter, "objectToIndexPathMapping");
    void *path = mappingStorage
        ? ApolloSwiftListAdapterIndexPathForModelIdentifier(
            mappingStorage, (__bridge const void *)identifier)
        : NULL;
    return path ? CFBridgingRelease(path) : nil;
}

static UIViewController *ApolloPaneOwningViewControllerForSurface(id surface) {
    id view = surface;
    if (![view isKindOfClass:[UIView class]] && [surface respondsToSelector:@selector(view)]) {
        view = ((id (*)(id, SEL))objc_msgSend)(surface, @selector(view));
    }
    UIResponder *responder = [view isKindOfClass:[UIResponder class]] ? view : nil;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static id ApolloPaneStableIdentifierForSelectedNode(id tableNode, NSIndexPath *indexPath) {
    SEL nodeSelector = NSSelectorFromString(@"nodeForRowAtIndexPath:");
    if (!tableNode || !indexPath || ![tableNode respondsToSelector:nodeSelector]) return nil;
    id node = ((id (*)(id, SEL, id))objc_msgSend)(tableNode, nodeSelector, indexPath);
    if (!node) return nil;
    id model = nil;
    static const char *modelIvarNames[] = { "link", "message" };
    for (size_t index = 0; index < sizeof(modelIvarNames) / sizeof(modelIvarNames[0]); index++) {
        const char *name = modelIvarNames[index];
        @try {
            Ivar ivar = class_getInstanceVariable(object_getClass(node), name);
            if (ivar) model = object_getIvar(node, ivar);
        } @catch (__unused NSException *exception) {}
        if (model) break;
    }
    if (!model) return nil;
    for (NSString *selectorName in @[ @"fullName", @"identifier", @"diffIdentifier" ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![model respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
        if ([value conformsToProtocol:@protocol(NSCopying)]) return value;
    }
    return nil;
}

static void ApolloPaneObservePrimaryPopSettlement(
        ApolloPaneSplitViewController *pane,
        UINavigationController *navigationController,
        NSArray<UIViewController *> *beforeStack,
        NSUInteger token);

static void ApolloPanePollPrimaryPopSettlement(
        ApolloPaneSplitViewController *pane,
        UINavigationController *navigationController,
        NSArray<UIViewController *> *beforeStack,
        NSUInteger token,
        NSUInteger observations) {
    if (!pane || !navigationController || token == 0) return;
    if (navigationController.transitionCoordinator) {
        NSTimeInterval delay = observations < 120 ? 0.05 : 0.25;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ApolloPanePollPrimaryPopSettlement(pane, navigationController, beforeStack,
                                                token, observations + 1);
        });
        return;
    }
    [pane apollo_primaryNavigationPopDidSettle:token
                                   beforeStack:beforeStack
                                      cancelled:NO];
}

static void ApolloPaneObservePrimaryPopSettlement(
        ApolloPaneSplitViewController *pane,
        UINavigationController *navigationController,
        NSArray<UIViewController *> *beforeStack,
        NSUInteger token) {
    if (!pane || !navigationController || beforeStack.count == 0 || token == 0) return;
    void (^settle)(BOOL) = ^(BOOL cancelled) {
        [pane apollo_primaryNavigationPopDidSettle:token
                                       beforeStack:beforeStack
                                          cancelled:cancelled];
    };
    id<UIViewControllerTransitionCoordinator> coordinator =
        navigationController.transitionCoordinator;
    if (coordinator) {
        BOOL observing = [coordinator animateAlongsideTransition:nil
            completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                BOOL cancelled = context.isCancelled;
                dispatch_async(dispatch_get_main_queue(), ^{ settle(cancelled); });
            }];
        // Poll in parallel even after accepted registration. It is both the
        // rejected-registration fallback and a watchdog for a coordinator that
        // never invokes its completion; the pane token makes duplicate terminal
        // observations harmless.
        ApolloPanePollPrimaryPopSettlement(pane, navigationController, beforeStack,
                                            token, observing ? 1 : 0);
    } else {
        settle(NO);
    }
}

// Re-enter Apollo's real push override after a queued compact route settles,
// while bypassing serialization for exactly that navigation/destination pair.
// A broad boolean also bypassed synchronous lifecycle pushes triggered by the
// destination; those are new semantic intents and must remain serialized.
static void ApolloPaneReplayCompactPush(UINavigationController *navigationController,
                                        UIViewController *viewController,
                                        BOOL animated,
                                        id masterSelectionIntent) {
    sPaneRouterDeferredCompactNavigationController = navigationController;
    sPaneRouterDeferredCompactViewController = viewController;
    sPaneRouterReplayedMasterSelectionIntent = masterSelectionIntent;
    @try {
        [navigationController pushViewController:viewController animated:animated];
    } @finally {
        sPaneRouterDeferredCompactNavigationController = nil;
        sPaneRouterDeferredCompactViewController = nil;
        sPaneRouterReplayedMasterSelectionIntent = nil;
    }
}

// Most pushed controllers already express their correct leading-item policy.
// The one proven exception is ProfileViewController: Apollo designed it as a
// tab root, so when it is appended above a thread its own leading items suppress
// UIKit's only escape route. Keep that repair explicit and shared by regular and
// compact navigation; rightward ownership alone never authorizes a mutation.
static void ApolloPaneApplyPostPushNavigationPolicy(UINavigationController *navigationController,
                                                    UIViewController *viewController,
                                                    ApolloPaneColumn logicalColumn) {
    if (logicalColumn != ApolloPaneColumnSecondary ||
        !ApolloPaneDestinationRequiresSupplementalBack(viewController) ||
        navigationController.topViewController != viewController ||
        navigationController.viewControllers.count <= 1) return;

    viewController.navigationItem.hidesBackButton = NO;
    viewController.navigationItem.leftItemsSupplementBackButton = YES;
    ApolloLog(@"[PaneRouter] supplemented Back for appended %@",
              NSStringFromClass(viewController.class));
}

// Commit a semantic primary -> detail replacement without ever falling back to
// an in-place push. This is shared by immediate routes and deferred routes that
// settle after a populated pane has collapsed onto its detail branch.
static BOOL ApolloPaneReplaceDetailRoot(ApolloPaneSplitViewController *pane,
                                        UIViewController *viewController,
                                        UIViewController *sourceViewController,
                                        id masterSelectionIntent) {
    UINavigationController *destination =
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
    if (!destination || !viewController) return NO;

    viewController.extendedLayoutIncludesOpaqueBars = YES;
    NSArray<UIViewController *> *oldDestinationStack = destination.viewControllers;
    __block BOOL replacementSucceeded = NO;
    [pane apollo_performCrossColumnNavigationTransaction:^{
        sPaneRouterReentrant = YES;
        @try {
            [destination setViewControllers:@[ viewController ] animated:NO];
            replacementSucceeded = destination.topViewController == viewController;
            if (!replacementSucceeded) {
                ApolloLog(@"[PaneRouter] re-homing %@ failed postcondition; restoring destination",
                          NSStringFromClass(viewController.class));
                [destination setViewControllers:oldDestinationStack animated:NO];
            }
        } @catch (NSException *exception) {
            ApolloLog(@"[PaneRouter] re-homing %@ threw: %@; restoring destination",
                      NSStringFromClass(viewController.class), exception);
            @try {
                [destination setViewControllers:oldDestinationStack animated:NO];
            } @catch (NSException *rollbackException) {
                ApolloLog(@"[PaneRouter] destination rollback also threw: %@", rollbackException);
            }
        } @finally {
            sPaneRouterReentrant = NO;
        }
    }];
    if (!replacementSucceeded) return NO;

    // Readable-width settings/forms must have their final safe-area insets
    // before the first detail frame is committed. The ordinary pane geometry
    // refresh is intentionally deferred and otherwise produces a visible
    // full-width -> centered-width snap.
    [pane apollo_prepareDetailControllerForDisplay:viewController];
    ApolloPaneClearForwardHistory(destination);
    [pane apollo_recordDetailBranchFromPrimarySource:sourceViewController];
    [pane apollo_commitMasterSelectionIntent:masterSelectionIntent
                                  detailRoot:viewController];
    [pane apollo_refreshCompactDetailChromeAfterRootReplacement];
    [pane apollo_resolvedDisplayStateMayHaveChanged];
    [pane apollo_revealDetailAfterPrimarySelectionIfNeeded];
    ApolloLog(@"[PaneRouter] routed %@ to detail (tab %ld compact=%d)",
              NSStringFromClass(viewController.class), (long)pane.apollo_tabIndex,
              pane.isCollapsed);
    return YES;
}

static ApolloPaneSplitViewController *ApolloPaneForPrimaryController(UIViewController *controller) {
    UINavigationController *navigationController = controller.navigationController;
    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController ?: controller);
    if (![pane isKindOfClass:[ApolloPaneSplitViewController class]]) return nil;
    return navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary] ? pane : nil;
}

static ApolloPaneSplitViewController *ApolloPaneForMasterSelectionSurface(id surface) {
    UIViewController *owner = ApolloPaneOwningViewControllerForSurface(surface);
    return ApolloPaneForPrimaryController(owner);
}

static void ApolloPaneSchedulePostsScopeReconciliation(UIViewController *posts,
                                                        NSString *reason) {
    __weak UIViewController *weakPosts = posts;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongPosts = weakPosts;
        ApolloPaneSplitViewController *pane = ApolloPaneForPrimaryController(strongPosts);
        [pane apollo_scheduleDetailReconciliationAfterPrimaryMutation:reason];
    });
}

static void ApolloPaneCollectLivePanes(UIViewController *controller,
                                       NSHashTable<ApolloPaneSplitViewController *> *panes) {
    if (!controller || [panes containsObject:(id)controller]) return;
    if ([controller isKindOfClass:[ApolloPaneSplitViewController class]]) {
        [panes addObject:(ApolloPaneSplitViewController *)controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        ApolloPaneCollectLivePanes(child, panes);
    }
    ApolloPaneCollectLivePanes(controller.presentedViewController, panes);
}

static NSArray<ApolloPaneSplitViewController *> *ApolloPaneAllLivePanes(void) {
    NSHashTable<ApolloPaneSplitViewController *> *panes = [NSHashTable weakObjectsHashTable];
    for (UIWindow *window in ApolloAllWindows()) {
        ApolloPaneCollectLivePanes(window.rootViewController, panes);
    }
    return panes.allObjects;
}

static ApolloPaneSplitViewController *ApolloPaneForPrimaryNavigationItem(UINavigationItem *item) {
    for (ApolloPaneSplitViewController *pane in ApolloPaneAllLivePanes()) {
        UINavigationController *primary =
            [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
        for (UIViewController *controller in primary.viewControllers) {
            if (controller.navigationItem == item) return pane;
        }
    }
    return nil;
}

%group ApolloPaneRouterGroup

%hook ApolloPaneSettingsViewController

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIViewController *source = (UIViewController *)self;
    ApolloPaneSplitViewController *pane = ApolloPaneLayoutActive()
        ? ApolloPaneForPrimaryController(source) : nil;
    id intent = [pane apollo_masterSelectionIntentFromSource:source
                                                     surface:tableView
                                                   indexPath:indexPath
                                              itemIdentifier:nil
                                               identityOwner:nil];
    [pane apollo_stageMasterSelectionIntent:intent];
    id previousIntent = sPaneRouterPendingMasterSelectionIntent;
    UIViewController *previousSource = sPaneRouterPendingMasterSelectionSource;
    sPaneRouterPendingMasterSelectionIntent = intent;
    sPaneRouterPendingMasterSelectionSource = intent ? source : nil;
    @try {
        %orig;
    } @finally {
        sPaneRouterPendingMasterSelectionIntent = previousIntent;
        sPaneRouterPendingMasterSelectionSource = previousSource;
    }
}

%end

%hook ApolloPaneInboxListViewController

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIViewController *source = (UIViewController *)self;
    ApolloPaneSplitViewController *pane = ApolloPaneLayoutActive()
        ? ApolloPaneForPrimaryController(source) : nil;
    id intent = [pane apollo_masterSelectionIntentFromSource:source
                                                     surface:tableView
                                                   indexPath:indexPath
                                              itemIdentifier:nil
                                               identityOwner:nil];
    [pane apollo_stageMasterSelectionIntent:intent];
    id previousIntent = sPaneRouterPendingMasterSelectionIntent;
    UIViewController *previousSource = sPaneRouterPendingMasterSelectionSource;
    sPaneRouterPendingMasterSelectionIntent = intent;
    sPaneRouterPendingMasterSelectionSource = intent ? source : nil;
    @try {
        %orig;
    } @finally {
        sPaneRouterPendingMasterSelectionIntent = previousIntent;
        sPaneRouterPendingMasterSelectionSource = previousSource;
    }
}

%end

%hook ApolloPaneListAdapter

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIViewController *source = ApolloPaneLoadSwiftWeak((id)self, "viewController") ?:
        ApolloPaneOwningViewControllerForSurface(tableView);
    ApolloPaneSplitViewController *pane = ApolloPaneLayoutActive()
        ? ApolloPaneForPrimaryController(source) : nil;
    id itemIdentifier = pane
        ? ApolloPaneListAdapterModelIdentifier((id)self, indexPath) : nil;
    id identityOwner = itemIdentifier ? (id)self : nil;
    id tableNode = ApolloPaneLoadSwiftWeak((id)self, "tableNode");
    id surface = tableNode ?: tableView;
    if (!itemIdentifier && pane) {
        itemIdentifier = ApolloPaneStableIdentifierForSelectedNode(surface, indexPath);
    }
    id intent = [pane apollo_masterSelectionIntentFromSource:source
                                                     surface:surface
                                                   indexPath:indexPath
                                              itemIdentifier:itemIdentifier
                                               identityOwner:identityOwner];
    [pane apollo_stageMasterSelectionIntent:intent];
    id previousIntent = sPaneRouterPendingMasterSelectionIntent;
    UIViewController *previousSource = sPaneRouterPendingMasterSelectionSource;
    sPaneRouterPendingMasterSelectionIntent = intent;
    sPaneRouterPendingMasterSelectionSource = intent ? source : nil;
    @try {
        %orig;
    } @finally {
        sPaneRouterPendingMasterSelectionIntent = previousIntent;
        sPaneRouterPendingMasterSelectionSource = previousSource;
    }
}

- (void)tableNode:(id)tableNode didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    UIViewController *source = ApolloPaneLoadSwiftWeak((id)self, "viewController") ?:
        ApolloPaneOwningViewControllerForSurface(tableNode);
    ApolloPaneSplitViewController *pane = ApolloPaneLayoutActive()
        ? ApolloPaneForPrimaryController(source) : nil;
    id itemIdentifier = pane
        ? ApolloPaneListAdapterModelIdentifier((id)self, indexPath) : nil;
    id identityOwner = itemIdentifier ? (id)self : nil;
    if (!itemIdentifier && pane) {
        itemIdentifier = ApolloPaneStableIdentifierForSelectedNode(tableNode, indexPath);
    }
    id intent = [pane apollo_masterSelectionIntentFromSource:source
                                                     surface:tableNode
                                                   indexPath:indexPath
                                              itemIdentifier:itemIdentifier
                                               identityOwner:identityOwner];
    [pane apollo_stageMasterSelectionIntent:intent];
    id previousIntent = sPaneRouterPendingMasterSelectionIntent;
    UIViewController *previousSource = sPaneRouterPendingMasterSelectionSource;
    sPaneRouterPendingMasterSelectionIntent = intent;
    sPaneRouterPendingMasterSelectionSource = intent ? source : nil;
    @try {
        %orig;
    } @finally {
        sPaneRouterPendingMasterSelectionIntent = previousIntent;
        sPaneRouterPendingMasterSelectionSource = previousSource;
    }
}

- (id)modelIdentifierForElementAtIndexPath:(NSIndexPath *)indexPath inNode:(id)node {
    return ApolloPaneListAdapterModelIdentifier((id)self, indexPath);
}

- (NSIndexPath *)indexPathForElementWithModelIdentifier:(id)identifier inNode:(id)node {
    return ApolloPaneListAdapterIndexPath((id)self, identifier);
}

%end

// Apollo's delayed phone-navigation deselection must not erase a selection
// after the pane has committed that row as the owner of its visible detail.
// The checks are identity-exact and allocation-free before pane mode is active.
%hook UITableView

- (void)reloadData {
    %orig;
    if (!ApolloPaneLayoutActive()) return;
    ApolloPaneSplitViewController *pane = ApolloPaneForMasterSelectionSurface(self);
    if (!pane) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [pane apollo_refreshMasterSelection];
    });
}

- (void)deselectRowAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated {
    if (ApolloPaneLayoutActive()) {
        ApolloPaneSplitViewController *pane = ApolloPaneForMasterSelectionSurface(self);
        if ([pane apollo_shouldRetainMasterSelectionForSurface:self indexPath:indexPath]) return;
    }
    %orig;
}

%end

%hook ApolloPaneTableNode

- (void)deselectRowAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated {
    if (ApolloPaneLayoutActive()) {
        ApolloPaneSplitViewController *pane = ApolloPaneForMasterSelectionSurface(self);
        if ([pane apollo_shouldRetainMasterSelectionForSurface:self indexPath:indexPath]) return;
    }
    %orig;
}

%end

%hook UITableViewCell

- (void)prepareForReuse {
    const void *key = ApolloPaneMasterSelectionAXMarkerKey();
    if ([objc_getAssociatedObject(self, key) boolValue]) {
        self.accessibilityTraits &= ~UIAccessibilityTraitSelected;
        objc_setAssociatedObject(self, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}

%end

%hook ApolloPaneNavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!ApolloPaneLayoutActive()) { %orig; return; }

    // Logos types `self` as id for a runtime-bound class alias.
    UINavigationController *navigationController = (UINavigationController *)self;

    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController);

    if (!pane) {
        ApolloLog(@"[PaneRouter] no pane for navigation parent=%@ split=%@",
                  NSStringFromClass(navigationController.parentViewController.class),
                  NSStringFromClass(navigationController.splitViewController.class));
        %orig;
        return;
    }

    // During collapse UIKit appends this pane's exact secondary navigation
    // controller to the surviving primary stack as structural bridge state.
    // It is not an app destination and must pass through untouched; treating it
    // as a Settings detail route recursively installs the nav inside itself.
    if (viewController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
        %orig;
        return;
    }

    // Native Modmail has an independent superclass hook that substitutes the
    // authenticated modern mailbox. A cross-column re-home intentionally does
    // not call %orig, so normalize here as well; otherwise hook ordering could
    // decide whether modern Modmail is honored. Re-pushing the replacement
    // re-enters this router as an ordinary, explicitly classified destination.
    Class nativeModmailClass = objc_getClass("_TtC6Apollo26ModmailInboxViewController");
    if (nativeModmailClass &&
        [viewController isMemberOfClass:nativeModmailClass] &&
        ApolloModernModmailShouldOpen()) {
        ApolloLog(@"[PaneRouter] normalizing native Modmail to modern mailbox before routing");
        [navigationController pushViewController:ApolloCreateModernModmailViewController()
                                         animated:animated];
        return;
    }

    // CONTENT ONLY EVER MOVES RIGHTWARD.
    //
    // Cross-column routing applies only to pushes that START in the list column.
    // Anything pushed from the detail column stays there and behaves like a
    // normal navigation stack: push, back button, pop.
    //
    // Without this the layout teleports content leftward and destroys your place.
    // Tapping a subreddit link inside a comment thread pushed a
    // PostsViewController, the table sent it to the LIST column, and re-homing
    // there means setViewControllers: — which replaces the whole left stack. The
    // Home tab's [subreddit list, feed] became [new feed], so the subreddit list,
    // the feed you were reading and every back button went with it. That is why
    // there was no way back to the home feed, and why the direction felt wrong:
    // you tapped something on the right and watched the left half of the app get
    // replaced.
    //
    // The detail column is now the browsing stack — the thing you tapped opens
    // where you were looking, and back always returns — while the list column
    // stays the stable context you navigated from.
    BOOL fromListColumn =
        (navigationController == [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]);
    UIViewController *sourceViewController = navigationController.topViewController;
    id routeMasterSelectionIntent = sPaneRouterReplayedMasterSelectionIntent;
    if (!routeMasterSelectionIntent &&
        sPaneRouterPendingMasterSelectionSource == sourceViewController) {
        routeMasterSelectionIntent = sPaneRouterPendingMasterSelectionIntent;
    }
    if (fromListColumn) {
        id stagedIntent =
            [pane apollo_claimStagedMasterSelectionIntentForSource:sourceViewController];
        if (!routeMasterSelectionIntent) routeMasterSelectionIntent = stagedIntent;
    }

    BOOL explicitlyClassified = NO;
    ApolloPaneColumn sourceColumn = fromListColumn
        ? ApolloPaneColumnPrimary : ApolloPaneColumnSecondary;
    ApolloPaneColumn column = ApolloPaneResolveLogicalColumn(navigationController.topViewController,
                                                              viewController,
                                                              sourceColumn,
                                                              &explicitlyClassified);

    if (pane.isCollapsed) {
        // There is only one physical stack while compact, but that does not
        // erase column ownership. A detail route opened from the visible list
        // must stay on this stack for now and move to the real detail column
        // when the split expands. Once a compact route is logically detail,
        // everything it pushes inherits detail ownership (rightward-only),
        // regardless of the destination class table.
        BOOL sourceBelongsToDetail =
            [pane apollo_compactViewControllerBelongsToDetail:navigationController.topViewController] ||
            navigationController == [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
        if (sourceBelongsToDetail) {
            column = ApolloPaneColumnSecondary;
        }

        // A regular-width replacement can still be waiting when the window
        // collapses. Compact navigation must participate in the same latest-
        // intent queue or an older regular request could replay over a newer
        // compact selection after the transition settles. Detail continuations
        // capture the stable primary context rather than becoming unconditional
        // source-less work that could outlive a feed/account change.
        __weak UINavigationController *weakCompactNavigationController = navigationController;
        __weak ApolloPaneSplitViewController *weakCompactPane = pane;
        __weak UIViewController *weakCompactSourceViewController = sourceViewController;
        UIViewController *deferredCompactViewController = viewController;
        BOOL deferredCompactAnimated = animated;
        BOOL deferredSourceBelongsToDetail = sourceBelongsToDetail;
        NSString *compactReason = [NSString stringWithFormat:@"compact route %@",
            NSStringFromClass(viewController.class)];
        BOOL applyingThisDeferredPush =
            sPaneRouterDeferredCompactNavigationController == navigationController &&
            sPaneRouterDeferredCompactViewController == viewController;
        // During compact Back/showColumn UIKit can temporarily expose only the
        // index root while the pane is about to restore [index, feed]. Bind a
        // new selection to that anticipated stable context, not the transient
        // physical top, or reconciliation can erase the newer route.
        UIViewController *compactValidationSource =
            pane.apollo_primaryContextViewController ?: sourceViewController;
        if (!applyingThisDeferredPush &&
            [pane apollo_deferCrossColumnNavigationIfNeeded:^{
                UINavigationController *strongNavigationController =
                    weakCompactNavigationController;
                ApolloPaneSplitViewController *strongPane = weakCompactPane;
                if (!strongNavigationController || !strongPane ||
                    ApolloPaneSplitControllerFor(strongNavigationController) != strongPane) {
                    ApolloLog(@"[PaneTransition] dropped deferred compact %@ after pane/source detached",
                              NSStringFromClass(deferredCompactViewController.class));
                    return;
                }
                UINavigationController *resolvedNavigationController = strongNavigationController;
                if (deferredSourceBelongsToDetail) {
                    UIViewController *strongSourceViewController = weakCompactSourceViewController;
                    UINavigationController *resolvedPrimary =
                        [strongPane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
                    UINavigationController *resolvedDetail =
                        [strongPane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary];
                    if (strongSourceViewController &&
                        [resolvedDetail.viewControllers containsObject:strongSourceViewController]) {
                        resolvedNavigationController = resolvedDetail;
                    } else if (strongSourceViewController &&
                               [resolvedPrimary.viewControllers containsObject:strongSourceViewController]) {
                        resolvedNavigationController = resolvedPrimary;
                    } else {
                        ApolloLog(@"[PaneTransition] dropped deferred compact detail continuation after source moved away");
                        return;
                    }
                    if (resolvedNavigationController.topViewController != strongSourceViewController) {
                        ApolloLog(@"[PaneTransition] dropped deferred compact detail continuation after source was popped");
                        return;
                    }
                }
                ApolloPaneReplayCompactPush(resolvedNavigationController,
                                            deferredCompactViewController,
                                            deferredCompactAnimated,
                                            routeMasterSelectionIntent);
            }
                                  sourceViewController:compactValidationSource
                                                reason:compactReason]) {
            return;
        }

        UIViewController *beforeTop = navigationController.topViewController;
        NSUInteger beforeDepth = navigationController.viewControllers.count;
        %orig;
        BOOL pushSucceeded = navigationController.topViewController == viewController &&
            (beforeTop != viewController || navigationController.viewControllers.count != beforeDepth);
        if (pushSucceeded) {
            [pane apollo_recordCompactViewController:viewController logicalColumn:column];
        }
        if (column == ApolloPaneColumnSecondary && !sourceBelongsToDetail && pushSucceeded) {
            [pane apollo_recordDetailBranchFromPrimarySource:sourceViewController];
            [pane apollo_commitMasterSelectionIntent:routeMasterSelectionIntent
                                          detailRoot:viewController];
        } else if (column == ApolloPaneColumnPrimary && pushSucceeded) {
            [pane apollo_primaryNavigationPushDidMutateExternally:
                navigationController.viewControllers];
            [pane apollo_reconcileDetailAfterPrimaryMutation:@"compact primary push"];
        }
        if (pushSucceeded) {
            ApolloPaneApplyPostPushNavigationPolicy(navigationController, viewController, column);
            if (navigationController ==
                [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
                [pane apollo_prepareDetailControllerForDisplay:viewController];
            }
        }
        ApolloLog(@"[PaneRouter] compact push %@ logicalColumn=%ld sourceDetail=%d succeeded=%d tab=%ld",
                  NSStringFromClass(viewController.class), (long)column, sourceBelongsToDetail,
                  pushSucceeded, (long)pane.apollo_tabIndex);
        return;
    }

    if (!explicitlyClassified) {
        UIViewController *beforeTop = navigationController.topViewController;
        NSUInteger beforeDepth = navigationController.viewControllers.count;
        %orig;
        if (fromListColumn && navigationController.topViewController == viewController &&
            (beforeTop != viewController ||
             navigationController.viewControllers.count != beforeDepth)) {
            [pane apollo_primaryNavigationPushDidMutateExternally:
                navigationController.viewControllers];
        }
        // Guarantee a way back out of the one known tab-root destination that
        // suppresses it, without rewriting arbitrary controllers merely because
        // they inherited rightward ownership from their source.
        //
        // Some Apollo screens are designed to be a TAB ROOT and supply their own
        // leading bar items, so when one is pushed they render no back button at
        // all. On iPhone that never happens — you reach them by selecting a tab,
        // never by pushing. In the detail column it does: tapping your own
        // username inside a comment thread pushes ProfileViewController onto the
        // thread, and the result is a screen with the thread still underneath it
        // and no affordance to return. That is the "stuck in a second profile"
        // report, and it is not a routing problem — the push lands in exactly
        // the right column.
        //
        // leftItemsSupplementBackButton keeps the screen's own items (the
        // profile's hide/history buttons) rather than replacing them.
        // Unknown composers, login screens, settings descendants and modal-like
        // screens keep their exact native leading-item policy.
        ApolloPaneApplyPostPushNavigationPolicy(navigationController, viewController, column);
        if (navigationController ==
            [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
            [pane apollo_prepareDetailControllerForDisplay:viewController];
        }
        return;
    }

    UINavigationController *destination = [pane apollo_navigationControllerForColumn:column];

    // Already in the right column. A feed arriving here means the user moved to
    // different content, so the stale thread beside it goes.
    if (!destination || destination == navigationController) {
        UIViewController *beforeTop = navigationController.topViewController;
        %orig;
        if (column == ApolloPaneColumnSecondary &&
            navigationController.topViewController == viewController) {
            [pane apollo_prepareDetailControllerForDisplay:viewController];
        }
        // Apollo rejects duplicate pushes. Reconcile after the call so a no-op
        // intent cannot erase detail whose primary context never changed.
        if (column != ApolloPaneColumnSecondary &&
            navigationController.topViewController != beforeTop) {
            [pane apollo_primaryNavigationPushDidMutateExternally:
                navigationController.viewControllers];
            [pane apollo_reconcileDetailAfterPrimaryMutation:@"primary push"];
        }
        return;
    }

    // A detail pop/push may still own UIKit's transition context even though
    // the primary row tap has already delivered a new destination. Replacing
    // the detail stack in that interval produces nested-transition warnings and
    // can strand Apollo's custom edge gesture. Keep only the newest semantic
    // intent, then re-enter this same router after commit/cancellation so source
    // ownership and compact/regular topology are resolved from final state.
    __weak UINavigationController *weakSourceNavigationController = navigationController;
    __weak ApolloPaneSplitViewController *weakPane = pane;
    __weak UIViewController *weakSourceViewController = sourceViewController;
    UIViewController *deferredViewController = viewController;
    BOOL deferredAnimated = animated;
    NSString *deferredReason = [NSString stringWithFormat:@"route %@",
        NSStringFromClass(viewController.class)];
    if ([pane apollo_deferCrossColumnNavigationIfNeeded:^{
            ApolloPaneSplitViewController *strongPane = weakPane;
            UINavigationController *strongSourceNavigationController =
                weakSourceNavigationController;
            if (!strongPane || !strongSourceNavigationController ||
                ApolloPaneSplitControllerFor(strongSourceNavigationController) != strongPane) {
                ApolloLog(@"[PaneTransition] dropped deferred %@ after pane/source detached",
                          NSStringFromClass(deferredViewController.class));
                return;
            }
            if (!strongPane.isCollapsed || !strongPane.apollo_detailIsEmpty) {
                ApolloPaneReplaceDetailRoot(strongPane, deferredViewController,
                                           weakSourceViewController,
                                           routeMasterSelectionIntent);
            } else {
                UINavigationController *resolvedPrimary =
                    [strongPane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary];
                ApolloPaneReplayCompactPush(resolvedPrimary, deferredViewController,
                                            deferredAnimated,
                                            routeMasterSelectionIntent);
            }
        }
                              sourceViewController:sourceViewController
                                            reason:deferredReason]) {
        return;
    }

    // Cross-column. Re-home rather than push: this REPLACES the destination
    // stack, so opening a second post swaps the thread instead of burying the
    // first one under a back button, and the placeholder disappears with it.
    //
    // setViewControllers: is plain UIKit — Apollo overrides pushViewController:
    // and the pop family, but not this — so the one thing Apollo's push body
    // would have done that still matters here is applied by hand below.
    // The rest of that body (its duplicate guard, the interactive-transition
    // `pushing` flag, the hidden-nav-bar re-show timer loop) is specific to an
    // animated push onto an existing stack and does not apply to replacing a
    // column's root.
    ApolloPaneReplaceDetailRoot(pane, viewController, sourceViewController,
                               routeMasterSelectionIntent);
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UINavigationController *navigationController = (UINavigationController *)self;
    BOOL observesSettlement = sPaneRouterPopHookDepth++ == 0;
    NSArray<UIViewController *> *beforeStack = observesSettlement
        ? [navigationController.viewControllers copy] : nil;
    ApolloPaneSplitViewController *pane = observesSettlement && ApolloPaneLayoutActive()
        ? (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController) : nil;
    NSUInteger popToken = navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]
            ? [pane apollo_primaryNavigationPopWillBeginWithOperation:@"popViewController"
                                                              animated:animated] : 0;
    UIViewController *popped = nil;
    BOOL originalCompleted = NO;
    @try {
        popped = %orig;
        originalCompleted = YES;
    } @finally {
        --sPaneRouterPopHookDepth;
        if (!originalCompleted && popToken != 0) {
            [pane apollo_primaryNavigationPopDidSettle:popToken
                                           beforeStack:beforeStack
                                              cancelled:YES];
        }
    }
    if (popToken != 0 && popped) {
        ApolloPaneObservePrimaryPopSettlement(
            pane, navigationController, beforeStack, popToken);
    } else if (popToken != 0) {
        [pane apollo_primaryNavigationPopDidSettle:popToken
                                       beforeStack:beforeStack
                                          cancelled:YES];
    }
    if (popped && navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
        [pane apollo_prepareDetailControllerForDisplay:navigationController.topViewController];
    }
    return popped;
}

- (NSArray<UIViewController *> *)popToViewController:(UIViewController *)viewController
                                             animated:(BOOL)animated {
    UINavigationController *navigationController = (UINavigationController *)self;
    BOOL observesSettlement = sPaneRouterPopHookDepth++ == 0;
    NSArray<UIViewController *> *beforeStack = observesSettlement
        ? [navigationController.viewControllers copy] : nil;
    ApolloPaneSplitViewController *pane = observesSettlement && ApolloPaneLayoutActive()
        ? (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController) : nil;
    NSUInteger popToken = navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]
            ? [pane apollo_primaryNavigationPopWillBeginWithOperation:@"popToViewController"
                                                              animated:animated] : 0;
    NSArray<UIViewController *> *popped = nil;
    BOOL originalCompleted = NO;
    @try {
        popped = %orig;
        originalCompleted = YES;
    } @finally {
        --sPaneRouterPopHookDepth;
        if (!originalCompleted && popToken != 0) {
            [pane apollo_primaryNavigationPopDidSettle:popToken
                                           beforeStack:beforeStack
                                              cancelled:YES];
        }
    }
    if (popToken != 0 && popped.count > 0) {
        ApolloPaneObservePrimaryPopSettlement(
            pane, navigationController, beforeStack, popToken);
    } else if (popToken != 0) {
        [pane apollo_primaryNavigationPopDidSettle:popToken
                                       beforeStack:beforeStack
                                          cancelled:YES];
    }
    if (popped.count > 0 && navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
        [pane apollo_prepareDetailControllerForDisplay:navigationController.topViewController];
    }
    return popped;
}

- (NSArray<UIViewController *> *)popToRootViewControllerAnimated:(BOOL)animated {
    UINavigationController *navigationController = (UINavigationController *)self;
    BOOL observesSettlement = sPaneRouterPopHookDepth++ == 0;
    NSArray<UIViewController *> *beforeStack = observesSettlement
        ? [navigationController.viewControllers copy] : nil;
    ApolloPaneSplitViewController *pane = observesSettlement && ApolloPaneLayoutActive()
        ? (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController) : nil;
    NSUInteger popToken = navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]
            ? [pane apollo_primaryNavigationPopWillBeginWithOperation:@"popToRoot"
                                                              animated:animated] : 0;
    NSArray<UIViewController *> *popped = nil;
    BOOL originalCompleted = NO;
    @try {
        popped = %orig;
        originalCompleted = YES;
    } @finally {
        --sPaneRouterPopHookDepth;
        if (!originalCompleted && popToken != 0) {
            [pane apollo_primaryNavigationPopDidSettle:popToken
                                           beforeStack:beforeStack
                                              cancelled:YES];
        }
    }
    if (popToken != 0 && popped.count > 0) {
        ApolloPaneObservePrimaryPopSettlement(
            pane, navigationController, beforeStack, popToken);
    } else if (popToken != 0) {
        [pane apollo_primaryNavigationPopDidSettle:popToken
                                       beforeStack:beforeStack
                                          cancelled:YES];
    }
    if (popped.count > 0 && navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
        [pane apollo_prepareDetailControllerForDisplay:navigationController.topViewController];
    }
    return popped;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers animated:(BOOL)animated {
    %orig;
    if (!ApolloPaneLayoutActive() || sPaneRouterReentrant) return;
    UINavigationController *navigationController = (UINavigationController *)self;
    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController);
    if (navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]) {
        [pane apollo_primaryNavigationStackWasReplacedExternally:
            navigationController.viewControllers];
        [pane apollo_scheduleDetailReconciliationAfterPrimaryMutation:@"primary stack replacement"];
    } else if (navigationController ==
               [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
        [pane apollo_prepareDetailControllerForDisplay:navigationController.topViewController];
    }
}

- (void)setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    %orig;
    if (!ApolloPaneLayoutActive() || sPaneRouterReentrant) return;
    UINavigationController *navigationController = (UINavigationController *)self;
    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(navigationController);
    if (navigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]) {
        [pane apollo_primaryNavigationStackWasReplacedExternally:
            navigationController.viewControllers];
        [pane apollo_scheduleDetailReconciliationAfterPrimaryMutation:@"primary stack replacement"];
    } else if (navigationController ==
               [pane apollo_navigationControllerForColumn:ApolloPaneColumnSecondary]) {
        [pane apollo_prepareDetailControllerForDisplay:navigationController.topViewController];
    }
}

- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    %orig;
    if (!ApolloPaneLayoutActive()) return;
    UINavigationController *selfNavigationController = (UINavigationController *)self;
    ApolloPaneSplitViewController *pane =
        (ApolloPaneSplitViewController *)ApolloPaneSplitControllerFor(selfNavigationController);
    [pane apollo_navigationTransitionDidSettle];
    [pane apollo_resolvedDisplayStateMayHaveChanged];
    if (selfNavigationController ==
        [pane apollo_navigationControllerForColumn:ApolloPaneColumnPrimary]) {
        [pane apollo_scheduleDetailReconciliationAfterPrimaryMutation:@"primary navigation settled"];
    }
}

%end


%hook ApolloPanePostsViewController

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // Posts owns a second UITableView only while its Jump Bar dropdown is open.
    // Selecting a post on the main Texture table must not clear first; selecting
    // a dropdown row can synchronously reuse this same controller for a new
    // subreddit/feed, so request a semantic comparison after Apollo settles.
    UITableView *dropDownTableView = nil;
    @try {
        Ivar ivar = class_getInstanceVariable([self class], "dropDownTableView");
        if (ivar) dropDownTableView = object_getIvar(self, ivar);
    } @catch (__unused NSException *exception) {}
    BOOL wasDropDownSelection = dropDownTableView && tableView == dropDownTableView;
    %orig;
    if (wasDropDownSelection) {
        ApolloPaneSchedulePostsScopeReconciliation((UIViewController *)self,
                                                   @"Jump Bar dropdown selection");
    }
}

- (void)redditAccountChangedWithNotification:(NSNotification *)notification {
    %orig;
    ApolloPaneSplitViewController *pane =
        ApolloPaneForPrimaryController((UIViewController *)self);
    [pane apollo_forcePrimaryContextChangedForViewController:(UIViewController *)self
                                                      reason:@"account changed"];
}

%end


%hook UINavigationItem

- (void)setTitle:(NSString *)title {
    NSString *before = self.title;
    %orig;
    NSString *after = self.title;
    if (!ApolloPaneLayoutActive() || before == after || [before isEqualToString:after]) return;
    ApolloPaneSplitViewController *pane = ApolloPaneForPrimaryNavigationItem(self);
    [pane apollo_scheduleDetailReconciliationAfterPrimaryMutation:
        @"primary navigation title changed"];
}

%end

%end

%ctor {
    // iPhone never installs this, and neither does an iPad with the layout off:
    // ApolloPaneLayoutActive() would be NO for the whole process anyway, so the
    // hook would be pure overhead on Apollo's hottest navigation path.
    if (!ApolloPaneLayoutEnabled()) return;

    Class navigationControllerClass = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!navigationControllerClass) {
        ApolloLog(@"[PaneRouter] ApolloNavigationController class missing; router not installed");
        return;
    }
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    Class settingsClass = objc_getClass("_TtC6Apollo22SettingsViewController");
    Class inboxListClass = objc_getClass("_TtC6Apollo23InboxListViewController");
    Class listAdapterClass = objc_getClass("_TtC6Apollo11ListAdapter");
    Class tableNodeClass = objc_getClass("ASTableNode");
    if (!postsClass || !settingsClass || !inboxListClass || !listAdapterClass ||
        !tableNodeClass) {
        ApolloLog(@"[PaneRouter] required class missing posts=%@ settings=%@ inbox=%@ adapter=%@ tableNode=%@; router not installed",
                  NSStringFromClass(postsClass), NSStringFromClass(settingsClass),
                  NSStringFromClass(inboxListClass), NSStringFromClass(listAdapterClass),
                  NSStringFromClass(tableNodeClass));
        return;
    }
    %init(ApolloPaneRouterGroup,
          ApolloPaneNavigationController=navigationControllerClass,
          ApolloPanePostsViewController=postsClass,
          ApolloPaneSettingsViewController=settingsClass,
          ApolloPaneInboxListViewController=inboxListClass,
          ApolloPaneListAdapter=listAdapterClass,
          ApolloPaneTableNode=tableNodeClass);

    NSArray<NSString *> *accountNotifications = @[
        @"com.christianselig.RedditCurrentAccountChanged",
        @"com.christianselig.RedditAccountChanged",
    ];
    for (NSString *name in accountNotifications) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                for (ApolloPaneSplitViewController *pane in ApolloPaneAllLivePanes()) {
                    [pane apollo_accountContextDidChange];
                }
            }];
    }
    ApolloLog(@"[PaneRouter] installed with %lu routed classes",
              (unsigned long)ApolloPaneExplicitRouteCount());
}
