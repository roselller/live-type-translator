import Foundation

enum TargetLanguage: String, Codable, Sendable, CaseIterable {
    case simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case japanese = "ja", korean = "ko"

    static let phaseOne: [Self] = [.japanese, .korean]
    var register: String {
        switch self {
        case .japanese: "Japanese: polite です/ます (teineigo)."
        case .korean: "Korean: polite-formal 합쇼체, -습니다/-ㅂ니다 endings."
        case .simplifiedChinese: "Simplified Chinese: formal, polite, use 您."
        case .traditionalChinese: "Traditional Chinese: Taiwan wording, formal, polite, use 您."
        }
    }
}

struct TranslationProfile: Codable, Sendable, Equatable {
    struct Term: Codable, Sendable, Equatable { var source: String; var replacement: String }
    var audience = ""
    var glossary: [Term] = []

    func validate() throws {
        guard audience.count <= 200, glossary.count <= 12,
              !audience.contains("\0"), glossary.allSatisfy({
                  !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.source.count <= 80 && $0.replacement.count <= 120 &&
                  !$0.source.contains("\0") && !$0.replacement.contains("\0")
              }) else { throw AppFailure.profile }
    }

}

struct TranslationRequest: Sendable {
    var source: String
    var languages: [TargetLanguage] = TargetLanguage.phaseOne
    var profile = TranslationProfile()
}

struct Phrase: Sendable, Equatable {
    var source: String
    var used: String
    var alternatives: [String]
}

struct LanguageTranslation: Sendable {
    var language: TargetLanguage
    var text: String
    var notes: [String]
    var phrases: [Phrase]
}

struct TranslationResult: Sendable {
    var translations: [LanguageTranslation]
    var usedContextFallback = false
    var modelCalls = 1

    var pastePayload: String { "\n" + translations.map(\.text).joined(separator: "\n") }

    func validated(for request: TranslationRequest) throws -> Self {
        guard (1...3).contains(request.languages.count),
              Set(request.languages).count == request.languages.count,
              translations.count == request.languages.count else { throw AppFailure.invalidResult }
        var result = self
        let sourceLayout = TranslationLayout(request.source)
        let sourceLines = sourceLayout.sourceLines
        result.translations = try request.languages.map { language in
            let matches = translations.filter { $0.language == language }
            guard matches.count == 1, var translation = matches.first,
                  !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !translation.text.contains("\0") else { throw AppFailure.invalidResult }
            translation.phrases = translation.phrases.filter {
                !$0.used.isEmpty && translation.text.contains($0.used) &&
                !$0.source.isEmpty && request.source.contains($0.source) &&
                (2...3).contains($0.alternatives.count) && $0.alternatives.allSatisfy { !$0.isEmpty }
            }
            let outputLayout = TranslationLayout(translation.text)
            guard outputLayout.hasSameStructure(as: sourceLayout) else {
                Timing.event("validationLineStructure")
                throw AppFailure.invalidResult
            }
            for (sourceLine, translatedLine) in zip(sourceLines, outputLayout.sourceLines) {
                if TranslationLanguageCheck.isClearlyWrong(translatedLine, expected: language,
                    source: sourceLine, profile: request.profile) {
                    Timing.event("validationWrongLanguage", count: TargetLanguage.allCases.firstIndex(of: language) ?? -1)
                    throw AppFailure.wrongLanguage
                }
            }
            return translation
        }
        return result
    }
}

enum AppFailure: Error, LocalizedError, Equatable {
    case accessibility, modifiersHeld, focusChanged, secureField, noText
    case clipboardDenied, clipboardUnreadable, clipboardChanged, clipboardWrite, clipboardRestore
    case pasteUnconfirmed, invalidResult, wrongLanguage, contextOverflow, refused, unsupportedLanguage
    case deviceNotEligible, intelligenceOff, modelNotReady, modelBusy, modelFailed, timeout, profile
    case reviewUnavailable, tableSelection

    var errorDescription: String? {
        switch self {
        case .accessibility: "Grant TranslateBar Accessibility permission, then try again."
        case .modifiersHeld: "The shortcut keys stayed down too long. Release all shortcut keys and retry."
        case .focusChanged: "Focus or input changed. Nothing was inserted; trigger the shortcut again."
        case .secureField: "Secure text fields are not supported."
        case .noText: "Nothing to translate. Select some English text and try again."
        case .tableSelection: "Table cells or tab-separated text selected. Select text inside one cell, not the cell itself. Nothing was inserted."
        case .clipboardDenied: "Clipboard access was denied. Check System Settings → Privacy & Security."
        case .clipboardUnreadable: "The clipboard could not be read safely. Nothing was inserted."
        case .clipboardChanged: "The clipboard changed during capture. Try again."
        case .clipboardWrite: "Could not write the paste payload. Nothing was inserted."
        case .clipboardRestore: "Clipboard restoration failed. Inspect your clipboard before continuing."
        case .pasteUnconfirmed: "Paste was sent but consumption could not be confirmed. Inspect the app before retrying."
        case .invalidResult: "The model could not translate every line after two attempts. Nothing was inserted."
        case .wrongLanguage: "The model could not produce the requested languages after two attempts. Nothing was inserted."
        case .contextOverflow: "The text exceeds the on-device context window, even per language. Select less text."
        case .refused: "Apple's on-device model blocked this translation. This can happen with valid text. Nothing was inserted."
        case .unsupportedLanguage: "The on-device model does not support a requested language."
        case .deviceNotEligible: "This Mac is not eligible for the on-device model."
        case .intelligenceOff: "Enable Apple Intelligence in System Settings."
        case .modelNotReady: "The on-device model is not ready. Try again after its download finishes."
        case .modelBusy: "The on-device model is busy. Try again shortly."
        case .modelFailed: "On-device translation failed. Nothing was inserted."
        case .timeout: "On-device translation timed out. Nothing was inserted."
        case .profile: "Invalid profile. Use an audience of at most 200 characters and up to 12 glossary terms (80 / 120 characters each). English terms cannot be blank."
        case .reviewUnavailable: "The review panel could not receive keyboard focus. Nothing was inserted; try again."
        }
    }
}
