#import "ApolloSettingsRouter.h"

#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloThemeManagerViewController.h"
#import "PictureInPictureViewController.h"
#import "TagFiltersViewController.h"
#import "settings/ApolloAISettingsViewController.h"
#import "settings/ApolloDeletedCommentsSettingsViewController.h"
#import "settings/ApolloLinkPreviewSettingsViewController.h"
#import "settings/ApolloOpenInAppViewController.h"
#import "settings/CustomAPIViewController.h"
#import "settings/InlineMediaSettingsViewController.h"
#import "settings/SavedCategoriesViewController.h"
#import "settings/TranslationSettingsViewController.h"

typedef UIViewController *(^ApolloSettingsRouteBuilder)(void);

// Inset-grouped is what every settings screen in the tweak uses; a shared
// builder keeps the table below down to one line per route.
static ApolloSettingsRouteBuilder ApolloSettingsInsetGrouped(Class cls) {
    return ^UIViewController *{
        return [(UITableViewController *)[cls alloc] initWithStyle:UITableViewStyleInsetGrouped];
    };
}

static NSArray<NSString *> *sRouteIds = nil;                                  // presentation order, no aliases
static NSDictionary<NSString *, NSString *> *sRouteTitles = nil;              // id -> screen title
static NSDictionary<NSString *, ApolloSettingsRouteBuilder> *sRouteBuilders = nil; // id (incl. aliases) -> builder
static NSDictionary<NSString *, NSString *> *sRouteAliases = nil;             // alias -> canonical id

static void ApolloSettingsRouterEnsureRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, ApolloSettingsRouteBuilder> *builders = [NSMutableDictionary dictionary];

        void (^add)(NSString *, NSString *, ApolloSettingsRouteBuilder) =
            ^(NSString *routeId, NSString *title, ApolloSettingsRouteBuilder builder) {
                [ids addObject:routeId];
                titles[routeId] = title;
                builders[routeId] = builder;
            };

        add(@"reborn", @"Apollo Reborn", ApolloSettingsInsetGrouped([CustomAPIViewController class]));
        add(@"saved-categories", @"Saved Categories", ApolloSettingsInsetGrouped([SavedCategoriesViewController class]));
        add(@"translation", @"Translation", ApolloSettingsInsetGrouped([TranslationSettingsViewController class]));
        add(@"tag-filters", @"Tag Filters", ApolloSettingsInsetGrouped([TagFiltersViewController class]));
        add(@"picture-in-picture", @"Picture-in-Picture", ApolloSettingsInsetGrouped([PictureInPictureViewController class]));
        add(@"apollo-ai", @"Apollo AI", ApolloSettingsInsetGrouped([ApolloAISettingsViewController class]));
        add(@"deleted-comments", @"Deleted Comments", ApolloSettingsInsetGrouped([ApolloDeletedCommentsSettingsViewController class]));
        add(@"rich-link-previews", @"Rich Link Previews", ApolloSettingsInsetGrouped([ApolloLinkPreviewSettingsViewController class]));
        add(@"inline-media", @"Inline Media", ApolloSettingsInsetGrouped([InlineMediaSettingsViewController class]));
        add(@"open-in-app", @"Open in App", ApolloSettingsInsetGrouped([ApolloOpenInAppViewController class]));
        add(@"theme-manager", @"Theme Manager", ^UIViewController *{
            return [[ApolloThemeManagerViewController alloc] init]; // default init = hub/list mode
        });

        sRouteAliases = @{ @"pip": @"picture-in-picture", @"ai": @"apollo-ai" };
        [sRouteAliases enumerateKeysAndObjectsUsingBlock:^(NSString *alias, NSString *canonical, BOOL *stop) {
            builders[alias] = builders[canonical];
            titles[alias] = titles[canonical];
        }];

        sRouteIds = [ids copy];
        sRouteTitles = [titles copy];
        sRouteBuilders = [builders copy];
    });
}

BOOL ApolloSettingsRouteExists(NSString *routeId) {
    if (![routeId isKindOfClass:[NSString class]]) return NO;
    ApolloSettingsRouterEnsureRegistry();
    return sRouteBuilders[routeId.lowercaseString] != nil;
}

NSString *ApolloSettingsRouteTitle(NSString *routeId) {
    if (![routeId isKindOfClass:[NSString class]]) return nil;
    ApolloSettingsRouterEnsureRegistry();
    return sRouteTitles[routeId.lowercaseString];
}

NSArray<NSString *> *ApolloSettingsRouteIds(void) {
    ApolloSettingsRouterEnsureRegistry();
    return sRouteIds;
}

BOOL ApolloSettingsRouteOpenNow(NSString *routeId) {
    ApolloSettingsRouterEnsureRegistry();
    ApolloSettingsRouteBuilder builder = [routeId isKindOfClass:[NSString class]] ? sRouteBuilders[routeId.lowercaseString] : nil;
    if (!builder) return NO;

    UIViewController *tabBarController = ApolloMainTabBarController();
    if (!tabBarController) return NO;

    if ([tabBarController respondsToSelector:@selector(goToSettingsTab)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tabBarController, @selector(goToSettingsTab));
        } @catch (NSException *exception) {
            ApolloLog(@"[SettingsRouter] goToSettingsTab threw: %@", exception);
        }
    }

    if (![tabBarController isKindOfClass:UITabBarController.class]) return NO;
    UIViewController *selected = [(UITabBarController *)tabBarController selectedViewController];
    UINavigationController *nav = [selected isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)selected
        : selected.navigationController;
    if (!nav) return NO;

    // A modal over the settings tab (e.g. account switcher) would swallow the
    // push — clear it first.
    if (nav.presentedViewController) {
        [nav dismissViewControllerAnimated:NO completion:nil];
    }
    [nav popToRootViewControllerAnimated:NO];
    [nav pushViewController:builder() animated:YES];
    ApolloLog(@"[SettingsRouter] Opened route '%@'", routeId);
    return YES;
}

static void ApolloSettingsRouteOpenWithRetry(NSString *routeId, NSUInteger attempt) {
    if (ApolloSettingsRouteOpenNow(routeId)) return;
    if (attempt >= 8) {
        ApolloLog(@"[SettingsRouter] Gave up opening route '%@'", routeId);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSettingsRouteOpenWithRetry(routeId, attempt + 1);
    });
}

void ApolloSettingsRouteOpen(NSString *routeId) {
    if (!ApolloSettingsRouteExists(routeId)) {
        ApolloLog(@"[SettingsRouter] Unknown route '%@'", routeId);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSettingsRouteOpenWithRetry(routeId, 0);
    });
}

