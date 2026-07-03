#import "ApolloThemeQRScanViewController.h"
#import "ApolloThemeShareImage.h"
#import "ApolloCommon.h"
#import <AVFoundation/AVFoundation.h>

@interface ApolloThemeQRScanViewController () <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) UIView *viewfinder;
@property (nonatomic, assign) BOOL handled;   // one-shot guard against repeat detections
@property (nonatomic, assign) BOOL didConfigure;
@end

@implementation ApolloThemeQRScanViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // Dimmed instruction label near the top.
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = @"Point at an Apollo theme QR code";
    hint.textColor = [UIColor whiteColor];
    hint.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.numberOfLines = 0;
    hint.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
    hint.shadowOffset = CGSizeMake(0, 1);
    [self.view addSubview:hint];

    // Centered viewfinder square.
    UIView *finder = [[UIView alloc] init];
    finder.translatesAutoresizingMaskIntoConstraints = NO;
    finder.backgroundColor = [UIColor clearColor];
    finder.layer.borderColor = [UIColor whiteColor].CGColor;
    finder.layer.borderWidth = 3.0;
    finder.layer.cornerRadius = 16.0;
    [self.view addSubview:finder];
    self.viewfinder = finder;

    // Cancel button.
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancel setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    cancel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    cancel.contentEdgeInsets = UIEdgeInsetsMake(10, 22, 10, 22);
    cancel.layer.cornerRadius = 22.0;
    [cancel addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
        [hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],

        [finder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [finder.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [finder.widthAnchor constraintEqualToConstant:260],
        [finder.heightAnchor constraintEqualToConstant:260],

        [cancel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-28],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Bring up the camera only once the present transition has completed — a
    // permission-denied / no-camera (e.g. Simulator) alert presented during the
    // transition (from viewWillAppear:) can be silently dropped, leaving a blank
    // scanner; by viewDidAppear: the VC is settled so the alert reliably shows
    // (and the preview layer is correctly sized before startRunning).
    if (!self.didConfigure) {
        self.didConfigure = YES;
        [self ensureCameraThenStart];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopSession];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewLayer.frame = self.view.layer.bounds;
}

#pragma mark - Camera setup

- (void)ensureCameraThenStart {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self setupAndStart];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    [self setupAndStart];
                } else {
                    [self failWithTitle:@"Camera Access Needed"
                                message:@"Allow camera access for Apollo in Settings to scan a theme QR code, or use “From Photo…” instead."];
                }
            });
        }];
    } else { // denied / restricted
        [self failWithTitle:@"Camera Access Needed"
                    message:@"Camera access for Apollo is turned off. Enable it in Settings to scan a theme QR code, or use “From Photo…” instead."];
    }
}

- (void)setupAndStart {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) { // e.g. the Simulator has no camera
        [self failWithTitle:@"Camera Unavailable"
                    message:@"No usable camera was found. Use “From Photo…” to import a saved theme image instead."];
        return;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    if (!input || ![session canAddInput:input] || ![session canAddOutput:output]) {
        ApolloLog(@"ThemeScan: camera session setup failed: %@", error);
        [self failWithTitle:@"Camera Unavailable"
                    message:@"The camera could not be started. Use “From Photo…” instead."];
        return;
    }
    [session addInput:input];
    [session addOutput:output];
    [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
    self.session = session;

    AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
    preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    preview.frame = self.view.layer.bounds;
    [self.view.layer insertSublayer:preview atIndex:0];
    self.previewLayer = preview;

    // startRunning blocks; keep it off the main thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session startRunning];
    });
}

- (void)stopSession {
    AVCaptureSession *session = self.session;
    if (session.isRunning) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [session stopRunning];
        });
    }
}

#pragma mark - Detection

- (void)captureOutput:(AVCaptureOutput *)output
        didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
        fromConnection:(AVCaptureConnection *)connection {
    if (self.handled) return;
    for (AVMetadataObject *obj in metadataObjects) {
        if (![obj isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) continue;
        AVMetadataMachineReadableCodeObject *code = (AVMetadataMachineReadableCodeObject *)obj;
        if (![code.type isEqualToString:AVMetadataObjectTypeQRCode]) continue;

        NSDictionary *parsed = ApolloThemeShareDecodePayload(code.stringValue);
        if (!parsed) {
            continue; // not an Apollo theme QR — keep scanning silently
        }
        self.handled = YES;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self stopSession];
        ApolloLog(@"ThemeScan: scanned theme name=%@", parsed[@"name"]);
        void (^cb)(NSDictionary *) = self.onScan;
        [self dismissViewControllerAnimated:YES completion:^{
            if (cb) cb(parsed);
        }];
        return;
    }
}

#pragma mark - Actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)failWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
