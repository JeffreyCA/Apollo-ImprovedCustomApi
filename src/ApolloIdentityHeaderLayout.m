#import "ApolloIdentityHeaderLayout.h"

static CGFloat const ApolloIdentityBannerHeight = 150.0;
static CGFloat const ApolloIdentityAvatarDiameter = 96.0;
static CGFloat const ApolloIdentityAvatarOverlap = 48.0;
static CGFloat const ApolloIdentitySideInset = 24.0;
static CGFloat const ApolloIdentityBottomPadding = 14.0;
// Centered body text (bio/about) gets unreadably long lines on iPad/landscape
// without a column cap.
static CGFloat const ApolloIdentityBodyMaxWidth = 480.0;

CGFloat ApolloIdentityHeaderBannerHeight(void) {
    return ApolloIdentityBannerHeight;
}

CGFloat ApolloIdentityHeaderAvatarDiameter(void) {
    return ApolloIdentityAvatarDiameter;
}

CGFloat ApolloIdentityHeaderAvatarOverlap(void) {
    return ApolloIdentityAvatarOverlap;
}

CGFloat ApolloIdentityHeaderBottomPadding(void) {
    return ApolloIdentityBottomPadding;
}

// Fonts come from UIFontMetrics so adjustsFontForContentSizeCategory actually
// works (it is a no-op on plain systemFontOfSize: fonts). Not cached — the
// scaled result depends on the current content size category.
UIFont *ApolloIdentityHeaderNameFont(void) {
    UIFont *base = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:base];
}

UIFont *ApolloIdentityHeaderSubnameFont(void) {
    UIFont *base = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    return [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:base];
}

ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMakeWithBanner(CGFloat width, CGFloat bannerHeight) {
    bannerHeight = MAX(0.0, bannerHeight);
    CGFloat bodyWidth = MIN(ApolloIdentityBodyMaxWidth,
                            MAX(120.0, width - ApolloIdentitySideInset * 2.0));
    CGFloat bodyX = floor((width - bodyWidth) / 2.0);
    // The avatar overlaps the banner's bottom edge; with a short or absent banner
    // it can't sit above the header, so it bottoms out at a small top pad.
    CGFloat avatarY = MAX(14.0, bannerHeight - ApolloIdentityAvatarOverlap);
    CGRect avatarFrame = CGRectMake(floor((width - ApolloIdentityAvatarDiameter) / 2.0),
                                    avatarY,
                                    ApolloIdentityAvatarDiameter,
                                    ApolloIdentityAvatarDiameter);
    // Label heights track the (Dynamic Type-scaled) fonts so the frames the
    // header reserves always fit the text they hold.
    CGFloat nameHeight = ceil(ApolloIdentityHeaderNameFont().lineHeight) + 2.0;
    CGFloat subnameHeight = ceil(ApolloIdentityHeaderSubnameFont().lineHeight) + 2.0;
    CGFloat nameY = CGRectGetMaxY(avatarFrame) + 8.0;
    CGRect nameFrame = CGRectMake(bodyX, nameY, bodyWidth, nameHeight);
    CGRect subnameFrame = CGRectMake(bodyX,
                                     CGRectGetMaxY(nameFrame) + 1.0,
                                     bodyWidth,
                                     subnameHeight);
    ApolloIdentityHeaderLayout layout = {
        .bannerFrame = CGRectMake(0.0, 0.0, width, bannerHeight),
        .avatarFrame = avatarFrame,
        .nameFrame = nameFrame,
        .subnameFrame = subnameFrame,
        .bodyY = CGRectGetMaxY(subnameFrame) + 10.0,
        .bodyWidth = bodyWidth,
    };
    return layout;
}

ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMake(CGFloat width) {
    return ApolloIdentityHeaderLayoutMakeWithBanner(width, ApolloIdentityBannerHeight);
}

void ApolloIdentityHeaderApplyTextStyles(UILabel *nameLabel,
                                         UILabel *subnameLabel,
                                         UILabel *bioLabel) {
    nameLabel.font = ApolloIdentityHeaderNameFont();
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.numberOfLines = 1;
    nameLabel.adjustsFontForContentSizeCategory = YES;

    subnameLabel.font = ApolloIdentityHeaderSubnameFont();
    subnameLabel.textAlignment = NSTextAlignmentCenter;
    subnameLabel.numberOfLines = 1;
    subnameLabel.adjustsFontForContentSizeCategory = YES;

    bioLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    bioLabel.textAlignment = NSTextAlignmentCenter;
    bioLabel.numberOfLines = 0;
    bioLabel.adjustsFontForContentSizeCategory = YES;
}
