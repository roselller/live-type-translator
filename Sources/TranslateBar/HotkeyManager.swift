import Carbon

@MainActor
protocol HotkeyManager: AnyObject {
    var current: GlobalShortcut? { get }
    func register(_ shortcut: GlobalShortcut, persist: () throws -> Void,
                  action: @escaping @MainActor () -> Void) throws
    func unregister()
}

@MainActor
protocol HotkeyRegistration: AnyObject { func cancel() }

/// Keep the working registration until both the candidate and its save succeed.
@MainActor
final class CarbonHotkeyManager: HotkeyManager {
    typealias Factory = (GlobalShortcut, @escaping @MainActor () -> Void) throws -> any HotkeyRegistration
    private let makeRegistration: Factory
    private var registration: (any HotkeyRegistration)?
    private var action: (@MainActor () -> Void)?
    private(set) var current: GlobalShortcut?

    init(makeRegistration: @escaping Factory = { try CarbonRegistration($0, action: $1) }) {
        self.makeRegistration = makeRegistration
    }

    func register(_ shortcut: GlobalShortcut, persist: () throws -> Void,
                  action: @escaping @MainActor () -> Void) throws {
        try shortcut.validate()
        if current == shortcut { try persist(); self.action = action; return }
        let candidate = try makeRegistration(shortcut) { [weak self] in self?.action?() }
        do { try persist() }
        catch { candidate.cancel(); throw error }
        registration?.cancel()
        registration = candidate
        current = shortcut
        self.action = action
    }

    func unregister() { registration?.cancel(); registration = nil; current = nil; action = nil }
}

@MainActor
final class CarbonRegistration: HotkeyRegistration {
    private static var nextID: UInt32 = 0
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private var action: (@MainActor () -> Void)?
    var eventID: EventHotKeyID { EventHotKeyID(signature: 0x54524E53, id: id) }

    init(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {
        try SystemShortcutCheck.requireAvailable(shortcut)
        Self.nextID &+= 1
        id = Self.nextID
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var eventID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let registration = Unmanaged<CarbonRegistration>.fromOpaque(context).takeUnretainedValue()
                guard eventID.signature == 0x54524E53, eventID.id == registration.id else { return OSStatus(eventNotHandledErr) }
                registration.action?()
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { cancel(); throw ShortcutFailure.unavailable }
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers,
            eventID, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard status == noErr else { cancel(); throw ShortcutFailure.unavailable }
    }

    func cancel() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil; action = nil
    }

    isolated deinit { cancel() }
}
