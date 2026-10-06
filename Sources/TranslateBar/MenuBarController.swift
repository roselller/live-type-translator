import AppKit
import ApplicationServices

/// Native menu lifecycle gives each opening a fresh foreground-app snapshot.
/// SwiftUI continues to render settings and the review panel.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let quit: () -> Void
    private let item: NSStatusItem
    let menu = NSMenu()

    init(controller: AppController, quit: @escaping () -> Void) {
        self.controller = controller
        self.quit = quit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "TranslateBar")
        item.button?.toolTip = "TranslateBar — \(controller.settings.shortcut.displayName)"
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func rebuild() {
        menu.removeAllItems()
        item.button?.toolTip = "TranslateBar — \(controller.activeShortcut?.displayName ?? "use Translate now")"
        label(controller.status, in: menu)
        if let warning = controller.shortcutWarning { label(warning, in: menu) }
        if controller.settings.warning != nil { label("Saved settings need repair — open Settings", in: menu) }
        menu.addItem(.separator())
        let shortcut = controller.activeShortcut.map { " (\($0.displayName))" } ?? ""
        action("Translate now\(shortcut)", in: menu, enabled: controller.canStart) { [weak controller] in controller?.start(fromMenu: true) }
        if controller.busy { action("Cancel translation or review", in: menu) { [weak controller] in controller?.cancel() } }

        let languages = submenu("Target languages (choose 1–3)", in: menu)
        let picked = controller.settings.selection.languages
        label("Order: \(picked.map(\.displayName).joined(separator: " → "))", in: languages)
        for language in TargetLanguage.allCases {
            let selected = picked.firstIndex(of: language)
            let allowed = selected == nil ? picked.count < 3 : picked.count > 1
            let entry = action("\(selected.map { "\($0 + 1). " } ?? "")\(language.displayName)", in: languages,
                               enabled: !controller.busy && !controller.settingsPanel.isVisible && allowed) { [weak controller] in
                controller?.changeLanguage(language)
            }
            entry.state = selected == nil ? .off : .on
        }
        label("New choices are added last. Deselect, then reselect to reorder.", in: languages)

        let overrides = submenu("Treat this app as", in: menu)
        if let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let pid = front.processIdentifier
            let context = AXIsProcessTrusted() ? try? AppContext.capture(rules: controller.settings.rules) : nil
            let modeNow = context?.rule.mode ?? controller.settings.rules.rule(bundleID: bundleID, title: nil).mode
            label(front.localizedName ?? bundleID, in: overrides)
            label("Applies to the whole app, including all browser tabs.", in: overrides)
            for mode in [AppMode.chat, .document] {
                let entry = action(mode == .chat ? "Chat (whole input)" : "Document (current paragraph)", in: overrides,
                    enabled: !controller.busy && !controller.settingsPanel.isVisible) { [weak controller] in
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    controller?.overrideApp(bundleID: bundleID, mode: mode)
                }
                entry.state = modeNow == mode ? .on : .off
            }
        } else { label("Focus an app, then reopen this menu.", in: overrides) }

        let recent = submenu("Recent results", in: menu)
        label("In memory only · cleared on quit", in: recent)
        for entry in controller.recent.entries {
            let id = entry.id
            let time = entry.createdAt.formatted(date: .omitted, time: .shortened)
            let title = "\(time) · \(entry.preview)"
            let item = action(title, in: recent, enabled: controller.canStart) { [weak controller] in controller?.reopen(id) }
            item.toolTip = entry.result.translations.map { "\($0.language.displayName): \($0.notes.isEmpty ? "No notes" : $0.notes.joined(separator: " · "))" }.joined(separator: "\n")
        }
        if controller.recent.entries.isEmpty { label("No translations yet", in: recent) }
        else {
            recent.addItem(.separator())
            action("Clear recent results", in: recent, enabled: !controller.busy) { [weak controller] in controller?.recent.clear() }
        }
        menu.addItem(.separator())
        action("Settings…", in: menu, enabled: !controller.busy) { [weak controller] in controller?.showSettings() }
        action("Check Accessibility…", in: menu, enabled: !controller.busy) { [weak controller] in controller?.showPermissions() }
        action("Open Privacy Settings…", in: menu, enabled: !controller.busy) { PermissionGuide.openPrivacy() }
        menu.addItem(.separator())
        action("Quit TranslateBar", in: menu, perform: quit)
    }

    private func label(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
        return menu
    }
    @discardableResult private func action(_ title: String, in menu: NSMenu, enabled: Bool = true,
                                          perform: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, perform: perform)
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let perform: () -> Void
    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Programmatic menus only") }
    @objc private func invoke() { perform() }
}
