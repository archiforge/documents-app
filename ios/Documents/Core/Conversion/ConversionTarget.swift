import Foundation

/// The formats a document can be converted toward.
enum ConversionTarget: String, CaseIterable, Hashable, Sendable {
    case pdf
    case word
    case excel
    case ppt

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .word: "Word"
        case .excel: "Excel"
        case .ppt: "PowerPoint"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .word: "docx"
        case .excel: "xlsx"
        case .ppt: "pptx"
        }
    }

    var symbolName: String {
        switch self {
        case .pdf: "doc.richtext"
        case .word: "doc.text"
        case .excel: "tablecells"
        case .ppt: "rectangle.on.rectangle"
        }
    }

    /// The local PDF converter remains available for text, Markdown, HTML, and
    /// images. Office-family inputs and Office targets use the configured
    /// conversion service through `OfficeConversionClient`.
    static let localPDFSourceKinds: [DocumentKind] = [.text, .markdown, .html, .image]

    func availability(for sourceKind: DocumentKind, sourceExtension: String? = nil) -> ConversionAvailability {
        if self == .pdf && Self.localPDFSourceKinds.contains(sourceKind) {
            return .available
        }
        if OfficeConversionMatrix.targets(for: sourceKind).contains(self) {
            if let sourceExtension,
               !OfficeConversionMatrix.supports(sourceExtension: sourceExtension, target: self) {
                return .unavailable(.unsupportedOfficeCombination)
            }
            return .available
        }
        if self == .pdf {
            return .unavailable(.sourceNeedsLocalPDFInput)
        }
        return .unavailable(.unsupportedOfficeCombination)
    }
}

enum ConversionAvailability: Equatable, Hashable, Sendable {
    case available
    case unavailable(ConversionAvailabilityReason)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    func message(sourceKind: DocumentKind, target: ConversionTarget) -> String? {
        guard case .unavailable(let reason) = self else { return nil }
        switch reason {
        case .officeTarget:
            return "The Office conversion service is not configured."
        case .sourceNeedsLocalPDFInput:
            return "\(sourceKind.label) files are not supported by the on-device PDF converter yet."
        case .unsupportedOfficeCombination:
            return "\(sourceKind.label) files cannot be converted to \(target.label)."
        }
    }
}

enum ConversionAvailabilityReason: String, Equatable, Hashable, Sendable {
    case officeTarget
    case sourceNeedsLocalPDFInput
    case unsupportedOfficeCombination
}

/// Raised whenever a conversion falls outside the currently implemented local
/// PDF source and target boundary.
struct ConversionServiceUnavailableError: LocalizedError {
    let sourceKind: DocumentKind
    let target: ConversionTarget
    let sourceExtension: String?

    init(sourceKind: DocumentKind, target: ConversionTarget, sourceExtension: String? = nil) {
        self.sourceKind = sourceKind
        self.target = target
        self.sourceExtension = sourceExtension
    }

    var errorDescription: String? {
        target.availability(for: sourceKind, sourceExtension: sourceExtension)
            .message(sourceKind: sourceKind, target: target)
            ?? (OfficeConversionMatrix.targets(for: sourceKind).contains(target)
                ? "The Office conversion service is unavailable."
                : "The requested conversion is unavailable.")
    }
}

/// Failures while an on-device conversion runs.
enum ConversionError: LocalizedError, Sendable {
    case unreadableSource
    case sourceTooLarge
    case emptySource
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "The source file could not be read."
        case .sourceTooLarge: "The source file exceeds the 50 MB conversion limit."
        case .emptySource: "The source file is empty."
        case .renderingFailed: "The conversion failed while rendering the output."
        }
    }
}
