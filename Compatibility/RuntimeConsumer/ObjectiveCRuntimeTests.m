@import Foundation;
@import XCTest;
@import TelemetryKit;

@interface ObjectiveCRuntimeTests : XCTestCase
@end

@implementation ObjectiveCRuntimeTests

- (void)testConsentCaptureEraseAndShutdownThroughBinaryFacade {
    TKTelemetryConfiguration *configuration = [[TKTelemetryConfiguration alloc]
        initWithEndpoint:[NSURL URLWithString:@"https://telemetry.example.invalid/events"]
                  apiKey:nil];
    configuration.storageNamespace = [@"objc-runtime-" stringByAppendingString:NSUUID.UUID.UUIDString];
    __block TKTelemetryClient *client = nil;
    XCTestExpectation *started = [self expectationWithDescription:@"start"];
    [TKTelemetryClient startWithConfiguration:configuration completion:^(TKTelemetryClient *value, NSError *error) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertNil(error);
        client = value;
        [started fulfill];
    }];
    [self waitForExpectations:@[started] timeout:5];
    XCTAssertNotNil(client);
    if (client == nil) { return; }

    XCTestExpectation *pending = [self expectationWithDescription:@"pending capture rejected"];
    [client captureEventNamed:@"must-not-collect" attributes:@{} completion:^(NSError *error) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertNotNil(error);
        [pending fulfill];
    }];
    [self waitForExpectations:@[pending] timeout:5];

    XCTestExpectation *granted = [self expectationWithDescription:@"grant"];
    [client setConsent:TKTelemetryConsentGranted completion:^(NSError *error) {
        XCTAssertNil(error);
        [granted fulfill];
    }];
    [self waitForExpectations:@[granted] timeout:5];

    XCTestExpectation *captured = [self expectationWithDescription:@"capture"];
    [client captureEventNamed:@"objc.runtime" attributes:@{@"count": @42} completion:^(NSError *error) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertNil(error);
        [captured fulfill];
    }];
    [self waitForExpectations:@[captured] timeout:5];

    XCTestExpectation *queued = [self expectationWithDescription:@"queued"];
    [client queueStatusWithCompletion:^(TKTelemetryQueueStatus *status) {
        XCTAssertEqual(status.eventCount, 1);
        [queued fulfill];
    }];
    [self waitForExpectations:@[queued] timeout:5];

    XCTestExpectation *denied = [self expectationWithDescription:@"deny and purge"];
    [client setConsent:TKTelemetryConsentDenied completion:^(NSError *error) {
        XCTAssertNil(error);
        [denied fulfill];
    }];
    [self waitForExpectations:@[denied] timeout:5];

    XCTestExpectation *empty = [self expectationWithDescription:@"empty"];
    [client queueStatusWithCompletion:^(TKTelemetryQueueStatus *status) {
        XCTAssertEqual(status.eventCount, 0);
        [empty fulfill];
    }];
    [self waitForExpectations:@[empty] timeout:5];

    XCTestExpectation *stopped = [self expectationWithDescription:@"shutdown"];
    [client shutdownWithCompletion:^{
        XCTAssertTrue(NSThread.isMainThread);
        [stopped fulfill];
    }];
    [self waitForExpectations:@[stopped] timeout:5];
}
@end
