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
static const void *kApolloDeletedCommentsSuppressNextCollapseKey = &kApolloDeletedCommentsSuppressNextCollapseKey;

static NSString *const ApolloDeletedCommentsRevealURLString = @"apollo-deleted-comments://reveal";
static NSString *const ApolloDeletedCommentsRevealAttributeName = @"ApolloDeletedCommentsRevealAttribute";
static NSString *const ApolloDeletedCommentsReasonPrefixAttributeName = @"ApolloDeletedCommentsReasonPrefixAttribute";

static id ApolloDeletedCommentsCommentCellNodeForTextNode(id textNode);

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
    return [ApolloDeletedCommentsBadgeRed() colorWithAlphaComponent:0.22];
}

static UIColor *ApolloDeletedCommentsChipBackgroundColor(void) {
    return [UIColor colorWithRed:1.0 green:0.78 blue:0.76 alpha:1.0];
}

static UIColor *ApolloDeletedCommentsChipTextColor(void) {
    return [UIColor colorWithRed:0.30 green:0.04 blue:0.04 alpha:1.0];
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

static BOOL ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return NO;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    return ApolloDeletedCommentsIsRecoveredComment(fullName) ||
           ApolloDeletedCommentsIsRecoveredCommentBody(comment.author, comment.body);
}

static NSString *ApolloDeletedCommentsReasonLabelForComment(RDKComment *comment) {
    NSString *reason = ApolloDeletedCommentsRecoveredReasonForCommentObject(comment);
    return ApolloDeletedCommentsDisplayLabelForReason(reason);
}

static UIImage *ApolloDeletedCommentsReasonChipImage(NSString *text, UIFont *font) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (![font isKindOfClass:[UIFont class]]) font = [UIFont boldSystemFontOfSize:15.0];

    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: ApolloDeletedCommentsChipTextColor(),
    };
    CGSize textSize = [text sizeWithAttributes:attributes];
    CGFloat horizontalPadding = 8.0;
    CGFloat verticalPadding = 2.0;
    CGSize imageSize = CGSizeMake(ceil(textSize.width + horizontalPadding * 2.0),
                                  ceil(textSize.height + verticalPadding * 2.0));

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:imageSize format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGRect bounds = CGRectMake(0.0, 0.0, imageSize.width, imageSize.height);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:7.0];
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
    return [regex stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@" "];
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
    if (!comment || !ApolloDeletedCommentsCellNodeIsRecovered(cellNode)) return attributedText;
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
    id textNode = ApolloDeletedCommentsBestBodyTextNode(cellNode, comment);
    if (!textNode) return;

    BOOL recovered = ApolloDeletedCommentsCellNodeCanRevealRecoveredBody(cellNode);
    BOOL revealed = ApolloDeletedCommentsIsCommentRevealed(fullName) ||
                    ApolloDeletedCommentsIsCommentBodyRevealed(author, body);
    BOOL shouldHide = sShowDeletedComments &&
                      sTapToRevealDeletedComments &&
                      recovered &&
                      !revealed;
    if (!shouldHide) {
        ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);
        return;
    }

    NSAttributedString *existingOriginal = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey);
    NSAttributedString *existingCurrent = nil;
    @try {
        existingCurrent = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        existingCurrent = nil;
    }
    if ([existingOriginal isKindOfClass:[NSAttributedString class]] &&
        ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(existingCurrent)) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
        return;
    }

    NSString *hiddenFullName = objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey);
    if ([hiddenFullName isEqualToString:fullName]) {
        ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
        return;
    }

    ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);

    NSAttributedString *current = nil;
    @try {
        current = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        current = nil;
    }
    if (![current isKindOfClass:[NSAttributedString class]] || current.length == 0) return;
    if (ApolloDeletedCommentsAttributedTextIsRevealPlaceholder(current)) return;

    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloDeletedCommentsHiddenFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSAttributedString *placeholder = ApolloDeletedCommentsPlaceholderAttributedText(current, ApolloDeletedCommentsReasonLabelForComment(comment));
    @try {
        ((void (*)(id, SEL, NSAttributedString *))objc_msgSend)(textNode, @selector(setAttributedText:), placeholder);
    } @catch (__unused NSException *e) {}
    ApolloDeletedCommentsEnsureRevealAttributeIsTappable(textNode);
    ApolloDeletedCommentsRelayoutCellAndTextNode(cellNode, textNode);
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
    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) return NO;
    return ApolloDeletedCommentsTouchHitsTextNode(textNode, touch);
}

static void __attribute__((unused)) ApolloDeletedCommentsRevealHiddenBodyForCell(id cellNode) {
    id textNode = objc_getAssociatedObject(cellNode, kApolloDeletedCommentsHiddenTextNodeKey);
    if (!objc_getAssociatedObject(textNode, kApolloDeletedCommentsHiddenOriginalTextKey)) return;

    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    ApolloDeletedCommentsMarkCommentRevealed(fullName);
    ApolloDeletedCommentsMarkCommentBodyRevealed(comment.author, comment.body);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsRestoreHiddenBodyIfNeeded(cellNode, textNode);
    ApolloDeletedCommentsScheduleForceExpanded(comment, cellNode);
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
    id textNode = ApolloDeletedCommentsBestBodyTextNode(cellNode, comment);
    return ApolloDeletedCommentsTouchHitsTextNode(textNode, touch);
}

static void __attribute__((unused)) ApolloDeletedCommentsHideRevealedBodyForCell(id cellNode) {
    RDKComment *comment = ApolloDeletedCommentsCommentFromCellNode(cellNode);
    if (!comment) return;
    NSString *fullName = ApolloDeletedCommentsFullNameForComment(comment);
    ApolloDeletedCommentsUnmarkCommentRevealed(fullName);
    ApolloDeletedCommentsUnmarkCommentBodyRevealed(comment.author, comment.body);
    objc_setAssociatedObject(comment, kApolloDeletedCommentsSuppressNextCollapseKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloDeletedCommentsApplyTapToRevealIfNeeded(cellNode);
    ApolloDeletedCommentsScheduleForceExpanded(comment, cellNode);
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
    return ApolloDeletedCommentsCellNodeIsRecovered(cellNode);
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
    if (!sShowDeletedComments || !ApolloDeletedCommentsCellNodeIsRecovered(cellNode)) {
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

static void ApolloDeletedCommentsUpdateCell(id cellNode) {
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
    NSMutableAttributedString *renamed = [ApolloDeletedCommentsReasonChipAttributedText(ApolloDeletedCommentsReasonLabelForComment(comment), baseAttributes, NO) mutableCopy];
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
    return renamed;
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    NSAttributedString *rewrittenText = ApolloDeletedCommentsAttributedTextWithReasonPrefix((id)self,
        ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText)
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
    NSAttributedString *renamedAttributedText = ApolloDeletedCommentsRenameRecoveredSpoilerLabel((id)self, attributedText);
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
