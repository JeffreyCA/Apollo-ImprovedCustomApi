// ApolloSubredditSidebar.xm
//
// Fleshes out Apollo's subreddit Sidebar screen (SubredditSidebarViewController)
// with the structured content new-Reddit shows, all sourced from one
// /r/{sub}/api/widgets fetch:
//
//   • Stats header  — the id-card's subscriber + currently-viewing counts, using
//                     the subreddit's OWN custom labels ("Season Ticket Holders"
//                     / "In Attendance", "Members" / "Online", …). Replaces
//                     Apollo's hardcoded 2-stat "SUBSCRIBERS / ACTIVE" header.
//   • Search by Flair — colored flair chips (folded in from the flair feature).
//   • Related Communities — community-list widgets: each linked sub with its
//                     icon + subscriber count, tap opens the sub.
//   • (Stage B) link-button groups, menu/bookmarks, table-of-contents tabs.
//
// Architecture: a registry-based injector wraps the sidebar scrollNode's
// layoutSpecBlock ONCE and composes an ordered array of section nodes above the
// original spec. The scrollNode is automaticallyManagesContentSize, so Texture
// owns all sizing — no frame math. (Mirrors the proven pattern from the flair
// feature, generalized to many sections.)

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "ApolloCommon.h"
#import "ApolloState.h"

// Section builders / keys here are wired up incrementally; tolerate not-yet-used
// ones under the project's -Werror without per-symbol annotations.
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-variable"

#pragma mark - Weekly visitors / contributions (hidden-WKWebView harvest)

// Reddit removed weekly visitors + contributions from the OAuth API (GraphQL-only,
// 404 to our token) but the desktop reddit.com community page carries them as
// attributes on <shreddit-subreddit-header>: weekly-active-users (= weekly visitors)
// and weekly-contributions. We load that page logged-out in a hidden WKWebView
// (desktop UA, past the JS bot-challenge — same trick as Community Highlights) and
// read the attributes. Heavy → cached; callers fall back to the Created date.
static NSCache<NSString *, NSArray<NSNumber *> *> *ApolloSBWebStatsCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; cache.countLimit = 80; });
    return cache;
}

@interface ApolloSBStatsWebFetch : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *sub;
@property (nonatomic, copy) void (^done)(NSNumber *visitors, NSNumber *contributions);
@property (nonatomic) int polls;
@end
@implementation ApolloSBStatsWebFetch
- (void)startForSub:(NSString *)sub completion:(void (^)(NSNumber *, NSNumber *))done {
    self.sub = sub; self.done = done; self.polls = 0;
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    if (!win) { [self finishV:nil c:nil]; return; }
    self.web = [[WKWebView alloc] initWithFrame:win.bounds configuration:[[WKWebViewConfiguration alloc] init]];
    self.web.navigationDelegate = self;
    self.web.alpha = 0.011; self.web.userInteractionEnabled = NO;
    self.web.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    [win insertSubview:self.web atIndex:0];
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/", sub]]]];
    ApolloLog(@"[Sidebar][webstats] loading r/%@", sub);
    [self pollAfter:3.0];
}
- (void)pollAfter:(double)d {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws poll]; });
}
- (void)poll {
    if (!self.web) return;
    self.polls++;
    NSString *js = @"(function(){var h=document.querySelector('shreddit-subreddit-header');"
        "if(!h)return '{}';return JSON.stringify({v:h.getAttribute('weekly-active-users'),c:h.getAttribute('weekly-contributions')});})()";
    __weak typeof(self) ws = self;
    [self.web evaluateJavaScript:js completionHandler:^(id res, NSError *e) {
        NSString *s = [res isKindOfClass:[NSString class]] ? res : @"{}";
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSNumber *v = [j[@"v"] isKindOfClass:[NSString class]] && [j[@"v"] length] ? @([j[@"v"] longLongValue]) : nil;
        NSNumber *c = [j[@"c"] isKindOfClass:[NSString class]] && [j[@"c"] length] ? @([j[@"c"] longLongValue]) : nil;
        if (v || c) { ApolloLog(@"[Sidebar][webstats] r/%@ visitors=%@ contributions=%@ (poll#%d)", ws.sub, v, c, ws.polls); [ws finishV:v c:c]; }
        else if (ws.polls >= 8) { ApolloLog(@"[Sidebar][webstats] r/%@ timed out", ws.sub); [ws finishV:nil c:nil]; }
        else [ws pollAfter:2.0];
    }];
}
- (void)finishV:(NSNumber *)v c:(NSNumber *)c {
    if (self.web) { self.web.navigationDelegate = nil; [self.web removeFromSuperview]; self.web = nil; }
    void (^d)(NSNumber *, NSNumber *) = self.done; self.done = nil;
    if (d) d(v, c);
}
- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {}
@end

// Retains in-flight fetchers (one per sub) so they aren't deallocated mid-load.
static NSMutableDictionary<NSString *, ApolloSBStatsWebFetch *> *ApolloSBStatsFetchers(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// completion(@[visitors, contributions]) on the main queue — synchronous on a warm
// cache, else after the web harvest. visitors/contributions may be nil on failure.
static void ApolloSBFetchWebStats(NSString *sub, void (^completion)(NSNumber *visitors, NSNumber *contributions)) {
    NSString *key = sub.lowercaseString ?: @"";
    NSArray<NSNumber *> *cached = [ApolloSBWebStatsCache() objectForKey:key];
    if (cached) { completion(cached.count > 0 && cached[0] != (id)NSNull.null ? cached[0] : nil,
                             cached.count > 1 && cached[1] != (id)NSNull.null ? cached[1] : nil); return; }
    if (ApolloSBStatsFetchers()[key]) return; // already in flight
    ApolloSBStatsWebFetch *f = [[ApolloSBStatsWebFetch alloc] init];
    ApolloSBStatsFetchers()[key] = f;
    [f startForSub:sub completion:^(NSNumber *v, NSNumber *c) {
        // Cache success (both nil = failure: don't cache, so a later visit retries).
        if (v || c) [ApolloSBWebStatsCache() setObject:@[v ?: (id)NSNull.null, c ?: (id)NSNull.null] forKey:key];
        [ApolloSBStatsFetchers() removeObjectForKey:key];
        completion(v, c);
    }];
}

#pragma mark - Texture interfaces (runtime-bound)

typedef NS_ENUM(unsigned char, ApolloSBStackDirection) {
    ApolloSBStackVertical = 0,
    ApolloSBStackHorizontal = 1,
};
// ASStackLayoutJustifyContent
enum { ApolloSBJustifyStart = 0, ApolloSBJustifyCenter = 1, ApolloSBJustifyEnd = 2, ApolloSBJustifySpaceBetween = 3, ApolloSBJustifySpaceAround = 4 };
// ASStackLayoutAlignItems
enum { ApolloSBAlignStart = 0, ApolloSBAlignEnd = 1, ApolloSBAlignCenter = 2, ApolloSBAlignStretch = 3 };

static const NSUInteger kApolloSBControlEventTouchUpInside = 1 << 4;
static const NSUInteger kApolloSBFlexWrapWrap = 1;

// ASSizeRange
struct CDStruct_90e057aa { CGSize min; CGSize max; };

@class ASLayoutSpec;

// ASDimension { ASDimensionUnit unit (NSInteger: 0=auto,1=points,2=fraction); CGFloat value; }
typedef struct { NSInteger unit; CGFloat value; } ApolloSBDimension;
static inline ApolloSBDimension ApolloSBPoints(CGFloat v) { return (ApolloSBDimension){1, v}; }
static inline ApolloSBDimension ApolloSBAutoDim(void) { return (ApolloSBDimension){0, 0}; }

@interface ApolloSBLayoutElementStyle : NSObject
@property (nonatomic) CGSize preferredSize;
@property (nonatomic) CGFloat flexGrow;
@property (nonatomic) CGFloat flexShrink;
@property (nonatomic) ApolloSBDimension maxHeight;
@end

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (void)removeFromSupernode;
- (void)setNeedsLayout;
- (UIView *)view;
- (ApolloSBLayoutElementStyle *)style;
@property (nonatomic) BOOL automaticallyManagesSubnodes;
@property (nonatomic) BOOL clipsToBounds;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nullable, nonatomic, copy) ASLayoutSpec *(^layoutSpecBlock)(ASDisplayNode *node, struct CDStruct_90e057aa constrainedSize);
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

@interface ASControlNode : ASDisplayNode
- (void)addTarget:(id)target action:(SEL)action forControlEvents:(NSUInteger)controlEvents;
@end

@interface ASButtonNode : ASControlNode
- (void)setTitle:(NSString *)title withFont:(UIFont *)font withColor:(UIColor *)color forState:(NSUInteger)state;
@property (nonatomic) UIEdgeInsets contentEdgeInsets;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nullable, nonatomic, strong) UIImage *image;
@property (nonatomic) UIViewContentMode contentMode;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic, copy) UIColor *placeholderColor;
@end

@interface ASLayoutSpec : NSObject
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) CGFloat lineSpacing;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloSBStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(NSUInteger)justifyContent
                                  alignItems:(NSUInteger)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

#pragma mark - Class accessors

static Class ApolloSBNodeClass(void)    { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASDisplayNode"); }); return c; }
static Class ApolloSBTextClass(void)    { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASTextNode"); }); return c; }
static Class ApolloSBButtonClass(void)  { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASButtonNode"); }); return c; }
static Class ApolloSBControlClass(void) { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASControlNode"); }); return c; }
static Class ApolloSBImageClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASNetworkImageNode"); }); return c; }
static Class ApolloSBStackClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASStackLayoutSpec"); }); return c; }
static Class ApolloSBInsetClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASInsetLayoutSpec"); }); return c; }
static Class ApolloSBRatioClass(void)   { static Class c; static dispatch_once_t o; dispatch_once(&o, ^{ c = objc_getClass("ASRatioLayoutSpec"); }); return c; }

#pragma mark - Swift ivar helpers

static NSString *ApolloSBDecodeSwiftString(uint64_t w0, uint64_t w1) {
    if (w1 == 0) return nil;
    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";
        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }
    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sBridge = (BridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF"); });
    return sBridge ? sBridge(w0, w1) : nil;
}

static ptrdiff_t ApolloSBIvarOffset(Class cls, const char *name) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? ivar_getOffset(ivar) : -1;
}

static id ApolloSBReadObjectIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloSBIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return (__bridge id)(*(void **)(base + offset));
}

static NSString *ApolloSBReadSwiftStringIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloSBIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return ApolloSBDecodeSwiftString(*(uint64_t *)(base + offset), *(uint64_t *)(base + offset + 0x08));
}

#pragma mark - Small utilities

static UIColor *ApolloSBColorFromHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length < 4) return nil;
    NSString *cleaned = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (cleaned.length != 6) return nil;
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:cleaned] scanHexInt:&value]) return nil;
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0 green:((value >> 8) & 0xFF) / 255.0 blue:(value & 0xFF) / 255.0 alpha:1.0];
}

static NSString *ApolloSBFormatCount(long long n) {
    if (n >= 1000000) return [NSString stringWithFormat:@"%.1fM", n / 1000000.0];
    if (n >= 1000)    return [NSString stringWithFormat:@"%.1fK", n / 1000.0];
    return [NSString stringWithFormat:@"%lld", n];
}

static NSString *ApolloSBString(id v) { return [v isKindOfClass:[NSString class]] ? v : nil; }
static long long ApolloSBLongLong(id v) { return [v isKindOfClass:[NSNumber class]] ? [v longLongValue] : 0; }

// Normalize a section/widget title for fuzzy matching (lowercase, trimmed,
// punctuation/leading "r/" stripped, collapsed whitespace).
static NSString *ApolloSBNormTitle(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    s = [[s lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) [out appendFormat:@"%C", ch];
        else if (ch == ' ' && out.length && [out characterAtIndex:out.length - 1] != ' ') [out appendString:@" "];
    }
    NSString *r = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return r.length ? r : nil;
}
static void ApolloSBAddTitle(NSMutableSet<NSString *> *set, NSString *title) {
    NSString *n = ApolloSBNormTitle(title);
    if (n) [set addObject:n];
}

// Returns the first Discord invite URL found in `text` (discord.gg/… or
// discord(app).com/invite/…), normalized to an https URL, or nil. Used to surface
// a "Join our Discord" banner when a sub only links Discord from its bio markdown.
static NSString *ApolloSBFindDiscordInvite(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(?:https?://)?(?:www\\.)?(?:discord\\.gg|discord(?:app)?\\.com/invite)/[A-Za-z0-9_-]+"
              options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m) return nil;
    NSString *url = [text substringWithRange:m.range];
    if (![url.lowercaseString hasPrefix:@"http"]) url = [@"https://" stringByAppendingString:url];
    return url;
}

// Strip subreddit-emoji :tokens: from flair / label text for display.
static NSString *ApolloSBStripEmojiTokens(NSString *raw) {
    if (raw.length == 0) return raw;
    static NSRegularExpression *regex; static dispatch_once_t once;
    dispatch_once(&once, ^{ regex = [NSRegularExpression regularExpressionWithPattern:@":[A-Za-z0-9_+-]+:" options:0 error:NULL]; });
    NSString *s = [regex stringByReplacingMatchesInString:raw options:0 range:NSMakeRange(0, raw.length) withTemplate:@""];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([s containsString:@"  "]) s = [s stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return s.length > 0 ? s : raw;
}

#pragma mark - Tap targets

// Generic link tap: reddit hosts route natively; everything else opens Apollo's
// in-app web browser.
@interface ApolloSBLinkTapTarget : NSObject
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, weak) UIViewController *hostVC;
- (void)linkTapped:(id)sender;
@end
@implementation ApolloSBLinkTapTarget
- (void)linkTapped:(id)sender {
    NSURL *url = self.urlString.length ? [NSURL URLWithString:self.urlString] : nil;
    if (!url) return;
    ApolloLog(@"[Sidebar] link tapped -> %@", self.urlString);
    if (!ApolloRouteResolvedURLViaApolloScheme(url)) {
        if (self.hostVC) ApolloPresentWebURLFromViewController(self.hostVC, url);
    }
}
@end

// Flair chip tap: builds a flair_name:"…" search restricted to the sub.
@interface ApolloSBFlairTapTarget : NSObject
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *searchText;
- (void)chipTapped:(id)sender;
@end
@implementation ApolloSBFlairTapTarget
- (void)chipTapped:(id)sender {
    if (self.subredditName.length == 0 || self.searchText.length == 0) return;
    NSURLComponents *c = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://www.reddit.com/r/%@/search", self.subredditName]];
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:[NSString stringWithFormat:@"flair_name:\"%@\"", self.searchText]],
        [NSURLQueryItem queryItemWithName:@"restrict_sr" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"sort" value:@"new"],
    ];
    if (c.URL) ApolloRouteResolvedURLViaApolloScheme(c.URL);
}
@end

static char kApolloSBCollapseTargetKey;  // ApolloSBCollapseTarget on a collapsible container (declared early for the TOC tap)

// Table-of-contents chip tap: scrolls the sidebar to the target section (and
// expands it if it's a collapsible section).
@interface ApolloSBTOCTapTarget : NSObject
@property (nonatomic, weak) ASDisplayNode *scrollNode;
@property (nonatomic, weak) ASDisplayNode *targetSection;
- (void)tocTapped:(id)sender;
@end
@implementation ApolloSBTOCTapTarget
- (void)tocTapped:(id)sender {
    ASDisplayNode *scroll = self.scrollNode, *target = self.targetSection;
    if (!scroll || !target) return;
    id collapseTarget = objc_getAssociatedObject(target, &kApolloSBCollapseTargetKey);
    if ([collapseTarget respondsToSelector:@selector(expand)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [collapseTarget performSelector:@selector(expand)];
#pragma clang diagnostic pop
    }
    UIView *sv = scroll.view, *tv = target.view;
    if (![sv isKindOfClass:[UIScrollView class]] || !tv || !tv.superview) return;
    UIScrollView *scrollView = (UIScrollView *)sv;
    [scrollView layoutIfNeeded];
    CGRect r = [tv.superview convertRect:tv.frame toView:scrollView]; // content-space y
    CGFloat top = scrollView.adjustedContentInset.top;
    CGFloat minY = -top;
    CGFloat maxY = MAX(minY, scrollView.contentSize.height - scrollView.bounds.size.height + scrollView.adjustedContentInset.bottom);
    CGFloat y = MAX(minY, MIN(r.origin.y - top - 8.0, maxY));
    [scrollView setContentOffset:CGPointMake(0, y) animated:YES];
}
@end

// "Show more"/"Show less" toggle for the (height-clipped) description bio.
static const CGFloat kApolloSBBioCollapsedHeight = 52.0; // ~2 lines, then "Show more"
static char kApolloSBBioExpandedKey; // @YES (expanded) on the markdown node, else absent

@interface ApolloSBBioToggleTarget : NSObject
@property (nonatomic, weak) ASDisplayNode *markdownNode;
@property (nonatomic, weak) ASDisplayNode *scrollNode;
@property (nonatomic, weak) ASButtonNode *button;
- (void)toggle:(id)sender;
@end
@implementation ApolloSBBioToggleTarget
- (void)toggle:(id)sender {
    ASDisplayNode *md = self.markdownNode, *scroll = self.scrollNode;
    if (!md) return;
    BOOL expanded = (objc_getAssociatedObject(md, &kApolloSBBioExpandedKey) == nil); // was collapsed -> expand
    objc_setAssociatedObject(md, &kApolloSBBioExpandedKey, expanded ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    md.style.maxHeight = expanded ? ApolloSBAutoDim() : ApolloSBPoints(kApolloSBBioCollapsedHeight);
    [self.button setTitle:(expanded ? @"Show less" : @"Show more")
                 withFont:[UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold]
                withColor:UIColor.secondaryLabelColor forState:0];
    [md setNeedsLayout];
    [scroll setNeedsLayout];
}
@end

#pragma mark - Widgets fetch (raw root dict, cached)

static NSString *ApolloSBEscapedSubreddit(NSString *name) {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [name stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: name;
}

static NSCache<NSString *, NSDictionary *> *ApolloSBWidgetsCache(void) {
    static NSCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSCache alloc] init]; });
    return cache;
}

static void ApolloSBFetchWidgets(NSString *subredditName, void (^completion)(NSDictionary *root)) {
    if (subredditName.length == 0) { completion(nil); return; }
    NSString *cacheKey = subredditName.lowercaseString;
    NSDictionary *cached = [ApolloSBWidgetsCache() objectForKey:cacheKey];
    if (cached) { completion(cached.count ? cached : nil); return; }

    NSString *escaped = ApolloSBEscapedSubreddit(subredditName);
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *urlString = token.length > 0
        ? [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/widgets?raw_json=1", escaped]
        : [NSString stringWithFormat:@"https://www.reddit.com/r/%@/api/widgets.json?raw_json=1", escaped];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 15.0;
    if (token.length > 0) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"ApolloSidebar/1.0") forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : -1;
        id json = data.length > 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        ApolloLog(@"[Sidebar] widgets fetch r/%@ status=%ld items=%lu err=%@",
                  subredditName, (long)status, (unsigned long)[root[@"items"] count], error.localizedDescription ?: @"nil");
        if (root.count) {
            [ApolloSBWidgetsCache() setObject:root forKey:cacheKey];
        } else if (status == 200) {
            [ApolloSBWidgetsCache() setObject:@{} forKey:cacheKey]; // cache the miss
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(root); });
    }] resume];
}

#pragma mark - Section node builders

static const CGFloat kApolloSBSectionTitleSize = 20.0;
static const CGFloat kApolloSBCommunityIconDiameter = 34.0;

static ASTextNode *ApolloSBMakeTitleNode(NSString *title) {
    ASTextNode *node = [[ApolloSBTextClass() alloc] init];
    node.attributedText = [[NSAttributedString alloc] initWithString:(title ?: @"") attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:kApolloSBSectionTitleSize weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    return node;
}

// --- Stats (id-card) -------------------------------------------------------

// One stat column: small grey uppercase label on top, big bold count below
// (matching the native header it replaces).
static ASDisplayNode *ApolloSBMakeStatColumn(NSString *label, NSString *value) {
    ASTextNode *labelNode = [[ApolloSBTextClass() alloc] init];
    labelNode.attributedText = [[NSAttributedString alloc] initWithString:[label uppercaseString] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
        NSKernAttributeName: @(0.4),
    }];
    ASTextNode *countNode = [[ApolloSBTextClass() alloc] init];
    countNode.attributedText = [[NSAttributedString alloc] initWithString:(value ?: @"—") attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    ASDisplayNode *col = [[ApolloSBNodeClass() alloc] init];
    col.automaticallyManagesSubnodes = YES;
    col.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:3.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignCenter
                                                         children:@[labelNode, countNode]];
    };
    return col;
}

static ASDisplayNode *ApolloSBBuildStatsSection(NSArray<ASDisplayNode *> *columns) {
    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:12.0
                                                   justifyContent:ApolloSBJustifySpaceAround alignItems:ApolloSBAlignCenter
                                                         children:columns];
    };
    return container;
}

// --- Flair -----------------------------------------------------------------

static ASDisplayNode *ApolloSBBuildFlairSection(NSString *title, NSArray *order, NSDictionary *templates,
                                                NSString *subredditName, NSMutableArray *tapTargets) {
    NSMutableArray *chipNodes = [NSMutableArray array];
    for (NSString *templateID in order) {
        NSDictionary *tpl = [templates[templateID] isKindOfClass:[NSDictionary class]] ? templates[templateID] : nil;
        NSString *text = ApolloSBString(tpl[@"text"]);
        if (text.length == 0) continue;
        UIColor *background = ApolloSBColorFromHex(tpl[@"backgroundColor"]);
        BOOL lightText = [ApolloSBString(tpl[@"textColor"]) isEqualToString:@"light"];
        UIColor *textColor = background ? (lightText ? UIColor.whiteColor : [UIColor colorWithWhite:0.1 alpha:1.0]) : UIColor.labelColor;

        ASButtonNode *chip = [[ApolloSBButtonClass() alloc] init];
        [chip setTitle:ApolloSBStripEmojiTokens(text) withFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold] withColor:textColor forState:0];
        chip.backgroundColor = background ?: [UIColor colorWithWhite:0.5 alpha:0.25];
        chip.cornerRadius = 13.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(5.0, 12.0, 5.0, 12.0);

        ApolloSBFlairTapTarget *target = [[ApolloSBFlairTapTarget alloc] init];
        target.subredditName = subredditName;
        target.searchText = text;
        [tapTargets addObject:target];
        [chip addTarget:target action:@selector(chipTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
        [chipNodes addObject:chip];
    }
    if (chipNodes.count == 0) return nil;

    ASTextNode *titleNode = ApolloSBMakeTitleNode(title.length ? title : @"Search by Flair");
    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASStackLayoutSpec *cloud = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:8.0
                                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:chipNodes];
        cloud.flexWrap = kApolloSBFlexWrapWrap;
        cloud.lineSpacing = 8.0;
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:12.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:@[titleNode, cloud]];
    };
    return container;
}

// --- Community list (Related Communities) ----------------------------------

static ASControlNode *ApolloSBBuildCommunityRow(NSDictionary *community, UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSString *name = ApolloSBString(community[@"name"]);
    if (name.length == 0) return nil;
    NSString *iconURL = ApolloSBString(community[@"communityIcon"]) ?: ApolloSBString(community[@"iconUrl"]);
    long long subs = ApolloSBLongLong(community[@"subscribers"]);

    ASNetworkImageNode *icon = [[ApolloSBImageClass() alloc] init];
    if (iconURL.length) icon.URL = [NSURL URLWithString:iconURL];
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.clipsToBounds = YES;
    icon.cornerRadius = kApolloSBCommunityIconDiameter / 2.0;
    icon.placeholderColor = [UIColor secondarySystemFillColor];
    icon.style.preferredSize = CGSizeMake(kApolloSBCommunityIconDiameter, kApolloSBCommunityIconDiameter);

    ASTextNode *nameNode = [[ApolloSBTextClass() alloc] init];
    nameNode.attributedText = [[NSAttributedString alloc] initWithString:[@"r/" stringByAppendingString:name] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];
    ASTextNode *subsNode = [[ApolloSBTextClass() alloc] init];
    subsNode.attributedText = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ members", ApolloSBFormatCount(subs)] attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
    }];

    ApolloSBLinkTapTarget *target = [[ApolloSBLinkTapTarget alloc] init];
    target.urlString = [NSString stringWithFormat:@"https://www.reddit.com/r/%@", name];
    target.hostVC = hostVC;
    [tapTargets addObject:target];

    ASControlNode *row = [[ApolloSBControlClass() alloc] init];
    row.automaticallyManagesSubnodes = YES;
    [row addTarget:target action:@selector(linkTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
    row.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASStackLayoutSpec *textCol = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:1.0
                                                                         justifyContent:ApolloSBJustifyCenter alignItems:ApolloSBAlignStart children:@[nameNode, subsNode]];
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:10.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignCenter children:@[icon, textCol]];
    };
    return row;
}

static ASDisplayNode *ApolloSBBuildCommunityListSection(NSString *title, NSArray *communities, UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *c in communities) {
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        ASControlNode *row = ApolloSBBuildCommunityRow(c, hostVC, tapTargets);
        if (row) [rows addObject:row];
    }
    if (rows.count == 0) return nil;

    // Body only (no title) — the caller wraps this in a collapsible header.
    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:12.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:rows];
    };
    return container;
}

// --- Link-button groups (button + menu widgets) ----------------------------

static ASButtonNode *ApolloSBMakeLinkPill(NSString *text, NSString *urlString, UIColor *fill, UIColor *textColor,
                                          UIViewController *hostVC, NSMutableArray *tapTargets) {
    ASButtonNode *btn = [[ApolloSBButtonClass() alloc] init];
    [btn setTitle:(text ?: @"") withFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
        withColor:(textColor ?: UIColor.labelColor) forState:0];
    btn.backgroundColor = fill ?: [UIColor colorWithWhite:0.5 alpha:0.18];
    btn.cornerRadius = 12.0;
    btn.contentEdgeInsets = UIEdgeInsetsMake(11.0, 14.0, 11.0, 14.0);

    ApolloSBLinkTapTarget *t = [[ApolloSBLinkTapTarget alloc] init];
    t.urlString = urlString;
    t.hostVC = hostVC;
    [tapTargets addObject:t];
    [btn addTarget:t action:@selector(linkTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
    return btn;
}

// links: array of {text, url, fill?(UIColor), textColor?(UIColor)}
static ASDisplayNode *ApolloSBBuildLinkGroupSection(NSString *title, NSArray<NSDictionary *> *links,
                                                    UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSMutableArray *pills = [NSMutableArray array];
    for (NSDictionary *link in links) {
        NSString *text = ApolloSBString(link[@"text"]);
        NSString *url = ApolloSBString(link[@"url"]);
        if (text.length == 0 || url.length == 0) continue;
        UIColor *fill = [link[@"fill"] isKindOfClass:[UIColor class]] ? link[@"fill"] : nil;
        UIColor *tc = [link[@"textColor"] isKindOfClass:[UIColor class]] ? link[@"textColor"] : nil;
        [pills addObject:ApolloSBMakeLinkPill(text, url, fill, tc, hostVC, tapTargets)];
    }
    if (pills.count == 0) return nil;

    NSMutableArray *children = [NSMutableArray array];
    if (title.length) [children addObject:ApolloSBMakeTitleNode(title)];
    [children addObjectsFromArray:pills];

    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:8.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
    };
    return container;
}

static NSArray *ApolloSBLinksFromButtonWidget(NSDictionary *w) {
    NSMutableArray *links = [NSMutableArray array];
    for (NSDictionary *b in (NSArray *)w[@"buttons"]) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = ApolloSBString(b[@"text"]);
        NSString *url = ApolloSBString(b[@"url"]);
        if (text.length == 0 || url.length == 0) continue;
        NSMutableDictionary *d = [@{ @"text": text, @"url": url } mutableCopy];
        UIColor *fill = ApolloSBColorFromHex(ApolloSBString(b[@"fillColor"]) ?: ApolloSBString(b[@"color"]));
        UIColor *tc = ApolloSBColorFromHex(ApolloSBString(b[@"textColor"]));
        if (fill) d[@"fill"] = fill;
        if (tc) d[@"textColor"] = tc;
        [links addObject:d];
    }
    return links;
}

// --- Image widget (banners / "Join our Discord" tiles) ---------------------

static ASDisplayNode *ApolloSBBuildImageSection(NSDictionary *w, UIViewController *hostVC, NSMutableArray *tapTargets) {
    NSArray *data = [w[@"data"] isKindOfClass:[NSArray class]] ? w[@"data"] : nil;
    NSDictionary *img = [data.firstObject isKindOfClass:[NSDictionary class]] ? data.firstObject : nil;
    NSString *url = ApolloSBString(img[@"url"]);
    if (url.length == 0) return nil;
    NSString *linkURL = ApolloSBString(img[@"linkUrl"]);
    CGFloat iw = [img[@"width"] isKindOfClass:[NSNumber class]] ? [img[@"width"] doubleValue] : 0;
    CGFloat ih = [img[@"height"] isKindOfClass:[NSNumber class]] ? [img[@"height"] doubleValue] : 0;
    CGFloat ratio = (iw > 0 && ih > 0) ? (ih / iw) : 0.42; // height:width

    ASNetworkImageNode *imageNode = [[ApolloSBImageClass() alloc] init];
    imageNode.URL = [NSURL URLWithString:url];
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.clipsToBounds = YES;
    imageNode.cornerRadius = 10.0;
    imageNode.placeholderColor = [UIColor secondarySystemFillColor];

    NSString *title = ApolloSBString(w[@"shortName"]);
    ASTextNode *titleNode = title.length ? ApolloSBMakeTitleNode(title) : nil;

    ASControlNode *container = [[ApolloSBControlClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    if (linkURL.length) {
        ApolloSBLinkTapTarget *t = [[ApolloSBLinkTapTarget alloc] init];
        t.urlString = linkURL;
        t.hostVC = hostVC;
        [tapTargets addObject:t];
        [container addTarget:t action:@selector(linkTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
    }
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASLayoutSpec *ratioSpec = [ApolloSBRatioClass() ratioLayoutSpecWithRatio:ratio child:imageNode];
        if (!titleNode) return ratioSpec;
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:10.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:@[titleNode, ratioSpec]];
    };
    return container;
}

// --- Collapsible section (tappable header + chevron; body hidden when collapsed) ---

static NSAttributedString *ApolloSBChevronText(BOOL collapsed) {
    // Down when collapsed ("tap to reveal below"), up when expanded; sized larger
    // than the title so the disclosure affordance is clearly noticeable.
    return [[NSAttributedString alloc] initWithString:(collapsed ? @"▾" : @"▴") attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: UIColor.secondaryLabelColor,
    }];
}

static char kApolloSBCollapsedKey;       // NSNumber(BOOL) on the collapsible container

@interface ApolloSBCollapseTarget : NSObject
@property (nonatomic, weak) ASDisplayNode *container;
@property (nonatomic, weak) ASTextNode *chevron;
@property (nonatomic, weak) ASDisplayNode *scrollNode;
@property (nonatomic, weak) ASDisplayNode *relayoutNode; // intervening section container for NESTED collapsibles; nil at top level
- (void)toggle:(id)sender;
- (void)expand;
@end
@implementation ApolloSBCollapseTarget
- (void)applyCollapsed:(BOOL)collapsed {
    ASDisplayNode *c = self.container;
    if (!c) return;
    objc_setAssociatedObject(c, &kApolloSBCollapsedKey, collapsed ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.chevron.attributedText = ApolloSBChevronText(collapsed);
    [c setNeedsLayout];
    // A NESTED collapsible (e.g. a menu group inside the Community Bookmarks
    // container) sits under an intervening container whose layoutSpecBlock captures
    // its children by value and never reads collapsed state — so it can serve a
    // cached layout and miss the grown child. Dirty it too. nil for top-level.
    [self.relayoutNode setNeedsLayout];
    [self.scrollNode setNeedsLayout];
}
- (void)toggle:(id)sender { [self applyCollapsed:![objc_getAssociatedObject(self.container, &kApolloSBCollapsedKey) boolValue]]; }
- (void)expand { if ([objc_getAssociatedObject(self.container, &kApolloSBCollapsedKey) boolValue]) [self applyCollapsed:NO]; }
@end

// Title for a PILL-STYLE group header (nested menu groups): matches the link cells
// — 15pt semibold, centered — so a collapsible group reads as one of the bookmark
// cells, distinguished only by its disclosure chevron.
static ASTextNode *ApolloSBMakePillTitleNode(NSString *title) {
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    ASTextNode *node = [[ApolloSBTextClass() alloc] init];
    node.attributedText = [[NSAttributedString alloc] initWithString:(title ?: @"") attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor,
        NSParagraphStyleAttributeName: para,
    }];
    return node;
}

// Wraps `body` under a tappable title-row header. `startCollapsed` hides the body
// until the header (or its TOC tab) is tapped. `isSubSection` renders the header as
// a PILL (matching the section's link cells) with a trailing disclosure chevron, so
// a nested menu group looks like a bookmark cell you can tap to reveal its children;
// top-level sections keep the plain 20pt-bold title row. `relayoutNode` is the
// intervening section container to invalidate on toggle (nil for top-level).
static ASDisplayNode *ApolloSBMakeCollapsibleEx(NSString *title, ASDisplayNode *body, BOOL startCollapsed,
                                                BOOL isSubSection, ASDisplayNode *relayoutNode,
                                                ASDisplayNode *scrollNode, NSMutableArray *tapTargets) {
    if (!body) return nil;
    ASTextNode *titleNode = isSubSection ? ApolloSBMakePillTitleNode(title) : ApolloSBMakeTitleNode(title);
    ASTextNode *chevron = [[ApolloSBTextClass() alloc] init];
    chevron.attributedText = ApolloSBChevronText(startCollapsed);

    ASControlNode *header = [[ApolloSBControlClass() alloc] init];
    header.automaticallyManagesSubnodes = YES;
    if (isSubSection) {
        // Pill header: same dark rounded background + padding as a link cell, with
        // the title centered and the disclosure chevron pinned to the trailing edge.
        // flexGrow on the title fills the row so the chevron sits at the right.
        header.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.18];
        header.cornerRadius = 12.0;
        header.clipsToBounds = YES;
        titleNode.style.flexGrow = 1.0;
        titleNode.style.flexShrink = 1.0;
        header.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
            ASStackLayoutSpec *row = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:8.0
                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignCenter children:@[titleNode, chevron]];
            return [ApolloSBInsetClass() insetLayoutSpecWithInsets:UIEdgeInsetsMake(11, 14, 11, 14) child:row];
        };
    } else {
        header.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
            return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:8.0
                                                       justifyContent:ApolloSBJustifySpaceBetween alignItems:ApolloSBAlignCenter children:@[titleNode, chevron]];
        };
    }

    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    objc_setAssociatedObject(container, &kApolloSBCollapsedKey, startCollapsed ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloSBCollapseTarget *t = [[ApolloSBCollapseTarget alloc] init];
    t.container = container; t.chevron = chevron; t.scrollNode = scrollNode; t.relayoutNode = relayoutNode;
    [tapTargets addObject:t];
    objc_setAssociatedObject(container, &kApolloSBCollapseTargetKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [header addTarget:t action:@selector(toggle:) forControlEvents:kApolloSBControlEventTouchUpInside];

    // Nested sub-sections hug their pills a little tighter (8pt header→body gap).
    CGFloat innerSpacing = isSubSection ? 8.0 : 12.0;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *node, struct CDStruct_90e057aa cs) {
        BOOL collapsed = [objc_getAssociatedObject(node, &kApolloSBCollapsedKey) boolValue];
        NSArray *children = collapsed ? @[header] : @[header, body];
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:innerSpacing
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
    };
    return container;
}

// Back-compat shim: existing top-level callers (community-list, etc.) keep the
// 20pt-bold header, no sub-section styling, no nested relayout node.
static ASDisplayNode *ApolloSBMakeCollapsible(NSString *title, ASDisplayNode *body, BOOL startCollapsed,
                                              ASDisplayNode *scrollNode, NSMutableArray *tapTargets) {
    return ApolloSBMakeCollapsibleEx(title, body, startCollapsed, NO, nil, scrollNode, tapTargets);
}

// Builds the "Community Bookmarks" section from a topbar "menu" widget. Top-level
// entries are walked IN ORDER: a direct {text,url} entry renders as a normal pill
// in place; a {text, children:[...]} entry renders as a COLLAPSED pill cell (looks
// like a bookmark cell + disclosure chevron) that reveals its child pills on tap. A purely-flat
// menu (no groups) yields title + pills in an 8pt vstack — byte-identical to the
// old flat render. Rendered group names feed `widgetTitles` (may be nil) for bio
// dedup. Returns nil when nothing renders (caller no-ops on a nil section).
static ASDisplayNode *ApolloSBBuildMenuSection(NSString *title, NSDictionary *menuWidget, UIViewController *hostVC,
                                               ASDisplayNode *scrollNode, NSMutableArray *tapTargets,
                                               NSMutableSet<NSString *> *widgetTitles) {
    NSArray *data = [menuWidget[@"data"] isKindOfClass:[NSArray class]] ? menuWidget[@"data"] : nil;
    if (data.count == 0) return nil;

    // The section container is created up front so each group's collapse target can
    // invalidate it on toggle (nested relayout — its block captures children by value).
    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;

    NSMutableArray *children = [NSMutableArray array]; // section children, IN ORDER
    if (title.length) [children addObject:ApolloSBMakeTitleNode(title)];

    for (id entryObj in data) {
        if (![entryObj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = (NSDictionary *)entryObj;

        if ([entry[@"children"] isKindOfClass:[NSArray class]]) {
            // GROUP / dropdown — collect valid child links in order.
            NSMutableArray<NSDictionary *> *childLinks = [NSMutableArray array];
            for (id c in (NSArray *)entry[@"children"]) {
                if (![c isKindOfClass:[NSDictionary class]]) continue;
                NSString *ct = ApolloSBString(((NSDictionary *)c)[@"text"]), *cu = ApolloSBString(((NSDictionary *)c)[@"url"]);
                if (ct.length && cu.length) [childLinks addObject:@{ @"text": ct, @"url": cu }];
            }
            if (childLinks.count == 0) continue;                          // empty group — skip entirely
            NSString *realName = ApolloSBString(entry[@"text"]);
            NSString *groupName = realName.length ? realName : @"More";   // defensive: unnamed group
            ASDisplayNode *body = ApolloSBBuildLinkGroupSection(nil, childLinks, hostVC, tapTargets); // title==nil => body only
            ASDisplayNode *group = ApolloSBMakeCollapsibleEx(groupName, body, /*startCollapsed=*/YES,
                                                             /*isSubSection=*/YES, /*relayoutNode=*/container,
                                                             scrollNode, tapTargets);
            if (group) {
                [children addObject:group];
                if (widgetTitles && realName.length) ApolloSBAddTitle(widgetTitles, realName); // rendered-only dedup, skip "More"
            }
        } else {
            // DIRECT link — a normal pill in original position.
            NSString *text = ApolloSBString(entry[@"text"]), *url = ApolloSBString(entry[@"url"]);
            if (text.length == 0 || url.length == 0) continue;
            [children addObject:ApolloSBMakeLinkPill(text, url, nil, nil, hostVC, tapTargets)];
        }
    }

    // Nothing rendered beyond the title (or not even that) — no empty section header.
    if (children.count == 0 || (title.length && children.count == 1)) return nil;

    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:8.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
    };
    return container;
}

#pragma mark - Registry-based multi-section injector

@interface ApolloSBSection : NSObject
@property (nonatomic) NSInteger order;
@property (nonatomic, strong) ASDisplayNode *node;
@property (nonatomic) UIEdgeInsets insets;
@property (nonatomic, copy) NSString *tocTitle; // nil => not shown in the table-of-contents
@end
@implementation ApolloSBSection
@end

static char kApolloSBSectionsKey;     // NSMutableArray<ApolloSBSection*> on scrollNode
static char kApolloSBWrappedKey;      // BOOL: layoutSpecBlock already wrapped
static char kApolloSBTapTargetsKey;   // NSMutableArray on the VC (retains tap targets)
static char kApolloSBInstalledKey;    // BOOL on the VC
static char kApolloSBRevealedKey;     // BOOL on the VC: content already faded in (hide-until-built, anti-flash)
static char kApolloSBCoverKey;        // strong UIView: opaque anti-flash cover faded out on reveal
static char kApolloSBCollapseHeaderKey; // BOOL on the header node
static char kApolloSBWidgetTitlesKey;   // NSSet<NSString*> (normalized) on the sidebar markdown node, for bio dedup
static char kApolloSBMarkdownBlocksKey; // NSMutableArray<@[node, attrText]> on a markdown node — blocks that rendered before titles were ready

// Apollo's original spec (collapsed stats header + description/bio markdown) is
// spliced into the section stack at this order — just under our stats (order 0),
// above the TOC (30) and all widget sections.
static const NSInteger kApolloSBOrigSpecOrder = 25;

static void ApolloSBInstallSection(ASDisplayNode *scrollNode, ApolloSBSection *section) {
    if (!scrollNode || !scrollNode.layoutSpecBlock || !section.node) return;

    NSMutableArray *sections = objc_getAssociatedObject(scrollNode, &kApolloSBSectionsKey);
    if (!sections) {
        sections = [NSMutableArray array];
        objc_setAssociatedObject(scrollNode, &kApolloSBSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [sections addObject:section];
    [sections sortUsingComparator:^NSComparisonResult(ApolloSBSection *a, ApolloSBSection *b) {
        return a.order < b.order ? NSOrderedAscending : (a.order > b.order ? NSOrderedDescending : NSOrderedSame);
    }];
    [scrollNode addSubnode:section.node];

    if (![objc_getAssociatedObject(scrollNode, &kApolloSBWrappedKey) boolValue]) {
        objc_setAssociatedObject(scrollNode, &kApolloSBWrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ASLayoutSpec *(^origBlock)(ASDisplayNode *, struct CDStruct_90e057aa) = scrollNode.layoutSpecBlock;
        __weak ASDisplayNode *weakScroll = scrollNode;
        scrollNode.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *node, struct CDStruct_90e057aa cs) {
            ASDisplayNode *strongScroll = weakScroll;
            NSMutableArray *children = [NSMutableArray array];
            ASLayoutSpec *origSpec = origBlock ? origBlock(node, cs) : nil; // Apollo's (collapsed) header + description/bio
            BOOL origInserted = NO;
            for (ApolloSBSection *s in (NSArray *)objc_getAssociatedObject(strongScroll, &kApolloSBSectionsKey)) {
                if (!s.node) continue;
                // The bio/description (origSpec) sits in the bio slot — under the stats + TOC.
                if (!origInserted && origSpec && s.order > kApolloSBOrigSpecOrder) {
                    [children addObject:origSpec];
                    origInserted = YES;
                }
                [children addObject:[ApolloSBInsetClass() insetLayoutSpecWithInsets:s.insets child:s.node]];
            }
            if (origSpec && !origInserted) [children addObject:origSpec];
            return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:0.0
                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:children];
        };
    }
    [scrollNode setNeedsLayout];
}

// Builds the table-of-contents chip row from the sections already registered on
// the scroll node (those with a tocTitle). Tapping a chip scroll-jumps to it.
static ASDisplayNode *ApolloSBBuildTOC(NSArray<ApolloSBSection *> *sections, ASDisplayNode *scrollNode, NSMutableArray *tapTargets) {
    NSMutableArray *chips = [NSMutableArray array];
    for (ApolloSBSection *s in sections) {
        if (s.tocTitle.length == 0 || !s.node) continue;
        ASButtonNode *chip = [[ApolloSBButtonClass() alloc] init];
        [chip setTitle:s.tocTitle withFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold] withColor:UIColor.labelColor forState:0];
        chip.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.18];
        chip.cornerRadius = 14.0;
        chip.contentEdgeInsets = UIEdgeInsetsMake(6.0, 13.0, 6.0, 13.0);

        ApolloSBTOCTapTarget *t = [[ApolloSBTOCTapTarget alloc] init];
        t.scrollNode = scrollNode;
        t.targetSection = s.node;
        [tapTargets addObject:t];
        [chip addTarget:t action:@selector(tocTapped:) forControlEvents:kApolloSBControlEventTouchUpInside];
        [chips addObject:chip];
    }
    if (chips.count < 2) return nil; // a single tab isn't worth a TOC

    ASTextNode *titleNode = [[ApolloSBTextClass() alloc] init];
    titleNode.attributedText = [[NSAttributedString alloc] initWithString:@"Jump to a Section" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.labelColor,
    }];

    ASDisplayNode *container = [[ApolloSBNodeClass() alloc] init];
    container.automaticallyManagesSubnodes = YES;
    container.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
        ASStackLayoutSpec *row = [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:8.0
                                                                    justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:chips];
        row.flexWrap = kApolloSBFlexWrapWrap;
        row.lineSpacing = 8.0;
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:10.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStretch children:@[titleNode, row]];
    };
    return container;
}

#pragma mark - Section ordering

typedef NS_ENUM(NSInteger, ApolloSBOrder) {
    ApolloSBOrderStats   = 0,
    ApolloSBOrderTOC     = 20,  // "Jump to a Section" sits above the bio
    ApolloSBOrderFlair   = 100,
    ApolloSBOrderDiscord = 145, // synthesized "Join our Discord" banner, just above Community Bookmarks
    ApolloSBOrderMenu    = 150,
    ApolloSBOrderContent = 200,
};

static void ApolloSBAddSection(UIViewController *vc, ASDisplayNode *scrollNode, ASDisplayNode *node, NSInteger order, NSString *tocTitle, UIEdgeInsets insets) {
    if (!node) return;
    ApolloSBSection *s = [[ApolloSBSection alloc] init];
    s.order = order;
    s.node = node;
    s.insets = insets;
    s.tocTitle = tocTitle;
    ApolloSBInstallSection(scrollNode, s);
}

#pragma mark - Sidebar VC hook

// Anti-flash: viewDidLoad lays an OPAQUE cover (themed sidebar background) over the
// content so Apollo's native layout never paints AND the view itself stays opaque —
// so the navigation push slides in a solid sidebar panel rather than a see-through
// one (which read as a glitchy transition). Once our sections are installed (or a
// safety timeout fires) we fade the cover out, revealing the composed layout.
// Idempotent — only the first call reveals.
static void ApolloSBRevealSidebar(UIViewController *vc) {
    if (!vc) return;
    if ([objc_getAssociatedObject(vc, &kApolloSBRevealedKey) boolValue]) return;
    objc_setAssociatedObject(vc, &kApolloSBRevealedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *v = vc.viewIfLoaded;
    if (v && v.alpha < 1.0) v.alpha = 1.0; // safety: undo any legacy whole-view hide
    UIView *cover = (UIView *)objc_getAssociatedObject(vc, &kApolloSBCoverKey);
    objc_setAssociatedObject(vc, &kApolloSBCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![cover isKindOfClass:[UIView class]] || !cover.superview) return; // never covered (e.g. early-return path)
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ cover.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { [cover removeFromSuperview]; }];
}

// Swaps the already-installed stats section's node in place (used when the async
// web stats land after the sidebar has rendered with the Created-date fallback).
static void ApolloSBReplaceStatsSection(ASDisplayNode *scrollNode, ASDisplayNode *newNode) {
    if (!scrollNode || !newNode) return;
    NSMutableArray *sections = objc_getAssociatedObject(scrollNode, &kApolloSBSectionsKey);
    for (ApolloSBSection *s in sections) {
        if (s.order != ApolloSBOrderStats) continue;
        ASDisplayNode *old = s.node;
        s.node = newNode;
        [scrollNode addSubnode:newNode];
        if (old) [old removeFromSupernode];
        [scrollNode setNeedsLayout];
        return;
    }
}

// Builds all sidebar sections. Called only once Apollo's nodes are ready (see
// ApolloSBTryBuild). vc/root/subredditName/tapTargets come from the VC hook.
static void ApolloSBBuildSidebarSections(UIViewController *vc, NSDictionary *root, NSString *subredditName, NSMutableArray *tapTargets) {
    ASDisplayNode *scrollNode = (ASDisplayNode *)ApolloSBReadObjectIvar(vc, "scrollNode");
    if (!scrollNode || !scrollNode.layoutSpecBlock) return;

    // Collapse Apollo's native 2-stat header — we render our own stats instead.
    id hn = ApolloSBReadObjectIvar(vc, "headerNode");
    if (hn) {
        objc_setAssociatedObject(hn, &kApolloSBCollapseHeaderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [(ASDisplayNode *)hn setNeedsLayout];
    }

    id rdkSub = ApolloSBReadObjectIvar(vc, "subreddit");
    ASDisplayNode *markdownNode = (ASDisplayNode *)ApolloSBReadObjectIvar(vc, "markdownNode");

    // Titles of widgets we render — used to strip duplicate sections from the bio.
    // "Rules" is always included (Apollo has a Rules button top-right).
    NSMutableSet<NSString *> *widgetTitles = [NSMutableSet set];
    ApolloSBAddTitle(widgetTitles, @"Rules");
    ApolloSBAddTitle(widgetTitles, @"Subreddit Rules");

    // ---- Collapsible bio: clip the description markdown to ~2 lines + "Show more". ----
    NSString *mdSource = markdownNode ? ApolloSBReadSwiftStringIvar(markdownNode, "source") : nil;
    if (mdSource.length == 0 && markdownNode) mdSource = ApolloSBReadSwiftStringIvar(markdownNode, "sourceHTML");

    // If the sub links Discord from its bio markdown, surface a "Join our Discord"
    // banner — unless an image widget already renders one (e.g. r/apple). Detected here
    // from the bio; discordImageShown is set in the image-widget loop below.
    NSString *discordURL = ApolloSBFindDiscordInvite(mdSource);
    BOOL discordImageShown = NO;
    if (markdownNode && mdSource.length > 250) {
        markdownNode.clipsToBounds = YES;
        markdownNode.style.maxHeight = ApolloSBPoints(kApolloSBBioCollapsedHeight);
        objc_setAssociatedObject(markdownNode, &kApolloSBBioExpandedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ASButtonNode *moreBtn = [[ApolloSBButtonClass() alloc] init];
        [moreBtn setTitle:@"Show more" withFont:[UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold] withColor:UIColor.secondaryLabelColor forState:0];
        ApolloSBBioToggleTarget *bt = [[ApolloSBBioToggleTarget alloc] init];
        bt.markdownNode = markdownNode; bt.scrollNode = scrollNode; bt.button = moreBtn;
        [tapTargets addObject:bt];
        [moreBtn addTarget:bt action:@selector(toggle:) forControlEvents:kApolloSBControlEventTouchUpInside];
        ASDisplayNode *moreContainer = [[ApolloSBNodeClass() alloc] init];
        moreContainer.automaticallyManagesSubnodes = YES;
        moreContainer.layoutSpecBlock = ^ASLayoutSpec *(ASDisplayNode *n, struct CDStruct_90e057aa cs) {
            return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackHorizontal spacing:0.0
                                                       justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:@[moreBtn]];
        };
        ApolloSBAddSection(vc, scrollNode, moreContainer, kApolloSBOrigSpecOrder + 1, nil, UIEdgeInsetsMake(8, 16, 0, 16));
    }

    NSDictionary *items = [root[@"items"] isKindOfClass:[NSDictionary class]] ? root[@"items"] : nil;
    NSDictionary *layout = [root[@"layout"] isKindOfClass:[NSDictionary class]] ? root[@"layout"] : nil;

    // ---- Stats: Subscribers (custom id-card label when present) + weekly Visitors/Contributions. ----
    NSString *idCardID = ApolloSBString(layout[@"idCardWidget"]);
    NSDictionary *idCard = [items[idCardID] isKindOfClass:[NSDictionary class]] ? items[idCardID] : nil;
    long long idCardSubs = idCard ? ApolloSBLongLong(idCard[@"subscribersCount"]) : -1;
    // Guard the dynamic send: if `subreddit` ever isn't an RDKSubreddit, an unguarded
    // -totalSubscribers would doesNotRecognizeSelector-crash the sidebar (per review).
    long long rdkSubs = -1;
    SEL totalSubsSel = sel_registerName("totalSubscribers");
    if ([rdkSub respondsToSelector:totalSubsSel])
        rdkSubs = (long long)((unsigned long long(*)(id, SEL))objc_msgSend)(rdkSub, totalSubsSel);
    long long subsCount = idCardSubs > 0 ? idCardSubs : MAX(rdkSubs, 0LL);
    NSString *subsLabel = ApolloSBString(idCard[@"subscribersText"]);
    if (subsLabel.length == 0) subsLabel = @"Subscribers";
    // Stats: Subscribers + weekly Visitors + Contributions. Visitors/Contributions
    // come from the desktop reddit.com page (scraped async — see ApolloSBFetchWebStats).
    // To avoid a layout switch, we render all 3 columns immediately with the
    // Visitors/Contributions VALUES blank (a height-reserving space) until the scrape
    // lands, then fill them in — the column count + spacing never change. A failed
    // scrape simply leaves the two values blank.
    NSString *subsLabelC = subsLabel; long long subsCountC = subsCount;
    ASDisplayNode *(^build3)(NSNumber *, NSNumber *) = ^ASDisplayNode *(NSNumber *v, NSNumber *c) {
        return ApolloSBBuildStatsSection(@[
            ApolloSBMakeStatColumn(subsLabelC, subsCountC > 0 ? ApolloSBFormatCount(subsCountC) : @"—"),
            ApolloSBMakeStatColumn(@"Visitors", v ? ApolloSBFormatCount(v.longLongValue) : @" "),
            ApolloSBMakeStatColumn(@"Contributions", c ? ApolloSBFormatCount(c.longLongValue) : @" "),
        ]);
    };

    __block ASDisplayNode *warmStatsNode = nil;  // set if the cache resolves synchronously
    __block BOOL statsInstalled = NO;
    __weak ASDisplayNode *weakScrollForStats = scrollNode;
    ApolloSBFetchWebStats(subredditName, ^(NSNumber *visitors, NSNumber *contributions) {
        if (!visitors && !contributions) return;            // failure → leave the blank placeholders
        ASDisplayNode *node3 = build3(visitors, contributions);
        if (statsInstalled) { ApolloSBReplaceStatsSection(weakScrollForStats, node3); } // fill in async
        else { warmStatsNode = node3; }                     // warm cache → install below
    });

    // Warm cache → real numbers now; cold → 3 columns with blank V/C placeholders.
    ASDisplayNode *statsNode = warmStatsNode ?: build3(nil, nil);
    ApolloSBAddSection(vc, scrollNode, statsNode, ApolloSBOrderStats, nil, UIEdgeInsetsMake(18, 16, 6, 16));
    statsInstalled = YES;

    // ---- Flair ("Search by Flair") ----
    for (NSString *wid in items) {
        NSDictionary *w = items[wid];
        if (![w[@"kind"] isEqual:@"post-flair"]) continue;
        NSArray *order = [w[@"order"] isKindOfClass:[NSArray class]] ? w[@"order"] : nil;
        NSDictionary *templates = [w[@"templates"] isKindOfClass:[NSDictionary class]] ? w[@"templates"] : nil;
        if (order.count == 0 || templates.count == 0) continue;
        ASDisplayNode *flair = ApolloSBBuildFlairSection(ApolloSBString(w[@"shortName"]), order, templates, subredditName, tapTargets);
        ApolloSBAddSection(vc, scrollNode, flair, ApolloSBOrderFlair, @"Flair", UIEdgeInsetsMake(20, 16, 0, 16));
        ApolloSBAddTitle(widgetTitles, ApolloSBString(w[@"shortName"]) ?: @"Search by Flair");
        break;
    }

    // ---- Menu / Community Bookmarks (topbar menu widget) ----
    NSArray *topbarOrder = [layout[@"topbar"] isKindOfClass:[NSDictionary class]] ? layout[@"topbar"][@"order"] : nil;
    NSString *menuID = [topbarOrder isKindOfClass:[NSArray class]] ? topbarOrder.firstObject : nil;
    NSDictionary *menuWidget = [items[menuID] isKindOfClass:[NSDictionary class]] ? items[menuID] : nil;
    if (!menuWidget) {
        for (NSString *wid in items) { if ([items[wid][@"kind"] isEqual:@"menu"]) { menuWidget = items[wid]; break; } }
    }
    if (menuWidget) {
        ASDisplayNode *menuSection = ApolloSBBuildMenuSection(@"Community Bookmarks", menuWidget, vc, scrollNode, tapTargets, widgetTitles);
        ApolloSBAddSection(vc, scrollNode, menuSection, ApolloSBOrderMenu, @"Bookmarks", UIEdgeInsetsMake(20, 16, 0, 16));
        ApolloSBAddTitle(widgetTitles, @"Community Bookmarks");
    }

    // ---- button + community-list widgets (sidebar.order first, then any leftovers). ----
    NSArray *sidebarOrder = [layout[@"sidebar"] isKindOfClass:[NSDictionary class]] ? layout[@"sidebar"][@"order"] : nil;
    NSMutableArray *iterIDs = [NSMutableArray array];
    if ([sidebarOrder isKindOfClass:[NSArray class]]) [iterIDs addObjectsFromArray:sidebarOrder];
    for (NSString *wid in items) if (![iterIDs containsObject:wid]) [iterIDs addObject:wid];
    NSInteger seqOrder = ApolloSBOrderContent;
    for (NSString *wid in iterIDs) {
        NSDictionary *w = [items[wid] isKindOfClass:[NSDictionary class]] ? items[wid] : nil;
        NSString *kind = ApolloSBString(w[@"kind"]);
        if ([kind isEqualToString:@"button"]) {
            NSArray *links = ApolloSBLinksFromButtonWidget(w);
            NSString *shortName = ApolloSBString(w[@"shortName"]);
            ASDisplayNode *section = ApolloSBBuildLinkGroupSection(shortName, links, vc, tapTargets);
            ApolloSBAddSection(vc, scrollNode, section, seqOrder++, shortName ?: @"Links", UIEdgeInsetsMake(20, 16, 0, 16));
            ApolloSBAddTitle(widgetTitles, shortName);
        } else if ([kind isEqualToString:@"community-list"]) {
            NSArray *data = [w[@"data"] isKindOfClass:[NSArray class]] ? w[@"data"] : nil;
            if (data.count == 0) continue;
            NSString *shortName = ApolloSBString(w[@"shortName"]) ?: @"Related Communities";
            ASDisplayNode *body = ApolloSBBuildCommunityListSection(shortName, data, vc, tapTargets);
            // Long lists start collapsed so the sidebar stays compact; tap to reveal.
            ASDisplayNode *section = ApolloSBMakeCollapsible(shortName, body, data.count > 5, scrollNode, tapTargets);
            ApolloSBAddSection(vc, scrollNode, section, seqOrder++, shortName, UIEdgeInsetsMake(20, 16, 0, 16));
            ApolloSBAddTitle(widgetTitles, shortName);
        } else if ([kind isEqualToString:@"image"]) {
            // Banner / "Join our Discord" image tiles — tap opens the linked URL.
            NSString *shortName = ApolloSBString(w[@"shortName"]);
            ASDisplayNode *section = ApolloSBBuildImageSection(w, vc, tapTargets);
            ApolloSBAddSection(vc, scrollNode, section, seqOrder++, shortName ?: @"Image", UIEdgeInsetsMake(20, 16, 0, 16));
            ApolloSBAddTitle(widgetTitles, shortName);
            // A mod-provided Discord image banner makes our synthesized one redundant.
            NSArray *idata = [w[@"data"] isKindOfClass:[NSArray class]] ? w[@"data"] : nil;
            NSDictionary *img = [idata.firstObject isKindOfClass:[NSDictionary class]] ? idata.firstObject : nil;
            if (ApolloSBFindDiscordInvite(ApolloSBString(img[@"linkUrl"]))) discordImageShown = YES;
        }
    }

    // ---- Synthesized "Join our Discord" banner (Discord linked from the bio, no
    // image banner). Full-width Discord-blurple cell that opens the invite. ----
    if (discordURL.length && !discordImageShown) {
        UIColor *blurple = [UIColor colorWithRed:0x58/255.0 green:0x65/255.0 blue:0xF2/255.0 alpha:1.0];
        ASButtonNode *discordBtn = ApolloSBMakeLinkPill(@"Join our Discord", discordURL, blurple, UIColor.whiteColor, vc, tapTargets);
        ApolloSBAddSection(vc, scrollNode, discordBtn, ApolloSBOrderDiscord, nil, UIEdgeInsetsMake(20, 16, 0, 16));
    }

    // Hand the rendered widget titles to the bio-dedup hook, then re-trim any bio
    // blocks that rendered before the titles were ready (re-setting the text
    // re-fires the setAttributedText hook, which now trims).
    if (markdownNode && widgetTitles.count) {
        objc_setAssociatedObject(markdownNode, &kApolloSBWidgetTitlesKey, widgetTitles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSMutableArray *blocks = objc_getAssociatedObject(markdownNode, &kApolloSBMarkdownBlocksKey);
        for (NSArray *b in [blocks copy]) {
            ASTextNode *node = b[0];
            NSAttributedString *orig = b[1];
            if ([node respondsToSelector:@selector(setAttributedText:)]) node.attributedText = orig;
        }
        [blocks removeAllObjects];
    }

    // ---- Table of contents (built last, from all registered sections). ----
    NSArray *allSections = objc_getAssociatedObject(scrollNode, &kApolloSBSectionsKey);
    ASDisplayNode *toc = ApolloSBBuildTOC(allSections, scrollNode, tapTargets);
    ApolloSBAddSection(vc, scrollNode, toc, ApolloSBOrderTOC, nil, UIEdgeInsetsMake(18, 16, 0, 16));
    ApolloLog(@"[Sidebar] r/%@ built (idCard=%d menu=%d toc=%d)", subredditName, idCard != nil, menuWidget != nil, toc != nil);

    // Reveal on the next runloop turn, after Texture has applied the section
    // relayout — so the fade shows the final composed layout, not a mid-reflow frame.
    __weak UIViewController *weakVC = vc;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloSBRevealSidebar(weakVC); });
}

// On a warm widget cache the fetch completion fires synchronously + early — before
// Apollo has created the scroll/header/markdown nodes. Retry on the main queue
// until they exist, then build once. (Plain recursion — no self-freeing block.)
static void ApolloSBTryBuild(UIViewController *vc, NSDictionary *root, NSString *subredditName, NSMutableArray *tapTargets, NSInteger attempt) {
    if (!vc) return;
    ASDisplayNode *scrollNode = (ASDisplayNode *)ApolloSBReadObjectIvar(vc, "scrollNode");
    id hn = ApolloSBReadObjectIvar(vc, "headerNode");
    id md = ApolloSBReadObjectIvar(vc, "markdownNode");
    if ((!scrollNode || !scrollNode.layoutSpecBlock || !hn || !md) && attempt < 15) {
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloSBTryBuild(weakVC, root, subredditName, tapTargets, attempt + 1);
        });
        return;
    }
    ApolloSBBuildSidebarSections(vc, root, subredditName, tapTargets);
}

%hook _TtC6Apollo30SubredditSidebarViewController

- (void)viewDidLoad {
    %orig;
    if ([objc_getAssociatedObject(self, &kApolloSBInstalledKey) boolValue]) return;
    objc_setAssociatedObject(self, &kApolloSBInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *subredditName = ApolloSBReadSwiftStringIvar(self, "subredditName");
    if (subredditName.length == 0) return;

    // Collapse Apollo's native 2-stat header — we render our own custom-labeled
    // stats as the first section instead. Flag the header node now (before it
    // lays out) so it returns a zero-size spec.
    id headerNode = ApolloSBReadObjectIvar(self, "headerNode");
    if (headerNode) {
        objc_setAssociatedObject(headerNode, &kApolloSBCollapseHeaderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [(ASDisplayNode *)headerNode setNeedsLayout];
    }

    NSMutableArray *tapTargets = [NSMutableArray array];
    objc_setAssociatedObject(self, &kApolloSBTapTargetsKey, tapTargets, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Anti-flash: lay an OPAQUE cover over the content until our sections are built, so
    // Apollo's native sidebar never paints under it. Unlike hiding the whole view
    // (alpha 0), the view itself stays opaque, so the navigation push slides in a solid
    // themed sidebar panel instead of a see-through one — then we fade the cover out at
    // the end of the build (a safety timeout guarantees the reveal even if it stalls).
    UIView *vcView = ((UIViewController *)self).view;
    UIColor *coverBG = vcView.backgroundColor;
    if (!coverBG || CGColorGetAlpha(coverBG.CGColor) < 0.99) coverBG = UIColor.systemBackgroundColor;
    UIView *cover = [[UIView alloc] initWithFrame:vcView.bounds];
    cover.backgroundColor = coverBG;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.userInteractionEnabled = NO;
    [vcView addSubview:cover];
    objc_setAssociatedObject(self, &kApolloSBCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakSelf = (UIViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSBRevealSidebar(weakSelf);
    });

    ApolloSBFetchWidgets(subredditName, ^(NSDictionary *root) {
        ApolloSBTryBuild(weakSelf, root, subredditName, tapTargets, 0);
    });
}

- (void)viewDidLayoutSubviews {
    %orig;
    // Keep the anti-flash cover full-bounds and on TOP of any content nodes Apollo
    // adds after viewDidLoad (so the native sidebar can't peek out before reveal).
    // Cheap, no layout feedback: bringSubviewToFront/frame don't re-trigger layout.
    if ([objc_getAssociatedObject(self, &kApolloSBRevealedKey) boolValue]) return;
    UIView *cover = (UIView *)objc_getAssociatedObject(self, &kApolloSBCoverKey);
    if (![cover isKindOfClass:[UIView class]] || !cover.superview) return;
    UIView *vcView = ((UIViewController *)self).view;
    cover.frame = vcView.bounds;
    [vcView bringSubviewToFront:cover];
    // If Apollo set the themed background after viewDidLoad, match it (opaque only).
    UIColor *bg = vcView.backgroundColor;
    if (bg && CGColorGetAlpha(bg.CGColor) > 0.99) cover.backgroundColor = bg;
}

%end

#pragma mark - Bio dedup (strip markdown sections already shown as widgets)

// Best-effort: removes markdown heading-sections whose title matches a widget we
// already render (Rules, Community Bookmarks, Key Links, the community lists, …),
// keeping unique sections. Heading runs are detected by their larger-than-body
// font size; a section spans a heading to the next heading. Untouched if nothing
// matches confidently.
static NSAttributedString *ApolloSBTrimDuplicateSections(NSAttributedString *attr, NSSet<NSString *> *titles) {
    if (attr.length == 0 || titles.count == 0) return attr;

    // 1. Body font size = the size covering the most characters.
    NSMutableDictionary<NSNumber *, NSNumber *> *sizeChars = [NSMutableDictionary dictionary];
    [attr enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, attr.length) options:0
                  usingBlock:^(UIFont *font, NSRange range, BOOL *stop) {
        if (![font isKindOfClass:[UIFont class]]) return;
        NSNumber *k = @(round(font.pointSize));
        sizeChars[k] = @([sizeChars[k] integerValue] + (NSInteger)range.length);
    }];
    CGFloat bodySize = 0; NSInteger bodyChars = -1;
    for (NSNumber *k in sizeChars) if ([sizeChars[k] integerValue] > bodyChars) { bodyChars = [sizeChars[k] integerValue]; bodySize = k.doubleValue; }
    if (bodySize <= 0) return attr;
    CGFloat headingThreshold = bodySize + 1.0;

    // 2. Heading runs (larger font), merging adjacent.
    NSMutableArray<NSValue *> *headings = [NSMutableArray array];
    [attr enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, attr.length) options:0
                  usingBlock:^(UIFont *font, NSRange range, BOOL *stop) {
        if (![font isKindOfClass:[UIFont class]] || font.pointSize < headingThreshold) return;
        if (headings.count) {
            NSRange last = [headings.lastObject rangeValue];
            if (NSMaxRange(last) == range.location) { headings[headings.count - 1] = [NSValue valueWithRange:NSUnionRange(last, range)]; return; }
        }
        [headings addObject:[NSValue valueWithRange:range]];
    }];
    if (headings.count == 0) return attr;

    // 3. Mark sections whose heading matches a rendered widget title.
    NSString *full = attr.string;
    NSMutableArray<NSValue *> *deletes = [NSMutableArray array];
    for (NSUInteger i = 0; i < headings.count; i++) {
        NSRange h = [headings[i] rangeValue];
        if (![titles containsObject:ApolloSBNormTitle([full substringWithRange:h])]) continue;
        NSUInteger end = (i + 1 < headings.count) ? [headings[i + 1] rangeValue].location : attr.length;
        [deletes addObject:[NSValue valueWithRange:NSMakeRange(h.location, end - h.location)]];
    }
    if (deletes.count == 0) return attr;

    // 4. Delete back-to-front, trim leading whitespace.
    NSMutableAttributedString *result = [attr mutableCopy];
    for (NSInteger i = (NSInteger)deletes.count - 1; i >= 0; i--) {
        NSRange r = [deletes[i] rangeValue];
        if (NSMaxRange(r) <= result.length) [result deleteCharactersInRange:r];
    }
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (result.length && [ws characterIsMember:[result.string characterAtIndex:0]]) [result deleteCharactersInRange:NSMakeRange(0, 1)];
    return result;
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    Class mdc = objc_getClass("_TtC6Apollo12MarkdownNode");
    if (mdc && [(id)self respondsToSelector:@selector(delegate)]) {
        id del = ((id (*)(id, SEL))objc_msgSend)((id)self, @selector(delegate));
        if ([del isKindOfClass:mdc]) {
            NSSet *titles = objc_getAssociatedObject(del, &kApolloSBWidgetTitlesKey);
            if (titles.count) { %orig(ApolloSBTrimDuplicateSections(attributedText, titles)); return; }
            // Titles aren't stored yet — the bio renders before the async /api/widgets
            // fetch lands. Remember long blocks (descriptions, not short comments) so
            // the build can re-trim them once it knows which widgets exist.
            if (attributedText.length > 150) {
                NSMutableArray *blocks = objc_getAssociatedObject(del, &kApolloSBMarkdownBlocksKey);
                if (!blocks) { blocks = [NSMutableArray array]; objc_setAssociatedObject(del, &kApolloSBMarkdownBlocksKey, blocks, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
                [blocks addObject:@[(id)self, attributedText]];
            }
        }
    }
    %orig;
}

%end

#pragma mark - Collapse native stats header

%hook _TtC6Apollo26SubredditSidebarHeaderNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    if ([objc_getAssociatedObject(self, &kApolloSBCollapseHeaderKey) boolValue]) {
        return [ApolloSBStackClass() stackLayoutSpecWithDirection:ApolloSBStackVertical spacing:0.0
                                                   justifyContent:ApolloSBJustifyStart alignItems:ApolloSBAlignStart children:@[]];
    }
    return %orig;
}

%end
