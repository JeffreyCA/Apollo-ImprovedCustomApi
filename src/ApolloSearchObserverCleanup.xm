#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

@interface _UISearchBarTextFieldTokenCounter : NSObject
@end

static Ivar sTextStorageObservationIvar;

%group ApolloSearchObserverCleanup
%hook _UISearchBarTextFieldTokenCounter

- (void)dealloc {
    // UIKit leaves this main-queue observer registered after its text storage
    // is freed. ASDK can reuse that address and deadlock posting a text edit
    // while main waits for layout. Remove the exact token before UIKit frees
    // the storage; live search notifications keep their normal delivery.
    id observer = object_getIvar(self, sTextStorageObservationIvar);
    if (observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:observer];
    }
    %orig;
}

%end
%end

%ctor {
    if (@available(iOS 26.0, *)) {
        Class counterClass = objc_getClass("_UISearchBarTextFieldTokenCounter");
        Ivar observationIvar = class_getInstanceVariable(counterClass, "_textStorageObservation");
        const char *type = observationIvar ? ivar_getTypeEncoding(observationIvar) : NULL;
        if (!counterClass || !type || type[0] != '@') {
            ApolloLog(@"[SearchObserverCleanup] unsupported token-counter layout; skipping");
            return;
        }

        sTextStorageObservationIvar = observationIvar;
        %init(ApolloSearchObserverCleanup, _UISearchBarTextFieldTokenCounter = counterClass);
        ApolloLog(@"[SearchObserverCleanup] installed token-counter observer cleanup");
    }
}
