// ApolloChatComposer.xm
//
// The GIF/emoji/"+" composer fan-out was removed per user request: Reddit's message API
// rejects rich media (proven — /api/comment returns INVALID_COMMENT_SUBMISSION for the
// richtext_json on a t4 message parent, and there is no chat/SendBird/Matrix media-send in
// the binary), so GIFs/emoji only ever rendered Apollo-to-Apollo. The stock composer (Enter
// fullscreen + Add photos) is left untouched. What remains here:
//
//   1. Header avatar (feature 3): the chat participant's avatar in the nav bar, to the LEFT
//      of the username. The username is kept to a single truncated line so a long name never
//      wraps to a second line (which shoved the "[direct chat room]" subtitle out of view).
//   2. Outgoing gif-token rewrite: Apollo's native fullscreen markdown editor (shared with
//      comments) inserts the comment-only token ![gif](giphy|<id>). Chat replies go through
//      -[RDKClient replyToMessage:withText:] -> /api/comment, where a t4 (message) parent
//      rejects the richtext_json Apollo's gif-comment path adds ("Error Sending"). Rewriting
//      the token to a plain giphy URL at the send layer makes the send succeed.

#import "ApolloCommon.h"
#import "ApolloUserProfileCache.h"
#import "ApolloState.h"
#import "ApolloImgChestUpload.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - header avatar (feature 3)

static char kApolloComposerHeaderUserKey;   // on titleViewButton: username we set an avatar for
static char kApolloComposerSetupKey;        // on VC: header-avatar resolution already started

static id ApolloComposerIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    return iv ? object_getIvar(obj, iv) : nil;
}

// Circular avatar of diameter d, drawn at the LEFT of a (d + rightPad) wide canvas
// (transparent right padding). Baking the gap into the image lets the title button centre
// its title on the nav bar with the avatar poking out to the left.
static UIImage *ApolloComposerCircularAvatar(UIImage *src, CGFloat d, CGFloat rightPad) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = [UIScreen mainScreen].scale; fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(d + rightPad, d) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, d, d);
        [[UIBezierPath bezierPathWithOvalInRect:rect] addClip];
        if (src) {
            CGFloat a = src.size.width > 0 ? src.size.height / src.size.width : 1.0;
            CGFloat w = d, h = d;
            if (a > 1.0) { w = d; h = d * a; } else if (a > 0.0) { w = d / a; h = d; }
            [src drawInRect:CGRectMake((d - w) / 2.0, (d - h) / 2.0, w, h)];
        } else { [[UIColor secondarySystemFillColor] setFill]; UIRectFill(rect); }
    }];
}

// Show the chat participant's avatar in the nav bar, left of the username. The title's first
// line is the other user (or "r/sub" for modmail, which we skip). Gated on Show User Avatars.
static void ApolloComposerApplyHeaderAvatar(id vc, NSString *title) {
    if (!sShowUserAvatars) return;
    UIButton *titleBtn = ApolloComposerIvar(vc, "titleViewButton");
    if (![titleBtn isKindOfClass:[UIButton class]]) return;

    // For a chat, show the username on a SINGLE truncating line so a long name (e.g. "IllIIll…")
    // can never wrap to a 2nd line. The "[direct chat room]" subtitle is redundant for a chat, so
    // collapsing to one line is cleaner (iMessage-style). Non-chat threads keep their 2-line
    // title (name + subject) since the subject is informative there.
    BOOL isChatThread = [title localizedCaseInsensitiveContainsString:@"chat room"];
    titleBtn.titleLabel.numberOfLines = isChatThread ? 1 : 2;
    titleBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    NSString *first = [[[title componentsSeparatedByString:@"\n"] firstObject]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (first.length == 0 || [first hasPrefix:@"r/"] || [first hasPrefix:@"["]) return;   // not a single user
    NSString *username = [first hasPrefix:@"u/"] ? [first substringFromIndex:2] : first;
    if ([objc_getAssociatedObject(titleBtn, &kApolloComposerHeaderUserKey) isEqualToString:username]) return;
    objc_setAssociatedObject(titleBtn, &kApolloComposerHeaderUserKey, username, OBJC_ASSOCIATION_COPY_NONATOMIC);

    static const CGFloat d = 22.0;
    static const CGFloat gap = 6.0;
    void (^apply)(UIImage *) = ^(UIImage *img) {
        if (![objc_getAssociatedObject(titleBtn, &kApolloComposerHeaderUserKey) isEqualToString:username]) return;
        // AlwaysOriginal so the button doesn't tint the avatar with the accent (it showed solid green).
        // The avatar image bakes in `gap` of right padding; a matching right contentEdgeInset shifts the
        // [avatar][title] content left by (d+gap)/2 so the TITLE lands on the nav-bar centre and the
        // avatar pokes out to its left (instead of centring the avatar+title pair as one unit).
        // Just place the avatar (with its baked-in right gap) to the left of the title as one
        // centred unit. No contentEdgeInset widening — that squeezed the title's available width
        // and forced a long username ("IllIIll…") to wrap to a 2nd line, hiding the subtitle.
        UIImage *circ = [ApolloComposerCircularAvatar(img, d, gap) imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        [titleBtn setImage:circ forState:UIControlStateNormal];
        titleBtn.imageEdgeInsets = UIEdgeInsetsZero;
        // Adding the avatar image grows the button's content; force the nav bar to re-measure the
        // title view so the username gets its full width (otherwise it truncates on first entry and
        // only shows fully after a leave/return once the layout has settled).
        [titleBtn invalidateIntrinsicContentSize];
        [titleBtn sizeToFit];
        UINavigationBar *navBar = [(UIViewController *)vc navigationController].navigationBar;
        [navBar setNeedsLayout];
        [navBar layoutIfNeeded];
    };
    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *info = [cache cachedInfoForUsername:username];
    NSURL *url = info ? (info.iconURL ?: info.snoovatarURL) : nil;
    UIImage *cachedImg = url ? [cache cachedImageForURL:url] : nil;
    if (cachedImg) { apply(cachedImg); return; }
    [cache requestInfoForUsername:username completion:^(ApolloUserProfileInfo *info2) {
        NSURL *u = info2.iconURL ?: info2.snoovatarURL;
        if (u) [cache requestImageForURL:u completion:apply];
    }];
}

// The thread title ("[direct chat room]" / a PM subject) loads after the network fetch, so
// poll briefly for it, then stamp the header avatar.
static void ApolloComposerResolveTitle(id vc, NSInteger attempt) {
    if (!vc || attempt > 80) return;   // VC already gone: stop polling
    UIButton *titleBtn = ApolloComposerIvar(vc, "titleViewButton");
    NSString *title = titleBtn.currentAttributedTitle.string ?: titleBtn.titleLabel.text ?: titleBtn.currentTitle;
    if (title.length) { ApolloComposerApplyHeaderAvatar(vc, title); return; }
    // Poll quickly so we collapse the title to a single avatar line the instant Apollo sets it —
    // otherwise Apollo's default two-line "username / [direct chat room]" header flashes first.
    // Capture vc WEAKLY across the delay so a quickly-dismissed chat VC isn't kept alive by this
    // ~4s poll chain, and we never stamp a header avatar onto a VC that's already gone. (Reported
    // by @nickclyde in review.)
    __weak id weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id strongVC = weakVC;
        if (strongVC) ApolloComposerResolveTitle(strongVC, attempt + 1);
    });
}

#pragma mark - chat image upload -> ImgChest

// Reddit can't reliably host an image sent in a PM (a chat-uploaded asset is never claimed/published
// to i.redd.it). ImgChest gives a permanent public URL that renders inline in chat, so we route chat
// photo uploads to ImgChest regardless of the global Media Upload Host. It needs the user's ImgChest
// API key; if none is set we prompt them to add one instead of letting the send fail silently.
static double sApolloChatUploadUntil = 0.0;   // wall-clock deadline; an upload within this window -> ImgChest

#ifdef __cplusplus
extern "C" {
#endif
void ApolloChatMarkImageUpload(void) {
    if (!sEnableChatMedia) return;
    sApolloChatUploadUntil = [NSDate timeIntervalSinceReferenceDate] + 180.0;   // generous window for the picker
}
BOOL ApolloChatImageUploadPending(void) {
    return sEnableChatMedia && ([NSDate timeIntervalSinceReferenceDate] < sApolloChatUploadUntil);
}
// Close the chat-upload window the instant ApolloImageUploadHost consumes it for an actual upload, so
// the ImgChest routing (and the short imgchest.com/p/<id> rewrite) can't leak onto a later, unrelated
// upload — e.g. attaching an image to a comment soon after sending a chat image. (Reported by
// @nickclyde in review.)
void ApolloChatClearImageUpload(void) {
    sApolloChatUploadUntil = 0.0;
}
#ifdef __cplusplus
}
#endif

static void ApolloChatPromptImgChestSetup(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return;
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Image Chest API Key Needed"
                         message:@"To send images in chat, add a free Image Chest API key under Settings → Apollo Reborn → Accounts & API Keys. Reddit can't reliably host images in private messages, so chat images upload to Image Chest instead."
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Get a Free Key" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://imgchest.com/"] options:@{} completionHandler:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

%hook _TtC6Apollo28PrivateMessageViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // Start resolving as early as possible (before the header is on screen) to minimise the flash.
    if (objc_getAssociatedObject(self, &kApolloComposerSetupKey)) return;   // once per VC
    objc_setAssociatedObject(self, &kApolloComposerSetupKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloComposerResolveTitle(self, 0);
}
- (void)photosButtonTappedWithSender:(id)sender {
    // Route the chat photo upload to ImgChest (Reddit can't host PM images). Require an ImgChest key
    // first — otherwise prompt the user to add one rather than letting the send fail.
    if (sEnableChatMedia) {
        if (!ApolloImgChestUploadAvailable()) { ApolloChatPromptImgChestSetup((UIViewController *)self); return; }
        ApolloChatMarkImageUpload();
    }
    %orig;
}
%end

#pragma mark - outgoing gif-token rewrite (fixes "Error Sending" from the native gif button)

// Apollo's native fullscreen markdown editor (shared with comments) inserts the comment-only
// token ![gif](giphy|<id>). Chat replies submit via -[RDKClient replyToMessage:withText:] ->
// /api/comment; on a t4 (message) parent Reddit rejects the richtext_json that Apollo's
// gif-comment path builds (INVALID_COMMENT_SUBMISSION -> "Error Sending"). Rewrite the token
// to a plain giphy CDN URL at the send layer so the message sends as text and renders inline
// in Apollo. (Real post comments use a t1/t3 parent and are untouched — they still get rtjson.)
// Reddit rejects ANY markdown media embed ![alt](inner) on a t4 (message) parent — not just gifs.
// Apollo's gif button inserts ![gif](giphy|<id>); the photo button inserts ![img](<reddit upload
// url>). Both make a chat send fail with "Error Sending". Rewrite every embed to its plain URL so
// the message sends as text (and still renders inline in Apollo via the image overlay).
static NSString *ApolloChatRewriteGifTokens(NSString *body) {
    if (![body isKindOfClass:[NSString class]]) return body;
    if ([body rangeOfString:@"!["].location == NSNotFound) return body;   // no media embed
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"!\\[[^\\]]*\\]\\(([^)]+)\\)" options:0 error:nil];
    });
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:body options:0 range:NSMakeRange(0, body.length)];
    if (matches.count == 0) return body;
    NSMutableString *out = [body mutableCopy];
    NSUInteger n = 0;
    for (NSTextCheckingResult *m in [matches reverseObjectEnumerator]) {
        NSString *inner = [body substringWithRange:[m rangeAtIndex:1]];
        NSString *url = nil;
        if ([inner hasPrefix:@"giphy|"])      url = [NSString stringWithFormat:@"https://media.giphy.com/media/%@/giphy.gif", [inner substringFromIndex:6]];
        else if ([inner hasPrefix:@"http"])   url = inner;   // reddit-uploaded image / direct media url
        if (!url) continue;
        [out replaceCharactersInRange:m.range withString:url];
        n++;
    }
    if (n == 0) return body;
    ApolloLog(@"[Composer] rewrote %lu media embed(s) for chat send", (unsigned long)n);
    return out;
}

// Make an outgoing chat body sendable: strip ![alt](url) markdown embeds to plain URLs (Reddit
// rejects media embeds on a t4/message parent; the gif button inserts ![gif](giphy|id), the photo
// button inserts ![img](url)). Chat photo uploads are routed to ImgChest (see the photo-button hook
// below + ApolloImageUploadHost), giving a public CDN URL that renders inline in Apollo. Gated on the
// master chat-media toggle so OFF reverts to stock Apollo send behaviour.
static NSString *ApolloChatFixOutgoing(NSString *body) {
    if (![body isKindOfClass:[NSString class]]) return body;
    if (!sEnableChatMedia) return body;
    return ApolloChatRewriteGifTokens(body);
}

%hook RDKClient
- (id)sendMessage:(id)message subject:(id)subject recipient:(id)recipient completion:(id)completion {
    NSString *fixed = ApolloChatFixOutgoing(message);
    if ([message isKindOfClass:[NSString class]] && ![fixed isEqualToString:message]) return %orig(fixed, subject, recipient, completion);
    return %orig;
}
- (id)replyToMessage:(id)message withText:(id)text completion:(id)completion {
    NSString *fixed = ApolloChatFixOutgoing(text);
    if ([text isKindOfClass:[NSString class]] && ![fixed isEqualToString:text]) return %orig(message, fixed, completion);
    return %orig;
}
- (id)replyToMessageWithFullname:(id)fullname withText:(id)text completion:(id)completion {
    NSString *fixed = ApolloChatFixOutgoing(text);
    if ([text isKindOfClass:[NSString class]] && ![fixed isEqualToString:text]) return %orig(fullname, fixed, completion);
    return %orig;
}
%end

%ctor {
    ApolloLog(@"[Composer] module loaded (header avatar + gif-token rewrite)");
}
