import UIKit
import XCTest
@testable import iPadCasting

final class RemoteMouseInputTests: XCTestCase {
    @MainActor func testLocalGesturesHaveAnExclusiveHitTargetUntilFit() throws {
        let surface = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                                    pencilInteractionsEnabled: false)
        let controls = LocalViewportControls()
        surface.configureLocalViewport(controls)
        surface.layoutIfNeeded()
        surface.setBaseViewport(VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let center = CGPoint(x: 200, y: 150)
        XCTAssertTrue(surface.hitTest(center, with: nil) === surface.touchView)
        controls.isZoomMode = true
        let localTarget = surface.hitTest(center, with: nil)
        let gesture = try XCTUnwrap(localTarget as? LocalViewportGestureView)
        var packets = 0
        let session = IPadInputSession.preview()
        session.configure(identity: "viewport", point: true, type: true, direct: true, zoom: true,
                          reason: nil) { _ in packets += 1 }
        surface.touchView.inputSession = session
        surface.touchView.onPointerInput = { _ in packets += 1 }
        surface.touchView.onDirectTouchContact = { _ in packets += 1 }
        let first = NSObject(), second = NSObject()
        let a = ObjectIdentifier(first), b = ObjectIdentifier(second)
        gesture.update([a: center, b: CGPoint(x: 220, y: 150)], phase: .began)
        gesture.update([b: CGPoint(x: 240, y: 150)], phase: .moved)
        XCTAssertEqual(controls.scale, 2)
        gesture.update([b: .zero], phase: .ended)
        gesture.update([a: CGPoint(x: 210, y: 150)], phase: .moved)
        XCTAssertTrue(surface.hitTest(center, with: nil) === localTarget)
        controls.fit()
        XCTAssertEqual(controls.scale, 1)
        XCTAssertTrue(surface.hitTest(center, with: nil) === localTarget)
        gesture.update([a: .zero], phase: .ended)
        XCTAssertEqual(packets, 0)
        XCTAssertTrue(surface.hitTest(center, with: nil) === surface.touchView)
    }

    @MainActor func testPhoneSkipsPencilRegistrationsAndTabletKeepsDefaults() {
        for enabled in [false, true] {
            let view = enabled ? PencilUIKitView() : PencilUIKitView(frame: .zero, pencilInteractionsEnabled: false)
            XCTAssertEqual(view.interactions.contains { $0 is UIPencilInteraction }, enabled)
            XCTAssertEqual(view.gestureRecognizers?.contains { $0.name == "IPadInput.pencilHover" }, enabled)
            XCTAssertEqual(view.subviews.contains { $0 is UILabel }, enabled)
        }
    }

    @MainActor func testDismissingInputBarClearsHeldModifiers() {
        let session = IPadInputSession.preview()
        var events: [IPadInputEvent] = []
        session.configure(identity: "modifiers", point: true, type: true, direct: true, zoom: false,
                          reason: nil) { events.append($0) }
        session.setModifier(.control, .locked)
        session.setModifier(.shift, .oneShot)
        SessionInputBar.releaseHeldModifiers(in: session)
        XCTAssertEqual(session.modifierState(.control), .off)
        XCTAssertEqual(session.modifierState(.shift), .off)
        XCTAssertEqual(events, [.key(0xe0, 0), .key(0xe0, 1)])
    }

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

    @MainActor func testPhoneSurfaceRejectsNegotiatedDirectContacts() {
        let view = PencilUIKitView(frame: CGRect(x: 0, y: 0, width: 320, height: 240),
                                   pencilInteractionsEnabled: false, directTouchAllowed: false)
        var contacts: [DirectTouchContactCommand] = []
        view.onDirectTouchContact = { contacts.append($0) }
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.configureDirectTouch(active: true, generation: 1)
        let point = CGPoint(x: 100, y: 100)
        view.emitDirectOutputs([.directTouch(.down, 1, point, 255), .directTouch(.up, 1, point, 255)])
        XCTAssertTrue(contacts.isEmpty)
    }

    @MainActor func testPhoneSessionLeavesTabletModePreferenceUntouched() {
        let key = IPadInputSession.touchModeKey
        let before = UserDefaults.standard.string(forKey: key)
        let phone = IPadInputSession.phoneRemote()
        XCTAssertEqual(phone.touchMode, .trackpad)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), before)
    }

    @MainActor func testPhoneFingerWithDirectPreferenceClicksOnlyInsideVideo() {
        let view = PencilUIKitView(frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                   pencilInteractionsEnabled: false, directTouchAllowed: false)
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0.25, width: 1, height: 0.5))
        let session = IPadInputSession.phoneRemote()
        session.engine.mode = .direct
        var events: [IPadInputEvent] = []
        session.configure(identity: "phone", point: true, type: false, direct: true, zoom: false,
                          reason: nil) { events.append($0) }
        let finger = NSObject()
        let key = ObjectIdentifier(finger)
        view.beginV2Contact(key, point: .zero, pencil: false, tapCount: 1, session: session)
        XCTAssertTrue(events.isEmpty)
        let center = CGPoint(x: 200, y: 150)
        view.beginV2Contact(key, point: center, pencil: false, tapCount: 1, session: session)
        view.endV2Contact(key, point: center, cancelled: false, session: session)
        XCTAssertEqual(events, [.button(1, 0, 1), .button(1, 1, 1)])
    }

    @MainActor func testResizeReleasesTrackpadDragAndIgnoresOldLift() {
        let surface = ConnectedPresentationContainer(frame: CGRect(x: 0, y: 0, width: 320, height: 640),
            pencilInteractionsEnabled: false, directTouchAllowed: false)
        surface.configureLocalViewport(LocalViewportControls())
        surface.layoutIfNeeded()
        surface.setBaseViewport(VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        let view = surface.touchView
        let session = IPadInputSession.phoneRemote()
        view.inputSession = session
        var events: [IPadInputEvent] = []
        session.configure(identity: "rotation", point: true, type: false, direct: false, zoom: false,
                          reason: nil) { events.append($0) }
        let finger = NSObject()
        let key = ObjectIdentifier(finger)
        let p = CGPoint(x: 100, y: 100)
        view.beginV2Contact(key, point: p, pencil: false, tapCount: 2, session: session)
        XCTAssertEqual(events, [.button(1, 0, 1)])
        surface.bounds.size = CGSize(width: 640, height: 320)
        surface.layoutIfNeeded()
        XCTAssertNil(view.contentViewport)
        view.endV2Contact(key, point: p, cancelled: false, session: session)
        view.beginV2Contact(key, point: p, pencil: false, tapCount: 1, session: session)
        XCTAssertEqual(events, [.button(1, 0, 1), .button(1, 1, 1)])
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

extension RemoteMouseInputTests {
    func testRelativeHoverExitAndCancelReanchorWithoutJump() {
        for cancelled in [false, true] {
            var mouse = input(mode: .trackpad)
            _ = mouse.hover(point: CGPoint(x: 150, y: 75), buttons: .left, token: token, generation: generation)
            _ = mouse.hover(point: CGPoint(x: 150.25, y: 75), buttons: .left, token: token, generation: generation)
            XCTAssertEqual(mouse.hoverEnded(cancelled: cancelled, token: token, generation: generation),
                cancelled ? [command(2, 1, button: 1)] : [])
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 290, y: 120),
                buttons: cancelled ? [] : .left, token: token, generation: generation), [])
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 290.25, y: 120),
                buttons: cancelled ? [] : .left, token: token, generation: generation), [])
            XCTAssertEqual(mouse.hover(point: CGPoint(x: 290.5, y: 120),
                buttons: cancelled ? [] : .left, token: token, generation: generation), [command(1, 1)])
        }
    }
}

extension RemoteMouseInputTests {
    func testPencilPreemptsFingerDragInEitherArrivalOrder() {
        for pencilFirst in [false, true] {
            var mouse = input()
            let pencil = sample(time: 0.1, device: .pencil)
            if !pencilFirst {
                _ = mouse.touchBegan(sample(taps: 2), token: token, generation: generation)
                let takeover = mouse.touchBegan(pencil, token: token, generation: generation)
                XCTAssertEqual(takeover.filter { $0.kind == 2 }.map(\.a), [1, 0])
            } else {
                _ = mouse.touchBegan(pencil, token: token, generation: generation)
                XCTAssertTrue(mouse.touchBegan(sample(time: 0.2, taps: 2), token: token, generation: generation).isEmpty)
            }
            XCTAssertTrue(mouse.touchEnded(sample(time: 0.3), token: token, generation: generation).isEmpty)
            XCTAssertEqual(mouse.touchEnded(sample(time: 0.4, device: .pencil), token: token, generation: generation)
                .filter { $0.kind == 2 }.map(\.a), [1])
            XCTAssertTrue(mouse.heldButtons.isEmpty)
        }
    }
}
