#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

// MARK: - Modmail conversation layout fixes for Liquid Glass (issue #525)
//
// Apollo's chat conversation screen is `PrivateMessageViewController`
// (a MessageKit `MessagesViewController` subclass). The SAME class backs both
// regular DMs and modmail conversations — modmail mode is identified by a
// non-nil `newModmailConversationID`.
//
// In modmail mode `viewWillAppear:` reaches up to the enclosing
// `ApolloTabBarController` and sets `themeAsModerator = YES`, deliberately
// KEEPING the (now green) tab bar on screen — unlike a DM, which hides the
// bottom bar. Pre-Liquid-Glass that opaque green tab bar sat cleanly below the
// compose bar. On iOS 26 Liquid Glass both the tab bar and the MessageKit input
// bar float as translucent pills, so they collide: the compose field overlaps
// the tab bar and the conversation gets translucent bleed at top and bottom.
//
// Fix (this file): for a modmail conversation under Liquid Glass, hide the
// bottom bar so the screen behaves like every other chat window — exactly what
// the issue asks for. We do this by overriding `hidesBottomBarWhenPushed` to
// return YES; UINavigationController reads it at push time, hides the tab bar
// for the conversation, and restores it automatically on pop back to the
// modmail inbox.
//
// Gated to Liquid Glass: the non-LG opaque tab bar has coexisted with modmail
// for years (the issue reports this as new in the LG build), so we leave that
// long-standing behavior untouched.
//
// Companion fix (in ApolloLiquidGlass.xm): the issue's second half — a too-tall,
// text-bleeding top band — was the chat's nav-bar scroll-edge blur landing at the
// bottom instead of the top. `FixScrollEdgeEffectInversion` was counter-inverting
// the effect host unconditionally, but Apollo 3.3.0's chat collection is upright
// (not scaleY=-1), so the flip pushed the top blur off-screen and conversation
// text bled up through the image-less Liquid Glass nav bar. That hook is now gated
// on the collection actually being inverted. See the note there for details.

@interface _TtC6Apollo28PrivateMessageViewController : UIViewController
@end

// Cached ivar offset of `newModmailConversationID` (a Swift `String?`). We do
// NOT try to materialize the Swift String — we only replicate Apollo's own
// runtime nil-check, which tests the second 8-byte word of the inline String
// struct (`*(self + offset + 8) != 0`; see -[PrivateMessageViewController
// viewWillAppear:] in the binary). That word is the String's owner/discriminator
// slot — zero only when the optional is `.none`. This mirrors the app's exact
// gate and avoids the Swift-struct-ivar pitfalls (see AGENTS.md).
static BOOL ApolloPMVCIsModmailConversation(UIViewController *vc) {
    if (!vc) return NO;
    static dispatch_once_t onceToken;
    static ptrdiff_t sConvIDOffset = -1;
    dispatch_once(&onceToken, ^{
        Class cls = objc_getClass("_TtC6Apollo28PrivateMessageViewController");
        if (cls) {
            Ivar iv = class_getInstanceVariable(cls, "newModmailConversationID");
            if (iv) sConvIDOffset = ivar_getOffset(iv);
        }
    });
    if (sConvIDOffset < 0) return NO;

    uintptr_t discriminator = *(uintptr_t *)((char *)(__bridge void *)vc + sConvIDOffset + sizeof(void *));
    return discriminator != 0;
}

%hook _TtC6Apollo28PrivateMessageViewController

// UINavigationController queries this during the push transition to decide
// whether to slide the tab bar away. Force YES for modmail under Liquid Glass.
- (BOOL)hidesBottomBarWhenPushed {
    if (IsLiquidGlass() && ApolloPMVCIsModmailConversation(self)) {
        return YES;
    }
    return %orig;
}

%end

%ctor {
    %init;
}
