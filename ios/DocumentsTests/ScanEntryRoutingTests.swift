import XCTest
@testable import Documents

final class ScanEntryRoutingTests: XCTestCase {
    func testExistingDraftAlwaysSkipsCamera() {
        XCTAssertEqual(
            ScanEntryRouting.route(hasDraft: true, cameraAvailable: true),
            .restoreDraft
        )
        XCTAssertEqual(
            ScanEntryRouting.route(hasDraft: true, cameraAvailable: false),
            .restoreDraft
        )
    }

    func testFreshSupportedDeviceKeepsDirectCameraEntry() {
        XCTAssertEqual(
            ScanEntryRouting.route(hasDraft: false, cameraAvailable: true),
            .directCamera
        )
    }

    func testFreshUnsupportedDeviceEntersGalleryFlow() {
        XCTAssertEqual(
            ScanEntryRouting.route(hasDraft: false, cameraAvailable: false),
            .galleryFlow
        )
    }

    func testResumingDraftUsesSavedModeEvenWhenEntryRequestedAnotherMode() {
        XCTAssertEqual(
            ScanEntryRouting.modeForResume(requested: .document, draftMode: .idCard),
            .idCard
        )
        XCTAssertEqual(
            ScanEntryRouting.modeForResume(requested: .idCard, draftMode: .testPaper),
            .testPaper
        )
    }

    func testFreshSessionKeepsRequestedMode() {
        XCTAssertEqual(
            ScanEntryRouting.modeForResume(requested: .idCard, draftMode: nil),
            .idCard
        )
    }

    func testOnlySuccessfulFrontDeliveryReopensIDCardBackCamera() {
        XCTAssertEqual(
            ScanFlowCameraRouting.closeAction(
                outcome: .pages,
                frontPageCount: 1,
                pageCount: 0
            ),
            .openBackCamera
        )
        XCTAssertEqual(
            ScanFlowCameraRouting.closeAction(
                outcome: .failed,
                frontPageCount: 1,
                pageCount: 0
            ),
            .showPreview
        )
        XCTAssertEqual(
            ScanFlowCameraRouting.closeAction(
                outcome: .dropped,
                frontPageCount: 1,
                pageCount: 0
            ),
            .showPreview
        )
    }

    func testCameraUnavailableAndEmptyFailureDoNotCompeteWithGenericRetry() {
        XCTAssertEqual(
            ScanEntryRouting.route(hasDraft: false, cameraAvailable: false),
            .galleryFlow
        )
        XCTAssertEqual(
            ScanFlowCameraRouting.closeAction(
                outcome: .failed,
                frontPageCount: 0,
                pageCount: 0
            ),
            .stayForError
        )
        XCTAssertEqual(
            ScanFlowCameraRouting.closeAction(
                outcome: .dropped,
                frontPageCount: 0,
                pageCount: 0
            ),
            .showNoPages
        )
    }
}
