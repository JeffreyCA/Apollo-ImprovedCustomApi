#import "ApolloMarkdownToolbarGif.h"
#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloGiphyClient.h"
#import "ApolloState.h"
#import "ApolloSubredditInfoCache.h"
#import "CustomAPIViewController.h"
#import "GiphyPickerViewController.h"
#import "UserDefaultConstants.h"

#import <objc/runtime.h>
#import <objc/message.h>

NSRegularExpression *ApolloNativeGiphyMarkdownTokenRegex(void) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"!\\[gif\\]\\(giphy\\|([A-Za-z0-9_\\-]+)\\)"
                                                          options:NSRegularExpressionCaseInsensitive
                                                            error:nil];
    });
    return regex;
}

static char kApolloMarkdownGifToolbarLastAttemptKey;
static char kApolloMarkdownGifLoggedDiscoveryKey;
static char kApolloMarkdownGifLoggedFailureKey;
// Weak ref so it auto-nils when the compose controller deallocates. Previously
// stored as an OBJC_ASSOCIATION_ASSIGN associated object on UIApplication, which
// left a dangling raw pointer after the controller was gone; deferred injection
// blocks (scheduled up to ~2.5s out) then ARC-retained the dangling id and
// crashed in objc_retain. (Apollo-Reborn PR #337)
static __weak UIViewController *sApolloMarkdownGifActiveComposeController = nil;
static char kApolloMarkdownGifToolbarRootKey;
static char kApolloMarkdownGifSessionInjectedKey;
static char kApolloMarkdownGifLayoutLoggedKey;
static char kApolloMarkdownGifPendingInjectionBlocksKey;
static NSString *const kApolloMarkdownGifButtonIdentifier = @"apollo-tweak-gif-button";
static NSString *const kApolloMarkdownGifImageGateIdentifier = @"apollo-tweak-image-gate";
static const NSInteger kApolloMarkdownGifChipTag = 0x47494600;

// Associated-object keys for the comment-media gating feature.
static char kApolloMarkdownGifGifGatedSubredditKey;  // on the GIF button: NSString subreddit when GIFs are disallowed
static char kApolloMarkdownGifImageGateOverlayKey;   // on the image control: the transparent tap-catcher overlay
static char kApolloMarkdownGifGateSubredditKey;      // on the overlay button: NSString subreddit it gates

typedef NS_ENUM(NSInteger, ApolloMarkdownGifInsertResult) {
    ApolloMarkdownGifInsertResultFailed = 0,
    ApolloMarkdownGifInsertResultAlreadyPresent = 1,
    ApolloMarkdownGifInsertResultFreshInsert = 2,
};

typedef NS_ENUM(NSInteger, ApolloMarkdownGifInjectOutcome) {
    ApolloMarkdownGifInjectOutcomeNone = 0,
    ApolloMarkdownGifInjectOutcomeAlreadyPresent = 1,
    ApolloMarkdownGifInjectOutcomeFresh = 2,
};

@interface ApolloMarkdownGifTapTarget : NSObject
@property (nonatomic, weak) UINavigationController *presentedAPIKeysNav;
- (void)imageGateTapped:(id)sender;
@end

static ApolloMarkdownGifTapTarget *sApolloMarkdownGifTapTarget;
static BOOL sApolloMarkdownGifInstalled = NO;
static BOOL sApolloMarkdownGifInjecting = NO;
static BOOL sApolloMarkdownGifKeyboardVisible = NO;
// Last known keyboard end frame in screen coordinates, captured from the keyboard
// notifications so the gating toast can position itself just above the keyboard.
static CGRect sApolloMarkdownGifKeyboardFrameEnd = (CGRect){ {0, 0}, {0, 0} };

static void ApolloMarkdownGifCancelPendingInjections(UIViewController *composeController);
static void ApolloMarkdownGifPresentMissingAPIKeyAlert(UIViewController *composeController);
static UIViewController *ApolloMarkdownGifActiveComposeController(void);
static ApolloMarkdownGifInsertResult ApolloMarkdownGifTryInjectInRoot(UIView *root, UIViewController *composeController);
static ApolloMarkdownGifInjectOutcome ApolloMarkdownGifTryInjectForComposeController(UIViewController *composeController);
static NSString *ApolloMarkdownGifResolveCommentSubreddit(UIViewController *composeController);
static void ApolloMarkdownGifApplyMediaGating(UIViewController *composeController);
static void ApolloMarkdownGifShowGatingToast(UIViewController *host, NSString *message);

static BOOL ApolloMarkdownGifClassLooksLikeCompose(UIViewController *controller) {
    if (!controller) return NO;
    NSString *className = NSStringFromClass(controller.class);
    // Only Apollo's own Swift composers (mangled to _TtC6Apollo…). Apple's
    // MFMessageComposeViewController / MFMailComposeViewController also end in
    // "ComposeViewController"; running the GIF-injection machinery against those
    // out-of-process controllers crashes when sharing a post to Messages/Mail
    // (issue #366).
    if (![className hasPrefix:@"_TtC6Apollo"]) return NO;
    return [className hasSuffix:@"ComposeViewController"] ||
           [className hasSuffix:@"ComposePostViewController"] ||
           [className hasSuffix:@"WatcherComposerViewController"];
}

static BOOL ApolloMarkdownGifTextLooksLikeEditor(UITextView *textView) {
    if (!textView) return NO;
    NSString *className = NSStringFromClass(textView.class);
    if ([className containsString:@"PlaceHolderTextView"] ||
        [className containsString:@"InputTextView"] ||
        [className containsString:@"PasteableTextView"]) {
        return YES;
    }
    return textView.isEditable;
}

static UITextView *ApolloMarkdownGifFindBodyTextView(UIViewController *controller) {
    if (!controller || !controller.view) return nil;
    UITextView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:controller.view];
    while (stack.count > 0) {
        UIView *node = stack.lastObject;
        [stack removeLastObject];
        if ([node isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)node;
            if (!ApolloMarkdownGifTextLooksLikeEditor(textView)) continue;
            CGFloat area = textView.bounds.size.width * textView.bounds.size.height;
            if (area > bestArea) {
                bestArea = area;
                best = textView;
            }
        }
        for (UIView *subview in node.subviews) [stack addObject:subview];
    }
    return best;
}

static NSString *ApolloMarkdownGifAccessibilityLabelForView(UIView *view) {
    if (!view) return @"";
    if (view.accessibilityLabel.length > 0) return view.accessibilityLabel;
    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        if ([control isKindOfClass:[UIButton class]]) {
            NSString *title = [(UIButton *)control titleForState:UIControlStateNormal];
            if (title.length > 0) return title;
        }
    }
    return @"";
}

static void ApolloMarkdownGifCollectToolbarViewsInView(UIView *root, NSMutableArray<UIView *> *out, NSUInteger *budget) {
    if (!root || !out || !budget || *budget == 0) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0 && *budget > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        (*budget)--;
        if (view.hidden || view.alpha < 0.01) continue;
        if ([view.accessibilityIdentifier isEqualToString:kApolloMarkdownGifButtonIdentifier]) continue;

        NSString *label = ApolloMarkdownGifAccessibilityLabelForView(view);
        if (label.length > 0 || [view isKindOfClass:[UIControl class]]) {
            [out addObject:view];
        }
        for (UIView *subview in view.subviews) {
            [stack addObject:subview];
        }
    }
}

static BOOL ApolloMarkdownGifLabelIsImageSlot(NSString *label) {
    if (label.length == 0) return NO;
    if ([label isEqualToString:@"Add photos"]) return YES;
    NSString *lower = label.lowercaseString;
    return [lower containsString:@"add photo"] || [lower isEqualToString:@"photo"];
}

static BOOL ApolloMarkdownGifLabelIsOtherMarkdown(NSString *label) {
    if ([label isEqualToString:@"Bold text"] ||
        [label isEqualToString:@"Insert link"] ||
        [label isEqualToString:@"More actions"] ||
        [label isEqualToString:@"Italicize text"]) {
        return YES;
    }
    return [label isEqualToString:@"B"] || [label isEqualToString:@"I"];
}

static BOOL ApolloMarkdownGifToolbarContainsMarkdownLabels(NSArray<UIView *> *views) {
    BOOL hasImage = NO;
    BOOL hasOtherMarkdown = NO;
    for (UIView *view in views) {
        NSString *label = ApolloMarkdownGifAccessibilityLabelForView(view);
        if (ApolloMarkdownGifLabelIsImageSlot(label)) hasImage = YES;
        if (ApolloMarkdownGifLabelIsOtherMarkdown(label)) hasOtherMarkdown = YES;
    }
    return hasImage && hasOtherMarkdown;
}

static UIControl *ApolloMarkdownGifResolveControl(UIView *view) {
    if ([view isKindOfClass:[UIControl class]]) return (UIControl *)view;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIControl class]]) return (UIControl *)subview;
    }
    if ([view.superview isKindOfClass:[UIControl class]]) return (UIControl *)view.superview;
    return nil;
}

static UIControl *ApolloMarkdownGifFindImageControl(NSArray<UIView *> *views) {
    UIControl *exact = nil;
    UIControl *fuzzy = nil;
    for (UIView *view in views) {
        NSString *label = ApolloMarkdownGifAccessibilityLabelForView(view);
        UIControl *control = ApolloMarkdownGifResolveControl(view);
        if (!control) continue;
        if ([label isEqualToString:@"Add photos"]) exact = control;
        else if (!fuzzy && ApolloMarkdownGifLabelIsImageSlot(label)) fuzzy = control;
    }
    return exact ?: fuzzy;
}

static BOOL ApolloMarkdownGifStackContainsView(UIStackView *stack, UIView *view) {
    if (!stack || !view) return NO;
    for (UIView *arranged in stack.arrangedSubviews) {
        if (arranged == view || [view isDescendantOfView:arranged]) return YES;
    }
    return NO;
}

static UIStackView *ApolloMarkdownGifFindBestToolbarStack(NSArray<UIView *> *toolbarViews) {
    NSMutableDictionary<NSValue *, NSNumber *> *scores = [NSMutableDictionary dictionary];
    for (UIView *view in toolbarViews) {
        UIControl *control = ApolloMarkdownGifResolveControl(view);
        UIView *walk = control ?: view;
        while (walk) {
            if ([walk isKindOfClass:[UIStackView class]]) {
                UIStackView *stack = (UIStackView *)walk;
                if (ApolloMarkdownGifStackContainsView(stack, view)) {
                    NSValue *key = [NSValue valueWithNonretainedObject:stack];
                    scores[key] = @([scores[key] integerValue] + 1);
                }
            }
            walk = walk.superview;
        }
    }

    UIStackView *best = nil;
    NSInteger bestScore = 0;
    for (NSValue *key in scores) {
        NSInteger score = [scores[key] integerValue];
        if (score >= 3 && score > bestScore) {
            bestScore = score;
            best = (UIStackView *)[key nonretainedObjectValue];
        }
    }
    return best;
}

static UIView *ApolloMarkdownGifFindToolbarRowContainer(UIView *imageView, NSArray<UIView *> *toolbarViews) {
    if (!imageView) return nil;

    CGFloat referenceWidth = 0.0;
    for (UIView *walker = imageView; walker; walker = walker.superview) {
        if (walker.window) {
            referenceWidth = walker.window.bounds.size.width;
            break;
        }
    }
    if (referenceWidth <= 0.0) {
        referenceWidth = UIScreen.mainScreen.bounds.size.width;
    }

    UIView *best = nil;
    CGFloat bestWidth = CGFLOAT_MAX;

    for (UIView *ancestor = imageView.superview; ancestor; ancestor = ancestor.superview) {
        NSUInteger contained = 0;
        for (UIView *view in toolbarViews) {
            UIControl *control = ApolloMarkdownGifResolveControl(view);
            UIView *node = control ?: view;
            if (node == ancestor || [node isDescendantOfView:ancestor]) contained++;
        }
        if (contained < 2) continue;

        CGFloat width = ancestor.bounds.size.width;
        CGFloat height = ancestor.bounds.size.height;
        if (height > 64.0) continue;
        if (referenceWidth > 0.0 && fabs(width - referenceWidth) > 60.0) continue;

        if (width < bestWidth) {
            bestWidth = width;
            best = ancestor;
        }
    }
    return best ?: imageView.superview;
}

static UIView *ApolloMarkdownGifSlotViewInContainer(UIView *control, UIView *container) {
    if (!control || !container) return control;
    UIView *node = control;
    while (node.superview && node.superview != container) {
        node = node.superview;
    }
    return node.superview == container ? node : control;
}

static BOOL ApolloMarkdownGifFrameLooksLikeSlot(CGRect frameInContainer) {
    CGFloat maxDim = MAX(frameInContainer.size.width, frameInContainer.size.height);
    CGFloat minDim = MIN(frameInContainer.size.width, frameInContainer.size.height);
    return maxDim >= 20.0 && maxDim <= 56.0 && minDim >= 16.0;
}

static UIView *ApolloMarkdownGifResolveToolbarSlot(UIView *control, UIView *container) {
    if (!control || !container) return control;

    UIView *best = nil;
    for (UIView *node = control; node && node != container; node = node.superview) {
        CGRect frame = [container convertRect:node.bounds fromView:node];
        if (ApolloMarkdownGifFrameLooksLikeSlot(frame)) {
            best = node;
        }
    }
    if (best) return best;

    UIView *direct = ApolloMarkdownGifSlotViewInContainer(control, container);
    CGRect directFrame = [container convertRect:direct.bounds fromView:direct];
    if (ApolloMarkdownGifFrameLooksLikeSlot(directFrame)) return direct;

    return control;
}

static CGFloat ApolloMarkdownGifSlotDimension(UIControl *imageControl) {
    if (!imageControl) return 34.0;
    CGFloat w = imageControl.bounds.size.width;
    CGFloat h = imageControl.bounds.size.height;
    if (w > 8.0 && h > 8.0) return MAX(w, h);

    UIView *wrapper = imageControl.superview;
    if (wrapper && wrapper != imageControl) {
        w = wrapper.bounds.size.width;
        h = wrapper.bounds.size.height;
        if (w > 8.0 && h > 8.0) return MAX(w, h);
    }
    return 34.0;
}

static UIView *ApolloMarkdownGifArrangedSlotForView(UIStackView *stack, UIView *imageView) {
    if (!stack || !imageView) return imageView;
    for (UIView *candidate in stack.arrangedSubviews) {
        if (candidate == imageView || [imageView isDescendantOfView:candidate]) return candidate;
    }
    return imageView;
}

static BOOL ApolloMarkdownGifComposeSessionHasGif(UIViewController *composeController) {
    return [objc_getAssociatedObject(composeController, &kApolloMarkdownGifSessionInjectedKey) boolValue];
}

static void ApolloMarkdownGifMarkComposeSessionInjected(UIViewController *composeController) {
    if (!composeController) return;
    objc_setAssociatedObject(composeController, &kApolloMarkdownGifSessionInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloMarkdownGifContainerAlreadyHasButton(UIView *container) {
    if (!container) return NO;
    for (UIView *view in container.subviews) {
        if ([view.accessibilityIdentifier isEqualToString:kApolloMarkdownGifButtonIdentifier]) return YES;
    }
    if ([container isKindOfClass:[UIStackView class]]) {
        for (UIView *view in ((UIStackView *)container).arrangedSubviews) {
            if ([view.accessibilityIdentifier isEqualToString:kApolloMarkdownGifButtonIdentifier]) return YES;
        }
    }
    return NO;
}

static void ApolloMarkdownGifLogFailureOnce(UIViewController *composeController, NSString *reason) {
    if (!composeController || reason.length == 0) return;
    NSString *key = [NSString stringWithFormat:@"fail:%@", reason];
    NSMutableSet *logged = objc_getAssociatedObject(composeController, &kApolloMarkdownGifLoggedFailureKey);
    if (!logged) logged = [NSMutableSet set];
    if ([logged containsObject:key]) return;
    [logged addObject:key];
    objc_setAssociatedObject(composeController, &kApolloMarkdownGifLoggedFailureKey, logged, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[MarkdownGif] injection failed: %@", reason);
}

static void ApolloMarkdownGifLogDiscoveryOnce(UIViewController *composeController, NSString *message) {
    if (!composeController || message.length == 0) return;
    NSNumber *logged = objc_getAssociatedObject(composeController, &kApolloMarkdownGifLoggedDiscoveryKey);
    if (logged.boolValue) return;
    objc_setAssociatedObject(composeController, &kApolloMarkdownGifLoggedDiscoveryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[MarkdownGif] %@", message);
}

static void ApolloMarkdownGifNotifyTextViewChanged(UITextView *textView) {
    if (!textView) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:textView];
    id<UITextViewDelegate> delegate = textView.delegate;
    if ([delegate respondsToSelector:@selector(textViewDidChange:)]) {
        [delegate textViewDidChange:textView];
    }
}

static NSString *ApolloMarkdownGifInsertStringForURL(NSString *urlString, NSString *text, NSRange selected) {
    if (urlString.length == 0) return @"";
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return urlString;

    if (selected.location == 0 && selected.length == 0) {
        if (text.length == 0) return urlString;
        return [NSString stringWithFormat:@"%@\n\n", urlString];
    }

    NSMutableString *insert = [NSMutableString string];
    if (selected.location > 0) {
        unichar before = [text characterAtIndex:selected.location - 1];
        if (before != '\n') {
            [insert appendString:@"\n\n"];
        } else if (selected.location >= 2 && [text characterAtIndex:selected.location - 2] != '\n') {
            [insert appendString:@"\n"];
        }
    }
    [insert appendString:urlString];
    NSUInteger after = NSMaxRange(selected);
    if (after < text.length) {
        unichar next = [text characterAtIndex:after];
        if (next != '\n') {
            [insert appendString:@"\n\n"];
        }
    }
    return insert;
}

// Inserts a raw markdown token at the caret with whitespace padding so the
// token sits on its own line. Used for Reddit's native Giphy embed
// `![gif](giphy|<id>)` which the server resolves into media_metadata.
static void ApolloMarkdownGifInsertRawTokenInCompose(UIViewController *composeController, NSString *token) {
    if (!composeController || token.length == 0) return;
    UITextView *textView = ApolloMarkdownGifFindBodyTextView(composeController);
    if (!textView) {
        ApolloLog(@"[MarkdownGif] giphy native insert failed: no text view");
        return;
    }

    NSString *text = textView.text ?: @"";
    NSRange selected = textView.selectedRange;
    if (selected.location > text.length) {
        selected.location = text.length;
    }

    NSString *insert = ApolloMarkdownGifInsertStringForURL(token, text, selected);
    textView.text = [text stringByReplacingCharactersInRange:selected withString:insert];
    textView.selectedRange = NSMakeRange(selected.location + insert.length, 0);
    ApolloMarkdownGifNotifyTextViewChanged(textView);
    ApolloLog(@"[MarkdownGif] inserted native giphy token=%@", token);
}

static void ApolloMarkdownGifPresentUploadError(UIViewController *composeController, NSString *message) {
    if (!composeController || message.length == 0) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Upload GIF"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [composeController presentViewController:alert animated:YES completion:nil];
}

static void ApolloMarkdownGifUploadSelectedGIF(ApolloGiphyGIF *gif, UIViewController *composeController) {
    if (!gif || !composeController) return;

    // Reddit natively understands `![gif](giphy|<GIPHY_ID>)` in comment markdown.
    // The server resolves the Giphy ID to its CDN URL and populates media_metadata
    // (e: "AnimatedImage", m: "image/gif") server-side. This is the same shape
    // Reddit's own GIF picker emits and renders correctly in Apollo, reddit.com,
    // and the official Reddit iOS app. Skip Reddit's media-upload pipeline
    // entirely for Giphy GIFs — uploading + finalizing isn't needed and the
    // resulting `![img](<assetID>)` form is invisible in the official iOS app
    // without a follow-up websocket finalize handshake we don't implement.
    NSString *gifID = gif.gifID;
    if (gifID.length == 0) {
        ApolloLog(@"[MarkdownGif] giphy insert skipped: missing gifID");
        ApolloMarkdownGifPresentUploadError(composeController, @"This GIF is missing a Giphy ID.");
        return;
    }

    NSString *token = [NSString stringWithFormat:@"![gif](giphy|%@)", gifID];
    ApolloMarkdownGifInsertRawTokenInCompose(composeController, token);
    // ApolloMarkdownGifInsertRawTokenInCompose already logs the full token; no
    // need to log the bare gifID a second time here.
}

@implementation ApolloMarkdownGifTapTarget

- (void)dismissPresentedAPIKeys {
    [self.presentedAPIKeysNav dismissViewControllerAnimated:YES completion:nil];
    self.presentedAPIKeysNav = nil;
}

- (void)gifTapped:(__unused id)sender {
    UIViewController *composeController = ApolloMarkdownGifActiveComposeController();
    if (!composeController) {
        ApolloLog(@"[MarkdownGif] giphy picker skipped: no compose controller");
        return;
    }

    // When the subreddit disallows GIFs in comments the button is faded; tapping
    // it explains why instead of opening the picker (which would only fail at
    // submit time with a server error).
    NSString *gatedSubreddit = objc_getAssociatedObject(sender, &kApolloMarkdownGifGifGatedSubredditKey);
    if ([gatedSubreddit isKindOfClass:[NSString class]] && gatedSubreddit.length > 0) {
        ApolloLog(@"[MarkdownGif] giphy picker blocked: r/%@ disallows GIFs in comments", gatedSubreddit);
        ApolloMarkdownGifShowGatingToast(composeController,
            [NSString stringWithFormat:@"r/%@ doesn't allow GIFs in comments", gatedSubreddit]);
        return;
    }

    if ([ApolloGiphyClient configuredAPIKey].length == 0) {
        ApolloLog(@"[MarkdownGif] giphy picker skipped: no API key configured");
        ApolloMarkdownGifPresentMissingAPIKeyAlert(composeController);
        return;
    }

    GiphyPickerViewController *picker = [[GiphyPickerViewController alloc] init];
    picker.themeSourceViewController = composeController;
    __weak UIViewController *weakCompose = composeController;
    picker.onSelectGIF = ^(ApolloGiphyGIF *gif) {
        UIViewController *compose = weakCompose;
        if (!compose || !gif) return;
        ApolloMarkdownGifUploadSelectedGIF(gif, compose);
    };

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent], [UISheetPresentationControllerDetent largeDetent]];
            sheet.prefersGrabberVisible = YES;
        }
    }
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [composeController presentViewController:nav animated:YES completion:nil];
}

- (void)imageGateTapped:(id)sender {
    UIViewController *composeController = ApolloMarkdownGifActiveComposeController();
    NSString *subreddit = objc_getAssociatedObject(sender, &kApolloMarkdownGifGateSubredditKey);
    NSString *message = ([subreddit isKindOfClass:[NSString class]] && subreddit.length > 0)
        ? [NSString stringWithFormat:@"r/%@ doesn't allow images in comments", subreddit]
        : @"This subreddit doesn't allow images in comments";
    ApolloLog(@"[MarkdownGif] image upload blocked: r/%@ disallows images in comments", subreddit ?: @"?");
    ApolloMarkdownGifShowGatingToast(composeController, message);
}

@end

static void ApolloMarkdownGifApplyButtonChrome(UIButton *gifButton, UIColor *tint, CGFloat slot) {
    if (!gifButton) return;

    UIColor *accent = tint ?: UIColor.systemTealColor;
    gifButton.tintColor = accent;
    gifButton.backgroundColor = UIColor.clearColor;
    gifButton.layer.borderWidth = 0.0;
    gifButton.layer.cornerRadius = 0.0;
    gifButton.clipsToBounds = NO;
    gifButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    gifButton.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    gifButton.titleLabel.font = [UIFont systemFontOfSize:(slot <= 30.0 ? 8.0 : 9.0) weight:UIFontWeightBold];
    gifButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    gifButton.titleLabel.minimumScaleFactor = 0.75;
    gifButton.accessibilityLabel = @"GIF";
    [gifButton setTitle:@"GIF" forState:UIControlStateNormal];

    UIView *chip = [gifButton viewWithTag:kApolloMarkdownGifChipTag];
    if (!chip) {
        chip = [[UIView alloc] init];
        chip.tag = kApolloMarkdownGifChipTag;
        chip.userInteractionEnabled = NO;
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        [gifButton insertSubview:chip atIndex:0];
    }

    chip.backgroundColor = UIColor.clearColor;
    chip.layer.borderColor = accent.CGColor;
    chip.layer.borderWidth = 1.0;
    chip.layer.cornerRadius = 3.0;

    CGFloat chipHeight = round(slot * 0.72);
    CGFloat chipWidth = round(slot * 0.76);

    NSMutableArray<NSLayoutConstraint *> *stale = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in gifButton.constraints) {
        if (constraint.firstItem == chip || constraint.secondItem == chip) {
            [stale addObject:constraint];
        }
    }
    [NSLayoutConstraint deactivateConstraints:stale];

    [NSLayoutConstraint activateConstraints:@[
        [chip.centerXAnchor constraintEqualToAnchor:gifButton.centerXAnchor],
        [chip.centerYAnchor constraintEqualToAnchor:gifButton.centerYAnchor],
        [chip.widthAnchor constraintEqualToConstant:chipWidth],
        [chip.heightAnchor constraintEqualToConstant:chipHeight],
    ]];
}

static UIButton *ApolloMarkdownGifMakeButton(UIControl *imageControl) {
    CGFloat slot = ApolloMarkdownGifSlotDimension(imageControl);
    UIColor *tint = ApolloThemeAccentColor() ?: imageControl.tintColor ?: UIColor.systemTealColor;
    UIButton *gifButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gifButton.translatesAutoresizingMaskIntoConstraints = NO;
    gifButton.accessibilityIdentifier = kApolloMarkdownGifButtonIdentifier;
    ApolloMarkdownGifApplyButtonChrome(gifButton, tint, slot);
    [gifButton addTarget:sApolloMarkdownGifTapTarget action:@selector(gifTapped:) forControlEvents:UIControlEventTouchUpInside];
    return gifButton;
}

static void ApolloMarkdownGifApplySlotConstraints(UIButton *gifButton, UIView *referenceView, CGFloat slot) {
    [NSLayoutConstraint activateConstraints:@[
        [gifButton.widthAnchor constraintEqualToConstant:slot],
        [gifButton.heightAnchor constraintEqualToConstant:slot],
        [gifButton.centerYAnchor constraintEqualToAnchor:referenceView.centerYAnchor],
    ]];
}

static CGFloat ApolloMarkdownGifComputeFitGap(NSUInteger slotCount, CGFloat slotWidth, CGFloat availableWidth) {
    if (slotCount <= 1 || availableWidth <= 0.0) return 4.0;

    const CGFloat minGap = 2.0;
    const CGFloat minSlot = 30.0;
    CGFloat width = slotWidth > 8.0 ? slotWidth : 34.0;
    CGFloat gap = (availableWidth - (CGFloat)slotCount * width) / (CGFloat)(slotCount - 1);

    if (gap < minGap) {
        gap = minGap;
        width = (availableWidth - (CGFloat)(slotCount - 1) * gap) / (CGFloat)slotCount;
        if (width < minSlot) {
            width = minSlot;
            gap = MAX(0.0, (availableWidth - (CGFloat)slotCount * width) / (CGFloat)(slotCount - 1));
        }
    }
    return MAX(minGap, gap);
}

static UIStackView *ApolloMarkdownGifFindStackInContainer(UIView *container, UIView *imageView) {
    if (!container || !imageView) return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:container];
    while (queue.count > 0) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([node isKindOfClass:[UIStackView class]]) {
            UIStackView *stack = (UIStackView *)node;
            if (stack.arrangedSubviews.count >= 2) {
                for (UIView *arranged in stack.arrangedSubviews) {
                    if (arranged == imageView || [imageView isDescendantOfView:arranged]) {
                        return stack;
                    }
                }
            }
        }

        for (UIView *subview in node.subviews) {
            [queue addObject:subview];
        }
    }
    return nil;
}

static CGFloat ApolloMarkdownGifMeasureSlotsSpan(UIView *container, NSArray<UIView *> *slots) {
    if (!container || slots.count == 0) return 0.0;

    CGFloat minX = CGFLOAT_MAX;
    CGFloat maxX = -CGFLOAT_MAX;
    for (UIView *slot in slots) {
        CGRect frame = [container convertRect:slot.bounds fromView:slot];
        minX = MIN(minX, CGRectGetMinX(frame));
        maxX = MAX(maxX, CGRectGetMaxX(frame));
    }
    return maxX > minX ? (maxX - minX) : 0.0;
}

static NSUInteger ApolloMarkdownGifCompressToolbarRow(UIView *container,
                                                      UIView *imageView,
                                                      UIView *gifButton,
                                                      NSArray<UIView *> *toolbarViews,
                                                      CGFloat preferredSlot,
                                                      CGFloat *outGap,
                                                      CGFloat *outSpanBefore,
                                                      CGFloat *outSpanAfter,
                                                      CGFloat *outSlotWidth,
                                                      NSUInteger *outSkipped) {
    if (outGap) *outGap = 0.0;
    if (outSpanBefore) *outSpanBefore = 0.0;
    if (outSpanAfter) *outSpanAfter = 0.0;
    if (outSlotWidth) *outSlotWidth = 0.0;
    if (outSkipped) *outSkipped = 0;
    if (!container || !gifButton || !imageView) return 0;

    __block NSUInteger skipped = 0;
    UIView *imageSlot = ApolloMarkdownGifResolveToolbarSlot(imageView, container);
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    NSMutableArray<UIView *> *validSlots = [NSMutableArray array];

    void (^tryAddSlot)(UIView *) = ^(UIView *candidate) {
        if (!candidate) return;
        NSValue *key = [NSValue valueWithNonretainedObject:candidate];
        if ([seen containsObject:key]) return;

        CGRect frame = [container convertRect:candidate.bounds fromView:candidate];
        if (!ApolloMarkdownGifFrameLooksLikeSlot(frame)) {
            skipped++;
            return;
        }

        [seen addObject:key];
        [validSlots addObject:candidate];
    };

    tryAddSlot(imageSlot);
    tryAddSlot(gifButton);
    for (UIView *view in toolbarViews) {
        UIControl *control = ApolloMarkdownGifResolveControl(view);
        if (!control) continue;
        tryAddSlot(ApolloMarkdownGifResolveToolbarSlot((UIView *)control, container));
    }

    if (outSkipped) *outSkipped = skipped;
    if (validSlots.count < 2) return 0;

    [validSlots sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGRect fa = [container convertRect:a.bounds fromView:a];
        CGRect fb = [container convertRect:b.bounds fromView:b];
        if (fa.origin.x < fb.origin.x) return NSOrderedAscending;
        if (fa.origin.x > fb.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<UIView *> *slots = [NSMutableArray arrayWithObject:imageSlot];
    if (gifButton && gifButton != imageSlot && [validSlots containsObject:gifButton]) {
        [slots addObject:gifButton];
    }
    for (UIView *slot in validSlots) {
        if (slot == imageSlot || slot == gifButton) continue;
        [slots addObject:slot];
    }

    CGFloat slotWidth = preferredSlot > 8.0 ? preferredSlot : 34.0;
    slotWidth = MIN(MAX(slotWidth, 30.0), 44.0);
    if (outSlotWidth) *outSlotWidth = slotWidth;

    CGRect imageFrame = [container convertRect:imageSlot.bounds fromView:imageSlot];
    CGFloat leftInset = imageFrame.origin.x;
    CGFloat rightInset = 4.0;
    CGFloat availableWidth = container.bounds.size.width - leftInset - rightInset;
    if (availableWidth <= 0.0) return 0;

    NSUInteger slotCount = slots.count;
    if (outSpanBefore) *outSpanBefore = ApolloMarkdownGifMeasureSlotsSpan(container, slots);

    CGFloat gap = ApolloMarkdownGifComputeFitGap(slotCount, slotWidth, availableWidth);
    if (outGap) *outGap = gap;
    if (outSpanAfter) {
        *outSpanAfter = (CGFloat)slotCount * slotWidth + (CGFloat)(slotCount - 1) * gap;
    }

    NSUInteger repositioned = 0;
    for (NSUInteger i = 0; i < slotCount; i++) {
        UIView *slot = slots[i];
        CGRect currentFrame = [container convertRect:slot.bounds fromView:slot];
        CGFloat targetX = leftInset + (CGFloat)i * (slotWidth + gap);
        CGFloat dx = targetX - currentFrame.origin.x;
        slot.transform = CGAffineTransformMakeTranslation(dx, 0.0);
        repositioned++;
    }

    return repositioned;
}

static CGFloat ApolloMarkdownGifMeasureStackContentWidth(UIStackView *stack, CGFloat slotWidth) {
    if (!stack || stack.arrangedSubviews.count == 0) return 0.0;

    CGFloat width = slotWidth > 8.0 ? slotWidth : 34.0;
    CGFloat total = 0.0;
    for (UIView *view in stack.arrangedSubviews) {
        CGFloat w = view.bounds.size.width;
        CGFloat h = view.bounds.size.height;
        if (w > 8.0 && h > 8.0) {
            total += MAX(w, h);
        } else {
            total += width;
        }
    }
    total += stack.spacing * (CGFloat)(stack.arrangedSubviews.count - 1);
    return total;
}

static void ApolloMarkdownGifApplyStackFitSpacing(UIStackView *stack, CGFloat slotWidth) {
    if (!stack || stack.arrangedSubviews.count < 9) return;

    UIView *container = stack.superview;
    while (container && container.bounds.size.width < 80.0) {
        container = container.superview;
    }
    if (!container) container = stack;

    CGRect stackFrame = [container convertRect:stack.bounds fromView:stack];
    CGFloat availableWidth = stack.bounds.size.width > 20.0 ? stack.bounds.size.width : stackFrame.size.width;
    if (availableWidth <= 0.0) availableWidth = container.bounds.size.width;
    if (availableWidth <= 0.0) return;

    CGFloat contentWidth = ApolloMarkdownGifMeasureStackContentWidth(stack, slotWidth);
    if (contentWidth <= availableWidth) return;

    CGFloat gap = ApolloMarkdownGifComputeFitGap(stack.arrangedSubviews.count, slotWidth, availableWidth);
    stack.spacing = gap;
}

static ApolloMarkdownGifInsertResult ApolloMarkdownGifInsertIntoStack(UIStackView *stack,
                                                                      UIView *imageView,
                                                                      UIButton *gifButton,
                                                                      UIControl *imageControl) {
    if (ApolloMarkdownGifContainerAlreadyHasButton(stack)) return ApolloMarkdownGifInsertResultAlreadyPresent;

    NSInteger imageIndex = NSNotFound;
    if ([stack.arrangedSubviews containsObject:imageView]) {
        imageIndex = [stack.arrangedSubviews indexOfObject:imageView];
    } else {
        for (NSInteger i = 0; i < (NSInteger)stack.arrangedSubviews.count; i++) {
            UIView *candidate = stack.arrangedSubviews[i];
            if (candidate == imageView || [candidate.subviews containsObject:imageView] || [imageView isDescendantOfView:candidate]) {
                imageIndex = i;
                break;
            }
        }
    }
    if (imageIndex == NSNotFound) return ApolloMarkdownGifInsertResultFailed;

    UIView *imageSlot = ApolloMarkdownGifArrangedSlotForView(stack, imageView);
    CGFloat slot = ApolloMarkdownGifSlotDimension(imageControl);
    if (imageSlot != imageView && imageSlot.bounds.size.width > 8.0) {
        slot = MAX(slot, MAX(imageSlot.bounds.size.width, imageSlot.bounds.size.height));
    }

    ApolloMarkdownGifApplySlotConstraints(gifButton, imageSlot, slot);
    [stack insertArrangedSubview:gifButton atIndex:imageIndex + 1];
    [stack layoutIfNeeded];
    ApolloMarkdownGifApplyStackFitSpacing(stack, slot);
    return ApolloMarkdownGifInsertResultFreshInsert;
}

static ApolloMarkdownGifInsertResult ApolloMarkdownGifInsertFallback(UIView *container,
                                                                    UIView *imageView,
                                                                    UIButton *gifButton,
                                                                    UIControl *imageControl,
                                                                    NSArray<UIView *> *toolbarViews,
                                                                    NSUInteger *outReflowed,
                                                                    CGFloat *outGap,
                                                                    CGFloat *outSpanBefore,
                                                                    CGFloat *outSpanAfter,
                                                                    CGFloat *outSlotWidth,
                                                                    NSUInteger *outSkipped) {
    if (outReflowed) *outReflowed = 0;
    if (outGap) *outGap = 0.0;
    if (outSpanBefore) *outSpanBefore = 0.0;
    if (outSpanAfter) *outSpanAfter = 0.0;
    if (outSlotWidth) *outSlotWidth = 0.0;
    if (outSkipped) *outSkipped = 0;
    if (ApolloMarkdownGifContainerAlreadyHasButton(container)) return ApolloMarkdownGifInsertResultAlreadyPresent;

    UIView *imageSlot = ApolloMarkdownGifResolveToolbarSlot(imageView, container);
    CGFloat slot = ApolloMarkdownGifSlotDimension(imageControl);
    slot = MIN(MAX(slot, 30.0), 44.0);
    if (imageSlot != imageView) {
        CGRect imageSlotFrame = [container convertRect:imageSlot.bounds fromView:imageSlot];
        if (ApolloMarkdownGifFrameLooksLikeSlot(imageSlotFrame)) {
            slot = MIN(MAX(MAX(imageSlotFrame.size.width, imageSlotFrame.size.height), 30.0), 44.0);
        }
    }

    [container addSubview:gifButton];
    gifButton.translatesAutoresizingMaskIntoConstraints = YES;
    CGRect imageFrame = [container convertRect:imageSlot.bounds fromView:imageSlot];
    gifButton.frame = CGRectMake(CGRectGetMaxX(imageFrame) + 4.0,
                                 imageFrame.origin.y,
                                 slot,
                                 slot);

    [container layoutIfNeeded];
    NSUInteger reflowed = ApolloMarkdownGifCompressToolbarRow(container,
                                                              imageView,
                                                              gifButton,
                                                              toolbarViews,
                                                              slot,
                                                              outGap,
                                                              outSpanBefore,
                                                              outSpanAfter,
                                                              outSlotWidth,
                                                              outSkipped);
    if (outReflowed) *outReflowed = reflowed;
    return ApolloMarkdownGifInsertResultFreshInsert;
}

static void ApolloMarkdownGifMarkToolbarContainer(UIView *container) {
    if (!container || [objc_getAssociatedObject(container, &kApolloMarkdownGifToolbarRootKey) boolValue]) return;
    objc_setAssociatedObject(container, &kApolloMarkdownGifToolbarRootKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloMarkdownGifLogLayoutOnce(UIViewController *composeController, NSString *message) {
    if (!composeController || message.length == 0) return;
    NSNumber *logged = objc_getAssociatedObject(composeController, &kApolloMarkdownGifLayoutLoggedKey);
    if (logged.boolValue) return;
    objc_setAssociatedObject(composeController, &kApolloMarkdownGifLayoutLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLog(@"[MarkdownGif] %@", message);
}

static ApolloMarkdownGifInsertResult ApolloMarkdownGifTryInjectInRoot(UIView *root, UIViewController *composeController) {
    if (!root) return ApolloMarkdownGifInsertResultFailed;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSUInteger budget = 1200;
    ApolloMarkdownGifCollectToolbarViewsInView(root, views, &budget);
    if (!ApolloMarkdownGifToolbarContainsMarkdownLabels(views)) return ApolloMarkdownGifInsertResultFailed;

    UIControl *imageControl = ApolloMarkdownGifFindImageControl(views);
    if (!imageControl) {
        if (composeController) ApolloMarkdownGifLogFailureOnce(composeController, @"no image button");
        return ApolloMarkdownGifInsertResultFailed;
    }

    UIView *imageView = (UIView *)imageControl;
    UIStackView *stack = ApolloMarkdownGifFindBestToolbarStack(views);
    UIButton *gifButton = ApolloMarkdownGifMakeButton(imageControl);
    ApolloMarkdownGifInsertResult result = ApolloMarkdownGifInsertResultFailed;
    NSString *layoutPath = nil;
    NSString *layoutMode = nil;
    NSUInteger reflowed = 0;
    CGFloat compressedGap = 0.0;
    CGFloat spanBefore = 0.0;
    CGFloat spanAfter = 0.0;
    CGFloat containerWidth = 0.0;
    CGFloat slotWidthUsed = 0.0;
    NSUInteger skippedSlots = 0;
    UIView *rowContainer = ApolloMarkdownGifFindToolbarRowContainer(imageView, views);

    if (stack) {
        result = ApolloMarkdownGifInsertIntoStack(stack, imageView, gifButton, imageControl);
        if (result == ApolloMarkdownGifInsertResultFreshInsert) {
            layoutPath = @"stack";
            layoutMode = @"stack-spacing";
            reflowed = stack.arrangedSubviews.count;
            compressedGap = stack.spacing;
            containerWidth = stack.bounds.size.width;
        }
    }

    if (result == ApolloMarkdownGifInsertResultFailed && rowContainer) {
        UIStackView *innerStack = ApolloMarkdownGifFindStackInContainer(rowContainer, imageView);
        if (innerStack) {
            stack = innerStack;
            result = ApolloMarkdownGifInsertIntoStack(innerStack, imageView, gifButton, imageControl);
            if (result == ApolloMarkdownGifInsertResultFreshInsert) {
                layoutPath = @"stack-inner";
                layoutMode = @"stack-spacing";
                reflowed = innerStack.arrangedSubviews.count;
                compressedGap = innerStack.spacing;
                containerWidth = innerStack.bounds.size.width;
            }
        }
    }

    if (result == ApolloMarkdownGifInsertResultFailed) {
        if (!rowContainer) {
            if (composeController) ApolloMarkdownGifLogFailureOnce(composeController, @"no container");
            return ApolloMarkdownGifInsertResultFailed;
        }
        containerWidth = rowContainer.bounds.size.width;
        result = ApolloMarkdownGifInsertFallback(rowContainer,
                                                 imageView,
                                                 gifButton,
                                                 imageControl,
                                                 views,
                                                 &reflowed,
                                                 &compressedGap,
                                                 &spanBefore,
                                                 &spanAfter,
                                                 &slotWidthUsed,
                                                 &skippedSlots);
        if (result == ApolloMarkdownGifInsertResultFreshInsert) {
            layoutPath = @"fallback";
            layoutMode = @"transform";
        }
    }

    if (result == ApolloMarkdownGifInsertResultFreshInsert) {
        UIView *toolbarContainer = stack ?: rowContainer;
        ApolloMarkdownGifMarkToolbarContainer(toolbarContainer);
        if (composeController) {
            ApolloMarkdownGifMarkComposeSessionInjected(composeController);
            ApolloMarkdownGifCancelPendingInjections(composeController);
            ApolloMarkdownGifLogLayoutOnce(composeController,
                [NSString stringWithFormat:@"layout path=%@ container=%@ slots=%lu gap=%.1f reflowed=%lu mode=%@ containerW=%.0f slotW=%.0f spanBefore=%.0f spanAfter=%.0f skipped=%lu",
                 layoutPath ?: @"unknown",
                 NSStringFromClass(toolbarContainer.class),
                 (unsigned long)reflowed,
                 compressedGap,
                 (unsigned long)reflowed,
                 layoutMode ?: @"unknown",
                 containerWidth,
                 slotWidthUsed,
                 spanBefore,
                 spanAfter,
                 (unsigned long)skippedSlots]);
        }
        ApolloLog(@"[MarkdownGif] inserted Gif button after Add photos");
    } else if (result == ApolloMarkdownGifInsertResultAlreadyPresent) {
        if (composeController) {
            ApolloMarkdownGifMarkComposeSessionInjected(composeController);
            ApolloMarkdownGifCancelPendingInjections(composeController);
        }
    } else if (composeController) {
        ApolloMarkdownGifLogFailureOnce(composeController, @"insert failed");
    }

    if (composeController &&
        (result == ApolloMarkdownGifInsertResultFreshInsert ||
         result == ApolloMarkdownGifInsertResultAlreadyPresent)) {
        ApolloMarkdownGifApplyMediaGating(composeController);
    }

    return result;
}

static void ApolloMarkdownGifEnumerateWindows(void (^block)(UIWindow *window)) {
    if (!block) return;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha < 0.01) continue;
                block(window);
            }
        }
    }
    for (UIWindow *window in ApolloAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        block(window);
    }
}

static BOOL ApolloMarkdownGifWindowLooksLikeKeyboardHost(UIWindow *window) {
    if (!window) return NO;
    NSString *className = NSStringFromClass(window.class);
    return [className containsString:@"RemoteKeyboard"] ||
           [className containsString:@"TextEffects"] ||
           [className containsString:@"Keyboard"];
}

static void ApolloMarkdownGifCollectScanRoots(NSMutableArray<UIView *> *roots, UIViewController *composeController) {
    if (!roots) return;

    UIWindow *composeWindow = composeController.view.window;

    if (composeController) {
        UITextView *textView = ApolloMarkdownGifFindBodyTextView(composeController);
        if (textView.inputAccessoryView) [roots addObject:textView.inputAccessoryView];
        if (composeController.view) [roots addObject:composeController.view];
    }

    // Markdown toolbar often lives in a separate keyboard window; walk other visible windows last.
    ApolloMarkdownGifEnumerateWindows(^(UIWindow *window) {
        if (window == composeWindow) return;
        if (!sApolloMarkdownGifKeyboardVisible && ApolloMarkdownGifWindowLooksLikeKeyboardHost(window)) return;
        [roots addObject:window];
    });
}

#pragma mark - Comment media permission gating

// Read an ObjC-object ivar by name from a (possibly Swift) instance. Apollo's
// Swift compose controllers store the post/comment being acted on as Optional
// ivars wrapping ObjC RDKLink/RDKComment pointers, so object_getIvar returns the
// underlying object (or nil) directly.
static id ApolloMarkdownGifIvarObject(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    return object_getIvar(obj, ivar);
}

static NSString *ApolloMarkdownGifSubredditFromModel(id model) {
    if (!model || ![model respondsToSelector:@selector(subreddit)]) return nil;
    NSString *(*msgSend)(id, SEL) = (NSString *(*)(id, SEL))objc_msgSend;
    NSString *sub = msgSend(model, @selector(subreddit));
    if (![sub isKindOfClass:[NSString class]]) return nil;
    sub = [sub stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return sub.length > 0 ? sub : nil;
}

// Returns the subreddit name only when the composer is genuinely composing a
// comment/reply (replying to a link or comment, or editing a comment). Returns
// nil for post composers and DMs — `allowed_media_in_comments` only governs
// comments, so the feature stays inert elsewhere.
static NSString *ApolloMarkdownGifResolveCommentSubreddit(UIViewController *composeController) {
    if (!composeController) return nil;
    static const char *kCommentModelIvars[] = {
        "correspondingLink",       // top-level comment on a link
        "commentBeingRepliedTo",   // reply to a comment
        "commentBeingEdited",      // editing an existing comment
    };
    for (size_t i = 0; i < sizeof(kCommentModelIvars) / sizeof(kCommentModelIvars[0]); i++) {
        id model = ApolloMarkdownGifIvarObject(composeController, kCommentModelIvars[i]);
        NSString *sub = ApolloMarkdownGifSubredditFromModel(model);
        if (sub.length > 0) return sub;
    }
    return nil;
}

static UIButton *ApolloMarkdownGifFindInjectedButtonInView(UIView *root, NSUInteger *budget) {
    if (!root || !budget || *budget == 0) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count > 0 && *budget > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        (*budget)--;
        if ([view isKindOfClass:[UIButton class]] &&
            [view.accessibilityIdentifier isEqualToString:kApolloMarkdownGifButtonIdentifier]) {
            return (UIButton *)view;
        }
        for (UIView *subview in view.subviews) [stack addObject:subview];
    }
    return nil;
}

static void ApolloMarkdownGifShowGatingToastImpl(UIViewController *host, NSString *message) {
    UIWindow *window = host.view.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (window) break;
        }
    }
    if (!window) return;

    UIView *bubble = [[UIView alloc] init];
    bubble.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.85];
    bubble.layer.cornerRadius = 12.0;
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.userInteractionEnabled = NO;
    bubble.alpha = 0.0;
    [window addSubview:bubble];

    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [bubble addSubview:label];

    NSMutableArray<NSLayoutConstraint *> *constraints = [@[
        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:10.0],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-10.0],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:16.0],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-16.0],
        [bubble.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:24.0],
        [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-24.0],
    ] mutableCopy];

    // Position the toast just above the keyboard. The compose UI is a sheet and
    // the markdown toolbar/keyboard live in a separate input-accessory window, so
    // window.keyboardLayoutGuide does not track them reliably here. Instead use
    // the captured keyboard end frame, converted into this window's coordinate
    // space, and pin the bubble above the keyboard top. The keyboard frame does
    // NOT include the markdown toolbar (input accessory) that sits on top of the
    // keyboard, so clear that toolbar's height plus padding to avoid covering it.
    // When the keyboard is hidden, fall back to the bottom safe area.
    const CGFloat kApolloMarkdownGifToastToolbarClearance = 64.0;
    CGFloat bubbleBottomInWindow = -1.0;
    if (sApolloMarkdownGifKeyboardVisible && !CGRectIsEmpty(sApolloMarkdownGifKeyboardFrameEnd)) {
        CGRect kbInWindow = [window convertRect:sApolloMarkdownGifKeyboardFrameEnd fromWindow:nil];
        CGFloat windowHeight = CGRectGetHeight(window.bounds);
        // A hidden keyboard reports a frame at or below the bottom of the window;
        // only treat it as on-screen when its top sits above the window bottom.
        if (CGRectGetMinY(kbInWindow) < windowHeight - 1.0) {
            bubbleBottomInWindow = CGRectGetMinY(kbInWindow) - kApolloMarkdownGifToastToolbarClearance;
        }
    }
    if (bubbleBottomInWindow > 0.0) {
        [constraints addObject:
            [bubble.bottomAnchor constraintEqualToAnchor:window.topAnchor constant:bubbleBottomInWindow]];
    } else {
        [constraints addObject:
            [bubble.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-12.0]];
    }

    [NSLayoutConstraint activateConstraints:constraints];

    [UIView animateWithDuration:0.25 animations:^{
        bubble.alpha = 1.0;
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.3 delay:2.0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            bubble.alpha = 0.0;
        } completion:^(__unused BOOL done) {
            [bubble removeFromSuperview];
        }];
    }];
}

static void ApolloMarkdownGifShowGatingToast(UIViewController *host, NSString *message) {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloMarkdownGifShowGatingToastImpl(host, message);
    });
}

static void ApolloMarkdownGifApplyGatingStates(UIControl *imageControl,
                                               UIButton *gifButton,
                                               NSString *subreddit,
                                               BOOL imageAllowed,
                                               BOOL gifAllowed) {
    if (gifButton) {
        if (gifAllowed) {
            gifButton.alpha = 1.0;
            objc_setAssociatedObject(gifButton, &kApolloMarkdownGifGifGatedSubredditKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            gifButton.alpha = 0.4;
            objc_setAssociatedObject(gifButton, &kApolloMarkdownGifGifGatedSubredditKey, subreddit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    if (imageControl) {
        UIButton *overlay = objc_getAssociatedObject(imageControl, &kApolloMarkdownGifImageGateOverlayKey);
        if (imageAllowed) {
            imageControl.alpha = 1.0;
            imageControl.userInteractionEnabled = YES;
            if (overlay) {
                [overlay removeFromSuperview];
                objc_setAssociatedObject(imageControl, &kApolloMarkdownGifImageGateOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else {
            imageControl.alpha = 0.4;
            // Keep the image control interaction-enabled; a transparent overlay
            // sibling pinned over it intercepts taps so Apollo's photo picker
            // never opens, while letting us surface the explanatory toast.
            UIView *parent = imageControl.superview;
            if (!overlay || overlay.superview != parent) {
                if (overlay) [overlay removeFromSuperview];
                overlay = [UIButton buttonWithType:UIButtonTypeCustom];
                overlay.accessibilityIdentifier = kApolloMarkdownGifImageGateIdentifier;
                overlay.backgroundColor = UIColor.clearColor;
                overlay.translatesAutoresizingMaskIntoConstraints = NO;
                [overlay addTarget:sApolloMarkdownGifTapTarget action:@selector(imageGateTapped:) forControlEvents:UIControlEventTouchUpInside];
                if (parent) {
                    [parent addSubview:overlay];
                    [parent bringSubviewToFront:overlay];
                    [NSLayoutConstraint activateConstraints:@[
                        [overlay.centerXAnchor constraintEqualToAnchor:imageControl.centerXAnchor],
                        [overlay.centerYAnchor constraintEqualToAnchor:imageControl.centerYAnchor],
                        [overlay.widthAnchor constraintEqualToAnchor:imageControl.widthAnchor],
                        [overlay.heightAnchor constraintEqualToAnchor:imageControl.heightAnchor],
                    ]];
                    objc_setAssociatedObject(imageControl, &kApolloMarkdownGifImageGateOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            } else {
                [parent bringSubviewToFront:overlay];
            }
            objc_setAssociatedObject(overlay, &kApolloMarkdownGifGateSubredditKey, subreddit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void ApolloMarkdownGifApplyMediaGating(UIViewController *composeController) {
    if (!composeController) return;
    NSString *subreddit = ApolloMarkdownGifResolveCommentSubreddit(composeController);
    if (subreddit.length == 0) return; // not a comment composer → feature inert

    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    ApolloMarkdownGifCollectScanRoots(roots, composeController);

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger budget = 2400;
    UIButton *gifButton = nil;
    for (UIView *root in roots) {
        NSValue *key = [NSValue valueWithNonretainedObject:root];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        ApolloMarkdownGifCollectToolbarViewsInView(root, views, &budget);
        if (!gifButton) {
            NSUInteger gifBudget = 1200;
            gifButton = ApolloMarkdownGifFindInjectedButtonInView(root, &gifBudget);
        }
    }
    UIControl *imageControl = ApolloMarkdownGifFindImageControl(views);
    if (!imageControl && !gifButton) return; // toolbar not built yet; retried later

    ApolloSubredditInfoCache *cache = [ApolloSubredditInfoCache sharedCache];
    ApolloSubredditInfo *cached = [cache cachedInfoForSubreddit:subreddit];
    // With a Comment Link Host set, photo uploads from the comment editor post as
    // a plain link (always allowed) instead of native Reddit media, so the image
    // button stays enabled even where the subreddit disallows image comments. The
    // GIF (Giphy) button still submits native gif RTJSON, so its gate stays.
    BOOL imagesPostAsLinks = (sCommentLinkHost != CommentLinkHostOff);
    if (cached && cached.commentMediaInfoAvailable) {
        ApolloMarkdownGifApplyGatingStates(imageControl, gifButton, subreddit,
                                           cached.allowsImageComments || imagesPostAsLinks, cached.allowsGifComments);
        return;
    }

    // Unknown → fail open (buttons stay enabled) while we fetch, then re-apply.
    ApolloMarkdownGifApplyGatingStates(imageControl, gifButton, subreddit, YES, YES);
    __weak UIViewController *weakCompose = composeController;
    [cache requestCommentMediaInfoForSubreddit:subreddit completion:^(ApolloSubredditInfo *info) {
        if (!info || !info.commentMediaInfoAvailable) return; // fail open on error
        UIViewController *strong = weakCompose;
        if (!strong) return;
        NSString *currentSub = ApolloMarkdownGifResolveCommentSubreddit(strong);
        if (![currentSub.lowercaseString isEqualToString:subreddit.lowercaseString]) return;
        ApolloMarkdownGifApplyMediaGating(strong);
    }];
}

static NSString *ApolloMarkdownGifSampleLabels(NSArray<UIView *> *views, NSUInteger maxCount) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (UIView *view in views) {
        NSString *label = ApolloMarkdownGifAccessibilityLabelForView(view);
        if (label.length == 0) continue;
        [labels addObject:label];
        if (labels.count >= maxCount) break;
    }
    return labels.count > 0 ? [labels componentsJoinedByString:@", "] : @"(none)";
}

static ApolloMarkdownGifInjectOutcome ApolloMarkdownGifTryInjectForComposeController(UIViewController *composeController) {
    if (sApolloMarkdownGifInjecting) return ApolloMarkdownGifInjectOutcomeNone;
    if (composeController && ApolloMarkdownGifComposeSessionHasGif(composeController)) {
        return ApolloMarkdownGifInjectOutcomeAlreadyPresent;
    }

    sApolloMarkdownGifInjecting = YES;

    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    ApolloMarkdownGifCollectScanRoots(roots, composeController);

    NSMutableSet *seen = [NSMutableSet set];
    ApolloMarkdownGifInjectOutcome outcome = ApolloMarkdownGifInjectOutcomeNone;
    for (UIView *root in roots) {
        NSValue *key = [NSValue valueWithNonretainedObject:root];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        ApolloMarkdownGifInsertResult result = ApolloMarkdownGifTryInjectInRoot(root, composeController);
        if (result == ApolloMarkdownGifInsertResultFreshInsert) {
            outcome = ApolloMarkdownGifInjectOutcomeFresh;
            break;
        }
        if (result == ApolloMarkdownGifInsertResultAlreadyPresent) {
            outcome = ApolloMarkdownGifInjectOutcomeAlreadyPresent;
        }
    }

    if (outcome == ApolloMarkdownGifInjectOutcomeNone && composeController) {
        NSMutableArray<UIView *> *allViews = [NSMutableArray array];
        NSUInteger budget = 2400;
        for (UIView *root in roots) {
            ApolloMarkdownGifCollectToolbarViewsInView(root, allViews, &budget);
        }
        ApolloMarkdownGifLogDiscoveryOnce(composeController,
            [NSString stringWithFormat:@"scan roots=%lu controls=%lu markdown=%@ labels=[%@]",
             (unsigned long)roots.count,
             (unsigned long)allViews.count,
             ApolloMarkdownGifToolbarContainsMarkdownLabels(allViews) ? @"1" : @"0",
             ApolloMarkdownGifSampleLabels(allViews, 8)]);
        ApolloMarkdownGifLogFailureOnce(composeController, @"no markdown toolbar");
    }

    sApolloMarkdownGifInjecting = NO;
    return outcome;
}

static void ApolloMarkdownGifCancelPendingInjections(UIViewController *composeController) {
    if (!composeController) return;
    NSMutableArray<dispatch_block_t> *pending = objc_getAssociatedObject(composeController, &kApolloMarkdownGifPendingInjectionBlocksKey);
    if (!pending) return;
    for (dispatch_block_t block in pending) {
        dispatch_block_cancel(block);
    }
    [pending removeAllObjects];
}

static void ApolloMarkdownGifTrackPendingInjectionBlock(UIViewController *composeController, dispatch_block_t block) {
    if (!composeController || !block) return;
    NSMutableArray<dispatch_block_t> *pending = objc_getAssociatedObject(composeController, &kApolloMarkdownGifPendingInjectionBlocksKey);
    if (!pending) {
        pending = [NSMutableArray array];
        objc_setAssociatedObject(composeController, &kApolloMarkdownGifPendingInjectionBlocksKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [pending addObject:block];
}

static void ApolloMarkdownGifPresentMissingAPIKeyAlert(UIViewController *composeController) {
    if (!composeController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Giphy API Key Required"
                                                                   message:@"Add your free Giphy API key in Settings → API Keys to browse and post GIFs. Get one at developers.giphy.com."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open API Keys" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        CustomAPIViewController *apiVC = [[CustomAPIViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:apiVC];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        sApolloMarkdownGifTapTarget.presentedAPIKeysNav = nav;
        apiVC.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                                  target:sApolloMarkdownGifTapTarget
                                                                                                  action:@selector(dismissPresentedAPIKeys)];
        [composeController presentViewController:nav animated:YES completion:nil];
    }]];
    [composeController presentViewController:alert animated:YES completion:nil];
}

static UIViewController *ApolloMarkdownGifActiveComposeController(void) {
    return sApolloMarkdownGifActiveComposeController;
}

static void ApolloMarkdownGifSetActiveComposeController(UIViewController *controller) {
    sApolloMarkdownGifActiveComposeController = controller;
}

#pragma mark - Comment Link Host (plain-link comment uploads)

// When a Comment Link Host is set (sCommentLinkHost != Off), a photo picked from
// the COMMENT/REPLY editor should upload to that host and land in the comment as
// a plain link rather than a native Reddit media upload (which some subreddits
// disallow). The upload interception lives at the network layer
// (ApolloImageUploadHost.xm) where no editor context exists, so — like the chat
// photo flag in ApolloChatComposer.xm — we arm a window when the markdown
// toolbar's photo button is tapped in a comment-kind composer.
//
// Unlike the chat flag, the window is NOT cleared when an upload consumes it: one
// picker session can upload several images. Its real scope is the arming
// composer's LIFETIME — the weak ref zeroes on dealloc, so the window dies with
// the composer no matter how it was torn down — plus an explicit clear on
// teardown (below) and on a non-comment photo tap. The wall-clock deadline is
// only a long backstop: a short one quietly expired mid photo-pick and reverted
// the upload to native media routing, exactly in the gated subreddits where the
// image button was enabled on the promise of a link.
static double sApolloCommentLinkUploadUntil = 0.0;
static __weak UIViewController *sApolloCommentLinkArmedComposer = nil;
static char kApolloCommentLinkToastShownKey;

static void ApolloCommentLinkMarkUpload(UIViewController *composer) {
    sApolloCommentLinkUploadUntil = [NSDate timeIntervalSinceReferenceDate] + 1800.0;   // backstop only; scope = composer lifetime
    sApolloCommentLinkArmedComposer = composer;
}

#ifdef __cplusplus
extern "C" {
#endif
BOOL ApolloCommentLinkUploadPending(void) {
    return sCommentLinkHost != CommentLinkHostOff &&
           sApolloCommentLinkArmedComposer != nil &&   // weak: dies with the arming composer
           [NSDate timeIntervalSinceReferenceDate] < sApolloCommentLinkUploadUntil;
}
void ApolloCommentLinkClearUpload(void) {
    sApolloCommentLinkUploadUntil = 0.0;
    sApolloCommentLinkArmedComposer = nil;
}
void ApolloCommentLinkShowUploadedToast(NSString *hostName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *composer = sApolloCommentLinkArmedComposer ?: ApolloMarkdownGifActiveComposeController();
        if (!composer) return;
        if (objc_getAssociatedObject(composer, &kApolloCommentLinkToastShownKey)) return;   // once per compose session
        objc_setAssociatedObject(composer, &kApolloCommentLinkToastShownKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *message = [NSString stringWithFormat:@"Uploaded to %@ — this will post as a plain link, not a Reddit image upload.",
                             hostName.length > 0 ? hostName : @"the link host"];
        ApolloMarkdownGifShowGatingToast(composer, message);
    });
}
#ifdef __cplusplus
}
#endif

static void ApolloMarkdownGifScheduleInjection(UIViewController *composeController, NSString *reason) {
    if (composeController && ApolloMarkdownGifComposeSessionHasGif(composeController)) return;

    UIViewController *targetController = composeController ?: ApolloMarkdownGifActiveComposeController();
    if (targetController) {
        ApolloMarkdownGifCancelPendingInjections(targetController);
    }

    if (composeController) {
        ApolloMarkdownGifSetActiveComposeController(composeController);
        ApolloLog(@"[MarkdownGif] compose appeared class=%@ reason=%@",
                  NSStringFromClass(composeController.class), reason ?: @"");
    }
    __weak UIViewController *weakController = composeController;
    for (NSNumber *delay in @[@0.0, @0.1, @0.25, @0.5, @1.0, @2.0, @2.5]) {
        __block dispatch_block_t block = nil;
        block = dispatch_block_create((dispatch_block_flags_t)0, ^{
            if (dispatch_block_testcancel(block)) return;
            UIViewController *strong = weakController ?: ApolloMarkdownGifActiveComposeController();
            if (strong && ApolloMarkdownGifComposeSessionHasGif(strong)) return;
            ApolloMarkdownGifInjectOutcome outcome = ApolloMarkdownGifTryInjectForComposeController(strong);
            if (outcome == ApolloMarkdownGifInjectOutcomeFresh) {
                ApolloLog(@"[MarkdownGif] injection succeeded (reason=%@ delay=%@)", reason ?: @"", delay);
            }
        });
        ApolloMarkdownGifTrackPendingInjectionBlock(targetController, block);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
    }
}

static void ApolloMarkdownGifThrottledTryInject(UIViewController *controller, NSString *reason) {
    if (controller && ApolloMarkdownGifComposeSessionHasGif(controller)) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSNumber *last = objc_getAssociatedObject(controller, &kApolloMarkdownGifToolbarLastAttemptKey);
    if (last && (now - last.doubleValue) < 0.35) {
        ApolloMarkdownGifTryInjectForComposeController(controller);
        return;
    }
    objc_setAssociatedObject(controller, &kApolloMarkdownGifToolbarLastAttemptKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloMarkdownGifSetActiveComposeController(controller);
    ApolloMarkdownGifTryInjectForComposeController(controller);
    (void)reason;
}

static void ApolloMarkdownGifKeyboardShown(NSNotification *note) {
    sApolloMarkdownGifKeyboardVisible = YES;
    NSValue *frameValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (frameValue) sApolloMarkdownGifKeyboardFrameEnd = frameValue.CGRectValue;
    ApolloMarkdownGifScheduleInjection(ApolloMarkdownGifActiveComposeController(), @"keyboard");
}

static void ApolloMarkdownGifKeyboardHidden(NSNotification *note) {
    sApolloMarkdownGifKeyboardVisible = NO;
    NSValue *frameValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (frameValue) sApolloMarkdownGifKeyboardFrameEnd = frameValue.CGRectValue;
}

static UIViewController *ApolloMarkdownGifComposeControllerForTextView(UITextView *textView) {
    UIResponder *responder = textView;
    while ((responder = responder.nextResponder)) {
        if ([responder isKindOfClass:[UIViewController class]] &&
            ApolloMarkdownGifClassLooksLikeCompose((UIViewController *)responder)) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

void ApolloMarkdownGifInstall(void) {
    if (sApolloMarkdownGifInstalled) return;
    sApolloMarkdownGifInstalled = YES;
    if (!sApolloMarkdownGifTapTarget) {
        sApolloMarkdownGifTapTarget = [ApolloMarkdownGifTapTarget new];
    }
    ApolloLog(@"[MarkdownGif] module loaded");
    ApolloLog(@"[MarkdownGif] bootstrap from Tweak.xm");
}

%hook _TtC6Apollo21ComposeViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloMarkdownGifScheduleInjection((UIViewController *)self, @"compose-viewDidAppear");
    ApolloMarkdownGifApplyMediaGating((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMarkdownGifThrottledTryInject((UIViewController *)self, @"compose-layout");
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    // A torn-down comment editor takes its comment-link upload window with it, so
    // the plain-link routing can't leak onto uploads from a later composer. Only
    // on real teardown — a fullscreen picker presented OVER the editor also
    // triggers viewDidDisappear, and the upload it produces still needs the
    // window. Apollo presents the composer wrapped in a UINavigationController,
    // and UIKit sets the dismissal flag on the presented CONTAINER, not its
    // children — so walk the ancestor chain rather than checking only self.
    UIViewController *controller = (UIViewController *)self;
    if (controller != sApolloCommentLinkArmedComposer) return;
    for (UIViewController *ancestor = controller; ancestor; ancestor = ancestor.parentViewController) {
        if (ancestor.isBeingDismissed || ancestor.isMovingFromParentViewController) {
            ApolloCommentLinkClearUpload();
            return;
        }
    }
}

%end

// The markdown toolbar's photo button ("Add photos"). Arm the comment-link window
// BEFORE Apollo opens the picker when the active composer is genuinely composing
// a comment/reply; clear any stale window otherwise (the post composer's body
// editor and the fullscreen chat editor share this toolbar).
%hook _TtC6Apollo20QuickBarKeyboardView

- (void)cameraButtonTapped:(id)sender {
    if (sCommentLinkHost != CommentLinkHostOff) {
        UIViewController *composer = ApolloMarkdownGifActiveComposeController();
        if (ApolloMarkdownGifResolveCommentSubreddit(composer).length > 0) {
            ApolloCommentLinkMarkUpload(composer);
            ApolloLog(@"[CommentLinkHost] Armed comment-editor upload window (host=%ld)", (long)sCommentLinkHost);
        } else {
            ApolloCommentLinkClearUpload();
        }
    }
    %orig;
}

%end

%hook _TtC6Apollo25ComposePostViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloMarkdownGifScheduleInjection((UIViewController *)self, @"post-compose-viewDidAppear");
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMarkdownGifThrottledTryInject((UIViewController *)self, @"post-compose-layout");
}

%end

%hook _TtC6Apollo29WatcherComposerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ApolloMarkdownGifScheduleInjection((UIViewController *)self, @"watcher-compose-viewDidAppear");
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloMarkdownGifThrottledTryInject((UIViewController *)self, @"watcher-compose-layout");
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (ApolloIsSystemShareComposeController((UIViewController *)self)) return;
    if (ApolloMarkdownGifClassLooksLikeCompose((UIViewController *)self)) {
        ApolloMarkdownGifScheduleInjection((UIViewController *)self, @"viewController-viewDidAppear");
    }
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    %orig;
    if (ApolloIsSystemShareComposeController(viewControllerToPresent)) return;
    if (ApolloMarkdownGifClassLooksLikeCompose(viewControllerToPresent)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloMarkdownGifScheduleInjection(viewControllerToPresent, @"presentViewController");
        });
    }
}

%end

%hook UITextView

- (void)setInputAccessoryView:(UIView *)inputAccessoryView {
    %orig;
    UIViewController *composeController = ApolloMarkdownGifComposeControllerForTextView(self);
    if (composeController && inputAccessoryView) {
        ApolloMarkdownGifScheduleInjection(composeController, @"setInputAccessoryView");
    }
}

- (void)becomeFirstResponder {
    %orig;
    UIViewController *composeController = ApolloMarkdownGifComposeControllerForTextView(self);
    if (composeController) {
        ApolloMarkdownGifScheduleInjection(composeController, @"textView-firstResponder");
    }
}

%end

%ctor {
    ApolloMarkdownGifInstall();
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloMarkdownGifKeyboardShown(note);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloMarkdownGifKeyboardShown(note);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloMarkdownGifKeyboardHidden(note);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        ApolloMarkdownGifKeyboardHidden(note);
    }];
    // Comment Link Host toggled while a composer is open (e.g. iPad multitasking):
    // re-apply the media gating so the image button's blocked/enabled state
    // reflects the new setting immediately instead of after the next appearance.
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloCommentLinkHostChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        UIViewController *composer = ApolloMarkdownGifActiveComposeController();
        if (composer) ApolloMarkdownGifApplyMediaGating(composer);
    }];
}
