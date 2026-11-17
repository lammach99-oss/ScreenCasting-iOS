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
        e.beginExternalScroll(); e.externalScroll(CGPoint(x: 0, y: 10), discrete: false)
        e.beginExternalTransform(); e.zoom(scale: 2, at: .zero)
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
