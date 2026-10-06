import Foundation

/// Formatting is owned by the app, never guessed by the language model.
struct TranslationLayout: Sendable {
    let lines: [String]
    let separators: [String]
    let contentIndices: [Int]

    init(_ source: String) {
        var lines: [String] = []
        var separators: [String] = []
        var current = ""
        for character in source {
            if character.isNewline {
                lines.append(current)
                separators.append(String(character)) // Includes CRLF as one Character.
                current = ""
            } else {
                current.append(character)
            }
        }
        lines.append(current)
        self.lines = lines
        self.separators = separators
        contentIndices = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var sourceLines: [String] { contentIndices.map { lines[$0] } }

    func assemble(_ translations: [String]) throws -> String {
        guard translations.count == contentIndices.count else {
            Timing.event("validationLineCount", count: translations.count)
            throw AppFailure.invalidResult
        }
        var rendered = lines // Retain blank/whitespace-only lines exactly.
        for (index, translated) in zip(contentIndices, translations) {
            let text = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains(where: \.isNewline), !text.contains("\0") else {
                Timing.event("validationLineContent")
                throw AppFailure.invalidResult
            }
            rendered[index] = text
        }
        return rendered.indices.map { rendered[$0] + ($0 < separators.count ? separators[$0] : "") }.joined()
    }

    func hasSameStructure(as other: Self) -> Bool {
        separators == other.separators && contentIndices == other.contentIndices
    }
}
