import XCTest
import UIKit
@testable import iPadCasting

@MainActor final class InputLifetimeRegressionTests: XCTestCase {
    private func engine(_ clock: @escaping () -> TimeInterval = { 0 }) -> IPadInputEngine {
        let e = IPadInputEngine(clock: clock)
        e.enabled = true; e.typeEnabled = true; e.directAvailable = true
        e.physicalKeyIsDown = { _ in nil }
        return e
    }
    func testUncertaintyReleaseCannotRestoreCommandForAnUnmodifiedClick() {
        for command: UInt16 in [0xe3,0xe7] {
            var now: TimeInterval = 0; let e = engine { now }
            let ctrl: UInt16 = command == 0xe3 ? 0xe0 : 0xe4
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.hardware(usage: command,down: true)
            e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
            XCTAssertEqual(out.last,.key(ctrl,1)); out.removeAll()
            now = 3; e.click(1,at: .zero)
            XCTAssertEqual(out,[.pointer(0,0,0,0),.button(1,0,1),.button(1,1,1)])
        }
    }
    func testMoveOnlyCommandFlagsCannotModifyALaterUnflaggedAction() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.withPointerCommand(true) { e.external(point: .zero,normalized: .zero,buttons: 0) }
        out.removeAll(); e.click(1,at: .zero)
        XCTAssertEqual(out,[.pointer(0,0,0,0),.button(1,0,1),.button(1,1,1)])
    }
    func testPanelAndBarActionsNeverRestoreAnUncertainCommandEvenWithAQuery() {
        for query: Bool? in [nil,true] {
            for action in ["click","key","shortcut","drag","nudge"] {
                let name = "CurrentCommand." + UUID().uuidString
                let defaults = UserDefaults(suiteName: name)!
                defer { defaults.removePersistentDomain(forName: name) }
                defaults.set("trackpad",forKey: IPadInputSession.touchModeKey)
                let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
                var out: [IPadInputEvent] = []
                session.configure(identity: "open-panel",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
                session.engine.physicalKeyIsDown = { _ in nil }
                session.engine.hardware(usage: 0xe7,down: true)
                session.engine.hardware(usage: 6,down: true); session.engine.hardware(usage: 6,down: false)
                XCTAssertEqual(out.last,.key(0xe4,1)); out.removeAll()
                session.engine.physicalKeyIsDown = { _ in query }
                switch action {
                case "click": session.click(.left)
                case "key": session.tapKey(hidUsage: 0x50)
                case "shortcut": session.tapWindowsShortcut(hidUsage: 7,shift: false)
                case "drag": session.beginDrag(); session.click(.left); session.releaseDrag()
                default: session.moveAccessibleTarget(.right,coarse: false)
                }
                XCTAssertFalse(out.contains(.key(0xe0,0)),action)
                XCTAssertFalse(out.contains(.key(0xe4,0)),action)
                XCTAssertFalse(out.isEmpty,action)
                session.releaseAll()
            }
        }
    }
    func testCurrentExternalMouseFlagsRestoreReleasedCommandBeforeButtonDown() {
        for command: UInt16 in [0xe3,0xe7] {
            let e = engine(); let ctrl: UInt16 = command == 0xe3 ? 0xe0 : 0xe4
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.hardware(usage: command,down: true)
            e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
            out.removeAll()
            e.withPointerCommand(true) { e.external(point: .zero,normalized: .zero,buttons: 1) }
            e.withPointerCommand(true) { e.external(point: .zero,normalized: .zero,buttons: 0) }
            XCTAssertEqual(out,[.pointer(0,0,0,0),.key(ctrl,0),.button(1,0,1),
                                .pointer(0,0,0,0),.button(1,1,1),.key(ctrl,1)])
            out.removeAll(); e.click(1,at: .zero)
            XCTAssertFalse(out.contains(.key(ctrl,0))) // Prior event flags are not current.
        }
    }
    func testUncertaintyThenTouchWithoutCommandIsPlainAndCannotSeedALaterClick() {
        let e = engine(); e.mode = .trackpad
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true)
        e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
        out.removeAll()
        e.withPointerCommand(false) { e.begin(id: 1,pencil: false,point: .zero,normalized: .zero) }
        e.withPointerCommand(false) { e.end(id: 1,point: .zero,normalized: .zero,cancelled: false) }
        XCTAssertEqual(out,[.button(1,0,1),.button(1,1,1)])
        out.removeAll(); e.click(1,at: .zero)
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
    }
    func testIdleUncertaintyAlsoCannotSeedAnUnflaggedClick() {
        var now: TimeInterval = 0; let e = engine { now }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe7,down: true); now = 2; e.tick()
        XCTAssertEqual(out,[.key(0xe4,0),.key(0xe4,1)])
        out.removeAll(); e.click(1,at: .zero)
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
    }
    func testPanelAndBarKeepExplicitOneShotAndLockedModifiers() {
        for state in [IPadModifierState.oneShot,.locked] {
            for action in ["click","key"] {
                let name = "CurrentCommand." + UUID().uuidString
                let defaults = UserDefaults(suiteName: name)!
                defer { defaults.removePersistentDomain(forName: name) }
                let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
                var out: [IPadInputEvent] = []
                session.configure(identity: "controls",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
                session.engine.physicalKeyIsDown = { _ in nil }
                session.engine.hardware(usage: 0xe7,down: true)
                session.engine.hardware(usage: 6,down: true); session.engine.hardware(usage: 6,down: false)
                out.removeAll(); session.setModifier(.control,state)
                if action == "click" { session.click(.left) } else { session.tapKey(hidUsage: 6) }
                XCTAssertEqual(out.first,.key(0xe0,0))
                XCTAssertFalse(out.contains(.key(0xe4,0)))
                XCTAssertEqual(out.contains(.key(0xe0,1)),state == .oneShot)
                session.releaseAll()
                XCTAssertEqual(out.filter { $0 == .key(0xe0,1) }.count,1)
            }
        }
    }
    func testCurrentPointerFlagsSurviveContactPreemptionOnlyWithinThatEvent() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe7,down: true)
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        out.removeAll()
        e.withPointerCommand(true) { e.begin(id: 2,pencil: true,point: .zero,normalized: .zero) }
        XCTAssertEqual(out,[.touch(.cancel,1,.zero,255),.key(0xe4,1),.key(0xe4,0),.touch(.down,2,.zero,255)])
        e.end(id: 2,point: .zero,normalized: .zero,cancelled: false)
        out.removeAll(); e.click(1,at: .zero)
        XCTAssertFalse(out.contains(.key(0xe4,0)))
    }
    #if targetEnvironment(simulator)
    func testHardwareUpWithoutCommandFlagsClearsCommandEvenForUnknownUsage() {
        let name = "CurrentCommand." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var out: [IPadInputEvent] = []
        session.configure(identity: "keys",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
        session.engine.physicalKeyIsDown = { _ in nil }
        session.engine.hardware(usage: 0xe3,down: true)
        let view = PencilUIKitView(); view.inputSession = session
        view.hardwareKeyUsageForTesting = { _ in nil }
        view.hardwareModifierFlagsForTesting = { _ in [] }
        let press = UIPress()
        XCTAssertEqual(view.unhandledHardwarePresses([press],action: .keyUp),[press])
        XCTAssertEqual(out,[.key(0xe0,0),.key(0xe0,1)])
        out.removeAll(); session.click(.left)
        XCTAssertFalse(out.contains(.key(0xe0,0))); session.releaseAll()
    }
    #endif
    func testPhysicalControlShiftAndAltSurviveShortcutIdleAndPointerUntilTheirOwnUp() {
        for modifier: UInt16 in [0xe0,0xe4,0xe1,0xe5,0xe2,0xe6] {
            var now: TimeInterval = 0; let e = engine { now }
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.hardware(usage: modifier,down: true)
            e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
            XCTAssertFalse(out.contains(.key(modifier,1)))
            now = 3; e.tick(); e.click(1,at: .zero)
            XCTAssertFalse(out.contains(.key(modifier,1)))
            XCTAssertTrue(out.contains(.button(1,0,1)))
            e.hardware(usage: modifier,down: false)
            XCTAssertEqual(out.last,.key(modifier,1))
            XCTAssertEqual(out.filter { $0 == .key(modifier,0) }.count,1)
        }
    }
    func testAggregateFlagsCannotReleasePhysicalControlShiftOrAlt() {
        for modifier: UInt16 in [0xe0,0xe4,0xe1,0xe5,0xe2,0xe6] {
            let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.hardware(usage: modifier,down: true)
            e.hardwareModifiers(command: false,control: false,alt: false,shift: false)
            XCTAssertEqual(out,[.key(modifier,0)])
            e.hardwareDisconnected(); XCTAssertEqual(out.last,.key(modifier,1))
        }
    }
    func testExplicitFalseQueryStillReleasesEveryPhysicalModifier() {
        for modifier: UInt16 in [0xe0,0xe4,0xe1,0xe5,0xe2,0xe6,0xe3,0xe7] {
            let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.hardware(usage: modifier,down: true); e.physicalKeyIsDown = { _ in false }; e.tick()
            let pc: UInt16 = modifier == 0xe3 ? 0xe0 : modifier == 0xe7 ? 0xe4 : modifier
            XCTAssertEqual(out,[.key(pc,0),.key(pc,1)])
        }
    }
    func testUnknownCommandReleaseKeepsSameSidePhysicalControlOwner() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe0,down: true); e.hardware(usage: 0xe3,down: true)
        e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
        XCTAssertEqual(out,[.key(0xe0,0),.key(6,0),.key(6,1)])
        e.hardware(usage: 0xe0,down: false); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testCommandDragKeepsControlForFiveSecondsThroughContactAndLatchEnd() {
        for command: UInt16 in [0xe3,0xe7] {
            for latch in [false,true] {
                var now: TimeInterval = 0; let e = engine { now }; e.mode = latch ? .trackpad : .direct
                let ctrl: UInt16 = command == 0xe3 ? 0xe0 : 0xe4
                var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
                e.hardware(usage: command,down: true)
                if latch { e.armDrag(); e.click(1,at: .zero) }
                else { e.begin(id: 1,pencil: false,point: .zero,normalized: .zero) }
                now = 5; e.tick(); XCTAssertFalse(out.contains(.key(ctrl,1)))
                if latch { e.releaseDrag() }
                else { e.end(id: 1,point: .zero,normalized: .zero,cancelled: false) }
                XCTAssertEqual(out.last,.key(ctrl,1))
            }
        }
    }
    func testCommandShortcutThenEveryPointerActionRestoresSameSideBeforeDown() {
        for command: UInt16 in [0xe3,0xe7] {
            for action in ["direct","pencil","trackpad","click","button","wheel","zoom"] {
                let e = engine(); e.zoomAvailable = true
                let ctrl: UInt16 = command == 0xe3 ? 0xe0 : 0xe4
                var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
                e.hardware(usage: command,down: true); e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
                XCTAssertEqual(out.last,.key(ctrl,1)); out.removeAll()
                // Round eleven: restoration needs flags on this triggering event.
                e.withPointerCommand(true) {
                    switch action {
                    case "direct","pencil":
                        e.begin(id: 1,pencil: action == "pencil",point: .zero,normalized: .zero)
                        XCTAssertTrue(out.contains(.touch(.down,1,.zero,255)))
                        e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
                    case "trackpad":
                        e.mode = .trackpad; e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
                        e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
                    case "button": e.external(point: .zero,normalized: .zero,buttons: 1); e.hoverExited()
                    case "wheel": e.externalScroll(.init(x: 0,y: 24),discrete: true)
                    case "zoom": e.zoom(scale: 1.1,at: .zero)
                    default: e.click(1,at: .zero)
                    }
                }
                let controlDown = out.firstIndex(of: .key(ctrl,0))
                let pointerDown = out.firstIndex {
                    switch $0 {
                    case .touch(.down,_,_,_), .button(_,0,_), .pointer(3,_,_,_), .pointer(4,_,_,_): return true
                    default: return false
                    }
                }
                XCTAssertNotNil(controlDown,action); XCTAssertNotNil(pointerDown,action)
                if let controlDown, let pointerDown { XCTAssertLessThan(controlDown,pointerDown,action) }
                XCTAssertEqual(out.last,.key(ctrl,1),action)
                XCTAssertEqual(out.filter { $0 == .key(ctrl,0) }.count,1,action)
                XCTAssertGreaterThan(out.count,2,action)
            }
        }
    }
    func testCommandIdleClockRestartsAfterLastPointerActionEnds() {
        for action in ["contact","button","drag","scroll","zoom"] {
            var now: TimeInterval = 0; let e = engine { now }
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.hardware(usage: 0xe3,down: true)
            switch action {
            case "contact": e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
            case "button": e.external(point: .zero,normalized: .zero,buttons: 1)
            case "drag": e.mode = .trackpad; e.armDrag(); e.click(1,at: .zero)
            case "scroll": e.beginExternalScroll()
            default: e.beginExternalTransform()
            }
            now = 1; e.hardware(usage: 0xe3,down: true) // Fresh evidence during the action.
            now = 5; e.tick(); XCTAssertFalse(out.contains(.key(0xe0,1)),action)
            switch action {
            case "contact": e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
            case "button": e.hoverExited()
            case "drag": e.releaseDrag()
            case "scroll": e.endExternalScroll()
            default: e.endExternalTransform()
            }
            XCTAssertFalse(out.contains(.key(0xe0,1)),action)
            now = 6.999; e.tick(); XCTAssertFalse(out.contains(.key(0xe0,1)),action)
            now = 7; e.tick(); XCTAssertEqual(out.last,.key(0xe0,1),action)
        }
    }
    func testCurrentPointerFlagsOverrideStaleCommandCacheAndLifecycleClearsIt() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe7,down: true); e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
        out.removeAll(); e.withPointerCommand(false) { e.click(1,at: .zero) }
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
        e.hardware(usage: 0xe7,down: true); e.hardwareDisconnected(); out.removeAll()
        e.click(1,at: .zero)
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
    }
    func testPointerCommandCanBeRestoredFromEventFlagsOrRightSideKeyboardQuery() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.withPointerCommand(true) { e.click(1,at: .zero) }
        XCTAssertEqual(out.first,.key(0xe0,0)); XCTAssertEqual(out.last,.key(0xe0,1))
        e.retire(); out.removeAll(); e.physicalKeyIsDown = { $0 == 0xe7 }
        e.click(1,at: .zero)
        XCTAssertEqual(out.first,.key(0xe4,0)); XCTAssertFalse(out.contains(.key(0xe0,0)))
        e.physicalKeyIsDown = { _ in false }; e.tick(); XCTAssertEqual(out.last,.key(0xe4,1))
        e.retire(); out.removeAll(); e.physicalKeyIsDown = { $0 == 0xe7 }
        e.withPointerCommand(true) { e.click(1,at: .zero) }
        XCTAssertEqual(out.first,.key(0xe4,0)); XCTAssertFalse(out.contains(.key(0xe0,0)))
        e.retire(); out.removeAll(); e.physicalKeyIsDown = { $0 == 0xe3 ? false : nil }
        e.withPointerCommand(true) { e.click(1,at: .zero) }
        XCTAssertEqual(out.first,.key(0xe4,0)); XCTAssertEqual(out.last,.key(0xe4,1))
        e.retire(); out.removeAll(); e.physicalKeyIsDown = { _ in false }
        e.withPointerCommand(true) { e.click(1,at: .zero) }
        // Current event evidence outranks a contradictory controller snapshot.
        XCTAssertEqual(out.first,.key(0xe0,0)); XCTAssertEqual(out.last,.key(0xe0,1))
        e.retire(); out.removeAll()
        e.click(1,at: .zero) // Without current flags, explicit false is authoritative.
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
    }
    func testExplicitCommandUpStillReleasesDuringAnActivePointerAction() {
        var now: TimeInterval = 0; let e = engine { now }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true); e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        now = 1; e.hardware(usage: 0xe3,down: false)
        XCTAssertEqual(out.last,.key(0xe0,1))
        now = 5; e.tick(); e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
        XCTAssertEqual(out.filter { $0 == .key(0xe0,0) }.count,1)
        XCTAssertEqual(out.filter { $0 == .key(0xe0,1) }.count,1)
    }
    func testArmedDragPausesCommandIdleAndRestartsOnRelease() {
        var now: TimeInterval = 0; let e = engine { now }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true); e.armDrag()
        now = 5; e.tick(); XCTAssertEqual(out,[.key(0xe0,0)])
        e.releaseDrag(); now = 6.999; e.tick(); XCTAssertEqual(out,[.key(0xe0,0)])
        now = 7; e.tick(); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testSuppressedContactFinalLiftRestartsCommandIdleClock() {
        var now: TimeInterval = 0; let e = engine { now }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true)
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.begin(id: 2,pencil: false,point: .zero,normalized: .zero)
        now = 1; e.hardware(usage: 0xe3,down: true)
        now = 5; e.end(id: 1,point: .zero,normalized: .zero,cancelled: true)
        e.tick(); XCTAssertFalse(out.contains(.key(0xe0,1)))
        now = 9; e.end(id: 2,point: .zero,normalized: .zero,cancelled: false)
        now = 10.999; e.tick(); XCTAssertFalse(out.contains(.key(0xe0,1)))
        now = 11; e.tick(); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testBlockedPointerFlagsCannotRehydrateCommandAfterAdmissionReturns() {
        let e = engine(); e.enabled = false; e.typeEnabled = false
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.withPointerCommand(true) { e.click(1,at: .zero) }; XCTAssertTrue(out.isEmpty)
        e.enabled = true; e.typeEnabled = true; e.click(1,at: .zero)
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
    }
    func testUnknownCommandReleasesAfterShortcutWithoutItsUp() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true)
        e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
        XCTAssertEqual(out,[.key(0xe0,0),.key(6,0),.key(6,1),.key(0xe0,1)])
    }
    func testFreshModifierEvidenceDefersUnknownReleaseUntilIdleBound() {
        var now: TimeInterval = 0; let e = engine { now }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe7,down: true); e.hardware(usage: 6,down: true)
        now = 0.1; e.hardware(usage: 0xe7,down: true) // Repeat/pressesChanged evidence.
        e.hardware(usage: 6,down: false)
        XCTAssertFalse(out.contains(.key(0xe4,1)))
        now = 2.099; e.tick(); XCTAssertFalse(out.contains(.key(0xe4,1)))
        now = 2.1; e.tick(); XCTAssertEqual(out.last,.key(0xe4,1))
    }
    func testKnownHeldModifierSurvivesActionsAndIdle() {
        var now: TimeInterval = 0; let e = engine { now }; e.physicalKeyIsDown = { _ in true }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true); e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
        now = 10; e.tick(); XCTAssertFalse(out.contains(.key(0xe0,1)))
        e.hardwareDisconnected(); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testUnknownIdleModifierExpiresButNotDuringHeldOrdinaryKey() {
        var now: TimeInterval = 0; let e = engine { now }
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true); e.hardware(usage: 6,down: true)
        now = 10; e.tick(); XCTAssertFalse(out.contains(.key(0xe0,1)))
        e.hardware(usage: 6,down: false); XCTAssertEqual(out.last,.key(0xe0,1))
        e.hardware(usage: 0xe3,down: true)
        now = 11.999; e.tick(); XCTAssertEqual(out.last,.key(0xe0,0))
        now = 12; e.tick(); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testSuccessiveShortcutsRestoreRememberedCommandSideBeforeOrdinaryDown() {
        for command in [UInt16(0xe3),UInt16(0xe7)] {
            let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            let ctrl: UInt16 = command == 0xe3 ? 0xe0 : 0xe4
            e.hardware(usage: command,down: true)
            e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
            e.hardwareModifiers(command: true,control: false,alt: false,shift: false)
            e.hardware(usage: 25,down: true); e.hardware(usage: 25,down: false)
            XCTAssertEqual(out,[.key(ctrl,0),.key(6,0),.key(6,1),.key(ctrl,1),
                                .key(ctrl,0),.key(25,0),.key(25,1),.key(ctrl,1)])
        }
    }
    func testCancellationAndFocusLossRetireUnknownHardwareButKeepBarLock() {
        let e = engine(); e.setModifier(.control,.locked)
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true); e.hardware(usage: 6,down: true)
        e.hardwareDisconnected(); e.hardwareDisconnected()
        XCTAssertEqual(out,[.key(6,0),.key(6,1)])
        e.setModifier(.control,.off); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testScrollTerminalOutsideVideoReleasesOnceForEveryTerminalPhase() {
        for state in [UIGestureRecognizer.State.ended,.cancelled,.failed] {
            let defaults = UserDefaults(suiteName: "InputLifetime." + UUID().uuidString)!
            let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
            var out: [IPadInputEvent] = []
            session.configure(identity: "test",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
            let view = PencilUIKitView(frame: .init(x: 0,y: 0,width: 100,height: 100)); view.inputSession = session
            session.setModifier(.control,.oneShot); session.engine.beginExternalScroll()
            XCTAssertEqual(out,[.key(0xe0,0)])
            for _ in 0..<2 {
                XCTAssertTrue(view.routeV2Scroll(state: state,point: .init(x: -1,y: -1),translation: .zero,discrete: false))
            }
            XCTAssertEqual(out,[.key(0xe0,0),.key(0xe0,1)])
            session.releaseAll()
        }
    }
    func testCancelledMultiFingerGestureSuppressesSurvivorsAndNewFingersUntilAllLift() {
        for mode in [IPadTouchMode.direct,.trackpad] {
            let e = engine(); e.mode = mode
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.setModifier(.shift,.oneShot)
            e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
            e.begin(id: 2,pencil: false,point: .zero,normalized: .zero)
            e.end(id: 1,point: .zero,normalized: .zero,cancelled: true)
            XCTAssertEqual(out.last,.key(0xe1,1))
            out.removeAll()
            e.begin(id: 3,pencil: false,point: .zero,normalized: .zero)
            e.move(id: 2,point: .init(x: 30,y: 0),normalized: .zero)
            e.end(id: 2,point: .zero,normalized: .zero,cancelled: false)
            e.end(id: 3,point: .zero,normalized: .zero,cancelled: false)
            XCTAssertTrue(out.isEmpty)
            e.begin(id: 4,pencil: false,point: .zero,normalized: .zero)
            e.end(id: 4,point: .zero,normalized: .zero,cancelled: false)
            XCTAssertFalse(out.isEmpty) // A genuinely new gesture is admitted.
        }
    }
    func testOneShotArmedDuringExistingContactBelongsOnlyToNestedTap() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.setModifier(.shift,.oneShot); e.tapKey(0x50)
        XCTAssertEqual(Array(out.suffix(4)),[.key(0xe1,0),.key(0x50,0),.key(0x50,1),.key(0xe1,1)])
        e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
        XCTAssertEqual(out.filter { $0 == .key(0xe1,1) }.count,1)
    }
    func testSurfaceCancellationWithoutMatchingPressAndResponderChangeReleasePhysicalOwners() {
        let defaults = UserDefaults(suiteName: "InputLifetime." + UUID().uuidString)!
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var out: [IPadInputEvent] = []
        session.configure(identity: "test",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
        session.engine.physicalKeyIsDown = { _ in true }
        let view = PencilUIKitView(); view.inputSession = session
        view.handleHardwareKey(.keyboardLeftGUI,action: .keyDown)
        XCTAssertTrue(view.unhandledHardwarePresses([],action: .keyUp,phase: .cancelled).isEmpty)
        XCTAssertEqual(out,[.key(0xe0,0),.key(0xe0,1)])
        view.handleHardwareKey(.keyboardLeftGUI,action: .keyDown)
        view.softwareResponderOwnsInput = true
        XCTAssertEqual(Array(out.suffix(2)),[.key(0xe0,0),.key(0xe0,1)])
        session.releaseAll()
    }
    func testTerminalEntryPointsReleaseOnceAfterAdmissionCloses() {
        for action in ["contact","scroll","transform","button"] {
            let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.setModifier(.shift,.oneShot)
            switch action {
            case "contact": e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
            case "scroll": e.beginExternalScroll()
            case "transform": e.beginExternalTransform()
            default: e.external(point: .zero,normalized: .zero,buttons: 1)
            }
            e.enabled = false; e.typeEnabled = false
            for _ in 0..<2 {
                switch action {
                case "contact": e.end(id: 1,point: .zero,normalized: .zero,cancelled: true)
                case "scroll": e.endExternalScroll()
                case "transform": e.endExternalTransform()
                default: e.hoverExited()
                }
            }
            XCTAssertEqual(out.last,.key(0xe1,1),action)
            XCTAssertEqual(out.filter { $0 == .key(0xe1,1) }.count,1,action)
        }
    }
    func testOverlappingHardwareKeysAndScrollKeepOneShotUntilLastOwnerEnds() {
        let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.setModifier(.shift,.oneShot); e.beginExternalScroll()
        e.hardware(usage: 6,down: true); e.hardware(usage: 25,down: true)
        e.tapKey(0x50); e.endExternalScroll(); e.hardware(usage: 6,down: false)
        XCTAssertFalse(out.contains(.key(0xe1,1)))
        e.hardware(usage: 25,down: false); XCTAssertEqual(out.last,.key(0xe1,1))
    }
    #if targetEnvironment(simulator)
    func testUIKitModifierFlagsRestoreRightCommandBeforeSuccessiveShortcut() {
        let defaults = UserDefaults(suiteName: "InputLifetime." + UUID().uuidString)!
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var out: [IPadInputEvent] = []
        session.configure(identity: "test",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
        session.engine.physicalKeyIsDown = { _ in nil }
        let view = PencilUIKitView(); view.inputSession = session
        let press = UIPress(); var usage = UIKeyboardHIDUsage.keyboardC
        view.hardwareKeyUsageForTesting = { _ in usage }
        view.hardwareModifierFlagsForTesting = { _ in .command }
        view.handleHardwareKey(.keyboardRightGUI,action: .keyDown)
        XCTAssertTrue(view.unhandledHardwarePresses([press],action: .keyDown).isEmpty)
        XCTAssertTrue(view.unhandledHardwarePresses([press],action: .keyUp).isEmpty)
        usage = .keyboardV
        XCTAssertTrue(view.unhandledHardwarePresses([press],action: .keyDown).isEmpty)
        XCTAssertTrue(view.unhandledHardwarePresses([press],action: .keyUp).isEmpty)
        XCTAssertEqual(out,[.key(0xe4,0),.key(6,0),.key(6,1),.key(0xe4,1),
                            .key(0xe4,0),.key(25,0),.key(25,1),.key(0xe4,1)])
        session.releaseAll()
    }
    func testUIKitChangedEvidenceReachesEngineThroughSoftwareResponder() {
        var now: TimeInterval = 0
        let defaults = UserDefaults(suiteName: "InputLifetime." + UUID().uuidString)!
        let session = IPadInputSession(defaults: defaults,clock: { now },automaticallyTicks: false)
        var out: [IPadInputEvent] = []
        session.configure(identity: "test",point: true,type: true,direct: true,zoom: true,reason: nil) { out.append($0) }
        session.engine.physicalKeyIsDown = { _ in nil }
        let view = PencilUIKitView(); view.inputSession = session
        view.hardwareModifierFlagsForTesting = { _ in .command }
        let text = RemoteSoftwareKeyboardTextView(); text.keySourceRoutingEnabled = true
        text.onHardwareChanged = { view.hardwarePressesChanged($0) }
        text.onHardwareFocusLost = { session.engine.hardwareDisconnected() }
        session.engine.hardware(usage: 0xe3,down: true); session.engine.hardware(usage: 6,down: true)
        text.pressesChanged([UIPress()],with: nil)
        session.engine.hardware(usage: 6,down: false)
        XCTAssertFalse(out.contains(.key(0xe0,1)))
        now = 2; session.engine.tick(); XCTAssertEqual(out.last,.key(0xe0,1))
        session.engine.hardware(usage: 0xe3,down: true)
        text.textViewDidEndEditing(text); XCTAssertEqual(out.last,.key(0xe0,1))
        session.releaseAll()
    }
    #endif
    func testPencilPreemptionAndScrollTransformReplacementLeaveNoActionOwnerBehind() {
        for transform in [false,true] {
            let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.setModifier(.shift,.oneShot)
            if transform { e.beginExternalTransform(); e.beginExternalScroll() }
            else { e.beginExternalScroll(); e.beginExternalTransform() }
            e.begin(id: 1,pencil: true,point: .zero,normalized: .zero)
            e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
            XCTAssertEqual(out.filter { $0 == .key(0xe1,1) }.count,1)
            out.removeAll(); e.setModifier(.control,.oneShot); e.tapKey(6)
            XCTAssertEqual(out,[.key(0xe0,0),.key(6,0),.key(6,1),.key(0xe0,1)])
        }
    }
    func testNestedKeyAndShortcutKeepDirectContactOneShotUntilTouchUp() {
        for shortcut in [false,true] {
            let e = engine(); var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.setModifier(.shift,.oneShot)
            e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
            if shortcut { e.shortcut(0x50,shift: true) } else { e.tapKey(0x50) }
            XCTAssertFalse(out.contains(.key(0xe1,1)))
            e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
            XCTAssertEqual(out.last,.key(0xe1,1))
            XCTAssertEqual(out.filter { $0 == .key(0xe1,1) }.count,1)
        }
    }
    func testNestedHardwareKeyKeepsLatchedDragOneShotUntilRelease() {
        let e = engine(); e.mode = .trackpad
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.setModifier(.control,.oneShot); e.armDrag(); e.click(1,at: .zero)
        e.hardware(usage: 6,down: true); e.hardware(usage: 6,down: false)
        e.tapKey(0x50); e.shortcut(7,shift: false)
        XCTAssertFalse(out.contains(.key(0xe0,1)))
        e.releaseDrag(); XCTAssertEqual(out.last,.key(0xe0,1))
    }
}

final class IPadInputV2Tests: XCTestCase {
    private struct Fixture: Decodable {
        struct Vector: Decodable { let name: String; let transport: String?; let messageType: UInt8?; let hex: String; let vector: String? }
        let schemaVersion: Int
        let vectors: [Vector]
        let malformed: [Vector]
        struct StateCase: Decodable { let name: String; let valid: Bool }
        let stateCases: [StateCase]?
    }
    private func bytes(_ hex: String) throws -> Data {
        let chars = Array(hex); XCTAssertEqual(chars.count % 2, 0)
        return try Data(stride(from: 0,to: chars.count,by: 2).map { i in
            try XCTUnwrap(UInt8(String(chars[i...i+1]),radix: 16))
        })
    }
    private func roundTrip(_ type: UInt8, _ data: Data) -> Data? {
        switch type {
        case 61, 62: return RemoteFeaturesMessage.decode(data)?.encode()
        case 38: return KeyboardInputCommand.decode(data)?.encode()
        case 40: return TextCommitCommand.decode(data)?.encode()
        case 64: return RemoteScanKeyCommand.decode(data)?.encode()
        case 65: return RemotePointerCommand.decode(data)?.encode()
        case 82: return RemoteDirectTouchCommand.decode(data)?.encode()
        case 83: return IPadPointerV2Command.decode(data)?.encode()
        default: return nil
        }
    }
    func testSharedFixtureGoldenAndMalformedVectors() throws {
        let bundle = Bundle(for: IPadInputV2Tests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "IPadInputV2Golden",withExtension: "json") ?? bundle.url(forResource: "IPadInputV2Golden",withExtension: "json",subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode(Fixture.self,from: Data(contentsOf: url))
        XCTAssertEqual(f.schemaVersion,1)
        var tested = 0
        let supportedTypes: Set<UInt8> = [38,40,61,62,64,65,82,83]
        for v in f.vectors where v.transport == "scst" {
            guard let type = v.messageType, supportedTypes.contains(type) else { continue }
            let data = try bytes(v.hex)
            XCTAssertEqual(roundTrip(type,data),data,v.name); tested += 1
        }
        XCTAssertGreaterThanOrEqual(tested,12)
        let byName = Dictionary(uniqueKeysWithValues: f.vectors.map { ($0.name,$0) })
        // Load amended cases by stable name; added fixture entries remain compatible.
        let middleDownVector = try XCTUnwrap(byName["casting-middle-down"])
        let middleUpVector = try XCTUnwrap(byName["casting-middle-up"])
        let middleDown = IPadPointerV2Command.decode(try bytes(middleDownVector.hex))
        let middleUp = IPadPointerV2Command.decode(try bytes(middleUpVector.hex))
        XCTAssertEqual(try XCTUnwrap(middleDown).transaction,1)
        XCTAssertEqual(middleUp?.transaction,middleDown?.transaction)
        let malformedByName = Dictionary(uniqueKeysWithValues: f.malformed.map { ($0.name,$0) })
        for name in ["casting-button-zero-transaction", "casting-kind-0-transaction", "casting-kind-1-transaction", "casting-kind-3-transaction", "casting-kind-4-transaction"] {
            let v = try XCTUnwrap(malformedByName[name],name)
            XCTAssertNil(IPadPointerV2Command.decode(try bytes(v.hex)),name)
        }
        let stateByName = Dictionary(uniqueKeysWithValues: (f.stateCases ?? []).map { ($0.name,$0) })
        for name in ["old-up-after-retirement-and-successor-down", "nonincreasing-button-down-transaction", "transaction-survives-mode-and-capture-retirement"] {
            let c = try XCTUnwrap(stateByName[name],name)
            XCTAssertFalse(c.valid); try assertAmendedTransactionState(c.name)
        } // Other workers may add independent state cases.
        for v in f.malformed {
            guard let parent = v.vector.flatMap({ byName[$0] }), parent.transport == "scst", let type = parent.messageType, supportedTypes.contains(type) else { continue }
            XCTAssertNil(roundTrip(type,try bytes(v.hex)),v.name)
        }
        for v in f.vectors where v.transport == "scst-header" {
            let data = try bytes(v.hex), type = try XCTUnwrap(v.messageType)
            var packet = data; packet.append(Data(repeating: 0,count: 24))
            var messages = 0
            WireStreamParser(generation: 9).consume(packet,generation: 9,receivedAt: 1) { event in
                if case .message(let m) = event { XCTAssertEqual(m.header.type.rawValue,type); XCTAssertEqual(m.payload.count,24); messages += 1 }
                if case .failure = event { XCTFail(v.name) }
            }
            XCTAssertEqual(messages,1,v.name)
        }
    }
    func testNegotiationIntersectionAndNoSpeculativeNewMessage() {
        var n = RemoteFeatureNegotiation(requestedFeatures: 0x1f)
        XCTAssertTrue(n.begin(now: 0)); XCTAssertNil(n.pong(flags: 0,now: 0))
        XCTAssertFalse(n.maySend(feature: 8,token: 7)); XCTAssertFalse(n.maySend(feature: 0x10,token: 7))
        n = RemoteFeatureNegotiation(requestedFeatures: 0x1f); XCTAssertTrue(n.begin(now: 0))
        XCTAssertNotNil(n.pong(flags: 0x4000,now: 0))
        XCTAssertTrue(n.result(flags: 0,payload: RemoteFeaturesMessage(features: 3).encode()))
        XCTAssertFalse(n.maySend(feature: 8,token: 7)); XCTAssertFalse(n.maySend(feature: 0x10,token: 7))
        XCTAssertEqual(n.accepted,3)
    }
    func testV2TerminalOwnershipIsGenerationBound() throws {
        let down = try XCTUnwrap(IPadPointerV2Command(kind: 2,button: 3,a: 0,b: 0,transaction: 1).encode())
        let up = try XCTUnwrap(IPadPointerV2Command(kind: 2,button: 3,a: 1,b: 0,transaction: 1).encode())
        for revision: UInt64 in [1,8,99] {
            var lifetime = InputLifetime()
            XCTAssertFalse(lifetime.accept(kind: .iPadPointerV2,payload: down,generation: 7,revision: revision,mayStart: false))
            XCTAssertTrue(lifetime.accept(kind: .iPadPointerV2,payload: down,generation: 7,revision: revision,mayStart: true))
            XCTAssertFalse(lifetime.accept(kind: .iPadPointerV2,payload: up,generation: 8,revision: revision,mayStart: false))
            XCTAssertTrue(lifetime.accept(kind: .iPadPointerV2,payload: up,generation: 7,revision: revision,mayStart: false))
            XCTAssertFalse(lifetime.accept(kind: .iPadPointerV2,payload: up,generation: 7,revision: revision,mayStart: false))
        }
    }
    func testPointerCodecHasExactLayoutAndOpaqueHighAnchorBits() throws {
        let move = IPadPointerV2Command(kind: 1, button: 0, a: -3, b: 5)
        XCTAssertEqual(Array(try XCTUnwrap(move.encode())), [1,1,0,0,0,0,0,0,0,0,0,0,253,255,255,255,5,0,0,0,0,0,0,0])
        XCTAssertEqual(IPadPointerV2Command.decode(try XCTUnwrap(move.encode())), move)
        let zoom = IPadPointerV2Command(kind: 4, button: 0, a: 120, b: Int32(bitPattern: 0xffff8000))
        XCTAssertEqual(IPadPointerV2Command.decode(try XCTUnwrap(zoom.encode())), zoom)
        XCTAssertNil(IPadPointerV2Command(kind: 4, button: 0, a: 0, b: 0).encode())
        var bad = try XCTUnwrap(move.encode()); bad[4] = 1
        XCTAssertNil(IPadPointerV2Command.decode(bad))
    }
    func testRemoteTouchGoldenAndMalformed() throws {
        let touch = RemoteDirectTouchCommand(phase: .down, token: 0x0102030405060708, contactID: 1, x: 32768, y: 65535)
        XCTAssertEqual(Array(try XCTUnwrap(touch.encode())), [1,0,255,0,8,7,6,5,4,3,2,1,1,0,0,0,0,0,0,0,0,128,255,255])
        XCTAssertEqual(RemoteDirectTouchCommand.decode(try XCTUnwrap(touch.encode())), touch)
        XCTAssertNil(RemoteDirectTouchCommand(phase: .down, token: 0, contactID: 1, x: 0, y: 0).encode())
    }
}

@MainActor final class IPadInputEngineTests: XCTestCase {
    func testLongPressAndLeaseUseInjectedClock() {
        var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now })
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }; e.enabled = true; e.directAvailable = true
        e.begin(id: 1, pencil: false, point: .init(x: 20, y: 20), normalized: .init(x: 0.5, y: 0.5))
        now = 0.04; e.tick()
        XCTAssertEqual(out.filter { if case .touch(.update, _, _, _) = $0 { return true }; return false }.count, 1)
        e.retire(); out.removeAll(); e.mode = .trackpad
        e.begin(id: 2, pencil: false, point: .zero, normalized: .zero)
        now += 0.499; e.tick(); XCTAssertTrue(out.isEmpty)
        now += 0.002; e.tick()
        e.end(id: 2, point: .zero, normalized: .zero, cancelled: false)
        XCTAssertEqual(out.filter { if case .button(2, 0, _) = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(out.contains(.button(1, 0, 1)))
    }
    func testCommandAndControlShareFirstDownLastUp() {
        let e = IPadInputEngine(clock: { 0 }); e.typeEnabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe0, down: true); e.hardware(usage: 0xe3, down: true)
        e.hardware(usage: 0xe0, down: false)
        XCTAssertEqual(out, [.key(0xe0, 0)])
        e.hardware(usage: 0xe3, down: false)
        XCTAssertEqual(out, [.key(0xe0, 0), .key(0xe0, 1)])
    }
    func testDirectUnavailableNeverFallsBackToMouse() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.begin(id: 1, pencil: false, point: .zero, normalized: .zero)
        e.end(id: 1, point: .zero, normalized: .zero, cancelled: false)
        XCTAssertTrue(out.isEmpty)
    }
    func testPinchCancelsContactBeforeZoomWithoutControlEvents() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.directAvailable = true; e.zoomAvailable = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.begin(id: 1, pencil: false, point: .zero, normalized: .zero)
        e.begin(id: 2, pencil: false, point: .init(x: 100,y: 0), normalized: .init(x: 1,y: 0))
        e.move(id: 2, point: .init(x: 120,y: 0), normalized: .init(x: 1,y: 0))
        XCTAssertTrue(out.contains { if case .touch(.cancel, _, _, _) = $0 { return true }; return false })
        XCTAssertTrue(out.contains { if case .pointer(4, _, _, _) = $0 { return true }; return false })
        XCTAssertFalse(out.contains { if case .key = $0 { return true }; return false })
    }
    func testPencilPreemptionQuarantinesBothArrivalOrders() {
        for pencilFirst in [false, true] {
            var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now })
            e.enabled = true; e.directAvailable = true
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            if !pencilFirst { e.begin(id: 1,pencil: false,point: .zero,normalized: .zero) }
            e.begin(id: 2,pencil: true,point: .zero,normalized: .zero)
            if pencilFirst { e.begin(id: 1,pencil: false,point: .zero,normalized: .zero) }
            e.end(id: 1,point: .zero,normalized: .zero,cancelled: true)
            XCTAssertFalse(out.contains { if case .touch(.cancel, 2, _, _) = $0 { return true }; return false })
            e.end(id: 2,point: .zero,normalized: .zero,cancelled: false)
            e.begin(id: 3,pencil: false,point: .zero,normalized: .zero)
            let n = out.count; now = 0.2; e.move(id: 3,point: .zero,normalized: .zero)
            XCTAssertEqual(out.count, n)
        }
    }
    func testExternalButtonsFullMaskAndReentryNeutral() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.mode = .trackpad
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.external(point: .zero, normalized: .zero, buttons: 0x1f)
        XCTAssertEqual(out.filter { if case .button(_, 0, _) = $0 { return true }; return false }.count,5)
        e.hoverExited(); let n = out.count
        e.external(point: .init(x: 900,y: 0),normalized: .zero,buttons: 1)
        XCTAssertEqual(out.count,n)
        e.external(point: .init(x: 900,y: 0),normalized: .zero,buttons: 0)
        e.external(point: .init(x: 902,y: 0),normalized: .zero,buttons: 1)
        XCTAssertTrue(out.contains(.pointer(1,0,2,0)))
    }
    func testRetirementOrdersTerminalsAndDoesNotReplay() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true; e.directAvailable = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe3,down: true); e.hardware(usage: 4,down: true)
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        out.removeAll(); e.retire()
        XCTAssertEqual(out, [.touch(.cancel,1,.zero,255),.key(4,1),.key(0xe0,1)])
        out.removeAll(); e.tick(); e.hardware(usage: 4,down: false); XCTAssertTrue(out.isEmpty)
    }
}

extension IPadInputEngineTests {
    func testInertiaIsBoundedReversalImmediateAndUIKitNeverGetsAddedMomentum() {
        var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now }); e.enabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.fingerScroll(.init(x: 0,y: 100)); now = 0.02; e.fingerScroll(.init(x: 0,y: 100)); e.startInertia()
        out.removeAll()
        for _ in 0..<60 { now += 1.0/60; e.tick() }
        let total = out.reduce(Int32(0)) { sum,event in if case let .pointer(3,_,a,_) = event { return sum+abs(a) }; return sum }
        XCTAssertGreaterThan(total,0); XCTAssertLessThanOrEqual(total,2400)
        let n = out.count; now += 0.1; e.tick(); XCTAssertEqual(n,out.count)
        out.removeAll(); e.externalScroll(.init(x: 0,y: 24),discrete: true)
        XCTAssertEqual(out,[.pointer(3,0,120,0)])
        now += 0.04; e.tick(); XCTAssertEqual(out.count,1)
        out.removeAll(); e.reverseScroll = true; e.externalScroll(.init(x: 0,y: 24),discrete: false)
        XCTAssertEqual(out,[.pointer(3,0,-120,0)])
        out.removeAll(); e.reverseScroll = false; e.fingerScroll(.init(x: 0,y: 0.1)); e.fingerScroll(.init(x: 0,y: -0.4))
        XCTAssertEqual(out,[.pointer(3,0,-2,0)])
    }
    func testDragLatchRetainsOneShotUntilReleaseTap() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true; e.mode = .trackpad
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.setModifier(.shift,.oneShot); e.armDrag()
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
        XCTAssertEqual(e.drag,.latched); XCTAssertEqual(out,[.key(0xe1,0),.button(1,0,1)])
        e.begin(id: 2,pencil: false,point: .zero,normalized: .zero)
        e.end(id: 2,point: .zero,normalized: .zero,cancelled: false)
        XCTAssertEqual(e.drag,.idle); XCTAssertEqual(Array(out.suffix(2)),[.button(1,1,1),.key(0xe1,1)])
    }
    func testNativeDragLeaseFinalCoordinatesAndNoWheelWithPan() {
        var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now }); e.enabled = true; e.directAvailable = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }; e.armDrag()
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.end(id: 1,point: .zero,normalized: .zero,cancelled: false)
        now = 0.04; e.tick(); XCTAssertEqual(e.drag,.latched)
        e.begin(id: 2,pencil: false,point: .zero,normalized: .zero)
        e.move(id: 2,point: .init(x: 20,y: 0),normalized: .init(x: 0.8,y: 0.5))
        e.end(id: 2,point: .init(x: 21,y: 0),normalized: .init(x: 0.9,y: 0.5),cancelled: false)
        XCTAssertFalse(out.contains { if case .pointer(3,_,_,_) = $0 { return true }; return false })
        XCTAssertTrue(out.contains(.touch(.update,1,.init(x: 0.9,y: 0.5),255)))
        e.releaseDrag(); XCTAssertEqual(out.last,.touch(.up,1,.init(x: 0.9,y: 0.5),255))
    }
    func testPhysicalCommandUpReconcilesWithoutReleasingOtherControlOwner() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.hardware(usage: 0xe0,down: true); e.hardware(usage: 0xe3,down: true)
        e.physicalKeyIsDown = { $0 == 0xe3 ? false : true }; e.tick()
        XCTAssertEqual(out,[.key(0xe0,0)])
        e.hardware(usage: 0xe0,down: false); XCTAssertEqual(out.last,.key(0xe0,1))
    }
    func testExplicitWindowsKeyDoesNotUsePhysicalCommandMapping() {
        let e = IPadInputEngine(clock: { 0 }); e.typeEnabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.tapKey(0xe3); XCTAssertEqual(out,[.key(0x100,0),.key(0x100,1)])
    }
    func testActualRoutesRetireTheirEncodedContactAndGateOldHosts() throws {
        let context = RemoteInputContextCommand(state: 1,desktop: 1,token: 7,desktopEpoch: 8,left: 0,top: 0,width: 1920,height: 1080)
        let token = MirrorToken(low: 3,high: 4)
        let ticket = MirrorInputTicket(session: 5,uiRevision: 6,epoch: 7,source: 8,token: token)
        for kind in 0...2 {
            var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now }); e.enabled = true; e.directAvailable = true
            let route = IPadInputRoute(generation: 5,revision: 6,remote: kind == 2,features: 0x1f,context: context,ticket: kind == 1 ? ticket : nil,pointerV2: true)
            var packets: [IPadInputRoute.Packet] = []
            e.emit = { if let p = route.encode($0) { packets.append(p) } }
            e.begin(id: 1,pencil: false,point: .zero,normalized: .zero); e.retire()
            XCTAssertEqual(packets.count,2)
            let terminal = try XCTUnwrap(packets.last)
            if kind == 2 { XCTAssertEqual(terminal.type,.remoteDirectTouch); XCTAssertEqual(RemoteDirectTouchCommand.decode(terminal.payload)?.phase,.cancel) }
            else { XCTAssertEqual(terminal.type,.directTouchContact); XCTAssertEqual(DirectTouchContactCommand.decode(terminal.payload)?.phase,.cancel) }
            if kind == 1 {
                let envelope = MirrorInputEnvelope(epoch: ticket.epoch,source: ticket.source,token: token,sequence: 1,kind: .directTouch,payload: terminal.payload)
                let decoded = try MirrorControlCodec.decodeInput(MirrorControlCodec.encodeInput(envelope))
                XCTAssertEqual(decoded.source,ticket.source); XCTAssertEqual(decoded.kind,.directTouch)
            }
            packets.removeAll(); now = 5; e.tick(); e.move(id: 1,point: .zero,normalized: .zero)
            XCTAssertTrue(packets.isEmpty)
        }
        for remote in [true,false] {
            let old = IPadInputRoute(generation: 5,revision: 6,remote: remote,features: 3,context: context,ticket: nil,pointerV2: false)
            XCTAssertNil(old.encode(.pointer(4,0,120,0)))
            if remote { XCTAssertNil(old.encode(.touch(.down,1,.zero,255))) }
            else { XCTAssertNil(old.encode(.pointer(1,0,1,1))); XCTAssertNotNil(old.encode(.touch(.down,1,.zero,255))) }
            XCTAssertNotNil(old.encode(.key(4,0)))
        }
    }
    func testSuspendedSessionRetiresOnceBeforeNewSinkAndDoesNotReplay() {
        let defaults = UserDefaults(suiteName: "InputV2." + UUID().uuidString)!
        defaults.set("direct",forKey: IPadInputSession.touchModeKey)
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var first: [IPadInputEvent] = [], second: [IPadInputEvent] = []
        session.configure(identity: "first",point: true,type: true,direct: true,zoom: true,reason: nil) { first.append($0) }
        session.engine.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        session.configure(identity: "first",point: false,type: false,direct: true,zoom: false,reason: "paused") { second.append($0) }
        XCTAssertEqual(first.last,.touch(.cancel,1,.zero,255)); XCTAssertTrue(second.isEmpty)
        session.configure(identity: "first",point: false,type: false,direct: true,zoom: false,reason: "paused") { second.append($0) }
        session.engine.tick(); session.engine.hardware(usage: 4,down: true); XCTAssertTrue(second.isEmpty)
        session.configure(identity: "second",point: true,type: true,direct: true,zoom: true,reason: nil) { second.append($0) }
        session.engine.move(id: 1,point: .zero,normalized: .zero); XCTAssertTrue(second.isEmpty)
        session.releaseAll()
    }
    func testSoftwareMarkedTextCommittedWordAndHardwareSourceRemainSeparate() {
        let text = RemoteSoftwareKeyboardTextView(); text.keySourceRoutingEnabled = true; text.deliveryEnabled = true
        var emissions: [SoftwareKeyboardEmission] = []; text.onEmission = { emissions.append($0) }
        let word = "\u{0111}\u{1eb9}p"
        text.setMarkedText(word,selectedRange: NSRange(location: 3,length: 0)); text.consumeCommittedBuffer()
        XCTAssertTrue(emissions.isEmpty)
        text.unmarkText(); text.consumeCommittedBuffer(); XCTAssertEqual(emissions,[.text(word)])
        text.insertText(" "); XCTAssertEqual(text.text,"")
        text.clearCommittedHistory(); text.deleteBackward(); XCTAssertEqual(emissions.last,.key(0x08))
        let defaults = UserDefaults(suiteName: "InputV2." + UUID().uuidString)!
        defaults.set("direct",forKey: IPadInputSession.touchModeKey)
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        session.configure(identity: "keys",point: true,type: true,direct: true,zoom: true,reason: nil) { events.append($0) }
        session.clearTextHistory = { text.clearCommittedHistory() }
        let surface = PencilUIKitView(); surface.inputSession = session; surface.softwareResponderOwnsInput = true
        XCTAssertTrue(surface.handleHardwareKey(.keyboardA,action: .keyDown))
        XCTAssertTrue(surface.handleHardwareKey(.keyboardA,action: .keyUp))
        XCTAssertEqual(events,[.key(4,0),.key(4,1)])
        session.releaseAll()
    }
}

extension IPadInputEngineTests {
    func testSimultaneousFingerPanDoesNotBecomePinch() {
        var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now }); e.enabled = true; e.directAvailable = true; e.zoomAvailable = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.begin(id: 2,pencil: false,point: .init(x: 100,y: 0),normalized: .init(x: 1,y: 0))
        now = 0.02
        e.moveBatch([(1,.init(x: 0,y: 20),.init(x: 0,y: 0.2)),(2,.init(x: 100,y: 20),.init(x: 1,y: 0.2))])
        XCTAssertTrue(out.contains(.pointer(3,0,100,0)))
        XCTAssertFalse(out.contains { if case .pointer(4,_,_,_) = $0 { return true }; return false })
    }
    func testExternalFineWheelRetainsFractionsWithoutMomentum() {
        var now: TimeInterval = 0; let e = IPadInputEngine(clock: { now }); e.enabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.beginExternalScroll()
        e.externalScroll(.init(x: 0,y: 0.1),discrete: false)
        XCTAssertTrue(out.isEmpty)
        e.externalScroll(.init(x: 0,y: 0.1),discrete: false)
        e.endExternalScroll(); XCTAssertEqual(out,[.pointer(3,0,1,0)])
        now = 0.02; e.tick(); XCTAssertEqual(out.count,1)
    }
}

extension IPadInputEngineTests {
    func testClickDoesNotReleaseHardwareButtonAndPencilRetiresLatch() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.mode = .trackpad
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.external(point: .zero,normalized: .zero,buttons: 4)
        let before = out.count; e.click(3,at: .zero); XCTAssertEqual(out.count,before)
        e.external(point: .zero,normalized: .zero,buttons: 0)
        XCTAssertEqual(out.last,.button(3,1,1))
        e.armDrag(); e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.end(id: 1,point: .zero,normalized: .zero,cancelled: false); XCTAssertEqual(e.drag,.latched)
        out.removeAll(); e.begin(id: 2,pencil: true,point: .zero,normalized: .zero)
        XCTAssertEqual(out.first,.button(1,1,2)); XCTAssertEqual(out.last,.button(1,0,3)); XCTAssertEqual(e.drag,.idle)
    }
}

extension IPadInputEngineTests {
    func testQueueRetirementPrecedesPointerKeyAndModifierTerminals() {
        let defaults = UserDefaults(suiteName: "InputV2." + UUID().uuidString)!
        defaults.set("direct",forKey: IPadInputSession.touchModeKey)
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var order: [String] = []
        session.configure(identity: "owned",point: true,type: true,direct: true,zoom: true,reason: nil) { e in
            switch e {
            case .touch(.cancel,_,_,_): order.append("contact")
            case .key(4,1): order.append("key")
            case .key(0xe0,1): order.append("modifier")
            default: break
            }
        }
        session.retireQueuedInput = { order.append("queue") }
        session.engine.hardware(usage: 0xe3,down: true); session.engine.hardware(usage: 4,down: true)
        session.engine.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        session.releaseAll(); XCTAssertEqual(order,["queue","contact","key","modifier"])
    }
    func testKeyboardDisconnectKeepsBarOwnerAndReleasesPhysicalKeys() {
        let e = IPadInputEngine(clock: { 0 }); e.typeEnabled = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.setModifier(.control,.locked); e.hardware(usage: 0xe3,down: true); e.hardware(usage: 4,down: true)
        e.hardwareDisconnected(); XCTAssertEqual(out,[.key(0xe0,0),.key(4,0),.key(4,1)])
        e.setModifier(.control,.off); XCTAssertEqual(out.last,.key(0xe0,1))
    }
}

extension IPadInputEngineTests {
    func testEveryDeviceRetirementHasTerminalParityAcrossActualPacketRoutes() throws {
        let context = RemoteInputContextCommand(state: 1,desktop: 1,token: 7,desktopEpoch: 8,left: 0,top: 0,width: 1920,height: 1080)
        let ticket = MirrorInputTicket(session: 5,uiRevision: 6,epoch: 7,source: 8,token: MirrorToken(low: 3,high: 4))
        for remote in [false,true] {
            for mirror in [false,true] where !remote || !mirror {
                for device in ["key","button","finger","pencil"] {
                    let route = IPadInputRoute(generation: 5,revision: 6,remote: remote,features: 0x1f,context: context,ticket: mirror ? ticket : nil,pointerV2: true)
                    let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true; e.directAvailable = true
                    var packets: [IPadInputRoute.Packet] = []; e.emit = { if let p = route.encode($0) { packets.append(p) } }
                    switch device {
                    case "key": e.hardware(usage: 4,down: true)
                    case "button": e.external(point: .zero,normalized: .zero,buttons: 4)
                    default: e.begin(id: 1,pencil: device == "pencil",point: .zero,normalized: .zero)
                    }
                    packets.removeAll(); e.enabled = false; e.typeEnabled = false; e.retire()
                    XCTAssertEqual(packets.count,1,device)
                    let packet = try XCTUnwrap(packets.first)
                    switch device {
                    case "key":
                        if remote { XCTAssertEqual(RemoteScanKeyCommand.decode(packet.payload)?.action,1) }
                        else { XCTAssertEqual(KeyboardInputCommand.decode(packet.payload)?.action,.keyUp) }
                    case "button":
                        if remote { XCTAssertEqual(RemotePointerCommand.decode(packet.payload)?.a,1) }
                        else { XCTAssertTrue(IPadPointerV2Command.decode(packet.payload)?.terminal == true) }
                    default:
                        if remote { XCTAssertEqual(RemoteDirectTouchCommand.decode(packet.payload)?.phase,.cancel) }
                        else { XCTAssertEqual(DirectTouchContactCommand.decode(packet.payload)?.phase,.cancel) }
                    }
                    if mirror {
                        let kind = try XCTUnwrap(MirrorInputKind(rawValue: packet.type.rawValue))
                        let envelope = MirrorInputEnvelope(epoch: ticket.epoch,source: ticket.source,token: ticket.token,sequence: 1,kind: kind,payload: packet.payload)
                        XCTAssertEqual(try MirrorControlCodec.decodeInput(MirrorControlCodec.encodeInput(envelope)).token,ticket.token)
                    }
                    packets.removeAll(); e.retire(); XCTAssertTrue(packets.isEmpty)
                }
            }
        }
    }
    func testSettingsMigrationAndChangesUseVersionedKeysOnly() {
        let name = "InputV2." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("auto",forKey: RemoteMouseModeStore.key)
        let migrated = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        XCTAssertEqual(migrated.touchMode,.trackpad)
        XCTAssertTrue(migrated.scrollInertiaEnabled); XCTAssertFalse(migrated.reverseScrollEnabled)
        migrated.selectTouchMode(.direct); migrated.setScrollInertia(false); migrated.setReverseScroll(true)
        let restored = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        XCTAssertEqual(restored.touchMode,.direct); XCTAssertFalse(restored.scrollInertiaEnabled); XCTAssertTrue(restored.reverseScrollEnabled)
    }
}

extension IPadInputEngineTests {
    func testOneShotCanTransferToLockAndExplicitOffKeepsPhysicalOwner() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true; e.directAvailable = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.setModifier(.control,.oneShot); e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        XCTAssertEqual(out.first,.key(0xe0,0)); let count = out.count
        e.setModifier(.control,.locked); XCTAssertEqual(out.count,count)
        e.hardware(usage: 0xe3,down: true); e.setModifier(.control,.off); XCTAssertEqual(out.count,count)
        e.hardware(usage: 0xe3,down: false); XCTAssertEqual(out.last,.key(0xe0,1))
        e.retire()
    }
    func testDuplicateContactAndWrongTerminalCannotStealScope() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.directAvailable = true
        var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.begin(id: 1,pencil: false,point: .zero,normalized: .zero)
        e.end(id: 99,point: .zero,normalized: .zero,cancelled: true)
        XCTAssertEqual(out,[.touch(.down,1,.zero,255)])
        e.retire(); XCTAssertEqual(out.last,.touch(.cancel,1,.zero,255))
    }
}

extension IPadInputEngineTests {
    func testAccessibleDragPlacementMoveAndReleaseRespectMode() {
        for mode in [IPadTouchMode.direct,.trackpad] {
            let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.directAvailable = true; e.mode = mode
            var out: [IPadInputEvent] = []; e.emit = { out.append($0) }
            e.armDrag(); e.click(1,at: .init(x: 0.2,y: 0.3)); XCTAssertEqual(e.drag,.latched)
            e.accessibleMove(to: .init(x: 0.8,y: 0.7))
            let before = out.count; e.click(1,at: .init(x: 0.8,y: 0.7)); XCTAssertEqual(out.count,before+1)
            XCTAssertEqual(e.drag,.idle)
            if mode == .direct {
                XCTAssertEqual(out.last,.touch(.up,1,.init(x: 0.8,y: 0.7),255))
                XCTAssertFalse(out.contains { if case .pointer = $0 { return true }; return false })
            } else { XCTAssertEqual(out.last,.button(1,1,1)) }
        }
    }
}

extension IPadInputV2Tests {
    func testAmendedButtonTransactionCodecRejectsWrongKindAndReservedBytes() throws {
        let down = IPadPointerV2Command(kind: 2,button: 3,a: 0,b: 0,transaction: 1)
        let encoded = try XCTUnwrap(down.encode())
        XCTAssertEqual(Array(encoded),[1,2,0,3,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0])
        XCTAssertEqual(IPadPointerV2Command.decode(encoded),down)
        XCTAssertNil(IPadPointerV2Command(kind: 2,button: 3,a: 0,b: 0,transaction: 0).encode())
        for kind: UInt8 in [0,1,3,4] {
            XCTAssertNil(IPadPointerV2Command(kind: kind,button: 0,a: 120,b: 0,transaction: 1).encode())
        }
        var reserved = encoded; reserved[8] = 1; XCTAssertNil(IPadPointerV2Command.decode(reserved))
    }
}

extension IPadInputEngineTests {
    func testTransactionsSurviveScopeRetirementAndResetOnlyOnNewConnection() {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true
        var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.beginConnection(7)
        e.external(point: .zero,normalized: .zero,buttons: 0)
        e.external(point: .zero,normalized: .zero,buttons: 4)
        e.retire(); XCTAssertEqual(Array(events.suffix(2)),[.button(3,0,1),.button(3,1,1)])
        events.removeAll(); e.beginConnection(7)
        e.external(point: .zero,normalized: .zero,buttons: 0)
        e.external(point: .zero,normalized: .zero,buttons: 4)
        XCTAssertEqual(events.last,.button(3,0,2))
        events.removeAll(); e.beginConnection(8)
        XCTAssertEqual(events.last,.button(3,1,2))
        e.external(point: .zero,normalized: .zero,buttons: 0)
        e.external(point: .zero,normalized: .zero,buttons: 4)
        XCTAssertEqual(events.last,.button(3,0,1))
    }
    func testStandaloneWindowsShortcutAndChordsUseExplicitWinOwnership() {
        let e = IPadInputEngine(clock: { 0 }); e.typeEnabled = true
        var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.shortcut(0,shift: false)
        XCTAssertEqual(events,[.key(0x100,0),.key(0x100,1)])
        events.removeAll(); e.shortcut(0x16,shift: true)
        XCTAssertEqual(events,[.key(0x100,0),.key(0xe1,0),.key(0x16,0),.key(0x16,1),.key(0xe1,1),.key(0x100,1)])
    }
}

extension IPadInputV2Tests {
    private func assertAmendedTransactionState(_ name: String) throws {
        func payload(_ action: Int32, _ transaction: UInt32) throws -> Data {
            try XCTUnwrap(IPadPointerV2Command(kind: 2,button: 3,a: action,b: 0,transaction: transaction).encode())
        }
        var lifetime = InputLifetime()
        XCTAssertTrue(lifetime.accept(kind: .iPadPointerV2,payload: try payload(0,1),generation: 7,revision: 1,mayStart: true))
        // Retirement terminal keeps the old transaction, even after eligibility closes.
        XCTAssertTrue(lifetime.accept(kind: .iPadPointerV2,payload: try payload(1,1),generation: 7,revision: 1,mayStart: false))
        if name == "nonincreasing-button-down-transaction" {
            XCTAssertFalse(lifetime.accept(kind: .iPadPointerV2,payload: try payload(0,1),generation: 7,revision: 2,mayStart: true))
        } else {
            XCTAssertTrue(lifetime.accept(kind: .iPadPointerV2,payload: try payload(0,2),generation: 7,revision: 2,mayStart: true))
            XCTAssertFalse(lifetime.accept(kind: .iPadPointerV2,payload: try payload(1,1),generation: 7,revision: 2,mayStart: false))
            XCTAssertTrue(lifetime.accept(kind: .iPadPointerV2,payload: try payload(1,2),generation: 7,revision: 2,mayStart: false))
        }
    }
    func testTransactionOwnershipRejectsLateUpAndNonIncreasingDown() throws {
        try assertAmendedTransactionState("old-up-after-retirement-and-successor-down")
        try assertAmendedTransactionState("nonincreasing-button-down-transaction")
    }
}

extension IPadInputEngineTests {
    func testWindowsModifierMaterializesForKeysAndPointerInAllSessionTypes() throws {
        let context = RemoteInputContextCommand(state: 1,desktop: 1,token: 7,desktopEpoch: 8,left: 0,top: 0,width: 1920,height: 1080)
        let ticket = MirrorInputTicket(session: 5,uiRevision: 6,epoch: 7,source: 8,token: MirrorToken(low: 3,high: 4))
        for routeKind in 0...2 {
            for locked in [false,true] {
                for pointer in [false,true] {
                    let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true
                    let route = IPadInputRoute(generation: 5,revision: 6,remote: routeKind == 2,features: 0x1f,context: context,ticket: routeKind == 1 ? ticket : nil,pointerV2: true)
                    var packets: [IPadInputRoute.Packet] = []; e.emit = { if let p = route.encode($0) { packets.append(p) } }
                    e.setModifier(.win,locked ? .locked : .oneShot)
                    if pointer { e.click(1,at: .zero) } else { e.tapKey(4) }
                    if locked { e.setModifier(.win,.off) }
                    let first = try XCTUnwrap(packets.first), last = try XCTUnwrap(packets.last)
                    if routeKind == 2 {
                        XCTAssertEqual(first.type,.remoteScanKey); XCTAssertEqual(last.type,.remoteScanKey)
                        XCTAssertEqual(RemoteScanKeyCommand.decode(first.payload)?.scan,0x5b)
                        XCTAssertEqual(RemoteScanKeyCommand.decode(first.payload)?.flags,1)
                        XCTAssertEqual(RemoteScanKeyCommand.decode(first.payload)?.action,0)
                        XCTAssertEqual(RemoteScanKeyCommand.decode(last.payload)?.action,1)
                    } else {
                        XCTAssertEqual(first.type,.keyboardInput); XCTAssertEqual(last.type,.keyboardInput)
                        XCTAssertEqual(KeyboardInputCommand.decode(first.payload)?.virtualKey,0x5b)
                        XCTAssertEqual(KeyboardInputCommand.decode(first.payload)?.action,.keyDown)
                        XCTAssertEqual(KeyboardInputCommand.decode(last.payload)?.action,.keyUp)
                        if routeKind == 1 {
                            for p in packets {
                                let kind = try XCTUnwrap(MirrorInputKind(rawValue: p.type.rawValue))
                                let envelope = MirrorInputEnvelope(epoch: ticket.epoch,source: ticket.source,token: ticket.token,sequence: 1,kind: kind,payload: p.payload)
                                XCTAssertEqual(try MirrorControlCodec.decodeInput(MirrorControlCodec.encodeInput(envelope)).token,ticket.token)
                            }
                        }
                    }
                }
            }
        }
    }
    func testTransactionsAreSharedByButtonsAndPreservedByRetirement() throws {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true; e.typeEnabled = true
        var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.beginConnection(4); e.external(point: .zero,normalized: .zero,buttons: 0)
        e.external(point: .zero,normalized: .zero,buttons: 0x1f)
        XCTAssertEqual(events.filter { if case .button(_,0,_) = $0 { return true }; return false },
                       [.button(1,0,1),.button(2,0,2),.button(3,0,3),.button(4,0,4),.button(5,0,5)])
        events.removeAll(); e.retire()
        XCTAssertEqual(events,[.button(1,1,1),.button(2,1,2),.button(3,1,3),.button(4,1,4),.button(5,1,5)])
        events.removeAll(); e.click(3,at: .zero)
        XCTAssertEqual(Array(events.suffix(2)),[.button(3,0,6),.button(3,1,6)])
    }
}

extension IPadInputEngineTests {
    func testStandaloneWindowsConventionAcrossAllProductionPacketRoutes() throws {
        let context = RemoteInputContextCommand(state: 1,desktop: 1,token: 7,desktopEpoch: 8,left: 0,top: 0,width: 1920,height: 1080)
        let ticket = MirrorInputTicket(session: 5,uiRevision: 6,epoch: 7,source: 8,token: MirrorToken(low: 3,high: 4))
        for kind in 0...2 {
            let defaults = UserDefaults(suiteName: "InputV2." + UUID().uuidString)!
            let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
            let route = IPadInputRoute(generation: 5,revision: 6,remote: kind == 2,features: 0x1f,context: context,ticket: kind == 1 ? ticket : nil,pointerV2: true)
            var packets: [IPadInputRoute.Packet] = []
            session.configure(identity: "win",point: true,type: true,direct: true,zoom: true,reason: nil) { if let p = route.encode($0) { packets.append(p) } }
            session.tapWindowsShortcut(hidUsage: 0,shift: false)
            XCTAssertEqual(packets.count,2)
            let first = try XCTUnwrap(packets.first), last = try XCTUnwrap(packets.last)
            if kind == 2 {
                XCTAssertEqual(RemoteScanKeyCommand.decode(first.payload),RemoteScanKeyCommand(action: 0,flags: 1,scan: 0x5b,token: 7))
                XCTAssertEqual(RemoteScanKeyCommand.decode(last.payload),RemoteScanKeyCommand(action: 1,flags: 1,scan: 0x5b,token: 7))
            } else {
                XCTAssertEqual(KeyboardInputCommand.decode(first.payload),KeyboardInputCommand(action: .keyDown,virtualKey: 0x5b))
                XCTAssertEqual(KeyboardInputCommand.decode(last.payload),KeyboardInputCommand(action: .keyUp,virtualKey: 0x5b))
                if kind == 1 {
                    let envelope = MirrorInputEnvelope(epoch: ticket.epoch,source: ticket.source,token: ticket.token,sequence: 1,kind: .keyboard,payload: first.payload)
                    XCTAssertEqual(try MirrorControlCodec.decodeInput(MirrorControlCodec.encodeInput(envelope)).payload,first.payload)
                }
            }
            session.releaseAll()
        }
    }
    func testRawAndMirrorShareCounterAndNeverRewriteAnOldTerminal() throws {
        let e = IPadInputEngine(clock: { 0 }); e.enabled = true
        let raw = IPadInputRoute(generation: 5,revision: 6,remote: false,features: 0,context: nil,ticket: nil,pointerV2: true)
        let ticket = MirrorInputTicket(session: 5,uiRevision: 7,epoch: 8,source: 9,token: MirrorToken(low: 3,high: 4))
        let mirror = IPadInputRoute(generation: 5,revision: 7,remote: false,features: 0,context: nil,ticket: ticket,pointerV2: true)
        var events: [IPadInputEvent] = []; e.emit = { events.append($0) }; e.beginConnection(5)
        e.external(point: .zero,normalized: .zero,buttons: 0)
        e.external(point: .zero,normalized: .zero,buttons: 4); e.retire()
        let oldUp = try XCTUnwrap(events.last)
        let oldRaw = try XCTUnwrap(raw.encode(oldUp))
        events.removeAll(); e.beginConnection(5)
        e.external(point: .zero,normalized: .zero,buttons: 0)
        e.external(point: .zero,normalized: .zero,buttons: 4)
        let successor = try XCTUnwrap(mirror.encode(try XCTUnwrap(events.last)))
        XCTAssertEqual(IPadPointerV2Command.decode(oldRaw.payload)?.transaction,1)
        XCTAssertEqual(IPadPointerV2Command.decode(successor.payload)?.transaction,2)
        XCTAssertEqual(IPadPointerV2Command.decode(try XCTUnwrap(mirror.encode(oldUp)).payload)?.transaction,1)
        let envelope = MirrorInputEnvelope(epoch: ticket.epoch,source: ticket.source,token: ticket.token,sequence: 1,kind: .iPadPointerV2,payload: successor.payload)
        XCTAssertEqual(try MirrorControlCodec.decodeInput(MirrorControlCodec.encodeInput(envelope)).payload,successor.payload)
    }
    func testSameSideAndBothSideHardwareOwnersAcrossSharedEngine() {
        for side in [UInt16(0),UInt16(4)] {
            let e = IPadInputEngine(clock: { 0 }); e.typeEnabled = true
            var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
            let ctrl: UInt16 = 0xe0+side, command: UInt16 = 0xe3+side
            e.hardware(usage: command,down: true); e.hardware(usage: ctrl,down: true)
            e.hardware(usage: command,down: false); e.hardware(usage: command,down: false)
            XCTAssertEqual(events,[.key(ctrl,0)])
            e.hardwareDisconnected(); XCTAssertEqual(events,[.key(ctrl,0),.key(ctrl,1)])
        }
        let e = IPadInputEngine(clock: { 0 }); e.typeEnabled = true
        var events: [IPadInputEvent] = []; e.emit = { events.append($0) }
        e.hardware(usage: 0xe3,down: true); e.hardware(usage: 0xe7,down: true)
        e.hardware(usage: 0xe3,down: false); e.hardware(usage: 0xe7,down: false)
        XCTAssertEqual(events,[.key(0xe0,0),.key(0xe4,0),.key(0xe0,1),.key(0xe4,1)])
    }
}

extension IPadInputEngineTests {
    func testModeAndCaptureRetirementDoNotResetConnectionTransaction() {
        let name = "InputV2." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("direct",forKey: IPadInputSession.touchModeKey)
        let session = IPadInputSession(defaults: defaults,clock: { 0 },automaticallyTicks: false)
        var events: [IPadInputEvent] = []
        let sink: (IPadInputEvent) -> Void = { events.append($0) }
        session.configure(identity: "connection",point: true,type: true,direct: true,zoom: true,reason: nil,sink: sink)
        session.engine.beginConnection(7); session.click(.middle)
        session.selectTouchMode(.trackpad); session.click(.middle)
        session.configure(identity: "connection",point: false,type: false,direct: true,zoom: false,reason: "paused",sink: sink)
        session.configure(identity: "connection",point: true,type: true,direct: true,zoom: true,reason: nil,sink: sink)
        session.click(.middle)
        let downs = events.filter { if case .button(_,0,_) = $0 { return true }; return false }
        XCTAssertEqual(downs,[.button(3,0,1),.button(3,0,2),.button(3,0,3)])
        session.releaseAll()
    }
}
