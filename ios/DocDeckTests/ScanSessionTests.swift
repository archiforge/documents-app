import XCTest
import VisionKit
@testable import DocDeck

/// Drives the scan session through its callback adapter. The VisionKit
/// delegate methods themselves need real hardware (`VNDocumentCameraScan`
/// is not constructible in unit tests), so the adapter carries the
/// unit-testable behavior and a physical-device run covers the delegate
/// path end to end.
@MainActor
final class ScanSessionTests: XCTestCase {
    /// The delegate protocol is @optional, so a method with the wrong
    /// selector name compiles silently and is simply never called — the
    /// shipped `didScan` typo made every real scan vanish (VisionKit calls
    /// `didFinishWithScan:`). This pins the real protocol selectors.
    func testClassRespondsToTheRealVisionKitDelegateSelectors() {
        let session = ScanSession()
        XCTAssertTrue(
            session.responds(to: #selector(
                VNDocumentCameraViewControllerDelegate.documentCameraViewController(_:didFinishWith:)
            )),
            "must implement the real didFinishWithScan: selector, not a wrong-name variant"
        )
        XCTAssertTrue(
            session.responds(to: #selector(
                VNDocumentCameraViewControllerDelegate.documentCameraViewControllerDidCancel(_:)
            ))
        )
        XCTAssertTrue(
            session.responds(to: #selector(
                VNDocumentCameraViewControllerDelegate.documentCameraViewController(_:didFailWithError:)
            ))
        )
    }

    func testDeliverPagesInvokesOnPagesWithGivenPages() {
        let session = ScanSession()
        var received: [[UIImage]] = []
        session.onPages = { received.append($0) }

        let pages = [TestPDF.solidImage(size: CGSize(width: 12, height: 16), color: .systemBlue)]
        session.deliver(pages: pages)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.count, 1)
    }

    func testDeliverCancelInvokesOnCancel() {
        let session = ScanSession()
        var cancellations = 0
        session.onCancel = { cancellations += 1 }

        session.deliverCancel()

        XCTAssertEqual(cancellations, 1)
    }

    func testDeliverFailureInvokesOnError() {
        struct Boom: Error {}
        let session = ScanSession()
        var failures: [any Error] = []
        session.onError = { failures.append($0) }

        session.deliverFailure(Boom())

        XCTAssertEqual(failures.count, 1)
    }

    func testDefaultCallbacksMakeDeliveriesSafe() {
        // Defaults are no-ops: delivering without installed callbacks must
        // not crash (and must not recurse inside the trace path).
        let session = ScanSession()
        session.deliver(pages: [])
        session.deliverCancel()
    }

    func testCallbacksMayBeReboundBetweenDeliveries() {
        let session = ScanSession()
        var first = 0
        var second = 0
        session.onPages = { _ in first += 1 }

        session.deliver(pages: [])
        session.onPages = { _ in second += 1 }
        session.deliver(pages: [])

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
    }
}
