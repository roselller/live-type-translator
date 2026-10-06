import AppKit

@MainActor
final class CaptureInsert {
    private let events: any KeystrokePosting
    init(events: any KeystrokePosting = EventPoster()) { self.events = events }
    var waitsForModifiers: Bool { events.requiresModifierRelease }

    func capture(context: AppContext, watch: InputWatch, timing: Timing) async throws -> String {
        guard let text = try await captureText(context: context, watch: watch, timing: timing, allowFallback: true)
        else { throw AppFailure.noText }
        return text
    }

    func validateDestination(context: AppContext, watch: InputWatch, timing: Timing) async throws {
        // Recent results use a fresh destination. Inspect an existing selection
        // for tables, but never expand a caret into a paragraph or whole field.
        _ = try await captureText(context: context, watch: watch, timing: timing, allowFallback: false)
    }

    private func captureText(context: AppContext, watch: InputWatch, timing: Timing,
                             allowFallback: Bool) async throws -> String? {
        try await events.waitForModifiers()
        timing.mark("modifiersReady")
        try watch.requireUninterrupted()
        try context.requireFocus()
        let clipboard = try PasteboardSession()
        timing.mark("snapshotDone")
        var restoreError: (any Error)?
        let outcome: Result<String?, any Error>
        do {
            try clipboard.requireUnchanged()
            var copied = try await copy(context: context, watch: watch, clipboard: clipboard, timing: timing)
            if !copied && allowFallback {
                let strokes = context.rule.mode == .chat ? [.selectAll] : context.rule.paragraphSelection
                for stroke in strokes {
                    try watch.requireUninterrupted()
                    try await events.post(stroke, to: context)
                }
                copied = try await copy(context: context, watch: watch, clipboard: clipboard, timing: timing)
            }
            if copied { outcome = .success(try clipboard.acceptCopy()) }
            else if allowFallback { throw AppFailure.noText }
            else { outcome = .success(nil) }
        } catch { outcome = .failure(error) }
        do {
            let result = try clipboard.restore()
            timing.mark(result == .newerClipboardKept ? "newerClipboardKept" : "restoreDone")
        } catch { restoreError = error }
        if let restoreError { throw restoreError }
        return try outcome.get()
    }

    private func copy(context: AppContext, watch: InputWatch, clipboard: PasteboardSession, timing: Timing) async throws -> Bool {
        try watch.requireUninterrupted()
        let before = NSPasteboard.general.changeCount
        defer {
            // Preserve a copy completed just as cancellation arrived. Never
            // claim a newer clipboard if the user interacted in the meantime.
            if !watch.interrupted { clipboard.recordCopyChange() }
        }
        try await events.post(.copy, to: context)
        timing.mark("copyIssued")
        let deadline = ContinuousClock.now + .milliseconds(500)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try watch.requireUninterrupted()
            try context.requireFocus()
            if NSPasteboard.general.changeCount != before {
                clipboard.recordCopyChange()
                timing.mark("pasteboardChanged")
                return true
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func insert(_ result: TranslationResult, context: AppContext, watch: InputWatch,
                selection: CFRange?, timing: Timing) async throws {
        guard !result.translations.isEmpty,
              result.translations.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw AppFailure.invalidResult }
        try watch.requireUninterrupted()
        try context.requireFocus()
        try context.requireSelection(selection)
        let clipboard = try PasteboardSession()
        var pendingError: (any Error)?
        do {
            let provider = try clipboard.writePayload(result.pastePayload)
            try watch.requireUninterrupted()
            // Right Arrow collapses to the end, preserving the original. Never Return.
            try await events.post(.right, to: context)
            try watch.requireUninterrupted()
            if let range = AXRead.range(context.element), range.length != 0 {
                throw AppFailure.focusChanged
            }
            try clipboard.requireUnchanged()
            try Task.checkCancellation()
            let delivery = Task { @MainActor in
                try watch.requireUninterrupted()
                try await events.post(.paste, to: context)
            }
            try await delivery.value
            timing.mark("pasteIssued")
            // Once paste is posted, cleanup must complete even if cancellation occurs.
            // The provider proves a reader asked for text, not which reader consumed it.
            let deadline = ContinuousClock.now + context.rule.pasteTimeout
            while !provider.wasRequested && ContinuousClock.now < deadline {
                await Self.cleanupDelay(.milliseconds(20))
            }
            if provider.wasRequested {
                timing.mark("pasteDataRequested")
                await Self.cleanupDelay(.milliseconds(150))
            } else {
                timing.mark("pasteConsumptionTimeout")
                pendingError = AppFailure.pasteUnconfirmed
            }
        } catch { pendingError = error }
        do {
            let restored = try clipboard.restore()
            timing.mark(restored == .newerClipboardKept ? "newerClipboardKept" : "restoreDone")
        } catch { pendingError = error }
        if let pendingError { throw pendingError }
    }

    private static func cleanupDelay(_ duration: Duration) async {
        // Detached sleep is independent of an already-cancelled parent, and always joined.
        await Task.detached { try? await Task.sleep(for: duration) }.value
    }
}
