// Sim-only dev helper: when the APOLLO_OPEN_ROUTE env var is set, open that
// settings route a few seconds after launch so screens can be screenshotted
// via `simctl io` without any UI taps. Compiled ONLY under APOLLO_SIM_BUILD
// (see the Makefile's sim-only file list), so it is never present in a device
// or release build — the env gate then makes it inert unless deliberately set.

#import <UIKit/UIKit.h>
#import "settings/ApolloSettingsRouter.h"
#import "ApolloCommon.h"

__attribute__((constructor))
static void ApolloSimOpenRouteInit(void) {
    const char *route = getenv("APOLLO_OPEN_ROUTE");
    if (!route || !route[0]) return;
    NSString *routeId = [NSString stringWithUTF8String:route];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ApolloLog(@"[SimOpenRoute] opening route %@", routeId);
        ApolloSettingsRouteOpen(routeId);
    });
}
