import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import FoundationModels

@main
enum EntryPoint {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--smoke-shortcuts") {
            NSApplication.shared.setActivationPolicy(.accessory)
            exit(ShortcutSmoke.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--benchmark-model") {
            exit(await ModelBenchmark.run() ? 0 : 1)
        }
        if CommandLine.arguments.contains("--smoke-settings") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in exit(await SettingsSmoke.run() ? 0 : 1) }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--smoke-review") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in exit(await ReviewSmoke.run() ? 0 : 1) }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--diagnostics") {
            print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("Accessibility: \(AXIsProcessTrusted()); event posting: \(CGPreflightPostEventAccess())")
            do { try FoundationModelsEngine.checkAvailability(); print("Model: available") }
            catch { print("Model: \((error as? AppFailure)?.errorDescription ?? "unavailable")") }
            let model = SystemLanguageModel.default
            print("Context capacity: \(model.contextSize) tokens")
            for language in TargetLanguage.allCases {
                print("Supports \(language.rawValue): \(model.supportsLocale(Locale(identifier: language.rawValue)))")
            }
            return
        }
        if CommandLine.arguments.contains("--smoke-model") {
            // Fixed fixture only; no clipboard reads or source/result prints.
            let timing = Timing()
            do {
                let engine = FoundationModelsEngine()
                // Fixed-fixture benchmark only. Immediate prewarm recreates
                // Phase 1's schedule; default gives launch warmup two seconds.
                engine.prewarm()
                let immediate = CommandLine.arguments.contains("--immediate-prewarm")
                if !immediate { try await Task.sleep(for: .seconds(2)) }
                engine.prewarm() // Same call made when the shortcut fires.
                print("Model smoke preparation: \(immediate ? "immediate" : "2000ms lead")")
                let generation = Timing()
                let result = try await engine.translate(
                    TranslationRequest(source: "Thank you for your help. Please review the proposal.",
                        languages: CommandLine.arguments.contains("--three-targets")
                            ? [.traditionalChinese, .simplifiedChinese, .japanese] : TargetLanguage.phaseOne))
                print("Model smoke: PASS; languages=\(result.translations.count); calls=\(result.modelCalls)")
                print("Model smoke generation_ms=\(String(format: "%.2f", generation.elapsedMilliseconds))")
                timing.mark("smokeModelDone")
            } catch {
                print("Model smoke: FAILED; \((error as? AppFailure)?.errorDescription ?? "Cancelled")")
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--check-model-stdin") {
            // Developer reproduction harness: input arrives through stdin, stays
            // in memory, and is never echoed, logged, saved, copied, or pasted.
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let source = String(data: data, encoding: .utf8), !source.isEmpty else { exit(1) }
            var languages = TargetLanguage.phaseOne
            if let index = CommandLine.arguments.firstIndex(of: "--language") {
                guard CommandLine.arguments.indices.contains(index + 1),
                      let language = TargetLanguage(rawValue: CommandLine.arguments[index + 1]) else { exit(1) }
                languages = [language]
            }
            let repetitions = CommandLine.arguments.contains("--repeat-three") ? 3 : 1
            for attempt in 1...repetitions {
                let timing = Timing()
                do {
                    let engine = FoundationModelsEngine()
                    engine.prewarm()
                    try await Task.sleep(for: .seconds(2))
                    let result = try await engine.translate(TranslationRequest(source: source, languages: languages))
                    print("Input check: PASS run=\(attempt) source_lines=\(TranslationLayout(source).sourceLines.count) languages=\(result.translations.count) calls=\(result.modelCalls) elapsed_ms=\(String(format: "%.2f", timing.elapsedMilliseconds))")
                } catch {
                    print("Input check: FAILED run=\(attempt); \((error as? AppFailure)?.errorDescription ?? "Cancelled")")
                    exit(1)
                }
            }
            return
        }
        TranslateBarApp.main()
    }
}

struct TranslateBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(controller: controller) { [weak self] in self?.quitSafely() }
        controller.prewarmAtLaunch()
        controller.registerShortcutAtLaunch()
        if !EventPoster.permitted { controller.showPermissions() }
        Timing.event("appLaunched")
    }

    func quitSafely() {
        Task { @MainActor in
            controller.cancel()
            await controller.waitUntilIdle()
            controller.unregisterShortcut()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.busy else { return .terminateNow }
        Task { @MainActor in
            controller.cancel()
            await controller.waitUntilIdle()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor @Observable
final class AppController {
    var status = "Ready"
    private(set) var shortcutWarning: String?
    private(set) var activeShortcut: GlobalShortcut?
    var busy = false
    let settings: SettingsStore
    let recent = RecentResults()
    let settingsPanel = SettingsPanelController()
    private var settingsOpening = false
    var canStart: Bool { !busy && !settingsOpening && !settingsPanel.isVisible }
    private let hotkey: any HotkeyManager

    init(settings: SettingsStore = SettingsStore(), hotkey: any HotkeyManager = CarbonHotkeyManager()) {
        self.settings = settings
        self.hotkey = hotkey
        status = "Ready — \(settings.shortcut.displayName)"
    }

    func registerShortcutAtLaunch() {
        do {
            guard !settings.unreadableFiles.contains("shortcut.json") else { throw SettingsFailure.read }
            try configureShortcut(settings.shortcut, save: false)
        } catch {
            shortcutWarning = "Shortcut unavailable — open Settings. Translate now still works."
            showFailure(error)
        }
    }
    func saveShortcut(_ shortcut: GlobalShortcut) throws {
        guard !busy else { throw ShortcutFailure.unavailable }
        try configureShortcut(shortcut, save: true)
        status = "Shortcut saved — \(shortcut.displayName)"
    }
    private func configureShortcut(_ shortcut: GlobalShortcut, save: Bool) throws {
        try hotkey.register(shortcut, persist: { if save { try settings.saveShortcut(shortcut) } }) { [weak self] in
            guard let self else { return }
            if !self.settingsPanel.recordActiveShortcut(shortcut) { self.start() }
        }
        activeShortcut = shortcut
        shortcutWarning = nil
    }
    func unregisterShortcut() { hotkey.unregister(); activeShortcut = nil }

    func showSettings() {
        guard !busy, !settingsOpening else { return }
        settingsOpening = true
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(120))
            settingsPanel.show(store: settings) { [weak self] shortcut in
                guard let self else { throw ShortcutFailure.unavailable }
                try self.saveShortcut(shortcut)
            }
            settingsOpening = false
        }
    }
    func changeLanguage(_ language: TargetLanguage) {
        guard canStart else { return }
        do { try settings.toggle(language); status = "Languages saved." }
        catch { showFailure(error) }
    }
    func overrideApp(bundleID: String, mode: AppMode) {
        guard canStart else { return }
        do { try settings.override(bundleID: bundleID, mode: mode); status = "App override saved." }
        catch { showFailure(error) }
    }
    func reopen(_ id: UUID) {
        guard let entry = recent.entries.first(where: { $0.id == id }) else { return }
        run(recentEntry: entry, fromMenu: true)
    }
    private var task: Task<Void, Never>?
    private let engine: any TranslationEngine = FoundationModelsEngine()
    private let captureInsert = CaptureInsert()
    private let permissions = PermissionGuide()
    private let indicator = ActivityIndicator()
    private let review = ReviewPanelController()
    private let reviewFocus: any ReviewFocusRestoring = OriginalAppFocusRestorer()

    func showPermissions() { permissions.show(shortcut: settings.shortcut.displayName) }
    func cancel() { task?.cancel(); review.cancel() }
    func waitUntilIdle() async { await task?.value }
    func prewarmAtLaunch() {
        engine.prewarm()
        Timing.event("launchPrewarm")
    }

    func start(fromMenu: Bool = false) { run(recentEntry: nil, fromMenu: fromMenu) }

    private func run(recentEntry: RecentResult?, fromMenu: Bool) {
        guard canStart else { return }
        guard settings.translationSettingsReadable else { showFailure(SettingsFailure.read); showSettings(); return }
        let languages = settings.selection.languages
        let profile = settings.profile
        let timing = Timing()
        timing.mark("hotkeyFired")
        if recentEntry == nil { engine.prewarm(); timing.mark("shortcutPrewarm") }
        guard EventPoster.permitted else { showPermissions(); return }
        permissions.hide()
        let context: AppContext
        do {
            if recentEntry == nil { try FoundationModelsEngine.checkAvailability() }
            context = try AppContext.capture(rules: settings.rules)
        } catch { showFailure(error); return }
        timing.mark("appTypeResolved", count: context.rule.mode == .chat ? 1 : 0)
        let recentSelection = AXRead.range(context.element)
        busy = true
        status = recentEntry == nil ? "Capturing…" : "Opening recent translation…"
        if recentEntry == nil { indicator.begin(at: NSEvent.mouseLocation, waitingForModifiers: captureInsert.waitsForModifiers) }
        task = Task { @MainActor [self] in
            defer { review.cancel(); busy = false; timing.mark("total"); task = nil }
            do {
                let watch = try InputWatch(context: context, shortcut: activeShortcut)
                defer { watch.stop() }
                // Let a menu-triggered request finish closing the menu first.
                if fromMenu { try await Task.sleep(for: .milliseconds(120)) }
                let selection: CFRange?
                let request: TranslationRequest
                let result: TranslationResult
                if let recentEntry {
                    try context.requireSelection(recentSelection)
                    try await captureInsert.validateDestination(context: context, watch: watch, timing: timing)
                    try context.requireSelection(recentSelection)
                    selection = recentSelection
                    request = recentEntry.request
                    result = recentEntry.result
                } else {
                    let source = try await captureInsert.capture(context: context, watch: watch, timing: timing)
                    indicator.capturing()
                    selection = AXRead.range(context.element)
                    try Task.checkCancellation()
                    status = "Translating on device… Keep the selection unchanged."
                    indicator.translating()
                    timing.mark("modelStart", count: source.count)
                    request = TranslationRequest(source: source, languages: languages, profile: profile)
                    result = try await engine.translate(request)
                    timing.mark("modelDone", count: result.modelCalls)
                    // Warm a new, unused session while the user reviews this result.
                    // No transcript containing source text is retained or reused.
                    engine.prewarm()
                }
                let entryID = recentEntry?.id ?? recent.add(request: request, result: result)
                try Task.checkCancellation()
                try watch.requireUninterrupted()
                try context.requireFocus()
                try context.requireSelection(selection)
                indicator.hide()
                status = "Review translation — Return inserts all; Option–Return inserts current."
                watch.onInterruption = { [weak self] in self?.review.cancel(AppFailure.focusChanged) }
                let reviewed = try await review.present(result, request: request, originalPID: context.pid,
                    fromHistory: recentEntry != nil, onClose: { [weak self] edited in self?.recent.update(entryID, result: edited) })
                watch.onInterruption = nil
                try Task.checkCancellation()
                try watch.requireUninterrupted()
                try await reviewFocus.restore(context, selection: selection)
                try watch.requireUninterrupted()
                timing.mark("reviewAccepted", count: reviewed.translations.count)
                status = "Inserting…"
                indicator.begin(at: NSEvent.mouseLocation)
                indicator.inserting(contextFallback: reviewed.usedContextFallback)
                try await captureInsert.insert(reviewed, context: context, watch: watch, selection: selection, timing: timing)
                status = reviewed.usedContextFallback
                    ? "Paste requested — used per-language context fallback."
                    : "Paste requested — \(reviewed.translations.map { $0.language.displayName }.joined(separator: ", "))."
                indicator.finish("Done · \(reviewed.translations.count == 1 ? "Translation" : "Translations") added below.")
            } catch is CancellationError {
                status = "Cancelled."
                indicator.fail("Cancelled · no translation was inserted.")
            } catch {
                showFailure(error)
            }
        }
    }

    private func showFailure(_ error: any Error) {
        status = (error as? AppFailure)?.errorDescription ?? (error as? SettingsFailure)?.errorDescription
            ?? (error as? ShortcutFailure)?.errorDescription ?? "Operation failed. Nothing further was inserted."
        indicator.fail(status) // Include preflight failures, before a progress badge exists.
        Timing.event("operationFailed")
        NSSound.beep()
    }

}

@MainActor
final class PermissionGuide {
    private var panel: NSPanel?
    private var polling: Task<Void, Never>?

    static func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }
    func show(shortcut: String) {
        if EventPoster.permitted { hide(); return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "TranslateBar — Accessibility"
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.center()
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: PermissionView(shortcut: shortcut, request: { [weak self] in self?.request() }))
        panel?.orderFrontRegardless()
        polling?.cancel()
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if EventPoster.permitted { self?.hide(); return }
            }
        }
    }
    private func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func hide() { polling?.cancel(); polling = nil; panel?.orderOut(nil) }
}

private struct PermissionView: View {
    var shortcut: String
    var request: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translate the text you choose").font(.headline)
            Text("TranslateBar needs Accessibility to copy text, read the focused window, and paste translations below your English text.")
            Text("Press \(shortcut) and keep the selection unchanged. Review the result, then choose Insert to add it below your English. Nothing is sent automatically.")
                .font(.callout)
            Button("Open Accessibility Settings", action: request)
            Text("Always use the installed app at ~/Applications/TranslateBar.app. Keep the same signing identity when rebuilding.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 440)
    }
}
