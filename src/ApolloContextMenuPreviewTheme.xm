// ApolloContextMenuPreviewTheme.xm
//
// Fixes Apollo-Reborn issue #810: long-pressing a post or comment flashes a
// wrong-appearance backdrop behind the lifted content (light/lavender on a dark
// theme — unreadable dark-theme text over it; pure black on a light theme).
//
// MECHANISM (confirmed against decompiled UIKitCore 23B85 + a live sim dump):
// UIKit's context-menu lift builds a _UIMorphingPlatterView whose clipping /
// transform views are painted with `UIPreviewParameters.backgroundColor`
// (see -[_UIMorphingPlatterView _installPreview:inClippingView:transformView:]).
// Apollo creates all its highlight previews with `-[UITargetedPreview
// initWithView:]`, i.e. with UIKit's DEFAULT parameters, whose background is
// `_UIPreviewParametersDefaultBackgroundColor()` == +[UIColor systemBackgroundColor]
// — a dynamic color created INSIDE UIKitCore (so the theme runtime's
// caller-gated semantic accessor override deliberately never remaps it).
// The platter then resolves that dynamic color against the menu container's
// trait environment, which follows the SYSTEM appearance, not the Apollo
// theme: a dark Apollo theme on a light-mode device gets a light platter
// behind the lifted (transparent) text portal, so the text region "flashes"
// light with dark-theme text colors on top.
//
// FIX (two classes, both anchored on the SOURCE view's trait collection —
// the platter's own trait environment follows the SYSTEM appearance, not the
// Apollo theme):
//  1. Params still carrying the untouched UIKit default (tagged at init /
//     recognized as the systemBackground dynamic color / nil): stamp the
//     theme card color resolved via the source view's traits.
//  2. Params carrying an EXPLICIT theme color resolved under the wrong
//     appearance — Apollo's preview builders resolve theme backgrounds
//     through ambient traits, so a dark theme on a light-mode device gets a
//     light-variant platter (the #810 screenshot: lavender light-variant
//     panel behind dark-variant text). ApolloThemeRuntimeReresolveColor
//     recognizes theme token values and swaps in the correct variant.
// Non-theme explicit backgrounds (e.g. clear platters for accessory morphs)
// pass through untouched.
//
// Not gated on Liquid Glass or iOS version: the systemBackground platter
// default exists on every iOS this tweak supports, and a theme-matched
// platter is the correct look everywhere (on stock light themes it resolves
// to the same near-white UIKit used anyway).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

// Tag: the backgroundColor object a UIPreviewParameters instance received from
// UIKit's default init, so "still the untouched default" is detectable later.
static char kApolloPreviewDefaultBGKey;

static BOOL sLoggedPreviewStamp = NO;

%hook UIPreviewParameters

- (instancetype)init {
    UIPreviewParameters *params = %orig;
    if (params && params.backgroundColor) {
        objc_setAssociatedObject(params, &kApolloPreviewDefaultBGKey,
                                 params.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return params;
}

- (instancetype)initWithTextLineRects:(NSArray *)rects {
    UIPreviewParameters *params = %orig;
    if (params && params.backgroundColor) {
        objc_setAssociatedObject(params, &kApolloPreviewDefaultBGKey,
                                 params.backgroundColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return params;
}

%end

%hook UITargetedPreview

// Designated initializer — the initWithView: / initWithView:parameters:
// conveniences and UIKit's internal preview builders all funnel through here
// (UITargetedPreview.m stores `parameters` by reference, so mutating before
// %orig is authoritative).
- (instancetype)initWithView:(UIView *)view parameters:(UIPreviewParameters *)parameters target:(id)target {
    if (view && parameters) {
        UIColor *defaultBG = objc_getAssociatedObject(parameters, &kApolloPreviewDefaultBGKey);
        UIColor *current = parameters.backgroundColor;
        // Untouched UIKit default: nil (some paths leave the property unset
        // and the platter substitutes the default at paint time), the exact
        // color object -init installed, or — because UIKit copies the params
        // before building the preview, losing the associated-object tag, and
        // pointer-comparing against our own +systemBackgroundColor call is
        // unreliable (the theme runtime's UIColor hooks can hand back a
        // different instance) — any UIDynamicSystemColor still NAMED
        // systemBackgroundColor. An explicit "no platter" is clearColor, not
        // nil, so nil is safe to claim; an explicit systemBackground request
        // gets the theme card color, which is what a themed app means by it
        // anyway.
        BOOL untouched = (current == nil) || (defaultBG && current == defaultBG);
        if (!untouched) {
            // "name = systemBackgroundColor" with the leading space-equals so
            // secondary/tertiarySystemBackgroundColor (substring collisions)
            // don't match.
            untouched = [NSStringFromClass(current.class) containsString:@"DynamicSystemColor"] &&
                        [current.description containsString:@"= systemBackgroundColor"];
        }
        if (untouched) {
            // Prefer the theme's card color (what post and comment text
            // actually sits on); keep the system default when the theme is
            // unknown. Either way resolve NOW against the source view's
            // traits — the platter's own trait environment can disagree
            // with the themed window (see header).
            UIColor *themed = ApolloThemeCardBackgroundColor() ?: [UIColor systemBackgroundColor];
            UIColor *resolved = [themed resolvedColorWithTraitCollection:view.traitCollection];
            if (resolved) {
                parameters.backgroundColor = resolved;
                if (!sLoggedPreviewStamp) {
                    sLoggedPreviewStamp = YES;
                    ApolloLog(@"[PreviewTheme] stamped default platter background %@ for %@",
                              resolved, NSStringFromClass(view.class));
                }
            }
        } else {
            // Explicitly-set background. Apollo's preview builders resolve the
            // theme background through ambient traits, which follow the SYSTEM
            // appearance — under a dark theme on a light-mode device (or vice
            // versa) the platter arrives carrying the WRONG variant's RGB (the
            // #810 "flash"). If the color is a theme token value, swap in the
            // variant matching the source view's actual traits. Non-theme
            // explicit colors (e.g. clearColor platters) pass through.
            UIColor *corrected = ApolloThemeRuntimeReresolveColor(current, view.traitCollection);
            if (corrected) {
                parameters.backgroundColor = corrected;
                ApolloLog(@"[PreviewTheme] corrected wrong-variant platter background for %@",
                          NSStringFromClass(view.class));
            }
        }
    }
    return %orig;
}

%end

%ctor {
    %init;
    ApolloLog(@"[PreviewTheme] module loaded");
}
