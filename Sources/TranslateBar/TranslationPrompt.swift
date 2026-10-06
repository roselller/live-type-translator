import Foundation

/// Deterministic encoding with explicit language cues. Keep these cues even
/// though the guided schema also names languages: removing them regressed
/// short-input language correctness in the on-device benchmark.
enum TranslationPrompt {
    static func make(layout: TranslationLayout, languages: [TargetLanguage], profile: TranslationProfile, retrying: Bool) throws -> String {
        struct Input: Encodable {
            var languages: [String]
            var registers: [String]
            var profile: TranslationProfile
            var sourceLines: [String]
            var reminder = "Each named language field must use that language. Translate every sourceLines entry once, in order."
        }
        var input = Input(languages: languages.map(\.rawValue), registers: languages.map(\.register),
                          profile: profile, sourceLines: layout.sourceLines)
        if retrying {
            input.reminder += " The previous attempt failed validation. Check every line and language carefully; Korean must be Korean, not Japanese. Translate calendar months into the requested language; remove any introduced French or other foreign-language words."
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(input), as: UTF8.self)
    }
}
