//
//  ApolloTextureDecls.h
//  Apollo-Reborn
//
//  Minimal Texture (AsyncDisplayKit) forward declarations shared by files
//  that splice content into Apollo's Texture layout trees via
//  -layoutSpecThatFits: hooks (ApolloAISummary.xm, ApolloPollVoting.xm). Real
//  Texture headers aren't on this build's include path, so this declares
//  only the selectors/properties those two files actually use; the runtime
//  resolves them against Apollo's own bundled Texture implementation, and
//  every class named below is still looked up via objc_getClass/
//  NSClassFromString at the point of use rather than referenced directly
//  (ApolloReborn.dylib is injected rather than linked against Apollo, so a
//  direct class reference fails at link time).
//
//  Deliberately does NOT declare the stack layout's direction/justifyContent/
//  alignItems as a shared named enum: each caller keeps its own local
//  NS_ENUM with its own independently-verified raw values (a past bug had
//  one file's direction enum silently swapped relative to real Texture), and
//  this header only types those parameters/properties as the underlying
//  `unsigned char`, so a bad value in one caller's enum can't leak into the
//  other's.
//
//  Not folded into ApolloCommon.h and not meant for blanket import — several
//  other files (e.g. ApolloInlineImages.xm) declare their own, differently
//  shaped local copies of these same class names, which would collide if
//  this header were pulled in everywhere. Import it explicitly only from a
//  file that needs it.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ASLayoutSpec, ASStackLayoutSpec, ASInsetLayoutSpec, ASBackgroundLayoutSpec, ASTextNode, ASDisplayNode, ASLayoutElementStyle;

// Real Texture's ASLayoutElementStyle has many more properties; only the two
// flex-sizing ones used so far are declared here.
@interface ASLayoutElementStyle : NSObject
@property (nonatomic) CGFloat flexGrow;
@property (nonatomic) CGFloat flexShrink;
@end

@interface ASDisplayNode : NSObject
- (void)addSubnode:(ASDisplayNode *)subnode;
- (ASDisplayNode *)supernode;
- (void)setNeedsLayout;
- (void)setNeedsDisplay;
- (void)invalidateCalculatedLayout;
- (BOOL)isNodeLoaded;
- (UIView *)view;
- (void)onDidLoad:(void (^)(__kindof ASDisplayNode *node))body;
@property (nonatomic) BOOL userInteractionEnabled;
@property (nullable, nonatomic, copy) UIColor *backgroundColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL clipsToBounds;
@property (nonatomic) CGFloat borderWidth;
@property (nullable, nonatomic) CGColorRef borderColor;
@property (nonatomic, readonly) ASLayoutElementStyle *style;
@end

@interface ASTextNode : ASDisplayNode
@property (nonatomic, copy) NSAttributedString *attributedText;
@property (nonatomic) NSUInteger maximumNumberOfLines;
@end

@interface ASLayoutSpec : NSObject
@property (nullable, nonatomic) NSArray *children;
@property (nonatomic, readonly) ASLayoutElementStyle *style;
@end

@interface ASStackLayoutSpec : ASLayoutSpec
@property (nonatomic) unsigned char direction;
@property (nonatomic) CGFloat spacing;
@property (nonatomic) unsigned char justifyContent;
@property (nonatomic) unsigned char alignItems;
@property (nonatomic) NSUInteger flexWrap;
@property (nonatomic) NSUInteger alignContent;
@property (nonatomic) CGFloat lineSpacing;
+ (instancetype)stackLayoutSpecWithDirection:(unsigned char)direction
                                     spacing:(CGFloat)spacing
                              justifyContent:(unsigned char)justifyContent
                                  alignItems:(unsigned char)alignItems
                                    children:(NSArray *)children;
@end

@interface ASInsetLayoutSpec : ASLayoutSpec
@property (nonatomic) UIEdgeInsets insets;
@property (nullable, nonatomic) id child;
+ (instancetype)insetLayoutSpecWithInsets:(UIEdgeInsets)insets child:(id)child;
@end

@interface ASBackgroundLayoutSpec : ASLayoutSpec
+ (instancetype)backgroundLayoutSpecWithChild:(id)child background:(ASDisplayNode *)background;
@end

NS_ASSUME_NONNULL_END

// ASSizeRange stand-in (named CDStruct_90e057aa in class-dumped headers) so
// Logos can hook the by-value struct argument of -layoutSpecThatFits:.
struct ApolloTextureSizeRange { CGSize min; CGSize max; };
