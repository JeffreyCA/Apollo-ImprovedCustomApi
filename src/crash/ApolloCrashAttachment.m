#import "crash/ApolloCrashAttachment.h"

@implementation ApolloCrashAttachment

+ (instancetype)attachmentWithIdentifier:(NSString *)identifier
                                filename:(NSString *)filename
                                mimeType:(NSString *)mimeType
                            textContents:(NSString *)textContents {
    ApolloCrashAttachment *attachment = [[self alloc] init];
    if (attachment) {
        attachment->_identifier = [identifier copy];
        attachment->_filename = [filename copy];
        attachment->_mimeType = [mimeType copy];
        attachment->_textContents = [textContents copy];
    }
    return attachment;
}

@end
