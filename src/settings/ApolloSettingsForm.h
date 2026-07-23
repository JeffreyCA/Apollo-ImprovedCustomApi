// ApolloSettingsForm — declarative row/section model for the tweak-OWNED
// settings tables (CustomAPIViewController and its sub-screens).
//
// Rows are data; indices are derived. A screen subclasses
// ApolloSettingsFormViewController, overrides -buildForm once, and never
// touches an index path again:
//   - numberOfRows/cellForRow/didSelect/shouldHighlight are all served from a
//     VISIBILITY SNAPSHOT of the model (one encoding of the layout, not three);
//   - conditional rows carry a `visible` block; after a handler changes state
//     it calls -visibilityDidChange, which diffs the old snapshot against the
//     new one per section and performs the batch insert/delete itself — no
//     hand-computed offsets, no cross-toggle arithmetic;
//   - refreshing another row is by IDENTITY (-reloadRowWithID:), never by index.
//
// This is the sibling of settings/ApolloSettingsGeneralTable.{h,xm}: that layer
// remaps a native Eureka table we don't own; this one models the tables we do.
// Theming comes from the ApolloSettingsTableViewController base (accent walk in
// willDisplayCell) — the form VC calls through to it.
//
// See docs/settings-form-refactor-plan.md for the migration this landed with.

#import <UIKit/UIKit.h>

#import "settings/ApolloSettingsTableViewController.h"

NS_ASSUME_NONNULL_BEGIN

@class ApolloSettingsRow;

typedef UITableViewCell *_Nonnull (^ApolloSettingsCellBlock)(UITableView *tableView, ApolloSettingsRow *row);

@interface ApolloSettingsRow : NSObject

// A UISwitch row. isOn is re-read on every (re)configure; onToggle runs on
// UIControlEventValueChanged with the live switch (write your global + default
// there, then call -visibilityDidChange / -reloadRowWithID: as needed).
+ (instancetype)switchRowWithID:(NSString *)rowID
                          title:(NSString *)title
                           isOn:(BOOL (^)(void))isOn
                       onToggle:(void (^)(UISwitch *sender))onToggle;

// A Value1 row (detail re-read on every configure). onSelect is optional —
// typically presents a picker (see ApolloSettingsPresentPicker) or copies a
// value. No accessory by default.
+ (instancetype)valueRowWithID:(NSString *)rowID
                         title:(NSString *)title
                        detail:(nullable NSString * (^)(void))detail
                      onSelect:(nullable void (^)(void))onSelect;

// A disclosure row that pushes the VC returned by push() onto the nav stack.
+ (instancetype)disclosureRowWithID:(NSString *)rowID
                              title:(NSString *)title
                             detail:(nullable NSString * (^)(void))detail
                               push:(UIViewController * (^)(void))push;

// An accent-tinted action row (uses the theme base's accent action text color).
+ (instancetype)buttonRowWithID:(NSString *)rowID
                          title:(NSString *)title
                         action:(void (^)(void))action;

// Escape hatch: the block owns the cell entirely (dequeue/create + configure).
// onSelect nil => not highlightable.
+ (instancetype)customRowWithID:(NSString *)rowID
                           cell:(ApolloSettingsCellBlock)cell
                       onSelect:(nullable void (^)(void))onSelect;

@property (nonatomic, copy, readonly) NSString *rowID;

// Conditional visibility, evaluated ONLY at load and in -visibilityDidChange
// (the dataSource serves a snapshot). nil == always visible.
@property (nonatomic, copy, nullable) BOOL (^visible)(void);

// For switch rows: control enablement, re-read on every configure. nil == enabled.
@property (nonatomic, copy, nullable) BOOL (^enabled)(void);

// Settings-app-style leading icon tile: a white SF symbol on a colored 29pt
// rounded square (like Settings.app's row icons). Set both or neither.
// Built-in row kinds share reuse pools, so the form resets imageView.image to
// nil on rows without one; custom rows own their imageView (e.g. About's
// fetched avatars) unless they opt in by setting these.
@property (nonatomic, copy, nullable) NSString *iconSystemName;
@property (nonatomic, strong, nullable) UIColor *iconTileColor;

// Insert/delete animation when `visible` flips (default UITableViewRowAnimationFade).
@property (nonatomic) UITableViewRowAnimation showHideAnimation;

// Optional post-configure hook (runs after the built-in configuration, before
// theming). Use for one-off tweaks (fonts, detail color) without a custom row.
@property (nonatomic, copy, nullable) void (^configure)(UITableViewCell *cell);

// Optional fixed height (evaluated per layout pass). nil == table default.
@property (nonatomic, copy, nullable) CGFloat (^height)(void);

@end

@interface ApolloSettingsSection : NSObject

+ (instancetype)sectionWithTitle:(nullable NSString *)title
                          footer:(nullable NSString *)footer
                            rows:(NSArray<ApolloSettingsRow *> *)rows;

@property (nonatomic, copy, nullable, readonly) NSString *title;
@property (nonatomic, copy, nullable) NSString *footer;
@property (nonatomic, copy, readonly) NSArray<ApolloSettingsRow *> *rows;

@end

@interface ApolloSettingsFormViewController : ApolloSettingsTableViewController

// Override: return the full model (including conditionally-visible rows).
// Called once from viewDidLoad; call -rebuildForm to rebuild from scratch.
- (NSArray<ApolloSettingsSection *> *)buildForm;

// Recompute row visibility and animate the per-section insert/delete diff.
- (void)visibilityDidChange;

// Reload a single row in place (no animation), by identity. No-ops when the
// row is currently hidden or the ID is unknown.
- (void)reloadRowWithID:(NSString *)rowID;

// The live cell for a row, or nil when hidden/off-screen. For targeted control
// updates (e.g. animating a sibling switch) without a reload.
- (nullable UITableViewCell *)cellForRowID:(NSString *)rowID;

- (nullable ApolloSettingsRow *)rowWithID:(NSString *)rowID;
- (nullable NSIndexPath *)indexPathForRowID:(NSString *)rowID;

// Rebuild the whole model (drops and re-requests -buildForm) and reloadData.
- (void)rebuildForm;

// Rebuild the model but reload only the section containing rowID — for dynamic
// sections whose rows are generated inside -buildForm (a full reloadData would
// disturb unrelated sections' cells, e.g. an active text-field first responder).
- (void)rebuildSectionContainingRowID:(NSString *)rowID
                     withRowAnimation:(UITableViewRowAnimation)animation;

@end

#ifdef __cplusplus
extern "C" {
#endif

// The shared "(Current)"-suffix action-sheet picker every settings screen used
// to hand-roll: presents optionTitles with the current one suffixed, anchored
// to sourceView for iPad popovers. apply() runs for ANY pick, including
// re-picking the current option (legacy sheet semantics — some handlers rely
// on the re-fire), so apply blocks must be idempotent.
void ApolloSettingsPresentPicker(UIViewController *presenter,
                                 UIView *_Nullable sourceView,
                                 NSString *_Nullable title,
                                 NSArray<NSString *> *optionTitles,
                                 NSInteger currentIndex,
                                 void (^apply)(NSInteger pickedIndex));

// Settings-app-style icon tile: a white SF symbol on a colored 29pt rounded
// square (cached). Shared with settings search so result rows can render the
// same native-style icons. Unknown symbol names fail soft to a plain tile.
UIImage *ApolloSettingsIconTileImage(NSString *symbolName,
                                     UIColor *_Nullable tileColor,
                                     UITraitCollection *_Nullable traits);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
