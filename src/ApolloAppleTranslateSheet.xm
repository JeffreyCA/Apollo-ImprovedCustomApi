// ApolloAppleTranslateSheet
//
// Lets the user redirect Apollo's OWN Translate button (the native action-sheet
// item shown on comment/post long-press) to iOS's native Translate sheet
// instead of Apollo's built-in Google Translate web view.
//
// NOTE: unlike the headless TranslationSession API the bulk in-place pipeline
// uses (ApolloAppleTranslation.swift), this sheet is NOT guaranteed on-device.
// `.translationPresentation` may send the text to Apple's servers to translate
// by default — Apple's own sheet shows a one-time "will be sent to Apple"
// consent prompt for this — unless the user has turned on offline-only
// translation in the system Translate app's settings. Don't describe this
// setting as private/on-device in UI copy; see the Settings footer for the
// user-facing wording.
//
// How Apollo's Translate button works (confirmed in Hopper): it presents
// `_TtC6Apollo24TranslatorViewController`, whose `viewDidLoad` reads its
// `textToTranslate` Swift String ivar, builds a translate.google.com URL from it,
// and loads that into a WKWebView (`webView` ivar) inside a custom
// pan-to-dismiss presentation (TranslatorPresentationController/
// TranslatorAnimationController). There's no override point inside that flow —
// the URL construction and web load both happen in one Swift-compiled function
// (sub_100661c68 in the class-dump build) with no ObjC-visible seam.
//
// Instead we intercept one level up, at the PRESENTATION boundary: %hook
// UIViewController -presentViewController:animated:completion: (the same
// suppression pattern as ApolloHideSubscribePrompt.xm), detect that Apollo is
// about to present a TranslatorViewController, read its still-untranslated
// textToTranslate ivar off the not-yet-loaded instance, and — when the setting
// is on and the OS supports it — present Apple's native Translate sheet from the
// same presenter instead of letting Apollo's web view go up. Falls back to
// %orig (Apollo's own web view) whenever the Apple sheet isn't available, so
// this is always safe on older iOS.
//
// The actual sheet lives in ApolloAppleTranslateSheet.swift (Translation.framework
// has no ObjC surface — `.translationPresentation` is a SwiftUI-only modifier).
// This intentionally does NOT touch the separate bulk in-place translation
// pipeline (ApolloTranslation.xm) or its own Apple-backed provider
// (ApolloAppleTranslation.swift) — those already have their own on-device path;
// this file only concerns Apollo's own Translate action-sheet button.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

#import "ApolloCommon.h"
#import "ApolloState.h"

// Generated umbrella header for this module's Swift compilation units
// (ApolloAppleTranslation.swift, ApolloAppleTranslateSheet.swift), which vends
// the @objc ApolloAppleTranslateSheet class used below. Guarded with
// __has_include so this file still builds if Swift output isn't present yet.
#if __has_include("ApolloReborn-Swift.h")
#import "ApolloReborn-Swift.h"
#define APOLLO_HAS_APPLE_TRANSLATE_SHEET 1
#else
#define APOLLO_HAS_APPLE_TRANSLATE_SHEET 0
#endif

// Local copy of the small-Swift-string decoder, matching the copies already
// living independently in ApolloTranslation.xm and ApolloNativeActionMenus.xm —
// this codebase duplicates this helper per-file rather than sharing it.
// Strings <=15 bytes are packed inline across two registers/words; longer
// strings fall back to Swift's _bridgeToObjectiveC bridging thunk.
static NSString *ApolloAppleSheetDecodeSwiftString(uint64_t w0, uint64_t w1) {
    if (w1 == 0) return nil;

    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";

        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }

    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

    return sBridge ? sBridge(w0, w1) : nil;
}

// Reads TranslatorViewController's `textToTranslate` Swift String ivar directly
// off the not-yet-presented instance. Safe to call before -viewDidLoad runs:
// the ivar is set in -initWithCoder:/-initWithNibName:bundle: (Hopper confirms
// the class-dump-visible initializers take the text), well before viewDidLoad
// builds the Google Translate URL from it.
static NSString *ApolloTranslatorTextToTranslate(id translatorVC) {
    if (!translatorVC) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(translatorVC), "textToTranslate");
    if (!ivar) return nil;

    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *base = (uint8_t *)(__bridge void *)translatorVC;
    uint64_t w0 = *(uint64_t *)(base + offset);
    uint64_t w1 = *(uint64_t *)(base + offset + 0x08);
    return ApolloAppleSheetDecodeSwiftString(w0, w1);
}

%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent
                     animated:(BOOL)animated
                   completion:(void (^)(void))completion {
    if (sAppleTranslateSheet &&
        [viewControllerToPresent isKindOfClass:objc_getClass("_TtC6Apollo24TranslatorViewController")]) {
#if APOLLO_HAS_APPLE_TRANSLATE_SHEET
        NSString *text = ApolloTranslatorTextToTranslate(viewControllerToPresent);
        if (text.length > 0 && [ApolloAppleTranslateSheet isSupported] &&
            [ApolloAppleTranslateSheet present:text from:self]) {
            ApolloLog(@"[AppleTranslateSheet] Presented Apple's Translate sheet for %lu chars instead of Apollo's Google web view",
                       (unsigned long)text.length);
            // Honor the presentation contract: Apollo passes nil here, but a
            // future/other caller might not, and we're standing in for a real
            // presentation.
            if (completion) completion();
            return;
        }
        ApolloLog(@"[AppleTranslateSheet] Falling back to Apollo's Google Translate web view (unsupported OS, empty text, or a sheet is already up)");
#endif
    }
    %orig;
}

%end
