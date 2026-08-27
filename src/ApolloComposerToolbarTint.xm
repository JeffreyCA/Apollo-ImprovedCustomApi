// ApolloComposerToolbarTint.xm — keep the markdown composer's quick-bar icons on
// the theme accent.
//
// The bar above the keyboard in every composer (new comment, reply, new post,
// chat/modmail) is Apollo's `QuickBarKeyboardView`: seven icon buttons — photo,
// link, bold, italics, subreddit, user, more — plus the GIF chip this tweak
// injects (ApolloMarkdownToolbarGif).
//
// Where the stale colour actually lives (revised after reproducing the bug in
// the sim with a signed-in settings backup): each icon button renders a
// TEMPLATE image inside a UIImageView, and Apollo sets an explicit tintColor
// on that IMAGE VIEW — observed stuck at Apollo classic blue (#0088FF, which
// is not any entry in the stock accent table). An explicit subview tint beats
// anything set on the button, so the glyph stays blue even while the BUTTON's
// own tintColor correctly carries the theme accent (inherited or set by
// Apollo's awakeFromNib pass, which setTintColor:s the seven buttons from its
// stock-theme table). That split is why the first version of this fix — which
// wrote and guarded the BUTTON tint only — shipped as a no-op: its guard read
// the button's already-correct tint, concluded the bar was fine, and never
// touched the image views that actually draw. The injected GIF chip is
// tweak-drawn (no UIImageView) and already sources ApolloThemeAccentColor(),
// which is why it stays correctly themed next to seven blue icons.
//
// So the tweak takes ownership of this bar's tint at BOTH levels — the icon
// buttons and their image views — and drives it from the same accent seam
// every other tweak-drawn surface uses. The guard compares the first icon
// IMAGE VIEW's effective tint (the colour that actually renders) against the
// accent, so the steady state is a couple of colour resolutions and the fix
// self-heals if Apollo ever re-stamps either level with a stale colour.

#import <UIKit/UIKit.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"

// The icon buttons are the only UIButtons in the bar that render a UIImageView:
// the injected GIF chip draws a bordered UIView + UIButtonLabel, and the
// "Add Link" title button is label-only. Selecting on that structure therefore
// picks out exactly the seven native icons — no identifier lists to keep in
// sync, and the GIF chip stays owned by ApolloMarkdownToolbarGif (which also
// has to repaint its chip border, not just a tint).
static UIImageView *ApolloComposerToolbarIconImageView(UIButton *button) {
    for (UIView *subview in button.subviews) {
        if ([subview isKindOfClass:[UIImageView class]]) return (UIImageView *)subview;
    }
    return nil;
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
        ApolloComposerToolbarIconImageView((UIButton *)view) != nil) {
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

    // Apollo stamps all seven icons in one pass, so the first icon's colour
    // tells us whether the bar is already correct. The colour that renders is
    // the IMAGE VIEW's effective tint (an explicit subview tint beats the
    // button's), so that is what the guard must read — reading the button's
    // tint here is exactly the bug that made the first version of this fix a
    // silent no-op. Checking the live tint rather than a cached stamp keeps
    // this self-healing: if Apollo ever re-applies its stale colour at either
    // level, the next layout pass notices and repairs it.
    UITraitCollection *traits = toolbar.traitCollection;
    UIImageView *firstIcon = ApolloComposerToolbarIconImageView(buttons.firstObject);
    if (ApolloComposerToolbarColorsMatch(firstIcon.tintColor, accent, traits)) return;

    for (UIButton *button in buttons) {
        button.tintColor = accent;
        // The image view's explicit tint is what the template glyph renders
        // with — overwrite it too, or the button-level accent stays invisible.
        for (UIView *subview in button.subviews) {
            if ([subview isKindOfClass:[UIImageView class]]) subview.tintColor = accent;
        }
    }

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
