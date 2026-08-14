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

CGRect ApolloScrapeWebViewFrame(void) {
    CGRect frame = CGRectZero;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { frame = w.bounds; break; }
        }
        if (!CGRectIsEmpty(frame)) break;
    }
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
        // Belt and braces only — with no window these have nothing to act on. They
        // matter if someone ever re-attaches one of these views by accident.
        web.alpha = 0.011;
        web.userInteractionEnabled = NO;
        ready(web);
    });
}
