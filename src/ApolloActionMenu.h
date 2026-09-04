// ApolloActionMenu — feature-neutral single owner of Apollo's "..." action-menu
// geometry, on BOTH rendering paths:
//   - Liquid Glass (iOS 26): ApolloNativeActionMenus.xm converts Apollo's private
//     ActionController sheet into a real UIKit UIMenu. This module supplies the
//     extra UIMenuElements to splice into that menu's children.
//   - Everything else: Apollo presents _TtC6Apollo16ActionController, a plain
//     UIViewController+UITableView bottom sheet. This module owns EVERY hook on
//     that class's table methods and on
//     _TtC6Apollo38ActionControllerPresentationController's geometry.
//
// Exactly ONE module may hook _TtC6Apollo16ActionController's table delegate/
// dataSource methods or ActionControllerPresentationController's
// frameOfPresentedViewInContainerView. THIS IS THAT OWNER. A second module
// hooking either of those on the same class re-enters the chain in an index
// space the first module has already shifted — see src/settings/README.md's
// "one remapper per screen, always" rule and PR #570 for why. Feature modules
// never touch the table; they register WHAT they mean at %ctor time via
// ApolloActionMenuRegister(). Registration order — and Makefile link order — is
// irrelevant; slots are computed lazily, per controller, the first time any of
// them is asked about.
//
// Additive only: this owns injecting/replacing rows, not hiding native ones.
// A feature that needs to remove a native row (e.g. ApolloTranslation.xm's
// bulk-translate row removal) mutates Apollo's raw Swift `actions` buffer
// directly, in native index space, before presentation — that's a disjoint
// concern this module doesn't need to know about (it composes cleanly: the
// owner only ever sees the post-mutation native row count).
//
// See ApolloActionMenu.xm for the registry, the per-controller slot memoization,
// and the shared lookalike row cell.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Where a declarative spec's row lands in the Liquid Glass UIMenu's children.
// Legacy-sheet placement is NOT configurable here: every injected row is always
// appended after the last native row on that path, ordered by `order`/
// `identifier` — Apollo's own cellForRow dequeues with the index path it's
// handed and UIKit asserts if a native row's index shifts, so native rows can
// never move on the legacy path regardless of glass placement.
typedef NS_ENUM(NSInteger, ApolloActionMenuPlacement) {
    // End of the menu's children (DeletedComments' "Show/Hide Deleted Comments").
    ApolloActionMenuPlacementAppend = 0,
    // Immediately after the leading "Submit Post" row/post-type group, before
    // everything else (Gallery View — reads as its own group right under the
    // composer, never above it).
    ApolloActionMenuPlacementAfterLeadingSubmitAffordance,
};

// One potential row. Register from a feature's %ctor via
// ApolloActionMenuRegister(). Every block may be called multiple times across
// the lifetime of a single sheet/menu presentation; `matches` is the only one
// memoized per actionController (see ApolloActionMenu.xm), so it is safe (and
// intended) for a feature to do one-shot claiming/disarming work inside it.
@interface ApolloActionMenuSpec : NSObject

// Required. Used as the legacy-sheet reuse identifier, the log prefix, and the
// `order` tiebreak.
@property (nonatomic, copy) NSString *identifier;

// Tiebreak among multiple injected rows on the SAME sheet, ascending; ties break
// on `identifier`. Independent of %ctor/Makefile link order. Default 0.
@property (nonatomic, assign) NSInteger order;

// Does this spec apply to this presentation? `menuTitle` is Apollo's own
// actionsDescription string for the sheet (read once by the owner and handed to
// every spec — see the header note on ApolloActionMenuInjectMenuElements).
// Called once per controller and memoized; do any one-shot arm-claiming or
// disarming here, not in `perform`.
@property (nonatomic, copy) BOOL (^matches)(id actionController, NSString *menuTitle);

// Row title/image, re-evaluated on every call (NOT memoized) so state that
// changes between builds (DeletedComments' Show <-> Hide) stays correct. `donor`
// is the live, already-built row-0 cell on the legacy path (for deriving text
// styled the way Apollo's own rows are, e.g. PublicSticky's "<row 0's label> +
// suffix"); nil on the glass path, where there is no cell to donate from.
@property (nonatomic, copy) NSString *(^title)(id actionController, UITableViewCell *_Nullable donor);
@property (nonatomic, copy) UIImage *_Nullable (^image)(id actionController, UITableViewCell *_Nullable donor);

// Glass-menu insertion point for the declarative title/image path. Ignored if
// `buildElement` is set.
@property (nonatomic, assign) ApolloActionMenuPlacement placement;

// Wrap the declarative row in its own UIMenuOptionsDisplayInline single-item
// section (Gallery: YES, reads as a separated group; DeletedComments: NO).
@property (nonatomic, assign) BOOL inlineSection;

// Tap handler, shared by both paths.
@property (nonatomic, copy) void (^perform)(id actionController);

// Legacy path only: dismiss the sheet before running `perform`? Default YES
// (Gallery, DeletedComments both dismiss then act). PublicSticky needs NO: its
// `perform` forwards into the NATIVE row's own handler via
// ApolloActionMenuInvokeNativeRow(), which drives Apollo's own compose flow and
// dismisses itself. On the glass path this is never relevant — there's no
// sheet, and ApolloNativeActionMenus.xm already swallows an ActionController's
// self-dismiss while its "invoking" flag is set.
@property (nonatomic, assign) BOOL legacyDismissesSheet;

// Escape hatch for the glass path, for specs whose row can't be expressed
// declaratively (PublicSticky clones a NATIVE UIMenuElement's title/image/
// attributes/handler rather than building a new one, and inserts at an index it
// discovers mid-scan rather than a fixed placement). Takes the live children
// array so the block owns its own placement; return by mutating `children`, not
// a return value. When set, `title`/`image`/`placement`/`inlineSection` are
// ignored on the glass path (still used for the legacy row, since the legacy
// path has no equivalent escape hatch — the shared row cell covers it).
@property (nonatomic, copy, nullable) void (^buildElement)(id actionController, NSMutableArray<UIMenuElement *> *children);

@end

// Register a spec. Call from a feature's %ctor, after %init.
void ApolloActionMenuRegister(ApolloActionMenuSpec *spec);

// The square box menu row icons are fitted into, in points. Apollo's own
// option-* assets are ~24pt on the long edge and its legacy sheet shows them
// at natural size, so 24 is the weight a row icon needs to sit next to them
// (#985 review).
static const CGFloat ApolloActionMenuIconBoxSide = 24.0;

// An SF Symbol rendered as a plain template raster carrying the same visual
// weight as Apollo's option-* assets in the glass menu. UIMenu renders symbol
// images through its own (smaller, text-derived) symbol configuration no
// matter what configuration the image was created with, so a spec row that
// hands UIMenu a raw symbol sits visibly lighter than the native rows around
// it. Flattening the symbol into a bitmap sized to ApolloActionMenuIconBoxSide
// takes UIMenu's restyling out of the loop entirely. Returns nil for unknown
// symbol names.
UIImage *_Nullable ApolloActionMenuSymbolIcon(NSString *symbolName);

// Glass path entry point, called once by ApolloNativeActionMenuBuildMenu while
// assembling a sheet's UIMenu children, after Apollo's own native actions have
// been appended and before the array is wrapped into the final UIMenu.
void ApolloActionMenuInjectMenuElements(NSMutableArray<UIMenuElement *> *children,
                                        NSString *menuTitle,
                                        id actionController);

// A donor cell's rendered label text (first non-empty UILabel found by walking
// the cell's content tree). Apollo's action-sheet rows are custom-drawn, not
// built on UITableViewCell.textLabel, so a spec deriving its legacy-path title
// from the native row's own text (e.g. "<row 0's label> + suffix") must go
// through this rather than reading donor.textLabel directly. nil when `donor`
// is nil (the glass path never has one) or no label is found.
NSString *_Nullable ApolloActionMenuDonorLabelText(UITableViewCell *_Nullable donor);

// Legacy path: run a NATIVE row's own didSelectRowAtIndexPath: handler as if it
// had been tapped directly, for a spec whose `perform` forwards into existing
// Apollo behavior (PublicSticky re-running "Public Sticky"'s own compose flow).
// Deliberately does NOT flag the controller as "invoking" the way
// ApolloNativeActionMenuSelectRow (ApolloNativeActionMenus.xm, glass-only) does:
// on the legacy path the sheet is genuinely on screen and must actually
// dismiss when the native handler dismisses it, not have that swallowed.
void ApolloActionMenuInvokeNativeRow(id actionController, NSInteger row);

NS_ASSUME_NONNULL_END
