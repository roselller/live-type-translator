import AppKit
import ApplicationServices

enum AppMode: String, Codable { case chat, document }
struct KeyStroke: Sendable {
    var key: CGKeyCode
    var flags: CGEventFlags = []
    static let copy = Self(key: 0x08, flags: .maskCommand)
    static let selectAll = Self(key: 0x00, flags: .maskCommand)
    static let right = Self(key: 0x7C)
    static let paste = Self(key: 0x09, flags: .maskCommand)
}

struct AppRule {
    var bundleID: String
    var titlePattern: String? = nil
    var mode: AppMode
    var paragraphSelection: [KeyStroke] = [
        .init(key: 0x7E, flags: .maskAlternate),
        .init(key: 0x7D, flags: [.maskAlternate, .maskShift])
    ]
    var pasteTimeout: Duration = .milliseconds(1500)
}

protocol RuleStore {
    func rule(bundleID: String, title: String?) -> AppRule
    func usesWindowTitle(bundleID: String) -> Bool
}

@MainActor
enum AXRead {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func range(_ element: AXUIElement?) -> CFRange? {
        guard let element, let value = value(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

@MainActor
struct AppContext {
    var pid: pid_t
    var app: AXUIElement
    var window: AXUIElement?
    var element: AXUIElement?
    var rule: AppRule

    static func capture(rules: any RuleStore = RulesConfiguration.seed) throws -> Self {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw AppFailure.focusChanged }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        let window = AXRead.element(app, kAXFocusedWindowAttribute)
        let element = AXRead.element(app, kAXFocusedUIElementAttribute)
        if let element, AXRead.value(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
            throw AppFailure.secureField
        }
        let bundleID = front.bundleIdentifier ?? ""
        let title = rules.usesWindowTitle(bundleID: bundleID)
            ? window.flatMap { AXRead.value($0, kAXTitleAttribute) as? String } : nil
        if rules.usesWindowTitle(bundleID: bundleID), title == nil { Timing.event("focusedTitleUnavailable") }
        if window == nil { Timing.event("focusedWindowUnavailable") }
        return Self(pid: front.processIdentifier, app: app, window: window, element: element,
                    rule: rules.rule(bundleID: bundleID, title: title))
    }

    func requireFocus() throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw AppFailure.focusChanged }
        if let window {
            guard let current = AXRead.element(app, kAXFocusedWindowAttribute), CFEqual(window, current) else {
                throw AppFailure.focusChanged
            }
        }
        if let element {
            guard let current = AXRead.element(app, kAXFocusedUIElementAttribute), CFEqual(element, current) else {
                throw AppFailure.focusChanged
            }
        }
    }
}

@MainActor
final class InputWatch {
    private var monitor: Any?
    private var activation: NSObjectProtocol?
    private(set) var interrupted = false
    var onInterruption: (() -> Void)?

    init(context: AppContext, shortcut: GlobalShortcut? = .standard) throws {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let targetPID = event.cgEvent?.getIntegerValueField(.eventTargetUnixProcessID)
            let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
            // Global monitors normally exclude our events. Also check delivery
            // ownership explicitly; do not ignore a click just because it is
            // geometrically over the mouse-transparent pointer badge.
            let ownWindow = event.window.map { window in NSApp.windows.contains { $0 === window } } ?? false
            let input = GuardInput(type: event.type, keyCode: event.type == .keyDown ? event.keyCode : nil,
                flags: event.modifierFlags,
                isSynthetic: event.cgEvent?.getIntegerValueField(.eventSourceUserData) == EventPoster.tag,
                targetsOwnWindow: targetPID == ownPID || ownWindow)
            guard InputGuardPolicy.shouldInterrupt(input, shortcut: shortcut) else { return }
            self?.interrupt(event.type == .keyDown ? "guardKeystroke" : "guardOutsideClick")
        }
        guard monitor != nil else { throw AppFailure.accessibility }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if InputGuardPolicy.focusChanged(originalPID: context.pid, currentPID: pid) {
                    self?.interrupt("guardFocusChanged")
                }
            }
        }
    }

    private func interrupt(_ event: String) {
        guard !interrupted else { return }
        interrupted = true
        Timing.event(event)
        onInterruption?()
    }

    func requireUninterrupted() throws {
        if interrupted { throw AppFailure.focusChanged }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        monitor = nil
        activation = nil
        onInterruption = nil
    }
}

struct GuardInput {
    var type: NSEvent.EventType
    var keyCode: UInt16? = nil
    var flags: NSEvent.ModifierFlags = []
    var isSynthetic = false
    var targetsOwnWindow = false
}

enum InputGuardPolicy {
    static func shouldInterrupt(_ input: GuardInput, shortcut: GlobalShortcut? = .standard) -> Bool {
        guard !input.isSynthetic, !input.targetsOwnWindow else { return false }
        switch input.type {
        case .keyDown:
            // Holding/repeating the registered shortcut cannot start a second
            // operation. Caps Lock does not change which shortcut was pressed.
            return shortcut?.matches(keyCode: input.keyCode, flags: input.flags) != true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        default: return false // Scrolling, pointer motion, and key releases.
        }
    }

    static func focusChanged(originalPID: pid_t, currentPID: pid_t?) -> Bool {
        currentPID != originalPID // Unknown focus also fails closed.
    }
}
