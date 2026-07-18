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
FOUNDATION_EXPORT void ApolloIdentityHeaderApplyTextStyles(UILabel *nameLabel,
                                                            UILabel *subnameLabel,
                                                            UILabel *bioLabel);
