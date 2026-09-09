import Foundation
import UIKit
import VisionKit

/// The three scanner entry points from the Tools grid.
enum ScanMode: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case document
    case idCard
    case testPaper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .document: "Scan Document"
        case .idCard: "Scan ID Card"
        case .testPaper: "Test Paper"
        }
    }

    var instructions: String {
        switch self {
        case .document:
            "Position the page inside the frame. Add as many pages as you need, then tap Save."
        case .idCard:
            "Capture the front side first, then the back side. Each side becomes one PDF page."
        case .testPaper:
            "Capture the paper, and Documents runs on-device text recognition and saves the result as a text file."
        }
    }
}

/// Camera-availability checks and generated file names for scan results.
///
/// Pure helpers only — the camera presentation itself lives in
/// `DocumentScannerView` (a UIViewControllerRepresentable), so this logic is
/// unit-testable on machines without a camera.
enum ScanningService {
    /// The document scanner needs real camera hardware; both checks are
    /// false on the simulator.
    @MainActor
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && VNDocumentCameraViewController.isSupported
    }

    /// Suggested store name for a scan result.
    @MainActor
    static func suggestedName(for mode: ScanMode, date: Date = .now) -> String {
        switch mode {
        case .document: "Scan \(DateStamp.day(for: date)).pdf"
        case .idCard: "ID Card \(DateStamp.day(for: date)).pdf"
        case .testPaper: "Test Paper \(DateStamp.day(for: date)).txt"
        }
    }

    /// Base store name (no extension) for a scan result: a non-empty rename
    /// wins; otherwise the mode's dated default. This is the shipped naming
    /// path the scanner flow uses for every save.
    @MainActor
    static func baseName(for mode: ScanMode, renamed: String?, date: Date = .now) -> String {
        if let trimmed = renamed?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return (suggestedName(for: mode, date: date) as NSString).deletingPathExtension
    }

    /// Appends `fileExtension` to `base` unless `base` already ends with it.
    @MainActor
    static func fileName(base: String, fileExtension: String) -> String {
        base.hasSuffix(".\(fileExtension)") ? base : "\(base).\(fileExtension)"
    }

    /// Store names when a scan is saved as images: a single page keeps the
    /// plain base name; multiple pages get " Page N" suffixes.
    @MainActor
    static func imageNames(pageCount: Int, date: Date = .now) -> [String] {
        let base = "Scan \(DateStamp.day(for: date))"
        guard pageCount > 1 else { return ["\(base).png"] }
        return (1...pageCount).map { "\(base) Page \($0).png" }
    }

    /// Store name when a scan is saved as one stitched long image.
    @MainActor
    static func longImageName(date: Date = .now) -> String {
        "Scan \(DateStamp.day(for: date)) Long.png"
    }
}
