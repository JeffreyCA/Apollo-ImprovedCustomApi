#import "settings/ApolloSettingsTableViewController.h"

#import "ApolloCommon.h"
#import "ApolloThemeRuntime.h"
#import <objc/runtime.h>

static char kApolloAccentActionCellKey;

@implementation ApolloSettingsTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self apollo_applyTheme];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self apollo_applyTheme];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self apollo_applyTheme];
}

- (UITableView *)apollo_sourceThemeTableView {
    return ApolloInheritedSettingsThemeSourceTableView(self);
}

- (UIColor *)apollo_themeCellBackgroundColor {
    UITableView *source = [self apollo_sourceThemeTableView];
    if (!ApolloThemeSourceTableIsStale(source)) {
        for (UITableViewCell *cell in source.visibleCells) {
            UIColor *color = cell.backgroundColor ?: cell.contentView.backgroundColor;
            if (color) return color;
        }
    }
    return ApolloThemeCardBackgroundColor() ?: [UIColor secondarySystemGroupedBackgroundColor];
}

- (UIColor *)apollo_themeAccentColor {
    return ApolloThemeAccentColor() ?: self.view.tintColor ?: [UIColor systemBlueColor];
}

- (void)apollo_applyAccentActionTextColorToCell:(UITableViewCell *)cell {
    if (!cell) return;
    objc_setAssociatedObject(cell, &kApolloAccentActionCellKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)apollo_applyThemeToCell:(UITableViewCell *)cell {
    if (!cell) return;

    UIColor *cellColor = [self apollo_themeCellBackgroundColor];
    cell.backgroundColor = cellColor;

    UIColor *accentColor = [self apollo_themeAccentColor];
    cell.tintColor = accentColor;
    if (cell.accessoryView) cell.accessoryView.tintColor = accentColor;

    for (UIView *subview in cell.contentView.subviews) {
        subview.tintColor = accentColor;
    }

    if ([objc_getAssociatedObject(cell, &kApolloAccentActionCellKey) boolValue]) {
        cell.textLabel.textColor = accentColor;
    }
}

- (void)apollo_applyTheme {
    ApolloApplyInheritedSettingsTableTheme(self);

    UIColor *accentColor = [self apollo_themeAccentColor];
    self.view.tintColor = accentColor;
    self.tableView.tintColor = accentColor;
    self.navigationController.navigationBar.tintColor = accentColor;

    for (UITableViewCell *cell in self.tableView.visibleCells) {
        [self apollo_applyThemeToCell:cell];
    }
}

- (void)tableView:(UITableView *)__unused tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)__unused indexPath {
    [self apollo_applyThemeToCell:cell];
}

@end


// UITextView subclass that allows users to tap links within footer text, but not select text
@implementation ApolloFooterLinkTextView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UITextPosition *position = [self closestPositionToPoint:point];
    if (!position) return NO;

    UITextRange *range = [self.tokenizer rangeEnclosingPosition:position withGranularity:UITextGranularityCharacter inDirection:UITextLayoutDirectionLeft];
    if (!range) return NO;

    NSInteger startIndex = [self offsetFromPosition:self.beginningOfDocument toPosition:range.start];
    return [self.attributedText attribute:NSLinkAttributeName atIndex:startIndex effectiveRange:nil] != nil;
}

@end
