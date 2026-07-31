#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"

// Cosmetic cleanup for rendered markdown bodies (comments, post self-text, etc).
//
// Apollo's MarkdownNode (_TtC6Apollo12MarkdownNode) renders the markdown source
// into a *plain* ASTextNode body node, and sets the MarkdownNode itself as that
// text node's `delegate` right before assigning the attributed text. We use the
// delegate to precisely scope to markdown body text nodes, then post-process the
// attributed string before it is measured/drawn. Two issues are handled:
//
// 1. Trailing whitespace/newlines. Reddit bodies frequently end with trailing
//    newlines (e.g. "...programming\n\n"). These survive into the laid-out
//    attributed string as empty blank line(s) below the text, inflating the
//    cell height and leaving a gap before the next cell/divider.
//
// 2. Literal zero-width-space entities. Reddit's fancy-pants editor inserts the
//    HTML entity "&#x200B;" (U+200B ZERO WIDTH SPACE) to force blank lines.
//    Apollo never decodes it, so users see the literal text "&#x200B;" in the
//    middle (or anywhere) of a comment body. We strip the entity (hex/decimal
//    forms and the raw character) wherever it appears.
//
// Both passes preserve all surrounding glyphs and attributes (links, fonts,
// colors); only the unwanted characters are removed, so link ranges and
// interior paragraph breaks ("\n\n") stay intact.

static Class ApolloMarkdownNodeClass(void) {
    static Class cls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = objc_getClass("_TtC6Apollo12MarkdownNode");
    });
    return cls;
}

// Removes every occurrence of `needle` from `result`, using `options`
// (e.g. NSCaseInsensitiveSearch). Operates in place.
static void ApolloMarkdownDeleteAllOccurrences(NSMutableAttributedString *result,
                                               NSString *needle,
                                               NSStringCompareOptions options) {
    if (result.length == 0 || needle.length == 0) return;
    NSRange searchRange = NSMakeRange(0, result.length);
    while (searchRange.length >= needle.length) {
        NSRange found = [result.string rangeOfString:needle options:options range:searchRange];
        if (found.location == NSNotFound) break;
        [result deleteCharactersInRange:found];
        NSUInteger nextLocation = found.location;
        searchRange = NSMakeRange(nextLocation, result.length - nextLocation);
    }
}

// Strips literal zero-width-space entities ("&#x200B;", "&#8203;") and the raw
// U+200B character from anywhere in the body. Returns the original string
// unchanged (no allocation) when none are present.
static NSAttributedString *ApolloMarkdownStripZeroWidthSpaces(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) {
        return attributedText;
    }

    NSString *string = attributedText.string;
    BOOL hasEntity = ([string rangeOfString:@"&#"].location != NSNotFound);
    BOOL hasRawChar = ([string rangeOfString:@"\u200B"].location != NSNotFound);
    if (!hasEntity && !hasRawChar) return attributedText;

    NSMutableAttributedString *result = [attributedText mutableCopy];
    if (hasEntity) {
        // Case-insensitive covers &#x200B;, &#x200b;, &#X200B;, etc.
        ApolloMarkdownDeleteAllOccurrences(result, @"&#x200b;", NSCaseInsensitiveSearch);
        ApolloMarkdownDeleteAllOccurrences(result, @"&#8203;", 0);
    }
    if (hasRawChar) {
        ApolloMarkdownDeleteAllOccurrences(result, @"\u200B", 0);
    }
    return result;
}

// Trims trailing whitespace/newline characters from the end of the body.
// Returns the original string unchanged (no allocation) when there is nothing
// to trim.
static NSAttributedString *ApolloMarkdownTrimTrailingWhitespace(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]]) return attributedText;

    NSUInteger length = attributedText.length;
    if (length == 0) return attributedText;

    NSString *string = attributedText.string;
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    NSUInteger end = length;
    while (end > 0 && [trimSet characterIsMember:[string characterAtIndex:end - 1]]) {
        end--;
    }

    if (end == length) return attributedText; // No trailing whitespace to trim.

    return [attributedText attributedSubstringFromRange:NSMakeRange(0, end)];
}

static NSAttributedString *ApolloMarkdownCleanBody(NSAttributedString *attributedText) {
    // Strip zero-width entities first so any now-trailing whitespace they
    // exposed is also removed by the trailing trim.
    attributedText = ApolloMarkdownStripZeroWidthSpaces(attributedText);
    attributedText = ApolloMarkdownTrimTrailingWhitespace(attributedText);
    return attributedText;
}

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    Class markdownNodeClass = ApolloMarkdownNodeClass();
    if (markdownNodeClass && [(id)self respondsToSelector:@selector(delegate)]) {
        id delegate = ((id (*)(id, SEL))objc_msgSend)((id)self, @selector(delegate));
        if ([delegate isMemberOfClass:markdownNodeClass]) {
            %orig(ApolloMarkdownCleanBody(attributedText));
            return;
        }
    }
    %orig;
}

%end
