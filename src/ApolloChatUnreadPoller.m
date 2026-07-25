// Background unread poller for the modern Reddit Chat mailbox. See the header
// for the architecture summary. Data flow:
//
//   timer/kick -> eligibility gates -> bearer (token_v2, minted when stale)
//     -> GET matrix.redditspace.com/_matrix/client/v3/sync (filtered, ~2 KB)
//     -> ApolloModernChatPublishPolledStatus (badge/switcher UI updates)
//     -> Bark transition push (client-side, only when counts rise)

#import "ApolloChatUnreadPoller.h"
#import "ApolloBarkNotifications.h"
#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static const NSTimeInterval kChatPollDefaultInterval = 30.0;   // foreground cadence
static const NSTimeInterval kChatPollBearerSlack = 120.0;      // refresh token_v2 this close to expiry
static const NSTimeInterval kChatPollMintBackoff = 15.0 * 60.0;
static const NSTimeInterval kChatPollAuthBackoff = 30.0 * 60.0;
static const NSTimeInterval kChatPollServerBackoff = 5.0 * 60.0;
static const NSTimeInterval kChatPollRequestTimeout = 15.0;

// Matches the modern mailbox webview's Safari persona (ApolloDirectChatWeb.xm)
// so the token_v2 mint looks like the same browser session Reddit harvested.
static NSString *const kChatPollMintUserAgent =
    @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
    @"(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1";

// Minimal sync filter: one m.room.message per room for previews, no state, no
// ephemeral traffic. Reddit's com.reddit.* counters always ride at the top
// level regardless of the filter (verified live on full and `since` syncs).
static NSString *const kChatPollSyncFilter =
    @"{\"room\":{\"timeline\":{\"limit\":1,\"types\":[\"m.room.message\"]},"
    @"\"state\":{\"types\":[]},\"ephemeral\":{\"types\":[]},\"account_data\":{\"types\":[]}},"
    @"\"presence\":{\"types\":[]},\"account_data\":{\"types\":[]}}";

// All mutable poller state is confined to the main thread.
static NSTimer *sChatPollTimer = nil;
static BOOL sChatPollInFlight = NO;
static BOOL sChatPollPendingKick = NO;

static NSString *sChatPollBearer = nil;
static NSTimeInterval sChatPollBearerExpiry = 0;
static NSString *sChatPollRejectedBearer = nil; // last token the server 401'd — never re-adopt it
static NSString *sChatPollUsername = nil;      // owner of bearer/since/backoff state

static NSString *sChatPollSinceToken = nil;
static NSString *sChatPollSinceBase = nil;     // homeserver the since token belongs to

static NSTimeInterval sChatPollMintBlockedUntil = 0;
static NSTimeInterval sChatPollAuthBlockedUntil = 0;
static NSTimeInterval sChatPollServerBlockedUntil = 0;

#pragma mark - Small helpers

static NSString *ApolloChatPollCookieValue(NSString *cookieHeader, NSString *name) {
    if (cookieHeader.length == 0 || name.length == 0) return nil;
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSString *pair in [cookieHeader componentsSeparatedByString:@";"]) {
        NSString *trimmed = [pair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trimmed hasPrefix:prefix]) return [trimmed substringFromIndex:prefix.length];
    }
    return nil;
}

// token_v2 is a JWT; its payload carries the expiry. 0 when unparseable.
static NSTimeInterval ApolloChatPollJWTExpiry(NSString *jwt) {
    NSArray<NSString *> *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return 0;
    NSString *payload = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                         stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger remainder = payload.length % 4;
    if (remainder > 0) {
        payload = [payload stringByPaddingToLength:payload.length + (4 - remainder)
                                        withString:@"=" startingAtIndex:0];
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data) return 0;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return 0;
    id exp = json[@"exp"];
    return [exp respondsToSelector:@selector(doubleValue)] ? [exp doubleValue] : 0;
}

static NSString *ApolloChatPollHomeserverBase(void) {
    // Hidden debug override so the whole pipeline can be exercised against a
    // local mock homeserver in the simulator. Never set in normal use.
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyChatPollerHomeserverOverride];
    if ([override isKindOfClass:[NSString class]] && [override hasPrefix:@"http"]) return override;
    return @"https://matrix.redditspace.com";
}

static void ApolloChatPollResetPerAccountState(void) {
    sChatPollBearer = nil;
    sChatPollBearerExpiry = 0;
    sChatPollRejectedBearer = nil;
    sChatPollSinceToken = nil;
    sChatPollSinceBase = nil;
    sChatPollMintBlockedUntil = 0;
    sChatPollAuthBlockedUntil = 0;
    sChatPollServerBlockedUntil = 0;
}

#pragma mark - token_v2 bearer

// Reddit's edge only re-issues token_v2 for real browser page loads — a bare
// NSURLSession GET with the same cookies and headers comes back with no
// token_v2 at all (verified live; the TLS/client fingerprint is the
// discriminator, not the request contents). So mint the way the rest of the
// repo does: an offscreen WKWebView, seeded with the stored session cookies
// into an isolated non-persistent store (mirroring the modern-mailbox
// seeding), loads the homepage once; the rotated token_v2 lands in that
// store's cookie jar. The webview is never added to a window and is torn
// down as soon as the token (or timeout) arrives.
@interface ApolloChatPollWebMinter : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) void (^completion)(NSString *bearer);
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) NSInteger cookiePollsLeft;
@end

static NSMutableSet *ApolloChatPollActiveMinters(void) {
    static NSMutableSet *minters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ minters = [NSMutableSet set]; });
    return minters;
}

@implementation ApolloChatPollWebMinter

- (void)finishWithToken:(NSString *)token {
    if (self.done) return;
    self.done = YES;
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil;
    if (token.length > 0) {
        ApolloLog(@"[ChatPoller] Minted a fresh token_v2 for u/%@ (expires in %.0f min)",
                  self.username, (ApolloChatPollJWTExpiry(token) - [NSDate date].timeIntervalSince1970) / 60.0);
    } else {
        ApolloLog(@"[ChatPoller] token_v2 mint failed for u/%@ (no token after homepage load) — backing off %.0f min",
                  self.username, kChatPollMintBackoff / 60.0);
    }
    if (self.completion) self.completion(token.length > 0 ? token : nil);
    self.completion = nil;
    self.webView = nil;
    [ApolloChatPollActiveMinters() removeObject:self];
}

// The fresh token usually arrives on the main document response, but Reddit
// occasionally sets it a beat later; poll the isolated jar briefly.
- (void)checkCookieJar {
    if (self.done) return;
    __weak typeof(self) weakSelf = self;
    [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.done) return;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        for (NSHTTPCookie *cookie in cookies) {
            if (![cookie.name isEqualToString:@"token_v2"] || cookie.value.length == 0) continue;
            if (ApolloChatPollJWTExpiry(cookie.value) - now <= kChatPollBearerSlack) continue;
            [self finishWithToken:cookie.value];
            return;
        }
        if (--self.cookiePollsLeft <= 0) {
            [self finishWithToken:nil];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self checkCookieJar]; });
    }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self checkCookieJar];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithToken:nil];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    // Non-provisional failures can still have delivered the response headers
    // (and their Set-Cookie); give the jar checks a chance before giving up.
    [self checkCookieJar];
}

@end

static void ApolloChatPollMintBearer(NSString *username, NSString *cookieHeader,
                                     void (^completion)(NSString *bearer)) {
    // Under the debug homeserver override, mint against the mock too so the
    // whole poller pipeline (including this path) is testable offline.
    NSString *mintBase = [[NSUserDefaults standardUserDefaults] stringForKey:UDKeyChatPollerHomeserverOverride];
    if (![mintBase isKindOfClass:[NSString class]] || ![mintBase hasPrefix:@"http"]) {
        mintBase = @"https://www.reddit.com";
    }
    NSURL *mintURL = [NSURL URLWithString:[mintBase stringByAppendingString:@"/"]];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];

    ApolloChatPollWebMinter *minter = [ApolloChatPollWebMinter new];
    minter.username = username;
    minter.completion = completion;
    minter.cookiePollsLeft = 8;
    minter.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    minter.webView.navigationDelegate = minter;
    minter.webView.customUserAgent = kChatPollMintUserAgent;
    [ApolloChatPollActiveMinters() addObject:minter];

    // Seed the stored session into the isolated jar, minus the dead
    // token_v2 (Reddit reliably issues a fresh one for a session presenting
    // none). Mirrors ApolloSeedModernMailboxCookies.
    WKHTTPCookieStore *jar = config.websiteDataStore.httpCookieStore;
    NSMutableArray<NSHTTPCookie *> *seeds = [NSMutableArray array];
    for (NSString *pair in [cookieHeader componentsSeparatedByString:@"; "]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        NSString *name = [pair substringToIndex:eq.location];
        if ([name isEqualToString:@"token_v2"]) continue;
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: [pair substringFromIndex:eq.location + 1],
            NSHTTPCookieDomain: @".reddit.com",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
            NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:24 * 60 * 60],
        }];
        if (cookie) [seeds addObject:cookie];
    }
    __block NSUInteger remaining = seeds.count;
    void (^loadWhenSeeded)(void) = ^{
        [minter.webView loadRequest:[NSURLRequest requestWithURL:mintURL]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [minter finishWithToken:nil]; });
    };
    if (remaining == 0) {
        loadWhenSeeded();
        return;
    }
    for (NSHTTPCookie *cookie in seeds) {
        [jar setCookie:cookie completionHandler:^{
            if (--remaining == 0) loadWhenSeeded();
        }];
    }
}

// Resolve a usable bearer for `username`: cached, straight from the stored
// cookie when its token_v2 is still fresh, else minted. Main queue in and out.
static void ApolloChatPollObtainBearer(NSString *username, NSString *cookieHeader,
                                       void (^completion)(NSString *bearer)) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (sChatPollBearer.length > 0 && sChatPollBearerExpiry - now > kChatPollBearerSlack) {
        completion(sChatPollBearer);
        return;
    }
    NSString *stored = ApolloChatPollCookieValue(cookieHeader, @"token_v2");
    // A revoked token can carry a future exp — once the server rejects a
    // value, never re-adopt that same value from the stored snapshot, or
    // every tick would fire a doomed 401 for the whole backoff window.
    if (stored.length > 0 && ![stored isEqualToString:sChatPollRejectedBearer]) {
        NSTimeInterval expiry = ApolloChatPollJWTExpiry(stored);
        if (expiry - now > kChatPollBearerSlack) {
            sChatPollBearer = stored;
            sChatPollBearerExpiry = expiry;
            completion(stored);
            return;
        }
    }
    if (now < sChatPollMintBlockedUntil) {
        completion(nil);
        return;
    }
    ApolloChatPollMintBearer(username, cookieHeader, ^(NSString *bearer) {
        if (bearer.length > 0) {
            sChatPollBearer = bearer;
            sChatPollBearerExpiry = ApolloChatPollJWTExpiry(bearer);
        } else {
            sChatPollMintBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollMintBackoff;
            // Production fallback: the login module's silent re-harvest
            // refreshes the whole stored session from the persistent login
            // webview jar (its own cooldown + coalescing apply). On success
            // the store carries a fresh token_v2 and the next tick uses it.
            [ApolloWebSessionLoginViewController attemptSilentReharvestForUsername:username
                                                                        completion:^(BOOL success) {
                // Stale-owner guard: an account switch may have re-earned this
                // backoff for a DIFFERENT user while the re-harvest ran.
                if (!success || ![username isEqualToString:sChatPollUsername]) return;
                sChatPollMintBlockedUntil = 0;
                ApolloChatUnreadPollerKick();
            }];
        }
        completion(bearer.length > 0 ? bearer : nil);
    });
}

#pragma mark - Sync response parsing

static NSInteger ApolloChatPollCounter(NSDictionary *payload, NSString *key) {
    id value = payload[key];
    return [value respondsToSelector:@selector(integerValue)] ? MAX(0, [value integerValue]) : -1;
}

// Extract {unreadCount, requestsCount, preview?, unreadRoomId?, latestUnreadTs?}
// from a Matrix sync payload. Prefers Reddit's pre-computed counters; falls
// back to per-room data only on FULL syncs — an incremental response carries
// just the rooms that changed, so counter-absent there means "no information",
// not zero (returns nil in that case rather than clearing real state).
static NSDictionary *ApolloChatPollStatusFromSyncPayload(NSDictionary *payload, BOOL isIncremental) {
    NSDictionary *rooms = [payload[@"rooms"] isKindOfClass:[NSDictionary class]] ? payload[@"rooms"] : @{};
    NSDictionary *joined = [rooms[@"join"] isKindOfClass:[NSDictionary class]] ? rooms[@"join"] : @{};
    NSDictionary *invited = [rooms[@"invite"] isKindOfClass:[NSDictionary class]] ? rooms[@"invite"] : @{};

    NSInteger unread = ApolloChatPollCounter(payload, @"com.reddit.global_navigation_counter");
    NSInteger requests = ApolloChatPollCounter(payload, @"com.reddit.invites_counter");
    if ((unread < 0 || requests < 0) && isIncremental) return nil;
    if (requests < 0) requests = (NSInteger)invited.count;

    NSInteger summedUnread = 0;
    NSInteger unreadRoomCount = 0;
    NSString *unreadRoomId = nil;
    NSString *preview = nil;
    NSTimeInterval previewTimestamp = 0;
    for (NSString *roomId in joined) {
        NSDictionary *room = [joined[roomId] isKindOfClass:[NSDictionary class]] ? joined[roomId] : @{};
        NSDictionary *notifications = [room[@"unread_notifications"] isKindOfClass:[NSDictionary class]]
            ? room[@"unread_notifications"] : @{};
        NSInteger count = [notifications[@"notification_count"] respondsToSelector:@selector(integerValue)]
            ? [notifications[@"notification_count"] integerValue] : 0;
        // Reddit marks rooms excluded from its own navigation badge (e.g.
        // muted) — exclude those from ALL unread accounting, so the push
        // preview and deep link only ever reflect rooms the badge counts.
        id counted = notifications[@"com.reddit.is_counted_in_global_navigation_counter"];
        BOOL countsTowardBadge = counted == nil || [counted boolValue];
        if (count <= 0 || !countsTowardBadge) continue;
        summedUnread += count;
        unreadRoomCount++;
        unreadRoomId = unreadRoomCount == 1 ? roomId : nil;

        NSArray *events = [room[@"timeline"] isKindOfClass:[NSDictionary class]]
            ? ([room[@"timeline"][@"events"] isKindOfClass:[NSArray class]] ? room[@"timeline"][@"events"] : @[])
            : @[];
        for (NSDictionary *event in events.reverseObjectEnumerator) {
            if (![event isKindOfClass:[NSDictionary class]]) continue;
            if (![event[@"type"] isEqual:@"m.room.message"]) continue;
            NSString *body = [event[@"content"] isKindOfClass:[NSDictionary class]]
                ? event[@"content"][@"body"] : nil;
            if (![body isKindOfClass:[NSString class]] || body.length == 0) break;
            NSTimeInterval timestamp = [event[@"origin_server_ts"] respondsToSelector:@selector(doubleValue)]
                ? [event[@"origin_server_ts"] doubleValue] : 0;
            if (timestamp >= previewTimestamp) {
                previewTimestamp = timestamp;
                NSString *singleLine = [[body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                                        componentsJoinedByString:@" "];
                preview = singleLine.length > 140 ? [[singleLine substringToIndex:139] stringByAppendingString:@"…"] : singleLine;
            }
            break;
        }
    }
    if (unread < 0) unread = summedUnread;

    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"unreadCount"] = @(unread);
    status[@"requestsCount"] = @(requests);
    if (preview.length > 0) status[@"preview"] = preview;
    if (unreadRoomId.length > 0) status[@"unreadRoomId"] = unreadRoomId;
    if (previewTimestamp > 0) status[@"latestUnreadTs"] = @(previewTimestamp);
    return status;
}

#pragma mark - Bark transition pushes

// Per-account high-water marks of counts already notified about, persisted so
// a relaunch does not re-announce the same unread messages.
static NSDictionary *ApolloChatPollWatermarks(NSString *username) {
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryForKey:UDKeyChatUnreadNotifiedWatermarks];
    NSDictionary *entry = all[username.lowercaseString];
    return [entry isKindOfClass:[NSDictionary class]] ? entry : @{};
}

static void ApolloChatPollSaveWatermarks(NSString *username, NSInteger unread, NSInteger requests,
                                         NSTimeInterval latestTs) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *all = [[defaults dictionaryForKey:UDKeyChatUnreadNotifiedWatermarks] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    all[username.lowercaseString] = @{ @"unread": @(unread), @"requests": @(requests), @"latestTs": @(latestTs) };
    [defaults setObject:all forKey:UDKeyChatUnreadNotifiedWatermarks];
}

// Bark can be reached directly from the client (a plain POST to the push
// URL), so chat pushes work without any backend involvement. APNs-transport
// users get no chat pushes: the self-hosted backend polls Reddit's OAuth API
// server-side and modern Chat does not exist there.
static void ApolloChatPollNotifyTransitions(NSString *username, NSDictionary *status) {
    NSInteger unread = [status[@"unreadCount"] integerValue];
    NSInteger requests = [status[@"requestsCount"] integerValue];
    NSTimeInterval latestTs = [status[@"latestUnreadTs"] doubleValue];
    NSDictionary *marks = ApolloChatPollWatermarks(username);
    NSInteger unreadMark = [marks[@"unread"] integerValue];
    NSInteger requestsMark = [marks[@"requests"] integerValue];
    NSTimeInterval latestTsMark = [marks[@"latestTs"] doubleValue];

    // A newer message can arrive while the total holds steady (one read, one
    // received) — the advancing timestamp catches what the count can't. The
    // tsMark>0 requirement keeps the first-ever poll from announcing history.
    BOOL newerMessage = unread > 0 && latestTs > 0 && latestTsMark > 0 && latestTs > latestTsMark;
    if (unread == unreadMark && requests == requestsMark && !newerMessage) return;

    BOOL pushUnread = ApolloBarkConfigured() && (unread > unreadMark || newerMessage);
    BOOL pushRequests = ApolloBarkConfigured() && requests > requestsMark;
    if (!pushUnread && !pushRequests) {
        // No push owed (Bark unconfigured, or pure decreases): persist
        // immediately, so reading everything re-arms the next push.
        ApolloChatPollSaveWatermarks(username, unread, requests, MAX(latestTs, latestTsMark));
        return;
    }

    // A pushed component's watermark only advances once Bark actually accepts
    // the POST — on a transient failure it stays put, and the next 30s tick
    // re-trips the same transition and retries. Components that merely
    // decreased still land in the same single save below.
    __block NSInteger unreadToSave = unread;
    __block NSTimeInterval tsToSave = MAX(latestTs, latestTsMark);
    __block NSInteger requestsToSave = requests;
    dispatch_group_t group = dispatch_group_create();
    if (pushUnread) {
        NSString *title = unread == 1 ? @"New Chat Message"
            : [NSString stringWithFormat:@"%ld Unread Chat Messages", (long)unread];
        NSString *preview = [status[@"preview"] isKindOfClass:[NSString class]] ? status[@"preview"] : nil;
        NSString *roomId = [status[@"unreadRoomId"] isKindOfClass:[NSString class]] ? status[@"unreadRoomId"] : nil;
        // Invalid room paths safely fall back to the Chat entry screen
        // inside ApolloCreateModernChatViewControllerForPath.
        NSString *link = @"apollo://reborn/chat";
        if (roomId.length > 0) {
            NSString *escaped = [roomId stringByAddingPercentEncodingWithAllowedCharacters:
                                 NSCharacterSet.URLPathAllowedCharacterSet];
            if (escaped.length > 0) link = [NSString stringWithFormat:@"apollo://reborn/chat/room/%@", escaped];
        }
        dispatch_group_enter(group);
        ApolloBarkSendChatNotification(title, preview ?: @"Open Chat to read it.", link, ^(BOOL delivered) {
            if (!delivered) { unreadToSave = unreadMark; tsToSave = latestTsMark; }
            dispatch_group_leave(group);
        });
    }
    if (pushRequests) {
        NSString *title = requests == 1 ? @"New Chat Request"
            : [NSString stringWithFormat:@"%ld New Chat Requests", (long)requests];
        dispatch_group_enter(group);
        ApolloBarkSendChatNotification(title, @"Someone wants to start a chat with you.",
                                       @"apollo://reborn/chat/requests", ^(BOOL delivered) {
            if (!delivered) requestsToSave = requestsMark;
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // Stale-owner guard: an account switch while the POSTs were in flight
        // means these marks belong to the previous account — drop them.
        if (![username isEqualToString:sChatPollUsername]) return;
        if (unreadToSave != unread || requestsToSave != requests) {
            ApolloLog(@"[ChatPoller] Bark delivery failed — keeping the prior watermark so the next tick retries");
        }
        ApolloChatPollSaveWatermarks(username, unreadToSave, requestsToSave, tsToSave);
    });
}

#pragma mark - The poll itself

static void ApolloChatPollFinish(void) {
    sChatPollInFlight = NO;
    if (sChatPollPendingKick) {
        sChatPollPendingKick = NO;
        ApolloChatUnreadPollerKick();
    }
}

static void ApolloChatPollRunSync(NSString *username, NSString *bearer, BOOL isRetryAfterAuthFailure) {
    NSString *base = ApolloChatPollHomeserverBase();
    NSURLComponents *components = [NSURLComponents componentsWithString:
                                   [base stringByAppendingString:@"/_matrix/client/v3/sync"]];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"timeout" value:@"0"],
        [NSURLQueryItem queryItemWithName:@"set_presence" value:@"offline"],
        [NSURLQueryItem queryItemWithName:@"filter" value:kChatPollSyncFilter],
    ]];
    BOOL usedSinceToken = sChatPollSinceToken.length > 0 && [sChatPollSinceBase isEqualToString:base];
    if (usedSinceToken) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"since" value:sChatPollSinceToken]];
    }
    components.queryItems = query;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval = kChatPollRequestTimeout;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:[@"Bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        config.HTTPCookieStorage = nil;
        session = [NSURLSession sessionWithConfiguration:config];
    });

    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger statusCode = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        NSDictionary *payload = nil;
        if (!error && statusCode == 200 && data.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) payload = parsed;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![username isEqualToString:sChatPollUsername]) { ApolloChatPollFinish(); return; }

            // A since token can go stale (server-side retention, token_v2
            // rotation) — the server answers 400 M_UNKNOWN_TOKEN. Recover by
            // dropping it and re-running one full initial sync.
            if (statusCode == 400 && usedSinceToken) {
                ApolloLog(@"[ChatPoller] since token rejected for u/%@ — falling back to a full sync", username);
                sChatPollSinceToken = nil;
                sChatPollSinceBase = nil;
                ApolloChatPollRunSync(username, bearer, isRetryAfterAuthFailure);
                return;
            }

            if (statusCode == 401 || statusCode == 403) {
                sChatPollRejectedBearer = [bearer copy];
                sChatPollBearer = nil;
                sChatPollBearerExpiry = 0;
                if (isRetryAfterAuthFailure) {
                    // A freshly-minted bearer was rejected: the stored web
                    // session itself is dead. Try the login module's silent
                    // re-harvest (it has its own cooldown + coalescing); on
                    // success the next kick picks up the refreshed cookies.
                    sChatPollAuthBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollAuthBackoff;
                    ApolloLog(@"[ChatPoller] Fresh bearer rejected (HTTP %ld) for u/%@ — pausing polls %.0f min, attempting silent re-harvest",
                              (long)statusCode, username, kChatPollAuthBackoff / 60.0);
                    [ApolloWebSessionLoginViewController attemptSilentReharvestForUsername:username
                                                                                completion:^(BOOL success) {
                        // Stale-owner guard, as in the mint-failure path.
                        if (!success || ![username isEqualToString:sChatPollUsername]) return;
                        sChatPollAuthBlockedUntil = 0;
                        ApolloChatUnreadPollerKick();
                    }];
                    ApolloChatPollFinish();
                    return;
                }
                ApolloLog(@"[ChatPoller] Bearer rejected (HTTP %ld) for u/%@ — minting a fresh one",
                          (long)statusCode, username);
                ApolloWebSessionEntry *entry = ApolloWebSessionPollFor(username);
                if (entry.cookieHeader.length == 0) { ApolloChatPollFinish(); return; }
                // Skip the stored-cookie shortcut: it just produced this 401.
                if (sChatPollMintBlockedUntil > [NSDate date].timeIntervalSince1970) { ApolloChatPollFinish(); return; }
                ApolloChatPollMintBearer(username, entry.cookieHeader, ^(NSString *fresh) {
                    if (fresh.length == 0) {
                        sChatPollMintBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollMintBackoff;
                        ApolloChatPollFinish();
                        return;
                    }
                    sChatPollBearer = fresh;
                    sChatPollBearerExpiry = ApolloChatPollJWTExpiry(fresh);
                    ApolloChatPollRunSync(username, fresh, YES);
                });
                return;
            }
            if (error || statusCode != 200 || !payload) {
                if (statusCode == 429 || statusCode >= 500) {
                    sChatPollServerBlockedUntil = [NSDate date].timeIntervalSince1970 + kChatPollServerBackoff;
                }
                ApolloLog(@"[ChatPoller] Sync failed for u/%@ (HTTP %ld, %@)",
                          username, (long)statusCode, error.localizedDescription ?: @"unparseable body");
                ApolloChatPollFinish();
                return;
            }

            NSString *nextBatch = [payload[@"next_batch"] isKindOfClass:[NSString class]] ? payload[@"next_batch"] : nil;
            if (nextBatch.length > 0) {
                sChatPollSinceToken = nextBatch;
                sChatPollSinceBase = base;
            }

            NSMutableDictionary *status = [ApolloChatPollStatusFromSyncPayload(payload, usedSinceToken) mutableCopy];
            if (!status) {
                // Counter-absent incremental response: no information — keep
                // the last published state rather than clearing it.
                ApolloChatPollFinish();
                return;
            }
            status[@"username"] = username;
            status[@"checkedAt"] = @([NSDate date].timeIntervalSince1970 * 1000.0);
            ApolloLog(@"[ChatPoller] u/%@ unread=%@ requests=%@%@", username,
                      status[@"unreadCount"], status[@"requestsCount"],
                      sChatPollSinceToken.length > 0 ? @"" : @" (initial sync)");
            ApolloModernChatPublishPolledStatus(status);
            ApolloChatPollNotifyTransitions(username, status);
            ApolloChatPollFinish();
        });
    }] resume];
}

static void ApolloChatPollTick(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
        return;
    }
    if (sChatPollInFlight) { sChatPollPendingKick = YES; return; }
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;

    // Feature gates: modern Chat surface in use AND a stored web session for
    // the active account. With the toggle off this never fires, keeping the
    // API-key path's stock Direct Chat / Modmail behavior byte-identical.
    // Resolve the account identity ONCE per tick: ApolloActiveWebSessionUsername
    // unarchives the RedditAccounts2 blob and ApolloWebSessionPollFor hits the
    // keychain, so calling the three self-contained gate helpers here used to
    // cost ~3 unarchives + ~6 synchronous keychain reads every 30s on the main
    // thread — for every user, modern Chat or not.
    // Log the gate verdict, but only when it changes — not every 30 s.
    if (!ApolloModernMailboxOSSupported()) return;
    NSString *username = ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *entry = username.length > 0 ? ApolloWebSessionPollFor(username) : nil;
    BOOL available = username.length > 0 && entry != nil;
    BOOL shouldOpen = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseModernRedditChat]
        || ApolloModernChatIsRequiredForSession(entry);
    NSString *gateState = [NSString stringWithFormat:@"open=%d avail=%d user=%@ cookie=%d",
                           shouldOpen, available, username ?: @"-", entry.cookieHeader.length > 0];
    static NSString *sLastGateState = nil;
    if (![gateState isEqualToString:sLastGateState]) {
        sLastGateState = [gateState copy];
        ApolloLog(@"[ChatPoller] Gates: %@", gateState);
    }
    if (!shouldOpen || !available) return;
    if (username.length == 0 || entry.cookieHeader.length == 0) return;

    if (![username isEqualToString:sChatPollUsername]) {
        sChatPollUsername = [username copy];
        ApolloChatPollResetPerAccountState();
    }

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now < sChatPollAuthBlockedUntil || now < sChatPollServerBlockedUntil) return;

    sChatPollInFlight = YES;
    ApolloChatPollObtainBearer(username, entry.cookieHeader, ^(NSString *bearer) {
        if (bearer.length == 0 || ![username isEqualToString:sChatPollUsername]) {
            ApolloChatPollFinish();
            return;
        }
        ApolloChatPollRunSync(username, bearer, NO);
    });
}

#pragma mark - Lifecycle

static NSTimeInterval ApolloChatPollInterval(void) {
    // Hidden debug override for faster simulator iteration.
    double override = [[NSUserDefaults standardUserDefaults] doubleForKey:UDKeyChatPollerIntervalOverride];
    return override >= 5.0 ? override : kChatPollDefaultInterval;
}

static void ApolloChatPollStartTimer(void) {
    if (sChatPollTimer) return;
    sChatPollTimer = [NSTimer timerWithTimeInterval:ApolloChatPollInterval() repeats:YES
                                              block:^(__unused NSTimer *timer) { ApolloChatPollTick(); }];
    // Default mode, NOT common modes: a 30s unread poll has no business firing
    // mid-scroll — deferring the tick until tracking ends costs nothing and
    // keeps the account/keychain gate work out of scroll frames.
    [[NSRunLoop mainRunLoop] addTimer:sChatPollTimer forMode:NSDefaultRunLoopMode];
    ApolloLog(@"[ChatPoller] Started (%.0fs cadence)", ApolloChatPollInterval());
}

static void ApolloChatPollStopTimer(void) {
    [sChatPollTimer invalidate];
    sChatPollTimer = nil;
}

void ApolloChatUnreadPollerKick(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
}

__attribute__((constructor))
static void ApolloChatUnreadPollerInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            ApolloChatPollStartTimer();
            // Small delay so account/session stores settle after activation.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            ApolloChatPollStopTimer();
        }];
        // The activation notification normally fires after this block runs,
        // but don't depend on that ordering — if the app is already active,
        // start now.
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            ApolloChatPollStartTimer();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ApolloChatPollTick(); });
        }
    });
}
