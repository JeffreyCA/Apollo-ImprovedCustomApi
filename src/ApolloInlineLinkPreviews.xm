// ApolloInlineLinkPreviews.xm
//
// Replaces Apollo's basic LinkButtonNode cards with richer metadata cards when
// the target page exposes useful Open Graph / Twitter Card / first-party API
// metadata. Falls back to Apollo's native card when metadata is missing.

#import "ApolloCommon.h"
#import "ApolloDeletedCommentsData.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloBannedProfile.h"
#import "ApolloUserProfileCache.h"
#import "ApolloState.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloTranslation.h"
#import "ApolloUserProfileCache.h"
#import "UserDefaultConstants.h"

#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>
#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackDirection) {
    ApolloLinkPreviewStackDirectionVertical = 0,
    ApolloLinkPreviewStackDirectionHorizontal = 1,
};
typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackJustifyContent) {
    ApolloLinkPreviewStackJustifyContentStart = 0,
};
typedef NS_ENUM(unsigned char, ApolloLinkPreviewStackAlignItems) {
    ApolloLinkPreviewStackAlignItemsStart = 0,
    ApolloLinkPreviewStackAlignItemsCenter = 2,
    ApolloLinkPreviewStackAlignItemsStretch = 3,
};

@class ASLayoutSpec;
@class ASStackLayoutSpec;
@class ASInsetLayoutSpec;
@class ASRatioLayoutSpec;
@class ASBackgroundLayoutSpec;
@class ASDisplayNode;
@class ASNetworkImageNode;
@class ASTextNode;

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (NSArray *)subnodes;
- (id)style;
- (UIView *)view;
- (BOOL)isNodeLoaded;
- (void)setNeedsDisplay;
- (void)onDidLoad:(void(^)(__kindof ASDisplayNode *node))body;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nonatomic) CGFloat alpha;
@property (nonatomic, getter=isHidden) BOOL hidden;
@property (nonatomic) CGFloat borderWidth;
@property (nonatomic) CGColorRef borderColor;
@property (nonatomic) CGFloat shadowOpacity;
@property (nonatomic) CGFloat shadowRadius;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@property (nonatomic) NSLineBreakMode truncationMode;
@property (nonatomic) BOOL userInteractionEnabled;
@end

@interface ASNetworkImageNode : ASDisplayNode
@property (nullable, copy) NSURL *URL;
@property (nullable, nonatomic, strong) UIImage *image;
@property (nullable, nonatomic, strong) UIImage *defaultImage;
@property (nonatomic) UIViewContentMode contentMode;
// Texture ASImageNode: with a zero-size cropRect, only the origin is used —
// it's the unit-space anchor of the aspect-fill crop window measured from the
// image's top-left (y=0 features the top, 0.5 centers, 1 the bottom).
@property (nonatomic) CGRect cropRect;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL placeholderEnabled;
@property (nonatomic, copy) UIColor *placeholderColor;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
- (id)style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) ApolloLinkPreviewStackDirection direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) ApolloLinkPreviewStackJustifyContent justifyContent;
@property (nonatomic) ApolloLinkPreviewStackAlignItems alignItems;
+ (instancetype)stackLayoutSpecWithDirection:(ApolloLinkPreviewStackDirection)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(ApolloLinkPreviewStackJustifyContent)justifyContent
                                  alignItems:(ApolloLinkPreviewStackAlignItems)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASRatioLayoutSpec : ASLayoutSpec
+ (instancetype)ratioLayoutSpecWithRatio:(CGFloat)ratio child:(id)child;
@end

@interface ASBackgroundLayoutSpec : ASLayoutSpec
+ (instancetype)backgroundLayoutSpecWithChild:(id)child background:(id)background;
@end

struct CDStruct_90e057aa { CGSize min; CGSize max; };

static char kApolloLinkPreviewNodesKey;
static char kApolloLinkPreviewFetchInFlightKey;
static char kApolloLinkPreviewOriginalHostShellKey;
static char kApolloLinkPreviewRenderedPlaceholderKey;
// V24: context of the last RICH render (hero/compact), for detecting a
// final-hero -> final-compact flip that has no placeholder mark. Atomic
// association: written from Texture's background measurement threads.
static char kApolloLPLastRenderedContextKey;
static char kApolloLinkPreviewBackgroundColorPresetKey;
static char kApolloLinkPreviewAreaKey;
static char kApolloLinkPreviewContextMenuInstalledKey;
static char kApolloLinkPreviewContextMenuInteractionKey;
static char kApolloLinkPreviewURLKey;
static char kApolloLinkPreviewImageFallbackURLKey;
static char kApolloLinkPreviewImageFallbackScheduledKey;
static char kApolloLinkPreviewImageFallbackInFlightKey;
static char kApolloLinkPreviewImageFallbackAppliedURLKey;
static char kApolloLinkPreviewRenderSignaturesKey;
static char kApolloLinkPreviewCropContextKey;

static NSHashTable<id> *sApolloLPRegisteredLinkNodes = nil;
static dispatch_queue_t sApolloLPRegisteredLinkNodesQueue = NULL;

typedef struct {
    NSUInteger nodes;
    NSUInteger recolored;
} ApolloLPRegisteredRecolorResult;

static void ApolloLPTriggerRelayoutForHost(ASDisplayNode *node, NSString *host);
static BOOL ApolloLPInvokeRowReloadIfPossible(ASDisplayNode *startNode, ASDisplayNode *originNode, NSString *host);
static ASDisplayNode *ApolloLPFindOwningCellNode(ASDisplayNode *node);
static void ApolloLPNoteRowReloadMissForNode(ASDisplayNode *node, NSString *host);
static BOOL ApolloLPIsRedditUserProfileURL(NSURL *url);
static NSString *ApolloLPRedditUsernameFromProfileURL(NSURL *url);
static BOOL ApolloLPIsRedditSubredditURL(NSURL *url);
static NSString *ApolloLPRedditSubredditFromURL(NSURL *url);
static NSString *ApolloLPCleanDisplayText(NSString *text);
static void ApolloLPMaybeKickFaceScanForNode(ASNetworkImageNode *imageNode, NSURL *imageURL, UIImage *image);
static BOOL ApolloLPNodeImageBelongsToURL(ASNetworkImageNode *imageNode, NSString *key);

static Class ApolloLPClass(NSString *name) {
    return NSClassFromString(name);
}

static NSString *ApolloLPHost(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return host;
}

static BOOL ApolloLPHostHasSuffix(NSURL *url, NSString *suffix) {
    NSString *host = ApolloLPHost(url);
    return [host isEqualToString:suffix] || [host hasSuffix:[@"." stringByAppendingString:suffix]];
}

static NSString *ApolloLPRedditUsernameFromProfileURL(NSURL *url) {
    if (!url) return nil;
    NSString *host = ApolloLPHost(url).lowercaseString;
    if (![host isEqualToString:@"reddit.com"] && ![host hasSuffix:@".reddit.com"]) return nil;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count < 2) return nil;
    NSString *prefix = clean[0].lowercaseString;
    if (![prefix isEqualToString:@"user"] && ![prefix isEqualToString:@"u"]) return nil;
    for (NSString *part in clean) {
        if ([part.lowercaseString isEqualToString:@"comments"]) return nil;
    }
    NSString *username = [clean[1] stringByRemovingPercentEncoding] ?: clean[1];
    username = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([username isEqualToString:@"[deleted]"]) return nil;
    return username.length > 0 ? username : nil;
}

static void ApolloLPPrefetchRedditUserProfileIfNeeded(NSURL *url) {
    NSString *username = ApolloLPRedditUsernameFromProfileURL(url);
    if (username.length == 0) return;
    [[ApolloUserProfileCache sharedCache] requestInfoForUsername:username completion:nil];
}

static BOOL ApolloLPTrustedInlineImageHost(NSURL *url) {
    NSArray<NSString *> *suffixes = @[
        @"redd.it", @"imgur.com", @"giphy.com", @"tenor.com", @"redgifs.com",
        @"twimg.com", @"discordapp.com", @"discordapp.net", @"imgchest.com"
    ];
    for (NSString *suffix in suffixes) {
        if (ApolloLPHostHasSuffix(url, suffix)) return YES;
    }
    return NO;
}

static BOOL ApolloLPIsImgurAlbumOrShareURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"imgur.com")) return NO;
    if (url.pathExtension.length > 0) return NO;
    NSString *path = url.path ?: @"";
    if ([path hasPrefix:@"/a/"] || [path hasPrefix:@"/gallery/"]) return YES;

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 1) return NO;
    NSCharacterSet *disallowed = [NSCharacterSet alphanumericCharacterSet].invertedSet;
    return [clean.firstObject rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

static BOOL ApolloLPIsImageChestAlbumURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"imgchest.com")) return NO;
    if (url.pathExtension.length > 0) return NO;
    NSArray<NSString *> *parts = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *clean = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) [clean addObject:part];
    }
    if (clean.count != 2 || ![[clean.firstObject lowercaseString] isEqualToString:@"p"]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
    return [clean.lastObject rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL ApolloLPShouldDeferToInlineMedia(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *extension = url.pathExtension.lowercaseString ?: @"";
    NSSet<NSString *> *imageExtensions = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"gif", nil];

    if (ApolloLPIsImgurAlbumOrShareURL(url)) return YES;
    if (ApolloLPIsImageChestAlbumURL(url)) return YES;
    if ([imageExtensions containsObject:extension] && ApolloLPTrustedInlineImageHost(url)) return YES;

    NSString *host = ApolloLPHost(url);
    NSString *query = url.query.lowercaseString ?: @"";
    if (([host isEqualToString:@"preview.redd.it"] || [host isEqualToString:@"external-preview.redd.it"] || ApolloLPHostHasSuffix(url, @"redd.it"))
        && [extension isEqualToString:@"gif"]
        && [query containsString:@"format=mp4"]) {
        return YES;
    }

    NSString *absolute = url.absoluteString.lowercaseString ?: @"";
    if ([absolute containsString:@"reddit.com/"] && [absolute containsString:@"/video/"] && [absolute containsString:@"/player"]) {
        return YES;
    }
    return NO;
}

static UIColor *ApolloLPResolvedColor(UIColor *color, UITraitCollection *traitCollection) {
    if (!color) return nil;
    if (@available(iOS 13.0, *)) {
        return [color resolvedColorWithTraitCollection:traitCollection ?: UIScreen.mainScreen.traitCollection];
    }
    return color;
}

static UIView *ApolloLPViewForNode(ASDisplayNode *node) {
    if (!node || ![node respondsToSelector:@selector(view)]) return nil;
    @try {
        // [node view] FORCE-LOADS the backing view; below-fold preload-range cards
        // must not pay that (memory + main-thread work for rows that may never
        // display). An unloaded node has no on-screen row to fix anyway — its next
        // display pass measures with the corrected layout.
        if ([node respondsToSelector:@selector(isNodeLoaded)] &&
            !((BOOL (*)(id, SEL))objc_msgSend)(node, @selector(isNodeLoaded))) {
            return nil;
        }
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(node, @selector(view));
        return [view isKindOfClass:[UIView class]] ? view : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL ApolloLPURLIsHTTP(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

static UIViewController *ApolloLPTopViewControllerFromView(UIView *view) {
    UIWindow *window = view.window;
    if (!window) {
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                    if (candidate.isKeyWindow) {
                        window = candidate;
                        break;
                    }
                }
                if (window) break;
            }
        }
    }

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static NSString *ApolloLPNormalizedRedditUsername(NSString *username) {
    if (![username isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean.lowercaseString hasPrefix:@"u/"]) clean = [clean substringFromIndex:2];
    return clean.length > 0 ? clean : nil;
}

static BOOL ApolloLPRedditUserPreviewSaysBanned(ApolloLinkPreview *preview) {
    return [preview.desc isEqualToString:ApolloBannedProfileBannedDescriptionText()];
}

static BOOL ApolloLPRedditUserPreviewNeedsSuspensionRefetch(NSURL *url, ApolloLinkPreview *preview) {
    if (!ApolloLPIsRedditUserProfileURL(url) || !preview) return NO;
    NSString *username = ApolloLPNormalizedRedditUsername(ApolloLPRedditUsernameFromProfileURL(url));
    if (username.length == 0 && preview.authorHandle.length > 0) {
        username = ApolloLPNormalizedRedditUsername(preview.authorHandle);
    }
    if (username.length == 0) return NO;

    ApolloUserProfileInfo *profileInfo = [[ApolloUserProfileCache sharedCache] cachedInfoForUsername:username];
    if (profileInfo && !profileInfo.suspensionChecked) return YES;

    BOOL previewSaysBanned = ApolloLPRedditUserPreviewSaysBanned(preview);
    BOOL cacheSaysBanned = ApolloBannedProfileCachedIsSuspended(username);
    return previewSaysBanned != cacheSaysBanned;
}

static NSString *ApolloLPNormalizedRedditSubreddit(NSString *subreddit) {
    if (![subreddit isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subreddit stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean.lowercaseString hasPrefix:@"r/"]) clean = [clean substringFromIndex:2];
    if ([clean.lowercaseString hasPrefix:@"/r/"]) clean = [clean substringFromIndex:3];
    return clean.length > 0 ? clean.lowercaseString : nil;
}

@interface ApolloLPRedditUserPreviewViewController : UIViewController
- (instancetype)initWithURL:(NSURL *)url preview:(ApolloLinkPreview *)preview;
@end

@interface ApolloLPRedditUserPreviewViewController ()
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) ApolloLinkPreview *preview;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, strong) UIImageView *avatarView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *handleLabel;
@property(nonatomic, strong) UILabel *bioLabel;
@end

@implementation ApolloLPRedditUserPreviewViewController

- (instancetype)initWithURL:(NSURL *)url preview:(ApolloLinkPreview *)preview {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _url = url;
        _preview = preview;
        _username = ApolloLPNormalizedRedditUsername(ApolloLPRedditUsernameFromProfileURL(url))
            ?: ApolloLPNormalizedRedditUsername(preview.authorHandle)
            ?: ApolloLPNormalizedRedditUsername(preview.title);
        self.preferredContentSize = CGSizeMake(360.0, 230.0);
    }
    return self;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 360.0, 230.0)];
    root.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *eyebrow = [UILabel new];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    eyebrow.text = @"REDDIT PROFILE";
    eyebrow.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    eyebrow.textColor = [UIColor secondaryLabelColor];

    UIImageView *avatarView = [UIImageView new];
    avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    avatarView.backgroundColor = [UIColor tertiarySystemFillColor];
    avatarView.contentMode = UIViewContentModeScaleAspectFill;
    avatarView.clipsToBounds = YES;
    avatarView.layer.cornerRadius = 32.0;
    avatarView.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    avatarView.tintColor = [UIColor secondaryLabelColor];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.numberOfLines = 1;

    UILabel *handleLabel = [UILabel new];
    handleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    handleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    handleLabel.textColor = [UIColor secondaryLabelColor];
    handleLabel.numberOfLines = 1;

    UILabel *bioLabel = [UILabel new];
    bioLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bioLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    bioLabel.textColor = [UIColor secondaryLabelColor];
    bioLabel.numberOfLines = 4;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, handleLabel, bioLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 4.0;
    textStack.alignment = UIStackViewAlignmentFill;

    UIStackView *headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[avatarView, textStack]];
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    headerStack.axis = UILayoutConstraintAxisHorizontal;
    headerStack.spacing = 14.0;
    headerStack.alignment = UIStackViewAlignmentCenter;

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 18.0;
    card.clipsToBounds = YES;

    [root addSubview:card];
    [card addSubview:eyebrow];
    [card addSubview:headerStack];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16.0],
        [card.topAnchor constraintEqualToAnchor:root.topAnchor constant:16.0],
        [card.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16.0],

        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [eyebrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],

        [headerStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [headerStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [headerStack.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:14.0],
        [headerStack.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-18.0],

        [avatarView.widthAnchor constraintEqualToConstant:64.0],
        [avatarView.heightAnchor constraintEqualToConstant:64.0],
    ]];

    self.avatarView = avatarView;
    self.titleLabel = titleLabel;
    self.handleLabel = handleLabel;
    self.bioLabel = bioLabel;
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self applyPreviewInfo:self.preview];
    [self loadProfileInfo];
}

- (void)applyPreviewInfo:(ApolloLinkPreview *)preview {
    NSString *username = self.username.length > 0 ? self.username : ApolloLPNormalizedRedditUsername(preview.authorHandle);
    if (ApolloBannedProfileCachedIsSuspended(username) ||
        [preview.desc isEqualToString:ApolloBannedProfileBannedDescriptionText()]) {
        [self applyBannedStateForUsername:username];
        return;
    }

    NSString *displayName = ApolloLPCleanDisplayText(preview.authorDisplayName.length > 0 ? preview.authorDisplayName : preview.title);
    NSString *handle = preview.authorHandle.length > 0 ? preview.authorHandle : (self.username.length > 0 ? [@"u/" stringByAppendingString:self.username] : @"Reddit profile");
    NSString *bio = ApolloLPCleanDisplayText(preview.desc);

    self.titleLabel.text = displayName.length > 0 ? displayName : (self.username.length > 0 ? self.username : @"Reddit Profile");
    self.handleLabel.hidden = NO;
    self.handleLabel.text = [handle hasPrefix:@"u/"] ? handle : [@"u/" stringByAppendingString:handle];
    self.bioLabel.text = bio.length > 0 ? bio : @"Open this profile in Apollo to view posts and comments.";

    NSURL *avatarURL = preview.avatarURL ?: preview.imageURL;
    [self loadImageURL:avatarURL intoImageView:self.avatarView];
}

- (void)applyBannedStateForUsername:(NSString *)username {
    username = ApolloLPNormalizedRedditUsername(username) ?: username;
    NSString *handle = username.length > 0 ? [@"u/" stringByAppendingString:username] : @"Reddit profile";
    self.titleLabel.text = handle;
    self.handleLabel.hidden = YES;
    self.bioLabel.text = ApolloBannedProfileBannedDescriptionText();
    UIImage *icon = ApolloBannedProfileIconImage();
    if (icon) {
        self.avatarView.image = icon;
        self.avatarView.tintColor = nil;
        self.avatarView.backgroundColor = [UIColor tertiarySystemFillColor];
    }
}

- (void)loadProfileInfo {
    if (self.username.length == 0) return;

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    ApolloUserProfileInfo *cachedInfo = [cache cachedInfoForUsername:self.username];
    if (cachedInfo) [self applyProfileInfo:cachedInfo];

    __weak typeof(self) weakSelf = self;
    [cache requestInfoForUsername:self.username completion:^(ApolloUserProfileInfo *info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloLPRedditUserPreviewViewController *strongSelf = weakSelf;
            if (!strongSelf || !info) return;
            [strongSelf applyProfileInfo:info];
        });
    }];
}

- (void)applyProfileInfo:(ApolloUserProfileInfo *)info {
    NSString *username = ApolloLPNormalizedRedditUsername(info.username) ?: self.username;
    if (info.isSuspended || ApolloBannedProfileCachedIsSuspended(username)) {
        [self applyBannedStateForUsername:username];
        return;
    }

    NSString *displayName = ApolloLPCleanDisplayText(info.displayName);
    NSString *bio = ApolloLPCleanDisplayText(info.aboutText);

    self.titleLabel.text = displayName.length > 0 ? displayName : (username.length > 0 ? username : self.titleLabel.text);
    self.handleLabel.hidden = NO;
    self.handleLabel.text = username.length > 0 ? [@"u/" stringByAppendingString:username] : self.handleLabel.text;
    if (bio.length > 0) self.bioLabel.text = bio;

    NSURL *avatarURL = info.hasSnoovatar && info.snoovatarURL ? info.snoovatarURL : info.iconURL;
    [self loadImageURL:avatarURL intoImageView:self.avatarView];
}

- (void)loadImageURL:(NSURL *)url intoImageView:(UIImageView *)imageView {
    if (!url || !imageView) return;

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    UIImage *cachedImage = [cache cachedImageForURL:url];
    if (cachedImage) {
        imageView.image = cachedImage;
        return;
    }

    [cache requestImageForURL:url completion:^(UIImage *image) {
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            imageView.image = image;
        });
    }];
}

@end

@interface ApolloLPRedditSubredditPreviewViewController : UIViewController
- (instancetype)initWithURL:(NSURL *)url preview:(ApolloLinkPreview *)preview;
@end

@interface ApolloLPRedditSubredditPreviewViewController ()
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) ApolloLinkPreview *preview;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic, strong) UIImageView *avatarView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *handleLabel;
@property(nonatomic, strong) UILabel *memberLabel;
@property(nonatomic, strong) UILabel *bioLabel;
@end

@implementation ApolloLPRedditSubredditPreviewViewController

- (instancetype)initWithURL:(NSURL *)url preview:(ApolloLinkPreview *)preview {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _url = url;
        _preview = preview;
        _subredditName = ApolloLPNormalizedRedditSubreddit(ApolloLPRedditSubredditFromURL(url))
            ?: ApolloLPNormalizedRedditSubreddit(preview.authorHandle);
        self.preferredContentSize = CGSizeMake(360.0, 250.0);
    }
    return self;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 360.0, 250.0)];
    root.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *eyebrow = [UILabel new];
    eyebrow.translatesAutoresizingMaskIntoConstraints = NO;
    eyebrow.text = @"REDDIT COMMUNITY";
    eyebrow.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    eyebrow.textColor = [UIColor secondaryLabelColor];

    UIImageView *avatarView = [UIImageView new];
    avatarView.translatesAutoresizingMaskIntoConstraints = NO;
    avatarView.backgroundColor = [UIColor tertiarySystemFillColor];
    avatarView.contentMode = UIViewContentModeScaleAspectFill;
    avatarView.clipsToBounds = YES;
    avatarView.layer.cornerRadius = 32.0;
    avatarView.image = [UIImage systemImageNamed:@"person.2.fill"];
    avatarView.tintColor = [UIColor secondaryLabelColor];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];
    titleLabel.numberOfLines = 1;

    UILabel *handleLabel = [UILabel new];
    handleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    handleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    handleLabel.textColor = [UIColor secondaryLabelColor];
    handleLabel.numberOfLines = 1;

    UILabel *memberLabel = [UILabel new];
    memberLabel.translatesAutoresizingMaskIntoConstraints = NO;
    memberLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    memberLabel.textColor = [UIColor secondaryLabelColor];
    memberLabel.numberOfLines = 1;

    UILabel *bioLabel = [UILabel new];
    bioLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bioLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    bioLabel.textColor = [UIColor secondaryLabelColor];
    bioLabel.numberOfLines = 4;

    UIStackView *textStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, handleLabel, memberLabel, bioLabel]];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 4.0;
    textStack.alignment = UIStackViewAlignmentFill;

    UIStackView *headerStack = [[UIStackView alloc] initWithArrangedSubviews:@[avatarView, textStack]];
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    headerStack.axis = UILayoutConstraintAxisHorizontal;
    headerStack.spacing = 14.0;
    headerStack.alignment = UIStackViewAlignmentCenter;

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 18.0;
    card.clipsToBounds = YES;

    [root addSubview:card];
    [card addSubview:eyebrow];
    [card addSubview:headerStack];

    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16.0],
        [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16.0],
        [card.topAnchor constraintEqualToAnchor:root.topAnchor constant:16.0],
        [card.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16.0],
        [eyebrow.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [eyebrow.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [eyebrow.topAnchor constraintEqualToAnchor:card.topAnchor constant:18.0],
        [headerStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18.0],
        [headerStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18.0],
        [headerStack.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:14.0],
        [headerStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18.0],
        [avatarView.widthAnchor constraintEqualToConstant:64.0],
        [avatarView.heightAnchor constraintEqualToConstant:64.0],
    ]];

    self.avatarView = avatarView;
    self.titleLabel = titleLabel;
    self.handleLabel = handleLabel;
    self.memberLabel = memberLabel;
    self.bioLabel = bioLabel;
    self.view = root;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self applyPreviewInfo:self.preview];
    [self loadSubredditInfo];
}

- (void)applyPreviewInfo:(ApolloLinkPreview *)preview {
    NSString *displayName = ApolloLPCleanDisplayText(preview.authorDisplayName.length > 0 ? preview.authorDisplayName : preview.title);
    NSString *handle = preview.authorHandle.length > 0 ? preview.authorHandle : (self.subredditName.length > 0 ? [@"r/" stringByAppendingString:self.subredditName] : @"Reddit community");
    NSString *bio = ApolloLPCleanDisplayText(preview.desc);
    NSString *members = ApolloLPCleanDisplayText(preview.postText);

    self.titleLabel.text = displayName.length > 0 ? displayName : (self.subredditName.length > 0 ? self.subredditName : @"Reddit Community");
    self.handleLabel.text = [handle hasPrefix:@"r/"] ? handle : [@"r/" stringByAppendingString:handle];
    self.memberLabel.text = members.length > 0 ? members : @"";
    self.memberLabel.hidden = members.length == 0;
    self.bioLabel.text = bio.length > 0 ? bio : @"Open this community in Apollo to browse posts.";

    NSURL *avatarURL = preview.avatarURL ?: preview.imageURL;
    [self loadImageURL:avatarURL intoImageView:self.avatarView];
}

- (void)loadSubredditInfo {
    if (self.subredditName.length == 0) return;

    ApolloSubredditInfoCache *cache = [ApolloSubredditInfoCache sharedCache];
    ApolloSubredditInfo *cachedInfo = [cache cachedInfoForSubreddit:self.subredditName];
    if (cachedInfo) [self applySubredditInfo:cachedInfo];

    __weak typeof(self) weakSelf = self;
    [cache requestInfoForSubreddit:self.subredditName completion:^(ApolloSubredditInfo *info) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloLPRedditSubredditPreviewViewController *strongSelf = weakSelf;
            if (!strongSelf || !info) return;
            [strongSelf applySubredditInfo:info];
        });
    }];
}

- (void)applySubredditInfo:(ApolloSubredditInfo *)info {
    NSString *displayName = ApolloLPCleanDisplayText(info.displayName);
    NSString *bio = ApolloLPCleanDisplayText(info.aboutText);
    NSString *subredditName = ApolloLPNormalizedRedditSubreddit(info.subredditName) ?: self.subredditName;
    NSString *members = ApolloSubredditFormattedMemberCount(info.subscriberCount);

    self.titleLabel.text = displayName.length > 0 ? displayName : (subredditName.length > 0 ? subredditName : self.titleLabel.text);
    self.handleLabel.text = subredditName.length > 0 ? [@"r/" stringByAppendingString:subredditName] : self.handleLabel.text;
    self.memberLabel.text = members.length > 0 ? members : @"";
    self.memberLabel.hidden = members.length == 0;
    if (bio.length > 0) self.bioLabel.text = bio;

    [self loadImageURL:info.iconURL intoImageView:self.avatarView];
}

- (void)loadImageURL:(NSURL *)url intoImageView:(UIImageView *)imageView {
    if (!url || !imageView) return;

    ApolloUserProfileCache *cache = [ApolloUserProfileCache sharedCache];
    UIImage *cachedImage = [cache cachedImageForURL:url];
    if (cachedImage) {
        imageView.image = cachedImage;
        return;
    }

    [cache requestImageForURL:url completion:^(UIImage *image) {
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            imageView.image = image;
        });
    }];
}

@end

@interface ApolloLinkPreviewInteractionDelegate : NSObject <UIContextMenuInteractionDelegate>
+ (instancetype)sharedDelegate;
@end

@implementation ApolloLinkPreviewInteractionDelegate

+ (instancetype)sharedDelegate {
    static ApolloLinkPreviewInteractionDelegate *delegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegate = [ApolloLinkPreviewInteractionDelegate new];
    });
    return delegate;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    UIView *view = interaction.view;
    NSURL *url = objc_getAssociatedObject(view, &kApolloLinkPreviewURLKey);
    if (!ApolloLPURLIsHTTP(url)) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:^UIViewController *{
        if (ApolloLPIsRedditUserProfileURL(url)) {
            ApolloLinkPreview *preview = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
            return [[ApolloLPRedditUserPreviewViewController alloc] initWithURL:url preview:preview];
        }
        if (ApolloLPIsRedditSubredditURL(url)) {
            ApolloLinkPreview *preview = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
            return [[ApolloLPRedditSubredditPreviewViewController alloc] initWithURL:url preview:preview];
        }
        return [[SFSafariViewController alloc] initWithURL:url];
    } actionProvider:^UIMenu *(__unused NSArray<UIMenuElement *> *suggestedActions) {
        __weak UIView *weakView = view;
        UIAction *copyAction = [UIAction actionWithTitle:@"Copy Link"
                                                   image:[UIImage systemImageNamed:@"doc.on.doc"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
            UIPasteboard.generalPasteboard.URL = url;
        }];
        UIAction *shareAction = [UIAction actionWithTitle:@"Share..."
                                                    image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                               identifier:nil
                                                  handler:^(__unused UIAction *action) {
            UIView *strongView = weakView;
            if (!strongView) return;
            UIActivityViewController *activityController = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            UIViewController *topController = ApolloLPTopViewControllerFromView(strongView);
            if (!topController) return;
            activityController.popoverPresentationController.sourceView = strongView;
            activityController.popoverPresentationController.sourceRect = strongView.bounds;
            [topController presentViewController:activityController animated:YES completion:nil];
        }];
        UIAction *openAction = [UIAction actionWithTitle:@"Open in Safari"
                                                   image:[UIImage systemImageNamed:@"safari"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }];
        return [UIMenu menuWithTitle:@"" children:@[copyAction, shareAction, openAction]];
    }];
}

@end

static void ApolloLPInstallContextMenuOnView(UIView *view, NSURL *url) {
    if (!view || !ApolloLPURLIsHTTP(url)) return;
    objc_setAssociatedObject(view, &kApolloLinkPreviewURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([objc_getAssociatedObject(view, &kApolloLinkPreviewContextMenuInstalledKey) boolValue]) return;

    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:[ApolloLinkPreviewInteractionDelegate sharedDelegate]];
    [view addInteraction:interaction];
    objc_setAssociatedObject(view, &kApolloLinkPreviewContextMenuInteractionKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kApolloLinkPreviewContextMenuInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloLPInstallContextMenuForNode(ASDisplayNode *node, NSURL *url) {
    if (!node || !ApolloLPURLIsHTTP(url)) return;
    objc_setAssociatedObject(node, &kApolloLinkPreviewURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    void (^install)(ASDisplayNode *) = ^(ASDisplayNode *loadedNode) {
        NSURL *currentURL = objc_getAssociatedObject(loadedNode, &kApolloLinkPreviewURLKey) ?: url;
        UIView *view = ApolloLPViewForNode(loadedNode);
        ApolloLPInstallContextMenuOnView(view, currentURL);
    };

    if ([node respondsToSelector:@selector(isNodeLoaded)] && [node isNodeLoaded]) {
        install(node);
        return;
    }
    // One pending onDidLoad block per node, EVER. This function runs on every
    // layoutSpecThatFits pass, and Texture APPENDS each block to the node's
    // internal _onDidLoadBlocks array — an unloaded node measured N times
    // accumulated N blocks (each retaining the URL + closure), and detached
    // measurement trees that never load never drain them: strictly monotonic
    // per-measure growth on card-heavy threads (#630 round-9 lag audit).
    static const void *kApolloLPOnDidLoadArmedKey = &kApolloLPOnDidLoadArmedKey;
    if ([objc_getAssociatedObject(node, kApolloLPOnDidLoadArmedKey) boolValue]) return;
    if ([node respondsToSelector:@selector(onDidLoad:)]) {
        objc_setAssociatedObject(node, kApolloLPOnDidLoadArmedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [node onDidLoad:^(__kindof ASDisplayNode *loadedNode) {
            install(loadedNode);
        }];
    }
}

static NSCache<NSString *, UIImage *> *ApolloLPFallbackImageCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
        cache.totalCostLimit = 40 * 1024 * 1024;
        // Under real memory pressure, drop the whole bitmap cache — cards
        // re-fetch/re-decode on demand. Cost-limited NSCache contents are not
        // reliably purged by the system while the app is frontmost, and 40MB
        // of card bitmaps is exactly the wrong thing to be holding when
        // jetsam is sizing up the process (#630 round-8/9).
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(__unused NSNotification *note) {
            [cache removeAllObjects];
        }];
    });
    return cache;
}

static BOOL ApolloLPNetworkImageNodeHasImage(ASNetworkImageNode *imageNode) {
    if (!imageNode || ![imageNode respondsToSelector:@selector(image)]) return NO;
    UIImage *image = imageNode.image;
    return [image isKindOfClass:[UIImage class]] && image.size.width > 0.0 && image.size.height > 0.0;
}

// Cap the pixel size of any bitmap the card machinery holds on to. Cards render at
// most ~screen width x ~200pt; og:image heroes are frequently 2000px+ wide, which
// decode to 8-12MB each — and the fallback path pins them in defaultImage, where
// Texture's out-of-range release never touches them. Those per-card pins were the
// bulk of the #630 round-8 jetsam (+20MB retained per card-heavy thread open).
static UIImage *ApolloLPDisplaySizedImage(UIImage *image) {
    if (!image) return nil;
    CGFloat const maxDim = 1000.0;
    CGFloat w = image.size.width * image.scale, h = image.size.height * image.scale;
    CGFloat longest = MAX(w, h);
    if (longest <= maxDim || w <= 0 || h <= 0) return image;
    CGFloat ratio = maxDim / longest;
    CGSize target = CGSizeMake(floor(w * ratio), floor(h * ratio));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:target format:format];
    UIImage *scaled = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    }];
    return scaled ?: image;
}

static void ApolloLPRememberRenderedImageForURL(ASNetworkImageNode *imageNode, NSURL *imageURL) {
    if (!imageURL.absoluteString.length || !ApolloLPNetworkImageNodeHasImage(imageNode)) return;
    UIImage *image = ApolloLPDisplaySizedImage(imageNode.image);
    NSUInteger cost = (NSUInteger)(image.size.width * image.size.height * image.scale * image.scale * 4.0);
    [ApolloLPFallbackImageCache() setObject:image forKey:imageURL.absoluteString cost:cost];
    ApolloLPMaybeKickFaceScanForNode(imageNode, imageURL, image);
}

static void ApolloLPSetNetworkImageURLPreservingImage(ASNetworkImageNode *imageNode, NSURL *imageURL) {
    if (!imageNode) return;
    NSURL *currentURL = imageNode.URL;
    if (!currentURL && !imageURL) return;
    if ([currentURL.absoluteString isEqualToString:imageURL.absoluteString]) {
        ApolloLPRememberRenderedImageForURL(imageNode, imageURL);
        return;
    }

    ApolloLPRememberRenderedImageForURL(imageNode, currentURL);
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackAppliedURLKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // Only clear the persisted defaultImage when we're switching to an
    // empty URL. Keeping defaultImage for non-empty new URLs lets the old
    // image keep showing for the brief moment before the new URL's image
    // loads, instead of flashing the placeholder gray. Texture will replace
    // the displayed image as soon as the new URL resolves.
    if (imageURL.absoluteString.length == 0
        && [imageNode respondsToSelector:@selector(setDefaultImage:)]) {
        imageNode.defaultImage = nil;
    }
    imageNode.URL = imageURL;
}

// Set imageNode.backgroundColor exactly once based on whether we expect a
// real image to load. ASNetworkImageNode already paints `placeholderColor`
// while the network image is loading (configured once in
// ApolloLPNodeBundleForHost), so we only need backgroundColor as a fallback
// when there is no URL at all. Re-flipping backgroundColor between nil and
// gray on every layoutSpecThatFits: pass was the main per-paint flicker
// source after entering / re-entering a thread, because Texture briefly
// releases imageNode.image around display-range changes.
static void ApolloLPSetImageNodeBackgroundForURL(ASNetworkImageNode *imageNode, NSURL *imageURL) {
    if (!imageNode) return;
    UIColor *target = imageURL.absoluteString.length > 0 ? nil : [UIColor tertiarySystemFillColor];
    UIColor *current = imageNode.backgroundColor;
    if ((!current && !target) || [current isEqual:target]) return;
    imageNode.backgroundColor = target;
}

// layoutSpecThatFits: runs on Texture background layout threads — never touch
// UIView/CALayer here (deadlocks with main-thread cornerRadius updates).
static void ApolloLPSetAvatarNodeVisible(ASNetworkImageNode *avatarNode, BOOL visible) {
    if (!avatarNode) return;
    avatarNode.placeholderEnabled = visible;
    avatarNode.alpha = visible ? 1.0 : 0.0;
    avatarNode.hidden = !visible;
}

// V21: dead preview images. Clip hosts (streamin, streamff, ...) publish an
// og:image URL before the thumbnail file actually exists — fresh clips 404
// for the first few minutes. Remember definitive 4xx failures per URL so the
// card can render compact instead of a hero with a big blank image area; the
// mark expires so the card upgrades itself once the thumbnail is generated.
static const NSTimeInterval kApolloLPDeadImageRetryCooldown = 300.0;

// Declared here (used by both the dead-image path and the V20 shrink path):
// host string of a row reload that failed while the node was detached, to be
// re-fired from didEnterVisibleState.
static char kApolloLPPendingRowReloadHostKey;

static NSMutableDictionary<NSString *, NSDate *> *ApolloLPDeadImageURLs(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static void ApolloLPMarkImageURLDead(NSURL *url) {
    NSString *key = url.absoluteString;
    if (key.length == 0) return;
    @synchronized (ApolloLPDeadImageURLs()) {
        ApolloLPDeadImageURLs()[key] = [NSDate date];
    }
}

static BOOL ApolloLPImageURLIsDead(NSURL *url) {
    NSString *key = url.absoluteString;
    if (key.length == 0) return NO;
    @synchronized (ApolloLPDeadImageURLs()) {
        NSDate *diedAt = ApolloLPDeadImageURLs()[key];
        if (!diedAt) return NO;
        if ([[NSDate date] timeIntervalSinceDate:diedAt] > kApolloLPDeadImageRetryCooldown) {
            [ApolloLPDeadImageURLs() removeObjectForKey:key];
            return NO;
        }
        return YES;
    }
}

static void ApolloLPApplyFallbackImage(ASNetworkImageNode *imageNode, NSURL *imageURL, UIImage *image, NSString *host) {
    (void)host;
    if (!imageNode || !image || image.size.width <= 0.0 || image.size.height <= 0.0) return;
    NSURL *currentURL = objc_getAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackURLKey);
    if (![currentURL.absoluteString isEqualToString:imageURL.absoluteString]) return;
    if (ApolloLPNetworkImageNodeHasImage(imageNode)) return;

    // Pin only a display-sized bitmap: og:image heroes decode to 8-12MB and
    // defaultImage is outside Texture's out-of-range release (#630 round 8).
    UIImage *displayImage = ApolloLPDisplaySizedImage(image);
    imageNode.image = displayImage;
    // Persist the decoded image as defaultImage so Texture keeps painting it
    // when it releases imageNode.image outside the display range. Without
    // this, re-entering a thread shows a blank/gray frame before the
    // fallback path re-applies the image.
    if ([imageNode respondsToSelector:@selector(setDefaultImage:)]) {
        imageNode.defaultImage = displayImage;
    }
    imageNode.backgroundColor = nil;
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackAppliedURLKey, imageURL.absoluteString, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloLPMaybeKickFaceScanForNode(imageNode, imageURL, image);
}

static void ApolloLPStartFallbackImageFetch(ASNetworkImageNode *imageNode, NSURL *imageURL, NSString *host) {
    if (!imageNode || !ApolloLPURLIsHTTP(imageURL)) return;
    // Dead-marked URLs don't get re-fetched during the cooldown — refetching
    // on every re-render loops: 404 -> reflow -> row reload -> re-render ->
    // fetch -> 404 ... (one reload per second, visible as flickering cells).
    if (ApolloLPImageURLIsDead(imageURL)) return;
    NSString *key = imageURL.absoluteString;
    if (key.length == 0) return;

    UIImage *cachedImage = [ApolloLPFallbackImageCache() objectForKey:key];
    if (cachedImage) {
        ApolloLPApplyFallbackImage(imageNode, imageURL, cachedImage, host);
        return;
    }

    if ([objc_getAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackInFlightKey) boolValue]) return;
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:imageURL cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0];
    [request setValue:@"image/avif,image/webp,image/apng,image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

    __weak ASNetworkImageNode *weakImageNode = imageNode;
    NSString *hostCopy = [host copy];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)error;
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
        BOOL definitivelyDead = NO;
        if (image) {
            NSUInteger cost = (NSUInteger)(image.size.width * image.size.height * image.scale * image.scale * 4.0);
            [ApolloLPFallbackImageCache() setObject:image forKey:key cost:cost];
        } else {
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            // 4xx = the file genuinely isn't there (clip hosts publish og:image
            // before generating the thumbnail). Transient network errors and
            // 5xx don't dead-mark, so flaky connectivity can't compact-ify
            // every card.
            definitivelyDead = httpResponse.statusCode >= 400 && httpResponse.statusCode < 500;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ASNetworkImageNode *strongImageNode = weakImageNode;
            if (!strongImageNode) return;
            objc_setAssociatedObject(strongImageNode, &kApolloLinkPreviewImageFallbackInFlightKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLPApplyFallbackImage(strongImageNode, imageURL, image, hostCopy);

            if (definitivelyDead && !ApolloLPImageURLIsDead(imageURL)) {
                // V21: re-render the host card as compact instead of leaving a
                // dead hero image area, and fix the row height (or defer the
                // reload to visibility if the node is detached, as in V20).
                // The reflow fires only on the FIRST death of a URL — the
                // dead-mark suppresses further fetches, so repeats mean a
                // race, and reflowing again would loop the row reload.
                ApolloLPMarkImageURLDead(imageURL);
                ASDisplayNode *hostNode = (ASDisplayNode *)strongImageNode;
                for (int hops = 0; hostNode && hops < 24; hops++) {
                    if ([NSStringFromClass([hostNode class]) containsString:@"LinkButtonNode"]) break;
                    hostNode = hostNode.supernode;
                }
                if (hostNode) {
                    ApolloLPTriggerRelayoutForHost(hostNode, hostCopy);
                    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(hostNode);
                    if (!ApolloLPInvokeRowReloadIfPossible(cellNode ?: hostNode, hostNode, hostCopy)) {
                        ApolloLPNoteRowReloadMissForNode(hostNode, hostCopy);
                    }
                }
            }
        });
    }] resume];
}

static void ApolloLPScheduleImageFallbackIfNeeded(ASNetworkImageNode *imageNode, NSURL *imageURL, NSString *host) {
    if (!imageNode || !ApolloLPURLIsHTTP(imageURL)) return;
    if (ApolloLPImageURLIsDead(imageURL)) return;
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackURLKey, imageURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *cacheKey = imageURL.absoluteString;
    UIImage *cachedImage = cacheKey.length > 0 ? [ApolloLPFallbackImageCache() objectForKey:cacheKey] : nil;
    if (cachedImage && !ApolloLPNetworkImageNodeHasImage(imageNode)) {
        ApolloLPApplyFallbackImage(imageNode, imageURL, cachedImage, host);
    }
    if (ApolloLPNetworkImageNodeHasImage(imageNode)) {
        ApolloLPRememberRenderedImageForURL(imageNode, imageURL);
        return;
    }

    NSString *scheduledURL = objc_getAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackScheduledKey);
    if ([scheduledURL isEqualToString:imageURL.absoluteString]) return;
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackScheduledKey, imageURL.absoluteString, OBJC_ASSOCIATION_COPY_NONATOMIC);

    __weak ASNetworkImageNode *weakImageNode = imageNode;
    NSURL *imageURLCopy = imageURL;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        ASNetworkImageNode *strongImageNode = weakImageNode;
        if (!strongImageNode) return;
        NSURL *currentURL = objc_getAssociatedObject(strongImageNode, &kApolloLinkPreviewImageFallbackURLKey);
        if (![currentURL.absoluteString isEqualToString:imageURLCopy.absoluteString]) return;
        if (ApolloLPNetworkImageNodeHasImage(strongImageNode)) {
            // Texture's own loader won the race. Remember the image instead of
            // just bailing — that feeds the fallback cache and, for tall
            // cropped cards, the V22 face scan. Gated so a stale previous-URL
            // image preserved as defaultImage across a URL switch is never
            // stored/scanned under the new URL.
            if (ApolloLPNodeImageBelongsToURL(strongImageNode, imageURLCopy.absoluteString)) {
                ApolloLPRememberRenderedImageForURL(strongImageNode, imageURLCopy);
            }
            return;
        }
        ApolloLPStartFallbackImageFetch(strongImageNode, imageURLCopy, hostCopy);
        // One bounded late re-check: if Texture's loader lands the image after
        // the 900ms window (slow CDN) and no further layout pass happens, the
        // card would stay on the default anchor with no face scan. Not broken,
        // but a mid-frame face wouldn't get re-centered while the card sits
        // on screen — so look once more.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            ASNetworkImageNode *lateNode = weakImageNode;
            if (!lateNode) return;
            NSURL *lateURL = objc_getAssociatedObject(lateNode, &kApolloLinkPreviewImageFallbackURLKey);
            if (![lateURL.absoluteString isEqualToString:imageURLCopy.absoluteString]) return;
            if (ApolloLPNodeImageBelongsToURL(lateNode, imageURLCopy.absoluteString)) {
                ApolloLPRememberRenderedImageForURL(lateNode, imageURLCopy);
            }
        });
    });
}

// ---------------------------------------------------------------------------
// V22: crop anchoring for tall preview images.
//
// The hero and bluesky cards clamp portrait images into a shorter
// ASRatioLayoutSpec box (0.6 / 0.75 h:w) and the compact card fills a fixed
// 84x84 square, all under UIViewContentModeScaleAspectFill. Texture's default
// cropRect of (0.5, 0.5, 0, 0) centers that crop vertically, which routinely
// decapitates portrait shots (user report: transfer-news cards showing a
// torso with no head). A zero-size cropRect's origin is a pure alignment
// anchor: origin.y = 0 features the TOP of the image, 1 the bottom. Tall
// images now anchor to the top by default — where faces, headlines and
// screenshot titles live — and a one-shot CIDetector face scan refines the
// anchor asynchronously so a face that is NOT near the top (news photo with a
// banner above the subject, etc.) still ends up inside the visible window.
//
// The scan runs at most once per image URL (results cached, including "no
// faces"), off-main at utility QoS, and only for images that are actually
// vertically cropped. ASImageNode's cropRect accessors are mutex-guarded and
// the setter bounces its conditional setNeedsDisplay to the main thread, so
// the card builders can set anchors from Texture's background layout threads;
// an anchor set before the network image arrives applies when it lands,
// because setImage: redisplays with the then-current cropRect.

// Union of detected face rects per image URL, in top-down unit coordinates.
// CGRectNull = scanned (or unscannable), no faces.
static NSCache<NSString *, NSValue *> *ApolloLPFaceRegionCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 512;
    });
    return cache;
}

static NSMutableSet<NSString *> *ApolloLPFaceScanPending(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static dispatch_queue_t ApolloLPFaceScanQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.apolloreborn.linkpreview.facescan",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static CIDetector *ApolloLPFaceDetector(void) {
    static CIDetector *detector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detector = [CIDetector detectorOfType:CIDetectorTypeFace
                                      context:nil
                                      options:@{ CIDetectorAccuracy : CIDetectorAccuracyLow }];
    });
    return detector;
}

// Nodes whose crop anchor should be re-refined when a face scan lands, keyed
// by image URL. Values are weak hash tables — dead nodes just drop out.
static NSMapTable<NSString *, NSHashTable<ASNetworkImageNode *> *> *ApolloLPCropRefinementNodes(void) {
    static NSMapTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMapTable strongToStrongObjectsMapTable]; });
    return table;
}

// YES when the node's current .image is genuinely the bitmap for `key`, and
// not the PREVIOUS URL's image that ApolloLPSetNetworkImageURLPreservingImage
// deliberately keeps as defaultImage across a URL switch (to avoid a gray
// flash). Scanning that stale bitmap would poison the face-region cache under
// the new URL for the whole session.
static BOOL ApolloLPNodeImageBelongsToURL(ASNetworkImageNode *imageNode, NSString *key) {
    if (key.length == 0 || !ApolloLPNetworkImageNodeHasImage(imageNode)) return NO;
    UIImage *image = imageNode.image;
    UIImage *defaultImage = [imageNode respondsToSelector:@selector(defaultImage)] ? imageNode.defaultImage : nil;
    // Distinct from defaultImage = Texture's own download for the current URL.
    if (image != defaultImage) return YES;
    // Equal to defaultImage = either our fallback apply for THIS url (stamped
    // below) or a preserved previous-URL bitmap (stamp cleared on switch).
    NSString *appliedURL = objc_getAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackAppliedURLKey);
    return [appliedURL isEqualToString:key];
}

static void ApolloLPRegisterCropRefinementNode(NSString *key, ASNetworkImageNode *imageNode) {
    if (key.length == 0 || !imageNode) return;
    NSMapTable *table = ApolloLPCropRefinementNodes();
    @synchronized (table) {
        // Keys are never removed on the hot path (their nodes just die out of
        // the weak tables), so sweep empty entries periodically to keep the
        // table from growing one entry per unique image URL for the session.
        static NSUInteger registrations = 0;
        if ((++registrations % 64) == 0) {
            NSMutableArray *deadKeys = [NSMutableArray array];
            for (NSString *existingKey in table) {
                NSHashTable *set = [table objectForKey:existingKey];
                if (set.allObjects.count == 0) [deadKeys addObject:existingKey];
            }
            for (NSString *deadKey in deadKeys) [table removeObjectForKey:deadKey];
        }
        NSHashTable *nodes = [table objectForKey:key];
        if (!nodes) {
            nodes = [NSHashTable weakObjectsHashTable];
            [table setObject:nodes forKey:key];
        }
        [nodes addObject:imageNode];
    }
}

static void ApolloLPSetCropAnchorY(ASNetworkImageNode *imageNode, CGFloat anchorY, BOOL redisplayIfLoaded) {
    if (![imageNode respondsToSelector:@selector(setCropRect:)]
        || ![imageNode respondsToSelector:@selector(cropRect)]) return;
    CGRect target = CGRectMake(0.5, anchorY, 0.0, 0.0);
    if (CGRectEqualToRect(imageNode.cropRect, target)) return;
    imageNode.cropRect = target;
    // The setter self-redisplays only when the node is loaded AND the image is
    // larger than the bounds in points; small upscaled images miss that check,
    // so the async refinement pass forces the redraw (display is deduped).
    if (redisplayIfLoaded && ApolloLPNetworkImageNodeHasImage(imageNode)) {
        [imageNode setNeedsDisplay];
    }
}

// The faceless default: top for genuinely portrait images (that's where
// heads, headlines and screenshot titles live), center for landscape-ish
// images that only crop because their box is even wider (YouTube hqdefault
// 4:3 thumbs are 16:9 frames LETTERBOXED with black bars — a centered crop
// removes the bars symmetrically, a top crop would feature the top bar).
static CGFloat ApolloLPDefaultCropAnchorY(CGFloat naturalRatio) {
    return naturalRatio > 1.0 ? 0.0 : 0.5;
}

// Where inside the image the crop window should sit, as the cropRect origin.y
// anchor (0 = window at the image top, 1 = at the bottom). visibleFrac is the
// fraction of the image's height the box shows.
static CGFloat ApolloLPCropAnchorYForFaceRegion(CGRect region, CGFloat visibleFrac, CGFloat defaultAnchorY) {
    if (visibleFrac <= 0.0 || visibleFrac >= 0.999) return defaultAnchorY;
    if (CGRectIsNull(region) || CGRectIsEmpty(region)) return defaultAnchorY;
    CGFloat hidden = 1.0 - visibleFrac;
    // Feature the topmost face, keeping ~15% of the window as headroom above
    // it so hair/foreheads don't kiss the card edge.
    CGFloat windowTop = region.origin.y - 0.15 * visibleFrac;
    if (windowTop < 0.0) windowTop = 0.0;
    if (windowTop > hidden) windowTop = hidden;
    return windowTop / hidden;
}

// Main thread. Re-anchor every live node still showing `key` once its scan
// result is in.
static void ApolloLPRefineCropAnchorsForKey(NSString *key) {
    NSValue *region = [ApolloLPFaceRegionCache() objectForKey:key];
    if (!region) return;
    NSArray *nodes = nil;
    NSMapTable *table = ApolloLPCropRefinementNodes();
    @synchronized (table) {
        NSHashTable *set = [table objectForKey:key];
        nodes = set.allObjects;
        if (set && set.count == 0) [table removeObjectForKey:key];
    }
    for (ASNetworkImageNode *node in nodes) {
        NSDictionary *context = objc_getAssociatedObject(node, &kApolloLinkPreviewCropContextKey);
        if (![context[@"url"] isEqualToString:key]) continue;
        CGFloat visibleFrac = [context[@"frac"] doubleValue];
        if (visibleFrac <= 0.0) continue; // geometry unknown — keep the default anchor
        CGFloat defaultAnchorY = [context[@"default"] doubleValue];
        ApolloLPSetCropAnchorY(node, ApolloLPCropAnchorYForFaceRegion([region CGRectValue], visibleFrac, defaultAnchorY), YES);
    }
}

static void ApolloLPStartFaceScanIfNeeded(NSString *key, UIImage *image, NSString *host) {
    if (key.length == 0 || !image) return;
    if ([ApolloLPFaceRegionCache() objectForKey:key]) return;
    // CGImage-less (CIImage/vector-backed), animated, rotated, or absurdly
    // large images would need coordinate gymnastics the detector can't repay —
    // settle on the top-crop default and don't rescan.
    CGImageRef cgImage = image.CGImage;
    if (!cgImage || image.images.count > 1 || image.imageOrientation != UIImageOrientationUp
        || (CGFloat)CGImageGetWidth(cgImage) * (CGFloat)CGImageGetHeight(cgImage) > 12000000.0) {
        [ApolloLPFaceRegionCache() setObject:[NSValue valueWithCGRect:CGRectNull] forKey:key];
        return;
    }
    NSMutableSet *pending = ApolloLPFaceScanPending();
    @synchronized (pending) {
        if ([pending containsObject:key]) return;
        [pending addObject:key];
    }
    (void)host;
    // Deliberately do NOT capture the UIImage: a fast scroll can queue many
    // scans, and blocks pinning full decoded bitmaps would hold megabytes
    // NSCache couldn't evict under pressure. Re-fetch from the fallback cache
    // at scan time instead — every kick path stores the image there first. If
    // it got evicted meanwhile, drop without caching a verdict so a later
    // arrival can re-kick.
    dispatch_async(ApolloLPFaceScanQueue(), ^{
        UIImage *scanUIImage = [ApolloLPFallbackImageCache() objectForKey:key];
        CGImageRef scanImage = scanUIImage.CGImage;
        if (!scanImage) {
            @synchronized (ApolloLPFaceScanPending()) { [ApolloLPFaceScanPending() removeObject:key]; }
            return;
        }
        // The cached object is normally the exact image the kick guards saw,
        // but re-check the unscannable cases in case it was replaced.
        if (scanUIImage.images.count > 1 || scanUIImage.imageOrientation != UIImageOrientationUp) {
            [ApolloLPFaceRegionCache() setObject:[NSValue valueWithCGRect:CGRectNull] forKey:key];
            @synchronized (ApolloLPFaceScanPending()) { [ApolloLPFaceScanPending() removeObject:key]; }
            return;
        }
        CGRect region = CGRectNull;
        @try {
            CGFloat width = (CGFloat)CGImageGetWidth(scanImage);
            CGFloat height = (CGFloat)CGImageGetHeight(scanImage);
            CIDetector *detector = ApolloLPFaceDetector();
            if (width >= 1.0 && height >= 1.0 && detector) {
                NSArray<CIFeature *> *features = [detector featuresInImage:[CIImage imageWithCGImage:scanImage]];
                for (CIFeature *feature in features) {
                    // CIDetector reports bottom-left-origin pixel rects;
                    // normalize into top-down unit coordinates.
                    CGRect bounds = feature.bounds;
                    CGRect normalized = CGRectMake(bounds.origin.x / width,
                                                   1.0 - (bounds.origin.y + bounds.size.height) / height,
                                                   bounds.size.width / width,
                                                   bounds.size.height / height);
                    region = CGRectIsNull(region) ? normalized : CGRectUnion(region, normalized);
                }
            }
        } @catch (NSException *exception) {
            region = CGRectNull;
        }
        [ApolloLPFaceRegionCache() setObject:[NSValue valueWithCGRect:region] forKey:key];
        @synchronized (pending) { [pending removeObject:key]; }
        dispatch_async(dispatch_get_main_queue(), ^{ ApolloLPRefineCropAnchorsForKey(key); });
    });
}

// Tap on every point where a real UIImage becomes observable for a node
// (Texture load noticed on a layout pass / 900ms recheck, fallback fetch
// applied). Only nodes a card builder marked as vertically cropped carry the
// context, so avatars and wide images never reach the detector.
static void ApolloLPMaybeKickFaceScanForNode(ASNetworkImageNode *imageNode, NSURL *imageURL, UIImage *image) {
    NSString *key = imageURL.absoluteString;
    if (key.length == 0) return;
    NSDictionary *context = objc_getAssociatedObject(imageNode, &kApolloLinkPreviewCropContextKey);
    if (![context[@"url"] isEqualToString:key]) return;
    // Only scan images with KNOWN tall geometry: with frac == 0 (size unknown)
    // a face region couldn't be applied anyway, and the pass that learns the
    // real size re-kicks with the image already in the fallback cache.
    if ([context[@"frac"] doubleValue] <= 0.0) return;
    // Never scan a stale previous-URL bitmap under this URL's cache key.
    if (!ApolloLPNodeImageBelongsToURL(imageNode, key)) return;
    ApolloLPStartFaceScanIfNeeded(key, image, ApolloLPHost(imageURL));
}

// Card-builder entry point (Texture background layout threads). boxRatio is
// the h:w ratio of the box the image aspect-fills. Decides whether the image
// is vertically cropped, sets the anchor (top, or face-refined when the scan
// already ran), registers the node for async refinement, and kicks the scan
// when a decoded image is already at hand.
static void ApolloLPApplyVerticalCropAnchor(ASNetworkImageNode *imageNode, ApolloLinkPreview *preview, CGFloat boxRatio, NSString *host) {
    if (!imageNode || boxRatio <= 0.0) return;
    if (![imageNode respondsToSelector:@selector(setCropRect:)]) return;
    NSString *key = imageNode.URL.absoluteString;
    if (key.length == 0) return;

    // Natural h:w — prefer the fetcher's metadata, fall back to any decoded
    // image we already hold (covers previews whose metadata lacks a size).
    CGFloat naturalRatio = 0.0;
    CGSize metaSize = preview.imageSize;
    if (metaSize.width > 1.0 && metaSize.height > 1.0) {
        naturalRatio = metaSize.height / metaSize.width;
    }
    UIImage *availableImage = ApolloLPNodeImageBelongsToURL(imageNode, key)
        ? imageNode.image
        : [ApolloLPFallbackImageCache() objectForKey:key];
    if (naturalRatio <= 0.0 && availableImage.size.width > 1.0 && availableImage.size.height > 1.0) {
        naturalRatio = availableImage.size.height / availableImage.size.width;
    }

    // Known geometry, no vertical crop (wide/matching images): keep Texture's
    // default centered crop and stop tracking the node for refinement.
    // (Atomic association: written here on Texture layout threads, read on
    // main by the refine/recheck paths — the nonatomic getter wouldn't retain
    // under the runtime's lock and could return a just-released dict.)
    if (naturalRatio > 0.0 && naturalRatio <= boxRatio * 1.02) {
        objc_setAssociatedObject(imageNode, &kApolloLinkPreviewCropContextKey, nil, OBJC_ASSOCIATION_COPY);
        ApolloLPSetCropAnchorY(imageNode, 0.5, NO);
        return;
    }

    // Vertically cropped image (or size still unknown — visibleFrac == 0,
    // where the centered default keeps the pre-V22 behavior until a real
    // size shows up on a later pass).
    CGFloat visibleFrac = naturalRatio > 0.0 ? boxRatio / naturalRatio : 0.0;
    CGFloat defaultAnchorY = naturalRatio > 0.0 ? ApolloLPDefaultCropAnchorY(naturalRatio) : 0.5;
    NSDictionary *context = @{ @"url": key, @"frac": @(visibleFrac), @"default": @(defaultAnchorY) };
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewCropContextKey, context, OBJC_ASSOCIATION_COPY);
    ApolloLPRegisterCropRefinementNode(key, imageNode);

    CGFloat anchorY = defaultAnchorY;
    NSValue *region = [ApolloLPFaceRegionCache() objectForKey:key];
    // A cache hit that is pointer-identical to this node's preserved
    // defaultImage during an A->B URL switch is A's bitmap filed under B
    // (the preserve-and-remember flow) — never feed that to the one-shot
    // face scan.
    BOOL imageTrusted = availableImage
        && (ApolloLPNodeImageBelongsToURL(imageNode, key) || availableImage != imageNode.defaultImage);
    if (region && visibleFrac > 0.0) {
        anchorY = ApolloLPCropAnchorYForFaceRegion([region CGRectValue], visibleFrac, defaultAnchorY);
    } else if (!region && imageTrusted && visibleFrac > 0.0) {
        ApolloLPStartFaceScanIfNeeded(key, availableImage, host);
    }
    ApolloLPSetCropAnchorY(imageNode, anchorY, NO);
}

static UIColor *ApolloLPBlendColor(UIColor *foreground, UIColor *background, CGFloat foregroundAlpha, UITraitCollection *traitCollection) {
    UIColor *resolvedForeground = ApolloLPResolvedColor(foreground, traitCollection);
    UIColor *resolvedBackground = ApolloLPResolvedColor(background, traitCollection);

    CGFloat fr = 0.0, fg = 0.0, fb = 0.0, fa = 1.0;
    CGFloat br = 0.0, bg = 0.0, bb = 0.0, ba = 1.0;
    if (![resolvedForeground getRed:&fr green:&fg blue:&fb alpha:&fa]) return background;
    if (![resolvedBackground getRed:&br green:&bg blue:&bb alpha:&ba]) return background;

    CGFloat alpha = MIN(MAX(foregroundAlpha * fa, 0.0), 1.0);
    return [UIColor colorWithRed:(fr * alpha) + (br * (1.0 - alpha))
                           green:(fg * alpha) + (bg * (1.0 - alpha))
                            blue:(fb * alpha) + (bb * (1.0 - alpha))
                           alpha:1.0];
}

// Resolves the user's free-form card color from the render-safe packed snapshot
// (sLinkPreviewCardColorPacked). Returns nil when no custom color is set
// ("Default"), in which case the card keeps the standard neutral background.
// Reads the volatile uint32 (atomic aligned load on arm64) — never the NSString
// global, which the settings UI reassigns on the main thread.
static UIColor *ApolloLPCustomCardColor(void) {
    uint32_t packed = sLinkPreviewCardColorPacked;
    if ((packed & (1u << 24)) == 0) return nil;
    CGFloat r = ((packed >> 16) & 0xFF) / 255.0;
    CGFloat g = ((packed >> 8) & 0xFF) / 255.0;
    CGFloat b = (packed & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

// When a custom card color is active, fills primary/secondary text colors that
// contrast with it (black-on-light / white-on-dark). Returns NO for the default
// neutral card so callers keep the dynamic system label colors.
static BOOL ApolloLPCustomCardTextColors(UIColor **primaryOut, UIColor **secondaryOut) {
    UIColor *card = ApolloLPCustomCardColor();
    if (!card) return NO;
    BOOL light = ApolloColorIsLight(card);
    UIColor *primary = light ? [UIColor colorWithWhite:0.0 alpha:1.0] : [UIColor colorWithWhite:1.0 alpha:1.0];
    // Secondary text (site name, description) is the same ink at reduced opacity
    // so it reads as a softer tier without introducing a clashing hue.
    UIColor *secondary = [primary colorWithAlphaComponent:light ? 0.62 : 0.78];
    if (primaryOut) *primaryOut = primary;
    if (secondaryOut) *secondaryOut = secondary;
    return YES;
}

// Rewrites just the foreground color of an existing text node's attributed text,
// preserving its string + font. Lets a live card recolor instantly when the user
// changes the card color, without rebuilding the whole layout from the preview.
static void ApolloLPRecolorTextNode(ASTextNode *node, UIColor *color) {
    if (!node || !color || ![node respondsToSelector:@selector(attributedText)]) return;
    NSAttributedString *current = node.attributedText;
    if (current.length == 0) return;
    NSMutableAttributedString *mutableText = [current mutableCopy];
    [mutableText addAttribute:NSForegroundColorAttributeName value:color range:NSMakeRange(0, mutableText.length)];
    node.attributedText = mutableText;
}

static UIColor *ApolloLPCardBackgroundColorForNode(ASDisplayNode *hostNode, NSURL *url) {
    UIColor *custom = ApolloLPCustomCardColor();
    if (custom) {
        // Paint the card the exact picked color, identical in light/dark, so the
        // result matches the swatch the user chose (WYSIWYG). Text auto-contrasts.
        return custom;
    }

    // Default ("Neutral"): keep the original subtle, theme-aware card background.
    UIColor *tintColor = ApolloLinkPreviewPresetColor(ApolloLinkPreviewCardColorNeutral);

    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traitCollection) {
            BOOL dark = traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            UIColor *base = dark ? [UIColor secondarySystemBackgroundColor] : [UIColor systemBackgroundColor];
            return ApolloLPBlendColor(tintColor, base, dark ? 0.14 : 0.08, traitCollection);
        }];
    }

    return ApolloLPBlendColor(tintColor, [UIColor secondarySystemBackgroundColor], 0.12, UIScreen.mainScreen.traitCollection);
}

static void ApolloLPRegisterLinkPreviewNode(ASDisplayNode *node) {
    if (!node || !sApolloLPRegisteredLinkNodes || !sApolloLPRegisteredLinkNodesQueue) return;
    dispatch_async(sApolloLPRegisteredLinkNodesQueue, ^{
        [sApolloLPRegisteredLinkNodes addObject:node];
    });
}

static NSArray *ApolloLPRegisteredLinkPreviewNodesSnapshot(void) {
    if (!sApolloLPRegisteredLinkNodes || !sApolloLPRegisteredLinkNodesQueue) return @[];
    __block NSArray *snapshot = nil;
    dispatch_sync(sApolloLPRegisteredLinkNodesQueue, ^{
        snapshot = sApolloLPRegisteredLinkNodes.allObjects ?: @[];
    });
    return snapshot ?: @[];
}

// MARK: - V23: cross-node row reload for detached measurement trees
//
// Search results measure posts on cell-node trees that live off-window (and
// are pre-marked visible while detached, so interface-state transitions
// never fire again once the row actually scrolls on screen). The preview
// fetch + hero->compact shrink happen on such a tree, so the V20 pending
// mark lands on a node whose didEnterVisibleState never re-fires and both
// row reloads miss ("no-scroll-cell") — the row keeps its hero placeholder
// height around the small compact card. No node-side trigger is reliable
// here, so remember the miss per URL (main-thread only) and poll once per
// second while anything is pending: as soon as ANY registered same-URL
// LinkButtonNode is attached to a window — i.e. the broken row is actually
// on screen — fire the reload from that node, which can resolve its table
// and index path. Entries are one-shot and the poll stops when the map
// drains, so the steady-state cost is zero.
//
// Generous age cap: a user can sit on the results screen for minutes before
// scrolling down to a marked row. Reloading an already-correct same-URL row
// is harmless (it re-renders identically), so the cap is only a safety
// valve against reloads firing in some unrelated screen much later.
static const NSTimeInterval ApolloLPPendingCrossNodeReloadMaxAge = 900.0;

static NSMutableDictionary<NSString *, NSDate *> *ApolloLPPendingCrossNodeRowReloads(void) {
    static NSMutableDictionary<NSString *, NSDate *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static BOOL ApolloLPFireRowReloadFromAttachedNodesForURL(NSString *urlString, NSString *host) {
    if (urlString.length == 0) return NO;
    BOOL fired = NO;
    for (ASDisplayNode *node in ApolloLPRegisteredLinkPreviewNodesSnapshot()) {
        NSURL *nodeURL = objc_getAssociatedObject(node, &kApolloLinkPreviewURLKey);
        if (![nodeURL.absoluteString isEqualToString:urlString]) continue;
        BOOL loaded = [node respondsToSelector:@selector(isNodeLoaded)] && [node isNodeLoaded];
        UIView *view = loaded ? ApolloLPViewForNode(node) : nil;
        if (!view.window) continue; // only an on-screen tree can resolve its row's index path
        ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
        if (ApolloLPInvokeRowReloadIfPossible(cellNode ?: node, node, host)) {
            fired = YES;
        }
    }
    return fired;
}

static BOOL sApolloLPCrossNodeReloadPollScheduled = NO;

static void ApolloLPRunCrossNodeRowReloadPoll(void);

static void ApolloLPScheduleCrossNodeRowReloadPoll(void) {
    if (sApolloLPCrossNodeReloadPollScheduled) return;
    sApolloLPCrossNodeReloadPollScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        sApolloLPCrossNodeReloadPollScheduled = NO;
        ApolloLPRunCrossNodeRowReloadPoll();
    });
}

static void ApolloLPRunCrossNodeRowReloadPoll(void) {
    NSMutableDictionary<NSString *, NSDate *> *pending = ApolloLPPendingCrossNodeRowReloads();
    if (pending.count == 0) return;
    for (NSString *urlString in pending.allKeys) {
        NSDate *registered = pending[urlString];
        if (-[registered timeIntervalSinceNow] > ApolloLPPendingCrossNodeReloadMaxAge) {
            [pending removeObjectForKey:urlString];
            continue;
        }
        NSString *host = ApolloLPHost([NSURL URLWithString:urlString]);
        if (ApolloLPFireRowReloadFromAttachedNodesForURL(urlString, host)) {
            [pending removeObjectForKey:urlString];
        }
    }
    if (pending.count > 0) {
        ApolloLPScheduleCrossNodeRowReloadPoll();
    }
}

// Record a row-reload miss on `node`: keep the V20 per-node pending mark
// (same-instance re-fire from didEnterVisibleState, the feed case) and queue
// the V23 cross-instance reload keyed by the node's URL. Try to fire right
// away — when the preview resolves while the row is already on screen, the
// display tree is attached and the row heals immediately.
//
// V24: the map entry is armed even when the immediate fire reports success —
// a YES from the fire only means a reload was SCHEDULED, and its async body
// can still drop on the visibility guard. The poll drains the entry on the
// next fire (an extra reload of an already-correct row is harmless and
// documented as such above), so arming unconditionally trades one cheap
// reload for never losing the row.
static void ApolloLPNoteRowReloadMissForNode(ASDisplayNode *node, NSString *host) {
    if (!node) return;
    objc_setAssociatedObject(node, &kApolloLPPendingRowReloadHostKey, host ?: @"?", OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSURL *url = objc_getAssociatedObject(node, &kApolloLinkPreviewURLKey);
    NSString *urlString = url.absoluteString;
    if (urlString.length == 0) return;
    ApolloLPPendingCrossNodeRowReloads()[urlString] = [NSDate date];
    ApolloLPScheduleCrossNodeRowReloadPoll();
    if (ApolloLPFireRowReloadFromAttachedNodesForURL(urlString, host)) {
        ApolloLog(@"[LinkPreviews] V23-cross-node-row-reload host=%@", host ?: @"?");
    }
}

static void ApolloLPMarkNodeForColorRefresh(ASDisplayNode *node) {
    if (!node) return;
    @try {
        if ([node respondsToSelector:@selector(setNeedsDisplay)]) {
            [(id)node setNeedsDisplay];
        }
        if ([node respondsToSelector:@selector(setNeedsLayout)]) {
            [(id)node setNeedsLayout];
        }
        if ([node respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(node, @selector(invalidateCalculatedLayout));
        }
    } @catch (__unused NSException *exception) {
    }
}

static BOOL ApolloLPApplyCardBackgroundColor(ASDisplayNode *hostNode, ASDisplayNode *backgroundNode, NSURL *url, BOOL force) {
    if (!backgroundNode || ![backgroundNode respondsToSelector:@selector(setBackgroundColor:)]) return NO;

    NSNumber *currentToken = @((unsigned long)sLinkPreviewCardColorPacked);
    NSNumber *lastToken = objc_getAssociatedObject(backgroundNode, &kApolloLinkPreviewBackgroundColorPresetKey);
    BOOL presetChanged = ![lastToken isKindOfClass:[NSNumber class]] || ![lastToken isEqualToNumber:currentToken];
    if (!force && !presetChanged) return NO;

    backgroundNode.backgroundColor = ApolloLPCardBackgroundColorForNode(hostNode, url);
    objc_setAssociatedObject(backgroundNode, &kApolloLinkPreviewBackgroundColorPresetKey, currentToken, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLPMarkNodeForColorRefresh(backgroundNode);
    ApolloLPMarkNodeForColorRefresh(hostNode);
    return YES;
}

static NSString *ApolloLPBundleKey(NSURL *url, NSString *variant) {
    return [NSString stringWithFormat:@"%@|%@", url.absoluteString ?: @"", variant ?: @"default"];
}

static NSDictionary *ApolloLPNodeBundleForHostUnlocked(ASDisplayNode *hostNode, NSURL *url, NSString *variant) {
    ApolloLPRegisterLinkPreviewNode(hostNode);

    NSMutableDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey);
    if (!bundles) {
        bundles = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey, bundles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *key = ApolloLPBundleKey(url, variant);
    NSDictionary *bundle = bundles[key];
    if (bundle) return bundle;

    Class imageNodeClass = ApolloLPClass(@"ASNetworkImageNode");
    Class textNodeClass = ApolloLPClass(@"ASTextNode");
    Class displayNodeClass = ApolloLPClass(@"ASDisplayNode");
    if (!imageNodeClass || !textNodeClass || !displayNodeClass) return nil;

    ASNetworkImageNode *imageNode = [[imageNodeClass alloc] init];
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.clipsToBounds = YES;
    imageNode.cornerRadius = 8.0;
    imageNode.placeholderEnabled = YES;
    imageNode.placeholderColor = [UIColor tertiarySystemFillColor];

    ASNetworkImageNode *avatarNode = [[imageNodeClass alloc] init];
    avatarNode.contentMode = UIViewContentModeScaleAspectFill;
    avatarNode.clipsToBounds = YES;
    avatarNode.cornerRadius = 18.0;
    avatarNode.placeholderEnabled = YES;
    avatarNode.placeholderColor = [UIColor tertiarySystemFillColor];

    ASTextNode *siteNode = [[textNodeClass alloc] init];
    ASTextNode *titleNode = [[textNodeClass alloc] init];
    ASTextNode *descriptionNode = [[textNodeClass alloc] init];
    siteNode.maximumNumberOfLines = 1;
    titleNode.maximumNumberOfLines = 3;
    descriptionNode.maximumNumberOfLines = 4;
    siteNode.truncationMode = NSLineBreakByTruncatingTail;
    titleNode.truncationMode = NSLineBreakByTruncatingTail;
    descriptionNode.truncationMode = NSLineBreakByTruncatingTail;
    siteNode.userInteractionEnabled = NO;
    titleNode.userInteractionEnabled = NO;
    descriptionNode.userInteractionEnabled = NO;

    ASDisplayNode *backgroundNode = [[displayNodeClass alloc] init];
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, YES);
    backgroundNode.cornerRadius = 12.0;
    backgroundNode.clipsToBounds = YES;

    [hostNode addSubnode:backgroundNode];
    [hostNode addSubnode:imageNode];
    [hostNode addSubnode:avatarNode];
    [hostNode addSubnode:siteNode];
    [hostNode addSubnode:titleNode];
    [hostNode addSubnode:descriptionNode];

    bundle = @{
        @"image": imageNode,
        @"avatar": avatarNode,
        @"site": siteNode,
        @"title": titleNode,
        @"description": descriptionNode,
        @"background": backgroundNode,
        @"url": url,
    };
    bundles[key] = bundle;
    return bundle;
}

// The bundle map is written from Texture measurement queues and read from the
// main-thread preload/theme paths. Use the host node itself as the single lock
// for every map access. Holding it through bundle construction also prevents two
// concurrent measurements from creating and attaching duplicate node bundles.
static NSDictionary *ApolloLPNodeBundleForHost(ASDisplayNode *hostNode, NSURL *url, NSString *variant) {
    if (!hostNode) return nil;
    @synchronized (hostNode) {
        return ApolloLPNodeBundleForHostUnlocked(hostNode, url, variant);
    }
}

static NSArray<NSDictionary *> *ApolloLPNodeBundlesSnapshot(ASDisplayNode *hostNode) {
    if (!hostNode) return @[];
    @synchronized (hostNode) {
        NSDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(hostNode, &kApolloLinkPreviewNodesKey);
        if (![bundles isKindOfClass:[NSDictionary class]]) return @[];
        return [bundles.allValues copy];
    }
}

static NSAttributedString *ApolloLPAttributedString(NSString *string, UIFont *font, UIColor *color) {
    if (string.length == 0) return nil;
    string = [[string stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (string.length == 0) return nil;
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style,
    };
    return [[NSAttributedString alloc] initWithString:string attributes:attrs];
}

static BOOL ApolloLPSetTextNodeAttributedTextIfChanged(ASTextNode *textNode, NSAttributedString *attributedText) {
    if (!textNode) return NO;
    NSAttributedString *current = textNode.attributedText;
    BOOL unchanged = (!current && !attributedText) || (current && attributedText && [current isEqualToAttributedString:attributedText]);
    if (unchanged) return NO;
    textNode.attributedText = attributedText;
    return YES;
}

// Regexes compiled once — NSRegularExpression is immutable and thread-safe.
// Compiling them per clean call was the hottest allocation in the card render
// path: several cleans per measure, several measures per card, per scroll.
static NSRegularExpression *ApolloLPTagRegex(void) {
    static NSRegularExpression *r; static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil]; });
    return r;
}
static NSRegularExpression *ApolloLPWhitespaceRunRegex(void) {
    static NSRegularExpression *r; static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil]; });
    return r;
}
static NSRegularExpression *ApolloLPInlineWhitespaceRegex(void) {
    static NSRegularExpression *r; static dispatch_once_t once;
    // \x0B (vertical tab), NOT \v: in ICU regex \v is a class shorthand for
    // ALL vertical whitespace including \n — it silently ate the very line
    // breaks the multiline variant exists to preserve.
    dispatch_once(&once, ^{ r = [NSRegularExpression regularExpressionWithPattern:@"[\\t\\f\\x0B ]+" options:0 error:nil]; });
    return r;
}
static NSRegularExpression *ApolloLPBlankRunRegex(void) {
    static NSRegularExpression *r; static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [NSRegularExpression regularExpressionWithPattern:@"\\n{3,}" options:0 error:nil]; });
    return r;
}

// Cleaned-text memo: the SAME titles/descriptions are re-cleaned on every
// measure of every card (and again by the render-signature path). Keyed by
// the source string with an "s|"/"m|" prefix so the single-line and multiline
// variants of the same source never collide. NSCache: thread-safe + bounded.
static NSCache<NSString *, NSString *> *ApolloLPCleanMemo(void) {
    static NSCache *c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSCache new]; c.countLimit = 512; });
    return c;
}

static NSString *ApolloLPCleanDisplayText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return text;
    NSString *memoKey = [@"s|" stringByAppendingString:text];
    NSString *memo = [ApolloLPCleanMemo() objectForKey:memoKey];
    if (memo) return memo;
    // Decode HTML entities FIRST (named + numeric, incl. « » ° €) — the fetcher
    // decodes freshly-stored metadata, but cached and *translated* card text reach
    // this render choke point raw and would otherwise show literal "&laquo;".
    // Decoding before tag-stripping also lets an encoded "&lt;b&gt;" collapse out.
    NSString *clean = ApolloLinkPreviewDecodeEntities(text) ?: text;
    clean = [ApolloLPTagRegex() stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    clean = [ApolloLPWhitespaceRunRegex() stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *result = clean.length > 0 ? clean : text;
    [ApolloLPCleanMemo() setObject:result forKey:memoKey];
    return result;
}

// Like ApolloLPCleanDisplayText, but preserves the text's line structure —
// used for the Bluesky post body, where paragraph breaks are part of the
// post (the fetcher already normalized them). Collapsing \s+ would squish
// a multi-paragraph post into one run-on blob.
static NSString *ApolloLPCleanMultilineDisplayText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return text;
    NSString *memoKey = [@"m|" stringByAppendingString:text];
    NSString *memo = [ApolloLPCleanMemo() objectForKey:memoKey];
    if (memo) return memo;
    // Decode entities first (see ApolloLPCleanDisplayText) — keeps numeric/named
    // entities out of cached/translated multiline bodies (e.g. Bluesky posts).
    NSString *clean = ApolloLinkPreviewDecodeEntities(text) ?: text;
    clean = [ApolloLPTagRegex() stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    clean = [ApolloLPInlineWhitespaceRegex() stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    clean = [ApolloLPBlankRunRegex() stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@"\n\n"];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *result = clean.length > 0 ? clean : text;
    [ApolloLPCleanMemo() setObject:result forKey:memoKey];
    return result;
}

static NSString *ApolloLPDisplayTitleForPreview(ApolloLinkPreview *preview) {
    NSString *clean = ApolloLPCleanDisplayText(preview.title);

    // Some pages (single-page apps like fifa.com match-center URLs) only expose
    // a numeric-ID <title> ("285023 289273 400021448"), which renders as a
    // meaningless series of numbers in the card. Substitute a clean website
    // name derived from the source — the eyebrow still shows the full domain.
    if (ApolloIsJunkNumericTitle(clean)) {
        NSString *site = preview.siteName;
        NSString *name = nil;
        if (site.length > 0 && [site containsString:@"."] && ![site containsString:@" "]) {
            // Host-like siteName ("fifa.com") -> "FIFA".
            name = ApolloWebsiteNameFromHost(site);
        } else if (site.length > 0 && !ApolloIsJunkNumericTitle(site)) {
            // Already a presentable name (og:site_name / curated, e.g. "YouTube").
            name = site;
        }
        if (name.length > 0) {
            return name;
        }
    }

    return clean;
}

static NSString *ApolloLPDisplayDescriptionForPreview(ApolloLinkPreview *preview) {
    return ApolloLPCleanDisplayText(preview.desc);
}

static NSURL *ApolloLPRepairedImageURLForPreviewURL(NSURL *previewURL, NSURL *imageURL) {
    if (!imageURL) return nil;
    NSString *previewHost = ApolloLPHost(previewURL);
    if (![previewHost isEqualToString:@"balackburn.github.io"]) return imageURL;

    NSString *absolute = imageURL.absoluteString ?: @"";
    NSString *badPrefix = @"https://balackburn.github.io/images/";
    if (![absolute hasPrefix:badPrefix]) return imageURL;

    NSString *fileName = [absolute substringFromIndex:badPrefix.length];
    return [NSURL URLWithString:[@"https://balackburn.github.io/Apollo/images/" stringByAppendingString:fileName]] ?: imageURL;
}

static void ApolloLPApplyStyleSize(id style, CGSize size) {
    if (!style) return;
    @try {
        [style setValue:[NSValue valueWithCGSize:size] forKey:@"preferredSize"];
    } @catch (__unused NSException *exception) {
    }
}

static void ApolloLPClearStyleSize(id style) {
    if (!style) return;
    @try {
        [style setValue:nil forKey:@"preferredSize"];
    } @catch (__unused NSException *exception) {
        ApolloLPApplyStyleSize(style, CGSizeZero);
    }
}

static void ApolloLPResetStyle(id style) {
    if (!style) return;
    ApolloLPClearStyleSize(style);
    @try {
        [style setValue:@0.0 forKey:@"flexGrow"];
        [style setValue:@0.0 forKey:@"flexShrink"];
    } @catch (__unused NSException *exception) {
    }
}

static void ApolloLPResetTextNode(ASTextNode *textNode, NSUInteger maximumLines) {
    if (!textNode) return;
    textNode.maximumNumberOfLines = maximumLines;
    textNode.truncationMode = NSLineBreakByTruncatingTail;
    textNode.userInteractionEnabled = NO;
    textNode.backgroundColor = [UIColor clearColor];
    textNode.clipsToBounds = NO;
    // Clear placeholder-only skeleton bar styling/a11y suppression so the real
    // text rendered by the final spec is unaffected by any prior placeholder
    // pass on the same recycled node.
    textNode.cornerRadius = 0.0;
    textNode.isAccessibilityElement = YES;
}

static void ApolloLPClearHostShell(ASDisplayNode *node) {
    if (!node) return;

    NSDictionary *original = objc_getAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey);
    if (!original) {
        original = @{
            @"background": node.backgroundColor ?: [NSNull null],
            @"cornerRadius": @(node.cornerRadius),
            @"clipsToBounds": @(node.clipsToBounds),
            @"borderWidth": @(node.borderWidth),
            @"borderColor": node.borderColor ? (__bridge id)node.borderColor : [NSNull null],
            @"shadowOpacity": @(node.shadowOpacity),
            @"shadowRadius": @(node.shadowRadius),
        };
        objc_setAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    node.backgroundColor = [UIColor clearColor];
    node.cornerRadius = 0.0;
    node.clipsToBounds = NO;
    node.borderWidth = 0.0;
    node.borderColor = nil;
    node.shadowOpacity = 0.0;
    node.shadowRadius = 0.0;
}

static void ApolloLPRestoreHostShell(ASDisplayNode *node) {
    if (!node) return;
    NSDictionary *original = objc_getAssociatedObject(node, &kApolloLinkPreviewOriginalHostShellKey);
    if (!original) return;

    id background = original[@"background"];
    node.backgroundColor = [background isKindOfClass:[NSNull class]] ? nil : background;
    node.cornerRadius = [original[@"cornerRadius"] doubleValue];
    node.clipsToBounds = [original[@"clipsToBounds"] boolValue];
    node.borderWidth = [original[@"borderWidth"] doubleValue];
    id borderColor = original[@"borderColor"];
    node.borderColor = [borderColor isKindOfClass:[NSNull class]] ? nil : (__bridge CGColorRef)borderColor;
    node.shadowOpacity = [original[@"shadowOpacity"] floatValue];
    node.shadowRadius = [original[@"shadowRadius"] doubleValue];
}

typedef NS_ENUM(NSUInteger, ApolloLPContext) {
    ApolloLPContextCompact = 0,
    ApolloLPContextSelfText = 1,
};

typedef NS_ENUM(NSUInteger, ApolloLPArea) {
    ApolloLPAreaBody = 0,
    ApolloLPAreaComments = 1,
};

static BOOL ApolloLPIsYouTubeURL(NSURL *url);

static NSString * const ApolloLinkPreviewDidCacheNotification = @"ApolloLinkPreviewDidCacheNotification";

static NSInteger ApolloLPModeForArea(ApolloLPArea area) {
    return (area == ApolloLPAreaComments) ? sLinkPreviewCommentsMode : sLinkPreviewBodyMode;
}

static BOOL ApolloLPAllModesDisabled(void) {
    return sLinkPreviewBodyMode == ApolloLinkPreviewModeOff &&
        sLinkPreviewCommentsMode == ApolloLinkPreviewModeOff;
}

static ApolloLPContext ApolloLPContextForMode(NSInteger mode, ApolloLinkPreview *preview) {
    if (mode == ApolloLinkPreviewModeCompact) return ApolloLPContextCompact;
    if (preview.imageIsFallbackIcon) return ApolloLPContextCompact;
    if (preview.imageURL.absoluteString.length == 0) return ApolloLPContextCompact;
    return ApolloLPContextSelfText;
}

static NSMutableSet<NSString *> *ApolloLPCompactPlaceholderHosts(void) {
    static NSMutableSet<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = [NSMutableSet setWithArray:@[
            @"amctheatres.com",
            @"doi.org",
            @"journals.sagepub.com",
            @"nature.com",
            @"news18.com",
            @"nuvioapp.space",
            @"piie.com",
            @"zerozero.pt"
        ]];
    });
    return hosts;
}

static BOOL ApolloLPShouldUseCompactPlaceholder(NSURL *url) {
    NSString *host = ApolloLPHost(url);
    if (host.length == 0) return NO;

    @synchronized (ApolloLPCompactPlaceholderHosts()) {
        if ([ApolloLPCompactPlaceholderHosts() containsObject:host]) return YES;
        for (NSString *knownHost in ApolloLPCompactPlaceholderHosts()) {
            if ([host hasSuffix:[@"." stringByAppendingString:knownHost]]) return YES;
        }
    }
    return NO;
}

static void ApolloLPRememberCompactPlaceholderHost(NSURL *url) {
    NSString *host = ApolloLPHost(url);
    if (host.length == 0) return;

    @synchronized (ApolloLPCompactPlaceholderHosts()) {
        [ApolloLPCompactPlaceholderHosts() addObject:host];
    }
}

static id ApolloLPModelFromNodeIvar(ASDisplayNode *node, const char *ivarName) {
    if (!node || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([node class], ivarName);
    if (!ivar) return nil;

    id model = nil;
    @try {
        model = object_getIvar(node, ivar);
    } @catch (__unused NSException *exception) {
    }
    return model;
}

// Positive class-based detection of the owning cell, by user-facing area.
// The two areas map to Apollo's two data models (see ApolloInlineImages.xm:
// CommentCellNode holds an RDKComment via a `comment` ivar; the header and
// feed post cells hold an RDKLink via a `link` ivar):
//
//   Comments area (`Rich Link Previews - Comments`):
//     _TtC6Apollo15CommentCellNode       — a reply in the comment list.
//
//   Body area (`Rich Link Previews - Body`, "feeds and post bodies"):
//     _TtC6Apollo22CommentsHeaderCellNode — OP selftext shown above the
//        comment list. This is the *post body*, so it follows the Body
//        setting (issue #318 — previously mis-mapped to comments).
//     _TtC6Apollo17LargePostCellNode      — feed post cell (large).
//     _TtC6Apollo19CompactPostCellNode    — feed post cell (compact).
//
// The walk below resolves whichever signal is *nearest* the link button, and
// falls back to the `comment`/`link` ivar as suspenders when a cell class is
// renamed in a future Apollo build.
static Class ApolloLPCommentCellClass(void) {
    static Class cls; static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo15CommentCellNode"); });
    return cls;
}
static Class ApolloLPCommentsHeaderCellClass(void) {
    static Class cls; static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo22CommentsHeaderCellNode"); });
    return cls;
}
static Class ApolloLPLargePostCellClass(void) {
    static Class cls; static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo17LargePostCellNode"); });
    return cls;
}
static Class ApolloLPCompactPostCellClass(void) {
    static Class cls; static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("_TtC6Apollo19CompactPostCellNode"); });
    return cls;
}

// Walk supernodes; returns YES on positive detection via known cell class or
// `comment` ivar. *outArea receives the resolved area; *outDepth receives the
// number of supernodes walked (diagnostic — short chains indicate detached
// measurement, the root cause of the vote-time compact→hero flip).
static BOOL ApolloLPResolveAreaByWalk(ASDisplayNode *linkButtonNode, ApolloLPArea *outArea, NSUInteger *outDepth) {
    NSUInteger depth = 0;
    Class commentCellCls = ApolloLPCommentCellClass();
    Class headerCellCls = ApolloLPCommentsHeaderCellClass();
    Class largePostCellCls = ApolloLPLargePostCellClass();
    Class compactPostCellCls = ApolloLPCompactPostCellClass();
    // Nearest-ancestor wins: the first node carrying any positive signal
    // decides the area. Within a node, Comments signals are checked before
    // Body signals so a comment cell that also references its parent post
    // still resolves to comments.
    for (ASDisplayNode *node = linkButtonNode; node; node = node.supernode) {
        depth++;
        Class cls = [node class];

        // --- Comments signals (RDKComment) ---
        if (commentCellCls && cls == commentCellCls) {
            if (outArea) *outArea = ApolloLPAreaComments;
            if (outDepth) *outDepth = depth;
            return YES;
        }
        if (ApolloLPModelFromNodeIvar(node, "comment")) {
            if (outArea) *outArea = ApolloLPAreaComments;
            if (outDepth) *outDepth = depth;
            return YES;
        }

        // --- Body signals (RDKLink): OP selftext header + feed post cells ---
        if ((headerCellCls && cls == headerCellCls) ||
            (largePostCellCls && cls == largePostCellCls) ||
            (compactPostCellCls && cls == compactPostCellCls)) {
            if (outArea) *outArea = ApolloLPAreaBody;
            if (outDepth) *outDepth = depth;
            return YES;
        }
        if (ApolloLPModelFromNodeIvar(node, "link")) {
            if (outArea) *outArea = ApolloLPAreaBody;
            if (outDepth) *outDepth = depth;
            return YES;
        }
    }
    if (outDepth) *outDepth = depth;
    return NO;
}

static BOOL ApolloLPResolveAreaByWalk(ASDisplayNode *linkButtonNode, ApolloLPArea *outArea, NSUInteger *outDepth);
static ASDisplayNode *ApolloLPEnclosingCellNode(ASDisplayNode *node);

static ApolloLPArea ApolloLPAreaForLinkButton(ASDisplayNode *linkButtonNode) {
    NSNumber *cachedArea = objc_getAssociatedObject(linkButtonNode, &kApolloLinkPreviewAreaKey);
    if ([cachedArea isKindOfClass:[NSNumber class]]) {
        return (ApolloLPArea)cachedArea.unsignedIntegerValue;
    }

    ApolloLPArea resolved = ApolloLPAreaBody;
    NSUInteger depth = 0;
    if (ApolloLPResolveAreaByWalk(linkButtonNode, &resolved, &depth)) {
        // Positive detection: cache forever. The mode-change refresh path
        // does not rely on this cache being invalidated — it re-runs layout,
        // and the cached area still correctly feeds ApolloLPModeForArea.
        objc_setAssociatedObject(linkButtonNode, &kApolloLinkPreviewAreaKey, @(resolved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return resolved;
    }
    // Negative outcome: linkButtonNode is detached during this background
    // measurement pass. Apollo recreates the comment cell on vote/etc, and
    // Texture measures the new link button on a background thread before its
    // supernode chain is wired up. This wrong measurement gets cached by
    // Texture as `calculatedLayout` and shown until a full redisplay event
    // (screenshot, page reentry) forces re-measure. Pull-to-refresh does NOT
    // fix it because the cell's constrainedSize is unchanged.
    //
    // Mitigation: pick whichever area yields the *smaller* preview as the
    // fallback. If the wrong area was guessed, the cached layout is at worst
    // an undersized card — never overflows neighbors. Then schedule a
    // deferred re-resolve that, if the resolved mode differs from the
    // fallback mode, invalidates the *enclosing cell's* layout (link-button
    // setNeedsLayout alone doesn't propagate enough to force Texture to drop
    // the cached spec).
    ApolloLPArea fallbackArea = (sLinkPreviewCommentsMode != ApolloLinkPreviewModeOff &&
                                 sLinkPreviewCommentsMode < sLinkPreviewBodyMode)
                                ? ApolloLPAreaComments
                                : ApolloLPAreaBody;

    __weak ASDisplayNode *weakNode = linkButtonNode;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (!strongNode) return;
        NSNumber *existing = objc_getAssociatedObject(strongNode, &kApolloLinkPreviewAreaKey);
        if ([existing isKindOfClass:[NSNumber class]]) return;
        ApolloLPArea deferredArea = ApolloLPAreaBody;
        if (!ApolloLPResolveAreaByWalk(strongNode, &deferredArea, NULL)) return;
        objc_setAssociatedObject(strongNode, &kApolloLinkPreviewAreaKey, @(deferredArea), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSInteger fallbackMode = ApolloLPModeForArea(fallbackArea);
        NSInteger resolvedMode = ApolloLPModeForArea(deferredArea);
        if (fallbackMode == resolvedMode) return;

        // Force re-measure: invalidate both the link button and the
        // enclosing cell. Cell invalidation is what actually makes Texture
        // drop the cached spec and re-run layoutSpecThatFits on the row.
        if ([strongNode respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(strongNode, @selector(invalidateCalculatedLayout));
        }
        if ([strongNode respondsToSelector:@selector(setNeedsLayout)]) {
            [(id)strongNode setNeedsLayout];
        }
        ASDisplayNode *cell = ApolloLPEnclosingCellNode(strongNode);
        if (cell) {
            if ([cell respondsToSelector:@selector(invalidateCalculatedLayout)]) {
                ((void (*)(id, SEL))objc_msgSend)(cell, @selector(invalidateCalculatedLayout));
            }
            if ([cell respondsToSelector:@selector(setNeedsLayout)]) {
                [(id)cell setNeedsLayout];
            }
        }
    });
    return fallbackArea;
}

// Walk up from any ASDisplayNode to find an enclosing ASCellNode (the table's
// cell). Returns nil if none found. Used by the deferred re-resolve path to
// invalidate the *cell's* layout so the wrong cached spec is discarded.
static ASDisplayNode *ApolloLPEnclosingCellNode(ASDisplayNode *node) {
    static Class cellCls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cellCls = objc_getClass("ASCellNode"); });
    if (!cellCls) return nil;
    for (ASDisplayNode *cur = node; cur; cur = cur.supernode) {
        if ([cur isKindOfClass:cellCls]) return cur;
    }
    return nil;
}

// Pre-stamp a cell's link-button descendants with the correct area so the
// first background-thread measurement (which may race ahead of supernode
// chain attachment) sees the right area without walking. Called from the
// CommentCellNode / CommentsHeaderCellNode didLoad hooks below.
static void ApolloLPStampLinkButtonAreaInTree(ASDisplayNode *root, ApolloLPArea area) {
    if (!root) return;
    static Class linkButtonCls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ linkButtonCls = objc_getClass("_TtC6Apollo14LinkButtonNode"); });
    if (!linkButtonCls) return;
    if ([root isKindOfClass:linkButtonCls]) {
        NSNumber *existing = objc_getAssociatedObject(root, &kApolloLinkPreviewAreaKey);
        if (![existing isKindOfClass:[NSNumber class]]) {
            objc_setAssociatedObject(root, &kApolloLinkPreviewAreaKey, @(area), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    NSArray *subnodes = nil;
    @try { subnodes = [root respondsToSelector:@selector(subnodes)] ? [(id)root subnodes] : nil; }
    @catch (__unused NSException *e) { subnodes = nil; }
    for (ASDisplayNode *child in subnodes) {
        ApolloLPStampLinkButtonAreaInTree(child, area);
    }
}

// A link counts toward the "collapse multi-link comments to compact" threshold
// only if it would actually render a preview card: a valid http(s) URL that is
// not handed off to another renderer (inline media, ImageChest albums, Twitter).
// This mirrors the skip gates in LinkButtonNode.layoutSpecThatFits: so the count
// matches what the user will see. The check is URL-only (no metadata fetch
// dependency) so the count is stable across measurement passes and never causes
// a hero<->compact flip as previews load in.
static BOOL ApolloLPURLEligibleForPreviewCard(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) return NO;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    if (ApolloLPIsImageChestAlbumURL(url)) return NO;
    if (ApolloLPShouldDeferToInlineMedia(url)) return NO;
    if ([ApolloLinkPreviewFetcher isTwitterURL:url]) return NO;
    return YES;
}

// Count eligible preview links beneath a node (called on a comment cell).
// Mirrors the subnode walk in ApolloLPStampLinkButtonAreaInTree. Intentionally
// not cached: Texture reuses ASCellNode instances for different comments, so a
// per-cell cached count could leak across reuse. Comment trees are small, so a
// fresh walk at layout time is cheap and always correct.
static NSUInteger ApolloLPCountEligiblePreviewLinksInTree(ASDisplayNode *root) {
    if (!root) return 0;
    static Class linkButtonCls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ linkButtonCls = objc_getClass("_TtC6Apollo14LinkButtonNode"); });

    NSUInteger count = 0;
    if (linkButtonCls && [root isKindOfClass:linkButtonCls]) {
        NSString *urlString = ApolloGetLinkButtonNodeURLString(root);
        NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
        if (ApolloLPURLEligibleForPreviewCard(url)) count++;
    }
    NSArray *subnodes = nil;
    @try { subnodes = [root respondsToSelector:@selector(subnodes)] ? [(id)root subnodes] : nil; }
    @catch (__unused NSException *e) { subnodes = nil; }
    for (ASDisplayNode *child in subnodes) {
        count += ApolloLPCountEligiblePreviewLinksInTree(child);
    }
    return count;
}

static BOOL ApolloLPIsYouTubeURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if ([host hasPrefix:@"m."]) host = [host substringFromIndex:2];
    static NSArray<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[@"youtube.com", @"youtu.be", @"music.youtube.com"];
    });
    for (NSString *match in hosts) {
        if ([host isEqualToString:match] || [host hasSuffix:[@"." stringByAppendingString:match]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL ApolloLPIsRedditUserProfileURL(NSURL *url) {
    return ApolloLPRedditUsernameFromProfileURL(url).length > 0;
}

static NSString *ApolloLPRedditSubredditFromURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"reddit.com")) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part];
    }
    if (parts.count < 2) return nil;

    NSString *prefix = parts[0].lowercaseString;
    if (![prefix isEqualToString:@"r"]) return nil;
    for (NSString *part in parts) {
        if ([part.lowercaseString isEqualToString:@"comments"]) return nil;
    }

    NSString *subreddit = [parts[1] stringByRemovingPercentEncoding] ?: parts[1];
    subreddit = [subreddit stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return subreddit.length > 0 ? subreddit : nil;
}

static BOOL ApolloLPIsRedditSubredditURL(NSURL *url) {
    return ApolloLPRedditSubredditFromURL(url).length > 0;
}

static BOOL ApolloLPIsPosterPreviewURL(NSURL *url, ApolloLinkPreview *preview) {
    if (!url || !preview) return NO;

    NSString *host = url.host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    if ([host hasPrefix:@"m."]) host = [host substringFromIndex:2];

    static NSArray<NSString *> *posterHosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        posterHosts = @[
            @"anidb.net",
            @"anilist.co",
            @"anime-planet.com",
            @"boxofficemojo.com",
            @"fandango.com",
            @"imdb.com",
            @"justwatch.com",
            @"kitsu.app",
            @"letterboxd.com",
            @"livechart.me",
            @"metacritic.com",
            @"movieinsider.com",
            @"myanimelist.net",
            @"rottentomatoes.com",
            @"shikimori.one",
            @"the-numbers.com",
            @"themoviedb.org",
            @"trakt.tv"
        ];
    });

    BOOL knownPosterHost = NO;
    for (NSString *posterHost in posterHosts) {
        if ([host isEqualToString:posterHost] || [host hasSuffix:[@"." stringByAppendingString:posterHost]]) {
            knownPosterHost = YES;
            break;
        }
    }
    if (!knownPosterHost) return NO;

    CGSize imageSize = preview.imageSize;
    if (imageSize.width <= 1.0 || imageSize.height <= 1.0) return NO;
    return (imageSize.height / imageSize.width) >= 1.15;
}

static NSString *ApolloLPPlaceholderLines(NSUInteger lineCount, BOOL title) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:lineCount];
    NSString *longLine = title ? @"MMMMMMMMMMMMMMMMMMMM" : @"MMMMMMMMMMMMMMMMMMMMMMMM";
    NSString *shortLine = title ? @"MMMMMMMMMMMM" : @"MMMMMMMMMMMMMMMM";
    for (NSUInteger index = 0; index < lineCount; index++) {
        [lines addObject:index + 1 == lineCount ? shortLine : longLine];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSDictionary *ApolloLPPreparedNodeBundle(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPNodeBundleForHost(hostNode, url, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPResetStyle([imageNode style]);
    ApolloLPResetStyle([avatarNode style]);
    ApolloLPResetStyle([backgroundNode style]);
    ApolloLPResetTextNode(siteNode, 1);
    ApolloLPResetTextNode(titleNode, 3);
    ApolloLPResetTextNode(descriptionNode, 4);
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    NSString *siteName = preview.siteName.length > 0 ? ApolloLPCleanDisplayText(preview.siteName) : ApolloLPHost(url);
    NSURL *imageURL = ApolloLPRepairedImageURLForPreviewURL(url, preview.imageURL);
    ApolloLPSetNetworkImageURLPreservingImage(imageNode, imageURL);
    // Don't toggle backgroundColor per layout pass based on whether the
    // imageNode currently has a UIImage loaded. ASNetworkImageNode already
    // shows `placeholderColor` while loading (set once in
    // ApolloLPNodeBundleForHost), so re-flipping backgroundColor between
    // nil and gray on every layoutSpecThatFits: was a redundant paint
    // source that flickered when Texture briefly released the image
    // outside the display range.
    ApolloLPSetImageNodeBackgroundForURL(imageNode, imageURL);
    ApolloLPScheduleImageFallbackIfNeeded(imageNode, imageURL, ApolloLPHost(url));
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.clipsToBounds = YES;
    ApolloLPSetImageNodeBackgroundForURL(avatarNode, nil);
    avatarNode.contentMode = UIViewContentModeScaleAspectFill;
    avatarNode.clipsToBounds = YES;
    avatarNode.cornerRadius = 18.0;
    // On a custom-colored card, swap the dynamic system label colors for ink
    // that contrasts with the user's chosen fill; otherwise keep label colors.
    UIColor *titleColor = [UIColor labelColor];
    UIColor *secondaryColor = [UIColor secondaryLabelColor];
    ApolloLPCustomCardTextColors(&titleColor, &secondaryColor);
    ApolloLPSetTextNodeAttributedTextIfChanged(siteNode, ApolloLPAttributedString([siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], secondaryColor));
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(ApolloLPDisplayTitleForPreview(preview), [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], titleColor));
    ApolloLPSetTextNodeAttributedTextIfChanged(descriptionNode, ApolloLPAttributedString(ApolloLPDisplayDescriptionForPreview(preview), [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], secondaryColor));

    return bundle;
}

static id ApolloLPBackgroundWrappedSpec(id contentSpec, ASDisplayNode *backgroundNode, Class backgroundClass) {
    if (backgroundClass && [backgroundClass respondsToSelector:@selector(backgroundLayoutSpecWithChild:background:)]) {
        return [backgroundClass backgroundLayoutSpecWithChild:contentSpec background:backgroundNode];
    }
    return contentSpec;
}

static id ApolloLPMeasuredWrapper(id cardSpec, Class insetClass) {
    if (insetClass && [insetClass respondsToSelector:@selector(insetLayoutSpecWithInsets:child:)]) {
        return [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsZero child:cardSpec];
    }
    return cardSpec;
}

static NSUInteger ApolloLPCompactDescriptionLineCount(ApolloLinkPreview *preview) {
    NSUInteger titleLength = ApolloLPDisplayTitleForPreview(preview).length;
    if (titleLength >= 110) return 0;
    if (titleLength >= 70) return 1;
    return 2;
}

static id ApolloLPBuildCompactCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPSetAvatarNodeVisible(avatarNode, NO);

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    imageNode.cornerRadius = 8.0;
    NSUInteger descriptionLineCount = ApolloLPCompactDescriptionLineCount(preview);
    titleNode.maximumNumberOfLines = 2;
    descriptionNode.maximumNumberOfLines = descriptionLineCount;
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    NSMutableArray *textChildren = [NSMutableArray array];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (descriptionLineCount > 0 && descriptionNode.attributedText.length > 0) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:3.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];

    NSMutableArray *rowChildren = [NSMutableArray array];
    // Dead-marked images (V21) render text-only — an 84pt square that will
    // never load is just a blank box next to the title.
    if (preview.imageURL.absoluteString.length > 0 && !ApolloLPImageURLIsDead(preview.imageURL)) {
        imageNode.contentMode = UIViewContentModeScaleAspectFill;
        imageNode.cornerRadius = 8.0;
        ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
        // V22: the square thumb shows h:w = 1.0 of the image; anchor tall
        // images to the top / detected face instead of the centered crop.
        ApolloLPApplyVerticalCropAnchor(imageNode, preview, 1.0, ApolloLPHost(url));
        [rowChildren addObject:imageNode];
    }
    [rowChildren addObject:textStack];

    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsStart
                                                             children:rowChildren];
    ASInsetLayoutSpec *contentInset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row];
    id card = ApolloLPBackgroundWrappedSpec(contentInset, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static NSUInteger ApolloLPHeroDescriptionLineCount(ApolloLinkPreview *preview) {
    NSUInteger titleLength = ApolloLPDisplayTitleForPreview(preview).length;
    if (titleLength >= 120) return 0;
    return 1;
}

static id ApolloLPBuildHeroCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPSetAvatarNodeVisible(avatarNode, NO);

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    imageNode.cornerRadius = 10.0;
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    BOOL isYouTube = ApolloLPIsYouTubeURL(url);
    BOOL isPosterPreview = ApolloLPIsPosterPreviewURL(url, preview);
    NSUInteger descriptionLineCount = ApolloLPHeroDescriptionLineCount(preview);
    titleNode.maximumNumberOfLines = 2;
    descriptionNode.maximumNumberOfLines = descriptionLineCount;
    UIColor *heroTitleColor = [UIColor labelColor];
    ApolloLPCustomCardTextColors(&heroTitleColor, NULL);
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(ApolloLPDisplayTitleForPreview(preview), [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold], heroTitleColor));
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    NSMutableArray *textChildren = [NSMutableArray array];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (descriptionLineCount > 0 && descriptionNode.attributedText.length > 0) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    NSMutableArray *cardChildren = [NSMutableArray array];
    if (preview.imageURL.absoluteString.length > 0 && ratioClass) {
        // Cap the hero image at a 0.6 (5:3) ratio rather than the previous
        // 1.0 (square) cap. Square / portrait preview images (page
        // screenshots from archive.is, vertical news hero shots, etc.) were
        // producing ~360pt-tall image blocks at feed width which made the
        // whole card balloon and run off the screen. Wide images (16:9,
        // 4:3, 3:2) are untouched because the MIN keeps their natural
        // ratio; only tall ones are clamped down here. The card width is
        // already bounded by the enclosing cell, so this is sufficient to
        // bound total card height without needing a separate maxHeight on
        // ASLayoutElementStyle (which takes an ASDimension struct and
        // therefore can't be set via simple KVC).
        CGFloat ratio = 9.0 / 16.0;
        CGSize imageSize = preview.imageSize;
        if (!isYouTube && imageSize.width > 1.0 && imageSize.height > 1.0) {
            CGFloat naturalRatio = imageSize.height / imageSize.width;
            if (isPosterPreview) {
                imageNode.contentMode = UIViewContentModeScaleAspectFit;
                ratio = MAX(MIN(naturalRatio, 1.1), 0.6);
            } else {
                ratio = MAX(MIN(naturalRatio, 0.6), 0.45);
            }
        }

        if (!isPosterPreview) {
            // V22: poster hosts render aspect-fit (no crop); everything else
            // aspect-fills, so anchor tall images to the top / detected face.
            ApolloLPApplyVerticalCropAnchor(imageNode, preview, ratio, ApolloLPHost(url));
        }
        [cardChildren addObject:[ratioClass ratioLayoutSpecWithRatio:ratio child:imageNode]];
    }

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:4.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
    UIEdgeInsets textInsets = isYouTube ? UIEdgeInsetsMake(8.0, 12.0, 10.0, 12.0) : UIEdgeInsetsMake(9.0, 12.0, 11.0, 12.0);
    ASInsetLayoutSpec *paddedText = [insetClass insetLayoutSpecWithInsets:textInsets child:textStack];
    [cardChildren addObject:paddedText];

    ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:0.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:cardChildren];
    id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static BOOL ApolloLPIsBlueskyPostURL(NSURL *url) {
    if (!ApolloLPHostHasSuffix(url, @"bsky.app")) return NO;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length > 0) [parts addObject:part.lowercaseString];
    }
    return parts.count >= 4
        && [parts[0] isEqualToString:@"profile"]
        && [parts[2] isEqualToString:@"post"];
}

static BOOL ApolloLPIsBlueskyPostPreview(NSURL *url, ApolloLinkPreview *preview) {
    return ApolloLPIsBlueskyPostURL(url)
        && [preview.previewKind isEqualToString:@"bluesky-post-v2"]
        && (preview.postText.length > 0 || preview.authorDisplayName.length > 0 || preview.authorHandle.length > 0);
}

static NSString *ApolloLPBlueskyHandleText(ApolloLinkPreview *preview) {
    NSString *handle = preview.authorHandle;
    if (handle.length == 0) return @"Bluesky";
    return [handle hasPrefix:@"@"] ? handle : [@"@" stringByAppendingString:handle];
}

static id ApolloLPBuildBlueskyPostCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPSetAvatarNodeVisible(avatarNode, YES);

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    NSString *displayName = preview.authorDisplayName.length > 0 ? preview.authorDisplayName : (ApolloLPDisplayTitleForPreview(preview).length > 0 ? ApolloLPDisplayTitleForPreview(preview) : @"Bluesky");
    NSString *handleText = ApolloLPBlueskyHandleText(preview);
    // Keep the post's own paragraph breaks — squashing them reads terribly
    // for multi-line posts. Bluesky posts are capped at ~300 chars, so the
    // body is naturally bounded even without a line limit.
    NSString *postText = preview.postText.length > 0 ? ApolloLPCleanMultilineDisplayText(preview.postText) : ApolloLPCleanMultilineDisplayText(preview.desc);
    BOOL imageIsAvatar = preview.avatarURL.absoluteString.length > 0
        && [preview.imageURL.absoluteString isEqualToString:preview.avatarURL.absoluteString];
    BOOL hasPostImage = preview.imageURL.absoluteString.length > 0 && !imageIsAvatar && !preview.imageIsFallbackIcon;

    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    ApolloLPSetNetworkImageURLPreservingImage(imageNode, hasPostImage ? preview.imageURL : nil);
    // Bluesky cards use a clear (transparent) imageNode background even
    // when no post image is loaded, because the avatar column carries the
    // visible chrome. Set this once regardless of load state so we don't
    // flip-flop with the placeholder gray across layout passes.
    UIColor *targetImageBg = hasPostImage ? nil : [UIColor clearColor];
    if (![imageNode.backgroundColor isEqual:targetImageBg]
        && !(!imageNode.backgroundColor && !targetImageBg)) {
        imageNode.backgroundColor = targetImageBg;
    }
    if (hasPostImage) ApolloLPScheduleImageFallbackIfNeeded(imageNode, preview.imageURL, ApolloLPHost(url));
    imageNode.contentMode = UIViewContentModeScaleAspectFill;
    imageNode.cornerRadius = 10.0;
    imageNode.clipsToBounds = YES;

    ApolloLPSetNetworkImageURLPreservingImage(avatarNode, preview.avatarURL);
    ApolloLPSetImageNodeBackgroundForURL(avatarNode, preview.avatarURL);
    ApolloLPScheduleImageFallbackIfNeeded(avatarNode, preview.avatarURL, ApolloLPHost(url));
    avatarNode.cornerRadius = 18.0;
    avatarNode.clipsToBounds = YES;
    ApolloLPApplyStyleSize([avatarNode style], CGSizeMake(36.0, 36.0));

    titleNode.maximumNumberOfLines = 1;
    siteNode.maximumNumberOfLines = 1;
    // No line cap: let the card grow to fit the whole post, like the native
    // tweet card does.
    descriptionNode.maximumNumberOfLines = 0;
    // …but stay inside the height the feed cell actually allots the card. With
    // every card child unshrinkable, a finite max height (the media budget
    // shrinks as the post title takes more lines) made Texture CLAMP the card
    // background to the constraint while the description's frame kept its full
    // unbounded height — the text painted past the card over the info row.
    // Marking the description shrinkable lets the flex pass re-measure it under
    // the reduced height instead, so it tail-truncates inside an intact card;
    // when the card fits (the normal case) shrink never engages and nothing
    // changes. Re-asserted every build: the bundle's text-node styles persist
    // across passes.
    [[descriptionNode style] setValue:@1.0 forKey:@"flexShrink"];
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(displayName, [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(siteNode, ApolloLPAttributedString(handleText, [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(descriptionNode, ApolloLPAttributedString(postText, [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular], [UIColor labelColor]));

    ASStackLayoutSpec *authorTextStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                          spacing:1.0
                                                                   justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                       alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                         children:@[titleNode, siteNode]];
    [[authorTextStack style] setValue:@1.0 forKey:@"flexShrink"];

    ASStackLayoutSpec *authorRow = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                                    spacing:9.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsCenter
                                                                   children:@[avatarNode, authorTextStack]];
    // In the vertical contentStack this flexShrink is a HEIGHT shrink — leave
    // the avatar/name row fixed (default 0) so a height shortfall is absorbed
    // entirely by the description's line count, never by crushing the header.

    NSMutableArray *contentChildren = [NSMutableArray arrayWithObject:authorRow];
    if (descriptionNode.attributedText.length > 0) {
        [contentChildren addObject:descriptionNode];
    }

    ASStackLayoutSpec *contentStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                       spacing:9.0
                                                                justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                    alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                      children:contentChildren];
    [[contentStack style] setValue:@1.0 forKey:@"flexShrink"];

    NSMutableArray *cardChildren = [NSMutableArray array];
    if (hasPostImage && ratioClass) {
        CGFloat ratio = 9.0 / 16.0;
        CGSize imageSize = preview.imageSize;
        if (imageSize.width > 1.0 && imageSize.height > 1.0) {
            ratio = MAX(MIN(imageSize.height / imageSize.width, 0.75), 0.45);
        }
        // V22: anchor tall post images to the top / detected face so portrait
        // shots keep the head inside the clamped box.
        ApolloLPApplyVerticalCropAnchor(imageNode, preview, ratio, ApolloLPHost(url));
        [cardChildren addObject:[ratioClass ratioLayoutSpecWithRatio:ratio child:imageNode]];
    }
    ASInsetLayoutSpec *contentInset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(11.0, 12.0, 12.0, 12.0) child:contentStack];
    // Shrinkable so a card-level height violation propagates down through
    // contentStack to the description, instead of being clamped at the stack
    // boundary (a clamp reports the short height to Apollo's cell while the
    // sublayout frames keep their full size — the overflow-paint bug). The
    // image ratio spec stays fixed: the post image keeps its aspect, text
    // gives up lines.
    [[contentInset style] setValue:@1.0 forKey:@"flexShrink"];
    [cardChildren addObject:contentInset];

    ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:0.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:cardChildren];
    id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static BOOL ApolloLPIsRedditUserPreview(NSURL *url, ApolloLinkPreview *preview) {
    return ApolloLPIsRedditUserProfileURL(url)
        && [preview.previewKind isEqualToString:@"reddit-user-profile"]
        && (preview.title.length > 0 || preview.authorHandle.length > 0);
}

static NSString *ApolloLPRedditUserHandleText(ApolloLinkPreview *preview) {
    NSString *handle = preview.authorHandle.length > 0 ? preview.authorHandle : preview.title;
    if (handle.length == 0) return @"Reddit profile";
    return [handle hasPrefix:@"u/"] ? handle : [@"u/" stringByAppendingString:handle];
}

static BOOL ApolloLPShouldUseBannedUserPresentation(NSURL *url, ApolloLinkPreview *preview) {
    NSString *username = ApolloLPNormalizedRedditUsername(ApolloLPRedditUsernameFromProfileURL(url));
    if (username.length == 0 && preview.authorHandle.length > 0) {
        username = ApolloLPNormalizedRedditUsername(preview.authorHandle);
    }
    if (ApolloBannedProfileCachedIsSuspended(username)) return YES;
    return [preview.desc isEqualToString:ApolloBannedProfileBannedDescriptionText()];
}

static void ApolloLPApplyBannedUserAvatarIfNeeded(ASNetworkImageNode *avatarNode, NSURL *url, ApolloLinkPreview *preview) {
    if (!avatarNode || !ApolloLPShouldUseBannedUserPresentation(url, preview)) return;
    UIImage *icon = ApolloBannedProfileIconImage();
    if (!icon) return;
    avatarNode.URL = nil;
    avatarNode.image = icon;
    if ([avatarNode respondsToSelector:@selector(setDefaultImage:)]) {
        avatarNode.defaultImage = icon;
    }
    avatarNode.backgroundColor = nil;
}

static id ApolloLPBuildRedditUserCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPSetAvatarNodeVisible(avatarNode, YES);

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    NSString *handleText = ApolloLPRedditUserHandleText(preview);
    NSString *displayName = preview.authorDisplayName.length > 0 ? preview.authorDisplayName : (preview.title.length > 0 ? preview.title : handleText);
    BOOL isBannedUser = ApolloLPShouldUseBannedUserPresentation(url, preview);
    NSString *aboutText = isBannedUser ? ApolloBannedProfileBannedDescriptionText() : (preview.desc.length > 0 ? preview.desc : handleText);
    NSURL *avatarURL = isBannedUser ? nil : (preview.avatarURL ?: preview.imageURL);

    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    if (isBannedUser) {
        ApolloLPApplyBannedUserAvatarIfNeeded(avatarNode, url, preview);
    } else {
        ApolloLPSetNetworkImageURLPreservingImage(avatarNode, avatarURL);
        ApolloLPSetImageNodeBackgroundForURL(avatarNode, avatarURL);
        ApolloLPScheduleImageFallbackIfNeeded(avatarNode, avatarURL, ApolloLPHost(url));
    }
    avatarNode.contentMode = UIViewContentModeScaleAspectFill;
    avatarNode.cornerRadius = 22.0;
    avatarNode.clipsToBounds = YES;
    ApolloLPApplyStyleSize([avatarNode style], CGSizeMake(44.0, 44.0));

    siteNode.maximumNumberOfLines = 1;
    titleNode.maximumNumberOfLines = 1;
    descriptionNode.maximumNumberOfLines = 2;
    ApolloLPSetTextNodeAttributedTextIfChanged(siteNode, ApolloLPAttributedString(handleText, [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(displayName, [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(descriptionNode, ApolloLPAttributedString(aboutText, [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]));

    NSMutableArray *textChildren = [NSMutableArray array];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (descriptionNode.attributedText.length > 0 && ![aboutText isEqualToString:handleText]) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:2.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];

    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsCenter
                                                             children:@[avatarNode, textStack]];
    ASInsetLayoutSpec *contentInset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row];
    id card = ApolloLPBackgroundWrappedSpec(contentInset, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static BOOL ApolloLPIsRedditSubredditPreview(NSURL *url, ApolloLinkPreview *preview) {
    return ApolloLPIsRedditSubredditURL(url)
        && [preview.previewKind isEqualToString:@"reddit-subreddit"]
        && (preview.title.length > 0 || preview.authorHandle.length > 0);
}

static NSString *ApolloLPRedditSubredditHandleText(ApolloLinkPreview *preview) {
    NSString *handle = preview.authorHandle.length > 0 ? preview.authorHandle : preview.title;
    if (handle.length == 0) return @"Reddit community";
    NSString *normalized = [handle hasPrefix:@"r/"] ? handle : [@"r/" stringByAppendingString:handle];
    NSString *members = ApolloLPCleanDisplayText(preview.postText);
    if (members.length == 0) return normalized;
    return [NSString stringWithFormat:@"%@ · %@", normalized, members];
}

static id ApolloLPBuildRedditSubredditCardSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPSetAvatarNodeVisible(avatarNode, YES);

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    NSString *handleText = ApolloLPRedditSubredditHandleText(preview);
    NSString *displayName = preview.authorDisplayName.length > 0 ? preview.authorDisplayName : (preview.title.length > 0 ? preview.title : handleText);
    NSString *aboutText = preview.desc.length > 0 ? preview.desc : handleText;
    NSURL *avatarURL = preview.avatarURL ?: preview.imageURL;

    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;

    ApolloLPSetNetworkImageURLPreservingImage(avatarNode, avatarURL);
    ApolloLPSetImageNodeBackgroundForURL(avatarNode, avatarURL);
    ApolloLPScheduleImageFallbackIfNeeded(avatarNode, avatarURL, ApolloLPHost(url));
    avatarNode.contentMode = UIViewContentModeScaleAspectFill;
    avatarNode.cornerRadius = 22.0;
    avatarNode.clipsToBounds = YES;
    ApolloLPApplyStyleSize([avatarNode style], CGSizeMake(44.0, 44.0));

    siteNode.maximumNumberOfLines = 1;
    titleNode.maximumNumberOfLines = 1;
    descriptionNode.maximumNumberOfLines = 2;
    ApolloLPSetTextNodeAttributedTextIfChanged(siteNode, ApolloLPAttributedString(handleText, [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(displayName, [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(descriptionNode, ApolloLPAttributedString(aboutText, [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]));

    NSMutableArray *textChildren = [NSMutableArray array];
    if (titleNode.attributedText.length > 0) [textChildren addObject:titleNode];
    if (siteNode.attributedText.length > 0) [textChildren addObject:siteNode];
    if (descriptionNode.attributedText.length > 0 && ![aboutText isEqualToString:handleText]) [textChildren addObject:descriptionNode];
    if (textChildren.count == 0) return nil;

    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:2.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:textChildren];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];

    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsCenter
                                                             children:@[avatarNode, textStack]];
    ASInsetLayoutSpec *contentInset = [insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row];
    id card = ApolloLPBackgroundWrappedSpec(contentInset, backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

static id ApolloLPBuildPlaceholderSpec(ASDisplayNode *hostNode, NSURL *url, ApolloLPContext context, NSString *variant) {
    ApolloLinkPreview *preview = [ApolloLinkPreview new];
    preview.siteName = ApolloLPHost(url);
    preview.title = @" ";
    preview.desc = context == ApolloLPContextSelfText ? @" " : nil;

    NSDictionary *bundle = ApolloLPPreparedNodeBundle(hostNode, url, preview, variant);
    if (!bundle) return nil;

    ASNetworkImageNode *imageNode = bundle[@"image"];
    ASNetworkImageNode *avatarNode = bundle[@"avatar"];
    ASTextNode *siteNode = bundle[@"site"];
    ASTextNode *titleNode = bundle[@"title"];
    ASTextNode *descriptionNode = bundle[@"description"];
    ASDisplayNode *backgroundNode = bundle[@"background"];

    ApolloLPSetAvatarNodeVisible(avatarNode, NO);

    Class stackClass = ApolloLPClass(@"ASStackLayoutSpec");
    Class insetClass = ApolloLPClass(@"ASInsetLayoutSpec");
    Class ratioClass = ApolloLPClass(@"ASRatioLayoutSpec");
    Class backgroundClass = ApolloLPClass(@"ASBackgroundLayoutSpec");
    if (!stackClass || !insetClass) return nil;

    UIColor *placeholder = [UIColor tertiarySystemFillColor];
    ApolloLPSetNetworkImageURLPreservingImage(imageNode, nil);
    ApolloLPSetImageNodeBackgroundForURL(imageNode, nil);
    imageNode.cornerRadius = context == ApolloLPContextSelfText ? 10.0 : 8.0;
    NSUInteger titleLines = context == ApolloLPContextSelfText ? 2 : 1;
    NSUInteger descriptionLines = context == ApolloLPContextSelfText ? 1 : 2;
    titleNode.maximumNumberOfLines = titleLines;
    descriptionNode.maximumNumberOfLines = context == ApolloLPContextSelfText ? descriptionLines : 1;
    ApolloLPSetTextNodeAttributedTextIfChanged(siteNode, ApolloLPAttributedString([preview.siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], [UIColor secondaryLabelColor]));
    // Render the placeholder Ms with clearColor text so they act as an
    // invisible width hint, then paint the text node backgroundColor with
    // the placeholder gray so each row appears as a solid skeleton bar.
    // Without this, the Ms render as visible gray text characters because
    // ASTextNode's backgroundColor defaults to clear and only the foreground
    // glyphs get drawn in `tertiarySystemFillColor`.
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(ApolloLPPlaceholderLines(titleLines, YES), context == ApolloLPContextSelfText ? [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor clearColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(descriptionNode, ApolloLPAttributedString(ApolloLPPlaceholderLines(descriptionLines, NO), [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor clearColor]));
    titleNode.backgroundColor = placeholder;
    titleNode.cornerRadius = 3.0;
    titleNode.clipsToBounds = YES;
    descriptionNode.backgroundColor = placeholder;
    descriptionNode.cornerRadius = 3.0;
    descriptionNode.clipsToBounds = YES;
    // Hide the placeholder Ms from VoiceOver / Translate / accessibility
    // tools so they don't read "M M M M..." while metadata is loading.
    titleNode.isAccessibilityElement = NO;
    descriptionNode.isAccessibilityElement = NO;

    if (context == ApolloLPContextSelfText && ratioClass) {
        NSMutableArray *children = [NSMutableArray array];
        [children addObject:[ratioClass ratioLayoutSpecWithRatio:9.0 / 16.0 child:imageNode]];

        ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                        spacing:4.0
                                                                 justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                     alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                       children:@[siteNode, titleNode, descriptionNode]];
        [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
        [children addObject:[insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(8.0, 12.0, 10.0, 12.0) child:textStack]];

        ASStackLayoutSpec *cardStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                        spacing:0.0
                                                                 justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                     alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                       children:children];
        ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
        backgroundNode.cornerRadius = 10.0;
        backgroundNode.clipsToBounds = YES;
        id card = ApolloLPBackgroundWrappedSpec(cardStack, backgroundNode, backgroundClass);
        return ApolloLPMeasuredWrapper(card, insetClass);
    }

    ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
    titleNode.maximumNumberOfLines = 1;
    ASStackLayoutSpec *textStack = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionVertical
                                                                    spacing:3.0
                                                             justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                                 alignItems:ApolloLinkPreviewStackAlignItemsStretch
                                                                   children:@[siteNode, titleNode]];
    [[textStack style] setValue:@1.0 forKey:@"flexGrow"];
    [[textStack style] setValue:@1.0 forKey:@"flexShrink"];
    ASStackLayoutSpec *row = [stackClass stackLayoutSpecWithDirection:ApolloLinkPreviewStackDirectionHorizontal
                                                              spacing:10.0
                                                       justifyContent:ApolloLinkPreviewStackJustifyContentStart
                                                           alignItems:ApolloLinkPreviewStackAlignItemsStart
                                                             children:@[imageNode, textStack]];
    ApolloLPApplyCardBackgroundColor(hostNode, backgroundNode, url, NO);
    backgroundNode.cornerRadius = 10.0;
    backgroundNode.clipsToBounds = YES;
    id card = ApolloLPBackgroundWrappedSpec([insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) child:row], backgroundNode, backgroundClass);
    return ApolloLPMeasuredWrapper(card, insetClass);
}

// UNUSED since the round-7 watchdog fix (#630): transitionLayout with
// shouldMeasureAsync:NO measures the entire subtree synchronously on main.
// Kept for reference only — do not reintroduce on cell-sized nodes.
static void __attribute__((unused)) ApolloLPInvokeTransitionLayoutIfPossible(id node) {
    if (!node) return;
    SEL transitionSel = NSSelectorFromString(@"transitionLayoutWithAnimation:shouldMeasureAsync:measurementCompletion:");
    if (![node respondsToSelector:transitionSel]) return;

    NSMethodSignature *signature = [node methodSignatureForSelector:transitionSel];
    if (!signature) return;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = node;
    invocation.selector = transitionSel;
    BOOL animated = NO;
    BOOL async = NO;
    void (^completion)(void) = nil;
    [invocation setArgument:&animated atIndex:2];
    [invocation setArgument:&async atIndex:3];
    [invocation setArgument:&completion atIndex:4];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
    }
}

static BOOL ApolloLPInvokeRelayoutItemsIfPossible(id node) {
    if (!node) return NO;

    SEL relayoutItems = NSSelectorFromString(@"relayoutItems");
    if (![node respondsToSelector:relayoutItems]) return NO;

    @try {
        ((void (*)(id, SEL))objc_msgSend)(node, relayoutItems);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static ASDisplayNode *ApolloLPFindOwningCellNode(ASDisplayNode *node) {
    NSUInteger depth = 0;
    for (ASDisplayNode *current = node; current && depth < 32; current = current.supernode, depth++) {
        if ([NSStringFromClass([current class]) containsString:@"CellNode"]) {
            return current;
        }
    }
    return nil;
}

static void ApolloLPPerformScrollViewHeightRefresh(UIView *scrollView) {
    if ([scrollView isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)scrollView;
        [tableView beginUpdates];
        [tableView endUpdates];
    } else if ([scrollView isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)scrollView performBatchUpdates:nil completion:nil];
    }
}

// V24: settle-deferred begin/endUpdates. Holds the RESOLVED scroll view
// strongly instead of re-walking from a weak node after the wait: the row
// reload that usually accompanies this refresh re-creates the cell node, so
// a weak node reference dies before the collapse settles and the deferred
// refresh silently vanished — leaving compact cards stranded inside their
// tall hero-measured rows (#620 stretched-card report). The table view
// outlives the animation, one pending refresh per table is enough (an empty
// begin/endUpdates re-queries EVERY row height), and the retry is bounded so
// a long collapse-event storm can't queue forever — after the cap we fire
// anyway, which at worst re-runs the (rare) mid-animation glitch this gate
// exists to avoid, never a permanently wrong layout.
static char kApolloLPSettleRefreshPendingKey;

static void ApolloLPScheduleSettleDeferredHeightRefresh(UIView *scrollView, NSTimeInterval settleDelay, NSInteger attemptsLeft) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((settleDelay + 0.03) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSTimeInterval remaining = ApolloDeletedCommentsCollapseSettleDelayRemaining();
        if (remaining > 0 && attemptsLeft > 0) {
            ApolloLPScheduleSettleDeferredHeightRefresh(scrollView, remaining, attemptsLeft - 1);
            return;
        }
        objc_setAssociatedObject(scrollView, &kApolloLPSettleRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN);
        if (!scrollView.window) return; // screen went away; nothing left to fix
        ApolloLog(@"[LinkPreviews] V24-settle-deferred-height-refresh fired attemptsLeft=%ld", (long)attemptsLeft);
        ApolloLPPerformScrollViewHeightRefresh(scrollView);
    });
}

static BOOL ApolloLPInvokeScrollViewHeightRefresh(ASDisplayNode *node) {
    // Resolve the enclosing table/collection view FIRST, while the caller's
    // node is still alive and attached — a deferred walk routinely fails
    // after cell reuse (V24, see above).
    UIView *view = ApolloLPViewForNode(node);
    UIView *scrollView = nil;
    for (UIView *current = view; current; current = current.superview) {
        if ([current isKindOfClass:[UITableView class]] || [current isKindOfClass:[UICollectionView class]]) {
            scrollView = current;
            break;
        }
    }
    if (!scrollView) return NO;

    // A comment collapse/expand animation is running: an empty begin/endUpdates
    // now re-queries every row height mid-animation and restarts the native row
    // animations (ghosting / rows sliding the wrong way — #630). Re-run the
    // refresh once the collapse settles instead, coalesced per scroll view.
    NSTimeInterval settleDelay = ApolloDeletedCommentsCollapseSettleDelayRemaining();
    if (settleDelay > 0) {
        if (!objc_getAssociatedObject(scrollView, &kApolloLPSettleRefreshPendingKey)) {
            objc_setAssociatedObject(scrollView, &kApolloLPSettleRefreshPendingKey, @YES, OBJC_ASSOCIATION_RETAIN);
            ApolloLPScheduleSettleDeferredHeightRefresh(scrollView, settleDelay, 6);
        }
        return YES;
    }

    // Coalesce the immediate path too: a thread opening with N link cards used to
    // fire N separate empty begin/endUpdates, each an O(rows) height re-query on a
    // big table (part of "certain threads get very laggy", #630 round 6). One
    // short-deferred refresh per scroll view batches a burst of healing cards
    // into a single pass; the pending flag is shared with the settle path so the
    // two can never double-fire.
    if (!objc_getAssociatedObject(scrollView, &kApolloLPSettleRefreshPendingKey)) {
        objc_setAssociatedObject(scrollView, &kApolloLPSettleRefreshPendingKey, @YES, OBJC_ASSOCIATION_RETAIN);
        __weak UIView *weakScrollView = scrollView;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strongScrollView = weakScrollView;
            if (!strongScrollView) return;
            objc_setAssociatedObject(strongScrollView, &kApolloLPSettleRefreshPendingKey, nil, OBJC_ASSOCIATION_RETAIN);
            if (!strongScrollView.window) return;
            ApolloLPPerformScrollViewHeightRefresh(strongScrollView);
        });
    }
    return YES;
}

static id ApolloLPTextureNodeForScrollView(UIView *scrollView) {
    if (!scrollView) return nil;

    SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
    for (NSUInteger index = 0; index < sizeof(nodeSelectors) / sizeof(SEL); index++) {
        SEL selector = nodeSelectors[index];
        if (![scrollView respondsToSelector:selector]) continue;
        @try {
            id node = ((id (*)(id, SEL))objc_msgSend)(scrollView, selector);
            if ([node respondsToSelector:NSSelectorFromString(@"relayoutItems")]) return node;
        } @catch (__unused NSException *exception) {
        }
    }

    @try {
        id node = [scrollView valueForKey:@"asyncdisplaykit_node"];
        if ([node respondsToSelector:NSSelectorFromString(@"relayoutItems")]) return node;
    } @catch (__unused NSException *exception) {
    }

    return nil;
}

// No longer called from the row-reload path (full-table relayout pinned main for
// seconds on big threads — #630 round 6); kept for manual debugging only.
static BOOL __attribute__((unused)) ApolloLPInvokeTextureScrollRelayoutIfPossible(UIView *scrollView, NSString *host, NSString *kind) {
    (void)host;
    (void)kind;
    id node = ApolloLPTextureNodeForScrollView(scrollView);
    if (!node) return NO;

    if (!ApolloLPInvokeRelayoutItemsIfPossible(node)) return NO;
    return YES;
}

// V24: the async reload bodies below can still drop their reload when the
// captured index path has left the visible set by the time the block runs
// (fast scroll, or a native collapse animation mutating the table — the very
// situation the settle gate detects). The synchronous YES already told the
// caller "handled", which suppresses the V20/V23 miss bookkeeping — so a
// dropped reload used to disarm every healer at once and the row kept its
// stale hero height forever (#620 stretched compact cards). Re-note the miss
// from the block instead of silently returning: that re-arms the V20 pending
// mark and the V23 cross-node map, whose 1s poll reloads the row as soon as
// it is back on screen. `originNode` is the LinkButtonNode that owns the
// preview (it carries the URL association the bookkeeping needs); if it has
// been deallocated the cell was re-created, which re-measures with cached
// metadata and heals the height by itself — nothing to re-arm.
static void ApolloLPRenoteDroppedRowReload(ASDisplayNode *originNode, NSString *host, NSInteger row) {
    if (!originNode) return;
    ApolloLog(@"[LinkPreviews] V24-row-reload-dropped-renote host=%@ row=%ld", host ?: @"?", (long)row);
    ApolloLPNoteRowReloadMissForNode(originNode, host);
}

static BOOL ApolloLPInvokeRowReloadIfPossible(ASDisplayNode *startNode, ASDisplayNode *originNode, NSString *host) {
    // Hard convergence budget, keyed on the preview URL (falls back to host): every
    // reload path (V12 shrink heal, V18 overflow, V20 pending mark, V23 poll) funnels
    // through here, and a row whose height never converges used to reload FOREVER —
    // each reload allocates a brand-new cell subtree + hero image rasters and wipes
    // the per-node guards, the #630 round-8 jetsam (+20MB retained per thread open,
    // sim-measured; 964MB peak on device). Budget exhaustion also drains the V23/V20
    // arming so the 1s poll stops re-firing; a stuck row height is strictly better
    // than an OOM kill.
    static NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *sReloadBudget = nil;
    if (!sReloadBudget) sReloadBudget = [NSMutableDictionary dictionary];
    NSURL *budgetURL = originNode ? objc_getAssociatedObject(originNode, &kApolloLinkPreviewURLKey) : nil;
    NSString *budgetKey = budgetURL.absoluteString.length > 0 ? budgetURL.absoluteString : (host ?: @"(nohost)");
    NSMutableArray<NSNumber *> *attempts = sReloadBudget[budgetKey];
    if (!attempts) { attempts = [NSMutableArray array]; sReloadBudget[budgetKey] = attempts; }
    NSTimeInterval now = CACurrentMediaTime();
    while (attempts.count > 0 && now - attempts.firstObject.doubleValue > 60.0) {
        [attempts removeObjectAtIndex:0];
    }
    if (attempts.count >= 3) {
        if (originNode) {
            objc_setAssociatedObject(originNode, &kApolloLPPendingRowReloadHostKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        if (budgetURL.absoluteString.length > 0) {
            [ApolloLPPendingCrossNodeRowReloads() removeObjectForKey:budgetURL.absoluteString];
        }
        // Report handled: a renote here would just re-arm the healers we drained.
        return YES;
    }

    UIView *cellView = ApolloLPViewForNode(startNode);
    if (!cellView) {
        return NO;
    }

    UITableViewCell *tableCell = nil;
    UICollectionViewCell *collectionCell = nil;
    for (UIView *current = cellView; current; current = current.superview) {
        if (!tableCell && [current isKindOfClass:[UITableViewCell class]]) {
            tableCell = (UITableViewCell *)current;
        }
        if (!collectionCell && [current isKindOfClass:[UICollectionViewCell class]]) {
            collectionCell = (UICollectionViewCell *)current;
        }

        if (tableCell && [current isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)current;
            NSIndexPath *indexPath = [tableView indexPathForCell:tableCell];
            if (!indexPath) return NO;

            [attempts addObject:@(now)]; // burn budget only for a SCHEDULED reload
            NSString *hostCopy = [host copy];
            NSIndexPath *indexPathCopy = [indexPath copy];
            __weak ASDisplayNode *weakOriginNode = originNode;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (![[tableView indexPathsForVisibleRows] containsObject:indexPathCopy]) {
                        ApolloLPRenoteDroppedRowReload(weakOriginNode, hostCopy, indexPathCopy.row);
                        return;
                    }
                    // Reload ONLY the affected row. This used to also run a full-table
                    // relayoutItems first, which re-lays out EVERY node synchronously on
                    // main — on big threads that pinned the main thread for seconds per
                    // healing card ("threads get very laggy" + the 0x8BADF00D scene-update
                    // watchdog kill in #630 round 6). The single-row reload re-measures
                    // this row's node from scratch, which is all the healer needs.
                    [tableView reloadRowsAtIndexPaths:@[indexPathCopy] withRowAnimation:UITableViewRowAnimationNone];
                } @catch (__unused NSException *exception) {
                }
            });
            return YES;
        }

        if (collectionCell && [current isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)current;
            NSIndexPath *indexPath = [collectionView indexPathForCell:collectionCell];
            if (!indexPath) return NO;

            [attempts addObject:@(now)]; // burn budget only for a SCHEDULED reload
            NSString *hostCopy = [host copy];
            NSIndexPath *indexPathCopy = [indexPath copy];
            __weak ASDisplayNode *weakOriginNode = originNode;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (![[collectionView indexPathsForVisibleItems] containsObject:indexPathCopy]) {
                        ApolloLPRenoteDroppedRowReload(weakOriginNode, hostCopy, indexPathCopy.item);
                        return;
                    }
                    // Single-item reload only — no full-table relayoutItems (see the
                    // table branch above; that pinned main for seconds on big threads).
                    [collectionView performBatchUpdates:^{
                        [collectionView reloadItemsAtIndexPaths:@[indexPathCopy]];
                    } completion:nil];
                } @catch (__unused NSException *exception) {
                }
            });
            return YES;
        }
    }

    return NO;
}

static void ApolloLPInvokeContainerRelayoutIfPossible(ASDisplayNode *node, ASDisplayNode *cellNode, NSString *host) {
    ASDisplayNode *containerNode = nil;
    NSUInteger depth = 0;
    for (ASDisplayNode *current = cellNode ?: node; current && depth < 48; current = current.supernode, depth++) {
        NSString *className = NSStringFromClass([current class]);
        if ([className containsString:@"TableNode"] || [className containsString:@"CollectionNode"]) {
            containerNode = current;
            break;
        }
    }

    // Cheap path first: begin/endUpdates re-queries row heights and only re-measures
    // nodes whose calculated layout was invalidated above. The old order preferred
    // -[ASTableNode relayoutItems], which re-lays out EVERY node in the table
    // synchronously on main — seconds of work on big threads, and the source of the
    // scene-update watchdog kill in #630 round 6. relayoutItems survives only as a
    // last-resort fallback, rate-limited and never while backgrounded.
    if (ApolloLPInvokeScrollViewHeightRefresh(cellNode ?: node)) {
        return;
    }

    // Active only: the scene-update watchdog runs while the app is Inactive/Background
    // (snapshotting), which is exactly when a multi-second full relayout becomes a
    // 0x8BADF00D kill instead of mere jank.
    if (containerNode &&
        [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        static NSTimeInterval sLastFullRelayoutUptime = 0;
        NSTimeInterval now = CACurrentMediaTime();
        if (now - sLastFullRelayoutUptime > 10.0 &&
            ApolloLPInvokeRelayoutItemsIfPossible(containerNode)) {
            // Burn the rate-limit only on a SUCCESSFUL invocation, so a failed
            // attempt doesn't suppress the next legitimate fallback.
            sLastFullRelayoutUptime = now;
        }
    }
}

// Cheap synchronous part of a relayout trigger: dirty the ancestor chain's
// cached layouts. Flag flips only — the expensive re-measure happens in the
// single escalation below. Every card must dirty its own path (several cards
// can share one cell), so this always runs at trigger time.
static void ApolloLPInvalidateAncestorChain(ASDisplayNode *node) {
    NSUInteger depth = 0;
    for (ASDisplayNode *current = node; current && depth < 32; current = current.supernode, depth++) {
        if ([current respondsToSelector:@selector(invalidateCalculatedLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(current, @selector(invalidateCalculatedLayout));
        }
        if ([current respondsToSelector:@selector(setNeedsLayout)]) {
            ((void (*)(id, SEL))objc_msgSend)(current, @selector(setNeedsLayout));
        }
    }
}

// The expensive part: ONE _u_setNeedsLayoutFromAbove escalation at the cell
// (Texture re-measures the whole ancestor chain itself — the old shape called
// it at EVERY level, an O(depth²) climb per preview resolution), plus the
// container relayout. The debounce that wraps this (#638) is a real scroll-lag
// win and is kept.
//
// #630 reconciliation: this deliberately does NOT call
// transitionLayoutWithAnimation:NO shouldMeasureAsync:NO on the cell node (the
// shape #638 shipped). That is a synchronous full-subtree re-measure on the main
// thread, fired per hero->compact card shrink, and because the measure re-runs
// layoutSpecThatFits — the hook that schedules these climbs — it self-feeds: it
// was the round-7 watchdog freeze ("full size previews collapsing to compact
// ones") and a driver of the round-8 jetsam OOM. The _u_setNeedsLayoutFromAbove
// escalation above plus the container height refresh below re-measure lazily on
// the next layout pass and commit the row height without the eager sync measure.
static void ApolloLPPerformRelayoutClimb(ASDisplayNode *node, ASDisplayNode *cellNode, NSString *host) {
    ASDisplayNode *target = cellNode ?: node;
    SEL relayout = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
    if ([target respondsToSelector:relayout]) {
        ((void (*)(id, SEL))objc_msgSend)(target, relayout);
    }
    ApolloLPInvokeContainerRelayoutIfPossible(node, cellNode, host);
}

// Debounce state lives on the climb TARGET (the owning cell when found), so
// every card in a cell shares one pending climb. ~50 staggered cold preview
// resolutions used to mean ~50 synchronous full-cell re-measures; now a burst
// collapses to one climb ~QUIET ms after its last trigger (MAX-capped).
static char kApolloLPClimbArmedKey;
static char kApolloLPClimbLastMsKey;
static char kApolloLPClimbFirstMsKey;
static const double kApolloLPClimbQuietMs = 150.0;
static const double kApolloLPClimbMaxMs   = 400.0;

static void ApolloLPArmRelayoutClimb(ASDisplayNode *node, ASDisplayNode *cellNode, NSString *host, double delayMs) {
    __weak ASDisplayNode *weakNode = node;
    __weak ASDisplayNode *weakCell = cellNode;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        ASDisplayNode *n = weakNode;
        ASDisplayNode *cell = weakCell;
        ASDisplayNode *target = cell ?: n;
        if (!n || !target) return;
        double now = ApolloPerfNowMs();
        double last = [objc_getAssociatedObject(target, &kApolloLPClimbLastMsKey) doubleValue];
        double first = [objc_getAssociatedObject(target, &kApolloLPClimbFirstMsKey) doubleValue];
        double sinceLast = now - last;
        if (sinceLast < kApolloLPClimbQuietMs - 10.0 && now - first < kApolloLPClimbMaxMs) {
            ApolloLPArmRelayoutClimb(n, cell, hostCopy, kApolloLPClimbQuietMs - sinceLast);
            return;
        }
        objc_setAssociatedObject(target, &kApolloLPClimbArmedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(target, &kApolloLPClimbFirstMsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLPPerformRelayoutClimb(n, cell, hostCopy);
    });
}

static void ApolloLPTriggerRelayoutInternal(ASDisplayNode *node, BOOL scheduleDelayed, NSString *host) {
    if (!node) return;
    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
    ApolloLPInvalidateAncestorChain(node);

    // scheduleDelayed == NO is the immediate path (placeholder-context shrink
    // checks row-reload right after; it needs the climb done synchronously).
    if (!scheduleDelayed) {
        ApolloLPPerformRelayoutClimb(node, cellNode, host);
        return;
    }

    // Per-resolution path: debounced.
    ASDisplayNode *target = cellNode ?: node;
    double now = ApolloPerfNowMs();
    objc_setAssociatedObject(target, &kApolloLPClimbLastMsKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([objc_getAssociatedObject(target, &kApolloLPClimbArmedKey) boolValue]) return;
    objc_setAssociatedObject(target, &kApolloLPClimbArmedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(target, &kApolloLPClimbFirstMsKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLPArmRelayoutClimb(node, cellNode, host, kApolloLPClimbQuietMs);
}

static void ApolloLPTriggerRelayoutForHost(ASDisplayNode *node, NSString *host) {
    ApolloLPTriggerRelayoutInternal(node, YES, host);
}

// V20: when a placeholder shrinks to a compact card while the node is still
// detached (cell measured off-tree — the common case for fresh feed cells),
// BOTH reload attempts below miss ("row-reload-miss no-scroll-cell") and the
// row keeps its tall hero-placeholder height around a small compact card.
// Geometry can't detect this oversize case (a card shorter than its cell is
// normal), so remember the failure on the node (kApolloLPPendingRowReloadHostKey,
// declared with the dead-image helpers) and re-fire the reload from
// didEnterVisibleState once the cell actually exists on screen.
static void ApolloLPTriggerPlaceholderContextRelayout(ASDisplayNode *node, NSString *host, ApolloLPContext fromContext, ApolloLPContext toContext) {
    (void)fromContext;
    (void)toContext;
    if (!node) return;

    ApolloLPTriggerRelayoutInternal(node, NO, host);
    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
    if (ApolloLPInvokeRowReloadIfPossible(cellNode ?: node, node, host)) {
        // Reload scheduled — done. The old 150ms follow-up ran even after SUCCESS,
        // and since the successful reload detaches this node from its (deleted)
        // cell, the follow-up deterministically missed, re-noted a phantom failure,
        // and re-armed the V20/V23 healers against the replacement node — one of
        // the feedback cycles behind the #630 round-8 reload loop / jetsam.
        return;
    }
    ApolloLPNoteRowReloadMissForNode(node, host);

    __weak ASDisplayNode *weakNode = node;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (!strongNode) return;
        ASDisplayNode *strongCellNode = ApolloLPFindOwningCellNode(strongNode);
        if (ApolloLPInvokeRowReloadIfPossible(strongCellNode ?: strongNode, strongNode, hostCopy)) {
            objc_setAssociatedObject(strongNode, &kApolloLPPendingRowReloadHostKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            NSURL *url = objc_getAssociatedObject(strongNode, &kApolloLinkPreviewURLKey);
            if (url.absoluteString.length > 0) {
                [ApolloLPPendingCrossNodeRowReloads() removeObjectForKey:url.absoluteString];
            }
        } else {
            ApolloLPNoteRowReloadMissForNode(strongNode, hostCopy);
        }
    });
}

// MARK: - V18: stale row-height fix for late twitter/bsky card content
//
// When a link card's real content lands after the owning cell was measured
// (slow TweetBuddy / Bluesky fetches), the card redraws at full size but the
// feed row keeps its placeholder height — the card bleeds over the post's
// footer. The relayout triggers above are no-ops in the common failure mode
// because the LinkButtonNode is still detached (supernode == nil) while the
// cell is measured off-tree, so no owning cell can be found at refresh time.
// Instead of trusting the triggers, verify geometry after the fact: if the
// card's rendered content sticks out the bottom of its row's cell view,
// reload that row. Pure geometry — healthy rows are never reloaded.
static void ApolloLPRunOverflowHeightCheck(ASDisplayNode *node, NSString *host, NSInteger remainingAttempts) {
    if (!node) return;
    @try {
        BOOL loaded = [node respondsToSelector:@selector(isNodeLoaded)] && [node isNodeLoaded];
        UIView *nodeView = loaded ? ApolloLPViewForNode(node) : nil;
        UIView *cellView = nil;
        if (nodeView.window) {
            for (UIView *current = nodeView; current; current = current.superview) {
                if ([current isKindOfClass:[UITableViewCell class]] ||
                    [current isKindOfClass:[UICollectionViewCell class]]) {
                    cellView = current;
                    break;
                }
            }
        }
        if (!cellView) {
            // Node not on screen (yet) — retry briefly in case it is mid-attach.
            if (remainingAttempts > 0) {
                __weak ASDisplayNode *weakNode = node;
                NSString *hostCopy = [host copy];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    ASDisplayNode *strongNode = weakNode;
                    if (strongNode) ApolloLPRunOverflowHeightCheck(strongNode, hostCopy, remainingAttempts - 1);
                });
            }
            return;
        }

        // Views don't clip by default, so a stale row shows content drawn
        // beyond the node's frame — include one level of subview frames.
        CGRect content = nodeView.bounds;
        for (UIView *subview in nodeView.subviews) {
            content = CGRectUnion(content, subview.frame);
        }
        CGRect frameInCell = [nodeView convertRect:content toView:cellView];
        CGFloat overflow = CGRectGetMaxY(frameInCell) - CGRectGetHeight(cellView.bounds);
        if (overflow > 8.0) {
            ApolloLog(@"[LinkPreviews] V18-stale-row-height host=%@ overflow=%.0fpt -> reloading row",
                      host ?: @"?", overflow);
            ApolloLPInvokeRowReloadIfPossible(node, node, host);
        }
    } @catch (__unused NSException *exception) {}
}

// Let layout settle before measuring; runs on main.
static void ApolloLPScheduleOverflowHeightCheck(ASDisplayNode *node, NSString *host) {
    if (!node) return;
    __weak ASDisplayNode *weakNode = node;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (strongNode) ApolloLPRunOverflowHeightCheck(strongNode, hostCopy, 1);
    });
}

static ASDisplayNode *ApolloLPNodeForViewIfPossible(UIView *view) {
    if (!view) return nil;
    SEL nodeSelectors[] = { NSSelectorFromString(@"asyncdisplaykit_node"), NSSelectorFromString(@"node") };
    for (NSUInteger index = 0; index < sizeof(nodeSelectors) / sizeof(SEL); index++) {
        SEL selector = nodeSelectors[index];
        if (![view respondsToSelector:selector]) continue;
        @try {
            id node = ((id (*)(id, SEL))objc_msgSend)(view, selector);
            if ([node respondsToSelector:@selector(supernode)] || [node respondsToSelector:@selector(subnodes)]) return node;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static NSUInteger ApolloLPRecolorLinkPreviewBackgroundsForNode(ASDisplayNode *node) {
    if (!node) return 0;

    // Resolve the text ink that matches the (possibly just-changed) card color
    // up front — it depends only on the global hex, not on any single bundle.
    UIColor *titleColor = [UIColor labelColor];
    UIColor *secondaryColor = [UIColor secondaryLabelColor];
    ApolloLPCustomCardTextColors(&titleColor, &secondaryColor);

    NSUInteger recolored = 0;
    for (NSDictionary *bundle in ApolloLPNodeBundlesSnapshot(node)) {
        if (![bundle isKindOfClass:[NSDictionary class]]) continue;
        ASDisplayNode *backgroundNode = bundle[@"background"];
        NSURL *url = bundle[@"url"];
        if (![url isKindOfClass:[NSURL class]]) continue;
        if (ApolloLPApplyCardBackgroundColor(node, backgroundNode, url, YES)) {
            // Background changed — bring the text ink along so it keeps
            // contrasting with the new fill (or reverts to label colors).
            ApolloLPRecolorTextNode(bundle[@"site"], secondaryColor);
            ApolloLPRecolorTextNode(bundle[@"title"], titleColor);
            ApolloLPRecolorTextNode(bundle[@"description"], secondaryColor);
            recolored++;
        }
    }

    if (recolored > 0) {
        ApolloLPTriggerRelayoutForHost(node, @"card-color-refresh");
    }
    return recolored;
}

static ApolloLPRegisteredRecolorResult ApolloLPRecolorRegisteredLinkPreviewBackgrounds(void) {
    ApolloLPRegisteredRecolorResult result = {0, 0};
    NSArray *nodes = ApolloLPRegisteredLinkPreviewNodesSnapshot();
    result.nodes = nodes.count;

    for (id object in nodes) {
        if (![object respondsToSelector:@selector(supernode)] && ![object respondsToSelector:@selector(subnodes)]) continue;
        result.recolored += ApolloLPRecolorLinkPreviewBackgroundsForNode((ASDisplayNode *)object);
    }

    return result;
}

static NSUInteger ApolloLPInvalidateRegisteredLinkPreviewNodes(NSString *reason) {
    NSArray *nodes = ApolloLPRegisteredLinkPreviewNodesSnapshot();
    NSUInteger invalidated = 0;
    for (id object in nodes) {
        if (![object respondsToSelector:@selector(supernode)] && ![object respondsToSelector:@selector(subnodes)]) continue;
        ApolloLPTriggerRelayoutForHost((ASDisplayNode *)object, reason ?: @"registered-refresh");
        invalidated++;
    }
    return invalidated;
}

static BOOL ApolloLPURLsMatch(NSURL *lhs, NSURL *rhs) {
    if (![lhs isKindOfClass:[NSURL class]] || ![rhs isKindOfClass:[NSURL class]]) return NO;
    return [lhs.absoluteString isEqualToString:rhs.absoluteString];
}

static BOOL ApolloLPRegisteredNodeHasPreviewURL(ASDisplayNode *node, NSURL *url) {
    if (!node || !url) return NO;
    for (NSDictionary *bundle in ApolloLPNodeBundlesSnapshot(node)) {
        if (![bundle isKindOfClass:[NSDictionary class]]) continue;
        NSURL *bundleURL = bundle[@"url"];
        if (ApolloLPURLsMatch(bundleURL, url)) return YES;
    }
    return NO;
}

static NSUInteger ApolloLPInvalidateRegisteredLinkPreviewNodesForURL(NSURL *url, NSString *reason) {
    if (!url) return 0;

    NSArray *nodes = ApolloLPRegisteredLinkPreviewNodesSnapshot();
    NSUInteger invalidated = 0;
    for (id object in nodes) {
        if (![object respondsToSelector:@selector(supernode)] && ![object respondsToSelector:@selector(subnodes)]) continue;
        ASDisplayNode *node = (ASDisplayNode *)object;
        if (!ApolloLPRegisteredNodeHasPreviewURL(node, url)) continue;
        ApolloLPTriggerRelayoutForHost(node, reason ?: ApolloLPHost(url));
        invalidated++;
    }
    return invalidated;
}

static NSUInteger ApolloLPRecolorLinkPreviewBackgroundsInTree(id object, NSUInteger depth, NSHashTable *visitedObjects) {
    if (!object || depth == 0) return 0;
    if ([visitedObjects containsObject:object]) return 0;
    [visitedObjects addObject:object];

    NSUInteger recolored = 0;
    if ([object isKindOfClass:[UIView class]]) {
        ASDisplayNode *node = ApolloLPNodeForViewIfPossible((UIView *)object);
        if (node) {
            recolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(node, depth - 1, visitedObjects);
        }
        for (UIView *subview in ((UIView *)object).subviews) {
            recolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(subview, depth - 1, visitedObjects);
        }
        return recolored;
    }

    if ([object respondsToSelector:@selector(supernode)] || [object respondsToSelector:@selector(subnodes)]) {
        ASDisplayNode *node = (ASDisplayNode *)object;
        recolored += ApolloLPRecolorLinkPreviewBackgroundsForNode(node);

        if ([node respondsToSelector:@selector(subnodes)]) {
            @try {
                NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
                if ([subnodes isKindOfClass:[NSArray class]]) {
                    for (id subnode in subnodes) {
                        recolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(subnode, depth - 1, visitedObjects);
                    }
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }

    return recolored;
}

static NSUInteger ApolloLPInvalidateLinkButtonNodesInTree(id object, NSUInteger depth, NSHashTable *visitedObjects) {
    if (!object || depth == 0) return 0;
    if ([visitedObjects containsObject:object]) return 0;
    [visitedObjects addObject:object];

    NSUInteger invalidated = 0;
    if ([object isKindOfClass:[UIView class]]) {
        ASDisplayNode *node = ApolloLPNodeForViewIfPossible((UIView *)object);
        if (node) {
            invalidated += ApolloLPInvalidateLinkButtonNodesInTree(node, depth - 1, visitedObjects);
        }
        for (UIView *subview in ((UIView *)object).subviews) {
            invalidated += ApolloLPInvalidateLinkButtonNodesInTree(subview, depth - 1, visitedObjects);
        }
        return invalidated;
    }

    if ([object respondsToSelector:@selector(supernode)] || [object respondsToSelector:@selector(subnodes)]) {
        ASDisplayNode *node = (ASDisplayNode *)object;
        NSString *className = NSStringFromClass([object class]);
        if ([className containsString:@"LinkButtonNode"]) {
            ApolloLPTriggerRelayoutForHost(node, @"mode-change-node");
            invalidated++;
        }

        if ([node respondsToSelector:@selector(subnodes)]) {
            @try {
                NSArray *subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(node, @selector(subnodes));
                if ([subnodes isKindOfClass:[NSArray class]]) {
                    for (id subnode in subnodes) {
                        invalidated += ApolloLPInvalidateLinkButtonNodesInTree(subnode, depth - 1, visitedObjects);
                    }
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }

    return invalidated;
}

static NSUInteger ApolloLPRefreshLinkPreviewScrollViewsInView(UIView *view, NSHashTable<UIView *> *visitedViews) {
    if (!view || view.hidden || view.alpha < 0.01) return 0;
    if ([visitedViews containsObject:view]) return 0;
    [visitedViews addObject:view];

    NSUInteger refreshCount = 0;
    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)view;
        @try {
            [tableView beginUpdates];
            [tableView endUpdates];
            [tableView setNeedsLayout];
            [tableView layoutIfNeeded];
            refreshCount++;
        } @catch (__unused NSException *exception) {
        }
    } else if ([view isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collectionView = (UICollectionView *)view;
        @try {
            [collectionView performBatchUpdates:nil completion:nil];
            [collectionView setNeedsLayout];
            [collectionView layoutIfNeeded];
            refreshCount++;
        } @catch (__unused NSException *exception) {
        }
    }

    for (UIView *subview in view.subviews) {
        refreshCount += ApolloLPRefreshLinkPreviewScrollViewsInView(subview, visitedViews);
    }
    return refreshCount;
}

static void ApolloLPRefreshVisibleLayoutsForModeChange(NSString *areaName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL cardColorRefresh = [areaName isEqualToString:@"card-color"];
        if (cardColorRefresh) {
            ApolloLPRecolorRegisteredLinkPreviewBackgrounds();
        } else {
            ApolloLPInvalidateRegisteredLinkPreviewNodes(areaName ?: @"mode-change");
        }

        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow && !window.hidden && window.alpha > 0.01) {
                        [windows addObject:window];
                    }
                }
            }
        }

        if (windows.count == 0) {
            UIWindow *keyWindow = nil;
            SEL keyWindowSel = NSSelectorFromString(@"keyWindow");
            if ([UIApplication.sharedApplication respondsToSelector:keyWindowSel]) {
                keyWindow = ((UIWindow *(*)(id, SEL))objc_msgSend)(UIApplication.sharedApplication, keyWindowSel);
            }
            if (keyWindow && !keyWindow.hidden && keyWindow.alpha > 0.01) {
                [windows addObject:keyWindow];
            }
        }

        NSHashTable *visitedRecolorObjects = [NSHashTable weakObjectsHashTable];
        NSHashTable *visitedLayoutObjects = [NSHashTable weakObjectsHashTable];
        for (UIWindow *window in windows) {
            if (cardColorRefresh) {
                ApolloLPRecolorLinkPreviewBackgroundsInTree(window, 24, visitedRecolorObjects);
            }
            ApolloLPInvalidateLinkButtonNodesInTree(window, 24, visitedLayoutObjects);
        }

        NSHashTable<UIView *> *visitedViews = [NSHashTable weakObjectsHashTable];
        for (UIWindow *window in windows) {
            ApolloLPRefreshLinkPreviewScrollViewsInView(window, visitedViews);
        }
    });
}

static NSMutableSet<NSString *> *ApolloLPPendingTranslationRefreshURLs(void) {
    static NSMutableSet<NSString *> *urls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        urls = [NSMutableSet set];
    });
    return urls;
}

// Translation results post one notification per field (title, description,
// site name, etc.) from ApolloTranslation.xm. Each notification used to
// schedule its own debounced URL refresh, so a single card commonly got two
// `V15-translation-url-refresh` cascades a few hundred ms apart (one for the
// title and one for the description), each of which forced a layout pass on
// the already-rendered card. Coalesce them: when a refresh is pending for a
// URL, just record the latest enqueue time and the firing block reschedules
// itself once if a newer enqueue arrived after it was originally armed.
static NSMutableDictionary<NSString *, NSNumber *> *ApolloLPLatestTranslationRefreshEnqueueTimes(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static void ApolloLPFireTranslationLayoutRefreshForURL(NSURL *url, NSString *urlKey);

static void ApolloLPArmTranslationLayoutRefreshForURL(NSURL *url, NSString *urlKey, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSNumber *latest = nil;
        @synchronized (ApolloLPLatestTranslationRefreshEnqueueTimes()) {
            latest = ApolloLPLatestTranslationRefreshEnqueueTimes()[urlKey];
        }

        NSTimeInterval latestEnqueue = latest.doubleValue;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        // If a newer enqueue arrived less than 250 ms before now, give it a
        // second to coalesce more results (title + description typically
        // complete within ~150 ms of each other).
        if (latestEnqueue > 0.0 && (now - latestEnqueue) < 0.25) {
            ApolloLPArmTranslationLayoutRefreshForURL(url, urlKey, 0.25);
            return;
        }

        @synchronized (ApolloLPLatestTranslationRefreshEnqueueTimes()) {
            [ApolloLPLatestTranslationRefreshEnqueueTimes() removeObjectForKey:urlKey];
        }
        @synchronized (ApolloLPPendingTranslationRefreshURLs()) {
            [ApolloLPPendingTranslationRefreshURLs() removeObject:urlKey];
        }

        ApolloLPFireTranslationLayoutRefreshForURL(url, urlKey);
    });
}

static void ApolloLPFireTranslationLayoutRefreshForURL(NSURL *url, NSString *urlKey) {
    (void)urlKey;
    ApolloLPInvalidateRegisteredLinkPreviewNodesForURL(url, @"translation-update-url");
}

static void ApolloLPScheduleTranslationLayoutRefreshForURL(NSURL *url) {
    if (!url.absoluteString.length) {
        static BOOL globalRefreshPending = NO;
        if (globalRefreshPending) return;
        globalRefreshPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            globalRefreshPending = NO;
            ApolloLPRefreshVisibleLayoutsForModeChange(@"translation-settings-update");
        });
        return;
    }

    NSString *urlKey = [url.absoluteString copy];
    NSNumber *nowNumber = @([NSDate timeIntervalSinceReferenceDate]);

    BOOL alreadyPending = NO;
    @synchronized (ApolloLPLatestTranslationRefreshEnqueueTimes()) {
        ApolloLPLatestTranslationRefreshEnqueueTimes()[urlKey] = nowNumber;
    }
    @synchronized (ApolloLPPendingTranslationRefreshURLs()) {
        alreadyPending = [ApolloLPPendingTranslationRefreshURLs() containsObject:urlKey];
        if (!alreadyPending) [ApolloLPPendingTranslationRefreshURLs() addObject:urlKey];
    }

    if (alreadyPending) {
        // Refresh already scheduled. The fire block re-checks the latest
        // enqueue time and will reschedule once if a newer enqueue arrives
        // within 250 ms of fire time, so this enqueue just updates the
        // timestamp and falls through.
        return;
    }

    ApolloLPArmTranslationLayoutRefreshForURL(url, urlKey, 0.30);
}

static NSString *ApolloLPVariant(ApolloLPArea area, NSInteger mode, ApolloLPContext context, BOOL placeholder) {
    NSString *areaName = (area == ApolloLPAreaComments) ? @"comments" : @"body";
    NSString *contextName = (context == ApolloLPContextSelfText) ? @"hero" : @"compact";
    return [NSString stringWithFormat:@"%@-%@-mode%ld-%@", placeholder ? @"placeholder" : @"final", areaName, (long)mode, contextName];
}

static NSString *ApolloLPRenderSignature(NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    CGSize imageSize = preview.imageSize;
    return [NSString stringWithFormat:@"%@|%@|%lu|%@|%@|%@|%@|%@|%@|%@|%@|%@|%.1fx%.1f|%d",
            variant ?: @"",
            url.absoluteString ?: @"",
            (unsigned long)sLinkPreviewCardColorPacked,
            ApolloLPDisplayTitleForPreview(preview) ?: @"",
            ApolloLPDisplayDescriptionForPreview(preview) ?: @"",
            ApolloLPCleanDisplayText(preview.siteName) ?: @"",
            preview.imageURL.absoluteString ?: @"",
            preview.avatarURL.absoluteString ?: @"",
            preview.authorHandle ?: @"",
            preview.authorDisplayName ?: @"",
            preview.postText ?: @"",
            preview.previewKind ?: @"",
            imageSize.width,
            imageSize.height,
            preview.imageIsFallbackIcon];
}

static BOOL ApolloLPMarkRenderSignatureIfChanged(ASDisplayNode *hostNode, NSString *variant, NSString *signature, NSString *host) {
    (void)host;
    if (!hostNode || variant.length == 0 || signature.length == 0) return YES;

    NSMutableDictionary<NSString *, NSString *> *signatures = objc_getAssociatedObject(hostNode, &kApolloLinkPreviewRenderSignaturesKey);
    if (![signatures isKindOfClass:[NSMutableDictionary class]]) {
        signatures = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostNode, &kApolloLinkPreviewRenderSignaturesKey, signatures, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *lastSignature = signatures[variant];
    if ([lastSignature isEqualToString:signature]) {
        return NO;
    }

    signatures[variant] = signature;
    return YES;
}

static ApolloLinkPreview *ApolloLPPreviewByApplyingTranslation(ASDisplayNode *hostNode, NSURL *url, ApolloLinkPreview *preview) {
    if (!preview || !ApolloRichPreviewTranslationShouldTranslateForNode(hostNode)) return preview;

    NSString *sourceTitle = ApolloLPDisplayTitleForPreview(preview);
    NSString *sourceDesc = ApolloLPDisplayDescriptionForPreview(preview);
    NSString *translatedTitle = ApolloRichPreviewTranslatedTextIfAvailable(url, @"title", sourceTitle, hostNode);
    NSString *translatedDesc = ApolloRichPreviewTranslatedTextIfAvailable(url, @"description", sourceDesc, hostNode);
    if (translatedTitle.length == 0 && translatedDesc.length == 0) return preview;

    ApolloLinkPreview *displayPreview = [ApolloLinkPreview previewFromDictionary:[preview dictionaryRepresentation]];
    if (!displayPreview) return preview;
    displayPreview.title = sourceTitle;
    displayPreview.desc = sourceDesc;
    if (translatedTitle.length > 0) displayPreview.title = translatedTitle;
    if (translatedDesc.length > 0) displayPreview.desc = translatedDesc;
    return displayPreview;
}

static id ApolloLPNativeLinkSpecWithBannedHintIfNeeded(id linkButtonNode, NSURL *url, id nativeSpec) {
    NSString *redditUsername = ApolloLPRedditUsernameFromProfileURL(url);
    if (redditUsername.length == 0 || !ApolloBannedProfileCachedIsSuspended(redditUsername)) {
        return nativeSpec;
    }
    return ApolloBannedProfileWrapLinkButtonSpecWithBannedHint(linkButtonNode, nativeSpec, redditUsername);
}

%hook _TtC6Apollo14LinkButtonNode

// Release the per-card bitmap pins when the card leaves the preload range, and
// restore them (from the size-capped NSCache) when it comes back. defaultImage is
// invisible to Texture's own interface-state memory management, so without this
// every card a session ever rendered kept its decoded bitmap alive — the driver
// of the round-8 jetsam. Re-entry repaints from the cache before display, so the
// anti-flash purpose of defaultImage is preserved.
- (void)didExitPreloadState {
    %orig;
    for (NSDictionary *bundle in ApolloLPNodeBundlesSnapshot((ASDisplayNode *)self)) {
        for (NSString *key in @[@"image", @"avatar"]) {
            ASNetworkImageNode *imageNode = bundle[key];
            if (![imageNode respondsToSelector:@selector(setDefaultImage:)]) continue;
            @try {
                if (imageNode.defaultImage) imageNode.defaultImage = nil;
            } @catch (__unused NSException *e) {}
        }
    }
}

- (void)didEnterPreloadState {
    %orig;
    for (NSDictionary *bundle in ApolloLPNodeBundlesSnapshot((ASDisplayNode *)self)) {
        ASNetworkImageNode *imageNode = bundle[@"image"];
        NSURL *fallbackURL = imageNode ? objc_getAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackURLKey) : nil;
        if (!fallbackURL.absoluteString.length) continue;
        UIImage *cached = [ApolloLPFallbackImageCache() objectForKey:fallbackURL.absoluteString];
        if (cached && !ApolloLPNetworkImageNodeHasImage(imageNode)) {
            ApolloLPApplyFallbackImage(imageNode, fallbackURL, cached, ApolloLPHost(fallbackURL));
        }
    }
}

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    ApolloLPPrefetchRedditUserProfileIfNeeded(url);

    if (ApolloLPAllModesDisabled()) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    if (!url) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    NSString *host = ApolloLPHost(url);
    ApolloLPArea area = ApolloLPAreaForLinkButton((ASDisplayNode *)self);

    // (The old V17 per-measure diagnostic block lived here. It ran a supernode
    // walk + os_log on virtually every LinkButtonNode measure — its 6-per-node
    // cap reset constantly because scrolling recreates nodes — which was
    // measurable overhead in link-dense comment threads. The vote-time
    // compact→hero flip it was added to diagnose is long since fixed.)
    if (ApolloLPIsImageChestAlbumURL(url)) {
        // #552: defer to the inline-image album renderer (ApolloInlineImages'
        // LinkButtonNode hook) instead of suppressing to empty. Suppressing left
        // ImgChest album LINK POSTS blank — the inline-image album only rendered
        // for in-text links, never a bare link post, so nothing filled the space.
        // Deferring lets the album cover render (or the native card show as a
        // placeholder / failure fallback) regardless of hook load order.
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    NSInteger selectedMode = ApolloLPModeForArea(area);
    if (selectedMode == ApolloLinkPreviewModeOff) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    if (ApolloLPShouldDeferToInlineMedia(url)) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }
    if ([ApolloLinkPreviewFetcher isTwitterURL:url]) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }
    ApolloLPInstallContextMenuForNode((ASDisplayNode *)self, url);

    ApolloLinkPreview *cached = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
    // Match the fetcher's staleness rule: a bsky-post preview without
    // postText renders its flattened desc as the body, so refetch it rather
    // than reuse it forever (the render gate alone accepts handle-only).
    if (cached && ApolloLPIsBlueskyPostURL(url) &&
        (!ApolloLPIsBlueskyPostPreview(url, cached) || cached.postText.length == 0)) {
        cached = nil;
    }
    if (cached && (ApolloLPIsRedditUserProfileURL(url) || ApolloLPIsRedditSubredditURL(url))) {
        BOOL staleRedditUser = ApolloLPIsRedditUserProfileURL(url)
            && ![cached.previewKind isEqualToString:@"reddit-user-profile"];
        BOOL staleRedditSubreddit = ApolloLPIsRedditSubredditURL(url)
            && ![cached.previewKind isEqualToString:@"reddit-subreddit"];
        BOOL staleRedditUserSuspension = ApolloLPIsRedditUserProfileURL(url)
            && ApolloLPRedditUserPreviewNeedsSuspensionRefetch(url, cached);
        if (![cached hasUsefulMetadata] || staleRedditUser || staleRedditSubreddit || staleRedditUserSuspension) {
            if (staleRedditUserSuspension) {
                NSString *username = ApolloLPNormalizedRedditUsername(ApolloLPRedditUsernameFromProfileURL(url));
                if (username.length > 0) {
                    [[ApolloLinkPreviewCache sharedCache] removePreviewsForRedditUsername:username];
                }
            }
            cached = nil;
        }
    }
    if (!cached) {
        BOOL compactPlaceholder = selectedMode == ApolloLinkPreviewModeCompact || ApolloLPShouldUseCompactPlaceholder(url) || ApolloLPIsRedditUserProfileURL(url) || ApolloLPIsRedditSubredditURL(url);
        ApolloLPContext placeholderContext = compactPlaceholder ? ApolloLPContextCompact : ApolloLPContextSelfText;
        NSNumber *inFlight = objc_getAssociatedObject(self, &kApolloLinkPreviewFetchInFlightKey);
        if (![inFlight boolValue]) {
            objc_setAssociatedObject(self, &kApolloLinkPreviewFetchInFlightKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            [ApolloLinkPreviewFetcher requestPreviewForURL:url completion:^(__unused ApolloLinkPreview *preview) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (preview) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloLinkPreviewDidCacheNotification
                                                                            object:nil
                                                                          userInfo:@{@"url": url}];
                    }
                    ASDisplayNode *strongSelf = weakSelf;
                    if (!strongSelf) return;
                    objc_setAssociatedObject(strongSelf, &kApolloLinkPreviewFetchInFlightKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (preview) {
                        NSUInteger invalidated = ApolloLPInvalidateRegisteredLinkPreviewNodesForURL(url, @"cache-update-url");
                        if (invalidated == 0) {
                            ApolloLPTriggerRelayoutForHost(strongSelf, host);
                        }
                    } else {
                        ApolloLPTriggerRelayoutForHost(strongSelf, host);
                    }
                });
            }];
        }
        NSString *placeholderVariant = ApolloLPVariant(area, selectedMode, placeholderContext, YES);
        ApolloLPMarkRenderSignatureIfChanged((ASDisplayNode *)self, placeholderVariant, ApolloLPRenderSignature(url, nil, placeholderVariant), host);
        id placeholder = ApolloLPBuildPlaceholderSpec((ASDisplayNode *)self, url, placeholderContext, placeholderVariant);
        if (placeholder) {
            objc_setAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey, @(placeholderContext), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLPClearHostShell((ASDisplayNode *)self);
            return placeholder;
        }
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    if (![cached hasUsefulMetadata]) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    BOOL isRedditUser = ApolloLPIsRedditUserPreview(url, cached);
    BOOL isRedditSubreddit = ApolloLPIsRedditSubredditPreview(url, cached);
    ApolloLinkPreview *displayPreview = (isRedditUser || isRedditSubreddit) ? cached : ApolloLPPreviewByApplyingTranslation((ASDisplayNode *)self, url, cached);
    BOOL isBlueskyPost = ApolloLPIsBlueskyPostPreview(url, displayPreview);
    ApolloLPContext context = isBlueskyPost ? ApolloLPContextSelfText : ((isRedditUser || isRedditSubreddit) ? ApolloLPContextCompact : ApolloLPContextForMode(selectedMode, displayPreview));

    // Multi-link comment collapse: in Full mode, a single comment that contains
    // 2+ eligible preview links would otherwise stack that many tall hero cards,
    // making the comment absurdly long. When this would-be hero card lives in a
    // comment with 2+ eligible links, render it compact instead. Single-link
    // comments keep their full hero card; post bodies/selftext are unaffected
    // (this only applies to the Comments area). Reddit user/subreddit/Bluesky
    // cards keep their own fixed context and are excluded above.
    if (area == ApolloLPAreaComments && selectedMode == ApolloLinkPreviewModeFull &&
        context == ApolloLPContextSelfText && !isBlueskyPost && !isRedditUser && !isRedditSubreddit) {
        ASDisplayNode *cell = ApolloLPEnclosingCellNode((ASDisplayNode *)self);
        if (cell) {
            NSUInteger linkCount = ApolloLPCountEligiblePreviewLinksInTree(cell);
            if (linkCount >= 2) {
                context = ApolloLPContextCompact;
            }
        } else {
            // OFF-TREE measure (fresh node, cell not reachable): default COMPACT, not
            // hero. Resolving hero here and compact once attached created a
            // deterministic hero->compact shrink edge on EVERY fresh node — and since
            // the shrink heal is a row reload that REPLACES the node (wiping every
            // per-node guard), that edge re-fired per reload: the self-sustaining
            // reload loop behind the #630 round-8 jetsam (+20MB retained per thread
            // open, 964MB peak on device). Defaulting compact means an off-tree
            // measure can only be UPGRADED to hero by an attached single-link
            // measure — a growth the ordinary height refresh commits without any
            // reload. A genuinely single-link comment still gets its hero card.
            context = ApolloLPContextCompact;
        }
    }

    // V21: the preview scraped an image URL but the file 404s (clip hosts
    // publish og:image before the thumbnail exists). Render compact instead
    // of a hero with a dead image area; the mark expires (5 min) so the card
    // upgrades itself once the host generates the thumbnail.
    if (context == ApolloLPContextSelfText && !isBlueskyPost && !isRedditUser && !isRedditSubreddit &&
        ApolloLPImageURLIsDead(displayPreview.imageURL)) {
        context = ApolloLPContextCompact;
    }

    if (!isBlueskyPost && !isRedditUser && !isRedditSubreddit && displayPreview.imageIsFallbackIcon) {
        ApolloLPRememberCompactPlaceholderHost(url);
    } else if (!isBlueskyPost && !isRedditUser && !isRedditSubreddit && selectedMode == ApolloLinkPreviewModeFull && context == ApolloLPContextCompact) {
        ApolloLPRememberCompactPlaceholderHost(url);
    }
    NSString *finalVariant = ApolloLPVariant(area, selectedMode, context, NO);
    ApolloLPMarkRenderSignatureIfChanged((ASDisplayNode *)self, finalVariant, ApolloLPRenderSignature(url, displayPreview, finalVariant), host);
    id richSpec = isBlueskyPost
        ? ApolloLPBuildBlueskyPostCardSpec((ASDisplayNode *)self, url, displayPreview, finalVariant)
        : isRedditUser
        ? ApolloLPBuildRedditUserCardSpec((ASDisplayNode *)self, url, displayPreview, finalVariant)
        : isRedditSubreddit
        ? ApolloLPBuildRedditSubredditCardSpec((ASDisplayNode *)self, url, displayPreview, finalVariant)
        : (context == ApolloLPContextSelfText)
        ? ApolloLPBuildHeroCardSpec((ASDisplayNode *)self, url, displayPreview, finalVariant)
        : ApolloLPBuildCompactCardSpec((ASDisplayNode *)self, url, displayPreview, finalVariant);
    if (richSpec) {
        NSNumber *renderedPlaceholder = objc_getAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey);
        // V24: also track the CONTEXT of every rich render. A final-hero card
        // can later re-render final-compact with no placeholder involved at
        // all (the multi-link rule counts links via a cell-subtree walk, so a
        // measurement against a not-yet-complete subtree can resolve hero and
        // a later one compact). That flip had NO relayout trigger — the
        // compact card kept the hero row height and V18's overflow geometry
        // is blind to oversize rows. Fire the same shrink relayout for it.
        NSNumber *lastRenderedContext = objc_getAssociatedObject(self, &kApolloLPLastRenderedContextKey);
        BOOL finalShrankToCompact = !renderedPlaceholder &&
            [lastRenderedContext isKindOfClass:[NSNumber class]] &&
            lastRenderedContext.unsignedIntegerValue == ApolloLPContextSelfText &&
            context == ApolloLPContextCompact;
        ApolloLPContext placeholderContext = renderedPlaceholder ? (ApolloLPContext)[renderedPlaceholder unsignedIntegerValue] : ApolloLPContextSelfText;
        BOOL placeholderShrankToCompact = (renderedPlaceholder != nil && placeholderContext == ApolloLPContextSelfText && context == ApolloLPContextCompact) || finalShrankToCompact;
        // Per-node cooldown for SHRINK-shaped triggers only: hero<->compact can
        // oscillate across measures (the multi-link count sees a different subtree
        // off-tree vs attached) and each flip re-fires this trigger — the round-7
        // #630 freeze. Non-shrink triggers (placeholder->hero) never oscillate and
        // must not stamp the window: the legitimate hero->compact flip lands
        // 80-200ms after them by construction (the 80ms delayed re-invalidate pass)
        // and would otherwise always be swallowed, stranding compact cards in hero
        // rows — the very #631 symptom this machinery heals.
        static char kApolloLPShrinkTriggerUptimeKey;
        NSNumber *lastShrinkTrigger = objc_getAssociatedObject(self, &kApolloLPShrinkTriggerUptimeKey);
        NSTimeInterval sinceLastShrink = [lastShrinkTrigger isKindOfClass:[NSNumber class]]
            ? (CACurrentMediaTime() - lastShrinkTrigger.doubleValue) : DBL_MAX;
        BOOL shrinkCooldownActive = placeholderShrankToCompact && sinceLastShrink < 1.0;

        if (shrinkCooldownActive) {
            // Skipped by the cooldown: preserve BOTH re-detection edges (keep the
            // placeholder marker, keep lastRenderedContext at hero) and force one
            // re-measure after the window so a legitimate shrink is only delayed,
            // never lost. Without this the flip consumed its edge and the compact
            // card stayed stranded at hero height forever.
            objc_setAssociatedObject(self, &kApolloLPLastRenderedContextKey, @(ApolloLPContextSelfText), OBJC_ASSOCIATION_RETAIN);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            NSTimeInterval retryDelay = MAX(0.05, 1.0 - sinceLastShrink) + 0.05;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ASDisplayNode *strongSelf = weakSelf;
                if (!strongSelf) return;
                @try {
                    SEL invalidateSel = NSSelectorFromString(@"invalidateCalculatedLayout");
                    if ([strongSelf respondsToSelector:invalidateSel]) {
                        ((void (*)(id, SEL))objc_msgSend)(strongSelf, invalidateSel);
                    }
                    if ([strongSelf respondsToSelector:@selector(setNeedsLayout)]) {
                        ((void (*)(id, SEL))objc_msgSend)((id)strongSelf, @selector(setNeedsLayout));
                    }
                } @catch (__unused NSException *e) {}
            });
        } else {
            objc_setAssociatedObject(self, &kApolloLPLastRenderedContextKey, @(context), OBJC_ASSOCIATION_RETAIN);
        }

        if ((renderedPlaceholder || finalShrankToCompact) && !shrinkCooldownActive) {
            if (placeholderShrankToCompact) {
                objc_setAssociatedObject(self, &kApolloLPShrinkTriggerUptimeKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            objc_setAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            NSString *hostCopy = [host copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                ASDisplayNode *strongSelf = weakSelf;
                if (!strongSelf) return;
                if (placeholderShrankToCompact) {
                    ApolloLPTriggerPlaceholderContextRelayout(strongSelf, hostCopy, placeholderContext, context);
                } else {
                    ApolloLPTriggerRelayoutForHost(strongSelf, hostCopy);
                }
                // V18: the trigger above is a no-op when this node is still
                // detached (cell measured off-tree); verify the row height by
                // geometry once things settle.
                ApolloLPScheduleOverflowHeightCheck(strongSelf, hostCopy);
            });
        }
        ApolloLPClearHostShell((ASDisplayNode *)self);
        return richSpec;
    }
    ApolloLPRestoreHostShell((ASDisplayNode *)self);
    return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
}

- (void)didLoad {
    %orig;
    // V17: by the time the view loads, the supernode chain is established.
    // Walk up and cache the area so subsequent measurements never have to
    // guess. This is the primary belt for the vote-time race; the dispatched
    // re-resolve in ApolloLPAreaForLinkButton is the suspenders.
    ApolloLPArea resolved = ApolloLPAreaBody;
    if (ApolloLPResolveAreaByWalk((ASDisplayNode *)self, &resolved, NULL)) {
        NSNumber *existing = objc_getAssociatedObject(self, &kApolloLinkPreviewAreaKey);
        if (![existing isKindOfClass:[NSNumber class]]) {
            objc_setAssociatedObject(self, &kApolloLinkPreviewAreaKey, @(resolved), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// V18: cards whose final content rendered while the node was detached could
// never fix their row height (no owning cell at refresh time). Verify the
// geometry whenever the card scrolls on screen; only broken rows reload.
// V20: also re-fire a placeholder-shrink row reload that failed while the
// node was detached — the oversized-row case geometry can't detect.
- (void)didEnterVisibleState {
    %orig;
    NSString *pendingHost = objc_getAssociatedObject(self, &kApolloLPPendingRowReloadHostKey);
    if (pendingHost) {
        objc_setAssociatedObject(self, &kApolloLPPendingRowReloadHostKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
        // Let the cell finish attaching before resolving its index path.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            ASDisplayNode *strongSelf = weakSelf;
            if (!strongSelf) return;
            ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(strongSelf);
            // V24: the mark was consumed above; if the reload can't even be
            // scheduled, re-arm instead of discarding the result — otherwise
            // this re-fire was one-shot and a single failed walk stranded the
            // row at its stale height.
            if (!ApolloLPInvokeRowReloadIfPossible(cellNode ?: strongSelf, strongSelf, pendingHost)) {
                ApolloLPNoteRowReloadMissForNode(strongSelf, pendingHost);
            }
        });
    }
    ApolloLPScheduleOverflowHeightCheck((ASDisplayNode *)self, @"visible-check");
}

%end

// V18: Apollo's native tweet card (data via the TweetBuddy shim) hits the
// same stale-row-height race when the tweet arrives after the row was
// measured — the info node materializes late and bleeds over the footer.
// Its didLoad is the earliest point with real geometry; the overflow check
// keeps healthy rows untouched.
%hook _TtC6Apollo23LinkButtonTweetInfoNode

- (void)didLoad {
    %orig;
    ApolloLPScheduleOverflowHeightCheck((ASDisplayNode *)self, @"tweet-info");
}

%end

// V17: pre-stamp area on link buttons inside a cell so the first
// background-thread measurement of a freshly-recreated cell (e.g. after a
// vote) does not race the supernode chain attachment. Comment cells stamp
// Comments; the OP-selftext header and feed post cells stamp Body (issue #318).
%hook _TtC6Apollo15CommentCellNode
- (void)didLoad {
    %orig;
    ApolloLPStampLinkButtonAreaInTree((ASDisplayNode *)self, ApolloLPAreaComments);
}
%end

%hook _TtC6Apollo22CommentsHeaderCellNode
- (void)didLoad {
    %orig;
    ApolloLPStampLinkButtonAreaInTree((ASDisplayNode *)self, ApolloLPAreaBody);
}
%end

%hook _TtC6Apollo17LargePostCellNode
- (void)didLoad {
    %orig;
    ApolloLPStampLinkButtonAreaInTree((ASDisplayNode *)self, ApolloLPAreaBody);
}
%end

%hook _TtC6Apollo19CompactPostCellNode
- (void)didLoad {
    %orig;
    ApolloLPStampLinkButtonAreaInTree((ASDisplayNode *)self, ApolloLPAreaBody);
}
%end

%ctor {
    sApolloLPRegisteredLinkNodes = [NSHashTable weakObjectsHashTable];
    sApolloLPRegisteredLinkNodesQueue = dispatch_queue_create("com.apollo.linkpreviews.nodes", DISPATCH_QUEUE_SERIAL);

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloLinkPreviewModeDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        NSString *areaName = [notification.userInfo[@"area"] isKindOfClass:[NSString class]] ? notification.userInfo[@"area"] : @"unknown";
        ApolloLPRefreshVisibleLayoutsForModeChange(areaName);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloRichPreviewTranslationDidUpdateNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        NSURL *url = [notification.userInfo[@"url"] isKindOfClass:[NSURL class]] ? notification.userInfo[@"url"] : nil;
        NSString *reason = [notification.userInfo[@"reason"] isKindOfClass:[NSString class]] ? notification.userInfo[@"reason"] : @"unknown";
        if (url) {
            ApolloLPScheduleTranslationLayoutRefreshForURL(url);
        } else if ([reason isEqualToString:@"settings-change"] || [reason isEqualToString:@"mode-toggle"]) {
            ApolloLPScheduleTranslationLayoutRefreshForURL(nil);
        }
    }];
}
