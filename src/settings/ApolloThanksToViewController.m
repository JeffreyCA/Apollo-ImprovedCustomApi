#import "ApolloThanksToViewController.h"

#import "ApolloCommon.h"
#import "ApolloContributors.h"

static NSString *const kThanksToCellId = @"Cell_ThanksTo_Contributor";

static BOOL ApolloThanksToContributorIsPinned(NSDictionary *contributor) {
    return ApolloContributorIsMaintainer(contributor);
}

@implementation ApolloThanksToViewController {
    NSArray<NSDictionary *> *_sections;
    BOOL _isLoading;
    NSString *_errorMessage;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _sections = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Thanks To";

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(loadContributors) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;

    [self loadContributors];
}

- (void)loadContributors {
    _isLoading = (_sections.count == 0);
    _errorMessage = nil;
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    ApolloFetchContributors(^(NSArray<NSDictionary *> *rawContributors, NSString *failureMessage) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSArray<NSDictionary *> *parsedSections = ApolloThanksToGroupedSections(rawContributors);
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf->_isLoading = NO;
            [strongSelf.refreshControl endRefreshing];
            if (failureMessage && parsedSections.count == 0) {
                strongSelf->_errorMessage = failureMessage;
            } else {
                strongSelf->_errorMessage = nil;
                strongSelf->_sections = parsedSections;
            }
            [strongSelf.tableView reloadData];
        });
    });
}

#pragma mark - Table

- (NSDictionary *)sectionAtIndex:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)_sections.count) return nil;
    return _sections[(NSUInteger)section];
}

- (NSDictionary *)contributorAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *section = [self sectionAtIndex:indexPath.section];
    NSArray *contributors = [section[@"contributors"] isKindOfClass:[NSArray class]] ? section[@"contributors"] : nil;
    if (!contributors || indexPath.row < 0 || indexPath.row >= (NSInteger)contributors.count) return nil;
    return contributors[(NSUInteger)indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_isLoading || _errorMessage) return 1;
    return (NSInteger)_sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return nil;
    NSDictionary *sectionInfo = [self sectionAtIndex:section];
    NSString *title = [sectionInfo[@"title"] isKindOfClass:[NSString class]] ? sectionInfo[@"title"] : nil;
    return title.length > 0 ? title : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (_isLoading || _errorMessage) return 1;
    NSDictionary *sectionInfo = [self sectionAtIndex:section];
    NSArray *contributors = [sectionInfo[@"contributors"] isKindOfClass:[NSArray class]] ? sectionInfo[@"contributors"] : nil;
    return (NSInteger)contributors.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_isLoading) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        cell.textLabel.text = @"Loading contributors…";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (_errorMessage) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.textLabel.text = @"Couldn't load contributors";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nTap to retry.", _errorMessage];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kThanksToCellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kThanksToCellId];
    }

    NSDictionary *c = [self contributorAtIndexPath:indexPath];
    if (!c) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    cell.textLabel.text = [self displayNameForContributor:c];
    cell.detailTextLabel.text = nil;
    cell.textLabel.font = ApolloThanksToContributorIsPinned(c)
        ? [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]   // bold body weight, Dynamic Type aware
        : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image = nil;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (_isLoading) return;
    if (_errorMessage) {
        [self loadContributors];
        return;
    }

    NSDictionary *c = [self contributorAtIndexPath:indexPath];
    if (!c) return;

    NSURL *url = [self profileURLForContributor:c];
    if (!url) return;

    ApolloPresentWebURLFromViewController(self, url);
}

#pragma mark - Contributor formatting

- (NSString *)displayNameForContributor:(NSDictionary *)c {
    NSString *github = ApolloContributorGitHubLogin(c);
    if ([github isEqualToString:@"icpryde"]) return @"@iCpryde";
    if (github.length > 0) return [@"@" stringByAppendingString:github];

    NSString *display = [c[@"displayName"] isKindOfClass:[NSString class]] ? c[@"displayName"] : nil;
    if (display.length > 0) return display;
    NSString *idStr = [c[@"id"] isKindOfClass:[NSString class]] ? c[@"id"] : nil;
    return idStr ?: @"";
}

- (NSURL *)profileURLForContributor:(NSDictionary *)c {
    NSString *profile = [c[@"profileUrl"] isKindOfClass:[NSString class]] ? c[@"profileUrl"] : nil;
    if (profile.length > 0) return [NSURL URLWithString:profile];
    NSString *github = [c[@"github"] isKindOfClass:[NSString class]] ? c[@"github"] : nil;
    if (github.length > 0) {
        return [NSURL URLWithString:[@"https://github.com/" stringByAppendingString:github]];
    }
    return nil;
}

@end
