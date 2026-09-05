#import "TKDemoTelemetry.h"

@import TelemetryKit;

static NSString *const TKDemoErrorDomain = @"io.telemetrykit.samples.objectivec";

@interface TKDemoTelemetry ()

@property(nonatomic, strong, nullable) TKTelemetryClient *client;

@end


@implementation TKDemoTelemetry

+ (instancetype)shared {
    static TKDemoTelemetry *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (BOOL)isCollectionEnabled {
    @synchronized (self) {
        return self.client != nil;
    }
}

- (void)setCollectionEnabled:(BOOL)enabled
                  completion:(TKDemoErrorCompletion)completion {
    if (enabled) {
        [self startAfterUserConsentWithCompletion:completion];
        return;
    }

    TKTelemetryClient *client = nil;
    @synchronized (self) {
        client = self.client;
        self.client = nil;
    }

    if (client == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    // This is a one-shot async operation, not a block-storing property setter.
    // Retain the wrapper until shutdown; it does not retain this completion.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    [client setConsent:TKTelemetryConsentDenied
             completion:^(NSError * _Nullable consentError) {
        [client shutdownWithCompletion:^{
            dispatch_async(dispatch_get_main_queue(), ^{ completion(consentError); });
        }];
    }];
#pragma clang diagnostic pop
}

- (void)startAfterUserConsentWithCompletion:(TKDemoErrorCompletion)completion {
    @synchronized (self) {
        if (self.client != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
    }

    NSURL *endpoint = [NSURL URLWithString:@"https://telemetry.example.invalid/v1/events"];
    TKTelemetryConfiguration *configuration =
        [[TKTelemetryConfiguration alloc]
            initWithEndpoint:endpoint
                       apiKey:@"replace-with-a-scoped-development-key"];
    configuration.maximumMemoryEventCount = 100;
    configuration.maximumEventCount = 1000;
    configuration.networkURLCollection = TKTelemetryNetworkURLCollectionHost;
    configuration.redactedAttributeKeys = @[ @"authorization", @"cookie", @"token" ];

    [TKTelemetryClient startWithConfiguration:configuration
                                    completion:^(TKTelemetryClient * _Nullable client,
                                                 NSError * _Nullable error) {
        if (client == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
            return;
        }

        // Keep the wrapper alive until the one-shot consent completion installs
        // it on the sample owner. The SDK does not store this block on client.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
        [client setConsent:TKTelemetryConsentGranted
                 completion:^(NSError * _Nullable consentError) {
            if (consentError == nil) {
                @synchronized (self) {
                    self.client = client;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(consentError); });
        }];
#pragma clang diagnostic pop
    }];
}

- (void)captureButtonTapWithCompletion:(TKDemoErrorCompletion)completion {
    TKTelemetryClient *client = nil;
    @synchronized (self) {
        client = self.client;
    }

    if (client == nil) {
        NSError *error = [NSError errorWithDomain:TKDemoErrorDomain
                                             code:1
                                         userInfo:@{
            NSLocalizedDescriptionKey: @"Enable telemetry collection first."
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        return;
    }

    [client captureEventNamed:@"demo.button_tapped"
                   attributes:@{
        @"screen": @"home",
        @"control": @"capture"
    }
                   completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}

- (void)flushWithCompletion:(TKDemoErrorCompletion)completion {
    TKTelemetryClient *client = nil;
    @synchronized (self) {
        client = self.client;
    }

    if (client == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    [client flushWithCompletion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }];
}

@end
