#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Preview surface and pin feedback. The controller places pinControl beside
// its Preview heading and persists the pin preference.
@interface ApolloLayoutPreviewCard : UIView

- (instancetype)initWithPreview:(UIView *)preview;
@property (nonatomic, strong, readonly) UIControl *pinControl;
@property (nonatomic) BOOL pinned;
// Pauses pinning when settings need room, preserving the saved preference.
@property (nonatomic) BOOL pinningAvailable;
@property (nonatomic, copy, nullable) void (^pinDidChange)(BOOL pinned);
- (void)apollo_applyCurrentAppearance;

@end

NS_ASSUME_NONNULL_END
