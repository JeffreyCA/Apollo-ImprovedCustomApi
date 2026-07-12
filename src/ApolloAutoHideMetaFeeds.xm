// ApolloAutoHideMetaFeeds.xm — makes "Auto Hide Read Posts" work on the Popular
// and All meta-feeds even when "Disable in Subreddits" is on (issue #641).
//
// Root cause (found via Hopper + live simulator instrumentation):
// Apollo models the feed you're viewing as a `PostsType` enum. The Home feed is
// its own case (`.home`), but the **Popular** and **All** meta-feeds are modelled
// as `.subreddit("Popular")` / `.subreddit("all")` — Reddit exposes them as the
// r/popular and r/all subreddits, and Apollo carries that through. Verified in the
// sim: on Popular, `PostsViewController.currentPostsType` is the subreddit case
// with payload "Popular", byte-identical in shape to a real subreddit like r/apple.
//
// When a post is marked read, Apollo's ReadPostsTracker only queues it for the
// server-side `api/hide` (so it stays gone across refreshes) when the feed is NOT
// "a subreddit you disabled auto-hide in". That gate reads the
// `DisableAutoHideReadPostsInSubreddits` default. Because Popular/All are typed as
// subreddits, turning "Disable in Subreddits" on ALSO silently disables auto-hide
// on Popular and All — even though those are main browsing feeds, not a specific
// subreddit you navigated into. Result: on Popular with "Disable in Subreddits"
// on, read posts are marked read but never hidden, so they come back on every
// refresh. That is exactly the reporter's setup and symptom.
//
// Confirmed empirically in the simulator:
//   • Popular + Disable-in-Subreddits ON  → readPostIDs grows, hide queue stays 0
//     (nothing ever hidden — the bug).
//   • Popular + Disable-in-Subreddits OFF → hide queue grows in lockstep (works).
//   • Home    + Disable-in-Subreddits ON  → hide queue grows (already fine, `.home`
//     isn't a subreddit).
//   • r/apple + Disable-in-Subreddits ON  → hide queue stays 0 (correct: a real
//     subreddit the user chose to exclude).
//
// Fix: "Disable in Subreddits" should only cover *actual* subreddits, not the
// Popular/All aggregate feeds (which behave like Home for this purpose). The gate
// reads the default with `-[NSUserDefaults boolForKey:]` on the main thread while
// the feed is visible (verified), so we intercept exactly that key: when the
// visible feed is the Popular or All meta-feed, report the toggle as OFF, so
// auto-hide behaves as it does on Home. Every other key, feed, and caller is
// untouched — real subreddits still honour the toggle, and the Settings switch
// (read while no feed is on top) still reflects the user's real choice.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ApolloCommon.h"

static NSString *const kApolloDisableInSubredditsKey = @"DisableAutoHideReadPostsInSubreddits";

// Walk to the visible leaf view controller of the key/normal window.
static UIViewController *ApolloAHVisibleLeaf(void) {
    for (UIWindow *w in ApolloAllWindows()) {
        if (!w.isKeyWindow && w.windowLevel != UIWindowLevelNormal) continue;
        UIViewController *vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        for (int i = 0; i < 12 && vc; i++) {
            if ([vc isKindOfClass:[UINavigationController class]]) {
                vc = [(UINavigationController *)vc topViewController]; continue;
            }
            if ([vc isKindOfClass:[UITabBarController class]]) {
                vc = [(UITabBarController *)vc selectedViewController]; continue;
            }
            if ([vc isKindOfClass:[UISplitViewController class]]) {
                vc = [(UISplitViewController *)vc viewControllers].lastObject ?: vc; continue;
            }
            break;
        }
        if (vc) return vc;
    }
    return nil;
}

// Decode the `currentPostsType` enum's leading Swift String payload (the subreddit
// slug for the `.subreddit(name)` case) and return YES if it names the Popular or
// All meta-feed. Only small Swift strings (<=15 bytes) are decoded — both "popular"
// and "all" are small, and non-subreddit cases (e.g. `.home`) hold no such string,
// so an exact case-insensitive match to "popular"/"all" cannot false-positive.
static BOOL ApolloAHTypeIsMetaFeed(id postsVC) {
    if (!postsVC) return NO;
    Ivar iv = class_getInstanceVariable(object_getClass(postsVC), "currentPostsType");
    if (!iv) return NO;
    const uint8_t *base = (const uint8_t *)(__bridge void *)postsVC + ivar_getOffset(iv);

    uint64_t w0 = 0, w1 = 0;
    memcpy(&w0, base, sizeof(w0));
    memcpy(&w1, base + 8, sizeof(w1));

    // Swift small-string: discriminator is the top byte of the second word; small
    // (immortal/inline) strings have the high nibble 0xE, with the low nibble the
    // length. Large strings (buffer-backed) can't be "popular"/"all", so bail.
    uint8_t disc = (uint8_t)(w1 >> 56);
    if ((disc & 0xF0) != 0xE0) return NO;
    NSUInteger len = disc & 0x0F;
    if (len == 0 || len > 15) return NO;

    uint8_t bytes[16];
    memcpy(bytes, &w0, 8);
    memcpy(bytes + 8, &w1, 7);            // low 7 bytes hold string bytes 8..14
    NSString *name = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    NSString *slug = name.lowercaseString;
    return [slug isEqualToString:@"popular"] || [slug isEqualToString:@"all"];
}

// Is the feed currently on screen the Popular or All meta-feed? Only the visible
// leaf is considered: posts are marked read on the feed that's actually on screen,
// and the gate is read on the main thread at that moment (verified), so the leaf
// is that feed. Keeping it to the visible leaf also means the Settings toggle —
// read while the Settings screen is on top, not a feed — always reflects the real
// stored value.
static BOOL ApolloAHOnMetaFeed(void) {
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    if (!postsClass) return NO;
    UIViewController *leaf = ApolloAHVisibleLeaf();
    return [leaf isKindOfClass:postsClass] && ApolloAHTypeIsMetaFeed(leaf);
}

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)key {
    BOOL orig = %orig;
    // Only touch the auto-hide subreddit gate, and only when the user actually
    // enabled it (orig == YES). Off the main thread we can't safely read UIKit, so
    // fall through to the real value.
    if (orig && [key isEqualToString:kApolloDisableInSubredditsKey] && [NSThread isMainThread]) {
        if (ApolloAHOnMetaFeed()) {
            // On Popular/All, behave as if the toggle were off so auto-hide runs
            // (these are aggregate feeds like Home, not a specific subreddit).
            return NO;
        }
    }
    return orig;
}

%end

%ctor {
    @autoreleasepool {
        %init;
        ApolloLog(@"[AutoHideMetaFeeds] Popular/All auto-hide gate fix installed");
    }
}
