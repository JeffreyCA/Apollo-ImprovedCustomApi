#import <Foundation/Foundation.h>

// Shared settings bridge for Interface → Tab Bar. The implementation owns
// Apollo's native HideBarsOnScroll key, the Left/Right/Fade/Down presentation
// preference, and the notifications/live relayout required after a change.
#ifdef __cplusplus
extern "C" {
#endif

BOOL ApolloTabBarHideBarsEnabled(void);
void ApolloTabBarHideBarsSetEnabled(BOOL enabled);

NSArray<NSString *> *ApolloTabBarHideStyleOptionTitles(void);
NSInteger ApolloTabBarHideStyleCurrentOptionIndex(void);
NSString *ApolloTabBarHideStyleCurrentTitle(void);
void ApolloTabBarHideStyleApplyOptionIndex(NSInteger optionIndex);

#ifdef __cplusplus
}
#endif
