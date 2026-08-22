// ApolloSubredditListLaunchSettle.xm
//
// Subreddit-list launch settle: suppress the animated first layout that makes
// section header bands overlap the rows above them, and record the geometry
// that produced it (issue #919).
//
// Symptom (measured frame-by-frame from a reporter's screen recording): on a
// cold launch that lands on Apollo.RedditListViewController, every CELL of the
// list glides upward by ~22-27pt over ~0.26s while the section header bands
// ("FAVORITES", the A-Z letters) sit at their FINAL Y from the first visible
// frame. During the settle a header therefore overlaps — and clips — the last
// row of the section above it. Row heights and inter-row spacing never change,
// so the whole content block is translating: a contentOffset / contentInset /
// safe-area change, not a row-metrics change.
//
// Why cells animate but headers do not (UIKitCore 26.1, verified in the
// decompiled UITableView):
//   * -[UITableView _updateVisibleCellsNow:] re-frames every visible cell with
//     a bare -setFrame:, so the move joins whatever animation context the
//     layout pass is running in. Inside a UIView animation block the cells
//     glide.
//   * A header UIKit has to CREATE or dequeue during that same pass is built
//     by -[UITableView _sectionHeaderView:withFrame:forSection:floating:...],
//     whose whole build-and-frame is wrapped in +[UIView
//     performWithoutAnimation:]. It lands at its final frame with animations
//     suppressed.
// So the artifact means: the list's first real layout pass happens INSIDE a
// UIView animation, and the geometry it lays out to differs from what was on
// screen a moment earlier. This module records which input moved.
//
// THE FIX (see the -[UITableView layoutSubviews] hook below): while the list is
// arriving, a layout pass that runs inside an inherited UIView animation is
// re-run with animations off, so the rows land where the headers already are.
// The guard is the bug's own precondition — a healthy launch lays this table
// out with inheritedAnimationDuration == 0 (verified in the simulator), so the
// hook falls straight through to %orig and nothing changes for anyone who was
// never seeing the artifact.
//
// THE RECORDER exists because only the reporter sees it: the maintainer, on the
// same iPhone 17 Pro / iOS 26.5 / Liquid Glass build, does not, and neither does
// the simulator. The most obvious asymmetry is list size (the reporter's table
// reports a 9864pt content height, which would make the first layout land late
// enough to fall inside the launch animation) — but that is a hypothesis, not a
// finding. The recorder captures which input actually moved, whether or not the
// suppression above turns out to be enough.
//
// Cost when idle: two static loads on the global UITableView hooks. The window
// only ever opens for Apollo.RedditListViewController's own table, closes after
// kWindowSeconds, and is hard-capped at kMaxLines lines. Snapshots are
// emitted only when the formatted geometry actually CHANGES, so a healthy
// launch writes a handful of lines, not one per layout pass.
//
// Output goes to ApolloListLayoutLog's channel: the apollofix os_log stream
// AND the bounded cross-launch buffer that Settings > Export Debug Logs
// prepends — so a reporter can force-quit, relaunch, and still export it.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "ApolloCommon.h"

// How long the recorder stays open after the list controller loads its view.
// The measured settle finishes ~0.3s after the launch crossfade; 4s covers the
// slow-fetch reloads (subscriptions / multireddits / moderated subs) that land
// afterwards without running into ordinary scrolling.
static const NSTimeInterval kWindowSeconds = 4.0;
// How long after the list controller loads its view the animated-layout
// suppression stays armed. The measured settle is over ~0.3s in; 1.5s leaves
// room for a slow first fetch without reaching into ordinary interaction.
static const NSTimeInterval kSuppressSeconds = 1.5;
// Hard cap so a pathological launch cannot flood the cross-launch buffer.
static const NSUInteger kMaxLines = 80;

// Compared by pointer only, never messaged, and cleared the moment the window
// closes — so it cannot outlive the controller and cannot be matched by some
// later table that happens to land on the same address.
static __unsafe_unretained UITableView *sTrackedTable = nil;
static BOOL sWindowOpen = NO;
static NSTimeInterval sWindowOpenedAt = 0;
static NSUInteger sLinesWritten = 0;
static NSString *sLastSnapshot = nil;
static CGFloat sFirstContentTop = CGFLOAT_MAX;   // -contentOffset.y at the first snapshot
static CGFloat sLastContentTop = CGFLOAT_MAX;
static CGFloat sLastSampledOffset = CGFLOAT_MAX;
// The fix window is deliberately much shorter than the recorder's: it only has
// to cover the list's first layout passes, never ordinary use of the screen.
static NSTimeInterval sSuppressUntil = 0;
static NSUInteger sSuppressedPasses = 0;
// backtrace_symbols() does a dladdr per frame, so a trace costs about a
// millisecond. Capping them keeps the recorder from adding measurable work to
// the very launch it is timing — and keeps one launch from evicting the rest of
// the shared cross-launch buffer.
static NSUInteger sTracesWritten = 0;
// The first list controller of the process, kept weakly so the simulator
// bridge can re-arm against it even while it sits under a pushed feed.
static __weak UIViewController *sListController = nil;

static NSString *ApolloSLDInsets(UIEdgeInsets i) {
    return [NSString stringWithFormat:@"%.1f/%.1f/%.1f/%.1f", i.top, i.left, i.bottom, i.right];
}

static NSString *ApolloSLDRect(CGRect r) {
    return [NSString stringWithFormat:@"%.0f,%.0f,%.0fx%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static void ApolloSLDWrite(NSString *line) {
    line = [NSString stringWithFormat:@"[SubListDiag] %@", line ?: @""];
    ApolloLog(@"%@", line);
    ApolloAppendListLayoutDiag(line);
}

static void ApolloSLDLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ApolloSLDLog(NSString *format, ...) {
    if (sLinesWritten >= kMaxLines) return;
    sLinesWritten++;
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    ApolloSLDWrite(body);
}

// Milliseconds since the window opened — the only clock that matters here, and
// it lines up directly with the frame timings measured off the recording.
static double ApolloSLDElapsedMs(void) {
    return (CACurrentMediaTime() - sWindowOpenedAt) * 1000.0;
}

// Is this call running inside a UIView animation block / a CATransaction that
// will animate? This is the single most important field in the log: it is what
// separates "geometry changed" from "geometry changed and the cells glided".
static NSString *ApolloSLDAnimationContext(void) {
    return [NSString stringWithFormat:@"inh=%.2f on=%d ca=%.2f dis=%d",
            [UIView inheritedAnimationDuration],
            [UIView areAnimationsEnabled],
            [CATransaction animationDuration],
            [CATransaction disableActions]];
}

static UIViewController *ApolloSLDOwningViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

// How many of the table's own subviews are mid-glide, split by kind, plus the
// frame of the first section header band. "cells > 0 with headers == 0" is the
// fingerprint of the reported artifact.
//
// This walks the table's subviews directly rather than asking for
// -numberOfSections / -headerViewForSection:, because both of those can drive
// the data source into a row-data rebuild — and a recorder that perturbs the
// launch layout it is measuring is worse than no recorder at all.
static void ApolloSLDCountLiveAnimations(UITableView *table, NSUInteger *cellsOut, NSUInteger *headersOut,
                                         NSString **firstHeaderFrameOut) {
    NSUInteger cells = 0, headers = 0;
    NSString *firstHeaderFrame = @"none";
    Class headerFooterClass = [UITableViewHeaderFooterView class];
    for (UIView *subview in table.subviews) {
        BOOL gliding = ([subview.layer animationForKey:@"position"] != nil ||
                        [subview.layer animationForKey:@"bounds"] != nil);
        if ([subview isKindOfClass:[UITableViewCell class]]) {
            if (gliding) cells++;
            continue;
        }
        // Apollo vends Apollo.RecreatedTableSectionHeaderView (a bare UIView)
        // for some sections and lets UIKit supply the rest, so match both.
        BOOL isHeader = [subview isKindOfClass:headerFooterClass] ||
                        [NSStringFromClass(subview.class) containsString:@"SectionHeader"];
        if (!isHeader) continue;
        if ([firstHeaderFrame isEqualToString:@"none"]) {
            firstHeaderFrame = ApolloSLDRect(subview.frame);
        }
        if (gliding) headers++;
    }
    if (cellsOut) *cellsOut = cells;
    if (headersOut) *headersOut = headers;
    if (firstHeaderFrameOut) *firstHeaderFrameOut = firstHeaderFrame;
}

// The CA animations that make cells glide are attached when the enclosing
// UIView animation block commits, i.e. AFTER the setter returns — so sample the
// fingerprint on the next runloop turn rather than in the setter itself.
// "cells>0 hdrs=0" is the artifact; "cells=0" means the change committed
// without animation and nothing would have been visible.
static void ApolloSLDSampleAnimationFingerprint(UITableView *table, NSString *reason) {
    if (!sWindowOpen || !table) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!sWindowOpen || table != sTrackedTable) return;
        NSUInteger cells = 0, headers = 0;
        NSString *firstHeaderFrame = @"none";
        ApolloSLDCountLiveAnimations(table, &cells, &headers, &firstHeaderFrame);
        CAAnimation *sample = nil;
        for (UITableViewCell *cell in table.visibleCells) {
            sample = [cell.layer animationForKey:@"position"];
            if (sample) break;
        }
        ApolloSLDLog(@"+%.0fms fingerprint(%@) glidingCells=%lu glidingHeaders=%lu dur=%.2f off=%.1f hdr0=%@",
                     ApolloSLDElapsedMs(), reason, (unsigned long)cells, (unsigned long)headers,
                     sample ? sample.duration : 0.0, table.contentOffset.y, firstHeaderFrame);
    });
}

// One formatted geometry snapshot. Emitted only when it differs from the last
// one, so a settled table stops producing lines on its own.
static void ApolloSLDSnapshot(UITableView *table, NSString *reason, BOOL force) {
    if (!sWindowOpen || !table || table != sTrackedTable) return;
    if (!force && ApolloSLDElapsedMs() > kWindowSeconds * 1000.0) {
        sWindowOpen = NO;
        sTrackedTable = nil;
        sSuppressUntil = 0;
        return;
    }

    UIViewController *vc = ApolloSLDOwningViewController(table);
    UINavigationController *nav = vc.navigationController;
    UITabBarController *tabs = vc.tabBarController;
    UIWindow *window = table.window;

    CGRect statusBarFrame = CGRectZero;
    if (@available(iOS 13.0, *)) {
        statusBarFrame = window.windowScene.statusBarManager.statusBarFrame;
    }

    // contentTop is what the eye actually sees: the screen-space Y the first
    // row starts at, in the table's own coordinates.
    CGFloat contentTop = -table.contentOffset.y;

    NSString *body = [NSString stringWithFormat:
        @"off=%.1f inset=%@ adj=%@ tblSafe=%@ frame=%@ contentSize=%.0fw/%.0fh "
        @"vcSafe=%@ addl=%@ winSafe=%@ status=%@ nav=%@ navHidden=%d tab=%@ anim(%@)",
        table.contentOffset.y,
        ApolloSLDInsets(table.contentInset),
        ApolloSLDInsets(table.adjustedContentInset),
        ApolloSLDInsets(table.safeAreaInsets),
        ApolloSLDRect(table.frame),
        table.contentSize.width, table.contentSize.height,
        ApolloSLDInsets(vc.view.safeAreaInsets),
        ApolloSLDInsets(vc.additionalSafeAreaInsets),
        ApolloSLDInsets(window.safeAreaInsets),
        ApolloSLDRect(statusBarFrame),
        ApolloSLDRect(nav.navigationBar.frame),
        nav.navigationBarHidden,
        ApolloSLDRect(tabs.tabBar.frame),
        ApolloSLDAnimationContext()];

    if (!force && [body isEqualToString:sLastSnapshot]) return;
    sLastSnapshot = body;

    if (sFirstContentTop == CGFLOAT_MAX) sFirstContentTop = contentTop;
    sLastContentTop = contentTop;

    ApolloSLDLog(@"+%.0fms %@ %@", ApolloSLDElapsedMs(), reason, body);
}

// Abbreviated caller trace for the geometry setters: enough to tell Apollo's
// own code, UIKit's layout machinery and the tweak apart without pulling in a
// full symbolicated backtrace on every call.
static const NSUInteger kMaxTraces = 12;

static NSString *ApolloSLDCallers(void) {
    if (sTracesWritten >= kMaxTraces) return @"(trace capped)";
    sTracesWritten++;
    NSArray<NSString *> *symbols = [NSThread callStackSymbols];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    // callStackSymbols format: "<n><pad><image><pad><addr> <symbol> + <offset>".
    // The symbol itself contains spaces (ObjC selectors, C++ names), so take
    // everything between the address and the trailing " + <offset>".
    for (NSUInteger i = 2; i < symbols.count && kept.count < 7; i++) {
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        for (NSString *field in [symbols[i] componentsSeparatedByString:@" "]) {
            if (field.length) [fields addObject:field];
        }
        if (fields.count < 5) continue;
        NSString *image = fields[1];
        NSRange symbolRange = NSMakeRange(3, fields.count - 5);   // drop idx/image/addr and "+ off"
        NSString *name = [[fields subarrayWithRange:symbolRange] componentsJoinedByString:@" "];
        NSString *offset = fields.lastObject;
        // Logos thunk names are long and add nothing beyond "the tweak"; fold
        // them so a trace stays readable.
        if ([name hasPrefix:@"_ZL"] || [name containsString:@"_logos_method$"]) name = @"(tweak hook)";
        if (image.length > 22) image = [image substringToIndex:22];
        [kept addObject:[NSString stringWithFormat:@"%@!%@+%@", image, name, offset]];
    }
    return [kept componentsJoinedByString:@" < "];
}

static void ApolloSLDOpenWindow(UITableView *table, NSString *reason) {
    if (!table) return;
    sTrackedTable = table;
    sWindowOpen = YES;
    sWindowOpenedAt = CACurrentMediaTime();
    sLastSnapshot = nil;
    sFirstContentTop = CGFLOAT_MAX;
    sLastSampledOffset = CGFLOAT_MAX;
    sTracesWritten = 0;
    sSuppressUntil = CACurrentMediaTime() + kSuppressSeconds;
    sSuppressedPasses = 0;
    ApolloSLDLog(@"window open (%@) table=%p uptime=%.0fms",
                 reason, table, NSProcessInfo.processInfo.systemUptime * 1000.0);
    ApolloSLDSnapshot(table, @"open", YES);

    // Sampled sweep across the settle. Each tick logs only when something moved
    // or a cell is mid-glide, so a healthy launch stays silent here.
    static const int kSampleMs[] = { 80, 160, 250, 350, 500, 700, 1000, 1400, 2000, 2800 };
    for (size_t i = 0; i < sizeof(kSampleMs) / sizeof(kSampleMs[0]); i++) {
        int delay = kSampleMs[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (!sWindowOpen || table != sTrackedTable) return;
            NSUInteger cells = 0, headers = 0;
            NSString *firstHeaderFrame = @"none";
            ApolloSLDCountLiveAnimations(table, &cells, &headers, &firstHeaderFrame);
            CGFloat offset = table.contentOffset.y;
            BOOL moved = (sLastSampledOffset == CGFLOAT_MAX) || fabs(offset - sLastSampledOffset) > 0.5;
            sLastSampledOffset = offset;
            if (!moved && cells == 0 && headers == 0) return;
            ApolloSLDLog(@"+%.0fms sample off=%.1f glidingCells=%lu glidingHeaders=%lu hdr0=%@",
                         ApolloSLDElapsedMs(), offset,
                         (unsigned long)cells, (unsigned long)headers, firstHeaderFrame);
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWindowSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!sWindowOpen) return;
        sWindowOpen = NO;
        // Drop every hot-path trigger together. After this the global hooks are
        // a single BOOL test, the layoutSubviews guard can never match again
        // (so a table allocated at this address later cannot be mistaken for
        // the list's), and the list controller's layout hooks stop resolving
        // ivars. The recorder and the fix are done for the life of the process.
        sTrackedTable = nil;
        sSuppressUntil = 0;
        CGFloat delta = (sFirstContentTop == CGFLOAT_MAX) ? 0.0 : (sLastContentTop - sFirstContentTop);
        // Positive settle == the content ended HIGHER than it started, which is
        // the direction measured off the reporter's recording. Written straight
        // through so the summary survives even when the line cap was reached.
        ApolloSLDWrite([NSString stringWithFormat:
            @"window closed: contentTop %.1f -> %.1f (settle %.1fpt) lines=%lu",
            sFirstContentTop, sLastContentTop, -delta, (unsigned long)sLinesWritten]);
    });
}

// The list controller's table lives in ApolloTableViewController's `tableView`
// ivar (a Swift stored property with no ObjC getter).
static UITableView *ApolloSLDTableForController(id controller) {
    if (!controller) return nil;
    Class cls = object_getClass(controller);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, "tableView");
        if (ivar) {
            id value = object_getIvar(controller, ivar);
            return [value isKindOfClass:[UITableView class]] ? value : nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

%group ApolloSubredditListLaunchSettle

%hook _TtC6Apollo24RedditListViewController

- (void)viewDidLoad {
    %orig;
    // Arm on the FIRST list controller of the process only: the launch case is
    // what is being investigated, and a later push (Edit, a second tab) would
    // otherwise re-open the window over ordinary use.
    static BOOL sArmed = NO;
    sListController = (UIViewController *)self;
    if (sArmed) return;
    sArmed = YES;
    ApolloSLDOpenWindow(ApolloSLDTableForController(self), @"viewDidLoad");
}

// Every hook below tests sWindowOpen BEFORE resolving the table: the ivar walk
// takes the runtime lock, and viewWillLayoutSubviews/viewDidLayoutSubviews run
// on this screen for the life of the process. Once the window has closed these
// are a static BOOL load and a return.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!sWindowOpen) return;
    ApolloSLDSnapshot(ApolloSLDTableForController(self), @"viewWillAppear", NO);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!sWindowOpen) return;
    ApolloSLDSnapshot(ApolloSLDTableForController(self), @"viewDidAppear", NO);
}

- (void)viewWillLayoutSubviews {
    %orig;
    if (!sWindowOpen) return;
    ApolloSLDSnapshot(ApolloSLDTableForController(self), @"vcWillLayout", NO);
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!sWindowOpen) return;
    ApolloSLDSnapshot(ApolloSLDTableForController(self), @"vcDidLayout", NO);
}

%end

// Global scroll-view hooks. Every one of them bails on a pointer compare when
// the window is shut or the table is not the tracked one.
%hook UITableView

// THE FIX for #919.
//
// A layout pass that runs inside a UIView animation re-frames the visible cells
// through an animatable -setFrame: while any header UIKit builds during the
// same pass is framed inside +[UIView performWithoutAnimation:] (see the file
// header). That asymmetry is the whole artifact: the rows glide, the section
// bands do not, and for a quarter of a second a band sits on top of the row
// above it.
//
// There is no first-launch layout of the subreddit list that is better for
// being animated — the user has not interacted with anything yet, and the list
// is simply arriving at its resting geometry. So when this table lays out
// inside an inherited animation during its first moments, run the pass with
// animations off: the cells then land exactly where the headers already do.
//
// The guard is the bug's own precondition, which makes this a no-op for anyone
// not seeing it: a healthy launch lays the list out with
// inheritedAnimationDuration == 0 (confirmed in the simulator), so %orig runs
// untouched and nothing about the screen changes.
- (void)layoutSubviews {
    BOOL tracked = (self == sTrackedTable);
    if (tracked && sSuppressUntil > 0 && [UIView inheritedAnimationDuration] > 0.0) {
        if (CACurrentMediaTime() < sSuppressUntil) {
            NSTimeInterval inherited = [UIView inheritedAnimationDuration];
            CGFloat before = self.contentOffset.y;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [UIView performWithoutAnimation:^{ %orig; }];
            [CATransaction commit];
            sSuppressedPasses++;
            // One line per launch is enough to tell a fixed launch from an
            // untouched one; further passes in the same window are silent.
            if (sSuppressedPasses == 1) {
                ApolloSLDLog(@"+%.0fms SUPPRESSED animated launch layout (inherited=%.2fs, offsetY %.1f -> %.1f)",
                             ApolloSLDElapsedMs(), inherited, before, self.contentOffset.y);
            }
            ApolloSLDSnapshot(self, @"layout(suppressed)", NO);
            return;
        }
        sSuppressUntil = 0;
        if (sSuppressedPasses) {
            ApolloSLDLog(@"+%.0fms suppression window closed after %lu pass(es)",
                         ApolloSLDElapsedMs(), (unsigned long)sSuppressedPasses);
        }
    }

    %orig;
    if (!sWindowOpen || !tracked) return;
    ApolloSLDSnapshot(self, @"layout", NO);
}

- (void)setContentOffset:(CGPoint)offset {
    if (!sWindowOpen || self != sTrackedTable) { %orig; return; }
    CGPoint before = self.contentOffset;
    %orig;
    if (fabs(before.y - offset.y) < 0.5) return;
    ApolloSLDLog(@"+%.0fms setContentOffset y %.1f -> %.1f anim(%@) via %@",
                 ApolloSLDElapsedMs(), before.y, offset.y, ApolloSLDAnimationContext(), ApolloSLDCallers());
    ApolloSLDSnapshot(self, @"afterSetOffset", NO);
    ApolloSLDSampleAnimationFingerprint(self, @"offset");
}

- (void)setContentInset:(UIEdgeInsets)inset {
    if (!sWindowOpen || self != sTrackedTable) { %orig; return; }
    UIEdgeInsets before = self.contentInset;
    %orig;
    if (UIEdgeInsetsEqualToEdgeInsets(before, inset)) return;
    ApolloSLDLog(@"+%.0fms setContentInset %@ -> %@ anim(%@) via %@",
                 ApolloSLDElapsedMs(), ApolloSLDInsets(before), ApolloSLDInsets(inset),
                 ApolloSLDAnimationContext(), ApolloSLDCallers());
    ApolloSLDSnapshot(self, @"afterSetInset", NO);
    ApolloSLDSampleAnimationFingerprint(self, @"inset");
}

// Apollo parks several of its tables through -setBounds: rather than
// -setContentOffset:, so the offset move can bypass the setter above.
- (void)setBounds:(CGRect)bounds {
    if (!sWindowOpen || self != sTrackedTable) { %orig; return; }
    CGRect before = self.bounds;
    %orig;
    if (fabs(before.origin.y - bounds.origin.y) < 0.5) return;
    ApolloSLDLog(@"+%.0fms setBounds originY %.1f -> %.1f anim(%@) via %@",
                 ApolloSLDElapsedMs(), before.origin.y, bounds.origin.y,
                 ApolloSLDAnimationContext(), ApolloSLDCallers());
    ApolloSLDSampleAnimationFingerprint(self, @"bounds");
}

- (void)safeAreaInsetsDidChange {
    if (!sWindowOpen || self != sTrackedTable) { %orig; return; }
    UIEdgeInsets before = self.safeAreaInsets;
    %orig;
    ApolloSLDLog(@"+%.0fms safeAreaInsetsDidChange %@ -> %@ anim(%@) via %@",
                 ApolloSLDElapsedMs(), ApolloSLDInsets(before), ApolloSLDInsets(self.safeAreaInsets),
                 ApolloSLDAnimationContext(), ApolloSLDCallers());
}

- (void)reloadData {
    if (!sWindowOpen || self != sTrackedTable) { %orig; return; }
    CGFloat before = self.contentSize.height;
    %orig;
    ApolloSLDLog(@"+%.0fms reloadData contentHeight %.0f -> %.0f anim(%@) via %@",
                 ApolloSLDElapsedMs(), before, self.contentSize.height,
                 ApolloSLDAnimationContext(), ApolloSLDCallers());
}

%end

%end   // group

// Re-arm from the simulator debug bridge ("listdiag") so the window can be
// opened on demand while iterating, instead of only on a cold launch.
void ApolloSubredditListDiagRearm(void) {
    UITableView *table = ApolloSLDTableForController(sListController);
    if (!table) {
        ApolloLog(@"[SubListDiag] rearm: no RedditListViewController seen yet");
        return;
    }
    sLinesWritten = 0;
    ApolloSLDOpenWindow(table, @"rearm");
}

%ctor {
    if (objc_getClass("_TtC6Apollo24RedditListViewController")) {
        %init(ApolloSubredditListLaunchSettle);
        ApolloLog(@"[SubListDiag] launch geometry recorder armed (window=%.0fs cap=%lu lines)",
                  kWindowSeconds, (unsigned long)kMaxLines);
    }
}
