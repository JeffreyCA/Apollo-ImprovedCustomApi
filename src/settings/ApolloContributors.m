#import "ApolloContributors.h"

static NSString *const kContributorsJSONURL = @"https://raw.githubusercontent.com/Apollo-Reborn/Apollo-Reborn/refs/heads/main/contributors.json";

NSString *ApolloContributorGitHubLogin(NSDictionary *contributor) {
    NSString *github = [contributor[@"github"] isKindOfClass:[NSString class]] ? contributor[@"github"] : nil;
    return github.length > 0 ? github : nil;
}

NSString *ApolloContributorDisplayName(NSDictionary *contributor) {
    NSString *github = ApolloContributorGitHubLogin(contributor);
    if ([github isEqualToString:@"icpryde"]) return @"iCpryde";

    NSString *display = [contributor[@"displayName"] isKindOfClass:[NSString class]] ? contributor[@"displayName"] : nil;
    if (display.length > 0) return display;
    if (github.length > 0) return github;
    NSString *idStr = [contributor[@"id"] isKindOfClass:[NSString class]] ? contributor[@"id"] : nil;
    return idStr ?: @"";
}

BOOL ApolloContributorIsMaintainer(NSDictionary *contributor) {
    NSString *role = [contributor[@"role"] isKindOfClass:[NSString class]] ? contributor[@"role"] : nil;
    return role.length > 0 && [role caseInsensitiveCompare:@"maintainer"] == NSOrderedSame;
}

NSArray<NSDictionary *> *ApolloContributorsForRole(NSArray<NSDictionary *> *rawContributors, NSString *role) {
    NSMutableArray<NSDictionary *> *matched = [NSMutableArray array];
    for (NSDictionary *contributor in rawContributors) {
        NSString *contributorRole = [contributor[@"role"] isKindOfClass:[NSString class]] ? contributor[@"role"] : nil;
        if ([contributorRole caseInsensitiveCompare:role] == NSOrderedSame) {
            [matched addObject:contributor];
        }
    }
    return matched;
}

NSArray<NSDictionary *> *ApolloBuyCoffeeEntriesFromContributors(NSArray<NSDictionary *> *rawContributors) {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSDictionary *contributor in rawContributors) {
        if (![contributor isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = [contributor[@"buyMeACoffeeUrl"] isKindOfClass:[NSString class]] ? contributor[@"buyMeACoffeeUrl"] : nil;
        if (url.length == 0) continue;
        [entries addObject:@{
            @"name": ApolloContributorDisplayName(contributor),
            @"url": url,
        }];
    }
    return entries;
}

static NSArray<NSDictionary *> *ApolloRawContributorsFromJSONDictionary(NSDictionary *json) {
    NSMutableArray<NSDictionary *> *rawContributors = [NSMutableArray array];
    id contribObj = json[@"contributors"];
    if (![contribObj isKindOfClass:[NSArray class]]) return rawContributors;
    for (id item in (NSArray *)contribObj) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            [rawContributors addObject:item];
        }
    }
    return rawContributors;
}

NSArray<NSDictionary *> *ApolloThanksToGroupedSections(NSArray<NSDictionary *> *rawContributors) {
    if (rawContributors.count == 0) return @[];

    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];

    NSArray<NSDictionary *> *maintainers = ApolloContributorsForRole(rawContributors, @"maintainer");
    if (maintainers.count > 0) {
        [sections addObject:@{@"title": @"Maintainers", @"contributors": maintainers}];
    }

    NSArray<NSDictionary *> *codeContributors = ApolloContributorsForRole(rawContributors, @"code");
    if (codeContributors.count > 0) {
        [sections addObject:@{@"title": @"Code", @"contributors": codeContributors}];
    }

    NSArray<NSDictionary *> *designContributors = ApolloContributorsForRole(rawContributors, @"design");
    if (designContributors.count > 0) {
        [sections addObject:@{@"title": @"Icon & Design", @"contributors": designContributors}];
    }

    return sections;
}

void ApolloFetchContributors(void (^completion)(NSArray<NSDictionary *> *rawContributors,
                                                NSString *errorMessage)) {
    NSURL *url = [NSURL URLWithString:kContributorsJSONURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadRevalidatingCacheData
                                                   timeoutInterval:15];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSError *parseError = nil;
        NSDictionary *json = nil;
        if (data && !error) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        }

        NSString *failureMessage = nil;
        NSArray<NSDictionary *> *rawContributors = @[];
        if (error) {
            failureMessage = error.localizedDescription;
        } else if (parseError || ![json isKindOfClass:[NSDictionary class]]) {
            failureMessage = @"Couldn't parse contributors list.";
        } else {
            rawContributors = ApolloRawContributorsFromJSONDictionary(json);
        }
        completion(rawContributors, failureMessage);
    }];
    [task resume];
}
