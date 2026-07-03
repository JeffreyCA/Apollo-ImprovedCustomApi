#import <Foundation/Foundation.h>

/// Bootstrap markdown toolbar Gif injection. Called from Tweak.xm %ctor.
void ApolloMarkdownGifInstall(void);

/// Cached regex matching the `![gif](giphy|<id>)` tokens this module inserts
/// when the user picks a GIF from the toolbar. Shared with the submit-form
/// rewriter (`ApolloImageUploadHost.xm`) and the body-text renderer
/// (`ApolloMedia.xm`) so all three sites agree on the exact token shape.
/// Capture group 1 is the bare Giphy GIF ID.
NSRegularExpression *ApolloNativeGiphyMarkdownTokenRegex(void);

/// Comment Link Host support (UDKeyCommentLinkHost / sCommentLinkHost). The
/// markdown toolbar's photo-button hook in ApolloMarkdownToolbarGif.xm arms a
/// short window when the tap comes from a comment/reply editor;
/// ApolloImageUploadHost.xm consults it to route that upload to the chosen link
/// host and post it as a plain link instead of native Reddit media.
#ifdef __cplusplus
extern "C" {
#endif
BOOL ApolloCommentLinkUploadPending(void);
void ApolloCommentLinkClearUpload(void);
/// Keyboard-anchored toast confirming the plain-link upload ("Uploaded to
/// <hostName> — ..."), shown once per compose session.
void ApolloCommentLinkShowUploadedToast(NSString *hostName);
#ifdef __cplusplus
}
#endif
