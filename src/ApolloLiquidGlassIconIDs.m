#import "ApolloLiquidGlassIconIDs.h"

static NSSet<NSString *> *ApolloLGLegacyClassicsIconIDs(void) {
    static NSSet<NSString *> *iconIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        iconIDs = [NSSet setWithArray:@[
            @"morty", @"duck", @"antenna", @"spaceship", @"burnt-orange",
            @"green", @"dark", @"orange", @"purple", @"white", @"pink",
            @"gold", @"crimson", @"blueberry", @"calico", @"castro", @"teal",
            @"brown", @"sunset", @"gravel-juice", @"gray", @"chosen-one",
            @"enter-the-state", @"rule-of-two", @"galactic-zoomer", @"six-colors",
            @"stonewall", @"trans", @"pride", @"clearly-combustion", @"dino-spoon",
            @"apollos6", @"atp", @"canada", @"ernest", @"slothkun", @"dave2d",
            @"red-black-white", @"camera-pool", @"peachy", @"sandals", @"andru",
            @"rene", @"tld", @"snazzy", @"eap",
        ]];
    });
    return iconIDs;
}

NSString *ApolloLGMigratedClassicsIconID(NSString *iconID) {
    if (!iconID.length) return nil;
    if (![ApolloLGLegacyClassicsIconIDs() containsObject:iconID]) return nil;
    return [@"LG-" stringByAppendingString:iconID];
}

NSString *ApolloLGLegacyClassicsIconID(NSString *iconID) {
    if (!iconID.length) return nil;
    if (![iconID hasPrefix:@"LG-"]) return nil;
    NSString *legacyID = [iconID substringFromIndex:3];
    return [ApolloLGLegacyClassicsIconIDs() containsObject:legacyID] ? legacyID : nil;
}
