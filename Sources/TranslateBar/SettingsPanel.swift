import AppKit
import SwiftUI

@MainActor @Observable
final class SettingsDraft {
    var profile: TranslationProfile
    var rulesJSON: String
    var message: String?
    var failed = false
    var shortcut: GlobalShortcut
    var recordingShortcut = false
    var selectedTab = 0
    init(store: SettingsStore) {
        profile = store.profile
        rulesJSON = store.rules.json
        shortcut = store.shortcut
    }
    func saveProfile(to store: SettingsStore) {
        perform { try store.saveProfile(profile) }
    }
    func saveRules(to store: SettingsStore) {
        perform { try store.saveRules(rulesJSON); rulesJSON = store.rules.json }
    }
    func saveShortcut(using save: (GlobalShortcut) throws -> Void) {
        recordingShortcut = false
        perform { try save(shortcut) }
    }
    func acceptShortcut(_ value: GlobalShortcut) {
        shortcut = value
        recordingShortcut = false
        failed = false
        message = "Recorded \(value.displayName). Choose Save shortcut to apply."
    }
    func record(_ event: NSEvent) -> Bool {
        guard recordingShortcut else { return false }
        guard event.type == .keyDown else { return event.type == .keyUp }
        if event.isARepeat { return true }
        if event.keyCode == 0x35 {
            recordingShortcut = false
            message = "Recording cancelled. Your shortcut has not changed."
            failed = false
        } else {
            do { acceptShortcut(try GlobalShortcut(keyCode: event.keyCode, flags: event.modifierFlags)) }
            catch { failed = true; message = (error as? LocalizedError)?.errorDescription }
        }
        return true // Do not let recorded keystrokes edit another control.
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); failed = false; message = "Saved." }
        catch { failed = true; message = (error as? LocalizedError)?.errorDescription ?? "Could not save settings." }
    }
}

private final class SettingsWindow: NSPanel {
    var onClose: (() -> Void)?
    var recordEvent: ((NSEvent) -> Bool)?
    var stopRecording: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { onClose?() }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override func close() { if let onClose { onClose() } else { super.close() } }
    @objc func closeFromButton(_ sender: Any?) { onClose?() }
    override func resignKey() { stopRecording?(); super.resignKey() }
    override func sendEvent(_ event: NSEvent) {
        if recordEvent?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if recordEvent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class SettingsPanelController {
    private var window: SettingsWindow?
    var panel: NSPanel? { window }
    private(set) var draft: SettingsDraft?
    var isVisible: Bool { panel?.isVisible == true }

    func show(store: SettingsStore, saveShortcut: @escaping (GlobalShortcut) throws -> Void) {
        if let panel { panel.orderFrontRegardless(); panel.makeKey(); return }
        let draft = SettingsDraft(store: store)
        let panel = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "TranslateBar — Settings"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.close() }
        panel.recordEvent = { [weak draft] in draft?.record($0) ?? false }
        panel.stopRecording = { [weak draft] in draft?.recordingShortcut = false }
        if let close = panel.standardWindowButton(.closeButton) {
            close.target = panel
            close.action = #selector(SettingsWindow.closeFromButton(_:))
            close.isEnabled = true
        }
        panel.contentView = NSHostingView(rootView: SettingsView(store: store, draft: draft, saveShortcut: saveShortcut))
        panel.center()
        self.window = panel
        self.draft = draft
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        draft?.recordingShortcut = false
        window?.orderOut(nil)
        window?.onClose = nil
        window?.recordEvent = nil
        window?.stopRecording = nil
        window?.contentView = nil
        window = nil
        draft = nil // Unsaved edits are discarded, never automatically persisted.
    }

    func recordActiveShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard window?.isKeyWindow == true, draft?.recordingShortcut == true else { return false }
        draft?.acceptShortcut(shortcut)
        return true
    }
}

private struct SettingsView: View {
    @Bindable var store: SettingsStore
    @Bindable var draft: SettingsDraft
    let saveShortcut: (GlobalShortcut) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TranslateBar settings").font(.title2.bold())
            Text("English → \(store.selection.languages.map(\.displayName).joined(separator: ", ")) · Polite / formal")
                .font(.callout).foregroundStyle(.secondary)
            if let warning = store.warning {
                Text(warning).font(.caption).foregroundStyle(.red)
                Text("Files needing repair: \(store.unreadableFiles.sorted().joined(separator: ", ")). Save the affected tab, or change the language picker to repair languages.json.")
                    .font(.caption)
            }
            TabView(selection: $draft.selectedTab) {
                shortcutTab.tabItem { Text("Shortcut") }.tag(0)
                profileTab.tabItem { Text("Audience & glossary") }.tag(1)
                rulesTab.tabItem { Text("App rules") }.tag(2)
            }
            .onChange(of: draft.selectedTab) { draft.recordingShortcut = false }
            if let message = draft.message {
                Text(message).font(.caption).foregroundStyle(draft.failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Change target languages from the menu bar. Each tab saves separately; closing discards unsaved edits.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 680, height: 570)
    }

    private var shortcutTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Translate selected text").font(.headline)
            Text("Saved shortcut: \(store.shortcut.displayName)").foregroundStyle(.secondary)
            HStack {
                Text(draft.recordingShortcut ? "Press a shortcut…" : draft.shortcut.displayName)
                    .font(.system(size: 23, weight: .medium, design: .monospaced))
                    .frame(minWidth: 220, alignment: .leading)
                    .accessibilityLabel(draft.recordingShortcut ? "Recording shortcut" : "Chosen shortcut \(draft.shortcut.displayName)")
                Button(draft.recordingShortcut ? "Stop recording" : "Record shortcut") {
                    draft.recordingShortcut.toggle(); draft.message = nil; draft.failed = false
                }
            }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Use a letter, number, or F1–F20 with two or more modifiers, including Control or Command. Esc cancels recording.")
                .font(.callout)
            Text("Key labels use US physical positions. If a combination does not appear, macOS or another app may be using it. Choose another.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Your current shortcut stays active until the new one is registered and saved successfully.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Reset to \(GlobalShortcut.standard.displayName)") { draft.acceptShortcut(.standard) }
                Spacer()
                Button("Save shortcut") { draft.saveShortcut(using: saveShortcut) }
                    .buttonStyle(.borderedProminent).disabled(draft.recordingShortcut)
            }
        }.padding(14)
    }

    private var profileTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usual audience (\(draft.profile.audience.count)/200)").font(.headline)
            TextField("For example, university project teammates", text: $draft.profile.audience)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Glossary (\(draft.profile.glossary.count)/12)").font(.headline)
                Spacer()
                Button("Add term") { draft.profile.glossary.append(.init(source: "", replacement: "")) }
                    .disabled(draft.profile.glossary.count >= 12)
            }
            Text("English term → preferred wording. To keep a term, enter the same text on both sides. Limits: 80 / 120 characters per row; 4 KB total profile.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(draft.profile.glossary.indices, id: \.self) { index in
                        HStack {
                            TextField("English term", text: termBinding(index, \.source))
                                .accessibilityLabel("English term \(index + 1)")
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Preferred wording", text: termBinding(index, \.replacement))
                                .accessibilityLabel("Preferred wording \(index + 1)")
                            Button { draft.profile.glossary.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("Remove term \(index + 1)")
                        }.textFieldStyle(.roundedBorder)
                    }
                }.padding(2)
            }
            HStack {
                Text("Only this profile is saved. Translation history stays in memory.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save profile") { draft.saveProfile(to: store) }.buttonStyle(.borderedProminent)
            }
        }.padding(14)
    }

    private var rulesTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("First matching rule wins. No match uses Document. Title patterns apply only to IDs in browserBundleIDs.")
                .font(.callout)
            Text("Chat captures the whole input when nothing is selected. Document captures the current paragraph. Menu overrides apply to the entire app, including all browser tabs.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.rulesJSON).font(.system(.body, design: .monospaced))
                .accessibilityLabel("App rules JSON")
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.3)) }
            HStack {
                Button("Load default rules") { draft.rulesJSON = RulesConfiguration.seed.json; draft.message = "Defaults loaded into the editor. Choose Save rules to apply."; draft.failed = false }
                Spacer()
                Button("Save rules") { draft.saveRules(to: store) }.buttonStyle(.borderedProminent)
            }
        }.padding(14)
    }

    private func termBinding(_ index: Int, _ path: WritableKeyPath<TranslationProfile.Term, String>) -> Binding<String> {
        Binding(get: { draft.profile.glossary.indices.contains(index) ? draft.profile.glossary[index][keyPath: path] : "" },
                set: { if draft.profile.glossary.indices.contains(index) { draft.profile.glossary[index][keyPath: path] = $0 } })
    }
}
