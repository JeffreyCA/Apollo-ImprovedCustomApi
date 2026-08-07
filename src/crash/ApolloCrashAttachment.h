#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A text attachment destined for the report.apolloreborn.app form: the
// sanitized crash JSON, its human-readable summary, or (opt-in) the Reborn
// debug log. `identifier` is a native-side handle the web bridge echoes back
// in its submission confirmation so ApolloReportViewController can tell
// whether the crash report itself was actually part of what got sent.
@interface ApolloCrashAttachment : NSObject

+ (instancetype)attachmentWithIdentifier:(NSString *)identifier
                                filename:(NSString *)filename
                                mimeType:(NSString *)mimeType
                            textContents:(NSString *)textContents;

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *filename;
@property (nonatomic, copy, readonly) NSString *mimeType;
@property (nonatomic, copy, readonly) NSString *textContents;

// YES for the attachments whose confirmed submission should delete the local
// KSCrash report (the crash JSON itself, not the optional log).
@property (nonatomic, assign) BOOL representsCrashReport;

@end

NS_ASSUME_NONNULL_END
