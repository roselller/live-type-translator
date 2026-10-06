import Foundation
import Observation

enum SettingsFailure: Error, LocalizedError {
    case languages, rules, read, write, profileSize
    var errorDescription: String? {
        switch self {
        case .languages: "Choose one to three different languages."
        case .rules: "Invalid rules. Use version 1, a browserBundleIDs list, and up to 100 rules with a bundleID, optional valid titlePattern, and chat or document mode."
        case .read: "Could not load saved settings. Defaults are in use; the existing files have not been changed. Open Settings to repair them."
        case .write: "Could not save settings. Your previous settings are still in use."
        case .profileSize: "The profile exceeds 4 KB. Shorten the audience or glossary."
        }
    }
}

struct LanguageSelection: Codable, Equatable {
    var languages: [TargetLanguage] = TargetLanguage.phaseOne

    func validate() throws {
        guard (1...3).contains(languages.count), Set(languages).count == languages.count else {
            throw SettingsFailure.languages
        }
    }

    func toggling(_ language: TargetLanguage) throws -> Self {
        var copy = self
        if let index = copy.languages.firstIndex(of: language) { copy.languages.remove(at: index) }
        else { copy.languages.append(language) }
        try copy.validate()
        return copy
    }
}

struct StoredAppRule: Codable, Equatable {
    var bundleID: String
    var titlePattern: String? = nil
    var mode: AppMode
}

struct RulesConfiguration: Codable, Equatable, RuleStore {
    var version = 1
    var browserBundleIDs: [String]
    var rules: [StoredAppRule]

    // Unknown applications use document mode until explicitly configured.
    static let seed = Self(browserBundleIDs: ["com.google.Chrome", "com.apple.Safari"], rules: [
        .init(bundleID: "com.microsoft.Word", mode: .document),
        .init(bundleID: "com.google.Chrome", titlePattern: "[-–] Google Docs(?: [-–].*)?$", mode: .document),
        .init(bundleID: "com.apple.Safari", titlePattern: "[-–] Google Docs(?: [-–].*)?$", mode: .document)
    ])

    func usesWindowTitle(bundleID: String) -> Bool { browserBundleIDs.contains(bundleID) }

    func rule(bundleID: String, title: String?) -> AppRule {
        let title = usesWindowTitle(bundleID: bundleID) ? title : nil
        let found = rules.first {
            $0.bundleID == bundleID && ($0.titlePattern == nil ||
                title?.range(of: $0.titlePattern!, options: .regularExpression) != nil)
        }
        return AppRule(bundleID: bundleID, titlePattern: found?.titlePattern, mode: found?.mode ?? .document)
    }

    func validate() throws {
        func validID(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 255 &&
                value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
        }
        guard version == 1, browserBundleIDs.count <= 30, rules.count <= 100,
              Set(browserBundleIDs).count == browserBundleIDs.count,
              browserBundleIDs.allSatisfy(validID) else { throw SettingsFailure.rules }
        for rule in rules {
            guard validID(rule.bundleID) else { throw SettingsFailure.rules }
            if let pattern = rule.titlePattern {
                guard browserBundleIDs.contains(rule.bundleID), !pattern.isEmpty, pattern.count <= 256,
                      (try? NSRegularExpression(pattern: pattern)) != nil else { throw SettingsFailure.rules }
            }
        }
    }

    func overriding(bundleID: String, mode: AppMode) throws -> Self {
        var copy = self
        copy.rules.removeAll { $0.bundleID == bundleID && $0.titlePattern == nil }
        copy.rules.insert(.init(bundleID: bundleID, mode: mode), at: 0)
        try copy.validate()
        return copy
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }

    static func parse(_ json: String) throws -> Self {
        guard json.utf8.count <= 65_536, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { throw SettingsFailure.rules }
        try value.validate()
        return value
    }
}

/// The only persistence boundary. Never accepts requests, source text, or results.
@MainActor @Observable
final class SettingsStore {
    private(set) var selection = LanguageSelection()
    private(set) var profile = TranslationProfile()
    private(set) var rules = RulesConfiguration.seed
    private(set) var shortcut = GlobalShortcut.standard
    private(set) var unreadableFiles: Set<String> = []
    let directory: URL
    var warning: String? { unreadableFiles.isEmpty ? nil : SettingsFailure.read.errorDescription }
    var translationSettingsReadable: Bool { !unreadableFiles.contains("profile.json") && !unreadableFiles.contains("rules.json") && !unreadableFiles.contains("languages.json") }

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "local.translatebar.TranslateBar")) {
        self.directory = directory
        load("shortcut.json", limit: 1024) { data in
            let value = try JSONDecoder().decode(GlobalShortcut.self, from: data)
            try value.validate(); shortcut = value
        }
        load("languages.json", limit: 1024) { data in
            let value = try JSONDecoder().decode(LanguageSelection.self, from: data)
            try value.validate(); selection = value
        }
        load("profile.json", limit: 4096) { data in
            let value = try JSONDecoder().decode(TranslationProfile.self, from: data)
            try value.validate(); profile = value
        }
        load("rules.json", limit: 65_536) { data in
            rules = try RulesConfiguration.parse(String(decoding: data, as: UTF8.self))
        }
    }

    func toggle(_ language: TargetLanguage) throws {
        let updated = try selection.toggling(language)
        try save(updated, file: "languages.json", limit: 1024)
        selection = updated
    }

    func saveProfile(_ value: TranslationProfile) throws {
        try value.validate()
        try save(value, file: "profile.json", limit: 4096)
        profile = value
    }

    func saveShortcut(_ value: GlobalShortcut) throws {
        try value.validate()
        try save(value, file: "shortcut.json", limit: 1024)
        shortcut = value
    }

    func saveRules(_ json: String) throws {
        let value = try RulesConfiguration.parse(json)
        try save(value, file: "rules.json", limit: 65_536)
        rules = value
    }

    func override(bundleID: String, mode: AppMode) throws {
        // Do not overwrite an unreadable hand-edited file with defaults.
        guard !unreadableFiles.contains("rules.json") else { throw SettingsFailure.read }
        let updated = try rules.overriding(bundleID: bundleID, mode: mode)
        try saveRules(updated.json)
    }

    private func load(_ file: String, limit: Int, accept: (Data) throws -> Void) {
        let url = directory.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= limit else { throw SettingsFailure.read }
            try accept(Data(contentsOf: url))
        } catch { unreadableFiles.insert(file) }
    }

    private func save<T: Encodable>(_ value: T, file: String, limit: Int) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw file == "profile.json" ? SettingsFailure.profileSize : SettingsFailure.rules }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: file), options: .atomic)
        } catch { throw SettingsFailure.write }
        unreadableFiles.remove(file)
    }
}
