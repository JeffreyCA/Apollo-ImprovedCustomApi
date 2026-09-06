// Authenticated modern Reddit Chat for API-key-free accounts.
//
// Reddit no longer mirrors current Chat conversations through the legacy
// /message endpoints Apollo uses. The public API also has no modern Chat
// contract, so use Reddit's own authenticated web client inside an isolated
// WKWebView seeded only with the active account's stored Reddit cookies.

#import "ApolloDirectChatWeb.h"
#import "ApolloAccountCredentials.h"
#import "ApolloChatUnreadPoller.h"
#import "ApolloCommon.h"
#import "ApolloListLayoutSupport.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebSessionLoginViewController.h"
#import "ApolloWebSessionStore.h"
#import "UserDefaultConstants.h"

#import <UIKit/UIGestureRecognizerSubclass.h>
#import <WebKit/WebKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface UITabBarController (ApolloModernMailboxTabBarVisibility)
- (void)setTabBarHidden:(BOOL)hidden animated:(BOOL)animated;
@end

NSString * const ApolloModernChatStatusDidChangeNotification = @"ApolloModernChatStatusDidChangeNotification";
static NSDictionary<NSString *, id> *sApolloModernChatStatus = nil;
static NSObject *ApolloModernChatStatusLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString *ApolloDirectChatHex(NSString *hex) {
    return hex.length ? [@"#" stringByAppendingString:hex] : @"#000000";
}

static NSString *ApolloDirectChatHexFromColor(UIColor *color,
                                               UITraitCollection *traits,
                                               NSString *fallback) {
    UIColor *resolved = color;
    if (@available(iOS 13.0, *)) {
        resolved = [color resolvedColorWithTraitCollection:traits ?: UITraitCollection.currentTraitCollection];
    }
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if ([resolved getRed:&red green:&green blue:&blue alpha:&alpha]) {
        return [NSString stringWithFormat:@"#%02X%02X%02X",
                (unsigned int)lrint(red * 255.0),
                (unsigned int)lrint(green * 255.0),
                (unsigned int)lrint(blue * 255.0)];
    }
    CGFloat white = 0.0;
    if ([resolved getWhite:&white alpha:&alpha]) {
        unsigned int component = (unsigned int)lrint(white * 255.0);
        return [NSString stringWithFormat:@"#%02X%02X%02X", component, component, component];
    }
    return fallback;
}

// Theme Builder V2's typography choices are all Apple system designs. Convert
// the active UIFont design into its CSS system-family counterpart so the web
// clients follow the same per-theme font without bundling or downloading font
// files. Font weight and italic styling remain controlled by Reddit's markup.
static NSString *ApolloDirectChatThemeFontFamily(void) {
    UIFont *base = [UIFont systemFontOfSize:16.0];
    UIFont *active = ApolloThemeRuntimeFont(base) ?: base;
    NSString *identity = [NSString stringWithFormat:@"%@ %@",
                          active.fontName ?: @"", active.familyName ?: @""].lowercaseString;
    if ([identity containsString:@"rounded"]) {
        return @"ui-rounded,\"SF Pro Rounded\",-apple-system,BlinkMacSystemFont,sans-serif";
    }
    if ([identity containsString:@"newyork"] || [identity containsString:@"new york"] ||
        [identity containsString:@"serif"]) {
        return @"ui-serif,\"New York\",Georgia,serif";
    }
    if ([identity containsString:@"mono"]) {
        return @"ui-monospace,\"SF Mono\",Menlo,monospace";
    }
    return @"-apple-system,BlinkMacSystemFont,\"SF Pro Text\",\"Helvetica Neue\",sans-serif";
}

// Apollo's AppColorTheme values and role colors were runtime-mapped for Theme
// Builder (docs/theme-builder-RE.md). Reuse that exact palette here so Chat
// follows every stock theme as well as arbitrary Theme Builder colors instead
// of merely switching between Reddit's light and dark appearances.
static NSDictionary<NSString *, NSString *> *ApolloDirectChatThemePalette(UITraitCollection *traits) {
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    NSString *mode = dark ? @"dark" : @"light";

    // Theme Manager V2 already compiles every custom, gallery, imported, and
    // per-appearance theme into semantic runtime tokens. Consume those tokens
    // directly so Chat follows the exact active theme rather than trying to
    // reinterpret the persisted editor model.
    if (ApolloThemeRuntimeIsActive()) {
        return @{
            @"accent": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenAccent), traits, @"#007AFF"),
            @"primary": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenBackground), traits, dark ? @"#131516" : @"#FFFFFF"),
            @"secondary": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground), traits, dark ? @"#000000" : @"#F2F3F7"),
            @"tertiary": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenTertiaryBackground), traits, dark ? @"#1A1A1A" : @"#F8F8F8"),
            @"separator": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenSeparator), traits, dark ? @"#232323" : @"#EEEEEF"),
            @"bar": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenBarBackground), traits, dark ? @"#131516" : @"#FBFBFB"),
            @"secondaryText": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel), traits, dark ? @"#84878C" : @"#919191"),
            @"text": ApolloDirectChatHexFromColor(ApolloThemeRuntimeColor(ApolloThemeTokenLabel), traits, dark ? @"#F2F2F7" : @"#0D1117"),
            @"font": ApolloDirectChatThemeFontFamily(),
            @"mode": mode,
        };
    }

    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.christianselig.apollo"];
    NSString *theme = [group stringForKey:@"AppColorTheme"] ?: @"default";
    NSDictionary *accents = @{
        @"default": @{@"light": @"007AFF", @"dark": @"2399FF"},
        @"nefertiti": @{@"light": @"01A200", @"dark": @"01A200"},
        @"fieryStare": @{@"light": @"FF0000", @"dark": @"FD0000"},
        @"spookyPumpkin": @{@"light": @"FF6200", @"dark": @"F25D00"},
        @"solarized": @{@"light": @"268BD2", @"dark": @"268BD2"},
        @"outrun": @{@"light": @"C400A6", @"dark": @"FF00D8"},
        @"sunset": @{@"light": @"FF6600", @"dark": @"FF7D00"},
        @"sepia": @{@"light": @"B88023", @"dark": @"D3AC72"},
        @"monochromatic": @{@"light": @"000000", @"dark": @"FFFFFF"},
        @"navy": @{@"light": @"0058B8", @"dark": @"0060C9"},
        @"skiesOnSkies": @{@"light": @"00B5F2", @"dark": @"01ADE8"},
        @"majesticPurple": @{@"light": @"8800FF", @"dark": @"9C2CFF"},
        @"magentasplosion": @{@"light": @"FF00B2", @"dark": @"E800A2"},
        @"sniffingWalnut": @{@"light": @"A74E00", @"dark": @"A74E00"},
        @"fisherKing": @{@"light": @"808286", @"dark": @"76787D"},
        @"chumbus": @{@"light": @"007AFF", @"dark": @"2399FF"},
        @"dracula": @{@"light": @"9760FF", @"dark": @"AD81FF"},
        @"mint": @{@"light": @"37BB98", @"dark": @"37BB98"},
    };
    NSDictionary *standard = dark
        ? @{@"primary": @"131516", @"secondary": @"000000", @"tertiary": @"1A1A1A", @"separator": @"232323", @"bar": @"131516"}
        : @{@"primary": @"FFFFFF", @"secondary": @"F2F3F7", @"tertiary": @"F8F8F8", @"separator": @"EEEEEF", @"bar": @"FBFBFB"};
    NSDictionary *tinted = @{
        @"solarized": @{
            @"light": @{@"primary": @"FDF6E3", @"secondary": @"E6DFCF", @"tertiary": @"F2ECDA", @"separator": @"E0DCCD", @"bar": @"F1ECDC"},
            @"dark": @{@"primary": @"002B36", @"secondary": @"003745", @"tertiary": @"00181F", @"separator": @"002836", @"bar": @"00171F"},
        },
        @"outrun": @{
            @"light": @{@"primary": @"CFD7E8", @"secondary": @"BAC1D1", @"tertiary": @"C1C8D9", @"separator": @"B5B9C7", @"bar": @"C5CAD9"},
            @"dark": @{@"primary": @"061636", @"secondary": @"081D47", @"tertiary": @"041129", @"separator": @"06214D", @"bar": @"031229"},
        },
        @"sunset": @{
            @"light": @{@"primary": @"FFE3D0", @"secondary": @"F2D8C7", @"tertiary": @"F2D8C7", @"separator": @"E0CBBD", @"bar": @"F1DACB"},
            @"dark": @{@"primary": @"000F29", @"secondary": @"12223D", @"tertiary": @"000F29", @"separator": @"061B40", @"bar": @"000B1F"},
        },
        @"sepia": @{
            @"light": @{@"primary": @"F1EAD9", @"secondary": @"DBD5CA", @"tertiary": @"E6DFCF", @"separator": @"D4CEC0", @"bar": @"E6E0D1"},
            @"dark": @{@"primary": @"211E1A", @"secondary": @"38332C", @"tertiary": @"141310", @"separator": @"29271F", @"bar": @"14130F"},
        },
        @"dracula": @{
            @"light": @{@"primary": @"F8F8F3", @"secondary": @"EDEDE8", @"tertiary": @"F8F8F3", @"separator": @"D7D3E0", @"bar": @"E6E4EB"},
            @"dark": @{@"primary": @"1A1D29", @"secondary": @"222636", @"tertiary": @"1A1D29", @"separator": @"242838", @"bar": @"12141C"},
        },
    };
    NSDictionary *roles = tinted[theme][mode] ?: standard;
    NSString *accent = accents[theme][mode] ?: accents[@"default"][mode];
    return @{
        @"accent": ApolloDirectChatHex(accent),
        @"primary": ApolloDirectChatHex(roles[@"primary"]),
        @"secondary": ApolloDirectChatHex(roles[@"secondary"]),
        @"tertiary": ApolloDirectChatHex(roles[@"tertiary"]),
        @"separator": ApolloDirectChatHex(roles[@"separator"]),
        @"bar": ApolloDirectChatHex(roles[@"bar"]),
        @"secondaryText": dark ? @"#84878C" : @"#919191",
        @"text": dark ? @"#F2F2F7" : @"#0D1117",
        @"font": ApolloDirectChatThemeFontFamily(),
        @"mode": mode,
    };
}

static UIColor *ApolloDirectChatPaletteColor(NSDictionary *palette, NSString *key) {
    return ApolloColorFromHexString(palette[key]) ?: UIColor.systemBackgroundColor;
}

UIColor *ApolloModernChatThemeColor(UITraitCollection *traits, NSString *role) {
    return ApolloDirectChatPaletteColor(ApolloDirectChatThemePalette(traits), role);
}

NSDictionary<NSString *, id> *ApolloModernChatCachedStatus(void) {
    NSDictionary<NSString *, id> *status = nil;
    @synchronized (ApolloModernChatStatusLock()) {
        status = [sApolloModernChatStatus copy];
    }
    NSString *statusUsername = [status[@"username"] isKindOfClass:[NSString class]]
        ? [status[@"username"] lowercaseString] : @"";
    NSString *activeUsername = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    if (statusUsername.length > 0 && ![statusUsername isEqualToString:activeUsername]) {
        return nil;
    }
    return status;
}

static void ApolloModernChatPublishStatus(NSDictionary<NSString *, id> *status) {
    if (![status isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *username = [status[@"username"] isKindOfClass:[NSString class]]
            ? [status[@"username"] lowercaseString] : @"";
        NSString *activeUsername = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
        if (username.length == 0 || ![username isEqualToString:activeUsername]) {
            ApolloLog(@"[DirectChatWeb] Ignored stale Chat status for u/%@ while u/%@ is active",
                      username, activeUsername);
            return;
        }
        NSDictionary *old = ApolloModernChatCachedStatus();
        NSMutableDictionary *merged = old ? [old mutableCopy] : [NSMutableDictionary dictionary];
        merged[@"username"] = username;
        NSString *surface = [status[@"surface"] isKindOfClass:[NSString class]] ? status[@"surface"] : @"threads";
        BOOL routeUnread = [status[@"hasUnread"] boolValue];
        // Count authority: the Matrix poller reads Reddit's OWN exact counters,
        // so once a poll result owns the counts it stays authoritative until
        // the next poll. A scrape of the HIDDEN hub renders Reddit's PAUSED web
        // client, whose DOM lags reality in BOTH directions — it can show a
        // stale-low "nothing unread" (new arrival not yet rendered) OR a
        // stale-high count (already read elsewhere, receipt not synced). Either
        // way it is not authoritative, so a hidden scrape contributes nothing
        // to counts while a poll owns them; it neither clears nor raises. A
        // VISIBLE scrape is the user actually reading, so it may still move
        // counts (and the next poll re-takes ownership regardless).
        BOOL hiddenScrape = [status[@"origin"] isKindOfClass:[NSString class]] &&
            [status[@"origin"] isEqualToString:@"dom-hidden"];
        BOOL pollOwnsCounts = [old[@"countsSource"] isKindOfClass:[NSString class]] &&
            [old[@"countsSource"] isEqualToString:@"poll"];
        BOOL suppressCountWrites = hiddenScrape && pollOwnsCounts;
        if ([surface isEqualToString:@"poll"]) {
            // The background poller reads Reddit's own pre-computed counters,
            // so one snapshot authoritatively covers both surfaces at once.
            NSInteger unread = [status[@"unreadCount"] respondsToSelector:@selector(integerValue)]
                ? MAX(0, [status[@"unreadCount"] integerValue]) : 0;
            NSInteger requests = [status[@"requestsCount"] respondsToSelector:@selector(integerValue)]
                ? MAX(0, [status[@"requestsCount"] integerValue]) : 0;
            merged[@"hasThreadUnread"] = @(unread > 0);
            merged[@"threadUnreadCount"] = @(unread);
            merged[@"hasRequests"] = @(requests > 0);
            merged[@"requestsCount"] = @(requests);
            merged[@"countsSource"] = @"poll";
            // Incremental syncs only carry previews for rooms with fresh
            // events — keep the previous preview while anything stays unread.
            if ([status[@"preview"] isKindOfClass:[NSString class]]) merged[@"preview"] = status[@"preview"];
            else if (unread == 0) [merged removeObjectForKey:@"preview"];
        } else if (suppressCountWrites) {
            // Paused hidden DOM vs an authoritative poll — ignore its counts
            // and preview entirely; the merged dict keeps the poll's values.
        } else if ([surface isEqualToString:@"requests"]) {
            BOOL hasRequests = [status[@"hasRequests"] boolValue];
            merged[@"hasRequests"] = @(hasRequests);
            // The DOM scrape has no exact request count; only a definitive
            // "no requests" may clear the poller's counted value.
            if (!hasRequests) merged[@"requestsCount"] = @0;
            if (!hiddenScrape) merged[@"countsSource"] = @"dom";
        } else {
            NSInteger scrapeCount = [status[@"unreadCount"] isKindOfClass:[NSNumber class]]
                ? MAX(0, [status[@"unreadCount"] integerValue]) : 0;
            merged[@"hasThreadUnread"] = @(routeUnread);
            merged[@"threadUnreadCount"] = @(scrapeCount);
            if (!hiddenScrape) merged[@"countsSource"] = @"dom";
            if ([status[@"preview"] isKindOfClass:[NSString class]]) merged[@"preview"] = status[@"preview"];
            else [merged removeObjectForKey:@"preview"];
        }
        BOOL hasThreadUnread = [merged[@"hasThreadUnread"] boolValue];
        BOOL hasRequests = [merged[@"hasRequests"] boolValue];
        merged[@"hasUnread"] = @(hasThreadUnread || hasRequests);
        merged[@"checkedAt"] = status[@"checkedAt"] ?: @([[NSDate date] timeIntervalSince1970] * 1000.0);

        // countsSource is internal authority bookkeeping, deliberately NOT a
        // meaningful key: a poll<->visible-DOM handoff that leaves every count
        // unchanged must not fire a spurious status-change NOTIFICATION.
        NSArray<NSString *> *meaningfulKeys = @[
            @"username", @"hasUnread", @"hasThreadUnread", @"hasRequests",
            @"threadUnreadCount", @"requestsCount", @"preview"
        ];
        BOOL meaningfulChange = NO;
        for (NSString *key in meaningfulKeys) {
            id before = old[key];
            id after = merged[key];
            if ((before || after) && ![before isEqual:after]) {
                meaningfulChange = YES;
                break;
            }
        }
        // Persistence and notification must be decoupled: a poll that merely
        // CONFIRMS the cached counts still needs to record its countsSource=poll
        // ownership (so a later hidden scrape stays suppressed), even though it
        // fires no notification. Gating the cache write on meaningfulChange
        // alone would drop that ownership update and let the hidden scraper
        // clobber poll-correct counts. So persist whenever anything — including
        // countsSource — differs; notify only on a meaningful change.
        id oldSource = old[@"countsSource"];
        id newSource = merged[@"countsSource"];
        BOOL sourceChanged = (oldSource || newSource) && ![oldSource isEqual:newSource];
        if (!meaningfulChange && !sourceChanged) return;
        @synchronized (ApolloModernChatStatusLock()) {
            sApolloModernChatStatus = [merged copy];
        }
        if (!meaningfulChange) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloModernChatStatusDidChangeNotification object:nil];
    });
}

void ApolloModernChatPublishPolledStatus(NSDictionary<NSString *, id> *status) {
    if (![status isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *tagged = [status mutableCopy];
    tagged[@"surface"] = @"poll";
    ApolloModernChatPublishStatus(tagged);
}

// The modern Chat app is made of nested web components, so install the same
// variables in the document and every open shadow root. The second half finds
// the visible GIPHY results list by geometry rather than Reddit's generated
// class names, turning its phone-hostile full-width tiles into a stable 2-column
// grid while leaving message GIFs, images, and the emoji picker untouched.
static NSString *ApolloDirectChatEnhancementScript(NSDictionary *palette) {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:palette options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] ?: @"{}";
    NSMutableString *script = [NSMutableString stringWithString:@"(()=>{const palette="];
    [script appendString:json];
    [script appendString:@";"
        "window.__apolloChatPalette=palette;window.__apolloChatShadowRoots=window.__apolloChatShadowRoots||[];"
        // The selected-section marker is a plain window global, so Reddit's
        // real navigations reset it; restore it from sessionStorage (scoped to
        // this WKWebView's private data store) at document start so the
        // in-room back interception stays correctly gated on fresh documents.
        // __apolloEmbeddedInboxMessages is deliberately NOT restored early:
        // the native align pass re-marks it after the Messages filter pipeline
        // completes, and fresh list documents hydrate behind a native cover
        // anyway — hiding Reddit's list chrome from first paint risks hiding
        // controls the filter-apply flow still needs to click.
        "try{const sec=sessionStorage.getItem('__apolloEmbeddedSection');if(sec)window.__apolloEmbeddedSection=sec;}catch(e){}"
        "const roots=()=>{const out=[];const visit=r=>{if(!r||out.includes(r))return;out.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);for(const r of window.__apolloChatShadowRoots)visit(r);return out;};"
        "const mailRoute=()=>location.pathname.startsWith('/mail/');"
        "const chatListRoute=()=>/^\\/chat\\/?$/.test(location.pathname);"
        // Reddit renders both mailbox surfaces smaller than Apollo's native
        // typography. Enlarge text through WebKit autosizing instead of page
        // zoom so rows still reflow at the real device width. Modmail stays more
        // conservative because its dense editor already has large controls;
        // Chat starts at 108% on compact phones and gradually reaches 116%.
        "const textScale=()=>{const w=document.documentElement?.clientWidth||innerWidth||375;if(mailRoute())return Math.min(112,Math.max(100,100+(w-350)*0.15));return Math.min(116,Math.max(108,108+(w-350)*0.12));};"
        // Reddit wraps the entire Modmail thread in p-md (roughly 17 points on
        // a current-size iPhone). Remove that artificial outer gutter so the
        // subject, messages, and composer use the whole screen. Preserve only
        // WebKit's real safe area on landscape/notched devices. Scope this by
        // route so the modern Chat layout remains untouched.
        // Reddit reserves 57 points for its own header even after we hide that
        // header. Zeroing the source variable lets every current mailbox shell
        // (including its nested shadow-root layout) fill the WKWebView without
        // imposing a fixed height that would fight the iOS keyboard viewport.
        "const mailLayout=()=>mailRoute()?':host,:root,shreddit-app{--shreddit-header-height:0px!important;--shreddit-header-large-height:0px!important;}#main-content.flex.gap-md.p-md{padding-left:env(safe-area-inset-left,0px)!important;padding-right:env(safe-area-inset-right,0px)!important;padding-bottom:0!important;box-sizing:border-box!important;}rpl-inbox-row .title{font-weight:600!important;color:var(--apollo-chat-text)!important;}':'';"
        // Reddit's Chat media button is the only composer control that combines
        // a touch tooltip with a native file-input chooser. Mobile WebKit can
        // leave that tooltip's :hover/:focus presentation stuck after the
        // chooser closes. RPL renders the body and arrow in two nested shadow
        // roots, so hiding only role=tooltip leaves a small black diamond above
        // the icon. Suppress both visual pieces on the touch-only Chat surface.
        // The :host(.tooltip) guard restricts the arrow rule to tooltip poppers;
        // menu/popover arrows and aria-label/aria-describedby stay untouched.
        "const chatTouchLayout=()=>mailRoute()?'':'@media (hover:none),(pointer:coarse){[role=tooltip],:host(.tooltip) .popup--arrow[part=arrow]{display:none!important;}}';"
        // fixEmbeddedMessagesChrome (below) hides Reddit's redundant list rows
        // with inline styles, but only after the elements exist and a sweep has
        // run — one visible frame of Requests/Threads rows and filter chips
        // during a list reload. These stylesheet rules live in every themed
        // root (including new shadow roots), so the known chrome never paints
        // at all while the hub is active. The JS pass stays for the rs-rooms-nav
        // header, whose stable selector lives only in its shadow tree.
        // Scoped to the root list route: Requests/Threads crop their redundant
        // chrome natively and must keep those rows in layout, and on room
        // routes the background list pane keeps the sweep's inline styles.
        "const embeddedChrome=()=>window.__apolloEmbeddedInboxMessages&&chatListRoute()?'li[data-testid=requests-button],li[data-testid=threads-button],rs-rooms-nav-filter-chips{display:none!important;}':'';"
        // Every keystroke in the Modmail reply box makes Reddit re-render the
        // composer header, which REPLACES the "Reply as r/…" avatar with a
        // brand-new <img> carrying the same src. A fresh element re-runs the
        // image load even against the memory cache, so for a frame or two it
        // has no pixels and paints only its own placeholder background — the
        // subreddit's key colour — which reads as the icon flickering while
        // you type. Republish each small square avatar URL as a background
        // image keyed on that exact src: a background is resolved from the
        // document's already-loaded CSS image cache during style resolution,
        // so a replacement element paints the real icon on its very first
        // frame. Rules are emitted through the same stylesheet the theme uses
        // (so they exist before any replacement is inserted, unlike a
        // mutation-driven inline style), capped, and scoped to the mailbox.
        "window.__apolloMailAvatarSrcs=window.__apolloMailAvatarSrcs||[];"
        "const collectMailAvatarSrcs=()=>{if(!mailRoute())return 0;const seen=window.__apolloMailAvatarSrcs;let added=0;"
        "for(const r of roots())for(const img of r.querySelectorAll('img')){const b=img.getBoundingClientRect();"
        "if(b.width<=0||b.width>72||Math.abs(b.width-b.height)>10)continue;"
        "const u=img.getAttribute('src')||'';if(!u||u.startsWith('data:')||u.includes('\"')||u.includes('\\\\'))continue;"
        "if(seen.includes(u))continue;seen.push(u);added++;while(seen.length>24)seen.shift();}return added;};"
        "const mailAvatarHold=()=>!mailRoute()?'':window.__apolloMailAvatarSrcs.map(u=>"
        "`img[src=\"${u}\"]{background-image:url(\"${u}\")!important;background-size:cover!important;background-position:center!important;background-repeat:no-repeat!important;}`).join('');"
        "const css=()=>`:host,:root{"
            "--apollo-chat-accent:${palette.accent};--apollo-chat-bg:${palette.primary};--apollo-chat-surface:${palette.secondary};--apollo-chat-raised:${palette.tertiary};--apollo-chat-border:${palette.separator};--apollo-chat-text:${palette.text};--apollo-chat-muted:${palette.secondaryText};--apollo-chat-font:${palette.font};"
            "--font-sans:var(--apollo-chat-font)!important;--font-family-sans:var(--apollo-chat-font)!important;font-family:var(--apollo-chat-font)!important;"
            "--color-neutral-background:${palette.primary}!important;--color-neutral-background-container:${palette.secondary}!important;--color-neutral-background-strong:${palette.secondary}!important;--color-neutral-background-strong-hover:${palette.tertiary}!important;--color-neutral-background-weak:${palette.tertiary}!important;--color-neutral-background-hover:${palette.tertiary}!important;--color-neutral-background-selected:${palette.tertiary}!important;--color-neutral-background-disabled:${palette.tertiary}!important;"
            "--color-neutral-border:${palette.separator}!important;--color-neutral-border-weak:${palette.separator}!important;--color-neutral-border-medium:${palette.separator}!important;--color-neutral-border-strong:${palette.separator}!important;--color-neutral-content:${palette.text}!important;--color-neutral-content-strong:${palette.text}!important;--color-neutral-content-weak:${palette.secondaryText}!important;--color-neutral-content-disabled:${palette.secondaryText}!important;"
            "--color-primary:${palette.accent}!important;--color-primary-hover:${palette.accent}!important;--color-primary-visited:${palette.accent}!important;--color-primary-background:${palette.accent}!important;--color-secondary:${palette.text}!important;--color-secondary-background:${palette.tertiary}!important;"
            "--color-tone-1:${palette.text}!important;--color-tone-2:${palette.secondaryText}!important;--color-tone-3:${palette.secondaryText}!important;--color-tone-4:${palette.separator}!important;--color-tone-5:${palette.tertiary}!important;--color-tone-6:${palette.secondary}!important;--color-tone-7:${palette.primary}!important;"
            "--newCommunityTheme-body:${palette.primary}!important;--newCommunityTheme-bodyText:${palette.text}!important;--newCommunityTheme-button:${palette.accent}!important;--newCommunityTheme-line:${palette.separator}!important;"
        "}html,body,button,input,textarea,select{font-family:var(--apollo-chat-font)!important;}html,body{background-color:var(--apollo-chat-bg)!important;color:var(--apollo-chat-text)!important;-webkit-text-size-adjust:${textScale()}%!important;text-size-adjust:${textScale()}%!important;}body{accent-color:var(--apollo-chat-accent)!important;}a{color:var(--apollo-chat-accent)!important;}input,textarea,[contenteditable=true]{caret-color:var(--apollo-chat-accent)!important;font-size:16px!important;}::selection{background:var(--apollo-chat-accent)!important;color:var(--apollo-chat-bg)!important;}"
        "shreddit-app{--page-y-padding:0px!important;padding-top:0!important;}header.v2.hui{display:none!important;}modmail-mailbox-wrapper{top:0!important;margin-top:0!important;}${mailLayout()}${chatTouchLayout()}${embeddedChrome()}${mailAvatarHold()}`;"
        "const themeRoot=r=>{if(!r)return;let s=r.querySelector('style[data-apollo-chat-theme]');if(!s){s=document.createElement('style');s.setAttribute('data-apollo-chat-theme','');const target=r===document?(document.head||document.documentElement):r;if(!target)return;target.appendChild(s);}const next=css();if(s.textContent!==next)s.textContent=next;};"
        "let sweepScheduled=false;const scheduleSweep=()=>{if(sweepScheduled)return;sweepScheduled=true;requestAnimationFrame(()=>{sweepScheduled=false;window.__apolloChatEnhancementSweep?.();});};window.__apolloChatScheduleSweep=scheduleSweep;"
        // Tapping Send media currently lets Reddit focus the contenteditable
        // message field on pointer-down before it clicks the hidden file input.
        // iOS begins animating the keyboard, shrinks visualViewport, scrolls the
        // conversation, then immediately reverses all of that for the native
        // chooser. Mark only a genuine Send-media control gesture and blur only
        // text entries focused during that short gesture. The button click and
        // file input are never cancelled, so Photo Library / Camera / Files keep
        // running through Reddit's own implementation. Install this in every
        // captured shadow root too: current Chat nests the composer controls.
        "window.__apolloChatMediaGestureUntil=window.__apolloChatMediaGestureUntil||0;"
        "const mediaControlForEvent=event=>{if(mailRoute())return null;for(const node of event.composedPath?.()||[]){if(!(node instanceof Element)||!node.matches?.('button,[role=button]'))continue;const marker=[node.getAttribute('aria-label'),node.getAttribute('title'),node.getAttribute('data-testid'),node.getAttribute('data-control-name'),node.textContent].filter(Boolean).join(' ').replace(/\\s+/g,' ').trim().toLowerCase();if(marker.includes('send media')||/(^|[\\s_-])(media|image|photo)([\\s_-]|$)/.test(marker))return node;}return null;};"
        "const isChatTextEntry=node=>!!node?.matches?.('textarea,[contenteditable=true],[role=textbox],input:not([type=file]):not([type=button]):not([type=submit])');"
        "const deepActiveElement=root=>{let node=root?.activeElement||document.activeElement;while(node?.shadowRoot?.activeElement)node=node.shadowRoot.activeElement;return node;};"
        "const blurMediaGestureTextEntry=root=>{const active=deepActiveElement(root);if(!isChatTextEntry(active))return false;active.blur?.();return true;};"
        // Reddit's in-room back control performs a client-side pane flip: the
        // conversation list becomes visible again while location stays on
        // /chat/room/…. Every list treatment — the chrome hiding above, the
        // native crop, and the shared tab-bar restore — keys off the route,
        // so the flipped-back list would show Reddit's own header/rows with
        // Apollo's tab bar still hidden. When the room was entered from the
        // embedded Messages list (native KVO records this in
        // __apolloChatRoomFromList), let Reddit's own click handler flip the
        // pane — the list underneath is the same still-hydrated DOM, so the
        // return is instant with no reload, skeleton rows, or re-hydration
        // dance — then repair only the URL with a guarded history.back(): the
        // room is a real pushState entry on top of the list entry, and
        // Reddit's router provably ignores the resulting popstate, so this
        // only pops the URL, which drives every native route treatment
        // through the WKWebView URL observer. Rooms without a list history
        // entry (deep links) keep the full /chat navigation, which the native
        // side now covers until the fresh list stabilizes; the same
        // navigation doubles as the timeout net if the pane flip ever fails.
        // One definition of "Reddit's in-room Back control", shared by the
        // click interception below and the native swipe-back driver: a
        // VISIBLE button/link in the room header's top-left corner whose
        // label, testid, or icon reads as Back. The visibility test matters
        // only for the driver — it queries the whole document, where the
        // still-hydrated list pane behind the room also has controls, and a
        // hidden element reports an all-zero rect that would otherwise pass
        // the top-left test.
        "const isChatBackControl=node=>{if(!(node instanceof Element)||!node.matches?.('button,[role=button],a'))return false;const rect=node.getBoundingClientRect();if(rect.width<=0||rect.height<=0)return false;if(rect.top>140||rect.left>120)return false;const marker=[node.getAttribute('aria-label'),node.getAttribute('title'),node.getAttribute('data-testid'),node.textContent].filter(Boolean).join(' ').replace(/\\s+/g,' ').trim().toLowerCase();return /(^|[\\s_-])back([\\s_-]|$)/.test(marker)||!!node.querySelector('[icon-name*=back i],[name*=back i],[aria-label*=back i]');};"
        // Page-side surface report for the native side (see the controller's
        // pageConversationVisible): whether a conversation pane is on screen,
        // judged by the same in-room Back control the swipe driver clicks,
        // narrowed to a compact control so a full-width list row whose preview
        // happens to contain the word "back" can never read as a room. Only
        // the root list and conversation routes are judged — Reddit's Requests
        // and Threads lists carry their own header Back control, so they always
        // report no room. Posted only when the answer (or the path it was
        // judged under) changes, from the enhancement sweep: every pane flip is
        // a DOM mutation, so the observers deliver it within a frame.
        "const compactChatBackControlVisible=()=>{for(const r of roots())for(const node of r.querySelectorAll('button,[role=button],a')){if(!isChatBackControl(node))continue;const rect=node.getBoundingClientRect();if(rect.width<=120&&rect.height<=80)return true;}return false;};"
        "window.__apolloChatReportSurface=()=>{if(mailRoute())return;const path=location.pathname;const judged=/^\\/chat\\/?$/.test(path)||path.startsWith('/chat/room/')||/^\\/chat\\/threads\\/[^/]+/.test(path);const room=judged&&compactChatBackControlVisible();const key=(room?'1':'0')+path;if(window.__apolloChatSurfaceKey===key)return;window.__apolloChatSurfaceKey=key;try{window.webkit?.messageHandlers?.apolloChatSurface?.postMessage({room,path});}catch(e){}};"
        // Native swipe-back driver. A back gesture inside a conversation must
        // do exactly what tapping that control does — Reddit's own pane flip
        // plus the interception below (a capture-phase click listener; a
        // synthesized click propagates through the composed path like a real
        // one) — so the whole return stays in the single code path a tap
        // already used instead of growing a second, differently-behaving one.
        // Picks the most top-left candidate so a header with several small
        // controls resolves deterministically.
        "window.__apolloChatTapRoomBack=()=>{let best=null,bestScore=Infinity;for(const r of roots())for(const node of r.querySelectorAll('button,[role=button],a')){if(!isChatBackControl(node))continue;const rect=node.getBoundingClientRect();const score=rect.top+rect.left;if(score<bestScore){bestScore=score;best=node;}}if(!best)return 'none';"
        "const from=location.pathname,claimed=window.__apolloChatBackHandledAt||0;best.click();if((window.__apolloChatBackHandledAt||0)!==claimed)return 'clicked';"
        // Nobody claimed the click — the standalone Chat screen, or a reply
        // thread — so Reddit flips its pane but leaves the URL on the room,
        // which is what every native route treatment reads. Repair it, but
        // only once the flip is observable (the room's own Back control is
        // gone): desyncing a list URL onto a still-open room would be worse
        // than a slow return, and leaving the URL alone is exactly what lets
        // the native net do a real navigation instead.
        "window.__apolloChatBackHandledAt=Date.now();"
        // A room the route never reported leaves the URL already on the list;
        // there is nothing to repair then, and a history.back() would step
        // PAST the list. Only a URL that still reads the conversation is
        // repaired.
        "setTimeout(()=>{if(location.pathname!==from)return;for(const r of roots())for(const node of r.querySelectorAll('button,[role=button],a'))if(isChatBackControl(node))return;if(!from.startsWith('/chat/room/')&&!/^\\/chat\\/threads\\/[^/]+/.test(from))return;history.back();},90);"
        "return 'clicked';};"
        "const redirectEmbeddedRoomBack=event=>{if(mailRoute()||!window.__apolloEmbeddedInboxMessages)return;if((window.__apolloEmbeddedSection||'messages')!=='messages')return;if(!location.pathname.startsWith('/chat/room/'))return;for(const node of event.composedPath?.()||[]){if(!isChatBackControl(node))continue;"
        "const from=location.pathname;"
        // The pass-through branch cannot stopImmediatePropagation (that would
        // also swallow Reddit's own pane-flip handler), so the same tap
        // reaches this handler once per hooked shadow root on the composed
        // path — a timestamp latch keeps only the first invocation scheduling
        // the URL repair. The /chat ejection net is cancelled by the popstate
        // of a successful history repair, so quickly re-entering the same
        // room afterwards can never trip it.
        "if(window.__apolloChatRoomFromList){const now=Date.now();if(now-(window.__apolloChatBackHandledAt||0)<400)return;window.__apolloChatBackHandledAt=now;"
        "setTimeout(()=>{if(location.pathname===from)history.back();},60);"
        "const eject=setTimeout(()=>{if(location.pathname===from)location.assign('/chat');},700);"
        "addEventListener('popstate',()=>clearTimeout(eject),{once:true});return;}"
        "event.preventDefault();event.stopImmediatePropagation();location.assign('/chat');return;}};"
        "const installChatInteractionHooks=root=>{if(!root||root.__apolloChatInteractionHooks)return;try{Object.defineProperty(root,'__apolloChatInteractionHooks',{value:true,configurable:true});const beginMediaGesture=event=>{const control=mediaControlForEvent(event);if(!control)return;window.__apolloChatMediaGestureUntil=Date.now()+1600;const title=control.getAttribute?.('title');if(title&&!control.hasAttribute('aria-label')&&!control.hasAttribute('aria-labelledby'))control.setAttribute('aria-label',title);control.removeAttribute?.('title');control.blur?.();blurMediaGestureTextEntry(root);queueMicrotask(()=>blurMediaGestureTextEntry(root));requestAnimationFrame(()=>blurMediaGestureTextEntry(root));};const rejectMediaGestureFocus=event=>{if(Date.now()>window.__apolloChatMediaGestureUntil)return;const target=event.composedPath?.()[0]||event.target;if(!isChatTextEntry(target))return;target.blur?.();queueMicrotask(()=>blurMediaGestureTextEntry(root));};root.addEventListener('pointerdown',beginMediaGesture,true);root.addEventListener('touchstart',beginMediaGesture,{capture:true,passive:true});root.addEventListener('click',beginMediaGesture,true);root.addEventListener('click',redirectEmbeddedRoomBack,true);root.addEventListener('focusin',rejectMediaGestureFocus,true);}catch(e){console.debug('[ApolloFix][DirectChatWeb] Chat media interaction hook failed',e);}};"
        // The scroll-skip stamp below must catch scrolls of the real chat list
        // scroller, which lives in a shadow root (rs-virtual-scroll inside
        // rs-rooms-nav). A 'scroll' event is composed:false, so a single
        // window-level listener never sees it — stamp from a capture-phase
        // listener on EVERY captured root instead (document + each shadow
        // root), added exactly once per root alongside its observer.
        "const observeRoot=r=>{if(!r)return;installChatInteractionHooks(r);if(r.__apolloChatObserver)return;try{Object.defineProperty(r,'__apolloChatObserver',{value:new MutationObserver(()=>window.__apolloChatScheduleSweep?.()),configurable:true});r.__apolloChatObserver.observe(r,{childList:true,subtree:true});r.addEventListener('scroll',()=>{window.__apolloChatScrollStamp=Date.now();},{capture:true,passive:true});}catch(e){}};"
        "const themeRoots=()=>{for(const r of roots()){themeRoot(r);observeRoot(r);}};"
        // Patch attachShadow at document start. Reddit constructs the thread
        // composer as an SPA transition, so waiting for the periodic sweep
        // made its font and spacing visibly jump after the thread appeared.
        "window.__apolloChatNewShadowRoot=root=>{if(!window.__apolloChatShadowRoots.includes(root))window.__apolloChatShadowRoots.push(root);themeRoot(root);observeRoot(root);scheduleSweep();};"
        "if(!Element.prototype.__apolloChatOriginalAttachShadow){const original=Element.prototype.attachShadow;Object.defineProperty(Element.prototype,'__apolloChatOriginalAttachShadow',{value:original});Element.prototype.attachShadow=function(init){const root=original.call(this,init);window.__apolloChatNewShadowRoot?.(root);return root;};}"
        "const fixGiphy=()=>{let grids=0;for(const r of roots())for(const container of r.querySelectorAll('.gifs-container')){const media=[...container.querySelectorAll(':scope > img,:scope > video')];if(media.length<2)continue;container.setAttribute('data-apollo-giphy-grid','');container.style.setProperty('display','grid','important');container.style.setProperty('grid-template-columns','repeat(2,minmax(0,1fr))','important');container.style.setProperty('grid-auto-rows','104px','important');container.style.setProperty('gap','6px','important');container.style.setProperty('width','100%','important');container.style.setProperty('height','auto','important');container.style.setProperty('box-sizing','border-box','important');for(const m of media){m.style.setProperty('width','100%','important');m.style.setProperty('min-width','0','important');m.style.setProperty('height','104px','important');m.style.setProperty('max-width','none','important');m.style.setProperty('object-fit','cover','important');m.style.setProperty('margin','0','important');m.style.setProperty('overflow','hidden','important');m.style.setProperty('border-radius','10px','important');}grids++;}return grids;};"
        // Reddit appends each next GIPHY page to the existing dropdown, then
        // resets that same element's scrollTop to zero. Remember a recent real
        // scroll and restore it only when the results height has grown. Small
        // positions are allowed to reach zero normally, while closing/reopening
        // the picker or changing the search query clears the remembered state.
        "const giphyQuery=dropdown=>dropdown.querySelector('faceplate-search-input,input,textarea')?.value||'';"
        "const giphyScrollState=dropdown=>{let state=dropdown.__apolloGiphyScrollState;if(state)return state;state={top:0,height:dropdown.scrollHeight,at:0,query:giphyQuery(dropdown),open:false};Object.defineProperty(dropdown,'__apolloGiphyScrollState',{value:state,configurable:true});const reset=()=>{state.top=0;state.height=dropdown.scrollHeight;state.at=0;state.query=giphyQuery(dropdown);};dropdown.addEventListener('input',reset,true);dropdown.addEventListener('scroll',()=>{if(!state.open)return;const query=giphyQuery(dropdown);if(query!==state.query){reset();return;}const top=dropdown.scrollTop,height=dropdown.scrollHeight,now=Date.now();if(top>8){if(!state.at||now-state.at>5000||height<=state.height+20)state.height=height;state.top=top;state.at=now;}else if(top<=1&&state.top<=16){state.top=0;state.height=height;state.at=0;}window.__apolloChatScheduleSweep?.();},{passive:true});return state;};"
        "const fixGiphyScroll=()=>{let restored=0;for(const r of roots())for(const dropdown of r.querySelectorAll('.gifs-dropdown')){const state=giphyScrollState(dropdown),rect=dropdown.getBoundingClientRect(),style=getComputedStyle(dropdown),open=rect.width>0&&rect.height>0&&style.display!=='none'&&style.visibility!=='hidden',query=giphyQuery(dropdown),top=dropdown.scrollTop,height=dropdown.scrollHeight,now=Date.now();if(!open){state.open=false;continue;}if(!state.open||query!==state.query){state.open=true;state.query=query;state.top=top;state.height=height;state.at=top>8?now:0;continue;}if(top<=1&&state.top>16&&now-state.at<5000&&height>state.height+20){const target=Math.min(state.top,Math.max(0,height-dropdown.clientHeight));state.top=target;state.height=height;state.at=now;dropdown.scrollTop=target;restored++;}else if(top<=1&&state.at&&now-state.at>=5000){state.top=0;state.height=height;state.at=0;}}return restored;};"
        // Reddit's conversation-profile header combines its width and height
        // utility classes incorrectly for the stock square Snoovatar. Keep the
        // supplied height, but derive width from a 1:1 aspect ratio. Restrict
        // this to the large user-avatar wrapper and Reddit's default-avatar
        // path so custom avatars and every message/header avatar stay native.
        "const fixDefaultProfileAvatars=()=>{if(mailRoute())return 0;let fixed=0;for(const r of roots())for(const img of r.querySelectorAll('img')){let u;try{u=new URL(img.currentSrc||img.src,location.href);}catch(e){continue;}const redditStatic=u.hostname==='redditstatic.com'||u.hostname.endsWith('.redditstatic.com');if(!redditStatic||!u.pathname.startsWith('/avatars/defaults/'))continue;const avatar=img.closest('.user-avatar');if(!avatar)continue;const inner=img.parentElement,shell=inner?.parentElement;if(!inner||!shell||!avatar.contains(shell))continue;shell.style.setProperty('width','auto','important');shell.style.setProperty('aspect-ratio','1 / 1','important');shell.style.setProperty('flex','0 0 auto','important');inner.style.setProperty('width','100%','important');inner.style.setProperty('height','100%','important');img.style.setProperty('display','block','important');img.style.setProperty('width','100%','important');img.style.setProperty('height','100%','important');img.style.setProperty('aspect-ratio','1 / 1','important');img.style.setProperty('object-fit','cover','important');fixed++;}return fixed;};"
        // Reddit's Threads list hard-codes its semantic row text to 12px. At
        // iPhone width that still resolves to only 13.7 points after our page
        // text adjustment, noticeably smaller than Apollo and Reddit's own
        // conversation view. Enlarge only the stable list-row classes; room
        // messages keep their already-correct native sizing.
        "const fixChatListTypography=()=>{if(!chatListRoute())return 0;let fixed=0;for(const r of roots()){for(const e of r.querySelectorAll('.room-name')){e.style.setProperty('font-size','15px','important');e.style.setProperty('line-height','20px','important');fixed++;}for(const e of r.querySelectorAll('.last-message')){e.style.setProperty('font-size','14px','important');e.style.setProperty('line-height','20px','important');fixed++;}for(const e of r.querySelectorAll('.last-message-time')){e.style.setProperty('font-size','12px','important');e.style.setProperty('line-height','20px','important');fixed++;}}return fixed;};"
        // The embedded Inbox supplies native Messages / Requests / Threads
        // navigation. Reddit's root Chat list still renders its own header,
        // filter chips, and Requests / Threads rows above the first room. A
        // negative native crop made those rows invisible at rest but exposed
        // them during WebKit's restored edge bounce. Remove the redundant DOM
        // chrome instead, and repeat on every sweep in case Reddit virtualizes
        // or replaces the list after a status update.
        "const fixEmbeddedMessagesChrome=()=>{if(!window.__apolloEmbeddedInboxMessages||!chatListRoute())return 0;let hidden=0;const hide=e=>{if(!e)return;if(e.style.getPropertyValue('display')!=='none'||e.style.getPropertyPriority('display')!=='important'){e.style.setProperty('display','none','important');}hidden++;};for(const r of roots()){for(const e of r.querySelectorAll('li[data-testid=\"requests-button\"],li[data-testid=\"threads-button\"],rs-rooms-nav-filter-chips'))hide(e);if(r instanceof ShadowRoot&&r.host?.tagName==='RS-ROOMS-NAV'){const home=r.querySelector('a[aria-label=\"Go to Reddit home\"]');let header=home;while(header?.parentElement)header=header.parentElement;hide(header);}}return hidden;};"
        // Apollo's floating tab bar overlaps the bottom of the embedded list
        // routes. The native side measures that overlap and publishes it as
        // __apolloChatBottomAllowance (0 when the tab bar is hidden or the
        // surface is standalone); applying it from the sweep — instead of a
        // one-shot native pass — keeps the extra scroll range alive when
        // Reddit re-creates its virtualized scrollers, and targets both the
        // list's rs-virtual-scroll and the dynamic variant used by rooms and
        // Threads. The pre-hide base padding is remembered per element so a
        // later allowance of 0 restores Reddit's own value exactly.
        "const fixBottomAllowance=()=>{if(mailRoute())return 0;const a=window.__apolloChatBottomAllowance||0;let applied=0;for(const r of roots())for(const e of r.querySelectorAll('rs-virtual-scroll,rs-virtual-scroll-dynamic')){if(e.dataset.apolloNativePaddingBottom===undefined){if(!a)continue;e.dataset.apolloNativePaddingBottom=String(parseFloat(getComputedStyle(e).paddingBottom)||0);}const total=(parseFloat(e.dataset.apolloNativePaddingBottom)||0)+a;const want=total+'px';if(e.style.getPropertyValue('padding-bottom')!==want){e.style.setProperty('padding-bottom',want,'important');e.style.setProperty('scroll-padding-bottom',want,'important');}applied++;}return applied;};"
        // Reddit disables scroll chaining on its virtualized list, which also
        // suppresses WebKit's edge stretch. Restore ordinary touch scrolling
        // on every actual overflow container. UIKit separately enables bounce
        // on the WKChildScrollView created for these elements after hydration.
        "const fixChatScrollPhysics=()=>{if(mailRoute())return 0;let fixed=0;for(const r of roots())for(const e of r.querySelectorAll('*')){const s=getComputedStyle(e),scrollable=(s.overflowY==='auto'||s.overflowY==='scroll')&&(e.scrollHeight>e.clientHeight+1);if(!scrollable&&e.tagName!=='RS-VIRTUAL-SCROLL'&&e.tagName!=='RS-THREADS-VIEW')continue;e.style.setProperty('overscroll-behavior-y','auto','important');e.style.setProperty('-webkit-overflow-scrolling','touch','important');fixed++;}return fixed;};"
        "const blockRedditHomeLogo=()=>{let blocked=0;for(const r of roots())for(const a of r.querySelectorAll('a[href]')){try{const u=new URL(a.href,location.href);if((u.hostname==='reddit.com'||u.hostname.endsWith('.reddit.com'))&&u.pathname==='/'&&u.search===''&&u.hash===''){const area=(a.parentElement?.textContent||'').trim().toLowerCase(),rect=a.getBoundingClientRect();if(area.includes('chats')||rect.top<180){a.setAttribute('aria-disabled','true');a.style.setProperty('pointer-events','none','important');a.style.setProperty('cursor','default','important');blocked++;}}}catch(e){}}return blocked;};"
        // Reddit currently leaves Preview genuinely disabled even after the
        // reply textarea contains text. Preserve its own preview renderer and
        // click handler; only repair the enabled state from the real input.
        "const fixModmailPreview=()=>{if(!mailRoute())return 0;const all=roots().flatMap(r=>[...r.querySelectorAll('*')]);const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden';};const textarea=all.find(e=>e.tagName==='TEXTAREA'&&visible(e)&&e.type!=='hidden');const preview=all.find(e=>e.tagName==='BUTTON'&&(e.textContent||'').trim()==='Preview'&&visible(e));if(!textarea||!preview)return 0;const sync=()=>{const hasText=(textarea.value||'').trim().length>0;if(hasText){if(preview.disabled){preview.disabled=false;preview.removeAttribute('disabled');preview.style.setProperty('pointer-events','auto','important');preview.dataset.apolloPreviewEnabled='true';}}else if(preview.dataset.apolloPreviewEnabled==='true'){preview.disabled=true;preview.setAttribute('disabled','');preview.style.removeProperty('pointer-events');delete preview.dataset.apolloPreviewEnabled;}};if(!textarea.dataset.apolloPreviewListener){textarea.dataset.apolloPreviewListener='true';textarea.addEventListener('input',sync);textarea.addEventListener('change',sync);}sync();return preview.dataset.apolloPreviewEnabled==='true'?1:0;};"
        // The sticky Modmail subject card sits above Reddit's Markdown Help
        // dialog. Fit only that dialog into the actual visual viewport so its
        // close button and final help rows are both reachable on every iPhone.
        "const fitMarkdownHelp=()=>{if(!mailRoute())return 0;const all=roots().flatMap(r=>[...r.querySelectorAll('*')]);let fitted=0;for(const dialog of all.filter(e=>e.tagName==='FACEPLATE-MODAL'||e.getAttribute?.('role')==='dialog')){const text=(dialog.textContent||'').replace(/\\s+/g,' ').trim();if(!text.includes('Markdown Help')&&!text.includes('Markdown is a way to quickly format text'))continue;const viewport=Math.round(window.visualViewport?.height||window.innerHeight||0);let top=96;for(const e of all){if(e===dialog||dialog.contains(e))continue;const b=e.getBoundingClientRect(),label=(e.textContent||'').replace(/\\s+/g,' ').trim();if(label&&b.width>innerWidth*0.8&&b.height>=60&&b.height<=180&&b.top>=0&&b.top<=32&&b.bottom>top)top=Math.ceil(b.bottom+8);}top=Math.min(top,Math.max(96,viewport-220));const height=Math.max(212,viewport-top-8);dialog.style.setProperty('position','fixed','important');dialog.style.setProperty('top',top+'px','important');dialog.style.setProperty('right','12px','important');dialog.style.setProperty('bottom','auto','important');dialog.style.setProperty('left','12px','important');dialog.style.setProperty('width','auto','important');dialog.style.setProperty('height',height+'px','important');dialog.style.setProperty('max-height','none','important');dialog.style.setProperty('overflow','auto','important');dialog.style.setProperty('-webkit-overflow-scrolling','touch','important');dialog.style.setProperty('transform','none','important');dialog.style.setProperty('z-index','2147483647','important');dialog.style.setProperty('box-sizing','border-box','important');fitted++;}return fitted;};"
        // Collect avatar sources BEFORE themeRoots() so a newly seen icon lands
        // in the stylesheet on the same sweep that first sees it.
        "const sweep=()=>{const mailAvatars=collectMailAvatarSrcs();themeRoots();const giphyGrids=fixGiphy();const result={roots:roots().length,mailAvatars,giphyGrids,giphyScrollRestores:fixGiphyScroll(),defaultProfileAvatars:fixDefaultProfileAvatars(),chatListTypography:fixChatListTypography(),embeddedMessagesChrome:fixEmbeddedMessagesChrome(),bottomAllowance:fixBottomAllowance(),chatScrollers:fixChatScrollPhysics(),blockedHomeLinks:blockRedditHomeLogo(),previewFixes:fixModmailPreview(),markdownDialogs:fitMarkdownHelp()};window.__apolloChatReportSurface?.();return result;};"
        "window.__apolloChatEnhancementSweep=sweep;"
        // The hidden preloaded Inbox hub reports document.hidden=true (WebKit
        // derives page visibility from the view hierarchy), so gate the
        // watchdog interval on it: MutationObservers keep coalescing dirty
        // marks through rAF (which WebKit parks until the first visible
        // frame), and the visibilitychange catch-up below sweeps immediately
        // when the hub is revealed. Net effect: zero periodic DOM work —
        // including fixChatScrollPhysics's whole-tree getComputedStyle pass —
        // while Chat is hidden behind Notifications or another tab.
        "if(!window.__apolloChatViewportHooks){window.__apolloChatViewportHooks=true;window.addEventListener('resize',()=>window.__apolloChatScheduleSweep?.());window.visualViewport?.addEventListener('resize',()=>window.__apolloChatScheduleSweep?.());document.addEventListener('DOMContentLoaded',()=>window.__apolloChatScheduleSweep?.(),{once:true});document.addEventListener('visibilitychange',()=>{if(!document.hidden)window.__apolloChatScheduleSweep?.();});}"
        // The MutationObservers + rAF coalescing above are the PRIMARY sweep
        // trigger — every real DOM change lands there. This interval is only
        // a safety net for state the observers can't see (style/layout-only
        // drift), so it runs rarely and never during active scrolling: each
        // sweep does whole-tree getComputedStyle work, and on a 120Hz frame
        // budget (~8ms) a mid-scroll sweep is a visible hitch.
        // Initialize the scroll stamp once (a plain 0 test would re-run on
        // every re-injection and stack duplicate window listeners). observeRoot
        // stamps per-root for shadow scrollers; the window listener here still
        // covers main-document / light-DOM scrolls.
        "if(!window.__apolloChatScrollHooks){window.__apolloChatScrollHooks=true;window.__apolloChatScrollStamp=0;window.addEventListener('scroll',()=>{window.__apolloChatScrollStamp=Date.now();},{capture:true,passive:true});}"
        // Watchdog is a SAFETY NET for style/layout drift the MutationObservers
        // can't see; the observers + rAF are the primary trigger. 2000ms is
        // ~3x slower than the old 700ms (big CPU/battery win Jordan asked for)
        // while capping observer-miss latency at ~2s, and the scroll-skip guard
        // (now shadow-aware) keeps the whole-tree getComputedStyle sweep from
        // ever firing mid-drag.
        "if(!window.__apolloChatEnhancementTimer)window.__apolloChatEnhancementTimer=setInterval(()=>{if(document.hidden)return;if(Date.now()-window.__apolloChatScrollStamp<600)return;window.__apolloChatEnhancementSweep?.();},2000);"
        "return sweep();})()"];
    return script;
}

static NSDictionary<NSString *, NSString *> *ApolloDirectChatCookiePairs(NSString *header) {
    NSMutableDictionary<NSString *, NSString *> *pairs = [NSMutableDictionary dictionary];
    for (NSString *component in [header componentsSeparatedByString:@";"]) {
        NSRange equals = [component rangeOfString:@"="];
        if (equals.location == NSNotFound) continue;
        NSString *name = [[component substringToIndex:equals.location]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *value = [component substringFromIndex:equals.location + 1];
        if (name.length > 0) pairs[name] = value ?: @"";
    }
    return pairs;
}

// Reuse only the WebKit process pool for an unchanged active session. Reddit
// stores the Chat filter (Direct / Group) in website data, so sharing a data
// store made a Threads filter leak into Messages and standalone Chat. Each
// visible controller therefore keeps its own non-persistent cookie/data store;
// only the process is shared, and a username or cookie change creates a new
// process pool.
@interface ApolloModernMailboxWebContext : NSObject
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *cookieHeader;
@property (nonatomic, strong) WKProcessPool *processPool;
@end

@implementation ApolloModernMailboxWebContext
@end

static ApolloModernMailboxWebContext *sApolloModernMailboxWebContext = nil;

static ApolloModernMailboxWebContext *ApolloModernMailboxContextForActiveSession(void) {
    NSString *username = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(username);
    if (session.cookieHeader.length == 0) return nil;

    BOOL unchanged = [sApolloModernMailboxWebContext.username isEqualToString:username] &&
        [sApolloModernMailboxWebContext.cookieHeader isEqualToString:session.cookieHeader];
    if (unchanged) return sApolloModernMailboxWebContext;

    ApolloModernMailboxWebContext *context = [ApolloModernMailboxWebContext new];
    context.username = username;
    context.cookieHeader = session.cookieHeader;
    context.processPool = [WKProcessPool new];
    sApolloModernMailboxWebContext = context;
    ApolloLog(@"[DirectChatWeb] Created account-isolated reusable WebKit process pool for u/%@", username);
    return context;
}

static void ApolloSeedModernMailboxCookies(NSString *cookieHeader,
                                           WKHTTPCookieStore *store,
                                           dispatch_block_t completion) {
    NSDictionary<NSString *, NSString *> *pairs = ApolloDirectChatCookiePairs(cookieHeader ?: @"");
    dispatch_group_t group = dispatch_group_create();
    [pairs enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        NSMutableDictionary *properties = [@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookieDomain: @".reddit.com",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
            NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:24.0 * 60.0 * 60.0],
        } mutableCopy];
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
        if (!cookie) return;
        dispatch_group_enter(group);
        [store setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), completion ?: ^{});
}

static NSString *ApolloModernMailboxUserAgent(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
}

static void *ApolloDirectChatWebViewURLContext = &ApolloDirectChatWebViewURLContext;

typedef NS_ENUM(NSUInteger, ApolloModernMailboxKind) {
    ApolloModernMailboxKindChat = 0,
    ApolloModernMailboxKindModmail,
};

@interface ApolloDirectChatWebViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) UILabel *loadingTitleLabel;
@property (nonatomic, strong) UILabel *loadingDetailLabel;
@property (nonatomic, strong) UIImageView *loadingIconView;
@property (nonatomic, strong) UIButton *reauthenticateButton;
// Every load-error state must carry a visible retry action: the embedded
// Inbox hub has no navigation bar, so the standalone-only refresh bar button
// cannot be the only way out of "Chat couldn't be opened".
@property (nonatomic, strong) UIButton *retryButton;
// Cookie header this controller last seeded into its private WKWebsiteDataStore
// (apollo_seedAndLoad). Together with `username` this is the controller's
// session identity, checked by ApolloModernChatControllerSessionIsCurrent.
@property (nonatomic, copy) NSString *seededCookieHeader;
// Reddit's web client stops syncing while its document is hidden or the app
// is suspended, and does not reliably catch up when it comes back — the list
// stays stale until something forces a navigation. Track when this surface
// last went away (hub hidden behind Notifications, app resigned active, or
// the standalone controller disappeared) so returning after a real absence
// can replay the current list load automatically.
@property (nonatomic) NSTimeInterval chatWentAwayAt;
// Mirrors the Inbox hub's cross-fade state (child appearance callbacks never
// fire for it): YES while Chat is the visible Inbox mode.
@property (nonatomic) BOOL embeddedInboxVisible;
@property (nonatomic, copy) NSString *username;
// A validated same-origin Reddit path supplied by a notification deep link.
// Keeping only the path (never an arbitrary URL) preserves the isolated
// cookie store's security boundary.
@property (nonatomic, copy) NSString *initialDestinationPath;
@property (nonatomic, assign) BOOL didRevealChat;
@property (nonatomic, assign) NSUInteger readinessGeneration;
@property (nonatomic, assign) BOOL modmailTransitionPending;
@property (nonatomic, assign) NSUInteger modmailTransitionGeneration;
@property (nonatomic, assign) BOOL modmailTransitionIsList;
@property (nonatomic, assign) NSTimeInterval modmailTransitionStartedAt;
// Chat-side counterpart of the Modmail thread transition. Reddit's Chat rooms
// and its reloaded Messages list both render progressively (skeletons, late
// usernames/avatars, image loads, scroll corrections), so a bare transition
// visibly "settles into place". While pending, the web document stays covered
// by the themed native background and a DOM-stability probe owns the reveal.
@property (nonatomic, assign) BOOL chatTransitionPending;
@property (nonatomic, assign) NSUInteger chatTransitionGeneration;
@property (nonatomic, assign) BOOL chatTransitionIsList;
// Last aligned web-view top offsets measured by the embedded align passes.
// Returning to a list from a room re-runs apollo_updateEmbeddedWebChromeForURL
// before the async re-measure lands; restoring the remembered constant instead
// of the generic default keeps the list from hopping by the breathing gap.
@property (nonatomic, assign) CGFloat messagesAlignedTopOffset;
@property (nonatomic, assign) CGFloat threadsAlignedTopOffset;
// Previous main-document path seen by the URL observer, for detecting the
// direction of same-document SPA route changes (list -> room, room -> list).
@property (nonatomic, copy) NSString *lastObservedWebPath;
// When the swipe driver last issued a "back to the conversation list".
// Reddit flips its panes immediately but the URL is only repaired a beat
// later (the interception's guarded history.back()), so the route still
// reads as a conversation for ~100ms after a successful back — a second back
// in that window would walk PAST the list. Reset on entering a conversation
// so re-opening a room re-arms the gesture at once.
@property (nonatomic, assign) NSTimeInterval conversationBackIssuedAt;
// The conversation list exactly as it was rendered when the current
// conversation was opened. A room is a web route inside this one web view,
// so there is no second view to reveal behind it during an interactive back —
// this still frame stands in for it while the drag runs, and is swapped for
// the live (identical) list once the panes have actually flipped.
@property (nonatomic, strong) UIView *conversationBackSnapshot;
@property (nonatomic, strong) UIView *conversationBackDimView;
@property (nonatomic, assign) BOOL conversationBackInteractive;
@property (nonatomic, assign) CGFloat conversationBackDirection;
// Bumped by every drag that takes the conversation. A settle animation from
// an earlier drag carries its own value and leaves the shared state alone if a
// newer drag has already claimed these views — the same guard the hub's
// sInboxSwipeGeneration gives the tab-switch pages.
@property (nonatomic, assign) NSUInteger conversationBackGeneration;
// What the page itself shows, reported by the enhancement script whenever it
// changes: YES while Reddit's in-room Back control is on screen, i.e. a
// conversation pane is the visible surface. The URL observer is the primary
// route source, but a room opened from the list is a same-document SPA
// transition, and on a device (iOS 26.6) that transition has been seen to
// deliver no URL change at all: the room was on screen while every route read
// still said "/chat", so a back swipe switched to Notifications instead of
// returning to the list, and the tab bar stayed over the composer. The page
// report closes that gap — the swipe hierarchy and the room treatments key
// on either source (apollo_isInsideConversation).
@property (nonatomic, assign) BOOL pageConversationVisible;
// YES while the room treatments (tab bar, composer inset) came from the page
// report because the route never reported the room; cleared when the route
// catches up or the page reports the list again.
@property (nonatomic, assign) BOOL pageConversationTreatmentsApplied;
// A fresh, isolated WKWebView can leave Reddit's Modmail bundle waiting
// forever when /mail/all is its very first document. Prime the authenticated
// reddit.com client through the known-good Chat route, then replace it with
// Modmail before revealing anything to the user.
@property (nonatomic, assign) BOOL modmailWarmupPending;
@property (nonatomic, strong) UIColor *originalNavigationTintColor;
@property (nonatomic, assign) BOOL didCaptureOriginalNavigationTintColor;
@property (nonatomic, assign) ApolloModernMailboxKind mailboxKind;
// A native Reddit destination opened from this mailbox lives in a different
// tab's navigation controller. This flag marks the temporary return path.
@property (nonatomic, assign) BOOL nativeReturnPathActive;
// Missing/expired web sessions are recoverable in place. Keep the prompt state
// on the mailbox controller so an automatic first offer never turns into a
// cancel/re-present loop; the visible button remains available for later retry.
@property (nonatomic, assign) BOOL authenticationRequired;
@property (nonatomic, assign) BOOL authenticationPromptVisible;
@property (nonatomic, assign) BOOL authenticationPromptAutomaticallyOffered;
// The All Inbox owns the visible tabs and navigation chrome. In embedded mode
// the web controller supplies only the conversation content beneath them.
@property (nonatomic, assign) BOOL embeddedInInbox;
@property (nonatomic, assign) ApolloModernChatInboxSection embeddedInboxSection;
@property (nonatomic, strong) NSLayoutConstraint *webViewTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *webViewBottomConstraint;
@property (nonatomic, strong) ApolloModernMailboxWebContext *webContext;
@property (nonatomic, strong) NSDate *loadStartedAt;
@property (nonatomic, assign) NSUInteger bounceConfiguredScrollViewCount;
@property (nonatomic, assign) CGFloat lastAppliedBottomScrollAllowance;
@property (nonatomic, assign) NSUInteger bottomScrollAllowanceGeneration;
@property (nonatomic, strong) NSTimer *chatStatusRefreshTimer;
@property (nonatomic, assign) BOOL mailboxConversationHidesTabBar;
// Set once a standalone mailbox discovers its seeded account is no longer the
// active one; the controller blanks itself and leaves its navigation stack.
@property (nonatomic, assign) BOOL sessionIdentityInvalidated;
- (BOOL)apollo_urlMatchesMailboxRoute:(NSURL *)url;
- (BOOL)apollo_isModmailConversationURL:(NSURL *)url;
- (BOOL)apollo_isModmailListURL:(NSURL *)url;
- (BOOL)apollo_isConversationURL:(NSURL *)url;
- (void)apollo_updateTabBarVisibilityForURL:(NSURL *)url animated:(BOOL)animated;
- (void)apollo_restoreTabBarVisibility;
- (void)apollo_beginModmailTransitionToURL:(NSURL *)url isList:(BOOL)isList;
- (void)apollo_waitForModmailStabilityAttempt:(NSUInteger)attempt
                                         generation:(NSUInteger)generation
                                      lastSignature:(NSString *)lastSignature
                                      stableSamples:(NSUInteger)stableSamples;
- (void)apollo_finishModmailTransitionForGeneration:(NSUInteger)generation;
- (BOOL)apollo_isChatConversationPath:(NSString *)path;
- (NSString *)apollo_currentChatPath;
- (BOOL)apollo_isInsideConversation;
- (void)apollo_notePageConversationVisible:(BOOL)visible reportedPath:(NSString *)reportedPath;
- (void)apollo_reconcilePageSurfaceReportedPath:(NSString *)reportedPath;
- (void)apollo_noteTouchBeganOnPage;
- (void)apollo_resettleEmbeddedListForPath:(NSString *)path;
- (BOOL)apollo_goBackToConversationList;
- (void)apollo_captureConversationBackSnapshot;
- (BOOL)apollo_beginInteractiveConversationBack;
- (void)apollo_updateInteractiveConversationBack:(CGFloat)progress;
- (void)apollo_finishInteractiveConversationBack:(BOOL)commit velocity:(CGFloat)velocity;
- (void)apollo_waitForConversationBackSwap:(UIView *)snapshot attempt:(NSUInteger)attempt;
- (void)apollo_endInteractiveConversationBack;
- (void)apollo_standaloneConversationBackPanned:(UIPanGestureRecognizer *)pan;
- (void)apollo_beginChatTransitionToURL:(NSURL *)url isList:(BOOL)isList;
- (void)apollo_waitForChatTransitionStabilityAttempt:(NSUInteger)attempt
                                          generation:(NSUInteger)generation
                                       lastSignature:(NSString *)lastSignature
                                       stableSamples:(NSUInteger)stableSamples;
- (void)apollo_finishChatTransitionForGeneration:(NSUInteger)generation;
- (void)apollo_revealChatTransition:(BOOL)isList;
- (void)apollo_pinCoveredConversationToLatestForGeneration:(NSUInteger)generation
                                                   attempt:(NSUInteger)attempt;
- (void)apollo_cancelChatTransition;
- (void)apollo_revealChat;
- (void)apollo_openConversationPath:(NSString *)path;
- (void)apollo_routeURLOutsideMailbox:(NSURL *)url;
- (void)apollo_prepareForMailboxReturnAnimated:(BOOL)animated;
- (void)apollo_showAuthenticationError:(NSString *)detail automaticallyPrompt:(BOOL)automaticallyPrompt;
- (void)apollo_presentAuthenticationPrompt;
- (void)apollo_showEmbeddedInboxSection:(ApolloModernChatInboxSection)section;
- (void)apollo_showEmbeddedInboxSection:(ApolloModernChatInboxSection)section forceReload:(BOOL)forceReload;
- (void)apollo_refreshAfterAwayIfStale;
- (void)apollo_clearEmbeddedChatTypeFiltersForGeneration:(NSUInteger)generation
                                               completion:(void (^)(BOOL changed))completion;
- (void)apollo_applyEmbeddedInboxFilterAttempt:(NSUInteger)attempt generation:(NSUInteger)generation;
- (void)apollo_alignEmbeddedMessagesForGeneration:(NSUInteger)generation
                                        completion:(dispatch_block_t)completion;
- (void)apollo_alignEmbeddedThreadsForGeneration:(NSUInteger)generation
                                       completion:(dispatch_block_t)completion;
- (void)apollo_updateEmbeddedWebChromeForURL:(NSURL *)url;
- (void)apollo_startChatStatusRefreshIfNeeded;
- (void)apollo_applicationDidBecomeActive:(NSNotification *)notification;
- (void)apollo_applicationWillResignActive:(NSNotification *)notification;
- (void)apollo_enableNativeScrollBounce;
- (void)apollo_applyEmbeddedBottomScrollAllowance:(CGFloat)bottomAllowance;
@end

// A CSS overflow scroller inside WKWebView is represented by a private
// WKChildScrollView that does not exist yet when the WKWebView itself is
// created. Configuring only webView.scrollView therefore leaves Reddit's real
// conversation list with a hard edge. Walk the public UIView hierarchy and
// apply normal iOS bounce behavior to every scroll view after hydration too.
//
static NSUInteger ApolloConfigureEmbeddedScrollViews(UIView *view) {
    if (!view) return 0;
    NSUInteger configured = 0;
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        scrollView.bounces = YES;
        scrollView.alwaysBounceVertical = YES;
        configured += 1;
    }
    for (UIView *subview in view.subviews) {
        configured += ApolloConfigureEmbeddedScrollViews(subview);
    }
    return configured;
}

static NSString *ApolloValidatedModernMailboxPath(ApolloModernMailboxKind kind,
                                                   NSString *candidate) {
    if (![candidate isKindOfClass:[NSString class]] || candidate.length == 0) return nil;

    NSString *decoded = [candidate stringByRemovingPercentEncoding] ?: candidate;
    if (![decoded hasPrefix:@"/"] || [decoded hasPrefix:@"//"] ||
        [decoded containsString:@"\\"] || [decoded containsString:@".."] ||
        [decoded containsString:@"?"] || [decoded containsString:@"#"]) {
        return nil;
    }

    BOOL valid = kind == ApolloModernMailboxKindModmail
        ? ([decoded isEqualToString:@"/mail"] || [decoded hasPrefix:@"/mail/"])
        : ([decoded isEqualToString:@"/chat"] || [decoded hasPrefix:@"/chat/"]);
    return valid ? decoded : nil;
}

static const void *kApolloMailboxReturnControllerKey = &kApolloMailboxReturnControllerKey;
static const void *kApolloMailboxReturnAnchorKey = &kApolloMailboxReturnAnchorKey;

static ApolloDirectChatWebViewController *ApolloMailboxReturnController(UINavigationController *navigationController) {
    return objc_getAssociatedObject(navigationController, kApolloMailboxReturnControllerKey);
}

static UIViewController *ApolloMailboxReturnAnchor(UINavigationController *navigationController) {
    return objc_getAssociatedObject(navigationController, kApolloMailboxReturnAnchorKey);
}

static void ApolloClearMailboxReturn(UINavigationController *navigationController) {
    ApolloDirectChatWebViewController *mailbox = ApolloMailboxReturnController(navigationController);
    mailbox.nativeReturnPathActive = NO;
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnControllerKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnAnchorKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloStoreMailboxReturn(UINavigationController *navigationController,
                                     ApolloDirectChatWebViewController *mailbox,
                                     UIViewController *anchor) {
    ApolloClearMailboxReturn(navigationController);
    mailbox.nativeReturnPathActive = YES;
    mailbox.hidesBottomBarWhenPushed =
        [mailbox apollo_isConversationURL:mailbox.webView.URL];
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnControllerKey,
                             mailbox, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navigationController, kApolloMailboxReturnAnchorKey,
                             anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloReturnToMailboxFromNavigationController(UINavigationController *navigationController) {
    ApolloDirectChatWebViewController *mailbox = ApolloMailboxReturnController(navigationController);
    UINavigationController *mailboxNavigationController = mailbox.navigationController;
    UITabBarController *tabBarController = navigationController.tabBarController ?: mailbox.tabBarController;
    if (!mailbox || !mailboxNavigationController || !tabBarController ||
        ![mailboxNavigationController.viewControllers containsObject:mailbox]) {
        ApolloClearMailboxReturn(navigationController);
        return NO;
    }

    ApolloClearMailboxReturn(navigationController);
    [mailbox apollo_prepareForMailboxReturnAnimated:NO];
    tabBarController.selectedViewController = mailboxNavigationController;
    ApolloLog(@"[DirectChatWeb] Native Back returned to preserved %@ without mutating Inbox navigation",
              mailbox.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat");
    return YES;
}

// The standalone Chat screen's back-pan — a process singleton, like the Inbox
// hub's mode-pan. See the "Standalone conversation back-swipe" section below
// the class for the rationale and the wiring.
static UIPanGestureRecognizer *sStandaloneChatBackPan = nil;
static __weak ApolloDirectChatWebViewController *sStandaloneChatBackPanHost = nil;
static NSHashTable<UIGestureRecognizer *> *sStandaloneChatBackPanWired = nil;
static BOOL sStandaloneChatBackInteractive = NO;   // NO = the release takes the instant step
static void ApolloStandaloneChatBackPanInstall(ApolloDirectChatWebViewController *controller);
static void ApolloStandaloneChatBackPanForgetHost(ApolloDirectChatWebViewController *controller);
// The most recently created mailbox controller: its cookie jar is the bearer
// source the chat poller and room directory read (see the %ctor registration).
static __weak ApolloDirectChatWebViewController *sLatestMailboxWebController = nil;

// Name of the page's surface report (see pageConversationVisible).
static NSString * const ApolloDirectChatSurfaceMessageName = @"apolloChatSurface";

// WKUserContentController retains its script message handlers; routing them
// through a weak proxy keeps the web view's configuration from retaining the
// controller back (which would keep its status timer and observers alive
// forever).
@interface ApolloDirectChatScriptMessageProxy : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation ApolloDirectChatScriptMessageProxy
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}
@end

// Watches touches without taking them: reports the first touch of every
// sequence and fails at once, so no other recognizer ever waits on it.
@interface ApolloDirectChatTouchObserver : UIGestureRecognizer
@property (nonatomic, copy) void (^onTouchBegan)(void);
@end

@implementation ApolloDirectChatTouchObserver
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (self.onTouchBegan) self.onTouchBegan();
    self.state = UIGestureRecognizerStateFailed;
}
@end

@implementation ApolloDirectChatWebViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    sLatestMailboxWebController = self;
    self.title = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Moderator Mail" : @"Reddit Chat";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.clipsToBounds = YES;
    self.messagesAlignedTopOffset = NAN;
    self.threadsAlignedTopOffset = NAN;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.webContext = ApolloModernMailboxContextForActiveSession();
    // Each controller gets a fresh private data store. Reusing that store made
    // Reddit's selected Group chip survive when navigating from Threads to
    // Messages, which is both confusing and capable of hiding real messages.
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.processPool = self.webContext.processPool ?: [WKProcessPool new];
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.customUserAgent = ApolloModernMailboxUserAgent();
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    [self.webView addObserver:self
                  forKeyPath:@"URL"
                     options:NSKeyValueObservingOptionNew
                     context:ApolloDirectChatWebViewURLContext];
    // The page reports which surface it shows (pageConversationVisible). The
    // web view's configuration is a copy, but its user content controller is
    // the shared object the user scripts are added to below.
    ApolloDirectChatScriptMessageProxy *surfaceProxy = [ApolloDirectChatScriptMessageProxy new];
    surfaceProxy.target = self;
    [self.webView.configuration.userContentController addScriptMessageHandler:surfaceProxy
                                                                         name:ApolloDirectChatSurfaceMessageName];
    if (self.mailboxKind == ApolloModernMailboxKindChat) {
        // See apollo_noteTouchBeganOnPage. Recognizers on this view receive
        // every touch that lands in the web view's subtree.
        ApolloDirectChatTouchObserver *touchObserver = [ApolloDirectChatTouchObserver new];
        touchObserver.cancelsTouchesInView = NO;
        touchObserver.delaysTouchesBegan = NO;
        touchObserver.delaysTouchesEnded = NO;
        __weak typeof(self) weakSelf = self;
        touchObserver.onTouchBegan = ^{ [weakSelf apollo_noteTouchBeganOnPage]; };
        [self.view addGestureRecognizer:touchObserver];
    }
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.opaque = YES;
    self.webView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // WKWebView only enables the familiar iOS stretch/bounce when content is
    // taller than its frame by default. Chat's empty and short lists should
    // still feel native when pulled at either edge.
    self.webView.scrollView.bounces = YES;
    self.webView.scrollView.alwaysBounceVertical = YES;
    // Keep Reddit's asynchronous Chat bootstrap hidden; only reveal the mobile
    // Chat document after its request list or composer has actually hydrated.
    self.webView.alpha = 0.0;
    self.webView.userInteractionEnabled = NO;
    [self.view addSubview:self.webView];
    // The parent Inbox view already ends below its native controls and above
    // Apollo's tab bar. Use those exact embedded bounds rather than adding a
    // second safe-area inset. On Messages, crop Reddit's redundant Chats,
    // Requests, and Threads navigation rows so the first conversation begins
    // beneath Apollo's tabs. The dedicated Threads route contains real reply
    // threads and is not cropped. Conversation rooms retain their web header
    // because it contains the participant and Back control.
    NSLayoutYAxisAnchor *webTopAnchor = self.embeddedInInbox
        ? self.view.topAnchor : self.view.safeAreaLayoutGuide.topAnchor;
    NSLayoutYAxisAnchor *webBottomAnchor = self.embeddedInInbox
        ? self.view.bottomAnchor : self.view.safeAreaLayoutGuide.bottomAnchor;
    CGFloat initialTopOffset = 0.0;
    if (self.embeddedInInbox) {
        // Requests has a useful "Additional requests" row and empty state just
        // below its duplicate title, while Messages has a much taller
        // Chats/Requests/Threads header. The Messages value is only a safe
        // fallback; after hydration we measure its first real row precisely.
        if (self.embeddedInboxSection == ApolloModernChatInboxSectionRequests) {
            initialTopOffset = -54.0;
        } else if (self.embeddedInboxSection == ApolloModernChatInboxSectionThreads) {
            initialTopOffset = 8.0;
        } else {
            initialTopOffset = -213.0;
        }
    }
    self.webViewTopConstraint = [self.webView.topAnchor constraintEqualToAnchor:webTopAnchor
                                                                        constant:initialTopOffset];
    self.webViewBottomConstraint = [self.webView.bottomAnchor
        constraintEqualToAnchor:webBottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // Keep Reddit's conversation composer below Apollo's navigation bar
        // and above the home indicator/keyboard instead of drawing underneath
        // either chrome surface.
        self.webViewTopConstraint,
        self.webViewBottomConstraint,
    ]];

    self.loadingView = [UIView new];
    self.loadingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingView.backgroundColor = UIColor.systemBackgroundColor;
    [self.view addSubview:self.loadingView];
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.loadingView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.loadingView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.loadingView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    NSString *iconName = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"shield.lefthalf.filled" : @"bubble.left.and.bubble.right.fill";
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName]];
    self.loadingIconView = iconView;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = [UIColor colorWithRed:0.93 green:0.12 blue:0.76 alpha:1.0];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:46.0],
        [iconView.heightAnchor constraintEqualToConstant:46.0],
    ]];

    self.loadingTitleLabel = [UILabel new];
    self.loadingTitleLabel.text = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"Opening Moderator Mail" : @"Opening Reddit Chat";
    self.loadingTitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.loadingTitleLabel.textColor = UIColor.labelColor;
    self.loadingTitleLabel.textAlignment = NSTextAlignmentCenter;

    self.loadingDetailLabel = [UILabel new];
    self.loadingDetailLabel.text = @"Preparing your private session…";
    self.loadingDetailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.loadingDetailLabel.textColor = UIColor.secondaryLabelColor;
    self.loadingDetailLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingDetailLabel.numberOfLines = 2;

    self.reauthenticateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.reauthenticateButton.hidden = YES;
    self.reauthenticateButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.reauthenticateButton.layer.cornerRadius = 12.0;
    self.reauthenticateButton.layer.borderWidth = 1.0;
    self.reauthenticateButton.contentEdgeInsets = UIEdgeInsetsMake(11.0, 22.0, 11.0, 22.0);
    [self.reauthenticateButton setTitle:@"Sign In Again" forState:UIControlStateNormal];
    [self.reauthenticateButton addTarget:self
                                  action:@selector(apollo_presentAuthenticationPrompt)
                        forControlEvents:UIControlEventTouchUpInside];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.retryButton.hidden = YES;
    self.retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.retryButton.layer.cornerRadius = 12.0;
    self.retryButton.layer.borderWidth = 1.0;
    self.retryButton.contentEdgeInsets = UIEdgeInsetsMake(11.0, 22.0, 11.0, 22.0);
    [self.retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
    [self.retryButton addTarget:self
                         action:@selector(apollo_reloadChat)
               forControlEvents:UIControlEventTouchUpInside];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    UIStackView *loadingStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        iconView, self.loadingTitleLabel, self.loadingDetailLabel, self.spinner,
        self.retryButton, self.reauthenticateButton
    ]];
    loadingStack.translatesAutoresizingMaskIntoConstraints = NO;
    loadingStack.axis = UILayoutConstraintAxisVertical;
    loadingStack.alignment = UIStackViewAlignmentCenter;
    loadingStack.spacing = 10.0;
    [self.loadingView addSubview:loadingStack];
    [NSLayoutConstraint activateConstraints:@[
        [loadingStack.centerXAnchor constraintEqualToAnchor:self.loadingView.centerXAnchor],
        [loadingStack.centerYAnchor constraintEqualToAnchor:self.loadingView.centerYAnchor constant:-24.0],
        [loadingStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.loadingView.leadingAnchor constant:30.0],
        [loadingStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.loadingView.trailingAnchor constant:-30.0],
    ]];
    [self.spinner startAnimating];

    if (!self.embeddedInInbox) {
        UIBarButtonItem *reload = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(apollo_reloadChat)];
        self.navigationItem.rightBarButtonItem = reload;
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_activeThemeChanged:)
                                                 name:@"com.christianselig.ApolloSpecificThemeChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_applicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    // A standalone mailbox retained on some navigation stack must never keep
    // showing — or compose as — an account the user has switched away from.
    // The embedded Inbox hub is torn down by InboxViewController's own
    // account-change hook; standalone controllers watch for themselves.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_activeRedditAccountChanged:)
                                                 name:@"com.christianselig.RedditCurrentAccountChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(apollo_activeRedditAccountChanged:)
                                                 name:@"com.christianselig.RedditAccountChanged"
                                               object:nil];
    [self apollo_applyActiveTheme];
    [self apollo_seedAndLoad];
}

// The hard privacy line is the USERNAME: account A's conversations rendering
// (or a reply sending) while account B is active. Cookie drift for the same
// user — rotation, a silent re-harvest — deliberately does not eject: the
// page's own session keeps working server-side, and yanking a controller
// mid-conversation over a snapshot delta would destroy a half-typed reply
// for no privacy gain. (An actually-dead session still lands in the existing
// Sign In Again flow.)
- (BOOL)apollo_sessionIdentityIsStale {
    if (self.embeddedInInbox) return NO;
    NSString *seededUsername = self.username.lowercaseString ?: @"";
    NSString *activeUsername = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    return seededUsername.length > 0 && ![seededUsername isEqualToString:activeUsername];
}

- (void)apollo_activeRedditAccountChanged:(__unused NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self apollo_ejectIfSessionIdentityStale];
    });
}

- (void)apollo_ejectIfSessionIdentityStale {
    // An already-invalidated controller is a blanked zombie: eject it even if
    // the user has since switched back to the account it was seeded for.
    if (!self.sessionIdentityInvalidated && ![self apollo_sessionIdentityIsStale]) return;
    if (!self.sessionIdentityInvalidated) {
        self.sessionIdentityInvalidated = YES;
        ApolloLog(@"[DirectChatWeb] Ejecting stale %@ mailbox seeded for u/%@ after an account switch",
                  self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat",
                  self.username.lowercaseString ?: @"");
        // Stop the wrong-account surface immediately even while buried in a
        // navigation stack: no further rendering, loads, or status scrapes
        // with the old account's cookies. Hiding beats loading about:blank —
        // it takes effect synchronously and never runs the navigation
        // delegate's routing logic.
        [self.webView stopLoading];
        self.webView.hidden = YES;
        [self.chatStatusRefreshTimer invalidate];
        self.chatStatusRefreshTimer = nil;
    }
    UINavigationController *navigationController = self.navigationController;
    if (navigationController) {
        if (navigationController.topViewController == self && self.viewIfLoaded.window != nil) {
            [navigationController popViewControllerAnimated:NO];
        } else if ([navigationController.viewControllers containsObject:self]) {
            NSMutableArray *stack = [navigationController.viewControllers mutableCopy];
            [stack removeObject:self];
            navigationController.viewControllers = stack;
        }
    } else if (self.presentingViewController) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self apollo_updateEmbeddedWebChromeForURL:self.webView.URL];
    [self apollo_enableNativeScrollBounce];
}

- (void)apollo_enableNativeScrollBounce {
    CGFloat bottomAllowance = 0.0;
    UITabBar *tabBar = self.tabBarController.tabBar;
    if (self.embeddedInInbox && tabBar && !tabBar.hidden && tabBar.alpha > 0.01 &&
        tabBar.window && self.webView.window) {
        CGRect tabBarFrame = [tabBar convertRect:tabBar.bounds toView:self.webView];
        CGFloat overlap = CGRectGetMaxY(self.webView.bounds) - CGRectGetMinY(tabBarFrame);
        if (overlap > 0.0) bottomAllowance = overlap + 12.0;
    }
    NSUInteger configured = ApolloConfigureEmbeddedScrollViews(self.webView);
    BOOL countChanged = configured != self.bounceConfiguredScrollViewCount;
    BOOL allowanceChanged = fabs(bottomAllowance - self.lastAppliedBottomScrollAllowance) > 0.5;
    BOOL generationChanged = self.bottomScrollAllowanceGeneration != self.readinessGeneration;
    self.bounceConfiguredScrollViewCount = configured;
    self.lastAppliedBottomScrollAllowance = bottomAllowance;
    self.bottomScrollAllowanceGeneration = self.readinessGeneration;
    // Publish 0 too: entering a room hides the tab bar, and the sweep then
    // restores Reddit's own scroller padding instead of leaving a stale gap.
    if (countChanged || allowanceChanged || generationChanged) {
        [self apollo_applyEmbeddedBottomScrollAllowance:bottomAllowance];
    }
    if (countChanged || allowanceChanged || generationChanged) {
        ApolloLog(@"[DirectChatWeb] Enabled Apollo-style bounce on %lu WebKit scroll view(s), bottom allowance %.1fpt",
                  (unsigned long)configured, bottomAllowance);
    }
}

// WKChildScrollView accepts bounces, but WebKit immediately resets its native
// contentInset to zero because the scroll range belongs to a CSS overflow
// element. Publish the measured tab-bar overlap to the page instead; the
// enhancement sweep's fixBottomAllowance pads Reddit's actual virtualized
// scrollers (rs-virtual-scroll on the Messages list, the dynamic variant in
// rooms and Threads) so the last row and the final reply composer can rest
// above Apollo's floating tab bar — and keeps re-applying it whenever Reddit
// re-creates those elements. Publishing 0 restores Reddit's own padding.
- (void)apollo_applyEmbeddedBottomScrollAllowance:(CGFloat)bottomAllowance {
    if (!self.embeddedInInbox) return;
    NSString *script = [NSString stringWithFormat:
        @"window.__apolloChatBottomAllowance=%.1f;window.__apolloChatScheduleSweep?.();",
        MAX(0.0, bottomAllowance)];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}

- (void)dealloc {
    // The standalone back-pan holds its action target unretained; strip this
    // controller's pair so the immortal pan can never message a dead host
    // (removeTarget: matches by pointer — a no-op for every other host).
    ApolloStandaloneChatBackPanForgetHost(self);
    [self.chatStatusRefreshTimer invalidate];
    [self.webView removeObserver:self
                     forKeyPath:@"URL"
                        context:ApolloDirectChatWebViewURLContext];
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:ApolloDirectChatSurfaceMessageName];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == ApolloDirectChatWebViewURLContext) {
        id nextValue = change[NSKeyValueChangeNewKey];
        NSURL *url = [nextValue isKindOfClass:[NSURL class]]
            ? nextValue : self.webView.URL;
        NSString *previousPath = self.lastObservedWebPath;
        NSString *path = url.path ?: @"";
        self.lastObservedWebPath = path;
        // Modmail opens conversations and returns to its list through
        // same-document SPA transitions that deliver no navigation callback at
        // all, so this observer is the only place they can be covered. Arm the
        // cover BEFORE the tab-bar update below: showing or hiding the shared
        // tab bar resizes the web view, and that reflow belongs behind the
        // cover too. Only a real path change counts — query/fragment mutations
        // inside an already-revealed route must not re-cover it.
        if (self.mailboxKind == ApolloModernMailboxKindModmail && url &&
            ![path isEqualToString:previousPath]) {
            BOOL isConversation = [self apollo_isModmailConversationURL:url];
            BOOL isList = [self apollo_isModmailListURL:url];
            if ((isConversation || isList) && !self.modmailTransitionPending &&
                !self.webView.loading) {
                [self apollo_beginModmailTransitionToURL:url isList:isList];
            }
        }
        [self apollo_updateTabBarVisibilityForURL:url animated:NO];
        [self apollo_updateEmbeddedWebChromeForURL:url];
        if (self.mailboxKind == ApolloModernMailboxKindChat && url) {
            BOOL isConversation = [self apollo_isChatConversationPath:path];
            BOOL wasConversation = [self apollo_isChatConversationPath:previousPath];
            BOOL previousWasRootList = [previousPath isEqualToString:@"/chat"] ||
                [previousPath isEqualToString:@"/chat/"];
            // Whether the page already showed this room before the route
            // reported it (pageConversationVisible): the room treatments are
            // in place and the room has painted, so the route is only catching
            // up — no fresh frame (it would be the room, not the list) and no
            // cover (it would blank a room the user is reading).
            BOOL pageAlreadyShowing = self.pageConversationTreatmentsApplied;
            if (![path isEqualToString:previousPath]) {
                ApolloLog(@"[DirectChatWeb] Chat route %@ -> %@%@",
                          previousPath.length ? previousPath : @"(none)", path,
                          pageAlreadyShowing ? @" (the page showed the room first)" : @"");
            }
            if (isConversation && !wasConversation) {
                // Record whether this room has the embedded Messages list as
                // its same-document history entry. The enhancement script's
                // back interception uses it to choose an instant history.back()
                // pane restore over a full /chat reload.
                [self.webView evaluateJavaScript:[NSString stringWithFormat:
                    @"window.__apolloChatRoomFromList=%@;",
                    previousWasRootList ? @"true" : @"false"]
                               completionHandler:nil];
                // A freshly entered conversation is also a fresh back target:
                // whatever the swipe driver did on the way out of the last one
                // must not swallow the first back gesture in this one.
                self.conversationBackIssuedAt = 0.0;
                // Grab the list while it is still the rendered frame — this
                // observer runs in the same turn as Reddit's pane swap, before
                // the room paints and before the transition cover blanks the
                // document — so an interactive back has something to reveal.
                if (!pageAlreadyShowing) [self apollo_captureConversationBackSnapshot];
                // WebKit re-creates its content view (and the history edge
                // recognizers on it) across navigations; entering a room is
                // exactly when the standalone back-pan must already outrank
                // them.
                ApolloStandaloneChatBackPanInstall(self);
            }
            if (isConversation) {
                // The route owns the room again from here.
                self.pageConversationTreatmentsApplied = NO;
                // Same-document room switches sometimes deliver no policy
                // callback at all; this observer is the fallback cover hook.
                // Only a real path change counts — query/fragment mutations
                // inside an already-revealed room must not re-cover it.
                if (!pageAlreadyShowing && !self.chatTransitionPending && !self.webView.loading &&
                    ![path isEqualToString:previousPath]) {
                    [self apollo_beginChatTransitionToURL:url isList:NO];
                }
            } else if (self.chatTransitionPending && !self.chatTransitionIsList) {
                // The user left the covered conversation (history back, edge
                // swipe) before it stabilized — reveal the list immediately.
                [self apollo_finishChatTransitionForGeneration:self.chatTransitionGeneration];
            }
            // A same-document return from a conversation (Reddit's pane flip
            // with the URL repaired by the intercepted back control, or the
            // edge swipe) keeps the fully-hydrated list pane alive; only the
            // list's sanity pass runs.
            if (wasConversation && !isConversation) {
                [self apollo_resettleEmbeddedListForPath:path];
                // If the room pane is in fact still on screen (the route
                // dropped to the list under it), the page report restores
                // the room treatments; in a normal return the page has
                // reported the list well before this fires.
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf apollo_reconcilePageSurfaceReportedPath:@"(route left the room)"];
                });
            }
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)viewWillAppear:(BOOL)animated {
    // Belt for a stale controller that reappears before (or without) the
    // account-change notification path ejecting it: never show the old
    // account's content, and leave the stack as soon as the transition
    // machinery allows.
    if (self.sessionIdentityInvalidated || [self apollo_sessionIdentityIsStale]) {
        self.webView.hidden = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self apollo_ejectIfSessionIdentityStale];
        });
    }
    if (self.nativeReturnPathActive) {
        [self apollo_prepareForMailboxReturnAnimated:animated];
    } else {
        [self apollo_updateTabBarVisibilityForURL:self.webView.URL animated:animated];
    }
    [super viewWillAppear:animated];
    [self apollo_applyActiveTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Apollo's full-width back/forward pans live on the navigation
    // controller's container view, which this view only reaches once it is on
    // screen — so the standalone back-pan is claimed and wired here. (No-op
    // for the embedded hub controller, whose gesture is the hub's mode-pan.)
    ApolloStandaloneChatBackPanInstall(self);
    if (self.didRevealChat && self.mailboxKind == ApolloModernMailboxKindChat) {
        [self apollo_captureChatStatus];
        [self apollo_startChatStatusRefreshIfNeeded];
    }
    if (self.authenticationRequired && !self.authenticationPromptAutomaticallyOffered) {
        [self apollo_presentAuthenticationPrompt];
    }
    // Appearance propagates to the hub child even while it sits hidden behind
    // Notifications; only refresh here when this surface is the visible one —
    // a hidden hub keeps its timestamp and refreshes on its next reveal.
    if (!self.embeddedInInbox || self.embeddedInboxVisible) {
        [self apollo_refreshAfterAwayIfStale];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    if (self.mailboxKind == ApolloModernMailboxKindChat) [self apollo_captureChatStatus];
    if (self.chatWentAwayAt <= 0) self.chatWentAwayAt = [NSDate date].timeIntervalSince1970;
    // The tab bar is a shared UITabBarController state. Always hand it back
    // before this controller leaves, even when Apollo Back exits from a room.
    [self apollo_restoreTabBarVisibility];
    [super viewWillDisappear:animated];
    if (!self.embeddedInInbox && self.didCaptureOriginalNavigationTintColor) {
        self.navigationController.navigationBar.tintColor = self.originalNavigationTintColor;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyActiveTheme];
}

- (void)apollo_activeThemeChanged:(NSNotification *)note {
    [self apollo_applyActiveTheme];
}

- (void)apollo_applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.didRevealChat && self.mailboxKind == ApolloModernMailboxKindChat) {
        [self apollo_captureChatStatus];
        [self apollo_startChatStatusRefreshIfNeeded];
    }
    // Only refresh a surface the user can actually see; a hidden hub keeps
    // its away timestamp and refreshes when it is next revealed instead.
    BOOL surfaceVisible = self.embeddedInInbox ? self.embeddedInboxVisible
        : (self.viewIfLoaded.window != nil);
    if (surfaceVisible) [self apollo_refreshAfterAwayIfStale];
}

- (void)apollo_applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    if (self.chatWentAwayAt <= 0) self.chatWentAwayAt = [NSDate date].timeIntervalSince1970;
}

// How long the surface must be away before returning triggers a refresh.
// Short flips (checking a notification, quick tab switch) stay instant and
// keep the cross-fade-in-place behavior; a real absence pays one list reload
// — the exact action users otherwise perform by re-tapping a section tab.
static NSTimeInterval ApolloChatStaleRefreshThreshold(void) {
    double override = [[NSUserDefaults standardUserDefaults] doubleForKey:UDKeyChatStaleRefreshOverride];
    return override >= 5.0 ? override : 60.0;
}

// Reddit's web chat client pauses its Matrix sync while the document is
// hidden or the app is suspended and does not reliably resume it — the room
// list keeps showing pre-absence state until a real navigation replaces
// Reddit's in-memory store. When the user returns after a genuine absence,
// replay the current LIST route through the normal load pipeline (identical
// to tapping its section tab). Conversation routes are never reloaded — that
// could discard a draft reply — they get a synthetic visibility/focus/online
// nudge, which is enough for Reddit's client to re-establish its sync loop.
- (void)apollo_refreshAfterAwayIfStale {
    if (self.sessionIdentityInvalidated) return;
    NSTimeInterval wentAwayAt = self.chatWentAwayAt;
    self.chatWentAwayAt = 0;
    if (wentAwayAt <= 0) return;
    NSTimeInterval away = [NSDate date].timeIntervalSince1970 - wentAwayAt;
    if (away < ApolloChatStaleRefreshThreshold()) return;
    if (!self.didRevealChat || self.authenticationRequired || self.presentedViewController) return;
    if (self.mailboxKind != ApolloModernMailboxKindChat) return;
    if (![self apollo_urlMatchesMailboxRoute:self.webView.URL]) return;

    NSString *path = self.webView.URL.path ?: @"";
    BOOL messagesList = [path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"];
    BOOL requestsList = [path isEqualToString:@"/chat/requests"] || [path isEqualToString:@"/chat/requests/"];
    BOOL threadsList = [path isEqualToString:@"/chat/threads"] || [path isEqualToString:@"/chat/threads/"];
    if (messagesList || requestsList || threadsList) {
        ApolloLog(@"[DirectChatWeb] Refreshing stale chat list (%@) after %.0fs away", path, away);
        if (self.embeddedInInbox) {
            [self apollo_showEmbeddedInboxSection:self.embeddedInboxSection forceReload:YES];
        } else {
            [self apollo_reloadChat];
        }
        return;
    }
    ApolloLog(@"[DirectChatWeb] Nudging open conversation to resync after %.0fs away", away);
    [self.webView evaluateJavaScript:
        @"(()=>{try{document.dispatchEvent(new Event('visibilitychange'));"
         "window.dispatchEvent(new Event('focus'));"
         "window.dispatchEvent(new Event('online'));return 1;}catch(e){return 0;}})()"
              completionHandler:nil];
}

- (void)apollo_applyActiveTheme {
    // UINavigationBar is shared by Apollo's whole navigation stack. Capture
    // its actual pre-chat value before the first theme application mutates it,
    // including a legitimate nil/default tint, so popping is a true restore.
    if (!self.embeddedInInbox && !self.didCaptureOriginalNavigationTintColor && self.navigationController) {
        self.originalNavigationTintColor = self.navigationController.navigationBar.tintColor;
        self.didCaptureOriginalNavigationTintColor = YES;
        ApolloLog(@"[DirectChatWeb] Captured original navigation tint before applying mailbox theme");
    }

    NSDictionary *palette = ApolloDirectChatThemePalette(self.traitCollection);
    UIColor *accent = ApolloDirectChatPaletteColor(palette, @"accent");
    UIColor *background = ApolloDirectChatPaletteColor(palette, @"primary");
    UIColor *bar = ApolloDirectChatPaletteColor(palette, @"bar");
    UIColor *separator = ApolloDirectChatPaletteColor(palette, @"separator");
    UIColor *text = ApolloDirectChatPaletteColor(palette, @"text");
    UIColor *secondaryText = ApolloDirectChatPaletteColor(palette, @"secondaryText");

    self.view.backgroundColor = background;
    self.loadingView.backgroundColor = background;
    self.webView.backgroundColor = background;
    self.webView.scrollView.backgroundColor = background;
    self.view.tintColor = accent;
    self.loadingIconView.tintColor = accent;
    self.loadingTitleLabel.textColor = text;
    self.loadingDetailLabel.textColor = secondaryText;
    self.spinner.color = accent;
    [self.reauthenticateButton setTitleColor:accent forState:UIControlStateNormal];
    self.reauthenticateButton.backgroundColor = [accent colorWithAlphaComponent:0.14];
    self.reauthenticateButton.layer.borderColor = [accent colorWithAlphaComponent:0.45].CGColor;
    [self.retryButton setTitleColor:accent forState:UIControlStateNormal];
    self.retryButton.backgroundColor = [accent colorWithAlphaComponent:0.14];
    self.retryButton.layer.borderColor = [accent colorWithAlphaComponent:0.45].CGColor;
    if (!self.embeddedInInbox) {
        self.navigationItem.rightBarButtonItem.tintColor = accent;
        self.navigationController.navigationBar.tintColor = accent;

        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = bar;
        appearance.shadowColor = separator;
        appearance.titleTextAttributes = @{NSForegroundColorAttributeName: text};
        self.navigationItem.standardAppearance = appearance;
        self.navigationItem.scrollEdgeAppearance = appearance;
        self.navigationItem.compactAppearance = appearance;
    }

    // Install the palette/layout hook before Reddit creates any SPA shadow
    // roots. The same source is evaluated below for the current document so a
    // live Theme Builder change is immediate as well as flash-free on the next
    // navigation.
    WKUserContentController *contentController = self.webView.configuration.userContentController;
    [contentController removeAllUserScripts];
    [contentController addUserScript:[[WKUserScript alloc]
        initWithSource:ApolloDirectChatEnhancementScript(palette)
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES]];

    if (self.webView.URL) {
        NSString *script = ApolloDirectChatEnhancementScript(palette);
        [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) {
                ApolloLog(@"[DirectChatWeb] Theme injection failed: %@", error);
            } else if ([result isKindOfClass:[NSDictionary class]] && [result[@"giphyGrids"] integerValue] > 0) {
                ApolloLog(@"[DirectChatWeb] Applied Apollo theme and compact GIPHY grid");
            }
        }];
    }
}

- (void)apollo_showLoadingWithDetail:(NSString *)detail {
    self.loadStartedAt = [NSDate date];
    self.authenticationRequired = NO;
    self.authenticationPromptAutomaticallyOffered = NO;
    self.reauthenticateButton.hidden = YES;
    self.retryButton.hidden = YES;
    self.didRevealChat = NO;
    self.readinessGeneration += 1;
    self.modmailTransitionPending = NO;
    self.modmailTransitionGeneration += 1;
    [self apollo_cancelChatTransition];
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        self.loadingTitleLabel.text = @"Opening Moderator Mail";
    } else if (self.embeddedInInbox) {
        switch (self.embeddedInboxSection) {
            case ApolloModernChatInboxSectionRequests:
                self.loadingTitleLabel.text = @"Opening Requests";
                break;
            case ApolloModernChatInboxSectionThreads:
                self.loadingTitleLabel.text = @"Opening Threads";
                break;
            case ApolloModernChatInboxSectionMessages:
            default:
                self.loadingTitleLabel.text = @"Opening Messages";
                break;
        }
    } else {
        self.loadingTitleLabel.text = @"Opening Reddit Chat";
    }
    self.loadingDetailLabel.text = detail.length ? detail : @"Preparing your private session…";
    self.loadingView.hidden = NO;
    self.loadingView.alpha = 1.0;
    self.webView.alpha = 0.0;
    self.webView.userInteractionEnabled = NO;
    [self.spinner startAnimating];

    // WebKit can occasionally stop delivering navigation callbacks after a
    // cancelled authentication flow or an unresponsive Reddit web process.
    // A retryable error is always better than a permanent activity indicator.
    NSUInteger generation = self.readinessGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.didRevealChat || generation != self.readinessGeneration) return;
        NSString *surface = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Moderator Mail" : @"Reddit Chat";
        ApolloLog(@"[DirectChatWeb] %@ loading watchdog fired", surface);
        [self.webView stopLoading];
        [self apollo_showLoadError:[NSString stringWithFormat:@"%@ took too long to respond. Tap Try Again to reload.", surface]];
    });
}

- (void)apollo_showLoadError:(NSString *)detail {
    self.authenticationRequired = NO;
    self.reauthenticateButton.hidden = YES;
    self.retryButton.hidden = NO;
    self.readinessGeneration += 1;
    self.modmailTransitionPending = NO;
    self.modmailTransitionGeneration += 1;
    [self apollo_cancelChatTransition];
    self.modmailWarmupPending = NO;
    self.loadingView.hidden = NO;
    self.loadingView.alpha = 1.0;
    self.loadingTitleLabel.text = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"Moderator Mail couldn’t be opened" : @"Chat couldn’t be opened";
    self.loadingDetailLabel.text = detail ?: @"Try refreshing or signing in again.";
    [self.spinner stopAnimating];
}

- (void)apollo_showAuthenticationError:(NSString *)detail automaticallyPrompt:(BOOL)automaticallyPrompt {
    [self apollo_showLoadError:detail];
    self.authenticationRequired = YES;
    self.reauthenticateButton.hidden = NO;
    // An expired session cannot be fixed by reloading — keep the single
    // relevant action (Sign In Again) instead of two competing buttons.
    self.retryButton.hidden = YES;
    if (automaticallyPrompt && !self.authenticationPromptAutomaticallyOffered && self.view.window) {
        [self apollo_presentAuthenticationPrompt];
    }
}

- (void)apollo_presentAuthenticationPrompt {
    if (!self.authenticationRequired || self.authenticationPromptVisible ||
        self.presentedViewController) return;

    NSString *targetUsername = ApolloActiveAccountUsername() ?: self.username;
    if (targetUsername.length == 0) {
        [self apollo_showAuthenticationError:
            @"Sign in to an Apollo account before opening Reddit Chat or Moderator Mail."
                         automaticallyPrompt:NO];
        return;
    }

    self.authenticationPromptVisible = YES;
    self.authenticationPromptAutomaticallyOffered = YES;
    NSString *purpose = self.mailboxKind == ApolloModernMailboxKindModmail
        ? @"modern Moderator Mail" : @"Reddit Chat";
    UIAlertController *prompt = [UIAlertController
        alertControllerWithTitle:@"Reddit Web Sign-In"
                         message:[NSString stringWithFormat:
                             @"Sign in once as u/%@ to use %@. This adds only the web session these features need; your API-key or API-Key-Free sign-in choice will not change.",
                             targetUsername, purpose]
                  preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Continue"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        ApolloWebSessionLoginViewController *login =
            [ApolloWebSessionLoginViewController loginControllerForUsername:targetUsername
                                                                  completion:^(BOOL success) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.authenticationPromptVisible = NO;
            if (!success || !self.authenticationRequired) return;

            NSString *active = ApolloActiveAccountUsername();
            ApolloWebSessionEntry *activeSession = ApolloWebSessionPollFor(active);
            if ([active.lowercaseString isEqualToString:targetUsername.lowercaseString] &&
                activeSession.cookieHeader.length > 0) {
                ApolloLog(@"[DirectChatWeb] One-time feature sign-in completed; retrying %@ in place",
                          self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat");
                [self apollo_seedAndLoad];
                return;
            }

            NSString *detail = active.length > 0
                ? [NSString stringWithFormat:@"That sign-in did not match u/%@. Tap below and sign in with that Reddit account.", active]
                : @"That sign-in did not match the active Apollo account. Switch accounts or try again.";
            [self apollo_showAuthenticationError:detail automaticallyPrompt:NO];
            ApolloLog(@"[DirectChatWeb] Feature sign-in completed without a matching active-account session");
        }];
        UINavigationController *navigationController =
            [[UINavigationController alloc] initWithRootViewController:login];
        [self presentViewController:navigationController animated:YES completion:nil];
    }]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        self.authenticationPromptVisible = NO;
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (BOOL)apollo_isModmailConversationURL:(NSURL *)url {
    if (self.mailboxKind != ApolloModernMailboxKindModmail || !url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    if (!redditHost) return NO;

    // List routes are /mail/<folder>; a real conversation adds its opaque ID
    // as the third non-empty path component (/mail/all/3jbwht).
    NSUInteger componentCount = 0;
    for (NSString *component in [url.path componentsSeparatedByString:@"/"]) {
        if (component.length > 0) componentCount += 1;
    }
    return componentCount >= 3 && [url.path hasPrefix:@"/mail/"];
}

// The mailbox list itself: /mail or /mail/<folder> and nothing deeper. Kept
// stricter than apollo_urlMatchesMailboxRoute:, which also accepts Reddit's
// saved-response manager under /mod/… — that page has neither list rows nor a
// thread, so covering it would only stall behind the probe's timeout.
- (BOOL)apollo_isModmailListURL:(NSURL *)url {
    if (self.mailboxKind != ApolloModernMailboxKindModmail || !url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    if (!([host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"])) return NO;
    NSString *path = url.path ?: @"";
    if (!([path isEqualToString:@"/mail"] || [path hasPrefix:@"/mail/"])) return NO;
    NSUInteger componentCount = 0;
    for (NSString *component in [path componentsSeparatedByString:@"/"]) {
        if (component.length > 0) componentCount += 1;
    }
    return componentCount <= 2;
}

- (BOOL)apollo_isConversationURL:(NSURL *)url {
    NSString *path = url.path ?: self.initialDestinationPath ?: @"";
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        NSURL *effectiveURL = url;
        if (!effectiveURL && path.length > 0) {
            effectiveURL = [NSURL URLWithString:
                [@"https://www.reddit.com" stringByAppendingString:path]];
        }
        return [self apollo_isModmailConversationURL:effectiveURL];
    }
    return [self apollo_isChatConversationPath:path];
}

- (void)apollo_updateTabBarVisibilityForURL:(NSURL *)url animated:(BOOL)animated {
    BOOL hidesForConversation = [self apollo_isConversationURL:url];
    self.hidesBottomBarWhenPushed = hidesForConversation;
    if (self.mailboxConversationHidesTabBar == hidesForConversation) return;
    self.mailboxConversationHidesTabBar = hidesForConversation;

    UITabBarController *tabBarController = self.tabBarController;
    UITabBar *tabBar = tabBarController.tabBar;
    BOOL usedSystemVisibilityAPI = NO;
    if (@available(iOS 18.0, *)) {
        if (tabBarController && [tabBarController respondsToSelector:
            @selector(setTabBarHidden:animated:)]) {
            // Use UIKit to update the safe area, but keep the transition
            // non-animated. Reddit performs its own list/room animation and two
            // independently animated bars produce a visible jump on iOS 26.
            [tabBarController setTabBarHidden:hidesForConversation animated:NO];
            usedSystemVisibilityAPI = YES;
        }
    }
    if (!usedSystemVisibilityAPI) {
        tabBar.hidden = hidesForConversation;
    }

    if (!hidesForConversation && tabBar) {
        // A room can be left through Reddit history, Apollo Back, a native
        // route, or a tab switch. Normalize every visual state that Apollo
        // hide-on-scroll may have left behind before handing the bar back.
        [tabBar.layer removeAnimationForKey:ApolloTabBarSlideDownAnimationKey];
        [tabBar.layer removeAnimationForKey:ApolloTabBarSlideUpAnimationKey];
        tabBar.hidden = NO;
        ApolloRestoreHideOnScrollPresentation(tabBarController,
                                              @"direct chat exit");
    }

    [tabBarController.view setNeedsLayout];
    [tabBarController.view layoutIfNeeded];

    if (!hidesForConversation) {
        // The bar's return just grew the bottom safe area, and iOS 27 may not
        // re-deliver a layout signal for it — the underlying list's inset can
        // stay at its hidden-bar value with the last rows stranded behind the
        // bar (same no-write mechanism as the legacy mirror's re-show). Give
        // Apollo one turn to react on its own, then verify.
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloListVerifyBottomInsetForVisibleLists(@"chatTabBarRestored");
        });
    }
    ApolloLog(@"[DirectChatWeb] %@ Inbox tab bar for %@ %@",
              hidesForConversation ? @"Hid" : @"Restored",
              self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat",
              hidesForConversation ? @"conversation" : @"list");
    (void)animated;
}

- (void)apollo_restoreTabBarVisibility {
    if (!self.mailboxConversationHidesTabBar && !self.hidesBottomBarWhenPushed) return;
    self.mailboxConversationHidesTabBar = YES;
    [self apollo_updateTabBarVisibilityForURL:[NSURL URLWithString:
        self.mailboxKind == ApolloModernMailboxKindModmail
            ? @"https://www.reddit.com/mail/all"
            : @"https://www.reddit.com/chat"]
                                      animated:NO];
}

// Modmail changes route in three different ways and only one of them delivers
// navigation callbacks: a notification deep link is a real document load, but
// opening a conversation from the list and Reddit's own in-thread back control
// are same-document SPA transitions with no policy, provisional, or finish
// callback at all — the WKWebView URL observer is the only signal. All three
// paint the destination in stages (bare subject text, an unstyled floating
// avatar, the composer's controls before its card, then the sticky header),
// and both directions additionally reflow when Apollo shows or hides the tab
// bar for the new route. Cover Reddit's document with the already-themed
// native background (Apollo's own chrome stays put) and let a DOM-stability
// probe own the reveal, so the user sees one settled surface instead of a
// layout assembling itself.
- (void)apollo_beginModmailTransitionToURL:(NSURL *)url isList:(BOOL)isList {
    if (self.mailboxKind != ApolloModernMailboxKindModmail) return;
    if (self.modmailTransitionPending) return;

    self.modmailTransitionGeneration += 1;
    self.modmailTransitionPending = YES;
    self.modmailTransitionIsList = isList;
    self.modmailTransitionStartedAt = [NSDate date].timeIntervalSince1970;
    self.webView.userInteractionEnabled = NO;
    [self.webView.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{ self.webView.alpha = 0.0; }];
    ApolloLog(@"[DirectChatWeb] Covering Modmail %@ while it hydrates: %@",
              isList ? @"list" : @"conversation", url.path ?: @"?");
    // A same-document transition delivers no navigation callback, so the probe
    // starts here rather than from didFinishNavigation:. Against a document
    // that has not routed yet it simply reports off-route and retries.
    NSUInteger generation = self.modmailTransitionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf apollo_waitForModmailStabilityAttempt:0
                                             generation:generation
                                          lastSignature:nil
                                          stableSamples:0];
    });
}

- (void)apollo_finishModmailTransitionForGeneration:(NSUInteger)generation {
    if (!self.modmailTransitionPending ||
        generation != self.modmailTransitionGeneration) return;
    BOOL initialNotificationDestination = !self.didRevealChat;
    BOOL isList = self.modmailTransitionIsList;
    self.modmailTransitionPending = NO;
    self.webView.userInteractionEnabled = YES;
    // Configure bounce before the first visible frame so the revealed layout
    // does not shift again afterwards.
    [self apollo_enableNativeScrollBounce];
    if (initialNotificationDestination) {
        // Exact-thread notification links arrive before the mailbox has ever
        // been revealed. Reuse the normal reveal path so it removes the native
        // loading cover as well as exposing the now-stable web document.
        [self apollo_revealChat];
    } else {
        [self.webView.layer removeAllAnimations];
        [UIView animateWithDuration:0.15 animations:^{ self.webView.alpha = 1.0; }];
    }
    ApolloLog(@"[DirectChatWeb] Revealed stable Modmail %@ after %.2fs",
              isList ? @"list" : @"conversation",
              self.modmailTransitionStartedAt > 0
                  ? [NSDate date].timeIntervalSince1970 - self.modmailTransitionStartedAt : 0.0);
}

- (void)apollo_waitForModmailStabilityAttempt:(NSUInteger)attempt
                                         generation:(NSUInteger)generation
                                      lastSignature:(NSString *)lastSignature
                                      stableSamples:(NSUInteger)stableSamples {
    if (!self.modmailTransitionPending ||
        generation != self.modmailTransitionGeneration) return;

    // Modmail reaches its destination route before its web components, message
    // data, lazy avatars, composer, and final scroll position finish settling.
    // Probe the document's real structure and geometry until several identical
    // samples land, instead of guessing at a fixed delay that would also slow
    // down already-cached conversations.
    //
    // The conversation probe keys readiness on modmail-thread-wrapper's
    // conversation-id matching the id in the URL: during an SPA transition the
    // *previous* thread is still fully rendered and would otherwise read as
    // instantly stable, revealing the old conversation under the new title.
    BOOL isList = self.modmailTransitionIsList;
    // Every sample runs on the main thread of the web process, so its own cost
    // is part of the cover's duration: an earlier version that walked
    // querySelectorAll('*') across every shadow root and read the whole
    // document's text took ~250ms per round. This one reuses the shadow-root
    // registry the enhancement script already maintains through its patched
    // attachShadow and queries only the handful of tags that matter, which
    // brought a round down to the ~83ms scheduling interval.
    NSString *script = [NSString stringWithFormat:
        @"(()=>{const path=location.pathname;const parts=path.split('/').filter(Boolean);"
         "const wantList=%@;const isListRoute=parts[0]==='mail'&&parts.length<3;"
         "if(parts[0]!=='mail'||isListRoute!==wantList)return {ready:false,onRoute:false,signature:''};"
         "const reg=window.__apolloChatShadowRoots;"
         "const roots=reg&&reg.length?[document,...reg]:(()=>{const out=[];const visit=r=>{if(!r||out.includes(r))return;out.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);return out;})();"
         "const q=sel=>{const out=[];for(const r of roots){if(r.querySelectorAll)for(const e of r.querySelectorAll(sel))out.push(e);}return out;};"
         "const rect=e=>{const b=e?.getBoundingClientRect?.();return b?[Math.round(b.x),Math.round(b.y),Math.round(b.width),Math.round(b.height)]:[];};"
         "const visible=e=>{const b=e.getBoundingClientRect();return b.width>0&&b.height>0;};"
         "const thread=q('modmail-thread-wrapper')[0];"
         "const composer=q('shreddit-composer')[0];"
         "const textarea=q('textarea').find(visible);"
         "const rows=q('rpl-inbox-row').filter(visible);"
         "const emptyOk=!rows.length&&/no (messages|conversations)/i.test(document.body?.textContent||'');"
         // Only images the reveal will actually expose. A long mailbox lays out
         // avatars far below the fold that Reddit never loads until they scroll
         // into view, and waiting on those held the cover up for seconds.
         // Avatars the enhancement script already republished as a CSS
         // background are excluded: those paint from the document's image cache
         // even while Reddit swaps their <img> element, so their constant
         // re-fetch churn must not hold the cover or reset the quiet window.
         "const held=new Set(window.__apolloMailAvatarSrcs||[]);"
         "const images=q('img').filter(e=>{if(held.has(e.getAttribute('src')||''))return false;const b=e.getBoundingClientRect();return b.width>0&&b.height>0&&b.bottom>0&&b.top<innerHeight;});"
         // Late avatars and message media would pop in right after an early
         // reveal; hold readiness for them, bounded so a stalled fetch cannot
         // keep the cover up on its own (the attempt cap is the outer net).
         "const imagesReady=images.every(e=>e.complete&&e.naturalWidth>0&&e.naturalHeight>0)||%lu>=18;"
         "const fontsReady=!document.fonts||document.fonts.status==='loaded';"
         "const scrolling=document.scrollingElement;"
         "const threadMatches=!!thread&&thread.getAttribute('conversation-id')===parts[parts.length-1];"
         "const ready=document.readyState==='complete'&&imagesReady&&fontsReady&&(wantList"
         "?(rows.length>0||emptyOk)"
         ":(threadMatches&&!!composer&&!!textarea));"
         // Content signal, deliberately render-aware and scoped. Whole-document
         // textContent also counts nodes that are never painted (Reddit keeps
         // filling hidden captcha/analytics text in for another ~300ms after
         // the thread is visually final) which held every reveal back for a
         // change nobody could see. A thread's innerText only counts rendered
         // text — it still catches late usernames and message bodies that
         // arrive without moving anything — and the list keys on its row
         // geometry, which is what actually reflows while rows hydrate.
         "const content=wantList?rows.map(e=>rect(e).join(',')).join(';'):String((thread?.innerText||'').length);"
         "const signature=[content,scrolling?.scrollTop||0,scrolling?.scrollHeight||0,document.body?.scrollHeight||0,rect(thread).join(','),rect(composer).join(','),rows.length,images.map(e=>[e.naturalWidth,e.naturalHeight,rect(e).join(',')].join(':')).join(';')].join('|');"
         "return {ready,onRoute:true,signature};})()",
        isList ? @"true" : @"false", (unsigned long)attempt];

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.modmailTransitionPending ||
            generation != self.modmailTransitionGeneration) return;

        NSDictionary *info = [result isKindOfClass:[NSDictionary class]] ? result : nil;
        BOOL onRoute = !error && [info[@"onRoute"] boolValue];
        BOOL ready = !error && [info[@"ready"] boolValue];
        NSString *signature = [info[@"signature"] isKindOfClass:[NSString class]]
            ? info[@"signature"] : nil;
        // A cover armed for a route Reddit never actually reached must not
        // leave a hidden, interaction-disabled document behind. During a real
        // cross-document navigation the probe samples the OLD, off-route
        // document until the new one commits, so only bail while no navigation
        // is in flight; the attempt cap still bounds a hung load.
        if (!onRoute && attempt >= 8 && !self.webView.loading) {
            ApolloLog(@"[DirectChatWeb] Modmail %@ transition never reached its route; revealing current document",
                      isList ? @"list" : @"conversation");
            [self apollo_finishModmailTransitionForGeneration:generation];
            return;
        }
        NSUInteger nextStableSamples = ready && signature.length > 0 &&
            [signature isEqualToString:lastSignature] ? stableSamples + 1 : 0;
        // Three identical 80ms samples of the full structure/geometry/media
        // signature. Readiness additionally holds on in-flight images, so this
        // quiet window only has to outlast Reddit's own re-render passes.
        if (ready && nextStableSamples >= 3) {
            [self apollo_finishModmailTransitionForGeneration:generation];
            return;
        }
        if (attempt >= 59) {
            ApolloLog(@"[DirectChatWeb] Modmail %@ stability probe timed out; revealing final available layout",
                      isList ? @"list" : @"conversation");
            [self apollo_finishModmailTransitionForGeneration:generation];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self apollo_waitForModmailStabilityAttempt:attempt + 1
                                                   generation:generation
                                                lastSignature:signature
                                                stableSamples:nextStableSamples];
        });
    }];
}

- (BOOL)apollo_isChatConversationPath:(NSString *)path {
    if (self.mailboxKind != ApolloModernMailboxKindChat || path.length == 0) return NO;
    if ([path hasPrefix:@"/chat/room/"]) return YES;
    // Message-reply threads append the conversation identifier to the list
    // route (/chat/threads/<id>); the bare list stays a list.
    if ([path hasPrefix:@"/chat/threads/"]) {
        NSUInteger componentCount = 0;
        for (NSString *component in [path componentsSeparatedByString:@"/"]) {
            if (component.length > 0) componentCount += 1;
        }
        return componentCount >= 3;
    }
    return NO;
}

// The path every route decision is made from: the URL observer's record (it
// also covers same-document SPA transitions, which deliver no navigation
// callback) with the live URL as the pre-observation fallback.
- (NSString *)apollo_currentChatPath {
    return self.lastObservedWebPath ?: (self.webView.URL.path ?: @"");
}

// YES while this controller is inside a conversation by EITHER source: the
// route (URL observer) or the page's own report (pageConversationVisible).
// Every swipe-hierarchy decision reads this rather than the route alone, so a
// room the route never reported still climbs back to its list instead of
// switching tabs or popping the screen.
- (BOOL)apollo_isInsideConversation {
    if (self.mailboxKind != ApolloModernMailboxKindChat) return NO;
    return self.pageConversationVisible ||
        [self apollo_isChatConversationPath:[self apollo_currentChatPath]];
}

// MARK: - Page surface report

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:ApolloDirectChatSurfaceMessageName]) return;
    // Page content is data: only the two typed fields are read.
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    id room = body[@"room"];
    NSString *path = [body[@"path"] isKindOfClass:[NSString class]] ? body[@"path"] : @"";
    [self apollo_notePageConversationVisible:[room isKindOfClass:[NSNumber class]] && [room boolValue]
                                reportedPath:path];
}

// The page reported its surface. Agreement with the route needs nothing —
// the URL observer has already done (or will do) the work. A DISAGREEMENT is
// the case this exists for: the page shows a room the route never reported
// (or the route dropped back to the list under a room that stayed), or the
// page has left a room the route never saw it enter.
- (void)apollo_notePageConversationVisible:(BOOL)visible reportedPath:(NSString *)reportedPath {
    if (self.mailboxKind != ApolloModernMailboxKindChat) return;
    self.pageConversationVisible = visible;
    [self apollo_reconcilePageSurfaceReportedPath:reportedPath];
}

- (void)apollo_reconcilePageSurfaceReportedPath:(NSString *)reportedPath {
    if (self.mailboxKind != ApolloModernMailboxKindChat) return;
    BOOL routeSaysConversation = [self apollo_isChatConversationPath:[self apollo_currentChatPath]];
    if (self.pageConversationVisible) {
        if (routeSaysConversation) {
            // The route owns the room; anything applied from the page report
            // is superseded by the observer's own treatments.
            self.pageConversationTreatmentsApplied = NO;
            return;
        }
        if (self.pageConversationTreatmentsApplied) return;
        // Apply the room treatments the observer would have (they only test
        // the route class, so a stand-in conversation URL is enough). No
        // frame is captured here: the room has already painted, and the
        // frame an interactive back reveals came from the touch that opened
        // it (apollo_noteTouchBeganOnPage).
        ApolloLog(@"[DirectChatWeb] Page shows a conversation while the route reads %@; applying room treatments from the page report",
                  reportedPath.length ? reportedPath : @"(empty)");
        self.pageConversationTreatmentsApplied = YES;
        self.conversationBackIssuedAt = 0.0;
        NSURL *standIn = [NSURL URLWithString:@"https://www.reddit.com/chat/room/page-reported-room"];
        [self apollo_updateTabBarVisibilityForURL:standIn animated:NO];
        [self apollo_updateEmbeddedWebChromeForURL:standIn];
        ApolloStandaloneChatBackPanInstall(self);
        return;
    }
    // The page shows a list. If the route reported the room it left, its
    // repair (or the fallback list load) delivers the list treatments through
    // the observer; only a room the page alone knew about has nobody else to
    // do it.
    if (!self.pageConversationTreatmentsApplied) return;
    self.pageConversationTreatmentsApplied = NO;
    NSURL *url = self.webView.URL;
    NSString *path = url.path ?: @"";
    ApolloLog(@"[DirectChatWeb] Page is back on the list (%@) from a page-reported conversation; applying list treatments",
              path.length ? path : @"(empty)");
    [self apollo_updateTabBarVisibilityForURL:url animated:NO];
    [self apollo_updateEmbeddedWebChromeForURL:url];
    [self apollo_resettleEmbeddedListForPath:path];
}

// Every touch that lands on the page while a list is showing refreshes the
// still frame an interactive back will reveal. The URL observer captures that
// frame at the pane swap for a room it is told about; a room the route never
// reports has already painted by the time the page report arrives, so the
// frame has to come from before the tap — the touch that opens the room is
// exactly that moment, and it also folds in any scrolling since the last
// capture. A snapshot is a render-server copy, cheap enough per touch.
- (void)apollo_noteTouchBeganOnPage {
    if (self.mailboxKind != ApolloModernMailboxKindChat || !self.didRevealChat) return;
    if (self.chatTransitionPending || self.conversationBackInteractive) return;
    if ([self apollo_isInsideConversation]) return;
    [self apollo_captureConversationBackSnapshot];
}

// After a conversation gives way to a list — the URL observer's normal path,
// or the page report's when no URL change followed — refresh what the list
// feeds: the status scrape right away (animation-independent) and the crop
// re-measure once Reddit's flip has settled; measuring immediately catches
// the pane mid-flip and mis-aligns the list by the transient geometry. The
// still-hydrated list pane needs no reload and the remembered crop is
// already correct, so this is only a sanity pass.
- (void)apollo_resettleEmbeddedListForPath:(NSString *)path {
    if (!self.embeddedInInbox || !self.didRevealChat || self.webView.loading) return;
    BOOL nowRootList = [path isEqualToString:@"/chat"] ||
        [path isEqualToString:@"/chat/"];
    BOOL nowThreadsList = [path isEqualToString:@"/chat/threads"] ||
        [path isEqualToString:@"/chat/threads/"];
    if (nowRootList &&
        self.embeddedInboxSection == ApolloModernChatInboxSectionMessages) {
        [self apollo_captureChatStatus];
    }
    if ((nowRootList &&
         self.embeddedInboxSection == ApolloModernChatInboxSectionMessages) ||
        (nowThreadsList &&
         self.embeddedInboxSection == ApolloModernChatInboxSectionThreads)) {
        NSUInteger generation = self.readinessGeneration;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.readinessGeneration) return;
            // The user may already be inside another room again;
            // measuring the hidden list pane would misplace the
            // crop under the conversation. The page report covers a
            // room the route does not show (a room-name marker in the
            // open room measured as the list's first row otherwise).
            if (self.pageConversationVisible) return;
            NSString *currentPath = self.webView.URL.path ?: @"";
            BOOL stillRootList = [currentPath isEqualToString:@"/chat"] ||
                [currentPath isEqualToString:@"/chat/"];
            BOOL stillThreadsList = [currentPath isEqualToString:@"/chat/threads"] ||
                [currentPath isEqualToString:@"/chat/threads/"];
            if (stillRootList &&
                self.embeddedInboxSection == ApolloModernChatInboxSectionMessages) {
                [self apollo_alignEmbeddedMessagesForGeneration:generation
                                                      completion:nil];
            } else if (stillThreadsList &&
                       self.embeddedInboxSection == ApolloModernChatInboxSectionThreads) {
                [self apollo_alignEmbeddedThreadsForGeneration:generation
                                                     completion:nil];
            }
        });
    }
}

// One step UP Reddit's chat hierarchy: from a conversation (a room or a reply
// thread) back to the list it was opened from, by clicking Reddit's own
// in-room Back control. That is the same pane flip a tap performs — the list
// pane underneath is still hydrated, so the return is instant — and it keeps
// the whole return in the one code path a tap already used, including the
// interception that repairs the URL so every native route treatment follows.
// Returns YES when the caller's gesture was consumed here (a back was issued,
// or one is still in flight), NO when this controller is not inside a
// conversation and the caller should keep its stock behavior.
- (BOOL)apollo_goBackToConversationList {
    if (![self apollo_isInsideConversation]) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.conversationBackIssuedAt > 0.0 &&
        now - self.conversationBackIssuedAt < 1.5) {
        ApolloLog(@"[DirectChatWeb] Conversation back already in flight; ignoring repeat");
        return YES;
    }
    self.conversationBackIssuedAt = now;
    NSString *listPath = @"/chat";
    if (self.embeddedInboxSection == ApolloModernChatInboxSectionThreads) {
        listPath = @"/chat/threads";
    } else if (self.embeddedInboxSection == ApolloModernChatInboxSectionRequests) {
        listPath = @"/chat/requests";
    }
    [self.webView evaluateJavaScript:@"window.__apolloChatTapRoomBack?.()||'unavailable'"
                   completionHandler:^(id result, NSError *error) {
        ApolloLog(@"[DirectChatWeb] Conversation back -> %@%@",
                  [result isKindOfClass:[NSString class]] ? result : @"unknown",
                  error ? [NSString stringWithFormat:@" (%@)", error.localizedDescription] : @"");
    }];
    // Reddit's own control is the fast path, not a guarantee: it flips the
    // pane instantly where it applies (a room opened from the Messages list),
    // but a reply thread's control can navigate — or do nothing this build
    // understands. If the route has still not left the conversation, load the
    // section's list outright rather than leaving a swipe that visibly did
    // nothing; the native transition cover already owns that reload. A real
    // navigation already in flight is that same escape happening on its own,
    // so never stack a second load on top of it.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.conversationBackIssuedAt != now) return;
        if (![self apollo_isInsideConversation]) return;
        if (self.webView.loading) return;
        ApolloLog(@"[DirectChatWeb] Conversation back did not leave the room; loading %@", listPath);
        [self.webView evaluateJavaScript:
            [NSString stringWithFormat:@"location.assign('%@');", listPath]
                       completionHandler:nil];
    });
    return YES;
}

// MARK: - Interactive conversation back
//
// The gesture drivers (the Inbox hub's mode-pan) hand progress to these three
// calls so the back reads like every other iOS back: the conversation tracks
// the finger while the list slides in behind it at the usual parallax, and a
// drag that is let go short of the commit point returns without touching the
// web view at all. Only on commit does the web-level back run, hidden behind
// the still frame that is already covering the same pixels.

- (void)apollo_captureConversationBackSnapshot {
    self.conversationBackSnapshot = nil;
    if (self.mailboxKind != ApolloModernMailboxKindChat) return;
    // A hidden hub renders nothing worth capturing, and an off-window view
    // snapshots empty.
    if (!self.view.window || CGRectIsEmpty(self.view.bounds)) return;
    if (self.embeddedInInbox && !self.embeddedInboxVisible) return;
    UIView *snapshot = [self.view snapshotViewAfterScreenUpdates:NO];
    if (!snapshot) return;
    snapshot.userInteractionEnabled = NO;
    self.conversationBackSnapshot = snapshot;
}

- (BOOL)apollo_beginInteractiveConversationBack {
    if (![self apollo_isInsideConversation]) return NO;
    if (self.conversationBackInteractive) {
        // Grabbed again mid-settle: hand the views straight back to the finger
        // instead of letting the previous animation keep driving them. The
        // settle's completion still fires — removing the animations does not
        // cancel it, and the dim's fade (a sublayer, not covered by the two
        // removals above) would keep it alive for its full duration — so the
        // generation bump is what turns it into a no-op: it can no longer end
        // the drag that has just begun, or issue a web-level back under it.
        self.conversationBackGeneration += 1;
        [self.view.layer removeAllAnimations];
        [self.conversationBackSnapshot.layer removeAllAnimations];
        [self.conversationBackDimView.layer removeAllAnimations];
        [self apollo_updateInteractiveConversationBack:0.0];
        return YES;
    }
    // A back already on its way owns these views until it settles.
    if (self.conversationBackIssuedAt > 0.0 &&
        [NSDate date].timeIntervalSince1970 - self.conversationBackIssuedAt < 1.5) return NO;
    UIView *container = self.view.superview;
    UIView *snapshot = self.conversationBackSnapshot;
    if (!container || !snapshot || CGRectIsEmpty(self.view.bounds)) return NO;

    self.view.transform = CGAffineTransformIdentity;
    snapshot.transform = CGAffineTransformIdentity;
    snapshot.alpha = 1.0;
    snapshot.frame = self.view.frame;
    [container insertSubview:snapshot belowSubview:self.view];

    UIView *dim = [[UIView alloc] initWithFrame:snapshot.bounds];
    dim.backgroundColor = UIColor.blackColor;
    dim.alpha = 0.0;
    dim.userInteractionEnabled = NO;
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [snapshot addSubview:dim];
    self.conversationBackDimView = dim;

    // The same leading-edge shadow UIKit draws under a screen being popped.
    self.view.layer.shadowColor = UIColor.blackColor.CGColor;
    self.view.layer.shadowOffset = CGSizeZero;
    self.view.layer.shadowRadius = 10.0;
    self.view.layer.shadowOpacity = 0.24;
    self.view.layer.shadowPath = [UIBezierPath bezierPathWithRect:self.view.bounds].CGPath;

    self.conversationBackDirection =
        (self.view.effectiveUserInterfaceLayoutDirection ==
         UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    self.conversationBackGeneration += 1;
    self.conversationBackInteractive = YES;
    [self apollo_updateInteractiveConversationBack:0.0];
    return YES;
}

- (void)apollo_updateInteractiveConversationBack:(CGFloat)progress {
    if (!self.conversationBackInteractive) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    if (width <= 0.0) return;
    CGFloat clamped = MAX(0.0, MIN(1.0, progress));
    CGFloat sign = self.conversationBackDirection;
    self.view.transform = CGAffineTransformMakeTranslation(sign * clamped * width, 0.0);
    // UIKit moves the screen underneath at 30% of the top screen's travel.
    self.conversationBackSnapshot.transform =
        CGAffineTransformMakeTranslation(sign * (clamped - 1.0) * width * 0.3, 0.0);
    self.conversationBackDimView.alpha = (1.0 - clamped) * 0.12;
}

- (void)apollo_finishInteractiveConversationBack:(BOOL)commit velocity:(CGFloat)velocity {
    if (!self.conversationBackInteractive) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat current = width > 0.0 ? fabs(self.view.transform.tx) / width : 0.0;
    CGFloat remaining = MAX(0.05, commit ? (1.0 - current) : current);
    // Carry the throw's speed into the settle instead of always spending the
    // same time, the way a released interactive pop does.
    NSTimeInterval duration = width > 0.0 && fabs(velocity) > 1.0
        ? MIN(0.42, MAX(0.14, remaining * width / fabs(velocity)))
        : 0.28;
    UIView *snapshot = self.conversationBackSnapshot;
    NSUInteger generation = self.conversationBackGeneration;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut |
                                UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [weakSelf apollo_updateInteractiveConversationBack:commit ? 1.0 : 0.0];
    } completion:^(BOOL finished) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        // A newer drag grabbed these views mid-settle and owns them now; this
        // settle's outcome — the web-level back included — is void.
        if (generation != self.conversationBackGeneration) {
            ApolloLog(@"[DirectChatWeb] Conversation back settle (%@) superseded by a newer drag",
                      commit ? @"commit" : @"cancel");
            return;
        }
        self.conversationBackInteractive = NO;
        self.view.layer.shadowOpacity = 0.0;
        if (!commit) {
            [self apollo_endInteractiveConversationBack];
            return;
        }
        // The still frame now covers exactly the pixels the live list will
        // occupy. Lift it above the conversation, put that back in place, and
        // flip the web panes underneath — the swap is one identical frame
        // replacing another instead of a visible jump.
        [snapshot.superview bringSubviewToFront:snapshot];
        snapshot.transform = CGAffineTransformIdentity;
        self.conversationBackDimView.alpha = 0.0;
        self.view.transform = CGAffineTransformIdentity;
        [self apollo_goBackToConversationList];
        [self apollo_waitForConversationBackSwap:snapshot attempt:0];
    }];
}

// Hold the still frame until the web view is actually showing the list, then
// cross-fade it out. The cap covers the paths where the pane flip needs a real
// navigation (a reply thread, a stale room) — the load runs behind this frame
// and the transition cover picks it up from there.
//
// The frame is handed down explicitly rather than re-read from the property:
// it is non-interactive, so a tap during the hold reaches the live list
// underneath, and opening a room that way captures a FRESH frame into the
// shared slot. This pass must tear down the exact view it showed and touch the
// shared state only while that state is still its own — otherwise the old
// frame stayed parked in the container at alpha 0 (one more per room opened
// this way) and the new room lost the frame its own back swipe needs.
- (void)apollo_waitForConversationBackSwap:(UIView *)snapshot attempt:(NSUInteger)attempt {
    if (!snapshot.superview) return;
    BOOL current = self.conversationBackSnapshot == snapshot;
    BOOL leftConversation = ![self apollo_isInsideConversation];
    if (current && !leftConversation && attempt < 28) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf apollo_waitForConversationBackSwap:snapshot attempt:attempt + 1];
        });
        return;
    }
    // Leaving the room route is not quite the same as the list being finished:
    // the CSS that hides Reddit's own list chrome re-applies on the sweep after
    // the URL repair, so an immediate hand-off flashed that chrome through the
    // fade. The still frame is identical to the settled list, so holding it a
    // beat longer costs nothing. A frame that has already been superseded (a
    // room opened during the hold) is stale, not identical — drop it at once.
    NSTimeInterval hold = current ? 0.18 : 0.0;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [UIView animateWithDuration:0.12
                         animations:^{ snapshot.alpha = 0.0; }
                         completion:^(BOOL finished) {
            // Tear down the frame this pass actually showed. Only while it is
            // still the shared one is the list on screen for real with no new
            // room behind it — then the next room open captures its own frame.
            UIView *container = snapshot.superview;
            BOOL stillCurrent = self.conversationBackSnapshot == snapshot;
            [snapshot removeFromSuperview];
            if (self.conversationBackDimView.superview == snapshot) {
                self.conversationBackDimView = nil;
            }
            if (stillCurrent) {
                [self apollo_endInteractiveConversationBack];
                self.conversationBackSnapshot = nil;
            }
            ApolloLog(@"[DirectChatWeb] Conversation back frame torn down (current=%d, container subviews=%lu)",
                      stillCurrent, (unsigned long)container.subviews.count);
        }];
    });
}

- (void)apollo_endInteractiveConversationBack {
    self.conversationBackInteractive = NO;
    [self.conversationBackDimView removeFromSuperview];
    self.conversationBackDimView = nil;
    UIView *snapshot = self.conversationBackSnapshot;
    [snapshot removeFromSuperview];
    snapshot.transform = CGAffineTransformIdentity;
    snapshot.alpha = 1.0;
    self.view.transform = CGAffineTransformIdentity;
    self.view.layer.shadowOpacity = 0.0;
}

// The gesture side of the standalone Reddit Chat screen's back (see the
// "Standalone conversation back-swipe" section below the class for why this
// screen owns the pan at all). The same state machine the Inbox hub's mode-pan
// runs when it drives a conversation back: the room tracks the finger, and a
// release past the commit point — or a decisive throw — completes the step.
- (void)apollo_standaloneConversationBackPanned:(UIPanGestureRecognizer *)pan {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    // Mirror under RTL, where back is a leftward drag.
    CGFloat rtlSign = (pan.view.effectiveUserInterfaceLayoutDirection ==
                       UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    CGPoint translation = [pan translationInView:pan.view];
    CGPoint velocity = [pan velocityInView:pan.view];
    CGFloat progress = width > 0.0 ? (translation.x * rtlSign) / width : 0.0;
    CGFloat commitVelocity = velocity.x * rtlSign;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            // NO means there is nothing to reveal yet (no captured list frame,
            // or a back already running); the release then takes the plain,
            // instant step instead.
            sStandaloneChatBackInteractive = [self apollo_beginInteractiveConversationBack];
            ApolloLog(@"[DirectChatWeb] Standalone conversation back-pan began (interactive=%d)",
                      sStandaloneChatBackInteractive);
            break;
        case UIGestureRecognizerStateChanged:
            if (sStandaloneChatBackInteractive) {
                [self apollo_updateInteractiveConversationBack:progress];
            }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            BOOL interactive = sStandaloneChatBackInteractive;
            sStandaloneChatBackInteractive = NO;
            BOOL commit = ApolloModernChatBackSwipeCommits(pan.state, progress, commitVelocity, translation);
            if (commit) ApolloLog(@"[DirectChatWeb] Standalone swipe: conversation -> chat list");
            if (interactive) {
                [self apollo_finishInteractiveConversationBack:commit velocity:commitVelocity];
            } else if (commit) {
                [self apollo_goBackToConversationList];
            }
            break;
        }
        default:
            break;
    }
}

// Drops a pending lightweight transition cover when a full-cover pipeline
// (the loading screen) supersedes it. The caller owns web-view alpha and
// interaction from here; bumping the generation parks the in-flight probe.
- (void)apollo_cancelChatTransition {
    self.chatTransitionPending = NO;
    self.chatTransitionGeneration += 1;
}

// Chat rooms open through a same-document SPA transition and the reloaded
// Messages list through a real navigation, but both paint progressively:
// Reddit first shows its default message styling without usernames or
// avatars, then hydrates names, avatars, images, and scroll position over
// several frames. Cover only Reddit's document with the already-themed native
// background (Apollo's chrome stays put) so the user sees one stable surface
// instead of rows visibly adjusting into place — the exact treatment the
// Modmail thread transition already ships.
- (void)apollo_beginChatTransitionToURL:(NSURL *)url isList:(BOOL)isList {
    if (self.mailboxKind != ApolloModernMailboxKindChat) return;
    if (self.chatTransitionPending || self.modmailTransitionPending) return;
    self.chatTransitionGeneration += 1;
    self.chatTransitionPending = YES;
    self.chatTransitionIsList = isList;
    self.webView.userInteractionEnabled = NO;
    [self.webView.layer removeAllAnimations];
    [UIView performWithoutAnimation:^{ self.webView.alpha = 0.0; }];
    ApolloLog(@"[DirectChatWeb] Covering Chat %@ while it settles: %@",
              isList ? @"list" : @"conversation", url.path ?: @"?");
    // A room switch may deliver no navigation callback at all, so the probe
    // starts here rather than from didFinishNavigation. Against a document
    // that has not routed yet it simply reports off-route and retries.
    NSUInteger generation = self.chatTransitionGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf apollo_waitForChatTransitionStabilityAttempt:0
                                                    generation:generation
                                                 lastSignature:nil
                                                 stableSamples:0];
    });
}

// Samples the document's structure and geometry until several consecutive
// probes return an identical signature (the Modmail stability pattern). The
// signature deliberately includes text length, image natural sizes, and
// scroll offsets: late usernames, avatars, media, and Reddit's automatic
// scroll corrections each keep the cover up until they stop changing.
- (void)apollo_waitForChatTransitionStabilityAttempt:(NSUInteger)attempt
                                          generation:(NSUInteger)generation
                                       lastSignature:(NSString *)lastSignature
                                       stableSamples:(NSUInteger)stableSamples {
    if (!self.chatTransitionPending || generation != self.chatTransitionGeneration) return;

    BOOL isList = self.chatTransitionIsList;
    NSString *script;
    if (isList) {
        script =
            @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
             "if(!/^\\/chat\\/?$/.test(location.pathname))return {ready:false,onRoute:false,signature:''};"
             "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);"
             "const rect=e=>{const b=e?.getBoundingClientRect?.();return b?[Math.round(b.x),Math.round(b.y),Math.round(b.width),Math.round(b.height)]:[];};"
             "const visible=e=>{const b=e.getBoundingClientRect();return b.width>0&&b.height>0;};"
             "const rows=all.filter(e=>visible(e)&&e.matches?.('.room-name,.last-message,.last-message-time'));"
             "const images=all.filter(e=>e.tagName==='IMG'&&visible(e));"
             "const fontsReady=!document.fonts||document.fonts.status==='loaded';"
             "const emptyOk=all.some(e=>visible(e)&&e.children.length===0&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='no messages');"
             "const ready=(rows.length>0||emptyOk)&&fontsReady;"
             "const signature=[all.length,rows.map(e=>((e.textContent||'').replace(/\\s+/g,' ').trim().length)+'@'+rect(e).join(',')).join(';'),images.map(e=>[e.naturalWidth,e.naturalHeight,rect(e).join(',')].join(':')).join(';')].join('|');"
             "return {ready,onRoute:true,signature};})()";
    } else {
        script = [NSString stringWithFormat:
            @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
             "const onRoute=location.pathname.startsWith('/chat/room/')||/^\\/chat\\/threads\\/[^/]+/.test(location.pathname);"
             "if(!onRoute)return {ready:false,onRoute:false,signature:''};"
             "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);"
             "const rect=e=>{const b=e?.getBoundingClientRect?.();return b?[Math.round(b.x),Math.round(b.y),Math.round(b.width),Math.round(b.height)]:[];};"
             "const visible=e=>{const b=e.getBoundingClientRect();return b.width>0&&b.height>0;};"
             "const composer=all.find(e=>visible(e)&&e.matches?.('textarea,[contenteditable=true],[role=textbox]'));"
             // A pending chat request opens as a room with Accept/Ignore/Block
             // controls instead of a composer; treat those as the hydrated
             // marker so request rooms don't sit through the probe timeout.
             "const invite=all.some(e=>{if(!visible(e)||!e.matches?.('button,[role=button]'))return false;const t=(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase();return t==='accept'||t==='ignore'||t==='block'||t==='view request'||t==='join';});"
             "const images=all.filter(e=>e.tagName==='IMG'&&visible(e));"
             // In-flight message media would pop in right after an early
             // reveal; hold readiness for them briefly (failed loads flip
             // complete=true, and the attempt cap bounds a stalled fetch).
             "const pendingImg=images.some(e=>!e.complete);"
             "const fontsReady=!document.fonts||document.fonts.status==='loaded';"
             "const text=(document.body?.innerText||'').replace(/\\s+/g,' ').trim();"
             "const scrollSig=all.filter(e=>e.scrollHeight>e.clientHeight+1).map(e=>Math.round(e.scrollTop)+'x'+e.scrollHeight).join(',');"
             "const ready=(!!composer||invite)&&fontsReady&&(!pendingImg||%lu>=15);"
             "const signature=[all.length,text.length,rect(composer).join(','),scrollSig,images.map(e=>[e.naturalWidth,e.naturalHeight,rect(e).join(',')].join(':')).join(';')].join('|');"
             "return {ready,onRoute:true,signature};})()",
            (unsigned long)attempt];
    }

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.chatTransitionPending ||
            generation != self.chatTransitionGeneration) return;

        NSDictionary *info = [result isKindOfClass:[NSDictionary class]] ? result : nil;
        BOOL onRoute = !error && [info[@"onRoute"] boolValue];
        BOOL ready = !error && [info[@"ready"] boolValue];
        NSString *signature = [info[@"signature"] isKindOfClass:[NSString class]]
            ? info[@"signature"] : nil;
        // A cover armed from a policy decision Reddit never actually routed
        // must not leave a hidden, interaction-disabled document behind.
        // During a real cross-document navigation the probe samples the OLD,
        // off-route document until the new one commits, so only bail while
        // no navigation is in flight — a slow deep-link load must keep its
        // cover (the 40-attempt timeout still bounds a hung navigation).
        if (!onRoute && attempt >= 6 && !self.webView.loading) {
            ApolloLog(@"[DirectChatWeb] Chat %@ transition never reached its route; revealing current document",
                      isList ? @"list" : @"conversation");
            [self apollo_finishChatTransitionForGeneration:generation];
            return;
        }
        NSUInteger nextStableSamples = ready && signature.length > 0 &&
            [signature isEqualToString:lastSignature] ? stableSamples + 1 : 0;
        // Three identical 80ms samples of the full structure/geometry/media
        // signature; rooms additionally hold readiness on in-flight images,
        // so the shorter quiet period stays safe there too.
        NSUInteger requiredStableSamples = 3;
        if (ready && nextStableSamples >= requiredStableSamples) {
            [self apollo_finishChatTransitionForGeneration:generation];
            return;
        }
        if (attempt >= 39) {
            ApolloLog(@"[DirectChatWeb] Chat %@ stability probe timed out; revealing final available layout",
                      isList ? @"list" : @"conversation");
            [self apollo_finishChatTransitionForGeneration:generation];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self apollo_waitForChatTransitionStabilityAttempt:attempt + 1
                                                    generation:generation
                                                 lastSignature:signature
                                                 stableSamples:nextStableSamples];
        });
    }];
}

- (void)apollo_finishChatTransitionForGeneration:(NSUInteger)generation {
    if (!self.chatTransitionPending || generation != self.chatTransitionGeneration) return;
    BOOL isList = self.chatTransitionIsList;
    self.chatTransitionPending = NO;
    // Reddit sometimes parks a freshly-opened conversation mid-history: the
    // virtualized rows above the fold change height as their media measure
    // in, dragging the scroll anchor with them. The document is still covered
    // here, so pin it to the latest message before anything becomes visible.
    if (!isList && [self apollo_isChatConversationPath:self.webView.URL.path]) {
        [self apollo_pinCoveredConversationToLatestForGeneration:generation attempt:0];
        return;
    }
    [self apollo_revealChatTransition:isList];
}

- (void)apollo_revealChatTransition:(BOOL)isList {
    self.webView.userInteractionEnabled = YES;
    // Configure bounce and the tab-bar scroll allowance before the first
    // visible frame so the revealed layout does not shift again afterwards.
    [self apollo_enableNativeScrollBounce];
    if (!self.didRevealChat) {
        // A deep-linked conversation can arrive before the hub was ever
        // revealed; reuse the normal reveal path so it also removes the
        // native loading cover.
        [self apollo_revealChat];
    } else {
        [self.webView.layer removeAllAnimations];
        [UIView animateWithDuration:0.15 animations:^{ self.webView.alpha = 1.0; }];
    }
    ApolloLog(@"[DirectChatWeb] Revealed settled Chat %@", isList ? @"list" : @"conversation");
}

// Scrolls the covered conversation's on-screen virtualized scroller to its
// latest message. Only viewport-intersecting scrollers move, so the hidden
// list pane behind a room keeps the user's list position. When the pin
// actually moved the scroller, one short second pass re-pins after the
// newly-materialized bottom rows settle their heights.
- (void)apollo_pinCoveredConversationToLatestForGeneration:(NSUInteger)generation
                                                   attempt:(NSUInteger)attempt {
    if (self.chatTransitionPending || generation != self.chatTransitionGeneration) return;
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "let moved=false;for(const r of roots)for(const e of r.querySelectorAll('rs-virtual-scroll,rs-virtual-scroll-dynamic')){"
         "if(e.clientHeight<150||e.scrollHeight<=e.clientHeight+8)continue;"
         "const b=e.getBoundingClientRect();if(b.width<=0||b.height<=0||b.bottom<=0||b.top>=innerHeight)continue;"
         "const target=e.scrollHeight-e.clientHeight;if(Math.abs(e.scrollTop-target)>24){e.scrollTop=target;moved=true;}}"
         "return moved;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        // A newer transition begun while the pin was in flight owns the
        // cover now; never reveal on its behalf.
        if (!self || self.chatTransitionPending ||
            generation != self.chatTransitionGeneration) return;
        BOOL moved = !error && [result respondsToSelector:@selector(boolValue)] &&
            [result boolValue];
        if (moved && attempt == 0) {
            ApolloLog(@"[DirectChatWeb] Pinned covered conversation to its latest message");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self apollo_pinCoveredConversationToLatestForGeneration:generation
                                                                 attempt:1];
            });
            return;
        }
        [self apollo_revealChatTransition:NO];
    }];
}

- (void)apollo_revealChat {
    BOOL expectedRoute = [self apollo_urlMatchesMailboxRoute:self.webView.URL];
    if (self.didRevealChat || !expectedRoute) return;
    self.didRevealChat = YES;
    [self.spinner stopAnimating];
    self.webView.userInteractionEnabled = YES;
    [UIView animateWithDuration:0.22 animations:^{
        self.webView.alpha = 1.0;
        self.loadingView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.loadingView.hidden = YES;
    }];
    NSString *surface = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat";
    NSTimeInterval elapsed = self.loadStartedAt ? -[self.loadStartedAt timeIntervalSinceNow] : 0.0;
    ApolloLog(@"[DirectChatWeb] Revealed hydrated mobile %@ UI in %.2fs", surface, elapsed);
    // Reddit creates its WKChildScrollView only after the custom elements
    // hydrate. Configure it now and once more after the final compositing pass.
    [self apollo_enableNativeScrollBounce];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf apollo_enableNativeScrollBounce];
    });
    if (self.mailboxKind == ApolloModernMailboxKindChat) {
        [self apollo_startChatStatusRefreshIfNeeded];
        [self apollo_captureChatStatus];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self apollo_captureChatStatus];
        });
    }
}

- (void)apollo_startChatStatusRefreshIfNeeded {
    // A controller ejected for an account switch stays dead: a reveal/readiness
    // async that lands after the eject must not re-arm the scrape timer.
    if (self.sessionIdentityInvalidated) return;
    if (self.chatStatusRefreshTimer || self.mailboxKind != ApolloModernMailboxKindChat) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:20.0 repeats:YES block:^(__unused NSTimer *timer) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.didRevealChat) return;
        [self apollo_captureChatStatus];
    }];
    self.chatStatusRefreshTimer = timer;
    // Default mode only: the scan walks every shadow-root element, and firing
    // it from the tracking mode meant it could start mid-scroll on the very
    // list the user is dragging. Deferring to the next idle moment costs
    // nothing for a 20s cadence.
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    ApolloLog(@"[DirectChatWeb] Started foreground Chat unread refresh (20s)");
}

- (void)apollo_captureChatStatus {
    // Never scrape (and never publish status for) a controller ejected on an
    // account switch — its webview holds the previous account's cookies.
    if (self.sessionIdentityInvalidated) return;
    if (self.mailboxKind != ApolloModernMailboxKindChat || !self.webView.URL ||
        ![self apollo_urlMatchesMailboxRoute:self.webView.URL]) return;
    // This scan walks every element of every shadow root. Skip it while the
    // app is inactive — the Matrix poller resumes on the next activation and
    // republishes exact counts anyway, so nothing is lost. It intentionally
    // KEEPS running while the hub is merely hidden behind Notifications:
    // this DOM scrape is what feeds the unread badge shown on that screen.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const titleMatch=(document.title||'').match(/^\\((\\d+)\\)/);let unreadCount=titleMatch?parseInt(titleMatch[1],10)||0:0;let hasUnread=unreadCount>0;let preview='';"
         "for(const root of roots)for(const e of root.querySelectorAll('*')){if(!visible(e))continue;const cls=typeof e.className==='string'?e.className:'';const marker=(cls+' '+(e.getAttribute('data-testid')||'')+' '+(e.getAttribute('aria-label')||'')).toLowerCase();const text=(e.textContent||'').replace(/\\s+/g,' ').trim();if(!hasUnread&&marker.includes('unread')&&text.toLowerCase()!=='unread'&&!e.matches('input,[role=switch]'))hasUnread=true;if(!preview&&e.children.length===0&&text.length>3&&text.length<160&&/^[^:]{1,40}:\\s+.+/.test(text))preview=text;}"
         "const requests=location.pathname.startsWith('/chat/requests'),threads=location.pathname.startsWith('/chat/threads');const body=roots.map(r=>{const host=r===document?document.body:r;return host?.innerText||host?.textContent||'';}).join(' ').replace(/\\s+/g,' ').trim().toLowerCase();"
         "const result={surface:requests?'requests':(threads?'threads':'messages'),hasUnread,unreadCount,preview:preview||null,checkedAt:Date.now()};"
         "if(requests)result.hasRequests=!body.includes('no requests yet')&&!/additional requests\\s*0(?:\\D|$)/.test(body);return result;})()";
    NSString *statusUsername = self.username.lowercaseString ?: @"";
    // The status merge treats a scrape of the paused, hidden web client
    // differently from one the user is actually looking at (it may only
    // raise counts, never clear them past a newer Matrix poll).
    BOOL visibleScrape = self.viewIfLoaded.window != nil &&
        (!self.embeddedInInbox || self.embeddedInboxVisible);
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error || ![result isKindOfClass:[NSDictionary class]]) return;
        NSMutableDictionary *status = [(NSDictionary *)result mutableCopy];
        status[@"username"] = statusUsername;
        status[@"origin"] = visibleScrape ? @"dom-visible" : @"dom-hidden";
        ApolloModernChatPublishStatus(status);
    }];
}

- (void)apollo_updateEmbeddedWebChromeForURL:(NSURL *)url {
    if (!self.embeddedInInbox || !self.webViewTopConstraint ||
        !self.webViewBottomConstraint) return;
    NSString *path = url.path ?: @"";
    BOOL rootList = [path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"];
    BOOL requestsList = [path hasPrefix:@"/chat/requests"];
    // A reply-thread conversation lives at /chat/threads/<id>; only the bare
    // list is the Threads list. Classifying the conversation as a list would
    // apply the remembered list crop (potentially a large negative offset) to
    // the conversation, clipping its header and Back control off-screen.
    BOOL threadsList = [path hasPrefix:@"/chat/threads"] &&
        ![self apollo_isChatConversationPath:path];
    BOOL conversationRoom = [path hasPrefix:@"/chat/room/"];
    CGFloat topOffset = 0.0;
    if (requestsList) {
        topOffset = -54.0;
    } else if (threadsList) {
        // Use a harmless initial position until the real first thread can be
        // measured after hydration. The readiness pass then removes Reddit's
        // redundant back/Threads row without clipping the first participant.
        // Returning from a reply-thread conversation, restore the already
        // measured alignment instead so the list does not visibly hop while
        // the async re-measure runs.
        topOffset = 8.0;
        if (self.didRevealChat && !isnan(self.threadsAlignedTopOffset) &&
            self.embeddedInboxSection == ApolloModernChatInboxSectionThreads) {
            topOffset = self.threadsAlignedTopOffset;
        }
    } else if (rootList) {
        // Messages now removes Reddit's redundant list chrome in the DOM. Keep
        // the web view itself uncropped so elastic overscroll cannot reveal
        // hidden content above Apollo's native section switcher. After the
        // align pass has measured the real breathing gap once, returning from
        // a room reuses that value — resetting to zero here and re-measuring a
        // moment later made the whole list hop by the gap and back.
        topOffset = 0.0;
        if (self.didRevealChat && !isnan(self.messagesAlignedTopOffset) &&
            self.embeddedInboxSection == ApolloModernChatInboxSectionMessages) {
            topOffset = self.messagesAlignedTopOffset;
        }
    }

    // Standalone Direct Chat hides Apollo's tab bar, but the embedded Inbox
    // intentionally keeps it visible. Reddit anchors a room's message composer
    // to the bottom of the web viewport, so a full-height embedded viewport
    // places the entire composer behind Apollo's floating tab bar. Shorten only
    // conversation rooms to the top of that bar. Lists continue beneath the
    // floating chrome and retain their separate scroll allowance.
    CGFloat composerBottomInset = 0.0;
    UITabBar *tabBar = self.tabBarController.tabBar;
    if (conversationRoom && tabBar && !tabBar.hidden && tabBar.alpha > 0.01 &&
        tabBar.window && self.view.window) {
        CGRect tabBarFrame = [tabBar convertRect:tabBar.bounds toView:self.view];
        CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(tabBarFrame);
        if (overlap > 0.0) composerBottomInset = overlap + 8.0;
    }

    BOOL topChanged = fabs(self.webViewTopConstraint.constant - topOffset) >= 0.5;
    BOOL bottomChanged =
        fabs(self.webViewBottomConstraint.constant + composerBottomInset) >= 0.5;
    if (!topChanged && !bottomChanged) return;
    self.webViewTopConstraint.constant = topOffset;
    self.webViewBottomConstraint.constant = -composerBottomInset;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    ApolloLog(@"[DirectChatWeb] Embedded Chat %@ Reddit's list chrome; composer inset %.1fpt",
              (rootList || requestsList) ? @"cropped" : @"restored",
              composerBottomInset);
}

// Messages is the direct-chat list. Reddit exposes Direct chats, Group chats,
// and Mod mail as stable checkbox items behind Filter chat inbox. Change one
// checkbox per pass: the component rerenders after every click, so retaining
// and clicking several stale descendants in one JavaScript turn is unreliable.
- (void)apollo_applyEmbeddedInboxFilterAttempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (!self.embeddedInInbox || generation != self.readinessGeneration || self.didRevealChat) return;
    ApolloModernChatInboxSection desiredSection = self.embeddedInboxSection;
    if (desiredSection == ApolloModernChatInboxSectionRequests) {
        [self apollo_waitForChatReadinessAttempt:0 generation:generation];
        return;
    }
    if (desiredSection == ApolloModernChatInboxSectionThreads) {
        [self apollo_waitForChatReadinessAttempt:0 generation:generation];
        return;
    }

    NSString *script = [NSString stringWithFormat:
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const all=()=>roots.flatMap(r=>[...r.querySelectorAll('*')]);const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const items=all().filter(e=>e.tagName==='RS-ROOMS-NAV-FILTER-ITEM'&&visible(e));"
         "if(!items.length){const filter=all().find(e=>visible(e)&&(e.getAttribute('aria-label')||'').trim().toLowerCase()==='filter chat inbox');if(filter){filter.click();return 'opening';}return 'waiting';}"
         "const wanted={'group chats':%@,'direct chats':%@,'mod mail':false};"
         "for(const item of items){const label=(item.getAttribute('label')||item.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase();if(!(label in wanted))continue;const control=item.querySelector('[role=checkbox]')||item;const checked=item.checked===true||item.hasAttribute('checked')||control.getAttribute('aria-checked')==='true';if(checked!==wanted[label]){control.click();return 'changed';}}"
         "const apply=all().find(e=>visible(e)&&e.matches('button,[role=button]')&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='apply');if(apply){apply.click();return 'applied';}return 'waiting';})()",
         @"false", @"true"];

    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration || self.didRevealChat ||
            self.embeddedInboxSection != desiredSection) return;
        if (!error && [result isEqual:@"applied"]) {
            ApolloLog(@"[DirectChatWeb] Applied embedded Messages (direct chats) filter");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != self.readinessGeneration || self.didRevealChat) return;
                [self apollo_alignEmbeddedMessagesForGeneration:generation completion:^{
                    if (generation != self.readinessGeneration || self.didRevealChat) return;
                    [self apollo_captureChatStatus];
                    [self apollo_revealChat];
                }];
            });
            return;
        }
        if (attempt >= 39) {
            ApolloLog(@"[DirectChatWeb] Embedded Messages filter timed out; revealing Reddit's available list");
            [self apollo_alignEmbeddedMessagesForGeneration:generation completion:^{
                [self apollo_revealChat];
            }];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self apollo_applyEmbeddedInboxFilterAttempt:attempt + 1 generation:generation];
        });
    }];
}

// Messages deliberately enables Reddit Chat's Direct-only type filter. Reddit
// persists that choice in localStorage and applies it to the dedicated Requests
// route too, where it silently hides group-chat invitations and renders the
// legitimate "No requests yet" state. Clear only the three type flags before
// opening Requests or Threads, then perform a full route load so Reddit's
// in-memory store reads the reset state. Other per-account Chat preferences in
// the same object remain untouched.
- (void)apollo_clearEmbeddedChatTypeFiltersForGeneration:(NSUInteger)generation
                                               completion:(void (^)(BOOL changed))completion {
    if (!self.embeddedInInbox || generation != self.readinessGeneration) {
        if (completion) completion(NO);
        return;
    }
    NSString *script =
        @"(()=>{const key='chat:reddit-chat-type-filters';let state={};"
         "try{state=JSON.parse(localStorage.getItem(key)||'{}')}catch(e){state={}}"
         "let changed=false;for(const account of Object.keys(state)){const value=state[account]||{};"
         "if(value.shouldShowGroupChats||value.shouldShowDirectChats||value.shouldShowModmailChats)changed=true;"
         "state[account]={...value,shouldShowGroupChats:false,shouldShowDirectChats:false,shouldShowModmailChats:false};}"
         "if(changed)localStorage.setItem(key,JSON.stringify(state));return changed;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration) return;
        BOOL changed = !error && [result respondsToSelector:@selector(boolValue)] && [result boolValue];
        if (changed) {
            ApolloLog(@"[DirectChatWeb] Cleared persisted Chat type filters before %@",
                      self.embeddedInboxSection == ApolloModernChatInboxSectionRequests
                          ? @"Requests" : @"Threads");
        }
        if (completion) completion(changed);
    }];
}

// Reddit's root Chat page places its own header, filter chips, and two
// mobile-web navigation rows before the first conversation. Apollo already
// supplies all of that navigation. Remove those elements from layout rather
// than cropping the WKWebView: a native crop looks correct at rest but elastic
// overscroll can pull the supposedly-hidden rows back into view.
- (void)apollo_alignEmbeddedMessagesForGeneration:(NSUInteger)generation
                                        completion:(dispatch_block_t)completion {
    if (!self.embeddedInInbox ||
        self.embeddedInboxSection != ApolloModernChatInboxSectionMessages ||
        generation != self.readinessGeneration) {
        if (completion) completion();
        return;
    }
    NSString *script =
        @"(()=>{window.__apolloEmbeddedInboxMessages=true;window.__apolloEmbeddedSection='messages';"
         // Persist the section so the next real navigation's document restores
         // it at document start for the in-room back interception's gating.
         "try{sessionStorage.setItem('__apolloEmbeddedSection','messages');}catch(e){}"
         "window.__apolloChatEnhancementSweep?.();"
         "const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);let marker=all.find(e=>visible(e)&&e.matches('.room-name'));"
         "if(marker)marker=marker.closest('li,[role=button]')||marker;"
         "if(!marker)marker=all.find(e=>visible(e)&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='no messages');"
         "if(!marker)return null;const top=marker.getBoundingClientRect().top;return Number.isFinite(top)?top:null;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration ||
            self.embeddedInboxSection != ApolloModernChatInboxSectionMessages) return;
        CGFloat top = !error && [result respondsToSelector:@selector(doubleValue)]
            ? [result doubleValue] : 0.0;
        // The redundant elements are gone from layout, so the first room
        // normally measures at zero. Retain a small native breathing gap and
        // only compensate for a modest future Reddit wrapper—not a hidden
        // screenful that elastic overscroll could expose.
        CGFloat offset = MAX(-40.0, MIN(12.0, 12.0 - top));
        self.messagesAlignedTopOffset = offset;
        self.webViewTopConstraint.constant = offset;
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        ApolloLog(@"[DirectChatWeb] Aligned embedded Messages first content at %.1fpt (web offset %.1f)",
                  top, offset);
        if (completion) completion();
    }];
}

// The real Threads route prepends its own mobile back button and "Threads"
// title. Apollo already supplies that navigation through the three-way section
// switcher, so align the first actual reply thread beneath it. Measuring the
// custom element avoids clipping its participant row when Reddit changes the
// height of the redundant header.
- (void)apollo_alignEmbeddedThreadsForGeneration:(NSUInteger)generation
                                       completion:(dispatch_block_t)completion {
    if (!self.embeddedInInbox ||
        self.embeddedInboxSection != ApolloModernChatInboxSectionThreads ||
        generation != self.readinessGeneration) {
        if (completion) completion();
        return;
    }
    NSString *script =
        @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
         "const visible=e=>{const b=e.getBoundingClientRect(),s=getComputedStyle(e);return b.width>0&&b.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
         "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);let thread=all.find(e=>visible(e)&&e.tagName==='RS-THREADS-VIEW-THREAD'),marker=null;"
         "if(thread){const belongs=e=>{let n=e;while(n){if(n===thread)return true;const root=n.getRootNode?.();n=root instanceof ShadowRoot?root.host:n.parentElement;}return false;};marker=all.filter(e=>e!==thread&&belongs(e)&&visible(e)&&e.children.length===0&&(e.textContent||'').replace(/\\s+/g,' ').trim().length>0).sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0]||thread;}"
         "if(!marker)marker=all.find(e=>visible(e)&&e.children.length===0&&(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase()==='no threads');"
         "if(!marker)return null;const top=marker.getBoundingClientRect().top;return Number.isFinite(top)?top:null;})()";
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration ||
            self.embeddedInboxSection != ApolloModernChatInboxSectionThreads) return;
        if (!error && [result respondsToSelector:@selector(doubleValue)]) {
            CGFloat top = [result doubleValue];
            CGFloat offset = MAX(-240.0, MIN(8.0, 12.0 - top));
            self.threadsAlignedTopOffset = offset;
            self.webViewTopConstraint.constant = offset;
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
            ApolloLog(@"[DirectChatWeb] Aligned embedded Threads first content at %.1fpt (web offset %.1f)",
                      top, offset);
        }
        if (completion) completion();
    }];
}

- (void)apollo_showEmbeddedInboxSection:(ApolloModernChatInboxSection)section {
    [self apollo_showEmbeddedInboxSection:section forceReload:NO];
}

// forceReload replays the full load/filter pipeline even for the section that
// is already selected and on-route. Used by the stale-return refresh: simply
// re-applying the filter over the existing document would keep Reddit's stale
// in-memory room list — only a real navigation refetches it.
- (void)apollo_showEmbeddedInboxSection:(ApolloModernChatInboxSection)section forceReload:(BOOL)forceReload {
    if (!self.embeddedInInbox || self.mailboxKind != ApolloModernMailboxKindChat) return;
    if (section < ApolloModernChatInboxSectionMessages ||
        section > ApolloModernChatInboxSectionThreads) {
        section = ApolloModernChatInboxSectionMessages;
    }

    NSString *targetPath;
    switch (section) {
        case ApolloModernChatInboxSectionRequests:
            targetPath = @"/chat/requests";
            break;
        case ApolloModernChatInboxSectionThreads:
            targetPath = @"/chat/threads";
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            targetPath = @"/chat";
            break;
    }
    NSString *currentPath = self.webView.URL.path ?: @"";
    BOOL alreadyOnTarget;
    if (section == ApolloModernChatInboxSectionRequests) {
        alreadyOnTarget = [currentPath hasPrefix:@"/chat/requests"];
    } else if (section == ApolloModernChatInboxSectionThreads) {
        alreadyOnTarget = [currentPath hasPrefix:@"/chat/threads"];
    } else {
        alreadyOnTarget = [currentPath isEqualToString:@"/chat"] ||
            [currentPath isEqualToString:@"/chat/"];
    }
    BOOL sameSection = self.embeddedInboxSection == section;
    self.embeddedInboxSection = section;
    self.initialDestinationPath = targetPath;
    // Keep the in-page section marker current: the enhancement script's
    // in-room back interception only applies while Messages is the selected
    // section, and sessionStorage carries the value across real navigations.
    NSString *sectionMarker = section == ApolloModernChatInboxSectionRequests
        ? @"requests" : (section == ApolloModernChatInboxSectionThreads ? @"threads" : @"messages");
    [self.webView evaluateJavaScript:[NSString stringWithFormat:
        @"window.__apolloEmbeddedSection='%@';"
         "try{sessionStorage.setItem('__apolloEmbeddedSection','%@');}catch(e){}",
        sectionMarker, sectionMarker]
                   completionHandler:nil];
    [self apollo_updateEmbeddedWebChromeForURL:[NSURL URLWithString:
        [@"https://www.reddit.com" stringByAppendingString:targetPath]]];

    // Re-selecting the active list is intentionally inert, matching a native
    // tab bar. If a conversation room is open, however, tapping the selected
    // tab returns to that section's list.
    if (!forceReload && sameSection && alreadyOnTarget && self.didRevealChat) return;

    NSString *detail;
    switch (section) {
        case ApolloModernChatInboxSectionRequests:
            detail = @"Checking for people who want to chat…";
            break;
        case ApolloModernChatInboxSectionThreads:
            detail = @"Loading conversations around messages you replied to…";
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            detail = @"Loading your direct conversations…";
            break;
    }
    [self apollo_showLoadingWithDetail:detail];
    NSUInteger generation = self.readinessGeneration;

    // Direct-only is useful for Messages but incorrect for Requests, where it
    // hides group invitations. Reset the persisted type filter before either
    // non-Messages route is allowed to hydrate. If the route is already open,
    // a full reload is required to replace Reddit's in-memory filtered store.
    if (section != ApolloModernChatInboxSectionMessages) {
        __weak typeof(self) weakSelf = self;
        [self apollo_clearEmbeddedChatTypeFiltersForGeneration:generation
                                                    completion:^(BOOL changed) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.readinessGeneration ||
                self.embeddedInboxSection != section) return;
            if (!forceReload && alreadyOnTarget && !changed) {
                [self apollo_waitForChatReadinessAttempt:0 generation:generation];
                return;
            }
            [self.webView stopLoading];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
                [@"https://www.reddit.com" stringByAppendingString:targetPath]]];
            request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
            [self.webView loadRequest:request];
        }];
        return;
    }

    if (!forceReload && alreadyOnTarget) {
        [self apollo_applyEmbeddedInboxFilterAttempt:0 generation:generation];
        return;
    }

    // Rapid taps may leave WebKit finishing an older route after a newer tab
    // has already been selected. Explicitly cancel that obsolete navigation so
    // only the newly selected tab is allowed to drive readiness and layout.
    [self.webView stopLoading];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        [@"https://www.reddit.com" stringByAppendingString:targetPath]]];
    request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    [self.webView loadRequest:request];
}

// A conversation opened from OUTSIDE the web content (a legacy-inbox chat
// mirror tapped in Notifications). It loads as a real navigation: the policy
// callback covers the room while it settles exactly as a tapped room is, and
// the in-room Back control then returns to the list through its own reload
// path. Before the first document exists the path simply becomes the initial
// destination, so cookie seeding does not race a list load against it.
- (void)apollo_openConversationPath:(NSString *)path {
    if (self.mailboxKind != ApolloModernMailboxKindChat) return;
    NSString *validated = ApolloValidatedModernMailboxPath(ApolloModernMailboxKindChat, path);
    if (!validated || ![self apollo_isChatConversationPath:validated]) {
        ApolloLog(@"[DirectChatWeb] Ignored an invalid conversation path");
        return;
    }
    if (self.embeddedInInbox) {
        self.embeddedInboxSection = ApolloModernChatInboxSectionMessages;
        [self.webView evaluateJavaScript:
            @"window.__apolloEmbeddedSection='messages';"
             "try{sessionStorage.setItem('__apolloEmbeddedSection','messages');}catch(e){}"
                       completionHandler:nil];
    }
    NSURL *url = [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:validated]];
    if (!self.webView.URL) {
        self.initialDestinationPath = validated;
        ApolloLog(@"[DirectChatWeb] Queued a conversation as the first Chat document");
        return;
    }
    if ([[self apollo_currentChatPath] isEqualToString:validated]) {
        ApolloLog(@"[DirectChatWeb] Conversation already open");
        return;
    }
    // Retire any list readiness/filter loop still running for the previous
    // route; the room's covered transition owns the reveal from here.
    self.readinessGeneration += 1;
    [self.webView stopLoading];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    [self.webView loadRequest:request];
    ApolloLog(@"[DirectChatWeb] Opening a Chat conversation from the native inbox%@",
              self.embeddedInInbox ? @" (Inbox hub)" : @"");
}

- (void)apollo_seedAndLoad {
    self.username = ApolloActiveWebSessionUsername() ?: @"";
    ApolloWebSessionEntry *session = ApolloWebSessionPollFor(self.username);
    // Record the exact identity this controller is about to authenticate as;
    // ApolloModernChatControllerSessionIsCurrent compares against it so the
    // persistent Inbox hub can detect account switches / cookie rotations.
    self.seededCookieHeader = session.cookieHeader ?: @"";
    if (session.cookieHeader.length == 0) {
        NSString *detail = self.username.length > 0
            ? [NSString stringWithFormat:@"Sign in as u/%@ to continue.", self.username]
            : @"Sign in to Reddit to continue.";
        [self apollo_showAuthenticationError:detail automaticallyPrompt:YES];
        ApolloLog(@"[DirectChatWeb] Cannot load: active account has no web session");
        return;
    }
    NSString *detail = self.username.length ? [NSString stringWithFormat:@"Connecting as u/%@…", self.username] : @"Connecting to Reddit…";
    [self apollo_showLoadingWithDetail:detail];

    NSDictionary<NSString *, NSString *> *pairs = ApolloDirectChatCookiePairs(session.cookieHeader);
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    ApolloSeedModernMailboxCookies(session.cookieHeader, store, ^{
        BOOL modmail = self.mailboxKind == ApolloModernMailboxKindModmail;
        self.modmailWarmupPending = modmail;
        ApolloLog(@"[DirectChatWeb] Seeded %lu cookies for u/%@; loading mobile %@",
                  (unsigned long)pairs.count, self.username, modmail ? @"Modmail warm-up" : @"Chat Requests");
        // Reddit exposes stable authenticated routes for the conversation list
        // (`/chat`), incoming requests (`/chat/requests`), and participated
        // message-reply threads (`/chat/threads`). Start mobile/device-width
        // here so none of the old desktop feed/drawer handoff is needed during
        // ordinary use.
        // Reddit moved the official Modmail surface into www.reddit.com/mail;
        // unlike Apollo's OAuth-only /api/mod endpoints this page accepts the
        // same signed-in web cookie as the rest of API-Key-Free Mode. A fresh
        // web process needs one authenticated same-origin document first, so
        // Modmail deliberately starts on the hidden Chat Requests warm-up.
        NSString *chatPath = !modmail && self.initialDestinationPath.length > 0
            ? self.initialDestinationPath : @"/chat/requests";
        NSString *urlString = [@"https://www.reddit.com" stringByAppendingString:chatPath];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
        // Reddit's API calls still fetch current inbox data; allowing the main
        // document and versioned JS/CSS bundles to revalidate is what makes a
        // warmed launch faster without showing stale conversations.
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        [self.webView loadRequest:request];
    });
}

- (void)apollo_waitForChatReadinessAttempt:(NSUInteger)attempt generation:(NSUInteger)generation {
    if (generation != self.readinessGeneration || self.didRevealChat) return;
    // A covered conversation transition's stability probe owns the reveal;
    // park this loop so it cannot reveal the room mid-hydration. Every probe
    // outcome (stable, off-route, timeout) ends in a terminal reveal call.
    if (self.chatTransitionPending && !self.chatTransitionIsList) return;
    // The navigation-finished callback fires before Reddit's Chat custom
    // elements finish hydrating. Keep the native loading cover up until the
    // selected list has painted a real control, row, or legitimate empty state.
    NSString *script;
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        // Current (2026) Reddit Modmail lives at /mail/all. Its first navigation
        // finishes before the mailbox custom element paints, so keep the Apollo
        // loading cover up until a real folder/control or conversation is visible.
        script =
            @"(()=>{const body=(document.body?.innerText||'').replace(/\\s+/g,' ').trim().toLowerCase();"
             "const signedOut=(body.includes('log in')||body.includes('sign in'))&&!body.includes('mark all as read')&&!body.includes('recently updated');"
             "if(signedOut)return 'signedOut';"
             "const ready=location.pathname.startsWith('/mail')&&(body.includes('mark all as read')||body.includes('recently updated')||body.includes('all mail')||body.includes('in progress')||!!document.querySelector('modmail-mailbox-wrapper'));"
             "return ready?'ready':'waiting';})()";
    } else {
        BOOL keepExplicitEmptyRequests = [self.initialDestinationPath isEqualToString:@"/chat/requests"];
        script = [NSString stringWithFormat:
            @"(()=>{const roots=[];const visit=r=>{if(!r||roots.includes(r))return;roots.push(r);for(const e of r.querySelectorAll('*'))if(e.shadowRoot)visit(e.shadowRoot);};visit(document);"
             "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';};"
             "const text=e=>(e.textContent||'').replace(/\\s+/g,' ').trim().toLowerCase();"
             "const controls=roots.flatMap(r=>[...r.querySelectorAll('button,a,[role=button],input,textarea,[contenteditable=true],h1,h2,h3,p')]);"
             "const all=roots.flatMap(r=>[...r.querySelectorAll('*')]);const threadsRoute=location.pathname.startsWith('/chat/threads');"
             "if(threadsRoute){const threadItem=all.some(e=>visible(e)&&e.tagName==='RS-THREADS-VIEW-THREAD');const threadText=all.filter(e=>e.children.length===0).map(text).join(' ');return threadItem||threadText.includes('no threads')?'ready':'waiting';}"
             "const empty=location.pathname.startsWith('/chat/requests')&&controls.some(e=>visible(e)&&text(e)==='no requests yet');"
             // Reddit paints its Requests empty state before its current
             // invitations finish loading. Give that data request a short
             // settling window before accepting the empty state as genuine.
             "if(empty&&%@)return %lu>=8?'ready':'waiting';"
             "if(empty&&!window.__apolloEmptyRequestsHandled){window.__apolloEmptyRequestsHandled=true;const clickables=roots.flatMap(r=>[...r.querySelectorAll('button,a,[role=button]')]).filter(visible);"
             "let back=clickables.find(e=>{const r=e.getBoundingClientRect();if(r.left>130||r.top>180)return false;const marker=[text(e),e.getAttribute('aria-label'),e.getAttribute('title'),e.getAttribute('data-testid')].filter(Boolean).join(' ').toLowerCase();return /(^|\\s)(back|threads?)(\\s|$)/.test(marker)||!!e.querySelector('[icon-name*=back i],[name*=back i],[aria-label*=back i]');});"
             "if(!back)back=clickables.filter(e=>{const r=e.getBoundingClientRect(),cx=r.left+r.width/2,cy=r.top+r.height/2;return cx<90&&cy>55&&cy<180&&r.width<180&&r.height<100;}).sort((a,b)=>a.getBoundingClientRect().top-b.getBoundingClientRect().top)[0];"
             "if(back){back.click();return 'redirected';}location.replace('/chat');return 'redirected';}"
             // A fully-hydrated filtered list can legitimately contain no
             // rooms. Reddit renders this as an exact empty-state pair; treat
             // both markers together as ready instead of leaving an already
             // complete screen behind the loading cover for 15 seconds.
             "const rootList=location.pathname==='/chat'||location.pathname==='/chat/';"
             // Locale-independent ready marker: a painted conversation row
             // (.room-name — the same class fixChatListTypography styles)
             // proves the list hydrated, without depending on any English
             // button/empty-state text. Keeps non-English accounts off the
             // 15-second timeout fallback on the most common route.
             "if(rootList&&all.some(e=>visible(e)&&e.matches?.('.room-name')))return 'ready';"
             "const hydratedEmpty=rootList&&controls.some(e=>visible(e)&&text(e)==='no messages')&&controls.some(e=>visible(e)&&text(e)==='clear filters');"
             "if(hydratedEmpty)return 'ready';"
             "const ready=controls.some(e=>{if(!visible(e))return false;const t=text(e),a=(e.getAttribute('aria-label')||'').trim().toLowerCase();"
             "if(t==='view request'||t==='go to messages'||t==='start new chat'||t==='accept'||t==='additional requests'||t==='threads'||t==='chats')return true;"
             "const room=location.pathname.startsWith('/chat/room/');return room&&(e.matches('input,textarea,[contenteditable=true]')||a==='send message'||a==='message');});return ready?'ready':'waiting';})()",
             keepExplicitEmptyRequests ? @"true" : @"false",
             (unsigned long)attempt];
    }
    __weak typeof(self) weakSelf = self;
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.readinessGeneration || self.didRevealChat) return;
        if (!error && [result isEqual:@"ready"]) {
            NSString *path = self.webView.URL.path ?: @"";
            BOOL embeddedList = self.embeddedInInbox &&
                ([path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"]);
            if (embeddedList) {
                [self apollo_applyEmbeddedInboxFilterAttempt:0 generation:generation];
            } else if (self.embeddedInInbox && [path hasPrefix:@"/chat/threads"]) {
                [self apollo_alignEmbeddedThreadsForGeneration:generation completion:^{
                    [self apollo_revealChat];
                }];
            } else {
                [self apollo_revealChat];
            }
            return;
        }
        if (!error && [result isEqual:@"redirected"] && attempt == 0) {
            ApolloLog(@"[DirectChatWeb] No pending requests; returning to the Threads list");
        }
        if (!error && [result isEqual:@"signedOut"]) {
            [self apollo_showAuthenticationError:@"Your Reddit web session expired. Sign in again to reconnect."
                             automaticallyPrompt:YES];
            return;
        }
        if (attempt >= 59) {
            NSString *surface = self.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat";
            ApolloLog(@"[DirectChatWeb] %@ readiness probe timed out", surface);
            if (self.mailboxKind == ApolloModernMailboxKindModmail) {
                [self apollo_showLoadError:@"Moderator Mail took too long to finish loading. Tap Try Again to reload."];
            } else {
                // Chat's markup changes frequently; if its expected route did
                // finish, preserve the prior behavior and reveal it rather
                // than treating an unknown new ready marker as a hard failure.
                [self apollo_revealChat];
            }
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self apollo_waitForChatReadinessAttempt:attempt + 1 generation:generation];
        });
    }];
}

- (BOOL)apollo_urlMatchesMailboxRoute:(NSURL *)url {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    if (!redditHost) return NO;

    NSString *path = url.path ?: @"";
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        BOOL mailbox = [path isEqualToString:@"/mail"] || [path hasPrefix:@"/mail/"];
        // The composer links to Reddit's per-subreddit saved-response manager.
        // Keep that management flow in the authenticated Modmail WKWebView;
        // Apollo's native deep-link parser otherwise mistakes it for content
        // navigation and opens an unusable Comments controller.
        BOOL savedResponses = [path hasPrefix:@"/mod/"] &&
            [path rangeOfString:@"/saved-responses" options:NSCaseInsensitiveSearch].location != NSNotFound;
        return mailbox || savedResponses;
    }
    return [path isEqualToString:@"/chat"] || [path hasPrefix:@"/chat/"];
}

- (void)apollo_routeURLOutsideMailbox:(NSURL *)url {
    if (!url) return;
    NSURL *apolloURL = ApolloURLByConvertingResolvedURLToApolloScheme(url);
    if (apolloURL) {
        // Keep the hidden-tab mailbox and every Inbox controller completely out
        // of native Reddit navigation. Rebuilding or temporarily removing this
        // controller from the Inbox stack poisons UINavigationController's
        // safe-area cache on iOS 26; every later Inbox destination then starts
        // beneath the navigation bar. Route through Apollo's Posts tab instead.
        UINavigationController *mailboxNavigationController = self.navigationController;
        UITabBarController *tabBarController = self.tabBarController;
        UINavigationController *routingNavigationController = nil;
        for (UIViewController *candidate in tabBarController.viewControllers) {
            if (candidate == mailboxNavigationController ||
                ![candidate isKindOfClass:[UINavigationController class]]) continue;
            routingNavigationController = (UINavigationController *)candidate;
            break;
        }

        if (routingNavigationController) {
            ApolloClearMailboxReturn(routingNavigationController);
            // The destination lives on another tab. Restore the shared tab bar
            // before selecting it; returning to this mailbox reapplies the
            // current room/list state through apollo_prepareForMailboxReturn.
            [self apollo_restoreTabBarVisibility];
            tabBarController.selectedViewController = routingNavigationController;
        }

        UIViewController *routingAnchorBeforeOpen = routingNavigationController.topViewController;
        if (routingNavigationController && ApolloRouteResolvedURLViaApolloScheme(url)) {
            UINavigationController *destinationNavigationController =
                [tabBarController.selectedViewController isKindOfClass:[UINavigationController class]]
                    ? (UINavigationController *)tabBarController.selectedViewController
                    : routingNavigationController;
            UIViewController *destination = destinationNavigationController.topViewController;
            if (destinationNavigationController &&
                destinationNavigationController != mailboxNavigationController && destination &&
                destination != routingAnchorBeforeOpen) {
                ApolloStoreMailboxReturn(destinationNavigationController, self, destination);
                ApolloLog(@"[DirectChatWeb] Preserved mailbox while native Reddit destination %@ uses another tab",
                          NSStringFromClass(destination.class));
            }
            ApolloLog(@"[DirectChatWeb] Routed Reddit link through Apollo without changing the Inbox stack: %@",
                      url.absoluteString);
            return;
        }

        // The converter recognized Reddit but Apollo's native handler was not
        // available. Return to the still-intact mailbox before presenting
        // Apollo's browser.
        if (mailboxNavigationController && tabBarController) {
            tabBarController.selectedViewController = mailboxNavigationController;
        }
        [self apollo_prepareForMailboxReturnAnimated:NO];
        ApolloPresentWebURLFromViewController(self, url);
        ApolloLog(@"[DirectChatWeb] Native Reddit routing unavailable; used Apollo browser: %@", url.absoluteString);
        return;
    }

    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        ApolloPresentWebURLFromViewController(self, url);
    } else {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
    ApolloLog(@"[DirectChatWeb] Routed link outside isolated mailbox: %@", url.absoluteString);
}

- (void)apollo_prepareForMailboxReturnAnimated:(BOOL)animated {
    self.nativeReturnPathActive = NO;
    [self apollo_updateTabBarVisibilityForURL:self.webView.URL animated:animated];
    ApolloLog(@"[DirectChatWeb] Restored route-aware mailbox chrome");
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    // Reddit's “Open chat in full screen” control opens a new browsing context.
    // Keep mailbox routes inside the isolated web view, but never load a post,
    // profile, or third-party target into the cookie-seeded browsing context.
    if (!navigationAction.targetFrame && navigationAction.request.URL) {
        if ([self apollo_urlMatchesMailboxRoute:navigationAction.request.URL]) {
            [webView loadRequest:navigationAction.request];
        } else {
            [self apollo_routeURLOutsideMailbox:navigationAction.request.URL];
        }
    }
    return nil;
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    // Reddit Chat switches rooms with same-document client-side navigation.
    // WKWebView's URL is updated only after that transition, and neither
    // didStartProvisionalNavigation: nor didFinishNavigation: is guaranteed to
    // run. Size the pending mailbox route here so an embedded room's fixed
    // composer is already above Apollo's tab bar on the first rendered frame.
    // Arm the Modmail cover BEFORE the tab-bar update below: showing or hiding
    // the shared tab bar resizes the web view, and Reddit reflows its whole
    // document in response. Both directions of that reflow belong behind the
    // cover, and this callback runs before the URL observer does.
    if (url && self.mailboxKind == ApolloModernMailboxKindModmail &&
        !self.modmailTransitionPending) {
        if ([self apollo_isModmailConversationURL:url]) {
            [self apollo_beginModmailTransitionToURL:url isList:NO];
        } else if (self.didRevealChat && [self apollo_isModmailListURL:url]) {
            // Returning to the mailbox re-renders the whole list; the initial
            // bootstrap keeps its own loading cover instead.
            [self apollo_beginModmailTransitionToURL:url isList:YES];
        }
    }
    if (url && [self apollo_urlMatchesMailboxRoute:url]) {
        [self apollo_updateTabBarVisibilityForURL:url animated:NO];
        [self apollo_updateEmbeddedWebChromeForURL:url];
    }
    // A Chat room open reaches this policy callback before Reddit's SPA has
    // rendered anything of the room, making it the one reliable pre-paint
    // hook: cover the document now so its skeleton, late usernames/avatars,
    // and image loads all settle invisibly.
    if (url && self.mailboxKind == ApolloModernMailboxKindChat &&
        [self apollo_isChatConversationPath:url.path] && !self.chatTransitionPending) {
        [self apollo_beginChatTransitionToURL:url isList:NO];
    }
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL redditHost = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    BOOL redditHomeLogo = redditHost && [url.path isEqualToString:@"/"] && url.query.length == 0 && url.fragment.length == 0;
    if (redditHomeLogo && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloLog(@"[DirectChatWeb] Blocked Reddit home-logo navigation inside Chat");
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    if (url && navigationAction.navigationType == WKNavigationTypeLinkActivated &&
        ![self apollo_urlMatchesMailboxRoute:url]) {
        // User-selected links leave the mailbox through Apollo's native Reddit
        // router or in-app browser. Apart from avoiding the false expired-state
        // overlay, this prevents third-party pages inheriting Reddit cookies in
        // the private WKWebView used for Chat and Modmail.
        decisionHandler(WKNavigationActionPolicyCancel);
        [self apollo_routeURLOutsideMailbox:url];
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)apollo_reloadChat {
    if (self.mailboxKind == ApolloModernMailboxKindModmail) {
        [self.webView stopLoading];
        [self apollo_seedAndLoad];
        return;
    }
    if (self.webView.URL) {
        [self apollo_showLoadingWithDetail:self.mailboxKind == ApolloModernMailboxKindModmail
            ? @"Refreshing Moderator Mail…" : @"Refreshing your chat…"];
        [self.webView reloadFromOrigin];
    } else {
        [self apollo_seedAndLoad];
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    // A new document is on its way: whatever surface the old page reported
    // goes with it (the new document's first sweep reports afresh).
    self.pageConversationVisible = NO;
    self.pageConversationTreatmentsApplied = NO;
    // Reddit occasionally starts a Modmail thread through location.assign
    // without delivering a useful targetFrame in the policy callback. At this
    // point the destination URL has already been installed on WKWebView, but
    // the new document has not committed, so this remains early enough to hide
    // every placeholder/hydration frame. The pending guard makes this a no-op
    // when decidePolicyForNavigationAction: already covered the transition.
    if (self.mailboxKind == ApolloModernMailboxKindModmail && !self.modmailTransitionPending) {
        if ([self apollo_isModmailConversationURL:webView.URL]) {
            [self apollo_beginModmailTransitionToURL:webView.URL isList:NO];
        } else if (self.didRevealChat && [self apollo_isModmailListURL:webView.URL]) {
            [self apollo_beginModmailTransitionToURL:webView.URL isList:YES];
        }
    }
    // A real post-reveal navigation back to the embedded Messages list (the
    // in-room back control's fallback, or any same-route reload outside the
    // full loading pipeline) repaints from a blank document through Reddit's
    // own chrome and skeleton rows. Keep that hydration covered too.
    if (self.mailboxKind == ApolloModernMailboxKindChat && self.embeddedInInbox &&
        self.didRevealChat && !self.chatTransitionPending) {
        NSString *path = webView.URL.path ?: @"";
        if ([path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"]) {
            [self apollo_beginChatTransitionToURL:webView.URL isList:YES];
        }
    }
    [self apollo_updateTabBarVisibilityForURL:webView.URL animated:NO];
    [self apollo_updateEmbeddedWebChromeForURL:webView.URL];
    if (!self.didRevealChat) [self.spinner startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    ApolloLog(@"[DirectChatWeb] Loaded %@%@ for u/%@", webView.URL.host ?: @"unknown host", webView.URL.path ?: @"", self.username);
    [self apollo_updateTabBarVisibilityForURL:webView.URL animated:NO];
    [self apollo_updateEmbeddedWebChromeForURL:webView.URL];
    if (self.mailboxKind == ApolloModernMailboxKindModmail &&
        self.modmailWarmupPending && [webView.URL.path hasPrefix:@"/chat"]) {
        self.modmailWarmupPending = NO;
        NSString *modmailPath = self.initialDestinationPath.length > 0
            ? self.initialDestinationPath : @"/mail/all";
        ApolloLog(@"[DirectChatWeb] Modmail same-origin warm-up complete; loading requested mailbox route");
        NSMutableURLRequest *request = [NSMutableURLRequest
            requestWithURL:[NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:modmailPath]]];
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        [webView loadRequest:request];
        return;
    }
    BOOL expectedRoute = [self apollo_urlMatchesMailboxRoute:webView.URL];
    if (expectedRoute) {
        // Apply the active Apollo palette before the loading cover is removed;
        // users never see Reddit's stock colors flash during hydration.
        [self apollo_applyActiveTheme];
        // A covered Modmail destination's stability probe was started by
        // apollo_beginModmailTransitionToURL:isList: and owns the reveal —
        // including the case where a redirect lands on a different Modmail
        // route than the cover was armed for, which the probe's off-route bail
        // handles. Skip the generic readiness pipeline so it cannot reveal the
        // document mid-hydration.
        if (self.modmailTransitionPending) return;
        // A real-document conversation navigation (notification deep link) is
        // already covered by the chat transition begun in the policy callback;
        // its stability probe owns the reveal. Skip the generic readiness
        // pipeline so it cannot reveal the room mid-hydration.
        if (self.mailboxKind == ApolloModernMailboxKindChat && self.chatTransitionPending &&
            !self.chatTransitionIsList &&
            [self apollo_isChatConversationPath:webView.URL.path]) {
            return;
        }
        if (self.embeddedInInbox && self.mailboxKind == ApolloModernMailboxKindChat) {
            NSString *path = webView.URL.path ?: @"";
            BOOL wantsRequests = self.embeddedInboxSection == ApolloModernChatInboxSectionRequests;
            BOOL wantsThreads = self.embeddedInboxSection == ApolloModernChatInboxSectionThreads;
            BOOL routeMatchesSelection = wantsRequests
                ? [path hasPrefix:@"/chat/requests"]
                : (wantsThreads
                    ? [path hasPrefix:@"/chat/threads"]
                    : ([path isEqualToString:@"/chat"] || [path isEqualToString:@"/chat/"]));
            if (!routeMatchesSelection) {
                ApolloLog(@"[DirectChatWeb] Ignored stale embedded Chat navigation %@ while %@ is selected",
                          path, wantsRequests ? @"Requests" :
                          (wantsThreads ? @"Threads" : @"Messages"));
                return;
            }
            if (wantsRequests || wantsThreads) {
                [self apollo_waitForChatReadinessAttempt:0 generation:self.readinessGeneration];
            } else if (self.didRevealChat) {
                // Post-reveal real navigation back to the Messages list (the
                // in-room back control's /chat fallback). The document is
                // covered by the list transition begun in
                // didStartProvisionalNavigation and its stability probe owns
                // the reveal; here the fresh document gets the embedded-list
                // treatment: alignEmbeddedMessages sets the
                // __apolloEmbeddedInboxMessages flag, sweeps Reddit's
                // redundant chrome away, and re-measures the crop. Run it now
                // and once more after hydration settles.
                [self apollo_alignEmbeddedMessagesForGeneration:self.readinessGeneration completion:nil];
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self || self.embeddedInboxSection != ApolloModernChatInboxSectionMessages) return;
                    [self apollo_alignEmbeddedMessagesForGeneration:self.readinessGeneration completion:nil];
                    [self apollo_enableNativeScrollBounce];
                });
            } else {
                // The filter helper is itself a readiness loop and handles
                // Reddit's shadow-DOM rerenders. Starting it immediately after
                // the correct /chat document finishes avoids the generic
                // probe's 15-second timeout on valid empty chat lists.
                [self apollo_applyEmbeddedInboxFilterAttempt:0 generation:self.readinessGeneration];
            }
            return;
        }
        [self apollo_waitForChatReadinessAttempt:0 generation:self.readinessGeneration];
        return;
    }
    // An unexpected route only proves authentication failed during the initial
    // mailbox bootstrap. Once the mailbox was revealed, never cover a valid
    // page with a false “session expired” state; link-activated departures are
    // already cancelled and handed to Apollo above.
    if (!self.didRevealChat) {
        [self apollo_showAuthenticationError:@"Your Reddit web session expired. Sign in again to reconnect."
                         automaticallyPrompt:YES];
    } else {
        ApolloLog(@"[DirectChatWeb] Ignored post-reveal non-mailbox navigation: %@", webView.URL.absoluteString);
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled)
        [self apollo_showLoadError:@"Check your connection, then tap Try Again."];
    ApolloLog(@"[DirectChatWeb] Provisional navigation failed for u/%@: %@", self.username, error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled)
        [self apollo_showLoadError:@"Check your connection, then tap Try Again."];
    ApolloLog(@"[DirectChatWeb] Navigation failed for u/%@: %@", self.username, error.localizedDescription);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ApolloLog(@"[DirectChatWeb] Reddit web process terminated for u/%@", self.username);
    self.pageConversationVisible = NO;
    self.pageConversationTreatmentsApplied = NO;
    [self apollo_showLoadError:@"Reddit stopped responding. Tap Try Again to reconnect."];
}

@end

BOOL ApolloModernMailboxOSSupported(void) {
    // Same iOS 16 floor _isModernRedditSupported enforces for the web-session
    // login (ApolloWebSessionLoginViewController.m): modern reddit.com does
    // not render on iOS 14/15 WebKit, so never route anyone into it there.
    if (@available(iOS 16.0, *)) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ApolloLog(@"[DirectChatWeb] iOS < 16 — modern Chat/Modmail gates disabled");
    });
    return NO;
}

BOOL ApolloModernChatIsAvailable(void) {
    if (!ApolloModernMailboxOSSupported()) return NO;
    NSString *username = ApolloActiveWebSessionUsername();
    return username.length > 0 && ApolloWebSessionPollFor(username) != nil;
}

// Both surfaces are a straight user preference now. They used to be
// force-enabled — with the settings switches greyed out — whenever the active
// account had a primary reddit.com web session and no client identifier on the
// shared RDKClient, which was read as "this account is API-key-free, so it has
// no other option". But holding a web session is exactly what modern Chat and
// Modmail require, and an account can hold one *and* an API key: sign a keyed
// account into reddit.com to use these surfaces and the lock fired for it too,
// leaving no way back to Apollo's own Chat / Moderator Mail even though its
// credentials work fine. Because the preference is app-wide, one such account
// took the choice away from every account on the device.
//
// Modern Chat and Modmail work for keyed and keyless accounts alike, so the
// preference alone decides. Off means Apollo's own Direct Chat / Moderator
// Mail, which need Reddit API credentials — an account with no API key that
// turns these off simply has no Chat or Modmail, the same as before either
// modern surface existed. ApolloMigrateModernMailboxPreferences below makes
// sure nobody loses a surface they were relying on when the stored preference
// took over from the forced gate.
BOOL ApolloModernChatShouldOpen(void) {
    if (!ApolloModernMailboxOSSupported()) return NO;
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseModernRedditChat];
}

BOOL ApolloModernModmailShouldOpen(void) {
    if (!ApolloModernMailboxOSSupported()) return NO;
    return [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyUseModernRedditModmail];
}

void ApolloMigrateModernMailboxPreferences(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:UDKeyModernMailboxChoiceMigrated]) return;
    [defaults setBool:YES forKey:UDKeyModernMailboxChoiceMigrated];
    // The old forced-on state lived only in the derived gate, never in the
    // stored preference, so simply honouring the preference from now on would
    // silently take Chat and Modmail away from everyone who had been getting
    // them that way. Anyone running API-Key-Free Mode with a stored web session
    // was in that population — write down what they already had, which they can
    // now switch off if they would rather use Apollo's own surfaces.
    if (![defaults boolForKey:UDKeyWebJSONEnabled]) return;
    if (ApolloWebSessionUsernames().count == 0) return;
    BOOL chat = [defaults boolForKey:UDKeyUseModernRedditChat];
    BOOL modmail = [defaults boolForKey:UDKeyUseModernRedditModmail];
    if (!chat) [defaults setBool:YES forKey:UDKeyUseModernRedditChat];
    if (!modmail) [defaults setBool:YES forKey:UDKeyUseModernRedditModmail];
    if (!chat || !modmail) {
        ApolloLog(@"[DirectChatWeb] Recorded modern Chat/Modmail as on for this web-session setup "
                  @"(previously implied); both are now switchable in Settings");
    }
}

UIViewController *ApolloCreateModernChatViewController(void) {
    return ApolloCreateModernChatViewControllerForPath(nil);
}

UIViewController *ApolloCreateModernChatViewControllerForPath(NSString *destinationPath) {
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    controller.initialDestinationPath = ApolloValidatedModernMailboxPath(
        ApolloModernMailboxKindChat, destinationPath);
    // Lists remain part of the Inbox tab. Route observation hides the
    // shared tab bar only if this controller opens an actual conversation.
    controller.hidesBottomBarWhenPushed = NO;
    return controller;
}

UIViewController *ApolloCreateEmbeddedModernChatViewController(ApolloModernChatInboxSection section) {
    if (section < ApolloModernChatInboxSectionMessages ||
        section > ApolloModernChatInboxSectionThreads) {
        section = ApolloModernChatInboxSectionMessages;
    }
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    controller.embeddedInInbox = YES;
    controller.embeddedInboxSection = section;
    switch (section) {
        case ApolloModernChatInboxSectionRequests:
            controller.initialDestinationPath = @"/chat/requests";
            break;
        case ApolloModernChatInboxSectionThreads:
            controller.initialDestinationPath = @"/chat/threads";
            break;
        case ApolloModernChatInboxSectionMessages:
        default:
            controller.initialDestinationPath = @"/chat";
            break;
    }
    controller.hidesBottomBarWhenPushed = NO;
    return controller;
}

void ApolloModernChatControllerShowInboxSection(UIViewController *controller,
                                                ApolloModernChatInboxSection section) {
    if (![controller isMemberOfClass:[ApolloDirectChatWebViewController class]]) return;
    [(ApolloDirectChatWebViewController *)controller apollo_showEmbeddedInboxSection:section];
}

void ApolloModernChatControllerOpenConversationPath(UIViewController *controller, NSString *path) {
    if (![controller isMemberOfClass:[ApolloDirectChatWebViewController class]]) return;
    [(ApolloDirectChatWebViewController *)controller apollo_openConversationPath:path];
}

BOOL ApolloModernChatControllerSessionIsCurrent(UIViewController *controller) {
    if (![controller isMemberOfClass:[ApolloDirectChatWebViewController class]]) return NO;
    ApolloDirectChatWebViewController *chatController =
        (ApolloDirectChatWebViewController *)controller;
    NSString *activeUsername = ApolloActiveWebSessionUsername().lowercaseString ?: @"";
    NSString *activeCookies = ApolloWebSessionPollFor(activeUsername).cookieHeader ?: @"";
    NSString *seededUsername = chatController.username.lowercaseString ?: @"";
    NSString *seededCookies = chatController.seededCookieHeader ?: @"";
    return [seededUsername isEqualToString:activeUsername] &&
           [seededCookies isEqualToString:activeCookies];
}

void ApolloModernChatControllerSetInboxVisible(UIViewController *controller, BOOL visible) {
    if (![controller isMemberOfClass:[ApolloDirectChatWebViewController class]]) return;
    ApolloDirectChatWebViewController *chatController =
        (ApolloDirectChatWebViewController *)controller;
    chatController.embeddedInboxVisible = visible;
    if (visible) {
        [chatController apollo_updateTabBarVisibilityForURL:chatController.webView.URL animated:NO];
        // Returning to Chat after a real absence must show current messages,
        // not whatever Reddit's paused client last rendered.
        [chatController apollo_refreshAfterAwayIfStale];
    } else {
        [chatController apollo_restoreTabBarVisibility];
        if (chatController.chatWentAwayAt <= 0) {
            chatController.chatWentAwayAt = [NSDate date].timeIntervalSince1970;
        }
    }
}

BOOL ApolloModernChatControllerIsOnConversationRoute(UIViewController *controller) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return NO;
    ApolloDirectChatWebViewController *chatController =
        (ApolloDirectChatWebViewController *)controller;
    return [chatController apollo_isInsideConversation];
}

BOOL ApolloModernChatControllerGoBackToConversationList(UIViewController *controller) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return NO;
    return [(ApolloDirectChatWebViewController *)controller apollo_goBackToConversationList];
}

BOOL ApolloModernChatControllerBeginInteractiveBack(UIViewController *controller) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return NO;
    return [(ApolloDirectChatWebViewController *)controller apollo_beginInteractiveConversationBack];
}

void ApolloModernChatControllerUpdateInteractiveBack(UIViewController *controller, CGFloat progress) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return;
    [(ApolloDirectChatWebViewController *)controller apollo_updateInteractiveConversationBack:progress];
}

void ApolloModernChatControllerFinishInteractiveBack(UIViewController *controller,
                                                     BOOL commit, CGFloat velocity) {
    if (![controller isKindOfClass:[ApolloDirectChatWebViewController class]]) return;
    [(ApolloDirectChatWebViewController *)controller apollo_finishInteractiveConversationBack:commit
                                                                                     velocity:velocity];
}

void ApolloModernChatControllerRefreshEmbeddedLayout(UIViewController *controller) {
    if (![controller isMemberOfClass:[ApolloDirectChatWebViewController class]]) return;
    ApolloDirectChatWebViewController *chatController =
        (ApolloDirectChatWebViewController *)controller;
    [chatController.view setNeedsLayout];
    [chatController.view layoutIfNeeded];
    [chatController apollo_enableNativeScrollBounce];
    // WebKit may discard its private WKChildScrollView while the preloaded hub
    // is hidden and recreate it on the next compositing pass. Reapply after
    // that handoff so the real CSS overflow scroller receives the tab-bar inset.
    __weak ApolloDirectChatWebViewController *weakController = chatController;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakController apollo_enableNativeScrollBounce];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakController apollo_enableNativeScrollBounce];
    });
}

UIViewController *ApolloCreateModernModmailViewController(void) {
    return ApolloCreateModernModmailViewControllerForPath(nil);
}

UIViewController *ApolloCreateModernModmailViewControllerForPath(NSString *destinationPath) {
    ApolloDirectChatWebViewController *controller = [ApolloDirectChatWebViewController new];
    controller.mailboxKind = ApolloModernMailboxKindModmail;
    controller.initialDestinationPath = ApolloValidatedModernMailboxPath(
        ApolloModernMailboxKindModmail, destinationPath);
    // Lists remain part of the Inbox tab. Route observation hides the
    // shared tab bar only if this controller opens an actual conversation.
    controller.hidesBottomBarWhenPushed = NO;
    return controller;
}

// MARK: - Shared swipe rules
//
// A drag that begins over horizontally scrollable web content belongs to that
// content, not to a chat-hierarchy swipe (a media carousel inside a bubble, a
// horizontal picker row). WebKit backs every CSS overflow scroller with a
// real, private UIScrollView in the public view hierarchy, so one hit test
// answers this. Measure in WINDOW coordinates: locationInView: reads a stale
// view-local cache for synthesized touches (only _locationInWindow is
// maintained), which would make the simulator's own driver probe the wrong
// point.
BOOL ApolloModernChatPanStartsOverHorizontalScroller(UIPanGestureRecognizer *pan, UIView *hostView) {
    if (!pan || !hostView.window) return NO;
    CGPoint point = [hostView convertPoint:[pan locationInView:nil] fromView:nil];
    if (!CGRectContainsPoint(hostView.bounds, point)) return NO;
    UIView *hit = [hostView hitTest:point withEvent:nil];
    for (UIView *view = hit; view && view != hostView; view = view.superview) {
        if (![view isKindOfClass:[UIScrollView class]]) continue;
        UIScrollView *scrollView = (UIScrollView *)view;
        if (scrollView.contentSize.width > CGRectGetWidth(scrollView.bounds) + 8.0) return YES;
    }
    return NO;
}

// Commit like an interactive pop: past the halfway point, or a decisive throw
// in the same direction. The flick arm keeps its own axis-dominance check — a
// begin gate only samples the FIRST velocity, so a drag that starts horizontal
// and turns into a vertical scroll can still end with residual horizontal
// velocity, and without the test that diagonal release committed.
BOOL ApolloModernChatBackSwipeCommits(UIGestureRecognizerState state, CGFloat progress,
                                      CGFloat velocity, CGPoint translation) {
    BOOL flick = velocity > 350.0 && progress > 0.12 && fabs(translation.x) > fabs(translation.y);
    return state == UIGestureRecognizerStateEnded && (progress >= 0.5 || flick);
}

// MARK: - Standalone conversation back-swipe
//
// The standalone Reddit Chat screen (Boxes -> Direct Chat) has the same three
// levels the Inbox hub has, and its conversations are web routes rather than
// pushed controllers — so a back swipe inside one used to run Apollo's stock
// pop, which left Chat altogether and skipped the conversation list. The hub
// keeps that pop out of the touch by owning the gesture (its mode-pan); this
// pan does the same for the standalone screen. Every pan on the navigation
// controller's container (Apollo's full-width back/forward swipes and the
// interactive pop) and the web view's own history edge gestures are wired to
// REQUIRE its failure: inside a conversation a horizontal back-direction drag
// begins here and drives the interactive back; everywhere else the pan fails
// on the spot and the stock gestures behave exactly as before.
//
// Rejecting the gesture up front is the point. An earlier build let Apollo's
// pan run and swallowed the resulting pop at the UINavigationController level,
// which is too late: ApolloNavigationController's own popViewControllerAnimated:
// records `popping` / `viewControllerBeingPopped` (its forward-swipe
// bookkeeping) and bumps TotalTimesPoppedNavigationStack BEFORE calling super,
// and only navigationController:didShowViewController: clears them. With no
// transition that state went stale, and the next navigation filed the
// still-live Chat controller as a popped one — the forward swipe would then
// try to push a controller already on the stack. (Hopper: sub_10015ccb8 sets
// the fields, sub_10015fd98 consumes them, sub_10015e204 is the pan handler
// that calls the pop without checking its result.)
//
// A process singleton, like the hub's mode-pan: the recognizers it is wired
// against are shared by every screen on the stack, so each is wired at most
// once ever (static weak set) and the pan migrates to whichever standalone
// Chat controller is on screen. Detached or instantly failed, it satisfies
// every requirement at once, so nothing stock is ever held up.

@interface ApolloStandaloneChatBackGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation ApolloStandaloneChatBackGestureDelegate

+ (instancetype)shared {
    static ApolloStandaloneChatBackGestureDelegate *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ApolloStandaloneChatBackGestureDelegate new]; });
    return shared;
}

// The web view's scroll pan begins on ANY drag, and UIKit's default
// exclusivity would then block this pan for the rest of the touch. Recognizing
// alongside it is what lets a horizontal drag over the room begin here at all;
// the failure requirements set at wire time still outrank simultaneity, so the
// stock pans stay out while this one runs.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

// Fail INSTANTLY whenever the pan does not apply — every stock gesture on the
// stack waits on its failure, so a lingering Possible state here would add
// drag to them. NOTE: translationInView: is still zero inside this callback;
// only the velocity direction is usable.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != sStandaloneChatBackPan) return YES;
    // Zeroing-weak read: once the host deallocs this is nil and the pan simply
    // never begins (it cannot serve a dead host).
    ApolloDirectChatWebViewController *host = sStandaloneChatBackPanHost;
    if (!host || host.embeddedInInbox || host.mailboxKind != ApolloModernMailboxKindChat) return NO;
    // Only inside a conversation: on the list the stock pop is the right back.
    if (![host apollo_isInsideConversation]) return NO;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    CGPoint velocity = [pan velocityInView:pan.view];
    if (fabs(velocity.x) <= fabs(velocity.y)) return NO;   // decisively horizontal only
    CGFloat rtlSign = (pan.view.effectiveUserInterfaceLayoutDirection ==
                       UIUserInterfaceLayoutDirectionRightToLeft) ? -1.0 : 1.0;
    if (velocity.x * rtlSign <= 0.0) return NO;   // the forward direction stays with Apollo's forward pan
    if (ApolloModernChatPanStartsOverHorizontalScroller(pan, host.viewIfLoaded)) return NO;
    return YES;
}

@end

// Claim the singleton for `controller` and wire every stock gesture that could
// otherwise take a back swipe out from under it. Idempotent and cheap: re-run
// on every appearance and every room entry to catch recognizers attached later
// (pop/pan recognizers on the navigation container, WebKit's re-created edge
// recognizers). No-op for the embedded hub controller.
static void ApolloStandaloneChatBackPanInstall(ApolloDirectChatWebViewController *controller) {
    if (controller.embeddedInInbox || controller.mailboxKind != ApolloModernMailboxKindChat) return;
    UIView *hostView = controller.viewIfLoaded;
    if (!hostView) return;
    if (!sStandaloneChatBackPan) {
        sStandaloneChatBackPan = [UIPanGestureRecognizer new];
        sStandaloneChatBackPan.maximumNumberOfTouches = 1;
        sStandaloneChatBackPan.delegate = [ApolloStandaloneChatBackGestureDelegate shared];
    }
    UIPanGestureRecognizer *pan = sStandaloneChatBackPan;
    // Never migrate mid-touch — yanking a tracking recognizer off its view or
    // swapping its target kills the gesture, or delivers the end action to the
    // wrong host — and an off-window instance may not steal the pan from an
    // on-window owner.
    UIGestureRecognizerState panState = pan.state;
    BOOL panTracking = (panState == UIGestureRecognizerStateBegan ||
                        panState == UIGestureRecognizerStateChanged);
    UIView *panOwnerView = pan.view;
    BOOL mayClaim = !panTracking &&
        (hostView.window != nil || !panOwnerView || panOwnerView.window == nil);
    if (panOwnerView != hostView && mayClaim) {
        [hostView addGestureRecognizer:pan];
    }
    if (pan.view != hostView) return;
    if (!panTracking) {
        // Targets are unretained: swap in the same pass that sets the host
        // pointer so the two can never drift.
        [pan removeTarget:nil action:NULL];
        [pan addTarget:controller action:@selector(apollo_standaloneConversationBackPanned:)];
        sStandaloneChatBackPanHost = controller;
    }
    if (!sStandaloneChatBackPanWired) sStandaloneChatBackPanWired = [NSHashTable weakObjectsHashTable];
    NSHashTable *wired = sStandaloneChatBackPanWired;
    UIGestureRecognizer *pop = controller.navigationController.interactivePopGestureRecognizer;
    if (pop && ![wired containsObject:pop]) {
        [pop requireGestureRecognizerToFail:pan];
        [wired addObject:pop];
    }
    // Apollo's full-width back and forward pans (and its parallax pan) sit on
    // the navigation controller's container view up this chain. Scroll views'
    // own pans are spared — the delegate already recognizes alongside them.
    for (UIView *view = hostView; view; view = view.superview) {
        UIGestureRecognizer *scrollPan =
            [view isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)view).panGestureRecognizer : nil;
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            if (recognizer == pan || recognizer == scrollPan || recognizer == pop) continue;
            if ([wired containsObject:recognizer]) continue;
            if (![recognizer isKindOfClass:[UIPanGestureRecognizer class]]) continue;
            [recognizer requireGestureRecognizerToFail:pan];
            [wired addObject:recognizer];
        }
    }
    // The web view's history edge gestures (allowsBackForwardNavigationGestures)
    // would otherwise take an edge grab in a room and walk web history — which
    // Reddit's chat router ignores (the URL changes, the room pane stays), so
    // an edge swipe desynced the route. They sit the touch out like every other
    // stock gesture. Same trade-off as the hub's subtree walk; read both
    // rationales before "harmonizing" with ApolloFeedGalleryCarousel's, which
    // deliberately skips edge recognizers.
    UIView *webView = controller.webView;
    if (webView) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:webView];
        for (NSUInteger index = 0; index < queue.count; index++) {
            UIView *view = queue[index];
            for (UIView *subview in view.subviews) [queue addObject:subview];
            for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
                if (![recognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) continue;
                if ([wired containsObject:recognizer]) continue;
                [recognizer requireGestureRecognizerToFail:pan];
                [wired addObject:recognizer];
            }
        }
    }
}

// Called from the controller's dealloc: recognizer targets are unretained.
static void ApolloStandaloneChatBackPanForgetHost(ApolloDirectChatWebViewController *controller) {
    [sStandaloneChatBackPan removeTarget:controller action:NULL];
    if (sStandaloneChatBackPanHost == controller) sStandaloneChatBackPanHost = nil;
}

// Reddit content opened from a mailbox lives on another tab's native navigation
// stack. Back removes that temporary destination normally, then selects the
// untouched Inbox stack where the exact Chat/Modmail controller is still alive.
%hook UINavigationController

- (void)pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    // The Inbox row has its own direct modern-Modmail route, but subreddit
    // moderator menus (and any other Apollo entry point) still construct and
    // push Apollo's OAuth-only ModmailInboxViewController. Replace that
    // destination before its view loads so API-key-free accounts never land
    // on the legacy screen, and API-key accounts follow their explicit toggle.
    Class nativeModmailClass = objc_getClass("_TtC6Apollo26ModmailInboxViewController");
    if (nativeModmailClass &&
        [viewController isMemberOfClass:nativeModmailClass] &&
        ApolloModernModmailShouldOpen()) {
        ApolloLog(@"[DirectChatWeb] Redirecting native Modmail push to modern authenticated Modmail");
        %orig(ApolloCreateModernModmailViewController(), animated);
        return;
    }

    %orig;
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *anchor = ApolloMailboxReturnAnchor(self);
    if (anchor && self.topViewController == anchor) {
        // Reveal the preserved mailbox first, then clean up the now-hidden
        // native stack. Popping first briefly exposes the Posts screen between
        // the profile/subreddit and Modmail for a single rendered frame.
        ApolloReturnToMailboxFromNavigationController(self);
        return %orig(NO);
    }
    return %orig(animated);
}

%end

// Selecting Inbox already reveals the untouched mailbox. Clear the optional
// native-Back return marker so a later Back action in Posts behaves normally.
%hook _TtC6Apollo13SceneDelegate

- (BOOL)tabBarController:(UITabBarController *)tabBarController
 shouldSelectViewController:(UIViewController *)viewController {
    for (UIViewController *candidate in tabBarController.viewControllers) {
        if (![candidate isKindOfClass:[UINavigationController class]]) continue;
        UINavigationController *navigationController = (UINavigationController *)candidate;
        ApolloDirectChatWebViewController *mailbox = ApolloMailboxReturnController(navigationController);
        if (mailbox && viewController == mailbox.navigationController) {
            ApolloClearMailboxReturn(navigationController);
            [mailbox apollo_prepareForMailboxReturnAnimated:NO];
            ApolloLog(@"[DirectChatWeb] Inbox tab returned directly to preserved %@",
                      mailbox.mailboxKind == ApolloModernMailboxKindModmail ? @"Modmail" : @"Chat");
            // Apollo treats Inbox selection as a request to reset that tab's
            // stack. The mailbox is already the desired destination, so allow
            // UIKit to select it without running Apollo's reset behavior.
            return YES;
        }
    }
    return %orig(tabBarController, viewController);
}

%end

#if APOLLO_SIM_BUILD
// Sim debug bridge ("chatjs <js>"): evaluate JS in the most recently created
// mailbox web view and log the result, so a simulator can reproduce web-side
// states its own WebKit never produces (see ApolloSimDebugTap.xm).
void ApolloDirectChatDebugEvaluateJS(NSString *js);
void ApolloDirectChatDebugEvaluateJS(NSString *js) {
    dispatch_async(dispatch_get_main_queue(), ^{
        WKWebView *webView = sLatestMailboxWebController.webView;
        if (!webView) {
            ApolloLog(@"[DirectChatWeb] chatjs: no mailbox web view");
            return;
        }
        [webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
            ApolloLog(@"[DirectChatWeb] chatjs -> %@%@", result ?: @"(nil)",
                      error ? [NSString stringWithFormat:@" error: %@", error.localizedDescription] : @"");
        }];
    });
}
#endif

%ctor {
    %init;
    ApolloMigrateModernMailboxPreferences();
    // The mailbox web views load real reddit.com documents, so their isolated
    // cookie jar carries the token_v2 Reddit refreshed on the way — an
    // already-minted Matrix bearer for the chat poller and room directory.
    // Only a controller seeded for the CURRENT account's session qualifies.
    ApolloChatPollSetWebJarBearerProvider(^(void (^completion)(NSString *token)) {
        ApolloDirectChatWebViewController *controller = sLatestMailboxWebController;
        WKWebView *webView = controller.webView;
        if (!webView || !ApolloModernChatControllerSessionIsCurrent(controller)) {
            completion(nil);
            return;
        }
        [webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
            NSString *token = nil;
            for (NSHTTPCookie *cookie in cookies) {
                if ([cookie.name isEqualToString:@"token_v2"] && cookie.value.length > 0) {
                    token = cookie.value;
                    break;
                }
            }
            completion(token);
        }];
    });
    ApolloLog(@"[DirectChatWeb] module loaded");
}
