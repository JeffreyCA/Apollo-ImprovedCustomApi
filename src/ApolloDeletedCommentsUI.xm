#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloDeletedCommentsData.h"
#import "ApolloState.h"
#import "Tweak.h"

static const void *kApolloDeletedCommentsHighlightViewKey = &kApolloDeletedCommentsHighlightViewKey;
static const void *kApolloDeletedCommentsHiddenOriginalTextKey = &kApolloDeletedCommentsHiddenOriginalTextKey;
static const void *kApolloDeletedCommentsHiddenFullNameKey = &kApolloDeletedCommentsHiddenFullNameKey;
static const void *kApolloDeletedCommentsHiddenTextNodeKey = &kApolloDeletedCommentsHiddenTextNodeKey;
static const void *kApolloDeletedCommentsHiddenTextNodesKey = &kApolloDeletedCommentsHiddenTextNodesKey;
static const void *kApolloDeletedCommentsSuppressNextCollapseKey = &kApolloDeletedCommentsSuppressNextCollapseKey;

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

static UIColor *ApolloDeletedCommentsHighlightColor(void) {
    return [ApolloDeletedCommentsBadgeRed() colorWithAlphaComponent:0.24];
}

static UIColor *ApolloDeletedCommentsChipBackgroundColor(void) {
    return [UIColor colorWithRed:1.0 green:0.66 blue:0.64 alpha:1.0];
}

static UIColor *ApolloDeletedCommentsChipTextColor(void) {
    return [UIColor colorWithRed:0.42 green:0.06 blue:0.06 alpha:1.0];
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

static NSString *ApolloDeletedCommentsNormalizedReasonLabel(NSString *label) {
    if (![label isKindOfClass:[NSString class]] || label.length == 0) return @"REMOVED BY MOD";
    if ([label isEqualToString:@"DELETED BY MOD"]) return @"REMOVED BY MOD";
    return label;
}

static UIImage *ApolloDeletedCommentsReasonChipImage(NSString *text, UIFont *font) {
    text = ApolloDeletedCommentsNormalizedReasonLabel(text);
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (![font isKindOfClass:[UIFont class]]) font = [UIFont boldSystemFontOfSize:15.0];

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
    UIFont *font = baseAttributes[NSFontAttributeName];
    if (![font isKindOfClass:[UIFont class]]) {
        font = [UIFont boldSystemFontOfSize:15.0];
    } else {
        font = [UIFont boldSystemFontOfSize:MAX(12.0, font.pointSize - 2.5)];
    }

    UIImage *image = ApolloDeletedCommentsReasonChipImage(label, font);
    CGFloat chipLineHeight = [image isKindOfClass:[UIImage class]] ? image.size.height + 2.0 : font.lineHeight + 2.0;
    NSMutableParagraphStyle *paragraphStyle = [NSMutableParagraphStyle new];
    paragraphStyle.lineSpacing = 0.0;
    paragraphStyle.paragraphSpacing = 4.0;
    paragraphStyle.minimumLineHeight = ceil(chipLineHeight);
    paragraphStyle.maximumLineHeight = ceil(chipLineHeight);

    NSMutableAttributedString *result = nil;
    if ([image isKindOfClass:[UIImage class]]) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        attachment.image = image;
        attachment.bounds = CGRectMake(0.0, -2.0, image.size.width, image.size.height);
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
    for (Class cls = [commentCellNode class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; candidateNames[i]; i++) {
            Ivar ivar = class_getInstanceVariable(cls, candidateNames[i]);
            if (!ivar) continue;
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;
            id node = nil;
            @try {
                node = object_getIvar(commentCellNode, ivar);
            } @catch (__unused NSException *e) {
                node = nil;
            }
            if (node && [node respondsToSelector:@selector(attributedText)] && [node respondsToSelector:@selector(setAttributedText:)]) {
                return node;
            }
        }
    }
    return nil;
}

static void ApolloDeletedCommentsRelayoutCellAndTextNode(id cellNode, id textNode) {
    SEL selectors[] = {
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

static NSAttributedString *ApolloDeletedCommentsPlaceholderAttributedText(NSAttributedString *original, NSString *reasonLabel) {
    NSDictionary *attributes = @{};
    if ([original isKindOfClass:[NSAttributedString class]] && original.length > 0) {
        attributes = [original attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    }

    NSAttributedString *chip = ApolloDeletedCommentsReasonChipAttributedText(reasonLabel, attributes, YES);
    return chip;
}

static NSAttributedString *ApolloDeletedCommentsBodyAttributedText(NSAttributedString *templateText, NSString *body) {
    NSDictionary *attributes = @{};
    if ([templateText isKindOfClass:[NSAttributedString class]] && templateText.length > 0) {
        attributes = [templateText attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    }
    return [[NSAttributedString alloc] initWithString:body ?: @"" attributes:attributes];
}

static NSObject *ApolloDeletedCommentsVisibleCellsLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sApolloDeletedCommentsVisibleCellsLock = [NSObject new];
    });
    return sApolloDeletedCommentsVisibleCellsLock;
}

static void ApolloDeletedCommentsTrackVisiblePlaceholderCell(id cellNode) {
    if (!cellNode) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;
    if (!ApolloDeletedCommentsIsDeletedPlaceholder(fullName) || ApolloDeletedCommentsIsRecoveredComment(fullName)) return;

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

static NSAttributedString *ApolloDeletedCommentsAttributedTextWithTapToRevealPlaceholder(id textNode, NSAttributedString *attributedText) {
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
    if (sTapToRevealDeletedComments) return attributedText;
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return attributedText;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(attributedText) ||
        ApolloDeletedCommentsAttributedTextHasReasonPrefix(attributedText)) {
        return attributedText;
    }

    id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment || !ApolloDeletedCommentsCellNodeShouldShowDeletedTreatment(cellNode)) return attributedText;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(comment.author, comment.body);
    if (sTapToRevealDeletedComments && !revealed) return attributedText;
    id bodyTextNode = ApolloDeletedCommentsBestBodyTextNode(cellNode, comment);
    if (bodyTextNode && bodyTextNode != textNode) return attributedText;
    if (!ApolloDeletedCommentsTextQualifiesAsBodyCandidate(attributedText.string, comment.body)) return attributedText;

    NSDictionary *baseAttributes = [attributedText attributesAtIndex:0 effectiveRange:NULL] ?: @{};
    NSString *label = ApolloDeletedCommentsReasonLabelForComment(comment);
    NSMutableAttributedString *prefixed = [[NSMutableAttributedString alloc] init];
    [prefixed appendAttributedString:ApolloDeletedCommentsReasonChipAttributedText(label, baseAttributes, NO)];
    [prefixed appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:baseAttributes]];
    [prefixed appendAttributedString:attributedText];
    return prefixed;
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

static void ApolloDeletedCommentsRefreshHiddenPlaceholderForCell(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return;

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
    NSArray *textNodes = ApolloDeletedCommentsBodyTextNodes(cellNode, comment);
    if (textNodes.count == 0) return;

    BOOL placeholderOnly = ApolloDeletedCommentsCellNodeIsDeletedPlaceholder(cellNode) &&
                           !ApolloDeletedCommentsCellNodeIsRecovered(cellNode);
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
        ApolloDeletedCommentsRefreshHiddenPlaceholderForCell(cellNode);
        return;
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

    if (hiddenNodes.count == 0) return;
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

static void __attribute__((unused)) ApolloDeletedCommentsRevealHiddenBodyForCell(id cellNode) {
    BOOL hasHiddenBody = NO;
    for (id textNode in ApolloDeletedCommentsHiddenTextNodesForCell(cellNode)) {
        if (objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
            hasHiddenBody = YES;
            break;
        }
    }
    if (!hasHiddenBody) return;

    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);

    if (ApolloDeletedCommentsIsDeletedPlaceholder(fullName) && !ApolloDeletedCommentsIsRecoveredComment(fullName)) {
        ApolloDeletedCommentsRefreshHiddenPlaceholderForCell(cellNode);
        return;
    }

    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    ApolloDeletedCommentsMarkCommentBodyRevealed(comment.author, comment.body);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsRestoreHiddenBodiesIfNeeded(cellNode, nil);
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

static void __attribute__((unused)) ApolloDeletedCommentsHideRevealedBodyForCell(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    ApolloDeletedCommentsUnmarkCommentRevealed(fullName);
    ApolloDeletedCommentsUnmarkCommentBodyRevealed(comment.author, comment.body);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsApplyTapToRevealIfNeeded(cellNode);
}

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode) {
    if (!textNode || ![textNode respondsToSelector:@selector(supernode)]) return nil;
    id current = textNode;
    for (NSUInteger i = 0; current && i < 10; i++) {
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
        highlight.backgroundColor = ApolloDeletedCommentsHighlightColor();
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHighlightViewKey, highlight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

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
    if (!ApolloDeletedCommentsIsDeletedPlaceholder(fullName) || ApolloDeletedCommentsIsRecoveredComment(fullName)) return;

    NSArray *textNodes = ApolloDeletedCommentsBodyTextNodes(cellNode, comment);
    if (textNodes.count == 0) {
        id knownBodyNode = ApolloDeletedCommentsKnownBodyTextNode(cellNode);
        if (knownBodyNode) textNodes = @[knownBodyNode];
    }
    if (textNodes.count == 0) return;
    id firstTextNode = textNodes.firstObject;
    NSAttributedString *templateText = ApolloDeletedCommentsCurrentAttributedText(firstTextNode);

    NSString *reason = ApolloDeletedCommentsDeletedPlaceholderReason(fullName);
    if (!ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject((id)comment, archived, reason)) return;

    for (id textNode in textNodes) {
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *bodyText = ApolloDeletedCommentsBodyAttributedText(templateText, comment.body);
    if (!sTapToRevealDeletedComments) {
        bodyText = ApolloDeletedCommentsAttributedTextWithReasonPrefix(firstTextNode, bodyText);
    }
    ApolloDeletedCommentsSetTextNodeAttributedText(firstTextNode, bodyText);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, firstTextNode);

    NSDictionary *blankAttributes = bodyText.length > 0 ? ([bodyText attributesAtIndex:0 effectiveRange:NULL] ?: @{}) : @{};
    for (NSUInteger i = 1; i < textNodes.count; i++) {
        id textNode = textNodes[i];
        ApolloDeletedCommentsSetTextNodeAttributedText(textNode, [[NSAttributedString alloc] initWithString:@"" attributes:blankAttributes]);
        ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
    }

    ApolloDeletedCommentsApplyTapToRevealIfNeeded(cellNode);
    ApolloDeletedCommentsApplyCellHighlight(cellNode);
}

static void ApolloDeletedCommentsHandleArcticCacheUpdated(NSNotification *notification) {
    if (!sShowDeletedComments) return;
    NSDictionary *comments = [notification.userInfo[@"comments"] isKindOfClass:[NSDictionary class]] ? notification.userInfo[@"comments"] : nil;
    if (comments.count == 0) return;

    for (NSString *fullName in comments) {
        NSDictionary *archived = [comments[fullName] isKindOfClass:[NSDictionary class]] ? comments[fullName] : nil;
        if (![archived isKindOfClass:[NSDictionary class]]) continue;
        for (id cellNode in ApolloDeletedCommentsTrackedCellsForFullName(fullName)) {
            ApolloDeletedCommentsApplyRecoveredArchiveToVisibleCell(cellNode, archived);
        }
    }
}

static void ApolloDeletedCommentsApplyCachedArchiveToVisiblePlaceholderCell(id cellNode) {
    if (!cellNode) return;
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    if (fullName.length == 0) return;
    if (!ApolloDeletedCommentsIsDeletedPlaceholder(fullName) || ApolloDeletedCommentsIsRecoveredComment(fullName)) return;

    NSDictionary *archived = ApolloDeletedCommentsCachedArchivedComment(fullName);
    if (archived.count == 0) return;
    ApolloDeletedCommentsApplyRecoveredArchiveToVisibleCell(cellNode, archived);
}

static void ApolloDeletedCommentsUpdateCell(id cellNode) {
    ApolloDeletedCommentsTrackVisiblePlaceholderCell(cellNode);
    ApolloDeletedCommentsApplyCachedArchiveToVisiblePlaceholderCell(cellNode);
    ApolloDeletedCommentsApplyTapToRevealIfNeeded(cellNode);
    ApolloDeletedCommentsApplyCellHighlight(cellNode);
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
        NSString *body = ApolloDeletedCommentsUnwrappedSpoilerMarkdown(comment.body);
        NSAttributedString *original = ApolloDeletedCommentsBodyAttributedText(attributedText, body);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodesKey, @[textNode], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    }
    return renamed;
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *rewrittenText = ApolloDeletedCommentsAttributedTextWithReasonPrefix((id)self,
        ApolloDeletedCommentsAttributedTextWithTapToRevealPlaceholder((id)self,
            ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText)
        )
    );
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
    NSAttributedString *renamedAttributedText = ApolloDeletedCommentsAttributedTextWithTapToRevealPlaceholder((id)self,
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
}

@interface _TtC6Apollo15CommentCellNode
- (void)didLoad;
- (void)didEnterDisplayState;
- (void)calculatedLayoutDidChange;
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

- (void)layout {
    %orig;
    ApolloDeletedCommentsApplyCellHighlight((id)self);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return %orig;
}

%end

%hook RDKComment

- (void)setCollapsed:(BOOL)collapsed {
    if (collapsed && [objc_getAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey) boolValue]) {
        objc_setAssociatedObject((id)self, kApolloDeletedCommentsSuppressNextCollapseKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}

%end

%hook _TtC6Apollo12MarkdownNode

- (BOOL)textNode:(id)textNode shouldHighlightLinkAttribute:(id)attribute value:(id)value atPoint:(CGPoint)point {
    if (ApolloDeletedCommentsIsRevealLink(attribute, value) &&
        objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
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
    if (ApolloDeletedCommentsIsRevealLink(attribute, value) &&
        objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) {
        id cellNode = ApolloDeletedCommentsCommentCellNodeForTextNode(textNode);
        ApolloDeletedCommentsRevealHiddenBodyForCell(cellNode);
        return;
    }
    %orig(textNode, attribute, value, point, range);
}

%end
