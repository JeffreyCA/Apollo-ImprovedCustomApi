#import <UIKit/UIKit.h>

// One row in the Get Started setup card.
@interface ApolloGetStartedStep : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;   // optional second line
@property (nonatomic, copy) NSString *badge;      // optional trailing tag, e.g. "Optional"
@property (nonatomic, assign) BOOL done;          // checkmark vs empty circle
@property (nonatomic, assign) BOOL actionable;    // shows a chevron + fires action on tap
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)stepWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                         done:(BOOL)done
                   actionable:(BOOL)actionable
                       action:(void (^)(void))action;
@end

// A status-driven onboarding card for the top of the Apollo Reborn hub (used as
// the table's tableHeaderView). Purely presentational — the owning controller
// decides when to show/replace/remove it and supplies the steps + theme colors.
@interface ApolloGetStartedCardView : UIView
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                        steps:(NSArray<ApolloGetStartedStep *> *)steps
                  accentColor:(UIColor *)accentColor
                cardBackground:(UIColor *)cardBackground;
// Lay the card out for `width` and return the total height, for sizing the
// tableHeaderView (which UIKit does not auto-size).
- (CGFloat)heightForWidth:(CGFloat)width;
@end
