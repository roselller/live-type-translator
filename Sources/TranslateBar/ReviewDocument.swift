import Foundation

enum ReviewInsertMode: Sendable { case all, current }

struct ReviewHighlight: Identifiable, Sendable {
    let id = UUID()
    var range: NSRange
    let source: String
    let choices: [String]
}

struct ReviewedTranslation: Sendable {
    let language: TargetLanguage
    var text: String
    let notes: [String]
    var highlights: [ReviewHighlight]

    init(_ translation: LanguageTranslation) {
        language = translation.language
        text = translation.text
        notes = translation.notes
        highlights = []
        let string = translation.text as NSString
        var cursor = 0
        for phrase in translation.phrases where !phrase.used.isEmpty &&
            !phrase.used.contains(where: \.isNewline) && !phrase.used.contains("\0") {
            let range = string.range(of: phrase.used, range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound else { continue }
            var choices: [String] = []
            for value in [phrase.used] + phrase.alternatives {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !value.contains(where: \.isNewline), !value.contains("\0"),
                      !choices.contains(value) else { continue }
                choices.append(value)
            }
            if choices.count > 1 {
                highlights.append(.init(range: range, source: phrase.source, choices: choices))
            }
            cursor = NSMaxRange(range)
        }
    }

    mutating func choose(_ choice: String, for id: UUID) -> Bool {
        guard let index = highlights.firstIndex(where: { $0.id == id }),
              highlights[index].choices.contains(choice) else { return false }
        let oldRange = highlights[index].range
        let replacementLength = (choice as NSString).length
        text = (text as NSString).replacingCharacters(in: oldRange, with: choice)
        highlights[index].range.length = replacementLength
        for later in highlights.indices where highlights[later].range.location >= NSMaxRange(oldRange) && later != index {
            highlights[later].range.location += replacementLength - oldRange.length
        }
        return true
    }

    var translation: LanguageTranslation {
        .init(language: language, text: text, notes: notes, phrases: highlights.map {
            let used = (text as NSString).substring(with: $0.range)
            return Phrase(source: $0.source, used: used, alternatives: $0.choices.filter { $0 != used })
        })
    }
}

struct ReviewDocument: Sendable {
    private(set) var translations: [ReviewedTranslation]
    private(set) var currentIndex = 0
    let usedContextFallback: Bool
    let modelCalls: Int

    init(_ result: TranslationResult) {
        translations = result.translations.map(ReviewedTranslation.init)
        usedContextFallback = result.usedContextFallback
        modelCalls = result.modelCalls
    }

    var current: ReviewedTranslation { translations[currentIndex] }

    mutating func select(_ index: Int) {
        guard translations.indices.contains(index) else { return }
        currentIndex = index
    }

    mutating func moveLanguage(by offset: Int) {
        guard !translations.isEmpty else { return }
        select((currentIndex + offset % translations.count + translations.count) % translations.count)
    }

    mutating func choose(_ choice: String, for id: UUID) -> Bool {
        translations[currentIndex].choose(choice, for: id)
    }

    func result(for mode: ReviewInsertMode) -> TranslationResult {
        let values = mode == .all ? translations : [current]
        return .init(translations: values.map(\.translation),
                     usedContextFallback: usedContextFallback, modelCalls: modelCalls)
    }
}

extension TargetLanguage {
    var displayName: String {
        switch self {
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .simplifiedChinese: "Chinese (Simplified)"
        case .traditionalChinese: "Chinese (Traditional)"
        }
    }
}
