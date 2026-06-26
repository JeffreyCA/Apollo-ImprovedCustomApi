#import <PhotosUI/PhotosUI.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloState.h"
#import "ApolloCommon.h"
#import "ApolloSubredditCustomBannerCache.h"
#import "ApolloSubredditCustomIconCache.h"
#import "ApolloSubredditDefaultAssets.h"
#import "ApolloSubredditInfoCache.h"
#import "ApolloUserProfileCache.h"
#import "ApolloSubredditHighlights.h"

// Mirrors the profile-banner pattern in ApolloUserAvatars.xm exactly:
// - Only hooks `_TtC6Apollo19PostsViewController`.
// - Wraps `tableView.tableHeaderView` -- our header view sits above the
//   native Apollo header content in a wrapper UIView, which becomes the
//   new tableHeaderView.
// - No scroll fighting. No force-top, no setContentOffset hook, no pinning.
//   Apollo's tableview runs untouched.
// - Subreddit-name detection requires either a real ivar/property on the
//   controller or a slug-shaped navigation title; we never match by
//   class-name substring so global search-results VCs don't get a header.

static CGFloat const ApolloSubredditBannerHeight = 120.0;
static CGFloat const ApolloSubredditIconDiameter = 72.0;
static CGFloat const ApolloSubredditHeaderBottomPadding = 16.0;
static CGFloat const ApolloSubredditSidePadding = 20.0;
static CGFloat const ApolloSubredditAboutMaxHeight = 180.0;
static CGFloat const ApolloSubredditTopSpacing = 10.0;

static const void *kApolloSubredditHeaderViewKey = &kApolloSubredditHeaderViewKey;
static const void *kApolloSubredditWrappedHeaderKey = &kApolloSubredditWrappedHeaderKey;
static const void *kApolloSubredditOriginalHeaderKey = &kApolloSubredditOriginalHeaderKey;
static const void *kApolloSubredditNameKey = &kApolloSubredditNameKey;
static const void *kApolloSubredditWrapperMarkerKey = &kApolloSubredditWrapperMarkerKey;
// Set on the UITableView itself so our hooks can fast-path out for every
// scrollview/tableview in the app except the few we actually patched.
static const void *kApolloSubredditManagedTableKey = &kApolloSubredditManagedTableKey;
// Strong ref to our header view stored on the table -- used by the
// setTableHeaderView hook to re-wrap on the fly without needing a VC lookup.
static const void *kApolloSubredditTableManagedHeaderKey = &kApolloSubredditTableManagedHeaderKey;
// Guard so the setTableHeaderView re-wrap can call %orig without recursing.
static const void *kApolloSubredditRewrapInProgressKey = &kApolloSubredditRewrapInProgressKey;
// Weak-ish ownership path back to the live PostsViewController; used so the
// table hook can keep controller/bookkeeping aligned when Apollo swaps the
// native header during search transitions.
static const void *kApolloSubredditManagedViewControllerKey = &kApolloSubredditManagedViewControllerKey;
static const void *kApolloSubredditTeardownMarkerKey = &kApolloSubredditTeardownMarkerKey;
static const void *kApolloSubredditBannerPickerCoordinatorKey = &kApolloSubredditBannerPickerCoordinatorKey;
static const void *kApolloSubredditIconPickerCoordinatorKey = &kApolloSubredditIconPickerCoordinatorKey;
static const void *kApolloSubredditInstallInProgressKey = &kApolloSubredditInstallInProgressKey;

static Class sPostsViewControllerClass = Nil;

typedef NS_ENUM(NSInteger, ApolloSubredditHeaderAssetKind) {
    ApolloSubredditHeaderAssetKindBanner = 0,
    ApolloSubredditHeaderAssetKindIcon = 1,
};

@class ApolloSubredditHeaderView;

@interface ApolloSubredditHeaderPickerCoordinator : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic, weak) ApolloSubredditHeaderView *headerView;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic) ApolloSubredditHeaderAssetKind assetKind;
@end

@interface ApolloSubredditHeaderView : UIView
@property(nonatomic, strong) UIImageView *bannerImageView;
@property(nonatomic, strong) UIImageView *iconImageView;
@property(nonatomic, strong) UILabel *displayNameLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *aboutLabel;
@property(nonatomic, weak) UIViewController *hostViewController;
@property(nonatomic, copy) NSString *subredditName;
@property(nonatomic) BOOL usesCustomBanner;
@property(nonatomic) BOOL usesCustomIcon;
@property(nonatomic, copy) void (^heightInvalidationBlock)(void);
- (void)applyInfo:(ApolloSubredditInfo *)info fallbackSubredditName:(NSString *)subredditName;
- (void)apollo_bannerTapped;
- (void)apollo_iconTapped;
- (void)apollo_presentPhotoPickerForAssetKind:(ApolloSubredditHeaderAssetKind)assetKind;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

@interface ApolloSubredditHeaderWrapperView : UIView
@property(nonatomic, strong) ApolloSubredditHeaderView *apolloHeaderView;
@property(nonatomic, strong) UIView *apolloOriginalHeaderView;
@end

static void ApolloSubredditLoadImages(ApolloSubredditHeaderView *header, NSString *subredditName, BOOL forceRefresh);
static void ApolloSubredditApplyBannerForHeader(ApolloSubredditHeaderView *header, NSString *subredditName, ApolloSubredditInfo *info);
static void ApolloSubredditApplyIconForHeader(ApolloSubredditHeaderView *header, NSString *subredditName, ApolloSubredditInfo *info);
static void ApolloSubredditDismissHeaderPickersForViewController(UIViewController *viewController);
static void ApolloSubredditRefreshBannerForSubreddit(NSString *subredditName);
static void ApolloSubredditRefreshIconForSubreddit(NSString *subredditName);
static BOOL ApolloSubredditNamesEqual(NSString *left, NSString *right);
static void ApolloSubredditLayoutWrappedHeader(UIView *wrappedHeader,
                                               ApolloSubredditHeaderView *header,
                                               UIView *originalHeader,
                                               CGFloat width);
static void ApolloSubredditSyncAssociations(UITableView *tableView,
                                            UIViewController *viewController,
                                            ApolloSubredditHeaderView *header,
                                            UIView *wrappedHeader,
                                            UIView *originalHeader);
static void ApolloSubredditInstallOrUpdateHeader(UIViewController *viewController);
static void ApolloSubredditTearDownHeader(UIViewController *viewController, BOOL restoreNativeHeader);
static void ApolloSubredditScheduleRepairPasses(UIViewController *viewController, NSString *reason);

@implementation ApolloSubredditHeaderView {
    // Memoized about-text height; layoutSubviews fires often while scrolling, so
    // avoid re-measuring the about string every pass. Keyed on text/font/width.
    CGFloat _cachedAboutHeight;
    CGFloat _cachedAboutWidth;
    NSString *_cachedAboutText;
    UIFont *_cachedAboutFont;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        _bannerImageView = [[UIImageView alloc] init];
        _bannerImageView.backgroundColor = [UIColor clearColor];
        _bannerImageView.contentMode = UIViewContentModeScaleAspectFill;
        _bannerImageView.clipsToBounds = YES;
        _bannerImageView.userInteractionEnabled = YES;
        _bannerImageView.isAccessibilityElement = YES;
        _bannerImageView.accessibilityLabel = @"Subreddit banner";
        _bannerImageView.accessibilityHint = @"Double tap to change banner photo";
        UITapGestureRecognizer *bannerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_bannerTapped)];
        [_bannerImageView addGestureRecognizer:bannerTap];
        [self addSubview:_bannerImageView];

        _iconImageView = [[UIImageView alloc] init];
        _iconImageView.backgroundColor = [UIColor clearColor];
        _iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        _iconImageView.clipsToBounds = YES;
        _iconImageView.userInteractionEnabled = YES;
        _iconImageView.isAccessibilityElement = YES;
        _iconImageView.accessibilityLabel = @"Subreddit icon";
        _iconImageView.accessibilityHint = @"Double tap to change subreddit icon";
        UITapGestureRecognizer *iconTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_iconTapped)];
        [_iconImageView addGestureRecognizer:iconTap];
        [self addSubview:_iconImageView];

        _displayNameLabel = [[UILabel alloc] init];
        _displayNameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        _displayNameLabel.textColor = [UIColor labelColor];
        _displayNameLabel.numberOfLines = 2;
        _displayNameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_displayNameLabel];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _nameLabel.textColor = [UIColor secondaryLabelColor];
        _nameLabel.numberOfLines = 1;
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_nameLabel];

        _aboutLabel = [[UILabel alloc] init];
        _aboutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _aboutLabel.textColor = [UIColor labelColor];
        _aboutLabel.numberOfLines = 0;
        _aboutLabel.adjustsFontForContentSizeCategory = YES;
        [self addSubview:_aboutLabel];
    }
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.displayNameLabel.textColor = [UIColor labelColor];
    self.nameLabel.textColor = [UIColor secondaryLabelColor];
    self.aboutLabel.textColor = [UIColor labelColor];
}

- (CGFloat)apollo_aboutHeightForWidth:(CGFloat)width {
    NSString *text = self.aboutLabel.text;
    if (self.aboutLabel.hidden || text.length == 0 || width <= 0.0) return 0.0;

    UIFont *font = self.aboutLabel.font;
    if (_cachedAboutText == text && _cachedAboutFont == font && _cachedAboutWidth == width) {
        return _cachedAboutHeight;
    }

    CGRect rect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:@{NSFontAttributeName: font ?: [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]}
                                     context:nil];
    CGFloat height = MIN(ApolloSubredditAboutMaxHeight, MAX(18.0, ceil(rect.size.height)));

    _cachedAboutText = text;
    _cachedAboutFont = font;
    _cachedAboutWidth = width;
    _cachedAboutHeight = height;
    return height;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    CGFloat bannerBottom = ApolloSubredditTopSpacing + ApolloSubredditBannerHeight;
    CGFloat iconBottom = bannerBottom - 20.0 + ApolloSubredditIconDiameter;
    CGFloat nameTop = bannerBottom + 12.0;
    CGFloat aboutY = MAX(iconBottom + 12.0, nameTop + 46.0);
    CGFloat aboutWidth = MAX(120.0, width - ApolloSubredditSidePadding * 2.0);
    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:aboutWidth];
    if (aboutHeight <= 0.0) return aboutY + ApolloSubredditHeaderBottomPadding;
    return aboutY + aboutHeight + ApolloSubredditHeaderBottomPadding;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    NSArray<UIView *> *expectedSubviews = @[self.bannerImageView, self.iconImageView,
                                            self.displayNameLabel, self.nameLabel,
                                            self.aboutLabel];
    for (UIView *subview in expectedSubviews) {
        if (subview && subview.superview != self) {
            [self addSubview:subview];
        }
    }
    self.bannerImageView.hidden = NO;
    self.iconImageView.hidden = NO;
    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    self.bannerImageView.alpha = 1.0;
    self.iconImageView.alpha = 1.0;
    self.displayNameLabel.alpha = 1.0;
    self.nameLabel.alpha = 1.0;
    self.aboutLabel.alpha = 1.0;

    CGFloat width = self.bounds.size.width;
    CGFloat bannerY = ApolloSubredditTopSpacing;
    CGFloat bannerBottom = bannerY + ApolloSubredditBannerHeight;
    self.bannerImageView.frame = CGRectMake(0.0, bannerY, width, ApolloSubredditBannerHeight);

    CGRect iconFrame = CGRectMake(ApolloSubredditSidePadding, bannerBottom - 20.0, ApolloSubredditIconDiameter, ApolloSubredditIconDiameter);
    self.iconImageView.frame = iconFrame;
    self.iconImageView.layer.cornerRadius = ApolloSubredditIconDiameter / 2.0;

    CGFloat textX = CGRectGetMaxX(iconFrame) + 14.0;
    CGFloat textWidth = MAX(80.0, width - textX - ApolloSubredditSidePadding);
    self.displayNameLabel.frame = CGRectMake(textX, bannerBottom + 12.0, textWidth, 24.0);
    self.nameLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.displayNameLabel.frame) + 2.0, textWidth, 18.0);

    CGFloat aboutY = MAX(CGRectGetMaxY(iconFrame) + 12.0, CGRectGetMaxY(self.nameLabel.frame) + 10.0);
    CGFloat aboutWidth = MAX(120.0, width - ApolloSubredditSidePadding * 2.0);
    CGFloat aboutHeight = [self apollo_aboutHeightForWidth:aboutWidth];
    self.aboutLabel.frame = CGRectMake(ApolloSubredditSidePadding, aboutY, aboutWidth, aboutHeight);

    [self bringSubviewToFront:self.iconImageView];
    [self bringSubviewToFront:self.displayNameLabel];
    [self bringSubviewToFront:self.nameLabel];
    [self bringSubviewToFront:self.aboutLabel];
}

- (void)applyInfo:(ApolloSubredditInfo *)info fallbackSubredditName:(NSString *)subredditName {
    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    CGFloat heightBefore = [self preferredHeightForWidth:width];

    NSString *displayName = info.displayName.length > 0 ? info.displayName : [@"r/" stringByAppendingString:subredditName ?: @""];
    self.displayNameLabel.text = displayName.length > 0 ? displayName : nil;
    self.nameLabel.text = subredditName.length > 0 ? [@"r/" stringByAppendingString:subredditName] : nil;
    if ([self.displayNameLabel.text isEqualToString:self.nameLabel.text]) self.nameLabel.text = nil;
    self.aboutLabel.text = info.aboutText.length > 0 ? info.aboutText : nil;

    self.displayNameLabel.hidden = self.displayNameLabel.text.length == 0;
    self.nameLabel.hidden = self.nameLabel.text.length == 0;
    self.aboutLabel.hidden = self.aboutLabel.text.length == 0;
    [self setNeedsLayout];

    CGFloat heightAfter = [self preferredHeightForWidth:width];
    if (heightBefore != heightAfter && self.heightInvalidationBlock) {
        self.heightInvalidationBlock();
    }
}

- (void)apollo_presentPhotoPickerForAssetKind:(ApolloSubredditHeaderAssetKind)assetKind {
    UIViewController *host = self.hostViewController;
    NSString *subredditName = self.subredditName;
    if (!host || subredditName.length == 0 || !sShowSubredditHeaders) return;
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter imagesFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        ApolloSubredditHeaderPickerCoordinator *coordinator = [[ApolloSubredditHeaderPickerCoordinator alloc] init];
        coordinator.headerView = self;
        coordinator.subredditName = subredditName;
        coordinator.assetKind = assetKind;
        picker.delegate = coordinator;
        const void *key = assetKind == ApolloSubredditHeaderAssetKindIcon
            ? kApolloSubredditIconPickerCoordinatorKey
            : kApolloSubredditBannerPickerCoordinatorKey;
        objc_setAssociatedObject(host, key, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host presentViewController:picker animated:YES completion:nil];
    }
}

- (void)apollo_bannerTapped {
    UIViewController *host = self.hostViewController;
    NSString *subredditName = self.subredditName;
    if (!host || subredditName.length == 0 || !sShowSubredditHeaders) return;

    ApolloSubredditCustomBannerCache *customCache = [ApolloSubredditCustomBannerCache sharedCache];
    BOOL hasCustom = [customCache hasCustomBannerForSubreddit:subredditName];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose Photo"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf apollo_presentPhotoPickerForAssetKind:ApolloSubredditHeaderAssetKindBanner];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove Custom Banner"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [customCache removeBannerForSubreddit:subredditName];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self.bannerImageView;
        sheet.popoverPresentationController.sourceRect = self.bannerImageView.bounds;
    }
    [host presentViewController:sheet animated:YES completion:nil];
}

- (void)apollo_iconTapped {
    UIViewController *host = self.hostViewController;
    NSString *subredditName = self.subredditName;
    if (!host || subredditName.length == 0 || !sShowSubredditHeaders) return;

    ApolloSubredditCustomIconCache *customCache = [ApolloSubredditCustomIconCache sharedCache];
    BOOL hasCustom = [customCache hasCustomIconForSubreddit:subredditName];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose Photo"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf apollo_presentPhotoPickerForAssetKind:ApolloSubredditHeaderAssetKindIcon];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove Custom Icon"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [customCache removeIconForSubreddit:subredditName];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.sourceView = self.iconImageView;
        sheet.popoverPresentationController.sourceRect = self.iconImageView.bounds;
    }
    [host presentViewController:sheet animated:YES completion:nil];
}

@end

@implementation ApolloSubredditHeaderPickerCoordinator

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    UIViewController *presenter = picker.presentingViewController;
    ApolloSubredditHeaderView *header = self.headerView;
    NSString *subredditName = self.subredditName;
    ApolloSubredditHeaderAssetKind assetKind = self.assetKind;
    const void *key = assetKind == ApolloSubredditHeaderAssetKindIcon
        ? kApolloSubredditIconPickerCoordinatorKey
        : kApolloSubredditBannerPickerCoordinatorKey;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (presenter) {
            objc_setAssociatedObject(presenter, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }];

    PHPickerResult *result = results.firstObject;
    if (!result || subredditName.length == 0) return;

    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:[UIImage class]]) return;

    [provider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
        if (error || ![object isKindOfClass:[UIImage class]]) return;
        UIImage *image = (UIImage *)object;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *saveError = nil;
            BOOL saved = NO;
            if (assetKind == ApolloSubredditHeaderAssetKindIcon) {
                saved = [[ApolloSubredditCustomIconCache sharedCache] saveIcon:image forSubreddit:subredditName error:&saveError];
            } else {
                saved = [[ApolloSubredditCustomBannerCache sharedCache] saveBanner:image forSubreddit:subredditName error:&saveError];
            }
            if (saved) {
                if (header && ApolloSubredditNamesEqual(header.subredditName, subredditName)) {
                    ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
                    if (assetKind == ApolloSubredditHeaderAssetKindIcon) {
                        ApolloSubredditApplyIconForHeader(header, subredditName, info);
                    } else {
                        ApolloSubredditApplyBannerForHeader(header, subredditName, info);
                    }
                    [header setNeedsLayout];
                    [header layoutIfNeeded];
                }
                return;
            }

            UIViewController *host = header.hostViewController;
            if (!host) return;
            NSString *title = assetKind == ApolloSubredditHeaderAssetKindIcon ? @"Icon Not Saved" : @"Banner Not Saved";
            NSString *message = saveError.localizedDescription ?: @"Could not save the selected image.";
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [host presentViewController:alert animated:YES completion:nil];
        });
    }];
}

@end

@implementation ApolloSubredditHeaderWrapperView

- (void)layoutSubviews {
    [super layoutSubviews];

    ApolloSubredditHeaderView *header = self.apolloHeaderView;
    UIView *originalHeader = self.apolloOriginalHeaderView;
    if (!header) return;

    if (header.superview != self) {
        [self addSubview:header];
    }
    if (originalHeader && originalHeader.superview != self) {
        [self addSubview:originalHeader];
    }

    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    ApolloSubredditLayoutWrappedHeader(self, header, originalHeader, width);
    self.hidden = NO;
    self.alpha = 1.0;
    header.hidden = NO;
    header.alpha = 1.0;
}

@end

#pragma mark - Helpers

static BOOL ApolloSubredditShouldSkipViewController(UIViewController *viewController) {
    if (!viewController) return YES;
    if ([objc_getAssociatedObject(viewController, kApolloSubredditTeardownMarkerKey) boolValue]) return YES;
    if (viewController.isMovingFromParentViewController || viewController.isBeingDismissed) return YES;
    if (viewController.parentViewController == nil && viewController.presentingViewController == nil && viewController.view.window == nil) {
        return YES;
    }
    return NO;
}

static NSString *ApolloNormalizedSubredditName(NSString *subredditName) {
    if (![subredditName isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [subredditName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([clean hasPrefix:@"/r/"] || [clean hasPrefix:@"/R/"]) clean = [clean substringFromIndex:3];
    if ([clean hasPrefix:@"r/"] || [clean hasPrefix:@"R/"]) clean = [clean substringFromIndex:2];
    if (clean.length == 0) return nil;
    // Reject special feeds that aren't really single subreddits.
    NSArray<NSString *> *blocked = @[@"home", @"popular", @"all", @"search", @"profile",
                                     @"settings", @"inbox", @"friends", @"mod"];
    if ([blocked containsObject:clean.lowercaseString]) return nil;
    // Must look like a subreddit slug: letters/digits/underscores.
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
    if ([clean rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    return clean;
}

static BOOL ApolloSubredditNamesEqual(NSString *left, NSString *right) {
    NSString *normalizedLeft = ApolloNormalizedSubredditName(left);
    NSString *normalizedRight = ApolloNormalizedSubredditName(right);
    if (normalizedLeft.length == 0 || normalizedRight.length == 0) return NO;
    return [normalizedLeft caseInsensitiveCompare:normalizedRight] == NSOrderedSame;
}

static BOOL ApolloSubredditIsLikelyObjectPointer(id value) {
    if (!value) return NO;
    uintptr_t addr = (uintptr_t)(__bridge void *)value;
#if __arm64__
    // Tagged pointers are valid ObjC objects on arm64.
    if (addr & 0x1) return YES;
#endif
    // Reject inline Swift string bits and other non-heap addresses (e.g. 0x726563636f73 = "soccer").
    if (addr < 0x100000000ULL || addr > 0x8000000000ULL) return NO;
    return YES;
}

// Read a pointer-sized ObjC object ivar by name and validate it against an
// expected class. Reads the raw pointer at the ivar offset (rather than relying
// on object_getIvar + type encoding, which is unreliable for Swift-emitted
// ivars) and guards every read with isKindOfClass:, so a stale/garbage slot
// can't be mistaken for a real object.
static id ApolloSubredditTypedIvar(id object, NSString *name, Class expectedClass) {
    if (!object || name.length == 0 || !expectedClass) return nil;
    for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (!ivar) continue;
        ptrdiff_t offset = ivar_getOffset(ivar);
        void *raw = NULL;
        memcpy(&raw, (uint8_t *)(__bridge void *)object + offset, sizeof(raw));
        id value = (__bridge id)raw;
        if (!ApolloSubredditIsLikelyObjectPointer(value)) return nil;
        @try {
            return [value isKindOfClass:expectedClass] ? value : nil;
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

// PostsType is a Swift enum stored inline in the `currentPostsType` ivar; its
// case tag is the byte at offset 0x20 of that storage. Apollo sets it
// synchronously at init, so it tells us the feed kind immediately (unlike the
// `currentSubreddit` object, which is fetched asynchronously). Tag 0 is a named
// single subreddit and tag 5 is "random" (both backed by one subreddit); tag 1
// is a multireddit and the remaining tags are all/popular/home/profile feeds.
static const ptrdiff_t kApolloPostsTypeTagOffset = 0x20;
static const uint8_t kApolloPostsTypeSubreddit = 0;
static const uint8_t kApolloPostsTypeRandom = 5;

// Read the PostsType case tag. Returns NO (and leaves *tag untouched) when the
// ivar can't be found, so callers can degrade gracefully on future binaries.
static BOOL ApolloSubredditPostsTypeTag(id viewController, uint8_t *tag) {
    Ivar ivar = class_getInstanceVariable([viewController class], "currentPostsType");
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t value = 0;
    memcpy(&value, (uint8_t *)(__bridge void *)viewController + offset + kApolloPostsTypeTagOffset, sizeof(value));
    if (tag) *tag = value;
    return YES;
}

// Resolve the subreddit slug for Apollo's PostsViewController. This is the fix
// for #327: we gate on the synchronous PostsType tag so multireddit feeds (even
// when named like a real subreddit) and profile/special feeds (Upvoted, Hidden,
// All, Popular, ...) never install a header. For a genuine single-subreddit
// feed we use `currentSubreddit.name` once Apollo has fetched it, and otherwise
// fall back to the nav title so the header still appears instantly on
// navigation instead of waiting for that async object.
// Apollo's search-results VC is a different class and never reaches this hook.
static NSString *ApolloSubredditNameFromViewController(UIViewController *viewController) {
    if (!viewController) return nil;

    uint8_t tag = 0;
    BOOL haveTag = ApolloSubredditPostsTypeTag(viewController, &tag);
    if (haveTag && tag != kApolloPostsTypeSubreddit && tag != kApolloPostsTypeRandom) return nil;

    // Authoritative slug once Apollo has loaded the backing subreddit object.
    id subreddit = ApolloSubredditTypedIvar(viewController, @"currentSubreddit", objc_getClass("RDKSubreddit"));
    if (subreddit && [subreddit respondsToSelector:@selector(name)]) {
        id nameValue = ((id (*)(id, SEL))objc_msgSend)(subreddit, @selector(name));
        if ([nameValue isKindOfClass:[NSString class]]) {
            NSString *normalized = ApolloNormalizedSubredditName(nameValue);
            if (normalized.length) return normalized;
        }
    }

    // currentSubreddit is populated asynchronously; for a confirmed
    // single-subreddit feed (named or random) fall back to the nav title so the
    // header loads instantly. The tag is already known to be subreddit/random
    // here, so the title can't belong to a multireddit or profile feed.
    if (haveTag) {
        NSString *title = viewController.navigationItem.title;
        if (title.length == 0) title = viewController.title;
        return ApolloNormalizedSubredditName(title);
    }

    return nil;
}

static UIView *ApolloSubredditFindSubviewOfClass(UIView *root, Class cls) {
    if (!root || !cls) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *subview in root.subviews) {
        UIView *match = ApolloSubredditFindSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

static UITableView *ApolloSubredditFindTableView(UIViewController *viewController) {
    if ([viewController respondsToSelector:@selector(tableView)]) {
        UITableView *(*msgSend)(id, SEL) = (UITableView *(*)(id, SEL))objc_msgSend;
        id tableView = msgSend(viewController, @selector(tableView));
        if ([tableView isKindOfClass:[UITableView class]]) return tableView;
    }
    return (UITableView *)ApolloSubredditFindSubviewOfClass(viewController.view, [UITableView class]);
}

static UIImage *ApolloSubredditPlaceholderIconForUserInterfaceStyle(UIUserInterfaceStyle style) {
    static UIImage *darkIcon = nil;
    static UIImage *lightIcon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat diameter = ApolloSubredditIconDiameter;
        CGFloat scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 2.0;
        CGSize size = CGSizeMake(diameter, diameter);
        UIColor *darkFill = [UIColor colorWithRed:39.0 / 255.0 green:39.0 / 255.0 blue:41.0 / 255.0 alpha:1.0];
        UIColor *lightFill = [UIColor colorWithRed:218.0 / 255.0 green:219.0 / 255.0 blue:220.0 / 255.0 alpha:1.0];

        UIImage *(^drawIcon)(UIColor *, UIColor *) = ^UIImage *(UIColor *fill, UIColor *textColor) {
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = scale;
            format.opaque = YES;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
            return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [fill setFill];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0.0, 0.0, diameter, diameter)] fill];

                NSString *label = @"r/";
                UIFont *font = [UIFont systemFontOfSize:diameter * 0.48 weight:UIFontWeightSemibold];
                NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: textColor};
                CGSize textSize = [label sizeWithAttributes:attrs];
                CGRect textRect = CGRectMake((diameter - textSize.width) / 2.0,
                                             (diameter - textSize.height) / 2.0,
                                             textSize.width,
                                             textSize.height);
                [label drawInRect:textRect withAttributes:attrs];
            }];
        };

        darkIcon = drawIcon(darkFill, UIColor.whiteColor);
        lightIcon = drawIcon(lightFill, UIColor.blackColor);
    });

    UIUserInterfaceStyle resolved = style;
    if (resolved == UIUserInterfaceStyleUnspecified) {
        resolved = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    if (@available(iOS 13.0, *)) {
        return resolved == UIUserInterfaceStyleDark ? darkIcon : lightIcon;
    }
    return darkIcon ?: lightIcon;
}

static UIImage *ApolloSubredditPlaceholderIcon(void) {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (@available(iOS 13.0, *)) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return ApolloSubredditPlaceholderIconForUserInterfaceStyle(style);
}

static UIImage *ApolloSubredditDefaultBanner(void) {
    static UIImage *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSData *data = [NSData dataWithBytesNoCopy:(void *)ApolloSubredditDefaultBannerJPG
                                            length:ApolloSubredditDefaultBannerJPG_len
                                      freeWhenDone:NO];
        cached = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
    });
    return cached;
}

static UIColor *ApolloSubredditBannerBackgroundColorForUserInterfaceStyle(UIUserInterfaceStyle style) {
    UIUserInterfaceStyle resolved = style;
    if (resolved == UIUserInterfaceStyleUnspecified) {
        resolved = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    if (@available(iOS 13.0, *)) {
        if (resolved == UIUserInterfaceStyleDark) {
            return [UIColor colorWithRed:39.0 / 255.0 green:39.0 / 255.0 blue:41.0 / 255.0 alpha:1.0];
        }
        return [UIColor colorWithRed:218.0 / 255.0 green:219.0 / 255.0 blue:220.0 / 255.0 alpha:1.0];
    }
    return [UIColor colorWithRed:39.0 / 255.0 green:39.0 / 255.0 blue:41.0 / 255.0 alpha:1.0];
}

static UIColor *ApolloSubredditBannerBackgroundColor(void) {
    UIUserInterfaceStyle style = UIUserInterfaceStyleUnspecified;
    if (@available(iOS 13.0, *)) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return ApolloSubredditBannerBackgroundColorForUserInterfaceStyle(style);
}

static void ApolloSubredditApplyLoadingBanner(ApolloSubredditHeaderView *header) {
    if (!header) return;
    header.bannerImageView.image = nil;
    header.bannerImageView.backgroundColor = ApolloSubredditBannerBackgroundColor();
}

static void ApolloSubredditApplyDefaultBanner(ApolloSubredditHeaderView *header) {
    if (!header) return;
    header.bannerImageView.image = ApolloSubredditDefaultBanner();
    header.bannerImageView.backgroundColor = [UIColor clearColor];
}

static void ApolloSubredditApplyPlaceholderIcon(ApolloSubredditHeaderView *header) {
    if (!header) return;
    header.iconImageView.image = ApolloSubredditPlaceholderIcon();
    header.iconImageView.backgroundColor = [UIColor clearColor];
}

static void ApolloSubredditDismissHeaderPickersForViewController(UIViewController *viewController) {
    if (!viewController) return;
    UIViewController *presented = viewController.presentedViewController;
    if ([presented isKindOfClass:[PHPickerViewController class]]) {
        [presented dismissViewControllerAnimated:NO completion:nil];
    }
    objc_setAssociatedObject(viewController, kApolloSubredditBannerPickerCoordinatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditIconPickerCoordinatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloSubredditApplyBannerForHeader(ApolloSubredditHeaderView *header, NSString *subredditName, ApolloSubredditInfo *info) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditCustomBannerCache *customCache = [ApolloSubredditCustomBannerCache sharedCache];
    UIImage *customBanner = [customCache cachedBannerForSubreddit:subredditName];
    if (customBanner) {
        header.bannerImageView.image = customBanner;
        header.bannerImageView.backgroundColor = [UIColor clearColor];
        header.usesCustomBanner = YES;
        return;
    }

    header.usesCustomBanner = NO;
    if (info.bannerURL) {
        ApolloUserProfileCache *imageCache = [ApolloUserProfileCache sharedCache];
        UIImage *banner = [imageCache cachedImageForURL:info.bannerURL];
        if (banner) {
            header.bannerImageView.image = banner;
            header.bannerImageView.backgroundColor = [UIColor clearColor];
            return;
        }

        ApolloSubredditApplyLoadingBanner(header);

        __weak ApolloSubredditHeaderView *weakHeader = header;
        NSURL *bannerURL = info.bannerURL;
        [imageCache requestImageForURL:bannerURL completion:^(UIImage *image) {
            ApolloSubredditHeaderView *strongHeader = weakHeader;
            if (!strongHeader || strongHeader.usesCustomBanner) return;
            if ([[ApolloSubredditCustomBannerCache sharedCache] hasCustomBannerForSubreddit:subredditName]) return;
            if (image) {
                strongHeader.bannerImageView.image = image;
                strongHeader.bannerImageView.backgroundColor = [UIColor clearColor];
            } else {
                ApolloSubredditApplyDefaultBanner(strongHeader);
            }
        }];
        return;
    }

    if (info) {
        ApolloSubredditApplyDefaultBanner(header);
    } else {
        ApolloSubredditApplyLoadingBanner(header);
    }
}

static void ApolloSubredditApplyIconForHeader(ApolloSubredditHeaderView *header, NSString *subredditName, ApolloSubredditInfo *info) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditCustomIconCache *customCache = [ApolloSubredditCustomIconCache sharedCache];
    UIImage *customIcon = [customCache cachedIconForSubreddit:subredditName];
    if (customIcon) {
        header.iconImageView.image = customIcon;
        header.iconImageView.backgroundColor = [UIColor clearColor];
        header.usesCustomIcon = YES;
        return;
    }

    header.usesCustomIcon = NO;
    if (info.iconURL) {
        ApolloUserProfileCache *imageCache = [ApolloUserProfileCache sharedCache];
        UIImage *icon = [imageCache cachedImageForURL:info.iconURL];
        if (icon) {
            header.iconImageView.image = icon;
            header.iconImageView.backgroundColor = [UIColor clearColor];
            return;
        }

        __weak ApolloSubredditHeaderView *weakHeader = header;
        NSURL *iconURL = info.iconURL;
        [imageCache requestImageForURL:iconURL completion:^(UIImage *image) {
            ApolloSubredditHeaderView *strongHeader = weakHeader;
            if (!strongHeader || strongHeader.usesCustomIcon) return;
            if ([[ApolloSubredditCustomIconCache sharedCache] hasCustomIconForSubreddit:subredditName]) return;
            if (image) {
                strongHeader.iconImageView.image = image;
                strongHeader.iconImageView.backgroundColor = [UIColor clearColor];
            } else {
                ApolloSubredditApplyPlaceholderIcon(strongHeader);
            }
        }];
        return;
    }

    ApolloSubredditApplyPlaceholderIcon(header);
}

static ApolloSubredditHeaderView *ApolloSubredditCreateHeader(CGFloat width) {
    ApolloSubredditHeaderView *header = [[ApolloSubredditHeaderView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, 210.0)];
    header.iconImageView.image = ApolloSubredditPlaceholderIcon();
    ApolloSubredditApplyLoadingBanner(header);
    return header;
}

static void ApolloSubredditLoadImages(ApolloSubredditHeaderView *header, NSString *subredditName, BOOL forceRefresh) {
    if (!header || subredditName.length == 0) return;

    ApolloSubredditInfoCache *cache = [ApolloSubredditInfoCache sharedCache];
    ApolloSubredditInfo *cachedInfo = [cache cachedInfoForSubreddit:subredditName];

    void (^applyInfo)(ApolloSubredditInfo *) = ^(ApolloSubredditInfo *info) {
        if (!info) {
            ApolloSubredditApplyBannerForHeader(header, subredditName, nil);
            ApolloSubredditApplyIconForHeader(header, subredditName, nil);
            return;
        }
        [header applyInfo:info fallbackSubredditName:subredditName];
        ApolloSubredditApplyIconForHeader(header, subredditName, info);
        ApolloSubredditApplyBannerForHeader(header, subredditName, info);
    };

    if (cachedInfo) applyInfo(cachedInfo);
    else {
        ApolloSubredditApplyBannerForHeader(header, subredditName, nil);
        ApolloSubredditApplyIconForHeader(header, subredditName, nil);
    }

    if (forceRefresh) {
        [cache refetchInfoForSubreddit:subredditName completion:applyInfo];
    } else {
        [cache requestInfoForSubreddit:subredditName completion:applyInfo];
    }
}

static void ApolloSubredditLayoutWrappedHeader(UIView *wrappedHeader,
                                               ApolloSubredditHeaderView *header,
                                               UIView *originalHeader,
                                               CGFloat width) {
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    wrappedHeader.frame = CGRectMake(0.0, 0.0, width, headerHeight + originalHeight);
    header.frame = CGRectMake(0.0, 0.0, width, headerHeight);
    if (originalHeader) originalHeader.frame = CGRectMake(0.0, headerHeight, width, originalHeight);
}

static UIView *ApolloSubredditBuildWrapper(ApolloSubredditHeaderView *header,
                                           UIView *originalHeader,
                                           CGFloat width) {
    if (!header) return nil;
    // When Community Highlights is on, host its carousel in the original-header
    // slot (a container stacking the carousel above Apollo's real header). The
    // sizing/positioning below then accounts for it automatically.
    if (sCommunityHighlights && header.subredditName.length) {
        originalHeader = ApolloHLHeaderOriginalSubstitute(header.subredditName, header.hostViewController, originalHeader, width);
    }
    CGFloat originalHeight = originalHeader ? originalHeader.frame.size.height : 0.0;
    CGFloat headerHeight = [header preferredHeightForWidth:width];
    ApolloSubredditHeaderWrapperView *wrapper = [[ApolloSubredditHeaderWrapperView alloc] initWithFrame:CGRectMake(0.0, 0.0, width, headerHeight + originalHeight)];
    wrapper.backgroundColor = [UIColor clearColor];
    wrapper.apolloHeaderView = header;
    wrapper.apolloOriginalHeaderView = originalHeader;
    [wrapper addSubview:header];
    if (originalHeader) [wrapper addSubview:originalHeader];
    ApolloSubredditLayoutWrappedHeader(wrapper, header, originalHeader, width);
    objc_setAssociatedObject(wrapper, kApolloSubredditWrapperMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wrapper, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(wrapper, kApolloSubredditOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    header.hidden = NO;
    header.alpha = 1.0;
    wrapper.hidden = NO;
    wrapper.alpha = 1.0;
    return wrapper;
}

static void ApolloSubredditSyncAssociations(UITableView *tableView,
                                            UIViewController *viewController,
                                            ApolloSubredditHeaderView *header,
                                            UIView *wrappedHeader,
                                            UIView *originalHeader) {
    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, wrappedHeader ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, viewController, OBJC_ASSOCIATION_ASSIGN);
    }
    if (viewController) {
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, wrappedHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, originalHeader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloSubredditTearDownHeader(UIViewController *viewController, BOOL restoreNativeHeader) {
    if (!viewController) return;

    objc_setAssociatedObject(viewController, kApolloSubredditTeardownMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey);

    ApolloLog(@"[SubredditHeaders] teardown vc=%p restoreNative=%d subreddit=%@",
              viewController, restoreNativeHeader, objc_getAssociatedObject(viewController, kApolloSubredditNameKey) ?: @"nil");

    if (header) {
        header.hostViewController = nil;
        header.heightInvalidationBlock = nil;
    }

    ApolloSubredditDismissHeaderPickersForViewController(viewController);

    if (tableView && restoreNativeHeader && wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        tableView.tableHeaderView = originalHeader;
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (header.superview == wrappedHeader) {
        [header removeFromSuperview];
    }
    if (originalHeader.superview == wrappedHeader) {
        [originalHeader removeFromSuperview];
    }

    if (tableView) {
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);

}

static void ApolloSubredditScheduleRepairPasses(UIViewController *viewController, NSString *reason) {
    if (!viewController || !sShowSubredditHeaders) return;
    if (ApolloSubredditShouldSkipViewController(viewController)) {
        ApolloLog(@"[SubredditHeaders] repair skipped vc=%p reason=%@", viewController, reason ?: @"unknown");
        return;
    }

    NSArray<NSNumber *> *delays = @[@0.0, @0.08, @0.20, @0.45];
    __weak UIViewController *weakViewController = viewController;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongViewController = weakViewController;
            if (!strongViewController || !sShowSubredditHeaders) return;
            if (ApolloSubredditShouldSkipViewController(strongViewController)) return;
            ApolloSubredditInstallOrUpdateHeader(strongViewController);
        });
    }
}

#pragma mark - Install / restore

static void ApolloSubredditRefreshBannerInTree(UIViewController *viewController,
                                               NSString *subredditName,
                                               NSHashTable *visited);
static void ApolloSubredditRefreshIconInTree(UIViewController *viewController,
                                             NSString *subredditName,
                                             NSHashTable *visited);

static void ApolloSubredditInstallOrUpdateHeader(UIViewController *viewController) {
    if (!viewController) return;
    if ([objc_getAssociatedObject(viewController, kApolloSubredditInstallInProgressKey) boolValue]) return;
    objc_setAssociatedObject(viewController, kApolloSubredditInstallInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
    if (ApolloSubredditShouldSkipViewController(viewController)) return;
    // Only install on Apollo's PostsViewController. The notification-refresh
    // walker previously trampled across RedditListVC / InboxListVC /
    // ApolloNavigationController because their nav titles happened to be
    // slug-shaped ("Subreddits" / "Boxes" / "Comments").
    static Class postsVCClass = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        postsVCClass = NSClassFromString(@"_TtC6Apollo19PostsViewController");
    });
    if (postsVCClass && ![viewController isKindOfClass:postsVCClass]) return;

    UITableView *tableView = ApolloSubredditFindTableView(viewController);
    if (!tableView) return;

    ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
    UIView *wrappedHeader = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey);
    UIView *originalHeader = objc_getAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey);

    // Auto-repair: if Apollo's close-search teardown removed any of our
    // internal subviews from the header, put them back.
    if (header) {
        BOOL repairedInner = NO;
        NSArray<UIView *> *expected = @[header.bannerImageView, header.iconImageView,
                                        header.displayNameLabel, header.nameLabel,
                                        header.aboutLabel];
        for (UIView *child in expected) {
            if (child && child.superview != header) {
                [header addSubview:child];
                repairedInner = YES;
            }
            if (child && child.hidden && child != header.aboutLabel && child != header.nameLabel) {
                if (child == header.bannerImageView || child == header.iconImageView || child == header.displayNameLabel) {
                    child.hidden = NO;
                    repairedInner = YES;
                }
            }
        }
        if (repairedInner) {
            [header setNeedsLayout];
            [header layoutIfNeeded];
        }
    }

    // Setting off -> restore the native tableHeaderView and drop our state.
    if (!sShowSubredditHeaders) {
        if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
            tableView.tableHeaderView = originalHeader;
        }
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    NSString *subredditName = ApolloSubredditNameFromViewController(viewController);
    if (subredditName.length == 0) {
        // Not a single-subreddit feed (multireddit, profile section, or special
        // feed). If this controller was reused and previously hosted our header,
        // restore the native header and drop our bookkeeping so we don't leave a
        // stale/mislabeled header behind. (#327)
        if (wrappedHeader && tableView.tableHeaderView == wrappedHeader) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = originalHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditOriginalHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(viewController, kApolloSubredditNameKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(tableView, kApolloSubredditManagedTableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tableView, kApolloSubredditTableManagedHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(tableView, kApolloSubredditManagedViewControllerKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }

    ApolloLog(@"[SubredditHeaders] install vc=%p subreddit=%@", viewController, subredditName);

    CGFloat width = tableView.bounds.size.width > 0 ? tableView.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (!header) {
        header = ApolloSubredditCreateHeader(width);
        objc_setAssociatedObject(viewController, kApolloSubredditHeaderViewKey, header, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Recover bookkeeping from the wrapper itself in case the VC's associated
    // objects fell out of sync (e.g. after a memory warning).
    UIView *currentTableHeader = tableView.tableHeaderView;
    if (currentTableHeader && objc_getAssociatedObject(currentTableHeader, kApolloSubredditWrapperMarkerKey)) {
        wrappedHeader = currentTableHeader;
        header = objc_getAssociatedObject(currentTableHeader, kApolloSubredditHeaderViewKey) ?: header;
        originalHeader = objc_getAssociatedObject(currentTableHeader, kApolloSubredditOriginalHeaderKey);
        ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);
    }

    header.hostViewController = viewController;
    header.subredditName = subredditName;
    __weak UIViewController *weakViewController = viewController;
    header.heightInvalidationBlock = ^{
        UIViewController *strongViewController = weakViewController;
        if (strongViewController) ApolloSubredditInstallOrUpdateHeader(strongViewController);
    };

    if (!wrappedHeader || tableView.tableHeaderView != wrappedHeader) {
        originalHeader = currentTableHeader;
        // Re-wrapping during install: ensure setTableHeaderView hook treats
        // this as our own write (no double-wrap recursion).
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wrappedHeader = ApolloSubredditBuildWrapper(header, originalHeader, width);
        ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);
        tableView.tableHeaderView = wrappedHeader;
        objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        BOOL repaired = NO;
        if (header.superview != wrappedHeader) {
            [wrappedHeader addSubview:header];
            repaired = YES;
        }
        if (originalHeader && originalHeader.superview == nil) {
            [wrappedHeader addSubview:originalHeader];
            repaired = YES;
        }

        CGRect frameBeforeLayout = wrappedHeader.frame;
        ApolloSubredditLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (repaired || !CGRectEqualToRect(frameBeforeLayout, wrappedHeader.frame)) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = wrappedHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    // Force-unhide every install pass in case Apollo's search-mode UI hides
    // tableHeaderView subviews to clear the chrome (this is the
    // "search-then-return shows empty space" failure mode).
    header.hidden = NO;
    header.alpha = 1.0;
    if (wrappedHeader) {
        wrappedHeader.hidden = NO;
        wrappedHeader.alpha = 1.0;
    }

    // Mark the table itself so our setTableHeaderView / setContentOffset hooks
    // can fast-path out for every other table in the app.
    ApolloSubredditSyncAssociations(tableView, viewController, header, wrappedHeader, originalHeader);

    NSString *storedSubredditName = objc_getAssociatedObject(viewController, kApolloSubredditNameKey);
    BOOL subredditChanged = ![storedSubredditName isEqualToString:subredditName];
    if (subredditChanged) {
        objc_setAssociatedObject(viewController, kApolloSubredditNameKey, subredditName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        header.iconImageView.image = ApolloSubredditPlaceholderIcon();
        header.usesCustomIcon = NO;
        header.usesCustomBanner = NO;
        ApolloSubredditApplyLoadingBanner(header);
        [header applyInfo:nil fallbackSubredditName:subredditName];
        ApolloSubredditLoadImages(header, subredditName, NO);
    }

    if (wrappedHeader && header) {
        CGRect frameBeforeMetadata = wrappedHeader.frame;
        ApolloSubredditLayoutWrappedHeader(wrappedHeader, header, originalHeader, width);
        if (!CGRectEqualToRect(frameBeforeMetadata, wrappedHeader.frame)) {
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tableView.tableHeaderView = wrappedHeader;
            objc_setAssociatedObject(tableView, kApolloSubredditRewrapInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    } @finally {
        objc_setAssociatedObject(viewController, kApolloSubredditInstallInProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ApolloSubredditRefreshBannerInTree(UIViewController *viewController,
                                               NSString *subredditName,
                                               NSHashTable *visited) {
    if (!viewController || subredditName.length == 0 || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if ([ApolloSubredditNameFromViewController(viewController) isEqualToString:subredditName]) {
        ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
        if (header) {
            ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
            ApolloSubredditApplyBannerForHeader(header, subredditName, info);
        }
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshBannerInTree(child, subredditName, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshBannerInTree(viewController.presentedViewController, subredditName, visited);
    }
}

static void ApolloSubredditRefreshBannerForSubreddit(NSString *subredditName) {
    if (subredditName.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            ApolloSubredditRefreshBannerInTree(window.rootViewController, subredditName, visited);
        }
    });
}

static void ApolloSubredditRefreshIconInTree(UIViewController *viewController,
                                             NSString *subredditName,
                                             NSHashTable *visited) {
    if (!viewController || subredditName.length == 0 || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    if ([ApolloSubredditNameFromViewController(viewController) isEqualToString:subredditName]) {
        ApolloSubredditHeaderView *header = objc_getAssociatedObject(viewController, kApolloSubredditHeaderViewKey);
        if (header) {
            ApolloSubredditInfo *info = [[ApolloSubredditInfoCache sharedCache] cachedInfoForSubreddit:subredditName];
            ApolloSubredditApplyIconForHeader(header, subredditName, info);
        }
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshIconInTree(child, subredditName, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshIconInTree(viewController.presentedViewController, subredditName, visited);
    }
}

static void ApolloSubredditRefreshIconForSubreddit(NSString *subredditName) {
    if (subredditName.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:16];
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            ApolloSubredditRefreshIconInTree(window.rootViewController, subredditName, visited);
        }
    });
}

static void ApolloSubredditRefreshViewControllersInTree(UIViewController *viewController, NSHashTable *visited) {
    if (!viewController || [visited containsObject:viewController]) return;
    [visited addObject:viewController];

    BOOL isPostsVC = sPostsViewControllerClass && [viewController isKindOfClass:sPostsViewControllerClass];
    BOOL alreadyWrapped = objc_getAssociatedObject(viewController, kApolloSubredditWrappedHeaderKey) != nil;
    if (isPostsVC || alreadyWrapped) {
        ApolloSubredditInstallOrUpdateHeader(viewController);
    }

    for (UIViewController *child in viewController.childViewControllers) {
        ApolloSubredditRefreshViewControllersInTree(child, visited);
    }
    if (viewController.presentedViewController) {
        ApolloSubredditRefreshViewControllersInTree(viewController.presentedViewController, visited);
    }
}

static void ApolloSubredditRefreshVisibleControllers(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSHashTable *visited = [[NSHashTable alloc] initWithOptions:NSHashTableObjectPointerPersonality capacity:64];
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            ApolloSubredditRefreshViewControllersInTree(window.rootViewController, visited);
        }
    });
}

#pragma mark - Hooks

// Apollo enters/exits search mode by mutating its tableHeaderView (sometimes
// replacing it with a different view, sometimes hiding subviews). The
// setTableHeaderView hook below re-wraps any view Apollo tries to install so
// our header view is always part of the live tableHeaderView. The
// force-unhide in install handles the subview-hiding case.
//
// Apollo also auto-scrolls past tableHeaderView once posts finish loading.
// The setContentOffset hooks block ONLY a scroll whose target Y exactly
// matches tableHeaderView.frame.size.height (within a few px), which is
// Apollo's specific "skip my header" signature. Search-mode scrolls and
// every other programmatic scroll have different targets and pass through.

%hook UITableView

- (void)setTableHeaderView:(UIView *)tableHeaderView {
    if (![objc_getAssociatedObject(self, kApolloSubredditManagedTableKey) boolValue]) {
        %orig;
        return;
    }
    if ([objc_getAssociatedObject(self, kApolloSubredditRewrapInProgressKey) boolValue]) {
        %orig;
        return;
    }
    // Already our wrapper -- nothing to do.
    if (tableHeaderView && objc_getAssociatedObject(tableHeaderView, kApolloSubredditWrapperMarkerKey)) {
        %orig;
        return;
    }
    ApolloSubredditHeaderView *ourHeader = objc_getAssociatedObject(self, kApolloSubredditTableManagedHeaderKey);
    if (!ourHeader || !sShowSubredditHeaders) {
        %orig;
        return;
    }

    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    UIView *wrapper = ApolloSubredditBuildWrapper(ourHeader, tableHeaderView, width);
    UIViewController *viewController = ourHeader.hostViewController;
    ApolloSubredditSyncAssociations(self, viewController, ourHeader, wrapper, tableHeaderView);
    %orig(wrapper);
    if (viewController) {
        ApolloSubredditScheduleRepairPasses(viewController, @"setTableHeaderView");
    }
}

- (void)layoutSubviews {
    %orig;
}
- (void)reloadData {
    %orig;
    if (![objc_getAssociatedObject(self, kApolloSubredditManagedTableKey) boolValue]) return;
    UIViewController *viewController = objc_getAssociatedObject(self, kApolloSubredditManagedViewControllerKey);
    if (viewController) {
        ApolloSubredditScheduleRepairPasses(viewController, @"reloadData");
    }
}

%end

static BOOL ApolloSubredditShouldBlockOffset(UITableView *tableView, CGPoint newOffset) {
    if (![objc_getAssociatedObject(tableView, kApolloSubredditManagedTableKey) boolValue]) return NO;
    UIView *header = tableView.tableHeaderView;
    if (!header || !objc_getAssociatedObject(header, kApolloSubredditWrapperMarkerKey)) return NO;
    if (tableView.tracking || tableView.dragging || tableView.decelerating) return NO;

    CGFloat topY = -tableView.adjustedContentInset.top;
    BOOL atTop = (tableView.contentOffset.y - topY) <= 0.5;
    if (!atTop) return NO;
    CGFloat headerHeight = header.frame.size.height;
    CGFloat targetDelta = newOffset.y - topY;
    // Apollo's "scroll past my own tableHeaderView" call targets the exact
    // bottom of tableHeaderView. Other programmatic scrolls (search mode,
    // scroll-to-row, scroll-to-top) target different positions.
    return fabs(targetDelta - headerHeight) < 5.0;
}

%hook UIScrollView

- (void)setContentOffset:(CGPoint)contentOffset {
    if ([self isKindOfClass:[UITableView class]] &&
        ApolloSubredditShouldBlockOffset((UITableView *)self, contentOffset)) {
        return;
    }
    %orig;
}

- (void)setContentOffset:(CGPoint)contentOffset animated:(BOOL)animated {
    if ([self isKindOfClass:[UITableView class]] &&
        ApolloSubredditShouldBlockOffset((UITableView *)self, contentOffset)) {
        return;
    }
    %orig;
}

%end

%hook UISearchController

- (void)setActive:(BOOL)active {
    BOOL wasActive = self.active;
    %orig(active);
    if (wasActive && !active && sShowSubredditHeaders) {
        ApolloSubredditRefreshVisibleControllers();
        dispatch_async(dispatch_get_main_queue(), ^{
            ApolloSubredditRefreshVisibleControllers();
        });
    }
}

%end

%hook _TtC6Apollo19PostsViewController

- (void)viewDidLoad {
    %orig;
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    ApolloSubredditInstallOrUpdateHeader((UIViewController *)self);
}

- (void)viewDidDisappear:(BOOL)animated {
    BOOL movingFromParent = [(UIViewController *)self isMovingFromParentViewController];
    BOOL beingDismissed = [(UIViewController *)self isBeingDismissed];
    %orig(animated);
    if (movingFromParent || beingDismissed) {
        ApolloSubredditTearDownHeader((UIViewController *)self, YES);
    }
}

%end

%ctor {
    sPostsViewControllerClass = objc_getClass("_TtC6Apollo19PostsViewController");

    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloSubredditHeaderToggleChangedNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    // Re-run the wrapper build (which hosts the Community Highlights carousel)
    // when its toggle flips or its data lands while the header is showing.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"ApolloCommunityHighlightsToggleChangedNotification"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloHLDataReadyNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditInfoUpdatedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditCustomBannerChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *subredditName = note.userInfo[ApolloSubredditCustomBannerSubredditNameKey];
        if (subredditName.length > 0) {
            ApolloSubredditRefreshBannerForSubreddit(subredditName);
            return;
        }
        ApolloSubredditRefreshVisibleControllers();
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloSubredditCustomIconChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        NSString *subredditName = note.userInfo[ApolloSubredditCustomIconSubredditNameKey];
        if (subredditName.length > 0) {
            ApolloSubredditRefreshIconForSubreddit(subredditName);
            return;
        }
        ApolloSubredditRefreshVisibleControllers();
    }];
}
