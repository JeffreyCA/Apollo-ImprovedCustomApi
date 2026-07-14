#import <Foundation/Foundation.h>

#import "ApolloCommon.h"

// =============================================================================
// MARK: - Overview
// =============================================================================
//
// Fix: RedGifs link posts whose URL uses a modern subdomain — most commonly
// `v3.redgifs.com` (RedGifs' current web host), and any future `vN.`/CDN host —
// are not recognized as RedGifs media by Apollo. Instead of an inline video
// player they render as a dead link-preview card ("Link to v3.redgifs.com" /
// a static poster with "Watch this GIF on RedGIFs.com…"). See issue #79.
//
// Root cause (reverse-engineered in Hopper): every RedGifs-detecting code path —
// the central media-type classifier, the feed/comments-header thumbnail
// resolvers, MediaPageViewController, MediaViewerController, and the rich-push
// NotificationService — builds ONE host-recognition regex, constructed fresh at
// each call site through a shared Swift NSRegularExpression wrapper. That regex
// (embedded in the app binary) is:
//
//   ^http(?:s)?://(?:www\.)?(?:(?:giant|fat|thumbs|zippy)\d*\.)?redgifs.com/
//     (?:(?:\w{2}|ifr|gifs/detail|watch)/)?(\w+)[\w-]*
//
// The subdomain portion only allows an optional `www.` plus a handful of legacy
// CDN hosts (giant/fat/thumbs/zippy). `v3.redgifs.com` matches none of them, so
// the URL fails the very first recognition step and the post is treated as a
// plain external link.
//
// Note this is ONLY a recognition gap. RedGifs URLs that DO match already play
// correctly as inline video WITH audio and a mute button: the classifier stores
// a `.gif(host: redgifs, id:)` case, and RedGIFsClient fetches the audio-bearing
// hd/sd MP4 from api.redgifs.com/v2/gifs/<id> (the OAuth handshake is already
// rewritten to /v2/auth/temporary in Tweak.xm). So the whole fix is: make the
// recognition regex accept any subdomain, and the existing (working) playback
// path handles the rest — no per-consumer hooks, and no dependency on which
// model/ivar a given code path read the URL from.
//
// Interception point: every one of those regexes is built via
// -[NSRegularExpression initWithPattern:options:error:], so hooking that single
// Foundation initializer and widening the RedGifs host pattern's subdomain group
// fixes all consumers at once. The hook fast-rejects every non-RedGifs pattern
// (the overwhelming majority) with one substring check, so it is a cheap no-op
// for unrelated regexes.
//
// =============================================================================

// The exact subdomain fragment Apollo's RedGifs host regex uses. Widening just
// this fragment — rather than substituting the whole pattern — keeps the change
// minimal and resilient to unrelated adjustments Apollo might make to the rest
// of the pattern in a future app version.
static NSString *const kApolloRedgifsWWWFragment = @"(?:www\\.)?";

// Replacement: zero-or-more arbitrary DNS labels. Matches bare `redgifs.com`,
// `www.`, `v3.`, `v4.`, and any future/CDN subdomain, while staying anchored to
// `…redgifs.com` (a lookalike host such as `notredgifs.com` or `redgifs.evil.com`
// still fails to match, exactly as before).
static NSString *const kApolloRedgifsAnySubdomain = @"(?:[\\w-]+\\.)*";

// Returns a widened copy of the RedGifs host-recognition pattern, or the input
// unchanged for every other pattern.
static NSString *ApolloWidenRedgifsPatternIfNeeded(NSString *pattern) {
    if (![pattern isKindOfClass:[NSString class]] || pattern.length == 0) return pattern;

    // Fast reject: only the RedGifs host recognizer is of interest.
    if ([pattern rangeOfString:@"redgifs" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return pattern;
    }
    // Only widen the specific host recognizer, identified by its `(?:www\.)?`
    // subdomain group. Any other redgifs-mentioning pattern is left untouched.
    NSRange wwwRange = [pattern rangeOfString:kApolloRedgifsWWWFragment];
    if (wwwRange.location == NSNotFound) {
        // The recognizer's shape changed (app update). Do nothing rather than
        // risk mangling it, but leave a breadcrumb so we notice.
        static dispatch_once_t warnOnce;
        dispatch_once(&warnOnce, ^{
            ApolloLog(@"[RedgifsSubdomain] RedGifs pattern present but '(?:www\\.)?' fragment "
                      @"not found — recognizer may have changed; leaving pattern unmodified: %@", pattern);
        });
        return pattern;
    }
    // Already widened (defensive; our replacement contains no `(?:www\.)?`).
    if ([pattern rangeOfString:kApolloRedgifsAnySubdomain].location != NSNotFound) {
        return pattern;
    }

    NSString *widened = [pattern stringByReplacingCharactersInRange:wwwRange
                                                         withString:kApolloRedgifsAnySubdomain];
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        ApolloLog(@"[RedgifsSubdomain] widened RedGifs host regex to accept any subdomain "
                  @"(e.g. v3.redgifs.com now plays inline)");
    });
    return widened;
}

%hook NSRegularExpression

- (instancetype)initWithPattern:(NSString *)pattern
                        options:(NSRegularExpressionOptions)options
                          error:(NSError **)error {
    NSString *widened = ApolloWidenRedgifsPatternIfNeeded(pattern);
    if (widened != pattern) {
        return %orig(widened, options, error);
    }
    return %orig;
}

%end

// =============================================================================
// MARK: - Constructor
// =============================================================================

%ctor {
    ApolloLog(@"[RedgifsSubdomain] ctor: NSRegularExpression host-regex hook installed");
}
