import AppKit
import Carbon

enum ShortcutFailure: Error, LocalizedError {
    case invalid, reserved, unavailable, systemCheck
    var errorDescription: String? {
        switch self {
        case .invalid: "Use a letter, number, or F1–F20 with at least two modifiers, including Control or Command."
        case .reserved: "macOS reserves this shortcut. Choose another combination."
        case .unavailable: "Could not register this shortcut. It may be used by another app. Choose another combination."
        case .systemCheck: "Could not check macOS shortcuts. Try again, or use Translate now from the menu."
        }
    }
}

/// Stores physical key codes and Carbon modifiers, never text entered in an editor.
struct GlobalShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt32
    static let standard = Self(keyCode: 0x11, modifiers: UInt32(controlKey | optionKey))
    static let allowedModifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)

    func validate() throws {
        guard Self.keyNames[keyCode] != nil, modifiers & ~Self.allowedModifiers == 0,
              modifiers.nonzeroBitCount >= 2, modifiers & UInt32(controlKey | cmdKey) != 0 else {
            throw ShortcutFailure.invalid
        }
    }

    init(keyCode: UInt16, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: keyCode, modifiers: modifiers)
        guard !flags.contains(.function) || isFunctionKey else { throw ShortcutFailure.invalid }
        try validate()
    }

    var isFunctionKey: Bool { Self.functionKeys.contains(keyCode) }
    var displayName: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + (Self.keyNames[keyCode] ?? "?")
    }

    func matches(keyCode: UInt16?, flags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == self.keyCode, let keyCode else { return false }
        return (try? Self(keyCode: keyCode, flags: flags)) == self
    }

    // Standard macOS physical key positions, independent of IME/dead-key text.
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}

enum SystemShortcutCheck {
    static func requireAvailable(_ shortcut: GlobalShortcut) throws {
        var copied: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&copied) == noErr, let copied else { throw ShortcutFailure.systemCheck }
        let entries = copied.takeRetainedValue() as NSArray
        for case let entry as NSDictionary in entries {
            if (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
               (entry[kHISymbolicHotKeyCode] as? NSNumber)?.uint16Value == shortcut.keyCode,
               let modifiers = (entry[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value,
               modifiers & GlobalShortcut.allowedModifiers == shortcut.modifiers { throw ShortcutFailure.reserved }
        }
    }
}
