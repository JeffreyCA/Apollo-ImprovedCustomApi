#import "ApolloCommon.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <OSLog/OSLog.h>

#pragma mark - Logging

static NSDate *sProcessStartDate = nil;

os_log_t ApolloFixLog(void) {
    static os_log_t log = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("apollofix", "tweak");
        sProcessStartDate = [NSDate date];
    });
    return log;
}

NSString *ApolloCollectLogs(void) {
    if (@available(iOS 15.0, *)) {
        NSError *error = nil;
        OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&error];
        if (!store) {
            return [NSString stringWithFormat:@"Failed to open log store: %@", error.localizedDescription];
        }

        NSDate *startDate = sProcessStartDate ?: [NSDate distantPast];
        OSLogPosition *position = [store positionWithDate:startDate];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"subsystem == %@", @"apollofix"];

        NSArray<OSLogEntryLog *> *entries = (NSArray *)[[store entriesEnumeratorWithOptions:0
                                                                                  position:position
                                                                                 predicate:predicate
                                                                                     error:&error] allObjects];
        if (!entries) {
            return [NSString stringWithFormat:@"Failed to enumerate logs: %@", error.localizedDescription];
        }

        if (entries.count == 0) {
            return @"No [ApolloFix] log entries found since app launch.";
        }

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";

        NSMutableString *output = [NSMutableString new];
        [output appendFormat:@"ApolloFix Logs — %@ (%lu entries)\n\n",
            [NSDateFormatter localizedStringFromDate:[NSDate date]
                                           dateStyle:NSDateFormatterMediumStyle
                                           timeStyle:NSDateFormatterShortStyle],
            (unsigned long)entries.count];

        for (OSLogEntryLog *entry in entries) {
            if (![entry isKindOfClass:[OSLogEntryLog class]]) continue;
            [output appendFormat:@"[%@] %@\n", [formatter stringFromDate:entry.date], entry.composedMessage];
        }

        return output;
    }

    return @"Log export requires iOS 15+.";
}

// Get the SDK version from the main binary's LC_BUILD_VERSION load command
// Returns 0 if not found, otherwise packed version (major << 16 | minor << 8 | patch)
static uint32_t GetLinkedSDKVersion(void) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header) return 0;

    uintptr_t cursor = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *cmd = (struct load_command *)cursor;
        if (cmd->cmd == LC_BUILD_VERSION) {
            struct build_version_command *buildCmd = (struct build_version_command *)cmd;
            return buildCmd->sdk;
        }
        cursor += cmd->cmdsize;
    }
    return 0;
}

// Check if Liquid Glass is active by checking if the app binary was linked against iOS 26+ SDK
BOOL IsLiquidGlass(void) {
    static BOOL checked = NO;
    static BOOL available = NO;

    if (!checked) {
        checked = YES;
        // BOOL isiOS26Runtime = (objc_getClass("_UITabButton") != nil);
        // if (!isiOS26Runtime) {
        //     ApolloLog(@"[IsLiquidGlass] iOS 26+ runtime not detected");
        //     available = NO;
        //     return available;
        // }

        // iOS 26 SDK version = 19.0 = 0x00130000 (major 19 in high 16 bits)
        // SDK version format: major << 16 | minor << 8 | patch
        uint32_t sdkVersion = GetLinkedSDKVersion();
        uint32_t sdkMajor = (sdkVersion >> 16) & 0xFFFF;
        available = (sdkMajor >= 19);

        ApolloLog(@"[IsLiquidGlass] SDK version: 0x%08X (major: %u), linked for iOS 26+: %@",
                  sdkVersion, sdkMajor, available ? @"YES" : @"NO");
    }

    return available;
}

static BOOL ApolloRouteURLThroughUIApplication(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }

    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        @try {
            void (*msgSendOpenURL)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))objc_msgSend;
            msgSendOpenURL(application, @selector(openURL:options:completionHandler:), url, @{}, nil);
            return YES;
        } @catch (NSException *exception) {
            return NO;
        }
    }

    return NO;
}

NSURL *ApolloURLByConvertingResolvedURLToApolloScheme(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) {
        return nil;
    }

    NSString *host = [[components host] lowercaseString];
    if (![host isKindOfClass:[NSString class]] || host.length == 0) {
        return nil;
    }

    if ([host hasSuffix:@"reddit.com"]) {
        components.host = @"reddit.com";
    } else if ([host isEqualToString:@"redd.it"] || [host hasSuffix:@".redd.it"]) {
        components.host = host;
    } else {
        return nil;
    }

    components.scheme = @"apollo";
    if ([components.query isKindOfClass:[NSString class]] && components.query.length == 0) {
        components.query = nil;
    }

    ApolloLog(@"[ApolloURLByConvertingResolvedURLToApolloScheme] Converted URL: %@", components.URL);
    return components.URL;
}

BOOL ApolloRouteResolvedURLViaApolloScheme(NSURL *resolvedURL) {
    NSURL *apolloURL = ApolloURLByConvertingResolvedURLToApolloScheme(resolvedURL);
    if (![apolloURL isKindOfClass:[NSURL class]]) {
        return NO;
    }
    return ApolloRouteURLThroughUIApplication(apolloURL);
}
