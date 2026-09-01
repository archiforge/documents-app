import XCTest
import VisionKit
@testable import Documents

/// Drives the Tools tab's direct camera pass through the `ScanSession`
/// adapter. The VisionKit delegate path itself needs real hardware; these
/// cover the first-pass state machine that decides what the Tools tab does
/// when the camera cover closes.
@MainActor
final class ScanEntryPassTests: XCTestCase {
    func testDeliveredPagesAreCapturedForDocumentMode() {
        let pass = ScanEntryPass(mode: .document)
        let pages = [
            TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemBlue),
            TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemRed),
        ]

        pass.session.deliver(pages: pages)

        XCTAssertTrue(pass.scanDelivered)
        XCTAssertTrue(pass.hasCapture)
        XCTAssertEqual(pass.pages.count, 2)
        XCTAssertTrue(pass.frontPages.isEmpty)
        XCTAssertNil(pass.failureMessage)
    }

    func testEmptyDeliveryMarksDeliveredWithoutCapture() {
        // A didFinishWithScan with zero pages recovers on scanner close by
        // ending the flow, exactly like an empty in-flow delivery.
        let pass = ScanEntryPass(mode: .document)

        pass.session.deliver(pages: [])

        XCTAssertTrue(pass.scanDelivered)
        XCTAssertFalse(pass.hasCapture)
    }

    func testCancelMarksDeliveredWithoutCapture() {
        let pass = ScanEntryPass(mode: .document)

        pass.session.deliverCancel()

        XCTAssertTrue(pass.scanDelivered)
        XCTAssertFalse(pass.hasCapture)
        XCTAssertNil(pass.failureMessage)
    }

    func testFailureRecordsMessageAndDelivered() {
        let pass = ScanEntryPass(mode: .document)

        pass.session.deliverFailure(StubError())

        XCTAssertTrue(pass.scanDelivered)
        XCTAssertFalse(pass.hasCapture)
        XCTAssertEqual(pass.failureMessage, StubError().localizedDescription)
    }

    func testIDCardFirstDeliveryBecomesFrontPages() {
        let pass = ScanEntryPass(mode: .idCard)
        let front = TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemBlue)

        pass.session.deliver(pages: [front])

        XCTAssertEqual(pass.frontPages.count, 1)
        XCTAssertTrue(pass.pages.isEmpty)
        XCTAssertTrue(pass.hasCapture)
    }

    func testIDCardSecondDeliveryMergesFrontAndBack() {
        // Defensive: the flow view normally handles the back side, but a
        // second delivery at pass level must merge, not overwrite.
        let pass = ScanEntryPass(mode: .idCard)
        let front = TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemBlue)
        let back = TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemRed)

        pass.session.deliver(pages: [front])
        pass.session.deliver(pages: [back])

        XCTAssertEqual(pass.pages.count, 2)
        XCTAssertTrue(pass.frontPages.isEmpty)
    }

    func testResetClearsCaptureButKeepsModeAndSession() {
        let pass = ScanEntryPass(mode: .idCard)
        pass.session.deliver(pages: [TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemBlue)])

        pass.reset()

        XCTAssertFalse(pass.hasCapture)
        XCTAssertFalse(pass.scanDelivered)
        XCTAssertEqual(pass.mode, .idCard)
    }

    func testClearFailureRemovesMessage() {
        let pass = ScanEntryPass(mode: .document)
        pass.session.deliverFailure(StubError())

        pass.clearFailure()

        XCTAssertNil(pass.failureMessage)
    }

    /// VisionKit's header contract: the app dismisses the camera in every
    /// delegate callback. Without this, Cancel (and every other callback)
    /// leaves the camera stuck on screen.
    func testEveryCallbackRequestsCameraDismissal() {
        let pass = ScanEntryPass(mode: .document)
        var dismissals = 0
        pass.onCameraDismiss = { dismissals += 1 }

        pass.session.deliver(pages: [TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemBlue)])
        pass.session.deliver(pages: [])
        pass.session.deliverCancel()
        pass.session.deliverFailure(StubError())

        XCTAssertEqual(dismissals, 4, "every callback, including an empty delivery, must dismiss the camera")
    }
}

private struct StubError: LocalizedError {
    var errorDescription: String? { "stub failure" }
}
