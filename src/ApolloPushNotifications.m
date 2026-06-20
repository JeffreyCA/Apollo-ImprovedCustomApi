#import "ApolloPushNotifications.h"
#import <CommonCrypto/CommonDigest.h>

// `aps-environment` registration failures come back as NSCocoaErrorDomain 3000.
// Kept as named constants so the intent is obvious and the defensive fallback
// below documents why the literal string match also exists.
static NSString *const kApolloAPSEntitlementErrorDomain = @"NSCocoaErrorDomain";
static const NSInteger kApolloAPSEntitlementErrorCode = 3000;
static NSString *const kApolloAPSEntitlementMarker = @"aps-environment";

BOOL ApolloErrorIsMissingPushEntitlement(NSError *error) {
    if (![error isKindOfClass:[NSError class]]) {
        return NO;
    }

    // Canonical signature returned by iOS today.
    if ([error.domain isEqualToString:kApolloAPSEntitlementErrorDomain] &&
        error.code == kApolloAPSEntitlementErrorCode) {
        return YES;
    }

    // Defensive fallback: match the entitlement string itself, in case Apple
    // ever changes the domain/code. Covers the localized description directly.
    NSString *description = error.localizedDescription ?: @"";
    if ([description rangeOfString:kApolloAPSEntitlementMarker
                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    // …and any nested underlying error (guarding against self-referential
    // userInfo to avoid infinite recursion).
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]] && underlying != error) {
        return ApolloErrorIsMissingPushEntitlement(underlying);
    }

    return NO;
}

NSData *ApolloPlaceholderAPNSDeviceTokenForSeed(NSString *seed) {
    NSString *normalized = ([seed isKindOfClass:[NSString class]] && seed.length > 0)
        ? seed
        : @"apollo-reborn-placeholder-apns-seed";
    NSData *seedData = [normalized dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(seedData.bytes, (CC_LONG)seedData.length, digest);
    return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

#ifndef APOLLO_PUSH_NOTIFICATIONS_TESTING

#import <UIKit/UIKit.h>

// Persisted only when identifierForVendor is unavailable (e.g. before first
// device unlock), so the stand-in token stays stable across launches.
static NSString *const kApolloPlaceholderAPNSSeedDefaultsKey = @"ApolloPlaceholderAPNSDeviceSeed";

NSData *ApolloPlaceholderAPNSDeviceToken(void) {
    NSString *seed = [UIDevice currentDevice].identifierForVendor.UUIDString;
    if (seed.length == 0) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        seed = [defaults stringForKey:kApolloPlaceholderAPNSSeedDefaultsKey];
        if (seed.length == 0) {
            seed = [[NSUUID UUID] UUIDString];
            [defaults setObject:seed forKey:kApolloPlaceholderAPNSSeedDefaultsKey];
        }
    }
    return ApolloPlaceholderAPNSDeviceTokenForSeed(seed);
}

#endif
