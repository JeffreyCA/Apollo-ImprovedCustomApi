#import <Foundation/Foundation.h>

#import "ApolloDeletedCommentsData.h"

extern BOOL sTapToRevealDeletedComments;

static id MutableJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        @throw [NSException exceptionWithName:@"DeletedCommentsTestFailure" reason:message userInfo:nil];
    }
}

static NSDictionary *Archived(NSString *identifier, NSString *body, NSDictionary *metadata) {
    return @{
        @"id": identifier,
        @"name": [@"t1_" stringByAppendingString:identifier],
        @"body": body ?: @"",
        @"author": @"archive_author",
        @"score": @42,
        @"created_utc": @1700000000,
        @"parent_id": @"t3_thread",
        @"link_id": @"t3_thread",
        @"_meta": metadata ?: @{},
    };
}

static NSMutableDictionary *VisibleDeletedRoot(void) {
    return MutableJSON(@{
        @"kind": @"Listing",
        @"data": @{
            @"children": @[
                @{
                    @"kind": @"t1",
                    @"data": @{
                        @"id": @"c1",
                        @"name": @"t1_c1",
                        @"body": @"[deleted]",
                        @"body_html": @"&lt;div class=\"md\"&gt;&lt;p&gt;[deleted]&lt;/p&gt;&lt;/div&gt;",
                        @"author": @"[deleted]",
                        @"score": @0,
                        @"replies": @"",
                    },
                },
            ],
        },
    });
}

static NSMutableDictionary *VisibleRemovedRoot(void) {
    return MutableJSON(@{
        @"kind": @"Listing",
        @"data": @{
            @"children": @[
                @{
                    @"kind": @"t1",
                    @"data": @{
                        @"id": @"c2",
                        @"name": @"t1_c2",
                        @"body": @"[removed]",
                        @"body_html": @"&lt;div class=\"md\"&gt;&lt;p&gt;[removed]&lt;/p&gt;&lt;/div&gt;",
                        @"author": @"[deleted]",
                        @"score": @0,
                        @"replies": @"",
                    },
                },
            ],
        },
    });
}

static NSMutableDictionary *MoreRoot(NSArray *children, NSNumber *count) {
    return MutableJSON(@{
        @"kind": @"Listing",
        @"data": @{
            @"children": @[
                @{
                    @"kind": @"more",
                    @"data": @{
                        @"children": children,
                        @"count": count,
                        @"id": children.firstObject ?: @"",
                        @"name": children.firstObject ? [@"t1_" stringByAppendingString:children.firstObject] : @"",
                    },
                },
            ],
        },
    });
}

static void TestURLExtraction(void) {
    Require([ApolloDeletedCommentsTestLinkFullNameFromRedditURL([NSURL URLWithString:@"https://www.reddit.com/r/test/comments/abc123/title/"]) isEqualToString:@"t3_abc123"], @"extracts /comments/<id>");
    Require([ApolloDeletedCommentsTestLinkFullNameFromRedditURL([NSURL URLWithString:@"https://oauth.reddit.com/comments/abc123.json?raw_json=1"]) isEqualToString:@"t3_abc123"], @"extracts /comments/<id>.json");
    Require([ApolloDeletedCommentsTestLinkFullNameFromRedditURL([NSURL URLWithString:@"https://oauth.reddit.com/api/morechildren?link_id=t3_link&children=a,b"]) isEqualToString:@"t3_link"], @"extracts link_id query");
    Require([ApolloDeletedCommentsTestLinkFullNameFromRedditURL([NSURL URLWithString:@"https://oauth.reddit.com/api/info?id=abc123"]) isEqualToString:@"t3_abc123"], @"extracts id query");
    Require([ApolloDeletedCommentsTestLinkFullNameFromRedditURL([NSURL URLWithString:@"https://oauth.reddit.com/foo?article=abc123"]) isEqualToString:@"t3_abc123"], @"extracts article query");
}

static void TestDeletedBodyPolicy(void) {
    Require(ApolloDeletedCommentsTestBodyLooksDeleted(@"[deleted]", nil), @"detects [deleted]");
    Require(ApolloDeletedCommentsTestBodyLooksDeleted(@"[removed]", nil), @"detects [removed]");
    Require(!ApolloDeletedCommentsTestBodyLooksDeleted(@"", nil), @"empty body alone is not deleted");
    Require(ApolloDeletedCommentsTestBodyLooksDeleted(@"", @"&lt;p&gt;Removed by moderator&lt;/p&gt;"), @"detects removed HTML without body");
    Require(!ApolloDeletedCommentsTestBodyLooksDeleted(@"hello", @"&lt;p&gt;Removed by moderator&lt;/p&gt;"), @"stale removed HTML does not override visible body");
    Require(!ApolloDeletedCommentsTestBodyLooksDeleted(@"normal comment", nil), @"normal body is not deleted");
}

static void TestVisibleReplacement(void) {
    NSMutableDictionary *root = VisibleDeletedRoot();
    NSUInteger patched = ApolloDeletedCommentsTestPatchRedditJSONRoot(root, @{@"t1_c1": Archived(@"c1", @"Recovered body", @{@"removal_type": @"deleted"})});
    NSDictionary *data = root[@"data"][@"children"][0][@"data"];
    Require(patched == 1, @"patches one visible comment");
    Require([data[@"body"] isEqualToString:@"Recovered body"], @"replaces body");
    Require([data[@"author"] isEqualToString:@"archive_author"], @"replaces author");
    Require([data[@"score"] isEqual:@42], @"replaces score");
    Require([data[@"apollo_recovered_deleted_comment"] boolValue], @"sets marker");
    Require([data[@"apollo_recovered_deleted_reason"] isEqualToString:@"user_deleted"], @"sets reason");
    Require(data[@"author_flair_text"] == nil, @"does not replace author flair with recovered reason");
    Require([data[@"user_vote"] isEqual:@0] && [data[@"likes"] isKindOfClass:[NSNull class]], @"neutralizes vote metadata");
}

static void TestTapToRevealPatchDoesNotEmitNativeSpoiler(void) {
    BOOL previousTapSetting = sTapToRevealDeletedComments;
    sTapToRevealDeletedComments = YES;

    NSMutableDictionary *root = VisibleDeletedRoot();
    NSUInteger patched = ApolloDeletedCommentsTestPatchRedditJSONRoot(root, @{@"t1_c1": Archived(@"c1", @"Recovered body", @{@"removal_type": @"deleted"})});
    NSDictionary *data = root[@"data"][@"children"][0][@"data"];
    NSString *body = data[@"body"];
    NSString *bodyHTML = data[@"body_html"];

    sTapToRevealDeletedComments = previousTapSetting;

    Require(patched == 1, @"tap-to-reveal patches one visible comment");
    Require([body isEqualToString:@"DELETED BY USER"], @"tap-to-reveal hides the recovered body before first render");
    Require([body rangeOfString:@">!"].location == NSNotFound, @"tap-to-reveal body does not use native spoiler markdown");
    Require([bodyHTML rangeOfString:@"md-spoiler-text"].location == NSNotFound, @"tap-to-reveal body_html does not use native spoiler HTML");
    Require([bodyHTML rangeOfString:@"DELETED BY USER"].location != NSNotFound, @"tap-to-reveal body_html uses the reason label before first render");
    Require([bodyHTML rangeOfString:@"Recovered body"].location == NSNotFound, @"tap-to-reveal body_html does not expose recovered text before reveal");
}

static void TestMoreExpansion(void) {
    NSMutableDictionary *root = MoreRoot(@[@"c1", @"c2"], @2);
    NSDictionary *archive = @{
        @"t1_c1": Archived(@"c1", @"Recovered one", @{@"was_deleted_later": @YES}),
        @"t1_c2": Archived(@"c2", @"Recovered two", @{@"was_deleted_later": @YES}),
    };
    NSUInteger patched = ApolloDeletedCommentsTestPatchRedditJSONRoot(root, archive);
    NSArray *children = root[@"data"][@"children"];
    Require(patched == 2, @"expands complete more cluster");
    Require(children.count == 2, @"replaces more with recovered things");
    Require([children[0][@"kind"] isEqualToString:@"t1"], @"first replacement is comment");
    Require([children[1][@"data"][@"body"] isEqualToString:@"Recovered two"], @"second replacement body");
}

static void TestMixedMoreKeepsRemainingChildren(void) {
    NSMutableDictionary *root = MoreRoot(@[@"c1", @"c2"], @2);
    NSDictionary *archive = @{
        @"t1_c1": Archived(@"c1", @"Recovered one", @{@"was_deleted_later": @YES}),
        @"t1_c2": Archived(@"c2", @"[deleted]", @{@"was_deleted_later": @YES}),
    };
    NSUInteger patched = ApolloDeletedCommentsTestPatchRedditJSONRoot(root, archive);
    NSArray *children = root[@"data"][@"children"];
    Require(patched == 1, @"partially expands mixed deleted cluster");
    Require(children.count == 2, @"keeps one recovered thing and one more object");
    Require([children[0][@"kind"] isEqualToString:@"t1"], @"inserts recoverable child");
    Require([children[1][@"kind"] isEqualToString:@"more"], @"keeps unresolved child in more");
    Require([children[1][@"data"][@"children"] isEqualToArray:@[@"c2"]], @"remaining more child preserved");
}

static void TestNoOp(void) {
    NSMutableDictionary *root = VisibleDeletedRoot();
    NSUInteger patched = ApolloDeletedCommentsTestPatchRedditJSONRoot(root, @{});
    Require(patched == 0, @"no archive is no-op");
    Require([root[@"data"][@"children"][0][@"data"][@"body"] isEqualToString:@"[deleted]"], @"body remains unchanged");
}

static void TestPlaceholderMetadata(void) {
    NSMutableDictionary *deletedRoot = VisibleDeletedRoot();
    NSUInteger deletedMarked = ApolloDeletedCommentsTestMarkDeletedPlaceholdersInRoot(deletedRoot);
    NSDictionary *deletedData = deletedRoot[@"data"][@"children"][0][@"data"];
    Require(deletedMarked == 1, @"marks deleted placeholder");
    Require([deletedData[@"apollo_deleted_comment_placeholder"] boolValue], @"sets deleted placeholder marker");
    Require([deletedData[@"apollo_deleted_comment_placeholder_reason"] isEqualToString:@"user_deleted"], @"deleted placeholder reason");

    NSMutableDictionary *removedRoot = VisibleRemovedRoot();
    NSUInteger removedMarked = ApolloDeletedCommentsTestMarkDeletedPlaceholdersInRoot(removedRoot);
    NSDictionary *removedData = removedRoot[@"data"][@"children"][0][@"data"];
    Require(removedMarked == 1, @"marks removed placeholder");
    Require([removedData[@"apollo_deleted_comment_placeholder"] boolValue], @"sets removed placeholder marker");
    Require([removedData[@"apollo_deleted_comment_placeholder_reason"] isEqualToString:@"moderator_removed"], @"removed placeholder reason");
}

static void TestIntactCommentFromDeletedAccountIsPreserved(void) {
    NSMutableDictionary *root = MutableJSON(@{
        @"kind": @"Listing",
        @"data": @{
            @"children": @[
                @{
                    @"kind": @"t1",
                    @"data": @{
                        @"id": @"intact",
                        @"name": @"t1_intact",
                        @"body": @"This historical comment is still completely intact.",
                        @"body_html": @"&lt;div class=\"md\"&gt;&lt;p&gt;This historical comment is still completely intact.&lt;/p&gt;&lt;/div&gt;",
                        @"author": @"[deleted]",
                        // Reddit can retain stale collapse metadata after an
                        // account deletion. Neither field may override a body.
                        @"collapsed": @YES,
                        @"collapsed_reason_code": @"DELETED",
                        @"replies": @"",
                    },
                },
            ],
        },
    });

    NSUInteger marked = ApolloDeletedCommentsTestMarkDeletedPlaceholdersInRoot(root);
    NSDictionary *data = root[@"data"][@"children"][0][@"data"];
    Require(marked == 0, @"deleted author does not mark an intact comment");
    Require(data[@"apollo_deleted_comment_placeholder"] == nil, @"intact comment gets no placeholder marker");
    Require([data[@"collapsed"] boolValue], @"intact comment keeps its native collapse state");

    NSUInteger patched = ApolloDeletedCommentsTestPatchRedditJSONRoot(root,
        @{@"t1_intact": Archived(@"intact", @"This historical comment is still completely intact.", @{})});
    Require(patched == 0, @"archive does not rewrite an intact deleted-account comment");
    Require([data[@"author"] isEqualToString:@"[deleted]"], @"archive does not resurrect the deleted username");
    Require([data[@"body"] isEqualToString:@"This historical comment is still completely intact."], @"intact body is preserved");
}

static void TestImmediatePatchReturnsPlaceholderWithoutArchive(void) {
    NSMutableDictionary *root = VisibleRemovedRoot();
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/comments/thread.json?raw_json=1"]];
    NSData *patchedData = ApolloDeletedCommentsTestPatchResponseImmediate(data, request);
    NSDictionary *patched = [NSJSONSerialization JSONObjectWithData:patchedData options:0 error:nil];
    NSDictionary *commentData = patched[@"data"][@"children"][0][@"data"];
    Require([commentData[@"body"] isEqualToString:@"[removed]"], @"immediate patch leaves body as placeholder");
    Require([commentData[@"apollo_deleted_comment_placeholder"] boolValue], @"immediate patch marks placeholder");
    Require(commentData[@"apollo_recovered_deleted_comment"] == nil, @"immediate patch does not pretend placeholder is recovered");
}

static void TestArcticCooldownPolicy(void) {
    Require(ApolloDeletedCommentsTestArcticResponseShouldCooldown(429, NSIntegerMax), @"429 triggers cooldown");
    Require(ApolloDeletedCommentsTestArcticResponseShouldCooldown(200, 3), @"low remaining quota triggers cooldown");
    Require(!ApolloDeletedCommentsTestArcticResponseShouldCooldown(200, 4), @"remaining quota above threshold does not trigger cooldown");
    Require(!ApolloDeletedCommentsTestArcticResponseShouldCooldown(200, NSIntegerMax), @"missing quota header does not trigger cooldown");
}

static void TestReasonLabels(void) {
    Require([ApolloDeletedCommentsTestDisplayLabelForReason(@"user_deleted") isEqualToString:@"DELETED BY USER"], @"user-deleted reason label");
    Require([ApolloDeletedCommentsTestDisplayLabelForReason(@"moderator_removed") isEqualToString:@"REMOVED BY MOD"], @"mod-deleted reason label");
    Require([ApolloDeletedCommentsTestDisplayLabelForReason(nil) isEqualToString:@"REMOVED BY MOD"], @"default reason label");
}

int main(void) {
    @autoreleasepool {
        TestURLExtraction();
        TestDeletedBodyPolicy();
        TestVisibleReplacement();
        TestTapToRevealPatchDoesNotEmitNativeSpoiler();
        TestMoreExpansion();
        TestMixedMoreKeepsRemainingChildren();
        TestNoOp();
        TestPlaceholderMetadata();
        TestIntactCommentFromDeletedAccountIsPreserved();
        TestImmediatePatchReturnsPlaceholderWithoutArchive();
        TestArcticCooldownPolicy();
        TestReasonLabels();
        NSLog(@"deleted_comments_tests passed");
    }
    return 0;
}
