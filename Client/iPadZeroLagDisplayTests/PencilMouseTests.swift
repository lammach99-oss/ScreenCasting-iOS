import XCTest
import UIKit
@testable import iPadCasting

@MainActor final class PencilMouseTests: XCTestCase {
    func testHoverAndTipAreAbsoluteWithBalancedLeftButton() {
        var now: TimeInterval = 0
        var state = PencilMouseState(clock: { now })
        let a = CGPoint(x: 0.25, y: 0.5), b = CGPoint(x: 0.75, y: 1)
        XCTAssertEqual(state.hover(at: a), [.claimFingers, .move(a)])
        XCTAssertTrue(state.blocksFingers)
        XCTAssertEqual(state.begin(id: 1, at: a), [.claimFingers, .move(a), .button(1, true)])
        XCTAssertEqual(state.hover(at: nil), [], "Hover handoff cannot release a tip")
        XCTAssertEqual(state.move(id: 1, to: b), [.move(b)])
        XCTAssertEqual(state.end(id: 1, at: b, cancelled: false), [.move(b), .button(1, false)])
        XCTAssertEqual(state.end(id: 1, at: b, cancelled: false), [])
        now = 0.399; XCTAssertTrue(state.blocksFingers)
        now = 0.4; XCTAssertFalse(state.blocksFingers)
    }

    func testRightArmTogglesExpiresAndIsConsumedByExactlyOneTip() {
        var now: TimeInterval = 0
        var state = PencilMouseState(clock: { now })
        state.toggleRight(); XCTAssertTrue(state.rightArmed)
        state.toggleRight(); XCTAssertFalse(state.rightArmed)
        state.toggleRight(); now = 4.999; state.tick(); XCTAssertTrue(state.rightArmed)
        now = 5; state.tick(); XCTAssertFalse(state.rightArmed)
        state.toggleRight()
        XCTAssertEqual(state.begin(id: 8, at: .zero), [.claimFingers, .move(.zero), .button(2, true)])
        XCTAssertFalse(state.rightArmed)
        XCTAssertEqual(state.end(id: 8, at: nil, cancelled: true), [.button(2, false)])
        XCTAssertEqual(state.begin(id: 9, at: .zero), [.claimFingers, .move(.zero), .button(1, true)])
        XCTAssertEqual(state.retire(), [.button(1, false)])
        XCTAssertEqual(state.retire(), [])
    }

    func testUnownedAndMalformedSamplesNeverStartOrTerminateAnotherTip() {
        var state = PencilMouseState(clock: { 0 })
        XCTAssertEqual(state.hover(at: CGPoint(x: CGFloat.nan, y: 0)), [])
        XCTAssertEqual(state.begin(id: 0, at: .zero), [])
        _ = state.begin(id: 2, at: .zero)
        XCTAssertEqual(state.begin(id: 3, at: .zero), [])
        XCTAssertEqual(state.move(id: 3, to: .zero), [])
        XCTAssertEqual(state.end(id: 3, at: .zero, cancelled: true), [])
        XCTAssertEqual(state.retire(), [.button(1, false)])
        state.toggleRight(); _ = state.retire(); XCTAssertFalse(state.rightArmed)
    }

    func testMouseOwnedTipKeepsPalmLeaseButNeverAcquiresOrReleasesAButton() {
        var now: TimeInterval = 0
        var state = PencilMouseState(clock: { now })
        state.toggleRight()
        XCTAssertEqual(state.begin(id: 1, at: .zero, pointerAvailable: false), [.claimFingers])
        XCTAssertTrue(state.blocksFingers); XCTAssertTrue(state.rightArmed)
        XCTAssertEqual(state.move(id: 1, to: CGPoint(x: 1, y: 1)), [])
        XCTAssertEqual(state.begin(id: 2, at: .zero), [])
        XCTAssertEqual(state.end(id: 1, at: .zero, cancelled: false), [])
        now = 0.399; XCTAssertTrue(state.blocksFingers)
        now = 0.4; XCTAssertFalse(state.blocksFingers)
        XCTAssertEqual(state.begin(id: 2, at: .zero), [.claimFingers, .move(.zero), .button(2, true)])
        XCTAssertEqual(state.retire(), [.button(2, false)])
    }

    private func engine(clock: @escaping () -> TimeInterval = { 0 }) -> IPadInputEngine {
        let engine = IPadInputEngine(clock: clock)
        engine.enabled = true; engine.typeEnabled = true; engine.directAvailable = true
        return engine
    }

    func testPencilIgnoresTouchModeAndUsesTheExistingButtonTransaction() {
        for mode in [IPadTouchMode.direct, .trackpad] {
            let e = engine(); e.mode = mode
            var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
            e.pencilHover(at: CGPoint(x: 0.5, y: 0.5))
            e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
            e.move(id: 1, point: CGPoint(x: 3, y: 4), normalized: CGPoint(x: 1, y: 1))
            e.end(id: 1, point: .zero, normalized: CGPoint(x: 1, y: 1), cancelled: false)
            XCTAssertEqual(events, [.pointer(0, 0, 32768, 32768), .pointer(0, 0, 0, 0),
                .button(1, 0, 1), .pointer(0, 0, 65535, 65535),
                .pointer(0, 0, 65535, 65535), .button(1, 1, 1)])
        }
    }

    func testHoverPreemptsFingerAndGraceCannotReviveAPalm() {
        var now: TimeInterval = 0
        let e = engine(clock: { now }); var events: [IPadInputEvent] = []
        e.emit = { events.append($0) }
        e.begin(id: 1, pencil: false, point: .zero, normalized: .zero)
        events.removeAll(); e.pencilHover(at: .zero)
        XCTAssertEqual(events.first, .touch(.cancel, 1, .zero, 255))
        events.removeAll()
        e.begin(id: 2, pencil: false, point: .zero, normalized: .zero)
        e.pencilHover(at: nil)
        // External scroll/transform are not palms. Their coexistence is covered
        // by AU8ExternalMouseRegressionTests; this case checks fingers only.
        e.fingerScroll(CGPoint(x: 0, y: 10)); now = 0.4; e.tick()
        e.move(id: 2, point: .zero, normalized: .zero)
        e.end(id: 1, point: .zero, normalized: .zero, cancelled: false)
        e.end(id: 2, point: .zero, normalized: .zero, cancelled: false)
        XCTAssertTrue(events.isEmpty)
        e.begin(id: 3, pencil: false, point: .zero, normalized: .zero)
        XCTAssertEqual(events, [.touch(.down, 3, .zero, 255)])
    }

    func testPanelAndUnavailablePeerFencePencilButTerminalsStillRetire() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.togglePencilRight()
        e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
        e.setHardwareCaptureEnabled(false)
        XCTAssertEqual(events.last, .button(2, 1, 1)); XCTAssertFalse(e.pencilRightArmed)
        events.removeAll()
        e.pencilHover(at: .zero); e.togglePencilRight()
        e.begin(id: 2, pencil: true, point: .zero, normalized: .zero)
        XCTAssertTrue(events.isEmpty); XCTAssertFalse(e.pencilRightArmed)
        e.setHardwareCaptureEnabled(true); e.precisePencilAvailable = false
        e.pencilHover(at: .zero); e.togglePencilRight()
        e.begin(id: 3, pencil: true, point: .zero, normalized: .zero)
        XCTAssertTrue(events.isEmpty)
        e.precisePencilAvailable = true; e.armDrag()
        e.setHardwareCaptureEnabled(true)
        XCTAssertEqual(e.drag, .armed, "Closing the panel cannot retire its new drag")
    }

    func testAllThreeRoutesEncodeRightDragAndRetireWithTheOriginalAuthority() throws {
        let context = RemoteInputContextCommand(state: 1, desktop: 1, token: 7, desktopEpoch: 8,
            left: 0, top: 0, width: 1920, height: 1080)
        let ticket = MirrorInputTicket(session: 5, uiRevision: 6, epoch: 7, source: 8,
            token: MirrorToken(low: 3, high: 4))
        for kind in 0...2 {
            let e = engine()
            let route = IPadInputRoute(generation: 5, revision: 6, remote: kind == 2, features: 2,
                context: context, ticket: kind == 1 ? ticket : nil, pointerV2: true)
            var packets: [IPadInputRoute.Packet] = []
            e.emit = { if let packet = route.encode($0) { packets.append(packet) } }
            e.togglePencilRight(); e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
            e.enabled = false; e.typeEnabled = false; e.retire(); e.retire()
            XCTAssertEqual(packets.count, 3)
            if kind == 2 {
                let down = try XCTUnwrap(RemotePointerCommand.decode(packets[1].payload))
                let up = try XCTUnwrap(RemotePointerCommand.decode(packets[2].payload))
                XCTAssertEqual(down.kind, 2); XCTAssertEqual(down.button, 2)
                XCTAssertEqual(down.a, 0); XCTAssertEqual(up.a, 1); XCTAssertEqual(up.token, 7)
            } else {
                let down = try XCTUnwrap(IPadPointerV2Command.decode(packets[1].payload))
                let up = try XCTUnwrap(IPadPointerV2Command.decode(packets[2].payload))
                XCTAssertEqual(down.button, 2); XCTAssertEqual(down.transaction, 1)
                XCTAssertEqual(up.transaction, down.transaction); XCTAssertTrue(up.terminal)
                if kind == 1 {
                    let envelope = MirrorInputEnvelope(epoch: ticket.epoch, source: ticket.source, token: ticket.token,
                        sequence: 1, kind: try XCTUnwrap(MirrorInputKind(rawValue: packets[2].type.rawValue)), payload: packets[2].payload)
                    XCTAssertEqual(try MirrorControlCodec.decodeInput(MirrorControlCodec.encodeInput(envelope)).token, ticket.token)
                }
            }
            let old = IPadInputRoute(generation: 5, revision: 6, remote: kind == 2, features: 0,
                context: context, ticket: nil, pointerV2: false)
            XCTAssertNil(old.encode(.pointer(0, 0, 0, 0)))
            XCTAssertNil(old.encode(.button(2, 0, 1)))
        }
    }

    func testPencilOwnsCommandThroughLongDragAndRetiresOnce() {
        var now: TimeInterval = 0
        let e = engine(clock: { now }); var events: [IPadInputEvent] = []
        e.emit = { events.append($0) }; e.physicalKeyIsDown = { _ in nil }
        e.withPointerCommand(true) { e.begin(id: 1, pencil: true, point: .zero, normalized: .zero) }
        XCTAssertEqual(events.first, .key(0xe0, 0))
        now = 5; e.tick(); XCTAssertFalse(events.contains(.key(0xe0, 1)))
        e.end(id: 1, point: .zero, normalized: .zero, cancelled: true)
        XCTAssertEqual(Array(events.suffix(2)), [.button(1, 1, 1), .key(0xe0, 1)])
        let count = events.count; e.retire(); XCTAssertEqual(events.count, count)
    }

    func testIneligibleOwnedTipSendsOnlyItsTerminalWithoutMovingOrReplaying() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
        events.removeAll(); e.enabled = false
        e.move(id: 1, point: .zero, normalized: CGPoint(x: 1, y: 1))
        e.end(id: 1, point: .zero, normalized: CGPoint(x: 1, y: 1), cancelled: false)
        XCTAssertEqual(events, [.button(1, 1, 1)])
        e.retire(); e.enabled = true
        e.move(id: 1, point: .zero, normalized: .zero)
        XCTAssertEqual(events.count, 1)
    }

    func testArmedIndicatorPublishesExpiryAndPanelRetirement() {
        var now: TimeInterval = 0
        let session = IPadInputSession(clock: { now }, automaticallyTicks: false)
        session.configure(identity: "pencil", point: true, type: true, direct: true, zoom: true,
            reason: nil, sink: { _ in })
        session.engine.togglePencilRight(); XCTAssertTrue(session.pencilRightArmed)
        now = 5; session.engine.tick(); XCTAssertFalse(session.pencilRightArmed)
        session.engine.togglePencilRight(); XCTAssertTrue(session.pencilRightArmed)
        session.panelPresentationChanged(true); XCTAssertFalse(session.pencilRightArmed)
        session.engine.togglePencilRight(); XCTAssertFalse(session.pencilRightArmed)
        session.panelPresentationChanged(false); session.engine.togglePencilRight()
        XCTAssertTrue(session.pencilRightArmed)
        session.configure(identity: "other-route", point: true, type: true, direct: true, zoom: true,
            reason: nil, sink: { _ in })
        XCTAssertFalse(session.pencilRightArmed)
    }

    func testUIKitHoverUsesVideoViewportAndGeometryChangeRetiresOldButton() {
        let session = IPadInputSession(clock: { 0 }, automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        session.configure(identity: "geometry", point: true, type: true, direct: true, zoom: true,
            reason: nil, sink: { events.append($0) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let controller = UIViewController(); window.rootViewController = controller
        let view = PencilUIKitView(frame: window.bounds)
        controller.view.addSubview(view); view.inputSession = session
        window.isHidden = false
        defer { window.isHidden = true }
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        view.layoutSubviews()
        view.routePencilHover(state: .began, point: CGPoint(x: 200, y: 150))
        XCTAssertEqual(events.last, .pointer(0, 0, 32768, 32768))
        let count = events.count
        view.routePencilHover(state: .changed, point: CGPoint(x: 10, y: 150))
        XCTAssertEqual(events.count, count, "Letterbox cannot move the PC pointer")
        session.engine.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
        events.removeAll()
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(events, [.button(1, 1, 1)])
        view.routePencilHover(state: .ended, point: .zero)
        session.engine.end(id: 1, point: .zero, normalized: .zero, cancelled: false)
        XCTAssertEqual(events.count, 1, "Geometry retirement cannot double-release")
    }
}

// Adapted from the AU8 audit proposals; real shared engine, no UIKit event mocks.
@MainActor final class AU8ExternalMouseRegressionTests: XCTestCase {
    func testStationaryDoubleClickWithoutNeutralHoverBetweenClicks() {
        for mode in [IPadTouchMode.direct, .trackpad] {
            let session = IPadInputSession(clock: { 0 }, automaticallyTicks: false)
            session.engine.mode = mode; session.engine.enabled = true; session.engine.directAvailable = true
            var events: [IPadInputEvent] = []
            session.engine.emit = { events.append($0) }
            let view = PencilUIKitView(frame: .zero)
            for _ in 0..<2 {
                view.routeV2IndirectPointer(point: .zero, normalized: .zero, buttons: 1,
                                            flags: 1, cancelled: false, session: session)
                view.routeV2IndirectPointer(point: .zero, normalized: .zero, buttons: 0,
                                            flags: 4, cancelled: false, session: session)
            }
            XCTAssertEqual(events.filter { if case .button = $0 { return true }; return false },
                           [.button(1, 0, 1), .button(1, 1, 1), .button(1, 0, 2), .button(1, 1, 2)])
        }
    }

    private func engine(_ clock: @escaping () -> TimeInterval = { 0 }) -> IPadInputEngine {
        let e = IPadInputEngine(clock: clock)
        e.enabled = true; e.typeEnabled = true
        e.directAvailable = true; e.zoomAvailable = true
        return e
    }

    func testPencilHoverDoesNotReleasePhysicalMouseDrag() {
        for mode in [IPadTouchMode.direct, .trackpad] {
            let e = engine(); e.mode = mode
            var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
            e.external(point: .zero, normalized: .zero, buttons: 0x1f)
            events.removeAll()
            e.pencilHover(at: CGPoint(x: 0.75, y: 0.75))
            XCTAssertTrue(events.isEmpty, "Pencil cannot release or move a physical drag")
            e.external(point: CGPoint(x: 8, y: 0), normalized: .zero, buttons: 0x1f)
            XCTAssertTrue(events.contains { if case .pointer = $0 { return true }; return false })
            events.removeAll(); e.external(point: .zero, normalized: .zero, buttons: 0)
            XCTAssertEqual(events.filter { if case .button = $0 { return true }; return false },
                (UInt8(1)...UInt8(5)).map { IPadInputEvent.button($0, 1, UInt32($0)) })
        }
    }

    func testMouseOwnedTipIsIgnoredUntilLiftWithoutConsumingRightArm() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.external(point: .zero, normalized: .zero, buttons: 1)
        e.togglePencilRight(); events.removeAll()
        e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
        XCTAssertTrue(events.isEmpty); XCTAssertTrue(e.pencilRightArmed)
        e.external(point: .zero, normalized: .zero, buttons: 0)
        XCTAssertEqual(events.last, .button(1, 1, 1))
        events.removeAll()
        e.move(id: 1, point: .zero, normalized: CGPoint(x: 1, y: 1))
        e.begin(id: 2, pencil: false, point: .zero, normalized: .zero)
        e.end(id: 2, point: .zero, normalized: .zero, cancelled: false)
        e.end(id: 1, point: .zero, normalized: .zero, cancelled: false)
        XCTAssertTrue(events.isEmpty, "Ignored tip and palms cannot acquire the released mouse button")
        e.begin(id: 3, pencil: true, point: .zero, normalized: .zero)
        XCTAssertEqual(events.last, .button(2, 0, 2))
        e.end(id: 3, point: .zero, normalized: .zero, cancelled: true)
        XCTAssertEqual(events.last, .button(2, 1, 2))
    }

    func testPhysicalMouseDownRetiresAnOwnedPencilBeforeAcquiringItsButton() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
        events.removeAll()
        e.external(point: .zero, normalized: .zero, buttons: 1)
        XCTAssertEqual(events, [.button(1, 1, 1), .pointer(0, 0, 0, 0), .button(1, 0, 2)])
        e.end(id: 1, point: .zero, normalized: .zero, cancelled: false)
        XCTAssertEqual(events.last, .button(1, 0, 2), "Old tip Up cannot release the mouse")
        e.external(point: .zero, normalized: .zero, buttons: 0)
        XCTAssertEqual(events.last, .button(1, 1, 2))
    }

    func testPencilPalmGraceDoesNotSuppressExternalWheel() {
        var now: TimeInterval = 0
        let e = engine { now }; var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        for hovering in [true, false] {
            e.pencilHover(at: .zero)
            if !hovering { e.pencilHover(at: nil); now += 0.1 }
            events.removeAll(); e.beginExternalScroll()
            e.externalScroll(CGPoint(x: 0, y: 24), discrete: false)
            XCTAssertTrue(events.contains(.pointer(3, 0, 120, 0)))
            e.endExternalScroll(); events.removeAll()
            e.beginExternalTransform(); e.zoom(scale: 2, at: .zero)
            XCTAssertTrue(events.contains(.pointer(4, 0, 1200, 0)))
            e.endExternalTransform(); events.removeAll()
            e.begin(id: 90, pencil: false, point: .zero, normalized: .zero)
            e.end(id: 90, point: .zero, normalized: .zero, cancelled: false)
            XCTAssertTrue(events.isEmpty, "Only fingers remain palm-fenced")
        }
    }

    func testPencilHoverPreservesExternalFractionalWheelAndRelativeMotion() {
        let e = engine(); e.mode = .trackpad
        var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.external(point: .zero, normalized: .zero, buttons: 1)
        e.external(point: CGPoint(x: 0.25, y: 0), normalized: .zero, buttons: 1)
        e.beginExternalScroll()
        e.externalScroll(CGPoint(x: 0, y: 0.1), discrete: false)
        events.removeAll()
        e.pencilHover(at: CGPoint(x: 0.75, y: 0.75))
        e.externalScroll(CGPoint(x: 0, y: 0.1), discrete: false)
        e.external(point: CGPoint(x: 1, y: 0), normalized: .zero, buttons: 1)
        XCTAssertEqual(events, [.pointer(3, 0, 1, 0), .pointer(1, 0, 1, 0)])
        e.endExternalScroll(); e.external(point: .zero, normalized: .zero, buttons: 0)
    }

    func testExternalMouseMovesAndClicksDuringPencilHoverAndGrace() {
        var now: TimeInterval = 0
        let e = engine { now }; var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        for hovering in [true, false] {
            e.pencilHover(at: .zero)
            if !hovering { e.pencilHover(at: nil); now += 0.1 }
            events.removeAll()
            e.external(point: .zero, normalized: CGPoint(x: 1, y: 1), buttons: 0)
            e.external(point: .zero, normalized: CGPoint(x: 1, y: 1), buttons: 2)
            e.external(point: .zero, normalized: CGPoint(x: 1, y: 1), buttons: 0)
            let transaction: UInt32 = hovering ? 1 : 2
            XCTAssertEqual(events, [.pointer(0, 0, 65535, 65535), .pointer(0, 0, 65535, 65535),
                .button(2, 0, transaction), .pointer(0, 0, 65535, 65535), .button(2, 1, transaction)])
        }
    }

    func testWheelDoesNotReleasePhysicalMouseDrag() {
        for discrete in [false, true] {
            let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
            e.setModifier(.shift, .oneShot)
            e.external(point: .zero, normalized: .zero, buttons: 0x1f)
            events.removeAll(); e.beginExternalScroll()
            e.externalScroll(CGPoint(x: 24, y: 24), discrete: discrete)
            e.endExternalScroll()
            XCTAssertEqual(events, [.pointer(3, 0, 120, -120)], "Wheel keeps every button and its action modifier")
            e.external(point: .zero, normalized: .zero, buttons: 0)
            XCTAssertEqual(events.filter { if case .button = $0 { return true }; return false },
                (UInt8(1)...UInt8(5)).map { IPadInputEvent.button($0, 1, UInt32($0)) })
            XCTAssertEqual(events.last, .key(0xe1, 1))
            let count = events.count; e.retire(); XCTAssertEqual(events.count, count)
        }
    }

    func testTrackpadTransformDoesNotReleasePhysicalRightButton() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.external(point: .zero, normalized: .zero, buttons: 0x1f)
        events.removeAll(); e.beginExternalTransform()
        e.zoom(scale: 2, at: .zero); e.endExternalTransform()
        XCTAssertEqual(events, [.pointer(4, 0, 1200, 0)], "Anchored zoom has no button or Ctrl transitions")
        e.external(point: .zero, normalized: .zero, buttons: 0)
        XCTAssertEqual(events.filter { if case .button = $0 { return true }; return false },
            (UInt8(1)...UInt8(5)).map { IPadInputEvent.button($0, 1, UInt32($0)) })
    }

    func testExternalScrollAndTransformDoNotRetireAnAdmittedPencilTip() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.begin(id: 1, pencil: true, point: .zero, normalized: .zero)
        events.removeAll(); e.beginExternalScroll()
        e.externalScroll(CGPoint(x: 0, y: 24), discrete: true)
        e.beginExternalTransform(); e.zoom(scale: 2, at: .zero)
        e.endExternalTransform()
        XCTAssertEqual(events, [.pointer(3, 0, 120, 0), .pointer(4, 0, 1200, 0)])
        e.end(id: 1, point: .zero, normalized: .zero, cancelled: true)
        XCTAssertEqual(events.last, .button(1, 1, 1))
    }

    func testExternalScrollAndTransformRetireOnlyFingerContactOrSyntheticDrag() {
        for direct in [false, true] {
            for transform in [false, true] {
                let e = engine(); e.mode = direct ? .direct : .trackpad
                var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
                e.setModifier(.control, .oneShot)
                if !direct { e.armDrag() }
                e.begin(id: 1, pencil: false, point: .zero, normalized: .zero)
                events.removeAll()
                if transform { e.beginExternalTransform() } else { e.beginExternalScroll() }
                XCTAssertEqual(events.first, direct ? .touch(.cancel, 1, .zero, 255) : .button(1, 1, 1))
                // The replacing action acquires one-shot ownership before the
                // old finger action retires, so modifiers remain balanced.
                if transform { e.zoom(scale: 2, at: .zero) } else { e.externalScroll(CGPoint(x: 0, y: 24), discrete: true) }
                XCTAssertFalse(events.contains(.key(0xe0, 1)))
                if transform { e.endExternalTransform() } else { e.endExternalScroll() }
                XCTAssertEqual(events.last, .key(0xe0, 1))
                let count = events.count
                e.end(id: 1, point: .zero, normalized: .zero, cancelled: false)
                e.retire(); XCTAssertEqual(events.count, count)
            }
        }
    }

    func testHardwareFenceBlocksEveryExternalStartAndRetiresHeldInputOnce() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.setModifier(.control, .oneShot)
        e.external(point: .zero, normalized: .zero, buttons: 1)
        e.beginExternalScroll(); events.removeAll()
        e.setHardwareCaptureEnabled(false)
        XCTAssertEqual(events, [.button(1, 1, 1), .key(0xe0, 1)])
        XCTAssertFalse(e.isExternalScrolling)
        events.removeAll()
        e.external(point: .zero, normalized: .zero, buttons: 0x1f)
        e.hover(point: .zero, normalized: .zero)
        e.beginExternalScroll(); e.externalScroll(CGPoint(x: 0, y: 24), discrete: false)
        e.externalScroll(CGPoint(x: 0, y: 24), discrete: true)
        e.beginExternalTransform(); e.zoom(scale: 2, at: .zero)
        e.endExternalScroll(); e.endExternalTransform(); e.hoverExited()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(e.isExternalScrolling); XCTAssertFalse(e.isExternalTransforming)
        // Deliberate UI controls retain their separate authority while fenced.
        e.click(2, at: .zero)
        XCTAssertEqual(Array(events.suffix(2)), [.button(2, 0, 2), .button(2, 1, 2)])
    }

    func testFenceReopenRequiresNeutralMaskBeforeNewPhysicalDown() {
        for mode in [IPadTouchMode.direct, .trackpad] {
            let e = engine(); e.mode = mode
            var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
            e.external(point: .zero, normalized: .zero, buttons: 1)
            e.setHardwareCaptureEnabled(false); events.removeAll()
            e.setHardwareCaptureEnabled(true)
            e.external(point: CGPoint(x: 100, y: 0), normalized: .zero, buttons: 1)
            XCTAssertTrue(events.isEmpty, "Held state across a modal boundary cannot replay")
            e.external(point: CGPoint(x: 100, y: 0), normalized: .zero, buttons: 0)
            events.removeAll()
            e.external(point: CGPoint(x: 102, y: 0), normalized: .zero, buttons: 1)
            XCTAssertEqual(events.last, .button(1, 0, 2))
            if mode == .trackpad { XCTAssertEqual(events.first, .pointer(1, 0, 2, 0)) }
            e.external(point: .zero, normalized: .zero, buttons: 0)
            XCTAssertEqual(events.last, .button(1, 1, 2))
        }
    }

    func testIneligiblePhysicalMaskStillReleasesOwnedButtonWithoutNewInput() {
        let e = engine(); var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.external(point: .zero, normalized: .zero, buttons: 1)
        events.removeAll(); e.enabled = false
        e.external(point: .zero, normalized: .zero, buttons: 2)
        XCTAssertEqual(events, [.button(1, 1, 1)], "Only the owned terminal bypasses admission")
        e.retire(); XCTAssertEqual(events.count, 1)
    }

    func testFencedUIKitScrollDoesNotResumeMidGestureAfterPanelClose() throws {
        let suite = "AU8." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = IPadInputSession(defaults: defaults, clock: { 0 }, automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        session.configure(identity: "au8", point: true, type: true, direct: true, zoom: true,
            reason: nil, sink: { events.append($0) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let controller = UIViewController(); window.rootViewController = controller
        let view = PencilUIKitView(frame: window.bounds)
        controller.view.addSubview(view); view.inputSession = session
        view.contentViewport = VideoContentViewport(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        window.isHidden = false; defer { window.isHidden = true }
        session.panelPresentationChanged(true)
        XCTAssertTrue(view.routeV2Scroll(state: .began, point: CGPoint(x: 200, y: 150),
            translation: .zero, discrete: false))
        session.panelPresentationChanged(false)
        XCTAssertTrue(view.routeV2Scroll(state: .changed, point: CGPoint(x: 200, y: 150),
            translation: CGPoint(x: 0, y: 24), discrete: false))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(view.routeV2Scroll(state: .ended, point: .zero, translation: .zero, discrete: false))
        XCTAssertTrue(view.routeV2Scroll(state: .began, point: CGPoint(x: 200, y: 150),
            translation: CGPoint(x: 0, y: 24), discrete: false))
        XCTAssertTrue(events.contains(.pointer(3, 0, 120, 0)))
        session.releaseAll()
    }
}
