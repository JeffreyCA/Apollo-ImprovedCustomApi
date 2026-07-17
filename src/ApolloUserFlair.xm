#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloWebJSON.h"
#import "ApolloWebSessionStore.h"
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

static char kApolloUserFlairEditorPresentedKey;
static char kApolloUserFlairCapturedOptionsKey;
static char kApolloUserFlairCollapseModelKey;
static char kApolloUserFlairCurrentFlairKey;
static char kApolloUserFlairCssByTemplateKey;   // template_id -> css_class (trimmed)
static char kApolloUserFlairSpriteMapKey;        // css_class -> @{url,x,y,w,h,round}
static char kApolloUserFlairSpriteFetchedKey;    // @YES once sprite-data fetch started
static char kApolloUserFlairWebCSSClassKey;      // css_class recovered from old-reddit HTML
static char kApolloUserFlairWebCurrentOptionKey; // @YES on the option matched to the signed-in user's flair
static char kApolloUserFlairWebStateAppliedKey;  // prevents overwriting a selection made after initial load
// Per-option PERSISTENT display flairs for old-reddit css-class templates. Unlike
// the thread-local override below, this is read by Apollo's async ASDK layout pass
// (which runs after the node block returns, when the thread-local is gone), so the
// sprite/name actually renders. Only `flairs` is overridden — textRepresentation is
// left as the template's real (empty) text so committing the selection is unchanged.
static char kApolloUserFlairOptionDisplayFlairsKey;

static const NSUInteger kApolloUserFlairMaxLength = 64;

// The flair selector's flair options live in section 1 of its table.
static const NSInteger kApolloUserFlairOptionsSection = 1;

// Placeholder shown on a blank, editable flair row so it's obvious it's tappable.
static NSString *const kApolloUserFlairCustomRowText = @"Set custom flair…";

// Shown when a subreddit's flair is enabled but every template is empty AND not
// editable — there is genuinely nothing to pick (the case is broken on the web too).
static NSString *const kApolloUserFlairNoFlairsRowText = @"No usable flairs in this community";

static __thread __unsafe_unretained UIViewController *tApolloUserFlairCaptureController = nil;
static __thread NSInteger tApolloUserFlairCaptureSection = NSNotFound;
static __thread NSInteger tApolloUserFlairCaptureRow = NSNotFound;
// While a "custom flair" cell is being built, these let the (otherwise empty)
// RDKFlairOption getters render either the user's CURRENT flair or the
// "Set custom flair…" placeholder. They never mutate the model.
static __thread __unsafe_unretained id tApolloUserFlairCustomRowOption = nil;
static __thread __unsafe_unretained NSArray *tApolloUserFlairCustomRowFlairs = nil;
static __thread __unsafe_unretained NSString *tApolloUserFlairCustomRowDisplayText = nil;

// Forward declaration (defined in the collapse section) so the edit session can
// pre-fill the editor with the user's current flair.
static NSString *ApolloUserFlairCurrentFlairTextForOption(UIViewController *controller, id option);
static NSString *ApolloUserFlairPrettifyClass(NSString *cssClass);

// Implemented in ApolloSwiftIvarBridge.swift. Swift owns the assignment so the
// Optional<String> representation and retain/release behavior remain ABI-safe.
#ifdef __cplusplus
extern "C" {
#endif
extern void ApolloSwiftAssignOptionalString(void *storage, const char *utf8Value);
#ifdef __cplusplus
}
#endif

@interface ApolloUserFlairOptionAdapter : NSObject
@property (nonatomic, strong) id option;
+ (instancetype)adapterWithOption:(id)option;
- (NSString *)templateID;
- (NSString *)displayText;
- (BOOL)isEditableWithKnown:(BOOL *)known;
- (BOOL)setDisplayText:(NSString *)text;
@end

@interface ApolloUserFlairSelectorAdapter : NSObject
@property (nonatomic, weak) UIViewController *controller;
+ (instancetype)adapterWithController:(UIViewController *)controller;
- (BOOL)isUserFlairSelector;
- (NSString *)subredditNameUsingSource:(id)source;
- (UIViewController *)presenter;
- (BOOL)prepareForNativeUpdate;
- (BOOL)performNativeUpdate;
@end

@interface ApolloUserFlairEditSession : NSObject
@property (nonatomic, strong) ApolloUserFlairSelectorAdapter *selectorAdapter;
@property (nonatomic, strong) ApolloUserFlairOptionAdapter *optionAdapter;
@property (nonatomic, copy) NSString *subredditName;
@property (nonatomic, copy) NSString *templateID;
@property (nonatomic, copy) NSString *initialText;
+ (instancetype)sessionWithSelectorAdapter:(ApolloUserFlairSelectorAdapter *)selectorAdapter optionAdapter:(ApolloUserFlairOptionAdapter *)optionAdapter subredditName:(NSString *)subredditName templateID:(NSString *)templateID initialText:(NSString *)initialText;
@end

#pragma mark - Runtime Access

static id ApolloUserFlairObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSString *ApolloUserFlairSwiftStringIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') return nil;

        ptrdiff_t offset = ivar_getOffset(ivar);
        uint8_t *base = (uint8_t *)(__bridge void *)object + offset;
        uint64_t low = 0;   // _countAndFlags (word 0)
        uint64_t high = 0;  // _object / BridgeObject (word 1)
        memcpy(&low, base, sizeof(low));
        memcpy(&high, base + sizeof(low), sizeof(high));

        uint8_t discriminator = (uint8_t)(high >> 56);

        // Small string: up to 15 UTF-8 bytes stored inline across both words; the
        // discriminator byte is 0xE0 | count.
        if (discriminator >= 0xE0 && discriminator <= 0xEF) {
            NSUInteger length = discriminator - 0xE0;
            if (length == 0 || length > 15) return nil;

            char buffer[16] = {0};
            for (NSUInteger i = 0; i < length && i < 8; i++) {
                buffer[i] = (char)((low >> (i * 8)) & 0xFF);
            }
            for (NSUInteger i = 8; i < length; i++) {
                buffer[i] = (char)((high >> ((i - 8) * 8)) & 0xFF);
            }
            return [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
        }

        // Large string (>15 bytes, OR any string that was bridged in from an NSString —
        // e.g. a subreddit name passed through Apollo's ObjC RDKClient API, which never
        // takes the inline small-string form). Word 1 is a Swift BridgeObject whose
        // payload (with the top discriminator byte cleared) is the backing storage
        // object. Both Swift's native __StringStorage and a lazily-bridged Cocoa string
        // are NSString subclasses, so we read the value by messaging that pointer as an
        // NSString. Guard hard: a bad read must never crash the flair selector.
        uintptr_t storagePtr = (uintptr_t)(high & 0x00FFFFFFFFFFFFFFULL);
        if (storagePtr < 0x1000) return nil; // not a plausible heap pointer
        @try {
            id storage = (__bridge id)(void *)storagePtr;
            if ([storage isKindOfClass:[NSString class]]) {
                // Copy out of Swift's storage so we own a stable, ObjC-managed string.
                NSString *value = [(NSString *)storage copy];
                if (value.length > 0) return value;
            }
        } @catch (__unused NSException *exception) {
            return nil;
        }
        return nil;
    }
    return nil;
}

static BOOL ApolloUserFlairSetSwiftOptionalStringIvar(id object, NSString *name, NSString *value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') return NO;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *storage = (uint8_t *)(__bridge void *)object + offset;
        ApolloSwiftAssignOptionalString(storage, value.length > 0 ? value.UTF8String : NULL);
        return YES;
    }
    return NO;
}

static BOOL ApolloUserFlairBoolIvar(id object, NSString *name, BOOL *found) {
    if (found) *found = NO;
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        if (found) *found = YES;
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(BOOL *)((uint8_t *)(__bridge void *)object + offset);
    }
    return NO;
}

static BOOL ApolloUserFlairSetBoolIvar(id object, NSString *name, BOOL value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        ptrdiff_t offset = ivar_getOffset(ivar);
        *(BOOL *)((uint8_t *)(__bridge void *)object + offset) = value;
        return YES;
    }
    return NO;
}

static BOOL ApolloUserFlairSetByteIvar(id object, NSString *name, uint8_t value) {
    if (!object || name.length == 0) return NO;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        *((uint8_t *)(__bridge void *)object + offset) = value;
        return YES;
    }
    return NO;
}

static id ApolloUserFlairRawObjectIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *rawValue = NULL;
        memcpy(&rawValue, (uint8_t *)(__bridge void *)object + offset, sizeof(rawValue));
        return (__bridge id)rawValue;
    }
    return nil;
}

static id ApolloUserFlairSendObject(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL ApolloUserFlairSendBool(id target, NSString *selectorName, BOOL *found) {
    if (found) *found = NO;
    if (!target || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return NO;
    if (found) *found = YES;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        if (found) *found = NO;
        return NO;
    }
}

static id ApolloUserFlairKVCValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *ApolloUserFlairStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSURL class]]) return [(NSURL *)value absoluteString];
    if ([value respondsToSelector:@selector(stringValue)]) {
        id stringValue = ApolloUserFlairSendObject(value, @"stringValue");
        if ([stringValue isKindOfClass:[NSString class]]) return stringValue;
    }
    return nil;
}

static NSString *ApolloUserFlairObjectString(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        if ([object isKindOfClass:[NSDictionary class]]) {
            NSString *string = ApolloUserFlairStringFromValue([(NSDictionary *)object objectForKey:name]);
            if (string.length > 0) return string;
        }

        NSString *string = ApolloUserFlairStringFromValue(ApolloUserFlairSendObject(object, name));
        if (string.length > 0) return string;

        string = ApolloUserFlairStringFromValue(ApolloUserFlairKVCValue(object, name));
        if (string.length > 0) return string;

        string = ApolloUserFlairStringFromValue(ApolloUserFlairObjectIvar(object, name));
        if (string.length > 0) return string;

        NSString *underscored = [@"_" stringByAppendingString:name];
        string = ApolloUserFlairStringFromValue(ApolloUserFlairObjectIvar(object, underscored));
        if (string.length > 0) return string;

        string = ApolloUserFlairSwiftStringIvar(object, name);
        if (string.length > 0) return string;

        string = ApolloUserFlairSwiftStringIvar(object, underscored);
        if (string.length > 0) return string;
    }
    return nil;
}

static NSArray *ApolloUserFlairObjectArray(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = ApolloUserFlairSendObject(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairKVCValue(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairObjectIvar(object, name);
        if ([value isKindOfClass:[NSArray class]]) return value;

        value = ApolloUserFlairObjectIvar(object, [@"_" stringByAppendingString:name]);
        if ([value isKindOfClass:[NSArray class]]) return value;
    }
    return nil;
}

#pragma mark - Flair Option Adapter

static BOOL ApolloUserFlairOptionIsEditable(id option, BOOL *found) {
    BOOL localFound = NO;
    BOOL editable = ApolloUserFlairSendBool(option, @"isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairSendBool(option, @"editable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairBoolIvar(option, @"isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    editable = ApolloUserFlairBoolIvar(option, @"_isEditable", &localFound);
    if (localFound) {
        if (found) *found = YES;
        return editable;
    }

    if (found) *found = NO;
    return NO;
}

static NSString *ApolloUserFlairOptionIdentifier(id option) {
    return ApolloUserFlairObjectString(option, @[
        @"identifier",
        @"flairID",
        @"flairId",
        @"flairTemplateID",
        @"flairTemplateId",
        @"templateID",
        @"templateId"
    ]);
}

static NSString *ApolloUserFlairOptionText(id option) {
    NSString *text = ApolloUserFlairObjectString(option, @[
        @"textRepresentation",
        @"text",
        @"flairText",
        @"flair_text",
        @"plainText",
        @"title"
    ]);
    if (text.length > 0) return text;

    NSArray *flairs = ApolloUserFlairObjectArray(option, @[@"flairs"]);
    NSMutableString *joined = [NSMutableString string];
    for (id flair in flairs) {
        NSString *piece = ApolloUserFlairObjectString(flair, @[@"textRepresentation", @"text", @"emojiLabel"]);
        if (piece.length == 0) continue;
        [joined appendString:piece];
    }
    return joined.length > 0 ? joined : nil;
}

static BOOL ApolloUserFlairSetOptionText(id option, NSString *text) {
    SEL setter = @selector(setTextRepresentation:);
    if (!option || ![option respondsToSelector:setter]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(option, setter, text ?: @"");
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

@implementation ApolloUserFlairOptionAdapter

+ (instancetype)adapterWithOption:(id)option {
    ApolloUserFlairOptionAdapter *adapter = [ApolloUserFlairOptionAdapter new];
    adapter.option = option;
    return adapter;
}

- (NSString *)templateID {
    return ApolloUserFlairOptionIdentifier(self.option);
}

- (NSString *)displayText {
    return ApolloUserFlairOptionText(self.option) ?: @"";
}

- (BOOL)isEditableWithKnown:(BOOL *)known {
    return ApolloUserFlairOptionIsEditable(self.option, known);
}

- (BOOL)setDisplayText:(NSString *)text {
    return ApolloUserFlairSetOptionText(self.option, text);
}

@end

#pragma mark - Flair Selector Adapter

static NSString *ApolloUserFlairSubredditNameFromObject(id object, NSUInteger depth);

static NSString *ApolloUserFlairSubredditNameFromValue(id value, NSUInteger depth) {
    if (!value || depth > 2) return nil;
    NSString *direct = ApolloUserFlairStringFromValue(value);
    if (direct.length > 0) return direct;
    return ApolloUserFlairSubredditNameFromObject(value, depth + 1);
}

static NSString *ApolloUserFlairSubredditNameFromObject(id object, NSUInteger depth) {
    if (!object || depth > 2) return nil;

    NSArray<NSString *> *names = @[
        @"subredditName",
        @"subreddit",
        @"displayName",
        @"name",
        @"subredditIdentifier",
        @"currentSubreddit"
    ];
    for (NSString *name in names) {
        NSString *value = ApolloUserFlairObjectString(object, @[name]);
        if (value.length > 0) return value;

        value = ApolloUserFlairObjectString(object, @[[@"_" stringByAppendingString:name]]);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairSendObject(object, name), depth);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairObjectIvar(object, name), depth);
        if (value.length > 0) return value;

        value = ApolloUserFlairSubredditNameFromValue(ApolloUserFlairObjectIvar(object, [@"_" stringByAppendingString:name]), depth);
        if (value.length > 0) return value;
    }
    return nil;
}

static NSString *ApolloUserFlairCleanSubredditName(NSString *subredditName) {
    if (subredditName.length == 0) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"]) clean = [clean substringFromIndex:2];
    return clean.length > 0 ? clean : nil;
}

static BOOL ApolloUserFlairControllerLooksUserScoped(UIViewController *controller) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    if (controller.title.length > 0) [strings addObject:controller.title];
    if (controller.navigationItem.title.length > 0) [strings addObject:controller.navigationItem.title];
    if (controller.navigationItem.prompt.length > 0) [strings addObject:controller.navigationItem.prompt];

    for (NSString *string in strings) {
        NSString *lower = string.lowercaseString;
        if ([lower containsString:@"post flair"] || [lower containsString:@"link flair"] || [lower containsString:@"crosspost"]) return NO;
    }
    return YES;
}

static UIViewController *ApolloUserFlairPresenterForController(UIViewController *controller) {
    UIViewController *presenter = controller;
    while (presenter.presentedViewController && ![presenter.presentedViewController isKindOfClass:[UIAlertController class]]) {
        presenter = presenter.presentedViewController;
    }
    return presenter ?: controller;
}

// First http(s) URL embedded in a string (NSDataDetector handles "Go to <url> ..."
// instruction text, and promotes bare domains like "flair.x.com" to http). nil when
// there's no web link. The http/https-only filter is deliberate — it rejects
// mailto:/custom-scheme deeplinks that a malicious flair could otherwise smuggle
// into the in-app browser. outRange (optional) receives the matched URL's range.
static NSURL *ApolloUserFlairFirstURL(NSString *text, NSRange *outRange) {
    if (outRange) *outRange = NSMakeRange(NSNotFound, 0);
    if (text.length == 0) return nil;
    NSDataDetector *det = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    NSTextCheckingResult *m = [det firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSURL *url = m.URL;
    if (url && ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) {
        if (outRange) *outRange = m.range;
        return url;
    }
    return nil;
}

// Open a URL in an in-app browser (SFSafariViewController), keeping the user inside
// Apollo — used for subreddits whose only "flair" option is a link to an external
// flair tool (e.g. r/anime's flair.r-anime.moe). Falls back to the system opener.
static void ApolloUserFlairOpenURLInApp(UIViewController *controller, NSURL *url) {
    if (!url || !controller) return;
    Class sfvc = objc_getClass("SFSafariViewController");
    if (sfvc) {
        id vc = ((id (*)(id, SEL, NSURL *))objc_msgSend)([sfvc alloc], @selector(initWithURL:), url);
        if ([vc isKindOfClass:[UIViewController class]]) {
            [controller presentViewController:vc animated:YES completion:nil];
            return;
        }
    }
    if ([[UIApplication sharedApplication] respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

// YES when a flair row is really an "external flair tool" link — an instruction
// whose text is essentially just a URL (e.g. r/anime "Go to https://flair.r-anime.moe
// to get your flair!", r/CFB "More flair options at https://flair.redditcfb.com!") —
// rather than a selectable flair. We then open it in-app instead of committing it.
// Deliberately independent of editability: some subs mark the tool row editable, and
// the old non-editable gate let users commit the instruction text as their flair.
// Never hijacks a real flair: bails on image/emoji flairs, and only fires when the
// URL dominates the text (or there's explicit flair-tool phrasing / a known tool host).
static BOOL ApolloUserFlairOptionIsLinkInstruction(id option, NSURL **outURL) {
    if (outURL) *outURL = nil;
    if (!option) return NO;
    // A real badge/sprite/emoji flair that merely mentions a URL must NOT be hijacked.
    for (id f in ApolloUserFlairObjectArray(option, @[@"flairs"])) {
        if (ApolloUserFlairObjectString(f, @[@"imageURL"]).length > 0) return NO;
    }
    NSString *text = ApolloUserFlairOptionText(option);
    if (text.length == 0) return NO;
    NSRange r = NSMakeRange(NSNotFound, 0);
    NSURL *url = ApolloUserFlairFirstURL(text, &r);
    if (!url) return NO;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // (a) The URL dominates: it's basically the whole text, or only a short
    //     instruction wraps it ("Go to <url> to get your flair!").
    NSUInteger urlLen = (r.location == NSNotFound) ? 0 : r.length;
    NSString *remainder = (r.location != NSNotFound) ? [text stringByReplacingCharactersInRange:r withString:@""] : text;
    NSMutableCharacterSet *strip = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
    [strip formUnionWithCharacterSet:[NSCharacterSet punctuationCharacterSet]];
    [strip formUnionWithCharacterSet:[NSCharacterSet symbolCharacterSet]];
    remainder = [remainder stringByTrimmingCharactersInSet:strip];
    BOOL dominant = (urlLen >= trimmed.length) || (remainder.length <= 40);
    // (b) Explicit flair-tool phrasing (covers longer instructions on other subs).
    BOOL keyword = NO;
    NSString *low = text.lowercaseString;
    for (NSString *kw in @[@"get your flair", @"set your flair", @"more flair", @"flair options", @"flair tool", @"flair page", @"your flair"]) {
        if ([low containsString:kw]) { keyword = YES; break; }
    }
    // (c) Known external flair-tool hosts (a "flair"-prefixed subdomain, or flairwizard).
    NSString *host = url.host.lowercaseString;
    NSString *firstLabel = [[host componentsSeparatedByString:@"."] firstObject];
    BOOL knownDomain = host && ([firstLabel containsString:@"flair"] ||
                                [host rangeOfString:@"flairwizard"].location != NSNotFound);
    if (!(dominant || keyword || knownDomain)) return NO;
    if (outURL) *outURL = url;
    return YES;
}

@implementation ApolloUserFlairSelectorAdapter

+ (instancetype)adapterWithController:(UIViewController *)controller {
    ApolloUserFlairSelectorAdapter *adapter = [ApolloUserFlairSelectorAdapter new];
    adapter.controller = controller;
    return adapter;
}

- (BOOL)isUserFlairSelector {
    return ApolloUserFlairControllerLooksUserScoped(self.controller);
}

- (NSString *)subredditNameUsingSource:(id)source {
    NSString *subredditName = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject(source ?: self.controller, 0));
    if (subredditName.length == 0 && source != self.controller) {
        subredditName = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject(self.controller, 0));
    }
    return subredditName;
}

- (UIViewController *)presenter {
    return ApolloUserFlairPresenterForController(self.controller);
}

- (BOOL)prepareForNativeUpdate {
    BOOL marked = ApolloUserFlairSetBoolIvar(self.controller, @"hasMadeChanges", YES);
    if (!marked) marked = ApolloUserFlairSetByteIvar(self.controller, @"hasMadeChanges", 1);

    id updateButton = ApolloUserFlairObjectIvar(self.controller, @"updateBarButtonItem");
    if (!updateButton) updateButton = ApolloUserFlairRawObjectIvar(self.controller, @"updateBarButtonItem");
    BOOL buttonEnabled = NO;
    if ([updateButton respondsToSelector:@selector(setEnabled:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(updateButton, @selector(setEnabled:), YES);
        buttonEnabled = YES;
    }
    ApolloLog(@"[UserFlair] prepared native update dirty=%@ updateButton=%@ buttonEnabled=%@",
        marked ? @"yes" : @"no",
        updateButton ? @"yes" : @"no",
        buttonEnabled ? @"yes" : @"no");
    return marked;
}

- (BOOL)performNativeUpdate {
    UIViewController *controller = self.controller;
    SEL updateSEL = @selector(updateBarButtonItemTappedWithSender:);
    if (!controller || ![controller respondsToSelector:updateSEL]) return NO;

    objc_setAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id))objc_msgSend)(controller, updateSEL, nil);
    });
    return YES;
}

@end

#pragma mark - Edit Session

@implementation ApolloUserFlairEditSession

+ (instancetype)sessionWithSelectorAdapter:(ApolloUserFlairSelectorAdapter *)selectorAdapter optionAdapter:(ApolloUserFlairOptionAdapter *)optionAdapter subredditName:(NSString *)subredditName templateID:(NSString *)templateID initialText:(NSString *)initialText {
    ApolloUserFlairEditSession *session = [ApolloUserFlairEditSession new];
    session.selectorAdapter = selectorAdapter;
    session.optionAdapter = optionAdapter;
    session.subredditName = subredditName;
    session.templateID = templateID;
    session.initialText = initialText ?: @"";
    return session;
}

@end

static ApolloUserFlairEditSession *ApolloUserFlairBuildEditSession(UIViewController *controller, id option, id source, NSString *reason) {
    ApolloUserFlairSelectorAdapter *selectorAdapter = [ApolloUserFlairSelectorAdapter adapterWithController:controller];
    ApolloUserFlairOptionAdapter *optionAdapter = [ApolloUserFlairOptionAdapter adapterWithOption:option];

    BOOL editableKnown = NO;
    BOOL editable = [optionAdapter isEditableWithKnown:&editableKnown];
    NSString *subredditName = [selectorAdapter subredditNameUsingSource:source];
    NSString *templateID = [optionAdapter templateID];

    ApolloLog(@"[UserFlair] %@ tapped optionClass=%@ templateID=%@ editable=%@ editableKnown=%@ subreddit=%@",
        reason ?: @"selection",
        option ? NSStringFromClass([option class]) : @"(nil)",
        templateID ?: @"(nil)",
        editable ? @"yes" : @"no",
        editableKnown ? @"yes" : @"no",
        subredditName ?: @"(nil)");

    if (!option || ![selectorAdapter isUserFlairSelector] || !editableKnown || !editable || subredditName.length == 0 || templateID.length == 0) return nil;

    // Pre-fill with the user's CURRENT flair when editing the row it lives on, so
    // opening the editor shows (and lets you tweak) what you already have.
    NSString *currentFlairText = ApolloUserFlairCurrentFlairTextForOption(controller, option);
    NSString *initialText = currentFlairText.length > 0 ? currentFlairText : [optionAdapter displayText];

    return [ApolloUserFlairEditSession sessionWithSelectorAdapter:selectorAdapter
                                                    optionAdapter:optionAdapter
                                                    subredditName:subredditName
                                                      templateID:templateID
                                                     initialText:initialText];
}

#pragma mark - Editor

static void ApolloUserFlairShowError(UIViewController *controller, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error Setting Flair"
                                                                       message:message.length > 0 ? message : @"Reddit returned an error while saving your flair."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [ApolloUserFlairPresenterForController(controller) presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL ApolloUserFlairCommitEditedSession(ApolloUserFlairEditSession *session, NSString *text) {
    // Apollo only saves through the native Update path when its selector is dirty.
    // Text-only edits on the checked template do not flip that flag, so update the option text,
    // mark the selector dirty, then invoke Apollo's Update handler.
    if (![session.optionAdapter setDisplayText:text]) return NO;
    if (![session.selectorAdapter prepareForNativeUpdate]) return NO;

    ApolloLog(@"[UserFlair] committing through native update subreddit=%@ templateID=%@ textLen=%lu",
        session.subredditName ?: @"(nil)",
        session.templateID ?: @"(nil)",
        (unsigned long)text.length);
    return [session.selectorAdapter performNativeUpdate];
}

#pragma mark - Subreddit Emoji Picker

// Reddit caps user flair at 64 text characters and 10 emojis. An emoji is inserted
// into the flair text as a :name: token, which Reddit renders back as the image.
static const NSUInteger kApolloUserFlairMaxEmojis = 10;

static NSRegularExpression *ApolloUserFlairEmojiTokenRegex(void) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@":[A-Za-z0-9_+\\-]+:" options:0 error:NULL];
    });
    return regex;
}

// Cache of the user-flair-allowed emoji list per subreddit (lowercased key).
// Each item: @{ @"name": <token without colons>, @"url": <png url> }.
static NSMutableDictionary<NSString *, NSArray *> *ApolloUserFlairEmojiListCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

// Old Reddit's flair selector embeds only the emoji used by its visible
// templates. Keep track of those cache entries as partial so opening the editor
// still fetches Reddit's complete user-flair-allowed emoji catalogue.
static NSMutableSet<NSString *> *ApolloUserFlairPartialEmojiCacheKeys(void) {
    static NSMutableSet *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = [NSMutableSet set]; });
    return keys;
}

static NSMutableDictionary<NSString *, id> *ApolloUserFlairWebEmojiFetches(void);

static NSArray<NSHTTPCookie *> *ApolloUserFlairCookiesFromHeader(NSString *header) {
    if (header.length == 0) return @[];
    NSMutableArray *cookies = [NSMutableArray array];
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *rawPair in [header componentsSeparatedByString:@";"]) {
        NSString *pair = [rawPair stringByTrimmingCharactersInSet:whitespace];
        NSRange separator = [pair rangeOfString:@"="];
        if (separator.location == NSNotFound || separator.location == 0) continue;
        NSString *name = [[pair substringToIndex:separator.location] stringByTrimmingCharactersInSet:whitespace];
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

// Reddit's OAuth emoji endpoint deliberately rejects website-session cookies.
// Shreddit exposes the same catalog through a signed-in web-only endpoint. Load
// a subreddit page in a hidden WKWebView, then make that request in its page
// context once the flair control is ready. The active keyless account's exact
// cookies stay isolated in that web view, and a document-start fetch wrapper
// converts the HTML response into a small JSON array for Apollo.
@interface ApolloUserFlairWebEmojiFetch : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, strong) NSArray *fallback;
@property (nonatomic, strong) NSMutableArray *completions;
@property (nonatomic) NSUInteger polls;
@property (nonatomic) BOOL finished;
@end

@implementation ApolloUserFlairWebEmojiFetch
- (instancetype)initWithSubreddit:(NSString *)subreddit fallback:(NSArray *)fallback {
    if ((self = [super init])) {
        _subreddit = [subreddit copy];
        _cacheKey = subreddit.lowercaseString;
        _fallback = fallback ?: @[];
        _completions = [NSMutableArray array];
    }
    return self;
}

- (void)addCompletion:(void (^)(NSArray *))completion {
    if (completion) [self.completions addObject:[completion copy]];
}

- (void)start {
    self.polls = 0;
    UIWindow *window = nil;
    for (UIWindow *candidate in ApolloAllWindows()) {
        if (candidate.isKeyWindow) { window = candidate; break; }
    }
    if (!window) window = ApolloAllWindows().firstObject;
    if (!window) {
        [self finishWithItems:nil status:0 responseLength:0 reason:@"no app window"];
        return;
    }
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    // Keep this account's cookies isolated from other API-free accounts and
    // from any unrelated Reddit login left in WebKit's shared browser store.
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    NSString *hook = @"(function(){var f=window.fetch;if(!f)return;window.fetch=function(){var a=arguments,u=String(a[0]&&a[0].url||a[0]),match=/\\/svc\\/shreddit\\/[^/]+\\/emojis\\/USER_FLAIR/i.test(u);var p=f.apply(this,a);if(match){p.then(function(r){r.clone().text().then(function(t){try{var d=new DOMParser().parseFromString(t,'text/html'),items=Array.from(d.querySelectorAll('li[data-token][data-url]')).map(function(n){var name=n.getAttribute('data-token')||'',url=n.getAttribute('data-url')||'';if(name.charAt(0)===':')name=name.slice(1);if(name.charAt(name.length-1)===':')name=name.slice(0,-1);return{name:name,url:url};}).filter(function(x){return x.name&&x.url;});window.__apolloEmojiCatalog={state:'done',status:r.status,length:t.length,items:items};}catch(e){window.__apolloEmojiCatalog={state:'error',error:String(e)};}}).catch(function(e){window.__apolloEmojiCatalog={state:'error',error:String(e)};});}).catch(function(e){window.__apolloEmojiCatalog={state:'error',error:String(e)};});}return p;};})();";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:hook injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
    [config.userContentController addUserScript:script];
    self.web = [[WKWebView alloc] initWithFrame:window.bounds configuration:config];
    self.web.navigationDelegate = self;
    self.web.alpha = 0.011;
    self.web.userInteractionEnabled = NO;
    self.web.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
    [window insertSubview:self.web atIndex:0];
    ApolloWebSessionEntry *session = ApolloActiveWebSession();
    NSArray<NSHTTPCookie *> *cookies = ApolloUserFlairCookiesFromHeader(session.cookieHeader);
    if (cookies.count == 0) {
        [self finishWithItems:nil status:0 responseLength:0 reason:@"active web session has no cookies"];
        return;
    }
    NSString *encoded = [self.subreddit stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: self.subreddit;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        [NSString stringWithFormat:@"https://sh.reddit.com/r/%@/", encoded]]];
    [request setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    dispatch_group_t cookieGroup = dispatch_group_create();
    WKHTTPCookieStore *cookieStore = config.websiteDataStore.httpCookieStore;
    for (NSHTTPCookie *cookie in cookies) {
        dispatch_group_enter(cookieGroup);
        [cookieStore setCookie:cookie completionHandler:^{ dispatch_group_leave(cookieGroup); }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(cookieGroup, dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.finished) return;
        [self.web loadRequest:request];
        [self pollAfter:2.5];
    });
}

- (void)pollAfter:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf poll]; });
}

- (void)poll {
    if (!self.web || self.finished) return;
    self.polls++;
    NSString *encoded = [self.subreddit stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: self.subreddit;
    NSString *js = [NSString stringWithFormat:@"(function(){if(window.__apolloEmojiCatalog)return JSON.stringify(window.__apolloEmojiCatalog);var edit=document.querySelector('button[aria-label=\"Edit user flair\"]');if(edit&&!window.__apolloDirectEmojiRequest){window.__apolloDirectEmojiRequest=true;fetch('/svc/shreddit/%@/emojis/USER_FLAIR');}return JSON.stringify({state:'waiting',foundEdit:!!edit});})()", encoded];
    __weak typeof(self) weakSelf = self;
    [self.web evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || self.finished) return;
        NSDictionary *payload = nil;
        if ([result isKindOfClass:[NSString class]]) {
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if ([json isKindOfClass:[NSDictionary class]]) payload = json;
        }
        NSString *state = [payload[@"state"] isKindOfClass:[NSString class]] ? payload[@"state"] : @"";
        if ([state isEqualToString:@"done"]) {
            NSArray *items = [payload[@"items"] isKindOfClass:[NSArray class]] ? payload[@"items"] : @[];
            [self finishWithItems:items
                           status:[payload[@"status"] integerValue]
                   responseLength:[payload[@"length"] unsignedIntegerValue]
                           reason:nil];
            return;
        }
        if ([state isEqualToString:@"error"]) {
            [self finishWithItems:nil status:0 responseLength:0
                           reason:[payload[@"error"] isKindOfClass:[NSString class]] ? payload[@"error"] : @"web response error"];
            return;
        }
        if (self.polls >= 12) {
            NSString *reason = error.localizedDescription ?: ([payload[@"foundEdit"] boolValue]
                ? @"emoji response timed out" : @"flair editor button was not found");
            [self finishWithItems:nil status:0 responseLength:0 reason:reason];
            return;
        }
        [self pollAfter:1.5];
    }];
}

- (void)finishWithItems:(NSArray *)items status:(NSInteger)status
          responseLength:(NSUInteger)responseLength reason:(NSString *)reason {
    if (self.finished) return;
    self.finished = YES;

    BOOL validResponse = (status == 200 && [items isKindOfClass:[NSArray class]]);
    NSMutableDictionary<NSString *, NSString *> *uniqueURLs = [NSMutableDictionary dictionary];
    if (validResponse) {
        for (id raw in items) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = [raw[@"name"] isKindOfClass:[NSString class]] ? raw[@"name"] : nil;
            NSString *url = [raw[@"url"] isKindOfClass:[NSString class]] ? raw[@"url"] : nil;
            if (name.length > 0 && url.length > 0) uniqueURLs[name] = url;
        }
    }
    NSMutableArray *emojis = [NSMutableArray arrayWithCapacity:uniqueURLs.count];
    for (NSString *name in [[uniqueURLs allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        [emojis addObject:@{ @"name": name, @"url": uniqueURLs[name] }];
    }
    NSArray *result = validResponse ? emojis : self.fallback;
    if (validResponse) {
        @synchronized (ApolloUserFlairEmojiListCache()) {
            ApolloUserFlairEmojiListCache()[self.cacheKey] = emojis;
            [ApolloUserFlairPartialEmojiCacheKeys() removeObject:self.cacheKey];
        }
    }

    ApolloLog(@"[UserFlair][Web] emoji catalog r/%@ HTTP %ld bytes=%lu choices=%lu fallback=%@ reason=%@",
              self.subreddit, (long)status, (unsigned long)responseLength,
              (unsigned long)result.count, validResponse ? @"no" : @"yes", reason ?: @"none");

    self.web.navigationDelegate = nil;
    [self.web stopLoading];
    [self.web removeFromSuperview];
    self.web = nil;
    NSMutableDictionary *fetches = ApolloUserFlairWebEmojiFetches();
    @synchronized (fetches) {
        if (fetches[self.cacheKey] == self) [fetches removeObjectForKey:self.cacheKey];
    }
    NSArray *callbacks = [self.completions copy];
    [self.completions removeAllObjects];
    for (void (^callback)(NSArray *) in callbacks) callback(result ?: @[]);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithItems:nil status:0 responseLength:0 reason:error.localizedDescription];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self finishWithItems:nil status:0 responseLength:0 reason:@"web content process terminated"];
}
@end

static NSMutableDictionary<NSString *, id> *ApolloUserFlairWebEmojiFetches(void) {
    static NSMutableDictionary *fetches;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fetches = [NSMutableDictionary dictionary]; });
    return fetches;
}

static void ApolloUserFlairFetchEmojisViaWeb(NSString *subreddit, NSArray *fallback,
                                              void (^completion)(NSArray *emojis)) {
    dispatch_block_t start = ^{
        NSString *key = subreddit.lowercaseString;
        NSMutableDictionary *fetches = ApolloUserFlairWebEmojiFetches();
        ApolloUserFlairWebEmojiFetch *fetch;
        @synchronized (fetches) { fetch = fetches[key]; }
        if (fetch) {
            [fetch addCompletion:completion];
            return;
        }
        fetch = [[ApolloUserFlairWebEmojiFetch alloc] initWithSubreddit:subreddit fallback:fallback];
        [fetch addCompletion:completion];
        @synchronized (fetches) { fetches[key] = fetch; }
        [fetch start];
    };
    if ([NSThread isMainThread]) start();
    else dispatch_async(dispatch_get_main_queue(), start);
}

static void ApolloUserFlairFetchEmojis(NSString *subreddit, void (^completion)(NSArray *emojis)) {
    NSString *key = subreddit.lowercaseString;
    if (key.length == 0) { if (completion) completion(@[]); return; }
    NSArray *cached;
    BOOL cachedIsPartial = NO;
    @synchronized (ApolloUserFlairEmojiListCache()) {
        cached = ApolloUserFlairEmojiListCache()[key];
        cachedIsPartial = [ApolloUserFlairPartialEmojiCacheKeys() containsObject:key];
    }
    if (cached && !cachedIsPartial) { if (completion) completion(cached); return; }

    // A process-global captured bearer can belong to a different OAuth account.
    // Never use it while the active account is the API-key-free web-session
    // account; use that account's signed-in website session instead.
    if (ApolloWebJSONHasUsableSession()) {
        ApolloUserFlairFetchEmojisViaWeb(subreddit, cached, completion);
        return;
    }
    NSString *token = [sLatestRedditBearerToken copy];
    if (token.length == 0) { if (completion) completion(cached ?: @[]); return; }
    NSString *enc = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    NSString *urlStr = [NSString stringWithFormat:@"https://oauth.reddit.com/api/v1/%@/emojis/all?raw_json=1", enc];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    if (token.length) [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:(sUserAgent.length > 0 ? sUserAgent : @"Apollo iOS") forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 20;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSMutableArray *emojis = [NSMutableArray array];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        BOOL validCatalogue = [json isKindOfClass:[NSDictionary class]];
        if (validCatalogue) {
            for (NSString *group in (NSDictionary *)json) {
                id g = ((NSDictionary *)json)[group];
                if (![g isKindOfClass:[NSDictionary class]]) continue;
                for (NSString *name in (NSDictionary *)g) {
                    id meta = ((NSDictionary *)g)[name];
                    if (![meta isKindOfClass:[NSDictionary class]]) continue;
                    if (![meta[@"user_flair_allowed"] boolValue]) continue;
                    NSString *url = meta[@"url"];
                    if (![url isKindOfClass:[NSString class]] || url.length == 0) continue;
                    [emojis addObject:@{ @"name": name, @"url": url }];
                }
            }
        }
        [emojis sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
        }];
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        ApolloLog(@"[UserFlair] fetched %lu user-flair emoji for r/%@ HTTP %ld keyless=%@ valid=%@ error=%@",
                  (unsigned long)emojis.count, subreddit, (long)http.statusCode,
                  @"no", validCatalogue ? @"yes" : @"no", error ? @"yes" : @"no");
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *result = emojis;
            @synchronized (ApolloUserFlairEmojiListCache()) {
                if (validCatalogue && http.statusCode == 200) {
                    ApolloUserFlairEmojiListCache()[key] = emojis;
                    [ApolloUserFlairPartialEmojiCacheKeys() removeObject:key];
                } else if (cached.count > 0) {
                    // Preserve template-embedded icons if Reddit temporarily
                    // rejects or fails the complete catalogue request.
                    result = cached;
                }
            }
            if (completion) completion(result);
        });
    }] resume];
}

static NSCache<NSString *, UIImage *> *ApolloUserFlairEmojiImageCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 800; });
    return cache;
}

static void ApolloUserFlairLoadEmojiImage(NSString *urlStr, void (^completion)(UIImage *image)) {
    if (urlStr.length == 0) { if (completion) completion(nil); return; }
    UIImage *cached = [ApolloUserFlairEmojiImageCache() objectForKey:urlStr];
    if (cached) { if (completion) completion(cached); return; }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (completion) completion(nil); return; }
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
        if (image) [ApolloUserFlairEmojiImageCache() setObject:image forKey:urlStr];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(image); });
    }] resume];
}

#pragma mark Per-template flair limits (max emojis / allowable content)

// Reddit stores a per-flair-template emoji cap (max_emojis) and a content restriction
// (allowable_content: "all" | "emoji" | "text"). The kApolloUserFlairMaxEmojis (10)
// above is only Reddit's DEFAULT — a community can allow fewer (e.g. r/apolloreborn's
// editable flair caps at 3, r/soccer's at 1) or zero (when its flair is text-only). The
// flairselector `choices` Apollo already fetches DON'T carry these fields; only the
// GET /r/<sub>/api/user_flair_v2 template list does (keyed by the same template ids),
// so we fetch that and show the real cap instead of a flat "/10".

// subreddit(lowercased) -> @{ templateID -> @{ @"maxEmojis": NSNumber, @"allowableContent": NSString } }
// An empty dict is a valid cached value meaning "asked, nothing usable" (don't refetch).
static NSMutableDictionary<NSString *, NSDictionary *> *ApolloUserFlairTemplateLimitsCache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

// Parse a user_flair_v2 template array into templateID -> {maxEmojis, allowableContent}.
// Each element: { "id", "max_emojis", "allowable_content", ... }; the ids match
// flairselector's flair_template_id, so the editor can look up its own template.
static NSDictionary *ApolloUserFlairParseTemplateLimits(id templates) {
    if (![templates isKindOfClass:[NSArray class]]) return nil;
    NSMutableDictionary *byTemplate = [NSMutableDictionary dictionary];
    for (id obj in (NSArray *)templates) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *t = obj;
        NSString *tid = t[@"id"];
        if (![tid isKindOfClass:[NSString class]] || tid.length == 0) continue;
        NSMutableDictionary *limits = [NSMutableDictionary dictionary];
        id maxE = t[@"max_emojis"];
        if ([maxE isKindOfClass:[NSNumber class]]) limits[@"maxEmojis"] = maxE;
        id ac = t[@"allowable_content"];
        if ([ac isKindOfClass:[NSString class]] && ((NSString *)ac).length) limits[@"allowableContent"] = ac;
        if (limits.count) byTemplate[tid] = limits;
    }
    return byTemplate.count ? byTemplate : nil;
}

static void ApolloUserFlairStoreTemplateLimits(NSString *subreddit, NSDictionary *byTemplate) {
    NSString *key = subreddit.lowercaseString;
    if (key.length == 0 || !byTemplate) return;
    @synchronized (ApolloUserFlairTemplateLimitsCache()) { ApolloUserFlairTemplateLimitsCache()[key] = byTemplate; }
}

static BOOL ApolloUserFlairHasTemplateLimits(NSString *subreddit) {
    NSString *key = subreddit.lowercaseString;
    if (key.length == 0) return NO;
    @synchronized (ApolloUserFlairTemplateLimitsCache()) { return ApolloUserFlairTemplateLimitsCache()[key] != nil; }
}

// The emoji cap to show for a template, defaulting to kApolloUserFlairMaxEmojis when we
// have no data yet. A "text"-only flair allows no emoji at all, so report 0 there.
static NSUInteger ApolloUserFlairMaxEmojisForTemplate(NSString *subreddit, NSString *templateID) {
    NSString *key = subreddit.lowercaseString;
    NSDictionary *byTemplate;
    @synchronized (ApolloUserFlairTemplateLimitsCache()) { byTemplate = ApolloUserFlairTemplateLimitsCache()[key]; }
    id raw = templateID.length ? byTemplate[templateID] : nil;
    NSDictionary *limits = [raw isKindOfClass:[NSDictionary class]] ? raw : nil;
    if (!limits) return kApolloUserFlairMaxEmojis;
    if ([limits[@"allowableContent"] isEqualToString:@"text"]) return 0;
    id m = limits[@"maxEmojis"];
    if ([m isKindOfClass:[NSNumber class]]) return [m unsignedIntegerValue];
    return kApolloUserFlairMaxEmojis;
}

// Ensure the per-template limits for a subreddit are cached, fetching user_flair_v2 once
// if needed. Lazy: the editor calls this on open. `completion` always runs on the main
// queue. The result is cached (including an empty marker for 403/none) so reopening the
// editor doesn't refetch; a pure network failure is left uncached so it can retry.
static void ApolloUserFlairEnsureTemplateLimits(NSString *subreddit, void (^completion)(void)) {
    void (^done)(void) = ^{
        if (!completion) return;
        if ([NSThread isMainThread]) completion();
        else dispatch_async(dispatch_get_main_queue(), completion);
    };
    if (ApolloUserFlairHasTemplateLimits(subreddit)) { done(); return; }
    NSString *token = [sLatestRedditBearerToken copy];
    NSString *enc = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    if (token.length == 0 || enc.length == 0) { done(); return; }
    NSString *urlStr = [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/user_flair_v2?raw_json=1", enc];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"Apollo iOS" forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 20;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *byTemplate = ApolloUserFlairParseTemplateLimits(json);
        if (byTemplate.count) {
            ApolloUserFlairStoreTemplateLimits(subreddit, byTemplate);
            ApolloLog(@"[UserFlair] template emoji limits r/%@: %lu templates", subreddit, (unsigned long)byTemplate.count);
        } else if (resp) {
            ApolloUserFlairStoreTemplateLimits(subreddit, @{}); // definitive: no usable limits
        }
        done();
    }] resume];
}

#pragma mark Emoji grid cell

@interface ApolloUserFlairEmojiCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, copy) NSString *urlKey;
@end

@implementation ApolloUserFlairEmojiCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _imageView = [[UIImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_imageView];
    }
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
    self.urlKey = nil;
}
@end

#pragma mark Flair editor view controller

@interface ApolloUserFlairEditorViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate, UITextFieldDelegate>
@property (nonatomic, strong) ApolloUserFlairEditSession *session;
@property (nonatomic, copy) NSString *subreddit;
@property (nonatomic, strong) NSArray *allEmojis;       // [{name,url}]
@property (nonatomic, strong) NSArray *filteredEmojis;
@property (nonatomic, strong) NSDictionary *emojiURLByName;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIBarButtonItem *saveItem;
@property (nonatomic, assign) BOOL didFinish;
@property (nonatomic, assign) NSUInteger maxEmojis;     // this template's emoji cap (0 = text-only)
@end

@implementation ApolloUserFlairEditorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Set Flair";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Seed from cache (warm if this sub's editor was opened before); loadFlairLimits
    // fetches and refreshes it otherwise. Defaults to Reddit's cap of 10 until known.
    self.maxEmojis = ApolloUserFlairMaxEmojisForTemplate(self.subreddit, self.session.templateID);

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelTapped)];
    self.saveItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveTapped)];
    self.navigationItem.rightBarButtonItem = self.saveItem;

    // Preview (rendered flair with inline emoji)
    UILabel *previewTitle = [UILabel new];
    previewTitle.text = @"Preview";
    previewTitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    previewTitle.textColor = [UIColor secondaryLabelColor];

    self.previewLabel = [UILabel new];
    self.previewLabel.numberOfLines = 2;
    self.previewLabel.font = [UIFont systemFontOfSize:15];
    self.previewLabel.textColor = [UIColor labelColor];

    // Text field
    self.textField = [UITextField new];
    self.textField.placeholder = @"Flair text";
    self.textField.borderStyle = UITextBorderStyleRoundedRect;
    self.textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.textField.autocorrectionType = UITextAutocorrectionTypeDefault;
    self.textField.returnKeyType = UIReturnKeyDone;
    self.textField.delegate = self;
    NSString *initial = self.session.initialText ?: @"";
    self.textField.text = initial;
    [self.textField addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];

    self.counterLabel = [UILabel new];
    self.counterLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.counterLabel.textColor = [UIColor secondaryLabelColor];
    self.counterLabel.textAlignment = NSTextAlignmentRight;

    // Search bar (filter emoji)
    self.searchBar = [UISearchBar new];
    self.searchBar.placeholder = @"Search emoji";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.hidden = YES; // shown once emoji arrive

    // Emoji grid
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(44, 44);
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsMake(4, 12, 12, 12);
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[ApolloUserFlairEmojiCell class] forCellWithReuseIdentifier:@"emoji"];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[previewTitle, self.previewLabel, self.textField, self.counterLabel, self.searchBar]];
    top.axis = UILayoutConstraintAxisVertical;
    top.spacing = 6;
    [top setCustomSpacing:2 afterView:previewTitle];
    [top setCustomSpacing:14 afterView:self.previewLabel];
    [top setCustomSpacing:2 afterView:self.textField];

    top.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:top];
    [self.view addSubview:self.collectionView];
    [self.view addSubview:self.spinner];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [top.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [top.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [top.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.collectionView.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:4],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.collectionView.centerXAnchor],
        [self.spinner.topAnchor constraintEqualToAnchor:self.collectionView.topAnchor constant:24],
    ]];

    [self updateCounterAndPreview];
    [self refreshEmojiAvailability];
    [self loadEmojis];
    [self loadFlairLimits];
}

- (void)loadEmojis {
    [self.spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    ApolloUserFlairFetchEmojis(self.subreddit, ^(NSArray *emojis) {
        typeof(self) self = weakSelf;
        if (!self) return;
        [self.spinner stopAnimating];
        self.allEmojis = emojis;
        self.filteredEmojis = emojis;
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSDictionary *e in emojis) map[e[@"name"]] = e[@"url"];
        self.emojiURLByName = map;
        [self refreshEmojiAvailability];
        [self.collectionView reloadData];
        [self updateCounterAndPreview]; // preview can now resolve tokens to images
    });
}

// Fetch this template's real emoji cap (user_flair_v2), then update the counter + emoji
// UI. Cached per subreddit, so it's a no-op after the first open of this sub's editor.
- (void)loadFlairLimits {
    __weak typeof(self) weakSelf = self;
    ApolloUserFlairEnsureTemplateLimits(self.subreddit, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        self.maxEmojis = ApolloUserFlairMaxEmojisForTemplate(self.subreddit, self.session.templateID);
        [self refreshEmojiAvailability];
        [self updateCounterAndPreview];
    });
}

// Hide the emoji picker entirely for text-only flair (cap 0); otherwise show it once
// emoji have arrived, keeping the search bar only when the grid is long enough to need it.
- (void)refreshEmojiAvailability {
    BOOL emojiAllowed = (self.maxEmojis > 0);
    self.collectionView.hidden = !emojiAllowed;
    self.searchBar.hidden = !emojiAllowed || (self.allEmojis.count <= 24);
    if (!emojiAllowed) [self.spinner stopAnimating];
}

#pragma mark counter + preview

// Counts recognised :emoji: tokens, and reports the length of the remaining text
// (characters not part of a recognised token). Unknown :x: tokens count as text.
- (NSUInteger)emojiCountInText:(NSString *)text textLength:(NSUInteger *)outTextLen {
    NSUInteger emojiCount = 0;
    NSMutableIndexSet *emojiChars = [NSMutableIndexSet indexSet];
    NSArray *matches = [ApolloUserFlairEmojiTokenRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *m in matches) {
        NSString *tok = [text substringWithRange:m.range];
        NSString *name = [tok substringWithRange:NSMakeRange(1, tok.length - 2)];
        if (self.emojiURLByName[name]) {
            emojiCount++;
            [emojiChars addIndexesInRange:m.range];
        }
    }
    if (outTextLen) *outTextLen = text.length - emojiChars.count;
    return emojiCount;
}

- (void)updateCounterAndPreview {
    NSString *text = self.textField.text ?: @"";
    NSUInteger textLen = 0;
    NSUInteger emojiCount = [self emojiCountInText:text textLength:&textLen];
    BOOL overText = textLen > kApolloUserFlairMaxLength;
    BOOL overEmoji = emojiCount > self.maxEmojis;
    if (self.maxEmojis == 0) {
        // Text-only flair: report just the character count, and flag any emoji as over.
        self.counterLabel.text = [NSString stringWithFormat:@"%lu/%lu chars · no emoji",
            (unsigned long)textLen, (unsigned long)kApolloUserFlairMaxLength];
    } else {
        self.counterLabel.text = [NSString stringWithFormat:@"%lu/%lu chars · %lu/%lu emoji",
            (unsigned long)textLen, (unsigned long)kApolloUserFlairMaxLength,
            (unsigned long)emojiCount, (unsigned long)self.maxEmojis];
    }
    self.counterLabel.textColor = (overText || overEmoji) ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
    self.saveItem.enabled = !overText && !overEmoji;
    [self refreshPreview];
}

- (void)refreshPreview {
    NSString *text = self.textField.text ?: @"";
    if (text.length == 0) {
        self.previewLabel.attributedText = nil;
        self.previewLabel.text = @"(empty)";
        self.previewLabel.textColor = [UIColor tertiaryLabelColor];
        return;
    }
    self.previewLabel.textColor = [UIColor labelColor];
    self.previewLabel.attributedText = [self attributedFlairForText:text];
}

// Build an attributed string, replacing recognised :name: tokens with inline emoji
// images (loaded async; refreshes the preview when an image arrives).
- (NSAttributedString *)attributedFlairForText:(NSString *)text {
    NSMutableAttributedString *out = [[NSMutableAttributedString alloc] init];
    NSDictionary *baseAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:15], NSForegroundColorAttributeName: [UIColor labelColor] };
    NSArray *matches = [ApolloUserFlairEmojiTokenRegex() matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSUInteger cursor = 0;
    __weak typeof(self) weakSelf = self;
    for (NSTextCheckingResult *m in matches) {
        NSString *name = [[text substringWithRange:m.range] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
        NSString *url = self.emojiURLByName[name];
        if (!url) continue; // leave unknown tokens as literal text (handled below)
        if (m.range.location > cursor) {
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringWithRange:NSMakeRange(cursor, m.range.location - cursor)] attributes:baseAttrs]];
        }
        NSTextAttachment *att = [NSTextAttachment new];
        att.bounds = CGRectMake(0, -3, 18, 18);
        UIImage *img = [ApolloUserFlairEmojiImageCache() objectForKey:url];
        if (img) {
            att.image = img;
        } else {
            ApolloUserFlairLoadEmojiImage(url, ^(UIImage *image) {
                typeof(self) self = weakSelf;
                if (self && image) [self refreshPreview];
            });
        }
        [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
        cursor = m.range.location + m.range.length;
    }
    if (cursor < text.length) {
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:[text substringFromIndex:cursor] attributes:baseAttrs]];
    }
    return out;
}

- (void)textChanged { [self updateCounterAndPreview]; }

#pragma mark actions

- (void)insertEmojiToken:(NSString *)name {
    NSUInteger textLen = 0;
    NSUInteger emojiCount = [self emojiCountInText:(self.textField.text ?: @"") textLength:&textLen];
    if (emojiCount >= self.maxEmojis) {
        [self flashCounter];
        return;
    }
    NSString *token = [NSString stringWithFormat:@":%@:", name];
    UITextField *tf = self.textField;
    UITextRange *range = tf.selectedTextRange;
    if (!range) range = [tf textRangeFromPosition:tf.endOfDocument toPosition:tf.endOfDocument];
    [tf replaceRange:range withText:token];
    [self updateCounterAndPreview];
}

- (void)flashCounter {
    self.counterLabel.textColor = [UIColor systemRedColor];
    UISelectionFeedbackGenerator *fb = [UISelectionFeedbackGenerator new];
    [fb selectionChanged];
}

- (void)cancelTapped { [self finishAndDismiss]; }

- (void)saveTapped {
    NSString *text = self.textField.text ?: @"";
    ApolloUserFlairEditSession *session = self.session;
    ApolloLog(@"[UserFlair] save tapped subreddit=%@ templateID=%@ textLen=%lu",
        session.subredditName ?: @"(nil)", session.templateID ?: @"(nil)", (unsigned long)text.length);
    self.didFinish = YES;
    UIViewController *presenter = ApolloUserFlairPresenterForController(session.selectorAdapter.controller);
    UIViewController *flairController = session.selectorAdapter.controller;
    [self dismissViewControllerAnimated:YES completion:^{
        if (flairController) objc_setAssociatedObject(flairController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (!ApolloUserFlairCommitEditedSession(session, text)) {
            ApolloUserFlairShowError(presenter, @"Apollo's native flair update action was unavailable.");
        }
    }];
}

- (void)finishAndDismiss {
    self.didFinish = YES;
    UIViewController *flairController = self.session.selectorAdapter.controller;
    [self dismissViewControllerAnimated:YES completion:^{
        if (flairController) objc_setAssociatedObject(flairController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Catch interactive (swipe-down) dismissal so the selector can present again later.
    if (!self.didFinish) {
        UIViewController *flairController = self.session.selectorAdapter.controller;
        if (flairController) objc_setAssociatedObject(flairController, &kApolloUserFlairEditorPresentedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

#pragma mark text field

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return NO; }

#pragma mark search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredEmojis = self.allEmojis;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, NSDictionary *bindings) {
            return [e[@"name"] rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.filteredEmojis = [self.allEmojis filteredArrayUsingPredicate:p];
    }
    [self.collectionView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredEmojis.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ApolloUserFlairEmojiCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"emoji" forIndexPath:indexPath];
    if (indexPath.item >= (NSInteger)self.filteredEmojis.count) return cell;
    NSDictionary *e = self.filteredEmojis[indexPath.item];
    NSString *url = e[@"url"];
    cell.urlKey = url;
    UIImage *cached = [ApolloUserFlairEmojiImageCache() objectForKey:url];
    if (cached) {
        cell.imageView.image = cached;
    } else {
        // Capture the cell weakly so an in-flight download for a since-recycled cell
        // doesn't keep it alive while scrolling thousands of emoji; the urlKey guard
        // still prevents a stale image from landing on a reused cell.
        __weak ApolloUserFlairEmojiCell *weakCell = cell;
        ApolloUserFlairLoadEmojiImage(url, ^(UIImage *image) {
            ApolloUserFlairEmojiCell *strongCell = weakCell;
            if (image && strongCell && [strongCell.urlKey isEqualToString:url]) strongCell.imageView.image = image;
        });
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    if (indexPath.item >= (NSInteger)self.filteredEmojis.count) return;
    NSDictionary *e = self.filteredEmojis[indexPath.item];
    [self insertEmojiToken:e[@"name"]];
}

@end

static void ApolloUserFlairPresentEditor(ApolloUserFlairEditSession *session) {
    UIViewController *controller = session.selectorAdapter.controller;
    if ([objc_getAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey) boolValue]) return;
    objc_setAssociatedObject(controller, &kApolloUserFlairEditorPresentedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloUserFlairEditorViewController *editor = [ApolloUserFlairEditorViewController new];
    editor.session = session;
    editor.subreddit = session.subredditName;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    ApolloLog(@"[UserFlair] presenting flair editor subreddit=%@ templateID=%@ initialLen=%lu",
        session.subredditName ?: @"(nil)",
        session.templateID ?: @"(nil)",
        (unsigned long)(session.initialText.length));
    [[session.selectorAdapter presenter] presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Row Option Capture

static NSNumber *ApolloUserFlairRowKey(NSInteger section, NSInteger row) {
    return @((((long long)section) << 32) | ((long long)row & 0xffffffffLL));
}

static NSMutableDictionary<NSNumber *, id> *ApolloUserFlairCapturedOptions(UIViewController *controller, BOOL create) {
    if (!controller) return nil;
    @synchronized (controller) {
        NSMutableDictionary *options = objc_getAssociatedObject(controller, &kApolloUserFlairCapturedOptionsKey);
        if (!options && create) {
            options = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(controller, &kApolloUserFlairCapturedOptionsKey, options, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return options;
    }
}

static void ApolloUserFlairCaptureOptionIfNeeded(id option) {
    UIViewController *controller = tApolloUserFlairCaptureController;
    if (!controller || tApolloUserFlairCaptureSection == NSNotFound || tApolloUserFlairCaptureRow == NSNotFound || !option) return;

    NSNumber *key = ApolloUserFlairRowKey(tApolloUserFlairCaptureSection, tApolloUserFlairCaptureRow);
    @synchronized (controller) {
        NSMutableDictionary *options = ApolloUserFlairCapturedOptions(controller, YES);
        options[key] = option;
    }
}

static id ApolloUserFlairCapturedOptionAtIndexPath(UIViewController *controller, NSIndexPath *indexPath) {
    if (!controller || !indexPath) return nil;
    NSNumber *key = ApolloUserFlairRowKey(indexPath.section, indexPath.row);
    @synchronized (controller) {
        return ApolloUserFlairCapturedOptions(controller, NO)[key];
    }
}

static BOOL ApolloUserFlairMaybePresentEditorForOption(UIViewController *controller, id option, id source, NSString *reason) {
    if (!controller) return NO;
    ApolloUserFlairEditSession *session = ApolloUserFlairBuildEditSession(controller, option, source, reason);
    if (!session) return NO;
    ApolloUserFlairPresentEditor(session);
    return YES;
}

#pragma mark - Old Flair System Collapse
//
// Subreddits still on Reddit's "old" CSS-class flair system expose their flair
// templates with NO text and NO emoji — only an editable flag and a UUID. On
// mobile they are indistinguishable, so Apollo renders a wall of identical blank
// rows (r/nintendo returns 346) and shows a scary "Apollo is unable to interact"
// alert. We collapse every empty-but-editable template into a single, labelled
// "Set custom flair…" row that opens the text editor, and suppress the alert.
// Labelled templates (text or emoji) and ordinary (new-system) subreddits are
// left exactly as Apollo presents them.

// Returns the controller's flairOptions as an NSArray. The Swift
// `[RDKFlairOption]?` ivar bridges to a _ContiguousArrayStorage which responds
// to NSArray selectors (verified at runtime); nil/empty read back safely.
static NSArray *ApolloUserFlairControllerOptions(UIViewController *controller) {
    id raw = ApolloUserFlairRawObjectIvar(controller, @"flairOptions");
    if ([raw isKindOfClass:[NSArray class]]) return (NSArray *)raw;
    return nil;
}

// Some subreddits build "blank" flairs out of invisible characters (e.g. r/dbz uses
// U+2800 BRAILLE PATTERN BLANK). Treat text made up only of whitespace / invisibles
// as empty so those dead templates don't count as real flairs.
static BOOL ApolloUserFlairStringIsBlank(NSString *s) {
    if (s.length == 0) return YES;
    static NSCharacterSet *blanks = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *m = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
        // braille blank, ZWSP/ZWNJ/ZWJ, word joiner, BOM, hangul fillers, NBSP, MVS
        [m addCharactersInString:@"⠀​‌‍⁠﻿ㅤᅟ ᠎"];
        blanks = [m copy];
    });
    return [s stringByTrimmingCharactersInSet:blanks].length == 0;
}

// "Labelled" = something the user can actually tell apart: real (visible) text, an
// emoji label, or an image. A flair piece that exists but is visually empty (no
// real text, no emoji, no image — e.g. r/dbz's blank-character templates) does NOT
// count, otherwise we'd keep a wall of blank pills instead of collapsing them.
static BOOL ApolloUserFlairOptionIsLabeled(id option) {
    NSString *text = ApolloUserFlairOptionText(option); // covers text + emoji labels
    if (!ApolloUserFlairStringIsBlank(text)) return YES;
    NSArray *flairs = ApolloUserFlairObjectArray(option, @[@"flairs"]);
    for (id f in flairs) {
        if (ApolloUserFlairObjectString(f, @[@"imageURL"]).length > 0) return YES;
    }
    return NO;
}

// A blank-but-editable template: nothing to show, but you can type into it. These
// get the "Set custom flair…" placeholder so it's obvious the row is tappable —
// whether or not the subreddit's templates were collapsed.
static BOOL ApolloUserFlairOptionIsBlankEditable(id option) {
    if (!option || ApolloUserFlairOptionIsLabeled(option)) return NO;
    BOOL editableKnown = NO;
    BOOL editable = ApolloUserFlairOptionIsEditable(option, &editableKnown);
    return editableKnown && editable;
}

@interface ApolloUserFlairCollapseModel : NSObject
@property (nonatomic) BOOL active;
// displayRow -> real index into flairOptions
@property (nonatomic, strong) NSArray<NSNumber *> *realRows;
// real index of the single representative collapsed row (or NSNotFound)
@property (nonatomic) NSInteger customRealRow;
// YES = the representative row is an "no usable flairs" notice (empties are all
// non-editable); NO = it's a tappable "Set custom flair…" / current-flair row.
@property (nonatomic) BOOL infoMode;
// identity of the flairOptions array this model was computed from
@property (nonatomic) const void *sourcePtr;
@end

@implementation ApolloUserFlairCollapseModel
@end

static ApolloUserFlairCollapseModel *ApolloUserFlairBuildCollapseModel(NSArray *options) {
    ApolloUserFlairCollapseModel *model = [ApolloUserFlairCollapseModel new];
    model.customRealRow = NSNotFound;
    model.active = NO;

    NSMutableArray<NSNumber *> *labeledRows = [NSMutableArray array];
    NSInteger firstEmptyEditable = NSNotFound;
    NSInteger firstEmptyNonEditable = NSNotFound;
    NSInteger emptyEditableCount = 0;
    NSInteger emptyNonEditableCount = 0;

    for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
        id option = options[i];
        if (ApolloUserFlairOptionIsLabeled(option)) {
            [labeledRows addObject:@(i)];
            continue;
        }
        BOOL editableKnown = NO;
        BOOL editable = ApolloUserFlairOptionIsEditable(option, &editableKnown);
        if (editableKnown && editable) {
            emptyEditableCount++;
            if (firstEmptyEditable == NSNotFound) firstEmptyEditable = i;
        } else {
            // Empty AND non-editable: no text, can't be typed into — useless on mobile
            // (and on the web). Some subs have a whole wall of these.
            emptyNonEditableCount++;
            if (firstEmptyNonEditable == NSNotFound) firstEmptyNonEditable = i;
        }
    }

    // Collapse only when the subreddit is ENTIRELY empty templates (>=2 of them) and
    // has no real flairs. Then the whole list becomes a single representative row at
    // real index 0 — an identity mapping, which keeps the table-row remapping trivial
    // and safe. Subreddits that mix real flairs with a few blanks are left native
    // (their blank editable rows still get the "Set custom flair…" placeholder via the
    // per-row path; a handful of dead rows is fine and avoids fragile remapping).
    if (labeledRows.count == 0 && emptyEditableCount + emptyNonEditableCount >= 2) {
        if (emptyEditableCount >= 1) {
            model.realRows = @[@(firstEmptyEditable)];
            model.customRealRow = firstEmptyEditable;
            model.infoMode = NO;
        } else {
            model.realRows = @[@(firstEmptyNonEditable)];
            model.customRealRow = firstEmptyNonEditable;
            model.infoMode = YES;
        }
        model.active = YES;
    }
    return model;
}

static ApolloUserFlairCollapseModel *ApolloUserFlairCollapseModelFor(UIViewController *controller) {
    if (!controller) return nil;
    NSArray *options = ApolloUserFlairControllerOptions(controller);
    if (!options) return nil;

    ApolloUserFlairCollapseModel *cached = objc_getAssociatedObject(controller, &kApolloUserFlairCollapseModelKey);
    if (cached && cached.sourcePtr == (__bridge const void *)options) return cached;

    ApolloUserFlairCollapseModel *model;
    NSDictionary *cssByTemplate = objc_getAssociatedObject(controller, &kApolloUserFlairCssByTemplateKey);
    if ([cssByTemplate isKindOfClass:[NSDictionary class]] && cssByTemplate.count > 0) {
        // These are real old-reddit flairs (rendered via css_class sprites/names) —
        // show every one as its own row instead of collapsing to a "custom" row.
        model = [ApolloUserFlairCollapseModel new];
        model.customRealRow = NSNotFound;
        model.active = NO;
    } else {
        model = ApolloUserFlairBuildCollapseModel(options);
    }
    model.sourcePtr = (__bridge const void *)options;
    objc_setAssociatedObject(controller, &kApolloUserFlairCollapseModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (model.active) {
        ApolloLog(@"[UserFlair] old-flair collapse: %lu options -> %lu rows (rep index %ld, %@)",
            (unsigned long)options.count, (unsigned long)model.realRows.count, (long)model.customRealRow,
            model.infoMode ? @"no-usable-flairs notice" : @"custom flair row");
    }
    return model;
}

static id ApolloUserFlairMakeTextFlair(NSString *text) {
    Class flairClass = objc_getClass("RDKFlair");
    SEL initSEL = @selector(initWithRawText:);
    if (!flairClass || ![flairClass instancesRespondToSelector:initSEL]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)([flairClass alloc], initSEL, text ?: @"");
}

// An emoji piece must look exactly like Reddit's own: flairType "emoji", the bare
// emoji name in emojiLabel, the image URL, and a NIL text. Crucially `text` must be
// nil (not @"") — the native flair cell treats any non-nil text as a text run and
// renders it instead of loading the emoji image.
static id ApolloUserFlairMakeEmojiFlair(NSString *name, NSString *imageURL) {
    id flair = ApolloUserFlairMakeTextFlair(@"");
    if (!flair) return nil;
    NSURL *url = imageURL.length ? [NSURL URLWithString:imageURL] : nil;
    @try { [flair setValue:nil forKey:@"text"]; } @catch (__unused NSException *e) {}
    @try { [flair setValue:@"emoji" forKey:@"flairType"]; } @catch (__unused NSException *e) {}
    @try { if (name.length) [flair setValue:name forKey:@"emojiLabel"]; } @catch (__unused NSException *e) {}
    @try { if (url) [flair setValue:url forKey:@"imageURL"]; } @catch (__unused NSException *e) {}
    return flair;
}

// One reusable RDKFlair carrying the placeholder text, so a blank editable row
// renders through Apollo's normal flair cell layout instead of as a blank pill.
static NSArray *ApolloUserFlairPlaceholderFlairs(void) {
    static NSArray *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id flair = ApolloUserFlairMakeTextFlair(kApolloUserFlairCustomRowText);
        if (flair) cached = @[flair];
        else ApolloLog(@"[UserFlair] warning: could not build placeholder RDKFlair; custom-flair row will render unlabelled");
    });
    return cached;
}

// Build RDKFlair pieces from a flair_text string so the user's CURRENT flair
// renders in the row. Recognised :token: emoji become image pieces (using the
// subreddit's emoji map); everything else stays text. Unknown tokens remain as
// literal text. Returns nil if nothing could be built.
static NSArray *ApolloUserFlairPiecesFromFlairTextWithEmojiMap(NSString *flairText, NSDictionary<NSString *, NSString *> *map) {
    if (flairText.length == 0) return nil;

    NSMutableArray *pieces = [NSMutableArray array];
    NSArray *matches = [ApolloUserFlairEmojiTokenRegex() matchesInString:flairText options:0 range:NSMakeRange(0, flairText.length)];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *m in matches) {
        NSString *name = [[flairText substringWithRange:m.range] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
        NSString *url = map[name];
        if (!url) continue; // unknown token: leave it inside the surrounding text run
        if (m.range.location > cursor) {
            id t = ApolloUserFlairMakeTextFlair([flairText substringWithRange:NSMakeRange(cursor, m.range.location - cursor)]);
            if (t) [pieces addObject:t];
        }
        id e = ApolloUserFlairMakeEmojiFlair(name, url);
        if (e) [pieces addObject:e];
        cursor = m.range.location + m.range.length;
    }
    if (cursor < flairText.length) {
        id t = ApolloUserFlairMakeTextFlair([flairText substringFromIndex:cursor]);
        if (t) [pieces addObject:t];
    }
    return pieces.count ? pieces : nil;
}

static NSArray *ApolloUserFlairPiecesFromFlairText(NSString *flairText, NSString *subredditLowercase) {
    NSDictionary *map = nil;
    NSArray *emojis = nil;
    @synchronized (ApolloUserFlairEmojiListCache()) { emojis = ApolloUserFlairEmojiListCache()[subredditLowercase]; }
    if (emojis.count) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSDictionary *e in emojis) { if (e[@"name"] && e[@"url"]) m[e[@"name"]] = e[@"url"]; }
        map = m;
    }
    return ApolloUserFlairPiecesFromFlairTextWithEmojiMap(flairText, map);
}

#pragma mark - API-key-free old-Reddit flair bridge

// Reddit's OAuth-only GET /r/<sub>/api/user_flair_v2 is what Apollo normally
// uses to populate this screen. The cookie-authenticated web UI uses a different,
// older route instead: POST /api/flairselector with `r` and `name` in the form
// body. It returns HTML rather than JSON, but that HTML contains the same template
// UUID, editability, text, emoji URL, and CSS class data Apollo needs. Convert it
// into real RDKFlairOption/RDKFlair model objects, then invoke RedditKit's normal
// completion. This keeps Apollo's native selector, checkmarks, editor, and update
// flow rather than replacing the screen with a web view.

static NSString *ApolloUserFlairHTMLAttribute(NSString *tag, NSString *name) {
    if (tag.length == 0 || name.length == 0) return nil;
    NSString *escaped = [NSRegularExpression escapedPatternForString:name];
    NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*([\"'])(.*?)\\1", escaped];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *match = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (!match || match.numberOfRanges < 3) return nil;
    return [tag substringWithRange:[match rangeAtIndex:2]];
}

static NSString *ApolloUserFlairDecodeHTML(NSString *html) {
    if (html.length == 0) return @"";

    // This parser runs on the flair fetch's background queue. Foundation's HTML
    // attributed-string importer is WebKit-backed and main-thread-only, so keep
    // the old-Reddit attribute decoding small, deterministic, and thread-safe.
    static NSRegularExpression *entityRegex;
    static NSDictionary<NSString *, NSString *> *namedEntities;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entityRegex = [NSRegularExpression regularExpressionWithPattern:
            @"&(#(?:x[0-9a-f]+|[0-9]+)|amp|lt|gt|quot|apos);"
            options:NSRegularExpressionCaseInsensitive error:NULL];
        namedEntities = @{
            @"amp": @"&",
            @"lt": @"<",
            @"gt": @">",
            @"quot": @"\"",
            @"apos": @"'",
        };
    });

    NSArray<NSTextCheckingResult *> *matches = [entityRegex matchesInString:html options:0
        range:NSMakeRange(0, html.length)];
    if (matches.count == 0) return html;

    NSMutableString *decoded = [NSMutableString stringWithCapacity:html.length];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 2 || match.range.location < cursor) continue;
        [decoded appendString:[html substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]];

        NSString *token = [html substringWithRange:[match rangeAtIndex:1]];
        NSString *replacement = namedEntities[token.lowercaseString];
        if ([token hasPrefix:@"#"] && token.length > 1) {
            BOOL hexadecimal = token.length > 2 &&
                ([[token substringWithRange:NSMakeRange(1, 1)] caseInsensitiveCompare:@"x"] == NSOrderedSame);
            NSString *digits = [token substringFromIndex:hexadecimal ? 2 : 1];
            unsigned long long scalar = 0;
            if (hexadecimal) {
                NSScanner *scanner = [NSScanner scannerWithString:digits];
                [scanner scanHexLongLong:&scalar];
            } else {
                scalar = strtoull(digits.UTF8String, NULL, 10);
            }

            if (scalar > 0 && scalar <= 0x10FFFF && !(scalar >= 0xD800 && scalar <= 0xDFFF)) {
                if (scalar <= 0xFFFF) {
                    unichar character = (unichar)scalar;
                    replacement = [NSString stringWithCharacters:&character length:1];
                } else {
                    scalar -= 0x10000;
                    unichar characters[2] = {
                        (unichar)(0xD800 + (scalar >> 10)),
                        (unichar)(0xDC00 + (scalar & 0x3FF)),
                    };
                    replacement = [NSString stringWithCharacters:characters length:2];
                }
            }
        }

        [decoded appendString:replacement ?: [html substringWithRange:match.range]];
        cursor = NSMaxRange(match.range);
    }
    if (cursor < html.length) [decoded appendString:[html substringFromIndex:cursor]];
    return decoded;
}

static NSString *ApolloUserFlairCSSClassFromClassAttribute(NSString *classAttribute) {
    for (NSString *candidate in [classAttribute componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (![candidate hasPrefix:@"flair-"] || candidate.length <= @"flair-".length) continue;
        return [candidate substringFromIndex:@"flair-".length];
    }
    return nil;
}

static NSSet<NSString *> *ApolloUserFlairHTMLClassSet(NSString *classAttribute) {
    NSMutableSet *classes = [NSMutableSet set];
    for (NSString *candidate in [classAttribute componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (candidate.length > 0) [classes addObject:candidate];
    }
    return classes;
}

static NSMutableDictionary<NSString *, NSDictionary *> *ApolloUserFlairWebCurrentCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

static NSDictionary *ApolloUserFlairWebCurrentForSubreddit(NSString *subreddit) {
    if (subreddit.length == 0) return nil;
    NSDictionary *current = nil;
    @synchronized (ApolloUserFlairWebCurrentCache()) {
        current = ApolloUserFlairWebCurrentCache()[subreddit.lowercaseString];
    }
    return current;
}

// A signed-in old-Reddit subreddit page renders the user's applied flair in the
// sidebar immediately before their own `flairselectable` author link. Unlike the
// HTML returned by /api/flairselector, this also exposes the actual customized
// text and the current Show Flair checkbox. Restrict parsing to the titlebox and
// require the active username so a post author's flair can never be mistaken for
// the signed-in user's current selection.
static NSDictionary *ApolloUserFlairWebCurrentFromHTML(NSData *data, NSString *username) {
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (html.length == 0 || username.length == 0) return nil;

    NSRange titleStart = [html rangeOfString:@"<div class=\"titlebox\"" options:NSCaseInsensitiveSearch];
    if (titleStart.location == NSNotFound) return nil;
    NSRange remainder = NSMakeRange(titleStart.location, html.length - titleStart.location);
    NSRange titleEnd = [html rangeOfString:@"<div class=\"sidecontentbox" options:NSCaseInsensitiveSearch range:remainder];
    NSUInteger end = titleEnd.location == NSNotFound ? MIN(html.length, titleStart.location + 150000) : titleEnd.location;
    if (end <= titleStart.location) return nil;
    NSString *titlebox = [html substringWithRange:NSMakeRange(titleStart.location, end - titleStart.location)];

    NSRegularExpression *anchorRegex = [NSRegularExpression regularExpressionWithPattern:@"<a\\b([^>]*)>(.*?)</a>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:NULL];
    NSTextCheckingResult *userAnchor = nil;
    for (NSTextCheckingResult *match in [anchorRegex matchesInString:titlebox options:0 range:NSMakeRange(0, titlebox.length)]) {
        if (match.numberOfRanges < 3) continue;
        NSString *attrs = [titlebox substringWithRange:[match rangeAtIndex:1]];
        NSSet *classes = ApolloUserFlairHTMLClassSet(ApolloUserFlairHTMLAttribute(attrs, @"class") ?: @"");
        if (![classes containsObject:@"flairselectable"]) continue;
        NSString *label = ApolloUserFlairDecodeHTML([titlebox substringWithRange:[match rangeAtIndex:2]]);
        label = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([label caseInsensitiveCompare:username] == NSOrderedSame) {
            userAnchor = match;
            break;
        }
    }
    if (!userAnchor) return nil;

    NSString *beforeUser = [titlebox substringToIndex:userAnchor.range.location];
    NSRange taglineStart = [beforeUser rangeOfString:@"<div class=\"tagline\"" options:
                            NSCaseInsensitiveSearch | NSBackwardsSearch];
    if (taglineStart.location == NSNotFound) return nil;
    NSString *taglinePrefix = [beforeUser substringFromIndex:taglineStart.location];

    NSString *currentText = @"";
    NSString *currentCSSClass = @"";
    NSRegularExpression *spanRegex = [NSRegularExpression regularExpressionWithPattern:@"<span\\b([^>]*)>"
        options:NSRegularExpressionCaseInsensitive error:NULL];
    for (NSTextCheckingResult *match in [spanRegex matchesInString:taglinePrefix options:0
                                                              range:NSMakeRange(0, taglinePrefix.length)]) {
        if (match.numberOfRanges < 2) continue;
        NSString *attrs = [taglinePrefix substringWithRange:[match rangeAtIndex:1]];
        NSString *classAttribute = ApolloUserFlairHTMLAttribute(attrs, @"class") ?: @"";
        if (![ApolloUserFlairHTMLClassSet(classAttribute) containsObject:@"flair"]) continue;
        currentText = ApolloUserFlairDecodeHTML(ApolloUserFlairHTMLAttribute(attrs, @"title")) ?: @"";
        currentCSSClass = ApolloUserFlairCSSClassFromClassAttribute(classAttribute) ?: @"";
        break;
    }

    BOOL enabled = NO;
    NSRegularExpression *formRegex = [NSRegularExpression regularExpressionWithPattern:@"<form\\b([^>]*)>(.*?)</form>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:NULL];
    for (NSTextCheckingResult *match in [formRegex matchesInString:titlebox options:0 range:NSMakeRange(0, titlebox.length)]) {
        if (match.numberOfRanges < 3) continue;
        NSString *attrs = [titlebox substringWithRange:[match rangeAtIndex:1]];
        if (![ApolloUserFlairHTMLClassSet(ApolloUserFlairHTMLAttribute(attrs, @"class") ?: @"")
              containsObject:@"flairtoggle"]) continue;
        NSString *body = [titlebox substringWithRange:[match rangeAtIndex:2]];
        enabled = [body rangeOfString:@"checked" options:NSCaseInsensitiveSearch].location != NSNotFound;
        break;
    }

    return @{
        @"known": @YES,
        @"text": currentText,
        @"cssClass": currentCSSClass,
        @"enabled": @(enabled),
        @"templateID": @"",
    };
}

static NSDictionary *ApolloUserFlairMatchWebCurrent(NSDictionary *current, NSArray *options,
                                                     NSString *subreddit) {
    if (![current[@"known"] boolValue]) return current;
    NSString *currentText = [current[@"text"] isKindOfClass:[NSString class]] ? current[@"text"] : @"";
    NSString *currentCSS = [current[@"cssClass"] isKindOfClass:[NSString class]] ? current[@"cssClass"] : @"";
    id matchedOption = nil;

    if (currentCSS.length > 0) {
        for (id option in options) {
            NSString *css = objc_getAssociatedObject(option, &kApolloUserFlairWebCSSClassKey);
            if ([css isKindOfClass:[NSString class]] && [css caseInsensitiveCompare:currentCSS] == NSOrderedSame) {
                matchedOption = option;
                break;
            }
        }
    }
    if (!matchedOption && currentText.length > 0) {
        for (id option in options) {
            NSString *text = ApolloUserFlairObjectString(option,
                @[@"textRepresentation", @"text", @"flairText", @"flair_text", @"plainText"]);
            if ([text isKindOfClass:[NSString class]] && [text isEqualToString:currentText]) {
                matchedOption = option;
                break;
            }
        }
    }
    // Some communities expose a single editable template whose selector text is
    // the template default while the sidebar contains the user's customized text.
    // With only one possible template, that is still an unambiguous match.
    if (!matchedOption && currentText.length > 0 && options.count == 1) matchedOption = options.firstObject;

    NSString *templateID = matchedOption ? (ApolloUserFlairOptionIdentifier(matchedOption) ?: @"") : @"";
    if (matchedOption) {
        objc_setAssociatedObject(matchedOption, &kApolloUserFlairWebCurrentOptionKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableDictionary *resolved = [current mutableCopy];
    resolved[@"templateID"] = templateID;
    NSString *key = subreddit.lowercaseString;
    if (key.length > 0) {
        @synchronized (ApolloUserFlairWebCurrentCache()) {
            ApolloUserFlairWebCurrentCache()[key] = resolved;
        }
    }
    ApolloLog(@"[UserFlair][Web] current r/%@ present=%@ matched=%@ visible=%@",
              subreddit, currentText.length > 0 || currentCSS.length > 0 ? @"yes" : @"no",
              templateID.length > 0 ? @"yes" : @"no", [current[@"enabled"] boolValue] ? @"yes" : @"no");
    return resolved;
}

static NSString *ApolloUserFlairEmojiURLFromStyle(NSString *style) {
    if (style.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"background-image\\s*:\\s*url\\(\\s*['\"]?([^)'\"]+)"
        options:NSRegularExpressionCaseInsensitive error:NULL];
    NSTextCheckingResult *match = [re firstMatchInString:style options:0 range:NSMakeRange(0, style.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return ApolloUserFlairDecodeHTML([style substringWithRange:[match rangeAtIndex:1]]);
}

static NSArray *ApolloUserFlairWebOptionsFromHTML(NSData *data, NSString *subreddit) {
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (html.length == 0) return nil;
    if ([html rangeOfString:@"<h2>select flair</h2>" options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [html rangeOfString:@"flairoptionpane" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        return nil; // login/block/error HTML, not a valid (possibly empty) selector
    }

    NSRegularExpression *liRegex = [NSRegularExpression regularExpressionWithPattern:@"<li\\b([^>]*)>(.*?)</li>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:NULL];
    NSRegularExpression *spanRegex = [NSRegularExpression regularExpressionWithPattern:@"<span\\b([^>]*)>"
        options:NSRegularExpressionCaseInsensitive error:NULL];
    NSArray<NSTextCheckingResult *> *matches = [liRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    NSMutableArray *options = [NSMutableArray arrayWithCapacity:matches.count];
    NSMutableDictionary<NSString *, NSString *> *allEmojiURLs = [NSMutableDictionary dictionary];

    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 3) continue;
        NSString *liTag = [html substringWithRange:[match rangeAtIndex:1]];
        NSString *body = [html substringWithRange:[match rangeAtIndex:2]];
        NSString *identifier = ApolloUserFlairDecodeHTML(ApolloUserFlairHTMLAttribute(liTag, @"id"));
        if (identifier.length == 0) continue;
        NSString *liClass = ApolloUserFlairHTMLAttribute(liTag, @"class") ?: @"";
        BOOL editable = [[liClass componentsSeparatedByCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]] containsObject:@"texteditable"];

        NSString *flairText = nil;
        NSString *cssClass = nil;
        NSMutableDictionary<NSString *, NSString *> *emojiURLs = [NSMutableDictionary dictionary];
        for (NSTextCheckingResult *spanMatch in [spanRegex matchesInString:body options:0 range:NSMakeRange(0, body.length)]) {
            NSString *tag = [body substringWithRange:[spanMatch rangeAtIndex:1]];
            NSString *classes = ApolloUserFlairHTMLAttribute(tag, @"class") ?: @"";
            NSSet *classSet = [NSSet setWithArray:[classes componentsSeparatedByCharactersInSet:
                                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            if ([classSet containsObject:@"flairemoji"]) {
                NSString *label = ApolloUserFlairDecodeHTML(ApolloUserFlairHTMLAttribute(tag, @"title"));
                NSString *name = [label stringByTrimmingCharactersInSet:
                                  [NSCharacterSet characterSetWithCharactersInString:@":"]];
                NSString *url = ApolloUserFlairEmojiURLFromStyle(ApolloUserFlairHTMLAttribute(tag, @"style"));
                if (name.length > 0 && url.length > 0) {
                    emojiURLs[name] = url;
                    allEmojiURLs[name] = url;
                }
                continue;
            }
            if (!flairText && ([classSet containsObject:@"flairrichtext"] || [classSet containsObject:@"flair"])) {
                flairText = ApolloUserFlairDecodeHTML(ApolloUserFlairHTMLAttribute(tag, @"title"));
                cssClass = ApolloUserFlairCSSClassFromClassAttribute(classes);
            }
        }
        flairText = flairText ?: @"";

        NSArray *flairs = ApolloUserFlairPiecesFromFlairTextWithEmojiMap(flairText, emojiURLs);
        if (flairs.count == 0 && cssClass.length > 0) {
            // Old-CSS systems (r/nintendo and similar) have an empty title and
            // distinguish templates only with flair-<css_class>. Preserve the
            // model's empty commit text, but give the native row a readable name.
            id label = ApolloUserFlairMakeTextFlair(ApolloUserFlairPrettifyClass(cssClass));
            if (label) flairs = @[label];
        }

        Class optionClass = objc_getClass("RDKFlairOption");
        id option = optionClass ? [optionClass new] : nil;
        if (!option) continue;
        @try {
            [option setValue:identifier forKey:@"identifier"];
            [option setValue:flairText forKey:@"textRepresentation"];
            [option setValue:@(editable) forKey:@"isEditable"];
            [option setValue:flairs ?: @[] forKey:@"flairs"];
        } @catch (NSException *exception) {
            ApolloLog(@"[UserFlair][Web] Could not populate option %@: %@", identifier, exception.reason);
            continue;
        }
        if (cssClass.length > 0) {
            objc_setAssociatedObject(option, &kApolloUserFlairWebCSSClassKey, cssClass, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        [options addObject:option];
    }

    // Seed a partial fallback with the concrete URLs embedded in the templates.
    // This is deliberately marked partial: when the editor opens it must still
    // fetch Reddit's complete catalog, otherwise communities with one editable
    // template (such as r/soccer) show only its current icon instead of all choices.
    NSMutableArray *cachedEmojis = [NSMutableArray arrayWithCapacity:allEmojiURLs.count];
    for (NSString *name in [[allEmojiURLs allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        [cachedEmojis addObject:@{ @"name": name, @"url": allEmojiURLs[name] }];
    }
    NSString *cacheKey = subreddit.lowercaseString;
    if (cacheKey.length > 0) {
        @synchronized (ApolloUserFlairEmojiListCache()) {
            BOOL existingIsPartial = [ApolloUserFlairPartialEmojiCacheKeys() containsObject:cacheKey];
            if (!ApolloUserFlairEmojiListCache()[cacheKey] || existingIsPartial) {
                ApolloUserFlairEmojiListCache()[cacheKey] = cachedEmojis;
                [ApolloUserFlairPartialEmojiCacheKeys() addObject:cacheKey];
            }
        }
    }

    ApolloLog(@"[UserFlair][Web] Parsed %lu choices for r/%@ from old-Reddit selector HTML",
              (unsigned long)options.count, subreddit);
    return options;
}

static NSData *ApolloUserFlairFormData(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *key in fields) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:fields[key] ?: @""]];
    }
    NSURLComponents *components = [NSURLComponents new];
    components.queryItems = items;
    return [components.percentEncodedQuery dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError *ApolloUserFlairWebError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"ApolloUserFlairWeb" code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Reddit could not load user flair."}];
}

static NSMutableURLRequest *ApolloUserFlairWebRequest(NSString *path, NSDictionary<NSString *, NSString *> *fields,
                                                       ApolloWebSessionEntry *session) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = ApolloUserFlairFormData(fields);
    request.HTTPShouldHandleCookies = NO;
    request.timeoutInterval = 25.0;
    [request setValue:session.cookieHeader forHTTPHeaderField:@"Cookie"];
    if (session.modhash.length > 0) [request setValue:session.modhash forHTTPHeaderField:@"X-Modhash"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.reddit.com" forHTTPHeaderField:@"Origin"];
    [request setValue:(sUserAgent.length > 0 ? sUserAgent : @"Apollo iOS") forHTTPHeaderField:@"User-Agent"];
    return request;
}

static id ApolloUserFlairFetchWebOptions(NSString *subreddit, id completion) {
    NSString *username = ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *webSession = ApolloActiveWebSession();
    void (^callback)(NSArray *, NSError *) = [completion copy];
    if (username.length == 0 || subreddit.length == 0 || webSession.cookieHeader.length == 0) {
        if (callback) callback(nil, ApolloUserFlairWebError(1, @"The API-key-free Reddit session is unavailable."));
        return nil;
    }

    NSDictionary *fields = @{
        @"api_type": @"json",
        @"r": subreddit,
        @"name": username,
        @"is_newlink": @"false",
        @"uh": webSession.modhash ?: @"",
    };
    NSMutableURLRequest *selectorRequest = ApolloUserFlairWebRequest(@"/api/flairselector", fields, webSession);
    NSString *encodedSubreddit = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:
                                  [NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    NSMutableURLRequest *currentRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        [NSString stringWithFormat:@"https://old.reddit.com/r/%@/", encodedSubreddit]]];
    currentRequest.HTTPMethod = @"GET";
    currentRequest.HTTPShouldHandleCookies = NO;
    currentRequest.timeoutInterval = 25.0;
    [currentRequest setValue:webSession.cookieHeader forHTTPHeaderField:@"Cookie"];
    [currentRequest setValue:(sUserAgent.length > 0 ? sUserAgent : @"Apollo iOS") forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    dispatch_group_t group = dispatch_group_create();
    __block NSData *selectorData = nil;
    __block NSHTTPURLResponse *selectorHTTP = nil;
    __block NSError *selectorError = nil;
    __block NSData *currentData = nil;
    __block NSHTTPURLResponse *currentHTTP = nil;
    __block NSError *currentError = nil;

    dispatch_group_enter(group);
    NSURLSessionDataTask *selectorTask = [session dataTaskWithRequest:selectorRequest completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *networkError) {
            selectorData = data;
            selectorHTTP = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            selectorError = networkError;
            dispatch_group_leave(group);
        }];
    dispatch_group_enter(group);
    NSURLSessionDataTask *currentTask = [session dataTaskWithRequest:currentRequest completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *networkError) {
            currentData = data;
            currentHTTP = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            currentError = networkError;
            dispatch_group_leave(group);
        }];

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray *choices = (!selectorError && selectorHTTP.statusCode == 200)
                ? ApolloUserFlairWebOptionsFromHTML(selectorData, subreddit) : nil;
            NSError *error = selectorError;
            if (!error && !choices) {
                error = ApolloUserFlairWebError(selectorHTTP.statusCode ?: 2,
                    @"Reddit returned an unexpected response while loading user flair.");
            }
            NSDictionary *current = (!currentError && currentHTTP.statusCode == 200)
                ? ApolloUserFlairWebCurrentFromHTML(currentData, username) : nil;
            if (choices && current) ApolloUserFlairMatchWebCurrent(current, choices, subreddit);
            ApolloLog(@"[UserFlair][Web] selector r/%@ HTTP %ld choices=%lu error=%@",
                      subreddit, (long)selectorHTTP.statusCode, (unsigned long)choices.count, error ? @"yes" : @"no");
            ApolloLog(@"[UserFlair][Web] current-page r/%@ HTTP %ld parsed=%@ error=%@",
                      subreddit, (long)currentHTTP.statusCode, current ? @"yes" : @"no",
                      currentError ? @"yes" : @"no");
            dispatch_async(dispatch_get_main_queue(), ^{ if (callback) callback(choices, error); });
            [session finishTasksAndInvalidate];
        });
    [selectorTask resume];
    [currentTask resume];
    return selectorTask;
}

static NSError *ApolloUserFlairWebAPIError(NSData *data, NSHTTPURLResponse *http, NSError *networkError,
                                            NSString *fallback) {
    if (networkError) return networkError;
    if (http.statusCode != 200) return ApolloUserFlairWebError(http.statusCode ?: 3, fallback);
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *json = [root isKindOfClass:[NSDictionary class]] ? root[@"json"] : nil;
    NSArray *errors = [json isKindOfClass:[NSDictionary class]] ? json[@"errors"] : nil;
    if ([errors isKindOfClass:[NSArray class]] && errors.count > 0) {
        return ApolloUserFlairWebError(4, [errors.firstObject description] ?: fallback);
    }
    return nil;
}

static id ApolloUserFlairPerformWebUpdate(NSString *path, NSString *subreddit,
                                           NSDictionary<NSString *, NSString *> *extraFields, id completion) {
    NSString *username = ApolloActiveWebSessionUsername();
    ApolloWebSessionEntry *webSession = ApolloActiveWebSession();
    void (^callback)(NSError *) = [completion copy];
    if (username.length == 0 || subreddit.length == 0 || webSession.cookieHeader.length == 0) {
        if (callback) callback(ApolloUserFlairWebError(1, @"The API-key-free Reddit session is unavailable."));
        return nil;
    }

    NSMutableDictionary *fields = [@{
        @"api_type": @"json",
        @"r": subreddit,
        @"name": username,
        @"uh": webSession.modhash ?: @"",
    } mutableCopy];
    [fields addEntriesFromDictionary:extraFields ?: @{}];
    NSMutableURLRequest *request = ApolloUserFlairWebRequest(path, fields, webSession);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:
        ^(NSData *data, NSURLResponse *response, NSError *networkError) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            NSError *error = ApolloUserFlairWebAPIError(data, http, networkError,
                @"Reddit returned an error while saving user flair.");
            ApolloLog(@"[UserFlair][Web] update %@ r/%@ HTTP %ld error=%@",
                      path, subreddit, (long)http.statusCode, error ? @"yes" : @"no");
            dispatch_async(dispatch_get_main_queue(), ^{ if (callback) callback(error); });
            [session finishTasksAndInvalidate];
        }];
    [task resume];
    return task;
}

#pragma mark - Current Flair (so the user can see their existing flair)

// Stored on the controller: @{ @"text": flair_text, @"templateID": id-or-@"" }.
// Fetched once per controller from Reddit's flairselector `current`.
static void ApolloUserFlairFetchCurrentFlair(UIViewController *controller, NSString *subreddit) {
    if (!controller || subreddit.length == 0) return;

    // The keyless bridge populates its current-flair cache alongside the options
    // request. numberOfRows can run before that response arrives, so do not stamp
    // the one-shot marker until a real (possibly explicitly empty) current state
    // exists. Apollo reloads the table after installing the fetched choices; that
    // later numberOfRows pass then applies the cache and the native checkmark.
    if (ApolloWebJSONHasUsableSession()) {
        if (objc_getAssociatedObject(controller, &kApolloUserFlairCurrentFlairKey)) return;
        NSDictionary *webCurrent = ApolloUserFlairWebCurrentForSubreddit(subreddit);
        if (!webCurrent) return;

        NSString *webText = [webCurrent[@"text"] isKindOfClass:[NSString class]] ? webCurrent[@"text"] : @"";
        NSString *webTemplateID = [webCurrent[@"templateID"] isKindOfClass:[NSString class]]
            ? webCurrent[@"templateID"] : @"";
        objc_setAssociatedObject(controller, &kApolloUserFlairCurrentFlairKey,
            @{ @"text": webText, @"templateID": webTemplateID }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!objc_getAssociatedObject(controller, &kApolloUserFlairWebStateAppliedKey)) {
            BOOL set = ApolloUserFlairSetSwiftOptionalStringIvar(controller, @"currentFlairID", webTemplateID);
            objc_setAssociatedObject(controller, &kApolloUserFlairWebStateAppliedKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[UserFlair][Web] applied initial r/%@ template=%@ text=%@ setter=%@",
                      subreddit, webTemplateID.length > 0 ? @"matched" : @"none",
                      webText.length > 0 ? @"present" : @"empty", set ? @"yes" : @"no");
        }
        return;
    }

    if (objc_getAssociatedObject(controller, &kApolloUserFlairCurrentFlairKey)) return; // already fetched
    // Mark as in-flight so we don't fire the OAuth request twice (numberOfRows is called repeatedly).
    objc_setAssociatedObject(controller, &kApolloUserFlairCurrentFlairKey, @{}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Reddit's /api/flairselector `current` reliably returns the applied flair_text but
    // often omits flair_template_id (comes back empty), so we can't map the flair back
    // to its row from the response alone. Apollo's own selector, however, resolves the
    // applied template into its `currentFlairID` ivar (a Swift String) — that's what
    // drives its native checkmark. Capture it synchronously now (at open, before the
    // user taps anything) so we can use it as the authoritative template id when the
    // server's is missing. Without this the editor pre-fills the template's DEFAULT text
    // and re-saving silently overwrites the user's real flair.
    NSString *nativeTemplateID = ApolloUserFlairSwiftStringIvar(controller, @"currentFlairID");
    if (![nativeTemplateID isKindOfClass:[NSString class]]) nativeTemplateID = nil;

    NSString *token = [sLatestRedditBearerToken copy];
    if (token.length == 0) return;
    NSString *enc = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    __weak UIViewController *weakController = controller;

    // Fetch the emoji map FIRST so :token: flairs can render as images, then the
    // current flair, then reload the table once both are available.
    ApolloUserFlairFetchEmojis(subreddit, ^(NSArray *emojis) {
        (void)emojis;
        NSString *urlStr = [NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/flairselector?raw_json=1", enc];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        req.HTTPMethod = @"POST";
        [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [req setValue:@"Apollo iOS" forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSData data];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            id current = [json isKindOfClass:[NSDictionary class]] ? json[@"current"] : nil;
            NSString *text = nil, *templateID = nil;
            if ([current isKindOfClass:[NSDictionary class]]) {
                id t = current[@"flair_text"]; if ([t isKindOfClass:[NSString class]]) text = t;
                id tid = current[@"flair_template_id"]; if ([tid isKindOfClass:[NSString class]]) templateID = tid;
            }
            // The server frequently omits flair_template_id; fall back to the template id
            // Apollo itself resolved (its native checkmark source), captured above.
            if (templateID.length == 0 && nativeTemplateID.length > 0) templateID = nativeTemplateID;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *strongController = weakController;
                if (!strongController) return;
                objc_setAssociatedObject(strongController, &kApolloUserFlairCurrentFlairKey,
                    @{ @"text": text ?: @"", @"templateID": templateID ?: @"" }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                id tableNode = ApolloUserFlairRawObjectIvar(strongController, @"tableNode");
                BOOL reloaded = [tableNode respondsToSelector:@selector(reloadData)];
                if (reloaded) ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData));
                ApolloLog(@"[UserFlair] current flair r/%@ textLen=%lu template=%@ reloaded=%d", subreddit, (unsigned long)text.length, templateID.length ? @"yes" : @"none", reloaded);
            });
        }] resume];
    });
}

// The user's current flair_text IF it belongs on this option's row: either the
// template ids match, or the flair is free-form (no template) and this is a
// blank editable row. Returns nil otherwise.
static NSString *ApolloUserFlairCurrentFlairTextForOption(UIViewController *controller, id option) {
    NSDictionary *current = objc_getAssociatedObject(controller, &kApolloUserFlairCurrentFlairKey);
    NSString *text = current[@"text"];
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    NSString *templateID = current[@"templateID"];
    NSString *optionID = ApolloUserFlairOptionIdentifier(option);
    if (templateID.length > 0) {
        return [templateID isEqualToString:optionID] ? text : nil;
    }
    // Free-form flair (no template id): show it on the blank editable "custom" row,
    // OR on the sole editable template (e.g. r/soccer's single emoji template, whose
    // applied flair is free-form). Without this the row/editor fall back to the
    // template's generic default, so a changed flair looks like it never applied and
    // editing it would silently discard the user's real flair.
    if (ApolloUserFlairOptionIsBlankEditable(option)) return text;
    NSArray *options = ApolloUserFlairControllerOptions(controller);
    if (options.count == 1) {
        BOOL editableKnown = NO;
        if (ApolloUserFlairOptionIsEditable(option, &editableKnown) && editableKnown) return text;
    }
    return nil;
}

#pragma mark - Old-Reddit CSS Sprite Flairs
//
// Subreddits like r/nintendo keep their "real" flairs in the old-reddit stylesheet:
// each template carries a flair_css_class whose image is a region of a sprite sheet
// defined in CSS. New Reddit / Apollo drop the css_class + sprite, so these come back
// as blank "custom" templates. We recover them: fetch flairselector (template_id ->
// css_class) and the stylesheet, parse the common single-sheet sprite pattern, crop
// each flair's region, and render the real avatar in the selector. Subreddits whose
// CSS we can't safely parse (e.g. r/dbz's multi-sheet attribute selectors) fall back
// to the prettified css_class name; genuinely-empty subs keep the collapse behaviour.

static NSString *ApolloUserFlairRegexSub(NSString *s, NSString *pattern, NSString *tmpl) {
    if (s.length == 0) return s;
    return [s stringByReplacingOccurrencesOfString:pattern withString:tmpl
              options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
}

// Prettify a css_class for display: drop a trailing numeric variant, split camelCase
// and separators, title-case. "princessPeach"->"Princess Peach", "Beerus-001"->"Beerus".
static NSString *ApolloUserFlairPrettifyClass(NSString *cssClass) {
    NSString *s = [cssClass stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return nil;
    s = ApolloUserFlairRegexSub(s, @"[-_]?[0-9]{1,4}$", @"");
    s = ApolloUserFlairRegexSub(s, @"[-_]+", @" ");
    s = ApolloUserFlairRegexSub(s, @"([a-z])([A-Z])", @"$1 $2");
    s = ApolloUserFlairRegexSub(s, @"([A-Za-z])([0-9])", @"$1 $2");
    s = ApolloUserFlairRegexSub(s, @"([0-9])([A-Za-z])", @"$1 $2");
    s = ApolloUserFlairRegexSub(s, @"\\s+", @" ");
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (s.length == 0) return nil;
    return [s capitalizedString];
}

static NSCache<NSString *, UIImage *> *ApolloUserFlairSheetCache(void) {
    static NSCache *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [NSCache new]; c.countLimit = 8; });
    return c;
}

// css_class -> cropped sprite file:// URL (so the native flair cell can load it).
static NSMutableDictionary<NSString *, NSString *> *ApolloUserFlairSpriteFileCache(void) {
    static NSMutableDictionary *d = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

// Filename prefix that marks our locally-cropped sprite files, recognised by the
// ASNetworkImageNode hook below (its HTTP-only downloader can't load file:// URLs,
// so we intercept and set the in-memory cropped UIImage directly).
static NSString *const kApolloUserFlairSpriteFilePrefix = @"apolloflair_";

// file path -> cropped UIImage, so the image-node hook serves the exact crop
// without re-decoding from disk (and at the right scale).
static NSMutableDictionary<NSString *, UIImage *> *ApolloUserFlairSpriteImageByPath(void) {
    static NSMutableDictionary *d = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

static NSString *ApolloUserFlairFirstGroup(NSString *str, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    return (m && m.numberOfRanges > 1) ? [str substringWithRange:[m rangeAtIndex:1]] : nil;
}

// Parse the common single-sprite-sheet pattern. Returns css_class -> @{url,x,y,w,h,round}
// or nil when the stylesheet uses a layout we can't safely map (multiple sheets,
// attribute selectors, etc.) so callers fall back to names.
static NSDictionary *ApolloUserFlairParseSpriteCSS(NSString *css, NSArray *images) {
    if (css.length == 0) return nil;
    NSMutableDictionary *imgURL = [NSMutableDictionary dictionary];
    for (NSDictionary *im in images) {
        if ([im[@"name"] isKindOfClass:[NSString class]] && [im[@"url"] isKindOfClass:[NSString class]]) imgURL[im[@"name"]] = im[@"url"];
    }

    NSRegularExpression *ruleRe = [NSRegularExpression regularExpressionWithPattern:@"([^{}]*)\\{([^{}]*)\\}" options:0 error:NULL];
    NSArray *rules = [ruleRe matchesInString:css options:0 range:NSMakeRange(0, css.length)];

    // Base rule: a plain `.flair` / `.flair:before` (NOT .flair-x, NOT .flair[attr])
    // with background-image url + width + height. Reject subs with >1 distinct flair
    // sheet (multi-sheet) — too ambiguous to map by class alone.
    NSString *sheetURL = nil; CGFloat W = 0, H = 0; BOOL round = NO;
    NSMutableSet *flairSheets = [NSMutableSet set];
    for (NSTextCheckingResult *m in rules) {
        NSString *sel = [css substringWithRange:[m rangeAtIndex:1]];
        NSString *body = [css substringWithRange:[m rangeAtIndex:2]];
        if ([body rangeOfString:@"background-image"].location == NSNotFound) continue;
        if ([body rangeOfString:@"background-position"].location != NSNotFound) continue;
        // does this rule target flairs (a bare .flair token)?
        if ([sel rangeOfString:@"\\.flair(?![\\w\\[-])" options:NSRegularExpressionSearch].location == NSNotFound) continue;
        NSString *nm = ApolloUserFlairFirstGroup(body, @"background-image\\s*:\\s*url\\(\\s*[\"']?%%([^%]+)%%");
        NSString *resolved = nm ? imgURL[nm] : nil;
        if (!resolved) {
            NSString *direct = ApolloUserFlairFirstGroup(body, @"background-image\\s*:\\s*url\\(\\s*[\"']?(https?://[^\"')]+)");
            if (direct) resolved = direct;
        }
        if (!resolved) continue;
        [flairSheets addObject:resolved];
        if (!sheetURL) {
            NSString *ws = ApolloUserFlairFirstGroup(body, @"width\\s*:\\s*([0-9.]+)px");
            NSString *hs = ApolloUserFlairFirstGroup(body, @"height\\s*:\\s*([0-9.]+)px");
            if (ws.doubleValue > 0 && hs.doubleValue > 0) {
                sheetURL = resolved; W = ws.doubleValue; H = hs.doubleValue;
                round = ([body rangeOfString:@"border-radius"].location != NSNotFound);
            }
        }
    }
    if (!sheetURL || flairSheets.count != 1) return nil; // unparseable / multi-sheet

    NSRegularExpression *clsRe = [NSRegularExpression regularExpressionWithPattern:@"\\.flair-([A-Za-z0-9_-]+)" options:0 error:NULL];
    NSRegularExpression *posRe = [NSRegularExpression regularExpressionWithPattern:@"background-position\\s*:\\s*(-?[0-9.]+)(?:px)?\\s+(-?[0-9.]+)(?:px)?" options:0 error:NULL];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *m in rules) {
        NSString *sel = [css substringWithRange:[m rangeAtIndex:1]];
        NSString *body = [css substringWithRange:[m rangeAtIndex:2]];
        NSTextCheckingResult *bp = [posRe firstMatchInString:body options:0 range:NSMakeRange(0, body.length)];
        if (!bp) continue;
        CGFloat bx = [[body substringWithRange:[bp rangeAtIndex:1]] doubleValue];
        CGFloat by = [[body substringWithRange:[bp rangeAtIndex:2]] doubleValue];
        CGFloat w = W, h = H;
        NSString *ws = ApolloUserFlairFirstGroup(body, @"width\\s*:\\s*([0-9.]+)px");
        NSString *hs = ApolloUserFlairFirstGroup(body, @"height\\s*:\\s*([0-9.]+)px");
        if (ws.doubleValue > 0) w = ws.doubleValue;
        if (hs.doubleValue > 0) h = hs.doubleValue;
        for (NSTextCheckingResult *cm in [clsRe matchesInString:sel options:0 range:NSMakeRange(0, sel.length)]) {
            NSString *cls = [sel substringWithRange:[cm rangeAtIndex:1]];
            if (map[cls]) continue;
            map[cls] = @{ @"url": sheetURL, @"x": @(-bx), @"y": @(-by), @"w": @(w), @"h": @(h), @"round": @(round) };
        }
    }
    return map.count ? map : nil;
}

// Crop css_class's sprite from its (already-downloaded) sheet, write a temp PNG, and
// return a file:// URL. nil if the sheet isn't cached yet or the region is invalid.
static NSString *ApolloUserFlairSpriteFileForClass(UIViewController *controller, NSString *cssClass) {
    if (cssClass.length == 0) return nil;
    NSString *cached;
    @synchronized (ApolloUserFlairSpriteFileCache()) { cached = ApolloUserFlairSpriteFileCache()[cssClass]; }
    if (cached) return cached;
    NSDictionary *spriteMap = objc_getAssociatedObject(controller, &kApolloUserFlairSpriteMapKey);
    NSDictionary *region = spriteMap[cssClass];
    if (![region isKindOfClass:[NSDictionary class]]) return nil;
    UIImage *sheet = [ApolloUserFlairSheetCache() objectForKey:region[@"url"]];
    if (!sheet || !sheet.CGImage) return nil;
    CGFloat scale = sheet.scale > 0 ? sheet.scale : 1.0;
    CGRect r = CGRectMake([region[@"x"] doubleValue] * scale, [region[@"y"] doubleValue] * scale,
                          [region[@"w"] doubleValue] * scale, [region[@"h"] doubleValue] * scale);
    size_t sw = CGImageGetWidth(sheet.CGImage), sh = CGImageGetHeight(sheet.CGImage);
    if (r.size.width <= 0 || r.size.height <= 0 || r.origin.x < 0 || r.origin.y < 0 ||
        CGRectGetMaxX(r) > sw + 1 || CGRectGetMaxY(r) > sh + 1) return nil;
    CGImageRef crop = CGImageCreateWithImageInRect(sheet.CGImage, r);
    if (!crop) return nil;
    UIImage *img = [UIImage imageWithCGImage:crop scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(crop);
    NSData *png = UIImagePNGRepresentation(img);
    if (!png) return nil;
    NSString *safe = [cssClass stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]] ?: @"f";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.png", kApolloUserFlairSpriteFilePrefix, safe]];
    if (![png writeToFile:path atomically:YES]) return nil;
    // Keep the exact crop in memory so the ASNetworkImageNode hook can serve it
    // directly (its HTTP downloader can't load file:// URLs).
    @synchronized (ApolloUserFlairSpriteImageByPath()) { ApolloUserFlairSpriteImageByPath()[path] = img; }
    NSString *fileURL = [[NSURL fileURLWithPath:path] absoluteString];
    @synchronized (ApolloUserFlairSpriteFileCache()) { ApolloUserFlairSpriteFileCache()[cssClass] = fileURL; }
    return fileURL;
}

// css_class for an option (via the template_id -> css_class map). nil if none.
static NSString *ApolloUserFlairCssClassForOption(UIViewController *controller, id option) {
    NSString *webCSS = objc_getAssociatedObject(option, &kApolloUserFlairWebCSSClassKey);
    if ([webCSS isKindOfClass:[NSString class]] && webCSS.length > 0) return webCSS;
    NSDictionary *byTemplate = objc_getAssociatedObject(controller, &kApolloUserFlairCssByTemplateKey);
    if (![byTemplate isKindOfClass:[NSDictionary class]] || byTemplate.count == 0) return nil;
    NSString *tid = ApolloUserFlairOptionIdentifier(option);
    NSString *css = tid ? byTemplate[tid] : nil;
    return css.length ? css : nil;
}

// Fetch flairselector (css_class per template) + the stylesheet (sprite sheets), then
// reload so rows can render real sprites/names. One-shot per controller.
static void ApolloUserFlairFetchSpriteData(UIViewController *controller, NSString *subreddit) {
    if (!controller || subreddit.length == 0) return;
    if (objc_getAssociatedObject(controller, &kApolloUserFlairSpriteFetchedKey)) return;
    objc_setAssociatedObject(controller, &kApolloUserFlairSpriteFetchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The HTML bridge already recovered css_class names for keyless accounts.
    // The stylesheet API is OAuth-only, so stop here instead of accidentally
    // using another account's process-global bearer token.
    if (ApolloWebJSONHasUsableSession()) return;
    NSString *token = [sLatestRedditBearerToken copy];
    if (token.length == 0) return;
    NSString *enc = [subreddit stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: subreddit;
    __weak UIViewController *wc = controller;

    void (^reload)(void) = ^{
        UIViewController *c = wc; if (!c) return;
        // Drop the cached collapse model so it rebuilds (css-class subs stop collapsing).
        objc_setAssociatedObject(c, &kApolloUserFlairCollapseModelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id tableNode = ApolloUserFlairRawObjectIvar(c, @"tableNode");
        if ([tableNode respondsToSelector:@selector(reloadData)]) ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData));
    };

    NSMutableURLRequest *fs = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/api/flairselector?raw_json=1", enc]]];
    fs.HTTPMethod = @"POST"; fs.HTTPBody = [NSData data];
    [fs setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [fs setValue:@"Apollo iOS" forHTTPHeaderField:@"User-Agent"];
    [fs setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:fs completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSArray *choices = [j isKindOfClass:[NSDictionary class]] ? j[@"choices"] : nil;
        NSMutableDictionary *byTemplate = [NSMutableDictionary dictionary];
        for (NSDictionary *ch in (choices ?: @[])) {
            NSString *tid = ch[@"flair_template_id"];
            NSString *css = ch[@"flair_css_class"];
            if ([tid isKindOfClass:[NSString class]] && [css isKindOfClass:[NSString class]]) {
                NSString *trimmed = [css stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length) byTemplate[tid] = trimmed;
            }
        }
        if (byTemplate.count == 0) return; // no css-class flairs — leave default behaviour
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *c = wc; if (!c) return;
            objc_setAssociatedObject(c, &kApolloUserFlairCssByTemplateKey, byTemplate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLog(@"[UserFlair] css-class flairs: %lu templates", (unsigned long)byTemplate.count);
            reload(); // show prettified names immediately

            // Now fetch the stylesheet + parse + download sprite sheets.
            NSMutableURLRequest *ss = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://oauth.reddit.com/r/%@/about/stylesheet?raw_json=1", enc]]];
            [ss setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
            [ss setValue:@"Apollo iOS" forHTTPHeaderField:@"User-Agent"];
            [[[NSURLSession sharedSession] dataTaskWithRequest:ss completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                id j2 = d2 ? [NSJSONSerialization JSONObjectWithData:d2 options:0 error:NULL] : nil;
                NSDictionary *dd = [j2 isKindOfClass:[NSDictionary class]] ? j2[@"data"] : nil;
                NSString *cssStr = [dd[@"stylesheet"] isKindOfClass:[NSString class]] ? dd[@"stylesheet"] : nil;
                NSArray *imgs = [dd[@"images"] isKindOfClass:[NSArray class]] ? dd[@"images"] : @[];
                NSDictionary *spriteMap = cssStr ? ApolloUserFlairParseSpriteCSS(cssStr, imgs) : nil;
                if (spriteMap.count == 0) { ApolloLog(@"[UserFlair] sprite CSS not parseable — using names"); return; }
                NSSet *sheetURLs = [NSSet setWithArray:[spriteMap.allValues valueForKeyPath:@"url"]];
                ApolloLog(@"[UserFlair] sprite map: %lu classes, %lu sheet(s)", (unsigned long)spriteMap.count, (unsigned long)sheetURLs.count);
                dispatch_group_t grp = dispatch_group_create();
                for (NSString *u in sheetURLs) {
                    if ([ApolloUserFlairSheetCache() objectForKey:u]) continue;
                    NSURL *url = [NSURL URLWithString:u]; if (!url) continue;
                    dispatch_group_enter(grp);
                    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *id_, NSURLResponse *ir, NSError *ie) {
                        UIImage *im = id_ ? [UIImage imageWithData:id_] : nil;
                        if (im) [ApolloUserFlairSheetCache() setObject:im forKey:u];
                        dispatch_group_leave(grp);
                    }] resume];
                }
                dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
                    UIViewController *c2 = wc; if (!c2) return;
                    objc_setAssociatedObject(c2, &kApolloUserFlairSpriteMapKey, spriteMap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    reload(); // now sprites can crop+render
                });
            }] resume];
        });
    }] resume];
}

// YES when the presenter chain contains Apollo's flair selector. Used to scope
// alert suppression to that screen. NOTE: Apollo presents this alert *before* it
// stores self.flairOptions (verified in the binary), so the collapse model is not
// yet computable here — we deliberately key off the controller's presence, not
// its model. The alert's title is unique to this one situation, so this is safe.
static BOOL ApolloUserFlairPresenterHasFlairSelector(UIViewController *presenter) {
    Class flairClass = objc_getClass("_TtC6Apollo27FlairSelectorViewController");
    if (!flairClass) return NO;

    NSMutableArray<UIViewController *> *candidates = [NSMutableArray array];
    if (presenter) [candidates addObject:presenter];
    if ([presenter isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)presenter;
        [candidates addObjectsFromArray:nav.viewControllers];
    }
    if (presenter.presentedViewController) [candidates addObject:presenter.presentedViewController];

    for (UIViewController *candidate in candidates) {
        if ([candidate isKindOfClass:flairClass]) return YES;
    }
    return NO;
}

#pragma mark - Hooks

// Signatures confirmed from Apollo's RedditKit binary:
//   userFlairOptions... completion = void (^)(NSArray *, NSError *)
//   setUserFlair... / setShowUserFlair... completion = void (^)(NSError *)
// The API-key path remains byte-for-byte native; only the active account's
// explicit Web JSON session takes this bridge.
%hook RDKClient

- (id)userFlairOptionsForSubredditWithName:(NSString *)subreddit completion:(id)completion {
    if (!ApolloWebJSONHasUsableSession()) return %orig;
    return ApolloUserFlairFetchWebOptions(subreddit, completion);
}

- (id)setUserFlairForSubredditWithName:(NSString *)subreddit
                                  text:(NSString *)text
                            templateID:(NSString *)templateID
                            completion:(id)completion {
    if (!ApolloWebJSONHasUsableSession()) return %orig;
    return ApolloUserFlairPerformWebUpdate(@"/api/selectflair", subreddit, @{
        @"flair_template_id": templateID ?: @"",
        @"text": text ?: @"",
    }, completion);
}

- (id)setShowUserFlair:(BOOL)show subredditName:(NSString *)subreddit completion:(id)completion {
    if (!ApolloWebJSONHasUsableSession()) return %orig;
    return ApolloUserFlairPerformWebUpdate(@"/api/setflairenabled", subreddit, @{
        @"flair_enabled": show ? @"true" : @"false",
    }, completion);
}

%end

// Swallow Apollo's "Subreddit Uses 'Old' Flair System" alert app-wide. The alert
// claims Apollo "is unable to properly interact" with the subreddit, which is no
// longer true once we collapse the empty templates into a usable custom-flair
// row. We only suppress it when Apollo's flair selector is the screen presenting
// it (the alert is presented off the selector's nav container, not the controller
// itself, hence this global hook); its title is unique to this one situation.
%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        NSString *title = [(UIAlertController *)viewControllerToPresent title] ?: @"";
        if ([title localizedCaseInsensitiveContainsString:@"Old"] &&
            [title localizedCaseInsensitiveContainsString:@"Flair System"] &&
            ApolloUserFlairPresenterHasFlairSelector((UIViewController *)self)) {
            ApolloLog(@"[UserFlair] suppressed old-flair-system alert (presenter=%@)", NSStringFromClass([self class]));
            if (completion) completion();
            return;
        }
    }
    %orig;
}

%end

%hook _TtC6Apollo27FlairSelectorViewController

- (NSInteger)tableNode:(id)tableNode numberOfRowsInSection:(NSInteger)section {
    if (section == kApolloUserFlairOptionsSection) {
        NSString *sub = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject((UIViewController *)self, 0));
        ApolloUserFlairFetchCurrentFlair((UIViewController *)self, sub);
        ApolloUserFlairFetchSpriteData((UIViewController *)self, sub);
        ApolloUserFlairCollapseModel *model = ApolloUserFlairCollapseModelFor((UIViewController *)self);
        if (model.active) return (NSInteger)model.realRows.count;
    }
    return %orig;
}

- (id)tableNode:(id)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != kApolloUserFlairOptionsSection) return %orig;

    // Map the displayed row back to the real flairOptions index when collapsed.
    ApolloUserFlairCollapseModel *model = ApolloUserFlairCollapseModelFor((UIViewController *)self);
    NSInteger realRow = indexPath.row;
    BOOL isCustomRow = NO;
    NSIndexPath *effectiveIndexPath = indexPath;
    if (model.active) {
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)model.realRows.count) return %orig;
        realRow = [model.realRows[indexPath.row] integerValue];
        isCustomRow = (realRow == model.customRealRow);
        effectiveIndexPath = [NSIndexPath indexPathForRow:realRow inSection:kApolloUserFlairOptionsSection];
    }

    id originalBlock = %orig(tableNode, effectiveIndexPath);
    if (!originalBlock) return originalBlock;
    (void)isCustomRow;

    // Decide what this row should render via the option's (otherwise empty) getters:
    //  - the user's CURRENT flair, if it belongs on this row (so you can see it); or
    //  - a "Set custom flair…" placeholder, if the row is blank but editable.
    // Labelled rows that aren't the current flair are left to Apollo.
    // These are STRONG so the async cell block retains them — the synthetic flair
    // pieces are freshly built (autoreleased) and would otherwise dangle.
    id customRowOption = nil;
    NSArray *customRowFlairs = nil;
    NSString *customRowText = nil;
    {
        NSArray *options = ApolloUserFlairControllerOptions((UIViewController *)self);
        BOOL isInfoRow = (model.active && model.infoMode && realRow == model.customRealRow);
        if (isInfoRow) {
            // The whole subreddit's flair is empty + non-editable: show one notice
            // instead of a wall of dead rows. Tapping it explains (see didSelect).
            id opt = (realRow < (NSInteger)options.count) ? options[realRow] : nil;
            if (opt) {
                id piece = ApolloUserFlairMakeTextFlair(kApolloUserFlairNoFlairsRowText);
                customRowOption = opt;
                customRowFlairs = piece ? @[piece] : nil;
                customRowText = kApolloUserFlairNoFlairsRowText;
            }
        } else if (realRow >= 0 && realRow < (NSInteger)options.count) {
            id opt = options[realRow];

            // Old-reddit CSS-class flair: show the prettified class name as the row
            // label, plus the real cropped sprite (when the stylesheet parsed) as an
            // image alongside it. Both are persisted on the option so Apollo's async
            // layout pass renders them (the thread-locals are cleared by then);
            // textRepresentation drives the label, `flairs` the sprite image. The
            // committed selection is the bare template (we never touch the model).
            //
            // Only do this for templates that have NO real text of their own. Some
            // subs (e.g. r/steinsgate) give each template BOTH a css class AND a real
            // flair_text name ("suzuha amane") — for those the name is the right label,
            // so leave them to Apollo's native rendering instead of prettifying the
            // css class into nonsense like "Avatar Img Sg Rc 0".
            NSString *cssClass = ApolloUserFlairCssClassForOption((UIViewController *)self, opt);
            // Use the template's REAL text only (textRepresentation / flair_text), NOT
            // ApolloUserFlairOptionText — that falls back to the `flairs` getter, which
            // we override with our synthetic sprite+name, so it would read back our own
            // label on re-render and wrongly suppress the sprite (feedback loop).
            NSString *realText = ApolloUserFlairObjectString(opt, @[@"textRepresentation", @"text", @"flairText", @"flair_text", @"plainText"]);
            if (cssClass && !ApolloUserFlairStringIsBlank(realText)) {
                cssClass = nil; // labeled template — render its real name natively
            }
            if (cssClass) {
                NSString *name = ApolloUserFlairPrettifyClass(cssClass);
                NSString *spriteFile = ApolloUserFlairSpriteFileForClass((UIViewController *)self, cssClass);
                // The selector cell renders an option's `flairs` pieces (it ignores
                // textRepresentation), so build the row from pieces: the real cropped
                // sprite (when the stylesheet parsed) followed by the prettified class
                // name, so near-identical sprites (e.g. the many Marios) stay legible.
                // When the sheet can't be parsed we fall back to the name alone.
                NSMutableArray *pieces = [NSMutableArray array];
                if (spriteFile) {
                    id sprite = ApolloUserFlairMakeEmojiFlair(cssClass, spriteFile);
                    if (sprite) [pieces addObject:sprite];
                }
                if (name.length) {
                    NSString *label = pieces.count ? [@" " stringByAppendingString:name] : name;
                    id text = ApolloUserFlairMakeTextFlair(label);
                    if (text) [pieces addObject:text];
                }
                if (pieces.count) {
                    // Persist on the option so Apollo's async layout pass renders it
                    // (the thread-local override below is cleared by then). Only
                    // `flairs` is overridden — textRepresentation is left as the
                    // template's real (empty) text, so committing selects the bare
                    // template, never our synthetic display text.
                    objc_setAssociatedObject(opt, &kApolloUserFlairOptionDisplayFlairsKey, pieces, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    customRowOption = opt;
                    customRowFlairs = pieces;
                }
            }

            if (!customRowOption) {
                NSString *currentText = ApolloUserFlairCurrentFlairTextForOption((UIViewController *)self, opt);
                // When templates are collapsed into one representative row, the current
                // flair may live on a different (hidden) empty template — they're all
                // equivalent, so show it on the representative regardless of which one.
                if (currentText.length == 0 && isCustomRow) {
                    NSDictionary *cur = objc_getAssociatedObject((UIViewController *)self, &kApolloUserFlairCurrentFlairKey);
                    NSString *t = cur[@"text"];
                    if ([t isKindOfClass:[NSString class]] && t.length > 0) currentText = t;
                }
                BOOL blankEditable = ApolloUserFlairOptionIsBlankEditable(opt);
                if (currentText.length > 0) {
                    NSString *sub = ApolloUserFlairCleanSubredditName(ApolloUserFlairSubredditNameFromObject((UIViewController *)self, 0));
                    NSArray *pieces = ApolloUserFlairPiecesFromFlairText(currentText, sub.lowercaseString);
                    if (pieces.count) {
                        customRowOption = opt;
                        customRowFlairs = pieces;
                        customRowText = currentText;
                    } else if (blankEditable) {
                        // Have a current flair but couldn't build pieces (e.g. RDKFlair
                        // unavailable) — don't leave a blank row; show the placeholder.
                        customRowOption = opt;
                        customRowFlairs = ApolloUserFlairPlaceholderFlairs();
                        customRowText = kApolloUserFlairCustomRowText;
                    }
                } else if (blankEditable) {
                    customRowOption = opt;
                    customRowFlairs = ApolloUserFlairPlaceholderFlairs();
                    customRowText = kApolloUserFlairCustomRowText;
                }
            }
        }
    }

    id copiedBlock = [originalBlock copy];
    __weak UIViewController *weakController = (UIViewController *)self;
    NSInteger captureRow = realRow;

    return [^id {
        UIViewController *strongController = weakController;
        UIViewController *previousController = tApolloUserFlairCaptureController;
        NSInteger previousSection = tApolloUserFlairCaptureSection;
        NSInteger previousRow = tApolloUserFlairCaptureRow;
        id previousCustomOption = tApolloUserFlairCustomRowOption;
        NSArray *previousCustomFlairs = tApolloUserFlairCustomRowFlairs;
        NSString *previousCustomText = tApolloUserFlairCustomRowDisplayText;
        id node = nil;

        tApolloUserFlairCaptureController = strongController;
        tApolloUserFlairCaptureSection = kApolloUserFlairOptionsSection;
        tApolloUserFlairCaptureRow = captureRow;
        tApolloUserFlairCustomRowOption = customRowOption;
        tApolloUserFlairCustomRowFlairs = customRowFlairs;
        tApolloUserFlairCustomRowDisplayText = customRowText;
        @try {
            node = ((id (^)(void))copiedBlock)();
        } @finally {
            tApolloUserFlairCaptureController = previousController;
            tApolloUserFlairCaptureSection = previousSection;
            tApolloUserFlairCaptureRow = previousRow;
            tApolloUserFlairCustomRowOption = previousCustomOption;
            tApolloUserFlairCustomRowFlairs = previousCustomFlairs;
            tApolloUserFlairCustomRowDisplayText = previousCustomText;
        }

        return node;
    } copy];
}

- (void)tableNode:(id)tableNode didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSIndexPath *effectiveIndexPath = indexPath;
    ApolloUserFlairCollapseModel *model = (indexPath.section == kApolloUserFlairOptionsSection)
        ? ApolloUserFlairCollapseModelFor((UIViewController *)self) : nil;
    if (model.active && indexPath.row >= 0 && indexPath.row < (NSInteger)model.realRows.count) {
        effectiveIndexPath = [NSIndexPath indexPathForRow:[model.realRows[indexPath.row] integerValue]
                                               inSection:kApolloUserFlairOptionsSection];
    }

    // The "no usable flairs" notice isn't a real choice — explain instead of selecting.
    if (model.active && model.infoMode && effectiveIndexPath.row == model.customRealRow) {
        if ([tableNode respondsToSelector:@selector(deselectRowAtIndexPath:animated:)]) {
            ((void (*)(id, SEL, NSIndexPath *, BOOL))objc_msgSend)(tableNode, @selector(deselectRowAtIndexPath:animated:), indexPath, NO);
        }
        UIAlertController *info = [UIAlertController alertControllerWithTitle:@"No Usable Flairs"
            message:@"This community has flair enabled, but every flair option is empty and can't be edited, so there's nothing to apply. That's the subreddit's own setup — not an Apollo limitation."
            preferredStyle:UIAlertControllerStyleAlert];
        [info addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [ApolloUserFlairPresenterForController((UIViewController *)self) presentViewController:info animated:YES completion:nil];
        return;
    }

    // Some subreddits surface their flair through an EXTERNAL tool, exposing a row
    // whose "text" is just an instruction with a link (e.g. r/anime: "Go to
    // https://flair.r-anime.moe to get your flair!", r/CFB: "More flair options at
    // https://flair.redditcfb.com!"). There's nothing to apply, so open the link in
    // an in-app browser instead of selecting/committing it. ApolloUserFlairOptionIsLinkInstruction
    // works regardless of whether the row is editable (an editable tool row would
    // otherwise pop the editor pre-filled with the instruction string) and won't
    // hijack real image/text flairs.
    {
        id opt = ApolloUserFlairCapturedOptionAtIndexPath((UIViewController *)self, effectiveIndexPath);
        NSURL *link = nil;
        if (ApolloUserFlairOptionIsLinkInstruction(opt, &link) && link) {
            if ([tableNode respondsToSelector:@selector(deselectRowAtIndexPath:animated:)]) {
                ((void (*)(id, SEL, NSIndexPath *, BOOL))objc_msgSend)(tableNode, @selector(deselectRowAtIndexPath:animated:), indexPath, NO);
            }
            ApolloUserFlairOpenURLInApp((UIViewController *)self, link);
            ApolloLog(@"[UserFlair] flair-tool link row -> opened %@ in-app", link.absoluteString);
            return;
        }
    }

    id tappedOption = ApolloUserFlairCapturedOptionAtIndexPath((UIViewController *)self, effectiveIndexPath);
    %orig(tableNode, effectiveIndexPath);

    // When collapsed, the displayed row index differs from the real index Apollo
    // just selected, so the checkmark may land on the wrong (off-screen) row.
    // Reload so the visible rows recompute their checkmark from currentFlairID.
    if (model.active && [tableNode respondsToSelector:@selector(reloadData)]) {
        ((void (*)(id, SEL))objc_msgSend)(tableNode, @selector(reloadData));
    }

    // Old-reddit css-class flairs are preset character templates, not free-text:
    // selecting one is the whole interaction (Update then commits the bare
    // template). Don't pop the text editor for these — only for genuinely
    // editable/custom rows.
    if (tappedOption && objc_getAssociatedObject(tappedOption, &kApolloUserFlairOptionDisplayFlairsKey)) {
        return;
    }

    __weak UIViewController *weakController = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController) return;
        ApolloUserFlairMaybePresentEditorForOption(strongController, tappedOption, strongController, @"row-select");
    });
}

%end

%hook RDKFlairOption

- (NSString *)identifier {
    NSString *identifier = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return identifier;
}

- (NSString *)textRepresentation {
    NSString *textRepresentation = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    if (tApolloUserFlairCustomRowOption && tApolloUserFlairCustomRowOption == self && tApolloUserFlairCustomRowDisplayText) {
        return tApolloUserFlairCustomRowDisplayText;
    }
    return textRepresentation;
}

- (BOOL)isEditable {
    BOOL editable = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    return editable;
}

- (NSArray *)flairs {
    NSArray *flairs = %orig;
    ApolloUserFlairCaptureOptionIfNeeded(self);
    if (tApolloUserFlairCustomRowOption && tApolloUserFlairCustomRowOption == self && tApolloUserFlairCustomRowFlairs) {
        return tApolloUserFlairCustomRowFlairs;
    }
    // Persistent css-class sprite/name override (read by the async layout pass).
    NSArray *display = objc_getAssociatedObject(self, &kApolloUserFlairOptionDisplayFlairsKey);
    if ([display isKindOfClass:[NSArray class]] && display.count) return display;
    return flairs;
}

%end

// Our cropped old-reddit sprites live on disk as file:// URLs, but Apollo's flair
// emoji images load through ASNetworkImageNode's HTTP-only downloader, which can't
// fetch file:// (the request silently produces no image — blank rows). Intercept the
// URL setter: when it's one of our sprite files, set the cached cropped UIImage
// directly and skip the network path entirely. Real (https) emoji URLs are untouched.
static BOOL ApolloUserFlairTrySetSpriteImage(id imageNode, NSURL *url) {
    if (![url isKindOfClass:[NSURL class]] || !url.isFileURL) return NO;
    NSString *path = url.path;
    if (![[path lastPathComponent] hasPrefix:kApolloUserFlairSpriteFilePrefix]) return NO;
    UIImage *img = nil;
    @synchronized (ApolloUserFlairSpriteImageByPath()) { img = ApolloUserFlairSpriteImageByPath()[path]; }
    if (!img) img = [UIImage imageWithContentsOfFile:path];
    if (!img) return NO;
    if ([imageNode respondsToSelector:@selector(setImage:)]) {
        ((void (*)(id, SEL, UIImage *))objc_msgSend)(imageNode, @selector(setImage:), img);
        return YES;
    }
    return NO;
}

%hook ASNetworkImageNode

- (void)setURL:(NSURL *)URL {
    if (ApolloUserFlairTrySetSpriteImage(self, URL)) return;
    %orig;
}

- (void)setURL:(NSURL *)URL resetToDefault:(BOOL)reset {
    if (ApolloUserFlairTrySetSpriteImage(self, URL)) return;
    %orig;
}

%end
