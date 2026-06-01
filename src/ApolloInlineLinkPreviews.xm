// ApolloInlineLinkPreviews.xm
//
// Replaces Apollo's basic LinkButtonNode cards with richer metadata cards when
// the target page exposes useful Open Graph / Twitter Card / first-party API
// metadata. Falls back to Apollo's native card when metadata is missing.

#import "ApolloCommon.h"
#import "ApolloLinkPreviewCache.h"
#import "ApolloLinkPreviewFetcher.h"
#import "ApolloBannedProfile.h"
#import "ApolloUserProfileCache.h"
#import "ApolloState.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloTranslation.h"
#import "ApolloUserProfileCache.h"
#import "UserDefaultConstants.h"

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
static char kApolloLinkPreviewV17LogCountKey;

static NSHashTable<id> *sApolloLPRegisteredLinkNodes = nil;
static dispatch_queue_t sApolloLPRegisteredLinkNodesQueue = NULL;

typedef struct {
    NSUInteger nodes;
    NSUInteger recolored;
} ApolloLPRegisteredRecolorResult;

static void ApolloLPLogOncePerHost(NSString *host, NSString *event);
static void ApolloLPTriggerRelayoutForHost(ASDisplayNode *node, NSString *host);
static BOOL ApolloLPIsRedditUserProfileURL(NSURL *url);
static NSString *ApolloLPRedditUsernameFromProfileURL(NSURL *url);
static BOOL ApolloLPIsRedditSubredditURL(NSURL *url);
static NSString *ApolloLPRedditSubredditFromURL(NSURL *url);
static NSString *ApolloLPCleanDisplayText(NSString *text);

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
    }
    if ([node respondsToSelector:@selector(onDidLoad:)]) {
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
    });
    return cache;
}

static BOOL ApolloLPNetworkImageNodeHasImage(ASNetworkImageNode *imageNode) {
    if (!imageNode || ![imageNode respondsToSelector:@selector(image)]) return NO;
    UIImage *image = imageNode.image;
    return [image isKindOfClass:[UIImage class]] && image.size.width > 0.0 && image.size.height > 0.0;
}

static void ApolloLPRememberRenderedImageForURL(ASNetworkImageNode *imageNode, NSURL *imageURL) {
    if (!imageURL.absoluteString.length || !ApolloLPNetworkImageNodeHasImage(imageNode)) return;
    UIImage *image = imageNode.image;
    NSUInteger cost = (NSUInteger)(image.size.width * image.size.height * image.scale * image.scale * 4.0);
    [ApolloLPFallbackImageCache() setObject:image forKey:imageURL.absoluteString cost:cost];
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

static void ApolloLPApplyFallbackImage(ASNetworkImageNode *imageNode, NSURL *imageURL, UIImage *image, NSString *host) {
    if (!imageNode || !image || image.size.width <= 0.0 || image.size.height <= 0.0) return;
    NSURL *currentURL = objc_getAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackURLKey);
    if (![currentURL.absoluteString isEqualToString:imageURL.absoluteString]) return;
    if (ApolloLPNetworkImageNodeHasImage(imageNode)) return;

    imageNode.image = image;
    // Persist the decoded image as defaultImage so Texture keeps painting it
    // when it releases imageNode.image outside the display range. Without
    // this, re-entering a thread shows a blank/gray frame before the
    // fallback path re-applies the image.
    if ([imageNode respondsToSelector:@selector(setDefaultImage:)]) {
        imageNode.defaultImage = image;
    }
    imageNode.backgroundColor = nil;
    objc_setAssociatedObject(imageNode, &kApolloLinkPreviewImageFallbackAppliedURLKey, imageURL.absoluteString, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ApolloLPLogOncePerHost(host ?: ApolloLPHost(imageURL), @"fallback-image-applied");
}

static void ApolloLPStartFallbackImageFetch(ASNetworkImageNode *imageNode, NSURL *imageURL, NSString *host) {
    if (!imageNode || !ApolloLPURLIsHTTP(imageURL)) return;
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
        UIImage *image = data.length > 0 ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
        if (image) {
            NSUInteger cost = (NSUInteger)(image.size.width * image.size.height * image.scale * image.scale * 4.0);
            [ApolloLPFallbackImageCache() setObject:image forKey:key cost:cost];
        } else {
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            ApolloLog(@"[LinkPreviews] fallback-image failed host=%@ status=%ld bytes=%lu err=%@ url=%@",
                      hostCopy ?: ApolloLPHost(imageURL),
                      (long)httpResponse.statusCode,
                      (unsigned long)data.length,
                      error.localizedDescription ?: @"nil",
                      imageURL.absoluteString);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ASNetworkImageNode *strongImageNode = weakImageNode;
            if (!strongImageNode) return;
            objc_setAssociatedObject(strongImageNode, &kApolloLinkPreviewImageFallbackInFlightKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ApolloLPApplyFallbackImage(strongImageNode, imageURL, image, hostCopy);
        });
    }] resume];
}

static void ApolloLPScheduleImageFallbackIfNeeded(ASNetworkImageNode *imageNode, NSURL *imageURL, NSString *host) {
    if (!imageNode || !ApolloLPURLIsHTTP(imageURL)) return;
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
        if (ApolloLPNetworkImageNodeHasImage(strongImageNode)) return;
        ApolloLPStartFallbackImageFetch(strongImageNode, imageURLCopy, hostCopy);
    });
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

static UIColor *ApolloLPColorForCardPreset(NSInteger preset) {
    switch (preset) {
        case ApolloLinkPreviewCardColorGray:     return [UIColor colorWithWhite:0.56 alpha:1.0];
        case ApolloLinkPreviewCardColorRed:      return [UIColor colorWithRed:1.00 green:0.23 blue:0.19 alpha:1.0];
        case ApolloLinkPreviewCardColorOrange:   return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorYellow:   return [UIColor colorWithRed:1.00 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorGreen:    return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        case ApolloLinkPreviewCardColorMint:     return [UIColor colorWithRed:0.00 green:0.78 blue:0.75 alpha:1.0];
        case ApolloLinkPreviewCardColorTeal:     return [UIColor colorWithRed:0.19 green:0.69 blue:0.78 alpha:1.0];
        case ApolloLinkPreviewCardColorCyan:     return [UIColor colorWithRed:0.20 green:0.68 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorBlue:     return [UIColor colorWithRed:0.00 green:0.48 blue:1.00 alpha:1.0];
        case ApolloLinkPreviewCardColorIndigo:   return [UIColor colorWithRed:0.35 green:0.34 blue:0.84 alpha:1.0];
        case ApolloLinkPreviewCardColorPurple:   return [UIColor colorWithRed:0.69 green:0.32 blue:0.87 alpha:1.0];
        case ApolloLinkPreviewCardColorPink:     return [UIColor colorWithRed:1.00 green:0.18 blue:0.33 alpha:1.0];
        case ApolloLinkPreviewCardColorBrown:    return [UIColor colorWithRed:0.64 green:0.52 blue:0.37 alpha:1.0];
        case ApolloLinkPreviewCardColorCoral:    return [UIColor colorWithRed:1.00 green:0.50 blue:0.31 alpha:1.0];
        case ApolloLinkPreviewCardColorLime:     return [UIColor colorWithRed:0.60 green:0.80 blue:0.00 alpha:1.0];
        case ApolloLinkPreviewCardColorOlive:    return [UIColor colorWithRed:0.50 green:0.60 blue:0.20 alpha:1.0];
        case ApolloLinkPreviewCardColorLavender: return [UIColor colorWithRed:0.56 green:0.45 blue:0.90 alpha:1.0];
        case ApolloLinkPreviewCardColorSlate:    return [UIColor colorWithRed:0.35 green:0.43 blue:0.50 alpha:1.0];
        case ApolloLinkPreviewCardColorNeutral:
        default:                                 return [UIColor colorWithWhite:0.72 alpha:1.0];
    }
}

static UIColor *ApolloLPCardBackgroundColorForNode(ASDisplayNode *hostNode, NSURL *url) {
    UIColor *tintColor = ApolloLPColorForCardPreset(sLinkPreviewCardColor);
    ApolloLPLogOncePerHost(ApolloLPHost(url), @"V13-card-color-preset-resolved");

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

    NSNumber *lastPresetNumber = objc_getAssociatedObject(backgroundNode, &kApolloLinkPreviewBackgroundColorPresetKey);
    BOOL presetChanged = ![lastPresetNumber isKindOfClass:[NSNumber class]] || lastPresetNumber.integerValue != sLinkPreviewCardColor;
    if (!force && !presetChanged) return NO;

    backgroundNode.backgroundColor = ApolloLPCardBackgroundColorForNode(hostNode, url);
    objc_setAssociatedObject(backgroundNode, &kApolloLinkPreviewBackgroundColorPresetKey, @(sLinkPreviewCardColor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloLPMarkNodeForColorRefresh(backgroundNode);
    ApolloLPMarkNodeForColorRefresh(hostNode);
    return YES;
}

static NSString *ApolloLPBundleKey(NSURL *url, NSString *variant) {
    return [NSString stringWithFormat:@"%@|%@", url.absoluteString ?: @"", variant ?: @"default"];
}

static NSDictionary *ApolloLPNodeBundleForHost(ASDisplayNode *hostNode, NSURL *url, NSString *variant) {
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

static NSString *ApolloLPCleanDisplayText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return text;
    NSString *clean = [text stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
    NSRegularExpression *tagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    clean = [tagRegex stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    NSRegularExpression *whitespace = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    clean = [whitespace stringByReplacingMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length > 0 ? clean : text;
}

static NSString *ApolloLPDisplayTitleForPreview(ApolloLinkPreview *preview) {
    return ApolloLPCleanDisplayText(preview.title);
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

static NSString *ApolloLPContextLogName(ApolloLPContext context) {
    return context == ApolloLPContextSelfText ? @"hero" : @"compact";
}

static id ApolloLPModelFromNodeIvar(ASDisplayNode *node, const char *ivarName) {
    if (!node || !ivarName) return nil;
    Ivar ivar = class_getInstanceVariable([node class], ivarName);
    if (!ivar) return nil;

    id model = nil;
    @try {
        model = object_getIvar(node, ivar);
    } @catch (NSException *exception) {
        ApolloLog(@"[LinkPreviews] ivar read failed node=%@ ivar=%s err=%@",
                  NSStringFromClass([node class]), ivarName, exception.reason ?: exception.name);
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
        ApolloLog(@"[LinkPreviews] V18 deferred-upgrade fallback=%ld→resolved=%ld cell=%@",
                  (long)fallbackMode, (long)resolvedMode,
                  cell ? NSStringFromClass([cell class]) : @"(no-cell)");
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
    ApolloLPSetTextNodeAttributedTextIfChanged(siteNode, ApolloLPAttributedString([siteName uppercaseString], [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold], [UIColor secondaryLabelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(ApolloLPDisplayTitleForPreview(preview), [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold], [UIColor labelColor]));
    ApolloLPSetTextNodeAttributedTextIfChanged(descriptionNode, ApolloLPAttributedString(ApolloLPDisplayDescriptionForPreview(preview), [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular], [UIColor secondaryLabelColor]));

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
    ApolloLPLogOncePerHost(ApolloLPHost(url), @"hid-orphan-avatar-compact");

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
    if (preview.imageURL.absoluteString.length > 0) {
        imageNode.contentMode = UIViewContentModeScaleAspectFill;
        imageNode.cornerRadius = 8.0;
        ApolloLPApplyStyleSize([imageNode style], CGSizeMake(84.0, 84.0));
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
    ApolloLPLogOncePerHost(ApolloLPHost(url), @"hid-orphan-avatar-hero");

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
    ApolloLPSetTextNodeAttributedTextIfChanged(titleNode, ApolloLPAttributedString(ApolloLPDisplayTitleForPreview(preview), [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold], [UIColor labelColor]));
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
                ApolloLPLogOncePerHost(ApolloLPHost(url), [NSString stringWithFormat:@"V12-poster-hero-image ratio=%.2f", ratio]);
            } else {
                ratio = MAX(MIN(naturalRatio, 0.6), 0.45);
            }
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
    NSString *postText = preview.postText.length > 0 ? ApolloLPCleanDisplayText(preview.postText) : ApolloLPDisplayDescriptionForPreview(preview);
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
    descriptionNode.maximumNumberOfLines = 10;
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
    [[authorRow style] setValue:@1.0 forKey:@"flexShrink"];

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
        [cardChildren addObject:[ratioClass ratioLayoutSpecWithRatio:ratio child:imageNode]];
    }
    [cardChildren addObject:[insetClass insetLayoutSpecWithInsets:UIEdgeInsetsMake(11.0, 12.0, 12.0, 12.0) child:contentStack]];

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

    NSString *cardUsername = ApolloLPNormalizedRedditUsername(ApolloLPRedditUsernameFromProfileURL(url));
    if (cardUsername.length == 0) {
        cardUsername = ApolloLPNormalizedRedditUsername(preview.authorHandle);
    }
    if (cardUsername.length > 0) {
        static NSMutableSet<NSString *> *sLoggedRedditUserCardStates;
        static dispatch_once_t sLoggedRedditUserCardStatesOnce;
        dispatch_once(&sLoggedRedditUserCardStatesOnce, ^{
            sLoggedRedditUserCardStates = [NSMutableSet set];
        });
        NSString *logKey = cardUsername.lowercaseString;
        if (![sLoggedRedditUserCardStates containsObject:logKey]) {
            [sLoggedRedditUserCardStates addObject:logKey];
            ApolloLog(@"[BannedProfile] reddit-user card u/%@ cachedSuspended=%@ previewBanned=%@",
                      cardUsername,
                      ApolloBannedProfileCachedIsSuspended(cardUsername) ? @"YES" : @"NO",
                      isBannedUser ? @"YES" : @"NO");
        }
    }

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
    ApolloLPLogOncePerHost(ApolloLPHost(url), @"hid-orphan-avatar-placeholder");

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

static void ApolloLPInvokeTransitionLayoutIfPossible(id node) {
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

static BOOL ApolloLPInvokeScrollViewHeightRefresh(ASDisplayNode *node) {
    UIView *view = ApolloLPViewForNode(node);
    for (UIView *current = view; current; current = current.superview) {
        if ([current isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)current;
            [tableView beginUpdates];
            [tableView endUpdates];
            return YES;
        }

        if ([current isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)current;
            [collectionView performBatchUpdates:nil completion:nil];
            return YES;
        }
    }

    return NO;
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

static BOOL ApolloLPInvokeTextureScrollRelayoutIfPossible(UIView *scrollView, NSString *host, NSString *kind) {
    id node = ApolloLPTextureNodeForScrollView(scrollView);
    if (!node) return NO;

    if (!ApolloLPInvokeRelayoutItemsIfPossible(node)) return NO;
    ApolloLPLogOncePerHost(host, [NSString stringWithFormat:@"V12-texture-scroll-relayout kind=%@", kind ?: @"unknown"]);
    return YES;
}

static BOOL ApolloLPInvokeRowReloadIfPossible(ASDisplayNode *startNode, NSString *host) {
    UIView *cellView = ApolloLPViewForNode(startNode);
    if (!cellView) {
        ApolloLPLogOncePerHost(host, @"V12-row-reload-miss no-view");
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

            NSString *hostCopy = [host copy];
            NSIndexPath *indexPathCopy = [indexPath copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (![[tableView indexPathsForVisibleRows] containsObject:indexPathCopy]) return;
                    ApolloLPInvokeTextureScrollRelayoutIfPossible(tableView, hostCopy, @"table");
                    [tableView reloadRowsAtIndexPaths:@[indexPathCopy] withRowAnimation:UITableViewRowAnimationNone];
                    ApolloLPLogOncePerHost(hostCopy, [NSString stringWithFormat:@"V12-row-reload kind=table row=%ld", (long)indexPathCopy.row]);
                } @catch (__unused NSException *exception) {
                }
            });
            return YES;
        }

        if (collectionCell && [current isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)current;
            NSIndexPath *indexPath = [collectionView indexPathForCell:collectionCell];
            if (!indexPath) return NO;

            NSString *hostCopy = [host copy];
            NSIndexPath *indexPathCopy = [indexPath copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (![[collectionView indexPathsForVisibleItems] containsObject:indexPathCopy]) return;
                    ApolloLPInvokeTextureScrollRelayoutIfPossible(collectionView, hostCopy, @"collection");
                    [collectionView performBatchUpdates:^{
                        [collectionView reloadItemsAtIndexPaths:@[indexPathCopy]];
                    } completion:nil];
                    ApolloLPLogOncePerHost(hostCopy, [NSString stringWithFormat:@"V12-row-reload kind=collection row=%ld", (long)indexPathCopy.item]);
                } @catch (__unused NSException *exception) {
                }
            });
            return YES;
        }
    }

    ApolloLPLogOncePerHost(host, @"V12-row-reload-miss no-scroll-cell");
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

    if (containerNode && ApolloLPInvokeRelayoutItemsIfPossible(containerNode)) {
        ApolloLPLogOncePerHost(host, @"V12-table-relayout-items");
        return;
    }

    if (ApolloLPInvokeScrollViewHeightRefresh(cellNode ?: node)) {
        ApolloLPLogOncePerHost(host, @"V12-scrollview-height-refresh");
    }
}

static void ApolloLPTriggerRelayoutInternal(ASDisplayNode *node, BOOL scheduleDelayed, NSString *host) {
    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
    NSUInteger depth = 0;
    for (ASDisplayNode *current = node; current && depth < 32; current = current.supernode, depth++) {
        SEL invalidate = @selector(invalidateCalculatedLayout);
        if ([current respondsToSelector:invalidate]) {
            ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        }

        SEL relayout = NSSelectorFromString(@"_u_setNeedsLayoutFromAbove");
        if ([current respondsToSelector:relayout]) {
            ((void (*)(id, SEL))objc_msgSend)(current, relayout);
        }

        SEL setNeedsLayout = @selector(setNeedsLayout);
        if ([current respondsToSelector:setNeedsLayout]) {
            ((void (*)(id, SEL))objc_msgSend)(current, setNeedsLayout);
        }
    }

    if (cellNode) {
        ApolloLPInvokeTransitionLayoutIfPossible(cellNode);
    }

    if (!scheduleDelayed) {
        ApolloLPInvokeContainerRelayoutIfPossible(node, cellNode, host);
    }

    if (scheduleDelayed) {
        __weak ASDisplayNode *weakNode = node;
        NSString *hostCopy = [host copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            ASDisplayNode *strongNode = weakNode;
            if (strongNode) ApolloLPTriggerRelayoutInternal(strongNode, NO, hostCopy);
        });
    }
}

static void ApolloLPTriggerRelayoutForHost(ASDisplayNode *node, NSString *host) {
    ApolloLPTriggerRelayoutInternal(node, YES, host);
}

static void ApolloLPTriggerPlaceholderContextRelayout(ASDisplayNode *node, NSString *host, ApolloLPContext fromContext, ApolloLPContext toContext) {
    if (!node) return;

    ApolloLog(@"[LinkPreviews] V12-placeholder-context-shrink-refresh host=%@ from=%@ to=%@",
              host ?: @"(nohost)", ApolloLPContextLogName(fromContext), ApolloLPContextLogName(toContext));
    ApolloLPTriggerRelayoutInternal(node, NO, host);
    ASDisplayNode *cellNode = ApolloLPFindOwningCellNode(node);
    ApolloLPInvokeRowReloadIfPossible(cellNode ?: node, host);

    __weak ASDisplayNode *weakNode = node;
    NSString *hostCopy = [host copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (!strongNode) return;
        ASDisplayNode *strongCellNode = ApolloLPFindOwningCellNode(strongNode);
        ApolloLPInvokeRowReloadIfPossible(strongCellNode ?: strongNode, hostCopy);
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

    NSUInteger recolored = 0;
    NSDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(node, &kApolloLinkPreviewNodesKey);
    if ([bundles isKindOfClass:[NSDictionary class]]) {
        for (NSDictionary *bundle in bundles.allValues) {
            if (![bundle isKindOfClass:[NSDictionary class]]) continue;
            ASDisplayNode *backgroundNode = bundle[@"background"];
            NSURL *url = bundle[@"url"];
            if (![url isKindOfClass:[NSURL class]]) continue;
            if (ApolloLPApplyCardBackgroundColor(node, backgroundNode, url, YES)) {
                recolored++;
            }
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
    NSDictionary<NSString *, NSDictionary *> *bundles = objc_getAssociatedObject(node, &kApolloLinkPreviewNodesKey);
    if (![bundles isKindOfClass:[NSDictionary class]]) return NO;

    for (NSDictionary *bundle in bundles.allValues) {
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
        ApolloLPRegisteredRecolorResult registeredResult = {0, 0};
        NSUInteger registeredInvalidated = 0;
        if (cardColorRefresh) {
            registeredResult = ApolloLPRecolorRegisteredLinkPreviewBackgrounds();
        } else {
            registeredInvalidated = ApolloLPInvalidateRegisteredLinkPreviewNodes(areaName ?: @"mode-change");
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

        NSUInteger visibleRecolored = 0;
        NSHashTable *visitedRecolorObjects = [NSHashTable weakObjectsHashTable];
        NSHashTable *visitedLayoutObjects = [NSHashTable weakObjectsHashTable];
        NSUInteger invalidatedNodes = 0;
        for (UIWindow *window in windows) {
            if (cardColorRefresh) {
                visibleRecolored += ApolloLPRecolorLinkPreviewBackgroundsInTree(window, 24, visitedRecolorObjects);
            }
            invalidatedNodes += ApolloLPInvalidateLinkButtonNodesInTree(window, 24, visitedLayoutObjects);
        }

        NSHashTable<UIView *> *visitedViews = [NSHashTable weakObjectsHashTable];
        NSUInteger refreshCount = 0;
        for (UIWindow *window in windows) {
            refreshCount += ApolloLPRefreshLinkPreviewScrollViewsInView(window, visitedViews);
        }

        if (cardColorRefresh) {
            ApolloLog(@"[LinkPreviews] V14-card-color-global-refresh area=%@ scrollViews=%lu linkNodes=%lu registeredNodes=%lu registeredRecolored=%lu visibleRecolored=%lu",
                      areaName ?: @"unknown",
                      (unsigned long)refreshCount,
                      (unsigned long)invalidatedNodes,
                      (unsigned long)registeredResult.nodes,
                      (unsigned long)registeredResult.recolored,
                      (unsigned long)visibleRecolored);
        } else {
            ApolloLog(@"[LinkPreviews] V14-mode-change-layout-refresh area=%@ scrollViews=%lu linkNodes=%lu registeredNodes=%lu",
                      areaName ?: @"unknown", (unsigned long)refreshCount, (unsigned long)invalidatedNodes, (unsigned long)registeredInvalidated);
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
    NSUInteger invalidated = ApolloLPInvalidateRegisteredLinkPreviewNodesForURL(url, @"translation-update-url");
    ApolloLog(@"[LinkPreviews] V15-translation-url-refresh host=%@ invalidated=%lu",
              ApolloLPHost(url) ?: @"(nohost)",
              (unsigned long)invalidated);
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

// Round 4 diagnostic flag: throttles the per-call logging so a feed scroll
// doesn't spam OSLog with the same host hundreds of times. We still want one
// entry per unique host per session so we can correlate hook activity with
// the user's screenshots.
static NSMutableSet<NSString *> *ApolloLPLoggedHosts(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void ApolloLPLogOncePerHost(NSString *host, NSString *event) {
    if (host.length == 0) host = @"(nohost)";
    NSString *key = [NSString stringWithFormat:@"%@|%@", host, event];
    @synchronized (ApolloLPLoggedHosts()) {
        if ([ApolloLPLoggedHosts() containsObject:key]) return;
        [ApolloLPLoggedHosts() addObject:key];
    }
    ApolloLog(@"[LinkPreviews] %@ host=%@", event, host);
}

static void ApolloLPLogMetadataOnce(NSString *host, ApolloLinkPreview *preview, ApolloLPArea area, NSInteger mode, ApolloLPContext context) {
    if (host.length == 0) host = @"(nohost)";
    NSString *key = [NSString stringWithFormat:@"%@|metadata-v10", host];
    @synchronized (ApolloLPLoggedHosts()) {
        if ([ApolloLPLoggedHosts() containsObject:key]) return;
        [ApolloLPLoggedHosts() addObject:key];
    }

    NSString *areaName = (area == ApolloLPAreaComments) ? @"comments" : @"body";
    NSString *cardName = (context == ApolloLPContextSelfText) ? @"hero" : @"compact";
    ApolloLog(@"[LinkPreviews] V12 metadata host=%@ area=%@ mode=%ld card=%@ site=%d title=%d desc=%d image=%d fallbackIcon=%d titleLen=%lu descLen=%lu",
              host,
              areaName,
              (long)mode,
              cardName,
              preview.siteName.length > 0,
              preview.title.length > 0,
              preview.desc.length > 0,
              preview.imageURL.absoluteString.length > 0,
              preview.imageIsFallbackIcon,
              (unsigned long)preview.title.length,
              (unsigned long)preview.desc.length);
}

static NSString *ApolloLPVariant(ApolloLPArea area, NSInteger mode, ApolloLPContext context, BOOL placeholder) {
    NSString *areaName = (area == ApolloLPAreaComments) ? @"comments" : @"body";
    NSString *contextName = (context == ApolloLPContextSelfText) ? @"hero" : @"compact";
    return [NSString stringWithFormat:@"%@-%@-mode%ld-%@", placeholder ? @"placeholder" : @"final", areaName, (long)mode, contextName];
}

static NSString *ApolloLPRenderSignature(NSURL *url, ApolloLinkPreview *preview, NSString *variant) {
    CGSize imageSize = preview.imageSize;
    return [NSString stringWithFormat:@"%@|%@|%ld|%@|%@|%@|%@|%@|%@|%@|%@|%@|%.1fx%.1f|%d",
            variant ?: @"",
            url.absoluteString ?: @"",
            (long)sLinkPreviewCardColor,
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

static NSMutableDictionary<NSString *, NSNumber *> *ApolloLPConsecutiveDuplicateRenderCounts(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static BOOL ApolloLPMarkRenderSignatureIfChanged(ASDisplayNode *hostNode, NSString *variant, NSString *signature, NSString *host) {
    if (!hostNode || variant.length == 0 || signature.length == 0) return YES;

    NSMutableDictionary<NSString *, NSString *> *signatures = objc_getAssociatedObject(hostNode, &kApolloLinkPreviewRenderSignaturesKey);
    if (![signatures isKindOfClass:[NSMutableDictionary class]]) {
        signatures = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(hostNode, &kApolloLinkPreviewRenderSignaturesKey, signatures, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSString *lastSignature = signatures[variant];
    NSString *countKey = host.length > 0 ? host : @"(nohost)";
    if ([lastSignature isEqualToString:signature]) {
        ApolloLPLogOncePerHost(host, @"duplicate-render-signature");
        // Track consecutive duplicate-signature renders per host so a
        // follow-up log can confirm that re-entering a thread is no longer
        // producing extra paints. The "stable" log fires at most once per
        // host per session, on the third consecutive identical render.
        @synchronized (ApolloLPConsecutiveDuplicateRenderCounts()) {
            NSUInteger current = ApolloLPConsecutiveDuplicateRenderCounts()[countKey].unsignedIntegerValue;
            current += 1;
            ApolloLPConsecutiveDuplicateRenderCounts()[countKey] = @(current);
            if (current == 3) {
                ApolloLPLogOncePerHost(host, @"V17-thread-render-stable");
            }
        }
        return NO;
    }

    signatures[variant] = signature;
    @synchronized (ApolloLPConsecutiveDuplicateRenderCounts()) {
        [ApolloLPConsecutiveDuplicateRenderCounts() removeObjectForKey:countKey];
    }
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

static ASLayoutSpec *ApolloLPEmptyLayoutSpec(void) {
    Class layoutSpecCls = ApolloLPClass(@"ASLayoutSpec");
    if (!layoutSpecCls) return nil;

    ASLayoutSpec *empty = [[layoutSpecCls alloc] init];
    ApolloLPApplyStyleSize([empty style], CGSizeZero);
    return empty;
}

static id ApolloLPNativeLinkSpecWithBannedHintIfNeeded(id linkButtonNode, NSURL *url, id nativeSpec) {
    NSString *redditUsername = ApolloLPRedditUsernameFromProfileURL(url);
    if (redditUsername.length == 0 || !ApolloBannedProfileCachedIsSuspended(redditUsername)) {
        return nativeSpec;
    }
    return ApolloBannedProfileWrapLinkButtonSpecWithBannedHint(linkButtonNode, nativeSpec, redditUsername);
}

%hook _TtC6Apollo14LinkButtonNode

- (id)layoutSpecThatFits:(struct CDStruct_90e057aa)constrainedSize {
    NSString *urlString = ApolloGetLinkButtonNodeURLString(self);
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    ApolloLPPrefetchRedditUserProfileIfNeeded(url);

    if (ApolloLPAllModesDisabled()) {
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    if (!url) {
        ApolloLPLogOncePerHost(NSStringFromClass([(id)self class]), @"no-url");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }

    NSString *host = ApolloLPHost(url);
    ApolloLPArea area = ApolloLPAreaForLinkButton((ASDisplayNode *)self);

    // V17 diagnostic logging: per-node rate-limited (max 6 calls) snapshot of
    // area resolution + supernode chain depth to identify the vote-time
    // compact→hero flip. Always-on; gated by per-node counter to bound noise.
    {
        NSNumber *countObj = objc_getAssociatedObject(self, &kApolloLinkPreviewV17LogCountKey);
        NSUInteger count = [countObj isKindOfClass:[NSNumber class]] ? countObj.unsignedIntegerValue : 0;
        if (count < 6) {
            NSUInteger walkDepth = 0;
            ApolloLPArea walkArea = ApolloLPAreaBody;
            BOOL walkResolved = ApolloLPResolveAreaByWalk((ASDisplayNode *)self, &walkArea, &walkDepth);
            NSNumber *cached = objc_getAssociatedObject(self, &kApolloLinkPreviewAreaKey);
            ASDisplayNode *sup = [(id)self respondsToSelector:@selector(supernode)] ? [(id)self supernode] : nil;
            ApolloLog(@"[LinkPreviews] V17 layout host=%@ area=%lu cached=%@ walk=%d walkArea=%lu depth=%lu super=%@ bodyMode=%ld commentsMode=%ld n=%lu",
                      host, (unsigned long)area, cached, walkResolved, (unsigned long)walkArea, (unsigned long)walkDepth,
                      sup ? NSStringFromClass([sup class]) : @"(nil)",
                      (long)sLinkPreviewBodyMode, (long)sLinkPreviewCommentsMode, (unsigned long)count);
            objc_setAssociatedObject(self, &kApolloLinkPreviewV17LogCountKey, @(count + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (ApolloLPIsImageChestAlbumURL(url)) {
        ApolloLPLogOncePerHost(host, @"suppress-imagechest-card");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        ASLayoutSpec *empty = ApolloLPEmptyLayoutSpec();
        return empty ?: %orig;
    }

    NSInteger selectedMode = ApolloLPModeForArea(area);
    if (selectedMode == ApolloLinkPreviewModeOff) {
        ApolloLPLogOncePerHost(host, area == ApolloLPAreaComments ? @"comments-disabled" : @"body-disabled");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    if (ApolloLPShouldDeferToInlineMedia(url)) {
        ApolloLPLogOncePerHost(host, @"defer-inline-media");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }
    if ([ApolloLinkPreviewFetcher isTwitterURL:url]) {
        ApolloLPLogOncePerHost(host, @"defer-twitter");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return %orig;
    }
    ApolloLPInstallContextMenuForNode((ASDisplayNode *)self, url);

    ApolloLinkPreview *cached = [[ApolloLinkPreviewCache sharedCache] cachedPreviewForURL:url];
    if (cached && ApolloLPIsBlueskyPostURL(url) && !ApolloLPIsBlueskyPostPreview(url, cached)) {
        ApolloLPLogOncePerHost(host, @"stale-bluesky-inline-refetch");
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
            ApolloLPLogOncePerHost(host, staleRedditUserSuspension ? @"stale-reddit-user-suspension-refetch" : (staleRedditUser ? @"stale-reddit-user-refetch" : (staleRedditSubreddit ? @"stale-reddit-subreddit-refetch" : @"stale-reddit-empty-refetch")));
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
            ApolloLPLogOncePerHost(host, @"cache-miss-fetch");
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
                        ApolloLog(@"[LinkPreviews] V16-cache-url-refresh host=%@ invalidated=%lu",
                                  host ?: @"(nohost)",
                                  (unsigned long)invalidated);
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
            ApolloLPLogOncePerHost(host, area == ApolloLPAreaComments ? @"area-comments-placeholder" : @"area-body-placeholder");
            ApolloLPLogOncePerHost(host, placeholderContext == ApolloLPContextSelfText ? @"mode-full-placeholder" : @"mode-compact-placeholder");
            ApolloLPLogOncePerHost(host, placeholderContext == ApolloLPContextSelfText ? @"render-hero-placeholder" : @"render-compact-placeholder");
            return placeholder;
        }
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    if (![cached hasUsefulMetadata]) {
        ApolloLPLogOncePerHost(host, @"cache-hit-empty");
        ApolloLPRestoreHostShell((ASDisplayNode *)self);
        return ApolloLPNativeLinkSpecWithBannedHintIfNeeded(self, url, %orig);
    }

    BOOL isRedditUser = ApolloLPIsRedditUserPreview(url, cached);
    BOOL isRedditSubreddit = ApolloLPIsRedditSubredditPreview(url, cached);
    ApolloLinkPreview *displayPreview = (isRedditUser || isRedditSubreddit) ? cached : ApolloLPPreviewByApplyingTranslation((ASDisplayNode *)self, url, cached);
    BOOL isBlueskyPost = ApolloLPIsBlueskyPostPreview(url, displayPreview);
    ApolloLPContext context = isBlueskyPost ? ApolloLPContextSelfText : ((isRedditUser || isRedditSubreddit) ? ApolloLPContextCompact : ApolloLPContextForMode(selectedMode, displayPreview));
    ApolloLPLogMetadataOnce(host, displayPreview, area, selectedMode, context);
    if (!isBlueskyPost && !isRedditUser && !isRedditSubreddit && displayPreview.imageIsFallbackIcon) {
        ApolloLPRememberCompactPlaceholderHost(url);
        ApolloLPLogOncePerHost(host, @"fallback-icon-compact");
    } else if (!isBlueskyPost && !isRedditUser && !isRedditSubreddit && selectedMode == ApolloLinkPreviewModeFull && context == ApolloLPContextCompact) {
        ApolloLPRememberCompactPlaceholderHost(url);
        ApolloLPLogOncePerHost(host, @"full-fallback-compact");
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
        if (renderedPlaceholder) {
            objc_setAssociatedObject(self, &kApolloLinkPreviewRenderedPlaceholderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak ASDisplayNode *weakSelf = (ASDisplayNode *)self;
            NSString *hostCopy = [host copy];
            ApolloLPContext placeholderContext = (ApolloLPContext)[renderedPlaceholder unsignedIntegerValue];
            BOOL placeholderShrankToCompact = placeholderContext == ApolloLPContextSelfText && context == ApolloLPContextCompact;
            dispatch_async(dispatch_get_main_queue(), ^{
                ASDisplayNode *strongSelf = weakSelf;
                if (!strongSelf) return;
                ApolloLPLogOncePerHost(hostCopy, @"V12-post-final-height-refresh");
                if (placeholderShrankToCompact) {
                    ApolloLPTriggerPlaceholderContextRelayout(strongSelf, hostCopy, placeholderContext, context);
                } else {
                    ApolloLPTriggerRelayoutForHost(strongSelf, hostCopy);
                }
            });
        }
        ApolloLPClearHostShell((ASDisplayNode *)self);
        ApolloLPLogOncePerHost(host, area == ApolloLPAreaComments ? @"area-comments" : @"area-body");
        ApolloLPLogOncePerHost(host, isBlueskyPost ? @"mode-bluesky-post" : (isRedditUser ? @"mode-reddit-user" : (isRedditSubreddit ? @"mode-reddit-subreddit" : (context == ApolloLPContextSelfText ? @"mode-full" : @"mode-compact"))));
        ApolloLPLogOncePerHost(host, isBlueskyPost ? @"render-bluesky-post" : (isRedditUser ? @"render-reddit-user" : (isRedditSubreddit ? @"render-reddit-subreddit" : (context == ApolloLPContextSelfText ? @"render-hero" : @"render-compact"))));
        return richSpec;
    }
    ApolloLPLogOncePerHost(host, @"build-failed");
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
        } else {
            ApolloLog(@"[LinkPreviews] V15-translation-refresh-ignored reason=%@", reason ?: @"unknown");
        }
    }];

    ApolloLog(@"[LinkPreviews] ctor: hook installed for _TtC6Apollo14LinkButtonNode bodyMode=%ld commentsMode=%ld cardColor=%ld", (long)sLinkPreviewBodyMode, (long)sLinkPreviewCommentsMode, (long)sLinkPreviewCardColor);
    ApolloLog(@"[LinkPreviews] V5 polish active");
    ApolloLog(@"[LinkPreviews] V6 image-kind polish active");
    ApolloLog(@"[LinkPreviews] V7 display modes and placeholders active");
    ApolloLog(@"[LinkPreviews] V8 borderless cards active");
    ApolloLog(@"[LinkPreviews] V9 split body/comment modes active");
    ApolloLog(@"[LinkPreviews] V10 preview text restore active");
    ApolloLog(@"[LinkPreviews] V11 hero-card stability and naked-URL hiding active");
    ApolloLog(@"[LinkPreviews] V13 preset card colors and instant color refresh active");
    ApolloLog(@"[LinkPreviews] V12 cleanup hero sizing active");
    ApolloLog(@"[LinkPreviews] V12 hero image ratio cap 0.6 + nature/client-challenge bypass active");
    ApolloLog(@"[LinkPreviews] V14 translation-aware metadata text active");
    ApolloLog(@"[LinkPreviews] V15 targeted translation refresh active");
}
