#import <Foundation/Foundation.h>

#import "ApolloSavedItemsDeduplicator.h"

@interface ApolloSavedItemFixture : NSObject
@property(nonatomic, copy) NSString *fullName;
@property(nonatomic, copy) NSString *kindName;
@property(nonatomic, strong) id identifier;
@property(nonatomic, copy) NSString *label;
@end

@implementation ApolloSavedItemFixture
@end

static ApolloSavedItemFixture *Item(NSString *label, NSString *fullName,
                                    NSString *kindName, id identifier) {
    ApolloSavedItemFixture *item = [ApolloSavedItemFixture new];
    item.label = label;
    item.fullName = fullName;
    item.kindName = kindName;
    item.identifier = identifier;
    return item;
}

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"SavedItemsDeduplicatorTestFailure"
                                       reason:message userInfo:nil];
    }
}

static NSArray<NSString *> *Labels(NSArray *items) {
    return [items valueForKey:@"label"];
}

static void TestDuplicatePostAndComment(void) {
    NSArray *input = @[
        Item(@"post", @"t3_post", @"t3", @"post"),
        Item(@"post duplicate", @"t3_post", @"t3", @"post"),
        Item(@"comment", @"t1_comment", @"t1", @"comment"),
        Item(@"comment duplicate", @"t1_comment", @"t1", @"comment"),
    ];
    Require([Labels(ApolloDeduplicateSavedItems(input)) isEqual:@[ @"post", @"comment" ]],
            @"keeps the first post and comment in server order");
}

static void TestFallbackDistinguishesKinds(void) {
    NSArray *input = @[
        Item(@"post", nil, @"t3", @42),
        Item(@"comment", nil, @"t1", @42),
        Item(@"post duplicate", nil, @"t3", @42),
    ];
    Require([Labels(ApolloDeduplicateSavedItems(input)) isEqual:@[ @"post", @"comment" ]],
            @"kind plus identifier prevents post/comment collisions");
}

static void TestIdentitylessObjectsArePreserved(void) {
    ApolloSavedItemFixture *first = Item(@"first", nil, nil, nil);
    ApolloSavedItemFixture *second = Item(@"second", nil, nil, nil);
    NSArray *input = @[ first, second, first ];
    NSArray *output = ApolloDeduplicateSavedItems(input);
    Require(output.count == 3, @"identity-less objects are never dropped");
    Require(output[0] == first && output[1] == second && output[2] == first,
            @"identity-less object order and occurrences are preserved");
}

static void TestNilEmptyAndUniqueInputsRemainUnchanged(void) {
    Require(ApolloDeduplicateSavedItems(nil) == nil, @"nil stays nil");
    NSArray *empty = @[];
    Require(ApolloDeduplicateSavedItems(empty) == empty, @"empty array identity is preserved");
    NSArray *unique = @[
        Item(@"first", @"t3_first", @"t3", @"first"),
        Item(@"second", @"t3_second", @"t3", @"second"),
    ];
    Require(ApolloDeduplicateSavedItems(unique) == unique,
            @"an already-unique response is returned without allocation");
}

int main(void) {
    @autoreleasepool {
        TestDuplicatePostAndComment();
        TestFallbackDistinguishesKinds();
        TestIdentitylessObjectsArePreserved();
        TestNilEmptyAndUniqueInputsRemainUnchanged();
        NSLog(@"saved_items_deduplicator_tests passed");
    }
    return 0;
}
