import XCTest

@MainActor
final class AIReviewSmokeTests: XCTestCase {
    func testSmartExtractionRequiresReviewAndPreservesSource() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let suffix = String(UUID().uuidString.prefix(8))
        let sourceName = "AI Source " + suffix
        let outputName = "AI Reviewed " + suffix

        app.documentTab(named: "Tools").tap()
        app.buttons["New Document"].tap()
        let name = app.textFields["Document name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(sourceName)
        app.buttons["Markdown (.md)"].tap()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        let extraction = app.buttons["Smart Extraction"]
        for _ in 0..<10 where !extraction.isHittable { app.swipeUp() }
        XCTAssertTrue(extraction.isHittable)
        extraction.tap()
        let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", sourceName)).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        let save = app.buttons["Save AI Result"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        app.buttons["Discard"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertFalse(save.exists)

        source.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        let output = app.textFields["Output name"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        output.tap()
        output.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        if let old = output.value as? String {
            output.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        output.typeText(outputName)
        XCTAssertEqual(output.value as? String, outputName)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ai-smart-extraction-review"
        attachment.lifetime = .keepAlways
        add(attachment)
        save.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.documentTab(named: "Recent").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", sourceName)).firstMatch.waitForExistence(timeout: 5))
        let generated = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", outputName))
        XCTAssertTrue(generated.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(generated.count, 1)
    }
}
