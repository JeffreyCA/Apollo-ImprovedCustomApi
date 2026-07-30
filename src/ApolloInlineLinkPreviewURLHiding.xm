#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloState.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

@class ASDisplayNode;

@interface ASDisplayNode : NSObject
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)setNeedsDisplay;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@end

static NSString * const ApolloLinkPreviewDidCacheNotification = @"ApolloLinkPreviewDidCacheNotification";

static const void *kApolloLPURLHidingOriginalTextKey = &kApolloLPURLHidingOriginalTextKey;
static const void *kApolloLPURLHidingReentrancyKey = &kApolloLPURLHidingReentrancyKey;
static const void *kApolloLPURLHidingCandidateURLsKey = &kApolloLPURLHidingCandidateURLsKey;

static BOOL ApolloLPURLHidingEnabled(void) {
    return sLinkPreviewBodyMode != ApolloLinkPreviewModeOff || sLinkPreviewCommentsMode != ApolloLinkPreviewModeOff;
}

static NSHashTable *ApolloLPURLHidingTextNodes(void) {
    static NSHashTable *nodes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nodes = [NSHashTable weakObjectsHashTable];
    });
    return nodes;
}

static dispatch_queue_t ApolloLPURLHidingQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.apollo.linkpreviews.urlhiding", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL ApolloLPURLIsHTTP(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static BOOL ApolloLPURLHidingShouldProcessTextNode(id textNode) {
    if (!textNode) return NO;
    // The verdict is a pure function of the class, and this runs for every
    // setAttributedText app-wide (feed scrolling included) — cache it on the
    // class object itself instead of re-running NSStringFromClass plus the
    // substring scans each time. Class objects are immortal and associated
    // storage is thread-safe (these hooks also fire on Texture's background
    // layout threads).
    Class cls = [textNode class];
    static char kApolloLPURLHidingClassVerdictKey;
    NSNumber *cached = objc_getAssociatedObject(cls, &kApolloLPURLHidingClassVerdictKey);
    if (cached) return cached.boolValue;
    NSString *className = NSStringFromClass(cls);
    BOOL verdict = [className containsString:@"Markdown"] ||
                   ([className hasPrefix:@"_TtC6Apollo"] && [className containsString:@"TextNode"]);
    objc_setAssociatedObject(cls, &kApolloLPURLHidingClassVerdictKey, @(verdict), OBJC_ASSOCIATION_RETAIN);
    return verdict;
}

static BOOL ApolloLPURLsMatch(NSURL *a, NSURL *b) {
    NSString *aString = a.absoluteString.lowercaseString ?: @"";
    NSString *bString = b.absoluteString.lowercaseString ?: @"";
    return aString.length > 0 && [aString isEqualToString:bString];
}

static NSURL *ApolloLPBareHTTPURLFromText(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return nil;

    NSURL *url = [NSURL URLWithString:trimmed];
    return ApolloLPURLIsHTTP(url) ? url : nil;
}

static BOOL ApolloLPTextLooksLikeStandaloneURL(NSString *text, NSURL *url) {
    if (!ApolloLPURLIsHTTP(url)) return NO;

    NSURL *textURL = ApolloLPBareHTTPURLFromText(text);
    if (textURL && ApolloLPURLsMatch(textURL, url)) return YES;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";
    NSString *lowerText = trimmed.lowercaseString ?: @"";
    if (host.length > 0 && [lowerText rangeOfString:host].location == NSNotFound) return NO;
    return path.length == 0 || [lowerText rangeOfString:path.lowercaseString].location != NSNotFound;
}

static NSURL *ApolloLPHTTPURLFromAttributes(NSDictionary *attributes) {
    for (id value in attributes.allValues) {
        if ([value isKindOfClass:[NSURL class]] && ApolloLPURLIsHTTP((NSURL *)value)) {
            return (NSURL *)value;
        }
    }
    return nil;
}

static NSURL *ApolloLPURLFromStandaloneParagraph(NSAttributedString *attributedText, NSRange paragraphRange) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || paragraphRange.length == 0) return nil;

    NSString *string = attributedText.string ?: @"";
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSUInteger start = paragraphRange.location;
    NSUInteger end = NSMaxRange(paragraphRange);
    while (start < end && [trimSet characterIsMember:[string characterAtIndex:start]]) start++;
    while (end > start && [trimSet characterIsMember:[string characterAtIndex:end - 1]]) end--;
    if (end <= start) return nil;

    NSRange trimmedRange = NSMakeRange(start, end - start);
    NSString *urlText = [string substringWithRange:trimmedRange];
    __block NSURL *candidateURL = nil;
    __block BOOL linkCoversTrimmedRange = YES;
    __block BOOL multipleURLs = NO;

    [attributedText enumerateAttributesInRange:trimmedRange
                                       options:0
                                    usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
        NSURL *runURL = ApolloLPHTTPURLFromAttributes(attrs);
        if (!runURL) {
            linkCoversTrimmedRange = NO;
            *stop = YES;
            return;
        }

        if (!candidateURL) {
            candidateURL = runURL;
        } else if (!ApolloLPURLsMatch(candidateURL, runURL)) {
            multipleURLs = YES;
            *stop = YES;
        }
    }];

    if (candidateURL && linkCoversTrimmedRange && !multipleURLs && ApolloLPTextLooksLikeStandaloneURL(urlText, candidateURL)) {
        return candidateURL;
    }

    return ApolloLPBareHTTPURLFromText(urlText);
}

static BOOL ApolloLPAttributedTextContainsURL(NSAttributedString *attributedText, NSURL *url) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || url.absoluteString.length == 0) return NO;
    return [attributedText.string rangeOfString:url.absoluteString options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSAttributedString *ApolloLPAttributedTextByHidingStandalonePreviewURLs(NSAttributedString *attributedText, NSArray<NSURL *> **candidateURLsOut, NSUInteger *hiddenCountOut) {
    if (candidateURLsOut) *candidateURLsOut = @[];
    if (hiddenCountOut) *hiddenCountOut = 0;
    if (!ApolloLPURLHidingEnabled() || ![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) {
        return attributedText;
    }

    NSMutableArray<NSURL *> *candidateURLs = [NSMutableArray array];
    NSMutableArray<NSValue *> *rangesToRemove = [NSMutableArray array];
    NSString *string = attributedText.string ?: @"";
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                               options:NSStringEnumerationByParagraphs
                            usingBlock:^(__unused NSString *substring, NSRange substringRange, NSRange enclosingRange, __unused BOOL *stop) {
        NSURL *url = ApolloLPURLFromStandaloneParagraph(attributedText, substringRange);
        if (!url) return;
        [candidateURLs addObject:url];
        if ([[ApolloLinkPreviewCache sharedCache] cachedPreviewIsRichForURL:url]) {
            [rangesToRemove addObject:[NSValue valueWithRange:enclosingRange]];
        }
    }];

    if (candidateURLsOut) *candidateURLsOut = [candidateURLs copy];
    if (hiddenCountOut) *hiddenCountOut = rangesToRemove.count;
    if (rangesToRemove.count == 0) return attributedText;

    NSMutableAttributedString *rewrittenText = [attributedText mutableCopy];
    for (NSValue *value in [rangesToRemove reverseObjectEnumerator]) {
        NSRange range = value.rangeValue;
        if (NSMaxRange(range) <= rewrittenText.length) {
            [rewrittenText deleteCharactersInRange:range];
        }
    }
    return rewrittenText;
}

static void ApolloLPRegisterURLHidingTextNode(id textNode, NSAttributedString *originalText, NSArray<NSURL *> *candidateURLs) {
    if (!textNode || ![originalText isKindOfClass:[NSAttributedString class]] || candidateURLs.count == 0) return;
    objc_setAssociatedObject(textNode, kApolloLPURLHidingOriginalTextKey, [originalText copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloLPURLHidingCandidateURLsKey, [candidateURLs copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(ApolloLPURLHidingQueue(), ^{
        [ApolloLPURLHidingTextNodes() addObject:textNode];
    });
}

static void ApolloLPLogURLHide(NSUInteger hiddenCount, id textNode) {
    if (hiddenCount == 0) return;
    ApolloLog(@"[LinkPreviews] V12 hid %lu standalone rich-preview URL paragraph(s) node=%@",
              (unsigned long)hiddenCount,
              NSStringFromClass([textNode class]));
}

static void ApolloLPApplyURLHidingToTextNode(id textNode, NSAttributedString *incomingText) {
    if (!ApolloLPURLHidingShouldProcessTextNode(textNode) || ![incomingText isKindOfClass:[NSAttributedString class]]) return;

    NSArray<NSURL *> *candidateURLs = nil;
    NSUInteger hiddenCount = 0;
    NSAttributedString *rewritten = ApolloLPAttributedTextByHidingStandalonePreviewURLs(incomingText, &candidateURLs, &hiddenCount);
    ApolloLPRegisterURLHidingTextNode(textNode, incomingText, candidateURLs);
    if (rewritten == incomingText) return;

    objc_setAssociatedObject(textNode, kApolloLPURLHidingReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), rewritten);
    } @catch (__unused NSException *exception) {
    }
    objc_setAssociatedObject(textNode, kApolloLPURLHidingReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    ApolloLPLogURLHide(hiddenCount, textNode);
}

static void ApolloLPReapplyURLHidingForCachedURL(NSURL *url) {
    if (!ApolloLPURLHidingEnabled() || !ApolloLPURLIsHTTP(url)) return;

    dispatch_async(ApolloLPURLHidingQueue(), ^{
        NSArray *snapshot = ApolloLPURLHidingTextNodes().allObjects;
        dispatch_async(dispatch_get_main_queue(), ^{
            for (id textNode in snapshot) {
                NSAttributedString *originalText = objc_getAssociatedObject(textNode, kApolloLPURLHidingOriginalTextKey);
                NSArray<NSURL *> *candidateURLs = objc_getAssociatedObject(textNode, kApolloLPURLHidingCandidateURLsKey);
                BOOL containsCandidate = ApolloLPAttributedTextContainsURL(originalText, url);
                for (NSURL *candidateURL in candidateURLs) {
                    if (ApolloLPURLsMatch(candidateURL, url)) {
                        containsCandidate = YES;
                        break;
                    }
                }
                if (!containsCandidate) continue;
                ApolloLPApplyURLHidingToTextNode(textNode, originalText);
            }
        });
    });
}

static void ApolloLPInstallURLHidingObserver(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloLinkPreviewDidCacheNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        NSURL *url = notification.userInfo[@"url"];
        if ([url isKindOfClass:[NSURL class]]) {
            ApolloLPReapplyURLHidingForCachedURL(url);
        }
    }];
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloLPURLHidingEnabled()) {
        %orig;
        return;
    }

    if ([objc_getAssociatedObject(self, kApolloLPURLHidingReentrancyKey) boolValue] || !ApolloLPURLHidingShouldProcessTextNode(self)) {
        %orig;
        return;
    }

    NSArray<NSURL *> *candidateURLs = nil;
    NSUInteger hiddenCount = 0;
    NSAttributedString *rewritten = ApolloLPAttributedTextByHidingStandalonePreviewURLs(attributedText, &candidateURLs, &hiddenCount);
    ApolloLPRegisterURLHidingTextNode(self, attributedText, candidateURLs);
    if (rewritten != attributedText) {
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(rewritten); } @catch (__unused NSException *exception) {}
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLPLogURLHide(hiddenCount, self);
        return;
    }
    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (!ApolloLPURLHidingEnabled()) {
        %orig;
        return;
    }

    if ([objc_getAssociatedObject(self, kApolloLPURLHidingReentrancyKey) boolValue] || !ApolloLPURLHidingShouldProcessTextNode(self)) {
        %orig;
        return;
    }

    NSArray<NSURL *> *candidateURLs = nil;
    NSUInteger hiddenCount = 0;
    NSAttributedString *rewritten = ApolloLPAttributedTextByHidingStandalonePreviewURLs(attributedText, &candidateURLs, &hiddenCount);
    ApolloLPRegisterURLHidingTextNode(self, attributedText, candidateURLs);
    if (rewritten != attributedText) {
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(rewritten); } @catch (__unused NSException *exception) {}
        objc_setAssociatedObject(self, kApolloLPURLHidingReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLPLogURLHide(hiddenCount, self);
        return;
    }
    %orig;
}

%end

%ctor {
    ApolloLPInstallURLHidingObserver();
    ApolloLog(@"[LinkPreviews] V12 URL hiding helper active");
}
