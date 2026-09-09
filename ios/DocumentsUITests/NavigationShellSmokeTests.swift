import XCTest

/// Smoke coverage for the P3 shell and Recent's primary create action.
/// This intentionally stops at the action menu so the test does not require
/// a physical camera or persist a fixture document.
@MainActor
final class NavigationShellSmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testShellHasRecentToolsAndManageTabs() {
        XCTAssertTrue(app.documentTab(named: "Recent").waitForExistence(timeout: 5))
        XCTAssertTrue(app.documentTab(named: "Tools").exists)
        XCTAssertTrue(app.documentTab(named: "Manage").exists)
        XCTAssertFalse(app.documentTab(named: "Favorites").exists)
        XCTAssertFalse(app.documentTab(named: "Cloud").exists)
        XCTAssertFalse(app.documentTab(named: "Browse").exists)
    }

    func testRecentCreateMenuOffersScanAndNewDocument() {
        app.documentTab(named: "Recent").tap()

        let createMenu = app.buttons["recent-create-menu"]
        XCTAssertTrue(createMenu.waitForExistence(timeout: 5))
        createMenu.tap()

        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["New Document"].exists)
    }
}

/// iPhone exposes native tabs inside a TabBar. Regular-width iPad exposes
/// floating tab buttons directly, outside that container.
@MainActor
extension XCUIApplication {
    func documentTab(named title: String) -> XCUIElement {
        let compactTab = tabBars.buttons[title]
        if compactTab.exists { return compactTab }
        return buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }
}
