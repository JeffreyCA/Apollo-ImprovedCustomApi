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

// Select the active app window deterministically. ApolloAllWindows() spans every
// connected scene, so a hidden normal-level window from an inactive scene must
// not win merely because it happened to be enumerated first.
static UIWindow *ApolloAHActiveWindow(void) {
    UIWindow *normalFallback = nil;
    for (UIWindow *w in ApolloAllWindows()) {
        if (![w isKindOfClass:[UIWindow class]] || w.isHidden || w.alpha <= 0.01 || !w.rootViewController) continue;
        if (w.windowLevel != UIWindowLevelNormal) continue;
        if (w.isKeyWindow) return w;
        if (!normalFallback) normalFallback = w;
    }
    return normalFallback;
}

// Collect every visible leaf in the active container hierarchy. A split view is
// different from a navigation/tab container: both columns can be visible, and
// on iPad the feed commonly remains in the primary column while comments occupy
// the secondary. Presented controllers still replace the underlying hierarchy,
// preserving the Settings-screen behavior described below.
static void ApolloAHCollectVisibleLeaves(UIViewController *vc,
                                         NSMutableArray<UIViewController *> *leaves,
                                         NSUInteger depth) {
    if (!vc || depth >= 16) return;
    if (vc.presentedViewController) {
        ApolloAHCollectVisibleLeaves(vc.presentedViewController, leaves, depth + 1);
        return;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        ApolloAHCollectVisibleLeaves([(UINavigationController *)vc visibleViewController], leaves, depth + 1);
        return;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        ApolloAHCollectVisibleLeaves([(UITabBarController *)vc selectedViewController], leaves, depth + 1);
        return;
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *column in [(UISplitViewController *)vc viewControllers]) {
            ApolloAHCollectVisibleLeaves(column, leaves, depth + 1);
        }
        return;
    }
    [leaves addObject:vc];
}

static NSArray<UIViewController *> *ApolloAHVisibleLeaves(void) {
    UIWindow *window = ApolloAHActiveWindow();
    if (!window) return @[];
    NSMutableArray<UIViewController *> *leaves = [NSMutableArray array];
    ApolloAHCollectVisibleLeaves(window.rootViewController, leaves, 0);
    return leaves;
}

// Decode the `currentPostsType` enum's leading Swift String payload (the subreddit
// slug for the `.subreddit(name)` case) and return YES if it names the Popular or
// All meta-feed. The PostsType case tag is checked before touching the payload:
// several non-subreddit cases also begin with a Swift String, so decoding bytes
// without tag 0 could mistake a multireddit or username named "all" for r/all.
// Only small Swift strings (<=15 bytes) are needed for these two slugs.
static BOOL ApolloAHTypeIsMetaFeed(id postsVC) {
    if (!postsVC) return NO;
    Ivar iv = class_getInstanceVariable([postsVC class], "currentPostsType");
    if (!iv) return NO;
    ptrdiff_t ivarOffset = ivar_getOffset(iv);
    static const ptrdiff_t kApolloPostsTypeTagOffset = 0x20;
    static const uint8_t kApolloPostsTypeSubreddit = 0;
    if (ivarOffset < 0 || (size_t)ivarOffset + kApolloPostsTypeTagOffset >= class_getInstanceSize([postsVC class])) {
        return NO;
    }

    const uint8_t *base = (const uint8_t *)(__bridge void *)postsVC + ivarOffset;
    uint8_t tag = 0xFF;
    memcpy(&tag, base + kApolloPostsTypeTagOffset, sizeof(tag));
    if (tag != kApolloPostsTypeSubreddit) return NO;

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

// Is a visible feed currently the Popular or All meta-feed? On phones this is a
// single leaf; on iPad both split columns are inspected so a primary-column feed
// is not lost behind a secondary comments controller. A presented Settings screen
// replaces the underlying hierarchy, so its toggle still reads the stored value.
static BOOL ApolloAHOnMetaFeed(void) {
    Class postsClass = objc_getClass("_TtC6Apollo19PostsViewController");
    if (!postsClass) return NO;
    for (UIViewController *leaf in ApolloAHVisibleLeaves()) {
        if ([leaf isKindOfClass:postsClass] && ApolloAHTypeIsMetaFeed(leaf)) return YES;
    }
    return NO;
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
