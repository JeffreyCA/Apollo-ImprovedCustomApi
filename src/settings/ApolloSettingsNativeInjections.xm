// ApolloSettingsNativeInjections — the settings IA restructure's Phase 2 rows
// on Apollo's native Settings > General screen. Four former top-level/hub
// screens land beside their native families:
//
//   Open Links → "Open in App"           (under "Open Reddit Links in Apollo")
//   Media      → "Picture-in-Picture"    (under "Manage Uploads")
//   Other      → "Translation"           (in the hidden "Always Offer Translate"
//                                         slot — ApolloTranslation.xm hides that
//                                         native row; anchoring on it splices us
//                                         into exactly that position)
//   Other      → "Saved Categories"      (under its master switch,
//                                         "Allow Save Categories")
//
// It also registers the General-screen row HIDES for native rows Reborn
// relocates onto its own screens (each still driving the same native defaults
// key, so nothing behavioral moves — only where the control lives):
//
//   "Open Links in"               → Open in App (browser picker mirror)
//   "Open Videos in YouTube App"  → Open in App (YouTube switch mirror)
//   "Hide Username on Tab Bar"    → Apollo Reborn → Profiles (below Icon-Only
//                                   Tab Bar, which supersedes it while active)
//
// Geometry is owned by settings/ApolloSettingsGeneralTable.xm — this file only
// registers factories + selection handlers + hide matchers, and each push goes
// through the route registry so "how do I get to screen X" stays one table.
// Fail-soft by construction: an anchor or hide title that stops matching just
// means the native screen keeps that row.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "settings/ApolloSettingsGeneralTable.h"
#import "settings/ApolloSettingsRouter.h"
#import "ApolloThemeRuntime.h"

// One disclosure cell per (screen instance, injection), cached via a distinct
// associated-object key and re-themed from the live donor on every dequeue.
static UITableViewCell *ApolloNativeInjectionCell(UIViewController *vc,
                                                  UITableViewCell *donor,
                                                  const void *cacheKey,
                                                  NSString *title) {
    UITableViewCell *cell = objc_getAssociatedObject(vc, cacheKey);
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = title;
        objc_setAssociatedObject(vc, cacheKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (donor) {   // borrow the native sibling's live theming
        cell.backgroundColor = donor.backgroundColor;
        cell.textLabel.font = donor.textLabel.font;
        cell.textLabel.textColor = donor.textLabel.textColor;
    }
    return cell;
}

static void ApolloNativeInjectionOpenRoute(UIViewController *vc, NSString *routeId) {
    UIViewController *screen = ApolloSettingsRouteInstantiate(routeId);
    if (!screen || !vc.navigationController) {
        ApolloLog(@"[NativeInjections] cannot open route '%@' (screen=%@ nav=%@)",
                  routeId, screen, vc.navigationController);
        return;
    }
    [vc.navigationController pushViewController:screen animated:YES];
}

// Registers one disclosure row: title, unique native anchor, route to push.
static void ApolloRegisterGeneralDisclosureRow(NSString *title,
                                               NSString *anchorTitle,
                                               const void *cacheKey,
                                               NSString *routeId) {
    ApolloGeneralTableInjectSelectableRow(anchorTitle, nil,
        ^UITableViewCell *(UIViewController *vc, UITableViewCell *donor) {
            return ApolloNativeInjectionCell(vc, donor, cacheKey, title);
        },
        ^(UIViewController *vc) {
            ApolloNativeInjectionOpenRoute(vc, routeId);
        });
}

static const void *kApolloInjOpenInAppKey = &kApolloInjOpenInAppKey;
static const void *kApolloInjPiPKey = &kApolloInjPiPKey;
static const void *kApolloInjTranslationKey = &kApolloInjTranslationKey;
static const void *kApolloInjSavedCategoriesKey = &kApolloInjSavedCategoriesKey;

%ctor {
    ApolloRegisterGeneralDisclosureRow(@"Open in App",
                                       @"Open Reddit Links in Apollo",
                                       kApolloInjOpenInAppKey,
                                       @"open-in-app");
    ApolloRegisterGeneralDisclosureRow(@"Picture-in-Picture",
                                       @"Manage Uploads",
                                       kApolloInjPiPKey,
                                       @"picture-in-picture");
    ApolloRegisterGeneralDisclosureRow(@"Translation",
                                       @"Always Offer Translate",
                                       kApolloInjTranslationKey,
                                       @"translation");
    ApolloRegisterGeneralDisclosureRow(@"Saved Categories",
                                       @"Allow Save Categories",
                                       kApolloInjSavedCategoriesKey,
                                       @"saved-categories");

    // Native rows relocated onto Reborn screens (see the header comment). The
    // mirrors read/write the same native keys, so hiding these is pure
    // deduplication — none of them is used as an injection anchor above.
    ApolloGeneralTableHideRows(^BOOL(UITableViewCell *cell) {
        return ApolloGeneralTableCellHasTitle(cell, @"Open Links in")
            || ApolloGeneralTableCellHasTitle(cell, @"Open Videos in YouTube App")
            || ApolloGeneralTableCellHasTitle(cell, @"Hide Username on Tab Bar");
    });
}
