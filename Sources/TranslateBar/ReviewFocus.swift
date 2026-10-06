import AppKit
import ApplicationServices

@MainActor
protocol ReviewFocusRestoring {
    func restore(_ context: AppContext, selection: CFRange?) async throws
}

@MainActor
struct OriginalAppFocusRestorer: ReviewFocusRestoring {
    func restore(_ context: AppContext, selection: CFRange?) async throws {
        // The panel is already hidden. Never activate a different app after the
        // user has switched away, or restore a changed caret/selection by force.
        try Task.checkCancellation()
        try context.requireFocus()
        try context.requireSelection(selection)
        guard let original = NSRunningApplication(processIdentifier: context.pid) else {
            throw AppFailure.focusChanged
        }
        _ = original.activate(options: [])
        if let window = context.window {
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if result != .success { Timing.event("reviewWindowRaiseUnavailable") }
        }
        // Allow WindowServer to finish transferring key focus after orderOut.
        try await Task.sleep(for: .milliseconds(120))
        guard NSApp.keyWindow == nil else { throw AppFailure.focusChanged }
        try context.requireFocus()
        try context.requireSelection(selection)
        Timing.event("reviewFocusRestored")
    }
}

extension AppContext {
    func requireSelection(_ selection: CFRange?) throws {
        guard let selection else { return }
        guard let current = AXRead.range(element), current.location == selection.location,
              current.length == selection.length else { throw AppFailure.focusChanged }
    }
}
