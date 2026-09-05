// ApolloPaneRouting.h
//
// Shared logical-column policy for live pushes and stacks Apollo constructed
// before the pane hierarchy was installed (cold URLs, Handoff/Siri, and state
// restoration). Keeping one resolver prevents cold and warm navigation from
// assigning the same destination to different columns.

#import <UIKit/UIKit.h>
#import "ApolloPaneLayout.h"

NS_ASSUME_NONNULL_BEGIN
__BEGIN_DECLS

// Resolve one navigation edge. Unknown destinations inherit their source
// column; once navigation reaches detail it can only continue rightward.
ApolloPaneColumn ApolloPaneResolveLogicalColumn(UIViewController *_Nullable sourceViewController,
                                                UIViewController *_Nullable destinationViewController,
                                                ApolloPaneColumn sourceColumn,
                                                BOOL *_Nullable explicitlyClassified);

// Whether this exact destination is a tab-root-designed controller proven to
// suppress UIKit's Back item when physically appended to a detail stack. This
// policy is intentionally narrower than the column-routing allowlist.
BOOL ApolloPaneDestinationRequiresSupplementalBack(UIViewController *_Nullable destinationViewController);

// Number of destination classes explicitly listed in the policy. Diagnostic
// only, so the router can report what it installed without owning the table.
NSUInteger ApolloPaneExplicitRouteCount(void);

__END_DECLS
NS_ASSUME_NONNULL_END
