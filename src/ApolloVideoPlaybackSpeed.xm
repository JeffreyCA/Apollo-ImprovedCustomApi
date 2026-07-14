// ApolloVideoPlaybackSpeed.xm
//
// Adds two extra playback-speed options — 0.75× and 1.25× — to Apollo's
// built-in video player speed menu (GitHub issue #445).
//
// How Apollo's speed menu works (reverse-engineered from the iOS 26 binary):
//
//   • The fullscreen media viewer (`MediaViewerController`, ObjC name
//     `_TtC6Apollo21MediaViewerController`) shows a native iOS context `UIMenu`
//     when you long-press the video. One of its rows is a "Playback Speed"
//     SUBMENU — a `UIMenu` whose children are the rows "0.25×", "0.5×",
//     "Normal", "1.5×", "2×" (× is U+00D7), each with a custom animal glyph and
//     a checkmark (UIMenuElementStateOn) on the currently-selected speed.
//
//   • The selected speed is stored on the controller as `videoPlaybackSpeed`
//     (a Swift `Float?` ivar: 4-byte value at offset, 1-byte "has value" flag
//     at offset+4; flag == 0 means .some, flag != 0 means .none/nil).
//
//   • When playback starts the controller applies `player.setRate(
//     videoPlaybackSpeed ?? 1.0)`. When the speed is changed live while playing
//     it calls `player.setRate(newSpeed)` (only if `player.rate != 0`, i.e. it
//     does not un-pause a paused video).
//
// Interception: Apollo builds that submenu through the Swift UIKit overlay via a
// path that bypasses every public UIMenu/UIAction/UIDeferredMenuElement
// creation API (verified — none of those hooks fire). But UIKit always reads
// `-[UIMenu children]` to render the rows, so we hook that getter: when a menu's
// children are the speed rows, we return a cached augmented list with our own
// "0.75×"/"1.25×" `UIAction`s spliced in. Their handlers replicate Apollo's
// apply path in ObjC (write the `videoPlaybackSpeed` ivar, then `setRate:` if
// the player is playing). Detection is content-based (≥3 rows whose titles are
// "<number>×"), which is specific to the speed picker and localization-safe.

#import "ApolloCommon.h"

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kMediaViewerClassName = @"_TtC6Apollo21MediaViewerController";

// The two speeds we add, and the multiplication sign Apollo uses in its labels.
static const float kSpeedSlow = 0.75f;   // inserted after 0.5×
static const float kSpeedFast = 1.25f;   // inserted before 1.5×

static NSString *MultiplicationSign(void) {
    return [NSString stringWithFormat:@"%C", (unichar)0x00D7];
}

// "0.75×" / "1.25×" / "0.5×" / "1.5×" — built with the real U+00D7 so source
// encoding can't drift.
static NSString *SpeedTitle(float speed) {
    NSString *num;
    if (speed == 0.25f)      num = @"0.25";
    else if (speed == 0.5f)  num = @"0.5";
    else if (speed == 0.75f) num = @"0.75";
    else if (speed == 1.25f) num = @"1.25";
    else if (speed == 1.5f)  num = @"1.5";
    else if (speed == 2.0f)  num = @"2";
    else                     num = [NSString stringWithFormat:@"%g", speed];
    return [num stringByAppendingString:MultiplicationSign()];
}

#pragma mark - Current media viewer tracking

// The visible fullscreen media viewer. Set in -viewDidAppear: and cleared on
// disappear. The speed menu is only ever presented while one is on screen, so
// this is the controller whose speed we read (for checkmarks) and mutate.
static __weak UIViewController *sCurrentMediaViewer = nil;

static UIViewController *SearchMediaViewer(UIViewController *vc, Class cls) {
    if (!vc) return nil;
    if ([vc isKindOfClass:cls]) return vc;
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = SearchMediaViewer(child, cls);
        if (found) return found;
    }
    return SearchMediaViewer(vc.presentedViewController, cls);
}

// Prefer the tracked weak ref; fall back to walking the presented-VC tree in
// case the menu is built before -viewDidAppear: has fired.
static UIViewController *CurrentMediaViewer(void) {
    UIViewController *tracked = sCurrentMediaViewer;
    if (tracked) return tracked;

    Class cls = objc_getClass([kMediaViewerClassName UTF8String]);
    if (!cls) return nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *found = SearchMediaViewer(window.rootViewController, cls);
            if (found) return found;
        }
    }
    return nil;
}

#pragma mark - videoPlaybackSpeed ivar + player access

// Read the controller's current speed. Returns NO when unset (nil / Normal).
static BOOL ReadCurrentSpeed(UIViewController *mvc, float *outSpeed) {
    if (!mvc) return NO;
    Ivar ivar = class_getInstanceVariable([mvc class], "videoPlaybackSpeed");
    if (!ivar) return NO;
    uint8_t *base = (uint8_t *)(__bridge void *)mvc + ivar_getOffset(ivar);
    uint8_t hasValueFlag = base[4];   // 0 == .some, non-zero == .none
    if (hasValueFlag != 0) return NO;
    if (outSpeed) memcpy(outSpeed, base, sizeof(float));
    return YES;
}

static void WriteCurrentSpeed(UIViewController *mvc, float speed) {
    Ivar ivar = class_getInstanceVariable([mvc class], "videoPlaybackSpeed");
    if (!ivar) return;
    uint8_t *base = (uint8_t *)(__bridge void *)mvc + ivar_getOffset(ivar);
    memcpy(base, &speed, sizeof(float));
    base[4] = 0;   // mark the optional as .some
}

static AVPlayer *PlayerFromLayer(CALayer *layer) {
    if (!layer) return nil;
    if ([layer isKindOfClass:[AVPlayerLayer class]]) {
        AVPlayer *p = [(AVPlayerLayer *)layer player];
        if (p) return p;
    }
    for (CALayer *sub in layer.sublayers) {
        AVPlayer *p = PlayerFromLayer(sub);
        if (p) return p;
    }
    return nil;
}

static AVPlayer *PlayerFromView(UIView *view) {
    if (!view) return nil;
    SEL playerLayerSel = NSSelectorFromString(@"playerLayer");
    if ([view respondsToSelector:playerLayerSel]) {
        id pl = ((id (*)(id, SEL))objc_msgSend)(view, playerLayerSel);
        if ([pl isKindOfClass:[AVPlayerLayer class]]) {
            AVPlayer *p = [(AVPlayerLayer *)pl player];
            if (p) return p;
        }
    }
    AVPlayer *p = PlayerFromLayer(view.layer);
    if (p) return p;
    for (UIView *sub in view.subviews) {
        p = PlayerFromView(sub);
        if (p) return p;
    }
    return nil;
}

// MediaViewerController stores its AVPlayer two ways: directly on the `player`
// ivar for non-shareable videos (GIFs/Streamable), or — for shareable v.redd.it
// videos — on the `playerLayerContainerView`'s AVPlayerLayer (the `player` ivar
// is nil). Mirror Apollo's own lookup, with a view-tree scan as a last resort.
static AVPlayer *MediaViewerPlayer(UIViewController *mvc) {
    if (!mvc) return nil;

    Ivar playerIvar = class_getInstanceVariable([mvc class], "player");
    if (playerIvar) {
        id player = object_getIvar(mvc, playerIvar);
        if ([player isKindOfClass:[AVPlayer class]]) return (AVPlayer *)player;
    }

    Ivar containerIvar = class_getInstanceVariable([mvc class], "playerLayerContainerView");
    if (containerIvar) {
        id container = object_getIvar(mvc, containerIvar);
        if ([container isKindOfClass:[UIView class]]) {
            AVPlayer *p = PlayerFromView((UIView *)container);
            if (p) return p;
        }
    }

    return PlayerFromView(mvc.isViewLoaded ? mvc.view : nil);
}

// Replicates Apollo's own speed-change path: store the value, then push it to
// the player only if it's currently playing (rate != 0), exactly like the
// native setter. A paused video picks the value up on its next play via
// Apollo's `setRate(videoPlaybackSpeed ?? 1.0)` start path.
static void ApplyPlaybackSpeed(float speed) {
    UIViewController *mvc = CurrentMediaViewer();
    if (!mvc) {
        ApolloLog(@"PlaybackSpeed: no media viewer found to apply %.2fx", speed);
        return;
    }

    WriteCurrentSpeed(mvc, speed);

    AVPlayer *player = MediaViewerPlayer(mvc);
    if (player && player.rate != 0.0f) {
        [player setRate:speed];
    }
    ApolloLog(@"PlaybackSpeed: applied %.2fx (player=%@ rate=%.2f)",
              speed, player ? @"yes" : @"nil", player ? player.rate : 0.0f);
}

#pragma mark - Speed submenu detection + augmentation

// Read a menu element's title/image without assuming it's a UIAction — the speed
// rows could be UIAction, UICommand, or another UIMenuElement subclass.
static NSString *ElementTitle(UIMenuElement *e) {
    return [e respondsToSelector:@selector(title)] ? [(id)e title] : nil;
}

static UIImage *ElementImage(UIMenuElement *e) {
    return [e respondsToSelector:@selector(image)] ? ((UIAction *)e).image : nil;
}

// A speed row's title is digits/dot followed by the × sign, e.g. "0.5×", "2×".
static BOOL TitleIsSpeed(NSString *title) {
    if (title.length < 2 || ![title hasSuffix:MultiplicationSign()]) return NO;
    NSString *num = [title substringToIndex:title.length - 1];
    if (num.length == 0) return NO;
    NSCharacterSet *nonNumeric = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet];
    return [num rangeOfCharacterFromSet:nonNumeric].location == NSNotFound;
}

// True when `children` is Apollo's speed submenu and we haven't already added
// our rows. Detection is by content (>= 3 children whose titles are "<number>×"),
// which is specific to the speed picker and survives localization of "Normal".
static BOOL ShouldAugmentSpeedMenu(NSArray<UIMenuElement *> *children) {
    if (children.count < 3) return NO;
    NSString *slowTitle = SpeedTitle(kSpeedSlow);
    NSString *fastTitle = SpeedTitle(kSpeedFast);

    NSUInteger speedCount = 0;
    for (UIMenuElement *element in children) {
        NSString *title = ElementTitle(element);
        if (!title) continue;
        if ([title isEqualToString:slowTitle] || [title isEqualToString:fastTitle]) {
            return NO;   // already augmented — avoid double-insert
        }
        if (TitleIsSpeed(title)) speedCount++;
    }
    return speedCount >= 3;
}

#pragma mark - Row icons

// Source icons are 144px PNGs; render them around this point size so they sit at
// the same visual weight as Apollo's own menu glyphs.
static const CGFloat kSpeedIconSourcePx = 144.0;
static const CGFloat kSpeedIconPointSize = 34.0;

// Load a bundled icon (resources/<name>.png) as a template image at the menu
// point size. ApolloBundledResourcePath resolves the file across the supported
// install layouts (jailbreak, sideload, deb fuse) and the simulator.
static UIImage *LoadBundledSpeedIcon(NSString *name) {
    NSString *path = ApolloBundledResourcePath(name, @"png");
    if (path.length == 0) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    UIImage *raw = [UIImage imageWithData:data scale:(kSpeedIconSourcePx / kSpeedIconPointSize)];
    return [raw imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// Custom icons (PNGs in resources/), loaded once and cached: a leaping deer for
// 0.75× and a side-view running fox for 1.25× — matching Apollo's snail/turtle/
// rabbit/cheetah line-art set.
static UIImage *DeerIcon(void) {
    static UIImage *icon = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ icon = LoadBundledSpeedIcon(@"playback-speed-deer"); });
    return icon;
}

static UIImage *FoxIcon(void) {
    static UIImage *icon = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ icon = LoadBundledSpeedIcon(@"playback-speed-fox"); });
    return icon;
}

// Falls back to the borrowed neighbouring-row icon if decoding ever fails, so a
// row always has an image.
static UIImage *PreferredSpeedIcon(float speed, UIImage *fallback) {
    UIImage *img = nil;
    if (speed == kSpeedSlow) img = DeerIcon();
    else if (speed == kSpeedFast) img = FoxIcon();
    return img ?: fallback;
}

#pragma mark - Augmentation

static UIAction *MakeSpeedAction(float speed, UIImage *image, float currentSpeed, BOOL haveCurrent) {
    UIAction *action = [UIAction actionWithTitle:SpeedTitle(speed)
                                           image:image
                                      identifier:nil
                                         handler:^(__kindof UIAction *act) {
        ApplyPlaybackSpeed(speed);
    }];
    if (haveCurrent && fabsf(currentSpeed - speed) < 0.001f) {
        action.state = UIMenuElementStateOn;   // checkmark
    }
    return action;
}

// Build the augmented child list:  …0.5×, [0.75×], Normal, [1.25×], 1.5×…
static NSArray<UIMenuElement *> *AugmentedSpeedChildren(NSArray<UIMenuElement *> *children) {
    NSString *half = SpeedTitle(0.5f);
    NSString *oneHalf = SpeedTitle(1.5f);

    // Neighbouring-row images, used only as a fallback if our icons fail to load.
    UIImage *slowImage = nil;
    UIImage *fastImage = nil;
    for (UIMenuElement *element in children) {
        NSString *title = ElementTitle(element);
        if ([title isEqualToString:half]) slowImage = ElementImage(element);
        else if ([title isEqualToString:oneHalf]) fastImage = ElementImage(element);
    }

    float current = 1.0f;
    BOOL haveCurrent = ReadCurrentSpeed(CurrentMediaViewer(), &current);

    UIAction *slowAction = MakeSpeedAction(kSpeedSlow, PreferredSpeedIcon(kSpeedSlow, slowImage), current, haveCurrent);
    UIAction *fastAction = MakeSpeedAction(kSpeedFast, PreferredSpeedIcon(kSpeedFast, fastImage), current, haveCurrent);

    NSMutableArray<UIMenuElement *> *result = [NSMutableArray arrayWithCapacity:children.count + 2];
    BOOL insertedSlow = NO, insertedFast = NO;
    for (UIMenuElement *element in children) {
        NSString *title = ElementTitle(element);
        if (!insertedFast && [title isEqualToString:oneHalf]) {
            [result addObject:fastAction];   // 1.25× immediately before 1.5×
            insertedFast = YES;
        }
        [result addObject:element];
        if (!insertedSlow && [title isEqualToString:half]) {
            [result addObject:slowAction];   // 0.75× immediately after 0.5×
            insertedSlow = YES;
        }
    }
    if (!insertedSlow) [result addObject:slowAction];
    if (!insertedFast) [result addObject:fastAction];
    return result;
}

#pragma mark - Hooks

%hook _TtC6Apollo21MediaViewerController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sCurrentMediaViewer = (UIViewController *)self;
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (sCurrentMediaViewer == (UIViewController *)self) sCurrentMediaViewer = nil;
}

%end

%hook UIMenu

// Display-time interception: whatever built the menu, UIKit reads -children when
// it renders the rows. If this menu's children are the speed rows, return an
// augmented list (cached per instance so the array stays stable across reads).
- (NSArray<UIMenuElement *> *)children {
    NSArray<UIMenuElement *> *orig = %orig;
    static char kAugmentedChildrenKey;
    NSArray<UIMenuElement *> *cached = objc_getAssociatedObject(self, &kAugmentedChildrenKey);
    if (cached) return cached;
    if (ShouldAugmentSpeedMenu(orig)) {
        NSArray<UIMenuElement *> *augmented = AugmentedSpeedChildren(orig);
        objc_setAssociatedObject(self, &kAugmentedChildrenKey, augmented, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return augmented;
    }
    return orig;
}

%end

%ctor {
    ApolloLog(@"ApolloVideoPlaybackSpeed: module loaded (adds 0.75x and 1.25x)");
}
