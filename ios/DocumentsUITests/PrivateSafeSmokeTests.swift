import XCTest

@MainActor
final class PrivateSafeSmokeTests: XCTestCase {
    func testManageOpensLockedSafeAtLargeTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        app.documentTab(named: "Manage").tap()
        let safe = app.buttons["private-safe-entry"]
        XCTAssertTrue(safe.waitForExistence(timeout: 5))
        safe.tap()
        XCTAssertTrue(app.navigationBars["Private Safe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["private-safe-lock-screen"].exists)
        XCTAssertTrue(app.buttons["Unlock Private Safe"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "private-safe-locked-accessibility-xxxl"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCancellingCopyToSafeKeepsOriginalDocument() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let name = "Safe Audit " + String(UUID().uuidString.prefix(8))
        app.documentTab(named: "Tools").tap()
        app.buttons["New Document"].tap()
        let field = app.textFields["Document name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.documentTab(named: "Recent").tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        let copy = app.buttons["Copy to Private Safe"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(app.descendants(matching: .any)["private-safe-copy-sheet"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }
}
