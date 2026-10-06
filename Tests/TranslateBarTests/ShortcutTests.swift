import AppKit
import Carbon
import Testing
@testable import TranslateBar

@Suite @MainActor
struct ShortcutTests {
    private let custom = GlobalShortcut(keyCode: 0x0F, modifiers: UInt32(controlKey | cmdKey))

    @Test func rejectsTypingEditingAndUnsupportedCombinations() throws {
        for (key, flags): (UInt16, NSEvent.ModifierFlags) in [
            (0x00, []), (0x08, [.command]), (0x00, [.option, .shift]),
            (0x24, [.control, .option]), (0x35, [.command, .option]), (0x11, [.control, .option, .function])
        ] {
            #expect(throws: ShortcutFailure.self) { try GlobalShortcut(keyCode: key, flags: flags) }
        }
        #expect(throws: ShortcutFailure.self) { try GlobalShortcut(keyCode: 0x11, modifiers: UInt32.max).validate() }
        #expect(try GlobalShortcut(keyCode: 0x0F, flags: [.control, .command, .capsLock]) == custom)
        #expect(custom.displayName == "⌃⌘R")
        try GlobalShortcut(keyCode: 79, flags: [.control, .option, .function]).validate()
    }

    @Test func guardFollowsOnlyTheActiveShortcut() {
        let current = GuardInput(type: .keyDown, keyCode: 0x0F, flags: [.control, .command])
        #expect(!InputGuardPolicy.shouldInterrupt(current, shortcut: custom))
        #expect(InputGuardPolicy.shouldInterrupt(current, shortcut: nil))
        #expect(InputGuardPolicy.shouldInterrupt(current, shortcut: .standard))
        #expect(InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x11,
            flags: [.control, .option]), shortcut: custom))
        #expect(InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x0F,
            flags: [.control, .command, .shift]), shortcut: custom))
    }

    @Test func registrationConflictNeverChangesSavedOrActiveShortcut() throws {
        let original = Registration()
        let manager = CarbonHotkeyManager { shortcut, _ in
            if shortcut != .standard { throw ShortcutFailure.unavailable }
            return original
        }
        defer { manager.unregister() }
        try manager.register(.standard, persist: {}, action: {})
        var saved = false
        #expect(throws: ShortcutFailure.self) {
            try manager.register(custom, persist: { saved = true }, action: {})
        }
        #expect(!saved && manager.current == .standard && original.cancellations == 0)
    }

    @Test func failedDiskWriteCancelsCandidateButKeepsWorkingRegistration() throws {
        var registrations: [Registration] = []
        let manager = CarbonHotkeyManager { _, _ in
            let token = Registration(); registrations.append(token); return token
        }
        defer { manager.unregister() }
        try manager.register(.standard, persist: {}, action: {})
        #expect(throws: SettingsFailure.self) {
            try manager.register(custom, persist: { throw SettingsFailure.write }, action: {})
        }
        #expect(manager.current == .standard)
        #expect(registrations[0].cancellations == 0 && registrations[1].cancellations == 1)
    }

    @Test func replacementCommitsAfterSaveAndSameKeyCanRepairPreferences() throws {
        var registrations: [Registration] = []
        let manager = CarbonHotkeyManager { _, _ in
            let token = Registration(); registrations.append(token); return token
        }
        try manager.register(.standard, persist: {}, action: {})
        var saved: GlobalShortcut?
        try manager.register(custom, persist: {
            #expect(manager.current == .standard && registrations[0].cancellations == 0)
            saved = custom
        }, action: {})
        #expect(saved == custom && manager.current == custom && registrations[0].cancellations == 1)
        var repaired = false
        try manager.register(custom, persist: { repaired = true }, action: {})
        #expect(repaired && registrations.count == 2)
        manager.unregister()
        #expect(manager.current == nil && registrations[1].cancellations == 1)
    }

    @Test func persistenceAndCorruptFileRepairDoNotChangeOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TranslateBar-shortcut-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.saveShortcut(custom)
        #expect(SettingsStore(directory: directory).shortcut == custom)
        let url = directory.appending(path: "shortcut.json")
        let broken = Data(#"{"keyCode":17,"modifiers":0}"#.utf8)
        try broken.write(to: url)
        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.unreadableFiles == ["shortcut.json"])
        #expect(reloaded.translationSettingsReadable) // Menu action still works.
        #expect(try Data(contentsOf: url) == broken)
        try reloaded.saveShortcut(.standard)
        #expect(reloaded.warning == nil && SettingsStore(directory: directory).shortcut == .standard)
        #expect(reloaded.selection.languages == TargetLanguage.phaseOne)
    }

    @Test func recorderRejectsBareKeysCancelsAndRequiresExplicitSave() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TranslateBar-recorder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let draft = SettingsDraft(store: store)
        draft.recordingShortcut = true
        #expect(draft.record(try key(0x00)))
        #expect(draft.failed && draft.recordingShortcut && draft.shortcut == .standard)
        #expect(draft.record(try key(0x35)))
        #expect(!draft.recordingShortcut && draft.shortcut == .standard)
        draft.recordingShortcut = true
        #expect(draft.record(try key(0x0F, [.control, .command], repeated: true)))
        #expect(draft.recordingShortcut)
        #expect(draft.record(try key(0x0F, [.control, .command])))
        #expect(!draft.recordingShortcut && draft.shortcut == custom && store.shortcut == .standard)
        draft.saveShortcut { _ in throw ShortcutFailure.unavailable }
        #expect(draft.failed && store.shortcut == .standard)
        draft.saveShortcut { try store.saveShortcut($0) }
        #expect(!draft.failed && store.shortcut == custom)
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: code))
    }
    private final class Registration: HotkeyRegistration {
        var cancellations = 0
        func cancel() { cancellations += 1 }
    }
}
