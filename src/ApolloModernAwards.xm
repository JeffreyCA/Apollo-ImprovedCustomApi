#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloWebSessionStore.h"

// Reddit retired both pieces that Apollo's original award screen used: the
// Apollo-hosted catalog and Reddit's coin-era /api/v2/gold/gild API. Reddit's
// replacement is implemented on its first-party web stack. Its item-scoped
// route owns the live catalog, free-award entitlements, current gold prices,
// eligibility checks, anonymous/message controls, purchase flow, leaderboard,
// and the official award animations.
//
// Embedding that route is deliberately preferable to copying a private GraphQL
// schema or periodically snapshotting its catalog. Apollo therefore submits
// through Reddit's current implementation and follows future catalog, price,
// and animation changes without another tweak release.

static const void *kApolloModernAwardControllerKey = &kApolloModernAwardControllerKey;
static const void *kApolloModernAwardNavigationBarKey = &kApolloModernAwardNavigationBarKey;

static NSString *ApolloModernAwardFullName(id thing) {
    if (!thing || ![thing respondsToSelector:@selector(fullName)]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(thing, @selector(fullName));
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *fullName = [(NSString *)value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL supportedPrefix = [fullName hasPrefix:@"t1_"] || [fullName hasPrefix:@"t3_"];
    if (!supportedPrefix || fullName.length <= 3) return nil;
    NSCharacterSet *invalid = [NSCharacterSet.alphanumericCharacterSet invertedSet];
    return [[fullName substringFromIndex:3] rangeOfCharacterFromSet:invalid].location == NSNotFound ?
        fullName : nil;
}

static NSURL *ApolloModernAwardPermalink(id thing) {
    id value = nil;
    if ([thing respondsToSelector:@selector(permalink)]) {
        value = ((id (*)(id, SEL))objc_msgSend)(thing, @selector(permalink));
    } else if ([thing respondsToSelector:@selector(urlWithContext:)]) {
        value = ((id (*)(id, SEL, long long))objc_msgSend)(
            thing, @selector(urlWithContext:), 0);
    }

    NSURL *URL = [value isKindOfClass:[NSURL class]] ? value : nil;
    if (URL && URL.host.length == 0 && [URL.relativeString hasPrefix:@"/"]) {
        URL = [[NSURL URLWithString:URL.relativeString
                     relativeToURL:[NSURL URLWithString:@"https://www.reddit.com"]]
            absoluteURL];
    }
    if (!URL && [value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        URL = [string hasPrefix:@"/"] ?
            [NSURL URLWithString:string relativeToURL:[NSURL URLWithString:@"https://www.reddit.com"]] :
            [NSURL URLWithString:string];
        URL = URL.absoluteURL;
    }
    NSString *host = URL.host.lowercaseString;
    BOOL Reddit = [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"];
    return ([URL.scheme.lowercaseString isEqualToString:@"https"] && Reddit) ? URL : nil;
}

static NSArray<NSHTTPCookie *> *ApolloModernAwardCookiesFromHeader(NSString *header) {
    NSMutableArray<NSHTTPCookie *> *cookies = [NSMutableArray array];
    for (NSString *rawPair in [header componentsSeparatedByString:@";"]) {
        NSString *pair = [rawPair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange separator = [pair rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0) continue;
        NSString *name = [pair substringToIndex:separator.location];
        NSString *value = [pair substringFromIndex:separator.location + 1];
        if (name.length == 0) continue;
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookieDomain: @".reddit.com",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
        }];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

static NSString *ApolloModernAwardBridgeScript(void) {
    // Only operation names and UI lifecycle signals cross this bridge. Cookies,
    // request bodies, messages, and award choices remain entirely in Reddit.
    return @"(function(){"
        "if(window.__apolloModernAwardsInstalled)return;"
        "window.__apolloModernAwardsInstalled=true;"
        "var send=function(type,extra){try{window.webkit.messageHandlers.apolloModernAwards.postMessage(Object.assign({type:type},extra||{}));}catch(_){}};"
        "var operation=function(input,init){"
            "var url=String((input&&input.url)||input||'');"
            "var body=String((init&&init.body)||'');"
            "return /CreateAwardOrder|createAwardOrder/.test(url+' '+body);"
        "};"
        "var originalFetch=window.fetch;"
        "if(originalFetch){window.fetch=function(input,init){"
            "var isAward=operation(input,init),promise=originalFetch.apply(this,arguments);"
            "if(isAward){promise.then(function(response){"
                "if(response&&response.ok)send('awarded');"
                "else send('awardError',{status:(response&&response.status)||0});"
            "}).catch(function(error){send('awardError',{message:String(error||'Request failed')});});}"
            "return promise;"
        "};}"
        "document.addEventListener('click',function(event){"
            "var target=event.target;"
            "var path=event.composedPath?event.composedPath():[target];"
            "var showAll=path.find(function(node){return node.matches&&node.matches('award-selection-sheet button:not([data-award-id])');});"
            "if(showAll&&location.pathname.indexOf('/svc/shreddit/award-dialog/')===0){"
                "event.preventDefault();event.stopImmediatePropagation();"
                "send('showAll');return;"
            "}"
            "if(target&&target.closest&&target.closest('button[aria-label=\"Close\"]'))send('close');"
        "},true);"
        "document.addEventListener('award_content',function(){send('awarded');},true);"
        "document.addEventListener('award-content',function(){send('awarded');},true);"
        "var announced=false,signedOut=false;"
        "var inspect=function(){"
            "var dialog=document.querySelector('#award-dialog,[dialog-id=\"award-dialog\"],[role=\"dialog\"]');"
            "if(dialog&&!announced){announced=true;send('ready');}"
            "var text=(document.body&&document.body.innerText)||'';"
            "if(!signedOut&&/Already a redditor\\?|Log In to continue/i.test(text)){signedOut=true;send('signedOut');}"
        "};"
        "new MutationObserver(inspect).observe(document.documentElement,{childList:true,subtree:true});"
        "document.addEventListener('DOMContentLoaded',inspect);"
        "setTimeout(inspect,0);"
    "})();";
}

static NSString *ApolloModernAwardOpenFullPickerScript(NSString *fullName) {
    // Reddit's overflow component owns the supported transition into the full
    // selection sheet. Invoking that component keeps the catalog, eligibility,
    // balance, messaging, purchase flow, and animations entirely first-party.
    return [NSString stringWithFormat:@"(function(){"
        "if(window.__apolloModernAwardsOpeningFull)return;"
        "window.__apolloModernAwardsOpeningFull=true;"
        "var fullName='%@',started=false,ticks=0,targetFound=false,scrolled=false,controlFound=false,"
            "loaderFound=false,loaderRequested=false,loaderFailed=false,targetTag='',targetTags='',loaderNames='',"
            "routeFound=false,routeStarted=false,routeFailed=false;"
        "var exactTarget=function(){"
            "var roots='shreddit-post,shreddit-comment,article,[data-testid=\\\"post-container\\\"]';"
            "var direct=[document.getElementById(fullName),document.getElementById(fullName.substring(3))];"
            "var escaped=CSS.escape(fullName);"
            "var selectors=['[thingid=\\\"'+escaped+'\\\"]','[thing-id=\\\"'+escaped+'\\\"]','[data-fullname=\\\"'+escaped+'\\\"]','[data-thing-id=\\\"'+escaped+'\\\"]'];"
            "for(var index=0;index<selectors.length;index++){try{direct.push(document.querySelector(selectors[index]));}catch(_){}}"
            "for(var candidate of direct){if(candidate){var root=candidate.matches(roots)?candidate:candidate.closest(roots);if(root)return root;}}"
            "return null;"
        "};"
        "var timer=setInterval(function(){"
            "ticks++;"
            "var full=document.querySelector('award-dialog[page=\\\"selection-sheet\\\"] award-selection-sheet');"
            "if(full){clearInterval(timer);window.webkit.messageHandlers.apolloModernAwards.postMessage({type:'fullReady'});return;}"
            "if(!started){"
                "var target=exactTarget();"
                "targetFound=targetFound||!!target;"
                "if(target&&!targetTag){"
                    "targetTag=target.tagName||'';"
                    "targetTags=Array.from(new Set(Array.from(target.querySelectorAll('*')).map(function(node){"
                        "return (node.tagName||'').toLowerCase();"
                    "}).filter(function(tag){return /award|comment|faceplate|overflow/.test(tag);}))).slice(0,24).join(',');"
                "}"
                "if(target&&(!scrolled||ticks%%10===0)){"
                    "scrolled=true;"
                    "try{target.scrollIntoView({block:'center',inline:'nearest'});}catch(_){target.scrollIntoView();}"
                "}"
                // Both post and comment controls eventually call Reddit's
                // programmatic AwardDialog faceplate route. Activate that same
                // first-party route directly when present. This avoids relying
                // on a private controller property that Reddit removed from the
                // current full comment action row.
                "var routeParts=Array.from(document.querySelectorAll('faceplate-partial,faceplate-iframe'));"
                "var awardRoute=routeParts.find(function(node){"
                    "return /awarddialog|award-dialog/i.test((node.getAttribute('name')||'')+' '+(node.getAttribute('src')||''));"
                "});"
                "routeFound=routeFound||!!awardRoute;"
                "if(awardRoute&&typeof awardRoute.load==='function'){"
                    "var routeName=awardRoute.getAttribute('name')||'';"
                    "var routeLoader=Array.from(document.querySelectorAll('faceplate-loader')).find(function(loader){"
                        "return loader.getAttribute('name')===routeName;"
                    "});"
                    "if(!routeLoader||typeof routeLoader.load==='function'){"
                        "started=true;routeStarted=true;"
                        "try{"
                            "var routeURL=new URL(String(awardRoute.src||awardRoute.getAttribute('src')||''),location.origin);"
                            "routeURL.pathname=routeURL.pathname.replace(/(?:%%3A|:)thingId/i,fullName);"
                            "routeURL.searchParams.set('skipQuickGivePopover','true');"
                            "if(routeLoader)routeLoader.loading='programmatic';"
                            "awardRoute.loading='programmatic';"
                            "if('renderMode' in awardRoute)awardRoute.renderMode='contents';"
                            "awardRoute.src=routeURL.pathname+routeURL.search;"
                            "var routeLoads=[];"
                            "if(routeLoader)routeLoads.push(routeLoader.load());"
                            "routeLoads.push(awardRoute.load());"
                            "Promise.allSettled(routeLoads).then(function(results){"
                                "if(results.some(function(result){return result.status==='rejected';}))routeFailed=true;"
                            "});"
                        "}catch(_){started=false;routeFailed=true;}"
                    "}"
                "}"
                // Comment actions are wrapped in a lazy faceplate-loader. The
                // target permalink can sit several screens below a long post,
                // and a hidden WKWebView does not reliably trip its observer.
                // Reddit no longer gives this loader a stable name, so hydrate
                // only loaders physically contained by the exact t1 target.
                "if(!started&&target&&!loaderRequested){"
                    "var loaders=Array.from(target.querySelectorAll('faceplate-loader')).filter(function(loader){"
                        "return loader.closest('shreddit-comment')===target;"
                    "});"
                    "loaderFound=loaderFound||loaders.length>0;"
                    "loaderNames=loaders.map(function(loader){return loader.getAttribute('name')||'(unnamed)';}).join(',');"
                    "for(var loader of loaders){"
                        "if(typeof loader.load!=='function')continue;"
                        "loaderRequested=true;"
                        "try{"
                            "loader.loading='programmatic';"
                            "var loading=loader.load();"
                            "if(loading&&typeof loading.catch==='function')loading.catch(function(){loaderFailed=true;});"
                        "}catch(_){loaderFailed=true;}"
                    "}"
                "}"
                "var nodes=[];"
                "var collect=function(root){"
                    "if(!root||nodes.indexOf(root)!==-1)return;"
                    "nodes.push(root);"
                    "var children=root.querySelectorAll?Array.from(root.querySelectorAll('*')):[];"
                    "for(var child of children){"
                        "if(nodes.indexOf(child)===-1)nodes.push(child);"
                        "if(child.shadowRoot)collect(child.shadowRoot);"
                    "}"
                "};"
                "collect(target);"
                "var overflow=nodes.find(function(node){return typeof node.clickAwardButton==='function';});"
                "var hasController=function(node){"
                    "return !!node.awardController&&typeof node.awardController.activateDialog==='function';"
                "};"
                "var controllerMatches=function(node){"
                    "if(!hasController(node))return false;"
                    "var id='';"
                    "try{id=String(node.commentId||node.thingId||(node.getAttribute&&"
                        "(node.getAttribute('comment-id')||node.getAttribute('thing-id')||node.getAttribute('thingid')))||'');}catch(_){}"
                    "return id===fullName||id===fullName.substring(3);"
                "};"
                // A controller inside the exact target already has an
                // unambiguous owner even if Reddit does not expose its ID.
                "var commentControl=nodes.find(hasController);"
                // Reddit may portal the hydrated comment action component away
                // from its shreddit-comment. Search all light/shadow DOM only
                // for a controller whose own ID exactly matches our comment.
                "if(!commentControl&&fullName.indexOf('t1_')===0&&ticks%%5===0){"
                    "collect(document);"
                    "commentControl=nodes.find(controllerMatches);"
                "}"
                "controlFound=controlFound||!!overflow||!!commentControl;"
                "if(!started&&(overflow||commentControl)){"
                    "started=true;"
                    "try{"
                        "if(overflow)overflow.clickAwardButton({skipQuickGivePopover:true});"
                        "else commentControl.awardController.activateDialog({skipQuickGivePopover:true});"
                    "}"
                    "catch(_){clearInterval(timer);window.webkit.messageHandlers.apolloModernAwards.postMessage({type:'fullError'});return;}"
                "}"
            "}"
            "if(ticks>=150){"
                "clearInterval(timer);"
                "window.webkit.messageHandlers.apolloModernAwards.postMessage({"
                    "type:'fullError',targetFound:targetFound,scrolled:scrolled,controlFound:controlFound,"
                    "loaderFound:loaderFound,loaderRequested:loaderRequested,loaderFailed:loaderFailed,loaderNames:loaderNames,"
                    "targetTag:targetTag,targetTags:targetTags,routeFound:routeFound,routeStarted:routeStarted,routeFailed:routeFailed"
                "});"
            "}"
        "},200);"
    "})();", fullName];
}
static NSString *ApolloModernAwardAppearanceScript(void) {
    // The endpoint is a complete page whose only meaningful content is its
    // sheet. Remove desktop page padding so it fills Apollo's presentation.
    return @"(function(){"
        "var style=document.getElementById('apollo-modern-awards-style');"
        "if(!style){"
            "style=document.createElement('style');"
            "style.id='apollo-modern-awards-style';"
            "style.textContent='#shreddit-skip-link{display:none!important}'"
                "+'html,body,shreddit-app{margin:0!important;padding:0!important;min-height:100%!important;background:transparent!important}'"
                "+'rpl-dialog-sheet{--viewport-height:100dvh!important}';"
            "(document.head||document.documentElement).appendChild(style);"
        "}"
        "document.documentElement.style.colorScheme='light dark';"
    "})();";
}

@interface ApolloModernAwardErrorView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) UIButton *closeButton;
@end

@implementation ApolloModernAwardErrorView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = UIColor.systemBackgroundColor;

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 0;

        _detailLabel = [UILabel new];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.textAlignment = NSTextAlignmentCenter;
        _detailLabel.numberOfLines = 0;

        _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _retryButton.translatesAutoresizingMaskIntoConstraints = NO;
        _retryButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        [_retryButton setTitle:@"Try Again" forState:UIControlStateNormal];
        _retryButton.tintColor = ApolloThemeAccentColor() ?: self.tintColor ?: UIColor.systemBlueColor;
        _retryButton.contentEdgeInsets = UIEdgeInsetsMake(12.0, 22.0, 12.0, 22.0);
        _retryButton.layer.cornerRadius = 12.0;
        _retryButton.backgroundColor = [_retryButton.tintColor colorWithAlphaComponent:0.12];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        _closeButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [_closeButton setTitle:@"Close" forState:UIControlStateNormal];

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
            @[_titleLabel, _detailLabel, _retryButton, _closeButton]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 14.0;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:28.0],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-28.0],
            [_detailLabel.widthAnchor constraintLessThanOrEqualToConstant:430.0],
        ]];
    }
    return self;
}

@end

@interface ApolloModernAwardWebController : UIViewController
    <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property (nonatomic, weak) UIViewController *hostController;
@property (nonatomic, copy) NSString *thingFullName;
@property (nonatomic, strong) NSURL *thingPermalink;
@property (nonatomic, strong) ApolloWebSessionEntry *session;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *loadingView;
@property (nonatomic, strong) ApolloModernAwardErrorView *errorView;
@property (nonatomic) BOOL receivedReady;
@property (nonatomic) BOOL receivedAward;
@property (nonatomic) BOOL showingFullPicker;
@property (nonatomic) NSUInteger loadGeneration;
- (instancetype)initWithThingFullName:(NSString *)fullName
                            permalink:(NSURL *)permalink
                                  host:(UIViewController *)host;
@end

@implementation ApolloModernAwardWebController

- (instancetype)initWithThingFullName:(NSString *)fullName
                            permalink:(NSURL *)permalink
                                  host:(UIViewController *)host {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _thingFullName = [fullName copy];
        _thingPermalink = permalink;
        _hostController = host;
        _session = ApolloActiveWebSession();
    }
    return self;
}

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildLoadingView];
    if (self.session.cookieHeader.length == 0) {
        [self showErrorTitle:@"API-Key-Free sign-in required"
                      detail:@"Reddit only allows its new awards through a first-party web session. Sign in with Apollo Reborn's API-Key-Free option for this account, then try again."];
        ApolloLog(@"[ModernAwards] blocked %@: active account has no web session", self.thingFullName);
        return;
    }
    [self buildWebViewAndLoad];
}

- (void)buildLoadingView {
    UIActivityIndicatorViewStyle style = UIActivityIndicatorViewStyleWhiteLarge;
    if (@available(iOS 13.0, *)) style = UIActivityIndicatorViewStyleLarge;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:style];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = UIColor.secondaryLabelColor;
    [self.spinner startAnimating];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"Loading Reddit awards...";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = UIColor.secondaryLabelColor;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.spinner, label]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    self.loadingView = stack;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

- (void)discardWebView {
    self.webView.navigationDelegate = nil;
    self.webView.UIDelegate = nil;
    [self.webView stopLoading];
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"apolloModernAwards"];
    [self.webView removeFromSuperview];
    self.webView = nil;
}

- (void)buildWebViewAndLoad {
    [self discardWebView];
    NSUInteger generation = ++self.loadGeneration;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // Isolate this account from other API-free users and any unrelated login
    // left in WebKit's shared website data store.
    configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    WKUserContentController *content = [WKUserContentController new];
    [content addScriptMessageHandler:self name:@"apolloModernAwards"];
    [content addUserScript:[[WKUserScript alloc]
        initWithSource:ApolloModernAwardBridgeScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:NO]];
    configuration.userContentController = content;

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = UIColor.clearColor;
    self.webView.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.webView.customUserAgent =
        @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
         "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    self.webView.alpha = 0.0;
    [self.view insertSubview:self.webView atIndex:0];

    NSArray<NSHTTPCookie *> *cookies =
        ApolloModernAwardCookiesFromHeader(self.session.cookieHeader);
    if (cookies.count == 0) {
        [self showErrorTitle:@"Reddit session unavailable"
                      detail:@"Apollo could not prepare this account's Reddit web session. Re-sign in with API-Key-Free and try again."];
        return;
    }

    NSURL *URL = self.thingPermalink;
    if (URL) {
        // A full-screen Apollo controller should open Reddit's complete picker,
        // not its tiny feed popover. The post/comment page owns the supported
        // transition into that picker and retains the success animation.
        self.showingFullPicker = YES;
        self.webView.customUserAgent =
            @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";
    } else {
        NSString *escaped = [self.thingFullName
            stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        URL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://www.reddit.com/svc/shreddit/award-dialog/%@", escaped]];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:35.0];
    [request setValue:self.session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:@"https://www.reddit.com/" forHTTPHeaderField:@"Referer"];

    dispatch_group_t group = dispatch_group_create();
    WKHTTPCookieStore *store = configuration.websiteDataStore.httpCookieStore;
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(group);
        [store setCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || !self.webView) return;
        ApolloLog(@"[ModernAwards] loading %@ award flow for %@ with %lu cookies",
                  self.showingFullPicker ? @"full" : @"compact fallback",
                  self.thingFullName, (unsigned long)cookies.count);
        [self.webView loadRequest:request];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || generation != self.loadGeneration || self.receivedReady ||
            !self.webView) return;
        ApolloLog(@"[ModernAwards] dialog readiness timed out for %@", self.thingFullName);
        [self showErrorTitle:@"Reddit awards did not finish loading"
                      detail:@"Check your connection and retry."];
    });
}

- (void)showErrorTitle:(NSString *)title detail:(NSString *)detail {
    [self.spinner stopAnimating];
    self.loadingView.hidden = YES;
    if (!self.errorView) {
        self.errorView = [[ApolloModernAwardErrorView alloc] initWithFrame:self.view.bounds];
        [self.errorView.retryButton addTarget:self
                                       action:@selector(retryTapped)
                             forControlEvents:UIControlEventTouchUpInside];
        [self.errorView.closeButton addTarget:self
                                       action:@selector(dismissHost)
                             forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.errorView];
    }
    self.errorView.titleLabel.text = title;
    self.errorView.detailLabel.text = detail;
    self.errorView.hidden = NO;
    [self.view bringSubviewToFront:self.errorView];
}

- (void)retryTapped {
    self.session = ApolloActiveWebSession();
    self.errorView.hidden = YES;
    self.loadingView.hidden = NO;
    [self.spinner startAnimating];
    self.receivedReady = NO;
    self.receivedAward = NO;
    self.showingFullPicker = NO;
    if (self.session.cookieHeader.length == 0) {
        [self showErrorTitle:@"API-Key-Free sign-in required"
                      detail:@"Sign in with Apollo Reborn's API-Key-Free option for this account, then return here and try again."];
        return;
    }
    [self buildWebViewAndLoad];
}

- (void)loadFullPicker {
    if (self.showingFullPicker) return;
    if (!self.thingPermalink) {
        ApolloLog(@"[ModernAwards] no Reddit permalink for %@", self.thingFullName);
        [self showErrorTitle:@"Couldn't open all awards"
                      detail:@"Reddit did not provide a usable link for this item. The free awards remain available from the first screen."];
        return;
    }

    self.showingFullPicker = YES;
    NSUInteger generation = ++self.loadGeneration;
    self.receivedReady = NO;
    self.webView.alpha = 0.0;
    self.webView.customUserAgent =
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
         "(KHTML, like Gecko) Version/18.0 Safari/605.1.15";
    self.loadingView.hidden = NO;
    [self.spinner startAnimating];
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:self.thingPermalink
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:35.0];
    [request setValue:self.session.cookieHeader forHTTPHeaderField:@"Cookie"];
    [request setValue:@"https://www.reddit.com/" forHTTPHeaderField:@"Referer"];
    ApolloLog(@"[ModernAwards] opening full Reddit picker for %@ path=%@",
              self.thingFullName, self.thingPermalink.path ?: @"unknown");
    [self.webView loadRequest:request];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || generation != self.loadGeneration || !self.showingFullPicker ||
            self.receivedReady || !self.webView) return;
        [self showErrorTitle:@"Reddit's full award picker did not open"
                      detail:@"Tap Try Again to reload the award flow."];
    });
}

- (void)revealWebView {
    if (self.receivedReady) return;
    self.receivedReady = YES;
    [self.spinner stopAnimating];
    self.loadingView.hidden = YES;
    self.errorView.hidden = YES;
    [UIView animateWithDuration:0.18 animations:^{ self.webView.alpha = 1.0; }];
    ApolloLog(@"[ModernAwards] dialog ready for %@", self.thingFullName);
}

- (void)dismissHost {
    UIViewController *host = self.hostController;
    if (!host) return;
    if ([host respondsToSelector:@selector(cancelBarButtonItemTappedWithSender:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            host, @selector(cancelBarButtonItemTappedWithSender:), nil);
    } else if (host.navigationController.presentingViewController) {
        [host.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [host dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"apolloModernAwards"] ||
        ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *payload = (NSDictionary *)message.body;
    NSString *type = [payload[@"type"] isKindOfClass:[NSString class]] ?
        payload[@"type"] : @"";

    if ([type isEqualToString:@"ready"]) {
        if (!self.showingFullPicker) [self revealWebView];
    } else if ([type isEqualToString:@"showAll"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self loadFullPicker]; });
    } else if ([type isEqualToString:@"fullReady"]) {
        ApolloLog(@"[ModernAwards] full picker ready for %@", self.thingFullName);
        [self revealWebView];
    } else if ([type isEqualToString:@"fullError"]) {
        ApolloLog(@"[ModernAwards] full picker unavailable for %@ target=%@ tag=%@ children=%@ scrolled=%@ route=%@ started=%@ routeFailed=%@ control=%@ loader=%@ names=%@ requested=%@ failed=%@",
                  self.thingFullName,
                  payload[@"targetFound"] ?: @NO,
                  payload[@"targetTag"] ?: @"unknown",
                  payload[@"targetTags"] ?: @"unknown",
                  payload[@"scrolled"] ?: @NO,
                  payload[@"routeFound"] ?: @NO,
                  payload[@"routeStarted"] ?: @NO,
                  payload[@"routeFailed"] ?: @NO,
                  payload[@"controlFound"] ?: @NO,
                  payload[@"loaderFound"] ?: @NO,
                  payload[@"loaderNames"] ?: @"unknown",
                  payload[@"loaderRequested"] ?: @NO,
                  payload[@"loaderFailed"] ?: @NO);
        [self showErrorTitle:@"Couldn't open all Reddit awards"
                      detail:@"Reddit's page loaded, but its award control was unavailable. Tap Try Again to reload the flow."];
    } else if ([type isEqualToString:@"close"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dismissHost]; });
    } else if ([type isEqualToString:@"signedOut"]) {
        ApolloLog(@"[ModernAwards] Reddit rejected stored session for %@", self.thingFullName);
        [self showErrorTitle:@"Reddit session expired"
                      detail:@"Re-sign in to this account with Apollo Reborn's API-Key-Free option, then try again."];
    } else if ([type isEqualToString:@"awarded"]) {
        if (self.receivedAward) return;
        self.receivedAward = YES;
        ApolloLog(@"[ModernAwards] Reddit accepted award for %@", self.thingFullName);
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ApolloModernAwardGrantedNotification"
            object:nil
            userInfo:@{@"thingFullName": self.thingFullName ?: @""}];
        // Keep the web surface alive for Reddit's own success animation. Its
        // close control dismisses the Apollo wrapper through the bridge above.
    } else if ([type isEqualToString:@"awardError"]) {
        ApolloLog(@"[ModernAwards] Reddit award request failed for %@ status=%@",
                  self.thingFullName, payload[@"status"] ?: @"unknown");
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    ApolloLog(@"[ModernAwards] main page finished host=%@", webView.URL.host ?: @"unknown");
    if (self.showingFullPicker) {
        [webView evaluateJavaScript:ApolloModernAwardOpenFullPickerScript(self.thingFullName)
                  completionHandler:^(id result, NSError *error) {
            if (error) ApolloLog(@"[ModernAwards] full picker bootstrap failed: %@",
                                 error.localizedDescription);
        }];
    } else {
        [webView evaluateJavaScript:ApolloModernAwardAppearanceScript() completionHandler:nil];
        [self revealWebView];
    }
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[ModernAwards] provisional navigation failed for %@: %@",
              self.thingFullName, error.localizedDescription);
    [self showErrorTitle:@"Couldn't load Reddit awards"
                  detail:error.localizedDescription ?: @"Check your connection and try again."];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
             withError:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    ApolloLog(@"[ModernAwards] navigation failed for %@: %@",
              self.thingFullName, error.localizedDescription);
    [self showErrorTitle:@"Couldn't load Reddit awards"
                  detail:error.localizedDescription ?: @"Check your connection and try again."];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    ApolloLog(@"[ModernAwards] web process terminated for %@", self.thingFullName);
    [self showErrorTitle:@"Reddit awards stopped responding"
                  detail:@"Tap Try Again to reload the award picker."];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *URL = navigationAction.request.URL;
    if (!URL || [URL.scheme isEqualToString:@"about"] ||
        [URL.scheme isEqualToString:@"data"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    NSString *host = URL.host.lowercaseString;
    BOOL redditHost =
        [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"] ||
        [host isEqualToString:@"redditstatic.com"] || [host hasSuffix:@".redditstatic.com"];
    BOOL HTTPS = [URL.scheme.lowercaseString isEqualToString:@"https"];
    BOOL mainFrame = !navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame;
    // Reddit's live picker embeds reCAPTCHA and payment resources. Keep HTTPS
    // subframes inside Reddit's page while still restricting the top frame.
    if (HTTPS && (redditHost || !mainFrame)) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    decisionHandler(WKNavigationActionPolicyCancel);
    if (HTTPS && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloPresentWebURLFromViewController(self, URL);
    }
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    NSURL *URL = navigationAction.request.URL;
    NSString *host = URL.host.lowercaseString;
    BOOL redditHost =
        [host isEqualToString:@"reddit.com"] || [host hasSuffix:@".reddit.com"] ||
        [host isEqualToString:@"redditstatic.com"] || [host hasSuffix:@".redditstatic.com"];
    BOOL HTTPS = [URL.scheme.lowercaseString isEqualToString:@"https"];
    if (HTTPS && redditHost) {
        [webView loadRequest:navigationAction.request];
    } else if (HTTPS && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        ApolloPresentWebURLFromViewController(self, URL);
    }
    return nil;
}

- (void)dealloc {
    [self discardWebView];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    UIViewController *host = self.hostController;
    BOOL leaving = host.isBeingDismissed || host.isMovingFromParentViewController ||
        host.navigationController.isBeingDismissed;
    if (leaving) [self discardWebView];
}

@end

static ApolloModernAwardWebController *ApolloModernAwardControllerForHost(
    UIViewController *host) {
    return objc_getAssociatedObject(host, kApolloModernAwardControllerKey);
}

%hook _TtC6Apollo26AwardGiftingViewController

- (void)viewDidLoad {
    %orig;

    id thing = nil;
    @try {
        thing = MSHookIvar<id>(self, "thingToAward");
    } @catch (__unused id exception) {}
    NSString *fullName = ApolloModernAwardFullName(thing);
    if (fullName.length == 0) {
        ApolloLog(@"[ModernAwards] no usable fullname; leaving original UI intact");
        return;
    }

    // Stop the retired screen from spinning or refreshing behind its
    // replacement. Its view/controller lifecycle remains Apollo-owned.
    @try {
        UIActivityIndicatorView *legacySpinner =
            MSHookIvar<UIActivityIndicatorView *>(self, "spinner");
        [legacySpinner stopAnimating];
        legacySpinner.hidden = YES;
        NSTimer *timer = MSHookIvar<NSTimer *>(self, "balanceRefreshingTimer");
        [timer invalidate];
    } @catch (__unused id exception) {}

    UIViewController *host = (UIViewController *)self;
    NSURL *permalink = ApolloModernAwardPermalink(thing);
    ApolloModernAwardWebController *controller =
        [[ApolloModernAwardWebController alloc] initWithThingFullName:fullName
                                                           permalink:permalink
                                                                 host:host];
    objc_setAssociatedObject(host, kApolloModernAwardControllerKey,
                             controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addChildViewController:controller];
    controller.view.frame = host.view.bounds;
    controller.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host.view addSubview:controller.view];
    [controller didMoveToParentViewController:host];
    ApolloLog(@"[ModernAwards] replaced legacy gifting screen for %@", fullName);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!ApolloModernAwardControllerForHost((UIViewController *)self)) return;
    UINavigationController *navigationController =
        ((UIViewController *)self).navigationController;
    if (!navigationController) return;
    objc_setAssociatedObject(self, kApolloModernAwardNavigationBarKey,
                             @(navigationController.navigationBarHidden),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigationController setNavigationBarHidden:YES animated:NO];
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloModernAwardWebController *controller =
        ApolloModernAwardControllerForHost((UIViewController *)self);
    if (!controller) return;
    controller.view.frame = ((UIViewController *)self).view.bounds;
    [((UIViewController *)self).view bringSubviewToFront:controller.view];
}

- (void)viewWillDisappear:(BOOL)animated {
    NSNumber *wasHidden =
        objc_getAssociatedObject(self, kApolloModernAwardNavigationBarKey);
    if (wasHidden && ((UIViewController *)self).navigationController) {
        [((UIViewController *)self).navigationController
            setNavigationBarHidden:wasHidden.boolValue animated:NO];
    }
    %orig;
}

%end
