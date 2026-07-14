#import "ApolloSubredditFilterDetailViewController.h"
#import "ApolloPostFilterStore.h"

typedef NS_ENUM(NSInteger, ApolloPFDetailSection) {
    ApolloPFDetailSectionKeywords = 0,
    ApolloPFDetailSectionFlairs,
    ApolloPFDetailSectionRemove,
    ApolloPFDetailSectionCount,
};

@interface ApolloSubredditFilterDetailViewController ()
@property (nonatomic, copy) NSString *subredditName; // lowercased, normalized
@end

@implementation ApolloSubredditFilterDetailViewController

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _subredditName = [ApolloPostFilterStore normalizeSubreddit:subreddit];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"r/%@", self.subredditName];
    [self updateEditButtonAnimated:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    [self updateEditButtonAnimated:NO];
}

// Show the standard Edit button (toggles delete controls on the keyword/flair
// rows) whenever there's something to remove — mirrors the native Filters &
// Blocks screen. Swipe-to-delete keeps working too.
- (void)updateEditButtonAnimated:(BOOL)animated {
    BOOL hasItems = ([self keywords].count + [self flairs].count) > 0;
    if (hasItems) {
        if (self.navigationItem.rightBarButtonItem != self.editButtonItem) {
            [self.navigationItem setRightBarButtonItem:self.editButtonItem animated:animated];
        }
    } else {
        if (self.isEditing) [self setEditing:NO animated:animated];
        if (self.navigationItem.rightBarButtonItem != nil) {
            [self.navigationItem setRightBarButtonItem:nil animated:animated];
        }
    }
}

#pragma mark - Data

- (NSArray<NSString *> *)keywords { return [ApolloPostFilterStore keywordsForSubreddit:self.subredditName]; }
- (NSArray<NSString *> *)flairs   { return [ApolloPostFilterStore flairsForSubreddit:self.subredditName]; }

- (void)didChange {
    [self.tableView reloadData];
    [self updateEditButtonAnimated:YES];
    if (self.onChange) self.onChange();
}

#pragma mark - Table structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return ApolloPFDetailSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == ApolloPFDetailSectionKeywords) return (NSInteger)[self keywords].count + 1; // + "Add"
    if (section == ApolloPFDetailSectionFlairs)   return (NSInteger)[self flairs].count + 1;   // + "Add"
    return 1; // Remove
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == ApolloPFDetailSectionKeywords) return @"Keywords";
    if (section == ApolloPFDetailSectionFlairs) return @"Flairs";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ApolloPFDetailSectionKeywords)
        return [NSString stringWithFormat:@"Hide posts in r/%@ whose title or link contains any of these words (case-insensitive).", self.subredditName];
    if (section == ApolloPFDetailSectionFlairs)
        return [NSString stringWithFormat:@"Hide posts in r/%@ with any of these post flairs. Type the flair label exactly as it appears on posts (case-insensitive).", self.subredditName];
    return @"Stops filtering this subreddit and clears its keywords and flairs.";
}

#pragma mark - Cells

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger section = indexPath.section;

    if (section == ApolloPFDetailSectionRemove) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Remove This Subreddit";
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }

    NSArray<NSString *> *items = (section == ApolloPFDetailSectionKeywords) ? [self keywords] : [self flairs];
    if ((NSUInteger)indexPath.row < items.count) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = items[indexPath.row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    // "Add ..." row.
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = (section == ApolloPFDetailSectionKeywords) ? @"Add Keyword..." : @"Add Flair...";
    [self apollo_applyAccentActionTextColorToCell:cell];
    return cell;
}

#pragma mark - Selection

- (BOOL)isAddRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloPFDetailSectionKeywords) return (NSUInteger)indexPath.row == [self keywords].count;
    if (indexPath.section == ApolloPFDetailSectionFlairs)   return (NSUInteger)indexPath.row == [self flairs].count;
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == ApolloPFDetailSectionRemove) {
        [ApolloPostFilterStore removeSubreddit:self.subredditName];
        if (self.onChange) self.onChange();
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    if (![self isAddRowAtIndexPath:indexPath]) return;

    BOOL isKeyword = (indexPath.section == ApolloPFDetailSectionKeywords);
    NSString *title = isKeyword ? @"Add Keyword" : @"Add Flair";
    NSString *message = isKeyword
        ? @"Posts in this subreddit whose title or link contains this word are hidden."
        : @"Posts in this subreddit with this flair label are hidden.";
    NSString *placeholder = isKeyword ? @"giveaway" : @"Fanart";
    [self presentAddPromptWithTitle:title message:message placeholder:placeholder onAdd:^(NSString *text) {
        if (isKeyword) {
            [ApolloPostFilterStore addKeyword:text forSubreddit:self.subredditName];
        } else {
            [ApolloPostFilterStore addFlair:text forSubreddit:self.subredditName];
        }
        [self didChange];
    }];
}

#pragma mark - Editing (swipe to delete)

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ApolloPFDetailSectionKeywords) return (NSUInteger)indexPath.row < [self keywords].count;
    if (indexPath.section == ApolloPFDetailSectionFlairs)   return (NSUInteger)indexPath.row < [self flairs].count;
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section == ApolloPFDetailSectionKeywords) {
        NSArray<NSString *> *kw = [self keywords];
        if ((NSUInteger)indexPath.row >= kw.count) return;
        [ApolloPostFilterStore removeKeyword:kw[indexPath.row] forSubreddit:self.subredditName];
    } else if (indexPath.section == ApolloPFDetailSectionFlairs) {
        NSArray<NSString *> *fl = [self flairs];
        if ((NSUInteger)indexPath.row >= fl.count) return;
        [ApolloPostFilterStore removeFlair:fl[indexPath.row] forSubreddit:self.subredditName];
    } else {
        return;
    }
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    // Defer the edit-button refresh (which may toggle setEditing:NO when the last
    // item is gone) so it doesn't fight the in-flight delete animation.
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [wself updateEditButtonAnimated:YES]; });
    if (self.onChange) self.onChange();
}

#pragma mark - Add prompt

- (void)presentAddPromptWithTitle:(NSString *)title
                          message:(NSString *)message
                      placeholder:(NSString *)placeholder
                            onAdd:(void (^)(NSString *text))onAdd {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = placeholder;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UITextField *tf = weakAlert.textFields.firstObject;
        NSString *text = tf.text ?: @"";
        if ([text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) return;
        if (onAdd) onAdd(text);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
