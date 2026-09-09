import Foundation

private struct AIChartRowKey: Hashable {
    let page: Int
    let row: Int
}

struct AIService: Sendable {
    let textProvider: any AITextProvider
    let translationProvider: any AITranslationProvider
    let visionProvider: any AIVisionProvider
    let workspaceRoot: URL

    init(
        textProvider: any AITextProvider = FoundationModelTextProvider(),
        translationProvider: any AITranslationProvider = SystemTranslationProvider(),
        visionProvider: any AIVisionProvider = VisionDocumentProvider(),
        workspaceRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.textProvider = textProvider
        self.translationProvider = translationProvider
        self.visionProvider = visionProvider
        self.workspaceRoot = workspaceRoot
    }

    static var live: AIService { AIService() }

    func availability(for tool: AIToolKind) -> AIAvailability {
        switch tool {
        case .summary:
            textProvider.availability()
        case .translation, .smartExtraction, .chart, .formula:
            .available
        }
    }

    func translationAvailability(
        sourceLanguageCode: String,
        targetLanguageCode: String
    ) async -> AITranslationAvailability {
        await translationProvider.availability(
            sourceLanguageCode: sourceLanguageCode,
            targetLanguageCode: targetLanguageCode
        )
    }

    func run(
        tool: AIToolKind,
        input: AIInput,
        translationOptions: AITranslationOptions = AITranslationOptions(),
        allowLanguageDownload: Bool = false,
        translationSession: AITranslationSessionBridge? = nil
    ) async throws -> AIReviewArtifact {
        try Task.checkCancellation()
        guard AIInputSupport.supports(tool, documentKind: input.kind) else {
            throw AIError.unsupportedInput(input.kind)
        }

        let workspace = AIJobWorkspace(root: workspaceRoot)
        try workspace.prepare()
        defer { try? workspace.cleanup() }

        let extracted = try await AIContentExtractor.extract(
            input: input,
            vision: visionProvider,
            tool: tool
        )
        try Task.checkCancellation()

        switch tool {
        case .summary:
            return try await summarize(
                input: input,
                extracted: extracted
            )
        case .translation:
            return try await translate(
                input: input,
                extracted: extracted,
                options: translationOptions,
                allowLanguageDownload: allowLanguageDownload,
                translationSession: translationSession
            )
        case .smartExtraction:
            return try makeSmartExtraction(input: input, extracted: extracted)
        case .chart:
            return try makeChartCandidate(input: input, extracted: extracted)
        case .formula:
            return try makeFormulaCandidate(input: input, extracted: extracted)
        }
    }

    private func summarize(
        input: AIInput,
        extracted: AIExtractedContent
    ) async throws -> AIReviewArtifact {
        guard case .available = textProvider.availability() else {
            throw AIError.unavailable(textProvider.availability().reason ?? .modelPreparing)
        }
        let chunks = try await makeSummaryChunks(from: extracted.pages)
        guard !chunks.isEmpty else { throw AIError.emptyText }
        var partialSummaries: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let prompt = summaryPrompt(for: chunk)
            let summary = try await generate(prompt: prompt)
            try Task.checkCancellation()
            partialSummaries.append(summary)
        }

        let body: String
        if partialSummaries.count == 1 {
            body = partialSummaries[0]
        } else {
            var level = partialSummaries
            while level.count > 1 {
                var next: [String] = []
                for groupStart in stride(from: 0, to: level.count, by: 3) {
                    try Task.checkCancellation()
                    let group = Array(level[groupStart..<min(groupStart + 3, level.count)])
                    let joined = group.enumerated()
                        .map { "Chunk \($0.offset + 1):\n\($0.element)" }
                        .joined(separator: "\n\n")
                    let prompt = """
                    Combine these faithful chunk summaries into one concise
                    summary. Remove repetition and preserve every qualified
                    statement. Do not infer facts absent from the summaries.

                    \(joined)
                    """
                    next.append(try await generate(prompt: prompt))
                }
                level = next
            }
            body = level[0]
            try Task.checkCancellation()
        }
        return AIReviewArtifact(
            kind: .summary,
            sourceID: input.id,
            sourceName: input.displayName,
            title: "Summary — \(input.displayName)",
            body: body,
            sourceRegions: extracted.regions,
            tableCells: extracted.tableCells,
            previewPages: extracted.previewPages,
            confidence: nil,
            reviewNotice: "Review this on-device draft against the source before saving."
        )
    }

    private func translate(
        input: AIInput,
        extracted: AIExtractedContent,
        options: AITranslationOptions,
        allowLanguageDownload: Bool,
        translationSession: AITranslationSessionBridge?
    ) async throws -> AIReviewArtifact {
        let chunks = try makeChunks(from: extracted.pages)
        guard !chunks.isEmpty else { throw AIError.emptyText }
        let translated: [String]
        if let translationSession {
            translated = try await translationSession.translate(chunks: chunks)
        } else {
            translated = try await translationProvider.translate(
                chunks: chunks,
                sourceLanguageCode: options.sourceLanguageCode,
                targetLanguageCode: options.targetLanguageCode,
                allowDownload: allowLanguageDownload
            )
        }
        try Task.checkCancellation()
        guard translated.count == chunks.count else {
            throw AIError.translationUnavailable
        }
        let body = zip(chunks, translated).map { chunk, result in
            let pages = chunk.pageIndexes.map { "Page \($0 + 1)" }.joined(separator: ", ")
            return "[\(pages)]\n\(result)"
        }.joined(separator: "\n\n")
        return AIReviewArtifact(
            kind: .translation,
            sourceID: input.id,
            sourceName: input.displayName,
            title: "Translation — \(input.displayName)",
            body: body,
            sourceRegions: extracted.regions,
            tableCells: extracted.tableCells,
            previewPages: extracted.previewPages,
            confidence: nil,
            reviewNotice: "Review language, names, and line breaks against the source before saving."
        )
    }

    private func makeSmartExtraction(
        input: AIInput,
        extracted: AIExtractedContent
    ) throws -> AIReviewArtifact {
        var fields: [AIFieldCandidate] = []
        let regions = extracted.regions
        for (index, region) in regions.prefix(128).enumerated() {
            let parts = region.transcript.split(separator: ":", maxSplits: 1).map(String.init)
            let label = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespaces) : "Field \(index + 1)"
            let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : region.transcript
            guard !value.isEmpty else { continue }
            fields.append(
                AIFieldCandidate(
                    label: label,
                    value: value,
                    sourceRegion: region,
                    confidence: region.confidence
                )
            )
        }
        if fields.isEmpty {
            for (index, page) in extracted.pages.enumerated() {
                for (lineIndex, line) in page.text.split(separator: "\n").enumerated() where !line.isEmpty {
                    fields.append(
                        AIFieldCandidate(
                            label: "Page \(index + 1), line \(lineIndex + 1)",
                            value: String(line).trimmingCharacters(in: .whitespaces),
                            confidence: nil
                        )
                    )
                    if fields.count == 128 { break }
                }
                if fields.count == 128 { break }
            }
        }
        guard !fields.isEmpty else { throw AIError.emptyText }
        let body = fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        return AIReviewArtifact(
            kind: .smartExtraction,
            sourceID: input.id,
            sourceName: input.displayName,
            title: "Extraction — \(input.displayName)",
            body: body,
            fields: fields,
            sourceRegions: regions,
            tableCells: extracted.tableCells,
            previewPages: extracted.previewPages,
            confidence: average(fields.compactMap(\.confidence)),
            reviewNotice: "These are local OCR candidates. Verify every field and source region before saving."
        )
    }

    private func makeChartCandidate(
        input: AIInput,
        extracted: AIExtractedContent
    ) throws -> AIReviewArtifact {
        let cells = extracted.tableCells.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.column < $1.column
        }
        let body: String
        if cells.isEmpty {
            let rows = extracted.regions.sorted { lhs, rhs in
                if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
                return lhs.y > rhs.y
            }.map { escapeTSV($0.transcript) }
            guard !rows.isEmpty else { throw AIError.emptyText }
            body = rows.joined(separator: "\n")
        } else {
            let grouped = Dictionary(grouping: cells) {
                AIChartRowKey(page: $0.pageIndex, row: $0.row)
            }
            body = grouped.keys.sorted { lhs, rhs in
                if lhs.page != rhs.page { return lhs.page < rhs.page }
                return lhs.row < rhs.row
            }.map { key in
                (grouped[key] ?? []).sorted { $0.column < $1.column }
                    .map { escapeTSV($0.text) }
                    .joined(separator: "\t")
            }.joined(separator: "\n")
        }
        return AIReviewArtifact(
            kind: .chart,
            sourceID: input.id,
            sourceName: input.displayName,
            title: "Chart Candidate — \(input.displayName)",
            body: body,
            sourceRegions: extracted.regions,
            tableCells: cells,
            previewPages: extracted.previewPages,
            confidence: average(cells.compactMap { $0.region?.confidence }),
            reviewNotice: "Only detected text and table cells are shown. No plotted values were inferred. Review before saving."
        )
    }

    private func makeFormulaCandidate(
        input: AIInput,
        extracted: AIExtractedContent
    ) throws -> AIReviewArtifact {
        let orderedRegions = extracted.regions
            .sorted { lhs, rhs in
                if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
                if lhs.y != rhs.y { return lhs.y > rhs.y }
                return lhs.x < rhs.x
            }
            .map(\.transcript)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let regionOCR = orderedRegions.joined(separator: "\n")
        let pageOCR = extracted.pages
            .sorted { $0.pageIndex < $1.pageIndex }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let candidate = regionOCR.isEmpty ? pageOCR : regionOCR
        guard !candidate.isEmpty else { throw AIError.emptyText }
        return AIReviewArtifact(
            kind: .formula,
            sourceID: input.id,
            sourceName: input.displayName,
            title: "Formula Candidate — \(input.displayName)",
            body: candidate,
            sourceRegions: extracted.regions,
            tableCells: extracted.tableCells,
            previewPages: extracted.previewPages,
            confidence: average(extracted.regions.compactMap(\.confidence)),
            reviewNotice: "This is editable OCR text, not a proof of mathematical equivalence. Review the source crop before saving."
        )
    }

    private func makeChunks(from pages: [AIPageText]) throws -> [AITextChunk] {
        do {
            return try AIChunker.chunks(from: pages)
        } catch AIChunkingError.tooManyChunks {
            throw AIError.tooLarge
        }
    }

    /// Checks the complete prompt against the model's token budget before
    /// generation. If a conservative character chunk still cannot fit, split
    /// it while retaining its source page provenance. No provider is allowed
    /// to prefix-truncate a source chunk.
    private func makeSummaryChunks(from pages: [AIPageText]) async throws -> [AITextChunk] {
        let maximumChunks = maximumSummaryChunks(for: pages)
        var pending = try AIChunker.chunks(from: pages, maximumChunks: maximumChunks)
        var fitting: [AITextChunk] = []
        while !pending.isEmpty {
            try Task.checkCancellation()
            let chunk = pending.removeFirst()
            let prompt = summaryPrompt(for: chunk)
            if try await textProvider.promptFits(prompt, responseTokens: 512) {
                fitting.append(chunk)
                continue
            }

            // Keep splitting until the complete prompt fits. The source
            // bound, rather than an arbitrary minimum chunk size, limits the
            // total work; throwing here would otherwise reject a valid source
            // merely because its model budget is unusually small.
            guard chunk.text.count > 1 else { throw AIError.tooLarge }
            let nextMaximum = max(1, (chunk.text.count + 1) / 2)
            let pieces = try AIChunker.chunks(
                from: [AIPageText(pageIndex: chunk.pageIndexes.first ?? 0, text: chunk.text)],
                maximumCharacters: nextMaximum,
                maximumChunks: maximumChunks
            )
            guard pieces.count > 1 else { throw AIError.tooLarge }
            let withProvenance = pieces.enumerated().map { index, piece in
                AITextChunk(
                    id: "\(chunk.id)-\(index + 1)",
                    pageIndexes: chunk.pageIndexes,
                    text: piece.text
                )
            }
            pending.insert(contentsOf: withProvenance, at: 0)
            guard pending.count + fitting.count <= maximumChunks else {
                throw AIError.tooLarge
            }
        }
        return fitting
    }

    /// The source extractor accepts at most one million characters. Estimate
    /// how many small chunks that bound could require, while retaining a
    /// finite ceiling for malformed or future inputs. This keeps ordinary
    /// documents on the default path but allows low-context providers to
    /// split a bounded source without silently dropping its tail.
    private func maximumSummaryChunks(for pages: [AIPageText]) -> Int {
        let sourceCharacters = pages.reduce(into: 0) { total, page in
            total += page.text.count
        }
        let minimumExpectedChunkCharacters = 128
        let derived = max(
            AIChunker.defaultMaximumChunks,
            (sourceCharacters + minimumExpectedChunkCharacters - 1)
                / minimumExpectedChunkCharacters
        )
        return min(16_384, derived)
    }

    private func summaryPrompt(for chunk: AITextChunk) -> String {
        """
        Summarize this source chunk in a few faithful sentences. Keep names,
        dates, quantities, and uncertainty exactly as supplied. Do not add
        facts. Source pages: \(chunk.pageIndexes.map(String.init).joined(separator: ", ")).

        \(chunk.text)
        """
    }

    private func generate(prompt: String) async throws -> String {
        try Task.checkCancellation()
        let bounded = try await textProvider.boundedPrompt(prompt)
        try Task.checkCancellation()
        let result = try await textProvider.generate(prompt: bounded, maximumResponseTokens: 512)
        try Task.checkCancellation()
        return result
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func escapeTSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
