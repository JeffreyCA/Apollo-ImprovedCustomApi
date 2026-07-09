#import "ApolloPushNotifications.h"

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

#ifndef APOLLO_PUSH_NOTIFICATIONS_TESTING

#import <UIKit/UIKit.h>
#import <Security/Security.h>

// SecTaskCopyValueForEntitlement / SecTaskCreateFromSelf read the *current*
// process's code-signing entitlements. They ship in Security.framework but
// aren't in the public SDK headers, so declare the two symbols we need.
typedef struct __SecTask *ApolloSecTaskRef;
extern ApolloSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(ApolloSecTaskRef task,
                                                CFStringRef entitlement,
                                                CFErrorRef *error);

static BOOL sPushSupported = YES;
static NSString *sAPSEnvironment = nil;

static void ApolloReadPushEntitlementOnce(void) {
    // The answer is fixed at signing time, so compute it once.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ApolloSecTaskRef task = SecTaskCreateFromSelf(NULL);
        if (!task) {
            // Couldn't introspect entitlements — stay conservative and leave the
            // stock notifications screen untouched.
            return;
        }
        CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("aps-environment"), NULL);
        // Any non-null `aps-environment` value ("development" / "production")
        // means Apple granted the push entitlement and registration can succeed.
        sPushSupported = (value != NULL);
        if (value) {
            id obj = (__bridge_transfer id)value;
            if ([obj isKindOfClass:[NSString class]]) {
                sAPSEnvironment = obj;
            }
        }
        CFRelease(task);
    });
}

BOOL ApolloPushNotificationsSupported(void) {
    ApolloReadPushEntitlementOnce();
    return sPushSupported;
}

BOOL ApolloAPSEnvironmentIsDevelopment(void) {
    ApolloReadPushEntitlementOnce();
    return [sAPSEnvironment isEqualToString:@"development"];
}

// MARK: - "Notifications unavailable" screen

static UILabel *ApolloUnavailableLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

UIView *ApolloMakeNotificationsUnavailableView(void) {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    // Opaque so it fully hides the stock controls, and interactive so it
    // swallows every touch meant for the disabled page underneath.
    container.backgroundColor = [UIColor systemBackgroundColor];
    container.userInteractionEnabled = YES;

    UIImageSymbolConfiguration *iconConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:52.0 weight:UIImageSymbolWeightRegular];
    UIImageView *icon = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"bell.slash" withConfiguration:iconConfig]];
    icon.tintColor = [UIColor secondaryLabelColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *title = ApolloUnavailableLabel(
        @"Notifications Unavailable",
        [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2],
        [UIColor labelColor]);
    // Bold the title while keeping Dynamic Type scaling.
    UIFontDescriptor *boldDescriptor =
        [title.font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    if (boldDescriptor) {
        title.font = [UIFont fontWithDescriptor:boldDescriptor size:0.0];
    }

    UILabel *body = ApolloUnavailableLabel(
        @"This copy of Apollo was signed with a free Apple ID, which Apple doesn't grant the push notification entitlement. Push alerts, watchers, and inbox notifications can't be delivered to this build.",
        [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
        [UIColor secondaryLabelColor]);

    UILabel *footnote = ApolloUnavailableLabel(
        @"To get notifications on this build anyway, install the free Bark app from the App Store, copy its push URL (Server > right-click the key), and enable Bark Delivery in Settings > General > Custom API alongside your notification backend. Or install a build signed with a paid Apple Developer account.",
        [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote],
        [UIColor secondaryLabelColor]);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, body, footnote]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    [stack setCustomSpacing:20.0 afterView:icon];
    [stack setCustomSpacing:18.0 afterView:body];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];

    UILayoutGuide *safe = container.safeAreaLayoutGuide;
    NSLayoutConstraint *width = [stack.widthAnchor constraintLessThanOrEqualToConstant:360.0];
    NSLayoutConstraint *centerY = [stack.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor];
    // Keep the block from floating too low when the safe area is tall.
    centerY.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        centerY,
        width,
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:32.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-32.0],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:24.0],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-24.0],
    ]];

    return container;
}

#endif
