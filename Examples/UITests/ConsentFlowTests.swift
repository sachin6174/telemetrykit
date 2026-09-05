import XCTest

@MainActor
final class ConsentFlowTests: XCTestCase {
    func testConsentCaptureRevokeAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let consent = app.switches["telemetry.consent"]
        let capture = app.buttons["telemetry.capture"]
        let status = app.textViews["telemetry.status"]
        XCTAssertTrue(consent.waitForExistence(timeout: 30))
        XCTAssertFalse(capture.isEnabled)
        XCTAssertEqual(consent.value as? String, "0")

        toggle(consent, to: "1")
        waitFor("enabled == true", on: capture)
        capture.tap()
        waitFor("value CONTAINS[c] 'accepted'", on: status)

        toggle(consent, to: "0")
        waitFor("enabled == false", on: capture)
        waitFor("enabled == true", on: consent)
        XCTAssertEqual(consent.value as? String, "0")
        // Restart in-process after a purge to exercise storage lease release.
        toggle(consent, to: "1")
        waitFor("enabled == true", on: capture)
        toggle(consent, to: "0")
        waitFor("enabled == false", on: capture)
        waitFor("enabled == true", on: consent)

        app.terminate()
        app.launch()
        XCTAssertTrue(consent.waitForExistence(timeout: 30))
        XCTAssertEqual(consent.value as? String, "0")
        XCTAssertFalse(capture.isEnabled)
    }

    private func toggle(_ element: XCUIElement, to value: String) {
        XCTAssertTrue(element.isHittable)
        // Use a short physical press on the switch track; a zero-duration tap
        // intermittently failed to change UISwitch on the iOS 26.5 simulator.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.15)
        waitFor("value == '\(value)'", on: element)
    }

    private func waitFor(_ predicate: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
}
