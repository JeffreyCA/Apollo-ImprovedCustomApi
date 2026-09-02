// ApolloJumpBarSuggestionTint.xm
//
// Fixes #999: in the nav-title subreddit quick-switcher (Apollo's JumpBar), the
// inline autocomplete appends the completion to the title text field and
// SELECTS the appended range — iOS draws that selection highlight from the
// field's inherited tintColor. Under a near-white accent theme (e.g. the stock
// monochromatic themes) that renders as a solid white box over white text.
//
// Clamp only that case: when the field's effective tint resolves near-white,
// give the JumpBar's field a fixed legible selection tint (system blue — the
// stock look; also colors the caret, which stays legible on both grounds).
// Dark/colored accents pass through untouched.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

@interface _TtC6Apollo7JumpBar : UIControl
@end

static void ApolloJumpBarClampFieldTint(UIView *root, int depth) {
    if (depth > 3) return;
    for (UIView *sub in root.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            UIColor *tint = [sub.tintColor resolvedColorWithTraitCollection:sub.traitCollection];
            if (tint && ApolloColorIsLight(tint)) {
                sub.tintColor = [UIColor systemBlueColor];
            }
            continue;
        }
        ApolloJumpBarClampFieldTint(sub, depth + 1);
    }
}

%hook _TtC6Apollo7JumpBar

- (void)layoutSubviews {
    %orig;
    ApolloJumpBarClampFieldTint((UIView *)self, 0);
}

%end

%ctor {
    %init;
}
