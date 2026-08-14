#import "ApolloScrapeWebView.h"
#import "ApolloCommon.h"

// Bump the version suffix whenever kApolloScrapeBlockerRules changes — the
// compiled list is cached on disk by WKContentRuleListStore under this
// identifier, so a stale cache would otherwise keep serving the old rules.
static NSString *const kApolloScrapeBlockerID = @"ApolloScrapeBlocker-v1";

// Rules are deliberately conservative about what they DON'T touch: shreddit needs
// its own scripts, styles and XHR/fetch to hydrate before there is any DOM worth
// reading, and ApolloUserFlair's whole mechanism is a page-initiated fetch() to
// /svc/shreddit/…. So this blocks media, fonts, and known ad/measurement hosts —
// never reddit's own app JS/CSS, images, or service endpoints.
//
// Only "media" and "font" resource-types are used: both have been valid for many
// WebKit releases. An unknown resource-type fails the WHOLE list to compile,
// which would silently leave every scrape unblocked — not worth the extra saving.
//
// url-filter takes a RESTRICTED regex grammar, and a single unsupported pattern
// fails the entire list (not just its own rule), silently disabling all blocking.
// If "[ScrapeWeb] blocker compile FAILED" ever appears, find the culprit by
// compiling each rule on its own rather than guessing. Verified as supported
// here: `^`, `https?`, `([^/]+\.)?`, `[^.]*`, escaped dots. NOT supported:
// alternation inside a group, e.g. `criteo\.(com|net)`.
static NSString *const kApolloScrapeBlockerRules = @"["
    // The actual issue-#902 fix: a video that starts playing in a hidden web view
    // gets promoted into WebKit's fullscreen player, presented above the app.
    "{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"media\"]},\"action\":{\"type\":\"block\"}},"
    // Pure bandwidth in a view nobody looks at; nothing here reads layout.
    "{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"font\"]},\"action\":{\"type\":\"block\"}},"
    // Reddit's own ad + telemetry endpoints.
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?ads\\\\.reddit\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?alb\\\\.reddit\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?events\\\\.reddit\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://w3-reporting[^.]*\\\\.reddit\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://pixel\\\\.redditmedia\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    // Third-party ad networks / measurement vendors.
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?adzerk\\\\.net\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?doubleclick\\\\.net\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?googlesyndication\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?googleadservices\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?googletagmanager\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?google-analytics\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?amazon-adsystem\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?scorecardresearch\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?quantserve\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?moatads\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?adsafeprotected\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?doubleverify\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    // Two rules rather than criteo\.(com|net): WebKit's url-filter grammar rejects
    // alternation inside a group, and ONE bad regex fails the WHOLE list to
    // compile (verified — see the compile-failure log line below).
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?criteo\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?criteo\\\\.net\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?taboola\\\\.com\"},\"action\":{\"type\":\"block\"}},"
    "{\"trigger\":{\"url-filter\":\"^https?://([^/]+\\\\.)?outbrain\\\\.com\"},\"action\":{\"type\":\"block\"}}"
    "]";

// Main-thread only.
static WKContentRuleList *sBlocker;             // nil until compiled
static BOOL sBlockerFailed;                     // don't retry forever
static BOOL sCompileInFlight;
static NSMutableArray<void (^)(void)> *sWaiters;

static UIWindow *ApolloScrapeKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

// Real mobile Safari UA for this OS version. WKWebView's default UA is missing
// the trailing "Version/x ... Safari" token, which marks the request as an
// embedded web view and measurably raises Reddit's challenge rate.
static NSString *ApolloScrapeSafariUserAgent(void) {
    NSArray<NSString *> *parts = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
    NSString *major = parts.count > 0 ? parts[0] : @"18";
    NSString *minor = parts.count > 1 ? parts[1] : @"0";
    BOOL pad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    NSString *os = pad ? [NSString stringWithFormat:@"iPad; CPU OS %@_%@ like Mac OS X", major, minor]
                       : [NSString stringWithFormat:@"iPhone; CPU iPhone OS %@_%@ like Mac OS X", major, minor];
    return [NSString stringWithFormat:@"Mozilla/5.0 (%@) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@.%@ Mobile/15E148 Safari/604.1", os, major, minor];
}

CGRect ApolloScrapeWebViewFrame(void) {
    CGRect frame = ApolloScrapeKeyWindow().bounds;
    if (CGRectIsEmpty(frame)) frame = UIScreen.mainScreen.bounds;
    // Last resort: a plausible phone viewport, so shreddit still picks its mobile
    // breakpoint rather than hydrating against a zero-sized layout.
    if (CGRectIsEmpty(frame)) frame = CGRectMake(0, 0, 390, 844);
    return frame;
}

// Resolves the shared blocker, then runs `next` on the main queue. Concurrent
// callers during a compile all queue up behind the one in-flight compile.
static void ApolloScrapeBlockerResolve(void (^next)(void)) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloScrapeBlockerResolve(next); });
        return;
    }
    if (sBlocker || sBlockerFailed) { if (next) next(); return; }

    if (!sWaiters) sWaiters = [NSMutableArray array];
    if (next) [sWaiters addObject:[next copy]];
    if (sCompileInFlight) return;
    sCompileInFlight = YES;

    void (^drain)(void) = ^{
        sCompileInFlight = NO;
        NSArray *waiters = [sWaiters copy];
        [sWaiters removeAllObjects];
        for (void (^w)(void) in waiters) w();
    };

    WKContentRuleListStore *store = [WKContentRuleListStore defaultStore];
    if (!store) {
        ApolloLog(@"[ScrapeWeb] no WKContentRuleListStore — scrapes run unblocked");
        sBlockerFailed = YES;
        drain();
        return;
    }

    // Disk-cached from a previous launch in the common case; compiling is only
    // the first-run cost.
    [store lookUpContentRuleListForIdentifier:kApolloScrapeBlockerID
                            completionHandler:^(WKContentRuleList *found, NSError *lookupError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (found) {
                sBlocker = found;
                ApolloLog(@"[ScrapeWeb] ad/media blocker loaded from cache");
                drain();
                return;
            }
            [store compileContentRuleListForIdentifier:kApolloScrapeBlockerID
                                encodedContentRuleList:kApolloScrapeBlockerRules
                                     completionHandler:^(WKContentRuleList *list, NSError *compileError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (list) {
                        sBlocker = list;
                        ApolloLog(@"[ScrapeWeb] ad/media blocker compiled");
                    } else {
                        sBlockerFailed = YES;
                        ApolloLog(@"[ScrapeWeb] blocker compile FAILED (%@) — scrapes run unblocked",
                                  compileError.localizedDescription ?: @"unknown");
                    }
                    drain();
                });
            }];
        });
    }];
}

void ApolloScrapeWebViewPrewarmBlocker(void) {
    ApolloScrapeBlockerResolve(nil);
}

void ApolloScrapeWebViewCreate(WKWebViewConfiguration *config, void (^ready)(WKWebView *web)) {
    if (!ready) return;
    WKWebViewConfiguration *cfg = config ?: [[WKWebViewConfiguration alloc] init];
    ApolloScrapeBlockerResolve(^{
        if (sBlocker) {
            if (!cfg.userContentController) cfg.userContentController = [[WKUserContentController alloc] init];
            [cfg.userContentController addContentRuleList:sBlocker];
        }
        WKWebView *web = [[WKWebView alloc] initWithFrame:ApolloScrapeWebViewFrame() configuration:cfg];
        // Invisible and untouchable to the user, but attached — an unparented web
        // view reports document.visibilityState == "hidden", which Reddit's
        // reCAPTCHA interstitial treats as a bot and never clears. The rule-list
        // blocker (no media can load) is what keeps #902 fixed with the view in
        // the window.
        web.alpha = 0.011;
        web.userInteractionEnabled = NO;
        web.customUserAgent = ApolloScrapeSafariUserAgent();
        UIWindow *win = ApolloScrapeKeyWindow();
        if (win) [win insertSubview:web atIndex:0];
        ready(web);
    });
}

void ApolloScrapeWebViewDestroy(WKWebView *web) {
    if (!web) return;
    web.navigationDelegate = nil;
    [web stopLoading];
    [web removeFromSuperview];
}

WKWebsiteDataStore *ApolloScrapeWebViewSharedDataStore(void) {
    static WKWebsiteDataStore *store; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 17.0, *)) {
            // Fixed identifier → the same on-disk store every launch. Cookies that
            // already passed Reddit's checks keep future scrapes unchallenged,
            // instead of every launch starting cookie-less at maximum suspicion.
            NSUUID *ident = [[NSUUID alloc] initWithUUIDString:@"C4A9B7D2-3E61-4F0A-9B5C-8D2F7E1A6035"];
            if (ident) store = [WKWebsiteDataStore dataStoreForIdentifier:ident];
        }
        if (!store) store = [WKWebsiteDataStore nonPersistentDataStore];
    });
    return store;
}
