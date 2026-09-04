@import Foundation;
@import TelemetryKit;

// This file is a compile-time compatibility fixture. It deliberately uses
// every supported Objective-C selector so generated-header regressions fail at
// compile time before an SDK release.
int main(void) {
    @autoreleasepool {
        NSURL *endpoint = [NSURL URLWithString:@"https://telemetry.example.com/v1/events"];
        TKTelemetryConfiguration *pendingConfiguration __unused =
            [[TKTelemetryConfiguration alloc] initWithEndpoint:endpoint apiKey:nil];
        TKTelemetryConfiguration *configuration =
            [[TKTelemetryConfiguration alloc] initWithEndpoint:endpoint
                                                        apiKey:@"fixture-key"
                                                       consent:TKTelemetryConsentGranted];
        configuration.customEventsEnabled = YES;
        configuration.networkEventsEnabled = YES;
        configuration.sessionEventsEnabled = YES;
        configuration.spanEventsEnabled = YES;
        configuration.metricKitMetricsEnabled = NO;
        configuration.metricKitDiagnosticsEnabled = NO;
        configuration.sdkDiagnosticsEnabled = NO;
        configuration.sessionTrackingEnabled = YES;
        configuration.sessionTimeout = 900;
        configuration.maximumMemoryEventCount = 32;
        configuration.maximumMemoryBytes = 256 * 1024;
        configuration.maximumEventCount = 256;
        configuration.maximumDiskBytes = 2 * 1024 * 1024;
        configuration.maximumEventBytes = 32 * 1024;
        configuration.maximumEventAge = 86400;
        configuration.queueOverflowPolicy = TKTelemetryQueueOverflowPolicyDropOldest;
        configuration.retryInitialDelay = 0.25;
        configuration.retryMaximumDelay = 8;
        configuration.retryMaximumAttemptsPerCycle = 3;
        configuration.redactedAttributeKeys = @[ @"authorization", @"token" ];
        configuration.maximumAttributeCount = 32;
        configuration.maximumStringLength = 1024;
        configuration.maximumCollectionLength = 32;
        configuration.maximumNestingDepth = 6;
        configuration.networkURLCollection = TKTelemetryNetworkURLCollectionHost;
        configuration.storageNamespace = @"objc-compatibility-fixture";
        TKTelemetryErrorCode bridgeErrorCode __unused = TKTelemetryErrorCodeInvalidAttributes;

        [TKTelemetryClient startWithConfiguration:configuration
                                        completion:^(TKTelemetryClient * _Nullable client,
                                                     NSError * _Nullable startError) {
            if (client == nil) {
                NSLog(@"Objective-C compatibility fixture could not start: %@", startError);
                return;
            }

            NSDictionary<NSString *, id> *attributes = @{
                @"string": @"value",
                @"integer": @42,
                @"double": @3.5,
                @"boolean": @YES,
                @"null": NSNull.null,
                @"array": @[ @"one", @2 ],
                @"object": @{ @"nested": @"value" },
            };

            [client captureEventNamed:@"objc.fixture"
                            attributes:attributes
                              category:TKTelemetryCategoryCustom
                                 level:TKTelemetryLevelInfo
                            completion:^(NSError * _Nullable captureError) {
                NSCAssert(captureError == nil, @"Typed Foundation values must be accepted");
            }];

            [client queueStatusWithCompletion:^(TKTelemetryQueueStatus *status) {
                (void)status.eventCount;
                (void)status.byteCount;
                (void)status.oldestEventDate;
            }];

            [client flushWithReportCompletion:^(TKTelemetryFlushReport * _Nullable report,
                                                 NSError * _Nullable reportError) {
                (void)report.uploadedEventCount;
                (void)report.permanentlyDroppedEventCount;
                (void)report.remainingEventCount;
                (void)reportError;
            }];

            NSURLSession *session = [client makeInstrumentedURLSessionWithConfiguration:
                NSURLSessionConfiguration.ephemeralSessionConfiguration];
            [session invalidateAndCancel];

            [client startSpanNamed:@"objc.fixture.span"
                        attributes:@{}
                        completion:^(TKTelemetrySpan * _Nullable span,
                                     NSError * _Nullable spanError) {
                (void)span.identifier;
                (void)span.operation;
                (void)spanError;
                [span endWithStatus:TKTelemetrySpanStatusOk
                         attributes:@{}
                         completion:^(BOOL ended, NSError * _Nullable endError) {
                    (void)ended;
                    (void)endError;
                }];
            }];

            [client setConsent:TKTelemetryConsentDenied
                     completion:^(NSError * _Nullable consentError) {
                NSCAssert(consentError == nil, @"Consent transition must succeed");
            }];

            [client flushWithCompletion:^(NSError * _Nullable flushError) {
                (void)flushError;
            }];

            [client eraseStoredDataWithCompletion:^(NSError * _Nullable eraseError) {
                NSCAssert(eraseError == nil, @"Stored telemetry must be erasable");
            }];

            [client shutdownWithCompletion:^{}];
        }];
    }
    return 0;
}
