#import <Foundation/Foundation.h>

#import "ApolloPushNotifications.h"

// Standalone unit tests for the pure push-registration helpers. Build & run with:
//
//   clang -fobjc-arc -framework Foundation \
//       -DAPOLLO_PUSH_NOTIFICATIONS_TESTING \
//       -I src \
//       src/ApolloPushNotifications.m tests/push_notifications_tests.m \
//       -o /tmp/push_notifications_tests && /tmp/push_notifications_tests
//
// APOLLO_PUSH_NOTIFICATIONS_TESTING compiles out the UIKit-dependent convenience
// wrapper, leaving only the pure, device-independent logic under test.

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

static void TestPlaceholderTokenIsDeterministicAndSized(void) {
    NSData *a1 = ApolloPlaceholderAPNSDeviceTokenForSeed(@"vendor-id-A");
    NSData *a2 = ApolloPlaceholderAPNSDeviceTokenForSeed(@"vendor-id-A");
    NSData *b = ApolloPlaceholderAPNSDeviceTokenForSeed(@"vendor-id-B");

    Require(a1.length == 32, @"token is 32 bytes (a 64-char hex APNs token)");
    Require([a1 isEqualToData:a2], @"the same seed always yields the same token");
    Require(![a1 isEqualToData:b], @"different seeds yield different tokens");
}

static void TestPlaceholderTokenHandlesEmptySeed(void) {
    NSData *empty = ApolloPlaceholderAPNSDeviceTokenForSeed(@"");
    NSData *nilSeed = ApolloPlaceholderAPNSDeviceTokenForSeed(nil);
    Require(empty.length == 32, @"empty seed still yields a 32-byte token");
    Require([empty isEqualToData:nilSeed], @"empty and nil seeds fall back to the same deterministic token");
}

int main(void) {
    @autoreleasepool {
        TestDetectsCanonicalEntitlementError();
        TestDetectsByDescriptionAcrossDomainChanges();
        TestDetectsWrappedUnderlyingError();
        TestIgnoresTransientErrors();
        TestPlaceholderTokenIsDeterministicAndSized();
        TestPlaceholderTokenHandlesEmptySeed();
        NSLog(@"push_notifications_tests passed");
    }
    return 0;
}
