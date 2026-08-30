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
}

/// Raised whenever a conversion needs the server pipeline that lands in
/// Phase 2b (office sources to anything, and anything to office targets).
struct ConversionServiceUnavailableError: LocalizedError {
    let sourceKind: DocumentKind
    let target: ConversionTarget

    var errorDescription: String? {
        "Converting \(sourceKind.label) to \(target.label) needs the server conversion service, which arrives in Phase 2b."
    }
}

/// Failures while an on-device conversion runs.
enum ConversionError: LocalizedError {
    case unreadableSource
    case emptySource
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource: "The source file could not be read."
        case .emptySource: "The source file is empty."
        case .renderingFailed: "The conversion failed while rendering the output."
        }
    }
}
