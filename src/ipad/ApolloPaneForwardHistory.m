// ApolloPaneForwardHistory.m

// Apollo's `poppedViewControllers` is a native Swift Array value, not an
// Objective-C object pointer. The runtime gives us its byte offset; a tiny
// Swift bridge performs the actual typed access so Swift owns its ABI and
// reference counting.

#import "ApolloPaneForwardHistory.h"
#import <objc/runtime.h>
#import "../ApolloCommon.h"

extern void ApolloSwiftClearViewControllerArray(void *storage);
extern NSUInteger ApolloSwiftViewControllerArrayCount(const void *storage);

BOOL ApolloPaneClearForwardHistory(UINavigationController *navigationController) {
    if (!navigationController) return NO;

    // UIKit navigation mutations are main-thread-only, and the Swift storage
    // contract below is intentionally pinned to Apollo's exact class rather
    // than inherited by an unknown future subclass with a different layout.
    Class apolloNavigationClass =
        objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!NSThread.isMainThread || !apolloNavigationClass ||
        navigationController.class != apolloNavigationClass) {
        ApolloLog(@"[PaneHistory] refused clear main=%d actual=%@ expected=%@",
                  NSThread.isMainThread,
                  NSStringFromClass(navigationController.class),
                  NSStringFromClass(apolloNavigationClass));
        return NO;
    }

    Ivar forwardHistoryIvar =
        class_getInstanceVariable(apolloNavigationClass, "poppedViewControllers");
    Ivar followingIvar =
        class_getInstanceVariable(apolloNavigationClass, "interactionController");
    ptrdiff_t forwardOffset = forwardHistoryIvar ? ivar_getOffset(forwardHistoryIvar) : -1;
    ptrdiff_t followingOffset = followingIvar ? ivar_getOffset(followingIvar) : -1;
    if (!forwardHistoryIvar || !followingIvar ||
        followingOffset - forwardOffset != (ptrdiff_t)sizeof(void *)) {
        ApolloLog(@"[PaneHistory] %@ forward ivar layout mismatch (%td -> %td); history unchanged",
                  NSStringFromClass(navigationController.class),
                  forwardOffset, followingOffset);
        return NO;
    }

    uint8_t *objectBytes = (uint8_t *)(__bridge void *)navigationController;
    void *storage = objectBytes + forwardOffset;
    NSUInteger before = ApolloSwiftViewControllerArrayCount(storage);
    if (before == 0) return YES;
    ApolloSwiftClearViewControllerArray(storage);
    NSUInteger after = ApolloSwiftViewControllerArrayCount(storage);
    ApolloLog(@"[PaneHistory] cleared %@ forward history %lu -> %lu",
              NSStringFromClass(navigationController.class),
              (unsigned long)before, (unsigned long)after);
    return after == 0;
}
