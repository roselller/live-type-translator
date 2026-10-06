import Foundation
import FoundationModels
import Testing
@testable import TranslateBar

@Suite
struct TranslationStructureTests {
    @Test func mapsCurrentGuardrailAndRefusalWithoutExposingPrivateDetails() {
        let guardrail = LanguageModelError.guardrailViolation(.init(debugDescription: "Synthetic private detail"))
        let refusal = LanguageModelError.refusal(.init(explanation: "Synthetic private explanation",
                                                      debugDescription: "Synthetic private detail"))
        for error in [guardrail, refusal] {
            #expect(FoundationModelsEngine.classify(error) as? AppFailure == .refused)
        }
    }

    @Test func mapsLegacyErrorsStillEmittedByMacOS27() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "Synthetic private detail")
        let cases: [(LanguageModelSession.GenerationError, AppFailure)] = [
            (.exceededContextWindowSize(context), .contextOverflow),
            (.assetsUnavailable(context), .modelNotReady),
            (.guardrailViolation(context), .refused),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguage),
            (.decodingFailure(context), .invalidResult),
            (.rateLimited(context), .modelBusy),
            (.concurrentRequests(context), .modelBusy),
            (.unsupportedGuide(context), .modelFailed)
        ]
        for (error, expected) in cases {
            #expect(FoundationModelsEngine.classify(error) as? AppFailure == expected)
        }
    }

    @Test func responseBudgetGrowsWithOutputButStaysBounded() {
        #expect(FoundationModelsEngine.responseTimeout(for: .init(source: "Hello")) == .seconds(30))
        #expect(FoundationModelsEngine.responseTimeout(for: .init(source: String(repeating: "a", count: 500))) == .seconds(50))
        #expect(FoundationModelsEngine.responseTimeout(for: .init(source: String(repeating: "a", count: 10000))) == .seconds(60))
    }
    @Test func preservesBlankLinesAndEverySeparator() throws {
        let layout = TranslationLayout(" \nFirst\r\n\rSecond\u{2028}Third\u{2029}")
        #expect(layout.sourceLines == ["First", "Second", "Third"])
        let translated = try layout.assemble(["一つ目", "二つ目", "三つ目"])
        #expect(translated == " \n一つ目\r\n\r二つ目\u{2028}三つ目\u{2029}")
        #expect(TranslationLayout(translated).hasSameStructure(as: layout))
    }

    @Test func rejectsDroppedMergedEmptyAndExtraLines() {
        let layout = TranslationLayout("First\nSecond")
        for lines in [["one"], ["one", "two", "three"], ["one", ""], ["one\ntwo", "two"]] {
            #expect(throws: AppFailure.invalidResult) { try layout.assemble(lines) }
        }
    }

    @Test func ignoresOnlySurroundingModelWhitespace() throws {
        #expect(try TranslationLayout("First").assemble(["\n一つ目\n"]) == "一つ目")
    }

    @Test func blankSourceDoesNotRequestGeneration() {
        #expect(throws: AppFailure.noText) { try TranslationSchema(request: .init(source: " \r\n\n")) }
    }

    @Test func namedSlotsDetermineLanguageAndPreserveRequestedOrder() throws {
        let request = TranslationRequest(source: "First\n\nSecond\n", languages: [.korean, .japanese])
        let schema = try TranslationSchema(request: request)
        let generated = try GeneratedContent(json: """
        {"japanese":{"lines":["一つ目です。","二つ目です。"],"notes":[],"phrases":[]},
         "korean":{"lines":["첫 번째입니다.","두 번째입니다."],"notes":[],"phrases":[]}}
        """)
        let result = try schema.decode(generated).validated(for: request)
        #expect(result.translations.map(\.language) == [.korean, .japanese])
        #expect(result.translations[0].text == "첫 번째입니다.\n\n두 번째입니다.\n")
        #expect(result.translations[1].text == "一つ目です。\n\n二つ目です。\n")
    }

    @Test func schemaDecodingRejectsMissingLineEvenWithBothLanguages() throws {
        let schema = try TranslationSchema(request: .init(source: "First\nSecond"))
        let generated = try GeneratedContent(json: """
        {"japanese":{"lines":["一つ目です。"],"notes":[],"phrases":[]},
         "korean":{"lines":["첫 번째입니다.","두 번째입니다."],"notes":[],"phrases":[]}}
        """)
        #expect(throws: AppFailure.invalidResult) { try schema.decode(generated) }
    }

    @Test func rejectsJapaneseTextInKoreanSlotBeforePaste() throws {
        let request = TranslationRequest(source: "Please attend tomorrow's meeting.")
        let schema = try TranslationSchema(request: request)
        let generated = try GeneratedContent(json: """
        {"japanese":{"lines":["明日の会議に参加してください。"],"notes":[],"phrases":[]},
         "korean":{"lines":["明日の会議に出席してください。"],"notes":[],"phrases":[]}}
        """)
        #expect(throws: AppFailure.wrongLanguage) { try schema.decode(generated).validated(for: request) }
    }

    @Test func checksEveryLineForWrongLanguage() {
        let request = TranslationRequest(source: "First\nSecond")
        let result = TranslationResult(translations: [
            .init(language: .japanese, text: "一つ目です。\n二つ目です。", notes: [], phrases: []),
            .init(language: .korean, text: "첫 번째입니다.\n二つ目です。", notes: [], phrases: [])
        ])
        #expect(throws: AppFailure.wrongLanguage) { try result.validated(for: request) }
    }

    @Test func rejectsKoreanTextInJapaneseSlot() {
        #expect(TranslationLanguageCheck.isClearlyWrong("내일 회의에 참석해 주십시오.", expected: .japanese,
            source: "Please attend tomorrow's meeting.", profile: .init()))
    }

    @Test func allowsAmbiguousNamesAndIntentionalGlossaryReplacements() {
        let profile = TranslationProfile(glossary: [.init(source: "Example Brand", replacement: "サンプル")])
        #expect(!TranslationLanguageCheck.isClearlyWrong("サンプル", expected: .korean, source: "Example Brand", profile: profile))
        #expect(!TranslationLanguageCheck.isClearlyWrong("LINE", expected: .korean, source: "LINE", profile: .init()))
        #expect(!TranslationLanguageCheck.isClearlyWrong("https://example.com", expected: .japanese, source: "https://example.com", profile: .init()))
    }

    @Test func buildsSchemasForSingleLanguageFallbackAndThreeTargets() throws {
        _ = try TranslationSchema(request: .init(source: "First\nSecond", languages: [.korean]))
        _ = try TranslationSchema(request: .init(source: "First\nSecond", languages: [.simplifiedChinese, .traditionalChinese, .japanese]))
    }
}
