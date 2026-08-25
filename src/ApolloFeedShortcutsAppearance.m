#import "ApolloFeedShortcutsAppearance.h"

#import "ApolloCommon.h"
#import "UserDefaultConstants.h"

NSArray<UIView *> *ApolloFeedShortcutInstallLayout(UIView *hostView,
                                                    NSArray<UIView *> *items,
                                                    NSArray<UIView *> *contentViews,
                                                    NSArray<NSLayoutConstraint *> *contentCenterXConstraints,
                                                    ApolloSubredditFeedLayout layout,
                                                    UIColor *separatorColor,
                                                    NSArray<UILayoutGuide *> **installedLayoutGuides) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:items];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentFill;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 0.0;
    [hostView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor constant:-14.0],
        [stack.topAnchor constraintEqualToAnchor:hostView.topAnchor constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor constant:-8.0]
    ]];

    BOOL sideBySide = layout == ApolloSubredditFeedLayoutSideBySide;
    NSMutableArray<UIView *> *separators =
        [NSMutableArray arrayWithCapacity:items.count > 0 ? items.count - 1 : 0];
    NSMutableArray<UILayoutGuide *> *layoutGuides = [NSMutableArray array];
    for (NSUInteger index = 0; index + 1 < items.count; index++) {
        UIView *separator = [UIView new];
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        separator.userInteractionEnabled = NO;
        separator.backgroundColor = separatorColor;
        [hostView addSubview:separator];
        NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
            [separator.widthAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
            [separator.topAnchor constraintEqualToAnchor:hostView.topAnchor constant:sideBySide ? 14.0 : 22.0],
            [separator.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor constant:sideBySide ? -14.0 : -22.0]
        ]];
        if (sideBySide && items.count >= 3) {
            UILayoutGuide *gapGuide = [UILayoutGuide new];
            [hostView addLayoutGuide:gapGuide];
            [layoutGuides addObject:gapGuide];
            [constraints addObjectsFromArray:@[
                [gapGuide.leadingAnchor constraintEqualToAnchor:contentViews[index].trailingAnchor],
                [gapGuide.trailingAnchor constraintEqualToAnchor:contentViews[index + 1].leadingAnchor],
                [separator.centerXAnchor constraintEqualToAnchor:gapGuide.centerXAnchor]
            ]];
        } else {
            [constraints addObject:[separator.centerXAnchor constraintEqualToAnchor:items[index].trailingAnchor]];
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [separators addObject:separator];
    }

    if (sideBySide && items.count >= 3) {
        for (NSUInteger index = 1; index + 1 < items.count; index++) {
            contentCenterXConstraints[index].active = NO;
            UILayoutGuide *regionGuide = [UILayoutGuide new];
            [hostView addLayoutGuide:regionGuide];
            [layoutGuides addObject:regionGuide];
            [NSLayoutConstraint activateConstraints:@[
                [regionGuide.leadingAnchor constraintEqualToAnchor:separators[index - 1].centerXAnchor],
                [regionGuide.trailingAnchor constraintEqualToAnchor:separators[index].centerXAnchor],
                [contentViews[index].centerXAnchor constraintEqualToAnchor:regionGuide.centerXAnchor]
            ]];
        }
    }
    if (installedLayoutGuides) *installedLayoutGuides = [layoutGuides copy];
    return separators;
}

NSArray<NSNumber *> *ApolloFeedShortcutVisibleIndexes(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray arrayWithObject:@0];
    if (![defaults boolForKey:UDKeyHideRPopularRedditList]) [indexes addObject:@1];
    if (![defaults boolForKey:UDKeyHideRAllRedditList]) [indexes addObject:@2];
    if (![defaults boolForKey:UDKeyHideModeratorRedditList]) [indexes addObject:@3];
    return indexes;
}

NSString *ApolloFeedShortcutShortTitle(NSInteger index) {
    NSArray<NSString *> *titles = @[ @"Home", @"Popular", @"All", @"Moderator" ];
    return index >= 0 && index < (NSInteger)titles.count ? titles[(NSUInteger)index] : @"";
}

NSString *ApolloFeedShortcutRowTitle(NSInteger index) {
    NSArray<NSString *> *titles = @[ @"Home", @"Popular Posts", @"All Posts", @"Moderator Posts" ];
    return index >= 0 && index < (NSInteger)titles.count ? titles[(NSUInteger)index] : @"";
}

NSString *ApolloFeedShortcutDetail(NSInteger index) {
    NSArray<NSString *> *details = @[
        @"Posts from subscriptions",
        @"Most popular across Reddit",
        @"Posts across all subreddits",
        @"Posts from moderated subreddits"
    ];
    return index >= 0 && index < (NSInteger)details.count ? details[(NSUInteger)index] : @"";
}

UIColor *ApolloFeedShortcutColor(NSInteger index) {
    switch (index) {
        case 0: return [UIColor colorWithRed:254.0 / 255.0 green:0.0 blue:98.0 / 255.0 alpha:1.0];
        case 1: return [UIColor colorWithRed:0.0 green:143.0 / 255.0 blue:253.0 / 255.0 alpha:1.0];
        case 2: return [UIColor colorWithRed:1.0 / 255.0 green:214.0 / 255.0 blue:51.0 / 255.0 alpha:1.0];
        default: return [UIColor colorWithWhite:0.46 alpha:1.0];
    }
}

static UIImage *ApolloFeedShortcutBundledGlyph(NSString *resourceName, BOOL brighten) {
    NSString *path = ApolloBundledResourcePath(resourceName, @"png");
    UIImage *source = path.length > 0 ? [UIImage imageWithContentsOfFile:path] : nil;
    if (!source) return nil;
    if (!brighten) return [source imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.scale = source.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:source.size format:format];
    UIImage *image = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        [source drawAtPoint:CGPointZero];
        [source drawAtPoint:CGPointZero];
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *ApolloFeedShortcutGlyph(NSInteger index) {
    static NSArray<UIImage *> *bundledGlyphs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIImage *home = ApolloFeedShortcutBundledGlyph(@"meta-feed-home", NO) ?: [UIImage new];
        UIImage *popular = ApolloFeedShortcutBundledGlyph(@"meta-feed-popular", YES) ?: [UIImage new];
        bundledGlyphs = @[ home, popular ];
    });
    if (index >= 0 && index < 2) return bundledGlyphs[(NSUInteger)index];

    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.5 weight:UIImageSymbolWeightSemibold];
    NSString *symbolName = index == 2 ? @"square.stack.3d.up" : @"checkmark.shield.fill";
    return [[UIImage systemImageNamed:symbolName withConfiguration:configuration]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *ApolloFeedShortcutIconImage(NSInteger index,
                                     ApolloSubredditFeedIconStyle style,
                                     ApolloSubredditFeedLayout layout) {
    if (style == ApolloSubredditFeedIconStyleClassic) {
        return [ApolloSubredditClassicMetaFeedIcon(index) imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    }

    static NSMutableDictionary<NSNumber *, UIImage *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSNumber *cacheKey = @(index + style * 10 + layout * 100);
    UIImage *cached = cache[cacheKey];
    if (cached) return cached;

    UIImage *glyph = ApolloFeedShortcutGlyph(index);
    if (!glyph) return nil;
    UIColor *color = ApolloFeedShortcutColor(index);
    if (style == ApolloSubredditFeedIconStyleTinted &&
        layout == ApolloSubredditFeedLayoutSideBySide) {
        UIImage *icon = [glyph imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
        cache[cacheKey] = icon;
        return icon;
    }

    CGFloat canvasSize = layout == ApolloSubredditFeedLayoutRows ? 34.0 : 40.0;
    CGFloat glyphInset = layout == ApolloSubredditFeedLayoutRows ? 6.0 : 7.0;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(canvasSize, canvasSize)
        format:format];
    UIImage *icon = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
        CGRect bounds = CGRectMake(0.0, 0.0, canvasSize, canvasSize);
        BOOL usesCircle = style == ApolloSubredditFeedIconStyleCircle;
        BOOL usesTile = style == ApolloSubredditFeedIconStyleSoftTile ||
                        style == ApolloSubredditFeedIconStyleSolidTile;
        if (usesCircle || usesTile) {
            UIColor *fillColor = style == ApolloSubredditFeedIconStyleSoftTile
                ? [color colorWithAlphaComponent:0.14]
                : color;
            [fillColor setFill];
            UIBezierPath *path = usesTile
                ? [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:canvasSize * 0.25]
                : [UIBezierPath bezierPathWithOvalInRect:bounds];
            [path fill];
        }
        UIColor *glyphColor = (style == ApolloSubredditFeedIconStyleTinted ||
                               style == ApolloSubredditFeedIconStyleSoftTile)
            ? color
            : UIColor.whiteColor;
        UIImage *coloredGlyph = [glyph imageWithTintColor:glyphColor
                                             renderingMode:UIImageRenderingModeAlwaysOriginal];
        [coloredGlyph drawInRect:CGRectInset(bounds, glyphInset, glyphInset)];
    }];
    icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cache[cacheKey] = icon;
    return icon;
}

ApolloSubredditFeedLayout ApolloFeedShortcutEffectiveLayout(ApolloSubredditFeedLayout preferredLayout,
                                                             NSArray<NSNumber *> *visibleIndexes,
                                                             ApolloSubredditFeedIconStyle iconStyle,
                                                             CGFloat availableWidth,
                                                             UITraitCollection *traitCollection) {
    NSUInteger itemCount = visibleIndexes.count;
    if (preferredLayout != ApolloSubredditFeedLayoutSideBySide || itemCount < 2) {
        return preferredLayout;
    }

    UIContentSizeCategory category = traitCollection.preferredContentSizeCategory;
    if (UIContentSizeCategoryIsAccessibilityCategory(category)) {
        return ApolloSubredditFeedLayoutRows;
    }

    if (availableWidth > 0.0 && itemCount >= 2) {
        UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                                  compatibleWithTraitCollection:traitCollection];
        CGFloat iconWidth = ApolloFeedShortcutDisplayIconSize(iconStyle,
                                                               ApolloSubredditFeedLayoutSideBySide,
                                                               itemCount);
        CGFloat spacing = ApolloFeedShortcutContentSpacing(ApolloSubredditFeedLayoutSideBySide,
                                                            itemCount);
        CGFloat acceptableLabelScale = itemCount == 4 ? 0.72 : 0.80;
        CGFloat availableItemWidth = (availableWidth - 28.0) / (CGFloat)itemCount;
        CGFloat itemMargin = itemCount == 4 ? 0.0 : 12.0;
        for (NSNumber *index in visibleIndexes) {
            CGFloat labelWidth = ceil([ApolloFeedShortcutShortTitle(index.integerValue)
                sizeWithAttributes:@{ NSFontAttributeName: font }].width);
            CGFloat requiredWidth = iconWidth + spacing + labelWidth * acceptableLabelScale + itemMargin;
            if (requiredWidth > availableItemWidth) {
                return ApolloSubredditFeedLayoutGrid;
            }
        }
    }
    return preferredLayout;
}

CGFloat ApolloFeedShortcutLayoutHeight(ApolloSubredditFeedLayout layout,
                                       UITraitCollection *traitCollection) {
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                              compatibleWithTraitCollection:traitCollection];
    if (layout == ApolloSubredditFeedLayoutSideBySide) {
        CGFloat contentHeight = MAX(34.0, ceil(font.lineHeight)) + 16.0;
        return MAX(68.0, contentHeight);
    }
    if (layout == ApolloSubredditFeedLayoutGrid) {
        CGFloat contentHeight = 46.0 + 4.0 + ceil(font.lineHeight) + 16.0;
        return MAX(104.0, contentHeight);
    }
    return 0.0;
}

CGFloat ApolloFeedShortcutRowHeight(UITraitCollection *traitCollection) {
    UIFont *titleFont = [UIFont preferredFontForTextStyle:UIFontTextStyleBody
                                compatibleWithTraitCollection:traitCollection];
    UIFont *detailFont = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote
                                 compatibleWithTraitCollection:traitCollection];
    return MAX(60.0, ceil(titleFont.lineHeight) + ceil(detailFont.lineHeight) + 18.0);
}

CGFloat ApolloFeedShortcutPreviewRowItemHeight(UITraitCollection *traitCollection) {
    return MAX(52.0, ApolloFeedShortcutRowHeight(traitCollection) - 8.0);
}

CGFloat ApolloFeedShortcutDisplayIconSize(ApolloSubredditFeedIconStyle style,
                                          ApolloSubredditFeedLayout layout,
                                          NSUInteger itemCount) {
    if (layout == ApolloSubredditFeedLayoutRows) return 34.0;
    if (layout == ApolloSubredditFeedLayoutGrid) return 46.0;
    if (style == ApolloSubredditFeedIconStyleTinted) return 22.0;
    return itemCount == 4 ? 30.0 : 32.0;
}

CGFloat ApolloFeedShortcutContentSpacing(ApolloSubredditFeedLayout layout, NSUInteger itemCount) {
    if (layout == ApolloSubredditFeedLayoutSideBySide) return itemCount == 4 ? 3.5 : 7.0;
    return 4.0;
}
