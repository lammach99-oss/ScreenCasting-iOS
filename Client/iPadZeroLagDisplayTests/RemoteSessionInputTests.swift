import XCTest
@testable import iPadCasting

final class RemoteSessionInputTests: XCTestCase {
    private func context(_ token: UInt64 = 7) -> RemoteInputContextCommand {
        RemoteInputContextCommand(state: 1, desktop: 1, token: token, desktopEpoch: 2,
            left: 0, top: 0, width: 1000, height: 500)
    }

    @MainActor private func ready(_ state: RemoteSessionInputState, token: UInt64 = 7,
                                  generation: UInt64 = 10, revision: UInt64 = 1,
                                  features: UInt64 = 3, active: Bool = true) {
        state.configure(RemoteSessionInputConfiguration(remote: true, connected: true,
            active: active, generation: generation, features: features, context: context(token),
            ready: true, revision: revision))
        state.setVideoRect(CGRect(x: 0, y: 0, width: 500, height: 250))
    }

    @MainActor func testCastingAndOldHostKeepLegacyRoutes() {
        let state = RemoteSessionInputState()
        state.configure(RemoteSessionInputConfiguration(remote: false, connected: true,
            active: true, generation: 10, features: 3, context: context(), ready: true, revision: 1))
        XCTAssertFalse(state.usesScanKeyboard)
        XCTAssertFalse(state.usesEnhancedPointer)
        ready(state, features: 0)
        XCTAssertFalse(state.usesScanKeyboard)
        XCTAssertFalse(state.usesEnhancedPointer)
        XCTAssertFalse(state.keyboardEnabled)
    }

    @MainActor func testReadinessAndIndependentFeatureGates() {
        let state = RemoteSessionInputState()
        ready(state, features: 1)
        XCTAssertTrue(state.keyboardEnabled)
        XCTAssertFalse(state.pointerEnabled)
        ready(state, features: 2)
        XCTAssertFalse(state.keyboardEnabled)
        XCTAssertTrue(state.pointerEnabled)
        state.configure(RemoteSessionInputConfiguration(remote: true, connected: true,
            active: true, generation: 10, features: 3, context: context(), ready: false, revision: 2))
        XCTAssertFalse(state.keyboardEnabled)
        XCTAssertFalse(state.pointerEnabled)
        XCTAssertFalse(state.hardware(usage: 0x15, phase: .began))
    }

    @MainActor func testHardwareAndBarShareOwnershipAndCommandIsWin() {
        let state = RemoteSessionInputState()
        var keys: [RemoteScanKeyCommand] = []
        state.sendKey = { key, generation in XCTAssertEqual(generation, 10); keys.append(key) }
        ready(state)
        state.keyboard.lockModifier(.win).forEach { state.emitKey($0, generation: 10) }
        XCTAssertTrue(state.hardware(usage: 0xe3, phase: .began))
        _ = state.hardware(usage: 0x15, phase: .began)
        _ = state.hardware(usage: 0x15, phase: .cancelled)
        _ = state.hardware(usage: 0xe3, phase: .ended)
        XCTAssertEqual(keys.map(\.scan), [0x5b, 0x13, 0x13])
        XCTAssertEqual(keys.map(\.flags), [1, 0, 0])
        XCTAssertEqual(keys.map(\.action), [0, 0, 1])
    }

    @MainActor func testLifecycleResetReleasesAndWaitsForNewToken() {
        for reason: UInt8 in [0, 1, 2, 3, 4] {
            let state = RemoteSessionInputState()
            var events: [String] = []
            state.sendKey = { key, _ in events.append("key-\(key.action)-\(key.scan)") }
            state.sendPointer = { pointer, _ in events.append("button-\(pointer.a)") }
            state.sendReset = { reset, _ in events.append("reset-\(reset.reason)-\(reset.token)") }
            ready(state)
            _ = state.hardware(usage: 0xe0, phase: .began)
            _ = state.hardware(usage: 0x04, phase: .began)
            state.pointer(token: 7, generation: 10) {
                $0.hover(point: CGPoint(x: 100, y: 100), buttons: .left, token: 7, generation: 10)
            }
            events.removeAll()
            state.suspend(reason: reason)
            XCTAssertEqual(events, ["key-1-30", "button-1", "key-1-29", "reset-\(reason)-7"])
            XCTAssertTrue(state.keyboard.heldKeys.isEmpty)
            ready(state)
            XCTAssertFalse(state.keyboardEnabled)
            ready(state, token: 8, revision: 2)
            XCTAssertTrue(state.keyboardEnabled)
        }
    }

    @MainActor func testPauseTokenRevisionAndReconnectDiscardWithoutReplay() {
        let state = RemoteSessionInputState()
        var sent: [RemoteScanKeyCommand] = []
        state.sendKey = { key, _ in sent.append(key) }
        ready(state)
        _ = state.hardware(usage: 0x04, phase: .began)
        ready(state, token: 8, revision: 2)
        XCTAssertTrue(state.keyboard.heldKeys.isEmpty)
        XCTAssertEqual(sent.count, 1)
        state.emitKey(RemoteScanKeyCommand(action: 1, flags: 0, scan: 0x1e, token: 7), generation: 10)
        XCTAssertEqual(sent.count, 1)
        _ = state.hardware(usage: 0x05, phase: .began)
        ready(state, token: 8, revision: 3)
        XCTAssertTrue(state.keyboard.heldKeys.isEmpty)
        state.configure(RemoteSessionInputConfiguration(remote: true, connected: false,
            active: false, generation: 11, features: 0, context: nil, ready: false, revision: 4))
        ready(state, token: 8, generation: 12, revision: 5)
        state.emitKey(RemoteScanKeyCommand(action: 0, flags: 0, scan: 0x1e, token: 8), generation: 10)
        XCTAssertEqual(sent.count, 2)
    }

    @MainActor func testInactiveRetiresOnceAndDoesNotRearmOnForeground() {
        let state = RemoteSessionInputState()
        var resets: [RemoteInputResetCommand] = []
        state.sendReset = { reset, _ in resets.append(reset) }
        ready(state)
        ready(state, active: false)
        ready(state, active: false)
        ready(state)
        XCTAssertEqual(resets.map(\.reason), [0])
        XCTAssertFalse(state.pointerEnabled)
    }

    @MainActor func testMouseModeRetiresBeforeChangeAndStartsAutoEachConnection() {
        let state = RemoteSessionInputState()
        var resets: [UInt8] = []
        state.sendReset = { reset, _ in resets.append(reset.reason) }
        ready(state)
        state.changeMouseMode(.direct)
        XCTAssertEqual(state.mouseMode, .direct)
        XCTAssertEqual(resets, [3])
        XCTAssertFalse(state.pointerEnabled)
        ready(state, token: 8, generation: 11)
        XCTAssertEqual(state.mouseMode, .auto)
    }

    @MainActor func testHeldHardwareDoesNotReplayAfterTokenOrConnectionChange() {
        let state = RemoteSessionInputState()
        var keys: [RemoteScanKeyCommand] = []
        state.sendKey = { key, _ in keys.append(key) }
        ready(state)
        _ = state.hardware(usage: 0x04, phase: .began)
        ready(state, token: 8, generation: 11, revision: 2)
        _ = state.hardware(usage: 0x04, phase: .began)
        XCTAssertEqual(keys.count, 1)
        _ = state.hardware(usage: 0x04, phase: .ended)
        _ = state.hardware(usage: 0x04, phase: .began)
        XCTAssertEqual(keys.map(\.token), [7, 8])
    }

    @MainActor func testNewConnectionResetsActualMouseTranslatorToAuto() {
        let state = RemoteSessionInputState()
        var pointers: [RemotePointerCommand] = []
        state.sendPointer = { pointer, _ in pointers.append(pointer) }
        ready(state)
        state.changeMouseMode(.direct)
        ready(state, token: 8, generation: 11, revision: 2)
        let began = RemoteMouseSample(point: CGPoint(x: 50, y: 50), timestamp: 1,
            touchCount: 1, tapCount: 1, device: .finger, buttons: [])
        let moved = RemoteMouseSample(point: CGPoint(x: 60, y: 55), timestamp: 1.1,
            touchCount: 1, tapCount: 1, device: .finger, buttons: [])
        state.pointer(token: 8, generation: 11) { $0.touchBegan(began, token: 8, generation: 11) }
        state.pointer(token: 8, generation: 11) { $0.touchMoved(moved, token: 8, generation: 11) }
        XCTAssertEqual(pointers, [RemotePointerCommand(kind: 1, button: 0, token: 8, a: 20, b: 10)])
    }

    @MainActor func testPausedContextClearsOwnersAndWaitsForFreshReadyFrame() {
        let state = RemoteSessionInputState()
        ready(state)
        _ = state.hardware(usage: 0x04, phase: .began)
        state.suspend(reason: 2)
        let paused = RemoteInputContextCommand(state: 0, desktop: 1, token: 0, desktopEpoch: 2,
            left: 0, top: 0, width: 1000, height: 500)
        state.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: 10, features: 3, context: paused, ready: false, revision: 2))
        XCTAssertTrue(state.keyboard.heldKeys.isEmpty)
        XCTAssertFalse(state.keyboardEnabled)
        ready(state, revision: 3)
        XCTAssertFalse(state.keyboardEnabled)
        state.configure(RemoteSessionInputConfiguration(remote: true, connected: true, active: true,
            generation: 10, features: 3, context: context(8), ready: false, revision: 4))
        XCTAssertFalse(state.keyboardEnabled)
        ready(state, token: 8, revision: 4)
        XCTAssertTrue(state.keyboardEnabled)
    }

    @MainActor func testCommittedTextKeepsOriginTokenGenerationAndReadiness() {
        let state = RemoteSessionInputState()
        ready(state)
        XCTAssertTrue(state.acceptsText(token: 7, generation: 10))
        ready(state, token: 8, revision: 2)
        XCTAssertFalse(state.acceptsText(token: 7, generation: 10))
        XCTAssertTrue(state.acceptsText(token: 8, generation: 10))
        XCTAssertFalse(state.acceptsText(token: 8, generation: 9))
        state.suspend(reason: 0)
        XCTAssertFalse(state.acceptsText(token: 8, generation: 10))
        ready(state, token: 9, generation: 11, features: 0)
        XCTAssertTrue(state.acceptsText(token: nil, generation: 11))
        XCTAssertFalse(state.acceptsText(token: nil, generation: 10))
    }

    @MainActor func testStalePointerAndSoftwareKeysAreGated() {
        let state = RemoteSessionInputState()
        var pointers: [RemotePointerCommand] = []
        var keys: [RemoteScanKeyCommand] = []
        state.sendPointer = { pointer, _ in pointers.append(pointer) }
        state.sendKey = { key, _ in keys.append(key) }
        ready(state)
        state.pointer(token: 6, generation: 10) { $0.middleClick(token: 6, generation: 10) }
        state.pointer(token: 7, generation: 9) { $0.middleClick(token: 7, generation: 9) }
        XCTAssertTrue(pointers.isEmpty)
        state.softwareKey(KeyboardInputCommand(action: .keyDown, virtualKey: 0x0d))
        state.softwareKey(KeyboardInputCommand(action: .keyUp, virtualKey: 0x0d))
        XCTAssertEqual(keys.map(\.scan), [0x1c, 0x1c])
        XCTAssertEqual(keys.map(\.action), [0, 1])
        state.middleClick()
        XCTAssertEqual(pointers.map(\.button), [3, 3])
    }
}
