// ApolloOpenInFix.m
//
// Injected into Apollo's bundled "Open in Apollo" Action extension
// (OpenInUIExtension.appex, principal ObjC class ActionViewController).
//
// Why this exists
// ---------------
// The stock -[ActionViewController openURL:] walks the UIResponder chain and
// calls the DEPRECATED single-arg -[UIApplication openURL:] via
// performSelector:withObject:. iOS 18+ force-fails that exact selector:
//   "BUG IN CLIENT OF UIKIT: The caller of UIApplication.openURL(_:) needs to
//    migrate to ... open(_:options:completionHandler:). Force returning false."
// so the bundled share action does nothing from any browser.
//
// What we do
// ----------
// Replace -[ActionViewController openURL:] and open the (already apollo://) URL
// via two NON-deprecated paths, in order:
//   A. responder chain -> real UIApplication -> openURL:options:completionHandler:
//      (reported still working on iOS 18 on Apple's own forums; the stock code
//       and the earlier local attempt never used this path)
//   B. -[NSExtensionContext openURL:completionHandler:] (the officially-blessed
//      extension API; the earlier local attempt used only this)
// Fall back to the original IMP if neither path is usable.
//
// This is a pure ObjC-runtime swizzle from a constructor -- ActionViewController
// is a plain ObjC class, so no Substrate/ElleKit is needed inside the extension.
//
// Logs under subsystem "apollofix" with an "[ApolloFix][OpenIn]" message prefix,
// mirroring the main tweak's ApolloLog (src/ApolloCommon.h) so a Console text
// filter on "ApolloFix" catches them. NOTE: these fire from the separate
// OpenInUIExtension process, not the Apollo app process.
//
// NOTE: this is an unsupported runtime technique. It is confirmed on iOS 18 and
// must be validated on the target iOS (esp. iOS 26) on-device; the Shortcut /
// userscript / Safari-extension paths remain documented fallbacks.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>

static os_log_t OIFLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("apollofix", "openin"); });
    return log;
}

// Mirror the main tweak's ApolloLog convention (src/ApolloCommon.h): subsystem
// "apollofix" + an "[ApolloFix]" message prefix, logged as %{public}s at default
// level. The prefix matters: a Console text-filter on "ApolloFix" must catch
// these lines, and they fire from the separate OpenInUIExtension process.
#define OIFLOG(fmt, ...) do { \
    NSString *_m = [NSString stringWithFormat:@"[ApolloFix][OpenIn] " fmt, ##__VA_ARGS__]; \
    os_log_with_type(OIFLog(), OS_LOG_TYPE_DEFAULT, "%{public}s", _m.UTF8String); \
} while (0)

static IMP gOriginalOpenURL = NULL;

// Mark an NSExtensionContext as already-completed so we never call
// completeRequestReturningItems:completionHandler: twice (the second throws).
static const void *kOIFCompletedKey = &kOIFCompletedKey;

static id OIFExtensionContext(id controller) {
    if (![controller respondsToSelector:@selector(extensionContext)]) return nil;
    return [(UIViewController *)controller extensionContext];
}

// Dismiss the extension once the open has been handed off. Idempotent and
// exception-safe so it is harmless if the stock controller also completes.
static void OIFCompleteRequest(id context);

// Dismiss after a short grace period instead of immediately. Two reasons:
//   1) Avoids tearing the extension process down before the async open has been
//      handed off to the system (plan risk R9: dismissal racing the open).
//   2) Lets our os_log diagnostics flush to logd before the process is killed.
//      On the success path the open + completeRequest + teardown otherwise land
//      in the same millisecond, and the trailing os_log lines (which technique
//      fired, success=) are lost to the race — exactly what made the working
//      build look like the hook "never ran".
static void OIFCompleteRequestDeferred(id context) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ OIFCompleteRequest(context); });
}

static void OIFCompleteRequest(id context) {
    if (!context) return;
    @try {
        if (objc_getAssociatedObject(context, kOIFCompletedKey)) {
            OIFLOG(@"completeRequest skipped (already completed)");
            return;
        }
        objc_setAssociatedObject(context, kOIFCompletedKey, @YES, OBJC_ASSOCIATION_RETAIN);
        SEL sel = @selector(completeRequestReturningItems:completionHandler:);
        if ([context respondsToSelector:sel]) {
            void (*complete)(id, SEL, NSArray *, id) =
                (void (*)(id, SEL, NSArray *, id))objc_msgSend;
            complete(context, sel, @[], (id)nil);
            OIFLOG(@"extension request completed (dismissed)");
        }
    } @catch (NSException *e) {
        OIFLOG(@"completeRequest threw: %@", e);
    }
}

// Technique A: find the real UIApplication via the responder chain and open with
// the NON-deprecated openURL:options:completionHandler:. Returns YES if dispatched.
static BOOL OIFOpenViaApplication(id controller, NSURL *url) {
    Class UIApplicationClass = objc_getClass("UIApplication");
    if (!UIApplicationClass) return NO;

    UIApplication *app = nil;
    if ([controller isKindOfClass:[UIResponder class]]) {
        UIResponder *r = (UIResponder *)controller;
        while (r) {
            if ([r isKindOfClass:UIApplicationClass]) { app = (UIApplication *)r; break; }
            r = [r nextResponder];
        }
    }
    if (app) {
        OIFLOG(@"found UIApplication via responder chain");
    } else {
        // Usually nil inside an extension, but cheap to try + log.
        SEL sharedSel = @selector(sharedApplication);
        if ([UIApplicationClass respondsToSelector:sharedSel]) {
            id (*shared)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            app = shared(UIApplicationClass, sharedSel);
            if (app) OIFLOG(@"found UIApplication via +sharedApplication");
        }
    }

    SEL modern = @selector(openURL:options:completionHandler:);
    if (!app || ![app respondsToSelector:modern]) {
        OIFLOG(@"Technique A unavailable (no UIApplication in chain)");
        return NO;
    }

    id context = OIFExtensionContext(controller);
    OIFLOG(@"Technique A: opening %@ via UIApplication openURL:options:", url);
    void (*open)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) =
        (void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))objc_msgSend;
    open(app, modern, url, @{}, ^(BOOL success) {
        OIFLOG(@"Technique A open success=%d", success);
        OIFCompleteRequestDeferred(context);
    });
    return YES;
}

// Technique B: -[NSExtensionContext openURL:completionHandler:]. Returns YES if dispatched.
static BOOL OIFOpenViaExtensionContext(id controller, NSURL *url) {
    id context = OIFExtensionContext(controller);
    SEL sel = @selector(openURL:completionHandler:);
    if (!context || ![context respondsToSelector:sel]) {
        OIFLOG(@"Technique B unavailable (no usable extensionContext)");
        return NO;
    }

    OIFLOG(@"Technique B: opening %@ via NSExtensionContext", url);
    void (*open)(id, SEL, NSURL *, void (^)(BOOL)) =
        (void (*)(id, SEL, NSURL *, void (^)(BOOL)))objc_msgSend;
    open(context, sel, url, ^(BOOL success) {
        OIFLOG(@"Technique B open success=%d", success);
        OIFCompleteRequestDeferred(context);
    });
    return YES;
}

// Replacement for -[ActionViewController openURL:]. The controller hands us the
// already-converted apollo:// URL, so we just open it via the modern paths.
static void OIF_openURL(id self, SEL _cmd, NSURL *url) {
    OIFLOG(@"openURL: hooked, url=%@", url);
    @try {
        if ([url isKindOfClass:[NSURL class]]) {
            if (OIFOpenViaApplication(self, url)) return;
            if (OIFOpenViaExtensionContext(self, url)) return;
            OIFLOG(@"no usable open path; falling back to original openURL:");
        } else {
            OIFLOG(@"openURL: got non-NSURL; falling back to original");
        }
    } @catch (NSException *e) {
        OIFLOG(@"openURL: hook threw: %@; falling back", e);
    }
    if (gOriginalOpenURL) {
        ((void (*)(id, SEL, NSURL *))gOriginalOpenURL)(self, _cmd, url);
    }
}

__attribute__((constructor))
static void ApolloOpenInFixInit(void) {
    Class cls = objc_getClass("ActionViewController");
    if (!cls) {
        OIFLOG(@"ActionViewController not found; openURL: hook not installed");
        return;
    }
    Method m = class_getInstanceMethod(cls, @selector(openURL:));
    if (!m) {
        OIFLOG(@"openURL: not found on ActionViewController; hook not installed");
        return;
    }
    gOriginalOpenURL = method_getImplementation(m);
    method_setImplementation(m, (IMP)OIF_openURL);
    OIFLOG(@"Installed ActionViewController openURL: hook (Technique A primary, B fallback)");
}
