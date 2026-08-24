// ApolloComposerToolbarTint.xm — keep the markdown composer's quick-bar icons on
// the theme accent.
//
// The bar above the keyboard in every composer (new comment, reply, new post,
// chat/modmail) is Apollo's `QuickBarKeyboardView`: seven icon buttons — photo,
// link, bold, italics, subreddit, user, more — plus the GIF chip this tweak
// injects (ApolloMarkdownToolbarGif).
//
// Apollo tints those seven from its own stock-theme accent table: one Swift
// method reads the live `ThemeManager.appColorTheme` byte, builds that theme's
// accent hex, and pushes it onto each button with -setTintColor:. Nothing else
// re-tints them afterwards, so whenever that read disagrees with the accent the
// rest of the app is drawing — a custom theme whose donor hijack hasn't reached
// the live byte, a toolbar built before the theme settled — the icons keep the
// stock DEFAULT accent (#007AFF light / #2399FF dark) while everything around
// them is themed. That is the reported bug: every icon stuck "Apollo blue" next
// to a correctly-themed GIF chip, which is tweak-drawn and therefore already
// sources ApolloThemeAccentColor().
//
// Rather than chase Apollo's read back into sync, the tweak takes ownership of
// this bar's tint and drives it from the same accent seam every other
// tweak-drawn surface uses. On a stock theme that is a no-op by construction
// (kStockThemes in ApolloThemeRuntime was recovered from the very table Apollo
// consults, so the two agree colour-for-colour); on a custom theme it pins the
// icons to the custom accent; and in the broken state it repairs them.

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

// The icon buttons are the only UIButtons in the bar that render a UIImageView:
// the injected GIF chip draws a bordered UIView + UIButtonLabel, and the
// "Add Link" title button is label-only. Selecting on that structure therefore
// picks out exactly the seven native icons — no identifier lists to keep in
// sync, and the GIF chip stays owned by ApolloMarkdownToolbarGif (which also
// has to repaint its chip border, not just a tint).
static BOOL ApolloComposerToolbarIsIconButton(UIButton *button) {
    for (UIView *subview in button.subviews) {
        if ([subview isKindOfClass:[UIImageView class]]) return YES;
    }
    return NO;
}

static void ApolloComposerToolbarCollectIconButtons(UIView *view,
                                                    NSMutableArray<UIButton *> *out,
                                                    NSUInteger *budget) {
    if (!view || *budget == 0) return;
    // The autocomplete strip (subreddit/user suggestions) is a UICollectionView
    // whose cells Apollo styles on its own; never reach inside it.
    if ([view isKindOfClass:[UICollectionView class]]) return;
    (*budget)--;
    if ([view isKindOfClass:[UIButton class]] &&
        ApolloComposerToolbarIsIconButton((UIButton *)view)) {
        [out addObject:(UIButton *)view];
        return;
    }
    for (UIView *subview in view.subviews) {
        ApolloComposerToolbarCollectIconButtons(subview, out, budget);
        if (*budget == 0) return;
    }
}

// Both accent seams hand back *dynamic* provider colours that are freshly
// allocated on every call (see ApolloThemeRuntime.h), so pointer or -isEqual:
// comparison never matches even when the colour is semantically identical.
// Resolve both against the bar's traits and compare components instead.
static BOOL ApolloComposerToolbarColorsMatch(UIColor *lhs, UIColor *rhs, UITraitCollection *traits) {
    if (!lhs || !rhs) return NO;
    UIColor *a = [lhs resolvedColorWithTraitCollection:traits];
    UIColor *b = [rhs resolvedColorWithTraitCollection:traits];
    CGFloat ar = 0, ag = 0, ab = 0, aa = 0, br = 0, bg = 0, bb = 0, ba = 0;
    if (![a getRed:&ar green:&ag blue:&ab alpha:&aa]) return NO;
    if (![b getRed:&br green:&bg blue:&bb alpha:&ba]) return NO;
    const CGFloat epsilon = 1.0 / 512.0;
    return fabs(ar - br) < epsilon && fabs(ag - bg) < epsilon &&
           fabs(ab - bb) < epsilon && fabs(aa - ba) < epsilon;
}

static void ApolloComposerToolbarApplyAccent(UIView *toolbar, NSString *reason) {
    if (!toolbar.window) return;

    UIColor *accent = ApolloThemeAccentColor();
    // nil means neither a custom theme nor a recognised stock theme could be
    // resolved. Apollo's own tint is then the best information available —
    // leave it alone rather than forcing a guess onto the bar.
    if (!accent) return;

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    NSUInteger budget = 256;
    ApolloComposerToolbarCollectIconButtons(toolbar, buttons, &budget);
    if (buttons.count == 0) return;

    // Apollo sets all seven in one pass, so the first button's tint tells us
    // whether the bar is already correct. Checking the live tint rather than a
    // cached stamp keeps this self-healing: if Apollo ever re-applies its own
    // (stale) accent, the next layout pass notices and repairs it.
    UITraitCollection *traits = toolbar.traitCollection;
    if (ApolloComposerToolbarColorsMatch(buttons.firstObject.tintColor, accent, traits)) return;

    for (UIButton *button in buttons) button.tintColor = accent;

    UIColor *resolved = [accent resolvedColorWithTraitCollection:traits];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [resolved getRed:&r green:&g blue:&b alpha:&a];
    ApolloLog(@"[ComposerToolbarTint] retinted %lu icon buttons to #%02X%02X%02X (%@)",
              (unsigned long)buttons.count,
              (unsigned)lround(r * 255.0), (unsigned)lround(g * 255.0), (unsigned)lround(b * 255.0),
              reason);
}

%hook _TtC6Apollo20QuickBarKeyboardView

// The bar is an inputAccessoryView, so UIKit re-parents it into the keyboard's
// own window when the composer's editor becomes first responder. A freshly built
// bar has no buttons yet at that point (the walk finds none), but one being
// re-parented for a second composer already does — catching those here retints
// them before the first layout instead of a frame later.
- (void)didMoveToWindow {
    %orig;
    ApolloComposerToolbarApplyAccent((UIView *)self, @"didMoveToWindow");
}

// This is the pass that actually retints: the buttons exist and Apollo has
// tinted them by the time the bar lays out. It also covers a theme switched
// while a composer is open and a light/dark flip. tintColor is not an Auto
// Layout input, so writing it here cannot drive layout; the match check above
// makes the steady-state pass a couple of colour resolutions.
- (void)layoutSubviews {
    %orig;
    ApolloComposerToolbarApplyAccent((UIView *)self, @"layoutSubviews");
}

%end
