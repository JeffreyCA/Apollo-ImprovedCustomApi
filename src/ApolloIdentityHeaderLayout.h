#import <UIKit/UIKit.h>

typedef struct {
    CGRect bannerFrame;
    CGRect avatarFrame;
    CGRect nameFrame;
    CGRect subnameFrame;
    CGFloat bodyY;
    CGFloat bodyWidth;
    CGFloat bodyX;
} ApolloIdentityHeaderLayout;

FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderBannerHeight(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderAvatarDiameter(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderAvatarOverlap(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderBottomPadding(void);
FOUNDATION_EXPORT CGFloat ApolloIdentityHeaderSideInset(void);
FOUNDATION_EXPORT UIFont *ApolloIdentityHeaderNameFont(void);
FOUNDATION_EXPORT UIFont *ApolloIdentityHeaderSubnameFont(void);
FOUNDATION_EXPORT ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMake(CGFloat width);
// Variant with a caller-supplied banner height (0 = no banner reserved — the
// avatar bottoms out at a small top pad instead of overlapping nothing).
FOUNDATION_EXPORT ApolloIdentityHeaderLayout ApolloIdentityHeaderLayoutMakeWithBanner(CGFloat width, CGFloat bannerHeight);
FOUNDATION_EXPORT void ApolloIdentityHeaderApplyTextStyles(UILabel *nameLabel,
                                                            UILabel *subnameLabel,
                                                            UILabel *bioLabel);
