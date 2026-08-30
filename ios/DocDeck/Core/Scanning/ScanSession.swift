import Foundation
import os
import VisionKit

/// Scanner diagnostics, streamable via `devicectl device process launch --console`.
let scanLog = Logger(subsystem: "com.docdeck.app", category: "scan")

/// Mirrors scan traces to stdout as well: `devicectl --console` captures
/// stdout/stderr only, not the unified os_log store.
@MainActor
func scanTrace(_ message: String) {
    scanLog.notice("\(message, privacy: .public)")
    print("[scan] \(message)")
}

/// Owns the `VNDocumentCameraViewController` delegate outside of any
/// `UIViewControllerRepresentable` lifecycle.
///
/// VisionKit dismisses its own controller when the user confirms a scan;
/// SwiftUI then tears the presenting cover down and can deallocate a
/// coordinator created in `makeCoordinator` *before* `didScan` is delivered,
/// silently dropping the pages. Holding the delegate in the flow view's
/// `@State` keeps it alive for the whole scan session.
@MainActor
final class ScanSession: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
    var onPages: @MainActor ([UIImage]) -> Void = { _ in }
    var onCancel: @MainActor () -> Void = {}
    var onError: @MainActor (any Error) -> Void = { _ in }

    /// Strong reference to the presented scanner controller. VisionKit holds
    /// its delegate weakly; if presentation machinery tears the controller
    /// down mid-callback, the delegate invocation is lost with the scan.
    /// Holding it here keeps the controller alive until its callback ran.
    private var liveController: VNDocumentCameraViewController?

    // The init runs in a @State default value (nonisolated view init), so it
    // must not touch actor-isolated state; the closure defaults are plain.
    nonisolated override init() {
        super.init()
    }

    /// Called when the representable creates the scanner controller.
    func attach(_ controller: VNDocumentCameraViewController) {
        liveController = controller
    }

    /// Called when the flow's scanner presentation has fully ended.
    func detach() {
        liveController = nil
    }

    // MARK: - Callback adapter

    /// The delegate methods forward here so tests can drive
    /// success/cancel/failure without VisionKit fixtures —
    /// `VNDocumentCameraScan` is not constructible off hardware.
    func deliver(pages: [UIImage]) {
        scanTrace("didScan delivered \(pages.count) page(s)")
        onPages(pages)
        releaseController()
    }

    func deliverCancel() {
        scanTrace("scanner cancelled by user")
        onCancel()
        releaseController()
    }

    func deliverFailure(_ error: any Error) {
        scanTrace("scanner failed: \(error.localizedDescription)")
        onError(error)
        releaseController()
    }

    private func releaseController() {
        liveController = nil
    }

    // MARK: - VNDocumentCameraViewControllerDelegate

    // The success selector is `didFinishWithScan:` (Swift: didFinishWith).
    // The protocol is @optional, so a wrong-name method like `didScan`
    // compiles silently and is simply never called — VisionKit hands over
    // the scan and the flow loses it. Guarded by a responds(to:) test.
    //
    // VisionKit delivers these callbacks on the main thread; the
    // @preconcurrency conformance bridges the unisolated ObjC protocol.
    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController,
        didFinishWith scan: VNDocumentCameraScan
    ) {
        var pages: [UIImage] = []
        for index in 0..<scan.pageCount {
            pages.append(scan.imageOfPage(at: index))
        }
        deliver(pages: pages)
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        deliverCancel()
    }

    func documentCameraViewController(
        _ controller: VNDocumentCameraViewController,
        didFailWithError error: any Error
    ) {
        deliverFailure(error)
    }
}
