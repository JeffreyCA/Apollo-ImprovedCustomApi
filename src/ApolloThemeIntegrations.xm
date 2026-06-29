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
    NSString *owner = NSStringFromClass([delegate class]);
    BOOL inScope = [owner containsString:@"ViewController"]
        && ([owner containsString:@"Settings"] || [owner containsString:@"Search"]
            || [owner containsString:@"Friends"]);
    return inScope ? owner : nil;
}

static void ColorListCell(UITableViewCell *cell) {
    if (!ApolloThemeRuntimeIsActive()) return;
    NSString *owner = ListCellOwner(cell);
    if (!owner) return;
    UIColor *sel = SelectionToken();
    if (!sel) return;
    // Eureka cells highlight via selectedBackgroundView — idiomatic + self-
    // restoring. Set the dynamic token once (pointer-identity compare).
    if (cell.selectedBackgroundView.backgroundColor != sel) {
        UIView *bg = [[UIView alloc] init];
        bg.backgroundColor = sel;
        cell.selectedBackgroundView = bg;
    }
    // Apollo's OWN cells ignore selectedBackgroundView and swap backgroundColor,
    // which the seam collapses onto the card — paint the selection directly while
    // pressed and restore the card token on release. Skip Appearance (owns its bg).
    BOOL isApolloCell = [NSStringFromClass([cell class]) containsString:@"Apollo"];
    if (isApolloCell && ![owner containsString:@"Appearance"]) {
        UIColor *want = cell.highlighted ? sel : CardToken();
        if (want && cell.contentView.backgroundColor != want) {
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
    if (accent && icon.tintColor != accent) icon.tintColor = accent;
}

%hook _TtC6Apollo21IconTextTableViewCell
- (void)layoutSubviews { %orig; ApplyAccentImageView(self); }
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig; ApplyAccentImageView(self);
    if (ApolloThemeRuntimeIsActive()) [(UITableViewCell *)self setNeedsLayout];
}
- (void)setSelected:(BOOL)selected animated:(BOOL)animated { %orig; ApplyAccentImageView(self); }
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
    if (accent && [iconNode respondsToSelector:@selector(setTintColor:)])
        ((void (*)(id, SEL, UIColor *))objc_msgSend)(iconNode, @selector(setTintColor:), accent);
    if (accent && [iconNode respondsToSelector:@selector(view)]) {
        UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(iconNode, @selector(view));
        if (view.tintColor != accent) view.tintColor = accent;
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
