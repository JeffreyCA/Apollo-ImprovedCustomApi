#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const ApolloDeletedCommentsObservedThreadNotification;
extern NSString *const ApolloDeletedCommentsArcticCacheUpdatedNotification;

typedef void (^ApolloDeletedCommentsURLSessionCompletion)(NSData *data, NSURLResponse *response, NSError *error);

void ApolloDeletedCommentsHandleRequestObservation(NSURLRequest *request, NSString *source);
ApolloDeletedCommentsURLSessionCompletion ApolloDeletedCommentsMaybeWrapCompletion(NSURLRequest *request, ApolloDeletedCommentsURLSessionCompletion completion);
void ApolloDeletedCommentsInstallDelegateTransformerIfNeeded(NSURLSession *session, NSURLRequest *request);
void ApolloDeletedCommentsRegisterRecoveredComment(NSString *fullName, NSString *reason);
BOOL ApolloDeletedCommentsIsRecoveredComment(NSString *fullName);
NSString *ApolloDeletedCommentsRecoveredReasonForComment(NSString *fullName);
void ApolloDeletedCommentsRegisterDeletedPlaceholder(NSString *fullName, NSString *reason);
BOOL ApolloDeletedCommentsIsDeletedPlaceholder(NSString *fullName);
NSString *ApolloDeletedCommentsDeletedPlaceholderReason(NSString *fullName);
NSDictionary *ApolloDeletedCommentsCachedArchivedComment(NSString *fullName);
BOOL ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject(id comment, NSDictionary *archived, NSString *reason);
BOOL ApolloDeletedCommentsIsRecoveredCommentBody(NSString *author, NSString *body);
NSString *ApolloDeletedCommentsRecoveredReasonForCommentBody(NSString *author, NSString *body);
NSString *ApolloDeletedCommentsDisplayLabelForReason(NSString *reason);
BOOL ApolloDeletedCommentsIsCommentRevealed(NSString *fullName);
BOOL ApolloDeletedCommentsIsCommentBodyRevealed(NSString *author, NSString *body);
void ApolloDeletedCommentsMarkCommentRevealed(NSString *fullName);
void ApolloDeletedCommentsMarkCommentBodyRevealed(NSString *author, NSString *body);
void ApolloDeletedCommentsUnmarkCommentRevealed(NSString *fullName);
void ApolloDeletedCommentsUnmarkCommentBodyRevealed(NSString *author, NSString *body);

#ifdef APOLLO_DELETED_COMMENTS_TESTING
NSString *ApolloDeletedCommentsTestLinkFullNameFromRedditURL(NSURL *url);
BOOL ApolloDeletedCommentsTestBodyLooksDeleted(NSString *body, NSString *bodyHTML);
NSUInteger ApolloDeletedCommentsTestPatchRedditJSONRoot(id root, NSDictionary<NSString *, NSDictionary *> *archivedComments);
BOOL ApolloDeletedCommentsTestArcticResponseShouldCooldown(NSInteger statusCode, NSInteger remaining);
NSString *ApolloDeletedCommentsTestDisplayLabelForReason(NSString *reason);
NSUInteger ApolloDeletedCommentsTestMarkDeletedPlaceholdersInRoot(id root);
NSData *ApolloDeletedCommentsTestPatchResponseImmediate(NSData *data, NSURLRequest *request);
#endif

#ifdef __cplusplus
}
#endif
