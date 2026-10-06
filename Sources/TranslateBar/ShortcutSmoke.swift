import AppKit
import Carbon

/// Registers temporary combinations; dispatches events only to this process.
@MainActor
enum ShortcutSmoke {
    static func run() -> Bool {
        var registrations: [CarbonRegistration] = []
        let manager = CarbonHotkeyManager { shortcut, action in
            let value = try CarbonRegistration(shortcut, action: action)
            registrations.append(value)
            return value
        }
        let other = CarbonHotkeyManager()
        defer { manager.unregister(); other.unregister() }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let first = GlobalShortcut(keyCode: 79, modifiers: modifiers)
        let occupied = GlobalShortcut(keyCode: 80, modifiers: modifiers)
        let replacement = GlobalShortcut(keyCode: 90, modifiers: modifiers)
        var fired = 0
        do {
            try manager.register(first, persist: {}) { fired += 1 }
            let firstID = registrations[0].eventID
            try other.register(occupied, persist: {}, action: {})
            var persisted = false
            do {
                try manager.register(occupied, persist: { persisted = true }, action: {})
                throw Failure.check
            } catch is ShortcutFailure { }
            guard !persisted, manager.current == first else { throw Failure.check }
            try dispatch(firstID)
            guard fired == 1 else { throw Failure.check }
            print("Shortcut smoke: PASS conflict keeps previous registration and callback")

            do {
                try manager.register(replacement, persist: { throw Failure.save }, action: {})
                throw Failure.check
            } catch Failure.save { }
            guard manager.current == first else { throw Failure.check }
            try dispatch(firstID)
            guard fired == 2 else { throw Failure.check }
            other.unregister()
            try other.register(replacement, persist: {}, action: {})
            other.unregister()
            print("Shortcut smoke: PASS failed save releases candidate and preserves previous shortcut")

            try manager.register(replacement, persist: {}) { fired += 10 }
            guard manager.current == replacement, let currentID = registrations.last?.eventID else { throw Failure.check }
            try dispatch(firstID, expected: OSStatus(eventNotHandledErr))
            guard fired == 2 else { throw Failure.check }
            try dispatch(currentID)
            guard fired == 12 else { throw Failure.check }
            try other.register(first, persist: {}, action: {})
            manager.unregister()
            try dispatch(currentID, expected: OSStatus(eventNotHandledErr))
            guard fired == 12, manager.current == nil else { throw Failure.check }
            other.unregister()
            try other.register(replacement, persist: {}, action: {})
            print("Shortcut smoke: PASS replacement dispatch; old event ignored; registrations released")
            return true
        } catch {
            print("Shortcut smoke: FAILED; registration or event dispatch check")
            return false
        }
    }

    private static func dispatch(_ id: EventHotKeyID, expected: OSStatus = noErr) throws {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(), 0, &event) == noErr, let event else { throw Failure.check }
        defer { ReleaseEvent(event) }
        var id = id
        guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &id) == noErr,
              SendEventToEventTarget(event, GetApplicationEventTarget()) == expected else { throw Failure.check }
    }
    private enum Failure: Error { case check, save }
}
