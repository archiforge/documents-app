import Foundation
import FoundationModels
import ImageIO
import PDFKit
import Translation
import UIKit
import Vision

protocol AITextProvider: Sendable {
    func availability() -> AIAvailability
    func promptFits(_ prompt: String, responseTokens: Int) async throws -> Bool
    func boundedPrompt(_ prompt: String) async throws -> String
    func generate(prompt: String) async throws -> String
    func generate(prompt: String, maximumResponseTokens: Int) async throws -> String
}

extension AITextProvider {
    func promptFits(_ prompt: String, responseTokens: Int) async throws -> Bool {
        _ = prompt
        _ = responseTokens
        return true
    }

    func boundedPrompt(_ prompt: String) async throws -> String { prompt }

    func generate(prompt: String, maximumResponseTokens: Int) async throws -> String {
        _ = maximumResponseTokens
        return try await generate(prompt: prompt)
    }
}

protocol AITranslationProvider: Sendable {
    func availability(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async -> AITranslationAvailability

    func translate(
        chunks: [AITextChunk],
        sourceLanguageCode: String,
        targetLanguageCode: String,
        allowDownload: Bool
    ) async throws -> [String]
}

protocol AIVisionProvider: Sendable {
    func analyze(imageData: Data) async throws -> AIVisionResult
}

struct AIVisionPage: Sendable, Equatable {
    let pageIndex: Int
    let text: String
    let regions: [AISourceRegion]
    let tableCells: [AITableCell]
    let confidence: Double?

    init(
        pageIndex: Int,
        text: String,
        regions: [AISourceRegion] = [],
        tableCells: [AITableCell] = [],
        confidence: Double? = nil
    ) {
        self.pageIndex = pageIndex
        self.text = text
        self.regions = regions
        self.tableCells = tableCells
        self.confidence = confidence
    }
}

struct AIVisionResult: Sendable, Equatable {
    let pages: [AIVisionPage]

    var textPages: [AIPageText] {
        pages.map { AIPageText(pageIndex: $0.pageIndex, text: $0.text) }
    }

    var regions: [AISourceRegion] {
        pages.flatMap(\.regions)
    }

    var tableCells: [AITableCell] {
        pages.flatMap(\.tableCells)
    }
}

struct FoundationModelTextProvider: AITextProvider {
    func availability() -> AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable(.appleIntelligenceDisabled)
        case .unavailable(.modelNotReady):
            .unavailable(.modelPreparing)
        @unknown default:
            .unavailable(.modelPreparing)
        }
    }

    func boundedPrompt(_ prompt: String) async throws -> String {
        guard try await promptFits(prompt, responseTokens: 512) else {
            throw AIError.tooLarge
        }
        return prompt
    }

    func promptFits(_ prompt: String, responseTokens: Int) async throws -> Bool {
        guard #available(iOS 26.4, *) else {
            return true
        }
        let model = SystemLanguageModel.default
        // Leave room for the response and the model instructions. A prompt
        // that does not fit is rejected so a source is never silently
        // truncated; AIChunker and the bounded reduction split it earlier.
        let budget = max(512, model.contextSize - max(128, responseTokens) - 256)
        do {
            let tokenCount = try await model.tokenCount(for: prompt)
            return tokenCount <= budget
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The model can be unavailable while its assets prepare. The
            // generation call reports that readiness state; no source text is
            // dropped here while token counting is unavailable.
            return true
        }
    }

    func generate(prompt: String) async throws -> String {
        try await generate(prompt: prompt, maximumResponseTokens: 512)
    }

    func generate(prompt: String, maximumResponseTokens: Int) async throws -> String {
        try Task.checkCancellation()
        guard case .available = availability() else {
            throw AIError.unavailable(availability().reason ?? .modelPreparing)
        }
        let session = LanguageModelSession(
            model: .default,
            instructions: "Summarize or transform only the supplied document text. Do not invent facts, values, citations, or missing content."
        )
        let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(maximumResponseTokens: max(128, maximumResponseTokens))
        )
        try Task.checkCancellation()
        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIError.emptyText }
        return content
    }
}

private final class TranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }
}

/// A view-owned Translation framework session. Supported language pairs are
/// created by SwiftUI's `translationTask`, which is the public API that owns
/// the system download/consent lifecycle. The bridge keeps that session out of
/// the Sendable source snapshot and gives the worker a cancellation hook.
final class AITranslationSessionBridge: @unchecked Sendable {
    private let box: TranslationSessionBox

    init(session: TranslationSession) {
        box = TranslationSessionBox(session: session)
    }

    func translate(chunks: [AITextChunk]) async throws -> [String] {
        try Task.checkCancellation()
        let requests = chunks.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        let responses = try await withTaskCancellationHandler(operation: {
            if !(await box.session.isReady) {
                try await box.session.prepareTranslation()
            }
            try Task.checkCancellation()
            return try await box.session.translations(from: requests)
        }, onCancel: {
            box.session.cancel()
        })
        try Task.checkCancellation()
        let byID: [String: String] = Dictionary(uniqueKeysWithValues: responses.compactMap { response in
            guard let id = response.clientIdentifier else { return nil }
            return (id, response.targetText)
        })
        return try chunks.map { chunk in
            guard let value = byID[chunk.id] else { throw AIError.translationUnavailable }
            return value
        }
    }
}

struct SystemTranslationProvider: AITranslationProvider {
    func availability(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async -> AITranslationAvailability {
        let source = Locale.Language(identifier: sourceLanguageCode)
        let target = Locale.Language(identifier: targetLanguageCode)
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            return AITranslationAvailability.installed
        case .supported:
            return AITranslationAvailability.downloadRequired
        case .unsupported:
            return AITranslationAvailability.unsupported
        @unknown default:
            return AITranslationAvailability.unsupported
        }
    }

    func translate(
        chunks: [AITextChunk],
        sourceLanguageCode: String,
        targetLanguageCode: String,
        allowDownload: Bool
    ) async throws -> [String] {
        try Task.checkCancellation()
        let source = Locale.Language(identifier: sourceLanguageCode)
        let target = Locale.Language(identifier: targetLanguageCode)
        let status = await LanguageAvailability().status(from: source, to: target)
        let session: TranslationSession
        switch status {
        case .installed:
            session = TranslationSession(installedSource: source, target: target)
        case .supported:
            // A supported but uninstalled pair must be started by SwiftUI's
            // translationTask so the system owns its consent/download UI.
            // AIFlowView passes that task's session through
            // AITranslationSessionBridge after the user approves it.
            _ = allowDownload
            throw AIError.languageDownloadRequired
        case .unsupported:
            throw AIError.translationUnavailable
        @unknown default:
            throw AIError.translationUnavailable
        }

        try Task.checkCancellation()
        let requests = chunks.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        let box = TranslationSessionBox(session: session)
        let responses = try await withTaskCancellationHandler(operation: {
            try await box.session.translations(from: requests)
        }, onCancel: {
            box.session.cancel()
        })
        try Task.checkCancellation()

        let byID: [String: String] = Dictionary(uniqueKeysWithValues: responses.compactMap { response in
            guard let id = response.clientIdentifier else { return nil }
            return (id, response.targetText)
        })
        return try chunks.map { chunk in
            guard let translated = byID[chunk.id] else {
                throw AIError.translationUnavailable
            }
            return translated
        }
    }
}

struct VisionDocumentProvider: AIVisionProvider {
    func analyze(imageData: Data) async throws -> AIVisionResult {
        try Task.checkCancellation()
        guard !imageData.isEmpty else { throw AIError.unreadableInput }

        do {
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            request.textRecognitionOptions.maximumCandidateCount = 1
            let observations = try await withTaskCancellationHandler(operation: {
                try await request.perform(on: imageData)
            }, onCancel: {})
            try Task.checkCancellation()
            let pages = observations.enumerated().map { index, observation in
                Self.page(from: observation, pageIndex: index)
            }
            return AIVisionResult(pages: pages)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIError {
            throw error
        } catch {
            // RecognizeDocumentsRequest is preferred because it supplies table
            // geometry. Text recognition remains a local fallback for older
            // Vision revisions and images that do not produce a document
            // container.
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.automaticallyDetectsLanguage = true
                let observations = try await withTaskCancellationHandler(operation: {
                    try await request.perform(on: imageData)
                }, onCancel: {})
                try Task.checkCancellation()
                let regions = observations.map { observation in
                    let box = observation.boundingRegion.boundingBox
                    return AISourceRegion(
                        pageIndex: 0,
                        x: Double(box.origin.x),
                        y: Double(box.origin.y),
                        width: Double(box.width),
                        height: Double(box.height),
                        confidence: Double(observation.confidence),
                        transcript: observation.transcript
                    )
                }
                let text = observations.map(\.transcript).joined(separator: "\n")
                return AIVisionResult(pages: [
                    AIVisionPage(
                        pageIndex: 0,
                        text: text,
                        regions: regions,
                        confidence: observations.map(\.confidence).average
                    )
                ])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AIError.visionFailed
            }
        }
    }

    private static func page(
        from observation: DocumentObservation,
        pageIndex: Int
    ) -> AIVisionPage {
        let document = observation.document
        let paragraphs = document.paragraphs
        let text = document.text.transcript.isEmpty
            ? paragraphs.map(\.transcript).joined(separator: "\n\n")
            : document.text.transcript
        let sourceTexts = paragraphs.isEmpty ? document.text.lines : paragraphs.flatMap { $0.lines }
        let regions = sourceTexts.map { line in
            let box = line.boundingRegion.boundingBox
            return AISourceRegion(
                pageIndex: pageIndex,
                x: Double(box.origin.x),
                y: Double(box.origin.y),
                width: Double(box.width),
                height: Double(box.height),
                confidence: Double(line.confidence),
                transcript: line.transcript
            )
        }
        let tableCells = document.tables.flatMap { table in
            table.rows.enumerated().flatMap { rowIndex, row in
                row.enumerated().map { columnIndex, cell in
                    let cellText = cell.content.text.transcript
                    let box = cell.content.boundingRegion.boundingBox
                    let region = AISourceRegion(
                        pageIndex: pageIndex,
                        x: Double(box.origin.x),
                        y: Double(box.origin.y),
                        width: Double(box.width),
                        height: Double(box.height),
                        confidence: Double(observation.confidence),
                        transcript: cellText
                    )
                    return AITableCell(
                        pageIndex: pageIndex,
                        row: rowIndex,
                        column: columnIndex,
                        text: cellText,
                        region: region
                    )
                }
            }
        }
        return AIVisionPage(
            pageIndex: pageIndex,
            text: text,
            regions: regions,
            tableCells: tableCells,
            confidence: Double(observation.confidence)
        )
    }
}

private extension Collection where Element == Float {
    var average: Double? {
        guard !isEmpty else { return nil }
        return Double(reduce(0, +)) / Double(count)
    }
}

struct AIExtractedContent: Sendable, Equatable {
    let pages: [AIPageText]
    let visionPages: [AIVisionPage]
    let previewPages: [AIPreviewPage]

    /// Vision reports table-cell geometry separately from line regions. Merge
    /// those actual cell regions into the evidence list so table-only pages
    /// still show the source crop and retain provenance on export. Cell
    /// regions are deduplicated by their stable IDs when a provider also
    /// reports the same geometry as a regular region.
    var regions: [AISourceRegion] {
        var seen = Set<UUID>()
        return visionPages.flatMap { page in
            page.regions + page.tableCells.compactMap(\.region)
        }.filter { region in
            seen.insert(region.id).inserted
        }
    }
    var tableCells: [AITableCell] { visionPages.flatMap(\.tableCells) }
    var previewData: Data? { previewPages.first?.data }

    init(
        pages: [AIPageText],
        visionPages: [AIVisionPage],
        previewData: Data? = nil,
        previewPages: [AIPreviewPage] = []
    ) {
        self.pages = pages
        self.visionPages = visionPages
        self.previewPages = previewPages.isEmpty
            ? (previewData.map { [AIPreviewPage(pageIndex: 0, data: $0)] } ?? [])
            : previewPages
    }
}

enum AIContentExtractor {
    static func extract(
        input: AIInput,
        vision: any AIVisionProvider,
        tool: AIToolKind
    ) async throws -> AIExtractedContent {
        try Task.checkCancellation()
        guard input.data.count <= 32 * 1024 * 1024 else { throw AIError.tooLarge }
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.extractOffMain(input: input, vision: vision, tool: tool)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private static func extractOffMain(
        input: AIInput,
        vision: any AIVisionProvider,
        tool: AIToolKind
    ) async throws -> AIExtractedContent {
        try Task.checkCancellation()
        let maximumCharacters = 1_000_000
        switch input.kind {
        case .text, .markdown:
            guard let text = String(data: input.data, encoding: .utf8) else {
                throw AIError.unreadableInput
            }
            guard text.count <= maximumCharacters else { throw AIError.tooLarge }
            return AIExtractedContent(
                pages: [AIPageText(pageIndex: 0, text: text)],
                visionPages: []
            )
        case .html:
            guard let raw = String(data: input.data, encoding: .utf8) else {
                throw AIError.unreadableInput
            }
            let text = try HTMLTextParser.plainText(raw)
            guard text.count <= maximumCharacters else { throw AIError.tooLarge }
            return AIExtractedContent(
                pages: [AIPageText(pageIndex: 0, text: text)],
                visionPages: []
            )
        case .image:
            // Vision must only receive the bounded, decoded representation.
            // Passing the original bytes when decoding fails defeats the
            // dimension limit and can turn malformed input into an unrelated
            // provider error.
            guard let boundedData = boundedVisionData(from: input.data) else {
                throw AIError.unreadableInput
            }
            let previewPages = preview(from: boundedData)
            let result = try await vision.analyze(imageData: boundedData)
            return AIExtractedContent(
                pages: result.textPages,
                visionPages: result.pages,
                previewPages: previewPages.map { [AIPreviewPage(pageIndex: 0, data: $0)] } ?? []
            )
        case .pdf:
            guard let document = PDFDocument(data: input.data) else {
                throw AIError.unreadableInput
            }
            var pages: [AIPageText] = []
            var visionPages: [AIVisionPage] = []
            var previewPages: [AIPreviewPage] = []
            var extractedCharacters = 0
            let visualTool = tool == .smartExtraction || tool == .chart || tool == .formula
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard index < 500 else { throw AIError.tooLarge }
                guard let page = document.page(at: index) else { continue }
                if index == 0 {
                    if let data = render(page: page, maximumPixelSize: 1_200) {
                        previewPages.append(AIPreviewPage(pageIndex: index, data: data))
                    }
                }
                let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    extractedCharacters += text.count
                    guard extractedCharacters <= maximumCharacters else { throw AIError.tooLarge }
                    pages.append(AIPageText(pageIndex: index, text: text))
                    if !visualTool { continue }
                }
                guard let imageData = render(page: page) else { continue }
                let result = try await vision.analyze(imageData: imageData)
                for visionPage in result.pages {
                    try Task.checkCancellation()
                    let adjusted = AIVisionPage(
                        pageIndex: index,
                        text: visionPage.text,
                        regions: visionPage.regions.map { region in
                            AISourceRegion(
                                id: region.id,
                                pageIndex: index,
                                x: region.x,
                                y: region.y,
                                width: region.width,
                                height: region.height,
                                confidence: region.confidence,
                                transcript: region.transcript
                            )
                        },
                        tableCells: visionPage.tableCells.map { cell in
                            AITableCell(
                                id: cell.id,
                                pageIndex: index,
                                row: cell.row,
                                column: cell.column,
                                text: cell.text,
                                region: cell.region.map { region in
                                    AISourceRegion(
                                        id: region.id,
                                        pageIndex: index,
                                        x: region.x,
                                        y: region.y,
                                        width: region.width,
                                        height: region.height,
                                        confidence: region.confidence,
                                        transcript: region.transcript
                                    )
                                }
                            )
                        },
                        confidence: visionPage.confidence
                    )
                    visionPages.append(adjusted)
                    let hasEvidence = !visionPage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !visionPage.regions.isEmpty
                        || !visionPage.tableCells.isEmpty
                    if visualTool,
                       previewPages.count < 64,
                       !previewPages.contains(where: { $0.pageIndex == index }),
                       hasEvidence,
                       let data = render(page: page, maximumPixelSize: 1_200) {
                        previewPages.append(AIPreviewPage(pageIndex: index, data: data))
                    }
                    if text.isEmpty {
                        extractedCharacters += visionPage.text.count
                        guard extractedCharacters <= maximumCharacters else { throw AIError.tooLarge }
                        pages.append(AIPageText(pageIndex: index, text: visionPage.text))
                    }
                }
            }
            return AIExtractedContent(
                pages: pages,
                visionPages: visionPages,
                previewPages: previewPages
            )
        case .word, .excel, .powerpoint, .archive, .ofd, .epub, .other:
            throw AIError.unsupportedInput(input.kind)
        }
    }

    private static func render(page: PDFPage, maximumPixelSize: CGFloat = 2_000) -> Data? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let longest = max(pageRect.width, pageRect.height)
        let scale = min(maximumPixelSize / longest, 1)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }
        return image.pngData()
    }

    private static func preview(from data: Data) -> Data? {
        guard let cgImage = thumbnail(from: data, maximumPixelSize: 1_200) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            .jpegData(compressionQuality: 0.8)
    }

    private static func boundedVisionData(from data: Data) -> Data? {
        guard let cgImage = thumbnail(from: data, maximumPixelSize: 2_400) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
            .jpegData(compressionQuality: 0.9)
    }

    private static func thumbnail(from data: Data, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Small inert HTML tokenizer. It skips script/style bodies, respects quotes
/// while finding tag ends, inserts line breaks for block tags, and decodes the
/// entities that commonly occur in exported document HTML. It never executes
/// or evaluates markup.
private enum HTMLTextParser {
    static func plainText(_ html: String) throws -> String {
        let characters = Array(html)
        var output = ""
        var index = 0
        var rawTag: String?
        while index < characters.count {
            if index.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            if let activeRawTag = rawTag {
                if characters[index] == "<", let end = tagEnd(in: characters, from: index) {
                    let content = String(characters[(index + 1)..<end])
                    let closingName = content
                        .trimmingCharacters(in: htmlWhitespace)
                        .dropFirst()
                        .split(whereSeparator: { isHTMLWhitespace($0) || $0 == "/" })
                        .first
                        .map(String.init)?
                        .lowercased()
                    if closingName == activeRawTag {
                        rawTag = nil
                    }
                    index = end + 1
                } else {
                    index += 1
                }
                continue
            }
            guard characters[index] == "<" else {
                output.append(characters[index])
                index += 1
                continue
            }
            guard let end = tagEnd(in: characters, from: index) else {
                output.append(characters[index])
                index += 1
                continue
            }
            let content = String(characters[(index + 1)..<end])
            let trimmed = content.trimmingCharacters(in: htmlWhitespace)
            let isClosing = trimmed.hasPrefix("/")
            let nameStart = isClosing ? trimmed.index(after: trimmed.startIndex) : trimmed.startIndex
            let name = trimmed[nameStart...]
                .split(whereSeparator: { isHTMLWhitespace($0) || $0 == "/" })
                .first.map(String.init)?.lowercased() ?? ""
            if !isClosing && (name == "script" || name == "style") {
                rawTag = name
            } else if ["br", "p", "div", "section", "article", "li", "tr", "h1", "h2", "h3", "h4"].contains(name) {
                output.append("\n")
            }
            index = end + 1
        }
        return decodeEntities(output)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func tagEnd(in characters: [Character], from start: Int) -> Int? {
        var quote: Character?
        var index = start + 1
        while index < characters.count {
            let character = characters[index]
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if character == ">", quote == nil {
                return index
            }
            index += 1
        }
        return nil
    }

    // HTML defines whitespace for tag-tokenization as space, tab, LF, FF,
    // and CR. Swift's general whitespace set is broader, so keep the parser's
    // delimiters explicit and predictable for malformed/exported markup.
    private static let htmlWhitespace = CharacterSet(charactersIn: " \t\n\r\u{000C}")

    private static func isHTMLWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { htmlWhitespace.contains($0) }
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

}

struct AIJobWorkspace: Sendable {
    let directory: URL

    init(root: URL = FileManager.default.temporaryDirectory) {
        directory = root.appendingPathComponent("Documents-AI-\(UUID().uuidString)", isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Source text and model intermediates remain bounded in memory. The
    // app-private directory is retained as a cleanup scope for future native
    // framework artifacts, but plaintext chunks are never persisted here.
    func cleanup() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
