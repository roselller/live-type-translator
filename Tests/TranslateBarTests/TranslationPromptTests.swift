import Foundation
import Testing
@testable import TranslateBar

@Suite
struct TranslationPromptTests {
    @Test func promptPreservesEscapedTextNonblankLineOrderAndLanguageCues() throws {
        let layout = TranslationLayout("Say \"hello\".\n\nKeep C:\\data and https://example.com.\r\n")
        let prompt = try TranslationPrompt.make(layout: layout, languages: [.korean, .japanese], profile: .init(), retrying: false)
        let json = try #require(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        #expect(json["sourceLines"] as? [String] == layout.sourceLines)
        #expect(json["languages"] as? [String] == ["ko", "ja"])
        #expect(json["registers"] as? [String] == [TargetLanguage.korean.register, TargetLanguage.japanese.register])
        #expect(prompt == (try TranslationPrompt.make(layout: layout, languages: [.korean, .japanese], profile: .init(), retrying: false)))
    }

    @Test func retainsAudienceAndGlossaryAsDataAndCorrectsRetry() throws {
        let profile = TranslationProfile(audience: "Project \"A\" team", glossary: [
            .init(source: "Widget", replacement: "Widget")
        ])
        let layout = TranslationLayout("Please review Widget.")
        let prompt = try TranslationPrompt.make(layout: layout, languages: [.japanese], profile: profile, retrying: true)
        let json = try #require(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        let encodedProfile = try #require(json["profile"] as? [String: Any])
        #expect(encodedProfile["audience"] as? String == profile.audience)
        #expect((encodedProfile["glossary"] as? [[String: String]])?.first?["replacement"] == "Widget")
        #expect((json["reminder"] as? String)?.contains("previous attempt failed validation") == true)
        #expect(json["sourceLines"] as? [String] == ["Please review Widget."])
    }
}
