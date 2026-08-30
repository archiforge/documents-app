import Foundation

/// One entry in the tools grid. Names mirror the functional spec.
struct ToolItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case newDocument
        case scan(ScanMode)
        case pdfTools
        case formatConvert
        case convert(ConversionTarget)
        case compress
        case extract
        case stub(phase: Int)
    }

    let title: String
    let symbol: String
    let kind: Kind

    var id: String { title }

    var stubPhase: Int? {
        if case .stub(let phase) = kind { return phase }
        return nil
    }

    /// Phase mapping follows the parent plan (§5): scanner + conversion
    /// belong to Phase 2, extraction + AI features to Phase 3.
    static let all: [ToolItem] = [
        ToolItem(title: "New Document", symbol: "doc.badge.plus", kind: .newDocument),
        ToolItem(title: "Scan Document", symbol: "doc.viewfinder", kind: .scan(.document)),
        ToolItem(title: "Scan ID Card", symbol: "person.text.rectangle", kind: .scan(.idCard)),
        ToolItem(title: "Test Paper", symbol: "checklist", kind: .scan(.testPaper)),
        ToolItem(title: "PDF Tools", symbol: "wrench.and.screwdriver", kind: .pdfTools),
        ToolItem(title: "Extract Chart", symbol: "chart.xyaxis.line", kind: .stub(phase: 3)),
        ToolItem(title: "Extract Formula", symbol: "function", kind: .stub(phase: 3)),
        ToolItem(title: "Smart Extraction", symbol: "wand.and.stars", kind: .stub(phase: 3)),
        ToolItem(title: "Format Convert", symbol: "arrow.left.arrow.right", kind: .formatConvert),
        ToolItem(title: "To PDF", symbol: "doc.richtext", kind: .convert(.pdf)),
        ToolItem(title: "To Word", symbol: "doc.text", kind: .convert(.word)),
        ToolItem(title: "To Excel", symbol: "tablecells", kind: .convert(.excel)),
        ToolItem(title: "To PPT", symbol: "rectangle.on.rectangle", kind: .convert(.ppt)),
        ToolItem(title: "Compress", symbol: "doc.zipper", kind: .compress),
        ToolItem(title: "Extract", symbol: "shippingbox.open", kind: .extract),
        ToolItem(title: "Document Summary", symbol: "text.alignleft", kind: .stub(phase: 3)),
        ToolItem(title: "Document Translation", symbol: "globe", kind: .stub(phase: 3)),
    ]
}
