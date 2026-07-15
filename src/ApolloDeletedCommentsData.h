#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

extern NSString *const ApolloDeletedCommentsObservedThreadNotification;
extern NSString *const ApolloDeletedCommentsArcticCacheUpdatedNotification;

typedef void (^ApolloDeletedCommentsURLSessionCompletion)(NSData *data, NSURLResponse *response, NSError *error);

// Master gate: global toggle OR any per-thread "Passive" override active.
// Every deleted-comments code path checks this instead of sShowDeletedComments
// directly so passive per-thread enables reuse the whole machinery.
BOOL ApolloDeletedCommentsFeatureActive(void);
// Per-thread overrides (post fullName t3_xxx; bare ids accepted). In-memory
// only; managed by ApolloDeletedCommentsMenu.xm.
void ApolloDeletedCommentsSetThreadOverride(NSString *linkFullName, BOOL enabled);
BOOL ApolloDeletedCommentsHasThreadOverride(NSString *linkFullName);
// Global toggle OR an override for this specific post (t3_xxx or bare id).
BOOL ApolloDeletedCommentsActiveForLink(NSString *linkFullName);
void ApolloDeletedCommentsHandleRequestObservation(NSURLRequest *request, NSString *source);
// Collapse-animation window, stamped by the RDKComment setCollapsed: hook (UI.xm).
// Modules that re-measure list rows (deleted-comments height fixup, inline link
// previews) must defer table begin/endUpdates while this returns > 0: an empty
// update mid-collapse re-queries every row height and restarts the native row
// animations (the "comments collapse weirdly" glitches in #620/#630).
void ApolloDeletedCommentsNoteCollapseEvent(void);
NSTimeInterval ApolloDeletedCommentsCollapseSettleDelayRemaining(void);
ApolloDeletedCommentsURLSessionCompletion ApolloDeletedCommentsMaybeWrapCompletion(NSURLRequest *request, ApolloDeletedCommentsURLSessionCompletion completion);
void ApolloDeletedCommentsInstallDelegateTransformerIfNeeded(NSURLSession *session, NSURLRequest *request);
void ApolloDeletedCommentsRegisterRecoveredComment(NSString *fullName, NSString *reason);
BOOL ApolloDeletedCommentsIsRecoveredComment(NSString *fullName);
NSString *ApolloDeletedCommentsRecoveredReasonForComment(NSString *fullName);
void ApolloDeletedCommentsRegisterDeletedPlaceholder(NSString *fullName, NSString *reason);
BOOL ApolloDeletedCommentsIsDeletedPlaceholder(NSString *fullName);
NSString *ApolloDeletedCommentsDeletedPlaceholderReason(NSString *fullName);
// YES when the Arctic archive answered genuinely and definitively cannot
// restore this comment: it is absent from a coverage-complete tree (and old
// enough that ingestion lag can't explain it), or the archived copy is itself
// redacted. Never set from transient failures / rate limits. Drives the
// integrated UNRECOVERABLE chip state; self-heals if a later fetch finds the
// comment.
BOOL ApolloDeletedCommentsIsUnrecoverableComment(NSString *fullName);
NSDictionary *ApolloDeletedCommentsCachedArchivedComment(NSString *fullName);
BOOL ApolloDeletedCommentsApplyRecoveredArchivedCommentToObject(id comment, NSDictionary *archived, NSString *reason);
BOOL ApolloDeletedCommentsIsRecoveredCommentBody(NSString *author, NSString *body);
NSString *ApolloDeletedCommentsRecoveredReasonForCommentBody(NSString *author, NSString *body);
NSString *ApolloDeletedCommentsDisplayLabelForReason(NSString *reason);
// Markdown-aware Reddit body_html generator (renders links/bold). Shared so every
// recovered-body HTML path produces the same rendered output. Returns nil if empty.
NSString *ApolloDeletedCommentsRedditBodyHTML(NSString *body);
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
