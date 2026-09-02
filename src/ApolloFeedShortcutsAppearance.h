#import <UIKit/UIKit.h>

#import "ApolloState.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    BOOL usesFlexibleSideBySideLayout;
    CGFloat centerXOffset;
    CGFloat horizontalMargin;
} ApolloFeedShortcutItemGeometry;

NSArray<UIView *> *ApolloFeedShortcutInstallLayout(UIView *hostView,
                                                    NSArray<UIView *> *items,
                                                    NSArray<UIView *> *contentViews,
                                                    NSArray<NSLayoutConstraint *> *contentCenterXConstraints,
                                                    ApolloSubredditFeedLayout layout,
                                                    UIColor *separatorColor,
                                                    CGFloat stackHorizontalOffset);

NSArray<NSNumber *> *ApolloFeedShortcutVisibleIndexes(void);
NSString *ApolloFeedShortcutShortTitle(NSInteger index);
NSString *ApolloFeedShortcutRowTitle(NSInteger index);
NSString *ApolloFeedShortcutDetail(NSInteger index);
UIColor *ApolloFeedShortcutColor(NSInteger index);
UIImage *ApolloFeedShortcutIconImage(NSInteger index,
                                     ApolloSubredditFeedIconStyle style,
                                     ApolloSubredditFeedLayout layout,
                                     NSUInteger itemCount);
UIImage *ApolloSubredditClassicMetaFeedIcon(NSInteger index);

ApolloSubredditFeedLayout ApolloFeedShortcutEffectiveLayout(ApolloSubredditFeedLayout preferredLayout,
                                                             NSUInteger itemCount,
                                                             UITraitCollection *traitCollection);
ApolloFeedShortcutItemGeometry ApolloFeedShortcutItemGeometryForLayout(ApolloSubredditFeedLayout layout,
                                                                        NSUInteger itemCount,
                                                                        NSInteger feedIndex);
CGFloat ApolloFeedShortcutLayoutHeight(ApolloSubredditFeedLayout layout,
                                       UITraitCollection *traitCollection);
CGFloat ApolloFeedShortcutRowHeight(UITraitCollection *traitCollection);
CGFloat ApolloFeedShortcutPreviewRowItemHeight(UITraitCollection *traitCollection);
CGFloat ApolloFeedShortcutDisplayIconSize(ApolloSubredditFeedIconStyle style,
                                          ApolloSubredditFeedLayout layout,
                                          NSUInteger itemCount);
CGFloat ApolloFeedShortcutContentSpacing(ApolloSubredditFeedLayout layout, NSUInteger itemCount);

#ifdef __cplusplus
}
#endif
