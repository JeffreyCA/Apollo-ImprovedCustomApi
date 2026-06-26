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
//      (the loop-free way to grow it), so the Share button is never clipped.
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
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloCommon.h"

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
    // DIAGNOSTIC: confirm the share-as-image VC actually loads (post vs comment).
    BOOL isComment = ApolloShareLinkIvarObject(self, "comment") != nil;
    ApolloLog(@"[ShareLink] viewDidLoad comment=%d", (int)isComment);
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
    ApolloLog(@"[ShareLink] share tapped includeLink=%d", (int)sActiveShareIncludeLink);
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
        if ([item isKindOfClass:[ApolloShareLinkItemSource class]]) return YES;
        if (svLinkClass && [item isKindOfClass:svLinkClass]) return YES;
    }
    return NO;
}

%hook UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(NSArray *)applicationActivities {
    // This hook fires for EVERY UIActivityViewController in the app; the
    // sActiveShareVC handshake (set only by the share-as-image Share tap) scopes it,
    // and the link-source check keeps us from double-appending onto the video path's
    // own sheet.
    id vc = sActiveShareVC;
    if (vc && sActiveShareIncludeLink && !ApolloShareLinkAlreadyHasLinkSource(activityItems)) {
        NSURL *url = ApolloShareLinkURLForVC(vc);
        if ([url isKindOfClass:[NSURL class]]) {
            sActiveShareVC = nil;          // consume the handshake so we only append once
            sActiveShareIncludeLink = NO;  // reset too, so the flag is never left latched
            ApolloShareLinkItemSource *source = [[ApolloShareLinkItemSource alloc] init];
            source.url = url;
            NSMutableArray *items = [activityItems isKindOfClass:[NSArray class]]
                ? [activityItems mutableCopy] : [NSMutableArray array];
            [items addObject:source];
            ApolloLog(@"[ShareLink] appended link to share sheet: %@", url.absoluteString);
            return %orig(items, applicationActivities);
        }
        ApolloLog(@"[ShareLink] share active but no link resolved — leaving items unchanged");
    }
    return %orig;
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
        if (shareVCClass && [presented isKindOfClass:shareVCClass]) {
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
