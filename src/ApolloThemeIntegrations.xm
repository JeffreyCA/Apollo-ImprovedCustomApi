// ApolloThemeIntegrations.xm — the closed set of non-UIColor integrations
// (spec §16, Pillar 7). These are the surfaces a colour seam can't reach:
//
//   * glyph images Apollo renders non-template under the donor (their colour is
//     baked into the bitmap, so no UIColor accessor ever sees it) — re-template
//     them and tint with the Accent token;
//   * pressed/selection state on Apollo's own UIKit cells and Texture nodes,
//     which they draw by swapping a background colour the seam collapses onto the
//     card — repaint with the Selection token while pressed.
//
// Everything keys on the cached dynamic tokens from ApolloThemeRuntime, so light/
// dark resolves itself — no per-mode lookup, no currentTraitCollection. A token
// getter returning nil (runtime inactive) is the universal guard.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "ApolloThemeTokens.h"
#import "ApolloThemeRuntime.h"

// AsyncDisplayKit's -layoutSpecThatFits: takes an ASSizeRange by value.
typedef struct { CGSize min; CGSize max; } ApolloASSizeRange;

static char kAppliedSourceImageKey;
static char kAppliedTemplateImageKey;
static char kAppliedColorStateKey;
static char kSelectionViewOwnedKey;

// ApolloThemeRuntimeColor/the Accent/Selection/Card token helpers below always
// allocate a FRESH dynamic-provider colour on every call (see ApolloThemeRuntime.h
// — a shared/cached instance over-releases at certain UIKit cell-prep call
// sites), so two colours that are semantically identical are never pointer-equal.
// Comparing against them directly to skip redundant work therefore never skips
// anything. Cache ApolloThemeRuntimeEpoch() (bumped only when the compiled
// tokens or enabled state actually change) alongside any other state the applied
// colour depends on (e.g. highlighted), and skip re-applying when that composite
// key hasn't moved — this is what actually avoids reallocating/reassigning on
// every layoutSubviews/layoutSpecThatFits pass during scroll.
static inline BOOL ApolloThemeStateUnchanged(id object, const void *key, uint64_t state) {
    NSNumber *cached = objc_getAssociatedObject(object, key);
    if ([cached unsignedLongLongValue] == state && cached != nil) return YES;
    objc_setAssociatedObject(object, key, @(state), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return NO;
}

static inline UIColor *AccentToken(void)    { return ApolloThemeRuntimeColor(ApolloThemeTokenAccent); }
static inline UIColor *SelectionToken(void) { return ApolloThemeRuntimeColor(ApolloThemeTokenSelection); }
static inline UIColor *CardToken(void)      { return ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryBackground); }

static id ObjectIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

// ---------------------------------------------------------------------------
// Selection highlight — settings/search UIKit cells
// ---------------------------------------------------------------------------

// The owning VC class name if this cell belongs to an Apollo settings/search
// list, else nil. Scopes every side effect to those screens (the feed/comments
// Texture lists are handled separately, and UIKit's own tables are untouched).
static NSString *ListCellOwner(UITableViewCell *cell) {
    UIView *v = cell.superview;
    while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
    if (![v isKindOfClass:[UITableView class]]) return nil;
    id delegate = ((UITableView *)v).delegate;
    if (!delegate) return nil;
    // The in-scope verdict is a pure function of the delegate's class, and this
    // runs from the global UITableViewCell layoutSubviews hook on every cell
    // layout pass while a theme is active — cache it on the class object
    // instead of re-running NSStringFromClass + five substring scans each time
    // (@"" marks a cached out-of-scope class; class objects are immortal).
    Class cls = [delegate class];
    static char kListCellOwnerVerdictKey;
    NSString *cached = objc_getAssociatedObject(cls, &kListCellOwnerVerdictKey);
    if (cached) return cached.length > 0 ? cached : nil;
    NSString *owner = NSStringFromClass(cls);
    BOOL inScope = [owner containsString:@"ViewController"]
        && ([owner containsString:@"Settings"] || [owner containsString:@"Search"]
            || [owner containsString:@"Friends"] || [owner containsString:@"Inbox"]);
    objc_setAssociatedObject(cls, &kListCellOwnerVerdictKey, inScope ? owner : @"", OBJC_ASSOCIATION_RETAIN);
    return inScope ? owner : nil;
}

static void ColorListCell(UITableViewCell *cell) {
    if (!ApolloThemeRuntimeIsActive()) return;
    NSString *owner = ListCellOwner(cell);
    if (!owner) return;
    UIColor *sel = SelectionToken();
    if (!sel) return;

    BOOL pressed = cell.highlighted || cell.selected;
    uint64_t state = (ApolloThemeRuntimeEpoch() << 1) | (pressed ? 1 : 0);
    BOOL stateChanged = !ApolloThemeStateUnchanged(cell, &kAppliedColorStateKey, state);

    // Eureka cells highlight via selectedBackgroundView — but Eureka's own
    // defaultCellUpdate closures REINSTALL a donor-coloured view (which the seam
    // collapses onto a background token) on every row update, so an install-once
    // replacement loses the race. Recolour whatever view is present IN PLACE —
    // that wins regardless of install order and even repaints a press already in
    // flight — and mark it ours so untouched passes stay cheap.
    UIView *selView = cell.selectedBackgroundView;
    if (!selView) {
        selView = [[UIView alloc] init];
        cell.selectedBackgroundView = selView;
    }
    if (stateChanged || !objc_getAssociatedObject(selView, &kSelectionViewOwnedKey)) {
        selView.backgroundColor = sel;
        objc_setAssociatedObject(selView, &kSelectionViewOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!stateChanged) return;
    // Apollo's OWN cells ignore selectedBackgroundView and swap backgroundColor,
    // which the seam collapses onto a background token — paint the selection
    // directly while pressed/selected and restore the card token on release.
    // (Historical note: Appearance used to be excluded because v1's own
    // willDisplay hook painted those cells; v2 has no such hook, so the
    // exclusion just left Appearance with no visible highlight. The injected
    // Theme Manager row still manages its own chrome — skip only that.)
    NSString *cellClass = NSStringFromClass([cell class]);
    BOOL isApolloCell = [cellClass containsString:@"Apollo"]
        && ![cellClass containsString:@"ThemeManagerRowCell"];
    if (isApolloCell) {
        UIColor *want = pressed ? sel : CardToken();
        if (want) {
            cell.backgroundColor = want;
            cell.contentView.backgroundColor = want;
        }
    }
}

%hook UITableViewCell
- (void)layoutSubviews { %orig; ColorListCell(self); }
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    if (ApolloThemeRuntimeIsActive() && ListCellOwner(self)) [self setNeedsLayout];
}
// Apollo's cells paint the same donor "selected" constant from setSelected: too
// (a tapped row stays selected while the pushed screen is up) — without this the
// pressed repaint flashes back to the collapsed colour the moment selection
// replaces highlight.
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    if (ApolloThemeRuntimeIsActive() && ListCellOwner(self)) [self setNeedsLayout];
}
// Eureka re-runs its cellUpdate closure AT HIGHLIGHT TIME (didHighlightRowAt →
// updateCell), reinstalling its donor-coloured selection view after any earlier
// repair pass — so recolour foreign views at the setter itself, whenever the
// install happens. Marked (already-ours) views pass through untouched.
- (void)setSelectedBackgroundView:(UIView *)view {
    %orig;
    if (!view || !ApolloThemeRuntimeIsActive()) return;
    if (objc_getAssociatedObject(view, &kSelectionViewOwnedKey)) return;
    if (!ListCellOwner(self)) return;
    UIColor *sel = SelectionToken();
    if (!sel) return;
    view.backgroundColor = sel;
    objc_setAssociatedObject(view, &kSelectionViewOwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

// Filters & Blocks uses ApolloSubtitleTableViewCell, which doesn't route its
// layoutSubviews through the base hook.
%hook _TtC6Apollo27ApolloSubtitleTableViewCell
- (void)layoutSubviews { %orig; ColorListCell((UITableViewCell *)self); }
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    if (ApolloThemeRuntimeIsActive()) [(UITableViewCell *)self setNeedsLayout];
}
%end

// ---------------------------------------------------------------------------
// Glyph tinting — UIKit icon cells
// ---------------------------------------------------------------------------

static void ApplyAccentImageView(id cell) {
    if (!ApolloThemeRuntimeIsActive()) return;
    id iconObj = ObjectIvar(cell, "iconImageView");
    if (![iconObj isKindOfClass:[UIImageView class]]) return;
    UIImageView *icon = (UIImageView *)iconObj;
    UIImage *image = icon.image;
    if (image && image.renderingMode != UIImageRenderingModeAlwaysTemplate)
        icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIImage *hi = icon.highlightedImage;
    if (hi && hi.renderingMode != UIImageRenderingModeAlwaysTemplate)
        icon.highlightedImage = [hi imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIColor *accent = AccentToken();
    if (!accent) return;
    if (ApolloThemeStateUnchanged(icon, &kAppliedColorStateKey, ApolloThemeRuntimeEpoch())) return;
    icon.tintColor = accent;
}

// Also the Boxes/Inbox rows (InboxListViewController) — this cell overrides
// layoutSubviews/setSelected: itself, so route selection colouring through here
// rather than relying on the base-class hooks firing.
%hook _TtC6Apollo21IconTextTableViewCell
- (void)layoutSubviews { %orig; ApplyAccentImageView(self); ColorListCell((UITableViewCell *)self); }
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig; ApplyAccentImageView(self);
    if (ApolloThemeRuntimeIsActive()) [(UITableViewCell *)self setNeedsLayout];
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig; ApplyAccentImageView(self);
    if (ApolloThemeRuntimeIsActive()) [(UITableViewCell *)self setNeedsLayout];
}
%end

%hook _TtC6Apollo23IconActionTableViewCell
- (void)layoutSubviews { %orig; ApplyAccentImageView(self); }
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated { %orig; ApplyAccentImageView(self); }
- (void)setSelected:(BOOL)selected animated:(BOOL)animated { %orig; ApplyAccentImageView(self); }
%end

// ---------------------------------------------------------------------------
// Glyph tinting — Texture icon node (profile rows)
// ---------------------------------------------------------------------------

static void ApplyAccentImageNode(id cell) {
    if (!ApolloThemeRuntimeIsActive()) return;
    id iconNode = ObjectIvar(cell, "iconNode");
    id iconImage = ObjectIvar(cell, "iconImage");
    if (!iconNode || ![iconImage isKindOfClass:[UIImage class]]) return;

    UIImage *templated = objc_getAssociatedObject(iconNode, &kAppliedTemplateImageKey);
    if (objc_getAssociatedObject(iconNode, &kAppliedSourceImageKey) != iconImage || !templated) {
        templated = (((UIImage *)iconImage).renderingMode == UIImageRenderingModeAlwaysTemplate)
            ? iconImage : [(UIImage *)iconImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        objc_setAssociatedObject(iconNode, &kAppliedSourceImageKey, iconImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(iconNode, &kAppliedTemplateImageKey, templated, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([iconNode respondsToSelector:@selector(setImage:)]) {
        UIImage *current = [iconNode respondsToSelector:@selector(image)]
            ? ((UIImage *(*)(id, SEL))objc_msgSend)(iconNode, @selector(image)) : nil;
        if (current != templated)
            ((void (*)(id, SEL, UIImage *))objc_msgSend)(iconNode, @selector(setImage:), templated);
    }
    UIColor *accent = AccentToken();
    if (!accent) return;
    if (ApolloThemeStateUnchanged(iconNode, &kAppliedColorStateKey, ApolloThemeRuntimeEpoch())) return;
    if ([iconNode respondsToSelector:@selector(setTintColor:)])
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(iconNode, @selector(setTintColor:), accent);
    if ([iconNode respondsToSelector:@selector(view)]) {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(iconNode, @selector(view));
        view.tintColor = accent;
    }
}

%hook _TtC6Apollo16IconTextCellNode
- (id)layoutSpecThatFits:(ApolloASSizeRange)fits {
    ApplyAccentImageNode(self);
    id spec = %orig;
    ApplyAccentImageNode(self);
    return spec;
}
%end

// ---------------------------------------------------------------------------
// Pressed state — Texture cell nodes (feed posts, comments, profile rows)
// ---------------------------------------------------------------------------

// Repaint the visible card the node darkens on press with the Selection token;
// the node's own %orig restores its colour on release.
static void ApplyNodeHighlight(id node, BOOL highlighted) {
    if (!ApolloThemeRuntimeIsActive() || !highlighted) return;
    UIColor *sel = SelectionToken();
    if (!sel) return;
    // Profile feature rows darken a child inset card (insideNode); post/comment
    // cells darken the node itself.
    id target = ObjectIvar(node, "insideNode");
    if (![target respondsToSelector:@selector(setBackgroundColor:)]) target = node;
    if ([target respondsToSelector:@selector(setBackgroundColor:)])
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(target, @selector(setBackgroundColor:), sel);
}

%hook _TtC6Apollo22ProfileFeatureCellNode
- (void)setHighlighted:(BOOL)highlighted { %orig; ApplyNodeHighlight(self, highlighted); }
%end
%hook _TtC6Apollo17LargePostCellNode
- (void)setHighlighted:(BOOL)highlighted { %orig; ApplyNodeHighlight(self, highlighted); }
%end
%hook _TtC6Apollo19CompactPostCellNode
- (void)setHighlighted:(BOOL)highlighted { %orig; ApplyNodeHighlight(self, highlighted); }
%end
%hook _TtC6Apollo15CommentCellNode
- (void)setHighlighted:(BOOL)highlighted { %orig; ApplyNodeHighlight(self, highlighted); }
%end
