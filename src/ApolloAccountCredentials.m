#import "ApolloAccountCredentials.h"
#import "ApolloState.h"
#import "ApolloCommon.h"
#import "Defaults.h"
#import "UserDefaultConstants.h"
#import "Tweak.h" // minimal RDKClient stub (+sharedClient) — see Tweak.h
#import <objc/runtime.h>
#import <objc/message.h>

@implementation ApolloAccountCredentialEntry

- (BOOL)hasCustomCredentials {
    return self.clientId.length > 0 || self.clientSecret.length > 0 || self.redirectURI.length > 0;
}

@end

#pragma mark - Persistence

// Flat dictionary: lowercased username -> {clientId, clientSecret, redirectURI}.
// Stored as plain NSStrings (not archived custom objects) so the persisted
// shape stays simple and forward-compatible.
static NSString *ApolloNormalizeUsername(NSString *username) {
    return [[username ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
}

static NSDictionary<NSString *, NSDictionary *> *ApolloLoadRawAccountCredentials(void) {
    NSDictionary *raw = [[NSUserDefaults standardUserDefaults] objectForKey:UDKeyPerAccountCredentials];
    return [raw isKindOfClass:[NSDictionary class]] ? raw : @{};
}

static void ApolloSaveRawAccountCredentials(NSDictionary<NSString *, NSDictionary *> *raw) {
    [[NSUserDefaults standardUserDefaults] setObject:raw forKey:UDKeyPerAccountCredentials];
}

static ApolloAccountCredentialEntry *ApolloEntryFromRaw(NSDictionary *raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    ApolloAccountCredentialEntry *entry = [ApolloAccountCredentialEntry new];
    entry.clientId = [raw[@"clientId"] isKindOfClass:[NSString class]] ? raw[@"clientId"] : @"";
    entry.clientSecret = [raw[@"clientSecret"] isKindOfClass:[NSString class]] ? raw[@"clientSecret"] : @"";
    entry.redirectURI = [raw[@"redirectURI"] isKindOfClass:[NSString class]] ? raw[@"redirectURI"] : @"";
    return entry;
}

ApolloAccountCredentialEntry *ApolloAccountCredentialsFor(NSString *username) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return nil;
    NSDictionary *raw = ApolloLoadRawAccountCredentials()[key];
    return ApolloEntryFromRaw(raw);
}

void ApolloAccountCredentialsSet(NSString *username, NSString *clientId, NSString *clientSecret, NSString *redirectURI) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return;
    NSMutableDictionary<NSString *, NSDictionary *> *all = [ApolloLoadRawAccountCredentials() mutableCopy];
    all[key] = @{
        @"clientId": clientId ?: @"",
        @"clientSecret": clientSecret ?: @"",
        @"redirectURI": redirectURI ?: @"",
    };
    ApolloSaveRawAccountCredentials(all);
    ApolloLog(@"[AccountCredentials] Stored per-account credentials for u/%@ (clientId=%@)",
              username, (clientId.length > 0 ? clientId : @"<empty>"));
}

void ApolloAccountCredentialsRemove(NSString *username) {
    NSString *key = ApolloNormalizeUsername(username);
    if (key.length == 0) return;
    NSMutableDictionary<NSString *, NSDictionary *> *all = [ApolloLoadRawAccountCredentials() mutableCopy];
    if (!all[key]) return;
    [all removeObjectForKey:key];
    ApolloSaveRawAccountCredentials(all);
    ApolloLog(@"[AccountCredentials] Removed per-account credentials for u/%@", username);
}

NSDictionary<NSString *, ApolloAccountCredentialEntry *> *ApolloAllAccountCredentials(void) {
    NSDictionary<NSString *, NSDictionary *> *raw = ApolloLoadRawAccountCredentials();
    NSMutableDictionary<NSString *, ApolloAccountCredentialEntry *> *result = [NSMutableDictionary dictionaryWithCapacity:raw.count];
    for (NSString *username in raw) {
        ApolloAccountCredentialEntry *entry = ApolloEntryFromRaw(raw[username]);
        if (entry) result[username] = entry;
    }
    return result;
}

#pragma mark - Resolution

NSString *ApolloSecretForClientId(NSString *clientId) {
    if (clientId.length == 0) return @"";

    // Check every stored per-account entry first.
    NSDictionary<NSString *, ApolloAccountCredentialEntry *> *all = ApolloAllAccountCredentials();
    for (NSString *username in all) {
        ApolloAccountCredentialEntry *entry = all[username];
        if (entry.clientId.length > 0 && [entry.clientId isEqualToString:clientId] && entry.clientSecret.length > 0) {
            return entry.clientSecret;
        }
    }

    // Fall back to the global default, if it's the one being asked about.
    if (sRedditClientId.length > 0 && [sRedditClientId isEqualToString:clientId] && sRedditClientSecret.length > 0) {
        return sRedditClientSecret;
    }

    return @"";
}

NSString *ApolloActiveAccountUsername(void) {
    Class clientClass = objc_getClass("RDKClient");
    if (!clientClass || ![clientClass respondsToSelector:@selector(sharedClient)]) return nil;
    id client = [clientClass sharedClient];
    if (!client) return nil;
    id user = nil;
    @try { user = [client valueForKey:@"currentUser"]; }
    @catch (__unused NSException *e) { return nil; }
    if (!user) return nil;
    NSString *username = nil;
    @try { username = [user valueForKey:@"username"]; }
    @catch (__unused NSException *e) { return nil; }
    return [username isKindOfClass:[NSString class]] ? username : nil;
}

NSString *ApolloEffectiveRedditClientId(void) {
    NSString *active = ApolloActiveAccountUsername();
    if (active) {
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(active);
        if (entry && entry.clientId.length > 0) return entry.clientId;
    }
    return sRedditClientId ?: @"";
}

NSString *ApolloEffectiveRedirectURI(void) {
    NSString *active = ApolloActiveAccountUsername();
    if (active) {
        ApolloAccountCredentialEntry *entry = ApolloAccountCredentialsFor(active);
        if (entry && entry.redirectURI.length > 0) return entry.redirectURI;
    }
    return sRedirectURI.length > 0 ? sRedirectURI : defaultRedirectURI;
}
