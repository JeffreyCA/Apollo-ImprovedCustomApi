#import "InlineMediaSettingsViewController.h"
#import "ApolloCommon.h"
#import "ApolloDirectChatWeb.h"
#import "ApolloMediaAutoplay.h"
#import "ApolloState.h"
#import "UserDefaultConstants.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

// MARK: - Sections

typedef NS_ENUM(NSInteger, ApolloIMSection) {
    ApolloIMSectionPreview = 0,   // one transparent spacer row; the pinned card sits on it
    ApolloIMSectionMaster,
    ApolloIMSectionOptions,
    ApolloIMSectionCount,
};

typedef NS_ENUM(NSInteger, ApolloIMMasterRow) {
    ApolloIMMasterRowPreviews = 0,   // inline media in posts + comments
    ApolloIMMasterRowChat,           // inline media in Apollo's native message threads
    ApolloIMMasterRowCount,
};

typedef NS_ENUM(NSInteger, ApolloIMOptionsRow) {
    ApolloIMOptionsRowAlignment = 0,
    ApolloIMOptionsRowAutoplay,
    ApolloIMOptionsRowMediaSize,
    ApolloIMOptionsRowCount,
};

// MARK: - Live preview (fake comment + message thread)
//
// A standalone UIView owned by the controller. Unlike ApolloLPPreviewCardsView
// (Rich Link Preview settings) it is NOT hosted in a table cell: it lives in the
// pinned preview card (ApolloIMPinnedPreviewHost, a direct subview of the table
// view), so it survives every reloadData untouched and keeps updating live while
// the list scrolls beneath it. One apply/refresh entry point the controls call
// continuously while dragging. Frame-based layout — this is a plain settings
// view, not a Texture hook, so laying out subviews here is fine.
//
// Two mocks, one per master switch on this screen:
//   • a comment (avatar, name, text, then the GIF block that follows the
//     size / alignment / autoplay controls — or a plain link when Inline Media
//     Previews is off);
//   • a received message bubble with a small inline image (or a plain link when
//     Inline Media in Messages is off). Size/alignment don't apply to message
//     threads (ApolloWrapImageNodeForLayout is comments/posts only), so the
//     bubble's image is deliberately fixed-size.

@interface ApolloInlineMediaPreviewView : UIView
@property (nonatomic) BOOL commentMediaEnabled;   // Inline Media Previews (master)
@property (nonatomic) BOOL messageMediaEnabled;   // Inline Media in Messages
@property (nonatomic) CGFloat mediaFraction;      // 0.5 / 0.75 / 1.0
@property (nonatomic) NSInteger alignment;        // ApolloInlineImageAlignment
@property (nonatomic) BOOL showsPlayOverlay;      // paused modes that tap-to-play
@property (nonatomic, strong) UIColor *accentColor;   // plain-link text colour

@property (nonatomic, strong) UIView *avatarOne;
@property (nonatomic, strong) UILabel *nameOne;
@property (nonatomic, strong) UIView *textBarOne;
@property (nonatomic, strong) UIView *mediaBlock;
@property (nonatomic, strong) UILabel *gifBadge;
@property (nonatomic, strong) UIImageView *playIcon;
@property (nonatomic, strong) UILabel *commentLink;
@property (nonatomic, strong) UILabel *nameTwo;
@property (nonatomic, strong) UIView *bubble;
@property (nonatomic, strong) UIView *bubbleText;
@property (nonatomic, strong) UIView *bubbleImage;
@property (nonatomic, strong) UILabel *bubbleLink;
@end

// Card edge → mock content. The content column is capped so an iPad-width card
// shows a phone-width comment centered in it instead of a banner-sized block.
// The card is pinned while the list scrolls, so every point of height here is a
// point the list can't use — the layout is deliberately compact: the media block
// keeps a CONSTANT height and only its width follows the slider (width and
// alignment are what the settings control; a 16:9 block at 100% cost ~190pt and
// left a hole at 50%), and the message bubble holds a small inline image.
static const CGFloat kApolloIMPreviewInset = 12.0;      // horizontal
static const CGFloat kApolloIMPreviewPad = 8.0;         // vertical
static const CGFloat kApolloIMPreviewMaxContent = 440.0;
static const CGFloat kApolloIMMediaHeight = 110.0;      // comment media block
static const CGFloat kApolloIMLinkHeight = 18.0;
static const CGSize  kApolloIMBubbleImageSize = {88.0, 44.0};

static CGFloat ApolloIMContentWidth(CGFloat cardWidth) {
    return MAX(60.0, MIN(cardWidth - kApolloIMPreviewInset * 2.0, kApolloIMPreviewMaxContent));
}

static CGFloat ApolloIMBubbleWidth(CGFloat rowWidth) {
    return MAX(120.0, rowWidth * 0.72);
}

// Bubble = 8 pad + 8 text bar + 6 gap + (image | link line) + 8 pad.
static CGFloat ApolloIMBubbleHeight(BOOL mediaOn) {
    CGFloat body = mediaOn ? kApolloIMBubbleImageSize.height : kApolloIMLinkHeight;
    return 8.0 + 8.0 + 6.0 + body + 8.0;
}

@implementation ApolloInlineMediaPreviewView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _commentMediaEnabled = YES;
        _messageMediaEnabled = YES;
        _mediaFraction = 1.0;
        _alignment = ApolloInlineImageAlignmentCenter;
        [self build];
    }
    return self;
}

static UIView *ApolloIMBar(UIView *parent, CGFloat alpha) {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [[UIColor secondaryLabelColor] colorWithAlphaComponent:alpha];
    bar.layer.cornerRadius = 4.0;
    [parent addSubview:bar];
    return bar;
}

static UIView *ApolloIMAvatar(UIView *parent) {
    UIView *avatar = [[UIView alloc] init];
    avatar.backgroundColor = [UIColor systemFillColor];
    avatar.layer.cornerRadius = 11.0;
    [parent addSubview:avatar];
    return avatar;
}

static UILabel *ApolloIMName(UIView *parent, NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor secondaryLabelColor];
    [parent addSubview:label];
    return label;
}

// The "plain link" stand-in shown wherever inline media is switched off — the
// row then renders the URL as accent-coloured text, exactly like Apollo does.
static UILabel *ApolloIMLink(UIView *parent, NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13.0];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [parent addSubview:label];
    return label;
}

- (void)build {
    self.avatarOne = ApolloIMAvatar(self);
    self.nameOne = ApolloIMName(self, @"u/GifEnjoyer · 2h");
    self.textBarOne = ApolloIMBar(self, 0.35);

    self.mediaBlock = [[UIView alloc] init];
    self.mediaBlock.backgroundColor = [UIColor systemFillColor];
    self.mediaBlock.layer.cornerRadius = 10.0;
    self.mediaBlock.clipsToBounds = YES;
    [self addSubview:self.mediaBlock];

    self.gifBadge = [[UILabel alloc] init];
    self.gifBadge.text = @" GIF ";
    self.gifBadge.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    self.gifBadge.textColor = [UIColor whiteColor];
    self.gifBadge.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    self.gifBadge.layer.cornerRadius = 4.0;
    self.gifBadge.clipsToBounds = YES;
    [self.mediaBlock addSubview:self.gifBadge];

    UIImage *play = [UIImage systemImageNamed:@"play.circle.fill"];
    self.playIcon = [[UIImageView alloc] initWithImage:play];
    self.playIcon.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.9];
    self.playIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self.mediaBlock addSubview:self.playIcon];

    self.commentLink = ApolloIMLink(self, @"i.redd.it/happy-cat.gif");

    self.nameTwo = ApolloIMName(self, @"u/LinkLover · 1h");

    self.bubble = [[UIView alloc] init];
    self.bubble.backgroundColor = [UIColor secondarySystemFillColor];
    self.bubble.layer.cornerRadius = 16.0;
    self.bubble.clipsToBounds = YES;
    [self addSubview:self.bubble];

    self.bubbleText = ApolloIMBar(self.bubble, 0.5);

    self.bubbleImage = [[UIView alloc] init];
    self.bubbleImage.backgroundColor = [UIColor systemFillColor];
    self.bubbleImage.layer.cornerRadius = 8.0;
    self.bubbleImage.clipsToBounds = YES;
    [self.bubble addSubview:self.bubbleImage];

    self.bubbleLink = ApolloIMLink(self.bubble, @"i.redd.it/vacation.jpg");
}

// Natural card height, laid out for the TALLEST state (both switches on). The
// row height therefore never changes while the controls are adjusted — the
// media block's height is constant and switched-off media simply leaves a
// little room — so live slider drags never force table reloads.
+ (CGFloat)heightForCardWidth:(CGFloat)cardWidth {
    (void)cardWidth;   // width no longer affects the height; kept for the call sites
    return kApolloIMPreviewPad + 22.0 + 6.0 + 8.0 + 8.0 + kApolloIMMediaHeight + 12.0
         + 14.0 + 4.0 + ApolloIMBubbleHeight(YES) + kApolloIMPreviewPad;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width;
    if (W <= 0) return;
    CGFloat rowWidth = ApolloIMContentWidth(W);
    CGFloat margin = (W - rowWidth) * 0.5;
    CGFloat y = kApolloIMPreviewPad;

    // Comment header + a line of text.
    self.avatarOne.frame = CGRectMake(margin, y, 22, 22);
    self.nameOne.frame = CGRectMake(margin + 30, y + 3, rowWidth - 30 - 40, 16);   // room for the pin glyph
    y += 22 + 6;
    self.textBarOne.frame = CGRectMake(margin, y, rowWidth * 0.86, 8);
    y += 8 + 8;

    // Media block — width follows the media slider, height constant, horizontal
    // position follows the alignment setting (same slack rule as
    // ApolloWrapImageNodeForLayout). With Inline Media Previews off the row
    // shows the link as plain text instead.
    BOOL commentMedia = self.commentMediaEnabled;
    self.mediaBlock.hidden = !commentMedia;
    self.commentLink.hidden = commentMedia;
    if (commentMedia) {
        CGFloat mediaWidth = MAX(60.0, rowWidth * self.mediaFraction);
        CGFloat mediaHeight = kApolloIMMediaHeight;
        CGFloat slack = rowWidth - mediaWidth;
        CGFloat mediaX = margin + (self.alignment == ApolloInlineImageAlignmentLeft ? 0.0 :
                         self.alignment == ApolloInlineImageAlignmentRight ? slack : slack * 0.5);
        self.mediaBlock.frame = CGRectMake(mediaX, y, mediaWidth, mediaHeight);
        self.gifBadge.frame = CGRectMake(8, mediaHeight - 26, 40, 18);
        // Matches the real overlay: a small play badge pinned bottom-right.
        CGFloat playSide = 26.0;
        self.playIcon.frame = CGRectMake(mediaWidth - 6.0 - playSide, mediaHeight - 6.0 - playSide, playSide, playSide);
        self.playIcon.hidden = !self.showsPlayOverlay;
        y += mediaHeight;
    } else {
        self.commentLink.frame = CGRectMake(margin, y, rowWidth, kApolloIMLinkHeight);
        y += kApolloIMLinkHeight;
    }
    y += 12;

    // Message thread: sender name, then a received bubble with a line of text
    // and either a small inline image or the same plain-link stand-in.
    self.nameTwo.frame = CGRectMake(margin, y, rowWidth, 14);
    y += 14 + 4;
    BOOL messageMedia = self.messageMediaEnabled;
    CGFloat bubbleWidth = ApolloIMBubbleWidth(rowWidth);
    CGFloat inner = bubbleWidth - 20.0;
    CGFloat by = 8.0;
    self.bubbleText.frame = CGRectMake(10, by, inner * 0.8, 8);
    by += 8 + 6;
    self.bubbleImage.hidden = !messageMedia;
    self.bubbleLink.hidden = messageMedia;
    if (messageMedia) {
        self.bubbleImage.frame = CGRectMake(10, by, MIN(inner, kApolloIMBubbleImageSize.width), kApolloIMBubbleImageSize.height);
        by += kApolloIMBubbleImageSize.height;
    } else {
        self.bubbleLink.frame = CGRectMake(10, by, inner, kApolloIMLinkHeight);
        by += kApolloIMLinkHeight;
    }
    by += 8;
    self.bubble.frame = CGRectMake(margin, y, bubbleWidth, by);
}

- (void)refresh {
    UIColor *accent = self.accentColor ?: [UIColor systemBlueColor];
    self.commentLink.textColor = accent;
    self.bubbleLink.textColor = accent;
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

@end

// MARK: - Pinned preview host (sticks below the nav bar while the list scrolls)

// The preview card. A direct subview of the table view — never a cell — sized
// to the transparent spacer row that reserves its resting place under the
// "Preview" header. While that row is on screen the card sits exactly on it and
// scrolls like any other row; once the header would slide under the nav bar the
// header AND the card stick just below the bar instead (an opaque backdrop
// hides the rows passing underneath), so every control further down is adjusted
// with the preview still in view. Positioning lives in
// ApolloIMSettingsTableView's layoutSubviews, which UIScrollView runs on every
// content-offset change.
//
// The pinned "Preview" title is a copy of UIKit's own section header label —
// text, font, colour and position are sampled from the real header view while
// it is on screen (it always is at rest), so it matches whatever header style
// this iOS / Liquid Glass combination draws, and only becomes visible once the
// block is stuck (the native header is under the backdrop by then).
//
// Height-constrained layouts (landscape phones, tiny screens) don't stick:
// pinning a ~400pt card there would leave no usable list, so the card just
// scrolls with the content as it always did.
static const CGFloat kApolloIMStuckTopGap = 8.0;       // nav bar bottom → card top
static const CGFloat kApolloIMStuckBottomPad = 8.0;    // backdrop below the card
static const CGFloat kApolloIMMinListViewport = 200.0; // list room needed to bother sticking

@interface ApolloIMPinnedPreviewHost : UIView
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) ApolloInlineMediaPreviewView *preview;
@property (nonatomic, strong) UILabel *titleLabel;      // pinned copy of the section header
@property (nonatomic, strong) UIColor *backdropColor;   // table background, shown while stuck
@property (nonatomic, strong) UIColor *accentColor;     // filled pin glyph
@property (nonatomic) BOOL stuck;
// Pin toggle: tapping anywhere on the card flips it. Pinned (default) = the
// block sticks below the nav bar; unpinned = it scrolls with the list like any
// row. A small pin glyph in the card's corner shows the state at all times
// (filled + accent when pinned, outlined + dim when not), and a short caption
// acknowledges each tap. The controller persists the choice.
@property (nonatomic) BOOL pinned;
// Set by the controller while it scrolls the list to bring the spacer row under
// the stuck card after an unpin, so the block keeps sticking (instead of
// snapping back into the flow, which would be off-screen) until the row is
// exactly underneath it. See -apollo_releasePinnedPreview.
@property (nonatomic) BOOL holdStuck;
@property (nonatomic, strong) UIButton *pinButton;
@property (nonatomic, strong) UIImageView *pinIcon;
@property (nonatomic, strong) UILabel *pinCaption;
@property (nonatomic, strong) UISelectionFeedbackGenerator *pinFeedback;
@property (nonatomic) NSUInteger pinCaptionToken;
@property (nonatomic, copy) void (^pinDidChange)(BOOL pinned);
// Sampled from the native header: the label's origin relative to the card's
// resting origin (y is negative — the title sits above the card) and its size.
@property (nonatomic) BOOL hasTitleSample;
@property (nonatomic) CGPoint titleOffset;
@property (nonatomic) CGSize titleSize;
- (void)sampleTitleFromHeaderView:(UIView *)headerView inTable:(UITableView *)table cardOrigin:(CGPoint)cardOrigin;
// Real inset-grouped cell width measured by the layout pass (0 = not yet seen)
// and the callback the controller uses to re-measure the spacer row when it
// changes (first layout, rotation).
@property (nonatomic) CGFloat measuredCardWidth;
@property (nonatomic, copy) void (^cardWidthDidChange)(CGFloat width);
@end

@implementation ApolloIMPinnedPreviewHost

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _card = [[UIView alloc] init];
        _card.clipsToBounds = YES;
        [self addSubview:_card];
        _preview = [[ApolloInlineMediaPreviewView alloc] initWithFrame:CGRectZero];
        [_card addSubview:_preview];
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
    // A drag that starts on the card scrolls the list (the table cancels the
    // button's touch), so a touch-up that still reaches us mid-drag or while
    // the list is coasting is not a deliberate tap — ignore it.
    for (UIView *v = self.superview; v; v = v.superview) {
        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *scrollView = (UIScrollView *)v;
            if (scrollView.isDragging || scrollView.isDecelerating) return;
            break;
        }
    }
    self.pinned = !self.pinned;
    ApolloLog(@"[IMPreview] pin toggled → %@", self.pinned ? @"pinned" : @"unpinned");
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
static UILabel *ApolloIMFindHeaderLabel(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0) return (UILabel *)view;
    for (UIView *sub in view.subviews) {
        UILabel *label = ApolloIMFindHeaderLabel(sub);
        if (label) return label;
    }
    return nil;
}

- (void)sampleTitleFromHeaderView:(UIView *)headerView inTable:(UITableView *)table cardOrigin:(CGPoint)cardOrigin {
    UILabel *label = ApolloIMFindHeaderLabel(headerView);
    if (!label || !label.superview || CGRectIsEmpty(label.frame)) return;
    CGRect frame = [label.superview convertRect:label.frame toView:table];
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
    self.preview.frame = cardBounds;
    self.pinButton.frame = cardBounds;
    CGFloat side = 22.0;
    self.pinIcon.frame = CGRectMake(CGRectGetWidth(cardBounds) - kApolloIMPreviewInset - side, kApolloIMPreviewPad - 1.0, side, side);
    [self.pinCaption sizeToFit];
    CGSize captionSize = self.pinCaption.bounds.size;
    self.pinCaption.frame = CGRectMake(CGRectGetMinX(self.pinIcon.frame) - 6.0 - captionSize.width,
                                       CGRectGetMidY(self.pinIcon.frame) - captionSize.height * 0.5,
                                       captionSize.width, captionSize.height);
}

@end

// Transparent spacer cell: reserves the preview's resting slot in the flow (so
// UIKit draws the native "Preview" section header above it) while the pinned
// card does all the drawing. Kept clear by the theme override in the controller.
@interface ApolloIMPreviewSpacerCell : UITableViewCell
@end
@implementation ApolloIMPreviewSpacerCell
@end

static void ApolloIMClearSpacerCell(UITableViewCell *cell) {
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    if (!cell.backgroundView) cell.backgroundView = [[UIView alloc] init];
    cell.backgroundView.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
}

// Inset-grouped section geometry the card copies so it matches the real cells.
// Both are private UITableView getters (iOS 13+), called defensively with
// public fallbacks: the table's layoutMargins for the inset, and the familiar
// 10pt (26pt under Liquid Glass) for the corner radius.
static UIEdgeInsets ApolloIMSectionContentInset(UITableView *table) {
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

static CGFloat ApolloIMSectionCornerRadius(UITableView *table) {
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

// MARK: - Detent slider (50 / 75 / 100)

static NSInteger ApolloIMSnapPercent(float value) {
    if (value < 62.5f) return 50;
    if (value < 87.5f) return 75;
    return 100;
}

// The three stops and the midpoint boundaries between them (62.5, 87.5).
static const NSInteger kApolloIMStops[] = {50, 75, 100};
static const int kApolloIMStopCount = 3;

// Detent selection WITH hysteresis. The plain nearest-stop snap above flips
// the instant `raw` crosses a boundary — fine for a tap, fatal for a drag:
// a real fingertip held near a boundary jitters a pixel or two every frame
// (120Hz on ProMotion), so `raw` oscillates across the boundary and the
// caller re-fires the selection haptic each flip, producing a *continuous
// rumble* instead of one tick. (The Simulator's synthetic drags are perfectly
// smooth, so this only reproduces on device — which is why it slipped through.)
//
// Hysteresis adds a dead-band: once parked on a detent, the finger must cross
// the boundary by kApolloIMHysteresis before the detent changes. The band is
// far wider than any jitter, so a held finger stays put and the haptic fires
// exactly once per deliberate crossing. Multi-step fast drags still work — the
// loops walk as many stops as `raw` clears.
static const float kApolloIMHysteresis = 6.0f;  // percent units (range is 50)

static NSInteger ApolloIMSnapPercentHysteretic(float raw, NSInteger current) {
    int idx = 0;
    BOOL found = NO;
    for (int i = 0; i < kApolloIMStopCount; i++) {
        if (kApolloIMStops[i] == current) { idx = i; found = YES; break; }
    }
    if (!found) return ApolloIMSnapPercent(raw);   // current off-grid: hard snap
    // Move up while the finger is clearly past the upper boundary…
    while (idx < kApolloIMStopCount - 1) {
        float boundary = (kApolloIMStops[idx] + kApolloIMStops[idx + 1]) / 2.0f;
        if (raw > boundary + kApolloIMHysteresis) idx++; else break;
    }
    // …and down while clearly below the lower boundary.
    while (idx > 0) {
        float boundary = (kApolloIMStops[idx - 1] + kApolloIMStops[idx]) / 2.0f;
        if (raw < boundary - kApolloIMHysteresis) idx--; else break;
    }
    return kApolloIMStops[idx];
}

// MARK: - Swipe-back suppression while dragging the slider

// Nearest view controller for a view, via the responder chain.
static UIViewController *ApolloIMVCForView(UIView *view) {
    UIResponder *r = view;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// A zero-slop gesture recognizer that latches to Began the instant a touch lands
// on the slider, purely to act as a FAILURE ANCHOR. Every competing swipe-back /
// transition pan is wired (once) to `requireGestureRecognizerToFail:` this
// recognizer, so a drag that STARTS on the slider can never pop the page.
//
// Why this is needed: the 50% detent's thumb sits at the far-left of the track —
// right inside the screen-edge interactive-pop zone. Dragging from there toward
// 75/100 was being stolen by Apollo's full-width swipe-back pan, which either
// popped back a screen or cancelled the slider's UIControl tracking mid-drag so
// the thumb "froze" at a detent. (The scroll-lock added earlier only stops the
// *vertical* scroll steal; the horizontal pop pan is a separate competitor that
// an earlier round wrongly assumed UIKit already excluded for controls.)
//
// This mirrors the proven requireGestureRecognizerToFail wiring in
// ApolloStatsRowTouch's magnifier loupe — UIKit's own priority primitive, so it's
// fully stateless: nothing is disabled/restored, meaning a drag that never
// delivers a clean touch-up (which happens) can't wedge swipe-back the way a
// per-drag enable/disable could. It never cancels the slider's own UIControl
// tracking (cancelsTouchesInView = NO), so scrubbing is unaffected. Because the
// anchor lives on the slider, only touches that hit the slider ever hold up the
// pop pan — swipe-back is untouched everywhere else on the screen.
@interface ApolloIMSliderClaimGesture : UIGestureRecognizer
// The single touch this anchor is bound to for the current sequence. Tracked so a
// second finger landing on the slider can't invalidly re-latch us (Changed->Began)
// or, when it lifts first, end the anchor while the scrubbing finger is still down
// — either of which would momentarily satisfy the pop pan's failure requirement
// and re-open swipe-back mid-drag. UILongPressGestureRecognizer gives the loupe
// reference this bookkeeping for free; hand-rolled here, we do it explicitly.
@property (nonatomic, weak) UITouch *claimedTouch;
@end

@implementation ApolloIMSliderClaimGesture
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        self.cancelsTouchesInView = NO;   // never cancel the slider's UIControl tracking
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible) return;   // already bound — ignore extra fingers
    // A disabled (dimmed) slider must let a normal swipe-back through — only claim
    // the touch when the slider is actually interactive.
    UISlider *slider = [self.view isKindOfClass:[UISlider class]] ? (UISlider *)self.view : nil;
    if (slider && !slider.isEnabled) { self.state = UIGestureRecognizerStateFailed; return; }
    self.claimedTouch = touches.anyObject;
    self.state = UIGestureRecognizerStateBegan;   // latched — can no longer fail this touch
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // Keep anchoring until OUR touch lifts — a different finger ending must not
    // release the pop-pan gate while the scrubbing finger is still down.
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    }
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.claimedTouch && ![touches containsObject:self.claimedTouch]) return;
    self.state = UIGestureRecognizerStateCancelled;
}
- (void)reset {
    [super reset];
    self.claimedTouch = nil;   // ready for the next sequence
}
@end

// UISlider with exactly three stops. Unlike a stock slider, tracking begins
// from a touch anywhere on the bar (not just on the thumb), the thumb snaps
// between the detents while dragging — with a selection tick on each snap —
// and lifting the finger (a plain tap included) lands on the detent nearest the
// release point. Tick marks at both ends and the middle show the three
// positions so it doesn't read as a free-flowing slider.
@interface ApolloIMDetentSlider : UISlider
@property (nonatomic, strong) NSArray<UIView *> *tickViews;
@property (nonatomic, strong) UISelectionFeedbackGenerator *feedback;
// The detent the selection haptic last fired for. Change-detection keys off
// THIS, not self.value: setValue:animated:YES leaves self.value reporting the
// mid-animation thumb position, so reading it back each continueTracking frame
// would re-trip the guard every frame and turn one tap into a continuous buzz.
@property (nonatomic) NSInteger lastSnappedPercent;
// Confirmation guard: a new detent must be seen on N consecutive tracking
// frames before it commits + fires. A single-frame (or alternating) flip — the
// signature of jitter — never accumulates the streak, so it can NEVER produce a
// haptic, whatever the underlying input pattern. Belt-and-suspenders on top of
// the hysteresis dead-band. A deliberate crossing holds the new detent for many
// frames, so it confirms in ~2 frames (imperceptible).
@property (nonatomic) NSInteger pendingPercent;
@property (nonatomic) NSInteger pendingStreak;
// Post-fire lockout: after a haptic, ignore further changes for a short window.
// Deliberate detent crossings are >150ms apart, so both fire; any residual rapid
// oscillation the streak guard misses is hard-capped to <1 tick per lockout.
@property (nonatomic) CFTimeInterval lastFireTime;
// Swipe-back suppression: the anchor gesture (added in init, lives on the slider)
// plus the weak set of pop/transition pans already wired to require it to fail, so
// re-wiring is idempotent.
@property (nonatomic, strong) ApolloIMSliderClaimGesture *claimGesture;
@property (nonatomic, strong) NSHashTable<UIGestureRecognizer *> *wiredBackGestures;
// Our own tracking flag — see -isTracking.
@property (nonatomic) BOOL apolloTracking;
@end

@implementation ApolloIMDetentSlider

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSMutableArray<UIView *> *ticks = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            UIView *tick = [[UIView alloc] init];
            tick.backgroundColor = [UIColor tertiaryLabelColor];
            tick.userInteractionEnabled = NO;
            tick.layer.cornerRadius = 1.0;
            // Behind the track/thumb subviews: the track covers the middle of
            // each tick, leaving the ends peeking above and below the bar.
            [self insertSubview:tick atIndex:0];
            [ticks addObject:tick];
        }
        _tickViews = ticks;
        _feedback = [[UISelectionFeedbackGenerator alloc] init];

        // Failure anchor for swipe-back suppression. nil target/action on purpose:
        // the recognizer only needs to change state (not run a callback), and a
        // self-target would retain-cycle with the view that retains it.
        _wiredBackGestures = [NSHashTable weakObjectsHashTable];
        _claimGesture = [[ApolloIMSliderClaimGesture alloc] initWithTarget:nil action:NULL];
        [self addGestureRecognizer:_claimGesture];
    }
    return self;
}

// Wire every competing swipe-back / transition pan on the ancestor chain (plus the
// nav controller's interactive pop gesture) to require the claim gesture to fail
// before it may begin. Idempotent via the weak set, so it's safe to call as the
// view enters the window AND as a drag starts — the pop pans live on the nav
// container above the settings table, which isn't reachable until we're in the
// hierarchy, and Apollo's full-width pan may be (re)installed after the push
// settles. The enclosing scroll view's own pan is spared (that steal is already
// handled by ApolloIMSettingsTableView's touchesShouldCancelInContentView:).
- (void)apollo_wireSwipeBackFailureRequirements {
    if (!self.claimGesture) return;
    NSUInteger before = self.wiredBackGestures.count;
    UIGestureRecognizer *pop = ApolloIMVCForView(self).navigationController.interactivePopGestureRecognizer;
    if (pop && ![self.wiredBackGestures containsObject:pop]) {
        [pop requireGestureRecognizerToFail:self.claimGesture];
        [self.wiredBackGestures addObject:pop];
    }
    // Walk all the way up through the window (window.superview is nil, so this
    // stops there) — a pop/transition pan can sit on the window itself, and the
    // device-proven reference wires those too. Only touches that hit the slider
    // ever hold any of these up, so wiring more is strictly safe.
    for (UIView *v = self.superview; v; v = v.superview) {
        UIGestureRecognizer *scrollPan =
            [v isKindOfClass:[UIScrollView class]] ? ((UIScrollView *)v).panGestureRecognizer : nil;
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == self.claimGesture || g == scrollPan || g == pop) continue;
            if ([self.wiredBackGestures containsObject:g]) continue;
            NSString *cls = NSStringFromClass([g class]);
            BOOL panLike = [g isKindOfClass:[UIPanGestureRecognizer class]]
                || [cls containsString:@"ParallaxTransition"];
            if (!panLike) continue;
            [g requireGestureRecognizerToFail:self.claimGesture];
            [self.wiredBackGestures addObject:g];
        }
    }
    if (self.wiredBackGestures.count != before) {
        ApolloLog(@"[IMSlider] wired swipe-back suppression: %lu pan(s) now require the slider claim to fail (pop=%d)",
                  (unsigned long)self.wiredBackGestures.count, pop != nil);
    }
}

// iOS 26 attaches a private _UIFluidSliderInteraction to every UISlider. Its
// feedback conductor plays a CONTINUOUS "fluid" scrub haptic as the value
// modulates — a separate system from our one-tap-per-detent selectionChanged,
// and the real source of the "constant vibration while dragging" reports (our
// haptic tracer never saw it because it isn't a public UIFeedbackGenerator).
// We do our own detent tracking (UIControl beginTracking/continueTracking) and
// our own single tap, so we refuse the fluid interaction outright — this leaves
// classic UIControl tracking (still fired on device, per the logs) untouched.
- (void)addInteraction:(id<UIInteraction>)interaction {
    if ([NSStringFromClass([interaction class]) containsString:@"FluidSliderInteraction"]) {
        return;
    }
    [super addInteraction:interaction];
}

// Belt-and-suspenders: if a fluid interaction was already attached (added before
// we could refuse it, or via a path that bypasses addInteraction:), strip it and
// nil the private edge/modulation feedback generators when we enter a window.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    for (id<UIInteraction> ix in [self.interactions copy]) {
        if ([NSStringFromClass([ix class]) containsString:@"FluidSliderInteraction"]) {
            [self removeInteraction:ix];
        }
    }
    for (NSString *sel in @[@"_setModulationFeedbackGenerator:", @"_setEdgeFeedbackGenerator:"]) {
        SEL s = NSSelectorFromString(sel);
        if ([self respondsToSelector:s]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:s withObject:nil];
            #pragma clang diagnostic pop
        }
    }
    // Now that we're in the hierarchy, the nav container's swipe-back pans are
    // reachable — make them wait on our claim gesture.
    [self apollo_wireSwipeBackFailureRequirements];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect track = [self trackRectForBounds:self.bounds];
    const CGFloat fractions[3] = {0.0, 0.5, 1.0};
    for (NSUInteger i = 0; i < self.tickViews.count && i < 3; i++) {
        CGFloat x = CGRectGetMinX(track) + fractions[i] * CGRectGetWidth(track);
        self.tickViews[i].frame = CGRectMake(x - 1.0, CGRectGetMidY(track) - 7.0, 2.0, 14.0);
    }
}

// The un-snapped value at an x position along the track.
- (float)apollo_rawValueForX:(CGFloat)x {
    CGRect track = [self trackRectForBounds:self.bounds];
    CGFloat width = MAX(1.0, CGRectGetWidth(track));
    CGFloat fraction = (x - CGRectGetMinX(track)) / width;
    fraction = MIN(1.0, MAX(0.0, fraction));
    return self.minimumValue + fraction * (self.maximumValue - self.minimumValue);
}

- (float)apollo_rawValueForTouch:(UITouch *)touch {
    return [self apollo_rawValueForX:[touch locationInView:self].x];
}

// Touch-up: land on the detent nearest x — tap or drag alike. Plain nearest-stop
// snap on purpose: the hysteresis band and the 2-frame confirmation exist to
// debounce a HELD finger, and neither applies once it has lifted. For a tap they
// would leave the thumb where it was (a tap is a single frame, so the streak can
// never confirm — issue #1006); for a drag they could park the thumb a detent
// short of where the finger was released.
- (void)apollo_selectDetentAtX:(CGFloat)x source:(NSString *)source {
    float raw = [self apollo_rawValueForX:x];
    NSInteger target = ApolloIMSnapPercent(raw);
    if (target != self.lastSnappedPercent) {
        ApolloLog(@"[IMSlider] %@ → %ld%% (was %ld%%)", source, (long)target, (long)self.lastSnappedPercent);
        [self apollo_commitPercent:target];
    } else if ((NSInteger)lroundf(self.value) != target) {
        [self setValue:(float)target animated:YES];   // re-seat a thumb left off-grid
    }
}

// Commit a detent: one animated thumb move, one selection tick, one action.
- (void)apollo_commitPercent:(NSInteger)percent {
    self.lastSnappedPercent = percent;
    self.pendingStreak = 0;
    self.lastFireTime = CACurrentMediaTime();
    [self setValue:(float)percent animated:YES];
    [self.feedback selectionChanged];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)apollo_applyTouch:(UITouch *)touch {
    float raw = [self apollo_rawValueForTouch:touch];
    // Hysteretic snap keyed off the current detent — a held finger's jitter
    // can't flip it across a boundary, so the haptic fires once per crossing.
    NSInteger snapped = ApolloIMSnapPercentHysteretic(raw, self.lastSnappedPercent);

    // Confirmation streak: count consecutive frames the candidate detent differs
    // from the committed one. Only a sustained change (deliberate crossing) fires.
    if (snapped == self.lastSnappedPercent) {
        self.pendingStreak = 0;
    } else if (snapped == self.pendingPercent) {
        self.pendingStreak++;
    } else {
        self.pendingPercent = snapped;
        self.pendingStreak = 1;
    }
    CFTimeInterval now = CACurrentMediaTime();
    BOOL lockedOut = (now - self.lastFireTime) < 0.15;   // 150ms post-fire window
    BOOL confirmed = (snapped != self.lastSnappedPercent) && (self.pendingStreak >= 2) && !lockedOut;

    if (confirmed) {
        [self apollo_commitPercent:snapped];   // one haptic per confirmed crossing
    }
}

// MARK: iOS 26 — make UIControl finish the touch sequence
//
// On iOS 26 UISlider installs a "fluid" visual element (_UISliderFluidVisualElement)
// that changes how the CLASSIC UIControl tracking sequence completes, in two ways
// (both read from the decompiled UIKitCore):
//
//  1. -[UISlider isTracking] defers to the visual element's own "interactively
//     changing" flag, which only turns on for a thumb drag the element drives
//     itself. UIControl's touchesMoved:/touchesEnded: consult -isTracking before
//     calling continueTracking/endTracking, so a touch we started from the bare
//     track (beginTracking returned YES, but the element never saw a thumb drag)
//     reported NOT tracking and was dropped after beginTracking.
//  2. -[UISlider _deferFinalActions] returns YES whenever the fluid element is
//     installed. With that, UIControl's touchesEnded: does NOT call
//     endTrackingWithTouch: — it flags the touch-up as deferred and expects the
//     fluid interaction to finish the sequence later. We refuse that interaction
//     (see addInteraction:), so the deferral never completed: endTracking /
//     cancelTracking never fired for any touch, and the control stayed "tracking"
//     forever. (This, not synthetic input, is why end-tracking-based designs kept
//     failing here, and why a tap never landed — issue #1006.)
//
// Both overrides simply restore the classic sequence: report our own tracking
// state, and never defer the final actions.
- (BOOL)isTracking {
    return self.apolloTracking;
}

- (BOOL)_deferFinalActions {
    return NO;
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    // Catch any pop pan installed after we entered the window (e.g. re-added when
    // the push transition settled); wiring is idempotent.
    [self apollo_wireSwipeBackFailureRequirements];
    self.apolloTracking = YES;
    // Sync to the settled value before the drag — but only when it IS settled: a
    // quick second touch while the previous commit's thumb animation is still in
    // flight would otherwise read a mid-animation, off-grid value and lose the
    // committed detent the hysteresis keys off.
    NSInteger settled = (NSInteger)lroundf(self.value);
    if (settled == 50 || settled == 75 || settled == 100) self.lastSnappedPercent = settled;
    self.pendingPercent = self.lastSnappedPercent;
    self.pendingStreak = 0;
    [self.feedback prepare];
    [self apollo_applyTouch:touch];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self apollo_applyTouch:touch];
    return YES;
}

// Touch-up (tap or drag): land on the detent nearest the release point. This is
// the path that makes a plain tap select a stop (issue #1006) — beginTracking
// alone never commits, by design of the anti-jitter guards above.
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [super endTrackingWithTouch:touch withEvent:event];
    self.apolloTracking = NO;
    if (!touch) return;
    [self apollo_selectDetentAtX:[touch locationInView:self].x source:@"released"];
}

// A cancelled touch commits nothing — the thumb stays on the last detent the
// drag logic confirmed.
- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [super cancelTrackingWithEvent:event];
    self.apolloTracking = NO;
}

@end

// MARK: - Table view (keeps the slider drag from scrolling the screen)

// The settings table is isa-swizzled to this class in viewDidLoad. It overrides
// two UIScrollView touch-arbitration hooks, scoped to the size slider only, so
// the screen never scrolls out from under a slider drag — WITHOUT any per-drag
// state to enable/restore (the earlier scrollEnabled / canCancelContentTouches
// / pan-disabling approaches either collapsed the layout or left the table
// stuck when UIControl end-tracking didn't fire).
@interface ApolloIMSettingsTableView : UITableView
@end
@implementation ApolloIMSettingsTableView
static BOOL ApolloIMViewIsInSlider(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isMemberOfClass:[ApolloIMDetentSlider class]]) return YES;
    }
    return NO;
}
// A touch on the slider must reach it immediately (not after the scroll-detection
// delay), or a mostly-vertical drag is claimed by the table before the slider
// ever begins tracking.
- (BOOL)touchesShouldBegin:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event inContentView:(UIView *)view {
    if (ApolloIMViewIsInSlider(view)) return YES;
    return [super touchesShouldBegin:touches withEvent:event inContentView:view];
}
// Once the slider is tracking, never cancel it to scroll — this is what stops
// the screen moving up/down during a drag. Other rows keep the default (YES),
// so normal scrolling by dragging from a row is unaffected.
//
// The pinned preview card is covered by its pin button (a UIControl), and
// UIScrollView's default refuses to cancel a touch that landed on a control —
// which would make a drag that starts on the card (a third of the screen) not
// scroll at all. Say YES for anything inside the host: a real drag scrolls the
// list, a tap still reaches the button.
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    if (ApolloIMViewIsInSlider(view)) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[ApolloIMPinnedPreviewHost class]]) return YES;
    }
    return [super touchesShouldCancelInContentView:view];
}

// MARK: Pinned preview layout

// The host is attached by the controller (associated, not an ivar — the subclass
// must stay ivar-free for object_setClass to be safe).
static char kApolloIMPinnedHostKey;

- (void)layoutSubviews {
    [super layoutSubviews];
    [self apollo_layoutPinnedPreview];
}

- (void)apollo_layoutPinnedPreview {
    ApolloIMPinnedPreviewHost *host = objc_getAssociatedObject(self, &kApolloIMPinnedHostKey);
    if (!host || host.superview != self) return;
    if (self.numberOfSections <= ApolloIMSectionPreview ||
        [self numberOfRowsInSection:ApolloIMSectionPreview] < 1) {
        host.hidden = YES;
        return;
    }
    NSIndexPath *previewPath = [NSIndexPath indexPathForRow:0 inSection:ApolloIMSectionPreview];
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
        UIEdgeInsets inset = ApolloIMSectionContentInset(self);
        cardX = CGRectGetMinX(row) + inset.left;
        cardW = CGRectGetWidth(row) - inset.left - inset.right;
    }
    if (sample && fabs(cardW - host.measuredCardWidth) > 0.5) {
        host.measuredCardWidth = cardW;
        if (host.cardWidthDidChange) {
            // Row-height changes can't happen inside the table's own layout pass;
            // let the controller re-measure the spacer row on the next turn.
            void (^cb)(CGFloat) = host.cardWidthDidChange;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(cardW); });
        }
    }

    // The section header ("Preview") is pinned with the card. Sample its label
    // while UIKit has it on screen; the copy is only shown once stuck.
    UIView *headerView = [self headerViewForSection:ApolloIMSectionPreview];
    if (headerView) {
        [host sampleTitleFromHeaderView:headerView inTable:self cardOrigin:CGPointMake(cardX, CGRectGetMinY(row))];
    }
    CGFloat titleAbove = host.hasTitleSample ? -host.titleOffset.y : 0.0;   // title top → card top

    // Stick only when there's real list room left under the block.
    CGFloat boundsTop = self.contentOffset.y;                                    // top of the visible bounds, under the bars
    CGFloat visibleTop = boundsTop + self.adjustedContentInset.top;              // nav bar bottom (0 at rest)
    CGFloat visibleBottom = boundsTop + CGRectGetHeight(self.bounds) - self.adjustedContentInset.bottom;
    CGFloat listRoom = (visibleBottom - visibleTop) - titleAbove - CGRectGetHeight(row) - kApolloIMStuckTopGap - kApolloIMStuckBottomPad;
    BOOL compactHeight = self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact;
    BOOL canStick = (host.pinned || host.holdStuck) && !compactHeight && listRoom >= kApolloIMMinListViewport;

    // A pinned block is locked to the screen in BOTH directions: it sticks
    // below the bar once its row would scroll away, and it does not rubber-band
    // with the content on a pull past the top either (visibleTop goes negative
    // during that bounce; offsetting the resting position by the same amount
    // keeps the block's screen position fixed while the rows below bounce).
    CGFloat rowY = CGRectGetMinY(row);
    CGFloat overscrollTop = MIN(0.0, visibleTop);
    CGFloat cardY = canStick ? rowY + overscrollTop : rowY;
    if (canStick) cardY = MAX(cardY, visibleTop + kApolloIMStuckTopGap + titleAbove);
    // "Stuck" = displaced from its flow position in either direction; that is
    // when the backdrop and the title copy take over from the native header.
    BOOL stuck = fabs(cardY - rowY) > 0.5;

    // The backdrop starts at the very top of the bounds, not at the bar's
    // bottom edge: the iOS 26 bar is translucent, so rows that had disappeared
    // under the block would otherwise show through the bar above it.
    CGFloat hostTop = stuck ? boundsTop : rowY;
    CGFloat hostBottom = cardY + CGRectGetHeight(row) + (stuck ? kApolloIMStuckBottomPad : 0.0);
    host.frame = CGRectMake(0, hostTop, CGRectGetWidth(self.bounds), hostBottom - hostTop);
    host.card.frame = CGRectMake(cardX, cardY - hostTop, cardW, CGRectGetHeight(row));
    // Alpha rather than hidden so a pin/unpin toggle (run inside an animation
    // block by the controller) fades the title along with the sliding card.
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

// MARK: - Controller

@interface InlineMediaSettingsViewController ()
@property (nonatomic, strong) ApolloIMPinnedPreviewHost *previewHost;
@property (nonatomic, strong) UILabel *mediaSizeValueLabel;
// Card width the spacer row was last measured for (0 = only the table's own
// section inset was available). Updated from the real cell frame by the pinned
// layout pass, which then asks for a one-row re-measure.
@property (nonatomic) CGFloat previewCardWidth;
@end

@implementation InlineMediaSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Inline Media";
    // Route slider-drag touch arbitration through ApolloIMSettingsTableView so a
    // drag on the size slider scrubs it instead of scrolling the screen. The
    // subclass adds no ivars, so isa-swizzling the existing table view is safe.
    if (![self.tableView isMemberOfClass:[ApolloIMSettingsTableView class]]) {
        object_setClass(self.tableView, [ApolloIMSettingsTableView class]);
    }
    // Deliver slider touches immediately (the subclass's touchesShouldBegin only
    // applies while content touches are delayed; NO makes tracking begin at once
    // for a vertical drag too).
    self.tableView.delaysContentTouches = NO;

    // The pinned preview card: a subview of the table (positioned by the
    // subclass's layout pass), not a cell, so it never gets rebuilt by reloads.
    ApolloIMPinnedPreviewHost *host = [[ApolloIMPinnedPreviewHost alloc] initWithFrame:CGRectZero];
    __weak __typeof(self) weakSelf = self;
    host.cardWidthDidChange = ^(CGFloat width) {
        [weakSelf previewCardWidthDidChange:width];
    };
    host.pinned = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeyInlineMediaPreviewPinned];
    host.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeyInlineMediaPreviewPinned];
        if (!pinned && host.stuck) {
            // Unpinning a stuck block: the thing under the finger must not fly
            // off the top. Keep the card where it is and bring the list down to
            // it instead (see -apollo_releasePinnedPreview).
            [weakSelf apollo_releasePinnedPreview];
            return;
        }
        // Pinning: slide the block into its pinned spot instead of snapping —
        // the table's layout pass computes the new frames inside the animation.
        UITableView *table = weakSelf.tableView;
        [table setNeedsLayout];
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ [table layoutIfNeeded]; }
                         completion:nil];
    };
    self.previewHost = host;
    [self.tableView addSubview:host];
    objc_setAssociatedObject(self.tableView, &kApolloIMPinnedHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self applyThemeToPreviewHost];
    [self syncPreviewState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    [self syncPreviewState];
}

// MARK: Preview plumbing

- (ApolloInlineMediaPreviewView *)previewView {
    return self.previewHost.preview;
}

// Unpin while the block is stuck: scroll the list so the spacer row lands
// exactly under the card's current screen position. The block keeps sticking
// (holdStuck) for the duration of that scroll, so the card never moves — the
// rows slide down beneath it and, once the row is underneath, the layout pass
// finds the card at its flow position and the native header takes over from
// the copy without a visible change.
- (void)apollo_releasePinnedPreview {
    ApolloIMPinnedPreviewHost *host = self.previewHost;
    UITableView *table = self.tableView;
    if (!host || table.numberOfSections <= ApolloIMSectionPreview) return;
    CGRect row = [table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:ApolloIMSectionPreview]];
    CGFloat titleAbove = host.hasTitleSample ? -host.titleOffset.y : 0.0;
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat target = CGRectGetMinY(row) - (inset.top + kApolloIMStuckTopGap + titleAbove);
    CGFloat minY = -inset.top;
    CGFloat maxY = MAX(minY, table.contentSize.height + inset.bottom - CGRectGetHeight(table.bounds));
    target = MIN(MAX(target, minY), maxY);
    host.holdStuck = YES;
    [table setContentOffset:CGPointMake(table.contentOffset.x, target) animated:YES];
    // Belt and braces: the delegate callback below normally ends the hold; if
    // the animation is cut short some other way, don't leave the block held.
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf apollo_endPinnedPreviewRelease];
    });
}

- (void)apollo_endPinnedPreviewRelease {
    if (!self.previewHost.holdStuck) return;
    self.previewHost.holdStuck = NO;
    [self.tableView setNeedsLayout];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    [self apollo_endPinnedPreviewRelease];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self apollo_endPinnedPreviewRelease];   // the user took over mid-release
}

// Push every setting this screen owns into the mock. Called from each control's
// action (continuously while the slider drags) — the card is pinned, so the
// change is visible without scrolling back up.
- (void)syncPreviewState {
    ApolloInlineMediaPreviewView *preview = self.previewView;
    preview.commentMediaEnabled = sEnableInlineImages;
    preview.messageMediaEnabled = sEnableChatMedia;
    preview.mediaFraction = sInlineMediaSizePercent / 100.0;
    preview.alignment = sInlineImageAlignment;
    NSString *mode = ApolloAutoplayGIFModeString();
    preview.showsPlayOverlay = [mode isEqualToString:@"tap-to-play"];
    [preview refresh];
}

// Card chrome follows the same theme walk as the real cells (cell colour,
// section corner radius, table background for the stuck backdrop, accent for
// the plain-link stand-ins).
- (void)applyThemeToPreviewHost {
    ApolloIMPinnedPreviewHost *host = self.previewHost;
    if (!host) return;
    host.card.backgroundColor = [self apollo_themeCellBackgroundColor];
    host.card.layer.cornerRadius = ApolloIMSectionCornerRadius(self.tableView);
    UIColor *tableBackground = self.tableView.backgroundColor;
    UIColor *resolved = [tableBackground resolvedColorWithTraitCollection:self.tableView.traitCollection];
    if (!resolved || CGColorGetAlpha(resolved.CGColor) < 0.99) {
        tableBackground = [UIColor systemGroupedBackgroundColor];
    }
    host.backdropColor = tableBackground;
    host.accentColor = [self apollo_themeAccentColor];
    host.preview.accentColor = host.accentColor;
    [host.preview refresh];
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    [self applyThemeToPreviewHost];
}

// The spacer row must stay invisible whatever the theme pass does to cells.
- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if ([cell isKindOfClass:[ApolloIMPreviewSpacerCell class]]) {
        ApolloIMClearSpacerCell(cell);
        return;
    }
    [super apollo_applyThemeToCell:cell];
}

// Width the spacer row's height is derived from: the measured cell width once
// the layout pass has seen a real cell, else the table's reported section inset.
- (CGFloat)previewCardWidthForTable:(UITableView *)tableView {
    if (self.previewCardWidth > 0) return self.previewCardWidth;
    UIEdgeInsets inset = ApolloIMSectionContentInset(tableView);
    return CGRectGetWidth(tableView.bounds) - inset.left - inset.right;
}

- (void)previewCardWidthDidChange:(CGFloat)width {
    if (width <= 0 || fabs(width - self.previewCardWidth) <= 0.5) return;
    CGFloat oldHeight = [ApolloInlineMediaPreviewView heightForCardWidth:[self previewCardWidthForTable:self.tableView]];
    self.previewCardWidth = width;
    CGFloat newHeight = [ApolloInlineMediaPreviewView heightForCardWidth:width];
    ApolloLog(@"[IMPreview] card width %.1f → spacer row %.1f → %.1f", width, oldHeight, newHeight);
    if (fabs(newHeight - oldHeight) <= 0.5) return;
    if (self.tableView.numberOfSections <= ApolloIMSectionPreview) return;
    // Re-measure just the spacer row; the host follows the new rect on the next
    // layout pass. No animation so the pinned card doesn't visibly resize.
    [UIView performWithoutAnimation:^{
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:ApolloIMSectionPreview]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }];
}

// MARK: Cell helpers (repo-wide patterns — see PictureInPictureViewController)

- (UITableViewCell *)switchCellLabel:(NSString *)label on:(BOOL)on enabled:(BOOL)enabled action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.enabled = enabled;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    if (enabled) [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

- (UITableViewCell *)valueCellLabel:(NSString *)label detail:(NSString *)detail enabled:(BOOL)enabled {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (enabled) [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

// Slider row with a title, a live "NN%" value label, and a 50/75/100-detent
// slider underneath. The slider snaps to the three stops while dragging and
// updates the preview continuously.
- (UITableViewCell *)sliderCellLabel:(NSString *)label
                             percent:(NSInteger)percent
                             enabled:(BOOL)enabled
                              action:(SEL)action
                          valueLabel:(UILabel * __strong *)valueLabelOut {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *title = [[UILabel alloc] init];
    title.text = label;
    title.font = [UIFont systemFontOfSize:17.0];
    title.enabled = enabled;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:title];

    UILabel *value = [[UILabel alloc] init];
    value.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    value.font = [UIFont monospacedDigitSystemFontOfSize:17.0 weight:UIFontWeightRegular];
    value.textColor = [UIColor secondaryLabelColor];
    value.textAlignment = NSTextAlignmentRight;
    value.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:value];
    if (valueLabelOut) *valueLabelOut = value;

    ApolloIMDetentSlider *slider = [[ApolloIMDetentSlider alloc] init];
    slider.minimumValue = 50.0;
    slider.maximumValue = 100.0;
    slider.value = (float)percent;
    slider.enabled = enabled;
    slider.continuous = YES;
    slider.accessibilityLabel = label;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:slider];

    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10.0],
        [value.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [value.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [value.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8.0],
        [slider.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [slider.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6.0],
        [slider.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0],
    ]];
    return cell;
}

// MARK: Value strings

- (NSString *)alignmentText {
    switch (sInlineImageAlignment) {
        case ApolloInlineImageAlignmentLeft:  return @"Left";
        case ApolloInlineImageAlignmentRight: return @"Right";
        default:                              return @"Center";
    }
}

- (NSString *)autoplayModeText {
    switch (sAutoplayInlineGIFMode) {
        case ApolloAutoplayInlineGIFModeTapToPlay: return @"Tap to Play";
        case ApolloAutoplayInlineGIFModeWiFiOnly:  return @"WiFi Only";
        case ApolloAutoplayInlineGIFModeAlways:    return @"Always";
        case ApolloAutoplayInlineGIFModeNever:
        default:                                   return @"Never";
    }
}

// MARK: Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ApolloIMSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case ApolloIMSectionPreview:  return 1;
        case ApolloIMSectionMaster:   return ApolloIMMasterRowCount;
        case ApolloIMSectionOptions:  return ApolloIMOptionsRowCount;
        default:                      return 0;
    }
}

// The message-media toggle is scoped to the threads Apollo draws ITSELF with
// _TtC6Apollo28PrivateMessageViewController — one bubble UI serving three
// surfaces: legacy Direct Chat (Reddit mirrors chat rooms into the old message
// inbox as "[direct chat room]" items), ordinary private messages, and native
// Moderator Mail conversations (same class; see its newModmailConversation /
// currentModmailSendMode fields).
//
// Reddit's modern Chat / Modmail are authenticated web surfaces that render
// their own media, so switching either on takes that surface out of this
// setting's reach — hence the caveat sentence. It never empties the list
// though: private messages are always drawn natively (they exist for API-key
// and API-key-free accounts alike, /message/* being a routable keyless path),
// so this toggle always still governs something and must stay switchable
// rather than being forced off and greyed out when modern Chat is on.
//
// Both gates are the EFFECTIVE state, not the raw defaults: they already fold
// in the iOS 16 floor and the forced-on behaviour for API-key-free accounts,
// so a keyless account correctly sees the Chat + Moderator Mail caveat without
// the switches themselves having been touched.
static NSString *ApolloIMMessageMediaFooter(void) {
    BOOL modernChat = ApolloModernChatShouldOpen();
    BOOL modernModmail = ApolloModernModmailShouldOpen();

    NSMutableArray<NSString *> *native = [NSMutableArray array];
    if (!modernChat) [native addObject:@"Direct Chat"];
    [native addObject:@"private messages"];
    if (!modernModmail) [native addObject:@"Moderator Mail"];

    NSString *nativeList = native.count == 3
        ? [NSString stringWithFormat:@"%@, %@, and %@", native[0], native[1], native[2]]
        : (native.count == 2
            ? [NSString stringWithFormat:@"%@ and %@", native[0], native[1]]
            : native.firstObject);

    NSMutableString *footer = [NSMutableString stringWithFormat:
        @"Inline Media Previews renders image, GIF, and video links inside post text and comments "
        @"instead of leaving them as plain links. Inline Media in Messages does the same inside the "
        @"message threads Apollo draws itself — %@.", nativeList];

    if (modernChat || modernModmail) {
        BOOL both = modernChat && modernModmail;
        [footer appendFormat:@" Reddit's modern %@ %@ %@ own media, so this setting doesn't apply there.",
            both ? @"Chat and Moderator Mail" : (modernChat ? @"Chat" : @"Moderator Mail"),
            both ? @"render" : @"renders",
            both ? @"their" : @"its"];
    }
    return footer;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case ApolloIMSectionPreview:  return @"Preview";
        case ApolloIMSectionMaster:   return @"Inline Media";
        case ApolloIMSectionOptions:  return @"Comments & Posts";
        default:                      return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case ApolloIMSectionMaster:
            return ApolloIMMessageMediaFooter();
        case ApolloIMSectionOptions:
            return @"Tap to Play shows a paused GIF with a play button in the bottom corner — it plays that one GIF inline and becomes a pause button, and tapping the rest of the GIF opens the fullscreen viewer as usual. Never shows a static preview (tap opens the viewer). WiFi Only autoplays on WiFi and behaves like Tap to Play on cellular.";
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL inlineOn = sEnableInlineImages;
    switch (indexPath.section) {
        case ApolloIMSectionPreview: {
            // Transparent placeholder — the pinned host draws the card on top of
            // (or, once scrolled, instead of) this slot.
            ApolloIMPreviewSpacerCell *cell = [[ApolloIMPreviewSpacerCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            ApolloIMClearSpacerCell(cell);
            cell.isAccessibilityElement = NO;
            return cell;
        }
        case ApolloIMSectionMaster:
            if (indexPath.row == ApolloIMMasterRowChat) {
                // Deliberately NOT disabled when modern Chat/Modmail is on: those
                // only take their own surface out of scope, and native private
                // message threads always remain. See ApolloIMMessageMediaFooter.
                return [self switchCellLabel:@"Inline Media in Messages"
                                          on:sEnableChatMedia
                                     enabled:YES
                                      action:@selector(chatMediaSwitchToggled:)];
            }
            return [self switchCellLabel:@"Inline Media Previews"
                                      on:sEnableInlineImages
                                 enabled:YES
                                  action:@selector(inlineMediaSwitchToggled:)];
        case ApolloIMSectionOptions:
            switch (indexPath.row) {
                case ApolloIMOptionsRowAlignment:
                    return [self valueCellLabel:@"Inline Media Alignment" detail:[self alignmentText] enabled:inlineOn];
                case ApolloIMOptionsRowAutoplay:
                    return [self valueCellLabel:@"Autoplay Inline GIFs" detail:[self autoplayModeText] enabled:inlineOn];
                case ApolloIMOptionsRowMediaSize: {
                    UILabel *valueLabel = nil;
                    UITableViewCell *cell = [self sliderCellLabel:@"Inline Media Size"
                                                          percent:sInlineMediaSizePercent
                                                          enabled:inlineOn
                                                           action:@selector(mediaSizeSliderChanged:)
                                                       valueLabel:&valueLabel];
                    self.mediaSizeValueLabel = valueLabel;
                    return cell;
                }
            }
            break;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloIMSectionPreview) {
        return [ApolloInlineMediaPreviewView heightForCardWidth:[self previewCardWidthForTable:tableView]];
    }
    if (indexPath.section == ApolloIMSectionOptions && indexPath.row == ApolloIMOptionsRowMediaSize) {
        return 88.0;
    }
    return UITableViewAutomaticDimension;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != ApolloIMSectionOptions) return NO;
    if (!sEnableInlineImages) return NO;
    return indexPath.row == ApolloIMOptionsRowAlignment || indexPath.row == ApolloIMOptionsRowAutoplay;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != ApolloIMSectionOptions || !sEnableInlineImages) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (indexPath.row == ApolloIMOptionsRowAlignment) {
        [self presentAlignmentSheetFromSourceView:cell];
    } else if (indexPath.row == ApolloIMOptionsRowAutoplay) {
        [self presentAutoplayModeSheetFromSourceView:cell];
    }
}

// MARK: Actions

- (void)inlineMediaSwitchToggled:(UISwitch *)sw {
    sEnableInlineImages = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableInlineImages forKey:UDKeyEnableInlineImages];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ApolloIMSectionOptions]
                  withRowAnimation:UITableViewRowAnimationNone];
    [self syncPreviewState];   // comment mock flips between GIF block and plain link
}

// Master toggle for message-thread media (inline images/GIFs/emoji/snoomoji +
// working media sends + tap-to-fullscreen) in every thread Apollo draws itself.
// Open threads re-render their cells on next display/scroll, so no immediate-
// refresh notification is needed. Independent of the posts/comments inline
// toggle and of Show User Profile Pictures.
- (void)chatMediaSwitchToggled:(UISwitch *)sw {
    sEnableChatMedia = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sEnableChatMedia forKey:UDKeyEnableChatMedia];
    [self syncPreviewState];   // message bubble flips between inline image and plain link
}

- (void)mediaSizeSliderChanged:(UISlider *)slider {
    // The detent slider only ever sends an action for a committed detent (drag
    // crossing or tap), so read that rather than re-deriving it from `value`,
    // which may still be animating toward it.
    NSInteger percent = [slider isKindOfClass:[ApolloIMDetentSlider class]]
        ? ((ApolloIMDetentSlider *)slider).lastSnappedPercent
        : ApolloIMSnapPercent(slider.value);
    if (percent != 50 && percent != 75 && percent != 100) percent = ApolloIMSnapPercent(slider.value);
    self.mediaSizeValueLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    if (percent != sInlineMediaSizePercent) {
        sInlineMediaSizePercent = percent;
        [[NSUserDefaults standardUserDefaults] setInteger:percent forKey:UDKeyInlineMediaSizePercent];
        // Re-measure visible comments so the change applies without leaving
        // the thread.
        [[NSNotificationCenter defaultCenter] postNotificationName:ApolloInlineMediaLayoutDidChangeNotification
                                                            object:nil];
    }
    [self syncPreviewState];
}

// MARK: Sheets

- (void)presentAlignmentSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Inline Media Alignment"
                                                                   message:@"Horizontal position of inline media narrower than the row."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *values = @[@(ApolloInlineImageAlignmentCenter),
                                    @(ApolloInlineImageAlignmentLeft),
                                    @(ApolloInlineImageAlignmentRight)];
    NSArray<NSString *> *titles = @[@"Center", @"Left", @"Right"];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSInteger value = values[i].integerValue;
        NSString *title = titles[i];
        if (sInlineImageAlignment == value) title = [title stringByAppendingString:@" (Current)"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            sInlineImageAlignment = value;
            [[NSUserDefaults standardUserDefaults] setInteger:value forKey:UDKeyInlineImageAlignment];
            // Re-measure visible comments so the change applies without
            // leaving the thread.
            [[NSNotificationCenter defaultCenter] postNotificationName:ApolloInlineMediaLayoutDidChangeNotification
                                                                object:nil];
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:ApolloIMOptionsRowAlignment
                                                                        inSection:ApolloIMSectionOptions]]
                                  withRowAnimation:UITableViewRowAnimationNone];
            [self syncPreviewState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentAutoplayModeSheetFromSourceView:(UIView *)sourceView {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Autoplay Inline GIFs"
                                                                   message:@"Tap to Play pauses GIFs behind a play button; tapping plays or pauses that GIF inline."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *values = @[@(ApolloAutoplayInlineGIFModeAlways),
                                    @(ApolloAutoplayInlineGIFModeWiFiOnly),
                                    @(ApolloAutoplayInlineGIFModeTapToPlay),
                                    @(ApolloAutoplayInlineGIFModeNever)];
    NSArray<NSString *> *titles = @[@"Always", @"WiFi Only", @"Tap to Play", @"Never"];
    for (NSUInteger i = 0; i < values.count; i++) {
        NSInteger value = values[i].integerValue;
        NSString *title = titles[i];
        if (sAutoplayInlineGIFMode == value) title = [title stringByAppendingString:@" (Current)"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            sAutoplayInlineGIFMode = value;
            // The KVO observer in ApolloMediaAutoplay picks this write up and
            // refreshes every registered on-screen GIF immediately.
            [[NSUserDefaults standardUserDefaults] setInteger:value forKey:UDKeyAutoplayInlineGIFs];
            [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:ApolloIMOptionsRowAutoplay
                                                                        inSection:ApolloIMSectionOptions]]
                                  withRowAnimation:UITableViewRowAnimationNone];
            [self syncPreviewState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sourceView;
    sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
