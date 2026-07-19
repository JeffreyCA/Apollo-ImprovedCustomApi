#import <UIKit/UIKit.h>

typedef struct {
    CGRect bannerFrame;
    CGRect avatarFrame;
    CGRect nameFrame;
    CGRect subnameFrame;
    CGFloat bodyY;
    CGFloat bodyWidth;
} ApolloIdentityHeaderLayout;

FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderBannerHeight(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderAvatarDiameter(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderAvatarOverlap(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderBottomPadding(void);
FOUNDATION_EXPORT UIFont *ApolloIdentityHeaderNameFont(void);
FOUNDATION_EXPORT UIFont *ApolloIdentityHeaderSubnameFont(void);
FOUNDATION_EXPORT ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMake(CGFloat width);
// Same, but with an explicit banner height (profile passes 0 when the banner is off,
// a shorter height in Compact density, or the default in Immersive).
FOUNDATION_EXPORT ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMakeWithBanner(CGFloat width, CGFloat bannerHeight);
FOUNDATION_EXPORT void ApolloIdentityHeaderApplyTextStyles(UILabel *nameLabel,
                                                            UILabel *subnameLabel,
                                                            UILabel *bioLabel);
