import XCTest
@testable import iPadCasting

final class RemoteMouseInputTests: XCTestCase {
    private let token: UInt64 = 7
    private let generation: UInt64 = 3
    private let video = CGRect(x: 100, y: 50, width: 200, height: 100)

    private func context(token: UInt64 = 7, state: UInt8 = 1) -> RemoteInputContextCommand {
        RemoteInputContextCommand(state: state, desktop: 1, token: token, desktopEpoch: 9,
            left: -400, top: -200, width: 400, height: 200)
    }

    private func input(mode: RemoteMouseMode = .auto) -> RemoteMouseInput {
        RemoteMouseInput(context: context(), videoRect: video, generation: generation, mode: mode)
    }

    private func sample(_ x: CGFloat = 150, _ y: CGFloat = 75, time: TimeInterval = 0,
                        count: Int = 1, taps: Int = 1, device: RemoteMouseDevice = .finger,
                        buttons: RemoteMouseButtons = []) -> RemoteMouseSample {
        RemoteMouseSample(point: CGPoint(x: x, y: y), timestamp: time,
            touchCount: count, tapCount: taps, device: device, buttons: buttons)
    }

    private func command(_ kind: UInt8, _ a: Int32 = 0, _ b: Int32 = 0,
                         button: UInt8 = 0) -> RemotePointerCommand {
        RemotePointerCommand(kind: kind, button: button, token: token, a: a, b: b)
    }

    func testDeviceDefaultsAndManualOverrides() {
        XCTAssertEqual(RemoteMouseMode.auto.resolved(for: .finger), .trackpad)
        XCTAssertEqual(RemoteMouseMode.auto.resolved(for: .pencil), .direct)
        XCTAssertEqual(RemoteMouseMode.auto.resolved(for: .indirectPointer), .direct)
        for device in RemoteMouseDevice.allCases {
            XCTAssertEqual(RemoteMouseMode.trackpad.resolved(for: device), .trackpad)
            XCTAssertEqual(RemoteMouseMode.direct.resolved(for: device), .direct)
        }
    }

    func testPreferenceRoundTripAndInvalidValueDefaultsToAuto() {
        let name = "RemoteMouseInputTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(RemoteMouseModeStore.load(defaults: defaults), .auto)
        for mode in RemoteMouseMode.allCases {
            RemoteMouseModeStore.save(mode, defaults: defaults)
            XCTAssertEqual(RemoteMouseModeStore.load(defaults: defaults), mode)
        }
        defaults.set("invalid", forKey: RemoteMouseModeStore.key)
        XCTAssertEqual(RemoteMouseModeStore.load(defaults: defaults), .auto)
    }

    func testFingerMoveHasNoInitialJumpAndNoAcceleration() {
        var mouse = input()
        XCTAssertEqual(mouse.touchBegan(sample(), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchMoved(sample(153, 73, time: 0.1), token: token, generation: generation),
            [command(1, 6, -4)])
        XCTAssertEqual(mouse.touchMoved(sample(156, 71, time: 0.101), token: token, generation: generation),
            [command(1, 6, -4)])
        XCTAssertEqual(mouse.touchEnded(sample(156, 71, time: 1), token: token, generation: generation), [])
    }

    func testRelativeFractionsCarryAcrossSamplesAndTouches() {
        var mouse = input()
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(150.25, 74.75, time: 0.1), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchMoved(sample(150.5, 74.5, time: 0.2), token: token, generation: generation),
            [command(1, 1, -1)])
        _ = mouse.touchMoved(sample(150.75, 74.25, time: 0.3), token: token, generation: generation)
        _ = mouse.touchEnded(sample(150.75, 74.25, time: 1), token: token, generation: generation)
        _ = mouse.touchBegan(sample(time: 2), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(150.25, 74.75, time: 2.1), token: token, generation: generation),
            [command(1, 1, -1)])
    }

    func testTapIsLeftDownThenUp() {
        var mouse = input()
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        XCTAssertEqual(mouse.touchEnded(sample(time: 0.1), token: token, generation: generation),
            [command(2, button: 1), command(2, 1, button: 1)])
        XCTAssertTrue(mouse.heldButtons.isEmpty)
    }

    func testDoubleTapAndHoldDragsUntilEndOutsideVideo() {
        var mouse = input()
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        _ = mouse.touchEnded(sample(time: 0.1), token: token, generation: generation)
        XCTAssertEqual(mouse.touchBegan(sample(time: 0.2, taps: 2), token: token, generation: generation),
            [command(2, button: 1)])
        XCTAssertEqual(mouse.touchMoved(sample(160, 80, time: 0.8, taps: 2), token: token, generation: generation),
            [command(1, 20, 10)])
        XCTAssertEqual(mouse.touchEnded(sample(400, 80, time: 1, taps: 2), token: token, generation: generation),
            [command(2, 1, button: 1)])
    }

    func testTwoFingerTapIsRightClickAndThreeFingerTapIsIgnored() {
        var mouse = input()
        _ = mouse.touchBegan(sample(count: 2), token: token, generation: generation)
        XCTAssertEqual(mouse.touchEnded(sample(time: 0.1, count: 2), token: token, generation: generation),
            [command(2, button: 2), command(2, 1, button: 2)])
        _ = mouse.touchBegan(sample(time: 1, count: 3), token: token, generation: generation)
        XCTAssertEqual(mouse.touchEnded(sample(time: 1.1, count: 3), token: token, generation: generation), [])
    }

    func testTwoFingerMoveScrollsBothAxesWithoutClick() {
        var mouse = input()
        _ = mouse.touchBegan(sample(count: 2), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(222, 3, time: 0.1, count: 2), token: token, generation: generation),
            [command(3, -120, -120)])
        XCTAssertEqual(mouse.touchEnded(sample(222, 3, time: 0.2, count: 2), token: token, generation: generation), [])
    }

    func testTwoFingerTapToleratesJitterAndStaggeredArrival() {
        var mouse = input()
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        XCTAssertEqual(mouse.touchBegan(sample(180, 80, time: 0.02, count: 2), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchMoved(sample(181, 80, time: 0.05, count: 2), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchEnded(sample(181, 80, time: 0.1, count: 2), token: token, generation: generation),
            [command(2, button: 2), command(2, 1, button: 2)])
    }

    func testLongHoldAndMovedFingerNeverBecomeTap() {
        var mouse = input()
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        XCTAssertEqual(mouse.touchEnded(sample(time: 0.5), token: token, generation: generation), [])
        _ = mouse.touchBegan(sample(time: 1), token: token, generation: generation)
        _ = mouse.touchMoved(sample(170, 75, time: 1.1), token: token, generation: generation)
        XCTAssertEqual(mouse.touchEnded(sample(time: 1.2), token: token, generation: generation), [])
    }

    func testChangingTouchCountRebasesAndNeverClicksAfterScroll() {
        var mouse = input()
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(190, 90, time: 0.1, count: 2), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchMoved(sample(190, 18, time: 0.2, count: 2), token: token, generation: generation),
            [command(3, -120)])
        XCTAssertEqual(mouse.touchMoved(sample(190, 18, time: 0.3), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchEnded(sample(190, 18, time: 0.4), token: token, generation: generation), [])
    }

    func testPencilDirectMovePrecedesLeftDragAndRelease() {
        var mouse = input()
        XCTAssertEqual(mouse.touchBegan(sample(100, 50, device: .pencil), token: token, generation: generation),
            [command(0), command(2, button: 1)])
        XCTAssertEqual(mouse.touchMoved(sample(300, 150, time: 0.1, device: .pencil), token: token, generation: generation),
            [command(0, 65535, 65535)])
        XCTAssertEqual(mouse.touchEnded(sample(300, 150, time: 0.2, device: .pencil), token: token, generation: generation),
            [command(0, 65535, 65535), command(2, 1, button: 1)])
    }

    func testDirectFingerTapMovesBeforeClick() {
        var mouse = input(mode: .direct)
        XCTAssertEqual(mouse.touchBegan(sample(100, 50), token: token, generation: generation), [command(0)])
        XCTAssertEqual(mouse.touchEnded(sample(100, 50, time: 0.1), token: token, generation: generation),
            [command(0), command(2, button: 1), command(2, 1, button: 1)])
    }

    func testMappingCornersCenterAndNonzeroSourceOrigin() {
        var mouse = input()
        let vectors: [(CGPoint, Int32, Int32)] = [
            (CGPoint(x: 100, y: 50), 0, 0), (CGPoint(x: 300, y: 50), 65535, 0),
            (CGPoint(x: 100, y: 150), 0, 65535), (CGPoint(x: 300, y: 150), 65535, 65535),
            (CGPoint(x: 200, y: 100), 32768, 32768)]
        for (point, x, y) in vectors {
            XCTAssertEqual(mouse.hover(point: point, token: token, generation: generation), [command(0, x, y)])
        }
    }

    func testLetterboxMarginsNeverMoveOrPressButReleaseHeldButtons() {
        var mouse = input()
        for point in [CGPoint(x: 99, y: 100), CGPoint(x: 301, y: 100),
                      CGPoint(x: 200, y: 49), CGPoint(x: 200, y: 151)] {
            XCTAssertEqual(mouse.hover(point: point, buttons: [.left], token: token, generation: generation), [])
        }
        _ = mouse.hover(point: CGPoint(x: 100, y: 50), buttons: [.right], token: token, generation: generation)
        XCTAssertEqual(mouse.hover(point: CGPoint(x: 99, y: 50), token: token, generation: generation),
            [command(2, 1, button: 2)])
    }

    func testIndirectButtonsHaveTrueDownUpDragAndNoDuplicateDown() {
        for (mask, button) in [(RemoteMouseButtons.left, UInt8(1)), (.right, 2), (.middle, 3), (.x1, 4), (.x2, 5)] {
            var mouse = input()
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 100, y: 50), buttons: mask, token: token, generation: generation),
                [command(0), command(2, button: button)])
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 300, y: 150), buttons: mask, token: token, generation: generation),
                [command(0, 65535, 65535)])
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 300, y: 150), token: token, generation: generation),
                [command(0, 65535, 65535), command(2, 1, button: button)])
        }
    }

    func testMiddleClickPanelActionDoesNotReleaseHardwareHeldMiddle() {
        var mouse = input()
        XCTAssertEqual(mouse.middleClick(token: token, generation: generation),
            [command(2, button: 3), command(2, 1, button: 3)])
        _ = mouse.hover(point: CGPoint(x: 100, y: 50), buttons: [.middle], token: token, generation: generation)
        XCTAssertEqual(mouse.middleClick(token: token, generation: generation), [])
    }

    func testTrackpadOverrideAppliesToPencilAndIndirectPointer() {
        var mouse = input(mode: .trackpad)
        XCTAssertEqual(mouse.touchBegan(sample(device: .pencil), token: token, generation: generation),
            [command(2, button: 1)])
        XCTAssertEqual(mouse.touchMoved(sample(155, 80, time: 0.1, device: .pencil), token: token, generation: generation),
            [command(1, 10, 10)])
        _ = mouse.reset(token: token, generation: generation)
        XCTAssertEqual(mouse.hover(point: CGPoint(x: 150, y: 75), token: token, generation: generation), [])
        XCTAssertEqual(mouse.hover(point: CGPoint(x: 155, y: 80), buttons: [.x1], token: token, generation: generation),
            [command(1, 10, 10), command(2, button: 4)])
    }

    func testWheelWindowsUnitsAndFractionsOnBothAxes() {
        var mouse = input()
        XCTAssertEqual(mouse.scroll(vertical: 0.5, horizontal: -0.5, token: token, generation: generation), [])
        XCTAssertEqual(mouse.scroll(vertical: 0.5, horizontal: -0.5, token: token, generation: generation),
            [command(3, 1, -1)])
        XCTAssertEqual(mouse.scroll(vertical: 120, horizontal: -120, token: token, generation: generation),
            [command(3, 120, -120)])
        XCTAssertEqual(mouse.scrollPoints(CGPoint(x: 24, y: -24), token: token, generation: generation),
            [command(3, -120, -120)])
    }

    func testPausedStaleTokenGenerationAndUnreadySuppressEveryEntryPoint() {
        for kind in 0...3 {
            var mouse = input()
            var eventToken = token
            var eventGeneration = generation
            if kind == 0 { mouse.configure(context: context(token: 0, state: 0), videoRect: video, generation: generation) }
            if kind == 1 { eventToken = 6 }
            if kind == 2 { eventGeneration = 2 }
            if kind == 3 { mouse.configure(context: context(), videoRect: video, generation: generation, inputReady: false) }
            XCTAssertEqual(mouse.touchBegan(sample(device: .pencil), token: eventToken, generation: eventGeneration), [])
            XCTAssertEqual(mouse.touchMoved(sample(time: 0.1), token: eventToken, generation: eventGeneration), [])
            XCTAssertEqual(mouse.touchEnded(sample(time: 0.2), token: eventToken, generation: eventGeneration), [])
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 100, y: 50), buttons: [.left], token: eventToken, generation: eventGeneration), [])
            XCTAssertEqual(mouse.scroll(vertical: 120, horizontal: 120, token: eventToken, generation: eventGeneration), [])
            XCTAssertEqual(mouse.middleClick(token: eventToken, generation: eventGeneration), [])
            XCTAssertEqual(mouse.reset(token: eventToken, generation: eventGeneration), [])
        }
    }

    func testResetReleasesEveryHeldButtonExactlyOnce() {
        var mouse = input()
        _ = mouse.hover(point: CGPoint(x: 100, y: 50), buttons: [.left, .right, .middle, .x1, .x2], token: token, generation: generation)
        XCTAssertEqual(mouse.reset(token: token, generation: generation),
            (UInt8(1)...5).map { command(2, 1, button: $0) })
        XCTAssertEqual(mouse.reset(token: token, generation: generation), [])
        XCTAssertTrue(mouse.heldButtons.isEmpty)
    }

    func testModeChangeReleasesDragAndClearsFractionalMotion() {
        var mouse = input()
        _ = mouse.touchBegan(sample(device: .pencil), token: token, generation: generation)
        XCTAssertEqual(mouse.setMode(.trackpad, token: token, generation: generation), [command(2, 1, button: 1)])
        XCTAssertEqual(mouse.mode, .trackpad)
        XCTAssertEqual(mouse.touchMoved(sample(200, 100, time: 0.1, device: .pencil), token: token, generation: generation), [])
    }

    func testContextChangeDropsHeldStateWithoutRestampingOrReplay() {
        var mouse = input()
        _ = mouse.touchBegan(sample(device: .pencil), token: token, generation: generation)
        mouse.configure(context: context(token: 8), videoRect: video, generation: 4)
        XCTAssertTrue(mouse.heldButtons.isEmpty)
        XCTAssertEqual(mouse.reset(token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchEnded(sample(time: 1, device: .pencil), token: 8, generation: 4), [])
    }

    func testVideoResizeReturnsReleasesBeforeDroppingGesture() {
        var mouse = input()
        _ = mouse.touchBegan(sample(device: .pencil), token: token, generation: generation)
        XCTAssertEqual(mouse.configure(context: context(), videoRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            generation: generation), [command(2, 1, button: 1)])
        XCTAssertTrue(mouse.heldButtons.isEmpty)
    }

    func testStaleResetAndEndCannotReleaseCurrentDrag() {
        var mouse = input()
        _ = mouse.touchBegan(sample(device: .pencil), token: token, generation: generation)
        XCTAssertEqual(mouse.reset(token: 6, generation: generation), [])
        XCTAssertEqual(mouse.touchEnded(sample(time: 0.1, device: .pencil), token: token, generation: 2), [])
        XCTAssertEqual(mouse.heldButtons, Set([UInt8(1)]))
        XCTAssertEqual(mouse.reset(token: token, generation: generation), [command(2, 1, button: 1)])
    }

    func testResetClearsWheelAndRelativeRemainders() {
        var mouse = input()
        _ = mouse.scroll(vertical: 0.5, horizontal: -0.5, token: token, generation: generation)
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        _ = mouse.touchMoved(sample(150.25, 75, time: 0.1), token: token, generation: generation)
        _ = mouse.reset(token: token, generation: generation)
        XCTAssertEqual(mouse.scroll(vertical: 0.5, horizontal: -0.5, token: token, generation: generation), [])
        _ = mouse.touchBegan(sample(time: 1), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(150.25, 75, time: 1.1), token: token, generation: generation), [])
    }

    func testInvalidGeometryAndOutOfOrderSamplesAreIgnored() {
        var mouse = RemoteMouseInput(context: context(), videoRect: .zero, generation: generation)
        XCTAssertEqual(mouse.hover(point: .zero, buttons: [.left], token: token, generation: generation), [])
        mouse.configure(context: context(), videoRect: video, generation: generation)
        _ = mouse.touchBegan(sample(time: 1), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(200, 100, time: 0.9), token: token, generation: generation), [])
        XCTAssertEqual(mouse.touchMoved(sample(155, 80, time: 1.1), token: token, generation: generation),
            [command(1, 10, 10)])
    }

    func testNonfiniteAndOversizedInputCannotProduceInvalidWireValues() {
        var mouse = input()
        XCTAssertEqual(mouse.hover(point: CGPoint(x: CGFloat.nan, y: 50), token: token, generation: generation), [])
        XCTAssertEqual(mouse.scroll(vertical: .nan, horizontal: 0, token: token, generation: generation), [])
        XCTAssertEqual(mouse.scroll(vertical: 1e20, horizontal: -1e20, token: token, generation: generation),
            [command(3, 32767, -32767)])
        _ = mouse.touchBegan(sample(), token: token, generation: generation)
        XCTAssertEqual(mouse.touchMoved(sample(1e20, -1e20, time: 1), token: token, generation: generation),
            [command(1, 32767, -32767)])
    }
}
