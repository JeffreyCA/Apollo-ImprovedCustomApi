// Reborn gathers Apollo's native "Open Links in" (default browser) and "Open
// Videos in YouTube App" settings into its own "Open in App" screen
// (ApolloOpenInAppViewController), reached from Reborn's General settings. To
// avoid the same setting appearing in two places, those two native rows are
// hidden from Apollo's own Settings → General ("Other" section).
//
// The rows have no stable Eureka tag, so they're matched by exact cell title
// (RE-confirmed: "Open Links in" and "Open Videos in YouTube App"; Eureka rows
// can keep the title on a custom label, which the shared matcher handles). The
// hiding itself is owned by ApolloSettingsGeneralTable.xm — the screen's single
// geometry owner, where hidden rows are omitted from display space outright, so
// none of the old zero-height/separator-inset workarounds live here anymore.
// This module only registers the matcher. (It used to carry its own
// cellForRow/heightForRow %hook stack on the same class, which was safe purely
// by Makefile link order once ApolloPerPostCommentSort.xm started remapping
// index paths — the PR #570 review finding that motivated the neutral owner.)

#import <UIKit/UIKit.h>

#import "ApolloSettingsGeneralTable.h"

%ctor {
    ApolloGeneralTableHideRows(^BOOL(UITableViewCell *cell) {
        return ApolloGeneralTableCellHasTitle(cell, @"Open Links in")
            || ApolloGeneralTableCellHasTitle(cell, @"Open Videos in YouTube App");
    });
}
