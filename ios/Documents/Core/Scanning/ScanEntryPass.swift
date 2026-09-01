import UIKit

/// One direct camera pass for a fresh scan, owned by the Tools tab.
///
/// The camera cover used to live inside `ScannerFlowView`, so tapping a
/// scan tool first animated the flow's black camera stage in and the camera
/// over it. The camera is now the first cover the Tools tab presents; this
/// type carries that first pass's captured state and hands the pages to
/// `ScannerFlowView`, which runs the rest of the flow (preview, confirm,
/// save, and every later camera re-entry — retake, scan more, ID-card back
/// side).
///
/// Same VisionKit discipline as the in-flow camera: the cover closes on
/// every callback, and its `onDismiss` is the only point where the next
/// presentation (flow, retry, or reset) happens.
@MainActor
@Observable
final class ScanEntryPass {
    let mode: ScanMode
    let session = ScanSession()

    /// Invoked on every VisionKit callback: the Tools tab must dismiss the
    /// camera cover here (VisionKit's header contract — the app dismisses
    /// the camera in every callback), and the cover's `onDismiss` then runs
    /// the handoff.
    var onCameraDismiss: @MainActor () -> Void = {}

    private(set) var pages: [UIImage] = []
    private(set) var frontPages: [UIImage] = []
    /// Set by any VisionKit callback; lets the close handler tell a
    /// deliberate cancel from a scanner that vanished without delivering.
    private(set) var scanDelivered = false
    /// Failure message from `didFailWithError`; surfaced after the cover
    /// has fully closed.
    private(set) var failureMessage: String?

    init(mode: ScanMode) {
        self.mode = mode
        session.onPages = { [weak self] in self?.handle(pages: $0) }
        session.onCancel = { [weak self] in self?.handleCancel() }
        session.onError = { [weak self] in self?.handleFailure($0) }
    }

    /// True when the pass captured something worth handing to the flow.
    var hasCapture: Bool {
        !pages.isEmpty || !frontPages.isEmpty
    }

    func clearFailure() {
        failureMessage = nil
    }

    /// Clears the capture for the next pass; `mode` stays.
    func reset() {
        pages = []
        frontPages = []
        scanDelivered = false
        failureMessage = nil
    }

    private func handle(pages scanned: [UIImage]) {
        onCameraDismiss()
        scanDelivered = true
        guard !scanned.isEmpty else { return }
        // ID cards capture the front side first; the flow view reopens the
        // camera for the back side from its own stages. Merge semantics
        // mirror `ScannerFlowView.handle(pages:)`.
        if mode == .idCard, frontPages.isEmpty, pages.isEmpty {
            frontPages = scanned
            return
        }
        pages += frontPages + scanned
        frontPages = []
    }

    private func handleCancel() {
        onCameraDismiss()
        scanDelivered = true
    }

    private func handleFailure(_ error: any Error) {
        onCameraDismiss()
        scanDelivered = true
        failureMessage = error.localizedDescription
    }
}
