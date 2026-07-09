#import "ApolloMediaAutoplay.h"
#import "ApolloCommon.h"
#import "ApolloMediaMetadata.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Apollo's native General > Autoplay GIFs/Videos preference. Followed only when the
// tweak's Autoplay Inline GIFs setting is in Default mode.
static NSString *const kApolloNativeAutoplayGIFsKey = @"AutoplayGIFs";
static NSString *const kApolloGroupSuiteName = @"group.com.christianselig.apollo";

static const void *kApolloInlineAnimatedGIFViewKey = &kApolloInlineAnimatedGIFViewKey;
static const void *kApolloInlineGIFUserForcedPlayViewKey = &kApolloInlineGIFUserForcedPlayViewKey;
static const void *kApolloNativeInlineGIFNodeKey = &kApolloNativeInlineGIFNodeKey;

static SCNetworkReachabilityRef sReachability = NULL;
static NSHashTable *sInlineGIFNodes = nil;
static NSString *sLastLoggedAutoplayMode = nil;
static BOOL sCachedShouldPlayValid = NO;
static BOOL sCachedShouldPlay = NO;
static BOOL sAutoplayRefreshStateValid = NO;
static BOOL sAutoplayRefreshLastShouldPlay = NO;
static NSString *sAutoplayRefreshLastMode = nil;

static void ApolloInvalidateAutoplayCache(void) {
    sCachedShouldPlayValid = NO;
    sLastLoggedAutoplayMode = nil;
}

static void ApolloStartReachabilityMonitor(void);
static BOOL ApolloNetworkIsOnWiFi(void);
static BOOL ApolloNetworkIsOnCellular(void);
static void ApolloLogAutoplayDecision(NSString *mode, BOOL shouldPlay);
static void ApolloReloadAutoplayInlineGIFModeFromDefaults(void);
static NSString *ApolloNativeAutoplayGIFModeString(void);

static Class ApolloASNetworkImageNodeClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"ASNetworkImageNode");
    });
    return cls;
}

BOOL ApolloInlineGIFNodeIsRegistryEligible(id imageNode) {
    if (!imageNode || imageNode == (id)[NSNull null]) return NO;
    // Native inline animated nodes (giphy-picker embeds, snoomoji) are gated in
    // place — they only need liveness introspection, not the URL-reload API.
    if (ApolloNodeIsNativeInlineGIF(imageNode)) {
        return [imageNode respondsToSelector:@selector(isNodeLoaded)] &&
               [imageNode respondsToSelector:@selector(supernode)];
    }
    Class cls = ApolloASNetworkImageNodeClass();
    if (!cls || ![imageNode isKindOfClass:cls]) return NO;
    // Deliberately no -clearImage requirement: Apollo's AsyncDisplayKit build
    // doesn't implement it, and requiring it left this registry permanently
    // empty — settings changes never paused or resumed any on-screen GIF.
    if (![imageNode respondsToSelector:@selector(setURL:)]) return NO;
    if (![imageNode respondsToSelector:@selector(URL)]) return NO;
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)]) return NO;
    if (![imageNode respondsToSelector:@selector(supernode)]) return NO;
    return YES;
}

void ApolloFlagNativeInlineGIFNode(id imageNode) {
    if (!imageNode) return;
    objc_setAssociatedObject(imageNode, kApolloNativeInlineGIFNodeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloNodeIsNativeInlineGIF(id imageNode) {
    if (!imageNode) return NO;
    return [objc_getAssociatedObject(imageNode, kApolloNativeInlineGIFNodeKey) boolValue];
}

// Stops/starts a native inline animated node in place. Covers both Texture
// animation pipelines: an FLAnimatedImageView subview (gated through the
// FLAnimatedImageView hooks once the node view is marked) and Texture's own
// animated-image display (toggled via animatedImagePaused).
BOOL ApolloApplyNativeInlineGIFAutoplayGate(id imageNode) {
    if (!ApolloNodeIsNativeInlineGIF(imageNode)) return NO;
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)] ||
        !((BOOL (*)(id, SEL))objc_msgSend)(imageNode, @selector(isNodeLoaded))) {
        return NO;
    }
    BOOL shouldPlay = ApolloShouldAutoplayInlineGIFCached();
    @try {
        UIView *view = nil;
        if ([imageNode respondsToSelector:@selector(view)]) {
            view = ((UIView *(*)(id, SEL))objc_msgSend)(imageNode, @selector(view));
        }
        if (!view) return NO;
        ApolloMarkViewAsInlineGIF(view);
        UIView *animView = ApolloFindFLAnimatedImageViewInView(view);
        if (animView) {
            ApolloApplyFLAnimatedImageViewAutoplayGate(animView);
        }
        if ([imageNode respondsToSelector:@selector(setAnimatedImagePaused:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(imageNode, @selector(setAnimatedImagePaused:), !shouldPlay);
        }
    } @catch (NSException *exception) {
        ApolloLog(@"[AutoplayGIF] native gate failed node=%p class=%@ reason=%@",
                  imageNode, NSStringFromClass([imageNode class]), exception.reason);
        ApolloUnregisterInlineGIFNode(imageNode);
        return NO;
    }
    return YES;
}

static void ApolloAutoplaySettingsDidChange(void) {
    ApolloReloadAutoplayInlineGIFModeFromDefaults();
    ApolloRefreshVisibleInlineGIFAutoplay();
}

@interface ApolloAutoplayDefaultsObserver : NSObject
@end

@implementation ApolloAutoplayDefaultsObserver

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    (void)object;
    (void)change;
    (void)context;
    if ([keyPath isEqualToString:UDKeyAutoplayInlineGIFs] ||
        [keyPath isEqualToString:kApolloNativeAutoplayGIFsKey]) {
        ApolloAutoplaySettingsDidChange();
    }
}

@end

static ApolloAutoplayDefaultsObserver *sAutoplayDefaultsObserver = nil;

static void ApolloInstallAutoplayDefaultsKVO(NSUserDefaults *defaults, NSString *keyPath) {
    if (!defaults || !sAutoplayDefaultsObserver) return;
    @try {
        [defaults addObserver:sAutoplayDefaultsObserver
                   forKeyPath:keyPath
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
    } @catch (__unused NSException *exception) {
        ApolloLog(@"[AutoplayGIF] KVO unavailable for defaults key=%@", keyPath);
    }
}

static BOOL ApolloComputeShouldAutoplayInlineGIF(NSString **outMode) {
    if (@available(iOS 9.0, *)) {
        if ([NSProcessInfo processInfo].isLowPowerModeEnabled) {
            if (outMode) *outMode = @"lpm";
            return NO;
        }
    }

    ApolloStartReachabilityMonitor();

    NSString *mode = ApolloAutoplayGIFModeString();
    BOOL shouldPlay = NO;

    if ([mode isEqualToString:@"never"] || [mode isEqualToString:@"tap-to-play"]) {
        shouldPlay = NO;
    } else if ([mode isEqualToString:@"only-on-wifi"]) {
        shouldPlay = ApolloNetworkIsOnWiFi();
    } else if ([mode isEqualToString:@"always"]) {
        shouldPlay = YES;
    }

    if (outMode) *outMode = mode;
    return shouldPlay;
}

static BOOL ApolloNetworkIsOnWiFi(void) {
    if (!sReachability) return NO;
    SCNetworkReachabilityFlags flags = 0;
    if (!SCNetworkReachabilityGetFlags(sReachability, &flags)) return NO;
    if (!(flags & kSCNetworkReachabilityFlagsReachable)) return NO;
    if (flags & kSCNetworkReachabilityFlagsIsWWAN) return NO;
    return YES;
}

static BOOL ApolloNetworkIsOnCellular(void) {
    if (!sReachability) return NO;
    SCNetworkReachabilityFlags flags = 0;
    if (!SCNetworkReachabilityGetFlags(sReachability, &flags)) return NO;
    return (flags & kSCNetworkReachabilityFlagsReachable) && (flags & kSCNetworkReachabilityFlagsIsWWAN);
}

static void ApolloReachabilityCallback(__unused SCNetworkReachabilityRef target,
                                       __unused SCNetworkReachabilityFlags flags,
                                       __unused void *info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloRefreshVisibleInlineGIFAutoplay();
    });
}

static void ApolloStartReachabilityMonitor(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sReachability = SCNetworkReachabilityCreateWithName(NULL, "apple.com");
        if (!sReachability) return;
        SCNetworkReachabilityContext ctx = {0, NULL, NULL, NULL, NULL};
        SCNetworkReachabilitySetCallback(sReachability, ApolloReachabilityCallback, &ctx);
        SCNetworkReachabilityScheduleWithRunLoop(sReachability, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    });
}

NSInteger ApolloResolveLegacyDefaultAutoplayGIFMode(void) {
    NSString *native = ApolloNativeAutoplayGIFModeString();
    if ([native isEqualToString:@"always"]) return ApolloAutoplayInlineGIFModeAlways;
    if ([native isEqualToString:@"only-on-wifi"] || [native containsString:@"wifi"]) {
        return ApolloAutoplayInlineGIFModeWiFiOnly;
    }
    return ApolloAutoplayInlineGIFModeNever;
}

// Reloads and validates the inline-GIF autoplay mode from user defaults into the
// shared sAutoplayInlineGIFMode global. Called on KVO changes so external/defaults-
// driven edits are reflected even when the settings UI isn't the writer. Legacy
// Default (0) / out-of-range values (e.g. a restored old backup) resolve to the
// explicit equivalent of Apollo's native setting and are persisted so the
// migration happens once.
static void ApolloReloadAutoplayInlineGIFModeFromDefaults(void) {
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:UDKeyAutoplayInlineGIFs];
    if (mode < ApolloAutoplayInlineGIFModeNever || mode > ApolloAutoplayInlineGIFModeTapToPlay) {
        mode = ApolloResolveLegacyDefaultAutoplayGIFMode();
        // Persisting re-fires this KVO handler once; the stored value is
        // valid on the second pass so it terminates immediately.
        [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:UDKeyAutoplayInlineGIFs];
    }
    sAutoplayInlineGIFMode = mode;
}

// Reads Apollo's native Autoplay GIFs/Videos preference (standard, then group defaults),
// normalized to never / only-on-wifi / always. Falls back to "never" when unset.
static NSString *ApolloNativeAutoplayGIFModeString(void) {
    for (NSUserDefaults *defaults in @[[NSUserDefaults standardUserDefaults],
                                       [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuiteName]]) {
        id value = [defaults objectForKey:kApolloNativeAutoplayGIFsKey];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return [(NSString *)value lowercaseString];
        }
    }
    return @"never";
}

NSString *ApolloAutoplayGIFModeString(void) {
    switch (sAutoplayInlineGIFMode) {
        case ApolloAutoplayInlineGIFModeNever:     return @"never";
        case ApolloAutoplayInlineGIFModeTapToPlay: return @"tap-to-play";
        case ApolloAutoplayInlineGIFModeWiFiOnly:  return @"only-on-wifi";
        case ApolloAutoplayInlineGIFModeAlways:    return @"always";
        case ApolloAutoplayInlineGIFModeDefault:
        default:                                   return ApolloNativeAutoplayGIFModeString();
    }
}

// Zero-address (default-route) reachability, the exact predicate behind Apollo's
// [Reachability reachabilityForInternetConnection]. Unlike the hostname-based
// sReachability above, zero-address flags resolve synchronously from the routing
// table (no DNS), so the first query is already accurate.
static SCNetworkReachabilityRef ApolloZeroAddressReachability(void) {
    static SCNetworkReachabilityRef ref = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct sockaddr_in zeroAddress;
        memset(&zeroAddress, 0, sizeof(zeroAddress));
        zeroAddress.sin_len = sizeof(zeroAddress);
        zeroAddress.sin_family = AF_INET;
        ref = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zeroAddress);
    });
    return ref;
}

// Mirrors Apollo's decision in RichMediaNode's video setup (sub_10057c93c) and
// the preload-adopt helper (sub_100582a0c): both read AutoplayGIFs from STANDARD
// defaults only, treat nil as "always", switch over always/never/only-on-wifi
// (anything else falls through to the wifi-only check), and for wifi-only show
// the static poster iff currentReachabilityStatus == ReachableViaWWAN (2).
BOOL ApolloNativeAutoplayEffectivelyOff(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:kApolloNativeAutoplayGIFsKey];
    NSString *mode = [value isKindOfClass:[NSString class]] ? [(NSString *)value lowercaseString] : nil;
    if (mode.length == 0) return NO;                    // unset: Apollo autoplays
    if ([mode isEqualToString:@"always"]) return NO;
    if ([mode isEqualToString:@"never"]) return YES;
    // "only-on-wifi" (or unrecognized): off only on cellular. Reachable-but-WWAN
    // is Apollo's ReachableViaWWAN; not-reachable takes Apollo's autoplay path.
    SCNetworkReachabilityRef reachability = ApolloZeroAddressReachability();
    if (!reachability) return NO;
    SCNetworkReachabilityFlags flags = 0;
    if (!SCNetworkReachabilityGetFlags(reachability, &flags)) return NO;
    return (flags & kSCNetworkReachabilityFlagsReachable) && (flags & kSCNetworkReachabilityFlagsIsWWAN);
}

// Whether a paused inline GIF should carry a play-button overlay for inline
// tap-to-play. Tap to Play mode always wants it; WiFi Only wants it while
// blocked (cellular). Never mode is a pure static cover — tapping falls
// through to the normal image tap (media viewer).
BOOL ApolloPausedInlineGIFWantsPlayOverlay(void) {
    NSString *mode = ApolloAutoplayGIFModeString();
    if ([mode isEqualToString:@"tap-to-play"]) return YES;
    if ([mode isEqualToString:@"only-on-wifi"]) return !ApolloShouldAutoplayInlineGIFCached();
    return NO;
}

static void ApolloLogAutoplayDecision(NSString *mode, BOOL shouldPlay) {
    NSString *signature = [NSString stringWithFormat:@"%@|%d", mode ?: @"", shouldPlay];
    if ([signature isEqualToString:sLastLoggedAutoplayMode]) return;
    sLastLoggedAutoplayMode = [signature copy];

    BOOL lpm = NO;
    if (@available(iOS 9.0, *)) {
        lpm = [NSProcessInfo processInfo].isLowPowerModeEnabled;
    }
    ApolloLog(@"[AutoplayGIF] mode=%@ shouldPlay=%d lpm=%d wifi=%d cellular=%d",
              mode ?: @"unknown",
              shouldPlay,
              lpm,
              ApolloNetworkIsOnWiFi(),
              ApolloNetworkIsOnCellular());
}

BOOL ApolloShouldAutoplayInlineGIFCached(void) {
    if (!sCachedShouldPlayValid) {
        NSString *mode = nil;
        sCachedShouldPlay = ApolloComputeShouldAutoplayInlineGIF(&mode);
        sCachedShouldPlayValid = YES;
        ApolloLogAutoplayDecision(mode, sCachedShouldPlay);
    }
    return sCachedShouldPlay;
}

BOOL ApolloShouldAutoplayInlineGIF(void) {
    return ApolloShouldAutoplayInlineGIFCached();
}

void ApolloMarkViewAsInlineGIF(UIView *view) {
    if (!view) return;
    objc_setAssociatedObject(view, kApolloInlineAnimatedGIFViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL ApolloViewIsInlineGIF(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([objc_getAssociatedObject(cursor, kApolloInlineAnimatedGIFViewKey) boolValue]) {
            return YES;
        }
    }
    return NO;
}

void ApolloSetInlineGIFUserForcedPlay(UIView *view, BOOL forced) {
    if (!view) return;
    if (forced) {
        objc_setAssociatedObject(view, kApolloInlineGIFUserForcedPlayViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(view, kApolloInlineGIFUserForcedPlayViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

BOOL ApolloInlineGIFViewShouldAutoplay(UIView *view) {
    if (!ApolloViewIsInlineGIF(view)) return YES;
    if ([objc_getAssociatedObject(view, kApolloInlineGIFUserForcedPlayViewKey) boolValue]) return YES;
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([objc_getAssociatedObject(cursor, kApolloInlineGIFUserForcedPlayViewKey) boolValue]) {
            return YES;
        }
    }
    return ApolloShouldAutoplayInlineGIFCached();
}

static Ivar ApolloFLShouldAnimateIvar(void) {
    static Ivar ivar = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ivar = class_getInstanceVariable(objc_getClass("FLAnimatedImageView"), "_shouldAnimate");
    });
    return ivar;
}

static Class ApolloFLAnimatedImageViewClass(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("FLAnimatedImageView");
    });
    return cls;
}

static void ApolloSetFLAnimatedImageViewShouldAnimate(UIView *view, BOOL shouldAnimate) {
    if (!view) return;
    Ivar ivar = ApolloFLShouldAnimateIvar();
    if (!ivar) return;
    BOOL *slot = (BOOL *)((uint8_t *)(__bridge void *)view + ivar_getOffset(ivar));
    *slot = shouldAnimate;
}

void ApolloApplyFLAnimatedImageViewAutoplayGate(UIView *view) {
    Class cls = ApolloFLAnimatedImageViewClass();
    if (!view || !cls || ![view isKindOfClass:cls]) return;
    if (!ApolloViewIsInlineGIF(view)) return;

    BOOL shouldPlay = ApolloInlineGIFViewShouldAutoplay(view);
    ApolloSetFLAnimatedImageViewShouldAnimate(view, shouldPlay);
    if (shouldPlay) {
        [(id)view performSelector:@selector(startAnimating)];
    } else {
        [(id)view performSelector:@selector(stopAnimating)];
    }
}

UIView *ApolloFindFLAnimatedImageViewInView(UIView *view) {
    if (!view) return nil;
    Class cls = ApolloFLAnimatedImageViewClass();
    if (cls && [view isKindOfClass:cls]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = ApolloFindFLAnimatedImageViewInView(sub);
        if (found) return found;
    }
    return nil;
}

BOOL ApolloURLLooksLikeAnimatedGIF(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    NSString *ext = url.path.pathExtension.lowercaseString ?: @"";
    if ([ext isEqualToString:@"gif"] || [ext isEqualToString:@"gifv"]) return YES;

    static NSSet<NSString *> *animatedHosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        animatedHosts = [NSSet setWithObjects:
            @"giphy.com", @"media.giphy.com", @"tenor.com", @"media.tenor.com",
            @"redgifs.com", @"gfycat.com", nil];
    });
    for (NSString *parent in animatedHosts) {
        if ([host isEqualToString:parent] || [host hasSuffix:[@"." stringByAppendingString:parent]]) {
            return YES;
        }
    }
    if ([host isEqualToString:@"i.redd.it"] || [host hasSuffix:@".redd.it"]) {
        return [ext isEqualToString:@"gif"];
    }
    return NO;
}

static BOOL ApolloURLStringMatchesEntrySource(NSString *candidate, NSURL *url) {
    if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0 || !url) return NO;
    NSString *decoded = [candidate stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    if ([decoded isEqualToString:url.absoluteString]) return YES;
    NSURL *candidateURL = [NSURL URLWithString:decoded];
    if (candidateURL.path.length > 0 && url.path.length > 0 &&
        [candidateURL.path isEqualToString:url.path]) {
        return YES;
    }
    return NO;
}

static NSString *ApolloMediaMetadataIDFromURL(NSURL *videoURL) {
    NSString *host = videoURL.host.lowercaseString ?: @"";
    NSString *path = videoURL.path ?: @"";
    if ([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"]) {
        NSArray<NSString *> *comps = [path componentsSeparatedByString:@"/"];
        if (comps.count >= 6 && [comps[1] isEqualToString:@"link"] && [comps[3] isEqualToString:@"video"]) {
            return comps[4];
        }
        return nil;
    }
    return [[videoURL lastPathComponent] stringByDeletingPathExtension];
}

NSURL *ApolloInlineGIFDisplayURLFromMetadata(NSURL *url, NSDictionary *mediaMetadata) {
    if (![url isKindOfClass:[NSURL class]] || ![mediaMetadata isKindOfClass:[NSDictionary class]] || mediaMetadata.count == 0) {
        return nil;
    }

    BOOL preferMP4 = (sPreferredGIFFallbackFormat != 0);

    for (NSString *key in mediaMetadata) {
        if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
        NSDictionary *entry = mediaMetadata[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;

        BOOL isGIFEntry = [[entry objectForKey:@"e"] isEqualToString:@"AnimatedImage"]
            || ApolloMetadataEntryIsRedditHostedGIF(key, entry);
        if (!isGIFEntry) continue;

        NSDictionary *source = [entry[@"s"] isKindOfClass:[NSDictionary class]] ? entry[@"s"] : nil;
        BOOL matches = NO;
        if (source) {
            for (NSString *sourceKey in @[@"gif", @"mp4", @"u"]) {
                if (ApolloURLStringMatchesEntrySource(source[sourceKey], url)) {
                    matches = YES;
                    break;
                }
            }
        }
        if (!matches) {
            NSString *assetID = ApolloMediaMetadataIDFromURL(url);
            if (assetID.length > 0 && [assetID isEqualToString:key]) {
                matches = YES;
            }
        }
        if (!matches) continue;

        if (ApolloMetadataEntryIsRedditHostedGIF(key, entry)) {
            NSString *redditGIF = ApolloRedditHostedGIFDisplayURL(key);
            if (redditGIF.length > 0) return [NSURL URLWithString:redditGIF];
        }

        NSString *display = ApolloMediaDisplayURLFromMetadataEntry(key, entry, preferMP4);
        if (display.length == 0) continue;
        return [NSURL URLWithString:display];
    }
    return nil;
}

void ApolloRegisterInlineGIFNode(id imageNode) {
    if (!ApolloInlineGIFNodeIsRegistryEligible(imageNode)) {
        if (imageNode) {
            ApolloLog(@"[AutoplayGIF] register skipped ineligible class=%@", NSStringFromClass([imageNode class]));
        }
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sInlineGIFNodes = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (sInlineGIFNodes) {
        [sInlineGIFNodes addObject:imageNode];
    }
}

void ApolloUnregisterInlineGIFNode(id imageNode) {
    if (!imageNode || !sInlineGIFNodes) return;
    @synchronized (sInlineGIFNodes) {
        [sInlineGIFNodes removeObject:imageNode];
    }
}

static dispatch_block_t sDeferredAutoplayRefreshBlock = NULL;

void ApolloRefreshVisibleInlineGIFAutoplay(void) {
    BOOL previousShouldPlay = ApolloShouldAutoplayInlineGIFCached();
    NSString *previousMode = ApolloAutoplayGIFModeString();

    if (sDeferredAutoplayRefreshBlock) {
        dispatch_block_cancel(sDeferredAutoplayRefreshBlock);
        sDeferredAutoplayRefreshBlock = NULL;
    }

    ApolloInvalidateAutoplayCache();

    dispatch_block_t block = dispatch_block_create((dispatch_block_flags_t)0, ^{
        sDeferredAutoplayRefreshBlock = NULL;
        BOOL shouldPlay = ApolloShouldAutoplayInlineGIFCached();
        NSString *mode = ApolloAutoplayGIFModeString();

        if (sAutoplayRefreshStateValid &&
            sAutoplayRefreshLastShouldPlay == shouldPlay &&
            previousShouldPlay == shouldPlay &&
            ((sAutoplayRefreshLastMode == mode) || [sAutoplayRefreshLastMode isEqualToString:mode]) &&
            ((previousMode == mode) || [previousMode isEqualToString:mode])) {
            ApolloLog(@"[AutoplayGIF] refresh skipped unchanged mode=%@ shouldPlay=%d", mode, shouldPlay);
            return;
        }
        sAutoplayRefreshStateValid = YES;
        sAutoplayRefreshLastShouldPlay = shouldPlay;
        sAutoplayRefreshLastMode = [mode copy];

        NSHashTable *nodes = nil;
        @synchronized (sInlineGIFNodes) {
            nodes = [sInlineGIFNodes copy];
        }
        NSUInteger pauseCount = 0;
        NSUInteger reloadCount = 0;
        NSUInteger skipCount = 0;
        NSUInteger prunedCount = 0;
        for (id node in nodes.allObjects) {
            if (!node) continue;
            if (!ApolloInlineGIFNodeIsRegistryEligible(node)) {
                ApolloUnregisterInlineGIFNode(node);
                prunedCount++;
                continue;
            }
            if (ApolloNodeIsNativeInlineGIF(node)) {
                if (ApolloApplyNativeInlineGIFAutoplayGate(node)) {
                    if (shouldPlay) reloadCount++; else pauseCount++;
                } else {
                    skipCount++;
                }
                continue;
            }
            if (shouldPlay) {
                if (ApolloReloadInlineGIFImageNodeForAutoplay(node)) {
                    reloadCount++;
                } else {
                    skipCount++;
                }
            } else {
                if (ApolloPauseInlineGIFNodeForAutoplay(node)) {
                    pauseCount++;
                } else {
                    skipCount++;
                }
            }
        }
        ApolloLog(@"[AutoplayGIF] refresh mode=%@ nodes=%lu reload=%lu pause=%lu skip=%lu pruned=%lu shouldPlay=%d",
                  mode, (unsigned long)nodes.count, (unsigned long)reloadCount, (unsigned long)pauseCount, (unsigned long)skipCount, (unsigned long)prunedCount, shouldPlay);
    });
    sDeferredAutoplayRefreshBlock = block;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

void ApolloMediaAutoplayInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ApolloStartReachabilityMonitor();
        ApolloReloadAutoplayInlineGIFModeFromDefaults();
        sAutoplayDefaultsObserver = [ApolloAutoplayDefaultsObserver new];
        // Tweak setting (standard defaults) + Apollo's native setting (standard + group,
        // followed in Default mode).
        ApolloInstallAutoplayDefaultsKVO([NSUserDefaults standardUserDefaults], UDKeyAutoplayInlineGIFs);
        ApolloInstallAutoplayDefaultsKVO([NSUserDefaults standardUserDefaults], kApolloNativeAutoplayGIFsKey);
        ApolloInstallAutoplayDefaultsKVO([[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuiteName], kApolloNativeAutoplayGIFsKey);
        if (@available(iOS 9.0, *)) {
            [[NSNotificationCenter defaultCenter] addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *note) {
                ApolloRefreshVisibleInlineGIFAutoplay();
            }];
        }
    });
}
