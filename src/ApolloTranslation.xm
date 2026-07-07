#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <string.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "ApolloTranslation.h"
#import "Tweak.h"

// Generated umbrella header for the Swift compilation unit (ApolloAppleTranslation.swift),
// which vends the @objc ApolloAppleTranslator used by the on-device "apple" provider.
// Guarded with __has_include so the file still builds if Swift output isn't present.
#if __has_include("ApolloReborn-Swift.h")
#import "ApolloReborn-Swift.h"
#define APOLLO_HAS_APPLE_TRANSLATE 1
#else
#define APOLLO_HAS_APPLE_TRANSLATE 0
#endif

#ifndef APOLLO_TRANSLATION_VERBOSE_LOGS
#define APOLLO_TRANSLATION_VERBOSE_LOGS 0
#endif

#if APOLLO_TRANSLATION_VERBOSE_LOGS
#define ApolloTranslationVerboseLog(fmt, ...) ApolloLog(fmt, ##__VA_ARGS__)
#else
#define ApolloTranslationVerboseLog(fmt, ...) do {} while (0)
#endif

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
// Marker for title text nodes. Title nodes live outside the comments view
// controller (feeds, search, profiles) so they must bypass the
// `ApolloControllerIsInTranslatedMode` check used by the comment-thread
// ownership system. Set in addition to kApolloTranslationOwnedTextNodeKey.
static const void *kApolloTitleOwnedTextNodeKey = &kApolloTitleOwnedTextNodeKey;
// Marks a UIViewController as a feed-style VC (Posts/LitePosts/SearchResults).
// The globe-installation code uses this to gate visibility on
// sTranslatePostTitles in addition to sEnableBulkTranslation.
static const void *kApolloFeedTranslationVCKey = &kApolloFeedTranslationVCKey;
// Liquid Glass globe-merge: instead of adding the translation globe as a SEPARATE
// trailing bar button item (which iOS 26 spaces apart from Apollo's mod/sort/more
// container with a visible inter-group gap), we inject the globe button directly
// into Apollo's existing trailing container so all icons form one evenly-spaced
// group. kApolloGlobeMergeButtonKey holds the globe UIButton on the navigationItem;
// sApplyingGlobeMerge guards the setRightBarButtonItem(s) re-injection hook.
static const void *kApolloGlobeMergeButtonKey = &kApolloGlobeMergeButtonKey;
// Fallback for screens with no multi-button container to merge into: the globe
// is shown as its own trailing bar button item (the pre-26 behavior).
static const void *kApolloGlobeStandaloneItemKey = &kApolloGlobeStandaloneItemKey;
// The right-shift the merge applied to Apollo's buttons, stored on the container
// so removal can undo it exactly.
static const void *kApolloGlobeMergeShiftKey = &kApolloGlobeMergeShiftKey;
static BOOL sApplyingGlobeMerge = NO;
// Globe slot width inside Apollo's container. ~34pt centers the ~26pt glyph with
// the same modest padding Apollo's own icons use, so spacing reads even.
static const CGFloat kApolloGlobeMergeSlotWidth = 34.0;
// Points to nudge the globe glyph toward the next icon (compensates for the wide
// 44pt mod-badge slot's leading padding so the globe→badge gap looks even).
static const CGFloat kApolloGlobeMergeGlyphNudge = 3.0;
static const void *kApolloFeedSettledTitleRefreshScheduledKey = &kApolloFeedSettledTitleRefreshScheduledKey;
static const void *kApolloReapplyScheduledKey = &kApolloReapplyScheduledKey;
// Phase B — status banner above comments.
static const void *kApolloTranslationBannerKey = &kApolloTranslationBannerKey;
// Phase C — post selftext translation.
static const void *kApolloAppliedHeaderTranslationFullNameKey = &kApolloAppliedHeaderTranslationFullNameKey;
static const void *kApolloHeaderTranslatedTextNodeKey = &kApolloHeaderTranslatedTextNodeKey;
static const void *kApolloHeaderCellTranslationKeyKey = &kApolloHeaderCellTranslationKeyKey;
static const void *kApolloPostBodyReapplyScheduledKey = &kApolloPostBodyReapplyScheduledKey;
// Per-header-cell-node scheduling key for the fast (~10ms) cached
// translation reapply path used by the comments header `setNeedsLayout` /
// `setNeedsDisplay` hook, mirroring `kApolloReapplyScheduledKey` for
// comment cells. Catches vote-triggered redisplay before the visible flash.
static const void *kApolloHeaderReapplyScheduledKey = &kApolloHeaderReapplyScheduledKey;
// Set on the cell/header node by ApolloApplyTranslationTo*CellNode for ~150ms
// after a successful apply. Both schedulers skip while this is set, breaking
// the apply -> setNeedsLayout -> hook -> schedule -> apply feedback loop
// observed when ASDK propagates layout invalidation up from the text node.
static const void *kApolloRecentlyAppliedKey = &kApolloRecentlyAppliedKey;
// Last RDKLink applied to a header cell, retained so we can recover the link
// when ApolloLinkFromHeaderCellNode returns nil after the cell is rebuilt by
// a vote tap.
static const void *kApolloAppliedHeaderLinkKey = &kApolloAppliedHeaderLinkKey;
// Per-comments-VC last-applied post body translation. Updated on every
// successful header/post-body apply (any path). Used by the header reapply
// scheduler to recover after vote tap when Apollo rebuilds the header cell
// and we can no longer find the RDKLink. Layout: NSDictionary with keys
// @"link" (RDKLink), @"body" (NSString), @"translated" (NSString).
static const void *kApolloLastAppliedPostBodyKey = &kApolloLastAppliedPostBodyKey;
// Per-VC monotonic counter bumped in viewWillDisappear:. Pending toggle
// reconciles capture this at scheduling time and bail out if it changed,
// so we don't run multi-pass restore work mid swipe-back.
static const void *kApolloReconcileGenerationKey = &kApolloReconcileGenerationKey;

static NSString *const kApolloDefaultLibreTranslateURL = @"https://libretranslate.de/translate";

static NSCache<NSString *, NSString *> *sTranslationCache;
// fullName ("t1_xxxxx") -> translated body text. Survives cell reuse / collapse.
static NSCache<NSString *, NSString *> *sCommentTranslationByFullName;
// fullName ("t3_xxxxx") -> translated post selftext. Same idea, for posts.
static NSCache<NSString *, NSString *> *sLinkTranslationByFullName;
// Per-session set of comment fullNames for which we already emitted the
// "detected language matches target" skip log. Prevents the log from firing
// on every visibility / scroll tick for the same comment. Reset whenever
// the user changes the skip-language list (caches flushed).
static NSMutableSet<NSString *> *sLoggedSkippedCommentFullNames;
// Per-session set of post fullNames for which we already emitted the
// "skipping structured post body" log. Prevents the same per-call flood as
// above, since the post-body translate path runs on every viewDidAppear
// retry / cell visibility event. Reset on skip-language changes.
static NSMutableSet<NSString *> *sLoggedSkippedStructuredPostFullNames;
// Mirrors of the two persistent caches above. NSCache hides its contents, so
// we maintain plain NSMutableDictionaries alongside it for snapshot / disk
// persistence on backgrounding. All writes go through helper macros below.
static NSMutableDictionary<NSString *, NSString *> *sCommentTranslationMirror = nil;
static NSMutableDictionary<NSString *, NSString *> *sLinkTranslationMirror = nil;
static inline void ApolloMirrorSetComment(NSString *key, NSString *value) {
    if (!key || !value) return;
    @synchronized (sCommentTranslationMirror) { sCommentTranslationMirror[key] = value; }
}
static inline void ApolloMirrorRemoveComment(NSString *key) {
    if (!key) return;
    @synchronized (sCommentTranslationMirror) { [sCommentTranslationMirror removeObjectForKey:key]; }
}
static inline void ApolloMirrorSetLink(NSString *key, NSString *value) {
    if (!key || !value) return;
    @synchronized (sLinkTranslationMirror) { sLinkTranslationMirror[key] = value; }
}
static inline void ApolloMirrorRemoveLink(NSString *key) {
    if (!key) return;
    @synchronized (sLinkTranslationMirror) { [sLinkTranslationMirror removeObjectForKey:key]; }
}
static NSMutableDictionary<NSString *, NSMutableArray *> *sPendingTranslationCallbacks;
static __weak UIViewController *sVisibleCommentsViewController = nil;
// Weak set of every text node we've stamped with the ownership marker. Lets
// us walk *all* off-screen / preloaded text nodes on toggle-off, instead of
// only those whose UITableViewCells happen to be in `visibleCells`.
static NSHashTable<id> *sOwnedTextNodes = nil;
static dispatch_queue_t sOwnedTextNodesQueue = NULL;
static BOOL sPendingVisibleFeedTitleApplied = NO;
static NSMutableDictionary<NSString *, NSNumber *> *sFeedTitleModeByFeedKey = nil;
static BOOL sLastFeedTitleModeKnown = NO;
static BOOL sLastFeedTitleTranslatedMode = YES;
NSString * const ApolloRichPreviewTranslationDidUpdateNotification = @"ApolloRichPreviewTranslationDidUpdateNotification";
static NSMutableSet<NSString *> *sRichPreviewTranslationInFlightKeys = nil;
static __weak UIViewController *sLastInstalledFeedViewController = nil;

static void ApolloUpdateTranslationUIForController(id controller);
static RDKComment *ApolloCommentFromCellNode(id commentCellNode);
static void ApolloRegisterOwnedTextNode(id textNode);
static void ApolloRestoreAllOwnedTextNodes(void);
static void ApolloRescanTitleNodesForController(UIViewController *vc);
static void ApolloMaybeTranslateFeedPostBodyNode(id feedCellNode, id excludeTitleNode);
static UIViewController *ApolloEnclosingViewControllerForNode(id node);
static BOOL ApolloClassLooksLikeCommentsViewController(Class cls);
static BOOL ApolloFeedTitlesShouldShowTranslated(UIViewController *feedVC);
static BOOL ApolloControllerIsInTranslatedMode(UIViewController *vc);
static BOOL ApolloRefreshVisibleTranslationAppliedForController(UIViewController *vc);
static BOOL ApolloRefreshFeedTitleTranslationAppliedForController(UIViewController *vc);

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

static NSString *ApolloTrimmedString(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ApolloTextLooksLikeURLPreview(NSString *text) {
    NSString *trimmed = ApolloTrimmedString(text);
    if (trimmed.length == 0) return NO;

    NSString *lower = trimmed.lowercaseString;
    if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"] || [lower hasPrefix:@"www."]) return YES;

    NSRange firstWhitespace = [lower rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *firstToken = firstWhitespace.location == NSNotFound ? lower : [lower substringToIndex:firstWhitespace.location];
    if ([firstToken containsString:@"."] && ([firstToken containsString:@"/"] || [firstToken hasSuffix:@"…"] || [firstToken hasSuffix:@"..."])) {
        return YES;
    }

    return NO;
}

static BOOL ApolloTextLooksLikePreviewExcerptOfBody(NSString *candidateText, NSString *bodyText) {
    NSString *candidate = ApolloTrimmedString(candidateText);
    NSString *body = ApolloTrimmedString(bodyText);
    if (candidate.length == 0 || body.length == 0 || candidate.length >= body.length) return NO;

    NSString *candidateNorm = ApolloNormalizeTextForCompare(candidate);
    NSString *bodyNorm = ApolloNormalizeTextForCompare(body);
    if (candidateNorm.length == 0 || bodyNorm.length == 0 || ![bodyNorm containsString:candidateNorm]) return NO;

    BOOL visiblyTruncated = [candidate containsString:@"..."] || [candidate containsString:@"…"];
    BOOL markdownExcerpt = ([candidate containsString:@"**"] || [candidate containsString:@"*"]) && visiblyTruncated;
    CGFloat ratio = (CGFloat)candidateNorm.length / (CGFloat)bodyNorm.length;
    return ApolloTextLooksLikeURLPreview(candidate) || markdownExcerpt || ratio < 0.60;
}

static BOOL ApolloTextQualifiesAsBodyCandidate(NSString *candidateText, NSString *bodyText) {
    NSString *candidateNorm = ApolloNormalizeTextForCompare(candidateText);
    NSString *bodyNorm = ApolloNormalizeTextForCompare(bodyText);
    if (candidateNorm.length == 0 || bodyNorm.length == 0) return NO;
    if ([candidateNorm isEqualToString:bodyNorm]) return YES;

    if (ApolloTextLooksLikeURLPreview(candidateText) || ApolloTextLooksLikePreviewExcerptOfBody(candidateText, bodyText)) return NO;

    if ([candidateNorm containsString:bodyNorm]) return YES;
    if ([bodyNorm containsString:candidateNorm]) {
        CGFloat ratio = (CGFloat)candidateNorm.length / (CGFloat)bodyNorm.length;
        return ratio >= 0.60 || candidateNorm.length >= 160;
    }

    NSUInteger prefixLength = MIN((NSUInteger)24, MIN(candidateNorm.length, bodyNorm.length));
    if (prefixLength >= 12) {
        NSString *candidatePrefix = [candidateNorm substringToIndex:prefixLength];
        NSString *bodyPrefix = [bodyNorm substringToIndex:prefixLength];
        if ([candidatePrefix isEqualToString:bodyPrefix]) {
            CGFloat ratio = (CGFloat)candidateNorm.length / (CGFloat)bodyNorm.length;
            return ratio >= 0.60 || candidateNorm.length >= 160;
        }
    }

    return NO;
}

static BOOL ApolloTextIsSubstantiveForOwnershipCleanup(NSString *text) {
    NSString *norm = ApolloNormalizeTextForCompare(text);
    return norm.length >= 3;
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

// Detects post bodies whose visual structure (markdown tables, headings,
// many blank-line-separated paragraphs) does not survive a translator round-
// trip. Our apply path collapses per-range attributes (bold headings,
// monospace table cells, paragraph spacing) to a single base font, and the
// translator commonly collapses `\n\n` to single newlines — together those
// produce illegible output where most visible text disappears and only inline
// emoji remain. Conservative: when in doubt, treat as structured and skip.
// Only used for post bodies; comments don't trigger this and continue to
// translate normally inside structured posts.
static BOOL ApolloTextLooksLikeStructuredPostBody(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;

    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];

    NSUInteger pipeRowCount = 0;
    NSUInteger atxHeadingCount = 0;
    NSUInteger boldOnlyHeadingCount = 0;
    BOOL sawTableSeparator = NO;

    NSUInteger scanLimit = MIN(lines.count, (NSUInteger)200);
    for (NSUInteger i = 0; i < scanLimit; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:ws];
        if (line.length == 0) continue;

        // Markdown table separator row, e.g. "|---|---|" or "| --- | :---: |"
        if (!sawTableSeparator && [line hasPrefix:@"|"] && [line hasSuffix:@"|"]) {
            BOOL onlyDashesAndPipes = YES;
            for (NSUInteger j = 0; j < line.length; j++) {
                unichar c = [line characterAtIndex:j];
                if (c != '|' && c != '-' && c != ':' && c != ' ' && c != '\t') { onlyDashesAndPipes = NO; break; }
            }
            if (onlyDashesAndPipes && [line rangeOfString:@"---"].location != NSNotFound) {
                sawTableSeparator = YES;
            }
        }

        // Markdown table content row: starts and ends with `|`.
        if ([line hasPrefix:@"|"] && [line hasSuffix:@"|"] && line.length >= 3) {
            pipeRowCount++;
        }

        // ATX heading: `#`, `##`, ... up to 6.
        if ([line hasPrefix:@"#"]) {
            NSUInteger hashCount = 0;
            while (hashCount < line.length && hashCount < 6 && [line characterAtIndex:hashCount] == '#') hashCount++;
            if (hashCount > 0 && hashCount < line.length && [line characterAtIndex:hashCount] == ' ') {
                atxHeadingCount++;
            }
        }

        // Bold-only heading lines like "**LINE-UPS**" or "**MATCH STATS**"
        // — Reddit's post-match thread convention. Whole line wrapped in
        // `**...**` and no other formatting.
        if (line.length >= 5 && [line hasPrefix:@"**"] && [line hasSuffix:@"**"]) {
            NSString *inner = [line substringWithRange:NSMakeRange(2, line.length - 4)];
            if (inner.length > 0 && [inner rangeOfString:@"**"].location == NSNotFound) {
                boldOnlyHeadingCount++;
            }
        }
    }

    if (sawTableSeparator) return YES;
    if (pipeRowCount >= 3) return YES;
    if (atxHeadingCount >= 1) return YES;
    if (boldOnlyHeadingCount >= 2) return YES;

    // Many "Foo: bar" colon-terminated label lines (Venue:, Referee:,
    // Manager:, Starting XI:, etc.) is a strong indicator of a structured
    // post-match / spec-sheet style body even when no markdown survives.
    NSUInteger labelLineCount = 0;
    for (NSUInteger i = 0; i < scanLimit; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:ws];
        if (line.length < 4 || line.length > 80) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        // "Word:" or "Word Word:" near start, with content after
        if (colon.location >= 2 && colon.location <= 30) {
            labelLineCount++;
            if (labelLineCount >= 3) return YES;
        }
    }

    // Structural fingerprint: count "isolated short header-like lines" —
    // short lines (<40 chars) sitting alone between blank lines, not ending
    // in regular sentence punctuation. These are how rendered post-match /
    // line-up / spec-sheet bodies look after their markdown markers
    // (`**LINE-UPS**`, `# Schalke 04`, `---`) get consumed by the renderer:
    // bare standalone "LINE-UPS", "Schalke 04", "Fortuna Düsseldorf" lines
    // surrounded by blank space. Plain prose almost never has these — every
    // paragraph is a long line ending in `.`/`!`/`?`.
    NSCharacterSet *sentenceEnders = [NSCharacterSet characterSetWithCharactersInString:@".!?,;"];
    NSUInteger isolatedHeaderCount = 0;
    for (NSUInteger i = 0; i < scanLimit; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:ws];
        if (line.length == 0 || line.length > 40) continue;
        // Need blank (or start) before and blank (or end) after.
        BOOL prevBlank = (i == 0) ||
                         [[lines[i - 1] stringByTrimmingCharactersInSet:ws] length] == 0;
        BOOL nextBlank = (i + 1 >= lines.count) ||
                         [[lines[i + 1] stringByTrimmingCharactersInSet:ws] length] == 0;
        if (!prevBlank || !nextBlank) continue;
        // Skip lines that look like prose (end with sentence punctuation).
        unichar lastChar = [line characterAtIndex:line.length - 1];
        if ([sentenceEnders characterIsMember:lastChar]) continue;
        // Skip lines that are just a URL or markdown link — those are common
        // in prose ("Source: <link>") and aren't section headers.
        if ([line hasPrefix:@"http"] || [line hasPrefix:@"["]) continue;
        isolatedHeaderCount++;
        if (isolatedHeaderCount >= 2) return YES;
    }

    return NO;
}

static BOOL ApolloCommentContainsCodeOrPreformatted(RDKComment *comment) {
    if (!comment) return NO;
    return ApolloTextContainsMarkdownCode(comment.body) || ApolloHTMLContainsCode(comment.bodyHTML);
}

// HTML-side companion to ApolloTextLooksLikeStructuredPostBody. Reddit
// renders self-post bodies to HTML server-side, and Apollo's ASTextNode
// pipeline consumes the markdown before our gate sees it — so checking
// link.selfText / visibleText alone misses tables/headings/HRs whenever
// the markdown source isn't available locally. The HTML form, however,
// is reliably populated on RDKLink.selfTextHTML. Cheap case-insensitive
// substring checks; conservative — any structural tag trips the skip.
static BOOL ApolloHTMLLooksLikeStructuredPostBody(NSString *html) {
    if (![html isKindOfClass:[NSString class]] || html.length == 0) return NO;
    NSStringCompareOptions opts = NSCaseInsensitiveSearch;
    if ([html rangeOfString:@"<table" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<hr" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<h1" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<h2" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<h3" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<h4" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<h5" options:opts].location != NSNotFound) return YES;
    if ([html rangeOfString:@"<h6" options:opts].location != NSNotFound) return YES;

    // NOTE: a previous "<p> count >= 4" rule lived here as a paragraph-
    // structure proxy. Reddit wraps every paragraph in <p>, so any 4-
    // paragraph plain-prose rant tripped it and never translated. Removed;
    // the explicit table / hr / h1-h6 checks above are sufficient to catch
    // genuine structured content without false-positiving prose.
    return NO;
}

static BOOL ApolloLinkContainsCodeOrPreformatted(RDKLink *link, NSString *visibleText) {
    return ApolloTextContainsMarkdownCode(link.selfText) ||
           ApolloHTMLContainsCode(link.selfTextHTML) ||
           ApolloTextContainsMarkdownCode(visibleText) ||
           ApolloTextLooksLikeStructuredPostBody(link.selfText) ||
           ApolloTextLooksLikeStructuredPostBody(visibleText) ||
           ApolloHTMLLooksLikeStructuredPostBody(link.selfTextHTML);
}

// One-shot diagnostic helper for post-body skips. The translate path runs
// on every viewDidAppear retry / cell visibility event, so without a guard
// the same skip line floods the log dozens of times per post.
static void ApolloLogPostBodySkipOnce(RDKLink *link, NSString *reason) {
    NSString *fullName = link.fullName;
    if (fullName.length == 0) {
        ApolloLog(@"[Translation] Skipping post body — %@", reason);
        return;
    }
    @synchronized (sLoggedSkippedStructuredPostFullNames) {
        if ([sLoggedSkippedStructuredPostFullNames containsObject:fullName]) return;
        [sLoggedSkippedStructuredPostFullNames addObject:fullName];
    }
    ApolloLog(@"[Translation] Skipping post body fullName=%@ — %@", fullName, reason);
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
    if (!ApolloControllerIsInTranslatedMode(vc)) return;
    objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloUpdateTranslationUIForController(vc);
}

// Mark a specific (non-comments) controller as having visible translated
// content so its globe icon turns green. Used by the feed/title path where
// `sVisibleCommentsViewController` is nil.
//
// Strategy (after multiple failed attempts at responder-chain walks): just
// find the topmost visible feed VC in the key window that we've installed
// the globe on. The user is only ever looking at one feed at a time, so the
// "right" target is always the visible one. This avoids all the parent /
// child / nav-stack indirection that fails on Home (where the title node's
// responder chain doesn't reach the marked feed VC).
static UIViewController *ApolloFindTopmostVisibleFeedVC(void) {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in scene.windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) return nil;

    // BFS from the root, return the deepest VC marked with the feed key
    // that is currently visible (view in window, not hidden).
    NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
    UIViewController *root = keyWindow.rootViewController;
    if (root) [queue addObject:root];
    UIViewController *bestMatch = nil;
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 256) {
        UIViewController *vc = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue]) {
            if (vc.isViewLoaded && vc.view.window == keyWindow && !vc.view.hidden) {
                bestMatch = vc;  // Keep walking; deeper match wins.
            }
        }
        for (UIViewController *child in vc.childViewControllers) [queue addObject:child];
        if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
    }
    return bestMatch;
}

static void ApolloMarkVisibleFeedTitleApplied(NSString *sourceText, NSString *translatedText) {
    if (!ApolloTranslatedTextDiffersFromSource(sourceText, translatedText)) return;

    UIViewController *feedVC = ApolloFindTopmostVisibleFeedVC();
    if (!feedVC) feedVC = sLastInstalledFeedViewController;
    if (feedVC && [objc_getAssociatedObject(feedVC, kApolloFeedTranslationVCKey) boolValue] && ApolloControllerIsInTranslatedMode(feedVC)) {
        // Only log on the NO->YES transition; otherwise this fires per
        // translated title (many per scroll) and floods the log.
        BOOL wasApplied = [objc_getAssociatedObject(feedVC, kApolloVisibleTranslationAppliedKey) boolValue];
        objc_setAssociatedObject(feedVC, kApolloVisibleTranslationAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloUpdateTranslationUIForController(feedVC);
        sPendingVisibleFeedTitleApplied = NO;
        if (!wasApplied) {
            ApolloLog(@"[Translation] MarkFeedTitleApplied direct class=%@ ptr=%p", NSStringFromClass([feedVC class]), feedVC);
        }
        return;
    }

    sPendingVisibleFeedTitleApplied = YES;
}

static void ApolloClearVisibleTranslationApplied(UIViewController *vc) {
    if (!vc) return;
    objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloRefreshFeedTranslationStateForController(UIViewController *vc) {
    if (!vc) return NO;
    if (![objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue]) {
        return ApolloRefreshVisibleTranslationAppliedForController(vc);
    }

    if (!sEnableBulkTranslation || !sTranslatePostTitles || !ApolloControllerIsInTranslatedMode(vc)) {
        ApolloClearVisibleTranslationApplied(vc);
        ApolloUpdateTranslationUIForController(vc);
        return NO;
    }

    BOOL applied = ApolloRefreshVisibleTranslationAppliedForController(vc);
    if (!applied) applied = ApolloRefreshFeedTitleTranslationAppliedForController(vc);
    ApolloUpdateTranslationUIForController(vc);
    return applied;
}

static void ApolloScheduleFeedTranslationStateRefresh(UIViewController *vc, NSTimeInterval delay) {
    if (!vc) return;
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC || !strongVC.isViewLoaded || !strongVC.view.window) return;
        ApolloRefreshFeedTranslationStateForController(strongVC);
    });
}

static NSString *ApolloTranslationCacheKey(NSString *text, NSString *targetLanguage) {
    return [NSString stringWithFormat:@"%@|%lu", targetLanguage ?: @"en", (unsigned long)text.hash];
}

static NSString *ApolloTranslationLinkToken(NSUInteger index) {
    return [NSString stringWithFormat:@"APOLLOTRANSLATIONLINK%luTOKEN", (unsigned long)index];
}

static NSRange ApolloRangeByTrimmingTrailingURLPunctuation(NSString *text, NSRange range) {
    if (range.location == NSNotFound || NSMaxRange(range) > text.length) return range;

    NSCharacterSet *trailingPunctuation = [NSCharacterSet characterSetWithCharactersInString:@".,!?;:"];
    while (range.length > 0) {
        unichar last = [text characterAtIndex:NSMaxRange(range) - 1];
        if (![trailingPunctuation characterIsMember:last]) break;
        range.length--;
    }
    return range;
}

static NSString *ApolloProtectTranslationLinks(NSString *sourceText, NSDictionary<NSString *, NSString *> **protectedLinksOut) {
    if (protectedLinksOut) *protectedLinksOut = @{};
    if (![sourceText isKindOfClass:[NSString class]] || sourceText.length == 0) return sourceText;

    NSMutableString *protectedText = [sourceText mutableCopy];
    NSMutableDictionary<NSString *, NSString *> *protectedLinks = [NSMutableDictionary dictionary];
    __block NSUInteger nextTokenIndex = 0;

    void (^replaceMatches)(NSRegularExpression *, BOOL) = ^(NSRegularExpression *regex, BOOL trimURLPunctuation) {
        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:protectedText options:0 range:NSMakeRange(0, protectedText.length)];
        for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
            NSRange range = match.range;
            if (trimURLPunctuation) {
                range = ApolloRangeByTrimmingTrailingURLPunctuation(protectedText, range);
            }
            if (range.length == 0 || NSMaxRange(range) > protectedText.length) continue;

            NSString *originalLink = [protectedText substringWithRange:range];
            NSString *token = ApolloTranslationLinkToken(nextTokenIndex++);
            protectedLinks[token] = originalLink;
            [protectedText replaceCharactersInRange:range withString:token];
        }
    };

    NSError *regexError = nil;
    NSRegularExpression *markdownLinkRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[[^\\]\\n]+\\]\\([^\\s)]+(?:\\s+\\\"[^\\\"]*\\\")?\\)"
                                                                                       options:0
                                                                                         error:&regexError];
    if (!regexError && markdownLinkRegex) {
        replaceMatches(markdownLinkRegex, NO);
    }

    regexError = nil;
    NSRegularExpression *bareURLRegex = [NSRegularExpression regularExpressionWithPattern:@"(?i)\\bhttps?://[^\\s<>()\\[\\]{}\\\"']+"
                                                                                options:0
                                                                                  error:&regexError];
    if (!regexError && bareURLRegex) {
        replaceMatches(bareURLRegex, YES);
    }

    if (protectedLinksOut && protectedLinks.count > 0) {
        *protectedLinksOut = [protectedLinks copy];
    }
    return protectedLinks.count > 0 ? [protectedText copy] : sourceText;
}

static NSString *ApolloRestoreTranslationLinks(NSString *translatedText, NSDictionary<NSString *, NSString *> *protectedLinks) {
    if (![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0) return translatedText;
    if (![protectedLinks isKindOfClass:[NSDictionary class]] || protectedLinks.count == 0) return translatedText;

    NSMutableString *restoredText = [translatedText mutableCopy];
    [protectedLinks enumerateKeysAndObjectsUsingBlock:^(NSString *token, NSString *originalLink, __unused BOOL *stop) {
        if (![token isKindOfClass:[NSString class]] || token.length == 0) return;
        if (![originalLink isKindOfClass:[NSString class]]) return;
        [restoredText replaceOccurrencesOfString:token
                                      withString:originalLink
                                         options:0
                                           range:NSMakeRange(0, restoredText.length)];
    }];
    return [restoredText copy];
}

static NSDictionary *ApolloAttributesWithoutLinkAttribute(NSDictionary *attributes) {
    if (![attributes isKindOfClass:[NSDictionary class]] || attributes.count == 0) return @{};
    NSMutableDictionary *filteredAttributes = [attributes mutableCopy];
    [filteredAttributes removeObjectForKey:NSLinkAttributeName];
    return [filteredAttributes copy];
}

static NSDictionary *ApolloVisualBaseAttributesFromAttributedString(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return @{};

    __block NSDictionary *firstAttributes = nil;
    __block NSDictionary *firstNonLinkAttributes = nil;
    [attributedText enumerateAttributesInRange:NSMakeRange(0, attributedText.length)
                                       options:0
                                    usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
        if (!firstAttributes) firstAttributes = attrs;
        if (!attrs[NSLinkAttributeName]) {
            firstNonLinkAttributes = attrs;
            *stop = YES;
        }
    }];

    return ApolloAttributesWithoutLinkAttribute(firstNonLinkAttributes ?: firstAttributes ?: @{});
}

static NSDictionary *ApolloFirstLinkAttributesFromAttributedString(NSAttributedString *attributedText) {
    if (![attributedText isKindOfClass:[NSAttributedString class]] || attributedText.length == 0) return nil;

    __block NSDictionary *linkAttributes = nil;
    [attributedText enumerateAttributesInRange:NSMakeRange(0, attributedText.length)
                                       options:0
                                    usingBlock:^(NSDictionary<NSAttributedStringKey, id> *attrs, __unused NSRange range, BOOL *stop) {
        if (attrs[NSLinkAttributeName]) {
            linkAttributes = attrs;
            *stop = YES;
        }
    }];
    return linkAttributes;
}

static id ApolloLinkAttributeValueForURLString(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    return url ?: urlString;
}

static BOOL ApolloRangeIntersectsRange(NSRange lhs, NSRange rhs) {
    if (lhs.location == NSNotFound || rhs.location == NSNotFound) return NO;
    return NSIntersectionRange(lhs, rhs).length > 0;
}

static NSString *ApolloDisplayStringByConvertingMarkdownLinks(NSString *text, NSMutableArray<NSDictionary *> **markdownLinksOut) {
    if (markdownLinksOut) *markdownLinksOut = [NSMutableArray array];
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return text;

    NSError *regexError = nil;
    NSRegularExpression *markdownLinkRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]\\n]+)\\]\\((https?://[^\\s)]+)(?:\\s+\\\"[^\\\"]*\\\")?\\)"
                                                                                       options:NSRegularExpressionCaseInsensitive
                                                                                         error:&regexError];
    if (regexError || !markdownLinkRegex) return text;

    NSArray<NSTextCheckingResult *> *matches = [markdownLinkRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (matches.count == 0) return text;

    NSMutableString *display = [NSMutableString string];
    NSMutableArray<NSDictionary *> *markdownLinks = markdownLinksOut ? *markdownLinksOut : nil;
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in matches) {
        if (match.range.location < cursor || NSMaxRange(match.range) > text.length) continue;
        [display appendString:[text substringWithRange:NSMakeRange(cursor, match.range.location - cursor)]];

        NSRange titleRange = [match rangeAtIndex:1];
        NSRange urlRange = [match rangeAtIndex:2];
        NSString *title = (titleRange.location != NSNotFound && NSMaxRange(titleRange) <= text.length) ? [text substringWithRange:titleRange] : nil;
        NSString *urlString = (urlRange.location != NSNotFound && NSMaxRange(urlRange) <= text.length) ? [text substringWithRange:urlRange] : nil;
        if (title.length == 0 || urlString.length == 0) {
            [display appendString:[text substringWithRange:match.range]];
            cursor = NSMaxRange(match.range);
            continue;
        }

        NSRange displayRange = NSMakeRange(display.length, title.length);
        [display appendString:title];
        if (markdownLinks && urlString.length > 0 && displayRange.length > 0) {
            [markdownLinks addObject:@{@"range": [NSValue valueWithRange:displayRange], @"url": urlString}];
        }
        cursor = NSMaxRange(match.range);
    }
    if (cursor < text.length) {
        [display appendString:[text substringFromIndex:cursor]];
    }
    return [display copy];
}

static void ApolloApplyLinkAttributes(NSMutableAttributedString *attributedString,
                                      NSRange range,
                                      NSString *urlString,
                                      NSDictionary *baseAttributes,
                                      NSDictionary *sourceLinkAttributes) {
    if (![attributedString isKindOfClass:[NSMutableAttributedString class]]) return;
    if (range.location == NSNotFound || range.length == 0 || NSMaxRange(range) > attributedString.length) return;
    id linkValue = ApolloLinkAttributeValueForURLString(urlString);
    if (!linkValue) return;

    NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithDictionary:baseAttributes ?: @{}];
    if ([sourceLinkAttributes isKindOfClass:[NSDictionary class]]) {
        [attributes addEntriesFromDictionary:sourceLinkAttributes];
    }
    attributes[NSLinkAttributeName] = linkValue;
    [attributedString addAttributes:attributes range:range];
}

static NSAttributedString *ApolloTranslatedAttributedStringPreservingVisualLinks(NSAttributedString *visualBase,
                                                                                 NSString *translatedText) {
    if (![translatedText isKindOfClass:[NSString class]]) translatedText = @"";

    NSMutableArray<NSDictionary *> *markdownLinks = nil;
    NSString *displayText = ApolloDisplayStringByConvertingMarkdownLinks(translatedText, &markdownLinks);
    NSDictionary *baseAttributes = ApolloVisualBaseAttributesFromAttributedString(visualBase);
    NSDictionary *sourceLinkAttributes = ApolloFirstLinkAttributesFromAttributedString(visualBase);
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:displayText ?: @"" attributes:baseAttributes ?: @{}];

    for (NSDictionary *linkInfo in markdownLinks) {
        NSValue *rangeValue = linkInfo[@"range"];
        NSString *urlString = linkInfo[@"url"];
        if (![rangeValue isKindOfClass:[NSValue class]] || ![urlString isKindOfClass:[NSString class]]) continue;
        ApolloApplyLinkAttributes(attributed, rangeValue.rangeValue, urlString, baseAttributes, sourceLinkAttributes);
    }

    NSError *regexError = nil;
    NSRegularExpression *bareURLRegex = [NSRegularExpression regularExpressionWithPattern:@"(?i)\\bhttps?://[^\\s<>()\\[\\]{}\\\"']+"
                                                                                options:0
                                                                                  error:&regexError];
    if (!regexError && bareURLRegex && attributed.length > 0) {
        NSArray<NSTextCheckingResult *> *matches = [bareURLRegex matchesInString:attributed.string options:0 range:NSMakeRange(0, attributed.length)];
        for (NSTextCheckingResult *match in matches) {
            NSRange range = ApolloRangeByTrimmingTrailingURLPunctuation(attributed.string, match.range);
            if (range.length == 0 || NSMaxRange(range) > attributed.length) continue;

            BOOL overlapsMarkdownLink = NO;
            for (NSDictionary *linkInfo in markdownLinks) {
                NSValue *rangeValue = linkInfo[@"range"];
                if ([rangeValue isKindOfClass:[NSValue class]] && ApolloRangeIntersectsRange(range, rangeValue.rangeValue)) {
                    overlapsMarkdownLink = YES;
                    break;
                }
            }
            if (overlapsMarkdownLink) continue;

            NSString *urlString = [attributed.string substringWithRange:range];
            ApolloApplyLinkAttributes(attributed, range, urlString, baseAttributes, sourceLinkAttributes);
        }
    }

    return [attributed copy];
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

    if (ApolloTextQualifiesAsBodyCandidate(candidateText.string, commentBody)) {
        // Require the overlap to be a meaningful chunk, not just a stray word.
        NSUInteger overlap = MIN(candidate.length, body.length);
        return 75000 + (NSInteger)overlap;
    }

    NSUInteger prefixLength = MIN((NSUInteger)24, MIN(candidate.length, body.length));
    if (prefixLength >= 12) {
        NSString *candidatePrefix = [candidate substringToIndex:prefixLength];
        NSString *bodyPrefix = [body substringToIndex:prefixLength];
        if ([candidatePrefix isEqualToString:bodyPrefix] && ApolloTextQualifiesAsBodyCandidate(candidateText.string, commentBody)) {
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

static void ApolloForceRelayoutForTextNodeAndOwner(id owner, id textNode) {
    SEL invalidateSel = NSSelectorFromString(@"invalidateCalculatedLayout");
    SEL supernodeSel = NSSelectorFromString(@"supernode");
    SEL transitionSel = NSSelectorFromString(@"transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:");

    void (^nudgeObject)(id) = ^(id object) {
        if (!object) return;
        @try {
            if ([object respondsToSelector:invalidateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(object, invalidateSel);
            }
            if ([object respondsToSelector:@selector(setNeedsLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(object, @selector(setNeedsLayout));
            }
            if ([object respondsToSelector:@selector(setNeedsDisplay)]) {
                ((void (*)(id, SEL))objc_msgSend)(object, @selector(setNeedsDisplay));
            }
            if ([object isKindOfClass:[UIView class]]) {
                UIView *view = (UIView *)object;
                [view setNeedsLayout];
                [view layoutIfNeeded];
            }
        } @catch (__unused NSException *e) {}
    };

    nudgeObject(textNode);
    nudgeObject(owner);

    id current = textNode;
    id cellNode = nil;
    for (int hops = 0; current && hops < 8; hops++) {
        nudgeObject(current);
        const char *className = class_getName([current class]);
        if (!cellNode && className && strstr(className, "CellNode")) {
            cellNode = current;
        }
        if (![current respondsToSelector:supernodeSel]) break;
        @try { current = ((id (*)(id, SEL))objc_msgSend)(current, supernodeSel); }
        @catch (__unused NSException *e) { break; }
    }
    if (!cellNode) cellNode = owner;

    @try {
        if ([cellNode respondsToSelector:transitionSel]) {
            NSMethodSignature *sig = [cellNode methodSignatureForSelector:transitionSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = cellNode;
                inv.selector = transitionSel;
                BOOL animated = NO;
                BOOL async = NO;
                void (^completion)(void) = nil;
                [inv setArgument:&animated atIndex:2];
                [inv setArgument:&async atIndex:3];
                [inv setArgument:&completion atIndex:4];
                [inv invoke];
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloApplyTranslationToCellNode(id commentCellNode, RDKComment *comment, NSString *translatedText) {
    if (!commentCellNode || ![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0) return;
    if (!ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) return;

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
    BOOL textMatchesBody = ApolloTextQualifiesAsBodyCandidate(current.string, comment.body);
    BOOL textMatchesTranslation = translatedNorm.length > 0 && ApolloTextQualifiesAsBodyCandidate(current.string, translatedText);
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

    NSAttributedString *translatedAttr = ApolloTranslatedAttributedStringPreservingVisualLinks(current, translatedText);

    // Phase D — vote resilience. Mark this text node as ours BEFORE the
    // setAttributedText: write below, so the global setter hook sees the
    // marker and the swap-to-translated logic can trigger if Apollo later
    // overwrites the node (e.g. on vote/score-flair refresh).
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [comment.body copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translatedText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloRegisterOwnedTextNode(textNode);

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
    ApolloForceRelayoutForTextNodeAndOwner(commentCellNode, textNode);

    objc_setAssociatedObject(commentCellNode, kApolloTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Re-entrancy guard: stamp the cell node so the setNeedsLayout /
    // setNeedsDisplay hook below skips scheduling another reapply for the
    // next ~150ms. Without this, ASDK's layout invalidation propagates from
    // the text node up to the cell node, fires our hook, schedules a
    // reapply, which calls us again, ad infinitum (~100/sec).
    objc_setAssociatedObject(commentCellNode, kApolloRecentlyAppliedKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakCell = commentCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakCell;
        if (strong) objc_setAssociatedObject(strong, kApolloRecentlyAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });

    // Persist the translation by Reddit fullName so we can re-apply after
    // collapse/expand or cell reuse without hitting the network again.
    NSString *fullName = ApolloCommentFullName(comment);
    if (fullName.length > 0) {
        [sCommentTranslationByFullName setObject:translatedText forKey:fullName];
        ApolloMirrorSetComment(fullName, translatedText);
        objc_setAssociatedObject(commentCellNode, kApolloAppliedTranslationFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    ApolloMarkVisibleTranslationApplied(comment.body, translatedText);
}

static void ApolloRestoreOriginalForCellNode(id commentCellNode, RDKComment *comment) {
    if (!commentCellNode) return;

    id currentBodyNode = ApolloBestCommentTextNode(commentCellNode, comment);
    id associatedNode = objc_getAssociatedObject(commentCellNode, kApolloTranslatedTextNodeKey);
    id textNode = currentBodyNode ?: associatedNode;
    if (!textNode) return;

    // Capture the cached translated body BEFORE clearing ownership keys, so
    // we can decide below whether the textNode actually still shows our
    // translation (safe to write saved-original) or has been reused for a
    // different comment (must NOT overwrite — the saved original would be
    // stale and would clobber the new comment's correct text).
    NSString *cachedTranslatedBody = objc_getAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey);
    NSString *cachedOriginalBody = objc_getAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey);

    // Drop ownership BEFORE writing original text back, otherwise the vote-
    // resilience hook would swap the original right back to translated.
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

    // Reuse-safety gate: only write the saved-original if the textNode
    // currently shows our cached translated body (i.e. the textNode really
    // is still displaying our stale translation). If the textNode has been
    // reused for a different comment, leave Apollo's freshly-rendered text
    // alone — clearing the ownership keys above is enough to prevent the
    // global setAttributedText hook from re-translating it.
    NSAttributedString *currentAttr = nil;
    @try {
        currentAttr = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
    } @catch (__unused NSException *e) {
        return;
    }
    if (![currentAttr isKindOfClass:[NSAttributedString class]]) return;

    NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    BOOL originalFromCommentModel = NO;
    if (![original isKindOfClass:[NSAttributedString class]]) {
        NSString *modelBody = [comment.body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (modelBody.length == 0) return;
        original = ApolloTranslatedAttributedStringPreservingVisualLinks(currentAttr, modelBody);
        originalFromCommentModel = [original isKindOfClass:[NSAttributedString class]];
        if (!originalFromCommentModel) return;
    }
    NSString *currentText = [currentAttr isKindOfClass:[NSAttributedString class]] ? currentAttr.string : nil;
    BOOL displaysOurTranslation = NO;
    if ([cachedTranslatedBody isKindOfClass:[NSString class]] && cachedTranslatedBody.length > 0 && currentText.length > 0) {
        displaysOurTranslation = ApolloTextQualifiesAsBodyCandidate(currentText, cachedTranslatedBody);
    }
    // Also accept the case where the current text already matches the saved
    // original (idempotent restore — will be a no-op write but harmless).
    BOOL displaysSavedOriginal = NO;
    if (!displaysOurTranslation && [cachedOriginalBody isKindOfClass:[NSString class]] && cachedOriginalBody.length > 0 && currentText.length > 0) {
        displaysSavedOriginal = ApolloTextQualifiesAsBodyCandidate(currentText, cachedOriginalBody);
    }
    BOOL shouldForceModelOriginal = NO;
    if (!displaysOurTranslation && !displaysSavedOriginal && originalFromCommentModel && currentText.length > 0) {
        shouldForceModelOriginal = !ApolloTextQualifiesAsBodyCandidate(currentText, comment.body);
    }
    if (!displaysOurTranslation && !displaysSavedOriginal && !shouldForceModelOriginal) {
        ApolloLog(@"[Translation] Restore skipped: textNode no longer shows our translation (likely reused)");
        return;
    }

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
    ApolloForceRelayoutForTextNodeAndOwner(commentCellNode, textNode);

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

static UIView *ApolloViewForTextObject(id object) {
    if ([object isKindOfClass:[UIView class]]) return (UIView *)object;
    @try {
        SEL isLoadedSel = NSSelectorFromString(@"isNodeLoaded");
        if ([object respondsToSelector:isLoadedSel] && !((BOOL (*)(id, SEL))objc_msgSend)(object, isLoadedSel)) {
            return nil;
        }
        if ([object respondsToSelector:@selector(view)]) {
            id view = ((id (*)(id, SEL))objc_msgSend)(object, @selector(view));
            if ([view isKindOfClass:[UIView class]]) return (UIView *)view;
        }
    } @catch (__unused NSException *e) {
    }
    return nil;
}

static CGFloat ApolloFirstVisibleCommentTopY(UIViewController *viewController, UITableView *tableView) {
    CGFloat top = CGFLOAT_MAX;
    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSelector]) continue;
        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        if (!ApolloCommentFromCellNode(cellNode)) continue;
        CGRect frame = [cell convertRect:cell.bounds toView:viewController.view];
        top = MIN(top, CGRectGetMinY(frame));
    }
    return top;
}

static id ApolloBestVisiblePostBodyTextNodeForController(UIViewController *viewController, UITableView *tableView, RDKLink *link) {
    if (!viewController.view) return nil;
    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:128];
    ApolloCollectAttributedTextNodes(viewController.view, 8, visited, candidates);

    CGFloat firstCommentTop = ApolloFirstVisibleCommentTopY(viewController, tableView);
    if (firstCommentTop == CGFLOAT_MAX) firstCommentTop = CGRectGetHeight(viewController.view.bounds);

    id best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id candidate in candidates) {
        NSString *text = ApolloVisibleTextFromNode(candidate);
        if (text.length == 0 || ApolloPostTextLooksLikeMetadata(text, link)) continue;

        UIView *view = ApolloViewForTextObject(candidate);
        if (!view || view.hidden || view.alpha < 0.01) continue;
        CGRect frame = [view convertRect:view.bounds toView:viewController.view];
        if (CGRectIsEmpty(frame) || CGRectGetMaxY(frame) <= 0) continue;

        // Post body sits above the first comment. Avoid accidentally grabbing
        // translated comment text lower in the table while still allowing long
        // selftext that scrolls near the first comment boundary.
        if (CGRectGetMinY(frame) >= firstCommentTop - 8.0) continue;

        NSInteger score = (NSInteger)text.length;
        if (CGRectGetMaxY(frame) < firstCommentTop) score += 1000;
        if (score > bestScore) {
            bestScore = score;
            best = candidate;
        }
    }
    return best;
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
    if (!ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) return;
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

    NSAttributedString *translatedAttr = ApolloTranslatedAttributedStringPreservingVisualLinks(current, translatedText);

    // Same vote-resilience marker pattern as comment cells.
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [body copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translatedText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloRegisterOwnedTextNode(textNode);

    @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), translatedAttr); }
    @catch (__unused NSException *e) { return; }

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    objc_setAssociatedObject(headerCellNode, kApolloHeaderTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Re-entrancy guard + link recovery for vote-tap rebuild (see comment
    // cell apply above for rationale).
    objc_setAssociatedObject(headerCellNode, kApolloRecentlyAppliedKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (link) {
        objc_setAssociatedObject(headerCellNode, kApolloAppliedHeaderLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Stash the (link, body, translated) tuple on the visible comments VC so
    // headerReapply can recover post-vote when the header cell loses its
    // link and no fresh apply has stamped this particular cell instance yet.
    UIViewController *currentVC = sVisibleCommentsViewController;
    if (currentVC && link && body.length > 0) {
        NSDictionary *tuple = @{ @"link": link, @"body": body, @"translated": translatedText };
        objc_setAssociatedObject(currentVC, kApolloLastAppliedPostBodyKey, tuple, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    __weak id weakHeader = headerCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakHeader;
        if (strong) objc_setAssociatedObject(strong, kApolloRecentlyAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });

    NSString *fullName = link.fullName;
    if (fullName.length > 0) {
        [sLinkTranslationByFullName setObject:translatedText forKey:fullName];
        ApolloMirrorSetLink(fullName, translatedText);
        objc_setAssociatedObject(headerCellNode, kApolloAppliedHeaderTranslationFullNameKey, fullName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    ApolloMarkVisibleTranslationApplied(body, translatedText);
}

static void ApolloApplyTranslationToPostTextNode(id owner, id textNode, NSString *sourceText, NSString *translatedText) {
    if (!owner || !textNode) return;
    if (![sourceText isKindOfClass:[NSString class]] || sourceText.length == 0) return;
    if (![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0) return;
    if (!ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) return;

    NSAttributedString *current = nil;
    @try { current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText)); }
    @catch (__unused NSException *e) { return; }
    if (![current isKindOfClass:[NSAttributedString class]]) return;

    NSString *currentNorm = ApolloNormalizeTextForCompare(current.string);
    NSString *sourceNorm = ApolloNormalizeTextForCompare(sourceText);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);
    if (currentNorm.length == 0 || sourceNorm.length == 0) return;
    BOOL textMatchesSource = [currentNorm isEqualToString:sourceNorm] ||
                             [currentNorm containsString:sourceNorm] ||
                             [sourceNorm containsString:currentNorm];
    BOOL textMatchesTranslation = translatedNorm.length > 0 &&
        ([currentNorm isEqualToString:translatedNorm] ||
         [currentNorm containsString:translatedNorm] ||
         [translatedNorm containsString:currentNorm]);
    if (!textMatchesSource && !textMatchesTranslation) return;
    if (textMatchesTranslation && !textMatchesSource) return;

    NSAttributedString *originalSaved = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![originalSaved isKindOfClass:[NSAttributedString class]]) {
        objc_setAssociatedObject(textNode, kApolloOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSAttributedString *translatedAttr = ApolloTranslatedAttributedStringPreservingVisualLinks(current, translatedText);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [sourceText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translatedText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloRegisterOwnedTextNode(textNode);

    @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), translatedAttr); }
    @catch (__unused NSException *e) { return; }

    if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
    }
    if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
        ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
    }

    objc_setAssociatedObject(owner, kApolloHeaderTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Mirror the per-VC stash so headerReapply has something to recover
    // from even when this code path (not ApolloApplyTranslationToHeaderCellNode)
    // performed the original apply.
    {
        UIViewController *currentVC = sVisibleCommentsViewController;
        RDKLink *link = currentVC ? ApolloLinkFromController(currentVC) : nil;
        if (currentVC && sourceText.length > 0 && translatedText.length > 0) {
            NSMutableDictionary *tuple = [NSMutableDictionary dictionaryWithDictionary:@{ @"body": sourceText, @"translated": translatedText }];
            if (link) tuple[@"link"] = link;
            objc_setAssociatedObject(currentVC, kApolloLastAppliedPostBodyKey, tuple, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    ApolloMarkVisibleTranslationApplied(sourceText, translatedText);
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

// MARK: - Script-composition guard (mixed-language detection)
//
// NLLanguageRecognizer scores only its top hypotheses and gives disproportionate
// weight to a unique writing system. One foreign-script word deliberately embedded in
// an otherwise-Latin sentence (e.g. someone explaining how a word is *written* in
// Japanese: "you spell it さん") can pull the dominant guess to Japanese, so the whole
// string gets translated and the embedded word — the entire point of the comment — is
// mangled. We can't tell Apple/Google to skip part of a string, so the lever is
// detection: when the writing system is overwhelmingly Latin, don't let a stray
// non-Latin token flip the detected language.

typedef NS_ENUM(NSInteger, ApolloScriptBucket) {
    ApolloScriptNeutral = 0,   // whitespace/digits/punctuation/emoji/symbols — excluded
    ApolloScriptLatin,
    ApolloScriptHan,
    ApolloScriptHiragana,
    ApolloScriptKatakana,
    ApolloScriptHangul,
    ApolloScriptCyrillic,
    ApolloScriptArabic,
    ApolloScriptGreek,
    ApolloScriptThai,
    ApolloScriptHebrew,
    ApolloScriptDevanagari,
    ApolloScriptBucketCount
};

static ApolloScriptBucket ApolloScriptBucketForCodepoint(UTF32Char c) {
    if ((c >= 0x0041 && c <= 0x005A) || (c >= 0x0061 && c <= 0x007A) ||
        (c >= 0x00C0 && c <= 0x024F) || (c >= 0x1E00 && c <= 0x1EFF)) return ApolloScriptLatin;
    if (c >= 0x3040 && c <= 0x309F) return ApolloScriptHiragana;
    if (c >= 0x30A0 && c <= 0x30FF) return ApolloScriptKatakana;
    if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) ||
        (c >= 0xF900 && c <= 0xFAFF) || (c >= 0x20000 && c <= 0x2A6DF)) return ApolloScriptHan;
    if ((c >= 0xAC00 && c <= 0xD7A3) || (c >= 0x1100 && c <= 0x11FF) ||
        (c >= 0x3130 && c <= 0x318F)) return ApolloScriptHangul;
    if (c >= 0x0400 && c <= 0x052F) return ApolloScriptCyrillic;
    if ((c >= 0x0600 && c <= 0x06FF) || (c >= 0x0750 && c <= 0x077F)) return ApolloScriptArabic;
    if ((c >= 0x0370 && c <= 0x03FF) || (c >= 0x1F00 && c <= 0x1FFF)) return ApolloScriptGreek;
    if (c >= 0x0E00 && c <= 0x0E7F) return ApolloScriptThai;
    if (c >= 0x0590 && c <= 0x05FF) return ApolloScriptHebrew;
    if (c >= 0x0900 && c <= 0x097F) return ApolloScriptDevanagari;
    // Everything else (digits, punctuation, whitespace, emoji, symbols, and scripts
    // we don't explicitly bucket) is treated as script-neutral and excluded from the
    // denominator so it can't skew the fraction.
    return ApolloScriptNeutral;
}

// Fraction (0..1) of script-bearing characters belonging to the single most common
// writing system; writes that bucket and the script-bearing char count to the outs.
static double ApolloDominantScriptFraction(NSString *text, ApolloScriptBucket *outBucket, NSUInteger *outScriptChars) {
    if (outBucket) *outBucket = ApolloScriptNeutral;
    if (outScriptChars) *outScriptChars = 0;
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return 0.0;

    NSUInteger counts[ApolloScriptBucketCount];
    memset(counts, 0, sizeof(counts));
    NSUInteger total = 0;
    NSUInteger len = text.length;
    for (NSUInteger i = 0; i < len; ) {
        unichar hi = [text characterAtIndex:i];
        UTF32Char c = hi;
        NSUInteger step = 1;
        if (CFStringIsSurrogateHighCharacter(hi) && (i + 1) < len) {
            unichar lo = [text characterAtIndex:(i + 1)];
            if (CFStringIsSurrogateLowCharacter(lo)) {
                c = CFStringGetLongCharacterForSurrogatePair(hi, lo);
                step = 2;
            }
        }
        i += step;
        ApolloScriptBucket b = ApolloScriptBucketForCodepoint(c);
        if (b == ApolloScriptNeutral) continue;
        counts[b]++;
        total++;
    }
    if (total == 0) return 0.0;
    ApolloScriptBucket best = ApolloScriptNeutral;
    NSUInteger bestN = 0;
    for (NSInteger b = 1; b < ApolloScriptBucketCount; b++) {
        if (counts[b] > bestN) { bestN = counts[b]; best = (ApolloScriptBucket)b; }
    }
    if (outBucket) *outBucket = best;
    if (outScriptChars) *outScriptChars = total;
    return (double)bestN / (double)total;
}

// Whether a (normalized) language code is written in the Latin alphabet. Used so the
// script guard can drop a non-Latin hypothesis for overwhelmingly-Latin text. Listed
// the other way (deny non-Latin) so unknown codes default to Latin (the common case).
static BOOL ApolloLanguageUsesLatinScript(NSString *code) {
    NSString *norm = ApolloNormalizeLanguageCode(code) ?: [code lowercaseString];
    if (norm.length == 0) return NO;
    static NSSet<NSString *> *nonLatin;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nonLatin = [NSSet setWithArray:@[
            @"ja", @"zh", @"ko", @"ru", @"uk", @"bg", @"sr", @"mk", @"be", @"mn",
            @"ar", @"fa", @"ur", @"ps", @"he", @"yi", @"el", @"th", @"lo", @"my", @"km",
            @"hi", @"bn", @"ta", @"te", @"kn", @"ml", @"mr", @"gu", @"pa", @"ne", @"si",
            @"ka", @"am", @"hy"
        ]];
    });
    return ![nonLatin containsObject:norm];
}

// YES when `text` is overwhelmingly Latin script (so we should ignore a stray non-Latin
// top hypothesis). 12-char floor avoids over-triggering on tiny strings.
static BOOL ApolloTextIsOverwhelminglyLatin(NSString *text) {
    ApolloScriptBucket bucket = ApolloScriptNeutral;
    NSUInteger scriptChars = 0;
    double frac = ApolloDominantScriptFraction(text, &bucket, &scriptChars);
    return (bucket == ApolloScriptLatin && frac >= 0.85 && scriptChars >= 12);
}

static NSString *ApolloDetectDominantLanguage(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Short strings produce unreliable detections ("lol", "wow", etc.). Skip them.
    if (trimmed.length < 8) return nil;
    if (@available(iOS 12.0, *)) {
        NLLanguageRecognizer *recognizer = [[NLLanguageRecognizer alloc] init];
        [recognizer processString:trimmed];
        // Top 3 (not 1) so the script guard can fall back to the best Latin hypothesis
        // when a stray non-Latin token would otherwise win.
        NSDictionary<NLLanguage, NSNumber *> *hyps = [recognizer languageHypothesesWithMaximum:3];
        BOOL latinDominant = ApolloTextIsOverwhelminglyLatin(trimmed);
        NSString *dominant = nil;
        double bestProb = 0.0;
        for (NLLanguage lang in hyps) {
            if (latinDominant && !ApolloLanguageUsesLatinScript((NSString *)lang)) continue;
            double p = hyps[lang].doubleValue;
            if (p > bestProb) { bestProb = p; dominant = (NSString *)lang; }
        }
        // Require reasonable confidence so we don't accidentally skip ambiguous text.
        if (bestProb < 0.55 || dominant.length == 0) return nil;
        return ApolloNormalizeLanguageCode(dominant);
    }
    return nil;
}

// Returns YES if the user has asked us not to translate text in `detectedLang`.
// We intentionally do NOT short-circuit when detected == target: many comments are
// mixed-language (e.g. mostly English with embedded Japanese), and NLLanguageRecognizer
// will return only the dominant language. Letting the provider see the full text means
// the embedded foreign chunks still get translated.
static BOOL ApolloShouldSkipTranslationForText(NSString *text, NSString *targetLanguage) {
    (void)targetLanguage;
    NSArray<NSString *> *skip = sTranslationSkipLanguages;
    if (![skip isKindOfClass:[NSArray class]] || skip.count == 0) return NO;

    NSString *detected = ApolloDetectDominantLanguage(text);
    if (detected.length == 0) return NO;

    for (NSString *code in skip) {
        if (![code isKindOfClass:[NSString class]]) continue;
        if ([code.lowercaseString isEqualToString:detected]) return YES;
    }
    return NO;
}

// Strict source-language detector for the Apple backend. Apple needs an EXPLICIT
// source, and a wrong guess is actively harmful: it spins up a bogus session and
// makes Apple prompt to download the wrong language (e.g. short Portuguese/Italian
// text misread as Indonesian/Danish), which then fails and starves the real
// languages of their model downloads. So we only accept a CONFIDENT, UNAMBIGUOUS
// top guess — high probability AND a clear margin over the runner-up. Distinct-script
// languages (Japanese/Chinese/Korean) score ~0.99 with a negligible runner-up and
// pass trivially; ambiguous short Romance text is left untranslated rather than
// mis-assigned. (No context "remember the last language" fallback — one bad guess
// would poison every short snippet after it.)
static NSString *ApolloDetectSourceLanguageForApple(NSString *text) {
    if (![text isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Low length floor so short CJK comments (e.g. "こんにちわ") still detect — those
    // are unique-script and score very high. The confidence + margin guards below keep
    // short ambiguous Latin text from being mis-assigned.
    if (trimmed.length < 4) return nil;
    if (@available(iOS 12.0, *)) {
        NLLanguageRecognizer *recognizer = [[NLLanguageRecognizer alloc] init];
        [recognizer processString:trimmed];
        NSDictionary<NLLanguage, NSNumber *> *hyps = [recognizer languageHypothesesWithMaximum:3];
        // Script-composition guard (see ApolloDetectDominantLanguage): never pick a
        // non-Latin SOURCE for overwhelmingly-Latin text, so a stray hiragana/CJK token
        // can't make Apple translate an English sentence as Japanese (mangling the very
        // word the author wrote in that script). CJK-dominant text is unaffected.
        BOOL latinDominant = ApolloTextIsOverwhelminglyLatin(trimmed);
        NSString *best = nil;
        double bestProb = 0.0, secondProb = 0.0;
        for (NLLanguage lang in hyps) {
            if (latinDominant && !ApolloLanguageUsesLatinScript((NSString *)lang)) continue;
            double p = hyps[lang].doubleValue;
            if (p > bestProb) { secondProb = bestProb; bestProb = p; best = (NSString *)lang; }
            else if (p > secondProb) { secondProb = p; }
        }
        // Confident (>=0.62) AND a clear winner (runner-up negligible, or top at least
        // ~1.8x the runner-up). This rejects the ambiguous guesses that produced the
        // bogus id/da sessions while still accepting real sentences in any language.
        if (best.length > 0 && bestProb >= 0.62 &&
            (secondProb <= 0.0001 || bestProb >= secondProb * 1.8)) {
            return ApolloNormalizeLanguageCode(best);
        }
    }
    return nil;
}

// On-device translation via Apple's Translation framework (iOS 18.0+), bridged
// through the @objc ApolloAppleTranslator Swift shim. Same block contract as the
// Google/Libre providers, with two Apple-specific behaviors:
//
//   1. We detect the SOURCE language client-side (NLLanguageRecognizer) and pass it
//      explicitly. Apple's `source: nil` auto-detect, on failure, silently presents
//      a system "select a language" picker and suspends the call — which would block
//      every queued translation behind it. An explicit source avoids that entirely.
//      If we can't confidently detect the source, we skip (leave original) rather
//      than hand Apple ambiguous text.
//   2. No cross-provider fallback: if Apple is selected it stays Apple. On a missing
//      language model the shim drives Apple's one-time system download sheet; on any
//      hard failure the original text is left intact.
static void ApolloTranslateViaApple(NSString *text,
                                    NSString *targetLanguage,
                                    void (^completion)(NSString *translated, NSError *error)) {
#if APOLLO_HAS_APPLE_TRANSLATE
    NSString *source = ApolloDetectSourceLanguageForApple(text);
    if (source.length == 0) {
        // Couldn't confidently fingerprint this snippet — don't guess (a wrong source
        // makes Apple prompt for the wrong language and fail). Leave the original text.
        NSError *err = [NSError errorWithDomain:@"ApolloTranslation" code:301
            userInfo:@{NSLocalizedDescriptionKey: @"Apple: source language undetected"}];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        return;
    }

    NSString *normTarget = ApolloNormalizeLanguageCode(targetLanguage) ?: targetLanguage;
    if ([source isEqualToString:[normTarget lowercaseString]]) {
        // Already in the target language — no-op success (Apple can't translate X->X).
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(text, nil); });
        return;
    }

    [ApolloAppleTranslator translate:text
                                from:source
                                  to:targetLanguage
                          completion:^(NSString *translated, NSError *error) {
        // The Swift shim already delivers on the main thread.
        if (completion) completion(translated, error);
    }];
#else
    NSError *error = [NSError errorWithDomain:@"ApolloTranslation" code:300
        userInfo:@{NSLocalizedDescriptionKey: @"Apple translation backend unavailable in this build"}];
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
    }
#endif
}

static void ApolloTranslateTextWithFallback(NSString *text,
                                            NSString *targetLanguage,
                                            void (^completion)(NSString *translated, NSError *error)) {
    // User-controlled skip: if the source language is in the skip list, or already
    // matches the target, return the original text untouched. Downstream callers
    // treat this as a successful no-op (cache will store source==translation,
    // making future hits instant).
    if (ApolloShouldSkipTranslationForText(text, targetLanguage)) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(text, nil); });
        }
        return;
    }

    // Apple is on-device and deliberately has NO cross-provider fallback: if the
    // user picked Apple, translation stays Apple (we'd rather prompt to download a
    // language model than silently substitute Google output). On failure the error
    // propagates and the caller leaves the original text. (A future opt-in fallback
    // could be added here.)
    if ([sTranslationProvider isEqualToString:@"apple"]) {
        ApolloTranslateViaApple(text, targetLanguage, completion);
        return;
    }

    // Provider can be: "google" or "libre". Anything unrecognized defaults to Google.
    // Primary = user's choice; fallback = the other one.
    NSString *primaryProvider = sTranslationProvider;
    if (![primaryProvider isEqualToString:@"libre"] &&
        ![primaryProvider isEqualToString:@"google"]) {
        primaryProvider = @"google";
    }

    void (^callPrimary)(void (^)(NSString *, NSError *)) = ^(void (^cb)(NSString *, NSError *)) {
        if ([primaryProvider isEqualToString:@"libre"]) {
            ApolloTranslateViaLibre(text, targetLanguage, cb);
        } else {
            ApolloTranslateViaGoogle(text, targetLanguage, cb);
        }
    };

    // If the primary provider fails, fall back to the other one.
    void (^fallback)(void) = ^{
        if ([primaryProvider isEqualToString:@"google"]) {
            ApolloTranslateViaLibre(text, targetLanguage, completion);
        } else {
            ApolloTranslateViaGoogle(text, targetLanguage, completion);
        }
    };

    callPrimary(^(NSString *translated, NSError *error) {
        if ([translated isKindOfClass:[NSString class]] && translated.length > 0) {
            completion(translated, nil);
            return;
        }
        fallback();
    });
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

    NSDictionary<NSString *, NSString *> *protectedLinks = nil;
    NSString *requestText = ApolloProtectTranslationLinks(sourceText, &protectedLinks);

    ApolloTranslateTextWithFallback(requestText, targetLanguage, ^(NSString *translated, NSError *error) {
        NSString *restoredTranslation = ApolloRestoreTranslationLinks(translated, protectedLinks);
        NSArray *callbacks = nil;
        @synchronized (sPendingTranslationCallbacks) {
            callbacks = [sPendingTranslationCallbacks[cacheKey] copy] ?: @[];
            [sPendingTranslationCallbacks removeObjectForKey:cacheKey];
        }

        if ([restoredTranslation isKindOfClass:[NSString class]] && restoredTranslation.length > 0) {
            [sTranslationCache setObject:restoredTranslation forKey:cacheKey];
        }

        for (id callbackObj in callbacks) {
            void (^callback)(NSString *, NSError *) = callbackObj;
            callback(restoredTranslation, error);
        }
    });
}

BOOL ApolloRichPreviewTranslationShouldTranslateForNode(id node) {
    if (!sEnableBulkTranslation) return NO;

    UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode(node);
    if (enclosingVC && ApolloClassLooksLikeCommentsViewController([enclosingVC class])) {
        return ApolloControllerIsInTranslatedMode(enclosingVC);
    }

    UIViewController *feedVC = ApolloFindTopmostVisibleFeedVC();
    if (feedVC && [objc_getAssociatedObject(feedVC, kApolloFeedTranslationVCKey) boolValue]) {
        return sTranslatePostTitles && ApolloFeedTitlesShouldShowTranslated(feedVC);
    }

    if (sVisibleCommentsViewController) {
        return ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController);
    }

    return sTranslatePostTitles && ApolloFeedTitlesShouldShowTranslated(feedVC);
}

static NSString *ApolloRichPreviewTranslationCacheKey(NSURL *url, NSString *field, NSString *sourceText, NSString *targetLanguage) {
    NSString *urlKey = url.absoluteString.length > 0 ? url.absoluteString : @"(no-url)";
    NSString *fieldKey = field.length > 0 ? field : @"text";
    return [NSString stringWithFormat:@"rich-preview|%@|%@|%lu|%lu",
            targetLanguage ?: @"en",
            fieldKey,
            (unsigned long)urlKey.hash,
            (unsigned long)(sourceText ?: @"").hash];
}

NSString *ApolloRichPreviewTranslatedTextIfAvailable(NSURL *url, NSString *field, NSString *sourceText, id ownerNode) {
    NSString *trimmed = ApolloTrimmedString(sourceText);
    if (trimmed.length < 3) return nil;
    if (!ApolloRichPreviewTranslationShouldTranslateForNode(ownerNode)) return nil;

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) return nil;

    NSString *detectionText = ApolloProtectTranslationLinks(trimmed, NULL);
    NSString *detected = ApolloDetectDominantLanguage(detectionText);
    if ([detected isEqualToString:targetLanguage]) return nil;

    NSString *cacheKey = ApolloRichPreviewTranslationCacheKey(url, field, trimmed, targetLanguage);
    NSString *cached = [sTranslationCache objectForKey:cacheKey];
    if (ApolloTranslatedTextDiffersFromSource(trimmed, cached)) return cached;

    @synchronized (sRichPreviewTranslationInFlightKeys) {
        if (!sRichPreviewTranslationInFlightKeys) sRichPreviewTranslationInFlightKeys = [NSMutableSet set];
        if ([sRichPreviewTranslationInFlightKeys containsObject:cacheKey]) return nil;
        [sRichPreviewTranslationInFlightKeys addObject:cacheKey];
    }

    ApolloRequestTranslation(cacheKey, trimmed, targetLanguage, ^(NSString *translated, NSError *error) {
        @synchronized (sRichPreviewTranslationInFlightKeys) {
            [sRichPreviewTranslationInFlightKeys removeObject:cacheKey];
        }

        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) ApolloLog(@"[Translation] Rich preview translate failed field=%@ url=%@: %@",
                                 field ?: @"text",
                                 url.absoluteString ?: @"(no-url)",
                                 error.localizedDescription ?: @"unknown");
            return;
        }
        if (!ApolloTranslatedTextDiffersFromSource(trimmed, translated)) return;

        if (sVisibleCommentsViewController && ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) {
            ApolloMarkVisibleTranslationApplied(trimmed, translated);
        } else {
            ApolloMarkVisibleFeedTitleApplied(trimmed, translated);
        }

        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification
                                                            object:nil
                                                          userInfo:url ? @{@"url": url, @"reason": @"translation-result"} : @{@"reason": @"translation-result"}];
    });

    return nil;
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
            ApolloMirrorRemoveComment(fullName);
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
        // Detect on link-stripped text so URLs / markdown link targets don't
        // pollute the signal. A comment like "[title](https://record.pt/...)
        // body in Portuguese" would otherwise feed NLLanguageRecognizer a
        // big chunk of URL path that can pull detection toward English /
        // generic and skip translation.
        NSString *detectionText = ApolloProtectTranslationLinks(sourceText, NULL);
        NSString *detected = ApolloDetectDominantLanguage(detectionText);
        if ([detected isEqualToString:targetLanguage]) {
            // Log only once per fullName per session — this path is hit on
            // every visibility / scroll tick for the same cell otherwise.
            NSString *logKey = fullName.length > 0 ? fullName : nil;
            BOOL shouldLog = YES;
            if (logKey) {
                @synchronized (sLoggedSkippedCommentFullNames) {
                    if ([sLoggedSkippedCommentFullNames containsObject:logKey]) {
                        shouldLog = NO;
                    } else {
                        [sLoggedSkippedCommentFullNames addObject:logKey];
                    }
                }
            }
            if (shouldLog) {
                ApolloTranslationVerboseLog(@"[Translation] Skipping comment fullName=%@ — detected language matches target (%@)",
                                            logKey ?: @"(none)", targetLanguage);
            }
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
                ApolloMirrorSetComment(fullName, translated);
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
            ApolloMirrorSetComment(fullName, translated);
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
    if (!comment) {
        ApolloTranslationVerboseLog(@"[Translation/vote] commentReapply: no RDKComment on cellNode=%p", commentCellNode);
        return NO;
    }
    NSString *fullName = ApolloCommentFullName(comment);
    if (fullName.length == 0) {
        ApolloTranslationVerboseLog(@"[Translation/vote] commentReapply: empty fullName cellNode=%p", commentCellNode);
        return NO;
    }
    NSString *cached = [sCommentTranslationByFullName objectForKey:fullName];
    if (cached.length == 0) {
        ApolloTranslationVerboseLog(@"[Translation/vote] commentReapply: cache MISS fullName=%@", fullName);
        return NO;
    }
    ApolloTranslationVerboseLog(@"[Translation/vote] commentReapply: cache HIT fullName=%@ → applying (len=%lu)", fullName, (unsigned long)cached.length);
    ApolloApplyTranslationToCellNode(commentCellNode, comment, cached);
    return YES;
}

static void ApolloScheduleCachedTranslationReapplyForCellNode(id commentCellNode) {
    if (!commentCellNode || !sEnableBulkTranslation) return;
    if (!ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) return;
    if ([objc_getAssociatedObject(commentCellNode, kApolloReapplyScheduledKey) boolValue]) return;
    // Re-entrancy guard: skip if we just applied translation here. Breaks
    // the apply -> ASDK invalidates layout -> hook -> schedule loop.
    if ([objc_getAssociatedObject(commentCellNode, kApolloRecentlyAppliedKey) boolValue]) return;
    objc_setAssociatedObject(commentCellNode, kApolloReapplyScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloTranslationVerboseLog(@"[Translation/vote] commentReapply: SCHEDULED cellNode=%p", commentCellNode);
    __weak id weakNode = commentCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakNode;
        if (!strong) {
            ApolloTranslationVerboseLog(@"[Translation/vote] commentReapply: FIRED but cellNode dealloc'd");
            return;
        }
        objc_setAssociatedObject(strong, kApolloReapplyScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloReapplyCachedTranslationForCellNode(strong);
    });
}

// Re-applies a previously-translated post body from the link cache, without
// hitting the network or re-running language detection. Used when the post
// header cell node redisplays (e.g. after a vote tap rebuilds its content).
// Mirror of `ApolloReapplyCachedTranslationForCellNode` but for the post
// header path, declared early enough for the pre-Phase-D %hook below.
static void ApolloApplyTranslationToHeaderCellNode(id headerCellNode, RDKLink *link, NSString *sourceText, NSString *translatedText);
static NSString *ApolloPostBodyTextFromLink(RDKLink *link);
static NSString *ApolloVisiblePostCacheKey(RDKLink *link, NSString *sourceText, NSString *targetLanguage);
static NSString *ApolloResolvedTargetLanguageCode(void);
static RDKLink *ApolloLinkFromHeaderCellNode(id cellNode);

static BOOL ApolloReapplyCachedTranslationForHeaderCellNode(id headerCellNode) {
    if (!headerCellNode) return NO;
    RDKLink *link = ApolloLinkFromHeaderCellNode(headerCellNode);
    if (!link) {
        // Vote-tap rebuilds the header cell and clears its link ivars
        // momentarily. Fall back to the link we stashed when we last applied
        // translation, then to the controller's link.
        link = objc_getAssociatedObject(headerCellNode, kApolloAppliedHeaderLinkKey);
        if (!link) link = ApolloLinkFromController(sVisibleCommentsViewController);
    }
    NSDictionary *vcStash = nil;
    if (sVisibleCommentsViewController) {
        id raw = objc_getAssociatedObject(sVisibleCommentsViewController, kApolloLastAppliedPostBodyKey);
        if ([raw isKindOfClass:[NSDictionary class]]) vcStash = (NSDictionary *)raw;
    }
    if (!link && vcStash) link = vcStash[@"link"];

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) {
        ApolloTranslationVerboseLog(@"[Translation/vote] headerReapply: empty targetLanguage");
        return NO;
    }

    NSString *trimmed = nil;
    NSString *cached = nil;
    if (link) {
        NSString *body = ApolloPostBodyTextFromLink(link);
        if ([body isKindOfClass:[NSString class]] && body.length > 0) {
            trimmed = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *cacheKey = trimmed.length > 0 ? ApolloVisiblePostCacheKey(link, trimmed, targetLanguage) : nil;
            cached = cacheKey.length > 0 ? [sLinkTranslationByFullName objectForKey:cacheKey] : nil;
        }
    }

    // Final fallback: use the per-VC stash directly (covers the case where
    // the link was found via ApolloApplyTranslationToPostTextNode and the
    // cache key calculation differs from what we stored).
    if (cached.length == 0 && vcStash) {
        NSString *stashBody = vcStash[@"body"];
        NSString *stashTranslated = vcStash[@"translated"];
        if ([stashBody isKindOfClass:[NSString class]] && stashBody.length > 0 &&
            [stashTranslated isKindOfClass:[NSString class]] && stashTranslated.length > 0) {
            trimmed = [stashBody stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            cached = stashTranslated;
            if (!link) link = vcStash[@"link"];
            ApolloTranslationVerboseLog(@"[Translation/vote] headerReapply: using per-VC stash (linkResolved=%d, len=%lu)", link != nil, (unsigned long)cached.length);
        }
    }

    if (cached.length == 0 || trimmed.length == 0) {
        ApolloTranslationVerboseLog(@"[Translation/vote] headerReapply: cache MISS (link=%@ body=%lu)", link.fullName ?: @"<nil>", (unsigned long)trimmed.length);
        return NO;
    }

    ApolloTranslationVerboseLog(@"[Translation/vote] headerReapply: cache HIT fullName=%@ → applying (len=%lu)", link.fullName ?: @"<from-stash>", (unsigned long)cached.length);
    ApolloApplyTranslationToHeaderCellNode(headerCellNode, link, trimmed, cached);
    return YES;
}

static void ApolloScheduleCachedTranslationReapplyForHeaderCellNode(id headerCellNode) {
    if (!headerCellNode || !sEnableBulkTranslation) return;
    if (!ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) return;
    if ([objc_getAssociatedObject(headerCellNode, kApolloHeaderReapplyScheduledKey) boolValue]) return;
    if ([objc_getAssociatedObject(headerCellNode, kApolloRecentlyAppliedKey) boolValue]) return;
    objc_setAssociatedObject(headerCellNode, kApolloHeaderReapplyScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloTranslationVerboseLog(@"[Translation/vote] headerReapply: SCHEDULED header=%p", headerCellNode);
    __weak id weakNode = headerCellNode;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strong = weakNode;
        if (!strong) {
            ApolloTranslationVerboseLog(@"[Translation/vote] headerReapply: FIRED but header dealloc'd");
            return;
        }
        objc_setAssociatedObject(strong, kApolloHeaderReapplyScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloReapplyCachedTranslationForHeaderCellNode(strong);
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

    // One-shot diagnostic so we can see exactly why a post body did or did
    // not get gated. Logs once per fullName per session.
    {
        NSString *fn = link.fullName ?: @"<no-link>";
        static NSMutableSet<NSString *> *sLoggedDiag;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{ sLoggedDiag = [NSMutableSet set]; });
        BOOL shouldLog = NO;
        @synchronized (sLoggedDiag) {
            if (![sLoggedDiag containsObject:fn]) { [sLoggedDiag addObject:fn]; shouldLog = YES; }
        }
        if (shouldLog) {
            BOOL hasLink = (link != nil);
            NSUInteger selfTextLen = link.selfText.length;
            NSUInteger selfHTMLLen = link.selfTextHTML.length;
            NSUInteger trimmedLen = trimmed.length;
            BOOL textHit = ApolloTextLooksLikeStructuredPostBody(trimmed) || ApolloTextLooksLikeStructuredPostBody(link.selfText);
            BOOL htmlHit = ApolloHTMLLooksLikeStructuredPostBody(link.selfTextHTML);
            BOOL codeHit = ApolloTextContainsMarkdownCode(link.selfText) || ApolloHTMLContainsCode(link.selfTextHTML) || ApolloTextContainsMarkdownCode(trimmed);
            ApolloLog(@"[Translation] post-body diag fn=%@ hasLink=%d selfText=%lu selfHTML=%lu trimmed=%lu textHit=%d htmlHit=%d codeHit=%d",
                      fn, hasLink, (unsigned long)selfTextLen, (unsigned long)selfHTMLLen, (unsigned long)trimmedLen, textHit, htmlHit, codeHit);
        }
    }

    if (ApolloLinkContainsCodeOrPreformatted(link, trimmed)) {
        NSString *linkFullName = link.fullName;
        if (linkFullName.length > 0) {
            [sLinkTranslationByFullName removeObjectForKey:linkFullName];
            ApolloMirrorRemoveLink(linkFullName);
        }
        ApolloRestoreOriginalForHeaderCellNode(headerCellNode, link);
        NSString *reason = (ApolloTextLooksLikeStructuredPostBody(trimmed) ||
                            ApolloTextLooksLikeStructuredPostBody(link.selfText) ||
                            ApolloHTMLLooksLikeStructuredPostBody(link.selfTextHTML))
            ? @"structured content (table / heading / multi-paragraph)"
            : @"code/preformatted content";
        ApolloLogPostBodySkipOnce(link, reason);
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
        // Strip links so URLs don't pollute language detection.
        NSString *detectionText = ApolloProtectTranslationLinks(trimmed, NULL);
        NSString *detected = ApolloDetectDominantLanguage(detectionText);
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
            ApolloMirrorSetLink(cacheStoreKey, translated);
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

static void ApolloMaybeTranslateVisiblePostBodyForController(UIViewController *viewController, UITableView *tableView, BOOL forceTranslation) {
    if (!viewController || !tableView) return;
    if (!ApolloShouldTranslateNow(forceTranslation)) return;

    RDKLink *link = ApolloLinkFromController(viewController);
    id textNode = ApolloBestVisiblePostBodyTextNodeForController(viewController, tableView, link);
    NSString *sourceText = ApolloVisibleTextFromNode(textNode);
    if (sourceText.length == 0) return;
    if (ApolloLinkContainsCodeOrPreformatted(link, sourceText)) {
        // Companion to the header-cell skip just above — same rule, no log
        // here (header-cell path already logged once for this fullName).
        return;
    }

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) return;

    NSString *cacheStoreKey = ApolloVisiblePostCacheKey(link, sourceText, targetLanguage);
    if (cacheStoreKey.length > 0) {
        NSString *cached = [sLinkTranslationByFullName objectForKey:cacheStoreKey];
        if (cached.length > 0) {
            ApolloApplyTranslationToPostTextNode(viewController.view, textNode, sourceText, cached);
            return;
        }
    }

    if (!forceTranslation) {
        // Strip links so URLs don't pollute language detection.
        NSString *detectionText = ApolloProtectTranslationLinks(sourceText, NULL);
        NSString *detected = ApolloDetectDominantLanguage(detectionText);
        if ([detected isEqualToString:targetLanguage]) return;
    }

    NSString *cacheKey = ApolloTranslationCacheKey(sourceText, targetLanguage);
    objc_setAssociatedObject(viewController.view, kApolloHeaderCellTranslationKeyKey, cacheKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
    __weak UIViewController *weakVC = viewController;
    __weak id weakTextNode = textNode;
    ApolloRequestTranslation(cacheKey, sourceText, targetLanguage, ^(NSString *translated, NSError *error) {
        UIViewController *strongVC = weakVC;
        id strongTextNode = weakTextNode;
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) ApolloLog(@"[Translation] Failed to translate visible post body: %@", error.localizedDescription ?: @"unknown");
            return;
        }
        if (!strongVC || !strongTextNode) return;
        NSString *currentKey = objc_getAssociatedObject(strongVC.view, kApolloHeaderCellTranslationKeyKey);
        if (![currentKey isEqualToString:cacheKey]) return;
        if (!forceTranslation && !ApolloShouldTranslateNow(NO)) return;

        if (cacheStoreKey.length > 0) {
            [sLinkTranslationByFullName setObject:translated forKey:cacheStoreKey];
            ApolloMirrorSetLink(cacheStoreKey, translated);
        }
        ApolloApplyTranslationToPostTextNode(strongVC.view, strongTextNode, sourceText, translated);
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

    ApolloMaybeTranslateVisiblePostBodyForController(viewController, tableView, forceTranslation);
}

static void ApolloSchedulePostBodyReapplyForController(UIViewController *viewController) {
    if (!viewController || !sEnableBulkTranslation) return;
    if (!ApolloControllerIsInTranslatedMode(viewController)) return;
    if ([objc_getAssociatedObject(viewController, kApolloPostBodyReapplyScheduledKey) boolValue]) return;

    objc_setAssociatedObject(viewController, kApolloPostBodyReapplyScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloTranslationVerboseLog(@"[Translation/vote] postBodyReapply: SCHEDULED vc=%p (30ms safety net)", viewController);
    __weak UIViewController *weakVC = viewController;
    // Reduced from 220ms to 30ms: the per-cell `setNeedsLayout` /
    // `setNeedsDisplay` hook on the post header cell node now covers the
    // vote-triggered redisplay case at ~10ms, but we keep this controller-
    // level walk as a safety net for header surfaces that don't go through
    // the cell-node path (e.g. tableHeaderView on certain post types).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC) return;
        objc_setAssociatedObject(strongVC, kApolloPostBodyReapplyScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!sEnableBulkTranslation || !ApolloControllerIsInTranslatedMode(strongVC)) return;
        ApolloMaybeTranslatePostHeaderForController(strongVC, NO);
        ApolloUpdateTranslationUIForController(strongVC);
    });
}

static void ApolloReapplyCommentCellNodesInTree(id object, NSInteger depth, NSHashTable *visited, BOOL forceTranslation) {
    if (!object || depth < 0) return;
    if (visited.count >= 2048) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return;

    if (isDisplayNode) {
        RDKComment *comment = ApolloCommentFromCellNode(object);
        if (comment) {
            if (!ApolloReapplyCachedTranslationForCellNode(object)) {
                ApolloMaybeTranslateCommentCellNode(object, forceTranslation);
            }
        }
        // Also handle post-header cells found in the tree (covers the case
        // where the body is scrolled offscreen at toggle-on time).
        RDKLink *headerLink = ApolloLinkFromHeaderCellNode(object);
        if (headerLink) {
            ApolloMaybeTranslatePostHeaderCellNode(object, headerLink, forceTranslation);
        }
    }

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) ApolloReapplyCommentCellNodesInTree(node, depth - 1, visited, forceTranslation);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloReapplyCommentCellNodesInTree(subnode, depth - 1, visited, forceTranslation);
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) ApolloReapplyCommentCellNodesInTree(subview, depth - 1, visited, forceTranslation);
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloReapplyVisibleCommentCellNodesForController(UIViewController *viewController, BOOL forceTranslation) {
    if (!viewController || !viewController.isViewLoaded) return;
    if (!sEnableBulkTranslation || !ApolloControllerIsInTranslatedMode(viewController)) return;
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
    ApolloReapplyCommentCellNodesInTree(viewController.view, 18, visited, forceTranslation);
}

static void ApolloRestoreCommentCellNodesInTree(id object, NSInteger depth, NSHashTable *visited) {
    if (!object || depth < 0) return;
    if (visited.count >= 2048) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return;

    if (isDisplayNode) {
        RDKComment *comment = ApolloCommentFromCellNode(object);
        if (comment) {
            ApolloRestoreOriginalForCellNode(object, comment);
        }
        // Also restore post-header cells found in the tree (covers the case
        // where the body is scrolled offscreen at toggle-off time).
        RDKLink *headerLink = ApolloLinkFromHeaderCellNode(object);
        if (headerLink) {
            ApolloRestoreOriginalForHeaderCellNode(object, headerLink);
        }
    }

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object) ApolloRestoreCommentCellNodesInTree(node, depth - 1, visited);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) ApolloRestoreCommentCellNodesInTree(subnode, depth - 1, visited);
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) ApolloRestoreCommentCellNodesInTree(subview, depth - 1, visited);
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloRestoreVisibleCommentCellNodesForController(UIViewController *viewController) {
    if (!viewController || !viewController.isViewLoaded) return;
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
    ApolloRestoreCommentCellNodesInTree(viewController.view, 18, visited);
}

static void ApolloForceVisibleCommentsTableRelayoutForController(UIViewController *viewController);

static void ApolloTranslateVisibleCommentsForController(UIViewController *viewController, BOOL forceTranslation) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;

    for (UITableViewCell *cell in [tableView visibleCells]) {
        SEL nodeSelector = NSSelectorFromString(@"node");
        if (![cell respondsToSelector:nodeSelector]) continue;

        id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        ApolloMaybeTranslateCommentCellNode(cellNode, forceTranslation);
    }

    // Texture can keep some visible/preloaded comment cell nodes out of
    // UITableView.visibleCells until a visibility event (collapse/reopen,
    // screenshot/app snapshot, tiny scroll) wakes them. Walk the loaded node
    // tree too and hit the same cached-reapply path those events use.
    ApolloReapplyVisibleCommentCellNodesForController(viewController, forceTranslation);

    // Phase C — also translate the post selftext (header cell) if present.
    ApolloMaybeTranslatePostHeaderForController(viewController, forceTranslation);
    ApolloForceVisibleCommentsTableRelayoutForController(viewController);
}

// Associated key + helper used to defer the table-level begin/endUpdates pass
// when the comments table is mid-scroll. Calling [tableView beginUpdates]/
// [tableView endUpdates] while the table is tracking/dragging/decelerating on
// iOS 26 collides with UITableView's internal scroll state machine and can
// leave the table's panGestureRecognizer wedged — the table area stops
// responding to touches while the back button + bottom toolbar still work.
// See user-reported "freeze on bottom overscroll with translation on" bug.
static const void *kApolloTableRelayoutDeferScheduledKey = &kApolloTableRelayoutDeferScheduledKey;

static void ApolloDeferTableRelayoutUntilScrollIdle(UIViewController *viewController, NSUInteger remainingRetries) {
    if (!viewController) return;
    if ([objc_getAssociatedObject(viewController, kApolloTableRelayoutDeferScheduledKey) boolValue]) return;
    objc_setAssociatedObject(viewController, kApolloTableRelayoutDeferScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakVC = viewController;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC) return;
        objc_setAssociatedObject(strongVC, kApolloTableRelayoutDeferScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!strongVC.isViewLoaded) return;

        UITableView *tableView = GetCommentsTableView(strongVC);
        if (!tableView) return;

        if (tableView.isTracking || tableView.isDragging || tableView.isDecelerating) {
            if (remainingRetries > 0) {
                ApolloDeferTableRelayoutUntilScrollIdle(strongVC, remainingRetries - 1);
            } else {
                ApolloTranslationVerboseLog(@"[Translation] Relayout deferred — gave up after retry budget exhausted");
            }
            return;
        }

        ApolloForceVisibleCommentsTableRelayoutForController(strongVC);
    });
}

static void ApolloForceVisibleCommentsTableRelayoutForController(UIViewController *viewController) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;

    BOOL tableIsScrolling = tableView.isTracking || tableView.isDragging || tableView.isDecelerating;

    @try {
        [UIView performWithoutAnimation:^{
            // Per-cell layout is always safe — it doesn't touch UITableView's
            // gesture/scroll state. Visible cells need this to measure
            // freshly-applied translated text correctly.
            for (UITableViewCell *cell in [tableView visibleCells]) {
                [cell setNeedsLayout];
                [cell.contentView setNeedsLayout];
                [cell layoutIfNeeded];
                SEL nodeSelector = NSSelectorFromString(@"node");
                if ([cell respondsToSelector:nodeSelector]) {
                    id cellNode = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
                    ApolloForceRelayoutForTextNodeAndOwner(cellNode, nil);
                }
            }

            // Table-level begin/endUpdates is what wedges the pan gesture
            // when the table is mid-bounce. Defer it until the scroll settles.
            if (tableIsScrolling) {
                ApolloTranslationVerboseLog(@"[Translation] Relayout deferred — table is scrolling (tracking=%d dragging=%d decelerating=%d)",
                                            tableView.isTracking, tableView.isDragging, tableView.isDecelerating);
                return;
            }

            [tableView beginUpdates];
            [tableView endUpdates];
            [tableView setNeedsLayout];
            [tableView layoutIfNeeded];
        }];
    } @catch (__unused NSException *e) {}

    if (tableIsScrolling) {
        // Up to 40 retries × 50ms ≈ 2s ceiling — well past any realistic
        // bounce-back deceleration window.
        ApolloDeferTableRelayoutUntilScrollIdle(viewController, 40);
    }
}

static void ApolloRestoreVisibleCommentsForController(UIViewController *viewController) {
    UITableView *tableView = GetCommentsTableView(viewController);
    if (!tableView) return;
    RDKLink *controllerLink = ApolloLinkFromController(viewController);

    if (tableView.tableHeaderView) {
        ApolloRestoreOriginalForHeaderCellNode(tableView.tableHeaderView, controllerLink);
    }
    ApolloRestoreOriginalForHeaderCellNode(viewController.view, controllerLink);

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
            ApolloRestoreOriginalForHeaderCellNode(cellNode, link);
            continue;
        }

        ApolloRestoreOriginalForCellNode(cellNode, comment);
    }
    ApolloRestoreVisibleCommentCellNodesForController(viewController);
    ApolloForceVisibleCommentsTableRelayoutForController(viewController);
}

#pragma mark - Phase A/B: nav-bar globe icon + status banner

// Forward declaration so the globe bar button action can call it.
static void ApolloToggleThreadTranslationForController(UIViewController *vc);
static void ApolloToggleFeedTitleTranslationForController(UIViewController *vc);
static void ApolloScheduleThreadTranslationReconcileForController(UIViewController *vc, BOOL translatedMode);

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

static BOOL ApolloTextMatchesTranslatedDisplayText(NSString *visibleText, NSString *translatedText) {
    if (ApolloTextQualifiesAsBodyCandidate(visibleText, translatedText)) return YES;

    NSString *translatedDisplay = ApolloDisplayStringByConvertingMarkdownLinks(translatedText, nil);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);
    NSString *displayNorm = ApolloNormalizeTextForCompare(translatedDisplay);
    return displayNorm.length > 0 && ![displayNorm isEqualToString:translatedNorm] && ApolloTextQualifiesAsBodyCandidate(visibleText, translatedDisplay);
}

static BOOL ApolloRefreshVisibleTranslationAppliedForController(UIViewController *vc) {
    if (!vc || !ApolloControllerIsInTranslatedMode(vc)) return NO;
    BOOL isFeedVC = [objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue];

    NSMutableArray *nodes = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:128];
    ApolloCollectAttributedTextNodes(vc.view, 8, visited, nodes);

    for (id node in nodes) {
        if (![objc_getAssociatedObject(node, kApolloTranslationOwnedTextNodeKey) boolValue]) continue;
        if (!isFeedVC && [objc_getAssociatedObject(node, kApolloTitleOwnedTextNodeKey) boolValue]) continue;

        NSString *originalBody = objc_getAssociatedObject(node, kApolloOwnedNodeOriginalBodyKey);
        NSString *translatedText = objc_getAssociatedObject(node, kApolloOwnedNodeTranslatedTextKey);
        if (![originalBody isKindOfClass:[NSString class]] || ![translatedText isKindOfClass:[NSString class]]) continue;
        if (!ApolloTranslatedTextDiffersFromSource(originalBody, translatedText)) continue;

        NSAttributedString *attr = nil;
        @try { attr = ((id (*)(id, SEL))objc_msgSend)(node, @selector(attributedText)); }
        @catch (__unused NSException *e) { continue; }
        if (![attr isKindOfClass:[NSAttributedString class]] || attr.string.length == 0) continue;

        if (ApolloTextMatchesTranslatedDisplayText(attr.string, translatedText)) {
            objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return YES;
        }
    }

    return NO;
}

static BOOL ApolloFindVisibleTranslatedTitleOwnedTextNodeInTree(id object, NSInteger depth, NSHashTable *visited) {
    if (!object || depth < 0) return NO;
    if (visited.count >= 2048) return NO;

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];
    BOOL isView = [object isKindOfClass:[UIView class]];
    if (!isDisplayNode && !isView) return NO;
    if ([visited containsObject:object]) return NO;
    [visited addObject:object];

    @try {
        if ([object respondsToSelector:@selector(attributedText)] &&
            [objc_getAssociatedObject(object, kApolloTranslationOwnedTextNodeKey) boolValue] &&
            [objc_getAssociatedObject(object, kApolloTitleOwnedTextNodeKey) boolValue]) {
            NSString *originalBody = objc_getAssociatedObject(object, kApolloOwnedNodeOriginalBodyKey);
            NSString *translatedText = objc_getAssociatedObject(object, kApolloOwnedNodeTranslatedTextKey);
            if ([originalBody isKindOfClass:[NSString class]] &&
                [translatedText isKindOfClass:[NSString class]] &&
                ApolloTranslatedTextDiffersFromSource(originalBody, translatedText)) {
                NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(object, @selector(attributedText));
                if ([attr isKindOfClass:[NSAttributedString class]] &&
                    ApolloTextMatchesTranslatedDisplayText(attr.string, translatedText)) {
                    return YES;
                }
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL selector = nodeSelectors[i];
            if (![object respondsToSelector:selector]) continue;
            id node = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (node && node != object && ApolloFindVisibleTranslatedTitleOwnedTextNodeInTree(node, depth - 1, visited)) return YES;
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subnodes isKindOfClass:[NSArray class]]) {
                for (id subnode in subnodes) {
                    if (ApolloFindVisibleTranslatedTitleOwnedTextNodeInTree(subnode, depth - 1, visited)) return YES;
                }
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id subview in subviews) {
                    if (ApolloFindVisibleTranslatedTitleOwnedTextNodeInTree(subview, depth - 1, visited)) return YES;
                }
            }
        }
    } @catch (__unused NSException *e) {}

    return NO;
}

static BOOL ApolloRefreshFeedTitleTranslationAppliedForController(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return NO;
    if (![objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue]) return NO;
    if (!sEnableBulkTranslation || !sTranslatePostTitles || !ApolloControllerIsInTranslatedMode(vc)) return NO;

    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
    if (!ApolloFindVisibleTranslatedTitleOwnedTextNodeInTree(vc.view, 20, visited)) return NO;

    objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// MARK: - Liquid Glass globe-merge helpers
//
// On iOS 26, each custom-view UIBarButtonItem is hosted in its own
// NavigationButtonBar item wrapper, and the bar inserts ~16pt of inter-item
// spacing between separate items — far more than the ~2-3pt Apollo gets by
// hand-packing its mod/sort/more buttons into ONE combined custom-view
// container (CGRectGetMaxX layout). Added as a separate item, the globe sits
// visibly isolated with a big gap before Apollo's cluster (issue #393). The
// fix: inject the globe button straight into Apollo's container so every icon
// is one evenly-spaced group. Apollo rebuilds that container on various events,
// so the setRightBarButtonItem(s) hook re-applies this after each rebuild.

// Find Apollo's combined trailing button container for this nav item: a
// custom-view UIView that holds at least one UIButton OTHER than our globe.
static UIView *ApolloFindTrailingButtonContainer(UINavigationItem *navItem, UIButton *globe) {
    for (UIBarButtonItem *item in navItem.rightBarButtonItems) {
        UIView *cv = item.customView;
        if (![cv isKindOfClass:[UIView class]]) continue;
        BOOL hasOtherButton = NO;
        for (UIView *sub in cv.subviews) {
            if ([sub isKindOfClass:[UIButton class]] && sub != globe) { hasOtherButton = YES; break; }
        }
        if (hasOtherButton) return cv;
    }
    return nil;
}

// Detach the globe from any container it was merged into, restoring that
// container's original button layout (shift back, shrink).
static void ApolloDetachGlobeFromContainer(UIButton *globe) {
    if (!globe || ![globe.superview isKindOfClass:[UIView class]]) return;
    UIView *container = globe.superview;
    // Undo exactly the right-shift we applied when merging (stored on the
    // container), falling back to the slot width if unknown.
    CGFloat shift = [objc_getAssociatedObject(container, kApolloGlobeMergeShiftKey) doubleValue];
    if (shift <= 0.0) shift = globe.frame.size.width > 1.0 ? globe.frame.size.width : kApolloGlobeMergeSlotWidth;
    [globe removeFromSuperview];
    for (UIView *sub in container.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        CGRect f = sub.frame;
        f.origin.x -= shift;
        sub.frame = f;
    }
    CGRect cf = container.frame;
    cf.size.width = MAX(0.0, cf.size.width - shift);
    container.frame = cf;
    container.bounds = CGRectMake(0.0, 0.0, cf.size.width, cf.size.height);
    objc_setAssociatedObject(container, kApolloGlobeMergeShiftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [container setNeedsLayout];
}

// Place the globe correctly for this nav item (idempotent). If Apollo has a
// multi-button trailing container, inject the globe as its leading button so
// every icon is one evenly-spaced group (issue #393). Otherwise fall back to a
// standalone trailing bar button item (pre-26 behavior) so the globe still
// appears on single-button screens. Re-runs after each Apollo rebuild via the
// setRightBarButtonItem(s) hook.
static void ApolloApplyGlobeMergeForNavItem(UINavigationItem *navItem) {
    if (!navItem) return;
    UIButton *globe = objc_getAssociatedObject(navItem, kApolloGlobeMergeButtonKey);
    if (!globe) return;

    UIView *container = ApolloFindTrailingButtonContainer(navItem, globe);
    UIBarButtonItem *standalone = objc_getAssociatedObject(navItem, kApolloGlobeStandaloneItemKey);

    if (container) {
        // Prefer the merged layout — drop any standalone fallback we added.
        if (standalone) {
            NSMutableArray<UIBarButtonItem *> *its = [navItem.rightBarButtonItems mutableCopy];
            if ([its containsObject:standalone]) {
                [its removeObject:standalone];
                sApplyingGlobeMerge = YES;
                navItem.rightBarButtonItems = its;
                sApplyingGlobeMerge = NO;
            }
            objc_setAssociatedObject(navItem, kApolloGlobeStandaloneItemKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        if (globe.superview == container) return;  // already merged — don't double-shift

        CGFloat gw = kApolloGlobeMergeSlotWidth;
        CGFloat h = container.bounds.size.height > 1.0 ? container.bounds.size.height : 44.0;
        [globe removeFromSuperview];  // out of any previous (stale) container

        // Measure Apollo's button cluster and the container's trailing inset so
        // we can insert the globe and keep the whole group SYMMETRIC inside the
        // glass capsule (equal leading/trailing padding). Apollo's container can
        // carry an asymmetric leading inset (the subreddit nav bar starts its
        // first button ~10pt in) — inheriting it would leave a gap before the
        // globe, so we re-place the leading edge to match the trailing inset.
        CGFloat leadingX = CGFLOAT_MAX, rightEdge = 0.0, firstBtnWidth = 0.0;
        for (UIView *sub in container.subviews) {
            if (![sub isKindOfClass:[UIButton class]]) continue;
            if (CGRectGetMinX(sub.frame) < leadingX) {
                leadingX = CGRectGetMinX(sub.frame);
                firstBtnWidth = CGRectGetWidth(sub.frame);  // the button the globe sits before
            }
            rightEdge = MAX(rightEdge, CGRectGetMaxX(sub.frame));
        }
        if (leadingX == CGFLOAT_MAX) leadingX = 0.0;
        CGFloat contW = container.frame.size.width;
        CGFloat trailInset = (contW > rightEdge) ? (contW - rightEdge) : 0.0;
        trailInset = MAX(0.0, MIN(trailInset, 20.0));
        CGFloat globeX = trailInset;                    // symmetric leading inset
        CGFloat shift  = globeX + gw - leadingX;        // first Apollo button lands flush after the globe

        // Center the glyph, then nudge it toward the next icon by HALF that
        // icon's extra slot width beyond a normal ~38pt slot. The mod badge sits
        // in a wide 44pt slot, so its centered glyph carries extra leading
        // padding that makes the globe→badge gap read large; a narrow first icon
        // (e.g. the 34pt trophy on Home) gets no nudge. Keeps spacing even on
        // every screen without a one-size-fits-all shift.
        CGFloat nudge = (firstBtnWidth - 38.0) * 0.5;
        nudge = MAX(0.0, MIN(nudge, kApolloGlobeMergeGlyphNudge));
        globe.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        globe.imageEdgeInsets = UIEdgeInsetsMake(0.0, nudge, 0.0, -nudge);
        for (UIView *sub in container.subviews) {
            if (![sub isKindOfClass:[UIButton class]]) continue;
            CGRect f = sub.frame;
            f.origin.x += shift;
            sub.frame = f;
        }
        globe.frame = CGRectMake(globeX, 0.0, gw, h);
        [container insertSubview:globe atIndex:0];

        // Resize so the bar item re-measures: content spans [globeX, rightEdge+
        // shift] with a matching trailing inset. Remember the shift for removal.
        CGFloat newW = rightEdge + shift + trailInset;
        CGRect cf = container.frame;
        cf.size.width = newW;
        container.frame = cf;
        container.bounds = CGRectMake(0.0, 0.0, newW, cf.size.height > 1.0 ? cf.size.height : h);
        objc_setAssociatedObject(container, kApolloGlobeMergeShiftKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container setNeedsLayout];
        return;
    }

    // No multi-button container to merge into yet. Don't eagerly add a
    // standalone item — Apollo often builds its trailing container slightly
    // AFTER the first merge attempt (e.g. async mod-status load), and a
    // standalone globe added now would conflict with the container injection
    // that follows (the same button can't live in both), leaving the globe
    // stranded in its own item with a gap. Instead wait: the
    // setRightBarButtonItem(s) hook re-runs this as soon as Apollo sets its
    // container. Only fall back to standalone if the globe truly has nowhere to
    // go (already detached and no container appeared).
    if (globe.superview && ![globe.superview isKindOfClass:[UIView class]]) {
        // shouldn't happen, but normalize
    }
    ApolloDetachGlobeFromContainer(globe);
    globe.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    globe.frame = CGRectMake(0.0, 0.0, kApolloGlobeMergeSlotWidth, 32.0);
    if (!standalone) {
        standalone = [[UIBarButtonItem alloc] initWithCustomView:globe];
        objc_setAssociatedObject(navItem, kApolloGlobeStandaloneItemKey, standalone, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (standalone.customView != globe) {
        standalone.customView = globe;
    }
    NSMutableArray<UIBarButtonItem *> *its = [navItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    if (![its containsObject:standalone]) {
        [its addObject:standalone];
        sApplyingGlobeMerge = YES;
        navItem.rightBarButtonItems = its;
        sApplyingGlobeMerge = NO;
    }
}

// Remove the globe entirely (translation gated off): detach from any container,
// drop any standalone item, and clear tracking.
static void ApolloRemoveGlobeMergeForNavItem(UINavigationItem *navItem) {
    if (!navItem) return;
    UIButton *globe = objc_getAssociatedObject(navItem, kApolloGlobeMergeButtonKey);
    ApolloDetachGlobeFromContainer(globe);
    UIBarButtonItem *standalone = objc_getAssociatedObject(navItem, kApolloGlobeStandaloneItemKey);
    if (standalone) {
        NSMutableArray<UIBarButtonItem *> *its = [navItem.rightBarButtonItems mutableCopy];
        if ([its containsObject:standalone]) {
            [its removeObject:standalone];
            sApplyingGlobeMerge = YES;
            navItem.rightBarButtonItems = its;
            sApplyingGlobeMerge = NO;
        }
    }
    objc_setAssociatedObject(navItem, kApolloGlobeStandaloneItemKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navItem, kApolloGlobeMergeButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloUpdateTranslationUIForController(id controller) {
    UIViewController *vc = (UIViewController *)controller;
    if (!sEnableBulkTranslation) return;

    BOOL isFeedVC = [objc_getAssociatedObject(controller, kApolloFeedTranslationVCKey) boolValue];
    UIBarButtonItem *translationItem = objc_getAssociatedObject(controller, kApolloTranslateBarButtonKey);
    NSMutableArray<UIBarButtonItem *> *items = [vc.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    // Comments VCs require sEnableBulkTranslation.
    // Feed VCs additionally require sTranslatePostTitles — the only thing
    // they translate is post titles, so when titles are disabled the globe
    // shouldn't appear.
    BOOL gateOK = sEnableBulkTranslation && (!isFeedVC || sTranslatePostTitles);
    if (!gateOK) {
        // Feature flipped off: revert any active translation, drop the bar
        // button + hide the banner. Do not leak associations.
        if (ApolloControllerIsInTranslatedMode(vc)) {
            if (!isFeedVC) ApolloRestoreVisibleCommentsForController(vc);
        }
        ApolloRestoreAllOwnedTextNodes();
        ApolloClearVisibleTranslationApplied(vc);
        objc_setAssociatedObject(controller, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controller, kApolloThreadOriginalModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (translationItem) {
            [items removeObject:translationItem];
            vc.navigationItem.rightBarButtonItems = items;
            objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // Liquid Glass: also pull the globe back out of Apollo's merged container.
        ApolloRemoveGlobeMergeForNavItem(vc.navigationItem);
        if (!isFeedVC) ApolloUpdateBannerForController(vc);
        return;
    }

    BOOL translatedMode = ApolloControllerIsInTranslatedMode(vc);
    BOOL visibleTranslationApplied = [objc_getAssociatedObject(vc, kApolloVisibleTranslationAppliedKey) boolValue];
    NSString *targetName = ApolloLocalizedTargetLanguageName();

    // Globe icon — a UIButton hosted either inside Apollo's trailing container
    // (Liquid Glass, so it groups evenly with mod/sort/more — issue #393) or as
    // our own separate bar button item (pre-26, where that's the tuned layout).
    BOOL liquidGlass = IsLiquidGlass();

    UIImage *globeImage = [[UIImage systemImageNamed:@"globe"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    UIButton *globeButton = nil;
    if (liquidGlass) {
        globeButton = objc_getAssociatedObject(vc.navigationItem, kApolloGlobeMergeButtonKey);
    }
    if (!globeButton && translationItem && [translationItem.customView isKindOfClass:[UIButton class]]) {
        globeButton = (UIButton *)translationItem.customView;
    }
    if (!globeButton) {
        globeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        globeButton.frame = CGRectMake(0.0, 0.0, 36.0, 32.0);
        // Pre-26: right-align so the glyph tucks against Apollo's adjacent pill.
        // Liquid Glass: ApolloApplyGlobeMergeForNavItem re-centers it in the slot.
        globeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        [globeButton addTarget:controller action:@selector(apollo_translationGlobeTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    [globeButton setImage:globeImage forState:UIControlStateNormal];

    UIColor *themeTintColor = ApolloThemeAccentColor() ?: vc.view.tintColor ?: [UIColor systemBlueColor];
    UIColor *resolvedTint = visibleTranslationApplied ? [UIColor systemGreenColor] : themeTintColor;
    globeButton.tintColor = resolvedTint;
    globeButton.accessibilityLabel = translatedMode
        ? @"Translation: showing translated. Tap to show original."
        : [NSString stringWithFormat:@"Translation: showing original. Tap to translate to %@.", targetName];

    if (liquidGlass) {
        // Merge the globe into Apollo's combined trailing container so all icons
        // share one evenly-spaced group. Track the button on the nav item so the
        // setRightBarButtonItem(s) hook re-injects it after Apollo rebuilds.
        objc_setAssociatedObject(vc.navigationItem, kApolloGlobeMergeButtonKey, globeButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Drop any separate bar item from a prior pre-26 run (migration safety).
        if (translationItem && [items containsObject:translationItem]) {
            [items removeObject:translationItem];
            vc.navigationItem.rightBarButtonItems = items;
            objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ApolloApplyGlobeMergeForNavItem(vc.navigationItem);
    } else {
        if (!translationItem) {
            translationItem = [[UIBarButtonItem alloc] initWithCustomView:globeButton];
            objc_setAssociatedObject(controller, kApolloTranslateBarButtonKey, translationItem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (translationItem.customView != globeButton) {
            translationItem.customView = globeButton;
        }
        translationItem.menu = nil;
        translationItem.tintColor = resolvedTint;
        translationItem.accessibilityLabel = globeButton.accessibilityLabel;
        if (![items containsObject:translationItem]) {
            // Apollo's rightBarButtonItems are laid out right-to-left. Adding to
            // the end places the globe just to the left of Apollo's sort/3-dots
            // pill — same bubble, tighter spacing thanks to the narrower frame.
            [items addObject:translationItem];
        }
        vc.navigationItem.rightBarButtonItems = items;
    }

    if (!isFeedVC) ApolloUpdateBannerForController(vc);
}

static void ApolloToggleThreadTranslationForController(UIViewController *vc) {
    if (!vc) return;
    BOOL wasTranslated = ApolloControllerIsInTranslatedMode(vc);
    if (wasTranslated) {
        // Switch to original.
        ApolloRestoreVisibleCommentsForController(vc);
        // Off-screen / preloaded text nodes never went through the visible-
        // cells walk above. Restore every node we still own globally so the
        // user sees originals as soon as they scroll back, without waiting
        // for cellNodeVisibilityEvent (which has timing issues for cells
        // already cached in ASDK's preload range).
        ApolloRestoreAllOwnedTextNodes();
        ApolloClearVisibleTranslationApplied(vc);
        sPendingVisibleFeedTitleApplied = NO;
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloScheduleThreadTranslationReconcileForController(vc, NO);
    } else {
        // Switch to translated.
        ApolloClearVisibleTranslationApplied(vc);
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloTranslateVisibleCommentsForController(vc, YES);
        ApolloRescanTitleNodesForController(vc);
        ApolloScheduleThreadTranslationReconcileForController(vc, YES);
    }
    ApolloUpdateTranslationUIForController(vc);
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification
                                                        object:nil
                                                      userInfo:@{@"reason": @"mode-toggle"}];
}

static NSString *ApolloFeedTitleModeKeyForController(UIViewController *vc) {
    if (!vc) return nil;
    NSString *title = vc.navigationItem.title ?: vc.title ?: @"";
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass([vc class]), title.length > 0 ? title : @"(untitled)"];
}

static NSNumber *ApolloStoredFeedTitleModeForController(UIViewController *vc) {
    NSString *key = ApolloFeedTitleModeKeyForController(vc);
    if (key.length == 0) return nil;
    return sFeedTitleModeByFeedKey[key];
}

static void ApolloStoreFeedTitleModeForController(UIViewController *vc, BOOL translated) {
    NSString *key = ApolloFeedTitleModeKeyForController(vc);
    if (key.length == 0) return;
    if (!sFeedTitleModeByFeedKey) sFeedTitleModeByFeedKey = [NSMutableDictionary dictionary];
    sFeedTitleModeByFeedKey[key] = @(translated);
    sLastFeedTitleModeKnown = YES;
    sLastFeedTitleTranslatedMode = translated;
}

static BOOL ApolloFeedTitlesShouldShowTranslated(UIViewController *feedVC) {
    if (feedVC) {
        BOOL translated = ApolloControllerIsInTranslatedMode(feedVC);
        sLastFeedTitleModeKnown = YES;
        sLastFeedTitleTranslatedMode = translated;
        return translated;
    }
    return !sLastFeedTitleModeKnown || sLastFeedTitleTranslatedMode;
}

static BOOL ApolloClassLooksLikeCommentsViewController(Class cls) {
    if (!cls) return NO;
    const char *name = class_getName(cls);
    return name && strstr(name, "CommentsViewController");
}

static BOOL ApolloTitleOwnedNodeShouldShowTranslated(UIViewController *enclosingVC) {
    if (enclosingVC && ApolloClassLooksLikeCommentsViewController([enclosingVC class])) {
        return ApolloControllerIsInTranslatedMode(enclosingVC);
    }
    UIViewController *feedVC = ApolloFindTopmostVisibleFeedVC();
    if (!feedVC && sVisibleCommentsViewController) {
        return ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController);
    }
    return ApolloFeedTitlesShouldShowTranslated(feedVC);
}

static void ApolloScheduleThreadTranslationReconcileForController(UIViewController *vc, BOOL translatedMode) {
    if (!vc) return;
    // Capture the cancel generation at scheduling time. viewWillDisappear
    // bumps this counter; any reconcile pass that fires after the user has
    // started swiping back will see a mismatch and bail out before it walks
    // the owned-textnode registry / forces table relayouts.
    NSNumber *generationAtSchedule = objc_getAssociatedObject(vc, kApolloReconcileGenerationKey);
    NSUInteger schedGen = generationAtSchedule.unsignedIntegerValue;
    NSArray<NSNumber *> *delays = @[ @0.12, @0.35, @0.8 ];
    for (NSNumber *delayNumber in delays) {
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC || !strongVC.isViewLoaded || !strongVC.view.window) return;
            // Cancelled by viewWillDisappear: \u2014 don't run mid-pop.
            NSNumber *currentGen = objc_getAssociatedObject(strongVC, kApolloReconcileGenerationKey);
            if (currentGen.unsignedIntegerValue != schedGen) return;
            if (ApolloControllerIsInTranslatedMode(strongVC) != translatedMode) return;
            if (translatedMode) {
                ApolloTranslateVisibleCommentsForController(strongVC, NO);
                ApolloRescanTitleNodesForController(strongVC);
                ApolloRefreshVisibleTranslationAppliedForController(strongVC);
                ApolloForceVisibleCommentsTableRelayoutForController(strongVC);
            } else {
                ApolloRestoreVisibleCommentsForController(strongVC);
                // Skip the global restore walk when nothing remains to
                // restore \u2014 avoids the four-deep storm of full-registry walks
                // per toggle that the user sees as swipe-back / toggle lag.
                if (sOwnedTextNodes && sOwnedTextNodes.count > 0) {
                    ApolloRestoreAllOwnedTextNodes();
                }
                ApolloClearVisibleTranslationApplied(strongVC);
                ApolloForceVisibleCommentsTableRelayoutForController(strongVC);
            }
            ApolloUpdateTranslationUIForController(strongVC);
        });
    }
}

static void ApolloToggleFeedTitleTranslationForController(UIViewController *vc) {
    if (!vc) return;
    BOOL wasTranslated = ApolloControllerIsInTranslatedMode(vc);
    if (wasTranslated) {
        ApolloRestoreAllOwnedTextNodes();
        ApolloClearVisibleTranslationApplied(vc);
        sPendingVisibleFeedTitleApplied = NO;
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloStoreFeedTitleModeForController(vc, NO);
        ApolloRescanTitleNodesForController(vc);
        ApolloRefreshFeedTranslationStateForController(vc);
    } else {
        ApolloClearVisibleTranslationApplied(vc);
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloStoreFeedTitleModeForController(vc, YES);
        ApolloRescanTitleNodesForController(vc);
    }
    ApolloUpdateTranslationUIForController(vc);
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification
                                                        object:nil
                                                      userInfo:@{@"reason": @"mode-toggle"}];
}

#pragma mark - Phase D: vote / redisplay resilience

// Helper: rebuild a translated NSAttributedString preserving the attributes of
// `incoming` (which carries Apollo's freshly-computed score color, font size,
// link styles, etc.) but using our cached translated string.
static NSAttributedString *ApolloRebuildTranslatedAttrPreservingAttrs(NSAttributedString *incoming, NSString *translatedText) {
    return ApolloTranslatedAttributedStringPreservingVisualLinks(incoming, translatedText);
}

static BOOL ApolloTextMatchesSourceOrVisualDisplay(NSString *incomingText, NSString *targetText) {
    NSString *targetNorm = ApolloNormalizeTextForCompare(targetText);
    if (targetNorm.length == 0) return NO;
    if (ApolloTextQualifiesAsBodyCandidate(incomingText, targetText)) return YES;

    NSString *targetDisplay = ApolloDisplayStringByConvertingMarkdownLinks(targetText, nil);
    NSString *targetDisplayNorm = ApolloNormalizeTextForCompare(targetDisplay);
    return ![targetDisplayNorm isEqualToString:targetNorm] && ApolloTextQualifiesAsBodyCandidate(incomingText, targetDisplay);
}

static void ApolloClearTranslationOwnershipForTextNode(id textNode) {
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (textNode && sOwnedTextNodes) {
        dispatch_sync(sOwnedTextNodesQueue, ^{
            [sOwnedTextNodes removeObject:textNode];
        });
    }
}

// Add `textNode` to the global weak registry. Called from
// ApolloApplyTranslationToCellNode / ApolloApplyTranslationToHeaderCellNode
// every time we stamp a node with the ownership marker, so the toggle-off
// walk below can find every owned node — even those whose backing
// UITableViewCell is currently off-screen.
static void ApolloRegisterOwnedTextNode(id textNode) {
    if (!textNode || !sOwnedTextNodes) return;
    dispatch_sync(sOwnedTextNodesQueue, ^{
        [sOwnedTextNodes addObject:textNode];
    });
}

// Walk every text node we've ever stamped with the ownership marker and
// restore each one to its saved original attributedText. Used by the toggle-
// off path so cells that scrolled off-screen while translated immediately
// revert — instead of waiting for cellNodeVisibilityEvent (which doesn't
// always fire reliably for cells already cached in ASDK's preload range).
static void ApolloRestoreAllOwnedTextNodes(void) {
    if (!sOwnedTextNodes) return;
    // Cheap fast-path: nothing's been stamped, nothing to do. Avoids the
    // hashtable snapshot + full log line on every gateOK=NO refresh of
    // ApolloUpdateTranslationUIForController and on toggle reconciles after
    // the immediate pass already drained the registry.
    if (sOwnedTextNodes.count == 0) return;
    NSArray *snapshot = nil;
    {
        __block NSArray *capture = nil;
        dispatch_sync(sOwnedTextNodesQueue, ^{
            capture = [sOwnedTextNodes allObjects];
        });
        snapshot = capture;
    }
    NSUInteger restored = 0, skippedNoOriginal = 0, skippedReuse = 0, skippedTitleStaleReuse = 0;
    for (id textNode in snapshot) {
        if (!textNode) continue;
        // Only act if still tagged.
        if (![objc_getAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey) boolValue]) continue;

        BOOL isTitleOwned = [objc_getAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey) boolValue];
        NSString *cachedTranslated = objc_getAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey);
        NSAttributedString *savedOriginal = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);

        // Drop ownership keys FIRST so the global setAttributedText: hook
        // won't re-swap when we write the original below.
        objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

        if (![savedOriginal isKindOfClass:[NSAttributedString class]]) { skippedNoOriginal++; continue; }

        // Reuse-safety: only write if the node currently shows our cached
        // translation. If it now shows something else (reused for a
        // different comment), leave it alone — clearing ownership is
        // sufficient.
        NSAttributedString *currentAttr = nil;
        @try {
            currentAttr = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText));
        } @catch (__unused NSException *e) {
            continue;
        }
        NSString *currentText = [currentAttr isKindOfClass:[NSAttributedString class]] ? currentAttr.string : nil;
        if (currentText.length == 0) { skippedReuse++; continue; }

        BOOL shouldRestore = NO;
        if (isTitleOwned) {
            // Title-owned: be permissive. The strict body-candidate check
            // (which requires ≥60% length overlap or shared 12+ char prefix)
            // rejects many short translated titles whose normalized form
            // doesn't perfectly equal the cached translated string. For
            // titles, just compare normalized forms for equality OR check
            // that the saved-original text differs from currentText (i.e.
            // we haven't already restored). If the cell got reused for a
            // different post the next setAttributedText: from Apollo will
            // overwrite our restored stale text — no worse than leaving
            // stale translated text.
            NSString *currentNorm = ApolloNormalizeTextForCompare(currentText);
            NSString *cachedNorm = ApolloNormalizeTextForCompare(cachedTranslated);
            NSString *origNorm = ApolloNormalizeTextForCompare(savedOriginal.string);
            if (cachedNorm.length > 0 && [currentNorm isEqualToString:cachedNorm]) {
                shouldRestore = YES;
            } else if (origNorm.length > 0 && ![currentNorm isEqualToString:origNorm]) {
                // Currently showing something other than the saved original
                // — likely still translated text but with slight format diff.
                shouldRestore = YES;
            } else {
                skippedTitleStaleReuse++;
            }
        } else if ([cachedTranslated isKindOfClass:[NSString class]] && cachedTranslated.length > 0) {
            shouldRestore = ApolloTextQualifiesAsBodyCandidate(currentText, cachedTranslated);
            if (!shouldRestore) skippedReuse++;
        } else {
            skippedReuse++;
        }
        if (!shouldRestore) continue;

        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), savedOriginal);
        } @catch (__unused NSException *e) {
            continue;
        }
        restored++;
        if ([textNode respondsToSelector:@selector(setNeedsLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsLayout));
        }
        if ([textNode respondsToSelector:@selector(setNeedsDisplay)]) {
            ((void (*)(id, SEL))objc_msgSend)(textNode, @selector(setNeedsDisplay));
        }
        // ---- Restore-side cell relayout ----
        // Same problem as the apply path: the enclosing ASCellNode caches
        // the (longer) translated layout, so without an explicit transition
        // the original text gets truncated to "Benfica..." until you scroll.
        SEL invalidateSel = NSSelectorFromString(@"invalidateCalculatedLayout");
        SEL supernodeSel = NSSelectorFromString(@"supernode");
        @try {
            if ([textNode respondsToSelector:invalidateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(textNode, invalidateSel);
            }
            id supernode = nil;
            if ([textNode respondsToSelector:supernodeSel]) {
                supernode = ((id (*)(id, SEL))objc_msgSend)(textNode, supernodeSel);
            }
            int hops = 0;
            id cellNode = nil;
            while (supernode && hops < 8) {
                if ([supernode respondsToSelector:invalidateSel]) {
                    ((void (*)(id, SEL))objc_msgSend)(supernode, invalidateSel);
                }
                if ([supernode respondsToSelector:@selector(setNeedsLayout)]) {
                    ((void (*)(id, SEL))objc_msgSend)(supernode, @selector(setNeedsLayout));
                }
                if (!cellNode) {
                    const char *snName = class_getName([supernode class]);
                    if (snName && strstr(snName, "CellNode")) cellNode = supernode;
                }
                if (![supernode respondsToSelector:supernodeSel]) break;
                supernode = ((id (*)(id, SEL))objc_msgSend)(supernode, supernodeSel);
                hops++;
            }
            if (cellNode) {
                SEL transitionSel = NSSelectorFromString(@"transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:");
                if ([cellNode respondsToSelector:transitionSel]) {
                    NSMethodSignature *sig = [cellNode methodSignatureForSelector:transitionSel];
                    if (sig) {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = cellNode;
                        inv.selector = transitionSel;
                        BOOL animated = NO;
                        BOOL async = NO;
                        void (^completion)(void) = nil;
                        [inv setArgument:&animated atIndex:2];
                        [inv setArgument:&async atIndex:3];
                        [inv setArgument:&completion atIndex:4];
                        @try { [inv invoke]; } @catch (__unused NSException *e) {}
                    }
                }
            }
        } @catch (__unused NSException *e) {}
    }

    // Drain dead weak entries.
    dispatch_sync(sOwnedTextNodesQueue, ^{
        // NSHashTable handles weak entries automatically; a no-op iteration
        // suffices to compact in some implementations. Nothing else needed.
        (void)[sOwnedTextNodes count];
    });
    ApolloLog(@"[Translation] RestoreAllOwnedTextNodes total=%lu restored=%lu skippedNoOriginal=%lu skippedReuse=%lu skippedTitleStaleReuse=%lu",
              (unsigned long)snapshot.count,
              (unsigned long)restored,
              (unsigned long)skippedNoOriginal,
              (unsigned long)skippedReuse,
              (unsigned long)skippedTitleStaleReuse);
}

static BOOL ApolloPrepareTranslatedSwapForTextNode(id textNode,
                                                   NSAttributedString *incomingAttributedText,
                                                   NSAttributedString **swapOut) {
    if (swapOut) *swapOut = nil;

    NSString *originalBody = objc_getAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey);
    NSString *translatedText = objc_getAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey);

    if (![originalBody isKindOfClass:[NSString class]] || originalBody.length == 0 ||
        ![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0 ||
        ![incomingAttributedText isKindOfClass:[NSAttributedString class]]) {
        ApolloTranslationVerboseLog(@"[Translation/vote] prepareSwap: missing markers (orig=%lu trans=%lu) on node=%p",
                                    (unsigned long)originalBody.length, (unsigned long)translatedText.length, textNode);
        return NO;
    }

    NSString *incomingText = incomingAttributedText.string;
    if (ApolloTextMatchesSourceOrVisualDisplay(incomingText, translatedText)) {
        ApolloTranslationVerboseLog(@"[Translation/vote] prepareSwap: incoming==translated, no-op node=%p", textNode);
        return NO;
    }

    if (ApolloTextMatchesSourceOrVisualDisplay(incomingText, originalBody)) {
        ApolloTranslationVerboseLog(@"[Translation/vote] prepareSwap: incoming==original → SWAPPING to translated node=%p (incomingLen=%lu)",
                                    textNode, (unsigned long)incomingText.length);
        if (swapOut) *swapOut = ApolloRebuildTranslatedAttrPreservingAttrs(incomingAttributedText, translatedText);
        return YES;
    }

    NSString *incomingPreview = incomingText.length > 60 ? [incomingText substringToIndex:60] : incomingText;
    NSString *origPreview = originalBody.length > 60 ? [originalBody substringToIndex:60] : originalBody;
    if (ApolloTextIsSubstantiveForOwnershipCleanup(incomingText)) {
        ApolloLog(@"[Translation/vote] prepareSwap: NO MATCH (substantive) → CLEARING ownership node=%p incoming='%@' orig='%@'",
                  textNode, incomingPreview, origPreview);
        ApolloClearTranslationOwnershipForTextNode(textNode);
    } else {
        ApolloTranslationVerboseLog(@"[Translation/vote] prepareSwap: NO MATCH (non-substantive, keeping ownership) node=%p incoming='%@' orig='%@'",
                                    textNode, incomingPreview, origPreview);
    }
    return NO;
}

// Vote-flash mitigation: when the comments header is rebuilt after a vote
// tap, the new post-body text node has NO ownership markers yet. The
// scheduler-based reapply path takes ~80-100ms, during which the original
// (untranslated) body is visible. This helper checks the per-VC stash
// synchronously: if the incoming text exactly matches the stashed body and
// the stash carries a translated string, return a swap immediately and
// adopt ownership so subsequent updates flow through the normal hook.
//
// Cost: a single length compare guards everything; we only do the equality
// check + swap when the visible CommentsVC has a stash.
static BOOL ApolloPreemptUnownedTextNodeFromVCStash(id textNode, NSAttributedString *incoming, NSAttributedString **swapOut) {
    if (swapOut) *swapOut = nil;
    if (!textNode || ![incoming isKindOfClass:[NSAttributedString class]]) return NO;
    UIViewController *vc = sVisibleCommentsViewController;
    if (!vc) return NO;
    // Toggle-off gate: if the user just hit the globe to revert to original,
    // do NOT re-translate the rebuilt body node. The stash still exists from
    // the previous translated session — it should only drive the preempt
    // path while the controller is in translated mode.
    if (!ApolloControllerIsInTranslatedMode(vc)) return NO;
    id raw = objc_getAssociatedObject(vc, kApolloLastAppliedPostBodyKey);
    if (![raw isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *stash = (NSDictionary *)raw;
    NSString *body = stash[@"body"];
    NSString *translated = stash[@"translated"];
    if (![body isKindOfClass:[NSString class]] || body.length == 0) return NO;
    if (![translated isKindOfClass:[NSString class]] || translated.length == 0) return NO;
    NSString *incomingText = incoming.string;
    if (incomingText.length != body.length) return NO; // cheap reject
    if (!ApolloTextMatchesSourceOrVisualDisplay(incomingText, body)) return NO;
    NSAttributedString *swap = ApolloRebuildTranslatedAttrPreservingAttrs(incoming, translated);
    if (!swap) return NO;
    // Adopt ownership so the normal prepareSwap path handles future updates.
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [body copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translated copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Register in the global owned-nodes set so toggle-off's
    // ApolloRestoreAllOwnedTextNodes walk will restore us even when the
    // header is scrolled offscreen and the visible-cells walk skips us.
    ApolloRegisterOwnedTextNode(textNode);
    // Save the incoming (original) attributed text so toggle-off restore can
    // find it. Without this, ApolloRestoreOriginalForHeaderCellNode bails and
    // the body stays translated when the user taps the globe.
    if (!objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey)) {
        objc_setAssociatedObject(textNode, kApolloOriginalAttributedTextKey, [incoming copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // Register this text node on the visible header cell so toggle-off can
    // find it via kApolloHeaderTranslatedTextNodeKey lookup.
    {
        UIViewController *currentVC = sVisibleCommentsViewController;
        if ([currentVC respondsToSelector:@selector(view)]) {
            UIView *vcView = [(UIViewController *)currentVC view];
            if (vcView && !objc_getAssociatedObject(vcView, kApolloHeaderTranslatedTextNodeKey)) {
                objc_setAssociatedObject(vcView, kApolloHeaderTranslatedTextNodeKey, textNode, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if (swapOut) *swapOut = swap;
    ApolloTranslationVerboseLog(@"[Translation/vote] preempt: unowned node=%p matched VC stash → SYNC swap (len=%lu)", textNode, (unsigned long)translated.length);
    return YES;
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
        // Vote-flash preempt: brand-new (rebuilt) header body text node.
        NSAttributedString *preemptSwap = nil;
        if (ApolloPreemptUnownedTextNodeFromVCStash(self, attributedText, &preemptSwap)) {
            objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { %orig(preemptSwap); } @catch (__unused NSException *e) {}
            objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        %orig;
        return;
    }

    // Title-owned nodes live outside the comments controller (feeds, search,
    // profile, etc.) — they must bypass the per-thread translated-mode gate.
    BOOL isTitleOwned = [objc_getAssociatedObject(self, kApolloTitleOwnedTextNodeKey) boolValue];

    // Title-owned toggle-off gate: if the topmost-visible feed VC is in
    // original mode, drop ownership and let Apollo's incoming text through.
    if (isTitleOwned) {
        UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode((id)self);
        if (!ApolloTitleOwnedNodeShouldShowTranslated(enclosingVC)) {
            ApolloClearTranslationOwnershipForTextNode(self);
            %orig;
            return;
        }
    }

    // Toggle-off gate: if the controller is no longer in translated mode,
    // drop our ownership marker and let Apollo's incoming (original) text
    // through unchanged. Without this, off-screen text nodes that still
    // carry the ownership marker would re-swap to translated as soon as
    // Apollo touches them again on cell reuse / scroll-back, which is the
    // "translated text persists after toggling off" bug.
    if (!isTitleOwned && !ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) {
        ApolloClearTranslationOwnershipForTextNode(self);
        %orig;
        return;
    }

    // Re-entrancy guard: when WE call %orig with a substituted string, the
    // hook re-fires. Skip the swap on the inner call.
    if ([objc_getAssociatedObject(self, kApolloOwnedNodeReentrancyKey) boolValue]) {
        %orig;
        return;
    }

    NSAttributedString *swap = nil;
    if (ApolloPrepareTranslatedSwapForTextNode(self, attributedText, &swap)) {
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(swap); } @catch (__unused NSException *e) {}
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isTitleOwned) {
            NSString *originalBody = objc_getAssociatedObject(self, kApolloOwnedNodeOriginalBodyKey);
            NSString *translatedText = objc_getAssociatedObject(self, kApolloOwnedNodeTranslatedTextKey);
            UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode((id)self);
            if (ApolloClassLooksLikeCommentsViewController([enclosingVC class])) {
                ApolloMarkVisibleTranslationApplied(originalBody, translatedText);
            } else {
                ApolloMarkVisibleFeedTitleApplied(originalBody, translatedText);
            }
        }
        return;
    }

    %orig;
}

%end

%hook ASTextNode2

- (void)setAttributedText:(NSAttributedString *)attributedText {
    if (![objc_getAssociatedObject(self, kApolloTranslationOwnedTextNodeKey) boolValue]) {
        // Vote-flash preempt (mirror of ASTextNode hook above).
        NSAttributedString *preemptSwap = nil;
        if (ApolloPreemptUnownedTextNodeFromVCStash(self, attributedText, &preemptSwap)) {
            objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try { %orig(preemptSwap); } @catch (__unused NSException *e) {}
            objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        %orig;
        return;
    }

    BOOL isTitleOwned = [objc_getAssociatedObject(self, kApolloTitleOwnedTextNodeKey) boolValue];

    if (isTitleOwned) {
        UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode((id)self);
        if (!ApolloTitleOwnedNodeShouldShowTranslated(enclosingVC)) {
            ApolloClearTranslationOwnershipForTextNode(self);
            %orig;
            return;
        }
    }

    // Toggle-off gate (mirror of ASTextNode hook above).
    if (!isTitleOwned && !ApolloControllerIsInTranslatedMode(sVisibleCommentsViewController)) {
        ApolloClearTranslationOwnershipForTextNode(self);
        %orig;
        return;
    }

    if ([objc_getAssociatedObject(self, kApolloOwnedNodeReentrancyKey) boolValue]) {
        %orig;
        return;
    }

    NSAttributedString *swap = nil;
    if (ApolloPrepareTranslatedSwapForTextNode(self, attributedText, &swap)) {
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try { %orig(swap); } @catch (__unused NSException *e) {}
        objc_setAssociatedObject(self, kApolloOwnedNodeReentrancyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (isTitleOwned) {
            NSString *originalBody = objc_getAssociatedObject(self, kApolloOwnedNodeOriginalBodyKey);
            NSString *translatedText = objc_getAssociatedObject(self, kApolloOwnedNodeTranslatedTextKey);
            UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode((id)self);
            if (ApolloClassLooksLikeCommentsViewController([enclosingVC class])) {
                ApolloMarkVisibleTranslationApplied(originalBody, translatedText);
            } else {
                ApolloMarkVisibleFeedTitleApplied(originalBody, translatedText);
            }
        }
        return;
    }

    %orig;
}

%end

// ---------------------------------------------------------------------------
// Post title translation (PostTitleNode / PostTitleURLNode)
// ---------------------------------------------------------------------------
//
// Title translation runs in *every* feed surface (subreddit feed, home feed,
// search results, profile, and the post-detail header). Title nodes are
// produced and reused by AsyncDisplayKit *outside* the comments controller,
// so they bypass the per-thread translated-mode gate via the
// `kApolloTitleOwnedTextNodeKey` marker (see ASTextNode setAttributedText
// hooks above).
//
// CRITICAL: do NOT hook setNeedsLayout / setNeedsDisplay on title nodes.
// `setAttributedText:` internally invokes both, so hooking those methods to
// re-translate would cause unbounded recursion and a stack-overflow crash.
// (This was the v17 bug that caused the launch-time crash loop.)
// Re-application on cell reuse, vote refresh, edit, etc. is handled by the
// global ASTextNode/ASTextNode2 setAttributedText: swap hooks, keyed on
// `kApolloTranslationOwnedTextNodeKey`.

// Walks up an ASDisplayNode's supernode chain looking for one with a loaded
// view, then walks the UIView responder chain to find the enclosing
// UIViewController. Returns nil if the node isn't yet attached to a view
// hierarchy (e.g. during preload before the cell view is loaded).
static void ApolloMaybeTranslatePostTitleNode(id titleNode);

static UIViewController *ApolloEnclosingViewControllerForNode(id node) {
    if (!node) return nil;
    SEL supernodeSel = NSSelectorFromString(@"supernode");
    SEL isLoadedSel = NSSelectorFromString(@"isNodeLoaded");
    SEL viewSel = @selector(view);

    id current = node;
    int hops = 0;
    while (current && hops < 16) {
        @try {
            BOOL viewLoaded = NO;
            if ([current respondsToSelector:isLoadedSel]) {
                viewLoaded = ((BOOL (*)(id, SEL))objc_msgSend)(current, isLoadedSel);
            }
            if (viewLoaded && [current respondsToSelector:viewSel]) {
                UIView *v = ((id (*)(id, SEL))objc_msgSend)(current, viewSel);
                if ([v isKindOfClass:[UIView class]]) {
                    UIResponder *r = v.nextResponder;
                    while (r) {
                        if ([r isKindOfClass:[UIViewController class]]) {
                            return (UIViewController *)r;
                        }
                        r = r.nextResponder;
                    }
                }
            }
        } @catch (__unused NSException *e) {}
        if (![current respondsToSelector:supernodeSel]) break;
        @try {
            current = ((id (*)(id, SEL))objc_msgSend)(current, supernodeSel);
        } @catch (__unused NSException *e) { break; }
        hops++;
    }
    return nil;
}

// Returns YES if the controller has been confirmed-set to original-mode
// (either via the per-thread toggle, or via auto-translate-off). Returns NO
// when the VC is nil or its mode is unknown \u2014 callers use that to *defer*
// destructive actions (like restoring originals) until viewDidAppear has
// claimed `sVisibleCommentsViewController`.
static BOOL ApolloControllerIsConfirmedOriginalMode(UIViewController *vc) {
    if (!vc) return NO;
    if ([objc_getAssociatedObject(vc, kApolloThreadOriginalModeKey) boolValue]) return YES;
    // No explicit per-thread override: the VC follows global auto-translate.
    // If auto-translate is OFF, mode == original. If ON, the translated-mode
    // path handles things; we report NO here so callers don't mistakenly
    // restore originals on a translated thread.
    if (!sAutoTranslateOnAppear) return YES;
    return NO;
}

// Best-effort \"which CommentsViewController owns this cell node?\". Tries the
// global pointer first (covers the common case); falls back to walking the
// ASDisplayNode tree so cell-visibility hooks that fire BEFORE viewDidAppear:
// can still find their owning VC. Returns nil if the cell isn't attached to
// a view hierarchy yet.
static UIViewController *ApolloOwningCommentsVCForCellNode(id cellNode) {
    UIViewController *vc = sVisibleCommentsViewController;
    if (vc && vc.isViewLoaded && vc.view.window) return vc;
    UIViewController *enclosing = ApolloEnclosingViewControllerForNode(cellNode);
    if (enclosing) return enclosing;
    return vc; // may be nil; callers handle that
}


// when toggling the feed/thread globe on so that already-visible cells get
// translated immediately (the didLoad/preload/display hooks only fire on
// new cells).
static void ApolloRescanTitleNodesInTree(id object, NSInteger depth, NSHashTable *visited) {
    if (!object || depth < 0) return;
    if (visited.count >= 2048) return;
    if ([visited containsObject:object]) return;
    [visited addObject:object];

    Class displayNodeCls = NSClassFromString(@"ASDisplayNode");
    BOOL isDisplayNode = displayNodeCls && [object isKindOfClass:displayNodeCls];

    if (isDisplayNode) {
        const char *clsName = class_getName([object class]);
        if (clsName && (strstr(clsName, "PostTitleNode") || strstr(clsName, "PostTitleURLNode"))) {
            // Translating the title also walks up to the enclosing post cell and
            // translates its body preview (see ApolloMaybeTranslatePostTitleNode), so
            // a globe-toggle rescan updates both title and body for visible cells.
            ApolloMaybeTranslatePostTitleNode(object);
            // Don't return — title nodes might contain other PostTitleNodes
            // (e.g. crossposts), but practically we can stop descending.
        }
    }

    @try {
        SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
        for (size_t i = 0; i < sizeof(nodeSelectors) / sizeof(nodeSelectors[0]); i++) {
            SEL sel = nodeSelectors[i];
            if (![object respondsToSelector:sel]) continue;
            id n = ((id (*)(id, SEL))objc_msgSend)(object, sel);
            if (n && n != object) ApolloRescanTitleNodesInTree(n, depth - 1, visited);
        }
    } @catch (__unused NSException *e) {}

    @try {
        SEL subnodesSel = NSSelectorFromString(@"subnodes");
        if ([object respondsToSelector:subnodesSel]) {
            NSArray *subs = ((id (*)(id, SEL))objc_msgSend)(object, subnodesSel);
            if ([subs isKindOfClass:[NSArray class]]) {
                for (id s in subs) ApolloRescanTitleNodesInTree(s, depth - 1, visited);
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        if ([object respondsToSelector:@selector(subviews)]) {
            NSArray *subviews = ((id (*)(id, SEL))objc_msgSend)(object, @selector(subviews));
            if ([subviews isKindOfClass:[NSArray class]]) {
                for (id s in subviews) ApolloRescanTitleNodesInTree(s, depth - 1, visited);
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloRescanTitleNodesForController(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    BOOL isFeedVC = [objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:256];
    ApolloRescanTitleNodesInTree(vc.view, 16, visited);
    if (isFeedVC) ApolloRefreshFeedTranslationStateForController(vc);

    // Some cells haven't fully laid out their title node yet at the moment
    // the user taps the globe (e.g. cells just scrolled into view, or the
    // first toggle right after viewDidAppear). Schedule retries so those
    // late-arriving title nodes still get translated without the user having
    // to scroll, then repaint the globe from the visible title state.
    __weak UIViewController *weakVC = vc;
    void (^scheduleTranslatedRescan)(NSTimeInterval) = ^(NSTimeInterval delay) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC || !strongVC.isViewLoaded) return;
            if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
            if (!ApolloControllerIsInTranslatedMode(strongVC)) return;
            NSHashTable *visited2 = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:256];
            ApolloRescanTitleNodesInTree(strongVC.view, 16, visited2);
            if ([objc_getAssociatedObject(strongVC, kApolloFeedTranslationVCKey) boolValue]) {
                ApolloRefreshFeedTranslationStateForController(strongVC);
            }
        });
    };
    scheduleTranslatedRescan(0.15);
    scheduleTranslatedRescan(0.6);
}

static id ApolloTitleTextNodeFromTitleNode(id titleNode) {
    if (!titleNode) return nil;

    // Most likely path: PostTitleNode IS an ASTextNode subclass.
    if ([titleNode respondsToSelector:@selector(attributedText)]) {
        @try {
            NSAttributedString *attr = ((id (*)(id, SEL))objc_msgSend)(titleNode, @selector(attributedText));
            if ([attr isKindOfClass:[NSAttributedString class]] && attr.length > 0) {
                return titleNode;
            }
        } @catch (__unused NSException *e) {}
    }

    // Fallback: scan child text nodes and pick the longest non-empty one.
    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
    ApolloCollectAttributedTextNodes(titleNode, 3, visited, candidates);

    id best = nil;
    NSUInteger bestLen = 0;
    for (id n in candidates) {
        NSAttributedString *attr = nil;
        @try { attr = ((id (*)(id, SEL))objc_msgSend)(n, @selector(attributedText)); }
        @catch (__unused NSException *e) { continue; }
        if (![attr isKindOfClass:[NSAttributedString class]]) continue;
        if (attr.length > bestLen) { bestLen = attr.length; best = n; }
    }
    return best;
}

static void ApolloApplyTranslationToTitleNode(id titleNode, id textNode, NSString *sourceText, NSString *translatedText) {
    if (!titleNode || !textNode) return;
    if (![sourceText isKindOfClass:[NSString class]] || sourceText.length == 0) return;
    if (![translatedText isKindOfClass:[NSString class]] || translatedText.length == 0) return;

    NSAttributedString *current = nil;
    @try { current = ((id (*)(id, SEL))objc_msgSend)(textNode, @selector(attributedText)); }
    @catch (__unused NSException *e) { return; }
    if (![current isKindOfClass:[NSAttributedString class]]) return;

    NSString *currentNorm = ApolloNormalizeTextForCompare(current.string);
    NSString *sourceNorm = ApolloNormalizeTextForCompare(sourceText);
    NSString *translatedNorm = ApolloNormalizeTextForCompare(translatedText);
    if (currentNorm.length == 0 || sourceNorm.length == 0) return;

    BOOL textMatchesSource = [currentNorm isEqualToString:sourceNorm] ||
                             [currentNorm containsString:sourceNorm] ||
                             [sourceNorm containsString:currentNorm];
    BOOL textMatchesTranslation = translatedNorm.length > 0 &&
        ([currentNorm isEqualToString:translatedNorm] ||
         [currentNorm containsString:translatedNorm] ||
         [translatedNorm containsString:currentNorm]);

    // Already showing translation, or showing something unrelated (cell
    // recycled to a different post mid-flight) — nothing to do.
    if (!textMatchesSource && !textMatchesTranslation) return;
    if (textMatchesTranslation && !textMatchesSource) return;

    // Save original on first apply for this node so toggle-off / restore can
    // recover. Subsequent applies for the same node keep the first-seen
    // original.
    NSAttributedString *originalSaved = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
    if (![originalSaved isKindOfClass:[NSAttributedString class]]) {
        objc_setAssociatedObject(textNode, kApolloOriginalAttributedTextKey, [current copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSAttributedString *translatedAttr = ApolloTranslatedAttributedStringPreservingVisualLinks(current, translatedText);

    // Vote-resilience / cell-reuse markers (same scheme as comment cells +
    // post bodies). The title-owned marker tells the global swap hook to
    // bypass the per-thread translated-mode gate.
    objc_setAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey, [sourceText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey, [translatedText copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTranslationOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloRegisterOwnedTextNode(textNode);

    @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), translatedAttr); }
    @catch (__unused NSException *e) { return; }

    // Turn the feed/thread globe green now that we've actually swapped a
    // visible title to the translated string.
    UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode(titleNode);
    if (ApolloClassLooksLikeCommentsViewController([enclosingVC class])) {
        ApolloMarkVisibleTranslationApplied(sourceText, translatedText);
    } else {
        ApolloMarkVisibleFeedTitleApplied(sourceText, translatedText);
    }

    // ---- Tag overlap fix ----
    // PostTitleNode / PostTitleURLNode lay out subnodes (title text + tag
    // pills + URL hostname) using ASDK's flexbox with positions that depend
    // on the title text's calculated intrinsic size. When we replace the
    // attributed string in-place, ASDK doesn't always re-flow the parent
    // automatically — tag pills overlap the (longer) translated title until
    // a scroll-out / scroll-in forces a fresh layout pass.
    //
    // Force a fresh layout pass on both the text node AND its enclosing
    // title node. We do this from a static helper (NOT a hook), so even
    // though setNeedsLayout / invalidateCalculatedLayout normally trigger
    // ASDK relayout work, this never re-enters our translation code path.
    //
    // CRITICAL: do NOT install %hooks for setNeedsLayout / setNeedsDisplay
    // on PostTitleNode — setAttributedText: internally calls them, and
    // hooking those to invoke maybe-translate is what caused the v17 stack-
    // overflow crash. Calling them ourselves from this un-hooked function
    // is safe.
    SEL invalidateSel = NSSelectorFromString(@"invalidateCalculatedLayout");
    @try {
        if ([textNode respondsToSelector:invalidateSel]) {
            ((void (*)(id, SEL))objc_msgSend)(textNode, invalidateSel);
        }
        if (titleNode != textNode) {
            if ([titleNode respondsToSelector:invalidateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(titleNode, invalidateSel);
            }
            if ([titleNode respondsToSelector:@selector(setNeedsLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(titleNode, @selector(setNeedsLayout));
            }
        }
        // Bubble up: the cell node containing the title also caches layout
        // based on the title's old size. Invalidate the chain of supernodes
        // until we hit the table/collection node.
        id supernode = nil;
        SEL supernodeSel = NSSelectorFromString(@"supernode");
        if ([titleNode respondsToSelector:supernodeSel]) {
            supernode = ((id (*)(id, SEL))objc_msgSend)(titleNode, supernodeSel);
        }
        int hops = 0;
        id cellNode = nil;
        while (supernode && hops < 8) {
            if ([supernode respondsToSelector:invalidateSel]) {
                ((void (*)(id, SEL))objc_msgSend)(supernode, invalidateSel);
            }
            if ([supernode respondsToSelector:@selector(setNeedsLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(supernode, @selector(setNeedsLayout));
            }
            // Remember the first ASCellNode we encounter — we trigger an
            // explicit transition layout on it below so the table view
            // recalculates the row height around the now-larger title.
            if (!cellNode) {
                const char *snName = class_getName([supernode class]);
                if (snName && strstr(snName, "CellNode")) {
                    cellNode = supernode;
                }
            }
            if (![supernode respondsToSelector:supernodeSel]) break;
            supernode = ((id (*)(id, SEL))objc_msgSend)(supernode, supernodeSel);
            hops++;
        }
        // Without a real ASCellNode transition, the table view keeps using
        // the cached row height for the original (shorter) title — that's
        // what causes the "Benfica em Roma" -> "Benfica..." truncation.
        if (cellNode) {
            SEL transitionSel = NSSelectorFromString(@"transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:");
            if ([cellNode respondsToSelector:transitionSel]) {
                NSMethodSignature *sig = [cellNode methodSignatureForSelector:transitionSel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = cellNode;
                    inv.selector = transitionSel;
                    BOOL animated = NO;
                    BOOL async = NO;
                    void (^completion)(void) = nil;
                    [inv setArgument:&animated atIndex:2];
                    [inv setArgument:&async atIndex:3];
                    [inv setArgument:&completion atIndex:4];
                    @try { [inv invoke]; } @catch (__unused NSException *e) {}
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

static void ApolloMaybeTranslatePostTitleNode(id titleNode) {
    if (!titleNode) return;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;

    id textNode = ApolloTitleTextNodeFromTitleNode(titleNode);
    if (!textNode) return;

    // Feed body-preview translation is driven from HERE, not from a cell-class hook:
    // the body preview node has no dedicated node hook, and hooking the post cell class
    // directly proved unreliable (its RDKLink ivar isn't readable, so the body could
    // never be located that way). The PostTitleNode hooks fire reliably for every
    // visible post, so we walk up to the enclosing post cell and translate its body,
    // passing this title's text node so the body-finder never mistakes the title for
    // the body. The owned-node guards make this a cheap no-op once applied.
    {
        id sn = titleNode;
        id cellNode = nil;
        int hops = 0;
        SEL supernodeSel = NSSelectorFromString(@"supernode");
        while (sn && hops < 10) {
            const char *cn = class_getName([sn class]);
            if (cn && strstr(cn, "PostCellNode")) { cellNode = sn; break; }
            if (![sn respondsToSelector:supernodeSel]) break;
            @try { sn = ((id (*)(id, SEL))objc_msgSend)(sn, supernodeSel); }
            @catch (__unused NSException *e) { break; }
            hops++;
        }
        if (cellNode) ApolloMaybeTranslateFeedPostBodyNode(cellNode, textNode);
    }

    NSString *titleText = ApolloVisibleTextFromNode(textNode);
    if (!titleText || titleText.length < 3) return;

    // ---- Per-VC translated-mode gate ----
    // The user's contract: title translation in a feed/thread is gated by
    // that VC's globe state. Use the topmost-visible feed VC (the one the
    // user is actually looking at) instead of walking the title node's
    // responder chain — the responder chain often surfaces a child
    // container VC that doesn't carry the translated-mode flag, which
    // caused tap-on-after-tap-off to silently restore everything.
    UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode(titleNode);
    UIViewController *gateVC = ApolloClassLooksLikeCommentsViewController([enclosingVC class]) ? enclosingVC : ApolloFindTopmostVisibleFeedVC();
    if (!ApolloTitleOwnedNodeShouldShowTranslated(enclosingVC)) {
        // Visible feed is in original mode — restore if we previously
        // translated this node and bail.
        if ([objc_getAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey) boolValue]) {
            NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
            ApolloClearTranslationOwnershipForTextNode(textNode);
            if ([original isKindOfClass:[NSAttributedString class]]) {
                @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original); }
                @catch (__unused NSException *e) {}
            }
        }
        return;
    }

    // Already owned title nodes can be in either display state after a
    // toggle cycle: translated (nothing to do) or original (reapply the
    // cached translation immediately, no network). Do not assume ownership
    // means the node is currently showing translated text.
    if ([objc_getAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey) boolValue]) {
        NSString *ownedTranslated = objc_getAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey);
        NSString *ownedSource = objc_getAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey);
        NSString *currentNorm = ApolloNormalizeTextForCompare(titleText);
        NSString *ownedSourceNorm = ApolloNormalizeTextForCompare(ownedSource);
        NSString *ownedTranslatedNorm = ApolloNormalizeTextForCompare(ownedTranslated);
        if ([ownedTranslated isKindOfClass:[NSString class]] && ownedTranslated.length > 0 &&
            ownedTranslatedNorm.length > 0 && [currentNorm isEqualToString:ownedTranslatedNorm]) {
            if (ApolloClassLooksLikeCommentsViewController([gateVC class])) {
                ApolloMarkVisibleTranslationApplied(ownedSource, ownedTranslated);
            } else {
                ApolloMarkVisibleFeedTitleApplied(ownedSource, ownedTranslated);
            }
            return;
        }
        if ([ownedSource isKindOfClass:[NSString class]] && ownedSource.length > 0 &&
            [ownedTranslated isKindOfClass:[NSString class]] && ownedTranslated.length > 0 &&
            ownedSourceNorm.length > 0 && [currentNorm isEqualToString:ownedSourceNorm]) {
            ApolloApplyTranslationToTitleNode(titleNode, textNode, ownedSource, ownedTranslated);
            return;
        }
        // Title text changed (cell reuse for a new post). Drop ownership and
        // fall through to translate the new text.
        ApolloClearTranslationOwnershipForTextNode(textNode);
    }

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) return;

    // Strip links so URLs don't pollute language detection.
    NSString *detectionText = ApolloProtectTranslationLinks(titleText, NULL);
    NSString *detected = ApolloDetectDominantLanguage(detectionText);
    if ([detected isEqualToString:targetLanguage]) return;

    NSString *cacheKey = ApolloTranslationCacheKey(titleText, targetLanguage);
    __weak id weakTitleNode = titleNode;
    __weak id weakTextNode = textNode;
    ApolloRequestTranslation(cacheKey, titleText, targetLanguage, ^(NSString *translated, NSError *error) {
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) ApolloLog(@"[Translation] Title translate failed: %@", error.localizedDescription ?: @"unknown");
            return;
        }
        if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
        id strongTitleNode = weakTitleNode;
        id strongTextNode = weakTextNode;
        if (!strongTitleNode || !strongTextNode) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-check the visible feed VC mode after async translate — user
            // may have toggled the globe off while the request was in
            // flight. Use topmost-visible feed VC (NOT enclosing) for the
            // same reason as the pre-check above.
            UIViewController *enclosing = ApolloEnclosingViewControllerForNode(strongTitleNode);
            UIViewController *vc = ApolloClassLooksLikeCommentsViewController([enclosing class]) ? enclosing : ApolloFindTopmostVisibleFeedVC();
            if (ApolloClassLooksLikeCommentsViewController([vc class])) {
                if (!ApolloControllerIsInTranslatedMode(vc)) return;
            } else if (!ApolloFeedTitlesShouldShowTranslated(vc)) {
                return;
            }
            ApolloApplyTranslationToTitleNode(strongTitleNode, strongTextNode, titleText, translated);
        });
    });
}

// Feed post-body preview translation. Historically the feed only translated post
// TITLES; the selftext snippet shown under the title in the feed list stayed in the
// original language for every provider (Google/Libre/Apple). This reuses the title
// path's ownership / vote-resilience / restore machinery (ApolloApplyTranslationToTitleNode
// registers the node in the global owned set + sets kApolloTitleOwnedTextNodeKey), so it
// follows the same feed-globe + sTranslatePostTitles gate and restores on toggle-off.
//
// Triggered from ApolloMaybeTranslatePostTitleNode (NOT a cell-class hook): the feed
// cell's runtime class varies and its RDKLink ivar is NOT reliably readable
// (object_getIvar never returns it for LargePostCellNode — confirmed on device), so we
// locate the body preview node WITHOUT the link: walk the cell's text nodes and take the
// longest that isn't the title (excludeTitleNode) and isn't short metadata (author /
// score / timestamp / flair / source label). We translate the *displayed* (truncated)
// preview text, so the cell layout is unchanged.
static void ApolloMaybeTranslateFeedPostBodyNode(id feedCellNode, id excludeTitleNode) {
    if (!feedCellNode) return;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;

    NSMutableArray *candidates = [NSMutableArray array];
    NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
    ApolloCollectAttributedTextNodes(feedCellNode, 6, visited, candidates);

    id textNode = nil;
    NSUInteger bestLen = 0;
    for (id n in candidates) {
        if (excludeTitleNode && n == excludeTitleNode) continue;   // never the title node
        NSString *t = ApolloVisibleTextFromNode(n);
        if (t.length < 25) continue;                               // metadata / author / score are short
        if (ApolloPostTextLooksLikeMetadata(t, nil)) continue;
        if (t.length > bestLen) { bestLen = t.length; textNode = n; }
    }
    if (!textNode) return;

    NSString *previewText = ApolloVisibleTextFromNode(textNode);
    if (previewText.length < 3) return;
    // The node holds the FULL selftext (the display is line-clamped, but attributedText
    // is the whole string). For a feed PREVIEW we only need roughly what's visible, so
    // cap the translated text — otherwise long posts (e.g. 1200+ char Japanese selftext)
    // flood the serial on-device translation session and stall everything behind them.
    // The full body still translates in-thread. Cap on a composed-character boundary so
    // we never split a surrogate pair / combining sequence.
    const NSUInteger kFeedBodyPreviewCap = 400;
    if (previewText.length > kFeedBodyPreviewCap) {
        NSRange r = [previewText rangeOfComposedCharacterSequenceAtIndex:kFeedBodyPreviewCap];
        previewText = [previewText substringToIndex:r.location];
    }

    // Per-VC translated-mode gate (same as titles). When the feed globe is off,
    // restore any previously-translated preview and bail.
    UIViewController *enclosingVC = ApolloEnclosingViewControllerForNode(feedCellNode);
    if (!ApolloTitleOwnedNodeShouldShowTranslated(enclosingVC)) {
        if ([objc_getAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey) boolValue]) {
            NSAttributedString *original = objc_getAssociatedObject(textNode, kApolloOriginalAttributedTextKey);
            ApolloClearTranslationOwnershipForTextNode(textNode);
            if ([original isKindOfClass:[NSAttributedString class]]) {
                @try { ((void (*)(id, SEL, id))objc_msgSend)(textNode, @selector(setAttributedText:), original); }
                @catch (__unused NSException *e) {}
            }
        }
        return;
    }

    // Already-owned node: reapply cached translation (no network) or no-op if it's
    // already showing it. Drop ownership if the cell was recycled to a new post.
    if ([objc_getAssociatedObject(textNode, kApolloTitleOwnedTextNodeKey) boolValue]) {
        NSString *ownedTranslated = objc_getAssociatedObject(textNode, kApolloOwnedNodeTranslatedTextKey);
        NSString *ownedSource = objc_getAssociatedObject(textNode, kApolloOwnedNodeOriginalBodyKey);
        NSString *currentNorm = ApolloNormalizeTextForCompare(previewText);
        NSString *ownedSourceNorm = ApolloNormalizeTextForCompare(ownedSource);
        NSString *ownedTranslatedNorm = ApolloNormalizeTextForCompare(ownedTranslated);
        if ([ownedTranslated isKindOfClass:[NSString class]] && ownedTranslated.length > 0 &&
            ownedTranslatedNorm.length > 0 && [currentNorm isEqualToString:ownedTranslatedNorm]) {
            return;
        }
        if ([ownedSource isKindOfClass:[NSString class]] && ownedSource.length > 0 &&
            [ownedTranslated isKindOfClass:[NSString class]] && ownedTranslated.length > 0 &&
            ownedSourceNorm.length > 0 && [currentNorm isEqualToString:ownedSourceNorm]) {
            ApolloApplyTranslationToTitleNode(textNode, textNode, ownedSource, ownedTranslated);
            return;
        }
        ApolloClearTranslationOwnershipForTextNode(textNode);
    }

    NSString *targetLanguage = ApolloResolvedTargetLanguageCode();
    if (targetLanguage.length == 0) return;

    NSString *detectionText = ApolloProtectTranslationLinks(previewText, NULL);
    NSString *detected = ApolloDetectDominantLanguage(detectionText);
    if ([detected isEqualToString:targetLanguage]) return;

    ApolloLog(@"[FeedBodyDBG] body translate (len=%lu)", (unsigned long)previewText.length);
    NSString *cacheKey = ApolloTranslationCacheKey(previewText, targetLanguage);
    __weak id weakTextNode = textNode;
    ApolloRequestTranslation(cacheKey, previewText, targetLanguage, ^(NSString *translated, NSError *error) {
        if (![translated isKindOfClass:[NSString class]] || translated.length == 0) {
            if (error) ApolloLog(@"[Translation] Feed body translate failed: %@", error.localizedDescription ?: @"unknown");
            return;
        }
        if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
        id strongTextNode = weakTextNode;
        if (!strongTextNode) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Re-check the visible feed mode after the async translate — the user may
            // have toggled the globe off mid-flight.
            UIViewController *enclosing = ApolloEnclosingViewControllerForNode(strongTextNode);
            UIViewController *vc = ApolloClassLooksLikeCommentsViewController([enclosing class]) ? enclosing : ApolloFindTopmostVisibleFeedVC();
            if (ApolloClassLooksLikeCommentsViewController([vc class])) {
                if (!ApolloControllerIsInTranslatedMode(vc)) return;
            } else if (!ApolloFeedTitlesShouldShowTranslated(vc)) {
                return;
            }
            ApolloApplyTranslationToTitleNode(strongTextNode, strongTextNode, previewText, translated);
        });
    });
}

%hook _TtC6Apollo13PostTitleNode

- (void)didLoad {
    %orig;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloMaybeTranslatePostTitleNode(weakSelf); });
}

- (void)didEnterPreloadState {
    %orig;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloMaybeTranslatePostTitleNode(weakSelf); });
}

- (void)didEnterDisplayState {
    %orig;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloMaybeTranslatePostTitleNode(weakSelf); });
}

%end

%hook _TtC6Apollo16PostTitleURLNode

- (void)didLoad {
    %orig;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloMaybeTranslatePostTitleNode(weakSelf); });
}

- (void)didEnterPreloadState {
    %orig;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloMaybeTranslatePostTitleNode(weakSelf); });
}

- (void)didEnterDisplayState {
    %orig;
    if (!sEnableBulkTranslation || !sTranslatePostTitles) return;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ ApolloMaybeTranslatePostTitleNode(weakSelf); });
}

%end

// ---------------------------------------------------------------------------
// Feed view controllers (Posts / LitePosts / PostsSearchResults / Saved)
// ---------------------------------------------------------------------------
//
// When sTranslatePostTitles is on, install a globe button on each feed VC
// matching the existing thread-globe behaviour. The globe controls a
// per-VC translated mode (kApolloThreadTranslatedModeKey) that gates
// title translation in `ApolloMaybeTranslatePostTitleNode` via
// `ApolloEnclosingViewControllerForNode`.
//
// Settings/UI gating contract per user requirements:
//   - Settings titles OFF -> globe never shown, no titles translated.
//   - Settings titles ON  -> globe shown on every feed VC (and existing
//                            thread VC). Tapping toggles green/grey.
//   - Globe ON            -> titles translated as cells become visible.
//   - Globe OFF           -> titles restored to original.
//
// We rely entirely on the existing per-VC mode marker + the title hooks'
// per-VC gate. No additional re-entrant hooks on PostTitleNode.

static void ApolloScheduleFeedSettledTitleRefresh(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return;
    if (!sEnableBulkTranslation || !sTranslatePostTitles || !ApolloControllerIsInTranslatedMode(vc)) return;
    if ([objc_getAssociatedObject(vc, kApolloFeedSettledTitleRefreshScheduledKey) boolValue]) return;
    objc_setAssociatedObject(vc, kApolloFeedSettledTitleRefreshScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongVC = weakVC;
        if (!strongVC) return;
        objc_setAssociatedObject(strongVC, kApolloFeedSettledTitleRefreshScheduledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!strongVC.isViewLoaded || !strongVC.view.window) return;
        if (!sEnableBulkTranslation || !sTranslatePostTitles || !ApolloControllerIsInTranslatedMode(strongVC)) return;
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:512];
        ApolloRescanTitleNodesInTree(strongVC.view, 20, visited);
        ApolloRefreshFeedTranslationStateForController(strongVC);
    });
}

static void ApolloFeedVCInstallGlobe(UIViewController *vc) {
    if (!vc) return;
    if (!sEnableBulkTranslation) return;
    BOOL alreadyMarked = [objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue];
    objc_setAssociatedObject(vc, kApolloFeedTranslationVCKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sLastInstalledFeedViewController = vc;
    // Feed VCs default to "translated mode" so post titles auto-translate
    // the moment a non-English title scrolls into view (matches user
    // expectation: settings titles ON => feeds always translate by default).
    // The globe is a per-VC override the user can flip off.
    NSNumber *storedMode = ApolloStoredFeedTitleModeForController(vc);
    if ([storedMode isKindOfClass:[NSNumber class]]) {
        BOOL translated = storedMode.boolValue;
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @(translated), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @(!translated), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sLastFeedTitleModeKnown = YES;
        sLastFeedTitleTranslatedMode = translated;
        if (!translated) {
            ApolloClearVisibleTranslationApplied(vc);
            sPendingVisibleFeedTitleApplied = NO;
        }
    } else {
        // No explicit per-feed preference (user hasn't tapped the globe on
        // this feed). Always (re)apply the current global default so toggling
        // "Auto Translate by Default" takes effect on next visit even for VCs
        // still alive in memory from a previous install.
        BOOL defaultTranslated = sAutoTranslateOnAppear;
        objc_setAssociatedObject(vc, kApolloThreadTranslatedModeKey, @(defaultTranslated), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kApolloThreadOriginalModeKey, @(!defaultTranslated), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sLastFeedTitleModeKnown = YES;
        sLastFeedTitleTranslatedMode = defaultTranslated;
        if (!defaultTranslated) {
            ApolloClearVisibleTranslationApplied(vc);
            sPendingVisibleFeedTitleApplied = NO;
        }
    }
    if (!alreadyMarked) {
        ApolloLog(@"[Translation] InstallGlobe class=%@ ptr=%p title='%@'",
                  NSStringFromClass([vc class]), vc, vc.navigationItem.title ?: vc.title ?: @"(none)");
    }
    if (sPendingVisibleFeedTitleApplied && ApolloControllerIsInTranslatedMode(vc)) {
        objc_setAssociatedObject(vc, kApolloVisibleTranslationAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sPendingVisibleFeedTitleApplied = NO;
    }
    ApolloRefreshFeedTranslationStateForController(vc);
    ApolloScheduleFeedTranslationStateRefresh(vc, 0.05);
    ApolloScheduleFeedTranslationStateRefresh(vc, 0.2);
    ApolloScheduleFeedTranslationStateRefresh(vc, 0.75);
    ApolloScheduleFeedTranslationStateRefresh(vc, 1.5);
    ApolloScheduleFeedSettledTitleRefresh(vc);
    if (ApolloControllerIsInTranslatedMode(vc)) {
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC || !strongVC.isViewLoaded || !strongVC.view.window) return;
            if (!ApolloControllerIsInTranslatedMode(strongVC)) return;
            ApolloRescanTitleNodesForController(strongVC);
        });
    }
}

// Universal globe-tap selector. The original implementation declared this
// %new on each Swift feed VC class we hook; that broke whenever Home (or
// any future feed surface) was hosted by a class we hadn't hooked, because
// the action selector was silently missing on the target. A category on
// UIViewController guarantees the selector exists on every controller, so
// taps always reach our toggle code regardless of host class.
@interface UIViewController (ApolloTranslationGlobe)
- (void)apollo_translationGlobeTapped;
@end

@implementation UIViewController (ApolloTranslationGlobe)
- (void)apollo_translationGlobeTapped {
    ApolloLog(@"[Translation] GlobeTapped class=%@ ptr=%p", NSStringFromClass([self class]), self);
    if ([objc_getAssociatedObject(self, kApolloFeedTranslationVCKey) boolValue]) {
        ApolloToggleFeedTitleTranslationForController(self);
    } else {
        ApolloToggleThreadTranslationForController(self);
    }
}
@end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
    if (sEnableBulkTranslation && sTranslatePostTitles && ApolloControllerIsInTranslatedMode((UIViewController *)self)) {
        // Re-translate any visible titles in case the user came back to a
        // feed that was previously in translated mode.
        ApolloRescanTitleNodesForController((UIViewController *)self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloScheduleFeedSettledTitleRefresh((UIViewController *)self);
}

%new
- (void)apollo_translationGlobeTapped {
    ApolloToggleFeedTitleTranslationForController((UIViewController *)self);
}

%end

%hook _TtC6Apollo23LitePostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
    if (sEnableBulkTranslation && sTranslatePostTitles && ApolloControllerIsInTranslatedMode((UIViewController *)self)) {
        ApolloRescanTitleNodesForController((UIViewController *)self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloScheduleFeedSettledTitleRefresh((UIViewController *)self);
}

%new
- (void)apollo_translationGlobeTapped {
    ApolloToggleFeedTitleTranslationForController((UIViewController *)self);
}

%end

%hook _TtC6Apollo32PostsSearchResultsViewController

- (void)viewDidLoad {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
    if (sEnableBulkTranslation && sTranslatePostTitles && ApolloControllerIsInTranslatedMode((UIViewController *)self)) {
        ApolloRescanTitleNodesForController((UIViewController *)self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloScheduleFeedSettledTitleRefresh((UIViewController *)self);
}

%new
- (void)apollo_translationGlobeTapped {
    ApolloToggleFeedTitleTranslationForController((UIViewController *)self);
}

%end

%hook _TtC6Apollo25MultiredditViewController

- (void)viewDidLoad {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloFeedVCInstallGlobe((UIViewController *)self);
    if (sEnableBulkTranslation && sTranslatePostTitles && ApolloControllerIsInTranslatedMode((UIViewController *)self)) {
        ApolloRescanTitleNodesForController((UIViewController *)self);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloScheduleFeedSettledTitleRefresh((UIViewController *)self);
}

%new
- (void)apollo_translationGlobeTapped {
    ApolloToggleFeedTitleTranslationForController((UIViewController *)self);
}

%end

// Post-body reapply on header cell redisplay. When the user taps the
// upvote/downvote button on the post in the comments view, Apollo
// invalidates the header cell which triggers `setNeedsLayout` /
// `setNeedsDisplay`; without this hook, the body briefly flashes back to
// the original language until `ApolloSchedulePostBodyReapplyForController`
// fires its (now 30ms, formerly 220ms) fallback. Calling the cached
// reapply scheduler here closes the gap to ~10ms, eliminating the visible
// flash. Only `_TtC6Apollo22CommentsHeaderCellNode` carries selftext
// bodies — the rich-media variant doesn't host the post body text node
// path we translate, so we skip hooking it.
%hook _TtC6Apollo22CommentsHeaderCellNode

- (void)setNeedsLayout {
    %orig;
    ApolloScheduleCachedTranslationReapplyForHeaderCellNode((id)self);
}

- (void)setNeedsDisplay {
    %orig;
    ApolloScheduleCachedTranslationReapplyForHeaderCellNode((id)self);
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
    //
    // BUT: only do this when the controller is currently in translated mode.
    // If the user toggled translation OFF, off-screen cells still hold the
    // translated attributedText on their text nodes (they were never re-laid-
    // out while we restored visible cells). Force-restore those here so the
    // original text reappears as the cell scrolls back into view.
    if (!sEnableBulkTranslation) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *owningVC = ApolloOwningCommentsVCForCellNode((id)self);
        if (ApolloControllerIsInTranslatedMode(owningVC)) {
            if (!ApolloReapplyCachedTranslationForCellNode((id)self)) {
                ApolloMaybeTranslateCommentCellNode((id)self, NO);
            }
        } else if (ApolloControllerIsConfirmedOriginalMode(owningVC)) {
            // Only restore if the owning VC is confirmed to be in original
            // mode. If the VC is unknown (lifecycle race), defer — the
            // viewDidAppear retries will translate the cell shortly.
            RDKComment *comment = ApolloCommentFromCellNode((id)self);
            if (comment) {
                ApolloRestoreOriginalForCellNode((id)self, comment);
            }
        }
    });
}

- (void)cellNodeVisibilityEvent:(NSInteger)event {
    %orig;

    // Event 0 = "will become visible". Re-apply cached translation as soon as
    // possible so the original text never flashes when re-displaying — but
    // only while the thread is in translated mode. If translation was toggled
    // off, restore the original to defeat any stale translated attributedText
    // that's still sitting on the text node from before the toggle-off.
    if (!sEnableBulkTranslation || event != 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *owningVC = ApolloOwningCommentsVCForCellNode((id)self);
        if (ApolloControllerIsInTranslatedMode(owningVC)) {
            ApolloReapplyCachedTranslationForCellNode((id)self);
        } else if (ApolloControllerIsConfirmedOriginalMode(owningVC)) {
            // Same defer-on-unknown rule as didEnterDisplayState above.
            RDKComment *comment = ApolloCommentFromCellNode((id)self);
            if (comment) {
                ApolloRestoreOriginalForCellNode((id)self, comment);
            }
        }
    });
}

%end

%hook _TtC6Apollo22CommentsViewController

- (void)viewDidLoad {
    %orig;
    ApolloUpdateTranslationUIForController(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // Claim ownership AS EARLY AS POSSIBLE. Cell visibility events
    // (`cellNodeVisibilityEvent:`, `didEnterDisplayState`) often fire
    // *before* `viewDidAppear:` on iOS 26, and those handlers gate their
    // translate-vs-restore decision on `sVisibleCommentsViewController`.
    // If we wait until `viewDidAppear:` (as we used to), the global pointer
    // is still nil/stale when those cells arrive, so they take the
    // restore-original branch and the thread renders untranslated until
    // the user scrolls. Setting it here closes that race.
    sVisibleCommentsViewController = (UIViewController *)self;

    ApolloRefreshVisibleTranslationAppliedForController((UIViewController *)self);
    ApolloUpdateTranslationUIForController(self);
    ApolloSchedulePostBodyReapplyForController((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSchedulePostBodyReapplyForController((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    sVisibleCommentsViewController = (UIViewController *)self;

    if (sEnableBulkTranslation && ApolloControllerIsInTranslatedMode((UIViewController *)self)) {
        ApolloRefreshVisibleTranslationAppliedForController((UIViewController *)self);
        ApolloUpdateTranslationUIForController(self);
        // Staggered retries: comments may not be loaded at +0.12s on slower
        // threads (network fetch still in flight, no visible cells yet → the
        // walk is a no-op and the user is left with original-language
        // content). Re-walk a few times so late-arriving cells get picked up
        // without forcing the user to scroll.
        NSArray<NSNumber *> *retryDelays = @[ @0.12, @0.4, @0.9, @1.8 ];
        for (NSNumber *delayNumber in retryDelays) {
            __weak UIViewController *weakSelf = (UIViewController *)self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UIViewController *strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.isViewLoaded || !strongSelf.view.window) return;
                if (!sEnableBulkTranslation || !ApolloControllerIsInTranslatedMode(strongSelf)) return;
                ApolloTranslateVisibleCommentsForController(strongSelf, NO);
                ApolloRefreshVisibleTranslationAppliedForController(strongSelf);
                ApolloUpdateTranslationUIForController(strongSelf);
                ApolloSchedulePostBodyReapplyForController(strongSelf);
            });
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // Bump the cancel generation so any pending toggle reconciles bail out
    // instead of running mid-swipe. Each call to ApolloRestoreAllOwnedTextNodes
    // walks the entire owned-textnode registry and forces cell relayouts —
    // doing that 3× during an interactive pop is the swipe-back lag the user
    // sees.
    NSNumber *cur = objc_getAssociatedObject((id)self, kApolloReconcileGenerationKey);
    NSUInteger next = cur.unsignedIntegerValue + 1;
    objc_setAssociatedObject((id)self, kApolloReconcileGenerationKey, @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

// ---- Disk persistence for the per-comment / per-post translation caches ----
//
// Background: when the user momentarily backgrounds Apollo (swipes home, opens
// Control Center, locks the device) and returns, AsyncDisplayKit can drop the
// attributed text on visible cells, and iOS frequently fires a memory warning
// while the app is suspended. Without persistence the caches that drive the
// re-apply path are empty when the user comes back, and the thread reverts
// to the original language.
//
// We snapshot `sCommentTranslationByFullName` / `sLinkTranslationByFullName`
// to a plist on `DidEnterBackground` and re-hydrate them on launch. Entries
// are tagged with the provider + target language at write time so toggling
// providers or switching language never serves stale text.

static const NSTimeInterval kApolloTranslationDiskCacheTTL = 60 * 60; // 1 hour
static const NSUInteger kApolloTranslationDiskCacheMaxEntries = 2048;
static NSString *const kApolloTranslationDiskCacheVersion = @"v1";

static NSURL *ApolloTranslationDiskCacheURL(void) {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    if (!dir) return nil;
    return [dir URLByAppendingPathComponent:@"apollo-translation-cache-v1.plist"];
}

static NSString *ApolloCurrentTranslationTag(void) {
    NSString *provider = sTranslationProvider.length > 0 ? sTranslationProvider : @"google";
    NSString *language = sTranslationTargetLanguage.length > 0 ? sTranslationTargetLanguage : @"auto";
    return [NSString stringWithFormat:@"%@|%@", provider, language];
}

static void ApolloPersistTranslationCachesToDisk(void) {
    NSURL *url = ApolloTranslationDiskCacheURL();
    if (!url) return;

    NSString *tag = ApolloCurrentTranslationTag();
    NSDate *now = [NSDate date];

    // NSCache doesn't expose its contents — we maintain mirror dictionaries
    // alongside the caches that hold the same data while the app is alive.
    NSDictionary *commentSnapshot = nil;
    NSDictionary *linkSnapshot = nil;
    @synchronized (sCommentTranslationMirror) {
        commentSnapshot = [sCommentTranslationMirror copy];
    }
    @synchronized (sLinkTranslationMirror) {
        linkSnapshot = [sLinkTranslationMirror copy];
    }

    NSMutableArray *commentEntries = [NSMutableArray array];
    NSUInteger written = 0;
    for (NSString *key in commentSnapshot) {
        if (written++ >= kApolloTranslationDiskCacheMaxEntries) break;
        NSString *text = commentSnapshot[key];
        if (![key isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) continue;
        [commentEntries addObject:@{ @"k": key, @"v": text, @"t": now, @"tag": tag }];
    }
    NSMutableArray *linkEntries = [NSMutableArray array];
    written = 0;
    for (NSString *key in linkSnapshot) {
        if (written++ >= kApolloTranslationDiskCacheMaxEntries) break;
        NSString *text = linkSnapshot[key];
        if (![key isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) continue;
        [linkEntries addObject:@{ @"k": key, @"v": text, @"t": now, @"tag": tag }];
    }

    NSDictionary *root = @{
        @"version": kApolloTranslationDiskCacheVersion,
        @"comments": commentEntries,
        @"links": linkEntries,
    };
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
    if (!data) {
        ApolloLog(@"[translation/persist] serialize failed: %@", err);
        return;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        ApolloLog(@"[translation/persist] write failed: %@", err);
        return;
    }
    ApolloLog(@"[translation/persist] wrote %lu comment + %lu link entries", (unsigned long)commentEntries.count, (unsigned long)linkEntries.count);
}

static void ApolloHydrateTranslationCachesFromDisk(void) {
    NSURL *url = ApolloTranslationDiskCacheURL();
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return;

    NSError *err = nil;
    id root = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) {
        ApolloLog(@"[translation/hydrate] bad plist: %@", err);
        return;
    }
    NSString *version = root[@"version"];
    if (![version isEqualToString:kApolloTranslationDiskCacheVersion]) return;

    NSString *currentTag = ApolloCurrentTranslationTag();
    NSDate *now = [NSDate date];

    NSUInteger restored = 0;
    for (NSDictionary *entry in (NSArray *)root[@"comments"]) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *key = entry[@"k"];
        NSString *text = entry[@"v"];
        NSDate *t = entry[@"t"];
        NSString *tag = entry[@"tag"];
        if (![key isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) continue;
        if (![tag isEqualToString:currentTag]) continue;
        if (![t isKindOfClass:[NSDate class]] || [now timeIntervalSinceDate:t] > kApolloTranslationDiskCacheTTL) continue;
        [sCommentTranslationByFullName setObject:text forKey:key];
        ApolloMirrorSetComment(key, text);
        restored++;
    }
    NSUInteger restoredLinks = 0;
    for (NSDictionary *entry in (NSArray *)root[@"links"]) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *key = entry[@"k"];
        NSString *text = entry[@"v"];
        NSDate *t = entry[@"t"];
        NSString *tag = entry[@"tag"];
        if (![key isKindOfClass:[NSString class]] || ![text isKindOfClass:[NSString class]]) continue;
        if (![tag isEqualToString:currentTag]) continue;
        if (![t isKindOfClass:[NSDate class]] || [now timeIntervalSinceDate:t] > kApolloTranslationDiskCacheTTL) continue;
        [sLinkTranslationByFullName setObject:text forKey:key];
        ApolloMirrorSetLink(key, text);
        restoredLinks++;
    }
    ApolloLog(@"[translation/hydrate] restored %lu comments + %lu links (tag=%@)", (unsigned long)restored, (unsigned long)restoredLinks, currentTag);
}

// Re-runs the cache-only translation reapply path for the currently-visible
// comments controller. Used when the app returns to foreground and ASDK has
// dropped the attributed text on visible cells. Per-thread translated-mode
// state is stored as an associated object on the VC and survives backgrounding
// (the VC isn't dealloc'd while the app is suspended), so we just re-render
// from cache (force=NO — never burns a network round-trip on resume).
static void ApolloReapplyTranslationOnAppResume(void) {
    UIViewController *vc = sVisibleCommentsViewController;
    if (!vc) return;
    if (!ApolloControllerIsInTranslatedMode(vc)) return;

    // When the app is suspended long enough for the OS to memory-pressure
    // ASDK (typical when the user opens another app and lets it load), node
    // attributed text gets dropped. Cells then come back showing the
    // original-language strings until the user scrolls and triggers a
    // visibility/layout cycle. Mirror viewDidAppear's staggered retry
    // schedule — force=NO so this is cheap when nothing actually needs to
    // be re-rendered, but each pass will catch any cells whose attributed
    // text was reset since the last pass.
    NSArray<NSNumber *> *retryDelays = @[ @0.0, @0.15, @0.4, @0.9, @1.8, @3.0 ];
    for (NSNumber *delayNumber in retryDelays) {
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayNumber.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *current = weakVC ?: sVisibleCommentsViewController;
            if (!current || !current.isViewLoaded || !current.view.window) return;
            if (!ApolloControllerIsInTranslatedMode(current)) return;
            ApolloRefreshVisibleTranslationAppliedForController(current);
            ApolloUpdateTranslationUIForController(current);
            ApolloTranslateVisibleCommentsForController(current, NO);
            // Tree-walk so loaded-but-not-in-visibleCells nodes also reapply.
            ApolloReapplyVisibleCommentCellNodesForController(current, NO);
            ApolloSchedulePostBodyReapplyForController(current);
        });
    }
}

// Liquid Glass globe-merge re-injection. Apollo rebuilds its combined trailing
// button container on various events (mod-status load, trait changes, etc.) and
// re-sets it via setRightBarButtonItem(s):. When a nav item is flagged for the
// globe merge, re-inject the globe into the freshly-built container after each
// set. sApplyingGlobeMerge guards against our own re-set recursing.
%hook UINavigationItem

- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated {
    %orig(items, animated);
    if (sApplyingGlobeMerge) return;
    if (IsLiquidGlass() && objc_getAssociatedObject(self, kApolloGlobeMergeButtonKey)) {
        ApolloApplyGlobeMergeForNavItem(self);
    }
}

- (void)setRightBarButtonItem:(UIBarButtonItem *)item animated:(BOOL)animated {
    %orig(item, animated);
    if (sApplyingGlobeMerge) return;
    if (IsLiquidGlass() && objc_getAssociatedObject(self, kApolloGlobeMergeButtonKey)) {
        ApolloApplyGlobeMergeForNavItem(self);
    }
}

%end

%ctor {
    sTranslationCache = [NSCache new];
    sCommentTranslationByFullName = [NSCache new];
    sCommentTranslationByFullName.countLimit = 2048;
    sLinkTranslationByFullName = [NSCache new];
    sLinkTranslationByFullName.countLimit = 256;
    sLoggedSkippedCommentFullNames = [NSMutableSet set];
    sLoggedSkippedStructuredPostFullNames = [NSMutableSet set];
    sCommentTranslationMirror = [NSMutableDictionary dictionary];
    sLinkTranslationMirror = [NSMutableDictionary dictionary];
    sPendingTranslationCallbacks = [NSMutableDictionary dictionary];
    sRichPreviewTranslationInFlightKeys = [NSMutableSet set];
    sFeedTitleModeByFeedKey = [NSMutableDictionary dictionary];
    sOwnedTextNodes = [NSHashTable hashTableWithOptions:(NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality)];
    sOwnedTextNodesQueue = dispatch_queue_create("ca.jeffrey.apollo.translation.ownednodes", DISPATCH_QUEUE_SERIAL);

    // Hydrate disk cache early so any cells laid out during the first frame
    // already see translations.
    ApolloHydrateTranslationCachesFromDisk();

    // Memory-warning handler: only drop the raw key->text cache (cheap to
    // recompute via the persistent fullName caches). Do NOT wipe the
    // per-comment / per-post caches — iOS sends memory warnings when the app
    // is backgrounded, and clearing them caused translated threads to revert
    // to the original language as soon as the user returned to Apollo.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        [sTranslationCache removeAllObjects];
    }];

    // App lifecycle: snapshot caches when going to background; re-apply the
    // active thread's translation on return.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloPersistTranslationCachesToDisk();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloReapplyTranslationOnAppResume();
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification
                                                            object:nil
                                                          userInfo:@{@"reason": @"lifecycle"}];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloReapplyTranslationOnAppResume();
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloRichPreviewTranslationDidUpdateNotification
                                                            object:nil
                                                          userInfo:@{@"reason": @"lifecycle"}];
    }];

    // When the user changes the "Don't Translate" language list, blow away every
    // translation cache so previously-skipped (and cached as source==translation)
    // text gets a fresh provider call on the next view.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloTranslationSkipLanguagesChanged"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        [sTranslationCache removeAllObjects];
        [sCommentTranslationByFullName removeAllObjects];
        [sLinkTranslationByFullName removeAllObjects];
        @synchronized (sLoggedSkippedCommentFullNames) {
            [sLoggedSkippedCommentFullNames removeAllObjects];
        }
        @synchronized (sLoggedSkippedStructuredPostFullNames) {
            [sLoggedSkippedStructuredPostFullNames removeAllObjects];
        }
        ApolloLog(@"[Translation] Skip-languages changed; flushed translation caches");

        // Actively re-translate visible comments now (instead of waiting for
        // the next scroll/reuse). If the user just *removed* a language from
        // the skip list, the visible cells will pick up translations within
        // ~100ms instead of feeling laggy. If they *added* a language, the
        // skip-detect inside the per-comment translator path will short-circuit.
        UIViewController *visibleCommentsVC = sVisibleCommentsViewController;
        if (visibleCommentsVC && visibleCommentsVC.isViewLoaded && visibleCommentsVC.view.window
            && ApolloControllerIsInTranslatedMode(visibleCommentsVC)) {
            ApolloLog(@"[Translation] Re-translating visible comments after skip-languages change");
            ApolloTranslateVisibleCommentsForController(visibleCommentsVC, NO);
        }

        // Same idea for the visible feed VC: rescan titles so newly-allowed
        // languages translate now, AND clear the cached "applied" flag so the
        // green globe accurately reflects the current visible state. If the
        // user just added the dominant feed language to the skip list,
        // nothing visible will translate and the globe should drop back to
        // its un-applied appearance.
        UIViewController *visibleFeedVC = ApolloFindTopmostVisibleFeedVC();
        if (visibleFeedVC && visibleFeedVC.isViewLoaded && visibleFeedVC.view.window
            && [objc_getAssociatedObject(visibleFeedVC, kApolloFeedTranslationVCKey) boolValue]
            && ApolloControllerIsInTranslatedMode(visibleFeedVC)) {
            ApolloLog(@"[Translation] Refreshing visible feed titles after skip-languages change");
            ApolloClearVisibleTranslationApplied(visibleFeedVC);
            sPendingVisibleFeedTitleApplied = NO;
            ApolloRescanTitleNodesForController(visibleFeedVC);
            // Re-evaluate after the rescan has had time to issue/complete
            // translations \u2014 if anything came back translated, the globe
            // flips back to applied; if nothing did, it stays cleared.
            ApolloScheduleFeedTranslationStateRefresh(visibleFeedVC, 0.6);
            ApolloScheduleFeedTranslationStateRefresh(visibleFeedVC, 1.5);
        }
    }];

    // Live-update when the user toggles "Translate Post Titles" in settings:
    // refresh the topmost UIViewController so the feed-VC globe is added or
    // removed immediately and any owned title nodes are restored.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloTranslatePostTitlesChanged"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        if (!sTranslatePostTitles) {
            // Restore every title node we still own.
            ApolloRestoreAllOwnedTextNodes();
            [sFeedTitleModeByFeedKey removeAllObjects];
            sPendingVisibleFeedTitleApplied = NO;
            sLastFeedTitleModeKnown = NO;
            sLastFeedTitleTranslatedMode = YES;
        }
        // Walk the keyWindow's VC tree and update any feed VC.
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
                if (keyWindow) break;
            }
        }
        if (!keyWindow) return;
        UIViewController *root = keyWindow.rootViewController;
        NSMutableArray *queue = [NSMutableArray array];
        if (root) [queue addObject:root];
        while (queue.count) {
            UIViewController *vc = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([objc_getAssociatedObject(vc, kApolloFeedTranslationVCKey) boolValue]) {
                ApolloUpdateTranslationUIForController(vc);
            }
            for (UIViewController *child in vc.childViewControllers) [queue addObject:child];
            if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
        }
    }];

    %init;
}
