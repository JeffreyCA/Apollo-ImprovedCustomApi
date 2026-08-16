// ApolloNSFWGate
//
// Detects Reddit's third-party mature-content gate and offers the known fix.
//
// Since the 2023 API changes, Reddit withholds sexually explicit listings from
// third-party OAuth clients UNLESS the requesting account moderates at least
// one subreddit (the "mod tools" carve-out). Verified live: a gated
// /r/<sub>/hot request answers HTTP 200 with an empty `children` array — no
// error — while /r/<sub>/about still returns full metadata (over18,
// subscriber count). Accounts with any mod position get full listings, which
// is why the community workaround is "create a private subreddit". Cookie/web
// transport is unaffected, so keyless (API-Key-Free) accounts never see this.
//
// This module watches the response serializer for exactly that signature
// (OAuth host + subreddit listing path + empty Listing), confirms via a
// one-off /about fetch that the sub is over18 and popular enough that an
// empty page is implausible, then explains the situation once per launch and
// offers to create a private subreddit via POST /api/site_admin with the
// user's own credentials — the same thing users do manually on the website
// today, minus the trip to the website.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloAccountCredentials.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloWebSessionStore.h"
#import "Defaults.h"
#import "UserDefaultConstants.h"

// Subreddits already checked this launch (both confirmed-gated and cleared),
// so one sub can't re-trigger about-fetches on every pull-to-refresh.
static NSMutableSet<NSString *> *sGateCheckedSubs = nil;
// The explainer shows at most once per launch — browsing several gated subs
// in one session must not stack alerts.
static BOOL sGateSheetShownThisLaunch = NO;
// Set only while the explainer is between -presentViewController: and its
// completion, so a burst of empty listings can't stack duplicate alerts.
static BOOL sGateSheetPresenting = NO;

// A sub this small could genuinely have an empty page; only a popular over18
// sub with zero rows is treated as the gate.
static const NSInteger kGateMinimumSubscribers = 100;

#pragma mark - Helpers

// The active account's real OAuth bearer, or nil (signed out / keyless /
// unexpected object shapes). Keyless accounts carry a synthetic bearer and are
// excluded earlier by the web-session check, but stay defensive here.
static NSString *ApolloGateActiveBearer(void) {
    id client = ApolloActiveAccountClient();
    SEL credentialSel = NSSelectorFromString(@"authorizationCredential");
    SEL tokenSel = NSSelectorFromString(@"accessToken");
    if (!client || ![client respondsToSelector:credentialSel]) return nil;
    id credential = ((id (*)(id, SEL))objc_msgSend)(client, credentialSel);
    if (!credential || ![credential respondsToSelector:tokenSel]) return nil;
    id accessToken = ((id (*)(id, SEL))objc_msgSend)(credential, tokenSel);
    if (!accessToken || ![accessToken respondsToSelector:tokenSel]) return nil;
    id token = ((id (*)(id, SEL))objc_msgSend)(accessToken, tokenSel);
    return [token isKindOfClass:[NSString class]] ? (NSString *)token : nil;
}

static UIViewController *ApolloGateTopViewController(void) {
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

// "/r/<sub>", "/r/<sub>/hot", "/r/<sub>/top.json", … -> lowercased sub name;
// nil for anything else (home feed, search, comments, user pages).
// Apollo asks RedditKit for `r/%@/%@.json` (Hopper: the listing format string at
// 0x100a2c150), so both the bare and the .json form have to match here.
static NSString *ApolloGateSubredditFromListingPath(NSString *path) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^/r/([A-Za-z0-9_]+)(?:/(?:hot|new|rising|controversial|top|best))?(?:\\.json)?/?$"
                                                       options:0 error:NULL];
    });
    if (path.length == 0) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:path options:0 range:NSMakeRange(0, path.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    return [[path substringWithRange:[m rangeAtIndex:1]] lowercaseString];
}

// Only an unfiltered FIRST page may be read as the gate. Two ordinary requests
// answer with an empty `children` array from a perfectly healthy subreddit, and
// both were indistinguishable from the gate on the path alone:
//
//   • Pagination — the page after the last one (`after=t3_…`) is always empty.
//     Reddit also caps a listing around 1000 items, so anyone who keeps
//     scrolling reaches that empty page.
//   • Time-windowed sorts — `top`/`controversial` carry `t=hour|day|week|…`,
//     and a sub that simply had no posts in the window returns nothing. `t=all`
//     is the whole history, so it stays eligible.
//
// Treating either as the gate would pop the explainer (and offer to create a
// subreddit) over a normal empty page, so both are rejected here.
static BOOL ApolloGateListingIsFirstUnfilteredPage(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        NSString *name = item.name.lowercaseString;
        if (item.value.length == 0) continue;
        if ([name isEqualToString:@"after"] || [name isEqualToString:@"before"] ||
            [name isEqualToString:@"count"]) {
            return NO;
        }
        if ([name isEqualToString:@"t"] && ![item.value.lowercaseString isEqualToString:@"all"]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - Subreddit creation

static void ApolloGateShowResultAlert(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [ApolloGateTopViewController() presentViewController:alert animated:YES completion:nil];
}

// POST /api/site_admin with the user's own OAuth bearer. The response carries
// per-field errors in json.errors (e.g. SUBREDDIT_EXISTS, BAD_SR_NAME,
// RATELIMIT) rather than HTTP status.
static void ApolloGateCreateSubredditNamed(NSString *name) {
    NSString *bearer = ApolloGateActiveBearer();
    if (bearer.length == 0) {
        ApolloGateShowResultAlert(@"Not Signed In", @"Creating a subreddit needs a signed-in API-key account.");
        return;
    }
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/api/site_admin"]
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:15.0];
    request.HTTPMethod = @"POST";
    [request setValue:[@"bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    NSString *encodedName = [name stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: name;
    NSString *body = [NSString stringWithFormat:
        @"api_type=json&name=%@&title=%@&type=private&link_type=any&over_18=false"
        @"&public_description=%@",
        encodedName, encodedName,
        [@"Personal subreddit (created from Apollo to enable mature content)."
            stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSArray *errors = nil;
        if (data.length > 0) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            id json = [root isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)root)[@"json"] : nil;
            id errs = [json isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)json)[@"errors"] : nil;
            if ([errs isKindOfClass:[NSArray class]]) errors = errs;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || http.statusCode != 200) {
                ApolloLog(@"[NSFWGate] site_admin failed: HTTP %ld error=%@", (long)http.statusCode, error);
                ApolloGateShowResultAlert(@"Couldn't Create Subreddit",
                    [NSString stringWithFormat:@"Reddit answered HTTP %ld. Try again later, or create one at reddit.com.",
                                               (long)http.statusCode]);
                return;
            }
            if (!errors) {
                // HTTP 200 with a body we couldn't read as api_type=json. The
                // request may well have succeeded, so don't report an HTTP
                // failure that didn't happen — say what we actually know.
                ApolloLog(@"[NSFWGate] site_admin returned HTTP 200 with an unrecognized body shape");
                ApolloGateShowResultAlert(@"Couldn't Confirm",
                    [NSString stringWithFormat:@"Reddit accepted the request but its reply wasn't in the expected "
                                               @"format, so we can't tell whether r/%@ was created. Check your "
                                               @"subreddits before trying again.", name]);
                return;
            }
            if (errors.count > 0) {
                // Each entry is [CODE, message, field]; surface the message.
                NSArray *first = [errors.firstObject isKindOfClass:[NSArray class]] ? errors.firstObject : nil;
                NSString *message = first.count > 1 && [first[1] isKindOfClass:[NSString class]]
                    ? first[1] : @"Reddit rejected the request.";
                ApolloLog(@"[NSFWGate] site_admin rejected: %@", errors);
                ApolloGateShowResultAlert(@"Couldn't Create Subreddit", message);
                return;
            }
            ApolloLog(@"[NSFWGate] Created private subreddit r/%@", name);
            ApolloGateShowResultAlert(@"Subreddit Created",
                [NSString stringWithFormat:@"r/%@ was created as private. Reddit usually unlocks mature content for "
                                           @"moderator accounts within a few minutes — pull to refresh the subreddit "
                                           @"then. The subreddit is private and invisible to everyone but you.", name]);
        });
    }];
    [task resume];
    [session finishTasksAndInvalidate];
}

static void ApolloGatePromptCreateSubreddit(void) {
    // Reddit subreddit names: 3-21 chars, letters/digits/underscore, no
    // leading underscore. Suggest "<username>_apollo" trimmed to fit.
    NSString *username = ApolloActiveAccountUsername() ?: @"";
    NSMutableString *suggestion = [NSMutableString string];
    for (NSUInteger i = 0; i < username.length && suggestion.length < 14; i++) {
        // Explicit ASCII ranges, not isalnum(): that takes an int that must be
        // representable as unsigned char, and a unichar above 255 is undefined
        // behaviour there. Reddit usernames are ASCII, but the suggestion is
        // built from whatever the account name actually holds.
        unichar c = [username characterAtIndex:i];
        BOOL allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                       (c >= '0' && c <= '9') || c == '_';
        if (allowed) [suggestion appendFormat:@"%C", c];
    }
    while ([suggestion hasPrefix:@"_"]) [suggestion deleteCharactersInRange:NSMakeRange(0, 1)];
    NSString *prefill = suggestion.length > 0 ? [suggestion stringByAppendingString:@"_apollo"] : @"my_apollo_sub";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Create Private Subreddit"
                                                                   message:@"Pick a name (3–21 letters, numbers, or underscores). The subreddit will be private — nobody else can see it.\n\nReddit does not allow subreddits to be deleted, so this can't be undone and the name is taken for good."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = prefill;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        NSString *name = weakAlert.textFields.firstObject.text ?: @"";
        static NSRegularExpression *valid;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            valid = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9_]{2,20}$" options:0 error:NULL];
        });
        if (![valid firstMatchInString:name options:0 range:NSMakeRange(0, name.length)]) {
            ApolloGateShowResultAlert(@"Invalid Name", @"Subreddit names are 3–21 letters, numbers, or underscores, and can't start with an underscore.");
            return;
        }
        ApolloGateCreateSubredditNamed(name);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ApolloGateTopViewController() presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Explainer

static void ApolloGatePresentExplainer(NSString *subreddit) {
    if (sGateSheetShownThisLaunch || sGateSheetPresenting) return;
    // Don't spend the once-per-launch chance on a presentation that can't
    // land. UIKit silently drops -presentViewController: when the presenter is
    // nil or mid-transition, and the flag used to be set before the call — so
    // an alert that never appeared still burned the explainer for the whole
    // launch. Confirm a presentable controller first, then mark it shown from
    // the completion, once the alert is genuinely on screen.
    UIViewController *top = ApolloGateTopViewController();
    if (!top || top.isBeingPresented || top.isBeingDismissed ||
        top.presentedViewController) {
        ApolloLog(@"[NSFWGate] explainer for r/%@ deferred — no presentable controller", subreddit);
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Mature Content Blocked by Reddit"
                         message:[NSString stringWithFormat:
        @"r/%@ appears empty because Reddit withholds mature content from third-party API apps — "
        @"unless the account moderates a subreddit.\n\n"
        @"The reliable fix: create a private subreddit (invisible to everyone but you). Reddit then "
        @"treats this account as a moderator and unlocks mature content, usually within minutes.\n\n"
        @"Alternatively, accounts signed in with reddit.com (API-Key-Free) are not affected.", subreddit]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create Private Subreddit…" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        ApolloGatePromptCreateSubreddit();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Don't Show Again" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UDKeyNSFWGateExplainerEnabled];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now" style:UIAlertActionStyleCancel handler:nil]];
    // In-flight guard so a second empty listing arriving before the alert is
    // up can't present a duplicate; cleared alongside the shown flag.
    sGateSheetPresenting = YES;
    [top presentViewController:alert animated:YES completion:^{
        sGateSheetShownThisLaunch = YES;
        sGateSheetPresenting = NO;
        ApolloLog(@"[NSFWGate] Presented mature-content explainer for r/%@", subreddit);
    }];
}

#pragma mark - Detection

// Confirms the empty listing was the gate (sub is over18 + too popular for an
// empty first page) before involving the user. Uses the account's own bearer;
// one attempt per sub per launch.
static void ApolloGateVerifyAndExplain(NSString *subreddit) {
    NSString *bearer = ApolloGateActiveBearer();
    if (bearer.length == 0) return;
    NSString *path = [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/about?raw_json=1",
                      [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:path]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10.0];
    [request setValue:[@"bearer " stringByAppendingString:bearer] forHTTPHeaderField:@"Authorization"];
    [request setValue:([sUserAgent length] > 0 ? sUserAgent : defaultUserAgent) forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL over18 = NO;
        NSInteger subscribers = 0;
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (!error && http.statusCode == 200 && data.length > 0) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSDictionary *sub = [root isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)root)[@"data"] : nil;
            if ([sub isKindOfClass:[NSDictionary class]]) {
                over18 = [sub[@"over18"] isKindOfClass:[NSNumber class]] && [sub[@"over18"] boolValue];
                subscribers = [sub[@"subscribers"] isKindOfClass:[NSNumber class]] ? [sub[@"subscribers"] integerValue] : 0;
            }
        }
        if (!over18 || subscribers < kGateMinimumSubscribers) return;
        ApolloLog(@"[NSFWGate] Gate confirmed for r/%@ (over18, %ld subscribers, empty listing)",
                  subreddit, (long)subscribers);
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloGatePresentExplainer(subreddit); });
    }];
    [task resume];
    [session finishTasksAndInvalidate];
}

// Serializer-level sniff. Runs for every OAuth response on whatever thread
// AFNetworking parsed it on, so bail cheapest-first: the once-per-launch flag,
// then host, then the path regex, then the query, then the result shape. The
// NSUserDefaults read comes last so the common case never pays for it.
static void ApolloGateInspectResponse(NSURLResponse *response, id responseObject) {
    if (sGateSheetShownThisLaunch || sGateSheetPresenting) return;
    NSURL *url = response.URL;
    if (![url.host.lowercaseString isEqualToString:@"oauth.reddit.com"]) return;
    NSString *subreddit = ApolloGateSubredditFromListingPath(url.path);
    if (subreddit.length == 0) return;
    if (!ApolloGateListingIsFirstUnfilteredPage(url)) return;

    if (![responseObject isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *listing = (NSDictionary *)responseObject;
    if (![listing[@"kind"] isEqual:@"Listing"]) return;
    NSDictionary *data = [listing[@"data"] isKindOfClass:[NSDictionary class]] ? listing[@"data"] : nil;
    NSArray *children = [data[@"children"] isKindOfClass:[NSArray class]] ? data[@"children"] : nil;
    if (!children || children.count > 0) return;
    // An `after` cursor on an empty page means Reddit still has more to give —
    // a gated listing terminates instead of paging on.
    if ([data[@"after"] isKindOfClass:[NSString class]] && [data[@"after"] length] > 0) return;

    if (![[NSUserDefaults standardUserDefaults] boolForKey:UDKeyNSFWGateExplainerEnabled]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Keyless accounts route through cookies and never see the gate; a
        // signed-out session can't act on the advice. Both checks touch
        // main-confined account state, hence the hop.
        NSString *active = ApolloActiveAccountUsername();
        if (active.length == 0 || ApolloWebSessionFor(active) != nil) return;
        if (!sGateCheckedSubs) sGateCheckedSubs = [NSMutableSet set];
        if ([sGateCheckedSubs containsObject:subreddit]) return;
        [sGateCheckedSubs addObject:subreddit];
        ApolloGateVerifyAndExplain(subreddit);
    });
}

%hook RDKResponseSerializer

- (id)responseObjectForResponse:(id)response data:(id)data error:(id *)error {
    id obj = %orig;
    @try {
        if ([response isKindOfClass:[NSURLResponse class]]) {
            ApolloGateInspectResponse((NSURLResponse *)response, obj);
        }
    } @catch (NSException *e) {
        ApolloLog(@"[NSFWGate] response inspection failed: %@", e);
    }
    return obj;
}

%end
