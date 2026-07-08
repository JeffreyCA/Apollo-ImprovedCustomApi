#import <UIKit/UIKit.h>

// Transient "time overlay" — the Info Row "Timestamp Overlay" mode. Shows a small
// theme-bordered card with the post/comment's full date & time just above
// `anchorRectInWindow`, pops in, then fades away on its own after ~2s. Non-modal
// and non-interactive (touches pass through); only one is ever on screen at a time.
// Shared by the direct age tap (ApolloCreatedAtAlert.xm) and the magnifier loupe
// (ApolloStatsRowTouch.xm). Pass isComment=YES for "Commented", NO for "Posted".
void ApolloPresentTimeOverlay(NSDate *createdAt, CGRect anchorRectInWindow, UIWindow *window, BOOL isComment);
