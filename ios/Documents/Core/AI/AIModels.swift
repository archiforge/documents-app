import Foundation

/// The local AI tools that are exposed by the Tools board. The enum is kept in
/// Core/AI so routing and tests do not depend on a SwiftUI view type.
enum AIToolKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case summary
    case translation
    case smartExtraction
    case chart
    case formula

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: "Document Summary"
        case .translation: "Document Translation"
        case .smartExtraction: "Smart Extraction"
        case .chart: "Extract Chart"
        case .formula: "Extract Formula"
        }
    }

    var symbol: String {
        switch self {
        case .summary: "text.alignleft"
        case .translation: "globe"
        case .smartExtraction: "wand.and.stars"
        case .chart: "chart.xyaxis.line"
        case .formula: "function"
        }
    }

    var subtitle: String {
        switch self {
        case .summary:
            "Create a concise on-device summary"
        case .translation:
            "Translate a copy with a selected language pair"
        case .smartExtraction:
            "Review fields found in a document"
        case .chart:
            "Review an OCR table or chart candidate"
        case .formula:
            "Review an OCR formula candidate"
        }
    }

    var outputExtension: String {
        switch self {
        case .summary: "md"
        case .translation: "txt"
        case .smartExtraction: "json"
        case .chart: "tsv"
        case .formula: "txt"
        }
    }

    var requiresLanguageModel: Bool {
        self == .summary
    }
}

enum AIUnavailableReason: String, CaseIterable, Equatable, Hashable, Sendable {
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelPreparing
    case unsupportedLanguagePair
    case languageDownloadRequired
    case unsupportedInput
    case unreadableInput
    case noTextRecognized
    case visionFailure
    case cancelled

    var title: String {
        switch self {
        case .deviceNotEligible:
            "On-device model unavailable"
        case .appleIntelligenceDisabled:
            "On-device model is turned off"
        case .modelPreparing:
            "On-device model is preparing"
        case .unsupportedLanguagePair:
            "Language pair unavailable"
        case .languageDownloadRequired:
            "Language download required"
        case .unsupportedInput:
            "Input format unavailable"
        case .unreadableInput:
            "Document could not be read"
        case .noTextRecognized:
            "No text found"
        case .visionFailure:
            "Local analysis failed"
        case .cancelled:
            "Cancelled"
        }
    }

    var message: String {
        switch self {
        case .deviceNotEligible:
            "This device does not support the on-device language model."
        case .appleIntelligenceDisabled:
            "Turn on Apple Intelligence in Settings to use summaries."
        case .modelPreparing:
            "The on-device language model is preparing. Try again shortly."
        case .unsupportedLanguagePair:
            "That language pair is not available on this device."
        case .languageDownloadRequired:
            "The selected language needs a one-time system download."
        case .unsupportedInput:
            "This file type does not have a local text or image reader yet."
        case .unreadableInput:
            "The selected document is unavailable or could not be opened."
        case .noTextRecognized:
            "No readable text was found in the selected document."
        case .visionFailure:
            "The local document analysis could not finish. Try a clearer page."
        case .cancelled:
            "The local analysis was cancelled."
        }
    }
}

enum AIAvailability: Equatable, Hashable, Sendable {
    case available
    case unavailable(AIUnavailableReason)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: AIUnavailableReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

/// A bounded, Sendable snapshot of a source record. The model record and its
/// store are intentionally absent so this value can cross into worker tasks.
struct AIInput: Sendable, Equatable {
    let id: UUID
    let displayName: String
    let kind: DocumentKind
    let data: Data

    init(id: UUID, displayName: String, kind: DocumentKind, data: Data) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.data = data
    }
}

struct AIPageText: Sendable, Equatable, Hashable {
    let pageIndex: Int
    let text: String

    init(pageIndex: Int, text: String) {
        self.pageIndex = pageIndex
        self.text = text
    }
}

struct AITextChunk: Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let pageIndexes: [Int]
    let text: String

    init(id: String, pageIndexes: [Int], text: String) {
        self.id = id
        self.pageIndexes = pageIndexes
        self.text = text
    }
}

/// A normalized source region in Vision's lower-left coordinate convention.
/// Keeping scalar values here avoids sending Core Graphics objects through
/// detached work and makes provenance serializable in generated artifacts.
struct AISourceRegion: Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    let pageIndex: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double?
    let transcript: String

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double? = nil,
        transcript: String
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
        self.transcript = transcript
    }
}

struct AITableCell: Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    let pageIndex: Int
    let row: Int
    let column: Int
    let text: String
    let region: AISourceRegion?

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        row: Int,
        column: Int,
        text: String,
        region: AISourceRegion? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.row = row
        self.column = column
        self.text = text
        self.region = region
    }
}

struct AIFieldCandidate: Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    var label: String
    var value: String
    let sourceRegion: AISourceRegion?
    let confidence: Double?

    init(
        id: UUID = UUID(),
        label: String,
        value: String,
        sourceRegion: AISourceRegion? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.sourceRegion = sourceRegion
        self.confidence = confidence
    }
}

/// A small, orientation-normalized source page retained for review. Keeping
/// page IDs beside the bytes prevents a later-page OCR candidate from being
/// shown over an unrelated first-page image.
struct AIPreviewPage: Sendable, Equatable, Hashable, Identifiable {
    let pageIndex: Int
    let data: Data

    var id: Int { pageIndex }
}

struct AIReviewArtifact: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: AIToolKind
    let sourceID: UUID
    let sourceName: String
    var title: String
    var body: String
    var fields: [AIFieldCandidate]
    let sourceRegions: [AISourceRegion]
    let tableCells: [AITableCell]
    let previewPages: [AIPreviewPage]
    let confidence: Double?
    let reviewNotice: String

    var previewData: Data? { previewPages.first?.data }

    /// The page whose retained render best matches the editable candidate.
    /// Chart tables carry stronger page evidence than a generic OCR region.
    var preferredEvidencePageIndex: Int? {
        switch kind {
        case .chart:
            tableCells.first?.pageIndex ?? sourceRegions.first?.pageIndex
        case .formula, .smartExtraction, .summary, .translation:
            sourceRegions.first?.pageIndex
        }
    }

    init(
        id: UUID = UUID(),
        kind: AIToolKind,
        sourceID: UUID,
        sourceName: String,
        title: String,
        body: String,
        fields: [AIFieldCandidate] = [],
        sourceRegions: [AISourceRegion] = [],
        tableCells: [AITableCell] = [],
        previewData: Data? = nil,
        previewPages: [AIPreviewPage] = [],
        confidence: Double? = nil,
        reviewNotice: String
    ) {
        self.id = id
        self.kind = kind
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.title = title
        self.body = body
        self.fields = fields
        self.sourceRegions = sourceRegions
        self.tableCells = tableCells
        self.previewPages = previewPages.isEmpty
            ? (previewData.map { [AIPreviewPage(pageIndex: 0, data: $0)] } ?? [])
            : previewPages
        self.confidence = confidence
        self.reviewNotice = reviewNotice
    }
}

struct AITranslationOptions: Sendable, Equatable, Hashable {
    let sourceLanguageCode: String
    let targetLanguageCode: String

    init(sourceLanguageCode: String = "en", targetLanguageCode: String = "es") {
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }
}

enum AITranslationAvailability: Sendable, Equatable, Hashable {
    case installed
    case downloadRequired
    case unsupported
}

enum AIError: LocalizedError, Equatable, Sendable {
    case unavailable(AIUnavailableReason)
    case unsupportedInput(DocumentKind)
    case emptyText
    case unreadableInput
    case tooLarge
    case translationUnavailable
    case languageDownloadRequired
    case visionFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason.message
        case .unsupportedInput: AIUnavailableReason.unsupportedInput.message
        case .emptyText: AIUnavailableReason.noTextRecognized.message
        case .unreadableInput: AIUnavailableReason.unreadableInput.message
        case .tooLarge: "This document is too large for bounded on-device processing."
        case .translationUnavailable: AIUnavailableReason.unsupportedLanguagePair.message
        case .languageDownloadRequired: AIUnavailableReason.languageDownloadRequired.message
        case .visionFailed: AIUnavailableReason.visionFailure.message
        case .cancelled: AIUnavailableReason.cancelled.message
        }
    }
}

enum AIInputSupport {
    static func supports(_ tool: AIToolKind, documentKind: DocumentKind) -> Bool {
        switch documentKind {
        case .text, .markdown, .html, .pdf, .image:
            true
        case .word, .excel, .powerpoint, .archive, .ofd, .epub, .other:
            false
        }
    }
}

enum AIArtifactExporter {
    struct Payload: Sendable, Equatable {
        let name: String
        let data: Data
    }

    static func payload(for artifact: AIReviewArtifact) -> Payload {
        let base = sanitizedBaseName(artifact.title.isEmpty ? artifact.sourceName : artifact.title)
        let filename = "\(base).\(artifact.kind.outputExtension)"
        let evidencePages = Set(
            artifact.sourceRegions.map { $0.pageIndex + 1 }
                + artifact.tableCells.map { $0.pageIndex + 1 }
        ).sorted().map(String.init).joined(separator: ", ")
        let cropProvenance = artifact.sourceRegions.prefix(8).map { region in
            "p\(region.pageIndex + 1):\(Int(region.x * 100))%,\(Int(region.y * 100))%,\(Int(region.width * 100))%,\(Int(region.height * 100))%"
        }.joined(separator: "; ")
        let provenance = [
            "Source document: \(artifact.sourceName)",
            "Source record: \(artifact.sourceID.uuidString)",
            evidencePages.isEmpty ? "Source pages: unavailable" : "Source pages: \(evidencePages)",
            "Source regions: \(artifact.sourceRegions.count)",
            cropProvenance.isEmpty ? "Source crop: unavailable" : "Source crop bounds: \(cropProvenance)",
            artifact.confidence.map { "Observed confidence: \(Int($0 * 100))%" } ?? "Observed confidence: unavailable",
            "Reviewed by user in Documents",
        ].joined(separator: "\n")
        let data: Data
        switch artifact.kind {
        case .smartExtraction:
            let values: [[String: String]] = artifact.fields.map { field in
                ["label": field.label, "value": field.value]
            }
            let object: [String: Any] = [
                "provenance": provenance,
                "fields": values,
            ]
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
                ?? Data(provenance.utf8)
        case .summary:
            data = Data("<!-- \(provenance.replacingOccurrences(of: "\n", with: " · ")) -->\n\n\(artifact.body)".utf8)
        case .chart, .formula, .translation:
            data = Data("# \(provenance.replacingOccurrences(of: "\n", with: "\n# "))\n\n\(artifact.body)".utf8)
        }
        return Payload(name: filename, data: data)
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        let withoutExtension = (value as NSString).deletingPathExtension
        let cleaned = withoutExtension
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "AI Result" : cleaned
    }

}
