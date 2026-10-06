import AppKit

/// Fixed fixtures and a temporary preferences directory only. No clipboard,
/// model call, synthetic global events, or writes to actual user preferences.
@MainActor
enum SettingsSmoke {
    static func run() async -> Bool {
        try? await Task.sleep(for: .milliseconds(400))
        let directory = FileManager.default.temporaryDirectory.appending(path: "TranslateBar-settings-smoke-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return false }
        do {
            let store = SettingsStore(directory: directory)
            let controller = AppController(settings: store)
            defer { controller.unregisterShortcut(); controller.settingsPanel.close() }
            let bar = MenuBarController(controller: controller, quit: {})
            bar.rebuild()
            guard let languages = bar.menu.items.first(where: { $0.title.hasPrefix("Target languages") })?.submenu,
                  let chinese = languages.items.firstIndex(where: { $0.title == "Chinese (Simplified)" }) else { throw Failure.check }
            languages.performActionForItem(at: chinese)
            print("Settings smoke state: after_language_foreground_preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
            guard store.selection.languages == [.japanese, .korean, .simplifiedChinese] else { throw Failure.check }
            bar.rebuild()
            guard let updated = bar.menu.items.first(where: { $0.title.hasPrefix("Target languages") })?.submenu,
                  updated.items.first(where: { $0.title == "Chinese (Traditional)" })?.isEnabled == false else { throw Failure.check }
            print("Settings smoke: PASS menu callbacks; three-language limit")

            guard let settingsIndex = bar.menu.items.firstIndex(where: { $0.title == "Settings…" }) else { throw Failure.check }
            bar.menu.performActionForItem(at: settingsIndex)
            try await Task.sleep(for: .milliseconds(400))
            print("Settings smoke state: visible=\(controller.settingsPanel.isVisible) key=\(controller.settingsPanel.panel?.isKeyWindow == true) can_start=\(controller.canStart) foreground_preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) foreground_is_self=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)")
            guard let panel = controller.settingsPanel.panel, let draft = controller.settingsPanel.draft,
                  panel.isVisible, panel.isKeyWindow, !controller.canStart,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure.check }
            draft.recordingShortcut = true
            panel.sendEvent(try key(0x35, flags: [], panel: panel))
            guard !draft.recordingShortcut, panel.isVisible else { throw Failure.check }
            draft.recordingShortcut = true
            let recorded = try key(79, flags: [.control, .option, .command, .function], panel: panel)
            guard panel.performKeyEquivalent(with: recorded), !draft.recordingShortcut,
                  draft.shortcut.keyCode == 79, store.shortcut == .standard else { throw Failure.check }
            draft.saveShortcut { try controller.saveShortcut($0) }
            guard !draft.failed, store.shortcut == draft.shortcut,
                  controller.activeShortcut == draft.shortcut else { throw Failure.check }
            draft.recordingShortcut = true
            guard controller.settingsPanel.recordActiveShortcut(store.shortcut), !draft.recordingShortcut else { throw Failure.check }
            bar.rebuild()
            guard bar.menu.items.contains(where: { $0.title == "Translate now (\(store.shortcut.displayName))" }) else { throw Failure.check }
            print("Settings smoke: PASS native recorder; Esc contained; saved shortcut; active chord capture; menu label")
            draft.profile.audience = "Project teammates"
            draft.profile.glossary = [.init(source: "Codename", replacement: "Codename")]
            draft.saveProfile(to: store)
            print("Settings smoke state: profile_saved=\(!draft.failed)")
            guard !draft.failed, store.profile == draft.profile else { throw Failure.check }
            draft.rulesJSON = "invalid"
            draft.saveRules(to: store)
            guard draft.failed else { throw Failure.check }
            draft.rulesJSON = try RulesConfiguration.seed.overriding(bundleID: "example.editor", mode: .chat).json
            draft.saveRules(to: store)
            guard !draft.failed else { throw Failure.check }
            try await Task.sleep(for: .milliseconds(200))
            draft.recordingShortcut = true
            guard let close = panel.standardWindowButton(.closeButton), close.isEnabled else { throw Failure.check }
            close.performClick(nil)
            try await Task.sleep(for: .milliseconds(120))
            print("Settings smoke state: closed=\(!controller.settingsPanel.isVisible) can_start=\(controller.canStart) key_released=\(NSApp.keyWindow == nil) foreground_preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
            guard !controller.settingsPanel.isVisible, controller.canStart, NSApp.keyWindow == nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure.check }
            let reload = SettingsStore(directory: directory)
            guard !draft.recordingShortcut, reload.shortcut == store.shortcut,
                  reload.selection == store.selection, reload.profile == store.profile, reload.rules == store.rules else { throw Failure.check }
            print("Settings smoke: PASS panel key focus; foreground preserved; save/reload; invalid rules rejected")

            let request = TranslationRequest(source: "Please review the plan.", languages: [.japanese])
            let fixture = TranslationResult(translations: [.init(language: .japanese, text: "計画をご確認ください。",
                notes: ["Polite wording."], phrases: [.init(source: "plan", used: "計画", alternatives: ["提案", "案"])])])
            let id = controller.recent.add(request: request, result: fixture)
            let review = ReviewPanelController()
            let pending = Task { @MainActor in
                try await review.present(fixture, request: request, originalPID: pid, fromHistory: true,
                    onClose: { controller.recent.update(id, result: $0) })
            }
            try await Task.sleep(for: .milliseconds(250))
            guard let state = review.state, let phrase = state.document.current.highlights.first else {
                review.cancel(); _ = await pending.result; throw Failure.check
            }
            state.choose("提案", for: phrase.id)
            review.cancel()
            _ = await pending.result
            guard controller.recent.entries.first?.result.translations.first?.text.contains("提案") == true else { throw Failure.check }
            controller.recent.clear()
            guard controller.recent.entries.isEmpty else { throw Failure.check }
            print("Settings smoke: PASS recent review edits retained in memory; clear history")
            return true
        } catch {
            print("Settings smoke: FAILED; menu/settings/recent lifecycle check")
            return false
        }
    }
    private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags, panel: NSPanel) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { throw Failure.check }
        return event
    }
    private enum Failure: Error { case check }
}
