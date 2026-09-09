import XCTest

/// End-to-end interruption coverage using the DEBUG-only isolated draft
/// fixture. The fixture bypasses camera/gallery delivery, but every action
/// after seeding uses the production Tools flow and production draft actor.
@MainActor
final class ScannerDraftRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-DocumentsScannerDraftFixtureID",
            UUID().uuidString,
        ]
        app.launch()
    }

    func testEditedDraftSurvivesFlowCloseAndRelaunchThenSaves() {
        waitForFixture()
        openScanDocument()

        XCTAssertTrue(app.buttons["Resume Draft"].waitForExistence(timeout: 5))
        app.buttons["Resume Draft"].tap()
        XCTAssertTrue(app.navigationBars["Scan ID Card"].waitForExistence(timeout: 5))
        continueToConfirm()

        app.buttons["Edit"].tap()
        let rotate = app.buttons["Rotate"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 5))
        rotate.tap()
        app.navigationBars["Edit Scan"].buttons["Done"].tap()

        app.buttons["Rename"].tap()
        let nameField = app.textFields["Document name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        XCTAssertTrue(app.buttons["Clear name"].waitForExistence(timeout: 5))
        app.buttons["Clear name"].tap()
        nameField.typeText("UI Resumed ID")
        app.buttons["Confirm"].tap()
        XCTAssertTrue(app.buttons["scanner-flow-cancel"].waitForExistence(timeout: 5))

        // Normal flow disappearance keeps the durable snapshot for recovery.
        app.buttons["scanner-flow-cancel"].tap()
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        waitForFixture()
        openScanDocument()
        XCTAssertTrue(app.buttons["Resume Draft"].waitForExistence(timeout: 5))
        app.buttons["Resume Draft"].tap()
        XCTAssertTrue(app.navigationBars["Scan ID Card"].waitForExistence(timeout: 5))
        continueToConfirm()

        // The editor's page value proves the rotation survived the normal
        // flow disappearance and relaunch, rather than only the rename.
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Rotate"].firstMatch.waitForExistence(timeout: 5))
        let restoredPage = app.buttons["scanner-editor-page-1"]
        XCTAssertTrue(restoredPage.waitForExistence(timeout: 5))
        XCTAssertTrue(String(describing: restoredPage.value).contains("90"))
        app.navigationBars["Edit Scan"].buttons["Done"].tap()

        // The edit and rename survived relaunch; inspect the shared rename
        // sheet before saving the restored draft.
        app.buttons["Rename"].tap()
        let restoredName = app.textFields["Document name"]
        XCTAssertTrue(restoredName.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredName.value as? String, "UI Resumed ID")
        app.navigationBars["Rename"].buttons["Cancel"].tap()

        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Save as PDF"].waitForExistence(timeout: 5))
        app.buttons["Save as PDF"].tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10))

        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        waitForFixture()
        openScanDocument()
        XCTAssertTrue(app.buttons["scanner-gallery-import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Resume Draft"].exists)
    }

    private func waitForFixture() {
        XCTAssertTrue(
            app.descendants(matching: .any)["scanner-fixture-ready"].waitForExistence(timeout: 10),
            "The DEBUG scanner fixture was not seeded before UI interaction"
        )
    }

    private func openScanDocument() {
        app.tabBars.buttons["Tools"].tap()
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5))
        app.buttons["Scan Document"].tap()
    }

    private func continueToConfirm() {
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
    }
}
