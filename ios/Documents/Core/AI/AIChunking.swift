import Foundation

enum AIChunkingError: Error, Equatable, Sendable {
    case tooManyChunks
}

/// Paragraph-aware chunking used by summaries and translations. It keeps page
/// IDs on every chunk so the review artifact can explain which source pages
/// were processed, while keeping prompts within a conservative local bound.
enum AIChunker {
    // Leave room for instructions and the bounded model response. The
    // provider performs the final token check and rejects any prompt that
    // still cannot fit; this limit keeps ordinary chunks comfortably below
    // the model context budget without dropping source text.
    static let defaultMaximumCharacters = 4_000
    static let defaultMaximumChunks = 64

    static func chunks(
        from pages: [AIPageText],
        maximumCharacters: Int = defaultMaximumCharacters,
        maximumChunks: Int = defaultMaximumChunks
    ) throws -> [AITextChunk] {
        guard maximumCharacters > 0, maximumChunks > 0 else { return [] }
        var result: [AITextChunk] = []
        var pendingText = ""
        var pendingPages: [Int] = []

        func flush() {
            let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                pendingText = ""
                pendingPages = []
                return
            }
            result.append(
                AITextChunk(
                    id: "chunk-\(result.count + 1)",
                    pageIndexes: Array(Set(pendingPages)).sorted(),
                    text: trimmed
                )
            )
            pendingText = ""
            pendingPages = []
        }

        for page in pages {
            let paragraphs = splitParagraphs(page.text)
            for paragraph in paragraphs {
                for piece in splitLongParagraph(paragraph, maximumCharacters: maximumCharacters) {
                    let proposed = pendingText.isEmpty ? piece : pendingText + "\n\n" + piece
                    if proposed.count > maximumCharacters, !pendingText.isEmpty {
                        flush()
                    }
                    pendingText = pendingText.isEmpty ? piece : pendingText + "\n\n" + piece
                    pendingPages.append(page.pageIndex)
                    if pendingText.count >= maximumCharacters {
                        flush()
                    }
                    if result.count > maximumChunks {
                        throw AIChunkingError.tooManyChunks
                    }
                }
            }
        }
        flush()
        guard result.count <= maximumChunks else { throw AIChunkingError.tooManyChunks }
        return result
    }

    private static func splitParagraphs(_ text: String) -> [String] {
        text
            .components(separatedBy: "\n\n")
            .flatMap { paragraph in
                let normalized = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized.isEmpty { return [String]() }
                return [normalized]
            }
    }

    private static func splitLongParagraph(_ text: String, maximumCharacters: Int) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let wordString = String(word)
            if wordString.count > maximumCharacters {
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(contentsOf: stride(from: 0, to: wordString.count, by: maximumCharacters).map { start in
                    let startIndex = wordString.index(wordString.startIndex, offsetBy: start)
                    let endOffset = min(start + maximumCharacters, wordString.count)
                    let endIndex = wordString.index(wordString.startIndex, offsetBy: endOffset)
                    return String(wordString[startIndex..<endIndex])
                })
                continue
            }
            let proposed = current.isEmpty ? wordString : current + " " + wordString
            if proposed.count > maximumCharacters, !current.isEmpty {
                pieces.append(current)
                current = wordString
            } else {
                current = proposed
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
