// ApolloAutoHideTabBar.h
//
// The shipping module has no public API. Simulator builds expose one bounded
// scan probe so the allocation-free tab-navigation fast paths can be verified
// without putting diagnostics in production scroll callbacks.

#import <Foundation/Foundation.h>

#if APOLLO_SIM_BUILD
NSString *ApolloAutoHideTabBarSimScanStatus(NSUInteger iterations);
NSString *ApolloAutoHideTabBarSimSetPolicy(BOOL enabled);
#endif
