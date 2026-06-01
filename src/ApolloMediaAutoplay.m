#import "ApolloMediaAutoplay.h"
#import "ApolloCommon.h"
#import "ApolloMediaMetadata.h"
#import "ApolloState.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import <objc/runtime.h>

static NSString *const kApolloAutoplayGIFsKey = @"AutoplayGIFs";
static NSString *const kApolloGroupSuiteName = @"group.com.christianselig.apollo";

static const void *kApolloInlineAnimatedGIFViewKey = &kApolloInlineAnimatedGIFViewKey;
static const void *kApolloInlineGIFUserForcedPlayViewKey = &kApolloInlineGIFUserForcedPlayViewKey;

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
    Class cls = ApolloASNetworkImageNodeClass();
    if (!cls || ![imageNode isKindOfClass:cls]) return NO;
    if (![imageNode respondsToSelector:@selector(clearImage)]) return NO;
    if (![imageNode respondsToSelector:@selector(setURL:)]) return NO;
    if (![imageNode respondsToSelector:@selector(URL)]) return NO;
    if (![imageNode respondsToSelector:@selector(isNodeLoaded)]) return NO;
    if (![imageNode respondsToSelector:@selector(supernode)]) return NO;
    return YES;
}

static void ApolloAutoplaySettingsDidChange(void) {
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
    if ([keyPath isEqualToString:kApolloAutoplayGIFsKey]) {
        ApolloAutoplaySettingsDidChange();
    }
}

@end

static ApolloAutoplayDefaultsObserver *sAutoplayDefaultsObserver = nil;

static void ApolloInstallAutoplayDefaultsKVO(NSUserDefaults *defaults) {
    if (!defaults || !sAutoplayDefaultsObserver) return;
    @try {
        [defaults addObserver:sAutoplayDefaultsObserver
                   forKeyPath:kApolloAutoplayGIFsKey
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
    } @catch (__unused NSException *exception) {
        ApolloLog(@"[AutoplayGIF] KVO unavailable for defaults key=%@", kApolloAutoplayGIFsKey);
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

    if ([mode isEqualToString:@"never"]) {
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

static NSString *ApolloAutoplayGIFModeFromDefaults(NSUserDefaults *defaults) {
    if (!defaults) return nil;
    id value = [defaults objectForKey:kApolloAutoplayGIFsKey];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return [(NSString *)value lowercaseString];
    }
    return nil;
}

NSString *ApolloAutoplayGIFModeString(void) {
    NSString *mode = ApolloAutoplayGIFModeFromDefaults([NSUserDefaults standardUserDefaults]);
    if (mode.length == 0) {
        NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuiteName];
        mode = ApolloAutoplayGIFModeFromDefaults(groupDefaults);
    }
    if (mode.length == 0) {
        mode = @"never";
    }
    return mode;
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
        sAutoplayDefaultsObserver = [ApolloAutoplayDefaultsObserver new];
        ApolloInstallAutoplayDefaultsKVO([NSUserDefaults standardUserDefaults]);
        ApolloInstallAutoplayDefaultsKVO([[NSUserDefaults alloc] initWithSuiteName:kApolloGroupSuiteName]);
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
