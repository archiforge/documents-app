import UIKit

/// Paginated text → PDF rendering. Pure function: string in, PDF bytes out.
enum TextToPDF {
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 48

    static func pdf(from text: String, fontSize: CGFloat = 12) -> Data {
        let font = UIFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.isEmpty ? " " : $0 }

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        var index = 0
        return renderer.pdfData { context in
            context.beginPage()
            var y = margin
            let contentWidth = pageSize.width - margin * 2
            while index < paragraphs.count {
                let paragraph = paragraphs[index] as NSString
                let size = paragraph.boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    attributes: attributes,
                    context: nil
                ).size
                let height = max(size.height, font.lineHeight)

                if y + height > pageSize.height - margin, y > margin {
                    context.beginPage()
                    y = margin
                }
                paragraph.draw(
                    with: CGRect(x: margin, y: y, width: contentWidth, height: height),
                    options: [.usesLineFragmentOrigin],
                    attributes: attributes,
                    context: nil
                )
                y += height + 4
                index += 1
            }
        }
    }
}

/// Markdown → PDF: parses with `AttributedString(markdown:)` so headings,
/// emphasis, and lists keep their styling, then paginates paragraph by
/// paragraph. Pure function: string in, PDF bytes out.
enum MarkdownToPDF {
    static func pdf(fromMarkdown markdown: String) -> Data {
        let attributed = markdownAttributed(markdown)
        let paragraphs = splitParagraphs(attributed)
        let fallbackLineHeight = UIFont.systemFont(ofSize: 13).lineHeight

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: TextToPDF.pageSize)
        )
        let margin = TextToPDF.margin
        let contentWidth = TextToPDF.pageSize.width - margin * 2

        var index = 0
        return renderer.pdfData { context in
            context.beginPage()
            var y = margin
            while index < paragraphs.count {
                let paragraph = paragraphs[index]
                let size = paragraph.boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                ).size
                let height = max(size.height, fallbackLineHeight)

                if y + height > TextToPDF.pageSize.height - margin, y > margin {
                    context.beginPage()
                    y = margin
                }
                paragraph.draw(
                    with: CGRect(x: margin, y: y, width: contentWidth, height: height),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                y += height + 4
                index += 1
            }
        }
    }

    private static func markdownAttributed(_ markdown: String) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(markdown as String)

        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: UIFont.systemFont(ofSize: 13), range: range)
            }
        }
        mutable.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        }
        return mutable
    }

    /// Splits on newline boundaries (UTF-16 offsets, matching
    /// NSAttributedString indexing).
    private static func splitParagraphs(_ attributed: NSAttributedString) -> [NSAttributedString] {
        let units = Array(attributed.string.utf16)
        var paragraphs: [NSAttributedString] = []
        var start = 0
        var cursor = 0
        while cursor <= units.count {
            if cursor == units.count || units[cursor] == 0x0A {
                let range = NSRange(location: start, length: cursor - start)
                paragraphs.append(attributed.attributedSubstring(from: range))
                start = cursor + 1
            }
            cursor += 1
        }
        return paragraphs
    }
}
