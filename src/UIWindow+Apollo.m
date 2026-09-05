#import "UIWindow+Apollo.h"
#import "ApolloCommon.h"   // ApolloContentColumnForSplitViewController

// https://stackoverflow.com/a/21848247
@implementation UIWindow (Apollo)
- (UIViewController *)visibleViewController {
    UIViewController *rootViewController = self.rootViewController;
    return [UIWindow getVisibleViewControllerFrom:rootViewController];
}

+ (UIViewController *) getVisibleViewControllerFrom:(UIViewController *) vc {
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return [UIWindow getVisibleViewControllerFrom:[((UINavigationController *) vc) visibleViewController]];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        return [UIWindow getVisibleViewControllerFrom:[((UITabBarController *) vc) selectedViewController]];
    } else if ([vc isKindOfClass:[UISplitViewController class]]) {
        // The iPad pane layout puts a split view controller between the tab bar
        // and the navigation stacks. Without this branch the walk stops on the
        // container and every caller gets a shell instead of a content screen.
        return [UIWindow getVisibleViewControllerFrom:
                    ApolloContentColumnForSplitViewController((UISplitViewController *) vc)];
    } else {
        if (vc.presentedViewController) {
            return [UIWindow getVisibleViewControllerFrom:vc.presentedViewController];
        } else {
            return vc;
        }
    }
}
@end
