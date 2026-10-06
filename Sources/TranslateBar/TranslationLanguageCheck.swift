import Foundation
import NaturalLanguage

/// Conservative, on-device checks for clear cross-language output, not a
/// translation-quality score. Short names, URLs, and shared Han text are ambiguous.
enum TranslationLanguageCheck {
    static func isClearlyWrong(_ text: String, expected: TargetLanguage,
                               source: String, profile: TranslationProfile) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == source.trimmingCharacters(in: .whitespacesAndNewlines) { return false }
        if profile.glossary.contains(where: { $0.replacement == trimmed }) { return false }
        if containsIntroducedForeignWords(trimmed, source: source, profile: profile) { return true }
        var kana = 0
        var hangul = 0
        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F,
                 0xA960...0xA97F, 0xD7B0...0xD7FF: hangul += 1
            default: break
            }
        }
        if expected == .korean, kana > 0, hangul == 0 { return true }
        if expected == .japanese, hangul > 0, kana == 0 { return true }
        // Do not turn uncertain language identification into false cancellation.
        guard kana + hangul >= 10 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let guesses = recognizer.languageHypotheses(withMaximum: 2)
        if expected != .japanese, (guesses[.japanese] ?? 0) >= 0.9 { return true }
        if expected != .korean, (guesses[.korean] ?? 0) >= 0.9 { return true }
        return false
    }

    private static let latinWord = try! NSRegularExpression(pattern: #"[\p{Latin}\p{M}]+(?:['’-][\p{Latin}\p{M}]+)*"#)
    private static let englishMonths: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december"
    ]
    // A recognizer often labels a short foreign month as an uncertain proper
    // name. Cover calendar words explicitly, only in a numeric date context.
    private static let foreignMonths: Set<String> = Set(("""
        janvier fevrier mars avril mai juin juillet aout septembre octobre novembre decembre
        januar februar marz juni juli oktober dezember
        enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre
        janeiro fevereiro marco maio junho julho setembro outubro dezembro
        gennaio febbraio maggio giugno luglio settembre dicembre
        """).split(whereSeparator: \.isWhitespace).map(String.init))

    private static func words(_ text: String) -> [String] {
        let value = text as NSString
        return latinWord.matches(in: text, range: NSRange(location: 0, length: value.length)).map {
            value.substring(with: $0.range).folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                  locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func containsIntroducedForeignWords(_ text: String, source: String,
                                                       profile: TranslationProfile) -> Bool {
        let sourceWords = Set(words(source))
        let allowed = sourceWords.union(profile.glossary.flatMap { words($0.replacement) })
        let introduced = words(text).filter { !allowed.contains($0) }
        guard !introduced.isEmpty else { return false }
        if !sourceWords.isDisjoint(with: englishMonths), source.contains(where: \.isNumber),
           text.contains(where: \.isNumber), !Set(introduced).isDisjoint(with: foreignMonths) { return true }

        // Whole-line identification hides foreign phrases surrounded by CJK.
        // Check only newly introduced Latin words; retain names, URLs, code and
        // glossary spellings present in the source. Short/uncertain spans pass.
        guard introduced.count >= 3, introduced.joined().count >= 16 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(introduced.joined(separator: " "))
        let guesses = recognizer.languageHypotheses(withMaximum: 1)
        return guesses.contains { language, confidence in language != .english && confidence >= 0.9 }
    }
}
