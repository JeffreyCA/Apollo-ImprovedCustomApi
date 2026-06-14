#import "ApolloCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *ApolloQuickActionNameFromURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (![[url.scheme lowercaseString] isEqualToString:@"apollo"]) return nil;

    NSString *host = [[url.host lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![host isEqualToString:@"reborn"]) return nil;

    NSString *path = [[url.path lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (path.length == 0) return nil;

    // Only the actions we actually route below. Popular/All are opened by the
    // widget via Apollo's native apollo://reddit.com/r/popular|all URLs (host
    // "reddit.com", not "reborn"), so we must NOT claim them here — claiming a
    // URL we can't perform swallows it and then retries until it gives up.
    if ([path isEqualToString:@"search"] ||
        [path isEqualToString:@"home"] ||
        [path isEqualToString:@"inbox"] ||
        [path isEqualToString:@"profile"] ||
        [path isEqualToString:@"settings"]) {
        return path;
    }

    return nil;
}

static id ApolloQuickActionsIvarObject(id object, const char *name) {
    if (!object || !name) return nil;

    @try {
        Ivar ivar = class_getInstanceVariable([object class], name);
        return ivar ? object_getIvar(object, ivar) : nil;
    } @catch (NSException *exception) {
        ApolloLog(@"[QuickActions] Failed reading ivar %s on %@: %@", name, object, exception);
        return nil;
    }
}

static id ApolloQuickActionsTabBarController(void) {
    UIApplication *application = UIApplication.sharedApplication;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        id sceneDelegate = [(UIWindowScene *)scene delegate];
        id tabBarController = ApolloQuickActionsIvarObject(sceneDelegate, "tabBarController");
        if (tabBarController) return tabBarController;

        for (UIWindow *window in [(UIWindowScene *)scene windows]) {
            UIViewController *root = window.rootViewController;
            if ([root isKindOfClass:UITabBarController.class]) return root;
            if ([root.presentedViewController isKindOfClass:UITabBarController.class]) return root.presentedViewController;
        }
    }

    id appDelegate = application.delegate;
    id tabBarController = ApolloQuickActionsIvarObject(appDelegate, "tabBarController");
    if (tabBarController) return tabBarController;

    return nil;
}

// Opens Apollo's front-page feed (the aggregated "Posts from subscriptions"
// listing), NOT the subreddit picker list that goToHomeTab lands on.
//
// goToHomeTab only switches to the Home tab, whose root is a
// RedditListViewController — a table whose first row (section 0, row 0) is the
// "Home" entry ("Posts from subscriptions"). Selecting that row is exactly what
// a user tap does, so we drive Apollo's own navigation by calling its
// tableView:didSelectRowAtIndexPath: with that index path. This reuses Apollo's
// real push logic instead of trying to construct a PostsViewController (its
// PostsType.home initializer is a Swift enum that can't be built from ObjC).
static BOOL ApolloQuickActionsOpenHomeFeed(id tabBarController) {
    // Switch to the Home tab so the navigation we drive is the visible one.
    if ([tabBarController respondsToSelector:@selector(goToHomeTab)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabBarController, @selector(goToHomeTab));
        } @catch (NSException *exception) {
            ApolloLog(@"[QuickActions] goToHomeTab threw: %@", exception);
        }
    }

    if (![tabBarController isKindOfClass:UITabBarController.class]) {
        ApolloLog(@"[QuickActions] Home: tab controller is not a UITabBarController: %@", tabBarController);
        return NO;
    }

    UIViewController *selected = [(UITabBarController *)tabBarController selectedViewController];
    UINavigationController *nav = nil;
    if ([selected isKindOfClass:UINavigationController.class]) {
        nav = (UINavigationController *)selected;
    } else if ([selected.navigationController isKindOfClass:UINavigationController.class]) {
        nav = selected.navigationController;
    }
    if (!nav) {
        ApolloLog(@"[QuickActions] Home: no navigation controller for selected tab %@", selected);
        return NO;
    }

    // Pop back to the list root so the "Home" row is the controller we drive.
    [nav popToRootViewControllerAnimated:NO];
    UIViewController *root = nav.viewControllers.firstObject;

    Class listClass = objc_getClass("_TtC6Apollo24RedditListViewController");
    if (!listClass || ![root isKindOfClass:listClass]) {
        ApolloLog(@"[QuickActions] Home: root is not RedditListViewController (%@)", root);
        return NO;
    }

    UITableView *tableView = nil;
    if ([root respondsToSelector:@selector(tableView)]) {
        @try {
            tableView = ((UITableView *(*)(id, SEL))objc_msgSend)(root, @selector(tableView));
        } @catch (NSException *exception) {
            ApolloLog(@"[QuickActions] Home: failed reading tableView: %@", exception);
        }
    }

    if (![root respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        ApolloLog(@"[QuickActions] Home: %@ does not respond to tableView:didSelectRowAtIndexPath:", root);
        return NO;
    }

    NSIndexPath *homeIndexPath = [NSIndexPath indexPathForRow:0 inSection:0];
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(root, @selector(tableView:didSelectRowAtIndexPath:), tableView, homeIndexPath);
        ApolloLog(@"[QuickActions] Opened Home front-page feed via RedditListViewController row 0");
        return YES;
    } @catch (NSException *exception) {
        ApolloLog(@"[QuickActions] Home: failed selecting front-page row: %@", exception);
        return NO;
    }
}

static BOOL ApolloQuickActionsPerformNow(NSString *action) {
    id tabBarController = ApolloQuickActionsTabBarController();
    if (!tabBarController) {
        return NO;
    }

    // "home" opens the actual front-page feed (posts), not the picker list.
    if ([action isEqualToString:@"home"]) {
        return ApolloQuickActionsOpenHomeFeed(tabBarController);
    }

    // Remaining quick actions map directly to ApolloTabBarController tab selectors.
    SEL selector = NULL;
    if ([action isEqualToString:@"search"]) {
        selector = @selector(goToSearchTab);
    } else if ([action isEqualToString:@"inbox"]) {
        selector = @selector(goToInboxTab);
    } else if ([action isEqualToString:@"profile"]) {
        selector = @selector(goToProfileTab);
    } else if ([action isEqualToString:@"settings"]) {
        selector = @selector(goToSettingsTab);
    }

    if (!selector || ![tabBarController respondsToSelector:selector]) {
        ApolloLog(@"[QuickActions] Tab controller %@ does not respond to %@", tabBarController, NSStringFromSelector(selector));
        return NO;
    }

    @try {
        ((void (*)(id, SEL))objc_msgSend)(tabBarController, selector);
        ApolloLog(@"[QuickActions] Performed %@", action);
    } @catch (NSException *exception) {
        ApolloLog(@"[QuickActions] Failed performing %@: %@", action, exception);
        return NO;
    }

    return YES;
}

static void ApolloQuickActionsPerformWithRetry(NSString *action, NSUInteger attempt) {
    if (ApolloQuickActionsPerformNow(action)) return;
    if (attempt >= 8) {
        ApolloLog(@"[QuickActions] Gave up performing %@", action);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloQuickActionsPerformWithRetry(action, attempt + 1);
    });
}

static BOOL ApolloQuickActionsHandleURL(NSURL *url) {
    NSString *action = ApolloQuickActionNameFromURL(url);
    if (!action) return NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloQuickActionsPerformWithRetry(action, 0);
    });
    return YES;
}

%hook _TtC6Apollo11AppDelegate

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    if (ApolloQuickActionsHandleURL(url)) {
        return YES;
    }
    return %orig(application, url, options);
}

%end

%hook _TtC6Apollo13SceneDelegate

- (void)scene:(UIScene *)scene openURLContexts:(NSSet *)URLContexts {
    NSMutableSet *unhandledContexts = [NSMutableSet setWithCapacity:URLContexts.count];
    BOOL handledAny = NO;

    for (id context in URLContexts) {
        NSURL *url = nil;
        @try {
            if ([context respondsToSelector:@selector(URL)]) {
                url = ((NSURL *(*)(id, SEL))objc_msgSend)(context, @selector(URL));
            }
        } @catch (NSException *exception) {
            ApolloLog(@"[QuickActions] Failed reading URL context: %@", exception);
        }

        if (ApolloQuickActionsHandleURL(url)) {
            handledAny = YES;
        } else if (context) {
            [unhandledContexts addObject:context];
        }
    }

    if (unhandledContexts.count > 0) {
        %orig(scene, unhandledContexts);
    } else if (!handledAny) {
        %orig(scene, URLContexts);
    }
}

%end
