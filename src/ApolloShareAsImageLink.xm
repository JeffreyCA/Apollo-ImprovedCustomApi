// ApolloShareAsImageLink.xm
//
// "Include Link" option for Share as Image (issue #481).
//
// Apollo's ShareAsImageViewController (_TtC6Apollo26ShareAsImageViewController)
// renders a post or comment into a shareable image and presents the system
// share sheet (UIActivityViewController) when the user taps "Share". This module
// adds one extra options row — "Include Link" — beneath the native Watermark
// row. When the toggle is ON, the Reddit URL of the shared post/comment is
// appended to the share sheet's items, so apps like Messages and Mail attach the
// image AND a tappable link to the original thread. The preference persists in
// NSUserDefaults and defaults OFF (opt-in, preserves stock behaviour).
//
// Two halves:
//   1. UI — a UILabel + UISwitch (+ hairline separator) created in viewDidLoad,
//      styled from the native Watermark row, positioned one row below Watermark in
//      viewDidLayoutSubviews. The hosting bottom-sheet is made one row taller by a
//      hook on SourdoughPresentationController.frameOfPresentedViewInContainerView
//      by adjusting the presentation controller's frame directly, avoiding
//      layout feedback loops, so the Share button is never clipped.
//   2. Share interception — shareButtonTappedWithSender: records the active VC
//      and the toggle state, then the UIActivityViewController designated
//      initializer hook appends the link (via a UIActivityItemSource that keeps
//      photo-only activities image-only) while that flag is set.
//
// No hardcoded binary addresses: everything is ObjC-runtime ivar access (ivar
// names from class-dump headers) plus public UIKit selectors, with defensive
// guards throughout.
//
// MODULE ORDERING (Makefile ApolloReborn_FILES): this module is listed after
// ApolloShareAsImageGallery and before ApolloShareAsVideo, i.e.
// Gallery -> Link -> Video -> PreviewFix. All four hook
// _TtC6Apollo26ShareAsImageViewController (and the first three also
// SourdoughPresentationController); they compose via %ctor/%init() order. This
// module's option row stacks one row below Gallery's in its viewDidLayoutSubviews
// pass, and ApolloShareAsVideo's share-button hook installs after ours (so it is
// outermost and can suppress the native share). The link-append below is written to
// be idempotent (see ApolloShareLinkAlreadyHasLinkSource), so it no longer depends
// on that hook order to avoid a double link — but if you reorder these in the
// Makefile, re-verify the option-row layout still stacks correctly.

#import <UIKit/UIKit.h>
#import <LinkPresentation/LinkPresentation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"
#import "ApolloState.h"

// Persisted preference: whether "Include Link" is on. Default NO.
static NSString *const kApolloShareIncludeLinkKey = @"ApolloShareAsImageIncludeLink";

// Display text for the new options row.
static NSString *const kApolloShareIncludeLinkTitle = @"Include Link";

// Associated-object keys for the views we add to the VC. Repo idiom: bare
// `static char` whose address is the key (avoids -fmerge-all-constants aliasing).
static char kApolloShareLinkLabelKey;     // strong UILabel
static char kApolloShareLinkSwitchKey;    // strong UISwitch
static char kApolloShareLinkSeparatorKey; // strong UIView

// Active-share handshake between the button tap and the share-sheet construction.
// Set on the main thread in shareButtonTappedWithSender:, read in the
// UIActivityViewController init hook, both on the main thread.
static __weak id sActiveShareVC = nil;
static BOOL sActiveShareIncludeLink = NO;

#pragma mark - Runtime ivar helpers

static id ApolloShareLinkIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    @try { return object_getIvar(obj, ivar); } @catch (__unused NSException *e) { return nil; }
}

// Reads a Swift CGFloat (== double on arm64) stored ivar by raw offset.
static double ApolloShareLinkIvarDouble(id obj, const char *name) {
    if (!obj || !name) return 0.0;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return 0.0;
    ptrdiff_t offset = ivar_getOffset(ivar);
    const unsigned char *base = (const unsigned char *)(__bridge const void *)obj;
    double value = 0.0;
    memcpy(&value, base + offset, sizeof(double));
    return value;
}

#pragma mark - Link resolution

// RDKLink.permalink returns a *relative* NSURL (just the path, e.g.
// "/r/sub/comments/id/title/"), which is useless once handed to
// Messages/Mail. Resolve any scheme-less URL against the reddit web host so the
// recipient gets a tappable absolute link. Already-absolute URLs pass through.
static NSURL *ApolloShareLinkAbsoluteURL(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return nil;
    if (url.scheme.length > 0 && url.host.length > 0) return url;
    NSString *path = url.absoluteString ?: @"";
    if (path.length == 0) return nil;
    if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
    NSURL *abs = [NSURL URLWithString:[@"https://www.reddit.com" stringByAppendingString:path]];
    return abs ?: url;
}

// Resolves the Reddit URL to attach for the share-as-image VC. Always the whole
// post thread — even when sharing a comment, we link to the post, not the
// specific comment. The `link` ivar holds the post in both post- and comment-
// share modes, so this is uniform. Prefer the canonical reddit permalink,
// falling back to the link's content URL. Returns nil if nothing usable is found.
static NSURL *ApolloShareLinkURLForVC(id vc) {
    if (!vc) return nil;

    id link = ApolloShareLinkIvarObject(vc, "link");
    if (link) {
        @try {
            if ([link respondsToSelector:@selector(permalink)]) {
                id permalink = ((id (*)(id, SEL))objc_msgSend)(link, @selector(permalink));
                if ([permalink isKindOfClass:[NSURL class]]) return ApolloShareLinkAbsoluteURL((NSURL *)permalink);
            }
        } @catch (__unused NSException *e) {}
        @try {
            if ([link respondsToSelector:@selector(URL)]) {
                id url = ((id (*)(id, SEL))objc_msgSend)(link, @selector(URL));
                if ([url isKindOfClass:[NSURL class]]) return ApolloShareLinkAbsoluteURL((NSURL *)url);
            }
        } @catch (__unused NSException *e) {}
    }

    return nil;
}

#pragma mark - Share host rewriting

// Rewrites outgoing Reddit URLs to the user's selected share host.
static BOOL ApolloShareLinkIsRedditWebHost(NSString *host) {
    NSString *lower = host.lowercaseString;
    if (lower.length == 0) return NO;
    return [lower isEqualToString:@"reddit.com"] ||
           [lower isEqualToString:@"www.reddit.com"] ||
           [lower isEqualToString:@"old.reddit.com"] ||
           [lower isEqualToString:@"new.reddit.com"] ||
           [lower isEqualToString:@"np.reddit.com"];
}

static NSURL *ApolloShareLinkURLWithHost(NSURL *url, NSString *host) {
    if (![url isKindOfClass:[NSURL class]] || host.length == 0) return url;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components || !ApolloShareLinkIsRedditWebHost(components.host)) return url;
    components.scheme = @"https";
    components.host = host;
    return components.URL ?: url;
}

static NSURL *ApolloShareLinkRewriteURLForCurrentHost(NSURL *url) {
    NSString *host = ApolloShareLinkHostDomain((ShareLinkHost)sShareLinkHost);
    return host.length > 0 ? ApolloShareLinkURLWithHost(url, host) : url;
}

static NSString *ApolloShareLinkRewriteStringForCurrentHost(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return string;
    NSURL *url = [NSURL URLWithString:string];
    if (![url isKindOfClass:[NSURL class]] || url.scheme.length == 0 || url.host.length == 0) return string;
    NSURL *rewritten = ApolloShareLinkRewriteURLForCurrentHost(url);
    if (rewritten == url) return string;
    return rewritten.absoluteString ?: string;
}

static id ApolloShareLinkRewriteActivityItemForCurrentHost(id item,
                                                           BOOL wrapItemSources);

@interface ApolloShareHostRewritingItemSource : NSObject <UIActivityItemSource>
@property (nonatomic, strong) id<UIActivityItemSource> originalItemSource;
@end

@implementation ApolloShareHostRewritingItemSource

- (BOOL)respondsToSelector:(SEL)selector {
    if (selector == @selector(activityViewController:subjectForActivityType:) ||
        selector == @selector(activityViewController:dataTypeIdentifierForActivityType:) ||
        selector == @selector(activityViewController:thumbnailImageForActivityType:suggestedSize:) ||
        selector == @selector(activityViewControllerLinkMetadata:)) {
        return [self.originalItemSource respondsToSelector:selector];
    }
    return [super respondsToSelector:selector];
}

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController {
    id item = [self.originalItemSource activityViewControllerPlaceholderItem:activityViewController];
    return ApolloShareLinkRewriteActivityItemForCurrentHost(item, NO) ?: item;
}

- (id)activityViewController:(UIActivityViewController *)activityViewController
         itemForActivityType:(UIActivityType)activityType {
    id item = [self.originalItemSource activityViewController:activityViewController itemForActivityType:activityType];
    return ApolloShareLinkRewriteActivityItemForCurrentHost(item, NO) ?: item;
}

- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
              subjectForActivityType:(UIActivityType)activityType {
    if (![self.originalItemSource respondsToSelector:_cmd]) return nil;
    return [self.originalItemSource activityViewController:activityViewController subjectForActivityType:activityType];
}

- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
dataTypeIdentifierForActivityType:(UIActivityType)activityType {
    if (![self.originalItemSource respondsToSelector:_cmd]) return nil;
    return [self.originalItemSource activityViewController:activityViewController dataTypeIdentifierForActivityType:activityType];
}

- (UIImage *)activityViewController:(UIActivityViewController *)activityViewController
thumbnailImageForActivityType:(UIActivityType)activityType
                      suggestedSize:(CGSize)size {
    if (![self.originalItemSource respondsToSelector:_cmd]) return nil;
    return [self.originalItemSource activityViewController:activityViewController thumbnailImageForActivityType:activityType suggestedSize:size];
}

- (LPLinkMetadata *)activityViewControllerLinkMetadata:(UIActivityViewController *)activityViewController {
    if (![self.originalItemSource respondsToSelector:_cmd]) return nil;
    LPLinkMetadata *metadata = [self.originalItemSource activityViewControllerLinkMetadata:activityViewController];
    if (![metadata isKindOfClass:[LPLinkMetadata class]]) return metadata;

    NSURL *originalURL = metadata.originalURL;
    NSURL *rewrittenOriginalURL = ApolloShareLinkRewriteURLForCurrentHost(originalURL);
    if (rewrittenOriginalURL != originalURL) metadata.originalURL = rewrittenOriginalURL;

    NSURL *url = metadata.URL;
    NSURL *rewrittenURL = ApolloShareLinkRewriteURLForCurrentHost(url);
    if (rewrittenURL != url) metadata.URL = rewrittenURL;

    return metadata;
}

@end

static id ApolloShareLinkOriginalItemSource(id item) {
    if ([item isKindOfClass:[ApolloShareHostRewritingItemSource class]]) {
        return ((ApolloShareHostRewritingItemSource *)item).originalItemSource ?: item;
    }
    return item;
}

static id ApolloShareLinkRewriteActivityItemForCurrentHost(id item,
                                                           BOOL wrapItemSources) {
    if ([item isKindOfClass:[NSURL class]]) {
        return ApolloShareLinkRewriteURLForCurrentHost((NSURL *)item) ?: item;
    }
    if ([item isKindOfClass:[NSString class]]) {
        return ApolloShareLinkRewriteStringForCurrentHost((NSString *)item) ?: item;
    }
    if (wrapItemSources &&
        ![item isKindOfClass:[ApolloShareHostRewritingItemSource class]] &&
        [item conformsToProtocol:@protocol(UIActivityItemSource)]) {
        ApolloShareHostRewritingItemSource *source = [[ApolloShareHostRewritingItemSource alloc] init];
        source.originalItemSource = (id<UIActivityItemSource>)item;
        return source;
    }
    return item;
}

static NSArray *ApolloShareLinkRewriteActivityItemsForCurrentHost(NSArray *items,
                                                                  BOOL wrapItemSources) {
    if (sShareLinkHost == ShareLinkHostDefault || ![items isKindOfClass:[NSArray class]]) return items;

    NSMutableArray *rewrittenItems = [NSMutableArray arrayWithCapacity:items.count];
    BOOL changed = NO;
    for (id item in items) {
        id rewritten = ApolloShareLinkRewriteActivityItemForCurrentHost(item, wrapItemSources);
        id itemToAdd = rewritten ?: item;
        [rewrittenItems addObject:itemToAdd];

        if (itemToAdd != item) {
            changed = YES;
        }
    }
    if (changed) {
        ApolloLog(@"[ShareLink] rewrote outgoing share item host=%ld", (long)sShareLinkHost);
        return rewrittenItems;
    }
    return items;
}

#pragma mark - Activity item source

// Supplies the link URL to the share sheet. Returns the URL for sharing/messaging
// activities but nil for photo-only destinations (Save to Photos, Assign to
// Contact, Print) so those keep operating on the image alone.
@interface ApolloShareLinkItemSource : NSObject <UIActivityItemSource>
@property (nonatomic, strong) NSURL *url;
@end

@implementation ApolloShareLinkItemSource

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController {
    return self.url ?: (id)[NSNull null];
}

- (id)activityViewController:(UIActivityViewController *)activityViewController
         itemForActivityType:(UIActivityType)activityType {
    if (!self.url) return nil;
    if ([activityType isEqualToString:UIActivityTypeSaveToCameraRoll] ||
        [activityType isEqualToString:UIActivityTypeAssignToContact] ||
        [activityType isEqualToString:UIActivityTypePrint]) {
        return nil; // keep these image-only
    }
    return self.url;
}

@end

#pragma mark - Options row UI

// Builds (once) the Include Link label + switch + separator and adds them to the
// same container as the native Watermark row. Styling is copied from the
// Watermark row so the new row matches the current theme.
static void ApolloShareLinkInstallRow(id vc) {
    if (!vc) return;
    if (objc_getAssociatedObject(vc, &kApolloShareLinkSwitchKey)) return; // already built

    UILabel *watermarkLabel = (UILabel *)ApolloShareLinkIvarObject(vc, "watermarkRowTitleLabel");
    UISwitch *watermarkSwitch = (UISwitch *)ApolloShareLinkIvarObject(vc, "watermarkRowSwitch");
    if (![watermarkLabel isKindOfClass:[UILabel class]] ||
        ![watermarkSwitch isKindOfClass:[UISwitch class]]) {
        ApolloLog(@"[ShareLink] install: watermark row not found — skipping row");
        return;
    }

    UIView *container = watermarkLabel.superview;
    if (!container) {
        ApolloLog(@"[ShareLink] install: watermark label has no superview — skipping row");
        return;
    }

    // Label — mirror the native row's font/colour/alignment.
    UILabel *label = [[UILabel alloc] init];
    label.text = kApolloShareIncludeLinkTitle;
    label.font = watermarkLabel.font;
    label.textColor = watermarkLabel.textColor;
    label.textAlignment = watermarkLabel.textAlignment;
    label.numberOfLines = watermarkLabel.numberOfLines;
    [container addSubview:label];

    // Switch — mirror the native switch tint, seed from the saved preference.
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.onTintColor = watermarkSwitch.onTintColor;
    toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:kApolloShareIncludeLinkKey];
    [toggle addTarget:vc action:@selector(apollo_shareIncludeLinkToggled:)
     forControlEvents:UIControlEventValueChanged];
    [container addSubview:toggle];

    // Hairline separator matching the existing ones.
    UIView *separator = [[UIView alloc] init];
    NSArray *separators = (NSArray *)ApolloShareLinkIvarObject(vc, "separators");
    UIView *templateSep = [separators isKindOfClass:[NSArray class]] ? [separators lastObject] : nil;
    separator.backgroundColor = [templateSep isKindOfClass:[UIView class]]
        ? templateSep.backgroundColor
        : [UIColor colorWithWhite:0.5 alpha:0.3];
    [container addSubview:separator];

    objc_setAssociatedObject(vc, &kApolloShareLinkLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kApolloShareLinkSwitchKey, toggle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kApolloShareLinkSeparatorKey, separator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ApolloLog(@"[ShareLink] options row installed (on=%d)", (int)toggle.on);
}

// Native gap between the last options row and the Share button (matches Apollo's
// own row→button spacing). Used to place our relocated button consistently.
static const CGFloat kApolloShareLinkButtonGap = 20.0;

// Positions our "Include Link" row directly below the Watermark row and nudges the
// Share button down to sit beneath it. This ONLY moves subviews — it never touches
// the presented view's own frame. The sheet is made one row taller by the
// SourdoughPresentationController hook below, so there's room for the relocated
// button without us fighting the presentation controller (an earlier frame-based
// grow here caused a layout feedback loop / watchdog hang when a native toggle
// changed the content height). Recomputed from live native frames every pass, so
// it stays correct across content toggles, theme changes, and rotation.
static void ApolloShareLinkLayoutRow(id vc) {
    UILabel *label = (UILabel *)objc_getAssociatedObject(vc, &kApolloShareLinkLabelKey);
    UISwitch *toggle = (UISwitch *)objc_getAssociatedObject(vc, &kApolloShareLinkSwitchKey);
    UIView *separator = (UIView *)objc_getAssociatedObject(vc, &kApolloShareLinkSeparatorKey);
    if (!label || !toggle) return;

    UILabel *watermarkLabel = (UILabel *)ApolloShareLinkIvarObject(vc, "watermarkRowTitleLabel");
    UISwitch *watermarkSwitch = (UISwitch *)ApolloShareLinkIvarObject(vc, "watermarkRowSwitch");
    if (![watermarkLabel isKindOfClass:[UILabel class]] ||
        ![watermarkSwitch isKindOfClass:[UISwitch class]]) return;

    CGRect wl = watermarkLabel.frame;
    CGRect ws = watermarkSwitch.frame;

    // Row pitch: prefer the native rowHeight ivar; fall back to the label height.
    double pitch = ApolloShareLinkIvarDouble(vc, "rowHeight");
    if (pitch <= 1.0) pitch = wl.size.height > 0 ? wl.size.height : 44.0;

    toggle.frame = CGRectOffset(ws, 0, pitch);
    // "Include Link" is wider than "Watermark"; widen the label to fill the space
    // up to the switch so it isn't truncated (the native frame fits its own text).
    CGFloat labelW = MAX(wl.size.width, CGRectGetMinX(toggle.frame) - 8.0 - wl.origin.x);
    label.frame = CGRectMake(wl.origin.x, wl.origin.y + pitch, labelW, wl.size.height);

    // Separator: clone the bottom-most native separator's geometry, shifted down.
    NSArray *separators = (NSArray *)ApolloShareLinkIvarObject(vc, "separators");
    UIView *templateSep = [separators isKindOfClass:[NSArray class]] ? [separators lastObject] : nil;
    if (separator && [templateSep isKindOfClass:[UIView class]]) {
        separator.frame = CGRectOffset(templateSep.frame, 0, pitch);
        separator.hidden = templateSep.hidden;
    } else if (separator) {
        separator.frame = CGRectMake(wl.origin.x, CGRectGetMaxY(label.frame) + 0.5,
                                     wl.size.width, 1.0 / [UIScreen mainScreen].scale);
    }

    // Place the Share button just below our row (the sheet was grown by one row to
    // make room — see the presentation-controller hook). Deterministic + idempotent:
    // Apollo re-lays the button each %orig pass, we always re-anchor it under our row.
    UIView *shareButton = (UIView *)ApolloShareLinkIvarObject(vc, "shareButton");
    if ([shareButton isKindOfClass:[UIView class]]) {
        CGRect bf = shareButton.frame;
        bf.origin.y = CGRectGetMaxY(label.frame) + kApolloShareLinkButtonGap;
        shareButton.frame = bf;
    }
}

#pragma mark - Hooks

%hook _TtC6Apollo26ShareAsImageViewController

- (void)viewDidLoad {
    %orig;
    ApolloShareLinkInstallRow(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloShareLinkLayoutRow(self);
}

%new
- (void)apollo_shareIncludeLinkToggled:(UISwitch *)sender {
    BOOL on = [sender isKindOfClass:[UISwitch class]] ? sender.isOn : NO;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kApolloShareIncludeLinkKey];
    ApolloLog(@"[ShareLink] toggle -> %d", (int)on);
}

- (void)shareButtonTappedWithSender:(id)sender {
    sActiveShareVC = self;
    sActiveShareIncludeLink = [[NSUserDefaults standardUserDefaults] boolForKey:kApolloShareIncludeLinkKey];
    %orig;
    // Safety net: clear the handshake shortly after, in case no activity sheet is
    // built (the init hook also clears it immediately on a successful append). Reset
    // both fields so neither is left latched into a later, unrelated share.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ sActiveShareVC = nil; sActiveShareIncludeLink = NO; });
}

%end

// Does this share sheet ALREADY carry one of our Reddit-link item sources? Both this
// module (ApolloShareLinkItemSource) and ApolloShareAsVideo (ApolloSVLinkItemSource)
// attach one when their feature is on, and ApolloShareAsVideo presents its OWN
// activity sheet — whose initWithActivityItems: flows through THIS very hook. When
// the video path took over the share (both toggles on) it already added the link, so
// re-appending here would produce a double link. Gating on this makes the append
// idempotent regardless of Makefile hook order or how long the handshake timer below
// stays open — directly addressing the latent double-link path. We match the two
// concrete source classes (this module's directly; the video module's via a runtime
// objc_getClass lookup so there's no hard link/symbol or Makefile-order dependency),
// rather than an open-ended name match that could false-positive on a native class.
static BOOL ApolloShareLinkAlreadyHasLinkSource(NSArray *items) {
    if (![items isKindOfClass:[NSArray class]]) return NO;
    Class svLinkClass = objc_getClass("ApolloSVLinkItemSource"); // ApolloShareAsVideo's link source, if loaded
    for (id item in items) {
        id originalItem = ApolloShareLinkOriginalItemSource(item);
        if ([originalItem isMemberOfClass:[ApolloShareLinkItemSource class]]) return YES;
        if (svLinkClass && [originalItem isMemberOfClass:svLinkClass]) return YES;
    }
    return NO;
}

%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(NSArray *)applicationActivities {
    // This hook fires for every UIActivityViewController. It rewrites URLs for a
    // non-default share host, while the share-as-image handshake appends its link.
    id vc = sActiveShareVC;
    NSArray *rewrittenActivityItems = ApolloShareLinkRewriteActivityItemsForCurrentHost(activityItems, YES);
    if (vc && sActiveShareIncludeLink && !ApolloShareLinkAlreadyHasLinkSource(rewrittenActivityItems)) {
        NSURL *url = ApolloShareLinkURLForVC(vc);
        if ([url isKindOfClass:[NSURL class]]) {
            sActiveShareVC = nil;          // consume the handshake so we only append once
            sActiveShareIncludeLink = NO;  // reset too, so the flag is never left latched
            ApolloShareLinkItemSource *source = [[ApolloShareLinkItemSource alloc] init];
            source.url = ApolloShareLinkRewriteURLForCurrentHost(url);
            NSMutableArray *items = [rewrittenActivityItems isKindOfClass:[NSArray class]]
                ? [rewrittenActivityItems mutableCopy] : [NSMutableArray array];
            [items addObject:source];
            ApolloLog(@"[ShareLink] appended link to share sheet: %@", source.url.absoluteString);
            return %orig(items, applicationActivities);
        }
        ApolloLog(@"[ShareLink] share active but no link resolved — leaving items unchanged");
    }
    return %orig(rewrittenActivityItems, applicationActivities);
}

%end

#pragma mark - Copy Link support

// Apollo's custom Copy Link activity receives the rewritten share URL, but
// performs its own internal copy operation. Cache the rewritten URL during
// activity preparation, then replace the clipboard after Apollo finishes.
static char kApolloCopyURLActivityURLKey;

%hook _TtC6Apollo15CopyURLActivity

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems {
    if (sShareLinkHost == ShareLinkHostDefault) return %orig;

    NSURL *rewrittenURL = nil;

    if ([activityItems isKindOfClass:[NSArray class]]) {
        for (id item in activityItems) {
            if ([item isKindOfClass:[NSURL class]]) {
                NSURL *originalURL = (NSURL *)item;
                NSURL *candidate = ApolloShareLinkRewriteURLForCurrentHost(originalURL);
                if (candidate != originalURL) {
                    rewrittenURL = candidate;
                    break;
                }
            }

            if ([item isKindOfClass:[NSString class]]) {
                NSURL *originalURL = [NSURL URLWithString:(NSString *)item];
                NSURL *candidate = ApolloShareLinkRewriteURLForCurrentHost(originalURL);
                if (candidate != originalURL) {
                    rewrittenURL = candidate;
                    break;
                }
            }
        }
    }

    if (rewrittenURL) {
        objc_setAssociatedObject(self,
                                 &kApolloCopyURLActivityURLKey,
                                 rewrittenURL,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        objc_setAssociatedObject(self,
                                 &kApolloCopyURLActivityURLKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return %orig;
}

- (void)performActivity {
    if (sShareLinkHost == ShareLinkHostDefault) {
        %orig;
        return;
    }

    NSURL *rewrittenURL =
        objc_getAssociatedObject(self, &kApolloCopyURLActivityURLKey);

    if (![rewrittenURL isKindOfClass:[NSURL class]]) {
        ApolloLog(@"[ShareLink] CopyURLActivity had no cached URL; using stock behavior");
        %orig;
        return;
    }

    // Preserve Apollo's normal Copy Link behavior, then correct the final
    // pasteboard value using the URL captured from the rewritten share items.
    %orig;
    [UIPasteboard generalPasteboard].URL = rewrittenURL;

    ApolloLog(@"[ShareLink] CopyURLActivity replaced copied URL=%@",
              rewrittenURL.absoluteString);
}

%end

// The Share-as-Image preview is hosted in a custom bottom-sheet presentation
// controller that sizes the sheet to Apollo's native content. We add an extra
// "Include Link" row, so ask the controller for one row more height (extending the
// sheet upward, bottom edge anchored). Doing it here — in the controller's own
// frame method — is the loop-free way to grow the sheet: UIKit applies the
// returned frame, there's nothing to fight, and it's recomputed automatically on
// every content/size change (toggles, rotation). Only affects the Share-as-Image VC.
%hook _TtC6Apollo31SourdoughPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    @try {
        // Never let our adjustment produce a degenerate frame — that can abort the
        // presentation transition (the comment preview is taller, so a naive
        // origin.y -= pitch could go off the top). Bail on anything non-finite.
        if (!isfinite(frame.origin.y) || !isfinite(frame.size.height) ||
            frame.size.height <= 1.0) {
            return frame;
        }
        id presented = [(UIPresentationController *)self presentedViewController];
        Class shareVCClass = objc_getClass("_TtC6Apollo26ShareAsImageViewController");
        if (shareVCClass && [presented isMemberOfClass:shareVCClass]) {
            double pitch = ApolloShareLinkIvarDouble(presented, "rowHeight");
            if (pitch <= 1.0 || !isfinite(pitch)) pitch = 50.0;
            // Grow upward but clamp the top to the container (never negative), and
            // keep the bottom edge anchored. If there isn't a full pitch of room
            // above, grow by only what's available.
            CGFloat nativeBottom = frame.origin.y + frame.size.height;
            CGFloat newTop = MAX(0.0, frame.origin.y - pitch);
            frame.origin.y = newTop;
            frame.size.height = nativeBottom - newTop;
        }
    } @catch (__unused NSException *e) {}
    return frame;
}

%end

%ctor {
    @autoreleasepool {
        if (objc_getClass("_TtC6Apollo26ShareAsImageViewController")) {
            %init();
            ApolloLog(@"[ShareLink] module loaded");
        } else {
            ApolloLog(@"[ShareLink] ShareAsImageViewController not found — skipping");
        }
    }
}
