import Foundation

/// Decides how a scan-tool tap enters the flow. Keeping this decision pure
/// lets tests cover draft recovery and camera-unavailable gallery access
/// without constructing VisionKit controllers.
enum ScanEntryRoute: Equatable, Sendable {
    case restoreDraft
    case directCamera
    case galleryFlow
}

enum ScanEntryRouting {
    static func route(hasDraft: Bool, cameraAvailable: Bool) -> ScanEntryRoute {
        if hasDraft { return .restoreDraft }
        return cameraAvailable ? .directCamera : .galleryFlow
    }

    /// A resumed draft owns its scan mode. A discard or a fresh session keeps
    /// the mode the user requested from the Tools grid.
    static func modeForResume(requested: ScanMode, draftMode: ScanMode?) -> ScanMode {
        draftMode ?? requested
    }
}

/// Outcome of the currently presented VisionKit camera pass. The scanner can
/// dismiss without a delegate callback, so the absence of an outcome is
/// intentionally handled as `.dropped` by `ScanFlowCameraRouting`.
enum ScanCameraOutcome: Equatable, Sendable {
    case pages
    case emptyDelivery
    case cancelled
    case failed
    case dropped
}

enum ScanCameraCloseAction: Equatable, Sendable {
    case openBackCamera
    case showPreview
    case showNoPages
    case dismiss
    case stayForError
}

/// Keeps camera callback decisions independent from VisionKit controllers.
/// A successful ID-card front capture is the only outcome allowed to reopen
/// the camera automatically. Errors, cancellations, and dropped callbacks
/// preserve a captured front for editing instead of racing another cover.
enum ScanFlowCameraRouting {
    static func closeAction(
        outcome: ScanCameraOutcome?,
        frontPageCount: Int,
        pageCount: Int
    ) -> ScanCameraCloseAction {
        let resolved = outcome ?? .dropped
        let hasPages = frontPageCount > 0 || pageCount > 0

        switch resolved {
        case .pages:
            if frontPageCount > 0 { return .openBackCamera }
            return pageCount > 0 ? .showPreview : .showNoPages
        case .cancelled:
            return hasPages ? .showPreview : .dismiss
        case .failed:
            return hasPages ? .showPreview : .stayForError
        case .emptyDelivery, .dropped:
            return hasPages ? .showPreview : .showNoPages
        }
    }
}
