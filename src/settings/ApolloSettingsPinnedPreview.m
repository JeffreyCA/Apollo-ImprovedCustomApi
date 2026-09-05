#import "ApolloSettingsPinnedPreview.h"

#import "ApolloCommon.h"

#import <objc/message.h>
#import <objc/runtime.h>

// Extracted from InlineMediaSettingsViewController (the reference adoption)
// so every settings screen with a live preview behaves and looks the same:
// same sticking rules, same pin glyph, caption and animation.

static const CGFloat kApolloPinnedPreviewStuckBottomPad = 8.0;  // backdrop below the card
const CGFloat kApolloPinnedPreviewMinListViewport = 200.0;      // list room needed to bother sticking
static const CGFloat kApolloPinnedPreviewPinInset = 12.0;       // card right edge → pin glyph
static const CGFloat kApolloPinnedPreviewPinTop = 7.0;          // card top → pin glyph
static const CGFloat kApolloPinnedPreviewPinSide = 22.0;        // glyph box

// MARK: - Host

// The preview card. A direct subview of the table view — never a cell — sized
// to the transparent spacer row that reserves its resting place under the
// "Preview" header. Unpinned, the card sits exactly on that row and scrolls
// like any other row. Pinned, the header AND the card are LOCKED at their
// resting screen position — they never move, whichever way the list scrolls
// or rubber-bands — and the rows slide underneath (an opaque backdrop hides
// them), so every control further down is adjusted with the preview still in
// view. Positioning lives in ApolloPinnedPreviewTableView's layoutSubviews,
// which UIScrollView runs on every content-offset change.
//
// The pinned "Preview" title is a copy of UIKit's own section header label —
// text, font, colour and position are sampled from the real header view while
// it is on screen (it always is at rest), so it matches whatever header style
// this iOS / Liquid Glass combination draws, and only becomes visible once the
// list has left its resting offset (the native header is under the backdrop
// by then; at rest the two are pixel-identical, so the hand-off is invisible).
//
// Height-constrained layouts (landscape phones, tiny screens) don't lock:
// pinning a tall card there would leave no usable list, so the card just
// scrolls with the content as it always did.
@interface ApolloPinnedPreviewHost ()
@property (nonatomic, strong, readwrite) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;      // pinned copy of the section header
@property (nonatomic, readwrite) BOOL stuck;
@property (nonatomic, strong) UIButton *pinButton;
@property (nonatomic, strong) UIImageView *pinIcon;
@property (nonatomic, strong) UILabel *pinCaption;
@property (nonatomic, strong) UISelectionFeedbackGenerator *pinFeedback;
@property (nonatomic) NSUInteger pinCaptionToken;
// Sampled from the native header: the label's origin relative to the card's
// resting origin (y is negative — the title sits above the card) and its size.
@property (nonatomic) BOOL hasTitleSample;
@property (nonatomic) CGPoint titleOffset;
@property (nonatomic) CGSize titleSize;
@property (nonatomic, readwrite) CGFloat measuredCardWidth;
- (void)sampleTitleFromHeaderView:(UIView *)headerView
                          inTable:(UITableView *)table
                       headerRect:(CGRect)headerRect
                       cardOrigin:(CGPoint)cardOrigin;
@end

@implementation ApolloPinnedPreviewHost

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _card = [[UIView alloc] init];
        _card.clipsToBounds = YES;
        [self addSubview:_card];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.hidden = YES;
        [self addSubview:_titleLabel];

        // UIControl target/action does not retain its target, so the host can
        // be the target without a host → card → button → host cycle.
        _pinButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _pinButton.backgroundColor = [UIColor clearColor];
        [_pinButton addTarget:self action:@selector(apollo_pinTapped) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:_pinButton];
        _pinIcon = [[UIImageView alloc] init];
        _pinIcon.contentMode = UIViewContentModeCenter;
        _pinIcon.userInteractionEnabled = NO;
        [_card addSubview:_pinIcon];
        _pinCaption = [[UILabel alloc] init];
        _pinCaption.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        _pinCaption.textColor = [UIColor secondaryLabelColor];
        _pinCaption.textAlignment = NSTextAlignmentRight;
        _pinCaption.alpha = 0.0;
        _pinCaption.userInteractionEnabled = NO;
        [_card addSubview:_pinCaption];
        _pinFeedback = [[UISelectionFeedbackGenerator alloc] init];
        _pinned = YES;
        [self apollo_updatePinIcon];
    }
    return self;
}

// The screen's mock fills the card, underneath the pin controls (which stay
// on top so the whole card remains the pin's tap target).
- (void)setContentView:(UIView *)contentView {
    if (_contentView == contentView) return;
    [_contentView removeFromSuperview];
    _contentView = contentView;
    if (contentView) {
        contentView.userInteractionEnabled = NO;
        [self.card insertSubview:contentView atIndex:0];
        [self setNeedsLayout];
    }
}

- (void)setPinned:(BOOL)pinned {
    _pinned = pinned;
    [self apollo_updatePinIcon];
}

- (void)setAccentColor:(UIColor *)accentColor {
    _accentColor = accentColor;
    [self apollo_updatePinIcon];
}

- (void)apollo_updatePinIcon {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0 weight:UIImageSymbolWeightSemibold];
    self.pinIcon.image = [UIImage systemImageNamed:self.pinned ? @"pin.fill" : @"pin" withConfiguration:config];
    self.pinIcon.tintColor = self.pinned
        ? (self.accentColor ?: [UIColor systemBlueColor])
        : [UIColor tertiaryLabelColor];
    self.pinButton.accessibilityLabel = self.pinned ? @"Unpin preview" : @"Pin preview";
}

- (void)apollo_pinTapped {
    self.pinned = !self.pinned;
    [self.pinFeedback selectionChanged];

    // Bounce the glyph so the tap reads as a state change.
    self.pinIcon.transform = CGAffineTransformMakeScale(1.3, 1.3);
    [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ self.pinIcon.transform = CGAffineTransformIdentity; }
                     completion:nil];

    // Brief caption next to the glyph, replaced (not stacked) by a quick re-tap.
    NSUInteger token = ++self.pinCaptionToken;
    self.pinCaption.text = self.pinned ? @"Pinned" : @"Unpinned";
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [UIView animateWithDuration:0.15 animations:^{ self.pinCaption.alpha = 1.0; }];
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pinCaptionToken != token) return;
        [UIView animateWithDuration:0.3 animations:^{ strongSelf.pinCaption.alpha = 0.0; }];
    });

    if (self.pinDidChange) self.pinDidChange(self.pinned);
}

// The header's text label, wherever this iOS version nests it.
static UILabel *ApolloPinnedPreviewFindHeaderLabel(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0) return (UILabel *)view;
    for (UIView *sub in view.subviews) {
        UILabel *label = ApolloPinnedPreviewFindHeaderLabel(sub);
        if (label) return label;
    }
    return nil;
}

- (void)sampleTitleFromHeaderView:(UIView *)headerView
                          inTable:(UITableView *)table
                       headerRect:(CGRect)headerRect
                       cardOrigin:(CGPoint)cardOrigin {
    UILabel *label = ApolloPinnedPreviewFindHeaderLabel(headerView);
    if (!label || !label.superview || CGRectIsEmpty(label.frame) || !headerView.superview) return;
    CGRect frame = [label.superview convertRect:label.frame toView:table];
    // Only trust a label that lies inside the table's own rect for that header.
    // After a reloadData (a light/dark flip, or a hand-rolled screen's
    // viewWillAppear) the header view UIKit hands out reports its label ~37pt
    // ABOVE the header on iOS 26 while the title is visibly drawn in place;
    // sampling that pushed the block off its row at rest and floated the
    // title copy up into the gap. Skip such passes — the
    // previous good sample stays.
    if (!CGRectIsEmpty(headerRect) &&
        (CGRectGetMinY(frame) < CGRectGetMinY(headerRect) - 1.0 ||
         CGRectGetMaxY(frame) > CGRectGetMaxY(headerRect) + 1.0)) {
        return;
    }
    CGPoint offset = CGPointMake(CGRectGetMinX(frame) - cardOrigin.x, CGRectGetMinY(frame) - cardOrigin.y);
    if (offset.y >= 0) return;   // not above the card: not our header's label
    BOOL sameText = [self.titleLabel.text isEqualToString:label.text];
    if (self.hasTitleSample && sameText &&
        fabs(offset.x - self.titleOffset.x) < 0.5 && fabs(offset.y - self.titleOffset.y) < 0.5 &&
        fabs(frame.size.width - self.titleSize.width) < 0.5 && fabs(frame.size.height - self.titleSize.height) < 0.5) {
        return;   // unchanged
    }
    self.titleLabel.font = label.font;
    self.titleLabel.textColor = label.textColor;
    self.titleLabel.textAlignment = label.textAlignment;
    self.titleLabel.numberOfLines = label.numberOfLines;
    self.titleLabel.text = label.text;
    if (label.attributedText) self.titleLabel.attributedText = [label.attributedText copy];
    self.titleOffset = offset;
    self.titleSize = frame.size;
    self.hasTitleSample = YES;
}

- (void)setStuck:(BOOL)stuck {
    _stuck = stuck;
    [self apollo_updateBackdrop];
}

- (void)setBackdropColor:(UIColor *)backdropColor {
    _backdropColor = backdropColor;
    [self apollo_updateBackdrop];
}

- (void)apollo_updateBackdrop {
    self.backgroundColor = self.stuck
        ? (self.backdropColor ?: [UIColor systemGroupedBackgroundColor])
        : [UIColor clearColor];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect cardBounds = self.card.bounds;
    self.contentView.frame = cardBounds;
    self.pinButton.frame = cardBounds;
    self.pinIcon.frame = CGRectMake(CGRectGetWidth(cardBounds) - kApolloPinnedPreviewPinInset - kApolloPinnedPreviewPinSide,
                                    kApolloPinnedPreviewPinTop, kApolloPinnedPreviewPinSide, kApolloPinnedPreviewPinSide);
    [self.pinCaption sizeToFit];
    CGSize captionSize = self.pinCaption.bounds.size;
    self.pinCaption.frame = CGRectMake(CGRectGetMinX(self.pinIcon.frame) - 6.0 - captionSize.width,
                                       CGRectGetMidY(self.pinIcon.frame) - captionSize.height * 0.5,
                                       captionSize.width, captionSize.height);
}

@end

// MARK: - Spacer row

// Transparent spacer cell: reserves the preview's resting slot in the flow (so
// UIKit draws the native "Preview" section header above it) while the pinned
// card does all the drawing. Kept clear by the theme override in the screen.
@implementation ApolloPinnedPreviewSpacerCell
@end

void ApolloPinnedPreviewClearSpacerCell(UITableViewCell *cell) {
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    if (!cell.backgroundView) cell.backgroundView = [[UIView alloc] init];
    cell.backgroundView.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
}

// MARK: - Section geometry

// Inset-grouped section geometry the card copies so it matches the real cells.
// Both are private UITableView getters (iOS 13+), called defensively with
// public fallbacks: the table's layoutMargins for the inset, and the familiar
// 10pt (26pt under Liquid Glass) for the corner radius.
UIEdgeInsets ApolloPinnedPreviewSectionContentInset(UITableView *table) {
    SEL sel = NSSelectorFromString(@"_sectionContentInset");
    if ([table respondsToSelector:sel]) {
        NSMethodSignature *sig = [table methodSignatureForSelector:sel];
        if (sig && strcmp(sig.methodReturnType, @encode(UIEdgeInsets)) == 0) {
            UIEdgeInsets insets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(table, sel);
            if (insets.left >= 0 && insets.right >= 0) return insets;
        }
    }
    return table.layoutMargins;
}

CGFloat ApolloPinnedPreviewSectionCornerRadius(UITableView *table) {
    SEL sel = NSSelectorFromString(@"_sectionCornerRadius");
    if ([table respondsToSelector:sel]) {
        NSMethodSignature *sig = [table methodSignatureForSelector:sel];
        if (sig && strcmp(sig.methodReturnType, @encode(double)) == 0) {
            double radius = ((double (*)(id, SEL))objc_msgSend)(table, sel);
            if (radius > 0) return (CGFloat)radius;
        }
    }
    return IsLiquidGlass() ? 26.0 : 10.0;
}

// MARK: - Table view (the layout pass)

// The host is attached by the screen (associated, not an ivar — the subclass
// must stay ivar-free for object_setClass to be safe).
static char kApolloPinnedPreviewHostKey;

void ApolloPinnedPreviewAttachHost(UITableView *table, ApolloPinnedPreviewHost *host) {
    if (!table || !host) return;
    [table addSubview:host];
    objc_setAssociatedObject(table, &kApolloPinnedPreviewHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [table setNeedsLayout];
}

@implementation ApolloPinnedPreviewTableView

- (void)layoutSubviews {
    [super layoutSubviews];
    [self apollo_layoutPinnedPreview];
}

- (void)apollo_layoutPinnedPreview {
    ApolloPinnedPreviewHost *host = objc_getAssociatedObject(self, &kApolloPinnedPreviewHostKey);
    if (!host || host.superview != self) return;
    NSIndexPath *previewPath = host.spacerIndexPath ? host.spacerIndexPath() : nil;
    if (!previewPath ||
        self.numberOfSections <= previewPath.section ||
        [self numberOfRowsInSection:previewPath.section] <= previewPath.row) {
        host.hidden = YES;
        return;
    }
    CGRect row = [self rectForRowAtIndexPath:previewPath];   // full table width; cells are inset
    if (CGRectIsEmpty(row)) { host.hidden = YES; return; }
    host.hidden = NO;

    // Horizontal card geometry = whatever the inset-grouped cells actually use.
    // Any visible cell will do (they all share it), converted into the table's
    // coordinate space: on iOS 26 cells are parented to a per-section container,
    // so their raw frame is relative to that (x = 0), not to the table. Before
    // the first cell exists, fall back to the row rect — already inset on iOS 26,
    // full-width on earlier releases, where the table's section inset is applied.
    UITableViewCell *sample = [self cellForRowAtIndexPath:previewPath] ?: self.visibleCells.firstObject;
    CGFloat cardX, cardW;
    if (sample && sample.superview) {
        CGRect cellRect = [sample.superview convertRect:sample.frame toView:self];
        cardX = CGRectGetMinX(cellRect);
        cardW = CGRectGetWidth(cellRect);
    } else if (CGRectGetWidth(row) < CGRectGetWidth(self.bounds) - 1.0) {
        cardX = CGRectGetMinX(row);
        cardW = CGRectGetWidth(row);
    } else {
        UIEdgeInsets inset = ApolloPinnedPreviewSectionContentInset(self);
        cardX = CGRectGetMinX(row) + inset.left;
        cardW = CGRectGetWidth(row) - inset.left - inset.right;
    }
    if (sample && fabs(cardW - host.measuredCardWidth) > 0.5) {
        host.measuredCardWidth = cardW;
        if (host.cardWidthDidChange) {
            // Row-height changes can't happen inside the table's own layout pass;
            // let the screen re-measure the spacer row on the next turn.
            void (^cb)(CGFloat) = host.cardWidthDidChange;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(cardW); });
        }
    }

    // The section header ("Preview") is pinned with the card. Sample its label
    // while UIKit has it on screen; the copy is only shown once stuck.
    UIView *headerView = [self headerViewForSection:previewPath.section];
    if (headerView) {
        [host sampleTitleFromHeaderView:headerView
                                inTable:self
                             headerRect:[self rectForHeaderInSection:previewPath.section]
                             cardOrigin:CGPointMake(cardX, CGRectGetMinY(row))];
    }
    // How far the list has moved from its resting offset (negative while it
    // rubber-bands above it). At rest this is 0 and the block is on its row.
    CGFloat scrolled = self.contentOffset.y + self.adjustedContentInset.top;
    CGFloat viewport = CGRectGetHeight(self.bounds) - self.adjustedContentInset.top - self.adjustedContentInset.bottom;
    // Lock only when there's real list room left under the block at rest.
    CGFloat listRoom = viewport - (CGRectGetMaxY(row) + kApolloPinnedPreviewStuckBottomPad);
    BOOL compactHeight = self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact;
    BOOL canLock = host.pinned && !compactHeight && listRoom >= kApolloPinnedPreviewMinListViewport;

    // Pinned: the block stays exactly where it rests on screen. Its content
    // y follows the offset one-for-one, so scrolling down slides the rows
    // under it and a pull-down bounce leaves it put while the rows spring
    // away and back beneath it. Unpinned (or no room): it rides its row.
    CGFloat cardY = CGRectGetMinY(row);
    if (canLock) cardY += scrolled;
    BOOL stuck = canLock && fabs(scrolled) > 0.5;

    // Locked: the backdrop runs from the very top of the visible bounds, so
    // the native header and the section's own rounded background never show
    // around the block — under a transparent nav bar (Liquid Glass), the
    // status bar once a hide-on-scroll bar has gone, or while a bounce drags
    // them down past the locked card. The scroll-edge effect fades the
    // backdrop's top into the table's background, which is the same colour,
    // so nothing reads as a seam.
    CGFloat hostTop = stuck ? self.contentOffset.y : CGRectGetMinY(row);
    CGFloat hostBottom = cardY + CGRectGetHeight(row) + (stuck ? kApolloPinnedPreviewStuckBottomPad : 0.0);
    host.frame = CGRectMake(0, hostTop, CGRectGetWidth(self.bounds), hostBottom - hostTop);
    host.card.frame = CGRectMake(cardX, cardY - hostTop, cardW, CGRectGetHeight(row));
    // Alpha rather than hidden so a pin/unpin toggle (run inside an animation
    // block by the screen) fades the title along with the sliding card.
    host.titleLabel.hidden = !host.hasTitleSample;
    host.titleLabel.alpha = (stuck && host.hasTitleSample) ? 1.0 : 0.0;
    if (host.hasTitleSample) {
        host.titleLabel.frame = CGRectMake(cardX + host.titleOffset.x, cardY - hostTop + host.titleOffset.y,
                                           host.titleSize.width, host.titleSize.height);
    }
    if (host.stuck != stuck) host.stuck = stuck;

    // Keep the host above every cell and section header/footer (UITableView
    // appends those as they scroll in, which would otherwise put them over the
    // stuck card and let taps reach rows hidden underneath) — but no higher, so
    // UIKit's own overlays (scroll indicator, iOS 26 scroll-edge effect) stay on
    // top. Cells/headers may be nested in per-section containers (iOS 26), so
    // what matters is each one's ancestor that is a DIRECT subview of the table.
    NSArray<UIView *> *subviews = self.subviews;
    NSUInteger hostIndex = [subviews indexOfObjectIdenticalTo:host];
    NSMutableArray<UIView *> *content = [NSMutableArray arrayWithArray:self.visibleCells];
    NSInteger sections = self.numberOfSections;
    for (NSInteger section = 0; section < sections; section++) {
        UIView *header = [self headerViewForSection:section];
        UIView *footer = [self footerViewForSection:section];
        if (header) [content addObject:header];
        if (footer) [content addObject:footer];
    }
    UIView *topContent = nil;
    NSUInteger topContentIndex = 0;
    for (UIView *view in content) {
        UIView *direct = view;
        while (direct.superview && direct.superview != self) direct = direct.superview;
        if (direct.superview != self || direct == host) continue;
        NSUInteger index = [subviews indexOfObjectIdenticalTo:direct];
        if (index != NSNotFound && (!topContent || index > topContentIndex)) {
            topContent = direct;
            topContentIndex = index;
        }
    }
    if (topContent && topContentIndex > hostIndex) {
        [self insertSubview:host aboveSubview:topContent];
    }
}

@end
