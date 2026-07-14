#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>
#import <string.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloState.h"
#import "Tweak.h"

@class ASDisplayNode;
@class ASTextNode;
@class ASInsetLayoutSpec;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic, weak) id delegate;
@property (copy) NSArray<NSString *> *linkAttributeNames;
@property (nonatomic) BOOL userInteractionEnabled;
@end

@interface ASInsetLayoutSpec : NSObject
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

struct CDStruct_90e057aa { CGSize min; CGSize max; };

static const void *kApolloDeletedCommentsHighlightViewKey = &kApolloDeletedCommentsHighlightViewKey;
static const void *kApolloDeletedCommentsHiddenOriginalTextKey = &kApolloDeletedCommentsHiddenOriginalTextKey;
static const void *kApolloDeletedCommentsHiddenFullNameKey = &kApolloDeletedCommentsHiddenFullNameKey;
static const void *kApolloDeletedCommentsHiddenTextNodeKey = &kApolloDeletedCommentsHiddenTextNodeKey;
static const void *kApolloDeletedCommentsHiddenTextNodesKey = &kApolloDeletedCommentsHiddenTextNodesKey;
static const void *kApolloDeletedCommentsSuppressNextCollapseKey = &kApolloDeletedCommentsSuppressNextCollapseKey;
static const void *kApolloDeletedCommentsBodyOwnerCellKey = &kApolloDeletedCommentsBodyOwnerCellKey;
// Reverse of BodyOwnerCellKey: the cell -> its MarkdownNode (captured when the
// MarkdownNode's layoutSpecThatFits hook runs, which is the only place we have a
// guaranteed-correct reference to that node, independent of ivar-name lookup).
static const void *kApolloDeletedCommentsCellMarkdownNodeKey = &kApolloDeletedCommentsCellMarkdownNodeKey;
static const void *kApolloDeletedCommentsBodyReplacementTextNodeKey = &kApolloDeletedCommentsBodyReplacementTextNodeKey;
static const void *kApolloDeletedCommentsOriginalBodyKey = &kApolloDeletedCommentsOriginalBodyKey;
static const void *kApolloDeletedCommentsOriginalBodyHTMLKey = &kApolloDeletedCommentsOriginalBodyHTMLKey;
static const void *kApolloDeletedCommentsHostLayoutRefreshScheduledKey = &kApolloDeletedCommentsHostLayoutRefreshScheduledKey;
static const void *kApolloDeletedCommentsRevealToggleInFlightKey = &kApolloDeletedCommentsRevealToggleInFlightKey;
static const void *kApolloDeletedCommentsReasonChipRepairScheduledKey = &kApolloDeletedCommentsReasonChipRepairScheduledKey;
static const void *kApolloDeletedCommentsRevealTapGestureKey = &kApolloDeletedCommentsRevealTapGestureKey;

static NSMutableDictionary<NSString *, NSHashTable *> *sApolloDeletedCommentsVisibleCellsByFullName = nil;
static NSObject *sApolloDeletedCommentsVisibleCellsLock = nil;
static NSDictionary<NSAttributedStringKey, id> *sApolloDeletedCommentsBodyAttributesTemplate = nil;
// Apollo's ACTUAL comment-body font, captured live from a normally-rendered comment.
// Deriving the size ourselves (preferredFontForTextStyle:Subheadline at a resolved
// content-size category) was off by ~one Dynamic Type step vs Apollo's real font, so
// deleted comments rendered larger than normal ones — and worse when we own the layout
// (tap-to-reveal), where there is no native node left to read. Capturing the real font
// makes deleted bodies match exactly and track in-app/system text-size changes.
static UIFont *sApolloDeletedCommentsLiveCommentBodyFont = nil;
static BOOL sApolloDeletedCommentsBodyAttributesRefreshScheduled = NO;

// Both shared globals above (the captured live body font + the derived body
// attributes template) are read AND written from multiple threads: the
// setAttributedText: capture and the MarkdownNode layoutSpec resolver fire on
// background AsyncDisplayKit node-allocation threads, while cell-prep/refresh
// paths run on the main thread. An ARC store to a __strong global releases the
// previous object, so a store racing a read on another thread can free an
// object mid-`isKindOfClass:` — the intermittent EXC_BAD_ACCESS in
// ApolloDeletedCommentsCaptureLiveCommentBodyFont (two comment bodies rendering
// on two threads: one stores a new font while the other reads the old pointer).
// Funnel every access through these lock-guarded accessors: a getter retains
// its snapshot into a strong local UNDER the lock, so the returned value stays
// valid for the caller even if another thread stores (and releases the old
// value) the instant the lock is dropped.
static os_unfair_lock sApolloDeletedCommentsFontStateLock = OS_UNFAIR_LOCK_INIT;

static UIFont *ApolloDeletedCommentsLiveBodyFontGet(void) {
    os_unfair_lock_lock(&sApolloDeletedCommentsFontStateLock);
    UIFont *font = sApolloDeletedCommentsLiveCommentBodyFont;
    os_unfair_lock_unlock(&sApolloDeletedCommentsFontStateLock);
    return font;
}

static void ApolloDeletedCommentsLiveBodyFontSet(UIFont *font) {
    os_unfair_lock_lock(&sApolloDeletedCommentsFontStateLock);
    sApolloDeletedCommentsLiveCommentBodyFont = font;
    os_unfair_lock_unlock(&sApolloDeletedCommentsFontStateLock);
}

static NSDictionary<NSAttributedStringKey, id> *ApolloDeletedCommentsBodyTemplateGet(void) {
    os_unfair_lock_lock(&sApolloDeletedCommentsFontStateLock);
    NSDictionary<NSAttributedStringKey, id> *tmpl = sApolloDeletedCommentsBodyAttributesTemplate;
    os_unfair_lock_unlock(&sApolloDeletedCommentsFontStateLock);
    return tmpl;
}

static void ApolloDeletedCommentsBodyTemplateSet(NSDictionary<NSAttributedStringKey, id> *tmpl) {
    os_unfair_lock_lock(&sApolloDeletedCommentsFontStateLock);
    sApolloDeletedCommentsBodyAttributesTemplate = tmpl;
    os_unfair_lock_unlock(&sApolloDeletedCommentsFontStateLock);
}
static NSString *const ApolloDeletedCommentsRevealURLString = @"apollo-deleted-comments://reveal";
static NSString *const ApolloDeletedCommentsRevealAttributeName = @"ApolloDeletedCommentsRevealAttribute";
static NSString *const ApolloDeletedCommentsReasonPrefixAttributeName = @"ApolloDeletedCommentsReasonPrefixAttribute";

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode);
static void ApolloDeletedCommentsScheduleRevealToggleForTextNode(id cellNode, id textNode);
static void ApolloDeletedCommentsEnsureRevealAttributeIsTappable(id textNode);
static void ApolloDeletedCommentsRevealCommentInsteadOfCollapsing(RDKComment *comment);
static void __attribute__((unused)) ApolloDeletedCommentsScheduleForceExpanded(RDKComment *comment, id cellNode);
static void __attribute__((unused)) ApolloDeletedCommentsApplyTapToRevealIfNeeded(id cellNode);
static NSAttributedString *ApolloDeletedCommentsAttributedTextWithReasonPrefix(id textNode, NSAttributedString *attributedText);
static NSArray *ApolloDeletedCommentsHiddenTextNodesForCell(id cellNode);
static NSString *ApolloDeletedCommentsNormalizedReasonLabel(NSString *label);
static void ApolloDeletedCommentsSetTextNodeAttributedText(id textNode, NSAttributedString *attributedText);
static NSAttributedString *ApolloDeletedCommentsCurrentAttributedText(id textNode);
static NSMutableDictionary *ApolloDeletedCommentsDefaultBodyAttributes(void);
static NSMutableDictionary *ApolloDeletedCommentsBodyAttributesFromAttributedText(NSAttributedString *templateText);
static NSMutableDictionary *ApolloDeletedCommentsReasonChipBaseAttributes(NSAttributedString *templateText, id cellNode);
static void ApolloDeletedCommentsDisableRevealTapInterception(id textNode);
static void ApolloDeletedCommentsSynchronizeCommentModelDisplayState(id cellNode);
static NSString *ApolloDeletedCommentsReasonLabelForCommentAndBody(RDKComment *comment, NSString *body);
static void __attribute__((unused)) ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(id cellNode);
static void ApolloDeletedCommentsScheduleHostLayoutRefresh(id cellNode);
static BOOL ApolloDeletedCommentsStringIsReasonLabel(NSString *text);
static BOOL ApolloDeletedCommentsAuthorLooksDeleted(NSString *author);
static BOOL ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(NSString *candidate);
static BOOL ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(NSAttributedString *attributedText);
static BOOL ApolloDeletedCommentsAttributedTextHasReasonPrefix(NSAttributedString *attributedText);
static BOOL ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(NSAttributedString *attributedText);
static NSAttributedString *ApolloDeletedCommentsAttributedTextByRemovingReasonPrefix(NSAttributedString *attributedText);
static BOOL ApolloDeletedCommentsTextQualifiesAsBodyCandidate(NSString *candidate, NSString *body);
static BOOL ApolloDeletedCommentsTextQualifiesAsBodyFragment(NSString *candidate, NSString *body);
static BOOL ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(NSString *candidate, NSString *body);
static BOOL ApolloDeletedCommentsCommentIsCollapsed(RDKComment *comment);
static void ApolloDeletedCommentsRefreshVisibleDeletedCells(void);
static BOOL ApolloDeletedCommentsBodyAttributesAreUsable(NSDictionary *attributes);
static NSDictionary *ApolloDeletedCommentsRegularizedBodyAttributes(NSDictionary *attributes);
static void ApolloDeletedCommentsScheduleBodyAttributesRefresh(void);
static BOOL ApolloDeletedCommentsBodyAttributeFontsDiffer(NSDictionary *left, NSDictionary *right);

static Class ApolloDeletedCommentsASTextNodeClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"ASTextNode");
    });
    return cls;
}

static Class ApolloDeletedCommentsASInsetLayoutSpecClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"ASInsetLayoutSpec");
    });
    return cls;
}

static NSString *ApolloDeletedCommentsTrimmedString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static UIColor *ApolloDeletedCommentsBadgeRed(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemRedColor];
    }
    return [UIColor redColor];
}

static BOOL ApolloDeletedCommentsLabelIsUserDeleted(NSString *label) {
    return [ApolloDeletedCommentsNormalizedReasonLabel(label) isEqualToString:@"DELETED BY USER"];
}

static UIColor *ApolloDeletedCommentsHighlightColorForLabel(NSString *label) {
    if (ApolloDeletedCommentsLabelIsUserDeleted(label)) {
        return [[UIColor colorWithRed:0.82 green:0.02 blue:0.08 alpha:1.0] colorWithAlphaComponent:0.20];
    }
    return [ApolloDeletedCommentsBadgeRed() colorWithAlphaComponent:0.24];
}

static UIColor *ApolloDeletedCommentsChipBackgroundColor(void) {
    return [UIColor colorWithRed:1.0 green:0.66 blue:0.64 alpha:1.0];
}

static UIColor *ApolloDeletedCommentsChipTextColor(void) {
    return [UIColor colorWithRed:0.42 green:0.06 blue:0.06 alpha:1.0];
}

static UIFont *ApolloDeletedCommentsReasonChipFont(void) {
    return [UIFont boldSystemFontOfSize:13.0];
}

static UIFont *ApolloDeletedCommentsReasonChipFontForBaseAttributes(NSDictionary *baseAttributes) {
    UIFont *bodyFont = [baseAttributes isKindOfClass:[NSDictionary class]] ? baseAttributes[NSFontAttributeName] : nil;
    if (![bodyFont isKindOfClass:[UIFont class]]) {
        NSDictionary *tmpl = ApolloDeletedCommentsBodyTemplateGet();
        bodyFont = [tmpl isKindOfClass:[NSDictionary class]] ? tmpl[NSFontAttributeName] : nil;
    }
    if (![bodyFont isKindOfClass:[UIFont class]]) {
        bodyFont = ApolloDeletedCommentsDefaultBodyAttributes()[NSFontAttributeName];
    }
    if (![bodyFont isKindOfClass:[UIFont class]]) return ApolloDeletedCommentsReasonChipFont();

    CGFloat pointSize = bodyFont.pointSize;
    if (pointSize <= 0.0) return ApolloDeletedCommentsReasonChipFont();

    CGFloat chipPointSize = MAX(11.0, MIN(20.0, pointSize * 0.82));
    UIFontDescriptor *descriptor = [bodyFont.fontDescriptor fontDescriptorWithSymbolicTraits:(bodyFont.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold)];
    UIFont *font = descriptor ? [UIFont fontWithDescriptor:descriptor size:chipPointSize] : nil;
    return font ?: [UIFont boldSystemFontOfSize:chipPointSize];
}

static UIFont *ApolloDeletedCommentsRecoveredBodyFont(void) {
    // Prefer Apollo's real captured comment font when we've seen one.
    UIFont *live = ApolloDeletedCommentsLiveBodyFontGet();
    if ([live isKindOfClass:[UIFont class]]) {
        return live;
    }
    // Last-resort fallback: Apollo's comment body is UIFontTextStyleSubheadline
    // (15pt @ .large), NOT Body (17pt).
    return [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
}

static NSString *ApolloDeletedCommentsNormalizeCommentFullName(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return nil;
    if ([value hasPrefix:@"t1_"]) return value;
    if ([value rangeOfString:@"_"].location != NSNotFound) return nil;
    return [@"t1_" stringByAppendingString:value];
}

static NSString *ApolloDeletedCommentsFullNameForComment(RDKComment *comment) {
    if (!comment) return nil;
    SEL selectors[] = {
        @selector(name),
        NSSelectorFromString(@"fullName"),
        NSSelectorFromString(@"identifier"),
        NSSelectorFromString(@"id"),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if (![(id)comment respondsToSelector:sel]) continue;
        id value = nil;
        @try {
            value = ((id (*)(id, SEL))objc_msgSend)((id)comment, sel);
        } @catch (__unused NSException *e) {
            value = nil;
        }
        NSString *fullName = ApolloDeletedCommentsNormalizeCommentFullName([value isKindOfClass:[NSString class]] ? value : nil);
        if (fullName.length > 0) return fullName;
    }

    static const char *ivarNames[] = {
        "name",
        "_name",
        "fullName",
        "_fullName",
        "identifier",
        "_identifier",
        "commentID",
        "_commentID",
        "id",
        "_id",
        NULL,
    };
    for (Class cls = [(id)comment class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; ivarNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, ivarNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try {
                value = object_getIvar(comment, ivar);
            } @catch (__unused NSException *e) {
                value = nil;
            }
            NSString *fullName = ApolloDeletedCommentsNormalizeCommentFullName([value isKindOfClass:[NSString class]] ? value : nil);
            if (fullName.length > 0) return fullName;
        }
    }
    return nil;
}

static RDKComment *ApolloDeletedCommentsCommentFromCellNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    Ivar commentIvar = class_getInstanceVariable([commentCellNode class], "comment");
    if (!commentIvar) return nil;
    id comment = nil;
    @try {
        comment = object_getIvar(commentCellNode, commentIvar);
    } @catch (__unused NSException *e) {
        comment = nil;
    }
    Class rdkCommentClass = NSClassFromString(@"RDKComment");
    if (!rdkCommentClass || ![comment isKindOfClass:rdkCommentClass]) return nil;
    return (RDKComment *)comment;
}

static NSString *ApolloDeletedCommentsRecoveredReasonForCommentObject(RDKComment *comment) {
    if (!comment) return nil;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsRecoveredReasonForComment(fullName);
}

static BOOL ApolloDeletedCommentsCellNodeIsRecovered(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsRecoveredReasonForComment(fullName).length > 0;
}

static BOOL ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (!ApolloDeletedCommentsIsDeletedPlaceholder(fullName)) return NO;
    NSString *body = comment.body;
    if (ApolloDeletedCommentsStringIsReasonLabel(body) ||
        ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(body)) {
        return YES;
    }
    NSString *trimmedBody = ApolloDeletedCommentsTrimmedString(body);
    return trimmedBody.length == 0 && ApolloDeletedCommentsAuthorLooksDeleted(comment.author);
}

// Passive-mode scoping: with the global toggle off, only threads whose
// per-thread override is active may render treatment. The registries are
// global and outlive a cleared override, so without this a stale entry could
// stamp chips in a non-overridden thread while some other thread's override
// is live. When the comment's linkID can't be read, fall back to the coarse
// gate (no worse than the registries alone).
static BOOL ApolloDeletedCommentsTreatmentAllowedForComment(RDKComment *comment) {
    NSString *linkID = nil;
    if ([(id)comment respondsToSelector:@selector(linkID)]) {
        @try {
            linkID = ((NSString *(*)(id, SEL))objc_msgSend)((id)comment, @selector(linkID));
        } @catch (__unused NSException *e) {}
    }
    if (![linkID isKindOfClass:[NSString class]] || linkID.length == 0) return YES;
    return ApolloDeletedCommentsActiveForLink(linkID);
}

static BOOL ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(id cellNode) {
    if (!ApolloDeletedCommentsCellNodeIsRecovered(cellNode) &&
        !ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode)) {
        return NO;
    }
    return ApolloDeletedCommentsTreatmentAllowedForComment(ApolloDeletedCommentsCommentFromCellNode(cellNode));
}

static BOOL ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsRecoveredComment(fullName);
}

static BOOL ApolloDeletedCommentsCommentIsCollapsed(RDKComment *comment) {
    if (!comment) return NO;
    if ([(id)comment respondsToSelector:@selector(collapsed)]) {
        @try {
            return ((BOOL (*)(id, SEL))objc_msgSend)((id)comment, @selector(collapsed));
        } @catch (__unused NSException *e) {}
    }

    Ivar collapsedIvar = class_getInstanceVariable([(id)comment class], "_collapsed");
    if (collapsedIvar) {
        @try {
            ptrdiff_t offset = ivar_getOffset(collapsedIvar);
            if (offset > 0) {
                BOOL *slot = (BOOL *)((uint8_t *)(__bridge void *)comment + offset);
                return *slot;
            }
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

static NSString *ApolloDeletedCommentsReasonLabelForComment(RDKComment *comment) {
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *reason = ApolloDeletedCommentsRecoveredReasonForCommentObject(comment);
    if (reason.length == 0) reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName);
    NSString *label = ApolloDeletedCommentsDisplayLabelForReason(reason);
    if ([label isEqualToString:@"DELETED BY MOD"]) return @"REMOVED BY MOD";
    return label;
}

static NSString *ApolloDeletedCommentsCommentStringValue(RDKComment *comment, SEL selector) {
    if (!comment || !selector || ![(id)comment respondsToSelector:selector]) return nil;
    id value = nil;
    @try {
        value = ((id (*)(id, SEL))objc_msgSend)((id)comment, selector);
    } @catch (__unused NSException *e) {
        value = nil;
    }
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static void ApolloDeletedCommentsSetCommentStringValue(RDKComment *comment, SEL selector, NSString *value) {
    if (!comment || !selector || ![value isKindOfClass:[NSString class]] || ![(id)comment respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL, NSString *))objc_msgSend)((id)comment, selector, value);
    } @catch (__unused NSException *e) {}
}

static NSString *ApolloDeletedCommentsEscapedHTMLText(NSString *text) {
    NSMutableString *escaped = [text ?: @"" mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

static NSString *ApolloDeletedCommentsPlainBodyHTML(NSString *text) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(text);
    if (trimmed.length == 0) return @"";
    // Route through the shared markdown-aware generator so the saved/restored body_html
    // (returned by the bodyHTML getter hook and Apollo's native renderer) shows links and
    // bold instead of literal "[text](url)"/"**text**". Falls back to escaped plain text.
    NSString *html = ApolloDeletedCommentsRedditBodyHTML(trimmed);
    if (html.length > 0) return html;
    NSString *escaped = ApolloDeletedCommentsEscapedHTMLText(trimmed);
    return [NSString stringWithFormat:@"&lt;div class=&quot;md&quot;&gt;&lt;p&gt;%@&lt;/p&gt;\n&lt;/div&gt;", escaped];
}

static NSString *ApolloDeletedCommentsBodyByAppendingReasonLabel(NSString *body, NSString *label) {
    NSString *trimmedBody = ApolloDeletedCommentsTrimmedString(body);
    NSString *normalizedLabel = ApolloDeletedCommentsNormalizedReasonLabel(label);
    if (trimmedBody.length == 0 || normalizedLabel.length == 0) return body;

    NSString *lowerBody = trimmedBody.lowercaseString;
    NSString *lowerLabel = normalizedLabel.lowercaseString;
    if ([lowerBody isEqualToString:lowerLabel] || [lowerBody hasSuffix:[@"\n\n" stringByAppendingString:lowerLabel]]) {
        return trimmedBody;
    }
    return [NSString stringWithFormat:@"%@\n\n%@", trimmedBody, normalizedLabel];
}

static NSString *__attribute__((unused)) ApolloDeletedCommentsBodyHTMLByAppendingReasonLabel(NSString *bodyHTML, NSString *body, NSString *label) {
    NSString *normalizedLabel = ApolloDeletedCommentsNormalizedReasonLabel(label);
    if (normalizedLabel.length == 0) return bodyHTML;

    NSString *trimmedHTML = ApolloDeletedCommentsTrimmedString(bodyHTML);
    NSString *escapedParagraph = ApolloDeletedCommentsEscapedHTMLText([NSString stringWithFormat:@"<p>%@</p>", ApolloDeletedCommentsEscapedHTMLText(normalizedLabel)]);
    if (trimmedHTML.length > 0 &&
        [trimmedHTML rangeOfString:escapedParagraph options:NSCaseInsensitiveSearch].location == NSNotFound) {
        NSRange escapedClosingDiv = [trimmedHTML rangeOfString:@"&lt;/div&gt;" options:NSBackwardsSearch | NSCaseInsensitiveSearch];
        if (escapedClosingDiv.location != NSNotFound) {
            NSMutableString *mutableHTML = [trimmedHTML mutableCopy];
            [mutableHTML insertString:[@"\n" stringByAppendingString:escapedParagraph] atIndex:escapedClosingDiv.location];
            return mutableHTML;
        }

        NSString *rawParagraph = [NSString stringWithFormat:@"<p>%@</p>", ApolloDeletedCommentsEscapedHTMLText(normalizedLabel)];
        NSRange rawClosingDiv = [trimmedHTML rangeOfString:@"</div>" options:NSBackwardsSearch | NSCaseInsensitiveSearch];
        if (rawClosingDiv.location != NSNotFound && [trimmedHTML rangeOfString:rawParagraph options:NSCaseInsensitiveSearch].location == NSNotFound) {
            NSMutableString *mutableHTML = [trimmedHTML mutableCopy];
            [mutableHTML insertString:[@"\n" stringByAppendingString:rawParagraph] atIndex:rawClosingDiv.location];
            return mutableHTML;
        }
    }

    return ApolloDeletedCommentsPlainBodyHTML(ApolloDeletedCommentsBodyByAppendingReasonLabel(body, normalizedLabel));
}

static BOOL ApolloDeletedCommentsStringIsReasonLabel(NSString *text) {
    NSString *normalized = ApolloDeletedCommentsNormalizedReasonLabel(ApolloDeletedCommentsTrimmedString(text)).uppercaseString;
    return [normalized isEqualToString:@"REMOVED BY MOD"] ||
           [normalized isEqualToString:@"DELETED BY USER"] ||
           [normalized isEqualToString:@"LOADING..."] ||
           [normalized isEqualToString:@"NOT AVAILABLE"];
}

static NSString *ApolloDeletedCommentsRecoverableArchivedBody(NSDictionary *archived) {
    NSString *body = ApolloDeletedCommentsTrimmedString([archived[@"body"] isKindOfClass:[NSString class]] ? archived[@"body"] : nil);
    if (body.length == 0) return nil;
    if (ApolloDeletedCommentsStringIsReasonLabel(body)) return nil;
    if (ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(body)) return nil;
    return body;
}

static BOOL ApolloDeletedCommentsBodyIsDisplayableRecoveredText(NSString *body) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(body);
    if (trimmed.length == 0) return NO;
    if (ApolloDeletedCommentsStringIsReasonLabel(trimmed)) return NO;
    if (ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(trimmed)) return NO;
    return YES;
}

static NSString *ApolloDeletedCommentsResolvedRecoveredBodyForComment(RDKComment *comment) {
    if (!comment) return nil;

    NSString *savedBody = objc_getAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyKey);
    if (ApolloDeletedCommentsBodyIsDisplayableRecoveredText(savedBody)) {
        return savedBody;
    }

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSDictionary *archived = ApolloDeletedCommentsCachedArchivedComment(fullName);
    NSString *archivedBody = ApolloDeletedCommentsRecoverableArchivedBody(archived);
    if (archivedBody.length > 0) {
        objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyKey, [archivedBody copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyHTMLKey, ApolloDeletedCommentsPlainBodyHTML(archivedBody), OBJC_ASSOCIATION_COPY_NONATOMIC);
        return archivedBody;
    }

    NSString *currentBody = comment.body;
    if (ApolloDeletedCommentsBodyIsDisplayableRecoveredText(currentBody)) {
        objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyKey, [currentBody copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
        NSString *bodyHTML = ApolloDeletedCommentsCommentStringValue(comment, @selector(bodyHTML));
        if (bodyHTML.length > 0) {
            objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyHTMLKey, [bodyHTML copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        return currentBody;
    }

    return nil;
}

static BOOL ApolloDeletedCommentsAuthorLooksDeleted(NSString *author) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(author).lowercaseString;
    return trimmed.length == 0 ||
           [trimmed isEqualToString:@"[deleted]"] ||
           [trimmed isEqualToString:@"[removed]"] ||
           [trimmed isEqualToString:@"deleted"] ||
           [trimmed isEqualToString:@"removed"];
}

static BOOL ApolloDeletedCommentsVisibleCommentNeedsRecoveredArchive(RDKComment *comment, NSString *archivedBody) {
    if (!comment || archivedBody.length == 0) return NO;

    NSString *savedBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    BOOL savedBodyMatches = [savedBody isKindOfClass:[NSString class]] &&
                            (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(savedBody, archivedBody) ||
                             ApolloDeletedCommentsTextQualifiesAsBodyFragment(savedBody, archivedBody));
    BOOL authorLooksDeleted = ApolloDeletedCommentsAuthorLooksDeleted(comment.author);
    if (savedBodyMatches && !authorLooksDeleted) return NO;

    NSString *currentBody = comment.body;
    BOOL currentLooksPlaceholder = ApolloDeletedCommentsStringIsReasonLabel(currentBody) ||
                                   ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(currentBody);
    return authorLooksDeleted || currentLooksPlaceholder;
}

static void ApolloDeletedCommentsRememberOriginalModelBodyIfNeeded(RDKComment *comment) {
    if (!comment) return;
    NSString *body = comment.body;
    if (body.length == 0 || ApolloDeletedCommentsStringIsReasonLabel(body) || ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(body)) return;
    if (!objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey)) {
        objc_setAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey, [body copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    }

    NSString *bodyHTML = ApolloDeletedCommentsCommentStringValue(comment, @selector(bodyHTML));
    if (bodyHTML.length > 0 && !objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyHTMLKey)) {
        objc_setAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyHTMLKey, [bodyHTML copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static BOOL ApolloDeletedCommentsRestoreOriginalModelBodyIfNeeded(RDKComment *comment) {
    if (!comment) return NO;
    NSString *originalBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    if (![originalBody isKindOfClass:[NSString class]] || originalBody.length == 0) return NO;

    NSString *currentBody = comment.body;
    if (![currentBody isEqualToString:originalBody]) {
        ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBody:), originalBody);
    }

    NSString *originalBodyHTML = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyHTMLKey);
    if ([originalBodyHTML isKindOfClass:[NSString class]] && originalBodyHTML.length > 0) {
        ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBodyHTML:), originalBodyHTML);
    } else {
        ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBodyHTML:), ApolloDeletedCommentsPlainBodyHTML(originalBody));
    }
    return YES;
}

static void __attribute__((unused)) ApolloDeletedCommentsSetModelBodyToReasonLabel(RDKComment *comment, NSString *label) {
    if (!comment || label.length == 0) return;
    if (![comment.body isEqualToString:label]) {
        ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBody:), label);
    }
    ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBodyHTML:), ApolloDeletedCommentsPlainBodyHTML(label));
}

static BOOL ApolloDeletedCommentsCommentIsRevealedByFullName(RDKComment *comment) {
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsCommentRevealed(fullName);
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsShouldKeepModelBodyHidden(RDKComment *comment) {
    if (!ApolloDeletedCommentsFeatureActive() || !sTapToRevealDeletedComments || !comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return NO;
    return ApolloDeletedCommentsIsRecoveredComment(fullName) &&
           !ApolloDeletedCommentsIsCommentRevealed(fullName);
}

static void ApolloDeletedCommentsSynchronizeCommentModelDisplayState(id cellNode) {
    if (!cellNode) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL placeholderOnly = ApolloDeletedCommentsIsDeletedPlaceholder(fullName) &&
                           !ApolloDeletedCommentsIsRecoveredComment(fullName);
    BOOL recovered = ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode);

    if (placeholderOnly) {
        return;
    }

    if (recovered) {
        NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
        if (ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody) &&
            !objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey)) {
            objc_setAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey, [resolvedBody copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        if (ApolloDeletedCommentsShouldKeepModelBodyHidden(comment)) {
            NSString *label = ApolloDeletedCommentsReasonLabelForCommentAndBody(comment, resolvedBody ?: comment.body);
            ApolloDeletedCommentsSetModelBodyToReasonLabel(comment, label);
            return;
        }
        ApolloDeletedCommentsRememberOriginalModelBodyIfNeeded(comment);
        ApolloDeletedCommentsRestoreOriginalModelBodyIfNeeded(comment);
    }
}

static NSString *ApolloDeletedCommentsReasonLabelForCommentAndBody(RDKComment *comment, NSString *body) {
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *reason = ApolloDeletedCommentsRecoveredReasonForComment(fullName);
    if (reason.length == 0) reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName);
    NSString *label = ApolloDeletedCommentsDisplayLabelForReason(reason);
    return ApolloDeletedCommentsNormalizedReasonLabel(label);
}

static NSString *__attribute__((unused)) ApolloDeletedCommentsHiddenReasonLabelForCommentBody(RDKComment *comment, NSString *body) {
    if (!ApolloDeletedCommentsFeatureActive() || !comment) return nil;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *savedBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    NSString *bodyForState = [savedBody isKindOfClass:[NSString class]] && savedBody.length > 0 ? savedBody : body;
    BOOL placeholder = ApolloDeletedCommentsIsDeletedPlaceholder(fullName);
    BOOL recovered = ApolloDeletedCommentsIsRecoveredComment(fullName);
    BOOL placeholderOnly = placeholder && !recovered;
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName);

    if (placeholderOnly) {
        return ApolloDeletedCommentsReasonLabelForCommentAndBody(comment, bodyForState);
    }
    if (sTapToRevealDeletedComments && recovered && !revealed) {
        return ApolloDeletedCommentsReasonLabelForCommentAndBody(comment, bodyForState);
    }
    return nil;
}

static id ApolloDeletedCommentsObjectIvarByNames(id object, const char **candidateNames) {
    if (!object || !candidateNames) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; candidateNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, candidateNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type) continue;
            // Skip leading type-encoding qualifier chars before the object marker.
            // Swift class-type ivars on CommentCellNode (e.g. `bodyNode`) are
            // declared `_Atomic`, which clang encodes as `A@"..."` — without
            // skipping the 'A' we'd reject the MarkdownNode and never find it.
            const char *cursor = type;
            while (*cursor && strchr("rnNoORVAj", *cursor)) cursor++;
            if (*cursor != '@') continue;
            id value = nil;
            @try {
                value = object_getIvar(object, ivar);
            } @catch (__unused NSException *e) {
                value = nil;
            }
            if (value) return value;
        }
    }
    return nil;
}

static id ApolloDeletedCommentsKnownBodyContainerNode(id commentCellNode) {
    static const char *candidateNames[] = {
        "bodyNode",
        "markdownNode",
        "commentMarkdownNode",
        "commentBodyNode",
        "bodyMarkdownNode",
        NULL,
    };
    return ApolloDeletedCommentsObjectIvarByNames(commentCellNode, candidateNames);
}

static NSString *ApolloDeletedCommentsNormalizedReasonLabel(NSString *label) {
    if (![label isKindOfClass:[NSString class]] || label.length == 0) return @"REMOVED BY MOD";
    if ([label isEqualToString:@"DELETED BY MOD"]) return @"REMOVED BY MOD";
    return label;
}

static UIImage *ApolloDeletedCommentsReasonChipImage(NSString *text, UIFont *font) {
    text = ApolloDeletedCommentsNormalizedReasonLabel(text);
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (![font isKindOfClass:[UIFont class]]) font = ApolloDeletedCommentsReasonChipFont();

    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: ApolloDeletedCommentsChipTextColor(),
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    CGFloat horizontalPadding = 9.0;
    CGFloat verticalPadding = 2.5;
    CGSize imageSize = CGSizeMake(ceil(textSize.width + horizontalPadding * 2.0),
                                  ceil(textSize.height + verticalPadding * 2.0));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:imageSize format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGRect bounds = CGRectMake(0.0, 0.0, imageSize.width, imageSize.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:floor(imageSize.height / 2.0)];
        [ApolloDeletedCommentsChipBackgroundColor() setFill];
        [path fill];

        CGRect textRect = CGRectMake(horizontalPadding,
                                     floor((imageSize.height - textSize.height) / 2.0),
                                     textSize.width,
                                     textSize.height);
        [text drawInRect:textRect withAttributes:attributes];
    }];
}

static NSAttributedString *ApolloDeletedCommentsReasonChipAttributedText(NSString *label, NSDictionary *baseAttributes, BOOL revealLink) {
    label = ApolloDeletedCommentsNormalizedReasonLabel(label);
    UIFont *font = ApolloDeletedCommentsReasonChipFontForBaseAttributes(baseAttributes);

    // Return the SAME immutable chip string for identical (label, font, revealLink).
    // The chip is rebuilt on every comment-cell measure; without caching, each call
    // renders a fresh UIImage inside a fresh NSTextAttachment, so successive chip
    // strings are never -isEqualToAttributedString: to each other. That kept the body
    // text node perpetually dirty (set text -> re-measure -> rebuild -> set text ...),
    // a continuous re-measure churn that contributed to the #514 freeze. A shared
    // immutable result lets ASTextNode's setAttributedText: short-circuit so the node
    // settles after one measure. Chip colors are constant, so font is the only visual
    // variable besides the label. (Runs on background measure threads — guard the map.)
    static NSMutableDictionary<NSString *, NSAttributedString *> *chipCache = nil;
    static NSObject *chipCacheLock = nil;
    static dispatch_once_t chipCacheOnce;
    dispatch_once(&chipCacheOnce, ^{
        chipCache = [NSMutableDictionary dictionary];
        chipCacheLock = [NSObject new];
    });
    NSString *chipCacheKey = [NSString stringWithFormat:@"%@|%@|%.2f|%d",
                              label ?: @"",
                              [font isKindOfClass:[UIFont class]] ? (font.fontName ?: @"-") : @"-",
                              [font isKindOfClass:[UIFont class]] ? font.pointSize : 0.0,
                              revealLink ? 1 : 0];
    @synchronized (chipCacheLock) {
        NSAttributedString *cached = chipCache[chipCacheKey];
        if ([cached isKindOfClass:[NSAttributedString class]]) return cached;
    }

    UIImage *image = ApolloDeletedCommentsReasonChipImage(label, font);
    CGFloat chipLineHeight = [image isKindOfClass:[UIImage class]] ? image.size.height + 6.0 : font.lineHeight + 6.0;
    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.lineSpacing = 0.0;
    paragraphStyle.paragraphSpacing = 4.0;
    paragraphStyle.minimumLineHeight = ceil(chipLineHeight);
    paragraphStyle.maximumLineHeight = ceil(chipLineHeight);

    NSMutableAttributedString *result = nil;
    if ([image isKindOfClass:[UIImage class]]) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = image;
        attachment.bounds = CGRectMake(0.0, -1.0, image.size.width, image.size.height);
        result = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
        [result addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, result.length)];
    } else {
        result = [[NSMutableAttributedString alloc] initWithString:label attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: ApolloDeletedCommentsChipTextColor(),
            NSParagraphStyleAttributeName: paragraphStyle,
        }];
    }

    if (revealLink) {
        [result addAttribute:ApolloDeletedCommentsRevealAttributeName value:ApolloDeletedCommentsRevealURLString range:NSMakeRange(0, result.length)];
    }
    [result addAttribute:ApolloDeletedCommentsReasonPrefixAttributeName value:@YES range:NSMakeRange(0, result.length)];

    NSAttributedString *immutableChip = [result copy];
    @synchronized (chipCacheLock) {
        chipCache[chipCacheKey] = immutableChip;
    }
    return immutableChip;
}

static id ApolloDeletedCommentsKnownBodyTextNode(id commentCellNode) {
    if (!commentCellNode) return nil;
    static const char *candidateNames[] = {
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
    id node = ApolloDeletedCommentsObjectIvarByNames(commentCellNode, candidateNames);
    if (node && [node respondsToSelector:@selector(attributedText)] && [node respondsToSelector:@selector(setAttributedText:)]) {
        return node;
    }
    return nil;
}

static void ApolloDeletedCommentsRelayoutCellAndTextNode(id cellNode, id textNode) {
    SEL selectors[] = {
        @selector(invalidateCalculatedLayout),
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if ([textNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(textNode, sel); } @catch (__unused NSException *e) {}
        }
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
    ApolloDeletedCommentsScheduleHostLayoutRefresh(cellNode);
}

static void ApolloDeletedCommentsInvalidateCellAndTextNodeLocally(id cellNode, id textNode) {
    SEL selectors[] = {
        @selector(invalidateCalculatedLayout),
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL sel = selectors[i];
        if ([textNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(textNode, sel); } @catch (__unused NSException *e) {}
        }
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
}

static NSAttributedString *ApolloDeletedCommentsPlaceholderAttributedText(NSAttributedString *original, NSString *reasonLabel, id cellNode) {
    NSDictionary *attributes = ApolloDeletedCommentsReasonChipBaseAttributes(original, cellNode);
    NSAttributedString *chip = ApolloDeletedCommentsReasonChipAttributedText(reasonLabel, attributes, YES);
    return chip;
}

static NSMutableDictionary *ApolloDeletedCommentsDefaultBodyAttributes(void) {
    NSDictionary *tmpl = ApolloDeletedCommentsBodyTemplateGet();
    if ([tmpl isKindOfClass:[NSDictionary class]] && tmpl.count > 0) {
        return [tmpl mutableCopy];
    }

    UIColor *textColor = nil;
    if (@available(iOS 13.0, *)) {
        textColor = [UIColor labelColor];
    }
    if (!textColor) textColor = [UIColor blackColor];
    return [@{
        NSFontAttributeName: ApolloDeletedCommentsRecoveredBodyFont(),
        NSForegroundColorAttributeName: textColor,
    } mutableCopy];
}

// Apollo's in-app text size lives in standardUserDefaults (same domain as its
// other appearance settings):
//   UseSystemTextSize (Bool)   — YES: comment fonts follow the SYSTEM Dynamic Type
//                                size; NO: Apollo uses its own in-app slider.
//   ApolloCustomTextSize (Int) — the slider value: an Apollo.ApplicationTextSize
//                                raw value. Its 12 cases map 1:1, in declaration
//                                order, to the UIContentSizeCategory constants.
// Reading these is what lets us match Apollo's comment size exactly in BOTH modes
// without learning, guessing, or hardcoding any point size.
static NSString *const kApolloDeletedCommentsUseSystemTextSizeKey = @"UseSystemTextSize";
static NSString *const kApolloDeletedCommentsCustomTextSizeKey = @"ApolloCustomTextSize";

static NSString *ApolloDeletedCommentsCategoryForApplicationTextSize(NSInteger raw) {
    static NSArray<NSString *> *categories = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        categories = @[
            UIContentSizeCategoryExtraSmall,                        // xSmall
            UIContentSizeCategorySmall,                             // small
            UIContentSizeCategoryMedium,                            // medium
            UIContentSizeCategoryLarge,                             // large
            UIContentSizeCategoryExtraLarge,                        // xLarge
            UIContentSizeCategoryExtraExtraLarge,                   // xxLarge
            UIContentSizeCategoryExtraExtraExtraLarge,              // xxxLarge
            UIContentSizeCategoryAccessibilityMedium,              // accessibilityMedium
            UIContentSizeCategoryAccessibilityLarge,               // accessibilityLarge
            UIContentSizeCategoryAccessibilityExtraLarge,          // accessibilityXLarge
            UIContentSizeCategoryAccessibilityExtraExtraLarge,     // accessibilityXXLarge
            UIContentSizeCategoryAccessibilityExtraExtraExtraLarge,// accessibilityXXXLarge
        ];
    });
    if (raw < 0 || raw >= (NSInteger)categories.count) return nil;
    return categories[(NSUInteger)raw];
}

// The live SYSTEM content size category (used when "Use System Text Size" is on).
static NSString *ApolloDeletedCommentsSystemContentSizeCategory(id node) {
    NSString *category = nil;
    if (node) {
        @try {
            if ([node respondsToSelector:@selector(asyncTraitCollection)]) {
                id traitCollection = ((id (*)(id, SEL))objc_msgSend)(node, @selector(asyncTraitCollection));
                if (traitCollection && [traitCollection respondsToSelector:@selector(preferredContentSizeCategory)]) {
                    id value = ((id (*)(id, SEL))objc_msgSend)(traitCollection, @selector(preferredContentSizeCategory));
                    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) category = value;
                }
            }
        } @catch (__unused NSException *e) {}
    }
    if (![category isKindOfClass:[NSString class]] || category.length == 0) {
        category = UIApplication.sharedApplication.preferredContentSizeCategory;
    }
    if (![category isKindOfClass:[NSString class]] || category.length == 0) {
        category = UIContentSizeCategoryLarge;
    }
    return category;
}

// The EFFECTIVE comment-body content size category, resolved exactly like Apollo:
// follow the system size when "Use System Text Size" is on (or unset), otherwise
// use Apollo's own slider value. outUsedAppSize (optional) reports which branch
// was taken, for logging.
static NSString *ApolloDeletedCommentsEffectiveContentSizeCategory(id node, BOOL *outUsedAppSize) {
    if (outUsedAppSize) *outUsedAppSize = NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id useSystemObj = [defaults objectForKey:kApolloDeletedCommentsUseSystemTextSizeKey];
    BOOL useSystem = (useSystemObj == nil) ? YES : [defaults boolForKey:kApolloDeletedCommentsUseSystemTextSizeKey];
    if (!useSystem) {
        if ([defaults objectForKey:kApolloDeletedCommentsCustomTextSizeKey] != nil) {
            NSString *category = ApolloDeletedCommentsCategoryForApplicationTextSize(
                [defaults integerForKey:kApolloDeletedCommentsCustomTextSizeKey]);
            if ([category isKindOfClass:[NSString class]] && category.length > 0) {
                if (outUsedAppSize) *outUsedAppSize = YES;
                return category;
            }
        }
    }
    return ApolloDeletedCommentsSystemContentSizeCategory(node);
}

// THE app's comment-body font, resolved deterministically from the effective
// content size category above. Apollo's comment body is UIFontTextStyleSubheadline
// scaled by that category (verified: .large=15pt, .xxxLarge=21pt), regular weight.
static UIFont *ApolloDeletedCommentsAppCommentBodyFontForNode(id node) {
    // Prefer Apollo's real captured comment font (always matches normal comments and
    // tracks text-size changes). Fall back to the derived size only before we've seen
    // a normal comment render.
    UIFont *live = ApolloDeletedCommentsLiveBodyFontGet();
    if ([live isKindOfClass:[UIFont class]]) {
        return live;
    }
    NSString *category = ApolloDeletedCommentsEffectiveContentSizeCategory(node, NULL);
    if (![category isKindOfClass:[NSString class]] || category.length == 0) {
        category = UIContentSizeCategoryLarge;
    }
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:category];
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline compatibleWithTraitCollection:traits];
    return [font isKindOfClass:[UIFont class]] ? font : nil;
}

// Body attributes using the deterministic app font (above) for size/weight, while
// keeping Apollo's body text color/paragraph from whatever we last saw (or sane
// defaults). This is the primary source for revealed comment bodies.
static NSDictionary *ApolloDeletedCommentsAppBodyAttributesForNode(id node) {
    UIFont *font = ApolloDeletedCommentsAppCommentBodyFontForNode(node);
    if (![font isKindOfClass:[UIFont class]]) return nil;

    NSDictionary *tmpl = ApolloDeletedCommentsBodyTemplateGet();
    NSDictionary *base = [tmpl isKindOfClass:[NSDictionary class]] && tmpl.count > 0 ? tmpl : nil;
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    UIColor *color = base[NSForegroundColorAttributeName];
    if (![color isKindOfClass:[UIColor class]]) {
        if (@available(iOS 13.0, *)) color = [UIColor labelColor];
        if (![color isKindOfClass:[UIColor class]]) color = [UIColor blackColor];
    }
    attributes[NSForegroundColorAttributeName] = color;
    attributes[NSFontAttributeName] = font;
    return attributes;
}

static NSMutableDictionary *ApolloDeletedCommentsSanitizedBodyAttributes(NSDictionary *attrs) {
    UIFont *font = attrs[NSFontAttributeName];
    if (![font isKindOfClass:[UIFont class]]) return nil;

    NSMutableDictionary *attributes = [attrs mutableCopy];
    [attributes removeObjectForKey:NSAttachmentAttributeName];
    [attributes removeObjectForKey:NSBackgroundColorAttributeName];
    [attributes removeObjectForKey:NSLinkAttributeName];
    [attributes removeObjectForKey:ApolloDeletedCommentsRevealAttributeName];
    [attributes removeObjectForKey:ApolloDeletedCommentsReasonPrefixAttributeName];
    return attributes;
}

static NSMutableDictionary *ApolloDeletedCommentsBodyAttributesFromAttributedText(NSAttributedString *templateText) {
    __block NSMutableDictionary *attributes = nil;
    if ([templateText isKindOfClass:[NSAttributedString class]] && templateText.length > 0) {
        NSString *trimmed = ApolloDeletedCommentsTrimmedString(templateText.string);
        NSString *normalized = ApolloDeletedCommentsNormalizedReasonLabel(trimmed);
        NSString *lowercase = trimmed.lowercaseString;
        if (ApolloDeletedCommentsStringIsReasonLabel(normalized) ||
            [lowercase isEqualToString:@"spoiler"] ||
            ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(trimmed)) {
            return nil;
        }
        [templateText enumerateAttributesInRange:NSMakeRange(0, templateText.length)
                                         options:0
                                      usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
            if (attrs[NSAttachmentAttributeName]) return;
            attributes = ApolloDeletedCommentsSanitizedBodyAttributes(attrs);
            if (!attributes) return;
            *stop = YES;
        }];
    }
    return attributes;
}

static BOOL ApolloDeletedCommentsBodyAttributesNeedRefresh(NSDictionary *attributes) {
    if (![attributes isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *tmpl = ApolloDeletedCommentsBodyTemplateGet();
    if (![tmpl isKindOfClass:[NSDictionary class]] || tmpl.count == 0) {
        return NO;
    }

    UIFont *currentFont = attributes[NSFontAttributeName];
    UIFont *targetFont = tmpl[NSFontAttributeName];
    if (![currentFont isKindOfClass:[UIFont class]] || ![targetFont isKindOfClass:[UIFont class]]) return NO;

    if (fabs(currentFont.pointSize - targetFont.pointSize) > 0.1) return YES;
    if (![currentFont.fontName isEqualToString:targetFont.fontName]) return YES;
    return NO;
}

static NSAttributedString *ApolloDeletedCommentsBodyAttributedText(NSAttributedString *templateText, NSString *body) {
    NSMutableDictionary *attributes = ApolloDeletedCommentsBodyAttributesFromAttributedText(templateText);
    if (ApolloDeletedCommentsBodyAttributesNeedRefresh(attributes)) {
        attributes = nil;
    }
    if (!attributes) {
        attributes = ApolloDeletedCommentsDefaultBodyAttributes();
    }
    return [[NSAttributedString alloc] initWithString:body ?: @"" attributes:attributes];
}

static NSAttributedString *ApolloDeletedCommentsBodyTextByNormalizingFont(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;

    NSMutableAttributedString *normalized = [attributedText mutableCopy];
    NSRange fullRange = NSMakeRange(0, normalized.length);
    NSDictionary *bodyTemplate = ApolloDeletedCommentsBodyTemplateGet();
    NSDictionary *targetAttributes = [bodyTemplate isKindOfClass:[NSDictionary class]] ? bodyTemplate : nil;
    [normalized enumerateAttributesInRange:fullRange
                                   options:0
                                usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, __unused BOOL *stop) {
        if (attrs[NSAttachmentAttributeName]) return;
        [normalized removeAttribute:NSBackgroundColorAttributeName range:range];
        [normalized removeAttribute:NSLinkAttributeName range:range];
        [normalized removeAttribute:ApolloDeletedCommentsRevealAttributeName range:range];
        [normalized removeAttribute:ApolloDeletedCommentsReasonPrefixAttributeName range:range];
        if (targetAttributes.count > 0 && ApolloDeletedCommentsBodyAttributesNeedRefresh(attrs)) {
            for (NSAttributedStringKey key in targetAttributes) {
                [normalized addAttribute:key value:targetAttributes[key] range:range];
            }
        }
    }];
    return normalized;
}

static NSAttributedString *ApolloDeletedCommentsRecoveredBodyTextForDisplay(NSAttributedString *templateText, NSString *body) {
    if ([templateText isKindOfClass:[NSAttributedString class]] &&
        templateText.length > 0 &&
        !ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(templateText) &&
        !ApolloDeletedCommentsAttributedTextHasReasonPrefix(templateText) &&
        ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(templateText.string, body)) {
        return ApolloDeletedCommentsBodyTextByNormalizingFont(templateText);
    }
    return ApolloDeletedCommentsBodyAttributedText(templateText, body);
}

static NSObject *ApolloDeletedCommentsVisibleCellsLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sApolloDeletedCommentsVisibleCellsLock = [NSObject new];
    });
    return sApolloDeletedCommentsVisibleCellsLock;
}

static void ApolloDeletedCommentsTrackVisibleDeletedCommentCell(id cellNode) {
    if (!cellNode) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;
    if (!ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;

    @synchronized (ApolloDeletedCommentsVisibleCellsLock()) {
        if (!sApolloDeletedCommentsVisibleCellsByFullName) {
            sApolloDeletedCommentsVisibleCellsByFullName = [NSMutableDictionary dictionary];
        }
        NSHashTable *cells = sApolloDeletedCommentsVisibleCellsByFullName[fullName];
        if (!cells) {
            cells = [NSHashTable weakObjectsHashTable];
            sApolloDeletedCommentsVisibleCellsByFullName[fullName] = cells;
        }
        [cells addObject:cellNode];
    }
}

static NSArray *ApolloDeletedCommentsTrackedCellsForFullName(NSString *fullName) {
    if (fullName.length == 0) return @[];
    @synchronized (ApolloDeletedCommentsVisibleCellsLock()) {
        NSHashTable *cells = sApolloDeletedCommentsVisibleCellsByFullName[fullName];
        return cells ? cells.allObjects : @[];
    }
}

static NSArray *ApolloDeletedCommentsAllTrackedVisibleCells(void) {
    @synchronized (ApolloDeletedCommentsVisibleCellsLock()) {
        if (sApolloDeletedCommentsVisibleCellsByFullName.count == 0) return @[];
        NSMutableArray *allCells = [NSMutableArray array];
        for (NSHashTable *cells in sApolloDeletedCommentsVisibleCellsByFullName.allValues) {
            for (id cellNode in cells.allObjects) {
                if (cellNode) [allCells addObject:cellNode];
            }
        }
        return [allCells copy];
    }
}

static BOOL ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;

    __block BOOL hasRevealLink = NO;
    [attributedText enumerateAttribute:NSLinkAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSString *urlString = nil;
        if ([value isKindOfClass:[NSURL class]]) {
            urlString = [(NSURL *)value absoluteString];
        } else if ([value isKindOfClass:[NSString class]]) {
            urlString = value;
        }
        if ([urlString isEqualToString:ApolloDeletedCommentsRevealURLString]) {
            hasRevealLink = YES;
            *stop = YES;
        }
    }];
    if (hasRevealLink) return YES;

    [attributedText enumerateAttribute:ApolloDeletedCommentsRevealAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        if ([value isEqual:ApolloDeletedCommentsRevealURLString]) {
            hasRevealLink = YES;
            *stop = YES;
        }
    }];
    return hasRevealLink;
}

static NSString *ApolloDeletedCommentsNormalizeTextForCompare(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@">!"] && [trimmed hasSuffix:@"!<"] && trimmed.length > 4) {
        trimmed = [trimmed substringWithRange:NSMakeRange(2, trimmed.length - 4)];
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *normalizedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        while ([normalizedLine hasPrefix:@">"]) {
            normalizedLine = [[normalizedLine substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        if ([normalizedLine hasPrefix:@"!"] && ![normalizedLine hasPrefix:@"!!"]) {
            normalizedLine = [normalizedLine substringFromIndex:1];
        }
        if ([normalizedLine hasSuffix:@"!<"] && normalizedLine.length > 2) {
            normalizedLine = [normalizedLine substringToIndex:normalizedLine.length - 2];
        }
        [lines addObject:normalizedLine];
    }
    trimmed = [lines componentsJoinedByString:@" "];
    // Compile once. This classifier runs many times per comment cell per layout pass;
    // recompiling \s+ on every call (uregex_open) was a top hotspot in the #514 freeze.
    static NSRegularExpression *whitespaceRegex = nil;
    static dispatch_once_t whitespaceOnce;
    dispatch_once(&whitespaceOnce, ^{
        whitespaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    });
    trimmed = [whitespaceRegex stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@" "];

    NSArray<NSString *> *reasonPrefixes = @[@"removed by mod", @"deleted by user", @"loading...", @"not available"];
    NSString *lowercase = trimmed.lowercaseString;
    for (NSString *prefix in reasonPrefixes) {
        if ([lowercase hasPrefix:prefix]) {
            trimmed = [[trimmed substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        }
    }
    lowercase = trimmed.lowercaseString;
    for (NSString *suffix in reasonPrefixes) {
        if ([lowercase hasSuffix:suffix]) {
            trimmed = [[trimmed substringToIndex:trimmed.length - suffix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            break;
        }
    }
    return trimmed;
}

static NSString *ApolloDeletedCommentsUnwrappedSpoilerMarkdown(NSString *s) {
    NSString *trimmed = ApolloDeletedCommentsTrimmedString(s);
    if ([trimmed hasPrefix:@">!"] && [trimmed hasSuffix:@"!<"] && trimmed.length > 4) {
        return [trimmed substringWithRange:NSMakeRange(2, trimmed.length - 4)];
    }
    return trimmed;
}

static BOOL ApolloDeletedCommentsTextQualifiesAsBodyCandidate(NSString *candidate, NSString *body) {
    NSString *candidateNorm = ApolloDeletedCommentsNormalizeTextForCompare(candidate);
    NSString *bodyNorm = ApolloDeletedCommentsNormalizeTextForCompare(ApolloDeletedCommentsUnwrappedSpoilerMarkdown(body));
    if (candidateNorm.length == 0 || bodyNorm.length == 0) return NO;
    if ([candidateNorm isEqualToString:bodyNorm]) return YES;
    NSUInteger minLen = MIN(candidateNorm.length, bodyNorm.length);
    if (minLen < 24) return NO;
    NSString *candidatePrefix = [candidateNorm substringToIndex:minLen];
    NSString *bodyPrefix = [bodyNorm substringToIndex:minLen];
    return [candidatePrefix isEqualToString:bodyPrefix];
}

static BOOL ApolloDeletedCommentsTextQualifiesAsBodyFragment(NSString *candidate, NSString *body) {
    NSString *candidateNorm = ApolloDeletedCommentsNormalizeTextForCompare(candidate);
    NSString *bodyNorm = ApolloDeletedCommentsNormalizeTextForCompare(ApolloDeletedCommentsUnwrappedSpoilerMarkdown(body));
    if (candidateNorm.length < 12 || bodyNorm.length == 0) return NO;
    if ([candidateNorm isEqualToString:@"spoiler"]) return NO;
    if ([candidateNorm hasPrefix:@"deleted by "]) return NO;
    if ([candidateNorm hasPrefix:@"removed by "]) return NO;
    return [bodyNorm rangeOfString:candidateNorm options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSArray<NSString *> *ApolloDeletedCommentsBodyMatchTokens(NSString *text) {
    NSString *normalized = ApolloDeletedCommentsNormalizeTextForCompare(ApolloDeletedCommentsUnwrappedSpoilerMarkdown(text)).lowercaseString;
    if (normalized.length == 0) return @[];

    // Compile once (see NormalizeTextForCompare above) — this tokenizer regex was the
    // other per-call uregex_open hotspot in the #514 freeze.
    static NSRegularExpression *regex = nil;
    static dispatch_once_t tokenOnce;
    dispatch_once(&tokenOnce, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"[^a-z0-9]+"
                                                          options:0
                                                            error:nil];
    });
    NSString *tokenText = [regex stringByReplacingMatchesInString:normalized
                                                          options:0
                                                            range:NSMakeRange(0, normalized.length)
                                                     withTemplate:@" "];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in [tokenText componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (part.length < 4) continue;
        [tokens addObject:part];
    }
    return tokens;
}

static BOOL ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(NSString *candidate, NSString *body) {
    NSString *candidateNorm = ApolloDeletedCommentsNormalizeTextForCompare(candidate);
    NSString *bodyNorm = ApolloDeletedCommentsNormalizeTextForCompare(ApolloDeletedCommentsUnwrappedSpoilerMarkdown(body));
    if (candidateNorm.length == 0 || bodyNorm.length == 0) return NO;

    NSString *candidateLower = candidateNorm.lowercaseString;
    if ([candidateLower isEqualToString:@"spoiler"] ||
        [candidateLower hasPrefix:@"deleted by "] ||
        [candidateLower hasPrefix:@"removed by "] ||
        ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(candidateNorm)) {
        return NO;
    }

    if (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(candidateNorm, bodyNorm) ||
        ApolloDeletedCommentsTextQualifiesAsBodyFragment(candidateNorm, bodyNorm)) {
        return YES;
    }

    if (candidateNorm.length >= 16 &&
        [bodyNorm rangeOfString:candidateNorm options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    if (bodyNorm.length >= 16 &&
        [candidateNorm rangeOfString:bodyNorm options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    NSArray<NSString *> *candidateTokens = ApolloDeletedCommentsBodyMatchTokens(candidateNorm);
    NSArray<NSString *> *bodyTokens = ApolloDeletedCommentsBodyMatchTokens(bodyNorm);
    if (candidateTokens.count < 3 || bodyTokens.count == 0) return NO;

    NSSet<NSString *> *bodyTokenSet = [NSSet setWithArray:bodyTokens];
    NSUInteger matches = 0;
    for (NSString *token in candidateTokens) {
        if ([bodyTokenSet containsObject:token]) matches++;
    }

    NSUInteger requiredMatches = MAX((NSUInteger)3, (candidateTokens.count + 1) / 2);
    return matches >= requiredMatches;
}

static BOOL ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(NSString *candidate) {
    NSString *candidateNorm = ApolloDeletedCommentsNormalizeTextForCompare(candidate).lowercaseString;
    if (candidateNorm.length == 0) return NO;
    return [candidateNorm isEqualToString:@"[deleted]"] ||
           [candidateNorm isEqualToString:@"[removed]"] ||
           [candidateNorm isEqualToString:@"deleted"] ||
           [candidateNorm isEqualToString:@"removed"] ||
           [candidateNorm isEqualToString:@"spoiler"] ||
           [candidateNorm isEqualToString:@"..."] ||
           [candidateNorm isEqualToString:@"…"];
}

static void ApolloDeletedCommentsCollectAttributedTextNodes(id object, NSInteger depth, NSHashTable *visited, NSMutableArray *nodes) {
    if (!object || depth < 0 || [visited containsObject:object]) return;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] && [object respondsToSelector:@selector(setAttributedText:)]) {
            NSAttributedString *text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
            if ([text isKindOfClass:[NSAttributedString class]] && text.length > 0) {
                [nodes addObject:object];
            }
        }

        if ([object respondsToSelector:@selector(subnodes)]) {
            NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(object, @selector(subnodes));
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloDeletedCommentsCollectAttributedTextNodes(subnode, depth - 1, visited, nodes);
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloDeletedCommentsCollectWritableTextNodes(id object, NSInteger depth, NSHashTable *visited, NSMutableArray *nodes) {
    if (!object || depth < 0 || [visited containsObject:object]) return;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] && [object respondsToSelector:@selector(setAttributedText:)]) {
            [nodes addObject:object];
        }

        if ([object respondsToSelector:@selector(subnodes)]) {
            NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(object, @selector(subnodes));
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloDeletedCommentsCollectWritableTextNodes(subnode, depth - 1, visited, nodes);
            }
        }
    } @catch (__unused NSException *e) {}
}

static id ApolloDeletedCommentsFallbackBodyTextNode(id cellNode) {
    id known = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
    if (known) return known;

    id bodyContainer = ApolloDeletedCommentsKnownBodyContainerNode(cellNode);
    if (!bodyContainer) return nil;

    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:32];
    ApolloDeletedCommentsCollectWritableTextNodes(bodyContainer, 5, visited, candidates);
    return candidates.firstObject;
}

static id ApolloDeletedCommentsBestBodyTextNode(id cellNode, RDKComment *comment) {
    NSString *body = comment.body;
    id known = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
    if (known) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(known, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(text.string, body)) return known;
    }

    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloDeletedCommentsCollectAttributedTextNodes(cellNode, 6, visited, candidates);

    id bestNode = nil;
    NSUInteger bestLength = 0;
    for (id candidate in candidates) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(candidate, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (!ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(text.string, body)) continue;
        if (text.length > bestLength) {
            bestLength = text.length;
            bestNode = candidate;
        }
    }
    return bestNode;
}

static BOOL ApolloDeletedCommentsAttributedTextHasReasonPrefix(NSAttributedString *attributedText);

static NSArray *ApolloDeletedCommentsBodyTextNodes(id cellNode, RDKComment *comment) {
    if (!cellNode || !comment) return @[];
    NSString *body = comment.body;
    BOOL deletedPlaceholder = ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode);
    NSMutableArray *bodyNodes = [NSMutableArray array];
    NSHashTable *seen = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];

    id known = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
    if (known) {
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(known, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if ((deletedPlaceholder && ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(text.string)) ||
            ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(text.string, body)) {
            [bodyNodes addObject:known];
            [seen addObject:known];
        }
    }

    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloDeletedCommentsCollectAttributedTextNodes(cellNode, 6, visited, candidates);
    for (id candidate in candidates) {
        if ([seen containsObject:candidate]) continue;
        NSAttributedString *text = nil;
        @try {
            text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(candidate, @selector(attributedText));
        } @catch (__unused NSException *e) {
            text = nil;
        }
        if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(text)) {
            continue;
        }
        if (deletedPlaceholder && ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(text.string)) {
            [bodyNodes addObject:candidate];
            [seen addObject:candidate];
            continue;
        }
        if (!ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(text.string, body)) {
            continue;
        }
        [bodyNodes addObject:candidate];
        [seen addObject:candidate];
    }
    return bodyNodes;
}

static NSMutableDictionary *ApolloDeletedCommentsReasonChipBaseAttributes(NSAttributedString *templateText, id cellNode) {
    (void)cellNode;

    NSMutableDictionary *attributes = ApolloDeletedCommentsBodyAttributesFromAttributedText(templateText);
    if (ApolloDeletedCommentsBodyAttributesAreUsable(attributes)) {
        return attributes;
    }

    return ApolloDeletedCommentsDefaultBodyAttributes();
}

static BOOL ApolloDeletedCommentsAttributedTextHasReasonPrefix(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;
    __block BOOL hasPrefix = NO;
    [attributedText enumerateAttribute:ApolloDeletedCommentsReasonPrefixAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, BOOL *stop) {
        if ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) {
            hasPrefix = YES;
            *stop = YES;
        }
    }];
    return hasPrefix;
}

static BOOL ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return NO;

    __block BOOL hasChip = NO;
    [attributedText enumerateAttributesInRange:NSMakeRange(0, attributedText.length)
                                       options:0
                                    usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
        id prefix = attrs[ApolloDeletedCommentsReasonPrefixAttributeName];
        NSTextAttachment *attachment = [attrs[NSAttachmentAttributeName] isKindOfClass:[NSTextAttachment class]] ? attrs[NSAttachmentAttributeName] : nil;
        if ([prefix respondsToSelector:@selector(boolValue)] && [prefix boolValue] && [attachment.image isKindOfClass:[UIImage class]]) {
            hasChip = YES;
            *stop = YES;
        }
    }];
    return hasChip;
}

static NSAttributedString *ApolloDeletedCommentsAttributedTextByRemovingReasonPrefix(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    if (!ApolloDeletedCommentsAttributedTextHasReasonPrefix(attributedText)) return attributedText;

    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    [attributedText enumerateAttribute:ApolloDeletedCommentsReasonPrefixAttributeName
                               inRange:NSMakeRange(0, attributedText.length)
                               options:0
                            usingBlock:^(id value, NSRange range, __unused BOOL *stop) {
        if ([value respondsToSelector:@selector(boolValue)] && [value boolValue] && range.length > 0) {
            [ranges addObject:[NSValue valueWithRange:range]];
        }
    }];
    if (ranges.count == 0) return attributedText;

    NSMutableAttributedString *stripped = [attributedText mutableCopy];
    for (NSValue *value in [ranges reverseObjectEnumerator]) {
        NSRange range = value.rangeValue;
        if (range.location >= stripped.length) continue;
        range.length = MIN(range.length, stripped.length - range.location);

        if (range.location > 0) {
            unichar previous = [stripped.string characterAtIndex:range.location - 1];
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:previous]) {
                range.location -= 1;
                range.length += 1;
            }
        }
        if (NSMaxRange(range) < stripped.length) {
            unichar next = [stripped.string characterAtIndex:NSMaxRange(range)];
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:next]) {
                range.length += 1;
            }
        }
        [stripped deleteCharactersInRange:range];
    }

    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (stripped.length > 0 && [trimSet characterIsMember:[stripped.string characterAtIndex:stripped.length - 1]]) {
        [stripped deleteCharactersInRange:NSMakeRange(stripped.length - 1, 1)];
    }
    while (stripped.length > 0 && [trimSet characterIsMember:[stripped.string characterAtIndex:0]]) {
        [stripped deleteCharactersInRange:NSMakeRange(0, 1)];
    }
    return stripped;
}

static NSAttributedString *ApolloDeletedCommentsAttributedTextByRemovingTrailingReasonLabel(NSAttributedString *attributedText, NSString *label) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    NSString *normalizedLabel = ApolloDeletedCommentsNormalizedReasonLabel(label);
    NSString *string = attributedText.string;
    if (normalizedLabel.length == 0 || string.length == 0) return attributedText;

    NSUInteger trimmedEnd = string.length;
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (trimmedEnd > 0 && [trimSet characterIsMember:[string characterAtIndex:trimmedEnd - 1]]) {
        trimmedEnd--;
    }
    if (trimmedEnd == 0) return attributedText;

    NSRange searchRange = NSMakeRange(0, trimmedEnd);
    NSRange labelRange = [string rangeOfString:normalizedLabel
                                       options:NSBackwardsSearch | NSCaseInsensitiveSearch
                                         range:searchRange];
    if (labelRange.location == NSNotFound || NSMaxRange(labelRange) != trimmedEnd) return attributedText;

    NSUInteger deleteStart = labelRange.location;
    while (deleteStart > 0 && [trimSet characterIsMember:[string characterAtIndex:deleteStart - 1]]) {
        deleteStart--;
    }
    NSMutableAttributedString *stripped = [attributedText mutableCopy];
    [stripped deleteCharactersInRange:NSMakeRange(deleteStart, trimmedEnd - deleteStart)];

    while (stripped.length > 0 && [trimSet characterIsMember:[stripped.string characterAtIndex:stripped.length - 1]]) {
        [stripped deleteCharactersInRange:NSMakeRange(stripped.length - 1, 1)];
    }
    return stripped;
}

static void ApolloDeletedCommentsRememberHiddenTextNode(id cellNode, id textNode) {
    if (!cellNode || !textNode) return;
    NSMutableArray *nodes = nil;
    id existing = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey);
    if ([existing isKindOfClass:[NSArray class]]) {
        nodes = [existing mutableCopy];
    } else {
        nodes = [NSMutableArray array];
    }
    for (id node in nodes) {
        if (node == textNode) return;
    }
    [nodes addObject:textNode];
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, [nodes copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey)) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsPrepareTextNodeForRevealChip(id cellNode, id textNode, RDKComment *comment, NSAttributedString *templateText) {
    if (!cellNode || !textNode || !comment) return NO;
    NSAttributedString *existingOriginal = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if ([existingOriginal isKindOfClass:[NSAttributedString class]] && existingOriginal.length > 0) {
        ApolloDeletedCommentsRememberHiddenTextNode(cellNode, textNode);
        return YES;
    }

    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    if (!ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody)) return NO;

    NSAttributedString *sourceText = [templateText isKindOfClass:[NSAttributedString class]] && templateText.length > 0
        ? templateText
        : ApolloDeletedCommentsCurrentAttributedText(textNode);
    NSAttributedString *original = ApolloDeletedCommentsBodyAttributedText(sourceText, resolvedBody);
    if (![original isKindOfClass:[NSAttributedString class]] || original.length == 0) return NO;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloDeletedCommentsRememberHiddenTextNode(cellNode, textNode);
    return YES;
}

static BOOL ApolloDeletedCommentsCellAlreadyHasHiddenPlaceholder(id cellNode, NSString *fullName) {
    if (!cellNode || fullName.length == 0) return NO;
    for (id textNode in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        NSString *hiddenFullName = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey);
        NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
        if ([hiddenFullName isEqualToString:fullName] && [original isKindOfClass:[NSAttributedString class]]) {
            return YES;
        }
    }
    return NO;
}

static NSAttributedString *__attribute__((unused)) ApolloDeletedCommentsAttributedTextWithTapToRevealPlaceholder(id textNode, NSAttributedString *attributedText) {
    if (!ApolloDeletedCommentsFeatureActive() || !sTapToRevealDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(attributedText)) return attributedText;

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode)) return attributedText;
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    if (!ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody)) return attributedText;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName);
    if (revealed) return attributedText;

    BOOL bodyCandidate = ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(attributedText.string, resolvedBody);
    if (!bodyCandidate) return attributedText;

    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        NSAttributedString *original = [attributedText copy];
        if (ApolloDeletedCommentsStringIsReasonLabel(ApolloDeletedCommentsTrimmedString(attributedText.string)) ||
            ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(attributedText.string)) {
            original = ApolloDeletedCommentsBodyAttributedText(attributedText, resolvedBody);
        }
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloDeletedCommentsRememberHiddenTextNode(cellNode, textNode);
    }

    NSDictionary *attributes = [attributedText attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    if (ApolloDeletedCommentsCellAlreadyHasHiddenPlaceholder(cellNode, fullName) &&
        objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) != textNode) {
        return [[NSAttributedString alloc] initWithString:@"" attributes:attributes];
    }

    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSAttributedString *chipSourceText = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![chipSourceText isKindOfClass:[NSAttributedString class]] || chipSourceText.length == 0) {
        chipSourceText = attributedText;
    }
    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(chipSourceText, ApolloDeletedCommentsReasonLabelForComment(comment), cellNode);
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    return placeholder;
}

static NSAttributedString *ApolloDeletedCommentsAttributedTextWithReasonPrefix(id textNode, NSAttributedString *attributedText) {
    if (!ApolloDeletedCommentsFeatureActive()) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(attributedText)) {
        return attributedText;
    }
    if (ApolloDeletedCommentsAttributedTextHasReasonPrefix(attributedText)) {
        if (ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(attributedText)) return attributedText;
        attributedText = ApolloDeletedCommentsAttributedTextByRemovingReasonPrefix(attributedText);
        if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    }

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return attributedText;
    BOOL revealed = ApolloDeletedCommentsCommentIsRevealedByFullName(comment);
    if (sTapToRevealDeletedComments && !revealed) return attributedText;
    id bodyTextNode = ApolloDeletedCommentsBestBodyTextNode(cellNode, comment);
    if (bodyTextNode && bodyTextNode != textNode) return attributedText;
    NSString *label = ApolloDeletedCommentsReasonLabelForComment(comment);
    NSString *originalBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    NSString *bodyForCompare = [originalBody isKindOfClass:[NSString class]] && originalBody.length > 0 ? originalBody : (resolvedBody ?: comment.body);
    NSAttributedString *bodySourceText = ApolloDeletedCommentsAttributedTextByRemovingTrailingReasonLabel(attributedText, label);
    BOOL bodyCandidate = ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(bodySourceText.string, bodyForCompare);
    if (!bodyCandidate) return attributedText;

    NSAttributedString *bodyText = bodySourceText;
    NSDictionary *baseAttributes = ApolloDeletedCommentsReasonChipBaseAttributes(bodyText, cellNode);
    NSMutableDictionary *spacerAttributes = [baseAttributes mutableCopy];
    NSMutableParagraphStyle *spacerStyle = [NSMutableParagraphStyle new];
    spacerStyle.minimumLineHeight = 20.0;
    spacerStyle.maximumLineHeight = 20.0;
    spacerAttributes[NSParagraphStyleAttributeName] = spacerStyle;
    NSMutableAttributedString *decorated = [bodyText mutableCopy];
    [decorated appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:spacerAttributes]];
    [decorated appendAttributedString:ApolloDeletedCommentsReasonChipAttributedText(label, baseAttributes, NO)];
    ApolloDeletedCommentsDisableRevealTapInterception(textNode);
    return decorated;
}

static NSAttributedString *__attribute__((unused)) ApolloDeletedCommentsAttributedTextWithReasonChipIfNeeded(id textNode, NSAttributedString *attributedText) {
    if (!ApolloDeletedCommentsFeatureActive()) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    if (ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(attributedText)) return attributedText;

    // A node that trims to empty has no text to classify, so it can never be a
    // deleted-comment reason label. Bail before normalizing: this hook fires for
    // EVERY ASTextNode in the app, and NormalizedReasonLabel() defaults an empty
    // string to "REMOVED BY MOD". Without this guard, unrelated blank placeholder
    // labels get stamped with the chip — e.g. the subreddit sidebar's VISITORS /
    // CONTRIBUTIONS stat values, which are momentarily blank while their counts
    // load and briefly flashed "REMOVED BY MOD" before the real numbers arrived.
    NSString *trimmedSource = ApolloDeletedCommentsTrimmedString(attributedText.string);
    if (trimmedSource.length == 0) return attributedText;

    NSString *text = ApolloDeletedCommentsNormalizedReasonLabel(trimmedSource);
    BOOL exactReasonLabel = ApolloDeletedCommentsStringIsReasonLabel(text);
    if (!exactReasonLabel) return attributedText;

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    // Only a node that belongs to a comment cell whose comment is ACTUALLY
    // recovered/removed/deleted may receive a chip. A node that merely reads a
    // reason-label string — or normalizes to one because it is blank — with no
    // removed comment behind it (feed-post bylines, empty author-flair slots on
    // flair-enabled subreddits, transient UI labels) is NOT a deleted comment and
    // must be left untouched. This mirrors the sibling reason-prefix injector, which
    // bails on the identical condition. Previously this branch STAMPED a chip, which
    // is what made every non-removed post and comment on subs like r/personalfinance
    // show "REMOVED BY MOD" in the byline (#522).
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) {
        return attributedText;
    }

    NSString *label = ApolloDeletedCommentsReasonLabelForComment(comment);
    if (![text isEqualToString:label]) return attributedText;

    NSDictionary *baseAttributes = ApolloDeletedCommentsReasonChipBaseAttributes(attributedText, cellNode);
    BOOL revealLink = sTapToRevealDeletedComments && ApolloDeletedCommentsShouldKeepModelBodyHidden(comment);
    NSAttributedString *chip = ApolloDeletedCommentsReasonChipAttributedText(label,
                                                                             baseAttributes,
                                                                             revealLink);
    if (revealLink) ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    return chip;
}

static void ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(id cellNode, id textNode) {
    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![original isKindOfClass:[NSAttributedString class]]) return;

    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        current = nil;
    }
    if (![current isKindOfClass:[NSAttributedString class]] ||
        ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) {
        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), original);
        } @catch (__unused NSException *e) {}
    }
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) == textNode) {
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ApolloDeletedCommentsDisableRevealTapInterception(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
}

static NSArray *ApolloDeletedCommentsHiddenTextNodesForCell(id cellNode) {
    id nodes = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey);
    if ([nodes isKindOfClass:[NSArray class]]) return nodes;

    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    return textNode ? @[textNode] : @[];
}

static void ApolloDeletedCommentsRestoreHiddenBodiesIfNeeded(id cellNode, NSArray *textNodes) {
    NSMutableArray *nodesToRestore = [NSMutableArray array];
    NSHashTable *seen = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];

    for (id node in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        if (!node || [seen containsObject:node]) continue;
        [nodesToRestore addObject:node];
        [seen addObject:node];
    }
    for (id node in textNodes ?: @[]) {
        if (!node || [seen containsObject:node]) continue;
        [nodesToRestore addObject:node];
        [seen addObject:node];
    }

    for (id node in nodesToRestore) {
        ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, node);
    }
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloDeletedCommentsRefreshHiddenPlaceholderForCell(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return NO;

    BOOL placedPlaceholder = NO;
    for (id textNode in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
        if (![original isKindOfClass:[NSAttributedString class]]) continue;

        NSAttributedString *replacement = nil;
        if (!placedPlaceholder) {
            replacement = ApolloDeletedCommentsPlaceholderAttributedText(original, ApolloDeletedCommentsReasonLabelForComment(comment), cellNode);
            placedPlaceholder = YES;
        } else {
            NSDictionary *attributes = original.length > 0 ? ([original attributesAtIndex:0 effectiveRange:NULL] ?: @{}) : @{};
            replacement = [[NSAttributedString alloc] initWithString:@"" attributes:attributes];
        }

        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), replacement);
        } @catch (__unused NSException *e) {}
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
    }

    id firstHiddenNode = ApolloDeletedCommentsHiddenTextNodesForCell(cellNode).firstObject;
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(firstHiddenNode);
    return placedPlaceholder;
}

static BOOL ApolloDeletedCommentsInstallTapToRevealPlaceholderOnTextNode(id cellNode, id textNode, RDKComment *comment, NSString *fullName) {
    if (!cellNode || !textNode || !comment || fullName.length == 0) return NO;
    if (![textNode respondsToSelector:@selector(setAttributedText:)]) return NO;
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    if (!ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody)) return NO;

    NSAttributedString *current = ApolloDeletedCommentsCurrentAttributedText(textNode);
    NSAttributedString *original = nil;
    if ([current isKindOfClass:[NSAttributedString class]] &&
        current.length > 0 &&
        !ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current) &&
        !ApolloDeletedCommentsAttributedTextHasReasonPrefix(current) &&
        ApolloDeletedCommentsTextLooksLikeRecoveredBodyDisplay(current.string, resolvedBody)) {
        original = [current copy];
    } else {
        original = ApolloDeletedCommentsBodyAttributedText(current, resolvedBody);
    }
    if (![original isKindOfClass:[NSAttributedString class]] || original.length == 0) return NO;

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, @[textNode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(original, ApolloDeletedCommentsReasonLabelForComment(comment), cellNode);
    ApolloDeletedCommentsSetTextNodeAttributedText(textNode, placeholder);
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
    return YES;
}

static void ApolloDeletedCommentsApplyStaticPlaceholderChip(id cellNode, NSArray *textNodes) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || textNodes.count == 0) return;

    BOOL placedPlaceholder = NO;
    for (id textNode in textNodes) {
        NSAttributedString *current = nil;
        @try {
            current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
        } @catch (__unused NSException *e) {
            current = nil;
        }
        if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) continue;

        NSAttributedString *replacement = nil;
        if (!placedPlaceholder) {
            replacement = ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment),
                                                                        ApolloDeletedCommentsReasonChipBaseAttributes(current, cellNode),
                                                                        NO);
            placedPlaceholder = YES;
        } else {
            replacement = [[NSAttributedString alloc] initWithString:@""
                                                          attributes:[current attributesAtIndex:0 effectiveRange:NULL] ?: @{}];
        }

        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), replacement);
        } @catch (__unused NSException *e) {}
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
    }

    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// "Tap to show" is a single tap on a recovered-but-hidden comment that's
// currently expanded (its chip is on screen), kept completely separate from
// Apollo's collapse/expand:
//
//   * Tap an expanded hidden comment -> reveal the body.
//   * A collapsed comment expands natively (so uncollapsing never reveals), and a
//     revealed/non-deleted comment collapses/expands natively. Apollo's own
//     programmatic/auto collapses never reveal because they aren't taps.
//
// We attach one tap recognizer to the comment cell's view (the only reliably
// hit-testable view — the chip's own node is frequently rasterized with no usable
// backing view, which is why earlier per-node-gesture and body-rectangle attempts
// silently swallowed taps). Its delegate only lets it fire when a tap should
// reveal (see ApolloDeletedCommentsTapShouldReveal); when it fires it reveals
// synchronously and, via cancelsTouchesInView, swallows that tap so it can't also
// collapse the row.
//
// The chip itself is made non-interactive (the reveal attribute stays only as a
// marker for AttributedTextIsRevealPlaceholder, never added to linkAttributeNames)
// so it can't swallow the touch as an ASTextNode link before the cell sees it.

// True when a tap on this comment should reveal its recovered body instead of
// collapsing: tap-to-reveal is on, the body is recoverable, and it isn't revealed
// yet. (Whether it is currently collapsed is handled by the caller.)
static BOOL ApolloDeletedCommentsCommentArmedForReveal(RDKComment *comment) {
    if (!ApolloDeletedCommentsFeatureActive() || !sTapToRevealDeletedComments || !comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return NO;
    return ApolloDeletedCommentsIsRecoveredComment(fullName) &&
           !ApolloDeletedCommentsIsCommentRevealed(fullName);
}

// Make a reveal-chip node non-interactive so taps fall through to the cell and
// drive Apollo's normal collapse handler (which we redirect into a reveal).
static void ApolloDeletedCommentsEnsureRevealAttributeIsTappable(id textNode) {
    if (!textNode) return;

    if ([textNode respondsToSelector:@selector(setUserInteractionEnabled:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(textNode, @selector(setUserInteractionEnabled:), NO);
        } @catch (__unused NSException *e) {}
    }

    if ([textNode respondsToSelector:@selector(view)]) {
        @try {
            UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
            if ([view isKindOfClass:[UIView class]]) view.userInteractionEnabled = NO;
        } @catch (__unused NSException *e) {}
    }
}

static void ApolloDeletedCommentsDisableRevealTapInterception(id textNode) {
    if (!textNode) return;

    if ([textNode respondsToSelector:@selector(setUserInteractionEnabled:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(textNode, @selector(setUserInteractionEnabled:), NO);
        } @catch (__unused NSException *e) {}
    }

    if ([textNode respondsToSelector:@selector(view)]) {
        @try {
            UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
            if ([view isKindOfClass:[UIView class]]) view.userInteractionEnabled = NO;
        } @catch (__unused NSException *e) {}
    }
}

// A tap should reveal only when the comment is armed (recovered + hidden) AND
// currently expanded — i.e. its chip is on screen. A collapsed comment must be
// left to expand natively, so uncollapsing never reveals. We deliberately do NOT
// gate on a body-rectangle: the chip node is frequently rasterized with no usable
// frame, and that geometry test was unreliable enough to swallow real taps. The
// only taps we'd "over-claim" are header taps on an expanded hidden comment
// (whose author is usually "[deleted]" anyway), which is an acceptable trade for
// a chip tap that reliably reveals.
static BOOL ApolloDeletedCommentsTapShouldReveal(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!ApolloDeletedCommentsCommentArmedForReveal(comment)) return NO;
    return !ApolloDeletedCommentsCommentIsCollapsed(comment);
}

@interface ApolloDeletedCommentsRevealTapHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) id cellNode;
@end

@implementation ApolloDeletedCommentsRevealTapHandler
- (void)apolloRevealTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    id cellNode = self.cellNode;
    if (!ApolloDeletedCommentsTapShouldReveal(cellNode)) return;
    ApolloDeletedCommentsRevealCommentInsteadOfCollapsing(ApolloDeletedCommentsCommentFromCellNode(cellNode));
}

// Only claim (and swallow) the tap when it should reveal. For a collapsed comment,
// a revealed comment, or a non-deleted comment this returns NO, so collapse,
// expand, links and buttons all behave exactly as Apollo intends.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return ApolloDeletedCommentsTapShouldReveal(self.cellNode);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

// Apollo's tap-to-collapse is a Swift single-tap gesture that does NOT go through
// -[RDKComment setCollapsed:] (it drives CollapsedCommentsTracker directly), so
// suppressing setCollapsed: never stopped the visible collapse. Instead, force
// that collapse gesture to wait for — and be cancelled by — our reveal: when the
// comment is armed, our reveal recognizes and Apollo's single-tap collapse is
// required to fail, so a chip tap reveals without ever collapsing.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if (![otherGestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]) return NO;
    if (((UITapGestureRecognizer *)otherGestureRecognizer).numberOfTapsRequired > 1) return NO;
    return ApolloDeletedCommentsTapShouldReveal(self.cellNode);
}
@end

// One persistent recognizer per cell view. The delegate gates it per-tap, so it
// is safe across cell reuse (the comment is resolved live from the cell node).
static void ApolloDeletedCommentsInstallRevealTapGestureOnCell(id cellNode) {
    if (!cellNode || ![cellNode respondsToSelector:@selector(view)]) return;
    UIView *view = nil;
    @try {
        view = ((UIView *(*)(id, SEL))objc_msgSend)(cellNode, @selector(view));
    } @catch (__unused NSException *e) {
        return;
    }
    if (![view isKindOfClass:[UIView class]]) return;

    UITapGestureRecognizer *existing = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsRevealTapGestureKey);
    if ([existing isKindOfClass:[UITapGestureRecognizer class]]) {
        if (existing.view == view) return;
        @try { [existing.view removeGestureRecognizer:existing]; } @catch (__unused NSException *e) {}
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsRevealTapGestureKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    ApolloDeletedCommentsRevealTapHandler *handler = [ApolloDeletedCommentsRevealTapHandler new];
    handler.cellNode = cellNode;

    UITapGestureRecognizer *gesture = [[UITapGestureRecognizer alloc] initWithTarget:handler
                                                                              action:@selector(apolloRevealTap:)];
    gesture.delegate = handler;
    gesture.cancelsTouchesInView = YES;   // a reveal tap must not also collapse the row
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    // UIGestureRecognizer doesn't retain its target; keep the handler alive.
    objc_setAssociatedObject(gesture, kApolloDeletedCommentsRevealTapGestureKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try { [view addGestureRecognizer:gesture]; } @catch (__unused NSException *e) { return; }
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsRevealTapGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void __attribute__((unused)) ApolloDeletedCommentsApplyTapToRevealIfNeeded(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *body = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment) ?: comment.body;

    BOOL placeholderOnly = ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode) &&
                           !ApolloDeletedCommentsCellNodeIsRecovered(cellNode);
    NSArray *textNodes = ApolloDeletedCommentsBodyTextNodes(cellNode, comment);
    if (textNodes.count == 0) {
        id knownBodyNode = ApolloDeletedCommentsFallbackBodyTextNode(cellNode);
        if (knownBodyNode) textNodes = @[knownBodyNode];
    }
    if (textNodes.count == 0) return;

    if (placeholderOnly) {
        ApolloDeletedCommentsApplyStaticPlaceholderChip(cellNode, textNodes);
        return;
    }

    BOOL recovered = ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName);
    BOOL shouldHide = ApolloDeletedCommentsFeatureActive() &&
                      sTapToRevealDeletedComments &&
                      recovered &&
                      !revealed;
    if (!shouldHide) {
        if (recovered) {
            for (id textNode in textNodes) {
                NSAttributedString *current = ApolloDeletedCommentsCurrentAttributedText(textNode);
                if ([current isKindOfClass:[NSAttributedString class]] && current.length > 0) continue;
                NSAttributedString *bodyText = ApolloDeletedCommentsBodyAttributedText(current, body);
                if (bodyText.length == 0) continue;
                ApolloDeletedCommentsSetTextNodeAttributedText(textNode, bodyText);
                ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
                break;
            }
        }
        ApolloDeletedCommentsRestoreHiddenBodiesIfNeeded(cellNode, textNodes);
        for (id textNode in textNodes) {
            ApolloDeletedCommentsDisableRevealTapInterception(textNode);
        }
        return;
    }

    BOOL alreadyHiddenForComment = NO;
    for (id textNode in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        NSString *hiddenFullName = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey);
        NSAttributedString *existingOriginal = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
        if ([hiddenFullName isEqualToString:fullName] &&
            [existingOriginal isKindOfClass:[NSAttributedString class]] &&
            ApolloDeletedCommentsBodyIsDisplayableRecoveredText(existingOriginal.string)) {
            alreadyHiddenForComment = YES;
            break;
        }
    }
    if (alreadyHiddenForComment) {
        BOOL refreshed = ApolloDeletedCommentsRefreshHiddenPlaceholderForCell(cellNode);
        id knownBodyNode = ApolloDeletedCommentsFallbackBodyTextNode(cellNode);
        id activeHiddenNode = ApolloDeletedCommentsHiddenTextNodesForCell(cellNode).firstObject;
        if (refreshed && (!knownBodyNode || knownBodyNode == activeHiddenNode)) {
            return;
        }
        ApolloDeletedCommentsRestoreHiddenBodiesIfNeeded(cellNode, nil);
    }

    ApolloDeletedCommentsRestoreHiddenBodiesIfNeeded(cellNode, nil);

    NSMutableArray *hiddenNodes = [NSMutableArray array];
    BOOL placedPlaceholder = NO;
    for (id textNode in textNodes) {
        NSAttributedString *current = nil;
        @try {
            current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
        } @catch (__unused NSException *e) {
            current = nil;
        }
        if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) continue;
        if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) continue;

        NSAttributedString *hiddenOriginal = current;
        if (ApolloDeletedCommentsStringIsReasonLabel(ApolloDeletedCommentsTrimmedString(current.string)) ||
            ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(current.string)) {
            hiddenOriginal = ApolloDeletedCommentsBodyAttributedText(current, body);
        }
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [hiddenOriginal copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [hiddenNodes addObject:textNode];

        NSAttributedString *replacement = nil;
        if (!placedPlaceholder) {
            replacement = ApolloDeletedCommentsPlaceholderAttributedText(hiddenOriginal, ApolloDeletedCommentsReasonLabelForComment(comment), cellNode);
            placedPlaceholder = YES;
        } else {
            NSDictionary *attributes = [current attributesAtIndex:0 effectiveRange:NULL] ?: @{};
            replacement = [[NSAttributedString alloc] initWithString:@"" attributes:attributes];
        }

        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), replacement);
        } @catch (__unused NSException *e) {}
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
    }

    if (hiddenNodes.count == 0) {
        id knownBodyNode = ApolloDeletedCommentsFallbackBodyTextNode(cellNode);
        if (ApolloDeletedCommentsInstallTapToRevealPlaceholderOnTextNode(cellNode, knownBodyNode, comment, fullName)) return;
        return;
    }
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, [hiddenNodes copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, hiddenNodes.firstObject, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(hiddenNodes.firstObject);
}

static BOOL ApolloDeletedCommentsTouchHitsTextNode(id textNode, UITouch *touch) {
    if (!textNode || !touch || ![textNode respondsToSelector:@selector(view)]) return NO;
    UIView *nodeView = nil;
    @try {
        nodeView = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
    } @catch (__unused NSException *e) {
        nodeView = nil;
    }
    if (![nodeView isKindOfClass:[UIView class]] || nodeView.hidden || nodeView.alpha < 0.01) return NO;
    CGPoint point = [touch locationInView:nodeView];
    return CGRectContainsPoint(CGRectInset(nodeView.bounds, -8.0, -8.0), point);
}

static void __attribute__((unused)) ApolloDeletedCommentsForceCommentExpanded(RDKComment *comment, id cellNode) {
    if (!comment) return;

    if ([(id)comment respondsToSelector:@selector(setCollapsed:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)((id)comment, @selector(setCollapsed:), NO);
        } @catch (__unused NSException *e) {}
    }

    Ivar collapsedIvar = class_getInstanceVariable([(id)comment class], "_collapsed");
    if (collapsedIvar) {
        @try {
            ptrdiff_t offset = ivar_getOffset(collapsedIvar);
            if (offset > 0) {
                BOOL *slot = (BOOL *)((uint8_t *)(__bridge void *)comment + offset);
                *slot = NO;
            }
        } @catch (__unused NSException *e) {}
    }

    SEL selectors[] = {
        @selector(setNeedsLayout),
        @selector(setNeedsDisplay),
    };
    for (size_t i = 0; i < 2; i++) {
        SEL sel = selectors[i];
        if ([cellNode respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(cellNode, sel); } @catch (__unused NSException *e) {}
        }
    }
}

static void __attribute__((unused)) ApolloDeletedCommentsScheduleForceExpanded(RDKComment *comment, id cellNode) {
    if (!comment) return;
    NSArray<NSNumber *> *delays = @[@0.0, @0.03, @0.12, @0.30];
    for (NSNumber *delayNumber in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloDeletedCommentsForceCommentExpanded(comment, cellNode);
        });
    }
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsTouchHitsHiddenBody(id cellNode, UITouch *touch) {
    for (id textNode in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) continue;
        if (ApolloDeletedCommentsTouchHitsTextNode(textNode, touch)) return YES;
    }
    return NO;
}

static void __attribute__((unused)) ApolloDeletedCommentsApplyRevealedBodyTextToNode(id cellNode, id textNode) {
    if (!cellNode || !textNode) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (!comment || fullName.length == 0 || !ApolloDeletedCommentsIsCommentRevealed(fullName)) return;
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    if (!ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody)) return;

    NSAttributedString *templateText = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![templateText isKindOfClass:[NSAttributedString class]] || templateText.length == 0) {
        templateText = ApolloDeletedCommentsCurrentAttributedText(textNode);
    }
    NSAttributedString *bodyText = ApolloDeletedCommentsRecoveredBodyTextForDisplay(templateText, resolvedBody);
    bodyText = ApolloDeletedCommentsAttributedTextWithReasonPrefix(textNode, bodyText);
    if (bodyText.length == 0) return;

    ApolloDeletedCommentsSetTextNodeAttributedText(textNode, bodyText);
    ApolloDeletedCommentsDisableRevealTapInterception(textNode);
    ApolloDeletedCommentsInvalidateCellAndTextNodeLocally(cellNode, textNode);
}

static void __attribute__((unused)) ApolloDeletedCommentsRevealHiddenBodyForCell(id cellNode, id tappedTextNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (!comment || fullName.length == 0) return;

    if (ApolloDeletedCommentsIsDeletedPlaceholder(fullName) && !ApolloDeletedCommentsIsRecoveredComment(fullName)) {
        return;
    }

    BOOL restored = ApolloDeletedCommentsRestoreOriginalModelBodyIfNeeded(comment);
    if (!restored) {
        NSDictionary *archived = ApolloDeletedCommentsCachedArchivedComment(fullName);
        if (archived.count > 0) {
            NSString *reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName) ?: ApolloDeletedCommentsRecoveredReasonForComment(fullName);
            NSString *archivedBody = ApolloDeletedCommentsRecoverableArchivedBody(archived);
            if (ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject((id)comment, archived, reason)) {
                if (archivedBody.length > 0) {
                    objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyKey, [archivedBody copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
                    objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyHTMLKey, ApolloDeletedCommentsPlainBodyHTML(archivedBody), OBJC_ASSOCIATION_COPY_NONATOMIC);
                }
                restored = YES;
            }
        }
    }
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    if (!ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody)) return;

    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBody:), resolvedBody);
    ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBodyHTML:), ApolloDeletedCommentsPlainBodyHTML(resolvedBody));
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);

    id revealTextNode = tappedTextNode;
    if (!revealTextNode) {
        revealTextNode = ApolloDeletedCommentsHiddenTextNodesForCell(cellNode).firstObject;
    }
    if (!revealTextNode) {
        revealTextNode = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
    }
    ApolloDeletedCommentsApplyRevealedBodyTextToNode(cellNode, revealTextNode);

    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, revealTextNode ?: ApolloDeletedCommentsKnownBodyTextNode(cellNode));
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsCommentIsRevealed(RDKComment *comment) {
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsCommentRevealed(fullName);
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsTouchHitsRecoveredBody(id cellNode, UITouch *touch) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode)) return NO;
    for (id textNode in ApolloDeletedCommentsBodyTextNodes(cellNode, comment)) {
        if (ApolloDeletedCommentsTouchHitsTextNode(textNode, touch)) return YES;
    }
    return NO;
}

static void __attribute__((unused)) ApolloDeletedCommentsHideRevealedBodyForCell(id cellNode, id tappedTextNode) {
    (void)tappedTextNode;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    ApolloDeletedCommentsUnmarkCommentRevealed(fullName);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsApplyTapToRevealIfNeeded(cellNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyTextNode(cellNode));
}

// textNode is an optional hint of which body node was tapped. When nil (the cell
// level tap path) the reveal/hide helpers resolve the right body node themselves.
static void ApolloDeletedCommentsScheduleRevealToggleForTextNode(id cellNode, id textNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (!cellNode || !comment || fullName.length == 0) return;
    if ([objc_getAssociatedObject((id)comment, kApolloDeletedCommentsRevealToggleInFlightKey) boolValue]) return;

    BOOL shouldHide = ApolloDeletedCommentsCommentIsRevealedByFullName(comment);
    objc_setAssociatedObject((id)comment, kApolloDeletedCommentsRevealToggleInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakCellNode = cellNode;
    __weak id weakTextNode = textNode;
    __weak RDKComment *weakComment = comment;
    NSString *capturedFullName = [fullName copy];

    dispatch_async(dispatch_get_main_queue(), ^{
        id currentCellNode = weakCellNode;
        id currentTextNode = weakTextNode;
        RDKComment *currentComment = ApolloDeletedCommentsCommentFromCellNode(currentCellNode);
        if (!currentComment) currentComment = weakComment;

        @try {
            NSString *currentFullName = ApolloDeletedCommentsFullNameForComment(currentComment);
            if (currentCellNode && [currentFullName isEqualToString:capturedFullName]) {
                if (shouldHide) {
                    ApolloDeletedCommentsHideRevealedBodyForCell(currentCellNode, currentTextNode);
                } else {
                    ApolloDeletedCommentsRevealHiddenBodyForCell(currentCellNode, currentTextNode);
                }
            }
        } @catch (__unused NSException *e) {
        } @finally {
            RDKComment *clearComment = currentComment ?: weakComment;
            if (clearComment) {
                objc_setAssociatedObject((id)clearComment, kApolloDeletedCommentsRevealToggleInFlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    });
}

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;
    id current = textNode;
    id fallbackOwnerCell = nil;
    for (NSUInteger i = 0; current && i < 10; i++) {
        const char *className = class_getName(object_getClass(current));
        if (className && strstr(className, "CommentCellNode")) return current;
        id ownerCell = objc_getAssociatedObject(current, kApolloDeletedCommentsBodyOwnerCellKey);
        if (ownerCell && !fallbackOwnerCell) fallbackOwnerCell = ownerCell;
        if (![current respondsToSelector:@selector(supernode)]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        } @catch (__unused NSException *e) {
            break;
        }
    }
    return fallbackOwnerCell;
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(id textNode) {
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    return ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode);
}

static BOOL ApolloDeletedCommentsBodyAttributeFontsDiffer(NSDictionary *left, NSDictionary *right) {
    UIFont *leftFont = [left isKindOfClass:[NSDictionary class]] ? left[NSFontAttributeName] : nil;
    UIFont *rightFont = [right isKindOfClass:[NSDictionary class]] ? right[NSFontAttributeName] : nil;
    if (![leftFont isKindOfClass:[UIFont class]] || ![rightFont isKindOfClass:[UIFont class]]) {
        return leftFont != rightFont;
    }
    if (fabs(leftFont.pointSize - rightFont.pointSize) > 0.1) return YES;
    return ![leftFont.fontName isEqualToString:rightFont.fontName];
}

static BOOL ApolloDeletedCommentsBodyAttributesAreUsable(NSDictionary *attributes) {
    if (![attributes isKindOfClass:[NSDictionary class]]) return NO;
    UIFont *font = attributes[NSFontAttributeName];
    return [font isKindOfClass:[UIFont class]] && font.pointSize >= 8.0 && font.pointSize <= 40.0;
}

static void ApolloDeletedCommentsScheduleBodyAttributesRefresh(void) {
    if (sApolloDeletedCommentsBodyAttributesRefreshScheduled) return;
    sApolloDeletedCommentsBodyAttributesRefreshScheduled = YES;

    NSArray<NSNumber *> *delays = @[@0.0, @0.05, @0.15];
    for (NSNumber *delayNumber in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApolloDeletedCommentsRefreshVisibleDeletedCells();
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sApolloDeletedCommentsBodyAttributesRefreshScheduled = NO;
    });
}

// On a SYSTEM Dynamic Type change, drop the cached body template and refresh the
// visible deleted cells so they re-resolve at the new size (relevant when "Use
// System Text Size" is on).
static void ApolloDeletedCommentsHandleContentSizeChanged(__unused NSNotification *note) {
    ApolloDeletedCommentsBodyTemplateSet(nil);
    if (ApolloDeletedCommentsFeatureActive()) {
        ApolloDeletedCommentsScheduleBodyAttributesRefresh();
    }
}

static UIView *ApolloDeletedCommentsCellView(id cellNode) {
    if (!cellNode || ![cellNode respondsToSelector:@selector(view)]) return nil;
    UIView *view = nil;
    @try {
        view = ((UIView *(*)(id, SEL))objc_msgSend)(cellNode, @selector(view));
    } @catch (__unused NSException *e) {
        view = nil;
    }
    return [view isKindOfClass:[UIView class]] ? view : nil;
}

static UIView *ApolloDeletedCommentsHostListViewForCell(id cellNode) {
    UIView *view = ApolloDeletedCommentsCellView(cellNode);
    for (NSUInteger i = 0; view && i < 14; i++, view = view.superview) {
        if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
            return view;
        }
    }
    return nil;
}

static void ApolloDeletedCommentsScheduleHostLayoutRefresh(id cellNode) {
    if (!cellNode || !ApolloDeletedCommentsFeatureActive() || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;

    UIView *hostView = ApolloDeletedCommentsHostListViewForCell(cellNode);
    UIView *cellView = ApolloDeletedCommentsCellView(cellNode);
    if (![hostView isKindOfClass:[UIView class]] || !hostView.window) return;
    if (objc_getAssociatedObject(hostView, kApolloDeletedCommentsHostLayoutRefreshScheduledKey)) return;

    objc_setAssociatedObject(hostView, kApolloDeletedCommentsHostLayoutRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakHostView = hostView;
    __weak UIView *weakCellView = cellView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongHostView = weakHostView;
        UIView *strongCellView = weakCellView;
        if (![strongHostView isKindOfClass:[UIView class]]) return;

        objc_setAssociatedObject(strongHostView, kApolloDeletedCommentsHostLayoutRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *view = strongCellView; view && view != strongHostView.superview; view = view.superview) {
            [view setNeedsLayout];
            [view setNeedsDisplay];
        }

        @try {
            if ([strongHostView isKindOfClass:[UICollectionView class]]) {
                [(UICollectionView *)strongHostView performBatchUpdates:nil completion:nil];
            } else if ([strongHostView isKindOfClass:[UITableView class]]) {
                UITableView *tableView = (UITableView *)strongHostView;
                [tableView beginUpdates];
                [tableView endUpdates];
            } else {
                [strongHostView setNeedsLayout];
                [strongHostView layoutIfNeeded];
            }
        } @catch (__unused NSException *e) {
            [strongHostView setNeedsLayout];
        }
    });
}

static void ApolloDeletedCommentsRemoveCellHighlight(id cellNode) {
    UIView *highlight = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHighlightViewKey);
    if ([highlight isKindOfClass:[UIView class]]) {
        [highlight removeFromSuperview];
    }
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHighlightViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloDeletedCommentsApplyCellHighlight(id cellNode) {
    if (!ApolloDeletedCommentsFeatureActive() || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) {
        ApolloDeletedCommentsRemoveCellHighlight(cellNode);
        return;
    }

    UIView *cellView = ApolloDeletedCommentsCellView(cellNode);
    if (!cellView) return;

    UIView *highlight = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHighlightViewKey);
    if (![highlight isKindOfClass:[UIView class]]) {
        highlight = [[UIView alloc] initWithFrame:cellView.bounds];
        highlight.userInteractionEnabled = NO;
        highlight.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHighlightViewKey, highlight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    highlight.backgroundColor = ApolloDeletedCommentsHighlightColorForLabel(ApolloDeletedCommentsReasonLabelForComment(comment));

    highlight.frame = cellView.bounds;
    if (highlight.superview != cellView) {
        [highlight removeFromSuperview];
        [cellView addSubview:highlight];
    } else {
        [cellView bringSubviewToFront:highlight];
    }
}

// Single unification chokepoint: force the body text to the one body template font
// regardless of which path built it. Multiple paths construct the revealed body
// (layout spec, tap reveal, redecoration, defaults) and historically disagreed on
// size, which is why some comments rendered small and others large. Here we rewrite
// every long, non-attachment (body) run to the template font, leaving short runs
// (reason-chip labels) and image attachments (the chip itself) untouched.
static NSAttributedString *ApolloDeletedCommentsBodyFontUnifiedText(NSAttributedString *text) {
    if (![text isKindOfClass:[NSAttributedString class]] || text.length == 0) return text;
    NSDictionary *bodyTemplate = ApolloDeletedCommentsBodyTemplateGet();
    UIFont *templateFont = [bodyTemplate isKindOfClass:[NSDictionary class]]
                               ? bodyTemplate[NSFontAttributeName]
                               : nil;
    if (![templateFont isKindOfClass:[UIFont class]]) return text;

    __block NSUInteger longestPlainRun = 0;
    [text enumerateAttributesInRange:NSMakeRange(0, text.length) options:0
                          usingBlock:^(NSDictionary<NSAttributedStringKey, id> *a, NSRange r, __unused BOOL *stop) {
        if (a[NSAttachmentAttributeName]) return;
        if (r.length > longestPlainRun) longestPlainRun = r.length;
    }];
    if (longestPlainRun < 20) return text;

    NSMutableAttributedString *result = [text mutableCopy];
    [result enumerateAttributesInRange:NSMakeRange(0, result.length) options:0
                            usingBlock:^(NSDictionary<NSAttributedStringKey, id> *a, NSRange r, __unused BOOL *stop) {
        if (a[NSAttachmentAttributeName]) return;
        UIFont *runFont = a[NSFontAttributeName];
        UIFont *target = templateFont;
        if ([runFont isKindOfClass:[UIFont class]]) {
            // Preserve inline bold/italic by applying the template size to the run's traits.
            UIFontDescriptorSymbolicTraits emphasis = runFont.fontDescriptor.symbolicTraits &
                                                      (UIFontDescriptorTraitBold | UIFontDescriptorTraitItalic);
            if (emphasis) {
                UIFontDescriptor *d = [templateFont.fontDescriptor fontDescriptorWithSymbolicTraits:
                                       templateFont.fontDescriptor.symbolicTraits | emphasis];
                if (d) target = [UIFont fontWithDescriptor:d size:templateFont.pointSize] ?: templateFont;
            }
            if (fabs(runFont.pointSize - target.pointSize) <= 0.5 &&
                [runFont.fontName isEqualToString:target.fontName]) {
                return;
            }
        }
        [result addAttribute:NSFontAttributeName value:target range:r];
    }];
    return result;
}

static void ApolloDeletedCommentsSetTextNodeAttributedText(id textNode, NSAttributedString *attributedText) {
    if (!textNode || ![attributedText isKindOfClass:[NSAttributedString class]]) return;
    attributedText = ApolloDeletedCommentsBodyFontUnifiedText(attributedText);
    // Skip identical re-writes. Setting a text node's attributedText dirties it and
    // schedules a re-measure; if the new content equals the current content this is
    // pure churn. Combined with the cached chip string above, repeated measures of a
    // settled deleted cell now become no-ops instead of an endless re-measure loop
    // (#514). Uses -isEqualToAttributedString: so identical chip/body strings compare
    // equal even when freshly allocated.
    NSAttributedString *current = ApolloDeletedCommentsCurrentAttributedText(textNode);
    if ([current isKindOfClass:[NSAttributedString class]] &&
        [current isEqualToAttributedString:attributedText]) {
        return;
    }
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), attributedText);
    } @catch (__unused NSException *e) {}
}

static id ApolloDeletedCommentsBodyReplacementTextNode(id markdownNode, id cellNode) {
    if (!markdownNode || !cellNode) return nil;
    id textNode = objc_getAssociatedObject(markdownNode, kApolloDeletedCommentsBodyReplacementTextNodeKey);
    Class textNodeClass = ApolloDeletedCommentsASTextNodeClass();
    if (!textNode || !textNodeClass || ![textNode isKindOfClass:textNodeClass]) {
        textNode = [[textNodeClass alloc] init];
        if (!textNode) return nil;
        objc_setAssociatedObject(markdownNode, kApolloDeletedCommentsBodyReplacementTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(markdownNode, @selector(addSubnode:), textNode);
        } @catch (__unused NSException *e) {}
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setDelegate:), markdownNode);
    } @catch (__unused NSException *e) {}
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    return textNode;
}

static NSAttributedString *ApolloDeletedCommentsTemplateTextForMarkdownNode(id markdownNode) {
    NSMutableArray *textNodes = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
    ApolloDeletedCommentsCollectAttributedTextNodes(markdownNode, 4, visited, textNodes);
    for (id textNode in textNodes) {
        NSAttributedString *current = ApolloDeletedCommentsCurrentAttributedText(textNode);
        if ([current isKindOfClass:[NSAttributedString class]] && current.length > 0) return current;
    }
    return [[NSAttributedString alloc] initWithString:@" "
                                           attributes:ApolloDeletedCommentsDefaultBodyAttributes()];
}

// Reads the font Apollo actually uses for THIS MarkdownNode's body, straight from
// its native display nodes. This is the deterministic, per-comment source of the
// user's configured comment font — no global capture, no guessing. We deliberately
// ignore the node's STRING (it may be a "[removed]"/reason-label placeholder while
// hidden); we only want the font/paragraph attributes, which Apollo renders at the
// real body size regardless of the placeholder text. The replacement text node we
// inject is skipped so we never read back our own (chip-sized) attributes.
static NSDictionary *ApolloDeletedCommentsNativeBodyAttributesForMarkdownNode(id markdownNode) {
    if (!markdownNode) return nil;
    id replacement = objc_getAssociatedObject(markdownNode, kApolloDeletedCommentsBodyReplacementTextNodeKey);

    NSMutableArray *nodes = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
    ApolloDeletedCommentsCollectAttributedTextNodes(markdownNode, 4, visited, nodes);

    for (id node in nodes) {
        if (node == replacement) continue;
        NSAttributedString *text = ApolloDeletedCommentsCurrentAttributedText(node);
        if (![text isKindOfClass:[NSAttributedString class]] || text.length == 0) continue;

        __block NSMutableDictionary *attrs = nil;
        [text enumerateAttributesInRange:NSMakeRange(0, text.length)
                                 options:0
                              usingBlock:^(NSDictionary<NSAttributedStringKey, id> *a, __unused NSRange r, BOOL *stop) {
            if (a[NSAttachmentAttributeName]) return;
            UIFont *font = a[NSFontAttributeName];
            if (![font isKindOfClass:[UIFont class]] || font.pointSize < 8.0 || font.pointSize > 40.0) return;
            if ((font.fontDescriptor.symbolicTraits & (UIFontDescriptorTraitBold | UIFontDescriptorTraitItalic)) != 0) return;
            attrs = ApolloDeletedCommentsSanitizedBodyAttributes(a);
            *stop = YES;
        }];
        if (attrs) return ApolloDeletedCommentsRegularizedBodyAttributes(attrs);
    }
    return nil;
}

// Force a body-attributes dictionary's font to the REGULAR (non-bold, non-italic)
// weight at the same family/size. Guards against ever storing a bold/semibold body
// template, which would render revealed comments heavier than normal comments.
static NSDictionary *ApolloDeletedCommentsRegularizedBodyAttributes(NSDictionary *attributes) {
    if (![attributes isKindOfClass:[NSDictionary class]]) return attributes;
    UIFont *font = attributes[NSFontAttributeName];
    if (![font isKindOfClass:[UIFont class]]) return attributes;
    UIFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits;
    if ((traits & (UIFontDescriptorTraitBold | UIFontDescriptorTraitItalic)) == 0) return attributes;

    UIFont *regular = nil;
    UIFontDescriptor *desc = [font.fontDescriptor fontDescriptorWithSymbolicTraits:
                              traits & ~(UIFontDescriptorTraitBold | UIFontDescriptorTraitItalic)];
    if (desc) regular = [UIFont fontWithDescriptor:desc size:font.pointSize];
    if (!regular) regular = [UIFont systemFontOfSize:font.pointSize weight:UIFontWeightRegular];

    NSMutableDictionary *copy = [attributes mutableCopy];
    copy[NSFontAttributeName] = regular;
    return copy;
}

static id __attribute__((unused)) ApolloDeletedCommentsDeletedMarkdownLayoutSpecIfNeeded(id markdownNode) {
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(markdownNode);
    if (!cellNode) cellNode = objc_getAssociatedObject(markdownNode, kApolloDeletedCommentsBodyOwnerCellKey);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return nil;
    if (ApolloDeletedCommentsCommentIsCollapsed(comment)) return nil;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL placeholderOnly = ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode) &&
                           !ApolloDeletedCommentsCellNodeIsRecovered(cellNode);
    BOOL recovered = ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName);
    BOOL shouldHide = ApolloDeletedCommentsFeatureActive() &&
                      sTapToRevealDeletedComments &&
                      recovered &&
                      !revealed;
    // Once revealed, KEEP owning this MarkdownNode's layout (don't fall back to
    // %orig). %orig re-lays-out the node's stale displayNodes, which were built
    // from the hidden "[removed]" body, so it never shows the recovered text. By
    // staying on our replacement text node and just swapping its content from the
    // chip to the body, a single tap renders the body in place.
    BOOL revealedRecovered = ApolloDeletedCommentsFeatureActive() &&
                             sTapToRevealDeletedComments &&
                             recovered &&
                             revealed;

    if (!(placeholderOnly || shouldHide || revealedRecovered)) {
        return nil;
    }

    id textNode = ApolloDeletedCommentsBodyReplacementTextNode(markdownNode, cellNode);
    if (!textNode) return nil;

    NSAttributedString *templateText = ApolloDeletedCommentsTemplateTextForMarkdownNode(markdownNode);
    NSAttributedString *displayText = nil;
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment) ?: comment.body;
    // Font resolution — deterministic, matching Apollo exactly with NO learning,
    // guessing, or hardcoded point sizes:
    //   "Use System Text Size" ON  -> the live system Dynamic Type size
    //   "Use System Text Size" OFF -> Apollo's in-app slider (ApolloCustomTextSize)
    // SIZE/WEIGHT come from that resolver; body COLOR comes from the comment's own
    // native attributes when available (so it matches the active theme).
    NSDictionary *nativeAttributes = ApolloDeletedCommentsNativeBodyAttributesForMarkdownNode(markdownNode);
    NSDictionary *appAttributes = ApolloDeletedCommentsAppBodyAttributesForNode(markdownNode);
    if (appAttributes && [nativeAttributes[NSForegroundColorAttributeName] isKindOfClass:[UIColor class]]) {
        NSMutableDictionary *merged = [appAttributes mutableCopy];
        merged[NSForegroundColorAttributeName] = nativeAttributes[NSForegroundColorAttributeName];
        appAttributes = merged;
    }

    // Promote the resolved app font to the single authoritative body template so
    // EVERY body path (this layout, tap reveal, redecoration) and the unify
    // chokepoint render at the exact same size. When it changes (e.g. the user
    // moves the in-app text-size slider), refresh the visible deleted cells.
    if (ApolloDeletedCommentsBodyAttributesAreUsable(appAttributes)) {
        NSDictionary *cap = ApolloDeletedCommentsRegularizedBodyAttributes([appAttributes copy]);
        NSDictionary *tmpl = ApolloDeletedCommentsBodyTemplateGet();
        if (![tmpl isKindOfClass:[NSDictionary class]] ||
            ApolloDeletedCommentsBodyAttributeFontsDiffer(tmpl, cap)) {
            ApolloDeletedCommentsBodyTemplateSet(cap);
            if (ApolloDeletedCommentsFeatureActive()) ApolloDeletedCommentsScheduleBodyAttributesRefresh();
        }
        appAttributes = cap;
    }

    NSAttributedString *original = nil;
    if (appAttributes && resolvedBody.length > 0) {
        original = [[NSAttributedString alloc] initWithString:resolvedBody attributes:appAttributes];
    } else if (nativeAttributes && resolvedBody.length > 0) {
        original = [[NSAttributedString alloc] initWithString:resolvedBody attributes:nativeAttributes];
    } else {
        original = ApolloDeletedCommentsBodyAttributedText(templateText, resolvedBody);
    }
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, @[textNode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary *chipAttributes = ApolloDeletedCommentsReasonChipBaseAttributes(original, cellNode);
    if (revealedRecovered) {
        // Show the recovered body itself.
        displayText = ApolloDeletedCommentsAttributedTextWithReasonPrefix(textNode, original);
    } else if (placeholderOnly) {
        displayText = ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment),
                                                                    chipAttributes,
                                                                    NO);
    } else {
        displayText = ApolloDeletedCommentsPlaceholderAttributedText(original, ApolloDeletedCommentsReasonLabelForComment(comment), cellNode);
    }

    ApolloDeletedCommentsSetTextNodeAttributedText(textNode, displayText);
    Class insetClass = ApolloDeletedCommentsASInsetLayoutSpecClass();
    if (!insetClass) return nil;
    return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsZero child:textNode];
}

static NSAttributedString *ApolloDeletedCommentsCurrentAttributedText(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(attributedText)]) return nil;
    @try {
        return ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void ApolloDeletedCommentsApplyRecoveredArchiveToVisibleCell(id cellNode, NSDictionary *archived) {
    if (!cellNode || ![archived isKindOfClass:[NSDictionary class]]) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;
    NSString *archivedBody = ApolloDeletedCommentsRecoverableArchivedBody(archived);
    if (archivedBody.length == 0) return;
    if (!ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode) &&
        !ApolloDeletedCommentsVisibleCommentNeedsRecoveredArchive(comment, archivedBody)) {
        return;
    }
    if (!ApolloDeletedCommentsVisibleCommentNeedsRecoveredArchive(comment, archivedBody)) return;

    NSString *reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName) ?: ApolloDeletedCommentsRecoveredReasonForComment(fullName);
    if (!ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject((id)comment, archived, reason)) return;
    objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyKey, [archivedBody copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyHTMLKey, ApolloDeletedCommentsPlainBodyHTML(archivedBody), OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);
    ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(cellNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyTextNode(cellNode));
    ApolloDeletedCommentsApplyCellHighlight(cellNode);
}

static void ApolloDeletedCommentsHandleArcticCacheUpdated(NSNotification *notification) {
    if (!ApolloDeletedCommentsFeatureActive()) return;
    NSDictionary *comments = [notification.userInfo[@"comments"] isKindOfClass:[NSDictionary class]] ? notification.userInfo[@"comments"] : nil;
    if (comments.count == 0) return;

    for (NSString *fullName in comments) {
        NSDictionary *archived = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
        if (![archived isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *capturedArchive = [archived copy];
        NSString *capturedFullName = [fullName copy];
        for (NSNumber *delayNumber in @[@0.0, @0.05, @0.15, @0.35]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                for (id cellNode in ApolloDeletedCommentsTrackedCellsForFullName(capturedFullName)) {
                    RDKComment *currentComment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
                    NSString *currentFullName = ApolloDeletedCommentsFullNameForComment(currentComment);
                    if (![currentFullName isEqualToString:capturedFullName]) continue;
                    ApolloDeletedCommentsApplyRecoveredArchiveToVisibleCell(cellNode, capturedArchive);
                }
            });
        }
    }
}

static void ApolloDeletedCommentsApplyCachedArchiveToVisibleDeletedCell(id cellNode) {
    if (!cellNode) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;

    NSDictionary *archived = ApolloDeletedCommentsCachedArchivedComment(fullName);
    if (archived.count == 0) return;
    NSString *archivedBody = ApolloDeletedCommentsRecoverableArchivedBody(archived);
    if (archivedBody.length == 0) return;
    if (!ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode) &&
        !ApolloDeletedCommentsVisibleCommentNeedsRecoveredArchive(comment, archivedBody)) {
        return;
    }
    ApolloDeletedCommentsApplyRecoveredArchiveToVisibleCell(cellNode, archived);
}

static void __attribute__((unused)) ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(id cellNode) {
    if (!ApolloDeletedCommentsFeatureActive()) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;
    BOOL hiddenTapToReveal = sTapToRevealDeletedComments && !ApolloDeletedCommentsCommentIsRevealedByFullName(comment);

    NSArray *textNodes = ApolloDeletedCommentsBodyTextNodes(cellNode, comment);
    if (textNodes.count == 0) {
        id knownBodyNode = ApolloDeletedCommentsFallbackBodyTextNode(cellNode);
        if (knownBodyNode) textNodes = @[knownBodyNode];
    }
    for (id textNode in textNodes) {
        NSAttributedString *current = nil;
        @try {
            current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
        } @catch (__unused NSException *e) {
            current = nil;
        }
        if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) continue;
        if (ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(current)) {
            return;
        }

        NSString *label = ApolloDeletedCommentsReasonLabelForComment(comment);
        NSString *currentLabel = ApolloDeletedCommentsNormalizedReasonLabel(ApolloDeletedCommentsTrimmedString(current.string)).uppercaseString;
        if ([currentLabel isEqualToString:label.uppercaseString]) {
            NSAttributedString *chip = ApolloDeletedCommentsReasonChipAttributedText(label,
                                                                                     ApolloDeletedCommentsReasonChipBaseAttributes(current, cellNode),
                                                                                     NO);
            ApolloDeletedCommentsSetTextNodeAttributedText(textNode, chip);
            ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
            return;
        }
        if (hiddenTapToReveal) continue;

        NSAttributedString *bodySource = current;
        if (ApolloDeletedCommentsAttributedTextHasReasonPrefix(current)) {
            bodySource = ApolloDeletedCommentsAttributedTextByRemovingReasonPrefix(current);
            if (![bodySource isKindOfClass:[NSAttributedString class]] || bodySource.length == 0) {
                continue;
            }
        }
        NSAttributedString *repaired = ApolloDeletedCommentsAttributedTextWithReasonPrefix(textNode, bodySource);
        if (repaired != current) {
            ApolloDeletedCommentsSetTextNodeAttributedText(textNode, repaired);
            ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
            return;
        }
    }
}

static void ApolloDeletedCommentsScheduleReasonChipRepair(id cellNode) {
    if (!ApolloDeletedCommentsFeatureActive() || !cellNode) return;
    if ([objc_getAssociatedObject(cellNode, kApolloDeletedCommentsReasonChipRepairScheduledKey) boolValue]) return;

    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0 || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;

    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsReasonChipRepairScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // One deferred pass, not three. The repeats re-ran the repair + RelayoutCellAndTextNode
    // to catch async chip drift, but each pass re-fires a host-wide beginUpdates/endUpdates
    // re-measure across every visible deleted cell — a fan-out amplifier of the #514 freeze.
    // The setAttributedText: chip chain re-stamps on any rewrite and the MarkdownNode layout
    // spec re-emits on any measure, so a single deferred invalidate suffices to pick up the
    // taller recovered-body height after an archive/state change.
    NSArray<NSNumber *> *delays = @[@0.15];
    for (NSNumber *delayNumber in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RDKComment *currentComment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
            NSString *currentFullName = ApolloDeletedCommentsFullNameForComment(currentComment);
            if (![currentFullName isEqualToString:fullName]) return;

            ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(cellNode);
            ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
            ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyTextNode(cellNode));
            ApolloDeletedCommentsApplyCellHighlight(cellNode);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsReasonChipRepairScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static void ApolloDeletedCommentsUpdateCell(id cellNode) {
    ApolloDeletedCommentsTrackVisibleDeletedCommentCell(cellNode);
    ApolloDeletedCommentsApplyCachedArchiveToVisibleDeletedCell(cellNode);
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);
    ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(cellNode);
    ApolloDeletedCommentsScheduleReasonChipRepair(cellNode);
    ApolloDeletedCommentsApplyCellHighlight(cellNode);
    if (ApolloDeletedCommentsFeatureActive() && sTapToRevealDeletedComments) {
        ApolloDeletedCommentsInstallRevealTapGestureOnCell(cellNode);
    }
}

static void ApolloDeletedCommentsRefreshVisibleDeletedCells(void) {
    if (!ApolloDeletedCommentsFeatureActive()) return;
    for (id cellNode in ApolloDeletedCommentsAllTrackedVisibleCells()) {
        ApolloDeletedCommentsUpdateCell(cellNode);
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyTextNode(cellNode));
    }
}

static void ApolloDeletedCommentsScheduleVisibleCellRefreshForComment(RDKComment *comment) {
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;

    NSArray<NSNumber *> *delays = @[@0.0, @0.05, @0.15, @0.35];
    for (NSNumber *delayNumber in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (id cellNode in ApolloDeletedCommentsTrackedCellsForFullName(fullName)) {
                RDKComment *currentComment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
                NSString *currentFullName = ApolloDeletedCommentsFullNameForComment(currentComment);
                if (![currentFullName isEqualToString:fullName]) continue;
                ApolloDeletedCommentsUpdateCell(cellNode);
            }
        });
    }
}

static BOOL ApolloDeletedCommentsIsRevealLink(id attribute, id value) {
    if ([attribute isKindOfClass:[NSString class]] &&
        [(NSString *)attribute isEqualToString:ApolloDeletedCommentsRevealAttributeName]) {
        return YES;
    }

    NSString *urlString = nil;
    if ([value isKindOfClass:[NSURL class]]) {
        urlString = [(NSURL *)value absoluteString];
    } else if ([value isKindOfClass:[NSString class]]) {
        urlString = value;
    }
    return [urlString isEqualToString:ApolloDeletedCommentsRevealURLString];
}

static NSAttributedString *__attribute__((unused)) ApolloDeletedCommentsRenameRecoveredSpoilerLabel(id textNode, NSAttributedString *attributedText) {
    if (!ApolloDeletedCommentsFeatureActive() || !sTapToRevealDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    NSString *text = ApolloDeletedCommentsTrimmedString(attributedText.string);
    if (![text isEqualToString:@"SPOILER"]) return attributedText;
    if (!ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(textNode)) return attributedText;

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSDictionary *baseAttributes = ApolloDeletedCommentsReasonChipBaseAttributes(attributedText, cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL placeholderOnly = ApolloDeletedCommentsIsDeletedPlaceholder(fullName) &&
                           !ApolloDeletedCommentsIsRecoveredComment(fullName);
    if (placeholderOnly) {
        return ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment), baseAttributes, NO);
    }

    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName);
    NSMutableAttributedString *renamed = [ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment), baseAttributes, !revealed) mutableCopy];
    NSRange targetRange = NSMakeRange(0, renamed.length);
    [attributedText enumerateAttributesInRange:NSMakeRange(0, attributedText.length)
                                       options:0
                                    usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, __unused BOOL *stop) {
        for (NSAttributedStringKey key in attrs) {
            if ([key isEqualToString:NSFontAttributeName] ||
                [key isEqualToString:NSForegroundColorAttributeName] ||
                [key isEqualToString:NSBackgroundColorAttributeName] ||
                [key isEqualToString:NSParagraphStyleAttributeName]) {
                continue;
            }
            [renamed addAttribute:key value:attrs[key] range:targetRange];
        }
    }];
    if (!revealed) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    }
    return renamed;
}

static Class ApolloDeletedCommentsMarkdownNodeClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = objc_getClass("_TtC6Apollo12MarkdownNode");
    });
    return cls;
}

// Capture Apollo's real comment-body font from a normally-rendered comment body, so
// deleted comments render at the exact same size (see sApolloDeletedCommentsLiveCommentBodyFont).
// Runs from the global setAttributedText: hook, so the steady-state path is kept cheap:
// the supernode walk only runs when the captured font actually changes (first capture
// or a text-size change).
static void ApolloDeletedCommentsCaptureLiveCommentBodyFont(id textNode, NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length < 2) return;
    // Only comment/post *body* nodes carry a MarkdownNode delegate — gate on it cheaply.
    Class mdClass = ApolloDeletedCommentsMarkdownNodeClass();
    if (!mdClass || ![textNode respondsToSelector:@selector(delegate)]) return;
    id delegate = nil;
    @try { delegate = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(delegate)); } @catch (__unused NSException *e) {}
    if (![delegate isKindOfClass:mdClass]) return;
    // Skip our own injected chip/body text (it carries the reason-prefix marker).
    if (ApolloDeletedCommentsAttributedTextHasReasonPrefix(attributedText)) return;

    __block UIFont *candidate = nil;
    [attributedText enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, attributedText.length) options:0
                            usingBlock:^(id value, __unused NSRange range, BOOL *stop) {
        if (![value isKindOfClass:[UIFont class]]) return;
        UIFont *f = (UIFont *)value;
        if (f.pointSize < 8.0 || f.pointSize > 40.0) return;
        if ((f.fontDescriptor.symbolicTraits & (UIFontDescriptorTraitBold | UIFontDescriptorTraitItalic)) != 0) return;
        candidate = f;
        *stop = YES;
    }];
    if (![candidate isKindOfClass:[UIFont class]]) return;
    UIFont *live = ApolloDeletedCommentsLiveBodyFontGet();
    if ([live isKindOfClass:[UIFont class]] &&
        fabs(live.pointSize - candidate.pointSize) <= 0.5 &&
        [live.fontName isEqualToString:candidate.fontName]) {
        return; // unchanged — cheap steady-state exit
    }
    // Capture from any markdown body (comment or post self-text — Apollo renders both
    // at the same text-size setting). The cell hierarchy isn't wired up yet at
    // setAttributedText: time, so we can't reliably scope to comment cells here.
    ApolloDeletedCommentsLiveBodyFontSet(candidate);
    // Drop the cached body template so deleted cells re-resolve at the new size, and
    // refresh the visible ones (this is what makes a text-size change propagate).
    ApolloDeletedCommentsBodyTemplateSet(nil);
    if (ApolloDeletedCommentsFeatureActive()) ApolloDeletedCommentsScheduleBodyAttributesRefresh();
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *displayText = attributedText;
    ApolloDeletedCommentsCaptureLiveCommentBodyFont((id)self, displayText);
    displayText = ApolloDeletedCommentsAttributedTextWithTapToRevealPlaceholder((id)self, displayText);
    displayText = ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, displayText);
    displayText = ApolloDeletedCommentsAttributedTextWithReasonChipIfNeeded((id)self, displayText);
    displayText = ApolloDeletedCommentsAttributedTextWithReasonPrefix((id)self, displayText);
    %orig(displayText);
}

- (void)didEnterDisplayState {
    %orig;
}

%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloDeletedCommentsArcticCacheUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        ApolloDeletedCommentsHandleArcticCacheUpdated(notification);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIContentSizeCategoryDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        ApolloDeletedCommentsHandleContentSizeChanged(notification);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        NSArray<NSNumber *> *delays = @[@0.0, @0.08, @0.25, @0.60];
        for (NSNumber *delayNumber in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ApolloDeletedCommentsRefreshVisibleDeletedCells();
            });
        }
    }];
}

@interface _TtC6Apollo15CommentCellNode
- (void)didLoad;
- (void)didEnterDisplayState;
- (void)calculatedLayoutDidChange;
- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)fits;
- (void)layout;
@end

%hook _TtC6Apollo15CommentCellNode

- (void)didLoad {
    %orig;
    ApolloDeletedCommentsUpdateCell((id)self);
}

- (void)didEnterDisplayState {
    %orig;
    ApolloDeletedCommentsUpdateCell((id)self);
}

- (void)calculatedLayoutDidChange {
    %orig;
    // Intentionally NOT calling ApolloDeletedCommentsUpdateCell here. This is a
    // POST-measure callback; UpdateCell invalidates layout (RelayoutCellAndTextNode ->
    // setNeedsLayout/invalidateCalculatedLayout + ScheduleHostLayoutRefresh's host-wide
    // beginUpdates/endUpdates) and mutates the model, which re-fires this callback — the
    // self-amplifying re-measure loop behind the #514 freeze. The chip/body is already
    // rendered by the MarkdownNode layout spec (re-emits on every measure) and the
    // ASTextNode setAttributedText: chain; tracking + reveal-gesture install run from
    // didLoad/didEnterDisplayState; collapse/expand, archive arrival, and reveal each
    // drive their own off-layout refresh. Nothing here needs to run per measure.
}

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)fits {
    // Do NOT synchronize the model here. SynchronizeCommentModelDisplayState writes
    // setBody:/setBodyHTML:, and mutating RDKComment on the measure path dirties the
    // node and provokes another measure (Texture forbids model mutation in
    // layoutSpecThatFits:) — part of the #514 spin. It is idempotent and already runs
    // off-layout from didEnterDisplayState (UpdateCell), the archive-arrival path, and
    // the reveal path. The spec below resolves the body it displays via
    // ResolvedRecoveredBodyForComment and the body/bodyHTML getter hooks, so it does not
    // depend on the model being pre-normalized here.
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode((id)self);
    id bodyNode = ApolloDeletedCommentsKnownBodyContainerNode((id)self);
    if (bodyNode) {
        objc_setAssociatedObject(bodyNode, kApolloDeletedCommentsBodyOwnerCellKey, (id)self, OBJC_ASSOCIATION_ASSIGN);
    }
    id spec = %orig;
    if (ApolloDeletedCommentsFeatureActive() &&
        !ApolloDeletedCommentsCommentIsCollapsed(comment) &&
        ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment((id)self) &&
        spec) {
        Class insetClass = ApolloDeletedCommentsASInsetLayoutSpecClass();
        if (insetClass) {
            @try {
                return ((id (*)(Class, SEL, UIEdgeInsets, id))objc_msgSend)(insetClass,
                                                                             @selector(insetLayoutSpecWithInsets:child:),
                                                                             UIEdgeInsetsMake(0.0, 0.0, 8.0, 0.0),
                                                                             spec);
            } @catch (__unused NSException *e) {}
        }
    }
    return spec;
}

- (void)layout {
    %orig;
    ApolloDeletedCommentsApplyCellHighlight((id)self);
}

%end

// Reveal a recovered-but-hidden comment. This is the whole "show the text" path:
//
//   1. Put the recovered body into the model and flip the comment to "revealed",
//      so the body getters and the MarkdownNode layout spec both return the real
//      body instead of the chip.
//   2. Keep the row expanded and swallow the collapse that the same tap triggers
//      (the tap that reveals would otherwise also collapse the row — that's why
//      the body used to appear only after a manual collapse/expand). We both undo
//      a collapse that landed first (forceExpanded) and suppress one that lands
//      after (suppress flag).
//   3. Invalidate the MarkdownNode's cached layout and re-measure the row, which
//      is exactly what makes collapse/expand re-render — so the body shows now.
static void ApolloDeletedCommentsRevealCommentInsteadOfCollapsing(RDKComment *comment) {
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;

    // 1. Make the recovered body available on the model.
    if (!ApolloDeletedCommentsRestoreOriginalModelBodyIfNeeded(comment)) {
        NSDictionary *archived = ApolloDeletedCommentsCachedArchivedComment(fullName);
        if (archived.count > 0) {
            NSString *reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName) ?: ApolloDeletedCommentsRecoveredReasonForComment(fullName);
            NSString *archivedBody = ApolloDeletedCommentsRecoverableArchivedBody(archived);
            if (ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject((id)comment, archived, reason) && archivedBody.length > 0) {
                objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyKey, [archivedBody copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
                objc_setAssociatedObject((id)comment, kApolloDeletedCommentsOriginalBodyHTMLKey, ApolloDeletedCommentsPlainBodyHTML(archivedBody), OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
        }
    }
    NSString *resolvedBody = ApolloDeletedCommentsResolvedRecoveredBodyForComment(comment);
    if (!ApolloDeletedCommentsBodyIsDisplayableRecoveredText(resolvedBody)) return;

    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBody:), resolvedBody);
    ApolloDeletedCommentsSetCommentStringValue(comment, @selector(setBodyHTML:), ApolloDeletedCommentsPlainBodyHTML(resolvedBody));

    // 2. Eat the collapse this tap also fires.
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 3. Re-render every on-screen cell for this comment.
    NSArray *trackedCells = ApolloDeletedCommentsTrackedCellsForFullName(fullName);
    for (id cellNode in trackedCells) {
        RDKComment *cellComment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
        if (![ApolloDeletedCommentsFullNameForComment(cellComment) isEqualToString:fullName]) continue;

        ApolloDeletedCommentsForceCommentExpanded(comment, cellNode);
        ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);

        // Prefer the MarkdownNode captured live from its own layout hook; fall
        // back to the ivar lookup. We keep owning its layout (the layout spec now
        // emits the body when revealed), and we also push the body text straight
        // onto our replacement text node so it changes immediately, then
        // invalidate to re-measure the row height.
        id bodyNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsCellMarkdownNodeKey);
        if (!bodyNode) bodyNode = ApolloDeletedCommentsKnownBodyContainerNode(cellNode);

        id replacementNode = bodyNode ? objc_getAssociatedObject(bodyNode, kApolloDeletedCommentsBodyReplacementTextNodeKey) : nil;
        if (!replacementNode) replacementNode = ApolloDeletedCommentsHiddenTextNodesForCell(cellNode).firstObject;
        if (replacementNode) {
            NSAttributedString *templateText = objc_getAssociatedObject(replacementNode, kApolloDeletedCommentsHiddenOriginalTextKey);
            if (![templateText isKindOfClass:[NSAttributedString class]] || templateText.length == 0) {
                templateText = ApolloDeletedCommentsCurrentAttributedText(replacementNode);
            }
            NSAttributedString *bodyText = ApolloDeletedCommentsBodyAttributedText(templateText, resolvedBody);
            bodyText = ApolloDeletedCommentsAttributedTextWithReasonPrefix(replacementNode, bodyText);
            if (bodyText.length > 0) {
                ApolloDeletedCommentsSetTextNodeAttributedText(replacementNode, bodyText);
            }
        }

        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Invalidate the MarkdownNode (body) + replacement node so the layout
        // spec re-runs and the table re-measures the row to the body's height.
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, bodyNode);
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, replacementNode);
    }

    // Clear the suppress flag shortly after in case no stray collapse arrived, so
    // the user's next genuine collapse of the now-revealed comment still works.
    __weak RDKComment *weakComment = comment;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RDKComment *strongComment = weakComment;
        if (strongComment) {
            objc_setAssociatedObject(strongComment, kApolloDeletedCommentsSuppressNextCollapseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}

%hook RDKComment

- (NSString *)body {
    NSString *body = %orig;
    NSString *savedBody = objc_getAssociatedObject((id)self, kApolloDeletedCommentsOriginalBodyKey);
    if ([savedBody isKindOfClass:[NSString class]] &&
        savedBody.length > 0 &&
        ApolloDeletedCommentsStringIsReasonLabel(body)) {
        if (ApolloDeletedCommentsShouldKeepModelBodyHidden((RDKComment *)self)) {
            return body;
        }
        return savedBody;
    }
    return body;
}

- (NSString *)bodyHTML {
    NSString *bodyHTML = %orig;
    NSString *savedBodyHTML = objc_getAssociatedObject((id)self, kApolloDeletedCommentsOriginalBodyHTMLKey);
    if ([savedBodyHTML isKindOfClass:[NSString class]] &&
        savedBodyHTML.length > 0 &&
        ApolloDeletedCommentsStringIsReasonLabel(ApolloDeletedCommentsTrimmedString(bodyHTML))) {
        if (ApolloDeletedCommentsShouldKeepModelBodyHidden((RDKComment *)self)) {
            return bodyHTML;
        }
        return savedBodyHTML;
    }
    return bodyHTML;
}

- (void)setCollapsed:(BOOL)collapsed {
    if (collapsed && [objc_getAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey) boolValue]) {
        objc_setAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    // Collapse/expand stays fully native here and never reveals: revealing is a
    // separate chip-region tap handled by the cell's reveal recognizer. (Earlier
    // this redirected collapses into reveals, but that also fired on Apollo's
    // programmatic/auto collapses, so a comment would appear revealed only after
    // an expand and ordinary collapse/expand would reveal it.)
    %orig;
    if (!collapsed) {
        ApolloDeletedCommentsScheduleVisibleCellRefreshForComment((RDKComment *)self);
    }
}

%end

%hook _TtC6Apollo12MarkdownNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)fits {
    // Record cell -> this MarkdownNode so the reveal path can invalidate the
    // exact node that renders the body, without relying on ivar-name lookup
    // (CommentCellNode.bodyNode is _Atomic and was not being found reliably).
    id ownerCell = ApolloDeletedCommentsCommentCellNodeForTextNode((id)self);
    if (ownerCell) {
        objc_setAssociatedObject(ownerCell, kApolloDeletedCommentsCellMarkdownNodeKey, (id)self, OBJC_ASSOCIATION_ASSIGN);
    }
    id deletedSpec = ApolloDeletedCommentsDeletedMarkdownLayoutSpecIfNeeded((id)self);
    if (deletedSpec) return deletedSpec;

    return %orig;
}

- (BOOL)textNode:(id)textNode shouldHighlightLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value)) {
        return YES;
    }
    return %orig(textNode, attribute, value, point);
}

- (BOOL)textNode:(id)textNode shouldLongPressLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value)) {
        return NO;
    }
    return %orig(textNode, attribute, value, point);
}

- (void)textNode:(id)textNode tappedLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point textRange:(NSRange)range {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value)) {
        id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
        ApolloDeletedCommentsScheduleRevealToggleForTextNode(cellNode, textNode);
        return;
    }
    %orig(textNode, attribute, value, point, range);
}

%end
