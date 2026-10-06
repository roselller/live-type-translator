import Foundation
import Testing
@testable import TranslateBar

@Suite @MainActor
struct SettingsTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TranslateBar-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func languageLimitsAndOrderSurviveReload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.toggle(.simplifiedChinese)
        #expect(throws: SettingsFailure.self) { try store.toggle(.traditionalChinese) }
        try store.toggle(.japanese)
        try store.toggle(.japanese)
        #expect(store.selection.languages == [.korean, .simplifiedChinese, .japanese])
        #expect(SettingsStore(directory: directory).selection == store.selection)
        try store.toggle(.korean)
        try store.toggle(.simplifiedChinese)
        #expect(throws: SettingsFailure.self) { try store.toggle(.japanese) }
        #expect(store.selection.languages == [.japanese])
    }

    @Test func profileUsesExistingFileAndSavesOnlyValidChanges() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = TranslationProfile(audience: "Project teammates", glossary: [.init(source: "Codename", replacement: "Codename")])
        try JSONEncoder().encode(original).write(to: directory.appending(path: "profile.json"))
        let store = SettingsStore(directory: directory)
        #expect(store.profile == original)
        var changed = original
        changed.audience = "Students"
        try store.saveProfile(changed)
        changed.audience = String(repeating: "x", count: 201)
        #expect(throws: AppFailure.profile) { try store.saveProfile(changed) }
        #expect(store.profile.audience == "Students")
        #expect(SettingsStore(directory: directory).profile == store.profile)
        changed.audience = ""
        changed.glossary = [.init(source: " ", replacement: "x")]
        #expect(throws: AppFailure.profile) { try store.saveProfile(changed) }
    }

    @Test func profileByteBudgetIsEnforcedIndependentlyOfCharacterLimits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let value = TranslationProfile(glossary: Array(repeating: .init(source: String(repeating: "語", count: 80), replacement: String(repeating: "文", count: 120)), count: 12))
        try value.validate()
        #expect(throws: SettingsFailure.self) { try store.saveProfile(value) }
        #expect(store.profile.glossary.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "profile.json").path))
    }

    @Test func rulesUseFirstMatchAndBrowserTitleAllowlist() throws {
        var rules = RulesConfiguration.seed
        rules = try rules.overriding(bundleID: "example.chat", mode: .chat)
        #expect(rules.rule(bundleID: "example.chat", title: nil).mode == .chat)
        #expect(rules.rule(bundleID: "unknown.app", title: nil).mode == .document)
        rules.rules.insert(.init(bundleID: "com.google.Chrome", titlePattern: "Chat$", mode: .chat), at: 0)
        #expect(rules.rule(bundleID: "com.google.Chrome", title: "Test - Chat").mode == .chat)
        #expect(rules.rule(bundleID: "com.google.Chrome", title: "Test - Google Docs - Chrome").mode == .document)
        #expect(rules.rule(bundleID: "com.google.Chrome", title: nil).mode == .document)
        #expect(!rules.usesWindowTitle(bundleID: "com.microsoft.Word"))
        let override = try rules.overriding(bundleID: "com.google.Chrome", mode: .document)
        #expect(override.rule(bundleID: "com.google.Chrome", title: "Test - Chat").mode == .document)
        #expect(override.rules.first?.titlePattern == nil)
        #expect(try RulesConfiguration.parse(override.json) == override)
    }

    @Test func invalidRulesNeverReplaceSavedRules() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.override(bundleID: "example.editor", mode: .chat)
        let url = directory.appending(path: "rules.json")
        let originalBytes = try Data(contentsOf: url)
        var invalid = RulesConfiguration.seed
        invalid.rules[2].titlePattern = "["
        for json in ["not json", invalid.json, RulesConfiguration(version: 9, browserBundleIDs: [], rules: []).json] {
            #expect(throws: SettingsFailure.self) { try store.saveRules(json) }
            #expect(try Data(contentsOf: url) == originalBytes)
        }
        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.rules.rule(bundleID: "example.editor", title: nil).mode == .chat)
        #expect(reloaded.rules == store.rules)
    }

    @Test func corruptFilesRemainUntouchedUntilExplicitRepair() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = Data("{".utf8)
        let url = directory.appending(path: "rules.json")
        try broken.write(to: url)
        let store = SettingsStore(directory: directory)
        #expect(store.warning != nil)
        #expect(!store.translationSettingsReadable)
        #expect(throws: SettingsFailure.self) { try store.override(bundleID: "example.editor", mode: .chat) }
        #expect(try Data(contentsOf: url) == broken)
        try store.saveRules(RulesConfiguration.seed.json)
        #expect(store.translationSettingsReadable && store.warning == nil)
    }

    @Test func failedWriteKeepsInMemorySettings() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "file-not-directory")
        try Data().write(to: file)
        let store = SettingsStore(directory: file)
        #expect(throws: SettingsFailure.self) { try store.toggle(.japanese) }
        #expect(store.selection.languages == TargetLanguage.phaseOne)
    }

    @Test func duplicateOrEmptySelectionsAreNotLoaded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for languages: [TargetLanguage] in [[], [.japanese, .japanese], TargetLanguage.allCases] {
            try JSONEncoder().encode(LanguageSelection(languages: languages)).write(to: directory.appending(path: "languages.json"))
            let store = SettingsStore(directory: directory)
            #expect(store.warning != nil)
            #expect(store.selection.languages == TargetLanguage.phaseOne)
        }
    }

    @Test func historyIsBoundedEditableClearableAndNeverWritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let recent = RecentResults()
        for number in 0..<12 {
            recent.add(request: .init(source: "Please review item \(number).", languages: [.japanese]), result: .init(translations: [
                .init(language: .japanese, text: "確認してください。", notes: ["Polite"], phrases: [])
            ]))
        }
        #expect(recent.entries.count == 10)
        #expect(recent.entries.first?.request.source == "Please review item 11.")
        #expect(recent.entries.last?.request.source == "Please review item 2.")
        let latest = try #require(recent.entries.first)
        recent.update(latest.id, result: .init(translations: [.init(language: .japanese, text: "ご確認ください。", notes: ["Edited"], phrases: [])]))
        #expect(recent.entries.first?.result.translations.first?.notes == ["Edited"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        #expect(RecentResults().entries.isEmpty)
        recent.clear()
        #expect(recent.entries.isEmpty)
    }

    @Test func settingsDraftNeedsExplicitSaveAndRejectsInvalidRules() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let draft = SettingsDraft(store: store)
        draft.profile.audience = "Team"
        #expect(store.profile.audience.isEmpty)
        draft.saveProfile(to: store)
        #expect(!draft.failed && store.profile.audience == "Team")
        draft.rulesJSON = "invalid"
        draft.saveRules(to: store)
        #expect(draft.failed && store.rules == .seed)
    }
}
