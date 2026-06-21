#import <Foundation/Foundation.h>

#import "ApolloPushNotifications.h"

// Standalone unit tests for the pure push-notification helpers. Build & run with:
//
//   clang -fobjc-arc -framework Foundation \
//       -DAPOLLO_PUSH_NOTIFICATIONS_TESTING \
//       -I src \
//       src/ApolloPushNotifications.m tests/push_notifications_tests.m \
//       -o /tmp/push_notifications_tests && /tmp/push_notifications_tests
//
// APOLLO_PUSH_NOTIFICATIONS_TESTING compiles out the UIKit/Security-dependent
// pieces (the entitlement check and the "notifications unavailable" view),
// leaving only the pure, device-independent error classification under test.

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"PushNotificationsTestFailure" reason:message userInfo:nil];
    }
}

static void TestDetectsCanonicalEntitlementError(void) {
    NSError *canonical = [NSError errorWithDomain:NSCocoaErrorDomain
                                             code:3000
                                         userInfo:@{NSLocalizedDescriptionKey: @"no valid \"aps-environment\" entitlement string found for application"}];
    Require(ApolloErrorIsMissingPushEntitlement(canonical), @"NSCocoaErrorDomain/3000 is recognized");
}

static void TestDetectsByDescriptionAcrossDomainChanges(void) {
    NSError *future = [NSError errorWithDomain:@"SomeFutureAPNSDomain"
                                          code:42
                                      userInfo:@{NSLocalizedDescriptionKey: @"No valid aps-environment entitlement string found"}];
    Require(ApolloErrorIsMissingPushEntitlement(future), @"description fallback survives a domain/code change");
}

static void TestDetectsWrappedUnderlyingError(void) {
    NSError *canonical = [NSError errorWithDomain:NSCocoaErrorDomain
                                             code:3000
                                         userInfo:@{NSLocalizedDescriptionKey: @"no valid aps-environment entitlement"}];
    NSError *wrapped = [NSError errorWithDomain:@"OuterDomain"
                                           code:1
                                       userInfo:@{NSUnderlyingErrorKey: canonical}];
    Require(ApolloErrorIsMissingPushEntitlement(wrapped), @"underlying entitlement error is detected");
}

static void TestIgnoresTransientErrors(void) {
    NSError *offline = [NSError errorWithDomain:NSURLErrorDomain
                                           code:NSURLErrorNotConnectedToInternet
                                       userInfo:@{NSLocalizedDescriptionKey: @"The Internet connection appears to be offline."}];
    Require(!ApolloErrorIsMissingPushEntitlement(offline), @"transient network failure is not misclassified");
    Require(!ApolloErrorIsMissingPushEntitlement(nil), @"nil is not an entitlement error");
}

int main(void) {
    @autoreleasepool {
        TestDetectsCanonicalEntitlementError();
        TestDetectsByDescriptionAcrossDomainChanges();
        TestDetectsWrappedUnderlyingError();
        TestIgnoresTransientErrors();
        NSLog(@"push_notifications_tests passed");
    }
    return 0;
}
