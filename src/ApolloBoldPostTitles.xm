// ApolloBoldPostTitles.xm — "Bold Post Titles" (Appearance > Posts), issue #226.
//
// Apollo has no title-weight setting. Every feed title — large and compact
// posts, a crosspost's inner title, the post-context row above a comment — is
// built by PostTitleNode's private title rebuild (run from its init, from the
// cell's link assignment and from the isRead didSet). That rebuild asks
// Apollo's font system for the title font, which is
// [UIFont systemFontOfSize:<text size> weight:UIFontWeightRegular] (compact and
// large differ by size only), and sets titleNode.attributedText. The comments-
// header title runs the same code with isBolder=YES (UIFontWeightMedium,
// +2pt) — Apollo's own "bolder" look, which this module leaves alone.
//
// The title font is re-weighted at the one sink every rebuild passes through:
// ASTextNode's setAttributedText:. Doing it there — before ASDK measures the
// node — means the bold string is what gets measured, so row heights are right
// on the first layout pass: no post-measure invalidation, no visible jumps.
//
// Identification is structural, never address-based: the text node's
// supernode is a PostTitleNode whose `titleNode` ivar is this very node (the
// subnode is attached before the first text set), and isBolder=NO excludes
// the comments-header variant. If a future binary changes that layout the
// %ctor finds out and the feature stays inert.
//
// Theme fonts compose: the weight is added onto the font's EXISTING
// descriptor — family/design (SF Pro, Rounded, New York, Mono) and point size
// preserved, so the Mono theme's optical size scale is not applied a second
// time — and the theme runtime's own sink then re-derives the design while
// keeping the weight it reads back from CoreText.
//
// Toggling re-renders live: Apollo's Appearance toggles post
// com.christianselig.PostCellAppearanceUpdated, which every PostsViewController
// answers with a table reload that rebuilds its cell nodes. The switch posts
// the same notification and inherits the same refresh, in both directions.

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import "ApolloBoldPostTitles.h"
#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloTextureDecls.h"
#import "UserDefaultConstants.h"

// Posted by Apollo's own Appearance toggles ("Show Voting Buttons", ...);
// -[PostsViewController postCellAppearanceUpdatedWithNotification:] forwards
// to appFontChangedWithNotification:, which is a plain [tableView reloadData].
static NSString *const kApolloPostCellAppearanceUpdatedNotification =
    @"com.christianselig.PostCellAppearanceUpdated";

// Stamped over the whole title string once re-weighted, so a later set that
// derives from our string (translation swaps copy the attributes) is a no-op.
static NSString *const kApolloBoldPostTitleAppliedAttribute = @"ApolloRebornBoldPostTitle";

// Semibold: clearly heavier than Apollo's Regular title at every text size
// without Bold's weight on a three-line title. (Apollo's own "bolder"
// comments-header title is Medium, which reads as barely different.)
static const UIFontWeight kApolloBoldPostTitleWeight = UIFontWeightSemibold;

static Class sPostTitleNodeClass;
static Ivar sPostTitleNodeTitleIvar;
static ptrdiff_t sPostTitleNodeIsBolderOffset = -1;

#pragma mark - Font derivation

// CoreText's normalised weight (UIFontWeight scale). UIFont's own descriptor
// doesn't reliably expose the weight as an attribute; CTFontCopyTraits does.
static CGFloat ApolloFontWeight(UIFont *font) {
    NSDictionary *traits = CFBridgingRelease(CTFontCopyTraits((__bridge CTFontRef)font));
    NSNumber *weight = traits[(__bridge NSString *)kCTFontWeightTrait];
    return [weight isKindOfClass:[NSNumber class]] ? weight.doubleValue : 0;
}

// `font` at kApolloBoldPostTitleWeight in its own family/design and point
// size. Returns `font` itself when it is already that heavy or no heavier face
// exists. Cached per (name, size): the sink runs for every title.
static UIFont *ApolloBoldPostTitleFont(UIFont *font) {
    static NSCache<NSString *, UIFont *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 64;
    });

    NSString *key = [NSString stringWithFormat:@"%@|%.2f", font.fontName, font.pointSize];
    UIFont *cached = [cache objectForKey:key];
    if (cached) return cached;

    CGFloat sourceWeight = ApolloFontWeight(font);
    UIFont *bold = nil;
    if (sourceWeight < kApolloBoldPostTitleWeight - 0.05) {
        // Weight trait on the existing descriptor keeps family, design and
        // size; only the face changes. Verified through CoreText rather than
        // trusted: a descriptor can silently hand back the same face.
        UIFontDescriptor *weighted = [font.fontDescriptor fontDescriptorByAddingAttributes:@{
            UIFontDescriptorTraitsAttribute: @{ UIFontWeightTrait: @(kApolloBoldPostTitleWeight) },
        }];
        UIFont *candidate = weighted ? [UIFont fontWithDescriptor:weighted size:font.pointSize] : nil;
        if (candidate && ApolloFontWeight(candidate) > sourceWeight + 0.1) bold = candidate;
        if (!bold) {
            // Fallback: the family's bold face via the symbolic trait.
            UIFontDescriptorSymbolicTraits traits = font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitBold;
            UIFontDescriptor *symbolic = [font.fontDescriptor fontDescriptorWithSymbolicTraits:traits];
            candidate = symbolic ? [UIFont fontWithDescriptor:symbolic size:font.pointSize] : nil;
            if (candidate && ApolloFontWeight(candidate) > sourceWeight + 0.1) bold = candidate;
        }
    }
    if (!bold) bold = font;
    ApolloLog(@"BoldPostTitles: %@ %.1fpt (weight %.2f) -> %@ (weight %.2f)",
              font.fontName, font.pointSize, sourceWeight, bold.fontName, ApolloFontWeight(bold));
    [cache setObject:bold forKey:key];
    return bold;
}

#pragma mark - Title identification

// YES when `textNode` is the title text of a FEED PostTitleNode: its supernode
// is a PostTitleNode whose `titleNode` ivar is this very node, and that title
// isn't Apollo's own bolder (isBolder) comments-header variant.
static BOOL ApolloIsFeedPostTitleTextNode(ASDisplayNode *textNode) {
    ASDisplayNode *supernode = [textNode supernode];
    if (!supernode || object_getClass(supernode) != sPostTitleNodeClass) return NO;
    if (object_getIvar(supernode, sPostTitleNodeTitleIvar) != textNode) return NO;
    BOOL isBolder = *(BOOL *)((char *)(__bridge void *)supernode + sPostTitleNodeIsBolderOffset);
    return !isBolder;
}

// `text` with every font run re-weighted (the poll glyph prefix rides along;
// Apple Color Emoji has no weight). Already-stamped strings pass through.
static NSAttributedString *ApolloBoldPostTitleText(NSAttributedString *text) {
    if (![text isKindOfClass:[NSAttributedString class]] || text.length == 0) return text;
    if ([text attribute:kApolloBoldPostTitleAppliedAttribute atIndex:0 effectiveRange:NULL]) return text;

    NSRange full = NSMakeRange(0, text.length);
    NSMutableAttributedString *rewritten = [text mutableCopy];
    [text enumerateAttribute:NSFontAttributeName
                     inRange:full
                     options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:[UIFont class]]) return;
        UIFont *bold = ApolloBoldPostTitleFont(value);
        if (bold != value) [rewritten addAttribute:NSFontAttributeName value:bold range:range];
    }];
    [rewritten addAttribute:kApolloBoldPostTitleAppliedAttribute value:@YES range:full];
    return rewritten;
}

#pragma mark - Public

void ApolloBoldPostTitlesSetEnabled(BOOL enabled) {
    sBoldPostTitles = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UDKeyBoldPostTitles];
    // Every live PostsViewController reloads its table, rebuilding its cell
    // nodes through the sink below — bold on, and back to Regular off.
    [[NSNotificationCenter defaultCenter] postNotificationName:kApolloPostCellAppearanceUpdatedNotification
                                                        object:nil];
    ApolloLog(@"BoldPostTitles: enabled=%d, feeds asked to re-render", enabled);
}

#pragma mark - Hooks

// Both text node classes: Apollo's titleNode is declared ASTextNode, but
// Texture's ASTextNode2 experiment swaps instances at alloc time.
%group ApolloBoldPostTitlesHooks

%hook ASTextNode

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (sBoldPostTitles && ApolloIsFeedPostTitleTextNode((ASDisplayNode *)self)) {
        %orig(ApolloBoldPostTitleText(attributedText));
        return;
    }
    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (sBoldPostTitles && ApolloIsFeedPostTitleTextNode((ASDisplayNode *)self)) {
        %orig(ApolloBoldPostTitleText(attributedText));
        return;
    }
    %orig;
}

%end

%end

%ctor {
    sPostTitleNodeClass = objc_getClass("_TtC6Apollo13PostTitleNode");
    sPostTitleNodeTitleIvar = sPostTitleNodeClass ? class_getInstanceVariable(sPostTitleNodeClass, "titleNode") : NULL;
    Ivar isBolder = sPostTitleNodeClass ? class_getInstanceVariable(sPostTitleNodeClass, "isBolder") : NULL;
    sPostTitleNodeIsBolderOffset = isBolder ? ivar_getOffset(isBolder) : -1;
    if (!sPostTitleNodeClass || !sPostTitleNodeTitleIvar || sPostTitleNodeIsBolderOffset < 0) {
        ApolloLog(@"BoldPostTitles: PostTitleNode layout not recognised (class=%d titleNode=%d isBolder=%d) — feature inert",
                  sPostTitleNodeClass != Nil, sPostTitleNodeTitleIvar != NULL, sPostTitleNodeIsBolderOffset >= 0);
        return;
    }
    %init(ApolloBoldPostTitlesHooks);
    ApolloLog(@"BoldPostTitles: hooks installed (isBolder ivar offset %ld)", (long)sPostTitleNodeIsBolderOffset);
}
