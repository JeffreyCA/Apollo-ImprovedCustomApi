#import <UIKit/UIKit.h>

// Pinned "Preview" block for settings screens: a card hosted directly in the
// table (never in a cell) that sits on a transparent spacer row and, while
// pinned, stays locked at that resting spot — together with a copy of the
// section title — whichever way the list scrolls or bounces, the rows sliding
// underneath. Unpinned it scrolls like any row. Tap the card to pin/unpin. See
// InlineMediaSettingsViewController for the reference adoption and
// ApolloLinkPreviewSettingsViewController for the form-screen one.
//
// How it fits together:
//   • The screen's "Preview" section keeps its native title and holds ONE row,
//     an ApolloPinnedPreviewSpacerCell (run through
//     ApolloPinnedPreviewClearSpacerCell so no theme pass paints it), whose
//     height is the card's height for the current card width.
//   • The host is a direct subview of the table (ApolloPinnedPreviewAttachHost)
//     and the table is re-classed to ApolloPinnedPreviewTableView, whose layout
//     pass places the card exactly on the spacer row and, while pinned, keeps
//     it (plus a sampled copy of the section title) at that screen position
//     as the list moves, drawing an opaque backdrop so the rows slide
//     underneath. No locking in compact height or when less than
//     kApolloPinnedPreviewMinListViewport of list would remain.
//   • Pin toggle: a pin glyph in the card's top-right corner shows the state
//     (pin.fill in the accent when pinned, pin in tertiaryLabelColor when
//     not); tapping anywhere on the card flips it with a selection haptic, a
//     glyph bounce, a brief "Pinned"/"Unpinned" caption, and the block sliding
//     into / out of its stuck spot. The screen persists the choice (one
//     NSUserDefaults key per screen, default pinned) in pinDidChange.
@interface ApolloPinnedPreviewHost : UIView
@property (nonatomic, strong, readonly) UIView *card;
@property (nonatomic, strong) UIView *contentView;               // the screen's mock, fills the card
@property (nonatomic, strong) UIColor *backdropColor;            // table background, shown while stuck
@property (nonatomic, strong) UIColor *accentColor;              // filled pin glyph
@property (nonatomic, readonly) BOOL stuck;                      // locked with rows sliding beneath
@property (nonatomic) BOOL pinned;                               // default YES
@property (nonatomic, copy) void (^pinDidChange)(BOOL pinned);   // persist + animate, see the recipe
// Where the spacer row lives right now (form screens derive their indices, so
// this is asked on every layout pass rather than fixed at attach time). nil
// hides the host.
@property (nonatomic, copy) NSIndexPath *(^spacerIndexPath)(void);
// Real inset-grouped cell width as measured by the layout pass (0 = not yet
// seen) and the callback the screen uses to re-measure the spacer row when it
// changes (first layout, rotation). Delivered on the next runloop turn — row
// heights can't change inside the table's own layout pass.
@property (nonatomic, readonly) CGFloat measuredCardWidth;
@property (nonatomic, copy) void (^cardWidthDidChange)(CGFloat width);
@end

// Transparent placeholder row that reserves the card's resting slot.
@interface ApolloPinnedPreviewSpacerCell : UITableViewCell
@end
void ApolloPinnedPreviewClearSpacerCell(UITableViewCell *cell);

// Table subclass carrying the layout pass. Ivar-free on purpose: screens
// isa-swizzle their existing table with object_setClass (or subclass it when
// they need their own touch arbitration, as Inline Media does).
@interface ApolloPinnedPreviewTableView : UITableView
@end
// Adds the host to the table and registers it with the layout pass.
void ApolloPinnedPreviewAttachHost(UITableView *table, ApolloPinnedPreviewHost *host);

// Inset-grouped section geometry the card copies so it matches the real cells
// (private UITableView getters with public fallbacks).
UIEdgeInsets ApolloPinnedPreviewSectionContentInset(UITableView *table);
CGFloat ApolloPinnedPreviewSectionCornerRadius(UITableView *table);

// List room needed under the block at rest to bother locking it at all.
extern const CGFloat kApolloPinnedPreviewMinListViewport;
