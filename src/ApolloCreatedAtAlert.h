#import <UIKit/UIKit.h>

// The three tappable "info" icons in a post/comment info row that reveal detail.
typedef NS_ENUM(NSInteger, ApolloInfoKind) {
    ApolloInfoKindAge = 0,     // "Posted/Commented … Ago" + absolute date
    ApolloInfoKindPercentage,  // "N% Upvoted" (posts only)
    ApolloInfoKindEdited,      // "Edited … Ago" + absolute edit date
};

// Present the detail for one info-row icon (% upvoted / timestamp / edited),
// honoring the Info Row Popup/Overlay/off mode:
//   Overlay mode → a small theme-bordered card just above anchorRectInWindow that
//                  fades on its own after ~2s.
//   Popup mode   → a dismissable alert (presented from the window's visible VC).
//   Both off     → nothing.
// Pass the cell's RDKLink as `link` and/or RDKComment as `comment` (whichever the
// cell has); the function reads the ratio/date it needs. Returns NO if nothing was
// shown (mode off, or the data is missing). Shared by the direct taps
// (ApolloCreatedAtAlert.xm) and the magnifier loupe (ApolloStatsRowTouch.xm).
BOOL ApolloPresentInfoDetail(ApolloInfoKind kind, id link, id comment, CGRect anchorRectInWindow, UIWindow *window);

// Low-level transient overlay used by the above (two prebuilt text lines).
void ApolloPresentInfoOverlay(NSString *line1, NSString *line2, CGRect anchorRectInWindow, UIWindow *window);
