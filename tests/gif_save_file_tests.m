#import <Foundation/Foundation.h>
#define ApolloLog(...) do {} while (0)
@interface ApolloGIFSaveActivityContext : NSObject
@property(nonatomic,copy) NSURL *sourceURL;
@property(nonatomic,copy) NSURL *directoryURL;
@property(nonatomic,copy) NSURL *fileURL;
@property(nonatomic) BOOL saveToAlbum;
- (BOOL)prepareFile;
@end
#include "GIFSaveFile.inc"
static int checks;
static void Check(BOOL result, NSString *message) {
    checks++;
    if (!result) { NSLog(@"FAIL: %@",message); exit(1); }
}
int main(void) { @autoreleasepool {
    NSURL *sourceDir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:sourceDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *source=[sourceDir URLByAppendingPathComponent:@"Image.gif"];
    NSData *original=[@"GIF89a original animated file bytes" dataUsingEncoding:NSUTF8StringEncoding];
    [original writeToURL:source atomically:YES];
    NSURL *ownedDir; NSURL *ownedFile;
    @autoreleasepool {
        ApolloGIFSaveActivityContext *context=[ApolloGIFSaveActivityContext new];
        context.sourceURL=source;
        Check([context prepareFile],@"selected file is staged");
        ownedDir=context.directoryURL; ownedFile=context.fileURL;
        Check(![ownedFile isEqual:source],@"staging does not reuse Apollo's mutable path");
        Check([[NSData dataWithContentsOfURL:ownedFile] isEqual:original],@"original bytes preserved");
        [[@"next conversion" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:source atomically:YES];
        Check([[NSData dataWithContentsOfURL:ownedFile] isEqual:original],@"later conversion cannot overwrite selected GIF");
        [NSFileManager.defaultManager removeItemAtURL:source error:NULL];
        Check([[NSData dataWithContentsOfURL:ownedFile] isEqual:original],@"native cleanup cannot remove selected GIF");
        context=nil;
    }
    Check(![NSFileManager.defaultManager fileExistsAtPath:ownedDir.path],@"staging directory released with operation");
    Check([NSFileManager.defaultManager fileExistsAtPath:sourceDir.path],@"cleanup leaves unrelated directory intact");
    @autoreleasepool {
        ApolloGIFSaveActivityContext *missing=[ApolloGIFSaveActivityContext new]; missing.sourceURL=source;
        Check(![missing prepareFile],@"missing GIF produces a reported handoff failure");
        ownedDir=missing.directoryURL; missing=nil;
    }
    Check(![NSFileManager.defaultManager fileExistsAtPath:ownedDir.path],@"failed staging cleaned up");
    [NSFileManager.defaultManager removeItemAtURL:sourceDir error:NULL];
    NSLog(@"PASS: %d GIF file handoff checks",checks);
} return 0; }
