#import "ApolloBadgeBookStrip.h"
#import "ApolloBadgeBookViewController.h"
#import "ApolloBadgeBookScraper.h"
#import "ApolloBadgeBookCatalog.h"
#import "ApolloThemeRuntime.h"
#import "ApolloCommon.h"
#import "ApolloState.h"

NSString *const ApolloBadgeBookToggleChangedNotification = @"ApolloBadgeBookToggleChangedNotification";

BOOL ApolloBadgeBookEnabled(void) {
    return sBadgeBookEnabled;
}

static CGFloat const kBBStripHeight = 44.0;
static CGFloat const kBBIconSize    = 30.0;
static CGFloat const kBBIconGap     = 6.0;

@interface ApolloBadgeBookStripView ()
@property(nonatomic, strong) UIImageView *leadingGlyph;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIImageView *chevron;
@property(nonatomic, strong) NSMutableArray<UIImageView *> *iconViews;
@property(nonatomic, strong) UILabel *overflowLabel;
@property(nonatomic, strong) ApolloUserBadges *badges;
@property(nonatomic, copy) NSString *loadedUsername;   // guards async completions
@property(nonatomic) NSUInteger previewTotal;          // full count (icon views are capped)
@end

@implementation ApolloBadgeBookStripView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _iconViews = [NSMutableArray array];

        _leadingGlyph = [[UIImageView alloc] init];
        _leadingGlyph.contentMode = UIViewContentModeScaleAspectFit;
        _leadingGlyph.image = [UIImage systemImageNamed:@"rosette"];
        [self addSubview:_leadingGlyph];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.text = @"Badge Book";
        [self addSubview:_titleLabel];

        _chevron = [[UIImageView alloc] init];
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.image = [UIImage systemImageNamed:@"chevron.right"];
        _chevron.tintColor = [UIColor tertiaryLabelColor];
        [self addSubview:_chevron];

        _overflowLabel = [[UILabel alloc] init];
        _overflowLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _overflowLabel.textColor = [UIColor secondaryLabelColor];
        _overflowLabel.hidden = YES;
        [self addSubview:_overflowLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(apollo_tapped)];
        [self addGestureRecognizer:tap];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(apollo_toggleChanged)
                                                     name:ApolloBadgeBookToggleChangedNotification object:nil];
        // Late data (achievements merging in after the instant trophy delivery)
        // refreshes the preview icons in place.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(apollo_userUpdated:)
                                                     name:ApolloBadgeBookUserUpdatedNotification object:nil];
        [self apollo_applyAccent];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIColor *)apollo_accent {
    return ApolloThemeAccentColor() ?: self.tintColor ?: [UIColor systemBlueColor];
}

- (void)apollo_applyAccent {
    UIColor *accent = [self apollo_accent];
    self.leadingGlyph.tintColor = accent;
    self.titleLabel.textColor = accent;
}

- (void)tintColorDidChange { [super tintColorDidChange]; [self apollo_applyAccent]; }
- (void)traitCollectionDidChange:(UITraitCollection *)prev { [super traitCollectionDidChange:prev]; [self apollo_applyAccent]; }

#pragma mark Data

- (void)setUsername:(NSString *)username {
    NSString *clean = [username isKindOfClass:[NSString class]]
        ? [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    if ([clean isEqualToString:_username]) return;
    _username = [clean copy];
    self.badges = nil;
    self.loadedUsername = nil;
    [self apollo_rebuildIcons];
    [self setNeedsLayout];
    if (self.heightChangedBlock) self.heightChangedBlock();
    [self apollo_loadIfNeeded];
}

- (void)apollo_loadIfNeeded {
    if (!ApolloBadgeBookEnabled()) return;
    NSString *user = self.username;
    if (user.length == 0) return;
    if ([self.loadedUsername isEqualToString:user]) return;

    __weak typeof(self) ws = self;
    ApolloBadgeBookFetch(user, ^(ApolloUserBadges *result) {
        typeof(self) ss = ws; if (!ss) return;
        if (![ss.username isEqualToString:user]) return;   // moved on to another profile
        ss.loadedUsername = user;
        ss.badges = result;
        [ss apollo_rebuildIcons];
        [ss setNeedsLayout];
        if (ss.heightChangedBlock) ss.heightChangedBlock();
    });
}

// Preview items: earned achievements first (all bundled → instant), then trophies.
- (NSArray<ApolloBadgeItem *> *)apollo_previewItems {
    if (!self.badges) return @[];
    NSMutableArray<ApolloBadgeItem *> *items = [NSMutableArray array];
    if (self.badges.achievementsResolved && self.badges.earnedAchievementIDs.count) {
        ApolloBadgeBookCatalog *cat = [ApolloBadgeBookCatalog shared];
        for (ApolloBadgeItem *a in cat.achievements) {
            if ([self.badges.earnedAchievementIDs containsObject:a.identifier]) [items addObject:a];
        }
    }
    [items addObjectsFromArray:self.badges.trophies];
    return items;
}

- (void)apollo_rebuildIcons {
    for (UIImageView *v in self.iconViews) [v removeFromSuperview];
    [self.iconViews removeAllObjects];

    // The band fits ~8 icons at most — never build a view per collectible (a
    // heavily-decorated profile can have 90+). The "+N" chip covers the rest.
    NSArray<ApolloBadgeItem *> *preview = [self apollo_previewItems];
    self.previewTotal = preview.count;
    if (preview.count) ApolloBadgeBookPrewarmImages();
    NSUInteger const kMaxIconViews = 16;
    if (preview.count > kMaxIconViews) {
        preview = [preview subarrayWithRange:NSMakeRange(0, kMaxIconViews)];
    }
    for (ApolloBadgeItem *item in preview) {
        UIImageView *iv = [[UIImageView alloc] init];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        UIImage *bundled = [item bundledImage];
        if (bundled) {
            iv.image = bundled;
        } else if (item.imageURLString.length) {
            // Rare uncatalogued trophy — leave blank; the full book loads it. Keeping
            // the strip network-free stays instant.
            iv.image = [UIImage systemImageNamed:@"trophy.fill"];
            iv.tintColor = [UIColor tertiaryLabelColor];
        }
        [self addSubview:iv];
        [self.iconViews addObject:iv];
    }
}

#pragma mark Layout

- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    if (!ApolloBadgeBookEnabled()) return 0.0;
    if (self.username.length == 0) return 0.0;
    return kBBStripHeight;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    CGFloat w = self.bounds.size.width;
    if (h <= 0.0) return;

    CGFloat glyph = 20.0;
    self.leadingGlyph.frame = CGRectMake(0.0, (h - glyph) / 2.0, glyph, glyph);

    CGSize titleSize = [self.titleLabel sizeThatFits:CGSizeMake(w, h)];
    CGFloat titleX = CGRectGetMaxX(self.leadingGlyph.frame) + 8.0;
    self.titleLabel.frame = CGRectMake(titleX, 0.0, MIN(titleSize.width, 160.0), h);

    CGFloat chevronSize = 13.0;
    self.chevron.frame = CGRectMake(w - chevronSize, (h - chevronSize) / 2.0, chevronSize, chevronSize);

    // Icons flow between the title and the chevron.
    CGFloat iconsLeft = CGRectGetMaxX(self.titleLabel.frame) + 12.0;
    CGFloat iconsRight = CGRectGetMinX(self.chevron.frame) - 8.0;
    CGFloat available = iconsRight - iconsLeft;
    CGFloat iconY = (h - kBBIconSize) / 2.0;

    NSInteger maxFit = (available > kBBIconSize) ? (NSInteger)floor((available + kBBIconGap) / (kBBIconSize + kBBIconGap)) : 0;
    NSInteger total = (NSInteger)self.previewTotal;
    NSInteger shown = MIN(MIN(maxFit, (NSInteger)self.iconViews.count), total);
    // Reserve room for a "+N" chip when overflowing.
    BOOL overflow = (total > shown);
    if (overflow && shown > 0) shown -= 1;

    CGFloat x = iconsLeft;
    for (NSInteger i = 0; i < (NSInteger)self.iconViews.count; i++) {
        UIImageView *iv = self.iconViews[i];
        if (i < shown) {
            iv.hidden = NO;
            iv.frame = CGRectMake(x, iconY, kBBIconSize, kBBIconSize);
            x += kBBIconSize + kBBIconGap;
        } else {
            iv.hidden = YES;
        }
    }

    NSInteger remaining = total - shown;
    if (overflow && remaining > 0 && shown >= 0) {
        self.overflowLabel.hidden = NO;
        self.overflowLabel.text = [NSString stringWithFormat:@"+%ld", (long)remaining];
        [self.overflowLabel sizeToFit];
        CGFloat oy = (h - self.overflowLabel.bounds.size.height) / 2.0;
        self.overflowLabel.frame = CGRectMake(x, oy, MIN(self.overflowLabel.bounds.size.width, iconsRight - x), self.overflowLabel.bounds.size.height);
    } else {
        self.overflowLabel.hidden = YES;
    }
}

#pragma mark Actions

- (void)apollo_tapped {
    if (self.username.length == 0) return;
    UIViewController *host = self.hostViewController;
    if (!host) return;
    ApolloBadgeBookPresentForUsername(self.username, host);
}

- (void)apollo_toggleChanged {
    [self setNeedsLayout];
    if (self.heightChangedBlock) self.heightChangedBlock();
    [self apollo_loadIfNeeded];
}

- (void)apollo_userUpdated:(NSNotification *)note {
    NSString *user = [note.object isKindOfClass:[NSString class]] ? note.object : nil;
    if (![user.lowercaseString isEqualToString:self.username.lowercaseString]) return;
    self.loadedUsername = nil;    // re-pull from the (updated) cache
    [self apollo_loadIfNeeded];
}

- (void)refresh {
    ApolloBadgeBookInvalidate(self.username);
    self.badges = nil;
    self.loadedUsername = nil;
    [self apollo_rebuildIcons];
    [self setNeedsLayout];
    [self apollo_loadIfNeeded];
}

@end
