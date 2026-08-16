#import "settings/ApolloWallpapersViewController.h"

#import "settings/ApolloWallpaperViewerViewController.h"

@implementation ApolloWallpapersViewController

+ (NSArray<NSString *> *)goodbyeCaptions {
    return @[
        @"Adventures by David Lanham",
        @"Apollo A1 by Michael Flarup",
        @"Apollo-san by Helunky",
        @"Apollopy by Matthew Skiles",
        @"Argyle by Basic Apple Guy",
        @"Bean Paradise by Beanthew Skiles",
        @"Blast Off! by Helunky",
        @"Stories Around the Campfire by Anthony Piraino (The Iconfactory)",
        @"Playing Cards by Brad Ellis",
        @"Escaping the Circus by Matthew Skiles",
        @"Dino Spoon by Zheng3 / Christian Selig",
        @"Ducky Buddy by Lux",
        @"Floating by Lalit",
        @"Hang Time by David Lanham",
        @"Harmony by David Lanham",
        @"Helping Hand by David Lanham",
        @"Icarus by Michael Flarup",
        @"Keep it Up by David Lanham",
        @"The Masked Bot by Michael Flarup",
        @"Mechapollo by Jorge Velez",
        @"Neon by Candbot & Matthew Skiles",
        @"Onwards by David Lanham",
        @"Pixel Icons by Matthew Skiles",
        @"Reminiscing by David Lanham",
        @"Retirement Island by Matthew Skiles",
        @"Scanning Space by Gavin Nelson",
        @"Scenery by Yannick Lung",
        @"Solara by gleptech",
        @"Spaceman by Matthew Skiles",
        @"Special Place by David Lanham",
        @"Squingus by Adam Whitcroft",
        @"Sticker Bomb by Michael Flarup",
    ];
}

+ (NSArray<NSString *> *)goodbyeIPhoneURLs {
    return @[
        @"https://i.imgur.com/8dY2Pp9.jpeg", @"https://i.imgur.com/AJ7WTuw.jpeg",
        @"https://i.imgur.com/ngR7qDL.jpeg", @"https://i.imgur.com/uM4Nhls.jpeg",
        @"https://i.imgur.com/n7W7z73.jpeg", @"https://i.imgur.com/Wzyu5Gu.jpeg",
        @"https://i.imgur.com/a0b1Aqm.jpeg", @"https://i.imgur.com/E36nGoy.jpeg",
        @"https://i.imgur.com/dIvbzUo.jpeg", @"https://i.imgur.com/6DETaba.jpeg",
        @"https://i.imgur.com/A3klbfB.jpeg", @"https://i.imgur.com/bG6rLfV.jpeg",
        @"https://i.imgur.com/8uitIJZ.jpeg", @"https://i.imgur.com/HGtCU4m.jpeg",
        @"https://i.imgur.com/x41Gm6F.jpeg", @"https://i.imgur.com/PttkHAv.jpeg",
        @"https://i.imgur.com/HHtNY2z.jpeg", @"https://i.imgur.com/TXH8bxS.jpeg",
        @"https://i.imgur.com/Kc9o9G4.jpeg", @"https://i.imgur.com/P2zN82M.jpeg",
        @"https://i.imgur.com/mGXS70i.jpeg", @"https://i.imgur.com/tnHobJA.jpeg",
        @"https://i.imgur.com/zM0R57G.jpeg", @"https://i.imgur.com/l0YLuEo.jpeg",
        @"https://i.imgur.com/6cVawXf.jpeg", @"https://i.imgur.com/CmyLZNG.jpeg",
        @"https://i.imgur.com/dN9YnGc.jpeg", @"https://i.imgur.com/HlsdbJg.jpeg",
        @"https://i.imgur.com/DDdkfh0.jpeg", @"https://i.imgur.com/cnzm9SA.jpeg",
        @"https://i.imgur.com/RHGvhLK.jpeg", @"https://i.imgur.com/9EkRNQs.jpeg",
    ];
}

+ (NSArray<NSString *> *)goodbyeIPadURLs {
    return @[
        @"https://i.imgur.com/NgqQDXt.jpeg", @"https://i.imgur.com/xRgVIr5.jpeg",
        @"https://i.imgur.com/IM7eaeT.jpeg", @"https://i.imgur.com/D4e8NRF.jpeg",
        @"https://i.imgur.com/LGTFDZA.jpeg", @"https://i.imgur.com/9chtljy.jpeg",
        @"https://i.imgur.com/uxL6lBI.jpeg", @"https://i.imgur.com/nbXfwlv.jpeg",
        @"https://i.imgur.com/E1SJuDl.jpeg", @"https://i.imgur.com/gfhQEON.jpeg",
        @"https://i.imgur.com/xPAlIbH.jpeg", @"https://i.imgur.com/RPWHHxh.jpeg",
        @"https://i.imgur.com/XThv2A3.jpeg", @"https://i.imgur.com/YG60e02.jpeg",
        @"https://i.imgur.com/AuMVMXF.jpeg", @"https://i.imgur.com/Eu8S2qN.jpeg",
        @"https://i.imgur.com/SUrzm6S.jpeg", @"https://i.imgur.com/od72XYW.jpeg",
        @"https://i.imgur.com/6AJi43x.jpeg", @"https://i.imgur.com/Rm7kGfK.jpeg",
        @"https://i.imgur.com/4sD0stc.jpeg", @"https://i.imgur.com/ztAWzn7.jpeg",
        @"https://i.imgur.com/ndhknT2.jpeg", @"https://i.imgur.com/sLLw9hY.jpeg",
        @"https://i.imgur.com/DdGBYTZ.jpeg", @"https://i.imgur.com/mUcqY2r.jpeg",
        @"https://i.imgur.com/55F1J2a.jpeg", @"https://i.imgur.com/5AH1P6E.jpeg",
        @"https://i.imgur.com/K4CY2P1.jpeg", @"https://i.imgur.com/eM90sR4.jpeg",
        @"https://i.imgur.com/SB6T3BR.jpeg", @"https://i.imgur.com/A4yOLxp.jpeg",
    ];
}

+ (NSArray<NSString *> *)goodbyeMacURLs {
    return @[
        @"https://i.imgur.com/7a6I7Vc.jpeg", @"https://i.imgur.com/urmwuDX.jpeg",
        @"https://i.imgur.com/uC9ic9e.jpeg", @"https://i.imgur.com/pTtU94f.jpeg",
        @"https://i.imgur.com/JG7Fu69.jpeg", @"https://i.imgur.com/vlz7AWE.jpeg",
        @"https://i.imgur.com/LO5Txr2.jpeg", @"https://i.imgur.com/U4kwkMY.jpeg",
        @"https://i.imgur.com/P0PhCck.jpeg", @"https://i.imgur.com/5xnWb3K.jpeg",
        @"https://i.imgur.com/O0ZsFuV.jpeg", @"https://i.imgur.com/grc6Sqs.jpeg",
        @"https://i.imgur.com/bAzdrvl.jpeg", @"https://i.imgur.com/5S2ohZK.jpeg",
        @"https://i.imgur.com/VtoCvVY.jpeg", @"https://i.imgur.com/IS0Kwyj.jpeg",
        @"https://i.imgur.com/vd3Y8jo.jpeg", @"https://i.imgur.com/uGVhjVd.jpeg",
        @"https://i.imgur.com/zrgx7k9.jpeg", @"https://i.imgur.com/ODkLRAG.jpeg",
        @"https://i.imgur.com/LJTH3tT.jpeg", @"https://i.imgur.com/aui8puo.jpeg",
        @"https://i.imgur.com/V8n5KAI.jpeg", @"https://i.imgur.com/iYfrJXU.jpeg",
        @"https://i.imgur.com/d9WQjif.jpeg", @"https://i.imgur.com/Ts28YDU.jpeg",
        @"https://i.imgur.com/DdK4kYe.jpeg", @"https://i.imgur.com/2GxoJJ8.jpeg",
        @"https://i.imgur.com/eK8njLL.jpeg", @"https://i.imgur.com/DAgTmmm.jpeg",
        @"https://i.imgur.com/6x8rw7n.jpeg", @"https://i.imgur.com/Mj9Wlo9.jpeg",
        @"https://i.imgur.com/Gldd3Ei.png", @"https://i.imgur.com/Lv6Y6oq.png",
        @"https://i.imgur.com/Yu0nLS9.png", @"https://i.imgur.com/QS1erc3.png",
    ];
}

+ (NSArray<NSString *> *)goodbyeMacCaptions {
    return [self.goodbyeCaptions arrayByAddingObjectsFromArray:@[
        @"Adventures — Ultrawide",
        @"Harmony — Ultrawide",
        @"Adventures — Vertical",
        @"Harmony — Vertical",
    ]];
}

+ (NSArray<ApolloWallpaperItem *> *)itemsWithURLs:(NSArray<NSString *> *)URLs captions:(NSArray<NSString *> *)captions {
    NSMutableArray<ApolloWallpaperItem *> *items = [NSMutableArray arrayWithCapacity:URLs.count];
    [URLs enumerateObjectsUsingBlock:^(NSString *URLString, NSUInteger index, __unused BOOL *stop) {
        NSString *caption = index < captions.count ? captions[index] : [NSString stringWithFormat:@"Wallpaper %lu", (unsigned long)index + 1];
        [items addObject:[ApolloWallpaperItem itemWithURLString:URLString caption:caption]];
    }];
    return items;
}

+ (void)presentURLs:(NSArray<NSString *> *)URLs
           captions:(NSArray<NSString *> *)captions
 fromViewController:(UIViewController *)presenter {
    if (!presenter) return;
    ApolloWallpaperViewerViewController *viewer = [[ApolloWallpaperViewerViewController alloc]
        initWithItems:[self itemsWithURLs:URLs captions:captions]];
    [presenter presentViewController:viewer animated:YES completion:nil];
}

+ (void)presentDevicePickerFromViewController:(UIViewController *)presenter
                                   sourceView:(UIView *)sourceView {
    if (!presenter) return;

    // Warm each album's opening page while the user reads and chooses from the
    // device menu. The viewer shares these caches, so its first cell can render
    // immediately instead of beginning its first network request on screen.
    [ApolloWallpaperViewerViewController preloadFirstItemFromItems:
        [self itemsWithURLs:self.goodbyeIPhoneURLs captions:self.goodbyeCaptions]];
    [ApolloWallpaperViewerViewController preloadFirstItemFromItems:
        [self itemsWithURLs:self.goodbyeIPadURLs captions:self.goodbyeCaptions]];
    [ApolloWallpaperViewerViewController preloadFirstItemFromItems:
        [self itemsWithURLs:self.goodbyeMacURLs captions:self.goodbyeMacCaptions]];

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:nil
                         message:@"Choose a device"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    UIImpactFeedbackGenerator *deviceFeedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [deviceFeedback prepare];
    __weak UIViewController *weakPresenter = presenter;
    [sheet addAction:[UIAlertAction actionWithTitle:@"iPhone" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [deviceFeedback impactOccurred];
        [self presentURLs:self.goodbyeIPhoneURLs captions:self.goodbyeCaptions fromViewController:weakPresenter];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"iPad" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [deviceFeedback impactOccurred];
        [self presentURLs:self.goodbyeIPadURLs captions:self.goodbyeCaptions fromViewController:weakPresenter];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Mac" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [deviceFeedback impactOccurred];
        [self presentURLs:self.goodbyeMacURLs captions:self.goodbyeMacCaptions fromViewController:weakPresenter];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    UIView *anchor = sourceView ?: presenter.view;
    popover.sourceView = anchor;
    popover.sourceRect = anchor.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

@end
