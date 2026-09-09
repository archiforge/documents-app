import XCTest

/// Simulator smoke coverage for the camera-free scanner entry. The test
/// reaches the scanner flow and its PhotosPicker affordance without requiring
/// VisionKit camera hardware.
@MainActor
final class ScannerGallerySmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testCameraFreeEntryReachesGalleryImport() {
        app.tabBars.buttons["Tools"].tap()
        app.buttons["Scan Document"].tap()

        let unavailable = app.alerts["Camera unavailable"]
        if unavailable.waitForExistence(timeout: 5) {
            unavailable.buttons["OK"].tap()
        }

        let importButton = app.buttons["scanner-gallery-import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()

        // PhotosPicker is a system surface; its Cancel button is the stable
        // affordance available to UI tests across iPhone and iPad layouts.
        let cancel = app.navigationBars["Photos"].buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
    }
}
