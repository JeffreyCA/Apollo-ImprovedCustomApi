#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

static const void *kApolloOriginalAttributedTextKey = &kApolloOriginalAttributedTextKey;
static const void *kApolloTranslatedTextNodeKey = &kApolloTranslatedTextNodeKey;
static const void *kApolloCellTranslationKeyKey = &kApolloCellTranslationKeyKey;
static const void *kApolloThreadTranslatedModeKey = &kApolloThreadTranslatedModeKey;
static const void *kApolloTranslateBarButtonKey = &kApolloTranslateBarButtonKey;

static NSString *const kApolloDefaultLibreTranslateURL = @"https://libretranslate.de/translate";

static NSCache<NSString *, NSString *> *sTranslationCache;
static NSMutableDictionary<NSString *, NSMutableArray *> *sPendingTranslationCallbacks;
static __weak UIViewController *sVisibleCommentsViewController = nil;

static id GetIvarObjectQuiet(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable([obj class], ivarName);
    return ivar ? object_getIvar(obj, ivar) : nil;
}

static UITableView *FindFirstTableViewInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) {
        return (UITableView *)view;
    }

    for (UIView *subview in view.subviews) {
        UITableView *tableView = FindFirstTableViewInView(subview);
        if (tableView) return tableView;
    }

    return nil;
}

static UITableView *GetCommentsTableView(UIViewController *viewController) {
    id tableNode = GetIvarObjectQuiet(viewController, "tableNode");
    if (tableNode) {
        SEL viewSelector = NSSelectorFromString(@"view");
        if ([tableNode respondsToSelector:viewSelector]) {
            UIView *tableNodeView = ((id (*)(id, SEL))objc_msgSend)(tableNode, viewSelector);
            if ([tableNodeView isKindOfClass:[UITableView class]]) {
                return (UITableView *)tableNodeView;
            }
        }
    }

    return FindFirstTableViewInView(viewController.view);
}

static NSString *ApolloNormalizeLanguageCode(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return nil;

    NSString *lower = [[identifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (lower.length == 0) return nil;

    NSRange dash = [lower rangeOfString:@"-"];
    NSRange underscore = [lower rangeOfString:@"_"];
    NSUInteger splitIndex = NSNotFound;
    if (dash.location != NSNotFound) splitIndex = dash.location;
    if (underscore.location != NSNotFound) {
        splitIndex = (splitIndex == NSNotFound) ? underscore.location : MIN(splitIndex, underscore.location);
    }
    if (splitIndex != NSNotFound && splitIndex > 0) {
        lower = [lower substringToIndex:splitIndex];
    }

    return lower.length > 0 ? lower : nil;
}

static NSString *ApolloResolvedTargetLanguageCode(void) {
    NSString *override = ApolloNormalizeLanguageCode(sTranslationTargetLanguage);
    if (override.length > 0) return override;

    NSString *preferred = [NSLocale preferredLanguages].firstObject;
    NSString *normalized = ApolloNormalizeLanguageCode(preferred);
    return normalized ?: @"en";
}

static NSString *ApolloNormalizeTextForCompare(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"";

    NSArray<NSString *> *parts = [text.lowercaseString componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length > 0) [nonEmpty addObject:part];
    }
    return [nonEmpty componentsJoinedByString:@" "];
}

static NSString *ApolloDetectDominantLanguage(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length < 12) return nil;

    NSLinguisticTagger *tagger = [[NSLinguisticTagger alloc] initWithTagSchemes:@[NSLinguisticTagSchemeLanguage] options:0];
    tagger.string = text;
    NSString *language = [tagger dominantLanguage];
    return ApolloNormalizeLanguageCode(language);
}

static NSString *ApolloTranslationCacheKey(NSString *text, NSString *targetLanguage) {
    return [NSString stringWithFormat:@"%@|%lu", targetLanguage ?: @"en", (unsigned long)text.hash];
}

static BOOL ApolloThreadTranslationModeEnabledForVisibleCommentsVC(void) {
    UIViewController *vc = sVisibleCommentsViewController;
    if (!vc) return NO;
    return [objc_getAssociatedObject(vc, kApolloThreadTranslatedModeKey) boolValue];
}

static BOOL ApolloShouldTranslateNow(BOOL forceTranslation) {
    if (!sEnableBulkTranslation && !forceTranslation) return NO;
    if (forceTranslation) return YES;
    if (!sVisibleCommentsViewController) return NO;
    return sAutoTranslateOnAppear || ApolloThreadTranslationModeEnabledForVisibleCommentsVC();
}

static BOOL ApolloActionTitleLooksTranslate(NSString *title) {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return NO;

    NSString *lower = [title lowercaseString];
    NSArray<NSString *> *keywords = @[
        @"translate",
        @"traduz",
        @"tradu",
        @"übersetz",
        @"перев",
        @"翻译",
        @"번역",
        @"ترجم",
    ];

    for (NSString *keyword in keywords) {
        if ([lower containsString:keyword]) return YES;
    }
    return NO;
}

static NSString *ApolloDecodeSwiftString(uint64_t w0, uint64_t w1) {
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
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

    return sBridge ? sBridge(w0, w1) : nil;
}

static NSUInteger ApolloRemoveNativeTranslateActions(id actionController) {
    Class cls = object_getClass(actionController);
    Ivar actionsIvar = class_getInstanceVariable(cls, "actions");
    if (!actionsIvar) return 0;

    uint8_t *acBase = (uint8_t *)(__bridge void *)actionController;
    void *actionsBuffer = *(void **)(acBase + ivar_getOffset(actionsIvar));
    if (!actionsBuffer) return 0;

    int64_t count = *(int64_t *)((uint8_t *)actionsBuffer + 0x10);
    if (count <= 0) return 0;

    int64_t writeIndex = 0;
    NSUInteger removedCount = 0;

    for (int64_t readIndex = 0; readIndex < count; readIndex++) {
        uint8_t *entry = (uint8_t *)actionsBuffer + 0x20 + (readIndex * 0x30);
        NSString *title = ApolloDecodeSwiftString(*(uint64_t *)(entry + 0x08), *(uint64_t *)(entry + 0x10));
        if (ApolloActionTitleLooksTranslate(title)) {
            removedCount++;
            continue;
        }

        if (writeIndex != readIndex) {
            uint8_t *destination = (uint8_t *)actionsBuffer + 0x20 + (writeIndex * 0x30);
            memmove(destination, entry, 0x30);
        }
        writeIndex++;
    }

    if (removedCount > 0) {
        *(int64_t *)((uint8_t *)actionsBuffer + 0x10) = writeIndex;
    }

    return removedCount;
}

static void ApolloCollectAttributedTextNodes(id object,
                                             NSInteger depth,
                                             NSHashTable *visited,
                                             NSMutableArray *nodes) {
    if (!object || depth < 0 || [visited containsObject:object]) return;
    [visited addObject:object];

    if ([object respondsToSelector:@selector(attributedText)] &&
        [object respondsToSelector:@selector(setAttributedText:)]) {
        NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
        if ([attr isKindOfClass:[NSAttributedString class]] && attr.string.length > 0) {
            [nodes addObject:object];
        }
    }

    if (depth == 0) return;

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) {
                    ApolloCollectAttributedTextNodes(subnode, depth - 1, visited, nodes);
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }

    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;

        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;

            id child = object_getIvar(object, ivars[i]);
            if (!child || child == object) continue;

            ApolloCollectAttributedTextNodes(child, depth - 1, visited, nodes);
        }

        free(ivars);
    }
}

static NSInteger ApolloCandidateScore(NSAttributedString *candidateText, NSString *commentBody) {
    if (![candidateText isKindOfClass:[NSAttributedString class]]) return NSIntegerMin;

    NSString *candidate = ApolloNormalizeTextForCompare(candidateText.string);
    if (candidate.length == 0) return NSIntegerMin;

    NSString *body = ApolloNormalizeTextForCompare(commentBody ?: @"");
    if (body.length == 0) return (NSInteger)candidate.length;

    if ([candidate isEqualToString:body]) {
        return 100000 + (NSInteger)candidate.length;
    }

    if ([candidate containsString:body] || [body containsString:candidate]) {
        return 75000 + (NSInteger)MIN(candidate.length, body.length);
    }

    NSUInteger prefixLength = MIN((NSUInteger)20, MIN(candidate.length, body.length));
    if (prefixLength >= 8) {
        NSString *candidatePrefix = [candidate substringToIndex:prefixLength];
        NSString *bodyPrefix = [body substringToIndex:prefixLength];
        if ([candidatePrefix isEqualToString:bodyPrefix]) {
            return 50000 + (NSInteger)candidate.length;
        }
    }

    return (NSInteger)candidate.length;
}

static id ApolloBestCommentTextNode(id commentCellNode, RDKComment *comment) {
    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [NSHashTable weakObjectsHashTable];
    ApolloCollectAttributedTextNodes(commentCellNode, 4, visited, candidates);

    id bestNode = nil;
    NSInteger bestScore = NSIntegerMin;

    for (id candidateNode in candidates) {
        NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(candidateNode, @selector(attributedText));
        NSInteger score = ApolloCandidateScore(attr, comment.body);
        if (score > bestScore) {
            bestScore = score;
            bestNode = candidateNode;
        }
    }

    return bestNode;
}

static void ApolloApplyTranslationToCellNode(id commentCellNode, RDKComment *comment, NSString *translatedText) {
    if (!commentCellNode || ![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0) return;

    id textNode = ApolloBestCommentTextNode(commentCellNode, comment);
    if (!textNode) return;

    NSAttributedString *current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    if (![current isKindOfClass:[NSAttributedString class]]) return;

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) {
        objc_setAssociatedObject(textNode, kApolloOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSDictionary *attributes = nil;
    if (current.length > 0) {
        attributes = [current attributesAtIndex:0 effectiveRange:NULL];
    }

    NSAttributedString *translatedAttr = [[NSAttributedString alloc] initWithString:translatedText attributes:attributes ?: @{}];
    ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), translatedAttr);

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    objc_setAssociatedObject(commentCellNode, kApolloTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloRestoreOriginalForCellNode(id commentCellNode, RDKComment *comment) {
    if (!commentCellNode) return;

    id textNode = objc_getAssociatedObject(commentCellNode, kApolloTranslatedTextNodeKey);
    if (!textNode) {
        textNode = ApolloBestCommentTextNode(commentCellNode, comment);
    }
    if (!textNode) return;

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original);

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }
}

static NSString *ApolloExtractGoogleTranslation(id jsonObject) {
    if ([jsonObject isKindOfClass:[NSString class]]) {
        return (NSString *)jsonObject;
    }

    if (![jsonObject isKindOfClass:[NSArray class]]) return nil;

    NSArray *array = (NSArray *)jsonObject;
    if (array.count == 0) return nil;

    NSMutableString *joinedSegments = [NSMutableString string];
    BOOL foundSegment = NO;

    for (id item in array) {
        if ([item isKindOfClass:[NSArray class]]) {
            NSArray *segment = (NSArray *)item;
            if (segment.count > 0 && [segment[0] isKindOfClass:[NSString class]]) {
                [joinedSegments appendString:segment[0]];
                foundSegment = YES;
            }
        }
    }

    if (foundSegment && joinedSegments.length > 0) {
        return joinedSegments;
    }

    for (id item in array) {
        NSString *nested = ApolloExtractGoogleTranslation(item);
        if (nested.length > 0) return nested;
    }

    return nil;
}

static void ApolloTranslateViaGoogle(NSString *text,
                                     NSString *targetLanguage,
                                     void (^completion)(NSString *translated, NSError *error)) {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"translate.googleapis.com";
    components.path = @"/translate_a/single";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:targetLanguage],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
        [NSURLQueryItem queryItemWithName:@"q" value:text],
    ];

    NSURL *url = components.URL;
    if (!url) {
        NSError *error = [NSError errorWithDomain:@"ApolloTranslation" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Failed to build Google Translate URL"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
    request.HTTPMethod = @"GET";

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (![httpResponse isKindOfClass:[NSHTTPURLResponse class]] || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            NSError *statusError = [NSError errorWithDomain:@"ApolloTranslation" code:101 userInfo:@{NSLocalizedDescriptionKey: @"Google Translate request failed"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, statusError); });
            return;
        }

        NSError *jsonError = nil;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, jsonError); });
            return;
        }

        NSString *translated = ApolloExtractGoogleTranslation(jsonObject);
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            NSError *parseError = [NSError errorWithDomain:@"ApolloTranslation" code:102 userInfo:@{NSLocalizedDescriptionKey: @"Google Translate response parse error"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, parseError); });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(translated, nil); });
    }];

    [task resume];
}

static void ApolloTranslateViaLibre(NSString *text,
                                    NSString *targetLanguage,
                                    void (^completion)(NSString *translated, NSError *error)) {
    NSString *urlString = [sLibreTranslateURL length] > 0 ? sLibreTranslateURL : kApolloDefaultLibreTranslateURL;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSError *error = [NSError errorWithDomain:@"ApolloTranslation" code:200 userInfo:@{NSLocalizedDescriptionKey: @"Invalid LibreTranslate URL"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    NSMutableDictionary *payload = [@{
        @"q": text,
        @"source": @"auto",
        @"target": targetLanguage,
        @"format": @"text"
    } mutableCopy];

    if ([sLibreTranslateAPIKey length] > 0) {
        payload[@"api_key"] = sLibreTranslateAPIKey;
    }

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (!jsonData) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, jsonError); });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = jsonData;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (![httpResponse isKindOfClass:[NSHTTPURLResponse class]] || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
            NSError *statusError = [NSError errorWithDomain:@"ApolloTranslation" code:201 userInfo:@{NSLocalizedDescriptionKey: @"LibreTranslate request failed"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, statusError); });
            return;
        }

        NSError *parseError = nil;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (parseError) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, parseError); });
            return;
        }

        NSString *translated = nil;
        if ([jsonObject isKindOfClass:[NSDictionary class]]) {
            translated = ((NSDictionary *)jsonObject)[@"translatedText"];
        } else if ([jsonObject isKindOfClass:[NSArray class]]) {
            id first = [(NSArray *)jsonObject firstObject];
            if ([first isKindOfClass:[NSDictionary class]]) {
                translated = ((NSDictionary *)first)[@"translatedText"];
            }
        }

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            NSError *responseError = [NSError errorWithDomain:@"ApolloTranslation" code:202 userInfo:@{NSLocalizedDescriptionKey: @"LibreTranslate response parse error"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, responseError); });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(translated, nil); });
    }];

    [task resume];
}

static void ApolloTranslateTextWithFallback(NSString *text,
                                            NSString *targetLanguage,
                                            void (^completion)(NSString *translated, NSError *error)) {
    NSString *primaryProvider = [sTranslationProvider isEqualToString:@"libre"] ? @"libre" : @"google";
    BOOL googlePrimary = [primaryProvider isEqualToString:@"google"];

    void (^fallback)(void) = ^{
        if (googlePrimary) {
            ApolloTranslateViaLibre(text, targetLanguage, completion);
        } else {
            ApolloTranslateViaGoogle(text, targetLanguage, completion);
        }
    };

    void (^primaryCompletion)(NSString *, NSError *) = ^(NSString *translated, NSError *error) {
        if ([translated isKindOfClass:[NSString class]] && translated.length > 0) {
            completion(translated, nil);
            return;
        }
        fallback();
    };

    if (googlePrimary) {
        ApolloTranslateViaGoogle(text, targetLanguage, primaryCompletion);
    } else {
        ApolloTranslateViaLibre(text, targetLanguage, primaryCompletion);
    }
}

static void ApolloRequestTranslation(NSString *cacheKey,
                                     NSString *sourceText,
                                     NSString *targetLanguage,
                                     void (^completion)(NSString *translated, NSError *error)) {
    NSString *cached = [sTranslationCache objectForKey:cacheKey];
    if (cached.length > 0) {
        completion(cached, nil);
        return;
    }

    BOOL shouldStartRequest = NO;
    @synchronized (sPendingTranslationCallbacks) {
        NSMutableArray *callbacks = sPendingTranslationCallbacks[cacheKey];
        if (!callbacks) {
            callbacks = [NSMutableArray array];
            sPendingTranslationCallbacks[cacheKey] = callbacks;
            shouldStartRequest = YES;
        }
        [callbacks addObject:[completion copy]];
    }

    if (!shouldStartRequest) return;

    ApolloTranslateTextWithFallback(sourceText, targetLanguage, ^(NSString *translated, NSError *error) {
        NSArray *callbacks = nil;
        @synchronized (sPendingTranslationCallbacks) {
            callbacks = [sPendingTranslationCallbacks[cacheKey] copy] ?: @[];
            [sPendingTranslationCallbacks removeObjectForKey:cacheKey];
        }

        if ([translated isKindOfClass:[NSString class]] && translated.length > 0) {
            [sTranslationCache setObject:translated forKey:cacheKey];
        }

        for (id callbackObj in callbacks) {
            void (^callback)(NSString *, NSError *) = callbackObj;
            callback(translated, error);
        }
    });
}

static RDKComment *ApolloCommentFromCellNode(id commentCellNode) {
    if (!commentCellNode) return nil;

    Ivar commentIvar = class_getInstanceVariable([commentCellNode class], "comment");
    if (!commentIvar) return nil;

    id comment = object_getIvar(commentCellNode, commentIvar);
    return [comment isKindOfClass:[RDKComment class]] ? (RDKComment *)comment : nil;
}

static void ApolloMaybeTranslateCommentCellNode(id commentCellNode, BOOL forceTranslation) {
    if (!commentCellNode) return;
    if (!ApolloShouldTranslateNow(forceTranslation)) return;

    RDKComment *comment = ApolloCommentFromCellNode(commentCellNode);
    if (!comment) return;

    NSString *sourceText = [comment.body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (sourceText.length == 0) return;

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) return;

    if (!forceTranslation) {
        NSString *detected = ApolloDetectDominantLanguage(sourceText);
        if ([detected isEqualToString:targetLanguage]) {
            return;
        }
    }

    NSString *cacheKey = ApolloTranslationCacheKey(sourceText, targetLanguage);
    objc_setAssociatedObject(commentCellNode, kApolloCellTranslationKeyKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);

    __weak id weakCellNode = commentCellNode;
    ApolloRequestTranslation(cacheKey, sourceText, targetLanguage, ^(NSString *translated, NSError *error) {
        id strongCellNode = weakCellNode;
        if (!strongCellNode) return;

        NSString *currentKey = objc_getAssociatedObject(strongCellNode, kApolloCellTranslationKeyKey);
        if (![currentKey isEqualToString:cacheKey]) return;

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) {
                ApolloLog(@"[Translation] Failed to translate comment: %@", error.localizedDescription ?: @"unknown error");
            }
            return;
        }

        if (!forceTranslation && !ApolloShouldTranslateNow(NO)) return;

        RDKComment *strongComment = ApolloCommentFromCellNode(strongCellNode);
        if (!strongComment) return;

        ApolloApplyTranslationToCellNode(strongCellNode, strongComment, translated);
    });
}

static void ApolloTranslateVisibleCommentsForController(UIViewController *viewController, BOOL forceTranslation) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSelector]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        ApolloMaybeTranslateCommentCellNode(cellNode, forceTranslation);
    }
}

static void ApolloRestoreVisibleCommentsForController(UIViewController *viewController) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSelector]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        RDKComment *comment = ApolloCommentFromCellNode(cellNode);
        ApolloRestoreOriginalForCellNode(cellNode, comment);
    }
}

static void ApolloUpdateTranslationButtonForController(id controller) {
    UIViewController *vc = (UIViewController *)controller;

    UIBarButtonItem *translationItem = objc_getAssociatedObject(controller, kApolloTranslateBarButtonKey);
    NSMutableArray<UIBarButtonItem *> *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];

    if (!sEnableBulkTranslation) {
        if ([objc_getAssociatedObject(controller, kApolloThreadTranslatedModeKey) boolValue]) {
            ApolloRestoreVisibleCommentsForController(vc);
            objc_setAssociatedObject(controller, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        if (translationItem) {
            [items removeObject:translationItem];
            vc.navigationItem.rightBarButtonItems = items;
            objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!translationItem) {
        translationItem = [[UIBarButtonItem alloc] initWithTitle:@"Translate"
                                                           style:UIBarButtonItemStylePlain
                                                          target:controller
                                                          action:@selector(apollo_toggleThreadTranslation)];
        objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, translationItem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL translatedMode = [objc_getAssociatedObject(controller, kApolloThreadTranslatedModeKey) boolValue];
    translationItem.title = translatedMode ? @"Original" : @"Translate";

    if (![items containsObject:translationItem]) {
        [items insertObject:translationItem atIndex:0];
    }

    vc.navigationItem.rightBarButtonItems = items;
}

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;

    if (!sEnableBulkTranslation) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloMaybeTranslateCommentCellNode((id)self, NO);
    });
}

- (void)didEnterPreloadState {
    %orig;

    if (!sEnableBulkTranslation) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloMaybeTranslateCommentCellNode((id)self, NO);
    });
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    %orig;
    ApolloUpdateTranslationButtonForController(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloUpdateTranslationButtonForController(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    sVisibleCommentsViewController = (UIViewController *)self;

    if (sEnableBulkTranslation && (sAutoTranslateOnAppear || [objc_getAssociatedObject((id)self, kApolloThreadTranslatedModeKey) boolValue])) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloTranslateVisibleCommentsForController((UIViewController *)self, NO);
        });
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;

    if (sVisibleCommentsViewController == (UIViewController *)self) {
        sVisibleCommentsViewController = nil;
    }
}

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (sEnableBulkTranslation && [vc isKindOfClass:objc_getClass("_TtC6Apollo16ActionController")]) {
        NSUInteger removed = ApolloRemoveNativeTranslateActions(vc);
        if (removed > 0) {
            ApolloLog(@"[Translation] Removed %lu native Translate action(s)", (unsigned long)removed);
        }
    }
    %orig;
}

%new
- (void)apollo_toggleThreadTranslation {
    BOOL translatedMode = [objc_getAssociatedObject((id)self, kApolloThreadTranslatedModeKey) boolValue];

    if (translatedMode) {
        ApolloRestoreVisibleCommentsForController((UIViewController *)self);
        objc_setAssociatedObject((id)self, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        ApolloTranslateVisibleCommentsForController((UIViewController *)self, YES);
        objc_setAssociatedObject((id)self, kApolloThreadTranslatedModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloUpdateTranslationButtonForController(self);
}

%end

%ctor {
    sTranslationCache = [NSCache new];
    sPendingTranslationCallbacks = [NSMutableDictionary dictionary];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        [sTranslationCache removeAllObjects];
    }];

    %init;
}
