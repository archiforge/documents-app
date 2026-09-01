import XCTest

/// End-to-end smoke for the selection mode (board R3.8) — the one flow the
/// unit tests can't cover: toolbar-attached confirmation dialog, bottom
/// bulk bar, checkmark rows, and the auto-exit after a bulk trash.
///
/// Self-sufficient: it creates its own text document through the Tools tab
/// first, so it needs no pre-seeded library (name collisions across reruns
/// are handled by the store's " (n)" dedup + prefix matching).
final class BulkSelectionSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testSelectFlowWithConfirmDialogAndAutoExit() {
        createTextDocument(named: "Bulk Smoke")

        app.tabBars.buttons["Recent"].tap()
        let anyBulkRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Bulk Smoke'")
        ).firstMatch
        XCTAssertTrue(anyBulkRow.waitForExistence(timeout: 5), "Created document should appear in Recent")
        // Earlier failed runs may have left sibling rows behind — pin the
        // exact file this run created (" (n)"-deduped).
        let row = app.buttons[anyBulkRow.label]

        // Enter selection mode from the toolbar.
        app.buttons["Select"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Select All"].exists)

        // Bulk bar is present but disabled until something is selected.
        let delete = app.buttons["Delete"]
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["More"].exists)
        XCTAssertFalse(delete.isEnabled)

        // Select-all / deselect-all round trip.
        app.buttons["Select All"].tap()
        XCTAssertTrue(app.buttons["Deselect All"].waitForExistence(timeout: 3))
        app.buttons["Deselect All"].tap()
        XCTAssertTrue(app.buttons["Select All"].waitForExistence(timeout: 3))
        XCTAssertFalse(delete.isEnabled)

        // Tap the row to select it — the bar enables.
        row.tap()
        XCTAssertTrue(delete.isEnabled)

        // Delete asks for confirmation before the soft trash.
        delete.tap()
        let confirm = app.buttons["Move to Trash"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Confirmation dialog must present from the toolbar bar")
        confirm.tap()

        // A fully-emptied selection exits select mode; the row is gone.
        XCTAssertFalse(app.buttons["Cancel"].waitForExistence(timeout: 3), "Selection mode should auto-exit after the bulk trash")
        XCTAssertTrue(app.buttons["Select"].waitForExistence(timeout: 3), "Normal toolbar should return")
        XCTAssertFalse(row.waitForExistence(timeout: 3), "Trashed document should leave the list")
    }

    // MARK: - Helpers

    /// Tools ▸ New Document ▸ plain text ▸ Create ▸ close the viewer the
    /// tool opens on the new file.
    private func createTextDocument(named name: String) {
        app.tabBars.buttons["Tools"].tap()
        app.buttons["New Document"].tap()

        let field = app.textFields["Document name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        dismissKeyboard()

        app.buttons["Create"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Creation hands the file to the viewer")
        done.tap()
        XCTAssertTrue(app.tabBars.buttons["Recent"].waitForExistence(timeout: 5))
    }

    /// The simulator may run with a hardware keyboard, where the software
    /// return key is absent — fall back to tapping outside the field.
    private func dismissKeyboard() {
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.exists {
            returnKey.tap()
        } else {
            app.staticTexts["Type"].tap()
        }
    }
}
