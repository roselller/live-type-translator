import Foundation
import FoundationModels

/// Requested language keys and exact line counts are encoded into the grammar.
/// The model cannot label a second Japanese object as the Korean result.
struct TranslationSchema: Sendable {
    let layout: TranslationLayout
    let languages: [TargetLanguage]
    let schema: GenerationSchema

    init(request: TranslationRequest) throws {
        layout = TranslationLayout(request.source)
        languages = request.languages
        guard !layout.contentIndices.isEmpty else { throw AppFailure.noText }
        let lineCount = layout.contentIndices.count
        // Short prompts need the redundant language cues: abbreviating these
        // caused wrong-language retries in the native benchmark. Multiline input
        // provides more context and benefits from the shorter descriptions.
        let compact = lineCount > 1
        let properties = languages.map { language in
            let block = DynamicGenerationSchema(name: "\(language.schemaKey)Translation", properties: [
                // Repeat a grammar-fixed language name immediately before its text
                // to prevent the prior language from carrying into this block.
                .init(name: "language", description: compact ? nil : "The language of every following translation line.",
                    schema: .init(type: String.self, guides: [.constant(language.generationName)])),
                .init(name: "lines", description: compact
                    ? "\(language.register) One complete translation per sourceLines entry, in order; no embedded line breaks."
                    : "Translate each sourceLines entry into \(language.register) Return exactly \(lineCount) strings in source order, one complete translation per entry. No line breaks inside strings. Never use another target language here.",
                    schema: .init(arrayOf: .init(type: String.self), minimumElements: lineCount, maximumElements: lineCount)),
                .init(name: "notes", description: compact
                    ? "Usually empty. Only consequential ambiguities; at most two short notes."
                    : "Usually empty. At most two short sentences about consequential ambiguities; never explain routine wording.",
                    schema: .init(arrayOf: .init(type: String.self), maximumElements: 2)),
                .init(name: "phrases", description: compact
                    ? "Usually empty. At most two short ambiguous phrases."
                    : "Usually empty. At most two short ambiguous phrases worth reviewing, not a whole sentence.",
                    schema: .init(arrayOf: .init(type: ModelPhrase.self), maximumElements: 2))
            ])
            return DynamicGenerationSchema.Property(name: language.schemaKey,
                description: compact ? nil : "Only \(language.register)", schema: block)
        }
        schema = try GenerationSchema(root: .init(name: "Translations", properties: properties), dependencies: [])
    }

    func decode(_ content: GeneratedContent) throws -> TranslationResult {
        guard content.isComplete else { throw AppFailure.invalidResult }
        return TranslationResult(translations: try languages.map { language in
            let block = try content.value(GeneratedContent.self, forProperty: language.schemaKey)
            let lines = try block.value([String].self, forProperty: "lines")
            let phrases = try block.value([ModelPhrase].self, forProperty: "phrases")
            return LanguageTranslation(language: language, text: try layout.assemble(lines),
                notes: try block.value([String].self, forProperty: "notes"),
                phrases: phrases.map { .init(source: $0.source, used: $0.used, alternatives: $0.alternatives) })
        })
    }

    func hasTranslationText(_ content: GeneratedContent) -> Bool {
        for language in languages {
            guard let block = try? content.value(GeneratedContent.self, forProperty: language.schemaKey),
                  let lines = try? block.value(GeneratedContent.self, forProperty: "lines"),
                  case .array(let entries) = lines.kind else { continue }
            if entries.contains(where: { if case .string(let value) = $0.kind { return !value.isEmpty }; return false }) {
                return true
            }
        }
        return false
    }

    func logShape(_ content: GeneratedContent?) {
        guard let content else { return }
        for language in languages {
            guard let block = try? content.value(GeneratedContent.self, forProperty: language.schemaKey) else { continue }
            Timing.event("shapeLanguage", count: TargetLanguage.allCases.firstIndex(of: language) ?? -1)
            for (property, stage) in [("lines", "shapeLines"), ("notes", "shapeNotes"), ("phrases", "shapePhrases")] {
                guard let value = try? block.value(GeneratedContent.self, forProperty: property),
                      case .array(let entries) = value.kind else { continue }
                Timing.event(stage, count: entries.count)
                if property == "lines" {
                    for entry in entries {
                        if case .string(let text) = entry.kind { Timing.event("shapeLineCharacters", count: text.count) }
                    }
                }
            }
        }
    }
}

extension TargetLanguage {
    var generationName: String {
        switch self {
        case .japanese: "Japanese (日本語)"
        case .korean: "Korean (한국어)"
        case .simplifiedChinese: "Simplified Chinese (简体中文)"
        case .traditionalChinese: "Traditional Chinese (繁體中文)"
        }
    }

    var schemaKey: String {
        switch self {
        case .japanese: "japanese"
        case .korean: "korean"
        case .simplifiedChinese: "simplifiedChinese"
        case .traditionalChinese: "traditionalChinese"
        }
    }
}
