#import "TagFiltersViewController.h"

#import "ApolloState.h"
#import "UserDefaultConstants.h"

extern NSString *const ApolloTagFiltersChangedNotification;
NSString *const ApolloTagFiltersChangedNotification = @"ApolloTagFiltersChangedNotification";

typedef NS_ENUM(NSInteger, TagFiltersSection) {
    TagFiltersSectionGeneral = 0,    // Enable / Mode / NSFW / Spoiler
    TagFiltersSectionOverrides,      // Per-subreddit list + "Add Subreddit…"
    TagFiltersSectionCount,
};

#pragma mark - Per-subreddit detail VC

@interface TagFilterSubredditDetailViewController : UITableViewController
@property (nonatomic, copy) NSString *subredditName;   // lowercased
@property (nonatomic, copy) void (^onChange)(void);
@end

@implementation TagFilterSubredditDetailViewController

- (instancetype)initWithSubreddit:(NSString *)subreddit {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _subredditName = [[subreddit stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"r/%@", self.subredditName];
}

- (NSDictionary *)currentOverride {
    NSDictionary *all = sTagFilterSubredditOverrides;
    NSDictionary *o = all[self.subredditName];
    return [o isKindOfClass:[NSDictionary class]] ? o : @{};
}

- (void)updateOverrideWithBlock:(void (^)(NSMutableDictionary *override))block {
    NSMutableDictionary *all = [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];
    NSMutableDictionary *o = [([self currentOverride] ?: @{}) mutableCopy];
    if (block) block(o);
    if (o.count > 0) {
        all[self.subredditName] = [o copy];
    } else {
        [all removeObjectForKey:self.subredditName];
    }
    sTagFilterSubredditOverrides = [all copy];
    [[NSUserDefaults standardUserDefaults] setObject:sTagFilterSubredditOverrides forKey:UDKeyTagFilterSubredditOverrides];
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
    if (self.onChange) self.onChange();
}

- (BOOL)effectiveBoolForKey:(NSString *)key globalDefault:(BOOL)globalDefault {
    NSDictionary *o = [self currentOverride];
    id v = o[key];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    return globalDefault;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 2; // NSFW, Spoiler
    if (section == 1) return 1; // Reset
    return 1;                   // Delete
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Filter";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Per-subreddit settings override the global defaults. Toggles match what you'd set globally.";
    if (section == 1) return @"Reset clears overrides for this subreddit (it will follow global settings again).";
    return nil;
}

- (UITableViewCell *)switchCellLabel:(NSString *)label on:(BOOL)on action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        if (indexPath.row == 0) return [self switchCellLabel:@"NSFW"
                                                          on:[self effectiveBoolForKey:@"nsfw" globalDefault:sTagFilterNSFW]
                                                      action:@selector(nsfwChanged:)];
        return [self switchCellLabel:@"Spoiler"
                                  on:[self effectiveBoolForKey:@"spoiler" globalDefault:sTagFilterSpoiler]
                              action:@selector(spoilerChanged:)];
    }
    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Reset to Global Defaults";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = @"Remove Subreddit Override";
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    return cell;
}

- (void)nsfwChanged:(UISwitch *)sw {
    [self updateOverrideWithBlock:^(NSMutableDictionary *o) { o[@"nsfw"] = @(sw.on); }];
}

- (void)spoilerChanged:(UISwitch *)sw {
    [self updateOverrideWithBlock:^(NSMutableDictionary *o) { o[@"spoiler"] = @(sw.on); }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        [self updateOverrideWithBlock:^(NSMutableDictionary *o) {
            [o removeAllObjects];
        }];
        [self.tableView reloadData];
        return;
    }
    if (indexPath.section == 2) {
        [self updateOverrideWithBlock:^(NSMutableDictionary *o) {
            [o removeAllObjects];
        }];
        [self.navigationController popViewControllerAnimated:YES];
    }
}

@end

#pragma mark - Main TagFiltersViewController

@interface TagFiltersViewController () <UITextFieldDelegate>
@end

@implementation TagFiltersViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Tag Filters";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Helpers

- (NSArray<NSString *> *)overrideSubreddits {
    NSDictionary *all = sTagFilterSubredditOverrides ?: @{};
    return [[all allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (void)postChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:ApolloTagFiltersChangedNotification object:nil];
}

#pragma mark - Section / row counts

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return TagFiltersSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == TagFiltersSectionGeneral) return 3;  // Enable / NSFW / Spoiler
    if (section == TagFiltersSectionOverrides) return [self overrideSubreddits].count + 1; // + "Add"
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == TagFiltersSectionGeneral) return @"General";
    if (section == TagFiltersSectionOverrides) return @"Per-Subreddit Overrides";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == TagFiltersSectionGeneral) {
        return @"Filtered posts are covered with a frosted blur over the post's title and thumbnail. Tap the blur to confirm and reveal the post. Brand Affiliate is unavailable because Apollo does not store that tag.";
    }
    if (section == TagFiltersSectionOverrides) {
        return @"Per-subreddit settings override the global defaults. Add a subreddit to customize behavior for it.";
    }
    return nil;
}

#pragma mark - Cells

- (UITableViewCell *)switchCellLabel:(NSString *)label on:(BOOL)on enabled:(BOOL)enabled action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = label;
    cell.textLabel.enabled = enabled;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.enabled = enabled;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == TagFiltersSectionGeneral) {
        switch (indexPath.row) {
            case 0:
                return [self switchCellLabel:@"Enable Tag Filters" on:sTagFilterEnabled enabled:YES action:@selector(enableChanged:)];
            case 1: return [self switchCellLabel:@"NSFW" on:sTagFilterNSFW enabled:sTagFilterEnabled action:@selector(nsfwChanged:)];
            case 2: return [self switchCellLabel:@"Spoiler" on:sTagFilterSpoiler enabled:sTagFilterEnabled action:@selector(spoilerChanged:)];
        }
    }

    if (indexPath.section == TagFiltersSectionOverrides) {
        NSArray<NSString *> *subs = [self overrideSubreddits];
        if ((NSUInteger)indexPath.row < subs.count) {
            NSString *sub = subs[indexPath.row];
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.textLabel.text = [NSString stringWithFormat:@"r/%@", sub];
            cell.detailTextLabel.text = [self summaryForOverride:sub];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Add Subreddit…";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        return cell;
    }

    return [[UITableViewCell alloc] init];
}

- (NSString *)summaryForOverride:(NSString *)sub {
    NSDictionary *o = sTagFilterSubredditOverrides[sub];
    if (![o isKindOfClass:[NSDictionary class]]) return @"(no overrides)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([o[@"nsfw"] isKindOfClass:[NSNumber class]]) [parts addObject:[NSString stringWithFormat:@"NSFW: %@", [o[@"nsfw"] boolValue] ? @"on" : @"off"]];
    if ([o[@"spoiler"] isKindOfClass:[NSNumber class]]) [parts addObject:[NSString stringWithFormat:@"Spoiler: %@", [o[@"spoiler"] boolValue] ? @"on" : @"off"]];
    if (parts.count == 0) return @"(uses global)";
    return [parts componentsJoinedByString:@" · "];
}

#pragma mark - Switch handlers

- (void)enableChanged:(UISwitch *)sw {
    sTagFilterEnabled = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterEnabled];
    [self postChange];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:TagFiltersSectionGeneral] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)nsfwChanged:(UISwitch *)sw {
    sTagFilterNSFW = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterNSFW];
    [self postChange];
}

- (void)spoilerChanged:(UISwitch *)sw {
    sTagFilterSpoiler = sw.on;
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:UDKeyTagFilterSpoiler];
    [self postChange];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == TagFiltersSectionOverrides) {
        NSArray<NSString *> *subs = [self overrideSubreddits];
        if ((NSUInteger)indexPath.row < subs.count) {
            TagFilterSubredditDetailViewController *detail = [[TagFilterSubredditDetailViewController alloc] initWithSubreddit:subs[indexPath.row]];
            __weak typeof(self) wself = self;
            detail.onChange = ^{ [wself.tableView reloadData]; };
            [self.navigationController pushViewController:detail animated:YES];
        } else {
            [self presentAddSubredditPrompt];
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != TagFiltersSectionOverrides) return NO;
    return (NSUInteger)indexPath.row < [self overrideSubreddits].count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSArray<NSString *> *subs = [self overrideSubreddits];
    if ((NSUInteger)indexPath.row >= subs.count) return;
    NSString *sub = subs[indexPath.row];
    NSMutableDictionary *all = [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];
    [all removeObjectForKey:sub];
    sTagFilterSubredditOverrides = [all copy];
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:UDKeyTagFilterSubredditOverrides];
    [self postChange];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)presentAddSubredditPrompt {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Subreddit"
                                                                   message:@"Enter the subreddit name (without r/)."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"funny";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UITextField *tf = weakAlert.textFields.firstObject;
        NSString *raw = [tf.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([raw hasPrefix:@"r/"] || [raw hasPrefix:@"R/"]) raw = [raw substringFromIndex:2];
        if ([raw hasPrefix:@"/"]) raw = [raw substringFromIndex:1];
        NSString *sub = raw.lowercaseString;
        if (sub.length == 0) return;
        NSMutableDictionary *all = [(sTagFilterSubredditOverrides ?: @{}) mutableCopy];
        if (!all[sub]) all[sub] = @{}; // empty overrides; opens detail to configure
        sTagFilterSubredditOverrides = [all copy];
        [[NSUserDefaults standardUserDefaults] setObject:all forKey:UDKeyTagFilterSubredditOverrides];
        [self postChange];
        [self.tableView reloadData];
        TagFilterSubredditDetailViewController *detail = [[TagFilterSubredditDetailViewController alloc] initWithSubreddit:sub];
        __weak typeof(self) wself = self;
        detail.onChange = ^{ [wself.tableView reloadData]; };
        [self.navigationController pushViewController:detail animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
