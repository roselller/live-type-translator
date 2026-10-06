import AppKit

/// A developer-only UI check using fixed fixtures. It never captures source
/// text, generates a model response, reads the clipboard, or posts global keys.
@MainActor
enum ReviewSmoke {
    static func run() async -> Bool {
        try? await Task.sleep(for: .milliseconds(400)) // Finish ordinary AppKit launch first.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            print("Review smoke: FAILED; no external foreground app")
            return false
        }
        let activation = ActivationProbe(originalPID: pid)
        defer { activation.stop() }
        let request = TranslationRequest(source: "Please review the plan.\nThank you for your help.")
        let fixture = TranslationResult(translations: [
            .init(language: .japanese, text: "計画をご確認ください。\nご協力ありがとうございます。",
                  notes: ["The wording is polite and suitable for a group message."],
                  phrases: [.init(source: "plan", used: "計画", alternatives: ["提案", "案"])]),
            .init(language: .korean, text: "계획을 검토해 주십시오.\n도움을 주셔서 감사합니다.", notes: [], phrases: [])
        ])
        do {
            for mode in 0..<8 {
                let review = ReviewPanelController()
                let pending = Task { @MainActor in try await review.present(fixture, request: request, originalPID: pid) }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    print("Review smoke state: case=\(mode) visible=\(review.isVisible) key=\(review.panel?.isKeyWindow == true) appkit_active=\(NSApp.isActive) foreground_preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) activation_changed=\(activation.changed)")
                    guard let panel = review.panel, let state = review.state, review.isVisible,
                          panel.isKeyWindow, !activation.changed,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        throw SmokeFailure.check
                    }
                    if mode == 0 {
                        guard let phrase = state.document.current.highlights.first,
                              let text = textView(in: panel.contentView) else { throw SmokeFailure.check }
                        _ = text.delegate?.textView?(text, clickedOnLink: "translatebar://phrase/\(phrase.id.uuidString)", at: phrase.range.location)
                        guard state.selectedPhrase == phrase.id else { throw SmokeFailure.check }
                        state.choose("提案", for: phrase.id)
                        try await Task.sleep(for: .milliseconds(200))
                        if let index = CommandLine.arguments.firstIndex(of: "--review-snapshot"),
                           CommandLine.arguments.indices.contains(index + 1) {
                            try saveSnapshot(panel, to: CommandLine.arguments[index + 1])
                        }
                        send(.keyDown, key: 0x24, to: panel)
                        send(.keyDown, key: 0x24, repeated: true, to: panel)
                        guard review.isVisible else { throw SmokeFailure.check }
                        send(.keyUp, key: 0x24, to: panel)
                    } else if mode == 1 {
                        send(.keyDown, key: 0x7C, to: panel)
                        send(.keyUp, key: 0x7C, to: panel)
                        guard state.document.current.language == .korean else { throw SmokeFailure.check }
                        send(.keyDown, key: 0x24, flags: [.option], to: panel)
                        send(.keyUp, key: 0x24, to: panel)
                    } else if mode == 2 {
                        send(.keyDown, key: 0x35, to: panel)
                        send(.keyUp, key: 0x35, to: panel)
                    } else if mode == 3 {
                        pending.cancel()
                    } else if mode == 4 {
                        review.cancel(AppFailure.focusChanged)
                    } else if mode == 5 {
                        send(.keyDown, key: 0x24, to: panel)
                        guard let close = panel.standardWindowButton(.closeButton), close.isEnabled else { throw SmokeFailure.check }
                        close.performClick(nil)
                        send(.keyUp, key: 0x24, to: panel)
                    } else if mode == 6 {
                        panel.close()
                    } else {
                        panel.performClose(nil)
                    }
                    if mode >= 5, review.isVisible || review.state != nil { throw SmokeFailure.check }
                    do {
                        let result = try await pending.value
                        guard mode < 2, result.translations.count == (mode == 0 ? 2 : 1) else { throw SmokeFailure.check }
                        if mode == 0, !result.pastePayload.contains("提案") { throw SmokeFailure.check }
                        if mode == 1, result.translations.first?.language != .korean { throw SmokeFailure.check }
                    } catch is CancellationError {
                        guard mode == 2 || mode == 3 || mode >= 5 else { throw SmokeFailure.check }
                    } catch AppFailure.focusChanged {
                        guard mode == 4 else { throw SmokeFailure.check }
                    }
                    try await Task.sleep(for: .milliseconds(120))
                    guard !review.isVisible, review.state == nil, NSApp.keyWindow == nil, !activation.changed,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw SmokeFailure.check }
                    review.handle(.insertAll) // Completed/cancelled reviews cannot insert twice.
                    print("Review smoke: PASS case=\(mode) hidden=true key_released=true foreground_preserved=true")
                } catch {
                    review.cancel()
                    _ = await pending.result
                    throw error
                }
            }
            return true
        } catch {
            print("Review smoke: FAILED; panel lifecycle check")
            return false
        }
    }

    private enum SmokeFailure: Error { case check }

    @MainActor private final class ActivationProbe {
        var changed = false
        private var observer: NSObjectProtocol?
        init(originalPID: pid_t) {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if pid != originalPID { self?.changed = true } }
            }
        }
        func stop() {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
        }
    }

    private static func send(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags = [],
                             repeated: Bool = false, to panel: ReviewPanel) {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeated, keyCode: key) else { return }
        panel.sendEvent(event) // Directly to our panel; never to the source app.
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private static func saveSnapshot(_ panel: NSPanel, to path: String) throws {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SmokeFailure.check }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SmokeFailure.check }
        // This mode can only display the fixed fixture above, never user text.
        try data.write(to: URL(filePath: path))
    }
}
