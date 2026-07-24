#import <UIKit/UIKit.h>

typedef struct {
    CGRect bannerFrame;
    CGRect avatarFrame;
    CGRect nameFrame;
    CGRect subnameFrame;
    CGFloat bodyY;
    CGFloat bodyWidth;
    // Leading X for bodyWidth-spanning content (bio, social links, badge strip,
    // stat cards). Centered by default; a caller that overrides the layout for
    // a left-aligned presentation (see ApolloUserAvatars.xm's Classic density)
    // sets this to the side inset instead.
    CGFloat bodyX;
} ApolloIdentityHeaderLayout;

FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderBannerHeight(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderAvatarDiameter(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderAvatarOverlap(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderBottomPadding(void);
// The fixed side margin bodyX/bodyWidth are derived from. On narrow (phone)
// widths this equals the centered bodyX exactly; a caller that left-aligns
// content instead of centering it (see ApolloUserAvatars.xm's Classic density)
// needs this directly, since bodyX balloons into a huge centering offset once
// bodyWidth hits its column cap on wide/iPad screens.
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderSideInset(void);
FOUNDATION_EXPORT UIFont *ApolloIdentityHeaderNameFont(void);
FOUNDATION_EXPORT UIFont *ApolloIdentityHeaderSubnameFont(void);
FOUNDATION_EXPORT ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMake(CGFloat width);
// Same, but with an explicit banner height (profile passes 0 when the banner is off,
// a shorter height in Compact density, or the default in Immersive).
FOUNDATION_EXPORT ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMakeWithBanner(CGFloat width, CGFloat bannerHeight);
FOUNDATION_EXPORT void ApolloIdentityHeaderApplyTextStyles(UILabel *nameLabel,
                                                            UILabel *subnameLabel,
                                                            UILabel *bioLabel);
