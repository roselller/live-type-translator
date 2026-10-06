import AppKit
import ApplicationServices

@MainActor
protocol KeystrokePosting {
    var requiresModifierRelease: Bool { get }
    func waitForModifiers() async throws
    func post(_ stroke: KeyStroke, to context: AppContext) async throws
}

@MainActor
struct EventPoster: KeystrokePosting {
    nonisolated static let tag: Int64 = 0x5452414E534C
    static var permitted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    private let source: CGEventSource?
    let requiresModifierRelease: Bool

    init(waitForRelease: Bool = UserDefaults.standard.bool(forKey: "WaitForShortcutRelease")) {
        let isolated = CGEventSource(stateID: .privateState)
        source = isolated ?? CGEventSource(stateID: .combinedSessionState)
        requiresModifierRelease = waitForRelease || isolated == nil
    }

    func waitForModifiers() async throws {
        guard requiresModifierRelease else {
            Timing.event("privateModifierState")
            return
        }
        let start = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            // Read hardware state, not flags left by our own synthetic Cmd+C.
            let held = ModifierReleasePolicy.held(CGEventSource.flagsState(.hidSystemState))
            switch ModifierReleasePolicy.action(flags: held, elapsed: start.duration(to: .now)) {
            case .ready: return
            case .wait: try await Task.sleep(for: .milliseconds(20))
            case .timeout:
                Timing.event("modifierReleaseTimeout", count: Int(held.rawValue))
                for name in ModifierReleasePolicy.names(held) { Timing.event(name) }
                throw AppFailure.modifiersHeld
            }
        }
    }

    func post(_ stroke: KeyStroke, to context: AppContext) async throws {
        try Task.checkCancellation()
        guard Self.permitted else { throw AppFailure.accessibility }
        if requiresModifierRelease { try await waitForModifiers() }
        try context.requireFocus()
        guard let source else { throw AppFailure.accessibility }
        let (down, up) = try Self.makeEvents(stroke, source: source)
        // UNVERIFIED per editor: private state isolates the event flags, but an
        // editor could separately query hardware modifiers. Use the documented
        // WaitForShortcutRelease fallback if held-key manual tests fail.
        down.post(tap: .cghidEventTap)
        // Always pair key-up even if cancellation arrives during the interval.
        do { try await Task.sleep(for: .milliseconds(15)) }
        catch { up.post(tap: .cghidEventTap); throw error }
        up.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(45))
    }

    static func makeEvents(_ stroke: KeyStroke, source: CGEventSource) throws -> (CGEvent, CGEvent) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: stroke.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: stroke.key, keyDown: false)
        else { throw AppFailure.accessibility }
        for event in [down, up] {
            event.flags = stroke.flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        }
        return (down, up)
    }
}

enum ModifierReleasePolicy {
    enum Action { case ready, wait, timeout }
    static let mask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    static func held(_ flags: CGEventFlags) -> CGEventFlags { flags.intersection(mask) }
    static func action(flags: CGEventFlags, elapsed: Duration) -> Action {
        if held(flags).isEmpty { return .ready }
        return elapsed < .seconds(3) ? .wait : .timeout
    }
    static func names(_ flags: CGEventFlags) -> [String] {
        let labels: [(CGEventFlags, String)] = [
            (.maskCommand, "modifierHeldCommand"), (.maskControl, "modifierHeldControl"),
            (.maskAlternate, "modifierHeldOption"), (.maskShift, "modifierHeldShift"),
            (.maskSecondaryFn, "modifierHeldFn")
        ]
        return labels.compactMap { flags.contains($0.0) ? $0.1 : nil }
    }
}
