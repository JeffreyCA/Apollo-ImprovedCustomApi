// ApolloListLayoutSupport.h
//
// Shared surface between the two iOS 26/27 Liquid Glass list-layout modules:
//
//   ApolloListBottomInsetGuard.xm   — the FUNCTIONAL fix (keyboard-frame
//                                     normalization, content-scroll-view
//                                     registration, and settled recovery).
//   ApolloListLayoutDiagnostics.xm  — optional investigation-only geometry
//                                     snapshots, deliberately excluded from
//                                     shipping builds.
//
// Everything declared here is implemented in ApolloListBottomInsetGuard.xm so
// removing the diagnostics module never takes the fix with it.

#import <UIKit/UIKit.h>

// Bottom-edge geometry for an Apollo list controller, as seen by the guard.
// On iOS 27 the tab bar's frame and the tab controller's contentLayoutGuide
// KEEP their expanded (83pt) values while the floating bar is minimized or
// morphing, so the morph fields — not the frame math — are what distinguish a
// legitimate small inset from the expanded-bar foreground bug.
typedef struct {
    CGFloat safeBottom;
    CGFloat tabBarOverlap;
    CGFloat guideBottomClearance;
    CGFloat requiredChromeBottom;
    BOOL tabBarVisible;
    BOOL tabBarMorphTargetKnown;
    BOOL tabBarMinimized;
    BOOL tabBarMorphAnimatingKnown;
    BOOL tabBarMorphAnimating;
    BOOL tabBarInsetGuardShouldStandDown;
    // YES when the bar's visual state is known well enough to trust the
    // below-chrome corrections: Liquid Glass needs a readable morph target
    // (an expanded frame is ambiguous while minimized); the legacy opaque bar
    // needs no morph — visible and not mid-slide is proof (issue #809).
    BOOL tabBarStateTrusted;
    NSInteger tabBarMorphTarget;
} ApolloListBottomGeometry;

__BEGIN_DECLS

// YES only on Liquid Glass builds running iOS 26+ — the sole environment where
// the guard and its diagnostics operate.
BOOL ApolloListLayoutGuardEnabled(void);

// Apollo's ASTableViewController keeps its list in a Swift `tableNode` ivar
// with no ObjC getter; this resolves the underlying ASTableView (nil if the
// layout ever changes).
UIScrollView *ApolloListTableForController(UIViewController *controller);

ApolloListBottomGeometry ApolloListBottomGeometryForController(UIViewController *controller);

// The last captured healthy bottom inset for this table under the current
// chrome height (chrome + the table's remembered Apollo-specific extra), or 0
// when nothing has been captured yet.
CGFloat ApolloListRememberedHealthyBottom(UIScrollView *table, CGFloat requiredChromeBottom);

// Logs to the apollofix os_log stream AND the bounded cross-launch buffer that
// Export Debug Logs prepends. File I/O is async (see ApolloAppendListLayoutDiag).
void ApolloListLayoutLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// ApolloAutoHideTabBar's legacy hide/show mirror animates the tab bar with
// explicit layer animations under these keys while the MODEL state still says
// fully visible — the guard treats their presence as "bar state in flux".
extern NSString *const ApolloTabBarSlideDownAnimationKey;
extern NSString *const ApolloTabBarSlideUpAnimationKey;

// Capture the currently healthy inset of visible lists at explicit lifecycle /
// chrome boundaries. This avoids doing responder/geometry work on every
// scroll-adjacent setContentInset: call.
void ApolloListCaptureHealthyBottomForVisibleLists(NSString *reason);

// Settled recovery fallback: re-assert the bottom inset only when a visible
// tracked list remains below a stable visible tab bar after normal UIKit/Apollo
// layout has had time to finish. Used by the legacy tab-bar show path (#809)
// and once after a real foreground transition.
void ApolloListVerifyBottomInsetForVisibleLists(NSString *reason);

__END_DECLS
