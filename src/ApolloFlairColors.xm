// ApolloFlairColors.xm
//
// Colors post (link) flairs and user/author flairs with the colors each
// subreddit assigns on Reddit (filled pill background + matching text color),
// instead of Apollo's default flat grey styling.
//
// Why this is non-trivial: Apollo's Mantle data models (RDKLink / RDKComment /
// RDKFlair) DROP Reddit's flair color fields during JSON deserialization — they
// only keep the flair text / richtext, never link_flair_background_color,
// link_flair_text_color, author_flair_background_color or author_flair_text_color.
// So we cannot simply read a property at render time; we have to recover the
// colors from the raw JSON as Mantle ingests it, carry them to the RDKFlair
// objects, then apply them when Apollo's Swift FlairNode renders.
//
// Pipeline:
//   1. Hook -[MTLJSONAdapter modelFromJSONDictionary:error:] (the universal
//      Mantle deserialization entry point, used for both top-level and nested
//      models). When the produced model is an RDKLink / RDKComment, read the
//      four color keys from the JSON dict and (a) attach parsed UIColors onto
//      every RDKFlair instance in the model's flair arrays via associated
//      objects, and (b) record them in a text-keyed fallback cache (covers
//      plain-text flairs that Apollo rebuilds as fresh RDKFlair instances).
//   2. Hook _TtC6Apollo9FlairNode (Swift) didLoad / didEnterPreloadState. Read
//      the node's `flairs` (Swift Array<RDKFlair>) and `contentNodes`
//      (Swift Array<ASDisplayNode>) ivars, look up the recovered colors, and —
//      only when the toggle is on — paint the pill background + corner radius
//      and rewrite each text node's foreground color.
//
// Gated behind sEnableFlairColors (General settings → "Color Flairs", default
// off). When off or when no color was recovered, Apollo's default styling is
// left untouched.

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ASSizeRange is { CGSize min; CGSize max; }. Match the class-dumped
// layoutSpecThatFits: ABI used elsewhere in the tweak.
struct CDStruct_90e057aa { CGSize min; CGSize max; };

// Binary-compatible subset of Texture's ASDimension. We define it locally to
// avoid pulling Texture headers into the tweak build.
typedef NS_ENUM(NSInteger, ApolloFlairASDimensionUnit) {
    ApolloFlairASDimensionUnitAuto = 0,
    ApolloFlairASDimensionUnitPoints = 1,
    ApolloFlairASDimensionUnitFraction = 2,
};

typedef struct {
    ApolloFlairASDimensionUnit unit;
    CGFloat value;
} ApolloFlairASDimension;

#pragma mark - Associated object keys

// Attached to each RDKFlair instance that we recovered colors for.
static char kApolloFlairBackgroundColorKey;
static char kApolloFlairTextColorKey;
// Attached to a FlairNode once we've recolored its text (so reapply passes only
// touch the cheap, layout-safe background color and don't re-edit attributed
// text repeatedly).
static char kApolloFlairNodeTextAppliedKey;

#pragma mark - Fallback cache (text -> colors)

// Plain-text flairs (no richtext) are sometimes rebuilt by Apollo as fresh
// RDKFlair instances that never passed through our deserialization hook, so the
// associated-object link is lost. As a secondary lookup we remember the colors
// keyed by normalized flair text. Collisions across subreddits are possible but
// low-stakes (a flair occasionally taking the wrong shade), and the primary
// instance-identity path handles richtext flairs precisely.
static NSCache<NSString *, NSArray *> *sApolloFlairColorCache;

static NSString *ApolloFlairNormalizedText(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return trimmed.length > 0 ? trimmed : nil;
}

static void ApolloFlairCacheColors(NSString *text, UIColor *background, UIColor *textColor) {
    NSString *key = ApolloFlairNormalizedText(text);
    if (!key || !background) return;
    [sApolloFlairColorCache setObject:@[background, textColor ?: (id)[NSNull null]] forKey:key];
}

static BOOL ApolloFlairCachedColors(NSString *text, UIColor **outBackground, UIColor **outTextColor) {
    NSString *key = ApolloFlairNormalizedText(text);
    if (!key) return NO;
    NSArray *pair = [sApolloFlairColorCache objectForKey:key];
    if (pair.count != 2) return NO;
    if (outBackground) *outBackground = pair[0];
    if (outTextColor) *outTextColor = (pair[1] == [NSNull null]) ? nil : pair[1];
    return YES;
}

#pragma mark - Color parsing

// Reddit flair background colors arrive as "#rrggbb" (occasionally "#rrggbbaa"),
// or as "transparent" / "" when the subreddit hasn't set one.
static UIColor *ApolloFlairColorFromHex(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *hex = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (hex.length == 0) return nil;
    if ([hex.lowercaseString isEqualToString:@"transparent"]) return nil;
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    if (hex.length != 6 && hex.length != 8) return nil;

    unsigned int raw = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&raw]) return nil;

    CGFloat r, g, b, a;
    if (hex.length == 8) {
        r = ((raw >> 24) & 0xFF) / 255.0;
        g = ((raw >> 16) & 0xFF) / 255.0;
        b = ((raw >> 8) & 0xFF) / 255.0;
        a = (raw & 0xFF) / 255.0;
    } else {
        r = ((raw >> 16) & 0xFF) / 255.0;
        g = ((raw >> 8) & 0xFF) / 255.0;
        b = (raw & 0xFF) / 255.0;
        a = 1.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// Reddit specifies flair text color as the enum "light" (white text) or "dark"
// (near-black text). Default to white, which reads well on the saturated
// backgrounds subreddits typically use.
static UIColor *ApolloFlairTextColorForMode(id mode) {
    if ([mode isKindOfClass:[NSString class]] && [[(NSString *)mode lowercaseString] isEqualToString:@"dark"]) {
        return [UIColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:1.0];
    }
    return [UIColor whiteColor];
}

#pragma mark - Runtime helpers

static id ApolloFlairPerformObject(id target, SEL selector) {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *ApolloFlairArrayProperty(id model, SEL selector) {
    id value = ApolloFlairPerformObject(model, selector);
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
}

static NSString *ApolloFlairStringProperty(id model, SEL selector) {
    id value = ApolloFlairPerformObject(model, selector);
    return [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
}

static NSString *ApolloFlairText(id flair) {
    return ApolloFlairStringProperty(flair, @selector(text));
}

// Reads a Swift `Array<ObjCClass>` stored as an ivar. The ivar holds a single
// pointer to the array's backing storage; for class-element arrays that storage
// object is a subclass of NSArray (toll-free bridged), so we can use it directly
// once we confirm it answers as an NSArray.
static NSArray *ApolloFlairSwiftArrayIvar(id node, const char *name) {
    if (!node || !name) return nil;
    for (Class cls = object_getClass(node); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *raw = NULL;
        memcpy(&raw, (uint8_t *)(__bridge void *)node + offset, sizeof(raw));
        if (!raw) return nil;
        @try {
            id object = (__bridge id)raw;
            if ([object isKindOfClass:[NSArray class]]) return object;
        } @catch (__unused NSException *exception) {
        }
        return nil;
    }

    return nil;
}

static BOOL ApolloFlairBoolIvar(id node, const char *name) {
    if (!node || !name) return NO;
    for (Class cls = object_getClass(node); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || (type[0] != 'B' && type[0] != 'c' && type[0] != 'C')) return NO;
        ptrdiff_t offset = ivar_getOffset(ivar);
        return *(BOOL *)((uint8_t *)(__bridge void *)node + offset);
    }
    return NO;
}

#pragma mark - Recovery (Mantle deserialization)

static void ApolloFlairAnnotate(NSArray *flairs, UIColor *background, UIColor *textColor) {
    if (![flairs isKindOfClass:[NSArray class]] || !background) return;
    for (id flair in flairs) {
        objc_setAssociatedObject(flair, &kApolloFlairBackgroundColorKey, background, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(flair, &kApolloFlairTextColorKey, textColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloFlairCacheColors(ApolloFlairText(flair), background, textColor);
    }
}

static NSUInteger sApolloFlairRecoverLogCount = 0;

// Reddit sometimes nests the link/comment fields under a "data" sub-dictionary
// (the t3 / t1 "thing" wrapper). Pick whichever dict actually carries the flair
// keys so recovery works regardless of which layer Mantle handed us.
static NSDictionary *ApolloFlairFlairSource(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    if (json[@"link_flair_background_color"] || json[@"author_flair_background_color"] ||
        json[@"link_flair_text"] || json[@"link_flair_richtext"] ||
        json[@"author_flair_text"] || json[@"author_flair_richtext"]) {
        return json;
    }
    id data = json[@"data"];
    if ([data isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)data;
        if (d[@"link_flair_background_color"] || d[@"author_flair_background_color"] ||
            d[@"link_flair_text"] || d[@"link_flair_richtext"] ||
            d[@"author_flair_text"] || d[@"author_flair_richtext"]) {
            return d;
        }
    }
    return json;
}

static void ApolloFlairRecoverColors(id model, NSDictionary *rawJson, BOOL isLink) {
    NSDictionary *json = ApolloFlairFlairSource(rawJson);
    if (![json isKindOfClass:[NSDictionary class]]) return;

    if (isLink) {
        UIColor *linkBG = ApolloFlairColorFromHex(json[@"link_flair_background_color"]);
        if (linkBG) {
            UIColor *linkText = ApolloFlairTextColorForMode(json[@"link_flair_text_color"]);
            ApolloFlairAnnotate(ApolloFlairArrayProperty(model, @selector(linkFlair)), linkBG, linkText);
            ApolloFlairAnnotate(ApolloFlairArrayProperty(model, @selector(linkFlairRichText)), linkBG, linkText);
            ApolloFlairCacheColors(ApolloFlairStringProperty(model, @selector(linkFlairText)), linkBG, linkText);
            if (sApolloFlairRecoverLogCount < 30) {
                sApolloFlairRecoverLogCount++;
                ApolloLog(@"[FlairColors] recovered link flair bg=%@ textMode=%@", json[@"link_flair_background_color"], json[@"link_flair_text_color"]);
            }
        }
    }

    UIColor *authorBG = ApolloFlairColorFromHex(json[@"author_flair_background_color"]);
    if (authorBG) {
        UIColor *authorText = ApolloFlairTextColorForMode(json[@"author_flair_text_color"]);
        ApolloFlairAnnotate(ApolloFlairArrayProperty(model, @selector(authorFlair)), authorBG, authorText);
        ApolloFlairAnnotate(ApolloFlairArrayProperty(model, @selector(authorFlairRichtext)), authorBG, authorText);
        ApolloFlairCacheColors(ApolloFlairStringProperty(model, @selector(authorFlairPlaintext)), authorBG, authorText);
        if (sApolloFlairRecoverLogCount < 30) {
            sApolloFlairRecoverLogCount++;
            ApolloLog(@"[FlairColors] recovered author flair bg=%@ textMode=%@", json[@"author_flair_background_color"], json[@"author_flair_text_color"]);
        }
    }
}

#pragma mark - Application (FlairNode render)

// When Reddit didn't assign a flair color (many subreddits leave the default),
// generate a stable, readable color from the flair text so the pill still pops.
// Same text always yields the same color (deterministic FNV-1a hash -> hue).
static BOOL ApolloFlairGeneratedColors(NSString *text, UIColor **outBackground, UIColor **outTextColor) {
    NSString *key = ApolloFlairNormalizedText(text);
    if (!key) return NO;

    // FNV-1a over the UTF-8 bytes for a well-distributed, stable hash.
    uint32_t hash = 2166136261u;
    const char *bytes = key.UTF8String;
    for (const char *p = bytes; p && *p; p++) {
        hash ^= (uint8_t)(*p);
        hash *= 16777619u;
    }

    CGFloat hue = (hash % 360) / 360.0;
    CGFloat saturation = 0.55;
    CGFloat brightness = 0.62; // mid brightness reads well under white text

    UIColor *background = [UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1.0];

    // Choose black/white text by perceived luminance for contrast safety.
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [background getRed:&r green:&g blue:&b alpha:&a];
    CGFloat luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    UIColor *textColor = (luminance > 0.6) ? [UIColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:1.0]
                                           : [UIColor whiteColor];

    if (outBackground) *outBackground = background;
    if (outTextColor) *outTextColor = textColor;
    return YES;
}

// Resolve the recovered colors for a FlairNode: prefer the precise associated
// objects on its flair instances, fall back to the text-keyed cache.
static BOOL ApolloFlairResolveColors(NSArray *flairs, UIColor **outBackground, UIColor **outTextColor) {
    if (![flairs isKindOfClass:[NSArray class]]) return NO;

    for (id flair in flairs) {
        UIColor *background = objc_getAssociatedObject(flair, &kApolloFlairBackgroundColorKey);
        if (background) {
            if (outBackground) *outBackground = background;
            if (outTextColor) *outTextColor = objc_getAssociatedObject(flair, &kApolloFlairTextColorKey);
            return YES;
        }
    }

    for (id flair in flairs) {
        UIColor *background = nil, *textColor = nil;
        if (ApolloFlairCachedColors(ApolloFlairText(flair), &background, &textColor)) {
            if (outBackground) *outBackground = background;
            if (outTextColor) *outTextColor = textColor;
            return YES;
        }
    }
    return NO;
}

static void ApolloFlairSetBackground(id node, UIColor *background) {
    ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setBackgroundColor:), background);
    ((void (*)(id, SEL, double))objc_msgSend)(node, @selector(setCornerRadius:), 4.0);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(node, @selector(setClipsToBounds:), YES);
}

static CGFloat ApolloFlairMaxTextHeight(NSArray *contentNodes) {
    if (![contentNodes isKindOfClass:[NSArray class]]) return 0.0;

    CGFloat maxHeight = 0.0;
    for (id contentNode in contentNodes) {
        if (![contentNode respondsToSelector:@selector(attributedText)]) continue;
        id attributed = ApolloFlairPerformObject(contentNode, @selector(attributedText));
        if (![attributed isKindOfClass:[NSAttributedString class]] || [(NSAttributedString *)attributed length] == 0) continue;

        NSAttributedString *text = (NSAttributedString *)attributed;
        __block CGFloat maxLineHeight = 0.0;
        [text enumerateAttribute:NSFontAttributeName
                         inRange:NSMakeRange(0, text.length)
                         options:0
                      usingBlock:^(id value, __unused NSRange range, __unused BOOL *stop) {
            if ([value isKindOfClass:[UIFont class]]) {
                maxLineHeight = MAX(maxLineHeight, [(UIFont *)value lineHeight]);
            }
        }];

        CGRect bounds = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                          context:nil];
        maxHeight = MAX(maxHeight, ceil(MAX(maxLineHeight, bounds.size.height)));
    }
    return maxHeight;
}

static void ApolloFlairSetLayoutMaxHeight(id layoutElement, CGFloat height) {
    if (!layoutElement || !isfinite(height) || height <= 0.0) return;
    id style = ApolloFlairPerformObject(layoutElement, @selector(style));
    if (!style || ![style respondsToSelector:@selector(setMaxHeight:)]) return;

    ApolloFlairASDimension dimension = { ApolloFlairASDimensionUnitPoints, height };
    ((void (*)(id, SEL, ApolloFlairASDimension))objc_msgSend)(style, @selector(setMaxHeight:), dimension);
}

static void ApolloFlairFixMaxHeight(id node, id layoutSpec) {
    NSArray *contentNodes = ApolloFlairSwiftArrayIvar(node, "contentNodes");
    CGFloat textHeight = ApolloFlairMaxTextHeight(contentNodes);
    if (textHeight <= 0.0) return;

    BOOL isForAlert = ApolloFlairBoolIvar(node, "isForAlert");
    CGFloat nativeMaxHeight = isForAlert ? 21.0 : 16.0;
    CGFloat desiredMaxHeight = MAX(nativeMaxHeight, ceil(textHeight + 2.0));
    if (desiredMaxHeight <= nativeMaxHeight + 0.5) return;

    id innerStack = ApolloFlairPerformObject(layoutSpec, @selector(child));
    ApolloFlairSetLayoutMaxHeight(innerStack ?: layoutSpec, desiredMaxHeight);
}

static void ApolloFlairRecolorTextNodes(NSArray *contentNodes, UIColor *textColor) {
    if (![contentNodes isKindOfClass:[NSArray class]]) return;
    Class imageNodeClass = objc_getClass("ASImageNode");
    UIColor *foreground = textColor ?: [UIColor whiteColor];

    for (id contentNode in contentNodes) {
        // Recolor text runs (leave emoji/image attachments alone).
        if ([contentNode respondsToSelector:@selector(attributedText)] &&
            [contentNode respondsToSelector:@selector(setAttributedText:)]) {
            id attributed = ApolloFlairPerformObject(contentNode, @selector(attributedText));
            if ([attributed isKindOfClass:[NSAttributedString class]] && [(NSAttributedString *)attributed length] > 0) {
                NSMutableAttributedString *recolored = [(NSAttributedString *)attributed mutableCopy];
                [recolored addAttribute:NSForegroundColorAttributeName value:foreground range:NSMakeRange(0, recolored.length)];
                ((void (*)(id, SEL, id))objc_msgSend)(contentNode, @selector(setAttributedText:), recolored);
            }
            continue;
        }
        // A bare ASDisplayNode (not a text or image node) is almost always a
        // background/fill node — tint it so the pill picks up the flair color
        // even when the background isn't drawn by the node itself.
        if (object_getClass(contentNode) == objc_getClass("ASDisplayNode") &&
            !(imageNodeClass && [contentNode isKindOfClass:imageNodeClass])) {
            ((void (*)(id, SEL, id))objc_msgSend)(contentNode, @selector(setBackgroundColor:), [UIColor clearColor]);
        }
    }
}

static void ApolloFlairApply(id node, BOOL allowTextRecolor) {
    if (!sEnableFlairColors || !node) return;

    NSArray *flairs = ApolloFlairSwiftArrayIvar(node, "flairs");
    if (flairs.count == 0) return;

    UIColor *background = nil, *textColor = nil;
    // Prefer Reddit's assigned color; otherwise generate a stable color from the
    // flair text so flairs still stand out in subreddits that set no color.
    if (!ApolloFlairResolveColors(flairs, &background, &textColor) || !background) {
        NSString *text = ApolloFlairText(flairs.firstObject);
        if (!ApolloFlairGeneratedColors(text, &background, &textColor) || !background) return;
    }

    ApolloFlairSetBackground(node, background);

    if (allowTextRecolor && !objc_getAssociatedObject(node, &kApolloFlairNodeTextAppliedKey)) {
        objc_setAssociatedObject(node, &kApolloFlairNodeTextAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSArray *contentNodes = ApolloFlairSwiftArrayIvar(node, "contentNodes");
        ApolloFlairRecolorTextNodes(contentNodes, textColor);
    }
}

// Recover flair colors for any model produced from a single JSON dictionary.
static void ApolloFlairRecoverForModel(id model, NSDictionary *json) {
    if (!model || ![json isKindOfClass:[NSDictionary class]]) return;
    @try {
        Class linkClass = objc_getClass("RDKLink");
        Class commentClass = objc_getClass("RDKComment");
        if (linkClass && [model isKindOfClass:linkClass]) {
            static NSUInteger sLinkLog = 0;
            if (sLinkLog < 10) {
                sLinkLog++;
                ApolloLog(@"[FlairColors] adapter RDKLink hasBGKey=%d bg=%@ flairKeys=%@",
                          (int)(json[@"link_flair_background_color"] != nil),
                          json[@"link_flair_background_color"],
                          json[@"link_flair_richtext"] ? @"richtext" : (json[@"link_flair_text"] ? @"text" : @"none"));
            }
            ApolloFlairRecoverColors(model, json, YES);
        } else if (commentClass && [model isKindOfClass:commentClass]) {
            ApolloFlairRecoverColors(model, json, NO);
        }
    } @catch (__unused NSException *exception) {
    }
}

%hook MTLJSONAdapter

// Universal single-object funnel used by RedditKit. RedditKit calls the class
// methods directly (not the instance method), so we must hook here.
+ (id)modelOfClass:(Class)modelClass fromJSONDictionary:(NSDictionary *)JSONDictionary error:(NSError **)error {
    id model = %orig;
    static NSUInteger sClassLog = 0;
    if (sClassLog < 5) {
        sClassLog++;
        ApolloLog(@"[FlairColors] +modelOfClass:%@ fromJSONDictionary fired", NSStringFromClass(modelClass));
    }
    ApolloFlairRecoverForModel(model, JSONDictionary);
    return model;
}

// Listing/array funnel — JSON array and model array are index-parallel.
+ (id)modelsOfClass:(Class)modelClass fromJSONArray:(NSArray *)JSONArray error:(NSError **)error {
    id models = %orig;
    static NSUInteger sArrayLog = 0;
    if (sArrayLog < 5) {
        sArrayLog++;
        ApolloLog(@"[FlairColors] +modelsOfClass:%@ fromJSONArray count=%lu fired",
                  NSStringFromClass(modelClass), (unsigned long)([JSONArray isKindOfClass:[NSArray class]] ? JSONArray.count : 0));
    }
    if ([models isKindOfClass:[NSArray class]] && [JSONArray isKindOfClass:[NSArray class]] &&
        [(NSArray *)models count] == JSONArray.count) {
        NSArray *modelArray = (NSArray *)models;
        for (NSUInteger i = 0; i < modelArray.count; i++) {
            id json = JSONArray[i];
            if ([json isKindOfClass:[NSDictionary class]]) {
                ApolloFlairRecoverForModel(modelArray[i], (NSDictionary *)json);
            }
        }
    }
    return models;
}

- (id)modelFromJSONDictionary:(NSDictionary *)JSONDictionary error:(NSError **)error {
    id model = %orig;
    ApolloFlairRecoverForModel(model, JSONDictionary);
    return model;
}

%end

%hook _TtC6Apollo9FlairNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    id spec = %orig;
    ApolloFlairFixMaxHeight((id)self, spec);
    return spec;
}

- (void)didLoad {
    %orig;
    static NSUInteger sDidLoadLogCount = 0;
    if (sDidLoadLogCount < 20) {
        sDidLoadLogCount++;
        NSArray *flairs = ApolloFlairSwiftArrayIvar(self, "flairs");
        UIColor *bg = nil, *tx = nil;
        BOOL resolved = ApolloFlairResolveColors(flairs, &bg, &tx);
        ApolloLog(@"[FlairColors] FlairNode.didLoad enabled=%d flairs=%lu firstText=%@ resolved=%d bg=%@",
                  (int)sEnableFlairColors, (unsigned long)flairs.count,
                  flairs.count ? ApolloFlairText(flairs.firstObject) : @"(none)", (int)resolved, bg);
    }
    ApolloFlairApply(self, YES);
}

- (void)didEnterPreloadState {
    %orig;
    // Reapply only the (layout-safe) background in case Apollo re-set it after
    // didLoad; text was already handled and is guarded against repeats.
    ApolloFlairApply(self, NO);
}

%end

#pragma mark - Constructor

%ctor {
    sApolloFlairColorCache = [NSCache new];
    sApolloFlairColorCache.countLimit = 512;
    ApolloLog(@"[FlairColors] ctor: module loaded enabled=%d FlairNodeClass=%p MTLJSONAdapterClass=%p RDKLink=%p RDKComment=%p",
              (int)sEnableFlairColors,
              objc_getClass("_TtC6Apollo9FlairNode"),
              objc_getClass("MTLJSONAdapter"),
              objc_getClass("RDKLink"),
              objc_getClass("RDKComment"));
}
