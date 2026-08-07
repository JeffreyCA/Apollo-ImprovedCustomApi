// Hard-disable Apollo's embedded Bugsnag SDK (whose crash capture is a
// vendored KSCrash fork).
//
// The tweak has always firewalled Bugsnag's upload endpoints
// (notify.bugsnag.com / sessions.bugsnag.com in Tweak.xm's blockedUrls), but
// "cannot upload" is not "never starts": a started Bugsnag still installs
// mach-exception/signal handlers, breadcrumbs user activity to disk, and
// maintains persistent device/user UUIDs. This file makes "we disabled
// Apollo's telemetry" fully true — every Bugsnag start entry point becomes a
// no-op, so its recorder never installs and it never competes with the
// tweak's own KSCrash for process-level exception facilities (namespacing
// protects symbols, but only one system can own signal handlers).
//
// bugsnag-cocoa funnels +start and +startWithApiKey: through
// +startWithConfiguration:, but all three are hooked so a version skew in the
// embedded SDK can't reintroduce a live path. Returning nil from the
// (nominally nonnull) class methods is safe for Apollo's Swift callers:
// messaging nil is a no-op, and every later Bugsnag class-method call guards
// itself with the "Ensure you have started Bugsnag" error path by design.
//
// The tweak's own recorder (src/crash/ApolloCrashManager) installs in %ctor,
// long before Apollo's app code would have called Bugsnag.start — so there is
// no window where the two could both own crash handling.

#import <Foundation/Foundation.h>

#import "ApolloCommon.h"

%hook Bugsnag

+ (id)start {
    ApolloLog(@"[CrashCapture] blocked Bugsnag +start");
    return nil;
}

+ (id)startWithApiKey:(id)apiKey {
    ApolloLog(@"[CrashCapture] blocked Bugsnag +startWithApiKey:");
    return nil;
}

+ (id)startWithConfiguration:(id)configuration {
    ApolloLog(@"[CrashCapture] blocked Bugsnag +startWithConfiguration:");
    return nil;
}

%end

// Defense in depth: even a directly-constructed client must never arm itself.
%hook BugsnagClient

- (void)start {
    ApolloLog(@"[CrashCapture] blocked BugsnagClient -start");
}

%end
