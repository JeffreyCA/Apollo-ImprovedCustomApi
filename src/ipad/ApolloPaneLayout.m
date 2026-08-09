// ApolloPaneLayout.m — see ApolloPaneLayout.h

#import "ApolloPaneLayout.h"
#import "ApolloPaneSplitViewController.h"
#import "../ApolloCommon.h"   // ApolloLog
#import "../ApolloState.h"    // sIPadPaneLayout

// Set once, from the main thread, during scene connect. Read from the main
// thread by every consumer. No synchronization needed and none implied — if a
// background reader ever appears, make this atomic rather than adding a lock
// around a single BOOL.
static BOOL sPaneLayoutActive = NO;

BOOL ApolloPaneLayoutSupported(void) {
    static BOOL supported = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    });
    return supported;
}

BOOL ApolloPaneLayoutEnabled(void) {
    return ApolloPaneLayoutSupported() && sIPadPaneLayout;
}

BOOL ApolloPaneLayoutActive(void) {
    return sPaneLayoutActive;
}

void ApolloPaneLayoutSetActive(BOOL active) {
    if (sPaneLayoutActive == active) return;
    sPaneLayoutActive = active;
    ApolloLog(@"[PaneLayout] active=%d (supported=%d enabled=%d)",
              active, ApolloPaneLayoutSupported(), ApolloPaneLayoutEnabled());
}

UISplitViewController *ApolloPaneSplitControllerFor(UIViewController *viewController) {
    if (!sPaneLayoutActive) return nil;

    // Walk parents rather than `splitViewController`: UIKit's property only
    // reports an ancestor split controller when the receiver is one of its
    // direct children or inside its columns' navigation stacks, and it can
    // also report a split controller we did NOT install (Apollo embeds none
    // today, but a future one would silently match). Matching on our own class
    // keeps the answer unambiguous.
    for (UIViewController *node = viewController; node != nil; node = node.parentViewController) {
        if ([node isKindOfClass:[ApolloPaneSplitViewController class]]) {
            return (UISplitViewController *)node;
        }
    }
    return nil;
}
