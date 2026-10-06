import AppKit
import SwiftUI

enum ReviewAction: Equatable { case cancel, insertAll, insertCurrent, previousLanguage, nextLanguage }

struct ReviewKeyboardState {
    private var pending: (key: UInt16, action: ReviewAction)?

    mutating func handle(type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags,
                         repeated: Bool = false) -> (handled: Bool, action: ReviewAction?) {
        // Complete Return/Esc on release so a held key cannot repeat into the
        // source editor after the panel disappears. No global event tap is used.
        if type == .keyUp, let pending, pending.key == key {
            self.pending = nil
            return (true, pending.action)
        }
        let modifiers = flags.intersection([.command, .control, .option, .shift])
        let action: ReviewAction?
        switch (key, modifiers) {
        case (0x35, []): action = .cancel
        case (0x24, []), (0x4C, []): action = .insertAll
        case (0x24, [.option]), (0x4C, [.option]): action = .insertCurrent
        case (0x7B, []): action = .previousLanguage
        case (0x7C, []): action = .nextLanguage
        default: action = nil
        }
        guard let action else { return (false, nil) }
        guard type == .keyDown else { return (true, nil) }
        if action == .previousLanguage || action == .nextLanguage { return (true, action) }
        if !repeated, pending == nil { pending = (key, action) }
        return (true, nil)
    }
}

@MainActor
final class ReviewPanel: NSPanel {
    var onAction: ((ReviewAction) -> Void)?
    private var keyboard = ReviewKeyboardState()
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp {
            let response = keyboard.handle(type: event.type, key: event.keyCode, flags: event.modifierFlags,
                                           repeated: event.type == .keyDown && event.isARepeat)
            if let action = response.action { onAction?(action) }
            if response.handled { return }
        }
        super.sendEvent(event)
    }

    override func performClose(_ sender: Any?) { onAction?(.cancel) }

    override func close() {
        // Closing the native window must resolve the pending review as well as
        // hide it. Otherwise the app stays busy, waiting for an invisible panel.
        if let onAction { onAction(.cancel) } else { super.close() }
    }

    @objc func cancelFromCloseButton(_ sender: Any?) { onAction?(.cancel) }
}

enum ReviewPlacement {
    static func frame(near point: NSPoint, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(560, max(1, bounds.width)), height: min(640, max(1, bounds.height)))
        return NSRect(x: min(max(point.x + 18, bounds.minX), bounds.maxX - size.width),
                      y: min(max(point.y - size.height - 18, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

@MainActor @Observable
final class ReviewViewState {
    var document: ReviewDocument
    var selectedPhrase: UUID?
    var errorMessage: String?
    var hasMultipleSourceLines = false
    init(_ result: TranslationResult) { document = ReviewDocument(result) }
    func select(_ index: Int) { document.select(index); selectedPhrase = nil; errorMessage = nil }
    func moveLanguage(by offset: Int) { document.moveLanguage(by: offset); selectedPhrase = nil; errorMessage = nil }
    func choose(_ value: String, for id: UUID) {
        if document.choose(value, for: id) { errorMessage = nil }
    }
}

@MainActor
final class ReviewPanelController {
    private(set) var panel: ReviewPanel?
    private(set) var state: ReviewViewState?
    private var request: TranslationRequest?
    private var onClose: ((TranslationResult) -> Void)?
    private var continuation: CheckedContinuation<TranslationResult, any Error>?
    var isVisible: Bool { panel?.isVisible == true }

    func present(_ result: TranslationResult, request: TranslationRequest, originalPID: pid_t,
                 fromHistory: Bool = false, onClose: ((TranslationResult) -> Void)? = nil) async throws -> TranslationResult {
        try Task.checkCancellation()
        guard continuation == nil, !result.translations.isEmpty else { throw AppFailure.invalidResult }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.request = request
                self.onClose = onClose
                let state = ReviewViewState(result)
                state.hasMultipleSourceLines = TranslationLayout(request.source).contentIndices.count > 1
                self.state = state
                let point = NSEvent.mouseLocation
                let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame
                    ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
                let panel = ReviewPanel(contentRect: .zero,
                    styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "TranslateBar — Review"
                panel.isReleasedWhenClosed = false
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.hidesOnDeactivate = false
                panel.becomesKeyOnlyIfNeeded = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                panel.contentView = NSHostingView(rootView: ReviewView(state: state, fromHistory: fromHistory) { [weak self] in self?.handle($0) })
                panel.setFrame(ReviewPlacement.frame(near: point, visibleFrame: visible), display: false)
                panel.onAction = { [weak self] in self?.handle($0) }
                // A nonactivating floating panel needs an explicit close target;
                // do not depend on the foreground app's responder chain.
                if let close = panel.standardWindowButton(.closeButton) {
                    close.target = panel
                    close.action = #selector(ReviewPanel.cancelFromCloseButton(_:))
                    close.isEnabled = true
                }
                self.panel = panel
                panel.orderFrontRegardless()
                panel.makeKey() // A nonactivating panel can be key without activating TranslateBar.
                guard panel.isKeyWindow,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == originalPID else {
                    cancel(AppFailure.reviewUnavailable)
                    return
                }
                Timing.event("reviewShown")
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func handle(_ action: ReviewAction) {
        guard let state else { return }
        switch action {
        case .cancel: cancel()
        case .previousLanguage: state.moveLanguage(by: -1)
        case .nextLanguage: state.moveLanguage(by: 1)
        case .insertAll, .insertCurrent:
            let result = state.document.result(for: action == .insertAll ? .all : .current)
            guard var request else { return }
            request.languages = result.translations.map(\.language)
            do {
                let checked = try result.validated(for: request)
                finish(.success(checked))
            } catch {
                state.errorMessage = "This alternative does not match the text's language or line structure. Choose another, or cancel."
            }
        }
    }

    func cancel(_ error: any Error = CancellationError()) { finish(.failure(error)) }

    private func finish(_ outcome: Result<TranslationResult, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.orderOut(nil) // Must happen before any focus handoff or paste.
        if let state { onClose?(state.document.result(for: .all)) }
        onClose = nil
        panel?.onAction = nil
        panel?.contentView = nil
        panel = nil
        state = nil
        request = nil
        Timing.event("reviewHidden")
        continuation.resume(with: outcome)
    }
}

private struct ReviewView: View {
    @Bindable var state: ReviewViewState
    var fromHistory = false
    let action: (ReviewAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "character.bubble").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fromHistory ? "Review a recent translation" : "Review your translation").font(.headline)
                    Text(fromHistory ? "Insert below your current selection or at your current cursor." : "Your English stays. Translations will be added below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !fromHistory && state.hasMultipleSourceLines {
                Text("Translations follow the whole selection. For paragraph pairs, select and translate one paragraph at a time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Language", selection: Binding(get: { state.document.currentIndex }, set: state.select)) {
                ForEach(state.document.translations.indices, id: \.self) { index in
                    Text(state.document.translations[index].language.displayName).tag(index)
                }
            }.pickerStyle(.segmented).labelsHidden()
            HighlightedTranslation(translation: state.document.current, selected: state.selectedPhrase) {
                state.selectedPhrase = $0
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.2)) }

            VStack(alignment: .leading, spacing: 5) {
                Text("Notes").font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if state.document.current.notes.isEmpty {
                            Text("No notes for this translation.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(state.document.current.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 55)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let phrase = state.document.current.highlights.first(where: { $0.id == state.selectedPhrase }) {
                    Text("Alternatives for “\(phrase.source)”").font(.subheadline.bold()).lineLimit(2)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(phrase.choices, id: \.self) { choice in
                                Button { state.choose(choice, for: phrase.id) } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: currentChoice(phrase) == choice ? "checkmark.circle.fill" : "circle")
                                        Text(choice).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(.vertical, 2)
                                }.buttonStyle(.plain).foregroundStyle(currentChoice(phrase) == choice ? Color.accentColor : .primary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(state.document.current.highlights.isEmpty ? "No phrases flagged for alternatives." : "Click a highlighted phrase to compare alternatives.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.frame(height: 110, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)

            if let error = state.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if state.document.usedContextFallback {
                Text("Long text required a separate model call per language.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Cancel") { action(.cancel) }
                Spacer()
                Button("Insert \(state.document.current.language.displayName)") { action(.insertCurrent) }
                Button("Insert all") { action(.insertAll) }.buttonStyle(.borderedProminent)
            }
            Text("Return: insert all   ·   Option–Return: current   ·   Esc: cancel   ·   ← →: languages")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18)
    }

    private func currentChoice(_ phrase: ReviewHighlight) -> String {
        (state.document.current.text as NSString).substring(with: phrase.range)
    }
}

private struct HighlightedTranslation: NSViewRepresentable {
    let translation: ReviewedTranslation
    let selected: UUID?
    let choose: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(choose: choose) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 10, height: 12)
        text.delegate = context.coordinator
        text.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.choose = choose
        guard let text = scroll.documentView as? NSTextView else { return }
        let content = NSMutableAttributedString(string: translation.text, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor
        ])
        for phrase in translation.highlights {
            content.addAttributes([
                .link: "translatebar://phrase/\(phrase.id.uuidString)",
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(phrase.id == selected ? 0.22 : 0.09)
            ], range: phrase.range)
        }
        if text.attributedString() != content { text.textStorage?.setAttributedString(content) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var choose: (UUID) -> Void
        init(choose: @escaping (UUID) -> Void) { self.choose = choose }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let value = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            if let value, value.scheme == "translatebar", let id = UUID(uuidString: value.lastPathComponent) { choose(id) }
            return true // Never hand these internal links to a browser or network.
        }
    }
}
