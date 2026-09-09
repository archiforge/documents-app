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
        case ai(AIToolKind)
    }

    let title: String
    let symbol: String
    let kind: Kind

    var id: String { title }

    var stubPhase: Int? {
        if case .stub(let phase) = kind { return phase }
        return nil
    }

    /// The scanner and local file tools work with the current app services.
    /// Office conversion and AI tiles stay visible but report their current
    /// product availability instead of pretending a setup screen exists.
    var capability: ToolCapability {
        switch kind {
        case .stub:
            switch title {
            case "Document Summary":
                return .unavailable(.summaryUnavailable)
            case "Document Translation":
                return .unavailable(.translationUnavailable)
            default:
                return .unavailable(.extractionUnavailable)
            }
        case .ai(let tool):
            return .ai(tool)
        default:
            return .available
        }
    }

    var isScanHero: Bool {
        if case .scan(let mode) = kind {
            return mode == .document
        }
        return false
    }

    var isQuickAction: Bool {
        switch kind {
        case .newDocument, .pdfTools:
            return true
        default:
            return false
        }
    }

    var isFileConversion: Bool {
        switch kind {
        case .formatConvert, .convert:
            return true
        default:
            return false
        }
    }

    var isAITool: Bool {
        switch kind {
        case .stub, .ai:
            return true
        default:
            return false
        }
    }

    static var scanHero: ToolItem {
        all.first(where: \.isScanHero) ?? ToolItem(
            title: "Scan Document",
            symbol: "doc.viewfinder",
            kind: .scan(.document)
        )
    }

    static var fileConversion: [ToolItem] {
        all.filter(\.isFileConversion)
    }

    static var quickTools: [ToolItem] {
        all.filter(\.isQuickAction)
    }

    static var aiTools: [ToolItem] {
        all.filter(\.isAITool)
    }

    static var supportingTools: [ToolItem] {
        all.filter {
            !$0.isScanHero && !$0.isFileConversion && !$0.isAITool && !$0.isQuickAction
        }
    }

    static let all: [ToolItem] = [
        ToolItem(title: "New Document", symbol: "doc.badge.plus", kind: .newDocument),
        ToolItem(title: "Scan Document", symbol: "doc.viewfinder", kind: .scan(.document)),
        ToolItem(title: "Scan ID Card", symbol: "person.text.rectangle", kind: .scan(.idCard)),
        ToolItem(title: "Test Paper", symbol: "checklist", kind: .scan(.testPaper)),
        ToolItem(title: "PDF Tools", symbol: "wrench.and.screwdriver", kind: .pdfTools),
        ToolItem(title: "Extract Chart", symbol: AIToolKind.chart.symbol, kind: .ai(.chart)),
        ToolItem(title: "Extract Formula", symbol: AIToolKind.formula.symbol, kind: .ai(.formula)),
        ToolItem(title: "Smart Extraction", symbol: AIToolKind.smartExtraction.symbol, kind: .ai(.smartExtraction)),
        ToolItem(title: "Format Convert", symbol: "arrow.left.arrow.right", kind: .formatConvert),
        ToolItem(title: "To PDF", symbol: "doc.richtext", kind: .convert(.pdf)),
        ToolItem(title: "To Word", symbol: "doc.text", kind: .convert(.word)),
        ToolItem(title: "To Excel", symbol: "tablecells", kind: .convert(.excel)),
        ToolItem(title: "To PPT", symbol: "rectangle.on.rectangle", kind: .convert(.ppt)),
        ToolItem(title: "Compress", symbol: "doc.zipper", kind: .compress),
        ToolItem(title: "Extract", symbol: "shippingbox", kind: .extract),
        ToolItem(title: "Document Summary", symbol: AIToolKind.summary.symbol, kind: .ai(.summary)),
        ToolItem(title: "Document Translation", symbol: AIToolKind.translation.symbol, kind: .ai(.translation)),
    ]
}
