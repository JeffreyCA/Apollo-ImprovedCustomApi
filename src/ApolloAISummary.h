#import <Foundation/Foundation.h>

__BEGIN_DECLS

// Clears generated summaries, extracted article text, transient comment data,
// and the persisted summary plist. Returns the number of generated summaries
// removed from the in-memory cache.
NSUInteger ApolloAIClearSummaryCache(void);

__END_DECLS
