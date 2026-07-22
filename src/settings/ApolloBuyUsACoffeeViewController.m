#import "ApolloBuyUsACoffeeViewController.h"

#import "ApolloCommon.h"
#import "ApolloContributors.h"

static NSString *const kBuyCoffeeCellId = @"Cell_BuyCoffee";

@implementation ApolloBuyUsACoffeeViewController {
    NSArray<NSDictionary *> *_entries;
    BOOL _isLoading;
    NSString *_errorMessage;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _entries = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Buy Us a Coffee";

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(loadEntries) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self loadEntries];
}

- (void)loadEntries {
    _isLoading = (_entries.count == 0);
    _errorMessage = nil;
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    ApolloFetchContributors(^(NSArray<NSDictionary *> *rawContributors, NSString *failureMessage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSArray<NSDictionary *> *parsedEntries = ApolloBuyCoffeeEntriesFromContributors(rawContributors);
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_isLoading = NO;
            [strongSelf.refreshControl endRefreshing];
            if (failureMessage && parsedEntries.count == 0) {
                strongSelf->_errorMessage = failureMessage;
            } else {
                strongSelf->_errorMessage = nil;
                strongSelf->_entries = parsedEntries;
            }
            [strongSelf.tableView reloadData];
        });
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return nil;
    return @"If you're enjoying the updates, consider buying us a coffee!";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return 1;
    return (NSInteger)_entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_isLoading) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        cell.textLabel.text = @"Loading support links…";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (_errorMessage) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"Couldn't load support links";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nTap to retry.", _errorMessage];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kBuyCoffeeCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kBuyCoffeeCellId];
    }

    NSDictionary *entry = _entries[(NSUInteger)indexPath.row];
    cell.textLabel.text = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : @"";
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.imageView.image = ApolloBuyMeACoffeeSettingsIcon(32.0);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (_isLoading) return;
    if (_errorMessage) {
        [self loadEntries];
        return;
    }

    NSDictionary *entry = _entries[(NSUInteger)indexPath.row];
    NSString *urlString = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
    NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
    if (!url) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ApolloPresentWebURLFromViewController(weakSelf, url);
    });
}

@end
