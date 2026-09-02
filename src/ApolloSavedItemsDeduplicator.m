#import "ApolloSavedItemsDeduplicator.h"

#import <objc/message.h>

static id ApolloSavedItemValue(id item, SEL selector) {
    if (!item || ![item respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(item, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *ApolloSavedItemString(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)value;
        return string.length > 0 ? string : nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSString *ApolloSavedItemIdentity(id item) {
    NSString *fullName = ApolloSavedItemString(ApolloSavedItemValue(item, @selector(fullName)));
    if (fullName.length > 0) return [@"fullname:" stringByAppendingString:fullName];

    NSString *kind = ApolloSavedItemString(ApolloSavedItemValue(item, @selector(kindName)));
    NSString *identifier = ApolloSavedItemString(ApolloSavedItemValue(item, @selector(identifier)));
    if (kind.length == 0 || identifier.length == 0) return nil;
    return [NSString stringWithFormat:@"kind:%@:%@", kind, identifier];
}

NSArray *ApolloDeduplicateSavedItems(NSArray *items) {
    if (items.count < 2) return items;

    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:items.count];
    __block NSMutableArray *deduplicated = nil;

    [items enumerateObjectsUsingBlock:^(id item, NSUInteger index, __unused BOOL *stop) {
        NSString *identity = ApolloSavedItemIdentity(item);
        BOOL duplicate = identity.length > 0 && [seen containsObject:identity];
        if (!duplicate) {
            if (identity.length > 0) [seen addObject:identity];
            if (deduplicated) [deduplicated addObject:item];
            return;
        }

        if (!deduplicated) {
            deduplicated = [[items subarrayWithRange:NSMakeRange(0, index)] mutableCopy];
        }
    }];

    return deduplicated ?: items;
}
