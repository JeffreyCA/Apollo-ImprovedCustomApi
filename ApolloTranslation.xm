#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <string.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "Tweak.h"

static const void *kApolloOriginalAttributedTextKey = &kApolloOriginalAttributedTextKey;
static const void *kApolloTranslatedTextNodeKey = &kApolloTranslatedTextNodeKey;
static const void *kApolloCellTranslationKeyKey = &kApolloCellTranslationKeyKey;
static const void *kApolloThreadTranslatedModeKey = &kApolloThreadTranslatedModeKey;
// Set when the user explicitly toggled away from a translated thread (so we
// don't clobber the user's preference when sAutoTranslateOnAppear is on).
static const void *kApolloThreadOriginalModeKey = &kApolloThreadOriginalModeKey;
static const void *kApolloTranslateBarButtonKey = &kApolloTranslateBarButtonKey;
static const void *kApolloVisibleTranslationAppliedKey = &kApolloVisibleTranslationAppliedKey;
static const void *kApolloAppliedTranslationFullNameKey = &kApolloAppliedTranslationFullNameKey;
// Phase D — vote resilience. When we install a translated string into a text
// node we tag the node with these associations. A global setAttributedText:
// hook checks the marker and re-applies our translation if Apollo overwrites
// the node (e.g. on vote, edit, score-flair refresh).
static const void *kApolloTranslationOwnedTextNodeKey = &kApolloTranslationOwnedTextNodeKey;
static const void *kApolloOwnedNodeOriginalBodyKey = &kApolloOwnedNodeOriginalBodyKey;
static const void *kApolloOwnedNodeTranslatedTextKey = &kApolloOwnedNodeTranslatedTextKey;
static const void *kApolloOwnedNodeReentrancyKey = &kApolloOwnedNodeReentrancyKey;
static const void *kApolloReapplyScheduledKey = &kApolloReapplyScheduledKey;
// Phase B — status banner above comments.
static const void *kApolloTranslationBannerKey = &kApolloTranslationBannerKey;
// Phase C — post selftext translation.
static const void *kApolloAppliedHeaderTranslationFullNameKey = &kApolloAppliedHeaderTranslationFullNameKey;
static const void *kApolloHeaderTranslatedTextNodeKey = &kApolloHeaderTranslatedTextNodeKey;
static const void *kApolloHeaderCellTranslationKeyKey = &kApolloHeaderCellTranslationKeyKey;

static NSString *const kApolloDefaultLibreTranslateURL = @"https://libretranslate.de/translate";

static NSCache<NSString *, NSString *> *sTranslationCache;
// fullName ("t1_xxxxx") -> translated body text. Survives cell reuse / collapse.
static NSCache<NSString *, NSString *> *sCommentTranslationByFullName;
// fullName ("t3_xxxxx") -> translated post selftext. Same idea, for posts.
static NSCache<NSString *, NSString *> *sLinkTranslationByFullName;
static NSMutableDictionary<NSString *, NSMutableArray *> *sPendingTranslationCallbacks;
static __weak UIViewController *sVisibleCommentsViewController = nil;

static void ApolloUpdateTranslationUIForController(id controller);

// Returns the Reddit fullName ("t1_xxxxx") for a comment. Falls back to a
// stable derived key when the runtime doesn't expose `name` / `fullName`.
static NSString *ApolloCommentFullName(RDKComment *comment) {
    if (!comment) return nil;
    SEL sels[] = { @selector(name), NSSelectorFromString(@"fullName"), NSSelectorFromString(@"identifier"), NSSelectorFromString(@"id") };
    for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
        if ([(id)comment respondsToSelector:sels[i]]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(comment, sels[i]);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return (NSString *)v;
        }
    }
    NSString *body = comment.body;
    if (body.length > 0) return [NSString stringWithFormat:@"_body|%lu|%lu", (unsigned long)body.length, (unsigned long)body.hash];
    return nil;
}

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

static BOOL ApolloTextContainsMarkdownCode(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSString *lower = text.lowercaseString;
    if ([lower containsString:@"```"] || [lower containsString:@"~~~"] || [lower containsString:@"`"]) return YES;

    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSUInteger indentedCodeLines = 0;
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        if ([line hasPrefix:@"    "] || [line hasPrefix:@"\t"]) {
            indentedCodeLines++;
        }
    }
    return indentedCodeLines > 0;
}

static BOOL ApolloHTMLContainsCode(NSString *html) {
    if (![html isKindOfClass:[NSString class]] || html.length == 0) return NO;
    NSString *lower = html.lowercaseString;
    return [lower containsString:@"<pre"] ||
           [lower containsString:@"</pre"] ||
           [lower containsString:@"<code"] ||
           [lower containsString:@"</code"];
}

static BOOL ApolloCommentContainsCodeOrPreformatted(RDKComment *comment) {
    if (!comment) return NO;
    return ApolloTextContainsMarkdownCode(comment.body) || ApolloHTMLContainsCode(comment.bodyHTML);
}

static BOOL ApolloLinkContainsCodeOrPreformatted(RDKLink *link, NSString *visibleText) {
    return ApolloTextContainsMarkdownCode(link.selfText) ||
           ApolloHTMLContainsCode(link.selfTextHTML) ||
           ApolloTextContainsMarkdownCode(visibleText);
}

static BOOL ApolloTranslatedTextDiffersFromSource(NSString *sourceText, NSString *translatedText) {
    NSString *sourceNorm = ApolloNormalizeTextForCompare(sourceText ?: @"");
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText ?: @"");
    return sourceNorm.length > 0 && translatedNorm.length > 0 && ![sourceNorm isEqualToString:translatedNorm];
}

static void ApolloMarkVisibleTranslationApplied(NSString *sourceText, NSString *translatedText) {
    if (!ApolloTranslatedTextDiffersFromSource(sourceText, translatedText)) return;
    UIViewController *vc = sVisibleCommentsViewController;
    if (!vc) return;
    objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloUpdateTranslationUIForController(vc);
}

static void ApolloClearVisibleTranslationApplied(UIViewController *vc) {
    if (!vc) return;
    objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static BOOL ApolloThreadTranslationModeEnabledForVisibleCommentsVC(void) __attribute__((unused));
static BOOL ApolloThreadTranslationModeEnabledForVisibleCommentsVC(void) {
    UIViewController *vc = sVisibleCommentsViewController;
    if (!vc) return NO;
    return [objc_getAssociatedObject(vc, kApolloThreadTranslatedModeKey) boolValue];
}

// Returns YES if the controller is currently in translated mode considering
// both the auto-translate setting AND the user's per-thread overrides:
//   - Explicit "translate this thread" (kApolloThreadTranslatedModeKey = @YES)
//     always wins.
//   - sAutoTranslateOnAppear means default = translated, UNLESS the user has
//     explicitly toggled to original on this thread
//     (kApolloThreadOriginalModeKey = @YES).
static BOOL ApolloControllerIsInTranslatedMode(UIViewController *vc) {
    if (!vc) return NO;
    if ([objc_getAssociatedObject(vc, kApolloThreadTranslatedModeKey) boolValue]) return YES;
    if (sAutoTranslateOnAppear &&
        ![objc_getAssociatedObject(vc, kApolloThreadOriginalModeKey) boolValue]) {
        return YES;
    }
    return NO;
}

static BOOL ApolloShouldTranslateNow(BOOL forceTranslation) {
    if (!sEnableBulkTranslation && !forceTranslation) return NO;
    if (forceTranslation) return YES;
    UIViewController *vc = sVisibleCommentsViewController;
    if (!vc) return NO;
    return ApolloControllerIsInTranslatedMode(vc);
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

// Walks ONLY the ASDisplayNode subnode tree (and, lazily, UIView subviews when
// a view is loaded). We deliberately do NOT enumerate arbitrary `@`-typed
// ivars: many of those are __weak / __unsafe_unretained references to objects
// (delegates, model objects, captured cells) that may be deallocated during
// cell reuse — touching them ARC-retains a zombie and crashes (the original
// `objc_retain + 8` crash reported by users).
//
// Caps: depth and a hard visited-node ceiling, so even a misbehaving subtree
// can't blow the stack or burn unbounded CPU on the main thread.
static const NSUInteger kApolloMaxVisitedNodes = 256;

static void ApolloCollectAttributedTextNodes(id object,
                                             NSInteger depth,
                                             NSHashTable *visited,
                                             NSMutableArray *nodes) {
    if (!object || depth < 0) return;
    if (visited.count >= kApolloMaxVisitedNodes) return;

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return;

    if ([visited containsObject:object]) return;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] &&
            [object respondsToSelector:@selector(setAttributedText:)]) {
            NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
            if ([attr isKindOfClass:[NSAttributedString class]] && attr.string.length > 0) {
                [nodes addObject:object];
            }
        }
    } @catch (__unused NSException *exception) {
    }

    // Texture/AsyncDisplayKit views often keep the real ASDisplayNode behind
    // a private category accessor. When the post body lives in the table
    // header view, walking UIView subviews alone can stop at an _ASDisplayView;
    // hop back to the backing node so the normal subnode traversal can find
    // ASTextNode/ASTextNode2 children.
    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) {
                ApolloCollectAttributedTextNodes(node, depth - 1, visited, nodes);
            }
        }
    } @catch (__unused NSException *exception) {
    }

    if (depth == 0) return;

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) {
                    if (visited.count >= kApolloMaxVisitedNodes) break;
                    ApolloCollectAttributedTextNodes(subnode, depth - 1, visited, nodes);
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }

    // Only descend into UIView subviews when the node already has its view
    // loaded — querying `-view` would force-load and is wrong off-main anyway.
    @try {
        SEL isViewLoadedSel = NSSelectorFromString(@"isNodeLoaded");
        BOOL viewLoaded = isView;
        if (!viewLoaded && [object respondsToSelector:isViewLoadedSel]) {
            viewLoaded = ((BOOL (*)(id, SEL))objc_msgSend)(object, isViewLoadedSel);
        }
        if (viewLoaded && [object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id sub in subviews) {
                    if (visited.count >= kApolloMaxVisitedNodes) break;
                    ApolloCollectAttributedTextNodes(sub, depth - 1, visited, nodes);
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
}

// Returns the ASTextNode (or compatible) holding the comment body, by reading
// well-known body ivar names directly off the cell node. This is the safe
// fast path: it can't accidentally pick up the username / upvote / byline
// nodes because we ask the cell explicitly for the body slot.
static id ApolloKnownBodyTextNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    static const char *kCandidateNames[] = {
        "bodyTextNode",
        "commentTextNode",
        "commentBodyNode",
        "bodyNode",
        "markdownNode",
        "commentMarkdownNode",
        "attributedTextNode",
        "textNode",
        "commentBodyTextNode",
        "bodyMarkdownNode",
        NULL,
    };
    for (Class cls = [commentCellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kCandidateNames[i]; i++) {
            Ivar iv = class_getInstanceVariable(cls, kCandidateNames[i]);
            if (!iv) continue;
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != '@') continue;
            id node = nil;
            @try { node = object_getIvar(commentCellNode, iv); } @catch (__unused NSException *e) { continue; }
            if (!node) continue;
            if (![node respondsToSelector:@selector(attributedText)]) continue;
            return node;
        }
    }
    return nil;
}

// Score a candidate text node's attributedString against the comment body.
// Returns NSIntegerMin when the candidate is clearly NOT the body — this is
// critical: previously we'd fall back to `(NSInteger)candidate.length` which
// let unrelated nodes (username, upvote count, byline, "X minutes ago", etc.)
// win the race and get overwritten with the translation. Now only real
// matches qualify.
static NSInteger ApolloCandidateScore(NSAttributedString *candidateText, NSString *commentBody) {
    if (![candidateText isKindOfClass:[NSAttributedString class]]) return NSIntegerMin;

    NSString *candidate = ApolloNormalizeTextForCompare(candidateText.string);
    if (candidate.length == 0) return NSIntegerMin;

    NSString *body = ApolloNormalizeTextForCompare(commentBody ?: @"");
    if (body.length == 0) return NSIntegerMin;

    if ([candidate isEqualToString:body]) {
        return 100000 + (NSInteger)candidate.length;
    }

    if ([candidate containsString:body] || [body containsString:candidate]) {
        // Require the overlap to be a meaningful chunk, not just a stray word.
        NSUInteger overlap = MIN(candidate.length, body.length);
        if (overlap >= 12 || overlap == body.length || overlap == candidate.length) {
            return 75000 + (NSInteger)overlap;
        }
    }

    NSUInteger prefixLength = MIN((NSUInteger)24, MIN(candidate.length, body.length));
    if (prefixLength >= 12) {
        NSString *candidatePrefix = [candidate substringToIndex:prefixLength];
        NSString *bodyPrefix = [body substringToIndex:prefixLength];
        if ([candidatePrefix isEqualToString:bodyPrefix]) {
            return 50000 + (NSInteger)candidate.length;
        }
    }

    return NSIntegerMin;
}

static id ApolloBestCommentTextNode(id commentCellNode, RDKComment *comment) {
    // Fast path: ask the cell directly via well-known ivar names. This avoids
    // both the crash exposure and the wrong-node selection bug.
    id known = ApolloKnownBodyTextNode(commentCellNode);
    if (known) return known;

    NSMutableArray *candidates = [NSMutableArray array];
    // Pointer-identity hash table — does NOT retain visited objects, which
    // would otherwise resurrect zombies during cell teardown.
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloCollectAttributedTextNodes(commentCellNode, 5, visited, candidates);

    id bestNode = nil;
    NSInteger bestScore = NSIntegerMin;

    for (id candidateNode in candidates) {
        NSAttributedString *attr = nil;
        @try {
            attr = ((id (*)(id, SEL))objc_msgSend)(candidateNode, @selector(attributedText));
        } @catch (__unused NSException *e) {
            continue;
        }
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

    NSAttributedString *current = nil;
    @try {
        current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        return;
    }
    if (![current isKindOfClass:[NSAttributedString class]]) return;

    // Pre-write match guard: re-verify the chosen node's current text really
    // is the comment body. If `ApolloBestCommentTextNode` somehow returned a
    // wrong node (e.g. mid-reuse, body cleared), skip the write rather than
    // overwriting a username / upvote / byline label.
    NSString *currentNorm = ApolloNormalizeTextForCompare(current.string);
    NSString *bodyNorm = ApolloNormalizeTextForCompare(comment.body);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);
    if (currentNorm.length == 0 || bodyNorm.length == 0) return;
    BOOL textMatchesBody = [currentNorm isEqualToString:bodyNorm] ||
                           [currentNorm containsString:bodyNorm] ||
                           [bodyNorm containsString:currentNorm];
    BOOL textMatchesTranslation = translatedNorm.length > 0 &&
        ([currentNorm isEqualToString:translatedNorm] ||
         [currentNorm containsString:translatedNorm] ||
         [translatedNorm containsString:currentNorm]);
    if (!textMatchesBody && !textMatchesTranslation) {
        ApolloLog(@"[Translation] Skipping write — chosen node text does not match body or translation");
        return;
    }
    // Already showing the translation? No-op.
    if (textMatchesTranslation && !textMatchesBody) {
        return;
    }

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) {
        objc_setAssociatedObject(textNode, kApolloOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSDictionary *attributes = nil;
    if (current.length > 0) {
        attributes = [current attributesAtIndex:0 effectiveRange:NULL];
    }

    NSAttributedString *translatedAttr = [[NSAttributedString alloc] initWithString:translatedText attributes:attributes ?: @{}];

    // Phase D — vote resilience. Mark this text node as ours BEFORE the
    // setAttributedText: write below, so the global setter hook sees the
    // marker and the swap-to-translated logic can trigger if Apollo later
    // overwrites the node (e.g. on vote/score-flair refresh).
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [comment.body copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translatedText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), translatedAttr);
    } @catch (__unused NSException *e) {
        return;
    }

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    objc_setAssociatedObject(commentCellNode, kApolloTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Persist the translation by Reddit fullName so we can re-apply after
    // collapse/expand or cell reuse without hitting the network again.
    NSString *fullName = ApolloCommentFullName(comment);
    if (fullName.length > 0) {
        [sCommentTranslationByFullName setObject:translatedText forKey:fullName];
        objc_setAssociatedObject(commentCellNode, kApolloAppliedTranslationFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    ApolloMarkVisibleTranslationApplied(comment.body, translatedText);
}

static void ApolloRestoreOriginalForCellNode(id commentCellNode, RDKComment *comment) {
    if (!commentCellNode) return;

    id textNode = objc_getAssociatedObject(commentCellNode, kApolloTranslatedTextNodeKey);
    if (!textNode) {
        textNode = ApolloBestCommentTextNode(commentCellNode, comment);
    }
    if (!textNode) return;

    // Drop ownership BEFORE writing original text back, otherwise the vote-
    // resilience hook would swap the original right back to translated.
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original);
    } @catch (__unused NSException *e) {
        return;
    }

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    objc_setAssociatedObject(commentCellNode, kApolloAppliedTranslationFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

#pragma mark - Phase C: post selftext (header cell) translation

// Returns the post (RDKLink) ivar from a header-style cell node, or nil if
// this cellNode isn't a post header. Searches a couple of common ivar names,
// then falls back to scanning ALL `@`-typed ivars in the class hierarchy
// (cheap — there are only a handful per class) so we catch Apollo's actual
// ivar name even if it doesn't match our wishlist.
static RDKLink *ApolloLinkFromHeaderCellNode(id cellNode) {
    if (!cellNode) return nil;
    Class rdkLink = NSClassFromString(@"RDKLink");
    if (!rdkLink) return nil;

    // Fast path — common names.
    static const char *kLinkIvarNames[] = {
        "link", "post", "_link", "_post", "currentLink", "model", "data",
        "headerLink", "linkModel", "postModel", NULL
    };
    for (Class cls = [cellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kLinkIvarNames[i]; i++) {
            Ivar iv = class_getInstanceVariable(cls, kLinkIvarNames[i]);
            if (!iv) continue;
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(cellNode, iv); } @catch (__unused NSException *e) { continue; }
            if ([v isKindOfClass:rdkLink]) return (RDKLink *)v;
        }
    }

    // Fallback — scan every `@`-typed ivar in the class hierarchy and return
    // the first RDKLink we find. Bounded by the small number of ivars per
    // class, so cheap; this is the path that catches Swift-mangled names.
    for (Class cls = [cellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(cellNode, ivars[i]); } @catch (__unused NSException *e) { continue; }
            if ([v isKindOfClass:rdkLink]) {
                free(ivars);
                return (RDKLink *)v;
            }
        }
        free(ivars);
    }
    return nil;
}

static RDKLink *ApolloLinkFromController(UIViewController *vc) {
    if (!vc) return nil;
    Class rdkLink = NSClassFromString(@"RDKLink");
    if (!rdkLink) return nil;
    static const char *kNames[] = {
        "link", "post", "thing", "currentLink", "currentPost", "_link", "_post", NULL
    };
    for (Class cls = [vc class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kNames[i]; i++) {
            Ivar iv = class_getInstanceVariable(cls, kNames[i]);
            if (!iv) continue;
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(vc, iv); } @catch (__unused NSException *e) { continue; }
            if ([v isKindOfClass:rdkLink]) return (RDKLink *)v;
        }
    }
    for (Class cls = [vc class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(vc, ivars[i]); } @catch (__unused NSException *e) { continue; }
            if ([v isKindOfClass:rdkLink]) {
                free(ivars);
                return (RDKLink *)v;
            }
        }
        free(ivars);
    }
    return nil;
}

static NSString *ApolloPlainTextFromHTMLString(NSString *html) {
    if (![html isKindOfClass:[NSString class]] || html.length == 0) return nil;
    NSData *data = [html dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSDictionary *options = @{
        NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
        NSCharacterEncodingDocumentAttribute: @(NSUTF8StringEncoding),
    };
    NSAttributedString *attr = [[NSAttributedString alloc] initWithData:data options:options documentAttributes:nil error:nil];
    NSString *plain = attr.string;
    return [plain isKindOfClass:[NSString class]] ? [plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

static NSString *ApolloPostBodyTextFromLink(RDKLink *link) {
    if (!link) return nil;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    SEL stringSelectors[] = {
        @selector(selfText),
        NSSelectorFromString(@"selftext"),
        NSSelectorFromString(@"body"),
        NSSelectorFromString(@"text"),
        NSSelectorFromString(@"content"),
    };
    for (size_t i = 0; i < sizeof(stringSelectors) / sizeof(stringSelectors[0]); i++) {
        if ([(id)link respondsToSelector:stringSelectors[i]]) {
            id value = ((id (*)(id, SEL))objc_msgSend)((id)link, stringSelectors[i]);
            if ([value isKindOfClass:[NSString class]]) [candidates addObject:value];
        }
    }
    if ([(id)link respondsToSelector:@selector(selfTextHTML)]) {
        NSString *htmlPlain = ApolloPlainTextFromHTMLString(link.selfTextHTML);
        if (htmlPlain.length > 0) [candidates addObject:htmlPlain];
    }
    static const char *kBodyIvarNames[] = {
        "selfText", "selftext", "_selfText", "_selftext", "body", "_body",
        "text", "_text", "content", "_content", "selfTextHTML", "_selfTextHTML", NULL
    };
    for (Class cls = [(id)link class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kBodyIvarNames[i]; i++) {
            Ivar iv = class_getInstanceVariable(cls, kBodyIvarNames[i]);
            if (!iv) continue;
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try { value = object_getIvar(link, iv); } @catch (__unused NSException *e) { continue; }
            if ([value isKindOfClass:[NSString class]]) {
                NSString *string = (NSString *)value;
                if (strstr(kBodyIvarNames[i], "HTML")) string = ApolloPlainTextFromHTMLString(string) ?: string;
                [candidates addObject:string];
            }
        }
    }
    for (NSString *candidate in candidates) {
        NSString *trimmed = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) return trimmed;
    }
    return nil;
}

// Same idea as ApolloKnownBodyTextNode but for post header cells.
static id ApolloKnownPostBodyTextNode(id headerCellNode) {
    if (!headerCellNode) return nil;
    static const char *kCandidateNames[] = {
        "selfTextNode",
        "selfPostBodyNode",
        "bodyTextNode",
        "selfPostTextNode",
        "selfTextTextNode",
        "postBodyNode",
        "postTextNode",
        "bodyNode",
        "markdownNode",
        "attributedTextNode",
        NULL,
    };
    for (Class cls = [headerCellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; kCandidateNames[i]; i++) {
            Ivar iv = class_getInstanceVariable(cls, kCandidateNames[i]);
            if (!iv) continue;
            const char *type = ivar_getTypeEncoding(iv);
            if (!type || type[0] != '@') continue;
            id node = nil;
            @try { node = object_getIvar(headerCellNode, iv); } @catch (__unused NSException *e) { continue; }
            if (!node) continue;
            if (![node respondsToSelector:@selector(attributedText)]) continue;
            return node;
        }
    }
    return nil;
}

static BOOL ApolloPostTextLooksLikeMetadata(NSString *text, RDKLink *link) {
    NSString *norm = ApolloNormalizeTextForCompare(text ?: @"");
    if (norm.length == 0) return YES;
    NSString *titleNorm = ApolloNormalizeTextForCompare(link.title ?: @"");
    NSString *authorNorm = ApolloNormalizeTextForCompare(link.author ?: @"");
    NSString *subredditNorm = ApolloNormalizeTextForCompare(link.subreddit ?: @"");
    if (titleNorm.length > 0 && ([norm isEqualToString:titleNorm] || [titleNorm containsString:norm])) return YES;
    if (authorNorm.length > 0 && [norm containsString:authorNorm]) return YES;
    if (subredditNorm.length > 0 && [norm containsString:subredditNorm]) return YES;
    if ([norm hasPrefix:@"http://"] || [norm hasPrefix:@"https://"]) return YES;
    if (norm.length < 18) return YES;
    return NO;
}

static NSString *ApolloVisibleTextFromNode(id textNode) {
    if (!textNode) return nil;
    NSAttributedString *attr = nil;
    @try { attr = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText)); }
    @catch (__unused NSException *e) { return nil; }
    if (![attr isKindOfClass:[NSAttributedString class]]) return nil;
    return [attr.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *ApolloVisiblePostCacheKey(RDKLink *link, NSString *sourceText, NSString *targetLanguage) {
    NSString *fullName = link.fullName;
    if (fullName.length > 0) return fullName;
    NSString *sourceNorm = ApolloNormalizeTextForCompare(sourceText ?: @"");
    if (sourceNorm.length == 0) return nil;
    return [NSString stringWithFormat:@"_visiblePost|%@|%lu", targetLanguage ?: @"en", (unsigned long)sourceNorm.hash];
}

// Picks the post-body text node by name first, then falls back to a scored
// scan. If Apollo's model text is unavailable, choose the longest visible
// body-like text node that is not title/byline/URL metadata.
static id ApolloBestPostBodyTextNode(id headerCellNode, RDKLink *link, NSString *bodyText) {
    id known = ApolloKnownPostBodyTextNode(headerCellNode);
    if (known) {
        NSString *knownText = ApolloVisibleTextFromNode(known);
        if (bodyText.length > 0) {
            @try {
                NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(known, @selector(attributedText));
                if (ApolloCandidateScore(attr, bodyText) > NSIntegerMin) return known;
            } @catch (__unused NSException *e) { /* fall through */ }
        } else if (!ApolloPostTextLooksLikeMetadata(knownText, link)) {
            return known;
        }
    }
    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloCollectAttributedTextNodes(headerCellNode, 5, visited, candidates);
    id best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id n in candidates) {
        NSAttributedString *attr = nil;
        @try { attr = ((id (*)(id, SEL))objc_msgSend)(n, @selector(attributedText)); }
        @catch (__unused NSException *e) { continue; }
        NSInteger s = bodyText.length > 0 ? ApolloCandidateScore(attr, bodyText) : NSIntegerMin;
        if (s == NSIntegerMin && !ApolloPostTextLooksLikeMetadata(attr.string, link)) {
            s = (NSInteger)attr.string.length;
        }
        if (s > bestScore) { bestScore = s; best = n; }
    }
    return best;
}

static void ApolloApplyTranslationToHeaderCellNode(id headerCellNode, RDKLink *link, NSString *sourceText, NSString *translatedText) {
    if (!headerCellNode) return;
    if (![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0) return;
    NSString *body = sourceText.length > 0 ? sourceText : ApolloPostBodyTextFromLink(link);
    if (![body isKindOfClass:[NSString class]] || body.length == 0) return;

    id textNode = ApolloBestPostBodyTextNode(headerCellNode, link, body);
    if (!textNode) return;

    NSAttributedString *current = nil;
    @try { current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText)); }
    @catch (__unused NSException *e) { return; }
    if (![current isKindOfClass:[NSAttributedString class]]) return;

    NSString *currentNorm = ApolloNormalizeTextForCompare(current.string);
    NSString *bodyNorm = ApolloNormalizeTextForCompare(body);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);
    if (currentNorm.length == 0 || bodyNorm.length == 0) return;
    BOOL textMatchesBody = [currentNorm isEqualToString:bodyNorm] ||
                           [currentNorm containsString:bodyNorm] ||
                           [bodyNorm containsString:currentNorm];
    BOOL textMatchesTranslation = translatedNorm.length > 0 &&
        ([currentNorm isEqualToString:translatedNorm] ||
         [currentNorm containsString:translatedNorm] ||
         [translatedNorm containsString:currentNorm]);
    if (!textMatchesBody && !textMatchesTranslation) return;
    if (textMatchesTranslation && !textMatchesBody) return;

    NSAttributedString *originalSaved = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![originalSaved isKindOfClass:[NSAttributedString class]]) {
        objc_setAssociatedObject(textNode, kApolloOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSDictionary *attrs = current.length > 0 ? [current attributesAtIndex:0 effectiveRange:NULL] : nil;
    NSAttributedString *translatedAttr = [[NSAttributedString alloc] initWithString:translatedText attributes:attrs ?: @{}];

    // Same vote-resilience marker pattern as comment cells.
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [body copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translatedText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), translatedAttr); }
    @catch (__unused NSException *e) { return; }

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    objc_setAssociatedObject(headerCellNode, kApolloHeaderTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *fullName = link.fullName;
    if (fullName.length > 0) {
        [sLinkTranslationByFullName setObject:translatedText forKey:fullName];
        objc_setAssociatedObject(headerCellNode, kApolloAppliedHeaderTranslationFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    ApolloMarkVisibleTranslationApplied(body, translatedText);
}

static void ApolloRestoreOriginalForHeaderCellNode(id headerCellNode, RDKLink *link) {
    if (!headerCellNode) return;
    id textNode = objc_getAssociatedObject(headerCellNode, kApolloHeaderTranslatedTextNodeKey);
    if (!textNode) textNode = ApolloBestPostBodyTextNode(headerCellNode, link, ApolloPostBodyTextFromLink(link));
    if (!textNode) return;

    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;
    @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original); }
    @catch (__unused NSException *e) { return; }

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }
    objc_setAssociatedObject(headerCellNode, kApolloAppliedHeaderTranslationFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
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
    Class rdkCommentClass = NSClassFromString(@"RDKComment");
    if (!rdkCommentClass || ![comment isKindOfClass:rdkCommentClass]) return nil;
    return (RDKComment *)comment;
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

    NSString *fullName = ApolloCommentFullName(comment);
    if (ApolloCommentContainsCodeOrPreformatted(comment)) {
        if (fullName.length > 0) {
            [sCommentTranslationByFullName removeObjectForKey:fullName];
        }
        ApolloRestoreOriginalForCellNode(commentCellNode, comment);
        ApolloLog(@"[Translation] Skipping comment with code/preformatted content");
        return;
    }

    // Fast path 1: we already translated this exact comment in this session.
    // Re-apply from the fullName cache without going to the network. This
    // makes collapse/expand and cell reuse re-show the translation immediately.
    if (fullName.length > 0) {
        NSString *cachedTranslation = [sCommentTranslationByFullName objectForKey:fullName];
        if (cachedTranslation.length > 0) {
            ApolloApplyTranslationToCellNode(commentCellNode, comment, cachedTranslation);
            return;
        }
    }

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
        if (!strongCellNode) {
            // Cell gone, but stash the translation by fullName so the next
            // re-displayed cell for this comment picks it up instantly.
            if ([translated isKindOfClass:[NSString class]] && translated.length > 0 && fullName.length > 0) {
                [sCommentTranslationByFullName setObject:translated forKey:fullName];
            }
            return;
        }

        NSString *currentKey = objc_getAssociatedObject(strongCellNode, kApolloCellTranslationKeyKey);
        if (![currentKey isEqualToString:cacheKey]) return;

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) {
                ApolloLog(@"[Translation] Failed to translate comment: %@", error.localizedDescription ?: @"unknown error");
            }
            return;
        }

        // Stash by fullName even if the cell is no longer eligible to render
        // it, so a future re-display gets it for free.
        if (fullName.length > 0) {
            [sCommentTranslationByFullName setObject:translated forKey:fullName];
        }

        if (!forceTranslation && !ApolloShouldTranslateNow(NO)) return;

        RDKComment *strongComment = ApolloCommentFromCellNode(strongCellNode);
        if (!strongComment) return;

        ApolloApplyTranslationToCellNode(strongCellNode, strongComment, translated);
    });
}

// Re-applies a previously-translated body from the fullName cache, without
// hitting the network or re-running language detection. Used when a cell
// re-enters display (collapse/expand, scroll-back, reuse).
static BOOL ApolloReapplyCachedTranslationForCellNode(id commentCellNode) {
    if (!commentCellNode) return NO;
    RDKComment *comment = ApolloCommentFromCellNode(commentCellNode);
    if (!comment) return NO;
    NSString *fullName = ApolloCommentFullName(comment);
    if (fullName.length == 0) return NO;
    NSString *cached = [sCommentTranslationByFullName objectForKey:fullName];
    if (cached.length == 0) return NO;
    ApolloApplyTranslationToCellNode(commentCellNode, comment, cached);
    return YES;
}

static void ApolloScheduleCachedTranslationReapplyForCellNode(id commentCellNode) {
    if (!commentCellNode || !sEnableBulkTranslation) return;
    if (!ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) return;
    if ([objc_getAssociatedObject(commentCellNode, kApolloReapplyScheduledKey) boolValue]) return;
    objc_setAssociatedObject(commentCellNode, kApolloReapplyScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakNode = commentCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakNode;
        if (!strong) return;
        objc_setAssociatedObject(strong, kApolloReapplyScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloReapplyCachedTranslationForCellNode(strong);
    });
}

#pragma mark - Phase C: post selftext translation driver

static void ApolloMaybeTranslatePostHeaderCellNode(id headerCellNode, RDKLink *fallbackLink, BOOL forceTranslation) {
    if (!headerCellNode) return;
    RDKLink *link = ApolloLinkFromHeaderCellNode(headerCellNode);
    if (!link) link = fallbackLink;
    NSString *body = ApolloPostBodyTextFromLink(link);
    id visibleBodyNode = ApolloBestPostBodyTextNode(headerCellNode, link, body);
    NSString *visibleBody = ApolloVisibleTextFromNode(visibleBodyNode);
    if (![body isKindOfClass:[NSString class]] || body.length == 0) {
        body = visibleBody;
    } else if (visibleBody.length > 0 && !ApolloPostTextLooksLikeMetadata(visibleBody, link)) {
        NSString *bodyNorm = ApolloNormalizeTextForCompare(body);
        NSString *visibleNorm = ApolloNormalizeTextForCompare(visibleBody);
        BOOL visibleMatchesModel = [visibleNorm isEqualToString:bodyNorm] ||
                                   [visibleNorm containsString:bodyNorm] ||
                                   [bodyNorm containsString:visibleNorm];
        if (!visibleMatchesModel) {
            body = visibleBody;
        }
    }
    if (![body isKindOfClass:[NSString class]]) return;
    NSString *trimmed = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;  // link/image post — nothing to translate

    if (ApolloLinkContainsCodeOrPreformatted(link, trimmed)) {
        NSString *linkFullName = link.fullName;
        if (linkFullName.length > 0) {
            [sLinkTranslationByFullName removeObjectForKey:linkFullName];
        }
        ApolloRestoreOriginalForHeaderCellNode(headerCellNode, link);
        ApolloLog(@"[Translation] Skipping post body with code/preformatted content");
        return;
    }

    if (!ApolloShouldTranslateNow(forceTranslation)) return;

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) return;

    NSString *cacheStoreKey = ApolloVisiblePostCacheKey(link, trimmed, targetLanguage);
    if (cacheStoreKey.length > 0) {
        NSString *cached = [sLinkTranslationByFullName objectForKey:cacheStoreKey];
        if (cached.length > 0) {
            ApolloApplyTranslationToHeaderCellNode(headerCellNode, link, trimmed, cached);
            return;
        }
    }

    if (!forceTranslation) {
        NSString *detected = ApolloDetectDominantLanguage(trimmed);
        if ([detected isEqualToString:targetLanguage]) return;
    }

    NSString *cacheKey = ApolloTranslationCacheKey(trimmed, targetLanguage);
    objc_setAssociatedObject(headerCellNode, kApolloHeaderCellTranslationKeyKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);

    __weak id weakHeader = headerCellNode;
    ApolloRequestTranslation(cacheKey, trimmed, targetLanguage, ^(NSString *translated, NSError *error) {
        id strongHeader = weakHeader;
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) ApolloLog(@"[Translation] Failed to translate post body: %@", error.localizedDescription ?: @"unknown");
            return;
        }
        if (cacheStoreKey.length > 0) {
            [sLinkTranslationByFullName setObject:translated forKey:cacheStoreKey];
        }
        if (!strongHeader) return;
        NSString *currentKey = objc_getAssociatedObject(strongHeader, kApolloHeaderCellTranslationKeyKey);
        if (![currentKey isEqualToString:cacheKey]) return;
        if (!forceTranslation && !ApolloShouldTranslateNow(NO)) return;

        RDKLink *strongLink = ApolloLinkFromHeaderCellNode(strongHeader);
        if (!strongLink) strongLink = fallbackLink;
        ApolloApplyTranslationToHeaderCellNode(strongHeader, strongLink, trimmed, translated);
    });
}

// Walks the comments table looking for post header roots. Apollo can render
// the post body as a cell node, a tableHeaderView, or a plain contentView
// wrapper depending on post type/media layout, so cover those surfaces.
static void ApolloMaybeTranslatePostHeaderForController(UIViewController *viewController, BOOL forceTranslation) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;
    RDKLink *controllerLink = ApolloLinkFromController(viewController);

    if (tableView.tableHeaderView) {
        ApolloMaybeTranslatePostHeaderCellNode(tableView.tableHeaderView, controllerLink, forceTranslation);
    }

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        id cellNode = nil;
        if ([cell respondsToSelector:nodeSelector]) {
            cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        }
        if (!cellNode && controllerLink) {
            cellNode = cell.contentView ?: cell;
        }
        if (!cellNode) continue;
        if (ApolloLinkFromHeaderCellNode(cellNode) || (!ApolloCommentFromCellNode(cellNode) && controllerLink)) {
            ApolloMaybeTranslatePostHeaderCellNode(cellNode, controllerLink, forceTranslation);
        }
    }
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

    // Phase C — also translate the post selftext (header cell) if present.
    ApolloMaybeTranslatePostHeaderForController(viewController, forceTranslation);
}

static void ApolloRestoreVisibleCommentsForController(UIViewController *viewController) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;
    RDKLink *controllerLink = ApolloLinkFromController(viewController);

    if (tableView.tableHeaderView) {
        ApolloRestoreOriginalForHeaderCellNode(tableView.tableHeaderView, controllerLink);
    }

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        id cellNode = nil;
        if ([cell respondsToSelector:nodeSelector]) {
            cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        }
        if (!cellNode && controllerLink) {
            cellNode = cell.contentView ?: cell;
        }
        if (!cellNode) continue;

        RDKComment *comment = ApolloCommentFromCellNode(cellNode);

        // Header cell? Restore post body and skip the comment path.
        RDKLink *link = ApolloLinkFromHeaderCellNode(cellNode);
        if (link || !comment) {
            if (!link) link = controllerLink;
            NSString *linkFullName = link.fullName;
            if (linkFullName.length > 0) {
                [sLinkTranslationByFullName removeObjectForKey:linkFullName];
            }
            ApolloRestoreOriginalForHeaderCellNode(cellNode, link);
            continue;
        }

        // Drop from the persistent fullName cache so cellNodeVisibilityEvent:
        // / didEnterDisplayState don't re-apply it after the user asked for
        // the original text.
        NSString *fullName = ApolloCommentFullName(comment);
        if (fullName.length > 0) {
            [sCommentTranslationByFullName removeObjectForKey:fullName];
        }

        ApolloRestoreOriginalForCellNode(cellNode, comment);
    }
}

#pragma mark - Phase A/B: nav-bar globe icon + status banner

// Forward declaration so the globe bar button action can call it.
static void ApolloToggleThreadTranslationForController(UIViewController *vc);

// Returns a localized human name for the active target language (e.g. "en"
// → "English"). Falls back to the uppercased code.
static NSString *ApolloLocalizedTargetLanguageName(void) {
    NSString *code = ApolloResolvedTargetLanguageCode();
    NSString *name = [[NSLocale currentLocale] localizedStringForLanguageCode:code];
    if (name.length == 0) return [code uppercaseString];
    // Capitalize first letter for nicer display.
    return [[name substringToIndex:1].localizedUppercaseString stringByAppendingString:[name substringFromIndex:1]];
}

// Lazily install our small status caption inside the POST HEADER cell view
// (the cell that shows the post title / author / score / age). Pinned to
// the bottom-trailing edge of the cell so it sits on the same row as the
// "100% 2h" metadata — exactly where the user wants it. Returns the label
// (creating it if necessary) or nil if the header cell view isn't loaded.
static UILabel *ApolloEnsureBannerInHeaderCellView(UIView *headerCellView) {
    if (!headerCellView) return nil;
    UILabel *banner = objc_getAssociatedObject(headerCellView, kApolloTranslationBannerKey);
    if (banner && banner.superview == headerCellView) return banner;

    banner = [[UILabel alloc] init];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    banner.textAlignment = NSTextAlignmentRight;
    banner.backgroundColor = [UIColor clearColor];
    banner.numberOfLines = 1;
    banner.adjustsFontSizeToFitWidth = YES;
    banner.minimumScaleFactor = 0.85;
    banner.userInteractionEnabled = NO;
    banner.hidden = YES;
    [headerCellView addSubview:banner];

    // Pin trailing/bottom inside the header cell. Bottom is anchored a bit up
    // from the divider so it visually aligns with the metadata row baseline.
    [NSLayoutConstraint activateConstraints:@[
        [banner.trailingAnchor constraintEqualToAnchor:headerCellView.trailingAnchor constant:-14.0],
        [banner.bottomAnchor constraintEqualToAnchor:headerCellView.bottomAnchor constant:-44.0],
        [banner.heightAnchor constraintEqualToConstant:14.0],
        [banner.widthAnchor constraintLessThanOrEqualToAnchor:headerCellView.widthAnchor multiplier:0.6],
    ]];
    objc_setAssociatedObject(headerCellView, kApolloTranslationBannerKey, banner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return banner;
}

// Finds the post header cell's view (if visible), returns nil otherwise.
static UIView *ApolloFindPostHeaderCellViewForController(UIViewController *vc) {
    UITableView *tableView = GetCommentsTableView(vc);
    if (!tableView) return nil;
    RDKLink *controllerLink = ApolloLinkFromController(vc);
    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSelector]) continue;
        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        if (ApolloLinkFromHeaderCellNode(cellNode) || (!ApolloCommentFromCellNode(cellNode) && controllerLink)) {
            return cell.contentView ?: cell;
        }
    }
    return nil;
}

static void ApolloUpdateBannerForController(UIViewController *vc) {
    if (!vc) return;
    UIView *headerView = ApolloFindPostHeaderCellViewForController(vc);
    if (!headerView) return;  // header off-screen, nothing to do

    UILabel *banner = ApolloEnsureBannerInHeaderCellView(headerView);
    if (!banner) return;
    banner.hidden = YES;
}

static void ApolloUpdateTranslationUIForController(id controller) {
    UIViewController *vc = (UIViewController *)controller;

    UIBarButtonItem *translationItem = objc_getAssociatedObject(controller, kApolloTranslateBarButtonKey);
    NSMutableArray<UIBarButtonItem *> *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    if (!sEnableBulkTranslation) {
        // Feature flipped off: revert any active translation, drop the bar
        // button + hide the banner. Do not leak associations.
        if (ApolloControllerIsInTranslatedMode(vc)) {
            ApolloRestoreVisibleCommentsForController(vc);
        }
        ApolloClearVisibleTranslationApplied(vc);
        objc_setAssociatedObject(controller, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kApolloThreadOriginalModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (translationItem) {
            [items removeObject:translationItem];
            vc.navigationItem.rightBarButtonItems = items;
            objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ApolloUpdateBannerForController(vc);
        return;
    }

    BOOL translatedMode = ApolloControllerIsInTranslatedMode(vc);
    BOOL visibleTranslationApplied = [objc_getAssociatedObject(vc, kApolloVisibleTranslationAppliedKey) boolValue];
    NSString *targetName = ApolloLocalizedTargetLanguageName();

    // Compact globe icon — same width as the existing nav buttons, so the
    // central pill (sort/3-dots) is not pushed out of place.
    UIImage *globeImage = [UIImage systemImageNamed:@"globe"];
    if (!translationItem) {
        translationItem = [[UIBarButtonItem alloc] initWithImage:globeImage
                                                           style:UIBarButtonItemStylePlain
                                                          target:controller
                                                          action:@selector(apollo_translationGlobeTapped)];
        // Slight visual hint when translated mode is on — same image, distinct
        // tint so the user sees at a glance.
        objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, translationItem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    translationItem.image = globeImage;
    translationItem.target = controller;
    translationItem.action = @selector(apollo_translationGlobeTapped);
    translationItem.menu = nil;
    translationItem.tintColor = visibleTranslationApplied ? [UIColor systemGreenColor] : [UIColor systemBlueColor];
    translationItem.accessibilityLabel = translatedMode
        ? @"Translation: showing translated. Tap to show original."
        : [NSString stringWithFormat:@"Translation: showing original. Tap to translate to %@.", targetName];

    if (![items containsObject:translationItem]) {
        // Apollo's rightBarButtonItems are displayed right-to-left. Adding at
        // the END places the globe on the LEFT side of the existing pill,
        // keeping the three-dots / sort controls in their original slots.
        [items addObject:translationItem];
    }
    vc.navigationItem.rightBarButtonItems = items;

    ApolloUpdateBannerForController(vc);
}

static void ApolloToggleThreadTranslationForController(UIViewController *vc) {
    if (!vc) return;
    BOOL wasTranslated = ApolloControllerIsInTranslatedMode(vc);
    if (wasTranslated) {
        // Switch to original.
        ApolloRestoreVisibleCommentsForController(vc);
        ApolloClearVisibleTranslationApplied(vc);
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        // Switch to translated.
        ApolloClearVisibleTranslationApplied(vc);
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloTranslateVisibleCommentsForController(vc, YES);
    }
    ApolloUpdateTranslationUIForController(vc);
}

#pragma mark - Phase D: vote / redisplay resilience

// Helper: rebuild a translated NSAttributedString preserving the attributes of
// `incoming` (which carries Apollo's freshly-computed score color, font size,
// link styles, etc.) but using our cached translated string.
static NSAttributedString *ApolloRebuildTranslatedAttrPreservingAttrs(NSAttributedString *incoming, NSString *translatedText) {
    NSDictionary *attrs = nil;
    if ([incoming isKindOfClass:[NSAttributedString class]] && incoming.length > 0) {
        attrs = [incoming attributesAtIndex:0 effectiveRange:NULL];
    }
    return [[NSAttributedString alloc] initWithString:translatedText attributes:attrs ?: @{}];
}

// Global setAttributedText: hook on ASTextNode. Strict no-op for any node we
// haven't tagged with kApolloTranslationOwnedTextNodeKey. For tagged nodes:
// if Apollo is overwriting back to the original `comment.body`, swap to our
// cached translated string. This catches vote/score-color refresh, edit, and
// any other "Apollo rewrites the body without going through cell reuse"
// pathway in a single chokepoint.
%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (![objc_getAssociatedObject(self, kApolloTranslationOwnedTextNodeKey) boolValue]) {
        %orig;
        return;
    }

    // Re-entrancy guard: when WE call %orig with a substituted string, the
    // hook re-fires. Skip the swap on the inner call.
    if ([objc_getAssociatedObject(self, kApolloOwnedNodeReentrancyKey) boolValue]) {
        %orig;
        return;
    }

    NSString *originalBody = objc_getAssociatedObject(self, kApolloOwnedNodeOriginalBodyKey);
    NSString *translatedText = objc_getAssociatedObject(self, kApolloOwnedNodeTranslatedTextKey);

    if (![originalBody isKindOfClass:[NSString class]] || originalBody.length == 0 ||
        ![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0 ||
        ![attributedText isKindOfClass:[NSAttributedString class]]) {
        %orig;
        return;
    }

    NSString *incomingNorm = ApolloNormalizeTextForCompare(attributedText.string);
    NSString *originalNorm = ApolloNormalizeTextForCompare(originalBody);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);

    // If the incoming string already matches our translation, pass through.
    if (translatedNorm.length > 0 &&
        ([incomingNorm isEqualToString:translatedNorm] ||
         [incomingNorm containsString:translatedNorm] ||
         [translatedNorm containsString:incomingNorm])) {
        %orig;
        return;
    }

    // If the incoming string matches the original body, Apollo is reverting
    // (e.g. after vote / score color refresh). Substitute the cached
    // translation, preserving incoming attributes (color, font, links).
    BOOL incomingIsOriginal = [incomingNorm isEqualToString:originalNorm] ||
                              [incomingNorm containsString:originalNorm] ||
                              [originalNorm containsString:incomingNorm];
    if (incomingIsOriginal) {
        NSAttributedString *swap = ApolloRebuildTranslatedAttrPreservingAttrs(attributedText, translatedText);
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(swap); } @catch (__unused NSException *e) {}
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Unknown content (some other text Apollo wants to display). Pass
    // through unchanged — and clear the marker so this node is no longer
    // considered ours.
    objc_setAssociatedObject(self, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (![objc_getAssociatedObject(self, kApolloTranslationOwnedTextNodeKey) boolValue]) {
        %orig;
        return;
    }

    if ([objc_getAssociatedObject(self, kApolloOwnedNodeReentrancyKey) boolValue]) {
        %orig;
        return;
    }

    NSString *originalBody = objc_getAssociatedObject(self, kApolloOwnedNodeOriginalBodyKey);
    NSString *translatedText = objc_getAssociatedObject(self, kApolloOwnedNodeTranslatedTextKey);

    if (![originalBody isKindOfClass:[NSString class]] || originalBody.length == 0 ||
        ![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0 ||
        ![attributedText isKindOfClass:[NSAttributedString class]]) {
        %orig;
        return;
    }

    NSString *incomingNorm = ApolloNormalizeTextForCompare(attributedText.string);
    NSString *originalNorm = ApolloNormalizeTextForCompare(originalBody);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);

    if (translatedNorm.length > 0 &&
        ([incomingNorm isEqualToString:translatedNorm] ||
         [incomingNorm containsString:translatedNorm] ||
         [translatedNorm containsString:incomingNorm])) {
        %orig;
        return;
    }

    BOOL incomingIsOriginal = [incomingNorm isEqualToString:originalNorm] ||
                              [incomingNorm containsString:originalNorm] ||
                              [originalNorm containsString:incomingNorm];
    if (incomingIsOriginal) {
        NSAttributedString *swap = ApolloRebuildTranslatedAttrPreservingAttrs(attributedText, translatedText);
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(swap); } @catch (__unused NSException *e) {}
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    objc_setAssociatedObject(self, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}

%end

%hook _TtC6Apollo15CommentCellNode

- (void)setNeedsLayout {
    %orig;
    ApolloScheduleCachedTranslationReapplyForCellNode((id)self);
}

- (void)setNeedsDisplay {
    %orig;
    ApolloScheduleCachedTranslationReapplyForCellNode((id)self);
}

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

- (void)didEnterDisplayState {
    %orig;

    // Cell coming on-screen (scroll-back, collapse→expand, reuse). If we have
    // a cached translation for this comment, re-apply instantly — no network,
    // no language detection. This fixes the "translation lost on
    // collapse/uncollapse" report.
    if (sEnableBulkTranslation) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ApolloReapplyCachedTranslationForCellNode((id)self)) {
                ApolloMaybeTranslateCommentCellNode((id)self, NO);
            }
        });
    }
}

- (void)cellNodeVisibilityEvent:(NSInteger)event {
    %orig;

    // Event 0 = "will become visible". Re-apply cached translation as soon as
    // possible so the original text never flashes when re-displaying.
    if (sEnableBulkTranslation && event == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloReapplyCachedTranslationForCellNode((id)self);
        });
    }
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    %orig;
    ApolloUpdateTranslationUIForController(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloUpdateTranslationUIForController(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    sVisibleCommentsViewController = (UIViewController *)self;

    if (sEnableBulkTranslation && ApolloControllerIsInTranslatedMode((UIViewController *)self)) {
        ApolloClearVisibleTranslationApplied((UIViewController *)self);
        ApolloUpdateTranslationUIForController(self);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloTranslateVisibleCommentsForController((UIViewController *)self, NO);
            ApolloUpdateTranslationUIForController(self);
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
- (void)apollo_translationGlobeTapped {
    ApolloToggleThreadTranslationForController((UIViewController *)self);
}

%end

%ctor {
    sTranslationCache = [NSCache new];
    sCommentTranslationByFullName = [NSCache new];
    sCommentTranslationByFullName.countLimit = 2048;
    sLinkTranslationByFullName = [NSCache new];
    sLinkTranslationByFullName.countLimit = 256;
    sPendingTranslationCallbacks = [NSMutableDictionary dictionary];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        [sTranslationCache removeAllObjects];
        [sCommentTranslationByFullName removeAllObjects];
        [sLinkTranslationByFullName removeAllObjects];
    }];

    %init;
}
