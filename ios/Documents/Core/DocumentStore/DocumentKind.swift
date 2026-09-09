import Foundation

/// The coarse document category used for glyphs, grouping, and future routing
/// to specialized viewers/tools. Derived purely from the file extension.
enum DocumentKind: String, Codable, CaseIterable, Sendable {
    case pdf
    case word
    case excel
    case powerpoint
    case text
    case markdown
    case html
    case image
    case archive
    case ofd
    case epub
    case other

    init(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":
            self = .pdf
        case "ofd":
            self = .ofd
        case "epub":
            self = .epub
        case "doc", "docx", "dot", "dotx", "rtf", "pages", "odt":
            self = .word
        case "xls", "xlsx", "csv", "numbers", "ods":
            self = .excel
        case "ppt", "pptx", "pps", "ppsx", "key", "odp":
            self = .powerpoint
        case "txt", "log", "text":
            self = .text
        case "md", "markdown", "mdown":
            self = .markdown
        case "html", "htm", "xhtml":
            self = .html
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "svg":
            self = .image
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst":
            self = .archive
        default:
            self = .other
        }
    }

    /// SF Symbol used as the kind glyph across the app.
    var symbolName: String {
        switch self {
        case .pdf: "doc.richtext"
        case .word: "doc.text.fill"
        case .excel: "tablecells"
        case .powerpoint: "rectangle.on.rectangle.angled"
        case .text: "doc.plaintext"
        case .markdown: "m.square"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .archive: "doc.zipper"
        case .ofd: "doc.badge.gearshape"
        case .epub: "book"
        case .other: "doc"
        }
    }

    /// Human readable label, used in rows and metadata.
    var label: String {
        switch self {
        case .pdf: "PDF"
        case .word: "Word"
        case .excel: "Excel"
        case .powerpoint: "Presentation"
        case .text: "Plain text"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .image: "Image"
        case .archive: "Archive"
        case .ofd: "OFD"
        case .epub: "EPUB"
        case .other: "Document"
        }
    }
}
