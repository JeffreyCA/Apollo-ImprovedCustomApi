#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ApolloCommon.h"
#import "ApolloState.h"
#import "ApolloThemeRuntime.h"
#import "UserDefaultConstants.h"

static char kApolloSubredditIndexTableKey;
static char kApolloSubredditIndexOverlayKey;
static char kApolloSubredditIndexLoggedKey;
static char kApolloSubredditStarProxyKey;
static char kApolloSubredditStarProxyLoggedKey;
static char kApolloSubredditCellMarginsAppliedKey;
static char kApolloSubredditRowPolishAppliedKey;
static char kApolloSubredditOriginalSelectionStyleKey;
static char kApolloSubredditOriginalSelectedBackgroundKey;
static char kApolloSubredditOriginalMultipleSelectedBackgroundKey;
static char kApolloSubredditModernSelectionChromeAppliedKey;
static char kApolloSubredditModernPressOverlayKey;
// Flag-independent "this is the subreddit list" marker used only by the tap/selection highlight fix
// (#452). Distinct from kApolloSubredditIndexTableKey, which gates the enhancement styling suite.
static char kApolloSubredditSelectionTableKey;
static char kApolloSubredditHeaderSeparatorKey;
static char kApolloSubredditHeaderGradientLayerKey;
static char kApolloSubredditHeaderLoggedKey;
static char kApolloSubredditMultiredditsSectionKey;
static char kApolloSubredditMultiredditChildStyledKey;

static NSString * const ApolloSubredditIndexFavoriteSubredditsKey = @"FavoriteSubreddits";

static void (*orig_ApolloRedditListWillDisplayHeader)(id self, SEL _cmd, UITableView *tableView, UIView *view, NSInteger section) = NULL;
static void (*orig_ApolloRedditListWillDisplayCell)(id self, SEL _cmd, UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) = NULL;
static void (*orig_ApolloSubredditHeaderLayoutSubviews)(id self, SEL _cmd) = NULL;

static const CGFloat ApolloSubredditIndexSlotHeight = 14.0;
static const CGFloat ApolloSubredditIndexTouchWidth = 56.0;
static const CGFloat ApolloSubredditIndexGestureWidth = 34.0;
static const CGFloat ApolloSubredditIndexRightInset = 38.0;
static const CGFloat ApolloSubredditStarHitWidth = 60.0;
static const CGFloat ApolloSubredditRowBalancedLeadingMargin = 18.0;
static const CGFloat ApolloSubredditRowIconTextGap = 12.0;
static const CGFloat ApolloSubredditRowStandardIconTextTrim = 2.0;

static __unsafe_unretained UITableView *sApolloFavoriteMutationTable = nil;
static NSUInteger sApolloFavoriteMutationDepth = 0;
static NSInteger sApolloFavoriteMutationDeleteRow = NSNotFound;
static NSInteger sApolloFavoriteMutationOriginalLastRow = NSNotFound;

@class ApolloSubredditStarHitProxy;

@interface ApolloSubredditIndexOverlayView : UIView
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, strong) NSArray<UILabel *> *labels;
@property (nonatomic, strong) UISelectionFeedbackGenerator *selectionFeedbackGenerator;
@property (nonatomic) NSInteger activeIndex;
@property (nonatomic) NSInteger lastScrolledIndex;
- (void)apollo_applyThemeTintToLabels;
- (void)apollo_scheduleDeferredThemeTintRefresh;
- (void)updateWithTableView:(UITableView *)tableView titles:(NSArray<NSString *> *)titles;
@end

@interface ApolloSubredditStarHitProxy : UIControl
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic, weak) UITableViewCell *cell;
@property (nonatomic, weak) UIControl *nativeControl;
@property (nonatomic, copy) NSString *subredditName;
@end

static void ApolloSubredditIndexScheduleFavoritesRefresh(UITableView *tableView, UITableViewCell *cell, NSString *subredditName, UIControl *nativeControl);
static CGPoint ApolloSubredditIndexClampedContentOffset(UITableView *tableView, CGPoint requestedOffset);
static CGRect ApolloSubredditIndexProxyFrameForCell(UITableViewCell *cell, UIControl *nativeControl);
static void ApolloSubredditIndexApplyRedditListCellPolishOnce(UITableViewCell *cell, BOOL skipLeadingMarginClamp);
static void ApolloSubredditIndexPrepareCellForDisplay(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath);
static void ApolloSubredditIndexApplyMultiredditChildStyleIfNeeded(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath);

static UIViewController *ApolloSubredditIndexOwningViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

static UIColor *ApolloSubredditIndexThemeAccentColor(UITableView *tableView, UIView *fallbackView) {
    return ApolloThemeAccentColor() ?: fallbackView.tintColor ?: tableView.tintColor ?: [UIColor systemBlueColor];
}

static BOOL ApolloSubredditIndexColorIsVisible(UIColor *color) {
    if (![color isKindOfClass:[UIColor class]]) return NO;
    CGFloat alpha = CGColorGetAlpha(color.CGColor);
    return alpha > 0.01;
}

static UIColor *ApolloSubredditIndexThemeListBackgroundColor(UITableView *tableView, UIView *fallbackView) {
    UIViewController *viewController = ApolloSubredditIndexOwningViewController(tableView ?: fallbackView);
    NSMutableArray<UIColor *> *candidates = [NSMutableArray array];

    // Section headers stay transparent in modern mode; UITableView reveals its own
    // background in section gaps unless the table surface matches row cells.
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (cell.contentView.backgroundColor) [candidates addObject:cell.contentView.backgroundColor];
        if (cell.backgroundColor) [candidates addObject:cell.backgroundColor];
    }

    if (fallbackView.superview.backgroundColor) [candidates addObject:fallbackView.superview.backgroundColor];
    if (viewController.view.backgroundColor) [candidates addObject:viewController.view.backgroundColor];
    if (tableView.superview.backgroundColor) [candidates addObject:tableView.superview.backgroundColor];
    if (tableView.backgroundColor) [candidates addObject:tableView.backgroundColor];

    for (UIColor *color in candidates) {
        if (ApolloSubredditIndexColorIsVisible(color)) return color;
    }

    return [UIColor clearColor];
}

static BOOL ApolloSubredditIndexOwningTitleLooksLikeSubreddits(UITableView *tableView) {
    UIViewController *vc = ApolloSubredditIndexOwningViewController(tableView);
    NSString *title = vc.navigationItem.title ?: vc.title;
    return [title isEqualToString:@"Subreddits"];
}

static BOOL ApolloSubredditIndexShouldInspectTable(UITableView *tableView) {
    if (!tableView) return NO;
    if ([objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) return YES;
    return ApolloSubredditIndexOwningTitleLooksLikeSubreddits(tableView);
}

static NSArray<NSString *> *ApolloSubredditIndexTitlesForTable(UITableView *tableView) {
    id<UITableViewDataSource> dataSource = tableView.dataSource;
    if (!dataSource || ![dataSource respondsToSelector:@selector(sectionIndexTitlesForTableView:)]) return nil;

    NSArray *rawTitles = [dataSource sectionIndexTitlesForTableView:tableView];
    if (![rawTitles isKindOfClass:[NSArray class]] || rawTitles.count == 0) return nil;

    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithCapacity:rawTitles.count];
    for (id title in rawTitles) {
        if ([title isKindOfClass:[NSString class]] && [(NSString *)title length] > 0) {
            [titles addObject:title];
        }
    }
    return titles.count > 0 ? titles : nil;
}

static BOOL ApolloSubredditIndexLooksLikeSubredditsTable(UITableView *tableView, NSArray<NSString *> *titles) {
    if (!ApolloSubredditIndexOwningTitleLooksLikeSubreddits(tableView)) return NO;
    if (titles.count < 10) return NO;

    BOOL hasA = [titles containsObject:@"A"];
    BOOL hasZ = [titles containsObject:@"Z"];
    BOOL hasHash = [titles containsObject:@"#"];
    return hasA && (hasZ || hasHash);
}

static void ApolloSubredditIndexApplySeparatorInsets(UITableView *tableView) {
    UIEdgeInsets inset = tableView.separatorInset;
    if (inset.right < ApolloSubredditIndexRightInset) {
        inset.right = ApolloSubredditIndexRightInset;
        tableView.separatorInset = inset;
    }

    UITableViewCellSeparatorStyle separatorStyle = sModernSubredditDividers ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
    if (tableView.separatorStyle != separatorStyle) {
        tableView.separatorStyle = separatorStyle;
    }

    UIEdgeInsets margins = tableView.layoutMargins;
    if (margins.right < ApolloSubredditIndexRightInset) {
        margins.right = ApolloSubredditIndexRightInset;
        tableView.layoutMargins = margins;
    }
}

static void ApolloSubredditIndexHideNativeIndex(UITableView *tableView) {
    tableView.sectionIndexColor = [UIColor clearColor];
    tableView.sectionIndexBackgroundColor = [UIColor clearColor];
    tableView.sectionIndexTrackingBackgroundColor = [UIColor clearColor];
}

static UIColor *ApolloSubredditIndexResolvedColor(UIColor *color, UITraitCollection *traitCollection) {
    if (!color) return nil;
    if (@available(iOS 13.0, *)) {
        return [color resolvedColorWithTraitCollection:traitCollection ?: UIScreen.mainScreen.traitCollection];
    }
    return color;
}

static void ApolloSubredditIndexScrollToTitle(UITableView *tableView, NSString *title, NSInteger titleIndex) {
    if (!tableView || title.length == 0) return;

    NSInteger section = titleIndex;
    id<UITableViewDataSource> dataSource = tableView.dataSource;
    SEL sectionForTitle = @selector(tableView:sectionForSectionIndexTitle:atIndex:);
    if (dataSource && [dataSource respondsToSelector:sectionForTitle]) {
        section = ((NSInteger (*)(id, SEL, UITableView *, NSString *, NSInteger))objc_msgSend)(dataSource, sectionForTitle, tableView, title, titleIndex);
    }

    NSInteger sectionCount = [tableView numberOfSections];
    if (sectionCount <= 0) return;
    section = MIN(MAX(section, 0), sectionCount - 1);

    NSInteger rowCount = [tableView numberOfRowsInSection:section];
    if (rowCount > 0) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:section];
        [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionTop animated:NO];
    } else {
        CGRect sectionRect = [tableView rectForSection:section];
        if (!CGRectIsEmpty(sectionRect)) {
            [tableView scrollRectToVisible:sectionRect animated:NO];
        }
    }
    ApolloLog(@"[SubredditIndex] selected title=%@ section=%ld", title, (long)section);
}

static UITableView *ApolloSubredditIndexTableForCell(UITableViewCell *cell) {
    UIView *view = cell;
    while (view) {
        if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
        view = view.superview;
    }
    return nil;
}

static UITableViewCell *ApolloSubredditIndexCellForView(UIView *view) {
    while (view) {
        if ([view isKindOfClass:[UITableViewCell class]]) return (UITableViewCell *)view;
        view = view.superview;
    }
    return nil;
}

static Class ApolloSubredditIndexRedditListTableViewCellClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"_TtC6Apollo23RedditListTableViewCell");
    });
    return cls;
}

static UIControl *ApolloSubredditIndexRedditListAccessoryButton(UITableViewCell *cell) {
    static Ivar accessoryButtonIvar = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ApolloSubredditIndexRedditListTableViewCellClass();
        if (cls) accessoryButtonIvar = class_getInstanceVariable(cls, "accessoryButton");
    });

    Class cellClass = ApolloSubredditIndexRedditListTableViewCellClass();
    if (!accessoryButtonIvar || !cellClass || ![cell isKindOfClass:cellClass]) return nil;

    id value = object_getIvar(cell, accessoryButtonIvar);
    return [value isKindOfClass:[UIControl class]] ? (UIControl *)value : nil;
}

static NSArray<NSString *> *ApolloSubredditIndexFavoriteSubreddits(void) {
    NSArray *favorites = [[NSUserDefaults standardUserDefaults] stringArrayForKey:ApolloSubredditIndexFavoriteSubredditsKey];
    return [favorites isKindOfClass:[NSArray class]] ? favorites : @[];
}

static NSInteger ApolloSubredditIndexFavoriteRowForSubreddit(NSString *subredditName, NSArray<NSString *> *favorites) {
    if (subredditName.length == 0) return NSNotFound;

    NSUInteger exactIndex = [favorites indexOfObject:subredditName];
    if (exactIndex != NSNotFound) return (NSInteger)exactIndex;

    for (NSUInteger idx = 0; idx < favorites.count; idx++) {
        if ([favorites[idx] caseInsensitiveCompare:subredditName] == NSOrderedSame) {
            return (NSInteger)idx;
        }
    }
    return NSNotFound;
}

static void ApolloSubredditIndexBeginFavoriteMutation(UITableView *tableView, NSString *subredditName) {
    if (sApolloFavoriteMutationDepth > 0) {
        sApolloFavoriteMutationDepth++;
        return;
    }

    sApolloFavoriteMutationDepth = 1;
    sApolloFavoriteMutationTable = tableView;
    sApolloFavoriteMutationDeleteRow = NSNotFound;
    sApolloFavoriteMutationOriginalLastRow = NSNotFound;

    NSArray<NSString *> *favorites = ApolloSubredditIndexFavoriteSubreddits();
    NSInteger favoriteRow = ApolloSubredditIndexFavoriteRowForSubreddit(subredditName, favorites);
    if (favoriteRow == NSNotFound) return;

    sApolloFavoriteMutationDeleteRow = favoriteRow;
    sApolloFavoriteMutationOriginalLastRow = favorites.count > 0 ? (NSInteger)favorites.count - 1 : NSNotFound;
    ApolloLog(@"[SubredditIndex] favorite-mutation begin subreddit=%@ row=%ld nativeDeleteRow=%ld",
              subredditName ?: @"(unknown)",
              (long)sApolloFavoriteMutationDeleteRow,
              (long)sApolloFavoriteMutationOriginalLastRow);
}

static void ApolloSubredditIndexEndFavoriteMutation(void) {
    if (sApolloFavoriteMutationDepth == 0) return;

    sApolloFavoriteMutationDepth--;
    if (sApolloFavoriteMutationDepth > 0) return;

    sApolloFavoriteMutationTable = nil;
    sApolloFavoriteMutationDeleteRow = NSNotFound;
    sApolloFavoriteMutationOriginalLastRow = NSNotFound;
}

static NSArray<NSIndexPath *> *ApolloSubredditIndexCorrectedFavoriteDeleteIndexPaths(UITableView *tableView, NSArray<NSIndexPath *> *indexPaths) {
    if (sApolloFavoriteMutationDepth == 0 ||
        tableView != sApolloFavoriteMutationTable ||
        sApolloFavoriteMutationDeleteRow == NSNotFound ||
        indexPaths.count != 1) {
        return indexPaths;
    }

    NSIndexPath *indexPath = indexPaths.firstObject;
    if (indexPath.section != 1 || indexPath.row == sApolloFavoriteMutationDeleteRow) return indexPaths;

    NSIndexPath *corrected = [NSIndexPath indexPathForRow:sApolloFavoriteMutationDeleteRow inSection:indexPath.section];
    ApolloLog(@"[SubredditIndex] corrected favorite delete row native=%ld expectedLast=%ld corrected=%ld",
              (long)indexPath.row,
              (long)sApolloFavoriteMutationOriginalLastRow,
              (long)sApolloFavoriteMutationDeleteRow);
    return @[corrected];
}

static BOOL ApolloSubredditIndexStarControlFrameIsPlausible(UIControl *control, UITableViewCell *cell, CGRect *frameOut) {
    if (!control || !cell) return NO;

    CGRect frameInCell = [cell convertRect:control.bounds fromView:control];
    if (frameOut) *frameOut = frameInCell;
    if (CGRectIsEmpty(frameInCell) || CGRectIsNull(frameInCell) || !isfinite(CGRectGetMidX(frameInCell))) return NO;

    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat searchMinX = MAX(cellWidth - 140.0, cellWidth * 0.62);
    BOOL plausibleSize = CGRectGetWidth(frameInCell) <= 96.0 && CGRectGetHeight(frameInCell) <= 96.0;
    BOOL rightSide = CGRectGetMidX(frameInCell) >= searchMinX;
    return plausibleSize && rightSide;
}

static void ApolloSubredditIndexApplyCellMarginsOnce(UITableViewCell *cell) {
    if ([objc_getAssociatedObject(cell, &kApolloSubredditCellMarginsAppliedKey) boolValue]) return;

    UIEdgeInsets inset = cell.separatorInset;
    if (inset.right < ApolloSubredditIndexRightInset) {
        inset.right = ApolloSubredditIndexRightInset;
        cell.separatorInset = inset;
    }

    UIEdgeInsets margins = cell.layoutMargins;
    if (margins.right < ApolloSubredditIndexRightInset) {
        margins.right = ApolloSubredditIndexRightInset;
        cell.layoutMargins = margins;
    }

    objc_setAssociatedObject(cell, &kApolloSubredditCellMarginsAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL ApolloSubredditIndexStringLooksLikeSubredditName(NSString *string) {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;

    static NSSet<NSString *> *blocked;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blocked = [NSSet setWithArray:@[
            @"Home",
            @"Popular Posts",
            @"All Posts",
            @"Moderator Posts",
            @"Posts from subscriptions",
            @"Most popular posts across Reddit",
            @"Posts across all subreddits",
            @"Posts from moderated subreddits",
            @"FAVORITES",
            @"MODERATOR"
        ]];
    });
    if ([blocked containsObject:trimmed]) return NO;

    if (trimmed.length == 1) {
        unichar ch = [trimmed characterAtIndex:0];
        if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:ch]) return NO;
    }

    if ([trimmed rangeOfString:@"\n"].location != NSNotFound) return NO;
    if ([trimmed containsString:@"Posts from"] || [trimmed containsString:@"Posts across"] || [trimmed containsString:@"Most popular"]) return NO;
    return YES;
}

static BOOL ApolloSubredditIndexStringLooksLikeHeaderTitle(NSString *string) {
    NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;
    if ([trimmed isEqualToString:@"FAVORITES"] || [trimmed isEqualToString:@"MODERATOR"] || [trimmed isEqualToString:@"MULTIREDDITS"]) return YES;
    if (trimmed.length == 1) {
        unichar ch = [trimmed characterAtIndex:0];
        if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:ch]) return YES;
        if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:ch]) return YES;
        if (ch == '#') return YES;
    }
    return NO;
}

static UILabel *ApolloSubredditIndexHeaderLabelInView(UIView *view) {
    if (!view) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        if ([candidate isKindOfClass:[UILabel class]] && !candidate.hidden && candidate.alpha > 0.05) {
            UILabel *label = (UILabel *)candidate;
            if (ApolloSubredditIndexStringLooksLikeHeaderTitle(label.text)) return label;
        }

        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }
    return nil;
}

static BOOL ApolloSubredditIndexViewContainsView(UIView *container, UIView *target) {
    if (!container || !target) return NO;
    if (container == target) return YES;
    for (UIView *subview in container.subviews) {
        if (ApolloSubredditIndexViewContainsView(subview, target)) return YES;
    }
    return NO;
}

static void ApolloSubredditIndexClearHeaderBackgrounds(UIView *view, UILabel *labelToKeep) {
    if (view != labelToKeep) {
        view.backgroundColor = [UIColor clearColor];
        view.layer.backgroundColor = UIColor.clearColor.CGColor;
        view.opaque = NO;
        if ([view isKindOfClass:[UIVisualEffectView class]] && !ApolloSubredditIndexViewContainsView(view, labelToKeep)) {
            view.hidden = YES;
        }
    }
    for (UIView *subview in view.subviews) {
        ApolloSubredditIndexClearHeaderBackgrounds(subview, labelToKeep);
    }
}

static Class ApolloSubredditIndexTableHeaderFooterViewClass(void) {
    static Class cls = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cls = NSClassFromString(@"UITableViewHeaderFooterView");
    });
    return cls;
}

static void ApolloSubredditIndexClearHeaderChrome(UIView *header, UILabel *labelToKeep) {
    if (!header) return;

    ApolloSubredditIndexClearHeaderBackgrounds(header, labelToKeep);

    Class headerFooterClass = ApolloSubredditIndexTableHeaderFooterViewClass();
    if (headerFooterClass && [header isKindOfClass:headerFooterClass]) {
        UITableViewHeaderFooterView *headerFooter = (UITableViewHeaderFooterView *)header;
        if (!headerFooter.backgroundView) {
            UIView *clearBackground = [[UIView alloc] initWithFrame:CGRectZero];
            clearBackground.backgroundColor = [UIColor clearColor];
            clearBackground.opaque = NO;
            headerFooter.backgroundView = clearBackground;
        } else {
            headerFooter.backgroundView.backgroundColor = [UIColor clearColor];
            headerFooter.backgroundView.layer.backgroundColor = UIColor.clearColor.CGColor;
            headerFooter.backgroundView.opaque = NO;
        }
        headerFooter.contentView.backgroundColor = [UIColor clearColor];
        headerFooter.contentView.layer.backgroundColor = UIColor.clearColor.CGColor;
        headerFooter.contentView.opaque = NO;
        ApolloSubredditIndexClearHeaderBackgrounds(headerFooter.contentView, labelToKeep);
    }

    header.backgroundColor = [UIColor clearColor];
    header.layer.backgroundColor = UIColor.clearColor.CGColor;
    header.opaque = NO;
}

static UITableView *ApolloSubredditIndexTableForView(UIView *view) {
    while (view) {
        if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
        view = view.superview;
    }
    return nil;
}

static UILabel *ApolloSubredditIndexBestTitleLabelInView(UIView *view, UITableViewCell *cell) {
    if (!view || !cell) return nil;

    UILabel *bestLabel = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        if ([candidate isKindOfClass:[UILabel class]] && !candidate.hidden && candidate.alpha > 0.05) {
            UILabel *label = (UILabel *)candidate;
            NSString *text = label.text;
            if (ApolloSubredditIndexStringLooksLikeSubredditName(text)) {
                CGRect frameInCell = [cell convertRect:label.bounds fromView:label];
                CGFloat fontSize = label.font.pointSize;
                CGFloat width = CGRectGetWidth(frameInCell);
                CGFloat leftBonus = MAX(0.0, 180.0 - CGRectGetMinX(frameInCell)) / 18.0;
                CGFloat score = (fontSize * 4.0) + MIN(width, 220.0) / 20.0 + leftBonus;
                if (score > bestScore) {
                    bestScore = score;
                    bestLabel = label;
                }
            }
        }

        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }
    return bestLabel;
}

static NSString *ApolloSubredditIndexCellTitle(UITableViewCell *cell) {
    if (!cell) return nil;

    NSString *title = cell.textLabel.text;
    title = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (ApolloSubredditIndexStringLooksLikeSubredditName(title)) return title;

    UILabel *label = ApolloSubredditIndexBestTitleLabelInView(cell.contentView ?: cell, cell);
    title = [label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return title.length > 0 ? title : nil;
}

static UIControl *ApolloSubredditIndexFindStarControlInView(UIView *view, UITableViewCell *cell) {
    if (!view || !cell) return nil;

    UIControl *accessoryButton = ApolloSubredditIndexRedditListAccessoryButton(cell);
    if (accessoryButton &&
        !accessoryButton.hidden &&
        accessoryButton.alpha > 0.05 &&
        ApolloSubredditIndexStarControlFrameIsPlausible(accessoryButton, cell, NULL)) {
        return accessoryButton;
    }

    UIControl *best = nil;
    CGFloat bestX = -CGFLOAT_MAX;
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat searchMinX = MAX(cellWidth - 118.0, cellWidth * 0.68);

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        if ([candidate isKindOfClass:[UIControl class]] && ![candidate isKindOfClass:[ApolloSubredditStarHitProxy class]] && !candidate.hidden && candidate.alpha > 0.05) {
            CGRect frameInCell = CGRectZero;
            BOOL plausibleSize = ApolloSubredditIndexStarControlFrameIsPlausible((UIControl *)candidate, cell, &frameInCell);
            CGFloat midX = CGRectGetMidX(frameInCell);
            BOOL rightSide = midX >= searchMinX;
            if (plausibleSize && rightSide && midX > bestX) {
                best = (UIControl *)candidate;
                bestX = midX;
            }
        }

        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }

    return best;
}

static void ApolloSubredditIndexClearStarChrome(UIControl *control) {
    if (!control) return;

    control.highlighted = NO;
    control.backgroundColor = [UIColor clearColor];
    control.layer.backgroundColor = UIColor.clearColor.CGColor;
    [control cancelTrackingWithEvent:nil];

    if ([control isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)control;
        button.highlighted = NO;
        // Prevent auto-dimming on a button we don't own (no clean non-deprecated API for this).
        button.adjustsImageWhenHighlighted = NO;
        button.adjustsImageWhenDisabled = NO;

        UIControlState states[] = {
            UIControlStateNormal,
            UIControlStateHighlighted,
            UIControlStateSelected,
            UIControlStateDisabled,
            (UIControlStateSelected | UIControlStateHighlighted),
            (UIControlStateSelected | UIControlStateDisabled)
        };

        for (NSUInteger idx = 0; idx < sizeof(states) / sizeof(states[0]); idx++) {
            [button setBackgroundImage:nil forState:states[idx]];
        }
    }

    for (UIView *subview in control.subviews) {
        if (![subview isKindOfClass:[UIImageView class]]) {
            subview.backgroundColor = [UIColor clearColor];
            subview.layer.backgroundColor = UIColor.clearColor.CGColor;
        }
    }

    [control setNeedsLayout];
    [control setNeedsDisplay];
}

static CGRect ApolloSubredditIndexProxyFrameForCell(UITableViewCell *cell, UIControl *nativeControl) {
    CGFloat cellWidth = CGRectGetWidth(cell.bounds);
    CGFloat cellHeight = CGRectGetHeight(cell.bounds);
    CGFloat width = MIN(ApolloSubredditStarHitWidth, MAX(cellWidth, 0.0));

    if (!nativeControl) {
        return CGRectMake(MAX(cellWidth - width, 0.0), 0.0, width, cellHeight);
    }

    CGRect nativeFrame = [cell convertRect:nativeControl.bounds fromView:nativeControl];
    CGFloat minX = CGRectGetMidX(nativeFrame) - (width / 2.0);
    minX = MIN(MAX(minX, 0.0), MAX(cellWidth - width, 0.0));
    return CGRectMake(minX, 0.0, width, cellHeight);
}

static void ApolloSubredditIndexRemoveStarProxyFromCell(UITableViewCell *cell) {
    ApolloSubredditStarHitProxy *proxy = objc_getAssociatedObject(cell, &kApolloSubredditStarProxyKey);
    [proxy removeFromSuperview];
    objc_setAssociatedObject(cell, &kApolloSubredditStarProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@implementation ApolloSubredditStarHitProxy

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.exclusiveTouch = YES;
        [self addTarget:self action:@selector(apollo_starTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)apollo_starTapped {
    UIControl *nativeControl = self.nativeControl;
    UITableView *tableView = self.tableView;
    NSString *subredditName = self.subredditName;
    if (!nativeControl || !tableView) return;

    ApolloLog(@"[SubredditIndex] star-tap subreddit=%@", subredditName ?: @"(unknown)");

    // Capture the topmost-visible row's content + y-offset so we can
    // compensate for Apollo's synchronous favorites row insert/delete,
    // which otherwise shifts everything below the insertion point.
    NSString *anchorTitle = nil;
    NSInteger anchorSection = NSNotFound;
    CGFloat anchorDeltaY = 0.0;
    {
        CGFloat topY = tableView.contentOffset.y + tableView.adjustedContentInset.top;
        CGFloat bestMinY = CGFLOAT_MAX;
        for (UITableViewCell *visibleCell in tableView.visibleCells) {
            NSIndexPath *ip = [tableView indexPathForCell:visibleCell];
            if (!ip) continue;
            NSString *title = ApolloSubredditIndexCellTitle(visibleCell);
            if (title.length == 0) continue;
            CGRect rect = [tableView rectForRowAtIndexPath:ip];
            if (CGRectGetMaxY(rect) <= topY + 0.5) continue;
            if (CGRectGetMinY(rect) < bestMinY) {
                bestMinY = CGRectGetMinY(rect);
                anchorTitle = title;
                anchorSection = ip.section;
                anchorDeltaY = CGRectGetMinY(rect) - tableView.contentOffset.y;
            }
        }
    }

    [nativeControl sendActionsForControlEvents:UIControlEventTouchUpInside];

    if (anchorTitle.length > 0) {
        UITableViewCell *bestMatch = nil;
        UITableViewCell *sectionMatch = nil;
        for (UITableViewCell *visibleCell in tableView.visibleCells) {
            NSString *title = ApolloSubredditIndexCellTitle(visibleCell);
            if (![title isEqualToString:anchorTitle]) continue;
            if (!bestMatch) bestMatch = visibleCell;
            NSIndexPath *ip = [tableView indexPathForCell:visibleCell];
            if (ip && ip.section == anchorSection) {
                sectionMatch = visibleCell;
                break;
            }
        }
        UITableViewCell *match = sectionMatch ?: bestMatch;
        NSIndexPath *matchPath = match ? [tableView indexPathForCell:match] : nil;
        if (matchPath) {
            CGRect rect = [tableView rectForRowAtIndexPath:matchPath];
            CGPoint newOffset = CGPointMake(tableView.contentOffset.x, CGRectGetMinY(rect) - anchorDeltaY);
            [tableView setContentOffset:ApolloSubredditIndexClampedContentOffset(tableView, newOffset) animated:NO];
        }
    }

    ApolloSubredditIndexClearStarChrome(nativeControl);
}

@end

@implementation ApolloSubredditIndexOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.activeIndex = NSNotFound;
        self.lastScrolledIndex = NSNotFound;
        self.selectionFeedbackGenerator = [[UISelectionFeedbackGenerator alloc] init];
        self.userInteractionEnabled = YES;
        self.clipsToBounds = NO;
    }
    return self;
}

- (void)apollo_applyThemeTintToLabels {
    UIColor *accentColor = ApolloSubredditIndexThemeAccentColor(self.tableView, self);
    for (UILabel *label in self.labels) {
        label.textColor = accentColor;
    }
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self apollo_applyThemeTintToLabels];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self apollo_applyThemeTintToLabels];
    [self apollo_scheduleDeferredThemeTintRefresh];
}

- (void)apollo_scheduleDeferredThemeTintRefresh {
    __weak ApolloSubredditIndexOverlayView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloSubredditIndexOverlayView *strongSelf = weakSelf;
        [strongSelf apollo_applyThemeTintToLabels];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ApolloSubredditIndexOverlayView *strongSelf = weakSelf;
        [strongSelf apollo_applyThemeTintToLabels];
    });
}

- (void)updateWithTableView:(UITableView *)tableView titles:(NSArray<NSString *> *)titles {
    self.tableView = tableView;
    self.titles = titles ?: @[];
    self.backgroundColor = [UIColor clearColor];

    if (self.labels.count != self.titles.count) {
        for (UILabel *label in self.labels) {
            [label removeFromSuperview];
        }
        NSMutableArray<UILabel *> *labels = [NSMutableArray arrayWithCapacity:self.titles.count];
        for (NSString *title in self.titles) {
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
            label.text = title;
            label.textAlignment = NSTextAlignmentRight;
            label.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.65;
            label.layer.anchorPoint = CGPointMake(1.0, 0.5);
            [self addSubview:label];
            [labels addObject:label];
        }
        self.labels = labels;
    } else {
        [self.labels enumerateObjectsUsingBlock:^(UILabel *label, NSUInteger idx, BOOL *stop) {
            label.text = self.titles[idx];
        }];
    }

    [self apollo_applyThemeTintToLabels];
    [self apollo_scheduleDeferredThemeTintRefresh];
    [self setNeedsLayout];
    [self applyMagnificationForIndex:self.activeIndex animated:NO];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    NSUInteger count = self.labels.count;
    if (count == 0) return;

    CGFloat topInset = 4.0;
    CGFloat bottomInset = 4.0;
    CGFloat availableHeight = MAX(self.bounds.size.height - topInset - bottomInset, 1.0);
    CGFloat slotHeight = availableHeight / count;
    CGFloat labelHeight = MIN(MAX(slotHeight, 10.0), 16.0);

    [self.labels enumerateObjectsUsingBlock:^(UILabel *label, NSUInteger idx, BOOL *stop) {
        CGFloat centerY = topInset + (slotHeight * idx) + (slotHeight / 2.0);
        label.bounds = CGRectMake(0.0, 0.0, 30.0, labelHeight);
        label.center = CGPointMake(CGRectGetMaxX(self.bounds) - 2.0, centerY);
    }];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (![super pointInside:point withEvent:event]) return NO;
    return point.x >= CGRectGetWidth(self.bounds) - ApolloSubredditIndexGestureWidth;
}

- (NSInteger)indexForTouch:(UITouch *)touch {
    if (self.titles.count == 0) return NSNotFound;
    CGPoint point = [touch locationInView:self];
    CGFloat topInset = 4.0;
    CGFloat bottomInset = 4.0;
    CGFloat availableHeight = MAX(self.bounds.size.height - topInset - bottomInset, 1.0);
    CGFloat clampedY = MIN(MAX(point.y - topInset, 0.0), availableHeight - 0.01);
    NSInteger index = (NSInteger)floor((clampedY / availableHeight) * self.titles.count);
    return MIN(MAX(index, 0), (NSInteger)self.titles.count - 1);
}

- (void)applyMagnificationForIndex:(NSInteger)index animated:(BOOL)animated {
    void (^changes)(void) = ^{
        [self.labels enumerateObjectsUsingBlock:^(UILabel *label, NSUInteger idx, BOOL *stop) {
            CGFloat distance = index == NSNotFound ? CGFLOAT_MAX : fabs((CGFloat)((NSInteger)idx - index));
            CGFloat scale = 1.0;
            CGFloat translateX = 0.0;
            if (distance == 0.0) {
                scale = sModernSubredditDividers ? 3.75 : 2.90;
                translateX = sModernSubredditDividers ? -38.0 : -27.0;
            } else if (distance == 1.0) {
                scale = sModernSubredditDividers ? 2.35 : 1.85;
                translateX = sModernSubredditDividers ? -23.0 : -16.0;
            } else if (distance == 2.0) {
                scale = sModernSubredditDividers ? 1.60 : 1.38;
                translateX = sModernSubredditDividers ? -10.0 : -7.0;
            }
            CGAffineTransform transform = CGAffineTransformMakeTranslation(translateX, 0.0);
            label.transform = CGAffineTransformScale(transform, scale, scale);
            label.alpha = index == NSNotFound ? 1.0 : (distance <= 2.0 ? 1.0 : 0.72);
        }];
    };

    if (animated) {
        [UIView animateWithDuration:0.08
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)handleTouch:(UITouch *)touch {
    NSInteger index = [self indexForTouch:touch];
    if (index == NSNotFound || index >= (NSInteger)self.titles.count) return;

    self.activeIndex = index;
    [self applyMagnificationForIndex:index animated:YES];
    if (self.lastScrolledIndex == index) return;
    self.lastScrolledIndex = index;
    [self.selectionFeedbackGenerator selectionChanged];
    [self.selectionFeedbackGenerator prepare];
    ApolloSubredditIndexScrollToTitle(self.tableView, self.titles[index], index);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    [self.selectionFeedbackGenerator prepare];
    if (touch) [self handleTouch:touch];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (touch) [self handleTouch:touch];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.activeIndex = NSNotFound;
    self.lastScrolledIndex = NSNotFound;
    [self applyMagnificationForIndex:NSNotFound animated:YES];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.activeIndex = NSNotFound;
    self.lastScrolledIndex = NSNotFound;
    [self applyMagnificationForIndex:NSNotFound animated:YES];
}

@end

static CGPoint ApolloSubredditIndexClampedContentOffset(UITableView *tableView, CGPoint requestedOffset) {
    CGFloat minY = -tableView.adjustedContentInset.top;
    CGFloat maxY = MAX(minY, tableView.contentSize.height - CGRectGetHeight(tableView.bounds) + tableView.adjustedContentInset.bottom);
    requestedOffset.y = MIN(MAX(requestedOffset.y, minY), maxY);
    return requestedOffset;
}

static NSInteger ApolloSubredditIndexSectionForIndexTitle(UITableView *tableView, NSString *title) {
    NSArray<NSString *> *titles = ApolloSubredditIndexTitlesForTable(tableView);
    NSInteger titleIndex = [titles indexOfObject:title];
    if (titleIndex == NSNotFound) return NSNotFound;

    NSInteger section = titleIndex;
    id<UITableViewDataSource> dataSource = tableView.dataSource;
    SEL sectionForTitle = @selector(tableView:sectionForSectionIndexTitle:atIndex:);
    if (dataSource && [dataSource respondsToSelector:sectionForTitle]) {
        section = ((NSInteger (*)(id, SEL, UITableView *, NSString *, NSInteger))objc_msgSend)(dataSource, sectionForTitle, tableView, title, titleIndex);
    }
    return section;
}

static BOOL ApolloSubredditIndexCellIsInFavoritesSection(UITableViewCell *cell, UITableView *tableView) {
    if (!cell || !tableView) return NO;
    NSIndexPath *indexPath = [tableView indexPathForCell:cell];
    if (!indexPath) return NO;
    NSInteger favoritesSection = ApolloSubredditIndexSectionForIndexTitle(tableView, @"★");
    return favoritesSection != NSNotFound && indexPath.section == favoritesSection;
}

static NSDictionary *ApolloSubredditIndexCaptureScrollAnchor(UITableView *tableView) {
    NSIndexPath *indexPath = tableView.indexPathsForVisibleRows.firstObject;
    if (!indexPath) return @{@"offset": [NSValue valueWithCGPoint:tableView.contentOffset]};

    CGRect rect = [tableView rectForRowAtIndexPath:indexPath];
    CGFloat delta = tableView.contentOffset.y - CGRectGetMinY(rect);
    return @{
        @"indexPath": indexPath,
        @"delta": @(delta),
        @"offset": [NSValue valueWithCGPoint:tableView.contentOffset]
    };
}

static void ApolloSubredditIndexRestoreScrollAnchor(UITableView *tableView, NSDictionary *anchor) {
    NSIndexPath *indexPath = anchor[@"indexPath"];
    NSNumber *deltaNumber = anchor[@"delta"];
    if (indexPath &&
        indexPath.section < [tableView numberOfSections] &&
        indexPath.row < [tableView numberOfRowsInSection:indexPath.section]) {
        CGRect rect = [tableView rectForRowAtIndexPath:indexPath];
        CGPoint offset = CGPointMake(tableView.contentOffset.x, CGRectGetMinY(rect) + deltaNumber.doubleValue);
        [tableView setContentOffset:ApolloSubredditIndexClampedContentOffset(tableView, offset) animated:NO];
        return;
    }

    NSValue *offsetValue = anchor[@"offset"];
    if (offsetValue) {
        [tableView setContentOffset:ApolloSubredditIndexClampedContentOffset(tableView, offsetValue.CGPointValue) animated:NO];
    }
}

static void ApolloSubredditIndexCleanVisibleStarChrome(UITableView *tableView, NSString *subredditName) {
    if (!tableView) return;
    if (tableView.editing) return;

    for (UITableViewCell *cell in tableView.visibleCells) {
        if (subredditName.length > 0) {
            NSString *cellTitle = ApolloSubredditIndexCellTitle(cell);
            if (![cellTitle isEqualToString:subredditName]) continue;
        }

        UIControl *control = ApolloSubredditIndexFindStarControlInView(cell, cell);
        ApolloSubredditIndexClearStarChrome(control);
    }
}

static BOOL ApolloSubredditIndexVisibleContainsSubredditName(UITableView *tableView, NSString *subredditName) {
    if (!tableView || subredditName.length == 0) return NO;
    for (UITableViewCell *cell in tableView.visibleCells) {
        if ([ApolloSubredditIndexCellTitle(cell) isEqualToString:subredditName]) return YES;
    }
    return NO;
}

static NSArray<NSIndexPath *> *ApolloSubredditIndexVisibleIndexPathsForSubredditName(UITableView *tableView, NSString *subredditName) {
    if (!tableView || subredditName.length == 0) return @[];

    NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray array];
    for (UITableViewCell *cell in tableView.visibleCells) {
        if (![ApolloSubredditIndexCellTitle(cell) isEqualToString:subredditName]) continue;

        NSIndexPath *indexPath = [tableView indexPathForCell:cell];
        if (!indexPath) continue;
        if (indexPath.section >= [tableView numberOfSections]) continue;
        if (indexPath.row >= [tableView numberOfRowsInSection:indexPath.section]) continue;

        [indexPaths addObject:indexPath];
    }
    return indexPaths;
}

static void ApolloSubredditIndexRefreshFavorites(UITableView *tableView, NSString *subredditName, NSString *reason, BOOL shouldReload) {
    if (!tableView) return;

    NSArray<NSIndexPath *> *matchingVisibleRows = ApolloSubredditIndexVisibleIndexPathsForSubredditName(tableView, subredditName);
    BOOL reloadNeeded = shouldReload || !ApolloSubredditIndexVisibleContainsSubredditName(tableView, subredditName);
    BOOL rowReloaded = !reloadNeeded && matchingVisibleRows.count > 0;
    NSDictionary *anchor = (rowReloaded || reloadNeeded) ? ApolloSubredditIndexCaptureScrollAnchor(tableView) : nil;

    if (rowReloaded) {
        [UIView performWithoutAnimation:^{
            [tableView reloadRowsAtIndexPaths:matchingVisibleRows withRowAnimation:UITableViewRowAnimationNone];
            [tableView layoutIfNeeded];
            ApolloSubredditIndexRestoreScrollAnchor(tableView, anchor);
        }];
    } else if (reloadNeeded) {
        [UIView performWithoutAnimation:^{
            [tableView reloadData];
            [tableView layoutIfNeeded];
            ApolloSubredditIndexRestoreScrollAnchor(tableView, anchor);
        }];
    } else {
        for (UITableViewCell *cell in tableView.visibleCells) {
            [cell setNeedsLayout];
        }
    }

    ApolloSubredditIndexCleanVisibleStarChrome(tableView, nil);

    ApolloLog(@"[SubredditIndex] favorites-refresh reason=%@ subreddit=%@ rowReload=%lu fullReload=%d",
              reason ?: @"unknown",
              subredditName ?: @"(unknown)",
              (unsigned long)matchingVisibleRows.count,
              reloadNeeded);
}

static void ApolloSubredditIndexScheduleFavoritesRefresh(UITableView *tableView, UITableViewCell *cell, NSString *subredditName, UIControl *nativeControl) {
    if (!sSubredditListEnhancements) return;
    __weak UITableView *weakTable = tableView;
    __weak UIControl *weakControl = nativeControl;
    NSString *name = [subredditName copy];
    BOOL tappedFavoritesRow = ApolloSubredditIndexCellIsInFavoritesSection(cell, tableView);

    NSTimeInterval delay = 0.30;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableView *strongTable = weakTable;
        if (!strongTable) return;

        UIControl *strongControl = weakControl;
        if (strongControl && strongControl.superview) {
            ApolloSubredditIndexClearStarChrome(strongControl);
        }
        ApolloSubredditIndexRefreshFavorites(strongTable, name, [NSString stringWithFormat:@"star-delay-%.2f", delay], tappedFavoritesRow);
    });
}

static void ApolloSubredditIndexInstallStarProxyForCell(UITableViewCell *cell, UITableView *tableView) {
    if (!cell || !tableView) return;

    if (tableView.editing || cell.editing) {
        // In edit mode Apollo's reorder grip lives in the same right-side area.
        // Let the native reorder gesture win instead of covering it with our
        // larger transparent star hit target.
        ApolloSubredditIndexRemoveStarProxyFromCell(cell);
        return;
    }

    UIControl *nativeControl = ApolloSubredditIndexFindStarControlInView(cell, cell);
    ApolloSubredditStarHitProxy *proxy = objc_getAssociatedObject(cell, &kApolloSubredditStarProxyKey);
    if (!nativeControl) {
        ApolloSubredditIndexRemoveStarProxyFromCell(cell);
        return;
    }

    if (!proxy) {
        proxy = [[ApolloSubredditStarHitProxy alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(cell, &kApolloSubredditStarProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell addSubview:proxy];
    }

    proxy.tableView = tableView;
    proxy.cell = cell;
    proxy.nativeControl = nativeControl;
    proxy.subredditName = ApolloSubredditIndexCellTitle(cell);
    proxy.frame = ApolloSubredditIndexProxyFrameForCell(cell, nativeControl);
    ApolloSubredditIndexClearStarChrome(nativeControl);
    [cell bringSubviewToFront:proxy];

    if (![objc_getAssociatedObject(cell, &kApolloSubredditStarProxyLoggedKey) boolValue]) {
        objc_setAssociatedObject(cell, &kApolloSubredditStarProxyLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SubredditIndex] star-proxy-installed subreddit=%@ frame=%@ native=%@",
                  proxy.subredditName ?: @"(unknown)",
                  NSStringFromCGRect(proxy.frame),
                  NSStringFromClass([nativeControl class]));
    }
}

static void ApolloSubredditIndexInstallOrUpdate(UITableView *tableView) {
    if (!sSubredditListEnhancements) return;
    if (!ApolloSubredditIndexShouldInspectTable(tableView)) return;

    NSArray<NSString *> *titles = ApolloSubredditIndexTitlesForTable(tableView);
    if (!ApolloSubredditIndexLooksLikeSubredditsTable(tableView, titles)) return;

    objc_setAssociatedObject(tableView, &kApolloSubredditIndexTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ApolloSubredditIndexApplySeparatorInsets(tableView);
    // NB: deliberately do NOT colour the table's scroll-view background here. On iOS 26 any opaque
    // UIScrollView background flips the nav bar to its glass / content-reflecting appearance, which
    // mirrors the selected Home row across the whole header (#450). The gaps that transparent modern
    // section headers would leave are instead filled by each header's own opaque backgroundColor in
    // ApolloSubredditIndexStyleHeaderView, so the scroll view stays transparent.
    ApolloSubredditIndexHideNativeIndex(tableView);

    UIView *container = tableView.superview ?: tableView;
    ApolloSubredditIndexOverlayView *overlay = objc_getAssociatedObject(tableView, &kApolloSubredditIndexOverlayKey);
    if (!overlay) {
        overlay = [[ApolloSubredditIndexOverlayView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(tableView, &kApolloSubredditIndexOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:overlay];
    } else if (overlay.superview != container) {
        [overlay removeFromSuperview];
        [container addSubview:overlay];
    }

    CGRect tableFrame = [container convertRect:tableView.bounds fromView:tableView];
    CGFloat width = ApolloSubredditIndexTouchWidth;
    CGFloat rightPadding = 1.0;
    CGFloat visibleTop = CGRectGetMinY(tableFrame) + tableView.adjustedContentInset.top + 4.0;
    CGFloat visibleHeight = MAX(CGRectGetHeight(tableFrame) - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom - 8.0, 44.0);
    CGFloat desiredHeight = MIN(MAX(titles.count * ApolloSubredditIndexSlotHeight + 8.0, 240.0), visibleHeight);
    CGFloat originY = visibleTop + ((visibleHeight - desiredHeight) / 2.0);
    CGRect overlayFrame = CGRectMake(CGRectGetMaxX(tableFrame) - width - rightPadding,
                                     originY,
                                     width,
                                     desiredHeight);
    if (!CGRectEqualToRect(overlay.frame, overlayFrame)) {
        overlay.frame = overlayFrame;
    }
    [container bringSubviewToFront:overlay];
    if (overlay.tableView != tableView || ![overlay.titles isEqualToArray:titles] || overlay.labels.count != titles.count) {
        [overlay updateWithTableView:tableView titles:titles];
    } else {
        [overlay apollo_applyThemeTintToLabels];
    }

    if (![objc_getAssociatedObject(tableView, &kApolloSubredditIndexLoggedKey) boolValue]) {
        objc_setAssociatedObject(tableView, &kApolloSubredditIndexLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SubredditIndex] installed titles=%lu table=%@ vc=%@",
                  (unsigned long)titles.count,
                  tableView,
                  NSStringFromClass([ApolloSubredditIndexOwningViewController(tableView) class]));
    }
}

static void ApolloSubredditIndexRefreshTablesInView(UIView *view) {
    if (!sSubredditListEnhancements) return;
    if (!view) return;

    if ([view isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)view;
        if (ApolloSubredditIndexShouldInspectTable(tableView)) {
            NSArray<NSString *> *titles = ApolloSubredditIndexTitlesForTable(tableView);
            BOOL isSubredditTable = ApolloSubredditIndexLooksLikeSubredditsTable(tableView, titles);
            if (isSubredditTable) {
                objc_setAssociatedObject(tableView, &kApolloSubredditIndexTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSDictionary *anchor = ApolloSubredditIndexCaptureScrollAnchor(tableView);
                ApolloSubredditIndexApplySeparatorInsets(tableView);
                [UIView performWithoutAnimation:^{
                    [tableView reloadData];
                    [tableView layoutIfNeeded];
                    ApolloSubredditIndexInstallOrUpdate(tableView);
                    ApolloSubredditIndexRestoreScrollAnchor(tableView, anchor);
                }];
            }
        }
    }

    for (UIView *subview in view.subviews) {
        ApolloSubredditIndexRefreshTablesInView(subview);
    }
}

static void ApolloSubredditIndexRefreshAllVisibleTables(void) {
    for (UIWindow *window in ApolloAllWindows()) {
        ApolloSubredditIndexRefreshTablesInView(window);
    }
}

static BOOL ApolloSubredditIndexEnsureSubredditTable(UITableView *tableView) {
    if (!sSubredditListEnhancements) return NO;
    if (!tableView) return NO;
    if ([objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) return YES;
    if (!ApolloSubredditIndexShouldInspectTable(tableView)) return NO;

    NSArray<NSString *> *titles = ApolloSubredditIndexTitlesForTable(tableView);
    if (!ApolloSubredditIndexLooksLikeSubredditsTable(tableView, titles)) return NO;

    objc_setAssociatedObject(tableView, &kApolloSubredditIndexTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Identifies the subreddit list purely by structure (owning title + a large A–Z section index),
// independent of sSubredditListEnhancements / sModernSubredditDividers. This lets the tap/selection
// highlight (#452) run in every mode — including "classic" (enhancements off) — while the rest of the
// enhancement styling stays gated on kApolloSubredditIndexTableKey. Deliberately does NOT set that
// enhancement key; it only caches its own kApolloSubredditSelectionTableKey.
static BOOL ApolloSubredditIndexEnsureSelectionTable(UITableView *tableView) {
    if (!tableView) return NO;
    if ([objc_getAssociatedObject(tableView, &kApolloSubredditSelectionTableKey) boolValue]) return YES;
    // If the enhancement suite already recognised this table, inherit that verdict.
    if ([objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) {
        objc_setAssociatedObject(tableView, &kApolloSubredditSelectionTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    if (!ApolloSubredditIndexShouldInspectTable(tableView)) return NO;
    NSArray<NSString *> *titles = ApolloSubredditIndexTitlesForTable(tableView);
    if (!ApolloSubredditIndexLooksLikeSubredditsTable(tableView, titles)) return NO;
    objc_setAssociatedObject(tableView, &kApolloSubredditSelectionTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Cheap O(1) gate for the app-wide -[UITableViewCell setHighlighted:]/setSelected: hooks: only act on
// tables we've ALREADY recognised as the subreddit list. The recognition (and the one-time structural
// detection it needs) happens in the scoped willDisplayCell / layoutSubviews passes, which always run
// before a row can be tapped — so by press time a subreddit table already carries one of these keys.
// This keeps every cell tap elsewhere in the app from triggering a responder-chain walk + title compare.
static BOOL ApolloSubredditIndexTableAlreadyRecognised(UITableView *tableView) {
    if (!tableView) return NO;
    return [objc_getAssociatedObject(tableView, &kApolloSubredditSelectionTableKey) boolValue] ||
           [objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue];
}

static UIView *ApolloSubredditIndexModernSelectionBackground(UITableView *tableView, UITableViewCell *cell) {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.userInteractionEnabled = NO;
    view.opaque = NO;
    UIColor *accentColor = ApolloSubredditIndexThemeAccentColor(tableView, cell);
    UIColor *overlayColor = [accentColor colorWithAlphaComponent:0.10];
    view.backgroundColor = overlayColor;
    view.layer.backgroundColor = overlayColor.CGColor;
    view.layer.borderWidth = 0.0;
    view.layer.shadowOpacity = 0.0;
    view.layer.sublayers = nil;
    return view;
}

static void ApolloSubredditIndexRemoveModernPressOverlay(UITableViewCell *cell) {
    UIView *overlay = objc_getAssociatedObject(cell, &kApolloSubredditModernPressOverlayKey);
    [overlay removeFromSuperview];
    objc_setAssociatedObject(cell, &kApolloSubredditModernPressOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *ApolloSubredditIndexModernPressOverlay(UITableView *tableView, UITableViewCell *cell) {
    UIView *container = cell.contentView ?: (UIView *)cell;
    UIView *overlay = objc_getAssociatedObject(cell, &kApolloSubredditModernPressOverlayKey);
    if (!overlay || overlay.superview != container) {
        [overlay removeFromSuperview];
        overlay = [[UIView alloc] initWithFrame:container.bounds];
        overlay.userInteractionEnabled = NO;
        overlay.opaque = NO;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.alpha = 0.0;
        overlay.layer.borderWidth = 0.0;
        overlay.layer.shadowOpacity = 0.0;
        objc_setAssociatedObject(cell, &kApolloSubredditModernPressOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container insertSubview:overlay atIndex:0];
    }

    UIColor *accentColor = ApolloSubredditIndexThemeAccentColor(tableView, cell);
    UIColor *overlayColor = [accentColor colorWithAlphaComponent:0.16];
    overlay.frame = container.bounds;
    overlay.backgroundColor = overlayColor;
    overlay.layer.backgroundColor = overlayColor.CGColor;
    overlay.layer.borderWidth = 0.0;
    [container sendSubviewToBack:overlay];
    return overlay;
}

static void ApolloSubredditIndexSetModernPressOverlayVisible(UITableViewCell *cell, UITableView *tableView, BOOL visible, BOOL animated) {
    if (!cell) return;
    if (!tableView || !ApolloSubredditIndexEnsureSelectionTable(tableView)) {
        ApolloSubredditIndexRemoveModernPressOverlay(cell);
        return;
    }

    UIView *overlay = ApolloSubredditIndexModernPressOverlay(tableView, cell);
    CGFloat targetAlpha = visible ? 1.0 : 0.0;
    void (^changes)(void) = ^{
        overlay.alpha = targetAlpha;
    };
    if (animated) {
        [UIView animateWithDuration:(visible ? 0.06 : 0.16)
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

static void ApolloSubredditIndexRestoreCellSelectionChrome(UITableViewCell *cell) {
    ApolloSubredditIndexRemoveModernPressOverlay(cell);
    if (![objc_getAssociatedObject(cell, &kApolloSubredditModernSelectionChromeAppliedKey) boolValue]) return;

    NSNumber *originalStyle = objc_getAssociatedObject(cell, &kApolloSubredditOriginalSelectionStyleKey);
    UIView *originalSelectedBackground = objc_getAssociatedObject(cell, &kApolloSubredditOriginalSelectedBackgroundKey);
    UIView *originalMultipleSelectedBackground = objc_getAssociatedObject(cell, &kApolloSubredditOriginalMultipleSelectedBackgroundKey);
    if ([originalStyle respondsToSelector:@selector(integerValue)]) {
        cell.selectionStyle = (UITableViewCellSelectionStyle)originalStyle.integerValue;
    }
    cell.selectedBackgroundView = originalSelectedBackground;
    cell.multipleSelectionBackgroundView = originalMultipleSelectedBackground;

    objc_setAssociatedObject(cell, &kApolloSubredditOriginalSelectionStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloSubredditOriginalSelectedBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloSubredditOriginalMultipleSelectedBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kApolloSubredditModernSelectionChromeAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloSubredditIndexApplyCellSelectionChrome(UITableViewCell *cell, UITableView *tableView) {
    if (!cell || !tableView || !ApolloSubredditIndexEnsureSelectionTable(tableView)) return;

    // Separator style belongs to the enhancement/divider suite — only touch it when that suite owns
    // this table. In classic mode we leave Apollo's native separators untouched.
    if (ApolloSubredditIndexEnsureSubredditTable(tableView)) {
        UITableViewCellSeparatorStyle separatorStyle = sModernSubredditDividers ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
        if (tableView.separatorStyle != separatorStyle) {
            tableView.separatorStyle = separatorStyle;
        }
    }

    // Tap/selection highlight (#452). Apollo's native subreddit rows don't paint a visible selected
    // background under Liquid Glass — their opaque cell background covers it — so we install our own
    // selected background plus an in-contentView press overlay. This is a bug fix, so it runs in every
    // mode, not just when Modern Subreddit Dividers is on. The enhancement toggles only govern the
    // surrounding styling (separators, headers, custom index), handled elsewhere.
    BOOL appliedModernChrome = [objc_getAssociatedObject(cell, &kApolloSubredditModernSelectionChromeAppliedKey) boolValue];
    if (!appliedModernChrome) {
        objc_setAssociatedObject(cell, &kApolloSubredditOriginalSelectionStyleKey, @(cell.selectionStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kApolloSubredditOriginalSelectedBackgroundKey, cell.selectedBackgroundView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kApolloSubredditOriginalMultipleSelectedBackgroundKey, cell.multipleSelectionBackgroundView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kApolloSubredditModernSelectionChromeAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.selectedBackgroundView = ApolloSubredditIndexModernSelectionBackground(tableView, cell);
    cell.multipleSelectionBackgroundView = ApolloSubredditIndexModernSelectionBackground(tableView, cell);
    cell.backgroundView.layer.borderWidth = 0.0;
    cell.selectedBackgroundView.layer.borderWidth = 0.0;
    cell.multipleSelectionBackgroundView.layer.borderWidth = 0.0;
    ApolloSubredditIndexSetModernPressOverlayVisible(cell, tableView, cell.highlighted || cell.selected, NO);
}

static void ApolloSubredditIndexApplyModernPressedCellSelectionChrome(UITableViewCell *cell) {
    if (!cell) return;
    UITableView *tableView = ApolloSubredditIndexTableForCell(cell);
    if (!ApolloSubredditIndexEnsureSelectionTable(tableView)) return;

    ApolloSubredditIndexApplyCellSelectionChrome(cell, tableView);
    ApolloSubredditIndexSetModernPressOverlayVisible(cell, tableView, cell.highlighted || cell.selected, NO);
}

static NSInteger ApolloSubredditIndexMultiredditsSection(UITableView *tableView) {
    if (!tableView) return NSNotFound;
    NSNumber *section = objc_getAssociatedObject(tableView, &kApolloSubredditMultiredditsSectionKey);
    return section ? section.integerValue : NSNotFound;
}

static void ApolloSubredditIndexTrackMultiredditsSection(UITableView *tableView, UIView *headerView, NSInteger section) {
    if (!sSubredditListEnhancements) return;
    if (!tableView || !headerView) return;

    UILabel *label = ApolloSubredditIndexHeaderLabelInView(headerView);
    if (!label) return;

    NSString *text = [[label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([text isEqualToString:@"MULTIREDDITS"]) {
        objc_setAssociatedObject(tableView, &kApolloSubredditMultiredditsSectionKey, @(section), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL ApolloSubredditIndexViewLooksLikeMultiredditChildLine(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05) return NO;
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UIImageView class]] || [view isKindOfClass:[UIControl class]]) {
        return NO;
    }

    CGRect frame = view.bounds;
    if (frame.size.width <= 0.0 || frame.size.height <= 0.0) return NO;
    if (CGRectGetWidth(frame) > 4.0 || CGRectGetHeight(frame) < 20.0) return NO;
    return YES;
}

static BOOL ApolloSubredditIndexViewIsMultiredditChildLine(UIView *candidate, UIView *contentView) {
    if (!ApolloSubredditIndexViewLooksLikeMultiredditChildLine(candidate)) return NO;

    CGRect frameInContent = [contentView convertRect:candidate.bounds fromView:candidate];
    if (CGRectGetMinX(frameInContent) > 36.0) return NO;
    return YES;
}

static UIView *ApolloSubredditIndexMultiredditChildLineView(UITableViewCell *cell) {
    if (!cell) return nil;

    UIView *contentView = cell.contentView;
    if (!contentView) return nil;

    UIView *bestLine = nil;
    CGFloat bestHeight = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:contentView];
    while (stack.count > 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];

        if (ApolloSubredditIndexViewIsMultiredditChildLine(candidate, contentView)) {
            CGFloat height = CGRectGetHeight([contentView convertRect:candidate.bounds fromView:candidate]);
            if (height > bestHeight) {
                bestLine = candidate;
                bestHeight = height;
            }
        }

        for (UIView *subview in candidate.subviews) {
            [stack addObject:subview];
        }
    }

    return bestLine;
}

static BOOL ApolloSubredditIndexCellIsMultiredditChild(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (!sModernSubredditDividers || !tableView || !cell || !indexPath) return NO;

    NSInteger multiredditsSection = ApolloSubredditIndexMultiredditsSection(tableView);
    if (multiredditsSection == NSNotFound || indexPath.section != multiredditsSection) return NO;

    return ApolloSubredditIndexMultiredditChildLineView(cell) != nil;
}

static void ApolloSubredditIndexClearMultiredditChildBackgroundInView(UIView *view, UIView *lineView, UILabel *labelToKeep) {
    if (!view) return;
    if (view == lineView) return;
    if ([view isKindOfClass:[UIImageView class]]) return;
    if ([view isKindOfClass:[UILabel class]] && view != labelToKeep) return;

    view.backgroundColor = [UIColor clearColor];
    view.layer.backgroundColor = UIColor.clearColor.CGColor;
    view.opaque = NO;

    for (UIView *subview in view.subviews) {
        if (subview == lineView) continue;
        ApolloSubredditIndexClearMultiredditChildBackgroundInView(subview, lineView, labelToKeep);
    }
}

static void ApolloSubredditIndexApplyMultiredditChildStyle(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (!ApolloSubredditIndexCellIsMultiredditChild(tableView, cell, indexPath)) return;

    UIView *lineView = ApolloSubredditIndexMultiredditChildLineView(cell);
    if (!lineView) return;

    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.opaque = NO;
    if (cell.backgroundView) {
        cell.backgroundView.backgroundColor = [UIColor clearColor];
        cell.backgroundView.opaque = NO;
    }

    ApolloSubredditIndexClearMultiredditChildBackgroundInView(cell.contentView, lineView, nil);

    UIColor *accentColor = ApolloSubredditIndexThemeAccentColor(tableView, cell);
    UIColor *resolvedAccent = ApolloSubredditIndexResolvedColor(accentColor, cell.traitCollection);
    UIColor *lineColor = [resolvedAccent colorWithAlphaComponent:0.82];
    lineView.backgroundColor = lineColor;
    lineView.layer.backgroundColor = lineColor.CGColor;
    lineView.opaque = YES;

    objc_setAssociatedObject(cell, &kApolloSubredditMultiredditChildStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ApolloSubredditIndexApplyMultiredditChildStyleIfNeeded(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (!tableView || !cell) return;
    if (!indexPath) indexPath = [tableView indexPathForCell:cell];
    if (!indexPath) return;
    ApolloSubredditIndexApplyMultiredditChildStyle(tableView, cell, indexPath);
}

static void ApolloSubredditIndexPrepareCellForDisplay(UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (!cell || !ApolloSubredditIndexEnsureSubredditTable(tableView)) return;

    ApolloSubredditIndexApplySeparatorInsets(tableView);
    ApolloSubredditIndexApplyCellMarginsOnce(cell);
    Class redditListCellClass = ApolloSubredditIndexRedditListTableViewCellClass();
    BOOL isMultiredditChild = ApolloSubredditIndexCellIsMultiredditChild(tableView, cell, indexPath);
    if (redditListCellClass && [cell isKindOfClass:redditListCellClass]) {
        ApolloSubredditIndexApplyRedditListCellPolishOnce(cell, isMultiredditChild);
    }
    ApolloSubredditIndexApplyCellSelectionChrome(cell, tableView);
    ApolloSubredditIndexApplyMultiredditChildStyleIfNeeded(tableView, cell, indexPath);
}

static void ApolloSubredditIndexStyleHeaderView(UIView *header, UITableView *tableView) {
    if (!sSubredditListEnhancements) return;
    if (!header || !tableView) return;
    if (![objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) {
        if (!ApolloSubredditIndexShouldInspectTable(tableView)) return;
        NSArray<NSString *> *titles = ApolloSubredditIndexTitlesForTable(tableView);
        if (!ApolloSubredditIndexLooksLikeSubredditsTable(tableView, titles)) return;
        objc_setAssociatedObject(tableView, &kApolloSubredditIndexTableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UILabel *label = ApolloSubredditIndexHeaderLabelInView(header);
    if (!label) return;

    NSString *text = [[label.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (!ApolloSubredditIndexStringLooksLikeHeaderTitle(text)) return;

    UIView *separator = objc_getAssociatedObject(header, &kApolloSubredditHeaderSeparatorKey);
    if (!sModernSubredditDividers) {
        separator.hidden = YES;
        return;
    }

    ApolloSubredditIndexClearHeaderChrome(header, label);

    label.text = text;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = ApolloSubredditIndexThemeAccentColor(tableView, header);
    label.alpha = 0.9;
    label.backgroundColor = [UIColor clearColor];
    label.layer.backgroundColor = UIColor.clearColor.CGColor;
    label.frame = CGRectMake(18.0, 0.0, MAX(CGRectGetWidth(header.bounds) - 72.0, 0.0), CGRectGetHeight(header.bounds));

    if (!separator) {
        separator = [[UIView alloc] initWithFrame:CGRectZero];
        separator.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kApolloSubredditHeaderSeparatorKey, separator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [header addSubview:separator];
    }
    separator.hidden = NO;
    separator.backgroundColor = [UIColor clearColor];
    separator.layer.backgroundColor = UIColor.clearColor.CGColor;

    CGFloat lineHeight = 2.0;
    CGSize labelSize = [text sizeWithAttributes:@{ NSFontAttributeName: label.font }];
    CGFloat lineX = CGRectGetMinX(label.frame) + ceil(labelSize.width) + 12.0;
    CGFloat lineWidth = MAX(CGRectGetWidth(header.bounds) - lineX - 8.0, 0.0);
    CGFloat lineY = floor(CGRectGetMidY(header.bounds) - (lineHeight / 2.0));
    separator.frame = CGRectMake(lineX, lineY, lineWidth, lineHeight);

    CAGradientLayer *gradientLayer = objc_getAssociatedObject(separator, &kApolloSubredditHeaderGradientLayerKey);
    if (!gradientLayer) {
        gradientLayer = [CAGradientLayer layer];
        gradientLayer.startPoint = CGPointMake(0.0, 0.5);
        gradientLayer.endPoint = CGPointMake(1.0, 0.5);
        objc_setAssociatedObject(separator, &kApolloSubredditHeaderGradientLayerKey, gradientLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [separator.layer addSublayer:gradientLayer];
    }
    UIColor *accentColor = ApolloSubredditIndexThemeAccentColor(tableView, header);
    UIColor *resolvedAccentColor = ApolloSubredditIndexResolvedColor(accentColor, header.traitCollection);
    UIColor *visibleColor = [resolvedAccentColor colorWithAlphaComponent:0.76];
    UIColor *midColor = [resolvedAccentColor colorWithAlphaComponent:0.38];
    UIColor *clearColor = [resolvedAccentColor colorWithAlphaComponent:0.0];
    gradientLayer.frame = separator.bounds;
    gradientLayer.colors = @[(__bridge id)visibleColor.CGColor, (__bridge id)midColor.CGColor, (__bridge id)clearColor.CGColor];
    gradientLayer.locations = @[@0.0, @0.62, @1.0];

    [header bringSubviewToFront:separator];
    [header bringSubviewToFront:label];
    [header setNeedsDisplay];

    if (![objc_getAssociatedObject(tableView, &kApolloSubredditHeaderLoggedKey) boolValue]) {
        objc_setAssociatedObject(tableView, &kApolloSubredditHeaderLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApolloLog(@"[SubredditIndex] styled-header class=%@ title=%@", NSStringFromClass([header class]), text);
    }

    // Fill the gap a transparent modern header would otherwise leave by giving the header its
    // own opaque surface colour (matching the rows). This replaces the old approach of colouring
    // the whole scroll view, which tripped the iOS 26 nav-bar glass reflection (#450). The header
    // is a subview below the first row, so it never reaches the nav bar's reflected band.
    UIColor *surfaceColor = ApolloSubredditIndexThemeListBackgroundColor(tableView, header);
    header.backgroundColor = ApolloSubredditIndexColorIsVisible(surfaceColor) ? surfaceColor : tableView.backgroundColor;
}

static void ApolloSubredditIndexHeaderLayoutSubviewsHook(id self, SEL _cmd) {
    if (orig_ApolloSubredditHeaderLayoutSubviews) {
        orig_ApolloSubredditHeaderLayoutSubviews(self, _cmd);
    }

    if (![self isKindOfClass:[UIView class]]) return;
    UIView *header = (UIView *)self;
    UITableView *tableView = ApolloSubredditIndexTableForView(header);
    if (!tableView) return;

    ApolloSubredditIndexStyleHeaderView(header, tableView);
}

static void ApolloSubredditIndexWillDisplayHeaderHook(id self, SEL _cmd, UITableView *tableView, UIView *view, NSInteger section) {
    if (orig_ApolloRedditListWillDisplayHeader) {
        orig_ApolloRedditListWillDisplayHeader(self, _cmd, tableView, view, section);
    }
    ApolloSubredditIndexStyleHeaderView(view, tableView);
    ApolloSubredditIndexTrackMultiredditsSection(tableView, view, section);
}

static void ApolloSubredditIndexWillDisplayCellHook(id self, SEL _cmd, UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    if (orig_ApolloRedditListWillDisplayCell) {
        orig_ApolloRedditListWillDisplayCell(self, _cmd, tableView, cell, indexPath);
    }
    ApolloSubredditIndexPrepareCellForDisplay(tableView, cell, indexPath);
}

static Class ApolloSubredditIndexRedditListViewControllerClass(void) {
    Class cls = objc_getClass("Apollo.RedditListViewController");
    if (!cls) cls = NSClassFromString(@"Apollo.RedditListViewController");
    return cls;
}

static void ApolloSubredditIndexInstallHeaderHook(void) {
    Class cls = ApolloSubredditIndexRedditListViewControllerClass();
    if (!cls) {
        ApolloLog(@"[SubredditIndex] header hook skipped: RedditListViewController missing");
        return;
    }

    SEL selector = @selector(tableView:willDisplayHeaderView:forSection:);
    Method method = class_getInstanceMethod(cls, selector);
    IMP hook = (IMP)ApolloSubredditIndexWillDisplayHeaderHook;
    if (method) {
        orig_ApolloRedditListWillDisplayHeader = (void (*)(id, SEL, UITableView *, UIView *, NSInteger))method_getImplementation(method);
        method_setImplementation(method, hook);
        ApolloLog(@"[SubredditIndex] header hook installed via replace on %@", NSStringFromClass(cls));
    } else {
        BOOL added = class_addMethod(cls, selector, hook, "v@:@@q");
        ApolloLog(@"[SubredditIndex] header hook installed via add=%d on %@", added, NSStringFromClass(cls));
    }
}

static void ApolloSubredditIndexInstallCellDisplayHook(void) {
    Class cls = ApolloSubredditIndexRedditListViewControllerClass();
    if (!cls) {
        ApolloLog(@"[SubredditIndex] cell display hook skipped: RedditListViewController missing");
        return;
    }

    SEL selector = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    IMP hook = (IMP)ApolloSubredditIndexWillDisplayCellHook;
    if (method) {
        orig_ApolloRedditListWillDisplayCell = (void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))method_getImplementation(method);
        method_setImplementation(method, hook);
        ApolloLog(@"[SubredditIndex] cell display hook installed via replace on %@", NSStringFromClass(cls));
    } else {
        BOOL added = class_addMethod(cls, selector, hook, "v@:@@@");
        ApolloLog(@"[SubredditIndex] cell display hook installed via add=%d on %@", added, NSStringFromClass(cls));
    }
}

static void ApolloSubredditIndexInstallHeaderLayoutHook(void) {
    Class cls = objc_getClass("Apollo.RecreatedTableSectionHeaderView");
    if (!cls) cls = NSClassFromString(@"Apollo.RecreatedTableSectionHeaderView");
    if (!cls) {
        ApolloLog(@"[SubredditIndex] header layout hook skipped: RecreatedTableSectionHeaderView missing");
        return;
    }

    SEL selector = @selector(layoutSubviews);
    Method ownMethod = NULL;
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int idx = 0; idx < methodCount; idx++) {
        if (method_getName(methods[idx]) == selector) {
            ownMethod = methods[idx];
            break;
        }
    }
    free(methods);

    if (ownMethod) {
        orig_ApolloSubredditHeaderLayoutSubviews = (void (*)(id, SEL))method_getImplementation(ownMethod);
        method_setImplementation(ownMethod, (IMP)ApolloSubredditIndexHeaderLayoutSubviewsHook);
        ApolloLog(@"[SubredditIndex] header layout hook installed via replace on %@", NSStringFromClass(cls));
        return;
    }

    Method inheritedMethod = class_getInstanceMethod(cls, selector);
    if (!inheritedMethod) {
        ApolloLog(@"[SubredditIndex] header layout hook skipped: inherited layoutSubviews missing on %@", NSStringFromClass(cls));
        return;
    }

    orig_ApolloSubredditHeaderLayoutSubviews = (void (*)(id, SEL))method_getImplementation(inheritedMethod);
    const char *types = method_getTypeEncoding(inheritedMethod) ?: "v@:";
    BOOL added = class_addMethod(cls, selector, (IMP)ApolloSubredditIndexHeaderLayoutSubviewsHook, types);
    ApolloLog(@"[SubredditIndex] header layout hook installed via add=%d on %@", added, NSStringFromClass(cls));
}

%hook UITableView

- (void)layoutSubviews {
    %orig;
    ApolloSubredditIndexInstallOrUpdate((UITableView *)self);
}

- (void)reloadData {
    objc_setAssociatedObject((UITableView *)self, &kApolloSubredditMultiredditsSectionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    ApolloSubredditIndexInstallOrUpdate((UITableView *)self);
}

- (void)deleteRowsAtIndexPaths:(NSArray<NSIndexPath *> *)indexPaths withRowAnimation:(UITableViewRowAnimation)animation {
    NSArray<NSIndexPath *> *correctedIndexPaths = ApolloSubredditIndexCorrectedFavoriteDeleteIndexPaths((UITableView *)self, indexPaths);
    %orig(correctedIndexPaths, animation);
}

%end

%hook _TtC6Apollo24RedditListViewController

- (void)favoriteSubredditButtonTapped:(id)sender {
    UIView *senderView = [sender isKindOfClass:[UIView class]] ? (UIView *)sender : nil;
    UITableViewCell *cell = ApolloSubredditIndexCellForView(senderView);
    UITableView *tableView = ApolloSubredditIndexTableForCell(cell);
    NSString *subredditName = ApolloSubredditIndexCellTitle(cell);
    UIControl *control = [sender isKindOfClass:[UIControl class]] ? (UIControl *)sender : nil;

    ApolloSubredditIndexBeginFavoriteMutation(tableView, subredditName);
    %orig;
    ApolloSubredditIndexEndFavoriteMutation();

    ApolloSubredditIndexScheduleFavoritesRefresh(tableView, cell, subredditName, control);
}

%end

%hook UITableViewCell

- (void)prepareForReuse {
    %orig;
    ApolloSubredditIndexRestoreCellSelectionChrome((UITableViewCell *)self);
    objc_setAssociatedObject((UITableViewCell *)self, &kApolloSubredditCellMarginsAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((UITableViewCell *)self, &kApolloSubredditRowPolishAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject((UITableViewCell *)self, &kApolloSubredditMultiredditChildStyledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)layoutSubviews {
    %orig;
    Class redditListCellClass = ApolloSubredditIndexRedditListTableViewCellClass();
    if (!redditListCellClass || ![(UITableViewCell *)self isKindOfClass:redditListCellClass]) return;

    UITableView *tableView = ApolloSubredditIndexTableForCell((UITableViewCell *)self);
    // Selection highlight is a bug fix that applies on the subreddit list in every mode (#452).
    if (ApolloSubredditIndexEnsureSelectionTable(tableView)) {
        ApolloSubredditIndexApplyCellSelectionChrome((UITableViewCell *)self, tableView);
    }
    // Star proxy + multireddit child styling are enhancement-only.
    if ([objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) {
        ApolloSubredditIndexInstallStarProxyForCell((UITableViewCell *)self, tableView);
        ApolloSubredditIndexApplyMultiredditChildStyleIfNeeded(tableView, (UITableViewCell *)self, [tableView indexPathForCell:(UITableViewCell *)self]);
    }
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    %orig;
    UITableView *tableView = ApolloSubredditIndexTableForCell((UITableViewCell *)self);
    if (!ApolloSubredditIndexTableAlreadyRecognised(tableView)) return;
    ApolloSubredditIndexApplyModernPressedCellSelectionChrome((UITableViewCell *)self);
    ApolloSubredditIndexSetModernPressOverlayVisible((UITableViewCell *)self, tableView, highlighted || ((UITableViewCell *)self).selected, animated);
    if (highlighted) {
        __weak UITableViewCell *weakCell = (UITableViewCell *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UITableView *strongTable = ApolloSubredditIndexTableForCell(weakCell);
            ApolloSubredditIndexApplyModernPressedCellSelectionChrome(weakCell);
            ApolloSubredditIndexSetModernPressOverlayVisible(weakCell, strongTable, weakCell.highlighted || weakCell.selected, NO);
        });
    }
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    %orig;
    UITableView *tableView = ApolloSubredditIndexTableForCell((UITableViewCell *)self);
    if (!ApolloSubredditIndexTableAlreadyRecognised(tableView)) return;
    ApolloSubredditIndexApplyModernPressedCellSelectionChrome((UITableViewCell *)self);
    ApolloSubredditIndexSetModernPressOverlayVisible((UITableViewCell *)self, tableView, selected || ((UITableViewCell *)self).highlighted, animated);
    if (selected) {
        __weak UITableViewCell *weakCell = (UITableViewCell *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UITableView *strongTable = ApolloSubredditIndexTableForCell(weakCell);
            ApolloSubredditIndexApplyModernPressedCellSelectionChrome(weakCell);
            ApolloSubredditIndexSetModernPressOverlayVisible(weakCell, strongTable, weakCell.highlighted || weakCell.selected, NO);
        });
    }
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    %orig;
    Class redditListCellClass = ApolloSubredditIndexRedditListTableViewCellClass();
    if (!redditListCellClass || ![(UITableViewCell *)self isKindOfClass:redditListCellClass]) return;

    UITableView *tableView = ApolloSubredditIndexTableForCell((UITableViewCell *)self);
    if (ApolloSubredditIndexEnsureSelectionTable(tableView)) {
        ApolloSubredditIndexApplyCellSelectionChrome((UITableViewCell *)self, tableView);
    }
    if ([objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) {
        ApolloSubredditIndexInstallStarProxyForCell((UITableViewCell *)self, tableView);
    }
}

%end

static UIStackView *ApolloSubredditIndexRedditListMainStackView(UITableViewCell *cell) {
    static Ivar mainStackIvar = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ApolloSubredditIndexRedditListTableViewCellClass();
        if (cls) mainStackIvar = class_getInstanceVariable(cls, "mainStackView");
    });
    if (!mainStackIvar) return nil;
    id value = object_getIvar(cell, mainStackIvar);
    return [value isKindOfClass:[UIStackView class]] ? (UIStackView *)value : nil;
}

static void ApolloSubredditIndexApplyRedditListCellPolishOnce(UITableViewCell *cell, BOOL skipLeadingMarginClamp) {
    if ([objc_getAssociatedObject(cell, &kApolloSubredditRowPolishAppliedKey) boolValue]) return;

    if (!skipLeadingMarginClamp) {
        UIEdgeInsets margins = cell.contentView.layoutMargins;
        if (margins.left < ApolloSubredditRowBalancedLeadingMargin) {
            margins.left = ApolloSubredditRowBalancedLeadingMargin;
            cell.contentView.layoutMargins = margins;
        }
    }

    UIStackView *mainStack = ApolloSubredditIndexRedditListMainStackView(cell);
    if (mainStack && mainStack.spacing < ApolloSubredditRowIconTextGap) {
        mainStack.spacing = ApolloSubredditRowIconTextGap;
    }

    objc_setAssociatedObject(cell, &kApolloSubredditRowPolishAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC6Apollo27ApolloSubtitleTableViewCell

- (void)layoutSubviews {
    %orig;

    UITableViewCell *cell = (UITableViewCell *)self;
    // Only adjust within the subreddits list — this cell is shared with other screens.
    UITableView *tableView = ApolloSubredditIndexTableForCell(cell);
    if (![objc_getAssociatedObject(tableView, &kApolloSubredditIndexTableKey) boolValue]) return;

    UIImageView *iconView = cell.imageView;
    if (!iconView || !iconView.image) return;

    CGFloat deltaX = ApolloSubredditRowBalancedLeadingMargin - CGRectGetMinX(iconView.frame);
    if (deltaX <= 0.5) return;

    CGRect frame = iconView.frame;
    frame.origin.x += deltaX;
    iconView.frame = frame;

    // Pull labels left by the trim amount so the icon→text gap shrinks
    // to match the tightened gap on custom subreddit rows.
    CGFloat labelDeltaX = deltaX - ApolloSubredditRowStandardIconTextTrim;

    UILabel *textLabel = cell.textLabel;
    if (textLabel) {
        CGRect f = textLabel.frame;
        f.origin.x += labelDeltaX;
        textLabel.frame = f;
    }
    UILabel *detailLabel = cell.detailTextLabel;
    if (detailLabel) {
        CGRect f = detailLabel.frame;
        f.origin.x += labelDeltaX;
        detailLabel.frame = f;
    }
}

%end

%ctor {
    ApolloSubredditIndexInstallHeaderHook();
    ApolloSubredditIndexInstallCellDisplayHook();
    ApolloSubredditIndexInstallHeaderLayoutHook();
    [[NSNotificationCenter defaultCenter] addObserverForName:ApolloModernSubredditDividersChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *notification) {
        ApolloSubredditIndexRefreshAllVisibleTables();
        ApolloLog(@"[SubredditIndex] divider-style-changed modern=%d", sModernSubredditDividers);
    }];
    ApolloLog(@"[SubredditIndex] polish active modernDividers=%d", sModernSubredditDividers);
}
