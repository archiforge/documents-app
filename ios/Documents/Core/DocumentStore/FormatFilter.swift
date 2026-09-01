import Foundation

/// The format filter chips on the Recent screen. Custom row (product
/// decision 2026-09-01, divergence ledger #8): All / Scanned / PDF / DOC /
/// EPUB / XLS / TXT — the APK's PPT and OFD chips were dropped and EPUB
/// added; those kinds remain listed under All.
enum FormatFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case scanned
    case pdf
    case doc
    case epub
    case xls
    case txt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .scanned: "Scanned"
        case .pdf: "PDF"
        case .doc: "DOC"
        case .epub: "EPUB"
        case .xls: "XLS"
        case .txt: "TXT"
        }
    }

    /// Whether a document belongs under this chip. "Scanned" matches on
    /// provenance, every other chip on the document kind.
    func matches(kind: DocumentKind, provenance: Provenance) -> Bool {
        switch self {
        case .all:
            true
        case .scanned:
            provenance == .scanned
        case .pdf:
            kind == .pdf
        case .doc:
            kind == .word
        case .epub:
            kind == .epub
        case .xls:
            kind == .excel
        case .txt:
            kind == .text || kind == .markdown
        }
    }

    func matches(_ record: DocumentRecord) -> Bool {
        matches(kind: record.kind, provenance: record.provenance)
    }
}
