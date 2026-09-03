#import <UIKit/UIKit.h>

#import "ApolloSubredditLayout.h"

NS_ASSUME_NONNULL_BEGIN

@interface ApolloSubredditHeaderPreviewView : UIView

- (void)configureWithDensityMode:(ApolloSubredditDensityMode)mode
                          banner:(BOOL)banner
                      joinButton:(BOOL)joinButton
                     displayName:(BOOL)displayName
                        subtitle:(BOOL)subtitle
                     description:(BOOL)description;
- (CGFloat)preferredPreviewHeightForWidth:(CGFloat)width;
- (void)apollo_applyCurrentAppearance;

@end

@interface ApolloSubredditLayoutPreviewCard : UIView

+ (UIEdgeInsets)previewInsets;
- (instancetype)initWithPreview:(ApolloSubredditHeaderPreviewView *)preview;
@property (nonatomic, strong, readonly) UIControl *pinControl;
@property (nonatomic) BOOL pinned;
@property (nonatomic, copy, nullable) void (^pinDidChange)(BOOL pinned);
- (void)apollo_applyCurrentAppearance;

@end

@interface ApolloCommunityHighlightsPreviewView : UIView

- (void)configureWithMode:(ApolloCommunityHighlightsMode)mode;
- (void)apollo_applyCurrentAppearance;
+ (CGFloat)preferredContentHeightForMode:(ApolloCommunityHighlightsMode)mode
                                    width:(CGFloat)width
                                 hostView:(UIView *)hostView;

@end

NS_ASSUME_NONNULL_END
