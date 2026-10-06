import AppKit
import Testing
@testable import TranslateBar

@Suite
struct InputGuardTests {
    @Test func scrollMotionAndReleasesDoNotCancel() {
        for type: NSEvent.EventType in [.scrollWheel, .mouseMoved, .keyUp, .flagsChanged] {
            #expect(!InputGuardPolicy.shouldInterrupt(GuardInput(type: type)))
        }
    }

    @Test func typingAndAllOutsideClicksCancelIncludingUnknownTarget() {
        for type: NSEvent.EventType in [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(InputGuardPolicy.shouldInterrupt(GuardInput(type: type, keyCode: 0x00)))
        }
    }

    @Test func ownWindowAndTaggedSyntheticEventsDoNotCancel() {
        for type: NSEvent.EventType in [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(!InputGuardPolicy.shouldInterrupt(GuardInput(type: type, targetsOwnWindow: true)))
            #expect(!InputGuardPolicy.shouldInterrupt(GuardInput(type: type, isSynthetic: true)))
        }
    }

    @Test func onlyExactRepeatedShortcutIsIgnored() {
        #expect(!InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x11, flags: [.control, .option])))
        #expect(!InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x11, flags: [.control, .option, .capsLock])))
        #expect(InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x11)))
        #expect(InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x11, flags: [.control, .option, .shift])))
        #expect(InputGuardPolicy.shouldInterrupt(GuardInput(type: .keyDown, keyCode: 0x08, flags: [.control, .option])))
    }

    @Test func focusMustStillBeTheOriginalApp() {
        #expect(!InputGuardPolicy.focusChanged(originalPID: 101, currentPID: 101))
        #expect(InputGuardPolicy.focusChanged(originalPID: 101, currentPID: 202))
        #expect(InputGuardPolicy.focusChanged(originalPID: 101, currentPID: nil))
    }
}

@Suite @MainActor
struct ModifierTests {
    @Test func privateEventsCarryOnlyTheRequestedModifiers() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        // Construct only: these tests never post events or touch the user's app.
        for stroke in [KeyStroke.copy, .selectAll, .right, .paste,
                       .init(key: 0x7D, flags: [.maskAlternate, .maskShift])] {
            let (down, up) = try EventPoster.makeEvents(stroke, source: source)
            for event in [down, up] {
                #expect(event.flags == stroke.flags)
                #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(stroke.key))
                #expect(event.getIntegerValueField(.eventSourceUserData) == EventPoster.tag)
            }
            #expect(down.type == .keyDown)
            #expect(up.type == .keyUp)
        }
    }

    @Test func privatePathDoesNotWaitAndFallbackIsExplicit() async throws {
        let normal = EventPoster(waitForRelease: false)
        #expect(!normal.requiresModifierRelease)
        try await normal.waitForModifiers()
        #expect(EventPoster(waitForRelease: true).requiresModifierRelease)
    }

    @Test func releaseWaitHasThreeSecondGraceAndIgnoresCapsLock() {
        #expect(ModifierReleasePolicy.action(flags: [.maskControl, .maskAlternate], elapsed: .milliseconds(2999)) == .wait)
        #expect(ModifierReleasePolicy.action(flags: [.maskControl], elapsed: .seconds(3)) == .timeout)
        #expect(ModifierReleasePolicy.action(flags: [], elapsed: .seconds(3)) == .ready)
        #expect(ModifierReleasePolicy.action(flags: [.maskAlphaShift, .maskNumericPad], elapsed: .seconds(4)) == .ready)
    }

    @Test func timeoutIdentifiesEveryBlockingModifierWithoutInputText() {
        #expect(ModifierReleasePolicy.names([.maskControl, .maskAlternate, .maskAlphaShift]) == ["modifierHeldControl", "modifierHeldOption"])
        for flag: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn] {
            #expect(ModifierReleasePolicy.action(flags: flag, elapsed: .seconds(3)) == .timeout)
            #expect(ModifierReleasePolicy.names(flag).count == 1)
        }
    }
}
