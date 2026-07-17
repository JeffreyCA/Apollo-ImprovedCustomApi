#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ApolloHiddenContentKind) {
    ApolloHiddenContentKindPost = 0,
    ApolloHiddenContentKindComment,
};

// Hidden: still intact live, just excluded from the account's own listing.
// Removed: a moderator/AutoMod/admin took the content down (shell still
// exists). Deleted: the user (or account) deleted it. See
// ApolloHiddenContentClassify for how these are told apart.
typedef NS_ENUM(NSInteger, ApolloHiddenContentReason) {
    ApolloHiddenContentReasonHidden = 0,
    ApolloHiddenContentReasonDeleted,
    ApolloHiddenContentReasonRemoved,
};

@interface ApolloHiddenContentItem : NSObject
@property (nonatomic, copy) NSString *fullName;   // e.g. t3_abc123 / t1_abc123
@property (nonatomic, assign) ApolloHiddenContentKind kind;
@property (nonatomic, assign) ApolloHiddenContentReason reason;
// Human-readable "who" -- "Moderator"/"AutoMod"/"Reddit Admins" for Removed,
// "Author" for Deleted. Nil for Hidden, or when unknown.
@property (nonatomic, copy, nullable) NSString *removalDetail;
@property (nonatomic, copy, nullable) NSString *title;       // post title; nil for comments
@property (nonatomic, copy, nullable) NSString *body;        // selftext / comment body
@property (nonatomic, copy, nullable) NSString *subreddit;
@property (nonatomic, copy, nullable) NSString *permalink;
@property (nonatomic, strong, nullable) NSDate *createdDate;
@end

typedef void (^ApolloHiddenContentFetchCompletion)(NSArray<ApolloHiddenContentItem *> * _Nullable items, NSString * _Nullable errorMessage);

// Diffs `username`'s Arctic Shift archive against their live /submitted or
// /comments listing; archived items missing from the live listing come back
// classified hidden or deleted, newest-first. Scoped to one `kind` per call --
// Arctic Shift is shared/unauthenticated/rate-limited, and firing posts+comments
// concurrently occasionally trips a transient error on one of the two. Cached
// per username+kind; pass forceRefresh:YES to bypass (e.g. pull-to-refresh).
void ApolloHiddenContentFetch(NSString *username, ApolloHiddenContentKind kind, BOOL forceRefresh, ApolloHiddenContentFetchCompletion completion);

NS_ASSUME_NONNULL_END
