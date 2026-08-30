import Foundation

/// The format filter chips on the Recent screen, in the Android app's order:
/// All / Scanned / DOC / XLS / PPT / PDF / OFD / TXT.
enum FormatFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case scanned
    case doc
    case xls
    case ppt
    case pdf
    case ofd
    case txt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .scanned: "Scanned"
        case .doc: "DOC"
        case .xls: "XLS"
        case .ppt: "PPT"
        case .pdf: "PDF"
        case .ofd: "OFD"
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
        case .doc:
            kind == .word
        case .xls:
            kind == .excel
        case .ppt:
            kind == .powerpoint
        case .pdf:
            kind == .pdf
        case .ofd:
            kind == .ofd
        case .txt:
            kind == .text || kind == .markdown
        }
    }

    func matches(_ record: DocumentRecord) -> Bool {
        matches(kind: record.kind, provenance: record.provenance)
    }
}
