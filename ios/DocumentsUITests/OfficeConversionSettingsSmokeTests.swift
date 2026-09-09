import XCTest

@MainActor
final class OfficeConversionSettingsSmokeTests: XCTestCase {
    func testServiceSettingsRequireHTTPSWithoutChangingSavedConfiguration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.documentTab(named: "Manage").tap()
        app.buttons["Settings"].tap()
        let entry = app.buttons["office-conversion-settings-entry"]
        for _ in 0..<5 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let endpoint = app.textFields["Office conversion HTTPS endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        replaceText(in: endpoint, with: "http://localhost:8080")
        XCTAssertFalse(app.buttons["Save service settings"].isEnabled)
        replaceText(in: endpoint, with: "https://conversion.example.test")
        XCTAssertTrue(app.buttons["Save service settings"].isEnabled)
        XCTAssertTrue(app.secureTextFields["Office conversion bearer token"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "office-conversion-https-settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Deliberately leave without Save: UI validation must not send a file
        // or change the application's persisted endpoint/token.
        app.navigationBars["Office Conversion"].buttons["Settings"].firstMatch.tap()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, current.contains("://") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }
}
