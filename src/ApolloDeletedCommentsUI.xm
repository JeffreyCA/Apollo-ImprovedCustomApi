#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

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
static const void *kApolloDeletedCommentsBodyReplacementTextNodeKey = &kApolloDeletedCommentsBodyReplacementTextNodeKey;
static const void *kApolloDeletedCommentsOriginalBodyKey = &kApolloDeletedCommentsOriginalBodyKey;
static const void *kApolloDeletedCommentsOriginalBodyHTMLKey = &kApolloDeletedCommentsOriginalBodyHTMLKey;
static const void *kApolloDeletedCommentsHostLayoutRefreshScheduledKey = &kApolloDeletedCommentsHostLayoutRefreshScheduledKey;

static NSMutableDictionary<NSString *, NSHashTable *> *sApolloDeletedCommentsVisibleCellsByFullName = nil;
static NSObject *sApolloDeletedCommentsVisibleCellsLock = nil;

static NSString *const ApolloDeletedCommentsRevealURLString = @"apollo-deleted-comments://reveal";
static NSString *const ApolloDeletedCommentsRevealAttributeName = @"ApolloDeletedCommentsRevealAttribute";
static NSString *const ApolloDeletedCommentsReasonPrefixAttributeName = @"ApolloDeletedCommentsReasonPrefixAttribute";

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode);
static void ApolloDeletedCommentsEnsureRevealAttributeIsTappable(id textNode);
static void __attribute__((unused)) ApolloDeletedCommentsScheduleForceExpanded(RDKComment *comment, id cellNode);
static void __attribute__((unused)) ApolloDeletedCommentsApplyTapToRevealIfNeeded(id cellNode);
static NSAttributedString *ApolloDeletedCommentsAttributedTextWithReasonPrefix(id textNode, NSAttributedString *attributedText);
static NSArray *ApolloDeletedCommentsHiddenTextNodesForCell(id cellNode);
static NSString *ApolloDeletedCommentsNormalizedReasonLabel(NSString *label);
static void ApolloDeletedCommentsSetTextNodeAttributedText(id textNode, NSAttributedString *attributedText);
static NSAttributedString *ApolloDeletedCommentsCurrentAttributedText(id textNode);
static void ApolloDeletedCommentsSynchronizeCommentModelDisplayState(id cellNode);
static void __attribute__((unused)) ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(id cellNode);
static void ApolloDeletedCommentsScheduleHostLayoutRefresh(id cellNode);
static BOOL ApolloDeletedCommentsTextLooksLikeDeletedPlaceholderNode(NSString *candidate);
static BOOL ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(NSAttributedString *attributedText);
static BOOL ApolloDeletedCommentsAttributedTextHasReasonPrefix(NSAttributedString *attributedText);
static BOOL ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(NSAttributedString *attributedText);
static NSAttributedString *ApolloDeletedCommentsAttributedTextByRemovingReasonPrefix(NSAttributedString *attributedText);
static BOOL ApolloDeletedCommentsTextQualifiesAsBodyCandidate(NSString *candidate, NSString *body);
static BOOL ApolloDeletedCommentsTextQualifiesAsBodyFragment(NSString *candidate, NSString *body);

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

static UIFont *ApolloDeletedCommentsRecoveredBodyFont(void) {
    return [UIFont systemFontOfSize:16.0];
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
    NSString *reason = ApolloDeletedCommentsRecoveredReasonForComment(fullName);
    if (reason.length > 0) return reason;
    return ApolloDeletedCommentsRecoveredReasonForCommentBody(comment.author, comment.body);
}

static BOOL ApolloDeletedCommentsCellNodeIsRecovered(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsRecoveredReasonForComment(fullName).length > 0;
}

static BOOL ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsDeletedPlaceholder(fullName);
}

static BOOL ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(id cellNode) {
    return ApolloDeletedCommentsCellNodeIsRecovered(cellNode) ||
           ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode);
}

static BOOL ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsRecoveredComment(fullName) ||
           ApolloDeletedCommentsIsRecoveredCommentBody(comment.author, comment.body);
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
    NSString *normalized = ApolloDeletedCommentsNormalizedReasonLabel(ApolloDeletedCommentsTrimmedString(text));
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
    BOOL currentBodyMatches = ApolloDeletedCommentsTextQualifiesAsBodyCandidate(currentBody, archivedBody) ||
                              ApolloDeletedCommentsTextQualifiesAsBodyFragment(currentBody, archivedBody);
    return authorLooksDeleted || currentLooksPlaceholder || !currentBodyMatches;
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
    if (ApolloDeletedCommentsIsCommentRevealed(fullName)) return YES;
    NSString *originalBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    NSString *bodyForRevealKey = [originalBody isKindOfClass:[NSString class]] && originalBody.length > 0 ? originalBody : comment.body;
    return ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, bodyForRevealKey);
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
        ApolloDeletedCommentsRememberOriginalModelBodyIfNeeded(comment);
        ApolloDeletedCommentsRestoreOriginalModelBodyIfNeeded(comment);
    }
}

static NSString *ApolloDeletedCommentsReasonLabelForCommentAndBody(RDKComment *comment, NSString *body) {
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *reason = ApolloDeletedCommentsRecoveredReasonForComment(fullName);
    if (reason.length == 0) reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName);
    if (reason.length == 0) reason = ApolloDeletedCommentsRecoveredReasonForCommentBody(comment.author, body);
    NSString *label = ApolloDeletedCommentsDisplayLabelForReason(reason);
    return ApolloDeletedCommentsNormalizedReasonLabel(label);
}

static NSString *__attribute__((unused)) ApolloDeletedCommentsHiddenReasonLabelForCommentBody(RDKComment *comment, NSString *body) {
    if (!sShowDeletedComments || !comment) return nil;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *savedBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    NSString *bodyForState = [savedBody isKindOfClass:[NSString class]] && savedBody.length > 0 ? savedBody : body;
    BOOL placeholder = ApolloDeletedCommentsIsDeletedPlaceholder(fullName);
    BOOL recovered = ApolloDeletedCommentsIsRecoveredComment(fullName) ||
                     ApolloDeletedCommentsIsRecoveredCommentBody(comment.author, bodyForState);
    BOOL placeholderOnly = placeholder && !recovered;
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, bodyForState);

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
            if (!type || type[0] != '@') continue;
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
    (void)baseAttributes;
    label = ApolloDeletedCommentsNormalizedReasonLabel(label);
    UIFont *font = ApolloDeletedCommentsReasonChipFont();
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
    return result;
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

static NSAttributedString *ApolloDeletedCommentsPlaceholderAttributedText(NSAttributedString *original, NSString *reasonLabel) {
    NSDictionary *attributes = @{};
    if ([original isKindOfClass:[NSAttributedString class]] && original.length > 0) {
        attributes = [original attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    }

    NSAttributedString *chip = ApolloDeletedCommentsReasonChipAttributedText(reasonLabel, attributes, YES);
    return chip;
}

static NSMutableDictionary *ApolloDeletedCommentsDefaultBodyAttributes(void) {
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

static NSMutableDictionary *ApolloDeletedCommentsSanitizedBodyAttributes(NSDictionary *attrs) {
    UIFont *font = attrs[NSFontAttributeName];
    if (![font isKindOfClass:[UIFont class]]) return nil;

    NSMutableDictionary *attributes = [attrs mutableCopy];
    attributes[NSFontAttributeName] = ApolloDeletedCommentsRecoveredBodyFont();
    [attributes removeObjectForKey:NSAttachmentAttributeName];
    [attributes removeObjectForKey:NSBackgroundColorAttributeName];
    [attributes removeObjectForKey:NSLinkAttributeName];
    [attributes removeObjectForKey:ApolloDeletedCommentsRevealAttributeName];
    [attributes removeObjectForKey:ApolloDeletedCommentsReasonPrefixAttributeName];
    return attributes;
}

static NSAttributedString *ApolloDeletedCommentsBodyAttributedText(NSAttributedString *templateText, NSString *body) {
    __block NSMutableDictionary *attributes = nil;
    if ([templateText isKindOfClass:[NSAttributedString class]] && templateText.length > 0) {
        [templateText enumerateAttributesInRange:NSMakeRange(0, templateText.length)
                                         options:0
                                      usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
            if (attrs[NSAttachmentAttributeName]) return;
            attributes = ApolloDeletedCommentsSanitizedBodyAttributes(attrs);
            if (!attributes) return;
            *stop = YES;
        }];
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
    [normalized enumerateAttributesInRange:fullRange
                                   options:0
                                usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, NSRange range, __unused BOOL *stop) {
        if (attrs[NSAttachmentAttributeName]) return;
        [normalized addAttribute:NSFontAttributeName value:ApolloDeletedCommentsRecoveredBodyFont() range:range];
    }];
    return normalized;
}

static NSAttributedString *ApolloDeletedCommentsRecoveredBodyTextForDisplay(NSAttributedString *templateText, NSString *body) {
    if ([templateText isKindOfClass:[NSAttributedString class]] &&
        templateText.length > 0 &&
        !ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(templateText) &&
        !ApolloDeletedCommentsAttributedTextHasReasonPrefix(templateText) &&
        (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(templateText.string, body) ||
         ApolloDeletedCommentsTextQualifiesAsBodyFragment(templateText.string, body))) {
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
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    trimmed = [regex stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@" "];

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
        if (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body)) return known;
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
        if (!ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body)) continue;
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
            ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body) ||
            ApolloDeletedCommentsTextQualifiesAsBodyFragment(text.string, body)) {
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
        if (!ApolloDeletedCommentsTextQualifiesAsBodyCandidate(text.string, body) &&
            !ApolloDeletedCommentsTextQualifiesAsBodyFragment(text.string, body)) {
            continue;
        }
        [bodyNodes addObject:candidate];
        [seen addObject:candidate];
    }
    return bodyNodes;
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

    __block BOOL hasAttachmentChip = NO;
    [attributedText enumerateAttributesInRange:NSMakeRange(0, attributedText.length)
                                       options:0
                                    usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
        id prefix = attrs[ApolloDeletedCommentsReasonPrefixAttributeName];
        NSTextAttachment *attachment = [attrs[NSAttachmentAttributeName] isKindOfClass:[NSTextAttachment class]] ? attrs[NSAttachmentAttributeName] : nil;
        if ([prefix respondsToSelector:@selector(boolValue)] && [prefix boolValue] && [attachment.image isKindOfClass:[UIImage class]]) {
            hasAttachmentChip = YES;
            *stop = YES;
        }
    }];
    if (hasAttachmentChip) return YES;

    NSString *upperText = ApolloDeletedCommentsTrimmedString(attributedText.string).uppercaseString;
    return [upperText containsString:@"REMOVED BY MOD"] ||
           [upperText containsString:@"DELETED BY USER"];
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
    if (!sShowDeletedComments || !sTapToRevealDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(attributedText)) return attributedText;

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode)) return attributedText;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, comment.body);
    if (revealed) return attributedText;

    BOOL bodyCandidate = ApolloDeletedCommentsTextQualifiesAsBodyCandidate(attributedText.string, comment.body) ||
                         ApolloDeletedCommentsTextQualifiesAsBodyFragment(attributedText.string, comment.body);
    if (!bodyCandidate) return attributedText;

    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [attributedText copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        ApolloDeletedCommentsRememberHiddenTextNode(cellNode, textNode);
    }

    NSDictionary *attributes = [attributedText attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    if (ApolloDeletedCommentsCellAlreadyHasHiddenPlaceholder(cellNode, fullName) &&
        objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey) != textNode) {
        return [[NSAttributedString alloc] initWithString:@"" attributes:attributes];
    }

    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(attributedText, ApolloDeletedCommentsReasonLabelForComment(comment));
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    return placeholder;
}

static NSAttributedString *ApolloDeletedCommentsAttributedTextWithReasonPrefix(id textNode, NSAttributedString *attributedText) {
    if (!sShowDeletedComments) return attributedText;
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
    NSString *bodyForCompare = [originalBody isKindOfClass:[NSString class]] && originalBody.length > 0 ? originalBody : comment.body;
    NSAttributedString *bodySourceText = ApolloDeletedCommentsAttributedTextByRemovingTrailingReasonLabel(attributedText, label);
    BOOL bodyCandidate = ApolloDeletedCommentsTextQualifiesAsBodyCandidate(bodySourceText.string, bodyForCompare) ||
                         ApolloDeletedCommentsTextQualifiesAsBodyFragment(bodySourceText.string, bodyForCompare);
    if (!bodyCandidate) return attributedText;

    NSAttributedString *bodyText = ApolloDeletedCommentsRecoveredBodyTextForDisplay(bodySourceText, bodyForCompare);
    NSDictionary *baseAttributes = bodyText.length > 0 ? ([bodyText attributesAtIndex:0 effectiveRange:NULL] ?: @{}) : @{};
    NSMutableDictionary *spacerAttributes = [baseAttributes mutableCopy];
    NSMutableParagraphStyle *spacerStyle = [NSMutableParagraphStyle new];
    spacerStyle.minimumLineHeight = 20.0;
    spacerStyle.maximumLineHeight = 20.0;
    spacerAttributes[NSParagraphStyleAttributeName] = spacerStyle;
    NSMutableAttributedString *decorated = [bodyText mutableCopy];
    [decorated appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:spacerAttributes]];
    [decorated appendAttributedString:ApolloDeletedCommentsReasonChipAttributedText(label, baseAttributes, sTapToRevealDeletedComments && revealed)];
    if (sTapToRevealDeletedComments && revealed) ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    return decorated;
}

static NSAttributedString *ApolloDeletedCommentsAttributedTextWithReasonChipIfNeeded(id textNode, NSAttributedString *attributedText) {
    if (!sShowDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return attributedText;

    NSString *label = ApolloDeletedCommentsReasonLabelForComment(comment);
    NSString *text = ApolloDeletedCommentsNormalizedReasonLabel(ApolloDeletedCommentsTrimmedString(attributedText.string));
    if (![text isEqualToString:label]) return attributedText;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL placeholderOnly = ApolloDeletedCommentsIsDeletedPlaceholder(fullName) &&
                           !ApolloDeletedCommentsIsRecoveredComment(fullName);
    BOOL revealed = ApolloDeletedCommentsCommentIsRevealedByFullName(comment);
    BOOL revealLink = sTapToRevealDeletedComments &&
                      ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode) &&
                      !placeholderOnly &&
                      !revealed;

    NSAttributedString *chip = ApolloDeletedCommentsReasonChipAttributedText(label,
                                                                             [attributedText attributesAtIndex:0 effectiveRange:NULL] ?: @{},
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
            replacement = ApolloDeletedCommentsPlaceholderAttributedText(original, ApolloDeletedCommentsReasonLabelForComment(comment));
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

    NSAttributedString *current = ApolloDeletedCommentsCurrentAttributedText(textNode);
    NSAttributedString *original = nil;
    if ([current isKindOfClass:[NSAttributedString class]] &&
        current.length > 0 &&
        !ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current) &&
        !ApolloDeletedCommentsAttributedTextHasReasonPrefix(current) &&
        (ApolloDeletedCommentsTextQualifiesAsBodyCandidate(current.string, comment.body) ||
         ApolloDeletedCommentsTextQualifiesAsBodyFragment(current.string, comment.body))) {
        original = [current copy];
    } else {
        original = ApolloDeletedCommentsBodyAttributedText(current, comment.body);
    }
    if (![original isKindOfClass:[NSAttributedString class]] || original.length == 0) return NO;

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, @[textNode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(original, ApolloDeletedCommentsReasonLabelForComment(comment));
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
                                                                        [current attributesAtIndex:0 effectiveRange:NULL] ?: @{},
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

static void ApolloDeletedCommentsEnsureRevealAttributeIsTappable(id textNode) {
    if (!textNode) return;

    if ([textNode respondsToSelector:@selector(setUserInteractionEnabled:)]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(textNode, @selector(setUserInteractionEnabled:), YES);
        } @catch (__unused NSException *e) {}
    }

    if ([textNode respondsToSelector:@selector(view)]) {
        @try {
            UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(textNode, @selector(view));
            if ([view isKindOfClass:[UIView class]]) view.userInteractionEnabled = YES;
        } @catch (__unused NSException *e) {}
    }

    if (![textNode respondsToSelector:@selector(setLinkAttributeNames:)]) return;

    NSMutableSet *names = [NSMutableSet setWithObjects:NSLinkAttributeName, ApolloDeletedCommentsRevealAttributeName, nil];
    if ([textNode respondsToSelector:@selector(linkAttributeNames)]) {
        @try {
            id existing = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(linkAttributeNames));
            if ([existing isKindOfClass:[NSArray class]]) {
                [names addObjectsFromArray:(NSArray *)existing];
            } else if ([existing isKindOfClass:[NSSet class]]) {
                [names unionSet:(NSSet *)existing];
            }
        } @catch (__unused NSException *e) {}
    }

    NSArray *orderedNames = names.allObjects;
    @try {
        ((void (*)(id, SEL, NSArray *))objc_msgSend)(textNode, @selector(setLinkAttributeNames:), orderedNames);
    } @catch (__unused NSException *e) {}
}

static void __attribute__((unused)) ApolloDeletedCommentsApplyTapToRevealIfNeeded(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    NSString *author = comment.author;
    NSString *body = comment.body;

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
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(author, body);
    BOOL shouldHide = sShowDeletedComments &&
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
        return;
    }

    BOOL alreadyHiddenForComment = NO;
    for (id textNode in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        NSString *hiddenFullName = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey);
        NSAttributedString *existingOriginal = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
        if ([hiddenFullName isEqualToString:fullName] && [existingOriginal isKindOfClass:[NSAttributedString class]]) {
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

        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [hiddenNodes addObject:textNode];

        NSAttributedString *replacement = nil;
        if (!placedPlaceholder) {
            replacement = ApolloDeletedCommentsPlaceholderAttributedText(current, ApolloDeletedCommentsReasonLabelForComment(comment));
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

    NSAttributedString *templateText = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    if (![templateText isKindOfClass:[NSAttributedString class]] || templateText.length == 0) {
        templateText = ApolloDeletedCommentsCurrentAttributedText(textNode);
    }
    NSAttributedString *bodyText = ApolloDeletedCommentsRecoveredBodyTextForDisplay(templateText, comment.body);
    bodyText = ApolloDeletedCommentsAttributedTextWithReasonPrefix(textNode, bodyText);
    if (bodyText.length == 0) return;

    ApolloDeletedCommentsSetTextNodeAttributedText(textNode, bodyText);
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
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
    if (!restored && ApolloDeletedCommentsStringIsReasonLabel(comment.body)) return;

    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    NSString *originalBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    NSString *bodyForRevealKey = [originalBody isKindOfClass:[NSString class]] && originalBody.length > 0 ? originalBody : comment.body;
    ApolloDeletedCommentsMarkCommentBodyRevealed(comment.author, bodyForRevealKey);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsRestoreOriginalModelBodyIfNeeded(comment);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    (void)tappedTextNode;
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyTextNode(cellNode));
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsCommentIsRevealed(RDKComment *comment) {
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsCommentRevealed(fullName) ||
           ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, comment.body);
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
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    ApolloDeletedCommentsUnmarkCommentRevealed(fullName);
    NSString *originalBody = objc_getAssociatedObject(comment, kApolloDeletedCommentsOriginalBodyKey);
    NSString *bodyForRevealKey = [originalBody isKindOfClass:[NSString class]] && originalBody.length > 0 ? originalBody : comment.body;
    ApolloDeletedCommentsUnmarkCommentBodyRevealed(comment.author, bodyForRevealKey);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);
    (void)tappedTextNode;
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyContainerNode(cellNode));
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, ApolloDeletedCommentsKnownBodyTextNode(cellNode));
}

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;
    id current = textNode;
    for (NSUInteger i = 0; current && i < 10; i++) {
        id ownerCell = objc_getAssociatedObject(current, kApolloDeletedCommentsBodyOwnerCellKey);
        if (ownerCell) return ownerCell;
        const char *className = class_getName(object_getClass(current));
        if (className && strstr(className, "CommentCellNode")) return current;
        if (![current respondsToSelector:@selector(supernode)]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, @selector(supernode));
        } @catch (__unused NSException *e) {
            break;
        }
    }
    return nil;
}

static BOOL __attribute__((unused)) ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(id textNode) {
    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    return ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode);
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
    if (!cellNode || !sShowDeletedComments || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;

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
    if (!sShowDeletedComments || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) {
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

static void ApolloDeletedCommentsSetTextNodeAttributedText(id textNode, NSAttributedString *attributedText) {
    if (!textNode || ![attributedText isKindOfClass:[NSAttributedString class]]) return;
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
    UIColor *fallbackTextColor = nil;
    if (@available(iOS 13.0, *)) {
        fallbackTextColor = [UIColor labelColor];
    }
    if (!fallbackTextColor) fallbackTextColor = [UIColor blackColor];
    return [[NSAttributedString alloc] initWithString:@" " attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:16.0],
        NSForegroundColorAttributeName: fallbackTextColor,
    }];
}

static id __attribute__((unused)) ApolloDeletedCommentsDeletedMarkdownLayoutSpecIfNeeded(id markdownNode) {
    id cellNode = objc_getAssociatedObject(markdownNode, kApolloDeletedCommentsBodyOwnerCellKey);
    if (!cellNode) cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(markdownNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return nil;

    id textNode = ApolloDeletedCommentsBodyReplacementTextNode(markdownNode, cellNode);
    if (!textNode) return nil;

    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL placeholderOnly = ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode) &&
                           !ApolloDeletedCommentsCellNodeIsRecovered(cellNode);
    BOOL recovered = ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, comment.body);
    BOOL shouldHide = sShowDeletedComments &&
                      sTapToRevealDeletedComments &&
                      recovered &&
                      !revealed;

    NSAttributedString *templateText = ApolloDeletedCommentsTemplateTextForMarkdownNode(markdownNode);
    NSAttributedString *displayText = nil;
    if (placeholderOnly || shouldHide) {
        NSAttributedString *original = ApolloDeletedCommentsBodyAttributedText(templateText, comment.body);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, @[textNode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        displayText = placeholderOnly
            ? ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment),
                                                            [templateText attributesAtIndex:0 effectiveRange:NULL] ?: @{},
                                                            NO)
            : ApolloDeletedCommentsPlaceholderAttributedText(templateText, ApolloDeletedCommentsReasonLabelForComment(comment));
    } else {
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        displayText = ApolloDeletedCommentsBodyAttributedText(templateText, comment.body);
        if (!sTapToRevealDeletedComments) {
            NSDictionary *baseAttributes = displayText.length > 0 ? ([displayText attributesAtIndex:0 effectiveRange:NULL] ?: @{}) : @{};
            NSMutableDictionary *spacerAttributes = [baseAttributes mutableCopy];
            NSMutableParagraphStyle *spacerStyle = [NSMutableParagraphStyle new];
            spacerStyle.minimumLineHeight = 20.0;
            spacerStyle.maximumLineHeight = 20.0;
            spacerAttributes[NSParagraphStyleAttributeName] = spacerStyle;
            NSMutableAttributedString *decorated = [displayText mutableCopy];
            [decorated appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:spacerAttributes]];
            [decorated appendAttributedString:ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment), baseAttributes, NO)];
            displayText = decorated;
        }
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
    if (!sShowDeletedComments) return;
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
    if (!sShowDeletedComments) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return;
    if (sTapToRevealDeletedComments && !ApolloDeletedCommentsCommentIsRevealedByFullName(comment)) return;

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
        if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) {
            NSAttributedString *bodyText = ApolloDeletedCommentsBodyAttributedText(current, comment.body);
            if (bodyText.length == 0) continue;
            NSAttributedString *repaired = ApolloDeletedCommentsAttributedTextWithReasonPrefix(textNode, bodyText);
            ApolloDeletedCommentsSetTextNodeAttributedText(textNode, repaired);
            ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
            return;
        }
        if (ApolloDeletedCommentsAttributedTextHasVisibleReasonChip(current)) return;

        NSAttributedString *bodySource = current;
        if (ApolloDeletedCommentsAttributedTextHasReasonPrefix(current)) {
            bodySource = ApolloDeletedCommentsAttributedTextByRemovingReasonPrefix(current);
            if (![bodySource isKindOfClass:[NSAttributedString class]] || bodySource.length == 0) {
                bodySource = ApolloDeletedCommentsBodyAttributedText(current, comment.body);
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

static void ApolloDeletedCommentsUpdateCell(id cellNode) {
    ApolloDeletedCommentsTrackVisibleDeletedCommentCell(cellNode);
    ApolloDeletedCommentsApplyCachedArchiveToVisibleDeletedCell(cellNode);
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState(cellNode);
    ApolloDeletedCommentsRepairVisibleReasonChipIfNeeded(cellNode);
    ApolloDeletedCommentsApplyCellHighlight(cellNode);
}

static void ApolloDeletedCommentsRefreshVisibleDeletedCells(void) {
    if (!sShowDeletedComments) return;
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

static NSAttributedString *ApolloDeletedCommentsRenameRecoveredSpoilerLabel(id textNode, NSAttributedString *attributedText) {
    if (!sShowDeletedComments || !sTapToRevealDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    NSString *text = ApolloDeletedCommentsTrimmedString(attributedText.string);
    if (![text isEqualToString:@"SPOILER"]) return attributedText;
    if (!ApolloDeletedCommentsTextNodeBelongsToRecoveredComment(textNode)) return attributedText;

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSDictionary *baseAttributes = [attributedText attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL placeholderOnly = ApolloDeletedCommentsIsDeletedPlaceholder(fullName) &&
                           !ApolloDeletedCommentsIsRecoveredComment(fullName);
    if (placeholderOnly) {
        return ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment), baseAttributes, NO);
    }

    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, comment.body);
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

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *renamedText = ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText);
    NSAttributedString *chipText = ApolloDeletedCommentsAttributedTextWithReasonChipIfNeeded((id)self, renamedText);
    NSAttributedString *rewrittenText = ApolloDeletedCommentsAttributedTextWithReasonPrefix((id)self, chipText);
    %orig(rewrittenText);
}

- (void)didEnterDisplayState {
    %orig;
    NSAttributedString *attributedText = nil;
    @try {
        attributedText = ((NSAttributedString *(*)(id, SEL))objc_msgSend)((id)self, @selector(attributedText));
    } @catch (__unused NSException *e) {
        attributedText = nil;
    }
    NSAttributedString *renamedAttributedText = ApolloDeletedCommentsAttributedTextWithReasonChipIfNeeded((id)self,
        ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText)
    );
    if (renamedAttributedText != attributedText) {
        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)((id)self, @selector(setAttributedText:), renamedAttributedText);
            attributedText = renamedAttributedText;
        } @catch (__unused NSException *e) {}
    }
    NSAttributedString *prefixedText = ApolloDeletedCommentsAttributedTextWithReasonPrefix((id)self, attributedText);
    if (prefixedText != attributedText) {
        @try {
            ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)((id)self, @selector(setAttributedText:), prefixedText);
        } @catch (__unused NSException *e) {}
    }
}

%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloDeletedCommentsArcticCacheUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        ApolloDeletedCommentsHandleArcticCacheUpdated(notification);
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
    ApolloDeletedCommentsUpdateCell((id)self);
}

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)fits {
    ApolloDeletedCommentsSynchronizeCommentModelDisplayState((id)self);
    id bodyNode = ApolloDeletedCommentsKnownBodyContainerNode((id)self);
    if (bodyNode) {
        objc_setAssociatedObject(bodyNode, kApolloDeletedCommentsBodyOwnerCellKey, (id)self, OBJC_ASSOCIATION_ASSIGN);
    }
    id spec = %orig;
    if (sShowDeletedComments && ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment((id)self) && spec) {
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return %orig;
}

%end

%hook RDKComment

- (NSString *)body {
    NSString *body = %orig;
    NSString *savedBody = objc_getAssociatedObject((id)self, kApolloDeletedCommentsOriginalBodyKey);
    if ([savedBody isKindOfClass:[NSString class]] && savedBody.length > 0 && ApolloDeletedCommentsStringIsReasonLabel(body)) {
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
        return savedBodyHTML;
    }
    return bodyHTML;
}

- (void)setCollapsed:(BOOL)collapsed {
    if (collapsed && [objc_getAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey) boolValue]) {
        objc_setAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
    if (!collapsed) {
        ApolloDeletedCommentsScheduleVisibleCellRefreshForComment((RDKComment *)self);
    }
}

%end

%hook _TtC6Apollo12MarkdownNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)fits {
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
        RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
        if (ApolloDeletedCommentsCommentIsRevealedByFullName(comment)) {
            ApolloDeletedCommentsHideRevealedBodyForCell(cellNode, textNode);
        } else {
            ApolloDeletedCommentsRevealHiddenBodyForCell(cellNode, textNode);
        }
        return;
    }
    %orig(textNode, attribute, value, point, range);
}

%end
