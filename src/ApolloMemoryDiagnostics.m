#import "ApolloMemoryDiagnostics.h"
#import "ApolloCommon.h"

#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <stdatomic.h>

// MARK: - Footprint query

double ApolloMemoryFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return -1;
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

// MARK: - Purge handler registry

static NSMutableArray<NSDictionary *> *sPurgeHandlers;
static NSObject *sPurgeLock;

static void ApolloMemoryDiagnosticsEnsureState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sPurgeHandlers = [NSMutableArray array];
        sPurgeLock = [NSObject new];
    });
}

void ApolloMemoryRegisterPurgeHandler(NSString *name, void (^handler)(void)) {
    if (!handler) return;
    ApolloMemoryDiagnosticsEnsureState();
    @synchronized (sPurgeLock) {
        [sPurgeHandlers addObject:@{ @"name": name ?: @"?", @"handler": [handler copy] }];
    }
}

void ApolloMemoryLogFootprint(NSString *context) {
    ApolloLog(@"[MemoryDiag] %@ | footprint=%.0fMB", context ?: @"-", ApolloMemoryFootprintMB());
}

// MARK: - Warning + lifecycle observers, periodic sampler

static _Atomic(double) sPeakFootprintMB;
static double sLastLoggedFootprintMB;

static double ApolloMemoryPeakFootprintMB(void) {
    return atomic_load_explicit(&sPeakFootprintMB, memory_order_relaxed);
}

static void ApolloMemoryRunPurgeHandlers(void) {
    NSArray<NSDictionary *> *handlers;
    @synchronized (sPurgeLock) { handlers = [sPurgeHandlers copy]; }
    for (NSDictionary *entry in handlers) {
        double before = ApolloMemoryFootprintMB();
        void (^handler)(void) = entry[@"handler"];
        handler();
        double after = ApolloMemoryFootprintMB();
        ApolloLog(@"[MemoryDiag] purge '%@' | footprint %.0fMB -> %.0fMB",
                  entry[@"name"], before, after);
    }
}

__attribute__((constructor))
static void ApolloMemoryDiagnosticsInstall(void) {
    ApolloMemoryDiagnosticsEnsureState();
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // Memory warning: log, then purge everything registered. This is the last
    // signal before jetsam considers the app; footprint here is the number
    // that matters in JetsamEvent reports.
    [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        ApolloLog(@"[MemoryDiag] MEMORY WARNING | footprint=%.0fMB peak=%.0fMB",
                  ApolloMemoryFootprintMB(), ApolloMemoryPeakFootprintMB());
        ApolloMemoryRunPurgeHandlers();
    }];

    // Backgrounding: suspended footprint decides eviction order while the user
    // is away (issue #811: "Apollo reloads when I come back"). Log it and purge
    // proactively — a suspended app never gets another chance to shrink.
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        ApolloLog(@"[MemoryDiag] didEnterBackground | footprint=%.0fMB peak=%.0fMB",
                  ApolloMemoryFootprintMB(), ApolloMemoryPeakFootprintMB());
        ApolloMemoryRunPurgeHandlers();
    }];

    // Periodic sampler on a utility queue: tracks peak and logs only on
    // meaningful movement (>=50MB since the last logged value) so a healthy
    // session adds a handful of lines, a leaking one draws its own growth curve.
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                              30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        double mb = ApolloMemoryFootprintMB();
        if (mb < 0) return;
        double peak = ApolloMemoryPeakFootprintMB();
        while (mb > peak && !atomic_compare_exchange_weak_explicit(
            &sPeakFootprintMB, &peak, mb, memory_order_relaxed, memory_order_relaxed)) {}
        if (fabs(mb - sLastLoggedFootprintMB) >= 50.0) {
            sLastLoggedFootprintMB = mb;
            ApolloLog(@"[MemoryDiag] footprint=%.0fMB peak=%.0fMB", mb, ApolloMemoryPeakFootprintMB());
        }
    });
    dispatch_resume(timer);
    // Keep the source alive for the process lifetime.
    CFRetain((__bridge CFTypeRef)timer);
}
