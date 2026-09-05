// ApolloVisionOSMultiwindow.xm
//
// Multiwindow affordances for Apollo running as an iOS app in compatibility
// mode on visionOS (Apple Vision Pro). iPhone and iPad are a strict no-op — the
// %ctor bails unless running on visionOS.
//
// Apollo already declares UIApplicationSupportsMultipleScenes and a handoff
// activity for iPad multiwindow, but offers no way to trigger it on visionOS.
// This adds:
//
//   • Cmd-N (new window) and Cmd-Shift-N (duplicate the current window). A
//     bottom-left floating button duplicates too, since the Vision Pro is
//     usually driven without a keyboard and the window bar's menu only offers
//     system commands.
//
//   • "Open in New Window" on a post or comment long-press: the thread opens in
//     its own window beside the feed. Apollo's handoff opener accepts only its
//     universal-link domain (openinapollo.com) and reads the reddit target from
//     the URL's query items (subreddit / postID / commentID), so a new plain
//     scene is activated and then handed a browsing-web NSUserActivity carrying
//     that query URL through its scene delegate's -scene:continueUserActivity:.
//     The pressed post/comment is identified from the cell's Texture node,
//     located via the last touch point (gaze-and-pinch input does not report a
//     usable gesture state mid-press, so the point is traced from
//     -[UIWindow sendEvent:]).

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"
#import "Tweak.h"   // RDKLink, RDKComment

// RedditKit accessors not in Tweak.h's shared surface; resolved at runtime
// against Apollo's own classes.
@interface RDKLink (ApolloVisionOS)
@property (copy, nonatomic, readonly) NSString *identifier;
@end

@interface RDKComment (ApolloVisionOS)
@property (copy, nonatomic, readonly) NSString *identifier;
@property (copy, nonatomic, readonly) NSString *subreddit;
@end

// Minimal Texture surface, resolved at runtime (ApolloReborn.dylib is injected,
// not linked against Apollo).
@interface ASDisplayNode : NSObject
- (id)supernode;
@end

@interface UIView (ApolloVisionOSTexture)
- (ASDisplayNode *)asyncdisplaykit_node;
@end

#pragma mark - visionOS gate

static BOOL ApolloIsRunningOnVisionOS(void) {
    static BOOL result = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        SEL sel = NSSelectorFromString(@"isiOSAppOnVision");
        if ([processInfo respondsToSelector:sel]) {
            BOOL (*msgSend)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            if (msgSend(processInfo, sel)) {
                result = YES;
                return;
            }
        }
        if (NSClassFromString(@"UIWindowSceneGeometryPreferencesVision") != nil) {
            result = YES;
        }
    });
    return result;
}

#pragma mark - Window / scene helpers

// Multiple windows can stay foreground-active at once on visionOS, and
// connectedScenes is unordered, so prefer the scene that owns the key window
// before falling back to any foreground-active scene.
static UIWindowScene *ApolloForegroundWindowScene(void) {
    UIWindowScene *foreground = nil;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) return windowScene;
        }
        if (!foreground &&
            windowScene.activationState == UISceneActivationStateForegroundActive) {
            foreground = windowScene;
        }
        if (!fallback) fallback = windowScene;
    }
    return foreground ?: fallback;
}

// Reproduce a scene's window in a new scene. Apollo's SceneDelegate does not
// implement -stateRestorationActivityForScene:, so this rides the
// scene.userActivity fallback (Apollo's own handoff activity); a nil result
// opens a fresh window.
static NSUserActivity *ApolloStateActivityForScene(UIWindowScene *scene) {
    if (!scene) return nil;
    id<UISceneDelegate> delegate = scene.delegate;
    if ([delegate respondsToSelector:@selector(stateRestorationActivityForScene:)]) {
        NSUserActivity *activity = [delegate stateRestorationActivityForScene:scene];
        if (activity) return activity;
    }
    return scene.userActivity;
}

static NSUserActivity *ApolloCurrentStateActivity(void) {
    return ApolloStateActivityForScene(ApolloForegroundWindowScene());
}

static void ApolloOpenWindow(NSUserActivity *activity) {
    [[UIApplication sharedApplication] requestSceneSessionActivation:nil
                                                        userActivity:activity
                                                             options:nil
                                                        errorHandler:^(NSError *error) {
        ApolloLog(@"[VisionOSMultiwindow] scene activation failed: %@", error);
    }];
}

#pragma mark - Touch trace

// Gaze-and-pinch input does not report a usable gesture-recogniser state
// mid-press, so the pressed point is recorded at the source: every synthesized
// touch funnels through -[UIWindow sendEvent:] regardless of input mechanism.
static __weak UIWindow *gApolloLastTouchWindow = nil;
static CGPoint gApolloLastTouchPoint;
static CFAbsoluteTime gApolloLastTouchTime = 0;

%group ApolloVisionOSTouchTrace
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            UITouchPhase phase = touch.phase;
            if (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved ||
                phase == UITouchPhaseStationary) {
                gApolloLastTouchWindow = self;
                gApolloLastTouchPoint = [touch locationInView:self];
                gApolloLastTouchTime = CFAbsoluteTimeGetCurrent();
                break;
            }
        }
    }
    %orig;
}
%end
%end

#pragma mark - Deep-link resolution

static ASDisplayNode *ApolloNodeOfView(UIView *view) {
    if (![view respondsToSelector:@selector(asyncdisplaykit_node)]) return nil;
    return [view asyncdisplaykit_node];
}

// The RedditKit model stored under ivar `ivarName` on a Swift cell node,
// provided it is an instance of the named class.
static id ApolloModelIvar(id node, const char *ivarName, NSString *className) {
    Ivar ivar = class_getInstanceVariable(object_getClass(node), ivarName);
    if (!ivar) return nil;
    id value = object_getIvar(node, ivar);
    Class modelClass = NSClassFromString(className);
    return (value && modelClass && [value isKindOfClass:modelClass]) ? value : nil;
}

static NSString *ApolloID36FromFullName(NSString *fullName) {
    NSRange underscore = [fullName rangeOfString:@"_"];
    if (fullName && underscore.location != NSNotFound && underscore.location + 1 < fullName.length) {
        return [fullName substringFromIndex:underscore.location + 1];
    }
    return nil;
}

static NSString *ApolloNonEmpty(NSString *value) {
    return ([value isKindOfClass:[NSString class]] && value.length) ? value : nil;
}

// openinapollo.com deep link. Apollo's handoff opener gates on this host and
// reads the reddit target from bare-id36 query items (it adds the t3_/t1_
// prefixes itself), so the link is query-string encoded rather than a reddit
// path.
static NSURL *ApolloDeepLinkURL(NSString *subreddit, NSString *postID, NSString *commentID) {
    if (!postID.length) return nil;
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"openinapollo.com";
    components.path = @"/";
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    if (subreddit.length) [items addObject:[NSURLQueryItem queryItemWithName:@"subreddit" value:subreddit]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"postID" value:postID]];
    if (commentID.length) [items addObject:[NSURLQueryItem queryItemWithName:@"commentID" value:commentID]];
    components.queryItems = items;
    return components.URL;
}

static NSURL *ApolloDeepLinkForLink(RDKLink *link) {
    NSString *postID = ApolloNonEmpty(link.identifier) ?: ApolloID36FromFullName(link.fullName);
    if (!postID) return nil;
    return ApolloDeepLinkURL(ApolloNonEmpty(link.subreddit), postID, nil);
}

static NSURL *ApolloDeepLinkForComment(RDKComment *comment) {
    NSString *postID = ApolloNonEmpty([comment linkIDWithoutTypePrefix]);
    if (!postID) return nil;
    return ApolloDeepLinkURL(ApolloNonEmpty(comment.subreddit), postID,
                             ApolloNonEmpty(comment.identifier));
}

// Deep link for the post or comment displayed at or above `view`, walking each
// view's Texture node chain.
static NSURL *ApolloDeepLinkFromView(UIView *view) {
    NSUInteger hops = 0;
    for (UIView *v = view; v && ![v isKindOfClass:[UIWindow class]] && hops < 40;
         v = v.superview, hops++) {
        NSUInteger nodeHops = 0;
        for (ASDisplayNode *n = ApolloNodeOfView(v); n && nodeHops < 40; nodeHops++) {
            NSString *cls = NSStringFromClass([n class]);
            if ([cls hasSuffix:@"PostCellNode"]) {
                RDKLink *link = ApolloModelIvar(n, "link", @"RDKLink");
                if (link) return ApolloDeepLinkForLink(link);
            } else if ([cls hasSuffix:@"CommentCellNode"]) {
                RDKComment *comment = ApolloModelIvar(n, "comment", @"RDKComment");
                if (comment) return ApolloDeepLinkForComment(comment);
            }
            n = [n respondsToSelector:@selector(supernode)] ? [n supernode] : nil;
        }
    }
    return nil;
}

// The view under a long-press about to show a context menu: it carries a
// UIContextMenuInteraction and one of its recognisers is mid-recognition. Used
// as a fallback when no recent touch was traced.
static UIView *ApolloActiveContextMenuView(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            BOOL hasInteraction = NO;
            for (id<UIInteraction> interaction in view.interactions) {
                if ([interaction isKindOfClass:[UIContextMenuInteraction class]]) {
                    hasInteraction = YES;
                    break;
                }
            }
            if (hasInteraction) {
                for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
                    BOOL live = recognizer.state == UIGestureRecognizerStateBegan ||
                                recognizer.state == UIGestureRecognizerStateChanged ||
                                recognizer.numberOfTouches > 0;
                    if (!live) continue;
                    CGPoint point = [recognizer locationInView:view];
                    UIView *hit = [view hitTest:point withEvent:nil];
                    return hit ?: view;
                }
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

// Deep link for whatever is under the active long-press, or nil when it isn't a
// post/comment. Resolved eagerly at menu-configuration time — by the time a
// menu action runs the touch is gone. The traced touch point is primary; the
// interaction walk is the fallback.
static NSURL *ApolloActiveDeepLink(void) {
    UIWindow *window = gApolloLastTouchWindow;
    if (window && CFAbsoluteTimeGetCurrent() - gApolloLastTouchTime < 5.0) {
        UIView *hit = [window hitTest:gApolloLastTouchPoint withEvent:nil];
        NSURL *url = ApolloDeepLinkFromView(hit ?: window);
        if (url) return url;
    }
    UIView *view = ApolloActiveContextMenuView();
    return view ? ApolloDeepLinkFromView(view) : nil;
}

#pragma mark - New-window delivery

// Diagnostics must describe the route without retaining subreddit names,
// post IDs, comment IDs, usernames, or arbitrary query strings. Those values
// are necessary for delivery but not for understanding whether scene routing
// succeeded.
static NSString *ApolloPrivateDestinationKind(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    NSArray<NSString *> *components = url.pathComponents;
    if ([host hasSuffix:@"reddit.com"]) {
        if ([components containsObject:@"comments"]) return @"reddit-post";
        if ([components containsObject:@"r"]) return @"reddit-community";
        if ([components containsObject:@"user"] || [components containsObject:@"u"]) {
            return @"reddit-profile";
        }
        return @"reddit-root";
    }
    return [url.scheme.lowercaseString isEqualToString:@"apollo"]
        ? @"apollo-route" : @"external-web";
}

// Hand a URL to a scene through Apollo's handoff entry point. The activity type
// is the Foundation browsing-web constant, which is the type Apollo's activity
// handler gates its webpageURL branch on.
static void ApolloDeliverURLToScene(UIWindowScene *scene, NSURL *url) {
    id<UISceneDelegate> delegate = scene.delegate;
    if (![delegate respondsToSelector:@selector(scene:continueUserActivity:)]) {
        ApolloLog(@"[VisionOSMultiwindow] new scene's delegate (%@) has no continueUserActivity:; "
                  @"window opens without the target", NSStringFromClass([delegate class]));
        return;
    }
    NSUserActivity *activity =
        [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = url;
    ApolloLog(@"[VisionOSMultiwindow] handing destination=%@ to the new scene",
              ApolloPrivateDestinationKind(url));
    [delegate scene:scene continueUserActivity:activity];
}

// Poll for a scene that was not connected before the activation request, then
// deliver once its UI is up. A scene-activation notification observer proved
// unreliable; polling connectedScenes cannot miss.
static void ApolloAwaitNewScene(NSHashTable<UIScene *> *existing, NSURL *url, int attemptsLeft) {
    if (attemptsLeft <= 0) {
        ApolloLog(@"[VisionOSMultiwindow] no new scene appeared within 8s; destination=%@ not delivered",
                  ApolloPrivateDestinationKind(url));
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]] || [existing containsObject:scene]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.windows.count == 0) break;   // connected, UI not up yet
            ApolloDeliverURLToScene(windowScene, url);
            return;
        }
        ApolloAwaitNewScene(existing, url, attemptsLeft - 1);
    });
}

// Passing the activity through requestSceneSessionActivation's userActivity:
// parameter opens the window but drops the payload, so a plain scene is
// activated and the deep link delivered in-process once the new scene exists.
static void ApolloOpenDeepLinkInNewWindow(NSURL *url) {
    if (!url) return;
    NSHashTable<UIScene *> *existing = [NSHashTable weakObjectsHashTable];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        [existing addObject:scene];
    }
    ApolloAwaitNewScene(existing, url, 32);
    ApolloOpenWindow(nil);
}

#pragma mark - Keyboard shortcuts

%group ApolloVisionOSKeyCommands

%hook UIApplication

- (NSArray<UIKeyCommand *> *)keyCommands {
    NSArray<UIKeyCommand *> *existing = %orig ?: @[];

    UIKeyCommand *newWindow =
        [UIKeyCommand keyCommandWithInput:@"n"
                            modifierFlags:UIKeyModifierCommand
                                   action:@selector(apolloVisionOSNewWindow:)];
    newWindow.discoverabilityTitle = @"New Window";

    UIKeyCommand *duplicateWindow =
        [UIKeyCommand keyCommandWithInput:@"n"
                            modifierFlags:(UIKeyModifierCommand | UIKeyModifierShift)
                                   action:@selector(apolloVisionOSDuplicateWindow:)];
    duplicateWindow.discoverabilityTitle = @"Duplicate Window";

    return [existing arrayByAddingObjectsFromArray:@[newWindow, duplicateWindow]];
}

%new
- (void)apolloVisionOSNewWindow:(id)sender {
    ApolloOpenWindow(nil);
}

%new
- (void)apolloVisionOSDuplicateWindow:(id)sender {
    ApolloOpenWindow(ApolloCurrentStateActivity());
}

%end

%end

#pragma mark - Context menu entry

// Every context menu is built through this factory, so wrapping the action
// provider appends the entry wherever Apollo offers a long-press menu. The
// child-count test skips system menus (text selection and the like). The deep
// link is resolved HERE, while the long-press touch is still down and the
// pressed cell is findable. The action defers past the menu's dismissal, since
// a scene activation requested mid-dismissal is dropped.
%group ApolloVisionOSContextMenu

%hook UIContextMenuConfiguration

+ (instancetype)configurationWithIdentifier:(id<NSCopying>)identifier
                            previewProvider:(UIContextMenuContentPreviewProvider)previewProvider
                             actionProvider:(UIContextMenuActionProvider)actionProvider {
    if (!actionProvider) return %orig;

    NSURL *deepLink = ApolloActiveDeepLink();
    if (!deepLink) return %orig;

    UIContextMenuActionProvider wrapped = ^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        UIMenu *menu = actionProvider(suggestedActions);
        if (![menu isKindOfClass:[UIMenu class]] || menu.children.count < 2) return menu;

        UIAction *openInWindow =
            [UIAction actionWithTitle:@"Open in New Window"
                                image:[UIImage systemImageNamed:@"macwindow.badge.plus"]
                           identifier:@"com.apollo-reborn.visionos.open-in-new-window"
                              handler:^(__unused __kindof UIAction *action) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    ApolloOpenDeepLinkInNewWindow(deepLink);
                });
            }];

        return [menu menuByReplacingChildren:[menu.children arrayByAddingObject:openInWindow]];
    };

    return %orig(identifier, previewProvider, wrapped);
}

%end

%end

#pragma mark - Floating button

@interface ApolloVisionOSWindowButtonTarget : NSObject
+ (instancetype)shared;
- (void)duplicate:(id)sender;
@end

@implementation ApolloVisionOSWindowButtonTarget
+ (instancetype)shared {
    static ApolloVisionOSWindowButtonTarget *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[ApolloVisionOSWindowButtonTarget alloc] init]; });
    return shared;
}
// Duplicates the sender's OWN window, so each window's button reproduces that
// window rather than whichever scene is foreground.
- (void)duplicate:(id)sender {
    UIWindowScene *scene = nil;
    if ([sender isKindOfClass:[UIView class]]) scene = ((UIView *)sender).window.windowScene;
    ApolloOpenWindow(ApolloStateActivityForScene(scene ?: ApolloForegroundWindowScene()));
}
@end

// One button per window (weak keys, purged with the window), mirroring the
// per-window hover ghost pools. A single shared button placed on the key window
// would hop between scenes as focus changed, leaving the unfocused window
// without one — the case this feature exists for.
static NSMapTable<UIWindow *, UIButton *> *gApolloWindowButtons = nil;

// The content window of a scene: its first normal-level window with a root view
// controller (skips keyboard / alert overlay windows).
static UIWindow *ApolloContentWindow(UIWindowScene *scene) {
    for (UIWindow *window in scene.windows) {
        if (window.rootViewController && !window.hidden &&
            window.windowLevel == UIWindowLevelNormal) {
            return window;
        }
    }
    return nil;
}

// Bottom-left: the top-right corner is Apollo's own overflow button. Left as a
// stock UIButton with no hover style of ours — UIKit gives buttons their own
// automatic gaze treatment.
static UIButton *ApolloMakeWindowButton(void) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:@"plus.rectangle.on.rectangle"
                             withConfiguration:config]
            forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
    button.layer.cornerRadius = 22.0;
    button.accessibilityLabel = @"Duplicate Window";
    [button addTarget:[ApolloVisionOSWindowButtonTarget shared]
               action:@selector(duplicate:)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// Apollo replaces window contents freely, so the buttons are re-asserted on a
// slow timer rather than added once.
static void ApolloPlaceWindowButtons(void) {
    if (!gApolloWindowButtons) gApolloWindowButtons = [NSMapTable weakToStrongObjectsMapTable];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindow *target = ApolloContentWindow((UIWindowScene *)scene);
        if (!target) continue;

        UIButton *button = [gApolloWindowButtons objectForKey:target];
        if (!button) {
            button = ApolloMakeWindowButton();
            [gApolloWindowButtons setObject:button forKey:target];
        }
        if (button.superview != target) [target addSubview:button];
        [target bringSubviewToFront:button];
        button.frame =
            CGRectMake(16.0,
                       target.bounds.size.height - 44.0 - target.safeAreaInsets.bottom - 16.0,
                       44.0, 44.0);
    }
}

static void ApolloStartWindowButton(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
                ApolloPlaceWindowButtons();
            }];
        });
    }];
}

// visionOS ONLY. This was briefly extended to iPad as an answer to "a fourth
// tiled column will not fit, so use separate windows instead" — reverted at the
// user's request. iPad is a strict no-op again, exactly as before.
%ctor {
    if (!ApolloIsRunningOnVisionOS()) return;

    %init(ApolloVisionOSKeyCommands);
    %init(ApolloVisionOSTouchTrace);
    %init(ApolloVisionOSContextMenu);
    ApolloStartWindowButton();

    ApolloLog(@"[VisionOSMultiwindow] active on visionOS");
}
