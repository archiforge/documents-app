import XCTest

/// Simulator coverage for the English release surface at an accessibility
/// Dynamic Type size. Assertions intentionally target the labels and routes
/// users rely on, rather than suppressing a blanket accessibility audit.
@MainActor
final class AccessibilityReleaseTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
    }

    func testLargeTypeKeepsManageFolderNavigationReachable() {
        app.documentTab(named: "Manage").tap()

        let imports = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Files imports'")
        ).firstMatch
        for _ in 0..<5 where !imports.isHittable { app.swipeUp() }
        XCTAssertTrue(imports.waitForExistence(timeout: 5))
        XCTAssertTrue(imports.isHittable)
        attachScreenshot(named: "manage-accessibility-xxxl")
        imports.tap()

        XCTAssertTrue(app.navigationBars["Documents"].waitForExistence(timeout: 5))
        let back = app.navigationBars.buttons["Manage"]
        XCTAssertTrue(back.exists)
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.navigationBars["Manage"].waitForExistence(timeout: 5))
    }

    func testRecentControlsExposeLabelsAndSelectedFilterAtLargeType() {
        app.documentTab(named: "Recent").tap()

        let allFilter = app.buttons["All filter"]
        XCTAssertTrue(allFilter.waitForExistence(timeout: 5))
        XCTAssertTrue(allFilter.isHittable)
        XCTAssertEqual(allFilter.value as? String, "Selected")
        let search = app.buttons["Search"]
        let settings = app.buttons["Settings"]
        let sort = app.buttons["Sort"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(sort.waitForExistence(timeout: 3))
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(settings.isHittable)
        XCTAssertTrue(sort.isHittable)
        attachScreenshot(named: "recent-accessibility-xxxl")

        let createMenu = app.buttons["recent-create-menu"]
        XCTAssertTrue(createMenu.isHittable)
        createMenu.tap()
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["New Document"].exists)
    }

    func testRecentShellAccessibilityAudit() throws {
        app.documentTab(named: "Recent").tap()
        XCTAssertTrue(app.navigationBars["Recent"].waitForExistence(timeout: 5))

        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription]) { issue in
            XCTFail("Accessibility issue: \(issue.compactDescription) — \(issue.detailedDescription)")
            return false
        }
    }

    func testRenameSheetUsesFlexibleHeightAtLargeType() {
        createTextDocument(named: "Accessibility Rename")
        app.documentTab(named: "Recent").tap()

        let row = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Accessibility Rename'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)

        let rename = app.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.tap()

        XCTAssertTrue(app.descendants(matching: .any)["rename-sheet"].waitForExistence(timeout: 5))
        let confirm = app.buttons["Confirm"]
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(cancel.isHittable)
        attachScreenshot(named: "rename-accessibility-xxxl")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func createTextDocument(named name: String) {
        app.documentTab(named: "Tools").tap()
        app.buttons["New Document"].tap()

        let field = app.textFields["Document name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.exists {
            returnKey.tap()
        } else {
            app.staticTexts["Type"].tap()
        }

        app.buttons["Create"].tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }
}
