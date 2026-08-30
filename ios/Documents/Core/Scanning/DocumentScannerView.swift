import SwiftUI
import VisionKit

/// SwiftUI wrapper around VisionKit's document camera.
///
/// The iOS 26 SDK does not ship a newer document-scanner controller —
/// VisionKit only offers `DataScannerViewController` (a live AR scanner that
/// does not produce page captures), so the classic
/// `VNDocumentCameraViewController` is the right API for page-oriented
/// document/ID/test-paper scanning.
///
/// The delegate lives in `ScanSession`, owned by the presenting view's
/// `@State`, so teardown of this representable can never drop a callback.
struct DocumentScannerView: UIViewControllerRepresentable {
    let session: ScanSession

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = session
        session.attach(controller)
        MainActor.assumeIsolated {
            scanTrace("scanner controller created; delegate attached")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        uiViewController.delegate = session
    }
}
