#import "settings/ApolloSubredditLayoutViewController.h"

#import "ApolloSettingsForm.h"
#import "ApolloState.h"
#import "ApolloSubredditLayout.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"
#import "settings/ApolloSubredditLayoutPreview.h"

static NSInteger const ApolloCommunityHighlightsPreviewViewTag = 8102;

@interface ApolloSubredditLayoutViewController ()
@property (nonatomic, strong) ApolloSubredditHeaderPreviewView *layoutPreviewView;
@property (nonatomic, strong) UIView *pinnedPreviewHost;
@property (nonatomic, strong) ApolloSubredditLayoutPreviewCard *pinnedPreviewCard;
@property (nonatomic, strong) UILabel *pinnedPreviewTitleLabel;
@property (nonatomic, strong) UIView *pinnedPreviewSpacer;
@property (nonatomic) CGFloat pinnedPreviewHeight;
@property (nonatomic) BOOL updatingPinnedPreviewLayout;
- (ApolloSubredditDensityMode)currentDensityMode;
- (ApolloCommunityHighlightsMode)currentHighlightsMode;
- (CGRect)apollo_tableReadableFrame;
- (CGFloat)apollo_highlightsPreviewContentWidth;
@end

@implementation ApolloSubredditLayoutViewController

- (void)viewDidLoad {
    self.layoutPreviewView = [[ApolloSubredditHeaderPreviewView alloc] initWithFrame:CGRectZero];

    [super viewDidLoad];
    self.title = @"Subreddit Layout";
    [self apollo_installPinnedPreview];
    [self apollo_configureLayoutPreview:self.layoutPreviewView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self apollo_updatePinnedPreviewLayoutPreservingScroll:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_refreshLayoutPreviewAnimated:NO];
    [self apollo_refreshHighlightsPreviewAnimated:NO];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    BOOL appearanceChanged = !previousTraitCollection ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection];
    BOOL contentSizeChanged = !previousTraitCollection ||
        ![self.traitCollection.preferredContentSizeCategory
            isEqualToString:previousTraitCollection.preferredContentSizeCategory];
    if (appearanceChanged || contentSizeChanged) {
        [self apollo_refreshLayoutPreviewAnimated:NO];
        [self apollo_refreshHighlightsPreviewAnimated:NO];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil
                                 completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf apollo_refreshLayoutPreviewAnimated:NO];
        [weakSelf apollo_refreshHighlightsPreviewAnimated:NO];
    }];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == self.tableView) [self apollo_updatePinnedPreviewPosition];
}

- (void)tableView:(UITableView *)tableView
        willDisplayHeaderView:(UIView *)view
                   forSection:(NSInteger)section {
    if (tableView != self.tableView || section != 0 ||
        ![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;

    // Borrow the live Layout section header font so Preview stays identical
    // across iOS versions, Dynamic Type sizes, and Apollo font customizations.
    UIFont *layoutHeaderFont = ((UITableViewHeaderFooterView *)view).textLabel.font;
    if (layoutHeaderFont && ![self.pinnedPreviewTitleLabel.font isEqual:layoutHeaderFont]) {
        self.pinnedPreviewTitleLabel.font = layoutHeaderFont;
        [self apollo_updatePinnedPreviewLayoutPreservingScroll:YES];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (tableView != self.tableView || section != 0) return UITableViewAutomaticDimension;

    // The preview already supplies the first section's generous top spacing.
    // Match later section headers here instead of stacking another empty band.
    CGFloat lineHeight = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].lineHeight;
    return ceil(MAX(33.0, lineHeight + 15.0));
}

- (void)apollo_applyTheme {
    [super apollo_applyTheme];
    self.pinnedPreviewHost.backgroundColor = self.tableView.backgroundColor
        ?: ApolloThemePageBackgroundColor()
        ?: UIColor.systemGroupedBackgroundColor;
    self.pinnedPreviewCard.backgroundColor = [self apollo_themeCellBackgroundColor];
    [self.pinnedPreviewCard apollo_applyCurrentAppearance];
    self.pinnedPreviewTitleLabel.textColor = ApolloThemeRuntimeColor(ApolloThemeTokenSecondaryLabel)
        ?: UIColor.secondaryLabelColor;
    [self.layoutPreviewView apollo_applyCurrentAppearance];
    ApolloCommunityHighlightsPreviewView *highlightsPreview =
        (ApolloCommunityHighlightsPreviewView *)
            [[self cellForRowID:@"highlightsPreview"].contentView
                viewWithTag:ApolloCommunityHighlightsPreviewViewTag];
    [highlightsPreview apollo_applyCurrentAppearance];
}

#pragma mark - Pinned preview

- (void)apollo_installPinnedPreview {
    if (self.pinnedPreviewHost) return;

    self.pinnedPreviewSpacer = [[UIView alloc] initWithFrame:CGRectZero];
    self.pinnedPreviewSpacer.backgroundColor = UIColor.clearColor;
    self.pinnedPreviewSpacer.userInteractionEnabled = NO;
    self.pinnedPreviewSpacer.accessibilityElementsHidden = YES;
    self.tableView.tableHeaderView = self.pinnedPreviewSpacer;

    UIView *host = [[UIView alloc] initWithFrame:CGRectZero];
    host.clipsToBounds = YES;
    self.pinnedPreviewHost = host;

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = @"Preview";
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.isAccessibilityElement = YES;
    titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    self.pinnedPreviewTitleLabel = titleLabel;
    [host addSubview:titleLabel];

    ApolloSubredditLayoutPreviewCard *card =
        [[ApolloSubredditLayoutPreviewCard alloc] initWithPreview:self.layoutPreviewView];
    card.pinned = [[NSUserDefaults standardUserDefaults] boolForKey:UDKeySubredditLayoutPreviewPinned];
    __weak typeof(self) weakSelf = self;
    card.pinDidChange = ^(BOOL pinned) {
        [[NSUserDefaults standardUserDefaults] setBool:pinned forKey:UDKeySubredditLayoutPreviewPinned];
        if (UIAccessibilityIsReduceMotionEnabled()) {
            [weakSelf apollo_updatePinnedPreviewPosition];
        } else {
            [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.9 initialSpringVelocity:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{ [weakSelf apollo_updatePinnedPreviewPosition]; }
                             completion:nil];
        }
    };
    self.pinnedPreviewCard = card;
    [host addSubview:card];
    [host addSubview:card.pinControl];

    [self.tableView addSubview:host];
    [self apollo_applyTheme];
    [self apollo_updatePinnedPreviewLayoutPreservingScroll:NO];
}

- (BOOL)apollo_canPinPreview {
    CGFloat availableHeight = CGRectGetHeight(self.tableView.bounds)
        - self.tableView.adjustedContentInset.top - self.tableView.adjustedContentInset.bottom;
    return self.pinnedPreviewCard.pinned &&
        self.traitCollection.verticalSizeClass != UIUserInterfaceSizeClassCompact &&
        availableHeight - self.pinnedPreviewHeight >= 200.0;
}

- (void)apollo_orderPreviewAboveTableContent {
    // Keep visual and touch order aligned without covering UIKit's scroll
    // indicators or navigation-edge effects. iOS 26 nests cells in wrappers.
    NSMutableArray<UIView *> *content = [self.tableView.visibleCells mutableCopy];
    [content addObject:self.pinnedPreviewSpacer];
    for (NSInteger section = 0; section < self.tableView.numberOfSections; section++) {
        UIView *header = [self.tableView headerViewForSection:section];
        UIView *footer = [self.tableView footerViewForSection:section];
        if (header) [content addObject:header];
        if (footer) [content addObject:footer];
    }
    NSArray<UIView *> *subviews = self.tableView.subviews;
    NSUInteger topIndex = 0;
    UIView *topContent = nil;
    for (UIView *view in content) {
        UIView *direct = view;
        while (direct.superview && direct.superview != self.tableView) direct = direct.superview;
        if (direct.superview != self.tableView) continue;
        NSUInteger index = [subviews indexOfObjectIdenticalTo:direct];
        if (index != NSNotFound && (!topContent || index > topIndex)) {
            topIndex = index;
            topContent = direct;
        }
    }
    if (topContent && [subviews indexOfObjectIdenticalTo:self.pinnedPreviewHost] != topIndex + 1) {
        [self.tableView insertSubview:self.pinnedPreviewHost aboveSubview:topContent];
    }
}

- (void)apollo_updatePinnedPreviewPosition {
    if (!self.pinnedPreviewHost) return;

    CGFloat topInset = MAX(0.0, self.tableView.adjustedContentInset.top);
    CGFloat visibleTop = self.tableView.contentOffset.y + topInset;
    CGFloat contentY = [self apollo_canPinPreview] ? MAX(0.0, visibleTop) : 0.0;
    // Cover the navigation inset only while stuck. Matching negative bounds
    // keep the title/card stationary as the mask appears or disappears.
    CGFloat maskTop = contentY > 0.0 ? topInset : 0.0;
    CGRect frame = CGRectMake(0.0, contentY - maskTop,
                              CGRectGetWidth(self.tableView.bounds),
                              self.pinnedPreviewHeight + maskTop);
    CGRect bounds = CGRectMake(0.0, -maskTop, frame.size.width, frame.size.height);
    if (!CGRectEqualToRect(self.pinnedPreviewHost.frame, frame)) {
        self.pinnedPreviewHost.frame = frame;
    }
    if (!CGRectEqualToRect(self.pinnedPreviewHost.bounds, bounds)) {
        self.pinnedPreviewHost.bounds = bounds;
    }
    [self apollo_orderPreviewAboveTableContent];
}

- (void)apollo_updatePinnedPreviewLayoutPreservingScroll:(BOOL)preserveScroll {
    if (self.updatingPinnedPreviewLayout || !self.pinnedPreviewHost) return;
    CGFloat tableWidth = CGRectGetWidth(self.tableView.bounds);
    if (tableWidth <= 1.0) return;

    self.updatingPinnedPreviewLayout = YES;
    CGRect readableFrame = [self apollo_tableReadableFrame];
    CGFloat cardX = CGRectGetMinX(readableFrame);
    CGFloat cardWidth = CGRectGetWidth(readableFrame);
    UIEdgeInsets previewInsets = ApolloSubredditLayoutPreviewCard.previewInsets;
    CGFloat previewWidth = MAX(1.0, cardWidth - previewInsets.left - previewInsets.right);
    CGFloat previewHeight = ceil([self.layoutPreviewView preferredPreviewHeightForWidth:previewWidth]);
    CGFloat titleTop = 15.0;
    CGFloat titleHeight = ceil(MAX(20.0, self.pinnedPreviewTitleLabel.font.lineHeight));
    CGFloat cardTop = titleTop + titleHeight + 7.0;
    CGFloat cardHeight = previewHeight + previewInsets.top + previewInsets.bottom;
    CGFloat totalHeight = cardTop + cardHeight;

    CGFloat oldHeight = self.pinnedPreviewHeight;
    CGPoint oldOffset = self.tableView.contentOffset;
    CGFloat visibleTop = oldOffset.y + self.tableView.adjustedContentInset.top;
    BOOL preserveRowPosition = visibleTop > 0.5 &&
        ([self apollo_canPinPreview] || visibleTop >= oldHeight);

    CGFloat pinControlWidth = MIN(112.0, previewWidth * 0.45);
    self.pinnedPreviewTitleLabel.frame = CGRectMake(cardX + 16.0, titleTop,
                                                     previewWidth - pinControlWidth, titleHeight);
    self.pinnedPreviewCard.pinControl.frame = CGRectMake(cardX + cardWidth - 5.0 - pinControlWidth,
                                                         titleTop + (titleHeight - 44.0) / 2.0,
                                                         pinControlWidth, 44.0);
    self.pinnedPreviewCard.frame = CGRectMake(cardX, cardTop, cardWidth, cardHeight);
    [self.pinnedPreviewCard setNeedsLayout];
    [self.pinnedPreviewCard layoutIfNeeded];

    CGRect spacerFrame = CGRectMake(0.0, 0.0, tableWidth, totalHeight);
    BOOL spacerChanged = !CGRectEqualToRect(self.pinnedPreviewSpacer.frame, spacerFrame);
    self.pinnedPreviewSpacer.frame = spacerFrame;
    self.pinnedPreviewHeight = totalHeight;
    if (spacerChanged || self.tableView.tableHeaderView != self.pinnedPreviewSpacer) {
        self.tableView.tableHeaderView = self.pinnedPreviewSpacer;
    }
    if (preserveScroll && preserveRowPosition && oldHeight > 0.0 && ABS(totalHeight - oldHeight) > 0.5) {
        oldOffset.y = MAX(-self.tableView.adjustedContentInset.top,
                          oldOffset.y + totalHeight - oldHeight);
        self.tableView.contentOffset = oldOffset;
    }

    [self.layoutPreviewView setNeedsLayout];
    [self.layoutPreviewView layoutIfNeeded];
    [self apollo_updatePinnedPreviewPosition];
    self.updatingPinnedPreviewLayout = NO;
}

#pragma mark - Live apply

// Re-walks visible subreddit headers and reinstalls/relays them out — mirrors
// ApolloUserAvatarsToggleChangedNotification's role for profiles.
- (void)apollo_persistAndApply {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloSubredditLayoutChangedNotification
                                                        object:nil];
}

#pragma mark - Header style

- (NSString *)densityText {
    if (!sShowSubredditHeaders) return @"Native";
    return sSubredditHeaderImmersive ? @"Immersive" : @"Compact";
}

- (void)setDensityMode:(ApolloSubredditDensityMode)mode {
    if (mode < ApolloSubredditDensityModeImmersive ||
        mode > ApolloSubredditDensityModeNative ||
        mode == [self currentDensityMode]) return;

    BOOL previouslyUsedRebornHeader = sShowSubredditHeaders;
    BOOL useRebornHeader = mode != ApolloSubredditDensityModeNative;
    BOOL immersive = mode == ApolloSubredditDensityModeImmersive;
    sShowSubredditHeaders = useRebornHeader;
    sSubredditHeaderImmersive = immersive;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:useRebornHeader forKey:UDKeyShowSubredditHeaders];
    [defaults setBool:immersive forKey:UDKeySubredditHeaderImmersive];
    // Header styles can change both preview and conditional-row geometry.
    // Settle them together so the pinned card never participates in the
    // table transition or cross-dissolves against a differently sized copy.
    [UIView performWithoutAnimation:^{
        [self reloadRowWithID:@"density"];
        [self visibilityDidChange];
        [self apollo_refreshLayoutPreviewAnimated:NO];
        [self.tableView layoutIfNeeded];
    }];
    if (previouslyUsedRebornHeader != useRebornHeader) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ApolloSubredditHeaderOwnershipChangedNotification
                          object:nil];
    } else {
        [self apollo_persistAndApply];
    }
}

- (void)presentDensityPicker {
    __weak typeof(self) weakSelf = self;
    ApolloSubredditDensityMode selected = [self currentDensityMode];
    ApolloSettingsPresentPicker(self, [self cellForRowID:@"density"], @"Header Style",
                                @[@"Immersive", @"Compact", @"Native"],
                                selected, ^(NSInteger pickedIndex) {
        [weakSelf setDensityMode:(ApolloSubredditDensityMode)pickedIndex];
    });
}

#pragma mark - Community Highlights

// Backed by the same two booleans other builds' preferences/backups already
// use (see ApolloState.h), so no migration is needed. Independent of the
// density — highlights can install into Apollo's native
// tableHeaderView just as well as into ours (ApolloSubredditHighlights.xm),
// so this row stays visible regardless of sShowSubredditHeaders.
- (NSString *)communityHighlightsModeText {
    if (!sCommunityHighlights) return @"Off";
    return sCommunityHighlightsWeb ? @"Full" : @"Partial";
}

- (void)setCommunityHighlightsMode:(ApolloCommunityHighlightsMode)mode {
    if (mode < ApolloCommunityHighlightsModeOff ||
        mode > ApolloCommunityHighlightsModeFull) return;

    ApolloCommunityHighlightsMode previousMode = [self currentHighlightsMode];
    BOOL enabled = mode != ApolloCommunityHighlightsModeOff;
    BOOL full = mode == ApolloCommunityHighlightsModeFull;
    if (sCommunityHighlights == enabled && sCommunityHighlightsWeb == full) return;

    sCommunityHighlights = enabled;
    sCommunityHighlightsWeb = full;
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlights forKey:UDKeyCommunityHighlights];
    [[NSUserDefaults standardUserDefaults] setBool:sCommunityHighlightsWeb forKey:UDKeyCommunityHighlightsWeb];
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ApolloCommunityHighlightsModeChangedNotification
                      object:nil];
    [self reloadRowWithID:@"highlights"];
    BOOL keepsCarouselHeight = previousMode != ApolloCommunityHighlightsModeOff &&
        mode != ApolloCommunityHighlightsModeOff;
    [self apollo_refreshHighlightsPreviewAnimated:keepsCarouselHeight];
}

// Title + options + "(Current)" only — shared picker (option index == mode).
- (void)presentCommunityHighlightsModeSheetFromSourceView:(UIView *)sourceView {
    __weak typeof(self) weakSelf = self;
    ApolloCommunityHighlightsMode current = [self currentHighlightsMode];
    ApolloSettingsPresentPicker(self, sourceView, @"Community Highlights",
                                @[@"Off", @"Partial", @"Full"],
                                current,
                                ^(NSInteger pickedIndex) {
        [weakSelf setCommunityHighlightsMode:(ApolloCommunityHighlightsMode)pickedIndex];
    });
}

#pragma mark - Preview cells

- (CGRect)apollo_tableReadableFrame {
    CGFloat tableWidth = CGRectGetWidth(self.tableView.bounds);
    if (tableWidth <= 1.0) tableWidth = CGRectGetWidth(self.view.bounds);
    if (tableWidth <= 1.0) tableWidth = CGRectGetWidth(UIScreen.mainScreen.bounds);
    CGRect readableFrame = self.tableView.readableContentGuide.layoutFrame;
    CGFloat minX = MAX(0.0, CGRectGetMinX(readableFrame));
    CGFloat maxX = MIN(tableWidth, CGRectGetMaxX(readableFrame));
    if (maxX - minX <= 1.0) {
        UIEdgeInsets margins = self.tableView.layoutMargins;
        minX = MAX(0.0, margins.left);
        maxX = MIN(tableWidth, tableWidth - MAX(0.0, margins.right));
    }
    if (maxX - minX <= 1.0) {
        minX = 0.0;
        maxX = MAX(1.0, tableWidth);
    }
    return CGRectMake(minX, 0.0, MAX(1.0, maxX - minX), 0.0);
}

- (CGFloat)apollo_highlightsPreviewContentWidth {
    // Row height can be queried while the conditional header-option rows are
    // animating out. A live cell has a provisional narrow contentView during
    // that batch; measuring from it caches a short row, then the carousel lays
    // out at the final width and clips its bottom. The custom row spans the
    // table's readable frame, which is stable before and after the transition.
    return CGRectGetWidth([self apollo_tableReadableFrame]);
}

- (ApolloSubredditDensityMode)currentDensityMode {
    if (!sShowSubredditHeaders) return ApolloSubredditDensityModeNative;
    return sSubredditHeaderImmersive
        ? ApolloSubredditDensityModeImmersive : ApolloSubredditDensityModeClassic;
}

- (ApolloCommunityHighlightsMode)currentHighlightsMode {
    if (!sCommunityHighlights) return ApolloCommunityHighlightsModeOff;
    return sCommunityHighlightsWeb
        ? ApolloCommunityHighlightsModeFull : ApolloCommunityHighlightsModePartial;
}

- (CGFloat)highlightsPreviewHeight {
    // The carousel already owns its production 16pt side insets, so this
    // preview spans the inset-grouped cell rather than adding another set of
    // content margins around it.
    CGFloat width = [self apollo_highlightsPreviewContentWidth];
    CGFloat contentHeight = [ApolloCommunityHighlightsPreviewView
        preferredContentHeightForMode:[self currentHighlightsMode]
                                 width:width
                              hostView:self.tableView];
    return ceil(contentHeight) + 20.0;
}

- (UITableViewCell *)highlightsPreviewCellForTableView:(UITableView *)tableView {
    static NSString *const reuseID = @"ApolloCommunityHighlightsPreviewCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    ApolloCommunityHighlightsPreviewView *preview = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        preview = [[ApolloCommunityHighlightsPreviewView alloc] initWithFrame:CGRectZero];
        preview.tag = ApolloCommunityHighlightsPreviewViewTag;
        preview.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:preview];
        [NSLayoutConstraint activateConstraints:@[
            [preview.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [preview.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [preview.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10.0],
            [preview.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10.0],
        ]];
    } else {
        preview = (ApolloCommunityHighlightsPreviewView *)
            [cell.contentView viewWithTag:ApolloCommunityHighlightsPreviewViewTag];
    }
    [preview configureWithMode:[self currentHighlightsMode]];
    [self apollo_applyPrimaryTextColorToCell:cell];
    return cell;
}

- (void)apollo_configureLayoutPreview:(ApolloSubredditHeaderPreviewView *)preview {
    [preview configureWithDensityMode:[self currentDensityMode]
                               banner:sSubredditShowBanner
                          joinButton:sSubredditShowJoinButton
                         displayName:sSubredditShowDisplayName
                            subtitle:sSubredditShowSubtitle
                          description:sSubredditShowDescription];
}

- (void)apollo_crossDissolvePreviewView:(UIView *)preview
                              configure:(void (^)(void))configure {
    if (!preview || !configure) return;

    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.15 : 0.23;
    [UIView transitionWithView:preview
                      duration:duration
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionBeginFromCurrentState |
                               UIViewAnimationOptionAllowUserInteraction
                    animations:configure
                    completion:nil];
}

- (void)apollo_refreshLayoutPreviewAnimated:(BOOL)animated {
    __weak typeof(self) weakSelf = self;
    void (^update)(void) = ^{
        typeof(self) strongSelf = weakSelf;
        [strongSelf apollo_configureLayoutPreview:strongSelf.layoutPreviewView];
        [strongSelf apollo_updatePinnedPreviewLayoutPreservingScroll:YES];
    };
    if (!animated) {
        [UIView performWithoutAnimation:update];
        return;
    }

    NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.15 : 0.23;
    [UIView transitionWithView:self.pinnedPreviewCard
                      duration:duration
                       options:UIViewAnimationOptionTransitionCrossDissolve |
                               UIViewAnimationOptionBeginFromCurrentState |
                               UIViewAnimationOptionAllowUserInteraction
                    animations:update
                    completion:nil];
}

- (void)apollo_refreshHighlightsPreviewAnimated:(BOOL)animated {
    UITableViewCell *cell = [self cellForRowID:@"highlightsPreview"];
    ApolloCommunityHighlightsPreviewView *preview =
        (ApolloCommunityHighlightsPreviewView *)
            [cell.contentView viewWithTag:ApolloCommunityHighlightsPreviewViewTag];
    if (![preview isKindOfClass:[ApolloCommunityHighlightsPreviewView class]]) {
        [self reloadRowWithID:@"highlightsPreview"];
        return;
    }

    ApolloCommunityHighlightsMode mode = [self currentHighlightsMode];
    if (animated) {
        // Partial and Full have the same row height, so only their carousel
        // content needs to transition; the table and pinned preview stay put.
        [self apollo_crossDissolvePreviewView:preview configure:^{
            [preview configureWithMode:mode];
            [preview layoutIfNeeded];
        }];
        return;
    }

    // Height-changing mode switches and lifecycle refreshes re-query the row
    // outside an animation context so UITableView cannot disturb the pinned
    // header while reflowing.
    [UIView performWithoutAnimation:^{
        [preview configureWithMode:mode];
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
        [self.tableView layoutIfNeeded];
    }];
}

#pragma mark - Form

- (NSArray<ApolloSettingsSection *> *)buildForm {
    __weak typeof(self) weakSelf = self;

    ApolloSettingsRow *density =
        [ApolloSettingsRow valueRowWithID:@"density"
                                    title:@"Header Style"
                                   detail:^NSString * { return [weakSelf densityText]; }
                                 onSelect:^{ [weakSelf presentDensityPicker]; }];
    density.configure = ^(UITableViewCell *cell) { cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; };

    ApolloSettingsRow *banner =
        [ApolloSettingsRow switchRowWithID:@"showBanner"
                                     title:@"Banner"
                                      isOn:^BOOL { return sSubredditShowBanner; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowBanner = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowBanner];
            [weakSelf apollo_refreshLayoutPreviewAnimated:YES];
            [weakSelf apollo_persistAndApply];
        }];
    banner.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *joinButton =
        [ApolloSettingsRow switchRowWithID:@"showJoinButton"
                                     title:@"Join Button"
                                      isOn:^BOOL { return sSubredditShowJoinButton; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowJoinButton = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowJoinButton];
            [weakSelf apollo_refreshLayoutPreviewAnimated:YES];
            [weakSelf apollo_persistAndApply];
        }];
    joinButton.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *displayName =
        [ApolloSettingsRow switchRowWithID:@"showDisplayName"
                                     title:@"Subreddit Name"
                                      isOn:^BOOL { return sSubredditShowDisplayName; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowDisplayName = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowDisplayName];
            [weakSelf apollo_refreshLayoutPreviewAnimated:YES];
            [weakSelf apollo_persistAndApply];
        }];
    displayName.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *subtitle =
        [ApolloSettingsRow switchRowWithID:@"showSubtitle"
                                     title:@"Subtitle"
                                      isOn:^BOOL { return sSubredditShowSubtitle; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowSubtitle = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowSubtitle];
            [weakSelf apollo_refreshLayoutPreviewAnimated:YES];
            [weakSelf apollo_persistAndApply];
        }];
    subtitle.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsRow *description =
        [ApolloSettingsRow switchRowWithID:@"showDescription"
                                     title:@"Description"
                                      isOn:^BOOL { return sSubredditShowDescription; }
                                  onToggle:^(UISwitch *sender) {
            sSubredditShowDescription = sender.isOn;
            [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:UDKeySubredditShowDescription];
            [weakSelf apollo_refreshLayoutPreviewAnimated:YES];
            [weakSelf apollo_persistAndApply];
        }];
    description.visible = ^BOOL { return sShowSubredditHeaders; };

    ApolloSettingsSection *headerSection =
        [ApolloSettingsSection sectionWithTitle:@"Layout"
                                         footer:@"Immersive and Compact use Apollo Reborn’s customizable header. Native keeps Apollo’s original layout."
                                           rows:@[ density, banner, joinButton, displayName, subtitle, description ]];

    ApolloSettingsRow *highlights =
        [ApolloSettingsRow valueRowWithID:@"highlights"
                                    title:@"Display"
                                   detail:^NSString * { return [weakSelf communityHighlightsModeText]; }
                                 onSelect:^{
            [weakSelf presentCommunityHighlightsModeSheetFromSourceView:[weakSelf cellForRowID:@"highlights"]];
        }];
    highlights.configure = ^(UITableViewCell *cell) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    };

    ApolloSettingsRow *highlightsPreview =
        [ApolloSettingsRow customRowWithID:@"highlightsPreview"
                                      cell:^UITableViewCell *(UITableView *tableView, __unused ApolloSettingsRow *row) {
            return [weakSelf highlightsPreviewCellForTableView:tableView];
        }
                                  onSelect:nil];
    highlightsPreview.height = ^CGFloat { return [weakSelf highlightsPreviewHeight]; };

    ApolloSettingsSection *highlightsSection =
        [ApolloSettingsSection sectionWithTitle:@"Community Highlights"
                                         footer:nil
                                           rows:@[ highlights, highlightsPreview ]];

    return @[ headerSection, highlightsSection ];
}

@end
