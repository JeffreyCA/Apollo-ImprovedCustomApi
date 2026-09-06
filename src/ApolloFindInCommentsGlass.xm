// ApolloFindInCommentsGlass.xm
//
// Native Liquid Glass treatment for Apollo's in-thread "Find in Comments".
//
// Apollo's comments screen shares its search plumbing with the feed
// (ASTableViewController: an ApolloSearchToolbar resting inside the table with
// an ApolloSearchBarTextField, dismiss button, prev/next chevrons and an "n/m"
// label). What differs is the activation: with searchBarShouldStickToKeyboard
// the toolbar is torn out of the table when the field focuses and docked just
// above the keyboard as [Done] [Find] [^] [v] (sub_1002bea0c / sub_1002bc0b0,
// Apollo 1.15.11), then follows the keyboard down to the screen bottom when it
// hides. The match pipeline underneath is independent of that chrome: the
// text-change handler (Swift vtable slot the ObjC thunk
// textFieldEditingChangedWithSender: dispatches to — CommentsViewController's
// override) rebuilds `commentsSearch` = { Int currentIndex; [Match] matches }
// from the current field text, installs the highlight overlays and scrolls the
// first match into view; the chevron handlers move the index; a query shorter
// than two characters clears the whole state. None of it reads `isSearching`.
//
// On Liquid Glass the feed already replaced Apollo's toolbar with a real
// UISearchController in the navigation bar's palette (ApolloSearchNativeBar.xm:
// the glass pill under the title, in-place activation, scroll-away + pull-
// reveal, continuous collapse). This module gives the comments screen the same
// bar and the same resting behaviour by reusing that machinery — the attach,
// toolbar hide, inset ownership and reveal logic live in ApolloSearchNativeBar,
// gated there on "feed OR comments" — and adds the comments-specific half:
//
//   - a UISearchBar delegate that drives Apollo's find pipeline the way the
//     feed bridge does: mirror the text into Apollo's (hidden) field and call
//     textFieldEditingChangedWithSender: per keystroke. Apollo's field never
//     becomes first responder, so its dock-to-keyboard presentation never runs
//     (nor its refresh-control stash or the isSearching layout branch);
//   - a match navigator in the nav bar's trailing group while a search is
//     live: chevron.up / chevron.down as one custom bar button item, standing
//     in for the collapsible action pill (ApolloNavigationActions.xm: Apollo's
//     sort / more / globe fold into one More pill on Liquid Glass) for the
//     length of the search, with the pill's items restored after. The pill is
//     collapsed first so it neither lingers expanded under the stand-in nor
//     returns expanded. The chevrons call Apollo's own
//     previous/nextResultButtonTappedWithSender:, so the wrap-around, the
//     highlight move and the scroll stay native (and ApolloFindInComments.xm's
//     scroll watchdog + comma multi-term search keep wrapping those calls).
//     The "n/m" count lives in the search field, at its trailing end beside
//     the clear button, the way Safari's find shows its count. The title needs
//     no help: #1035's presentation centres it on the bar and only trims a
//     title that would collide with the trailing content, and two chevrons
//     stay well clear of any comments title;
//   - Apollo's own session side effects that still make sense: the floating
//     comment-jump button hides while a search is live, the keyboard dismisses
//     on drag (Apollo resigned its field once a drag reached 200pt/s), the
//     query survives a push and comes back with the bar text + navigator.
//
// Ending a search (the native round-glass cancel, or the field's clear button
// on a restored query) drives an empty query — the rebuild's own "< 2
// characters" path clears `commentsSearch` — and, because that path leaves the
// highlight overlays' rendering blocks on their text nodes, puts back the
// rendering block each of those nodes had before the search and redraws it
// (see "Highlight bookkeeping" below for why it is a restore, not a clear).
//
// Non-glass is untouched: nothing here runs unless ApolloSearchNativeBar has
// attached a search controller to the comments controller, and it only does so
// on Liquid Glass.
//
// Diagnostics: `log show --predicate 'subsystem == "apollofix"'`, lines tagged
// [FindGlass].

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import "ApolloSearchNativeBar.h"
#import "ApolloNavigationActions.h"
#import "ApolloFindInCommentsGlass.h"

@interface _TtC6Apollo22CommentsViewController : UIViewController
- (void)textFieldEditingChangedWithSender:(id)sender;
- (void)nextResultButtonTappedWithSender:(id)sender;
- (void)previousResultButtonTappedWithSender:(id)sender;
- (void)searchCommentsKeyCommandSelected;
@end

// Minimal Texture declarations (resolved at runtime against Apollo's bundled
// AsyncDisplayKit; per-file copies on purpose, see ApolloTextureDecls.h).
@interface ASDisplayNode : NSObject
@property (nonatomic, readonly) BOOL isNodeLoaded;
- (void)setNeedsDisplay;
@end

@interface ASTextNode : ASDisplayNode
- (id)didDisplayNodeContentWithRenderingContext;
- (void)setDidDisplayNodeContentWithRenderingContext:(id)block;
@end

// Runtime ivar reader; walks the superclass chain so inherited ivars resolve.
static id FGObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return object_getIvar(object, ivar);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static UITextField *FGApolloField(UIViewController *vc) {
    id field = FGObjectIvar(vc, "searchTextField");
    return [field isKindOfClass:[UITextField class]] ? (UITextField *)field : nil;
}

// Apollo's match state, read straight from the Swift struct stored inline in
// ASTableViewController: { Int currentIndex; [CommentsSearchMatch] matches }.
// The array's storage pointer is NULL when no search is active (Apollo's own
// "n/m" renderer, sub_1002bbe18, tests exactly that word); a live array is a
// Swift ContiguousArrayStorage whose element count sits at +0x10.
static BOOL FGReadMatchState(UIViewController *vc, NSInteger *outIndex, NSInteger *outCount) {
    if (!vc) return NO;
    Ivar ivar = class_getInstanceVariable(object_getClass(vc), "commentsSearch");
    if (!ivar) return NO;
    const char *base = (const char *)(__bridge void *)vc + ivar_getOffset(ivar);
    intptr_t index = *(const intptr_t *)base;
    uintptr_t storage = *(const uintptr_t *)(base + sizeof(intptr_t));
    if (storage == 0) return NO;
    intptr_t count = *(const intptr_t *)(storage + 0x10);
    if (count < 0 || count > 1000000) return NO;   // not an array we understand
    if (outIndex) *outIndex = index;
    if (outCount) *outCount = count;
    return YES;
}

NSString *ApolloFindInCommentsGlassPlaceholder(void) {
    return @"Find in Comments";
}

// MARK: - Highlight bookkeeping
//
// Apollo installs each match's highlight as a rendering block on the match's
// text node (setDidDisplayNodeContentWithRenderingContext:) and never removes
// it — a node that drops out of the match list keeps redrawing its stale range
// until the cell is recycled, and clearing the search leaves the current
// match's highlight behind the same way. That setter is not the search's
// alone: MarkdownNode gives every comment body's text node a rendering block
// of its own when it builds it (and MarkdownTableCellNode its cells), so the
// highlight block REPLACES drawing the comment relies on. Two rules keep this
// safe: the tracking window is opened only around Apollo's rebuild / selection
// calls (FGRunApolloSelection), where the blocks are installed synchronously,
// and never while merely scrolling a live search; and what we remember per
// node is the block that was there BEFORE Apollo's first replacement, so
// ending the search puts that original back (nil for a node that had none)
// and redraws — rather than blanking the node. The hook is a static-BOOL test
// outside the window.
static BOOL sFGTrackHighlightBlocks = NO;
static NSMapTable<ASTextNode *, id> *sFGOriginalBlocks = nil;   // weak node -> its pre-search block (NSNull for none)

// Run one of Apollo's match-changing calls with the highlight tracker armed.
static void FGRunApolloSelection(dispatch_block_t call) {
    BOOL was = sFGTrackHighlightBlocks;
    sFGTrackHighlightBlocks = YES;
    call();
    sFGTrackHighlightBlocks = was;
}

// Called from the setter hook BEFORE the replacement lands: the node's current
// block is still the original. First sight wins — a later re-selection of the
// same node sees Apollo's highlight block as "current", which is not it.
static void FGNoteHighlightedNode(ASTextNode *node) {
    if (!node) return;
    if (!sFGOriginalBlocks) sFGOriginalBlocks = [NSMapTable weakToStrongObjectsMapTable];
    if ([sFGOriginalBlocks objectForKey:node]) return;
    id original = nil;
    if ([node respondsToSelector:@selector(didDisplayNodeContentWithRenderingContext)]) {
        original = [node didDisplayNodeContentWithRenderingContext];
    }
    [sFGOriginalBlocks setObject:(original ?: (id)NSNull.null) forKey:node];
}

static void FGClearHighlights(void) {
    NSMapTable<ASTextNode *, id> *map = sFGOriginalBlocks;
    sFGOriginalBlocks = nil;
    if (map.count == 0) return;
    NSUInteger restored = 0;
    for (ASTextNode *node in map.keyEnumerator) {
        id original = [map objectForKey:node];
        if (original == (id)NSNull.null) original = nil;
        if ([node respondsToSelector:@selector(setDidDisplayNodeContentWithRenderingContext:)]) {
            [node setDidDisplayNodeContentWithRenderingContext:original];
        }
        if ([node isNodeLoaded]) [node setNeedsDisplay];
        restored++;
    }
    ApolloLog(@"[FindGlass] restored %lu text nodes' pre-search rendering", (unsigned long)restored);
}

%hook ASTextNode
- (void)setDidDisplayNodeContentWithRenderingContext:(id)block {
    if (sFGTrackHighlightBlocks && block) FGNoteHighlightedNode((ASTextNode *)self);
    %orig;
}
%end

%hook ASTextNode2
- (void)setDidDisplayNodeContentWithRenderingContext:(id)block {
    if (sFGTrackHighlightBlocks && block) FGNoteHighlightedNode((ASTextNode *)self);
    %orig;
}
%end

// MARK: - Bridge
//
// One per comments controller (retained by it). Holds the navigator items and
// the session bookkeeping; every reference back to Apollo's objects is weak or
// re-read from the controller's ivars, so a popped screen just lets go.

static const void *kFGBridgeKey     = &kFGBridgeKey;      // VC -> bridge
static const void *kFGNavItemOwnerKey = &kFGNavItemOwnerKey; // UINavigationItem -> weak box of the owning bridge

@interface ApolloFindGlassWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation ApolloFindGlassWeakBox
@end

// MARK: - Navigator capsule
//
// [^ v] as ONE custom bar button item. UIKit wraps a custom view in its own
// glass platter, so this reads as a capsule where the action pill sat. Two
// 34pt slots (Apollo's own icon slot width) with a little breathing room; the
// count is not in here (it lives in the search field), so the capsule never
// changes width during a search.

static const CGFloat kFGNavigatorHeight = 36.0;  // Apollo's trailing icon slot height
static const CGFloat kFGNavigatorSlot   = 34.0;  // Apollo's icon slot width
static const CGFloat kFGNavigatorInset  = 4.0;   // breathing room inside the capsule (UIKit's platter adds its own)

@interface ApolloFindGlassNavigatorView : UIView
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *nextButton;
@end

@implementation ApolloFindGlassNavigatorView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];

    _previousButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_previousButton setImage:[UIImage systemImageNamed:@"chevron.up" withConfiguration:cfg]
                     forState:UIControlStateNormal];
    _previousButton.accessibilityLabel = @"Previous match";
    [self addSubview:_previousButton];

    _nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_nextButton setImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg]
                 forState:UIControlStateNormal];
    _nextButton.accessibilityLabel = @"Next match";
    [self addSubview:_nextButton];
    CGSize size = [self intrinsicContentSize];
    self.frame = CGRectMake(0.0, 0.0, size.width, size.height);
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kFGNavigatorInset * 2.0 + kFGNavigatorSlot * 2.0, kFGNavigatorHeight);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return [self intrinsicContentSize];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = CGRectGetHeight(self.bounds);
    self.previousButton.frame = CGRectMake(kFGNavigatorInset, 0.0, kFGNavigatorSlot, height);
    self.nextButton.frame = CGRectMake(kFGNavigatorInset + kFGNavigatorSlot, 0.0, kFGNavigatorSlot, height);
}

@end

// MARK: - Count in the search field
//
// "n/m" sits inside the search field, at its trailing end just before the
// clear button (Safari's find puts its count there too). The label is a plain
// subview of the UISearchTextField; the hooks below make room for it in the
// text rect and place it against the clear button's rect, for tagged fields
// only — every other search field pays one associated-object lookup.

static const void *kFGCountLabelKey = &kFGCountLabelKey;   // UISearchTextField -> our count label
static const CGFloat kFGCountGap = 6.0;

static UILabel *FGCountLabelForField(UIView *field) {
    return objc_getAssociatedObject(field, kFGCountLabelKey);
}

static UILabel *FGEnsureCountLabel(UITextField *field) {
    if (!field) return nil;
    UILabel *label = FGCountLabelForField(field);
    if (!label) {
        label = [[UILabel alloc] init];
        label.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightRegular];
        label.textColor = UIColor.secondaryLabelColor;
        label.textAlignment = NSTextAlignmentRight;
        label.userInteractionEnabled = NO;
        label.hidden = YES;
        label.accessibilityTraits = UIAccessibilityTraitStaticText;
        objc_setAssociatedObject(field, kFGCountLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (label.superview != field) [field addSubview:label];
    return label;
}

static void FGRemoveCountLabel(UITextField *field) {
    UILabel *label = FGCountLabelForField(field);
    if (!label) return;
    [label removeFromSuperview];
    objc_setAssociatedObject(field, kFGCountLabelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [field setNeedsLayout];
}

static void FGSetCountText(UITextField *field, NSString *text) {
    UILabel *label = FGEnsureCountLabel(field);
    if (!label) return;
    BOOL hide = text.length == 0;
    BOOL changed = label.hidden != hide || ![label.text ?: @"" isEqualToString:text ?: @""];
    if (!changed) return;
    label.text = text;
    [label sizeToFit];
    label.hidden = hide;
    [field setNeedsLayout];
}

// Width the count takes out of the text rect (0 when nothing is shown).
static CGFloat FGCountReservedWidth(UIView *field) {
    UILabel *label = FGCountLabelForField(field);
    if (!label || label.hidden || label.superview != field) return 0.0;
    return CGRectGetWidth(label.bounds) + kFGCountGap;
}

%hook UISearchTextField

- (CGRect)textRectForBounds:(CGRect)bounds {
    CGRect rect = %orig;
    CGFloat reserved = FGCountReservedWidth(self);
    if (reserved > 0.0 && reserved < CGRectGetWidth(rect)) rect.size.width -= reserved;
    return rect;
}

- (CGRect)editingRectForBounds:(CGRect)bounds {
    CGRect rect = %orig;
    CGFloat reserved = FGCountReservedWidth(self);
    if (reserved > 0.0 && reserved < CGRectGetWidth(rect)) rect.size.width -= reserved;
    return rect;
}

- (void)layoutSubviews {
    %orig;
    UILabel *label = FGCountLabelForField(self);
    if (!label || label.hidden || label.superview != self) return;
    // Against the clear button's slot (present whenever the field has text,
    // which it always does while a count shows), vertically on the text line.
    CGRect clear = [self clearButtonRectForBounds:self.bounds];
    CGFloat right = CGRectGetWidth(clear) > 0.0 ? CGRectGetMinX(clear) - kFGCountGap
                                                : CGRectGetWidth(self.bounds) - 12.0;
    CGSize size = label.bounds.size;
    label.frame = CGRectMake(round(right - size.width),
                             round((CGRectGetHeight(self.bounds) - size.height) / 2.0),
                             size.width, size.height);
}

%end

@interface ApolloFindInCommentsGlassBridge : NSObject <UISearchBarDelegate, UISearchControllerDelegate>
@property (nonatomic, weak) UIViewController *commentsVC;
@property (nonatomic, strong) UIBarButtonItem *navigatorItem;          // the one trailing item: [^ v]
@property (nonatomic, strong) ApolloFindGlassNavigatorView *navigatorView;
@property (nonatomic, copy) NSArray<UIBarButtonItem *> *savedRightItems; // Apollo's items, restored after the search
@property (nonatomic, assign) BOOL navigatorInstalled;
@property (nonatomic, assign) BOOL applyingItems;   // our own rightBarButtonItems writes pass the hook below
@property (nonatomic, assign) BOOL transitioning;   // between viewWillDisappear and viewDidAppear
@property (nonatomic, strong) NSNumber *savedKeyboardDismissMode;
@property (nonatomic, strong) NSNumber *savedJumpButtonAlpha;
@end

static ApolloFindInCommentsGlassBridge *FGBridge(UIViewController *vc, BOOL create) {
    if (!vc) return nil;
    ApolloFindInCommentsGlassBridge *bridge = objc_getAssociatedObject(vc, kFGBridgeKey);
    if (!bridge && create) {
        bridge = [[ApolloFindInCommentsGlassBridge alloc] init];
        bridge.commentsVC = vc;
        objc_setAssociatedObject(vc, kFGBridgeKey, bridge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return bridge;
}

static ApolloFindInCommentsGlassBridge *FGBridgeOwningNavItem(UINavigationItem *navItem) {
    ApolloFindGlassWeakBox *box = objc_getAssociatedObject(navItem, kFGNavItemOwnerKey);
    return box.object;
}

id ApolloFindInCommentsGlassBridgeForController(UIViewController *vc) {
    return FGBridge(vc, YES);
}

BOOL ApolloFindInCommentsGlassOwnsRightItems(UINavigationItem *navItem) {
    if (!navItem) return NO;
    ApolloFindInCommentsGlassBridge *bridge = FGBridgeOwningNavItem(navItem);
    return bridge != nil && bridge.navigatorInstalled;
}

static UIScrollView *FGTableForVC(UIViewController *vc) {
    id tableNode = FGObjectIvar(vc, "tableNode");
    UIView *tv = [tableNode respondsToSelector:@selector(view)] ? [tableNode view] : nil;
    return [tv isKindOfClass:[UIScrollView class]] ? (UIScrollView *)tv : nil;
}

static UIView *FGJumpButton(UIViewController *vc) {
    id button = FGObjectIvar(vc, "commentJumpButton");
    return [button isKindOfClass:[UIView class]] ? (UIView *)button : nil;
}

static UIColor *FGAccent(UIViewController *vc) {
    return ApolloThemeAccentColor() ?: vc.navigationController.navigationBar.tintColor ?: UIColor.systemBlueColor;
}

@implementation ApolloFindInCommentsGlassBridge

// MARK: navigator items

- (void)buildItemsIfNeeded {
    if (self.navigatorItem) return;
    ApolloFindGlassNavigatorView *view = [[ApolloFindGlassNavigatorView alloc] init];
    [view.previousButton addTarget:self action:@selector(previousTapped:) forControlEvents:UIControlEventTouchUpInside];
    [view.nextButton addTarget:self action:@selector(nextTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.navigatorView = view;
    self.navigatorItem = [[UIBarButtonItem alloc] initWithCustomView:view];
}

- (NSArray<UIBarButtonItem *> *)navigatorItems {
    [self buildItemsIfNeeded];
    return @[self.navigatorItem];
}

- (BOOL)itemsAreOurs:(NSArray<UIBarButtonItem *> *)items {
    return self.navigatorItem && items.count == 1 && items[0] == self.navigatorItem;
}

// Reflect Apollo's match state into the navigator: "n/m" (Apollo's own label
// format, "0/0" for a query with no hits, an empty slot while no search is
// active) and chevrons enabled only when there is something to step through.
- (void)updateNavigator {
    UIViewController *vc = self.commentsVC;
    if (!vc || !self.navigatorView) return;
    NSInteger index = 0, count = 0;
    BOOL active = FGReadMatchState(vc, &index, &count);
    NSString *text = @"";
    if (active) text = count > 0 ? [NSString stringWithFormat:@"%ld/%ld", (long)(index + 1), (long)count] : @"0/0";
    FGSetCountText(vc.navigationItem.searchController.searchBar.searchTextField, text);
    BOOL enable = active && count > 0;
    if (self.navigatorView.nextButton.enabled != enable) self.navigatorView.nextButton.enabled = enable;
    if (self.navigatorView.previousButton.enabled != enable) self.navigatorView.previousButton.enabled = enable;
    UIColor *accent = FGAccent(vc);
    self.navigatorView.nextButton.tintColor = accent;
    self.navigatorView.previousButton.tintColor = accent;
}

- (void)installNavigator {
    UIViewController *vc = self.commentsVC;
    UINavigationItem *navItem = vc.navigationItem;
    if (!vc || !navItem || self.navigatorInstalled) return;
    [self buildItemsIfNeeded];

    // Fold the action pill before taking its place, so it is not left expanded
    // behind the navigator and does not come back expanded with its items.
    ApolloNavigationActionsCollapse(navItem);
    NSArray<UIBarButtonItem *> *current = navItem.rightBarButtonItems;
    if (![self itemsAreOurs:current]) self.savedRightItems = current;

    ApolloFindGlassWeakBox *box = objc_getAssociatedObject(navItem, kFGNavItemOwnerKey);
    if (!box) {
        box = [ApolloFindGlassWeakBox new];
        objc_setAssociatedObject(navItem, kFGNavItemOwnerKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.object = self;
    // Ownership is flagged BEFORE the write so the globe merge in
    // ApolloTranslation.xm (which runs from the setter hook) stands down.
    self.navigatorInstalled = YES;
    FGEnsureCountLabel(vc.navigationItem.searchController.searchBar.searchTextField);
    self.applyingItems = YES;
    navItem.rightBarButtonItems = [self navigatorItems];
    self.applyingItems = NO;

    // Apollo hides its floating comment-jump button for the length of a search
    // (its presentation sets alpha 0, the dismiss restores it); it would
    // otherwise compete with the navigator for "go to the next thing".
    UIView *jump = FGJumpButton(vc);
    if (jump && !self.savedJumpButtonAlpha) {
        self.savedJumpButtonAlpha = @(jump.alpha);
        jump.alpha = 0.0;
    }
    // Apollo resigned its own field once a drag got going; with the field in
    // the palette the table's dismiss mode does the same job.
    UIScrollView *table = FGTableForVC(vc);
    if (table && !self.savedKeyboardDismissMode) {
        self.savedKeyboardDismissMode = @(table.keyboardDismissMode);
        table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    }
    [self updateNavigator];
    ApolloLog(@"[FindGlass] navigator installed (saved %lu trailing items)", (unsigned long)self.savedRightItems.count);
}

- (void)removeNavigator {
    UIViewController *vc = self.commentsVC;
    UINavigationItem *navItem = vc.navigationItem;
    if (!self.navigatorInstalled) return;
    self.navigatorInstalled = NO;
    if (navItem) {
        self.applyingItems = YES;
        navItem.rightBarButtonItems = self.savedRightItems;
        self.applyingItems = NO;
    }
    self.savedRightItems = nil;
    FGRemoveCountLabel(vc.navigationItem.searchController.searchBar.searchTextField);
    UIView *jump = FGJumpButton(vc);
    if (jump && self.savedJumpButtonAlpha) jump.alpha = self.savedJumpButtonAlpha.doubleValue;
    self.savedJumpButtonAlpha = nil;
    UIScrollView *table = FGTableForVC(vc);
    if (table && self.savedKeyboardDismissMode) {
        table.keyboardDismissMode = (UIScrollViewKeyboardDismissMode)self.savedKeyboardDismissMode.integerValue;
    }
    self.savedKeyboardDismissMode = nil;
    ApolloLog(@"[FindGlass] navigator removed");
}

// MARK: driving Apollo

// Mirror the text into Apollo's hidden field and run its text-change handler:
// the CommentsViewController override rebuilds the match list from the field's
// text, installs the highlights and scrolls the first match into view (the
// scroll watchdog and the comma multi-term search in ApolloFindInComments.xm
// wrap that same call).
- (void)driveQuery:(NSString *)text {
    UIViewController *vc = self.commentsVC;
    UITextField *field = FGApolloField(vc);
    if (!vc || !field) return;
    NSString *query = text ?: @"";
    if (![field.text isEqualToString:query]) field.text = query;
    if ([vc respondsToSelector:@selector(textFieldEditingChangedWithSender:)]) {
        FGRunApolloSelection(^{
            ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(textFieldEditingChangedWithSender:), field);
        });
    }
    [self updateNavigator];
}

// End the search: Apollo's rebuild clears its match state for a query under
// two characters, then the leftover highlight blocks go, then Apollo's items
// come back.
- (void)endSearch {
    UIViewController *vc = self.commentsVC;
    if (!vc) return;
    UITextField *field = FGApolloField(vc);
    BOOL hadQuery = field.text.length > 0;
    if (hadQuery || FGReadMatchState(vc, NULL, NULL)) [self driveQuery:@""];
    FGClearHighlights();
    [self removeNavigator];
    ApolloLog(@"[FindGlass] search ended (hadQuery=%d)", (int)hadQuery);
}

- (void)previousTapped:(id)sender {
    UIViewController *vc = self.commentsVC;
    if (!vc) return;
    if ([vc respondsToSelector:@selector(previousResultButtonTappedWithSender:)]) {
        FGRunApolloSelection(^{
            ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(previousResultButtonTappedWithSender:), sender);
        });
    }
    [self updateNavigator];
}

- (void)nextTapped:(id)sender {
    UIViewController *vc = self.commentsVC;
    if (!vc) return;
    if ([vc respondsToSelector:@selector(nextResultButtonTappedWithSender:)]) {
        FGRunApolloSelection(^{
            ((void (*)(id, SEL, id))objc_msgSend)(vc, @selector(nextResultButtonTappedWithSender:), sender);
        });
    }
    [self updateNavigator];
}

// MARK: UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    if (!self.commentsVC) return;
    [self installNavigator];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (!self.commentsVC) return;
    // An empty change with the field unfocused is one of two things (same
    // split the feed bridge makes). During a push it is UIKit clearing the bar
    // as it deactivates the search UI — ignore it, the query lives on Apollo's
    // field and comes back with the screen. At rest it is the clear button on a
    // restored query: that ends the search.
    if (searchText.length == 0 && !searchBar.isFirstResponder) {
        if (!self.transitioning) [self endSearch];
        return;
    }
    if (!self.navigatorInstalled) [self installNavigator];
    [self driveQuery:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    // Apollo's return key drops the keyboard and keeps the search up; the
    // matches, highlights and navigator all stay for stepping through.
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    if (searchBar.text.length > 0) searchBar.text = @"";
    [self endSearch];
}

@end

// MARK: - Appearance hooks (called from ApolloSearchNativeBar.xm)

void ApolloFindInCommentsGlassViewWillAppear(UIViewController *vc) {
    ApolloFindInCommentsGlassBridge *bridge = FGBridge(vc, NO);
    if (!bridge) return;
    // Returning to a live search (back from a link or a profile opened out of a
    // comment): UIKit cleared the bar when the search UI deactivated for the
    // push, Apollo's field still holds the query. Put the text back and keep the
    // navigator up so the matches can still be stepped through or the search
    // ended.
    UITextField *field = FGApolloField(vc);
    UISearchBar *bar = vc.navigationItem.searchController.searchBar;
    if (field.text.length > 0) {
        if (bar && ![bar.text isEqualToString:field.text]) bar.text = field.text;
        [bridge installNavigator];
        [bridge updateNavigator];
    } else if (bridge.navigatorInstalled && !FGReadMatchState(vc, NULL, NULL)) {
        [bridge removeNavigator];
    }
}

void ApolloFindInCommentsGlassViewDidAppear(UIViewController *vc) {
    ApolloFindInCommentsGlassBridge *bridge = FGBridge(vc, NO);
    bridge.transitioning = NO;
}

void ApolloFindInCommentsGlassViewWillDisappear(UIViewController *vc) {
    ApolloFindInCommentsGlassBridge *bridge = FGBridge(vc, NO);
    bridge.transitioning = YES;
}

// MARK: - Hooks

// Apollo rebuilds its trailing items on various events (the moderator button
// after the mod-status load, sort changes) and re-sets them wholesale. While the
// navigator owns the trailing group, take those writes as the new "restore"
// set instead of letting them replace the chevrons mid-search.
%hook UINavigationItem

- (void)setRightBarButtonItems:(NSArray<UIBarButtonItem *> *)items animated:(BOOL)animated {
    ApolloFindInCommentsGlassBridge *bridge = FGBridgeOwningNavItem(self);
    if (bridge && bridge.navigatorInstalled && !bridge.applyingItems && ![bridge itemsAreOurs:items]) {
        bridge.savedRightItems = items;
        return;
    }
    %orig;
}

- (void)setRightBarButtonItem:(UIBarButtonItem *)item animated:(BOOL)animated {
    ApolloFindInCommentsGlassBridge *bridge = FGBridgeOwningNavItem(self);
    if (bridge && bridge.navigatorInstalled && !bridge.applyingItems) {
        bridge.savedRightItems = item ? @[item] : @[];
        return;
    }
    %orig;
}

%end

// The hardware-keyboard shortcut (Cmd-F) focuses Apollo's field directly and
// runs its dock-to-keyboard presentation without going through the delegate.
// With the native bar attached, route it to the palette instead.
%hook _TtC6Apollo22CommentsViewController

- (void)searchCommentsKeyCommandSelected {
    UISearchController *sc = self.navigationItem.searchController;
    if (sc && FGBridge(self, NO)) {
        if (!sc.active) sc.active = YES;
        [sc.searchBar becomeFirstResponder];
        return;
    }
    %orig;
}

%end

%ctor {
    %init;
    ApolloLog(@"[FindGlass] hooks installed (native glass Find in Comments)");
}
