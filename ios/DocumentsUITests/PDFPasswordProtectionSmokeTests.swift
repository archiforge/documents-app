import XCTest

/// Exercises the real protection form and persistence callback with a PDF
/// produced by the app, without relying on imported fixtures or camera access.
@MainActor
final class PDFPasswordProtectionSmokeTests: XCTestCase {
    func testProtectsConvertedPDFAndKeepsOriginal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let name = "Protect Audit " + String(UUID().uuidString.prefix(8))

        app.tabBars.buttons["Tools"].tap()
        app.buttons["New Document"].tap()
        let nameField = app.textFields["Document name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["Markdown (.md)"].tap()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        app.buttons["To PDF"].tap()
        let markdownRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", name + ".md")
        ).firstMatch
        XCTAssertTrue(markdownRow.waitForExistence(timeout: 5))
        markdownRow.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        app.navigationBars.buttons["Tools"].tap()

        app.buttons["PDF Tools"].tap()
        let protectionRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Protect PDF'")
        ).firstMatch
        XCTAssertTrue(protectionRow.waitForExistence(timeout: 5))
        protectionRow.tap()
        let pdfRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", name + ".pdf")
        ).firstMatch
        XCTAssertTrue(pdfRow.waitForExistence(timeout: 5))
        pdfRow.tap()

        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("Synthetic-audit-password")
        let confirmation = app.secureTextFields["Confirm password"]
        confirmation.tap()
        confirmation.typeText("Synthetic-audit-password")
        app.buttons["Protect"].tap()

        let success = app.alerts["PDF Protected"]
        XCTAssertTrue(success.waitForExistence(timeout: 15))
        success.buttons["OK"].tap()
        app.tabBars.buttons["Recent"].tap()
        for filename in [name + ".pdf", "Protected_" + name + ".pdf"] {
            let row = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", filename)
            ).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), filename)
        }
    }
}
