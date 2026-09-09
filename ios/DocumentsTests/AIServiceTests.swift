import Foundation
import UIKit
import XCTest
@testable import Documents

final class AIServiceTests: XCTestCase {
    func testChunkingKeepsPagesAndBoundsOversizedWords() throws {
        let pages = [
            AIPageText(pageIndex: 2, text: "alpha\n\nbeta"),
            AIPageText(pageIndex: 3, text: String(repeating: "x", count: 37)),
        ]
        let chunks = try AIChunker.chunks(from: pages, maximumCharacters: 12, maximumChunks: 20)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 12 })
        XCTAssertTrue(chunks.flatMap(\.pageIndexes).contains(2))
        XCTAssertTrue(chunks.flatMap(\.pageIndexes).contains(3))
    }

    func testSummaryUsesBoundedHierarchicalReductionAndCleansWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-service-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = RecordingTextProvider()
        let service = AIService(
            textProvider: provider,
            translationProvider: FakeTranslationProvider(),
            visionProvider: EmptyVisionProvider(),
            workspaceRoot: root
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Minutes.txt",
            kind: .text,
            data: Data(String(repeating: "A paragraph with facts.\n\n", count: 2_000).utf8)
        )

        let artifact = try await service.run(tool: .summary, input: input)

        XCTAssertEqual(artifact.kind, .summary)
        XCTAssertFalse(artifact.body.isEmpty)
        XCTAssertGreaterThan(provider.prompts.count, 1)
        XCTAssertTrue(provider.prompts.allSatisfy { $0.count <= 12_000 })
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)).isEmpty)
    }

    func testSummaryRechunksWhenProviderReportsARealTokenBudget() async throws {
        let provider = BudgetedTextProvider(maximumPromptCharacters: 520)
        let service = AIService(
            textProvider: provider,
            translationProvider: FakeTranslationProvider(),
            visionProvider: EmptyVisionProvider()
        )
        let source = String(repeating: "A faithful source sentence with dates and quantities. ", count: 240)
        let input = AIInput(id: UUID(), displayName: "Budget.txt", kind: .text, data: Data(source.utf8))

        let artifact = try await service.run(tool: .summary, input: input)

        XCTAssertFalse(artifact.body.isEmpty)
        XCTAssertGreaterThan(provider.prompts.count, 1)
        XCTAssertTrue(provider.prompts.allSatisfy { $0.count <= 520 })
    }

    func testHTMLExtractionSkipsRawBodiesAndRespectsQuotedTagCharacters() async throws {
        let provider = RecordingTextProvider()
        let service = AIService(
            textProvider: provider,
            translationProvider: FakeTranslationProvider(),
            visionProvider: EmptyVisionProvider()
        )
        let html = """
        <div>Hello <span title='2 > 1'>world</span></div>
        <script
         type='text/javascript'>secretShouldNotReachTheModel()</script\r>
        <style\u{000C}>.private { color: red; }</style\t>
        <p>Again &amp; done</p>
        """
        let input = AIInput(id: UUID(), displayName: "Page.html", kind: .html, data: Data(html.utf8))

        _ = try await service.run(tool: .summary, input: input)

        let prompts = provider.prompts.joined(separator: "\n")
        XCTAssertTrue(prompts.contains("Hello world"))
        XCTAssertTrue(prompts.contains("Again & done"))
        XCTAssertFalse(prompts.contains("secretShouldNotReachTheModel"))
        XCTAssertFalse(prompts.contains("private"))
    }

    func testImageExtractionRejectsUndecodableInputBeforeVision() async {
        let service = AIService(
            textProvider: RecordingTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: FailingIfCalledVisionProvider()
        )
        let input = AIInput(id: UUID(), displayName: "Broken.png", kind: .image, data: Data([1, 2, 3]))

        do {
            _ = try await service.run(tool: .chart, input: input)
            XCTFail("Undecodable image bytes must be rejected before Vision runs")
        } catch let error as AIError {
            XCTAssertEqual(error, .unreadableInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChartAndFormulaArtifactsOnlyExposeObservedText() async throws {
        let region = AISourceRegion(
            pageIndex: 0,
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
            confidence: 0.91,
            transcript: "Revenue"
        )
        let cells = [
            AITableCell(pageIndex: 0, row: 0, column: 0, text: "Quarter", region: region),
            AITableCell(pageIndex: 0, row: 0, column: 1, text: "Revenue", region: region),
        ]
        let vision = FakeVisionProvider(result: AIVisionResult(pages: [
            AIVisionPage(
                pageIndex: 0,
                text: "Quarter\nRevenue",
                regions: [region],
                tableCells: cells,
                confidence: 0.91
            ),
        ]))
        let service = AIService(
            textProvider: RecordingTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: vision
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Chart.png",
            kind: .image,
            data: try XCTUnwrap(TestPDF.solidImage(size: CGSize(width: 320, height: 200), color: .white).pngData())
        )

        let chart = try await service.run(tool: .chart, input: input)
        let formula = try await service.run(tool: .formula, input: input)

        XCTAssertEqual(chart.body, "Quarter\tRevenue")
        XCTAssertFalse(chart.body.contains("0.0"), "No plotted values may be inferred")
        XCTAssertEqual(formula.body, "Revenue")
        XCTAssertEqual(chart.tableCells, cells)
        XCTAssertTrue(chart.reviewNotice.contains("No plotted values"))
    }

    func testFormulaCandidatePreservesOrderedOCRRegions() async throws {
        let first = AISourceRegion(
            pageIndex: 0,
            x: 0.1,
            y: 0.8,
            width: 0.3,
            height: 0.1,
            transcript: "x = 1"
        )
        let second = AISourceRegion(
            pageIndex: 0,
            x: 0.1,
            y: 0.6,
            width: 0.3,
            height: 0.1,
            transcript: "y = 2"
        )
        let vision = FakeVisionProvider(result: AIVisionResult(pages: [
            AIVisionPage(
                pageIndex: 0,
                text: "x = 1\ny = 2",
                regions: [first, second]
            ),
        ]))
        let service = AIService(
            textProvider: RecordingTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: vision
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Formula.png",
            kind: .image,
            data: try XCTUnwrap(TestPDF.solidImage(size: CGSize(width: 320, height: 200), color: .white).pngData())
        )

        let artifact = try await service.run(tool: .formula, input: input)

        XCTAssertEqual(artifact.body, "x = 1\ny = 2")
    }

    func testTableOnlyArtifactRetainsCellGeometryAsSourceEvidence() async throws {
        let cellRegion = AISourceRegion(
            pageIndex: 0,
            x: 0.2,
            y: 0.3,
            width: 0.4,
            height: 0.2,
            confidence: 0.88,
            transcript: "Observed cell"
        )
        let cell = AITableCell(
            pageIndex: 0,
            row: 0,
            column: 0,
            text: "Observed cell",
            region: cellRegion
        )
        let service = AIService(
            textProvider: RecordingTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: FakeVisionProvider(result: AIVisionResult(pages: [
                AIVisionPage(pageIndex: 0, text: "", tableCells: [cell]),
            ]))
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Table.png",
            kind: .image,
            data: try XCTUnwrap(TestPDF.solidImage(size: CGSize(width: 320, height: 200), color: .white).pngData())
        )

        let artifact = try await service.run(tool: .chart, input: input)
        let payload = AIArtifactExporter.payload(for: artifact)
        let exported = String(decoding: payload.data, as: UTF8.self)

        XCTAssertEqual(artifact.sourceRegions, [cellRegion])
        XCTAssertTrue(exported.contains("Source crop bounds: p1:20%,30%,40%,20%"))
    }

    func testChartReviewEvidenceUsesTheTablePageInsteadOfFirstPreviewPage() {
        let firstPage = AIPreviewPage(pageIndex: 0, data: Data([0]))
        let chartPage = AIPreviewPage(pageIndex: 4, data: Data([4]))
        let cell = AITableCell(pageIndex: 4, row: 0, column: 0, text: "Observed")
        let artifact = AIReviewArtifact(
            kind: .chart,
            sourceID: UUID(),
            sourceName: "Multi-page.pdf",
            title: "Chart Candidate",
            body: "Observed",
            tableCells: [cell],
            previewPages: [firstPage, chartPage],
            reviewNotice: "Review"
        )

        XCTAssertEqual(artifact.preferredEvidencePageIndex, 4)
        XCTAssertEqual(artifact.previewPages.first { $0.pageIndex == artifact.preferredEvidencePageIndex }?.data, Data([4]))
    }

    func testVisualPDFRetainsTheDetectedLaterPageForReviewEvidence() async throws {
        let laterRegion = AISourceRegion(
            pageIndex: 0,
            x: 0.2,
            y: 0.3,
            width: 0.4,
            height: 0.2,
            transcript: "Observed chart"
        )
        let laterCell = AITableCell(
            pageIndex: 0,
            row: 0,
            column: 0,
            text: "Observed chart",
            region: laterRegion
        )
        let vision = SequencedVisionProvider(results: [
            AIVisionResult(pages: [AIVisionPage(pageIndex: 0, text: "")]),
            AIVisionResult(pages: [AIVisionPage(
                pageIndex: 0,
                text: "Observed chart",
                regions: [laterRegion],
                tableCells: [laterCell]
            )]),
        ])
        let service = AIService(
            textProvider: RecordingTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: vision
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Multi-page.pdf",
            kind: .pdf,
            data: TestPDF.make(pageCount: 2)
        )

        let artifact = try await service.run(tool: .chart, input: input)

        XCTAssertEqual(artifact.tableCells.first?.pageIndex, 1)
        XCTAssertTrue(artifact.previewPages.contains { $0.pageIndex == 1 })
        XCTAssertEqual(artifact.preferredEvidencePageIndex, 1)
    }

    func testCancellationStopsBeforeArtifactIsProduced() async {
        let service = AIService(
            textProvider: SlowTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: EmptyVisionProvider()
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Slow.txt",
            kind: .text,
            data: Data("A long source".utf8)
        )
        let task = Task {
            try await service.run(tool: .summary, input: input)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled work must not return an artifact")
        } catch is CancellationError {
            // Expected.
        } catch AIError.cancelled {
            // A provider may normalize cancellation to the domain error.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testTranslationPreservesChunkOrderAndUsesFakeProvider() async throws {
        let service = AIService(
            textProvider: RecordingTextProvider(),
            translationProvider: FakeTranslationProvider(),
            visionProvider: EmptyVisionProvider()
        )
        let input = AIInput(
            id: UUID(),
            displayName: "Notes.md",
            kind: .markdown,
            data: Data("First page\n\nSecond page".utf8)
        )

        let artifact = try await service.run(
            tool: .translation,
            input: input,
            translationOptions: AITranslationOptions(sourceLanguageCode: "en", targetLanguageCode: "fr")
        )

        XCTAssertTrue(artifact.body.contains("[Page 1]"))
        XCTAssertTrue(artifact.body.contains("FIRST PAGE"))
        XCTAssertTrue(artifact.body.contains("SECOND PAGE"))
        XCTAssertTrue(artifact.body.range(of: "FIRST PAGE")!.lowerBound < artifact.body.range(of: "SECOND PAGE")!.lowerBound)
    }
}

private struct RecordingTextProvider: AITextProvider {
    let recorder: PromptRecorder

    init(recorder: PromptRecorder = PromptRecorder()) {
        self.recorder = recorder
    }

    var prompts: [String] {
        recorder.values
    }

    func availability() -> AIAvailability { .available }
    func boundedPrompt(_ prompt: String) async throws -> String { prompt }
    func generate(prompt: String) async throws -> String {
        recorder.append(prompt)
        return "Local draft \(prompt.hashValue)"
    }
}

private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private struct SlowTextProvider: AITextProvider {
    func availability() -> AIAvailability { .available }
    func generate(prompt: String) async throws -> String {
        try await Task.sleep(nanoseconds: 100_000_000)
        try Task.checkCancellation()
        return prompt
    }
}

private struct BudgetedTextProvider: AITextProvider {
    let maximumPromptCharacters: Int
    let recorder = PromptRecorder()

    var prompts: [String] { recorder.values }
    func availability() -> AIAvailability { .available }

    func promptFits(_ prompt: String, responseTokens: Int) async throws -> Bool {
        _ = responseTokens
        return prompt.count <= maximumPromptCharacters
    }

    func generate(prompt: String) async throws -> String {
        recorder.append(prompt)
        return "Bounded local draft"
    }
}

private struct FakeTranslationProvider: AITranslationProvider {
    func availability(sourceLanguageCode: String, targetLanguageCode: String) async -> AITranslationAvailability {
        .installed
    }

    func translate(
        chunks: [AITextChunk],
        sourceLanguageCode: String,
        targetLanguageCode: String,
        allowDownload: Bool
    ) async throws -> [String] {
        try Task.checkCancellation()
        return chunks.map { $0.text.uppercased() }
    }
}

private struct EmptyVisionProvider: AIVisionProvider {
    func analyze(imageData: Data) async throws -> AIVisionResult {
        AIVisionResult(pages: [])
    }
}

private struct FakeVisionProvider: AIVisionProvider {
    let result: AIVisionResult

    func analyze(imageData: Data) async throws -> AIVisionResult { result }
}

private struct FailingIfCalledVisionProvider: AIVisionProvider {
    func analyze(imageData: Data) async throws -> AIVisionResult {
        _ = imageData
        throw AIError.visionFailed
    }
}

private actor SequencedVisionProvider: AIVisionProvider {
    private let results: [AIVisionResult]
    private var nextIndex = 0

    init(results: [AIVisionResult]) {
        self.results = results
    }

    func analyze(imageData: Data) async throws -> AIVisionResult {
        _ = imageData
        let result = results[min(nextIndex, results.count - 1)]
        nextIndex += 1
        return result
    }
}
