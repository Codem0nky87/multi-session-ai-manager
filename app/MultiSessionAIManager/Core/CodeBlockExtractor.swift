import Foundation

public struct ParsedMessageSegment: Identifiable, Equatable, Sendable {
    public let id: String
    public enum SegmentType: Equatable, Sendable {
        case text(String)
        case codeBlock(code: String, language: String?)
    }
    public let type: SegmentType

    public init(id: String = UUID().uuidString, type: SegmentType) {
        self.id = id
        self.type = type
    }
}

public enum CodeBlockExtractor {
    /// Parses a markdown string into interleaved text and code blocks.
    public static func parse(markdown: String) -> [ParsedMessageSegment] {
        guard !markdown.isEmpty else { return [] }

        var segments: [ParsedMessageSegment] = []
        let fence = "```"
        var currentIndex = markdown.startIndex

        while currentIndex < markdown.endIndex {
            // Find opening fence
            guard let openFenceRange = markdown[currentIndex...].range(of: fence) else {
                // Remaining text is all plain text
                let remaining = String(markdown[currentIndex...])
                let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(ParsedMessageSegment(type: .text(remaining)))
                }
                break
            }

            // Preceding text before opening fence
            if openFenceRange.lowerBound > currentIndex {
                let textBefore = String(markdown[currentIndex..<openFenceRange.lowerBound])
                let trimmed = textBefore.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(ParsedMessageSegment(type: .text(textBefore)))
                }
            }

            // After ```, read until newline for language specifier
            let afterOpenFence = openFenceRange.upperBound
            let lineEndIndex = markdown[afterOpenFence...].firstIndex(of: "\n") ?? markdown.endIndex

            let rawLang = String(markdown[afterOpenFence..<lineEndIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let language: String? = rawLang.isEmpty ? nil : rawLang

            let codeStartIndex = (lineEndIndex < markdown.endIndex) ? markdown.index(after: lineEndIndex) : lineEndIndex

            // Look for closing fence
            if let closeFenceRange = markdown[codeStartIndex...].range(of: fence) {
                let code = String(markdown[codeStartIndex..<closeFenceRange.lowerBound])
                    .trimmingCharacters(in: .newlines)
                segments.append(ParsedMessageSegment(type: .codeBlock(code: code, language: language)))
                currentIndex = closeFenceRange.upperBound
            } else {
                // Unclosed code block (e.g. streaming in progress)
                let code = String(markdown[codeStartIndex...]).trimmingCharacters(in: .newlines)
                segments.append(ParsedMessageSegment(type: .codeBlock(code: code, language: language)))
                break
            }
        }

        return segments
    }
}
