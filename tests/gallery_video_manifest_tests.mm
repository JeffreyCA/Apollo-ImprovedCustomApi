#import <Foundation/Foundation.h>

// The runner extracts this Foundation-only section from the shipping .xm.
// These fixtures exercise the production parser, with no copied implementation
// and no extra exported symbol or test condition in the tweak.
#include "ApolloGalleryVideoManifestProduction.inc"

static NSUInteger sManifestChecks;
static void CheckManifest(NSString *name, NSString *xml, BOOL parsedExpected, NSString *videoExpected, NSString *audioExpected, BOOL declaredExpected) {
    NSURL *video = nil, *audio = nil;
    BOOL declared = NO;
    BOOL parsed = ApolloGalleryExportParseManifest([xml dataUsingEncoding:NSUTF8StringEncoding], [NSURL URLWithString:@"https://v.redd.it/asset/DASHPlaylist.mpd"], &video, &audio, &declared);
    BOOL ok = parsed == parsedExpected && declared == declaredExpected &&
        ((videoExpected == nil && video == nil) || [video.absoluteString isEqualToString:videoExpected]) &&
        ((audioExpected == nil && audio == nil) || [audio.absoluteString isEqualToString:audioExpected]);
    if (!ok) {
        NSLog(@"FAIL %@ parsed=%d video=%@ audio=%@ declared=%d", name, parsed, video, audio, declared);
        exit(1);
    }
    sManifestChecks++;
}
int main(void) {
    @autoreleasepool {
        CheckManifest(@"inherited MIME and highest quality",
            @"<MPD><Period><AdaptationSet mimeType='video/mp4'><Representation bandwidth='10'><BaseURL>low.mp4</BaseURL></Representation><Representation bandwidth='40'><BaseURL>high.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType='audio/mp4'><Representation bandwidth='5'><BaseURL>audio-low</BaseURL></Representation><Representation bandwidth='8'><BaseURL>audio-high</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType='text/vtt'><Representation bandwidth='999999'><BaseURL>subtitles.vtt</BaseURL></Representation></AdaptationSet></Period></MPD>",
            YES, @"https://v.redd.it/asset/high.mp4", @"https://v.redd.it/asset/audio-high", YES);
        CheckManifest(@"representation MIME, extensionless and XML entity",
            @"<MPD><Period><AdaptationSet><Representation mimeType='video/mp4' bandwidth='20'><BaseURL>DASH_720?x=1&amp;y=2</BaseURL></Representation><Representation mimeType='audio/mp4'><BaseURL>audio</BaseURL></Representation></AdaptationSet></Period></MPD>",
            YES, @"https://v.redd.it/asset/DASH_720?x=1&y=2", @"https://v.redd.it/asset/audio", YES);
        CheckManifest(@"valid silent video",
            @"<MPD><Period><AdaptationSet contentType='video'><Representation><BaseURL>DASH_720</BaseURL></Representation></AdaptationSet></Period></MPD>",
            YES, @"https://v.redd.it/asset/DASH_720", nil, NO);
        CheckManifest(@"declared missing audio",
            @"<MPD><Period><AdaptationSet contentType='video'><Representation><BaseURL>DASH_720</BaseURL></Representation></AdaptationSet><AdaptationSet contentType='audio'><Representation/></AdaptationSet></Period></MPD>",
            YES, @"https://v.redd.it/asset/DASH_720", nil, YES);
        CheckManifest(@"unknown kind is not video", @"<MPD><Representation><BaseURL>unknown.mp4</BaseURL></Representation></MPD>", YES, nil, nil, NO);
        CheckManifest(@"explicit subtitle override", @"<MPD><AdaptationSet contentType='video'><Representation mimeType='text/vtt'><BaseURL>subtitle.vtt</BaseURL></Representation></AdaptationSet></MPD>", YES, nil, nil, NO);
        CheckManifest(@"segment template audio unsupported",
            @"<MPD><AdaptationSet contentType='video'><Representation><BaseURL>v.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet contentType='audio'><SegmentTemplate media='a$Number$.m4s'/><Representation><BaseURL>audio.mp4</BaseURL></Representation></AdaptationSet></MPD>",
            YES, @"https://v.redd.it/asset/v.mp4", nil, YES);
        CheckManifest(@"scoped BaseURL",
            @"<MPD><BaseURL>https://cdn.example/</BaseURL><Period><BaseURL>folder/</BaseURL><AdaptationSet contentType='video'><BaseURL>clips/</BaseURL><Representation><BaseURL>video.mp4</BaseURL><SegmentBase/></Representation></AdaptationSet></Period></MPD>",
            YES, @"https://cdn.example/folder/clips/video.mp4", nil, NO);
        CheckManifest(@"namespace and CDATA",
            @"<d:MPD xmlns:d='urn:mpeg:dash:schema:mpd:2011'><d:AdaptationSet contentType='video'><d:Representation><d:BaseURL><![CDATA[video.mp4?x=1&y=2]]></d:BaseURL></d:Representation></d:AdaptationSet></d:MPD>",
            YES, @"https://v.redd.it/asset/video.mp4?x=1&y=2", nil, NO);
        CheckManifest(@"never manifest as file", @"<MPD><Representation mimeType='video/mp4'><BaseURL>DASHPlaylist.mpd</BaseURL></Representation></MPD>", YES, nil, nil, NO);
        CheckManifest(@"malformed XML", @"<MPD><AdaptationSet>", NO, nil, nil, NO);
        CheckManifest(@"wrong XML root", @"<html><MPD/></html>", NO, nil, nil, NO);
        CheckManifest(@"empty XML", @"", NO, nil, nil, NO);
        NSCAssert([ApolloGalleryExportRedditAssetID([NSURL URLWithString:@"https://v.redd.it/asset/DASHPlaylist.mpd"]) isEqualToString:@"asset"], @"manifest URL identifies its Reddit video");
        NSCAssert(ApolloGalleryExportRedditAssetID([NSURL URLWithString:@"https://fake-v.redd.it/asset/DASHPlaylist.mpd"]) == nil, @"similar hosts do not enter the Reddit exporter");
        NSCAssert(ApolloGalleryExportRedditAssetID([NSURL URLWithString:@"https://v.redd.it/"]) == nil, @"an empty asset path cannot be exported");
        printf("gallery_video_manifest_tests: %lu XML cases and 3 asset URL checks passed\n", (unsigned long)sManifestChecks);
    }
    return 0;
}
