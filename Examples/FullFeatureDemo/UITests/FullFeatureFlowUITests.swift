import XCTest

final class FullFeatureFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--full-feature-ui-test"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Client: stopped  •  Consent: pending"]
                .waitForExistence(timeout: 5)
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    /// Runs the same golden path a person follows and asserts the visible result
    /// of every public feature group against the real linked TelemetryKit SDK.
    func testCompleteTelemetryKitFeatureJourney() throws {
        tap("1. Start Client (Pending Consent)")
        waitForLog("Client started with pending consent")
        XCTAssertTrue(app.staticTexts["Client: running  •  Consent: pending"].exists)

        // Prove the real synchronous consent gate rejects capture before grant.
        tap("3. Capture Every Value Type")
        waitForLog("demo.all_value_types: consentRequired")

        tap("2. Grant Consent")
        waitForLog("Consent is now granted")
        XCTAssertTrue(app.staticTexts["Client: running  •  Consent: granted"].exists)

        tap("3. Capture Every Value Type")
        waitForLog("demo.all_value_types: accepted")

        tap("4. Every Level and Category")
        waitForLog("category sdkDiagnostic: accepted")
        for level in ["debug", "info", "warning", "error", "fatal"] {
            XCTAssertTrue(latestResult.contains("level \(level): accepted"))
        }
        for category in [
            "custom", "network", "session", "span", "metricKitMetric",
            "metricKitDiagnostic", "sdkDiagnostic",
        ] {
            XCTAssertTrue(latestResult.contains("category \(category): accepted"))
        }

        tap("5. All Span Outcomes")
        waitForLog("First end=true; repeated end=false")

        tap("6. Client Instrumented Request")
        waitForLog("client-created session completed with HTTP", timeout: 20)

        tap("7. Factory Instrumented Request")
        waitForLog("factory-created session completed with HTTP", timeout: 20)

        tap("8. Forward Metrics from App Delegate")
        waitForLog("app-delegate forwarding session completed with HTTP", timeout: 20)

        tap("9. Inspect Queue Status")
        waitForLog("Queue:")
        XCTAssertTrue(latestResult.contains("payload bytes"))

        tap("Test Invalid Flush Timeout")
        waitForLog("Expected timeout validation error")

        // The endpoint is deliberately non-routable. This verifies that the real
        // transport/retry path reports failure instead of inventing delivery.
        tap("10. Flush and Show Report")
        waitForLog("bounded retry cycle was exhausted", timeout: 25, caseInsensitive: true)

        tap("11. Erase Stored Data")
        waitForLog("Queue now contains 0 events")

        tap("Set Consent to Pending")
        waitForLog("Consent is now pending")

        tap("2. Grant Consent")
        waitForLog("Consent is now granted")

        tap("Deny Consent and Purge")
        waitForLog("Consent is now denied")

        tap("2. Grant Consent")
        waitForLog("Consent is now granted")

        tap("12. Permanently Shut Down")
        waitForLog("capture on the stopped instance returned clientStopped")
        XCTAssertTrue(app.staticTexts["Client: stopped  •  Consent: pending"].exists)
    }

    private var latestResult: String {
        app.staticTexts["telemetry.latest.result"].label
    }

    private func tap(_ title: String) {
        let label = app.staticTexts[title]
        XCTAssertTrue(label.waitForExistence(timeout: 5), "Missing action: \(title)")
        let table = app.tables["telemetry.feature.table"]
        if !label.isHittable {
            // Actions near the beginning (especially Grant Consent after a later
            // action) can exist in the accessibility tree while being far above
            // the visible viewport. Search toward the top first.
            for _ in 0..<8 where !label.isHittable {
                table.swipeDown()
            }
        }
        if !label.isHittable {
            // Then search toward the bottom for later golden-path actions.
            for _ in 0..<12 where !label.isHittable {
                table.swipeUp()
            }
        }
        XCTAssertTrue(label.isHittable, "Action exists but could not be scrolled into view: \(title)")
        label.tap()
    }

    private func waitForLog(
        _ expected: String,
        timeout: TimeInterval = 8,
        alternate: String? = nil,
        caseInsensitive: Bool = false
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = caseInsensitive ? latestResult.lowercased() : latestResult
            let first = caseInsensitive ? expected.lowercased() : expected
            let second = alternate.map { caseInsensitive ? $0.lowercased() : $0 }
            if text.contains(first) || second.map(text.contains) == true {
                // The controller writes the result immediately before its `defer`
                // block re-enables the table. Allow that UI cleanup to settle so
                // the next synthetic tap cannot arrive during the tiny disabled
                // window.
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Latest result never contained '\(expected)'. Final result:\n\(latestResult)")
    }
}
