import XCTest

@MainActor
final class ToolsCapabilitySmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        app.documentTab(named: "Tools").tap()
        XCTAssertTrue(app.navigationBars["Tools"].waitForExistence(timeout: 5))
    }

    func testToolsBoardShowsHeroGroupsAndCapabilityStates() {
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5))
        attachScreenshot(named: "tools-board-normal")
        let conversionHeading = app.staticTexts["File conversion"]
        scrollUntilVisible(conversionHeading)
        XCTAssertTrue(isVisible(conversionHeading))

        let word = app.buttons["To Word"]
        scrollUntilVisible(word)
        XCTAssertTrue(word.isEnabled)
        XCTAssertEqual(word.value as? String, "Available")
        let pdf = app.buttons["To PDF"]
        scrollUntilVisible(pdf)
        XCTAssertTrue(pdf.exists)

        let aiHeading = app.staticTexts["AI tools"]
        scrollUntilVisible(aiHeading)
        XCTAssertTrue(isVisible(aiHeading))
        let summary = app.buttons["Document Summary"]
        scrollUntilVisible(summary)
        // Summary readiness depends on Apple Intelligence/model state. The
        // route remains open so the destination can offer a retry when the
        // system model is preparing.
        if summary.value as? String == "Available" {
            XCTAssertTrue(summary.isEnabled)
            XCTAssertEqual(summary.value as? String, "Available")
        } else {
            XCTAssertTrue(summary.isEnabled)
            XCTAssertEqual(summary.value as? String, "Unavailable")
            let reason = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'on-device model'")
            ).firstMatch
            XCTAssertTrue(reason.waitForExistence(timeout: 2))
        }
        for title in ["Document Translation", "Smart Extraction", "Extract Chart", "Extract Formula"] {
            let tool = app.buttons[title]
            scrollUntilVisible(tool)
            XCTAssertTrue(tool.isEnabled, title)
            XCTAssertEqual(tool.value as? String, "Available", title)
        }
    }

    func testToolsBoardAtAccessibilityTextSizeRemainsReachable() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        app.documentTab(named: "Tools").tap()
        XCTAssertTrue(app.buttons["Scan Document"].waitForExistence(timeout: 5))
        attachScreenshot(named: "tools-board-accessibility-xxxl-hero")

        let summary = app.buttons["Document Summary"]
        scrollUntilCentered(summary)
        XCTAssertTrue(isCentered(summary))
        attachScreenshot(named: "tools-board-accessibility-xxxl-summary")
    }

    private func scrollUntilVisible(_ element: XCUIElement) {
        // Disabled capability tiles are intentionally not hittable. Use their
        // actual frame intersection with the app viewport instead of `exists`,
        // which remains true for offscreen lazy content.
        for _ in 0..<8 where !isVisible(element) {
            app.swipeUp()
        }
        XCTAssertTrue(isVisible(element))
    }

    private func scrollUntilCentered(_ element: XCUIElement) {
        for _ in 0..<14 {
            guard element.exists else {
                app.swipeUp()
                continue
            }
            let viewport = safeViewport()
            let frame = element.frame
            if isCentered(element) { return }
            if frame.midY > viewport.maxY {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        XCTAssertTrue(isCentered(element))
    }

    private func isVisible(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let viewport = safeViewport()
        return frame.width > 0
            && frame.height > 0
            && frame.intersects(viewport)
    }

    private func isCentered(_ element: XCUIElement) -> Bool {
        guard isVisible(element) else { return false }
        let frame = element.frame
        let viewport = safeViewport()
        let intersection = frame.intersection(viewport)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return viewport.contains(center)
            && intersection.height >= min(frame.height, 96)
    }

    private func safeViewport() -> CGRect {
        let window = app.windows.firstMatch.frame
        var top = window.minY
        var bottom = window.maxY
        let navigation = app.navigationBars.firstMatch
        if navigation.exists {
            top = max(top, navigation.frame.maxY)
        }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            if tabBar.frame.midY < window.midY {
                top = max(top, tabBar.frame.maxY)
            } else {
                bottom = min(bottom, tabBar.frame.minY)
            }
        }
        return CGRect(
            x: window.minX,
            y: top,
            width: window.width,
            height: max(0, bottom - top)
        )
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
