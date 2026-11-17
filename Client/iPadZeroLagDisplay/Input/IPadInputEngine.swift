import Foundation
import CoreGraphics

enum IPadInputEvent: Equatable {
    case touch(DirectTouchPhase, UInt64, CGPoint, UInt8)
    case pointer(UInt8, UInt8, Int32, Int32)
    case button(UInt8, UInt8, UInt32)
    // Canonical HID usage; 0x100 is the explicit Windows key (never physical Command).
    case key(UInt16, UInt8)
}

/// UIKit-free arbiter. Time advances only through the injected monotonic clock.
/// All terminals are emitted through the SAME sink that admitted their downs.
@MainActor final class IPadInputEngine {
    var emit: ((IPadInputEvent) -> Void)?
    var changed: (() -> Void)?
    var consumedModifier: ((IPadModifier) -> Void)?
    var openSettings: (() -> Void)?
    var physicalKeyIsDown: ((UInt16) -> Bool?)?
    var enabled = false, typeEnabled = false, directAvailable = false, zoomAvailable = false
    var mode: IPadTouchMode = .direct
    var inertiaEnabled = true, reverseScroll = false
    var relativeScale = CGPoint(x: 1,y: 1)
    private(set) var drag: IPadDragState = .idle { didSet { changed?() } }
    private var nextContactID: UInt64 = 0
    func allocateContactID() -> UInt64 { nextContactID &+= 1; if nextContactID == 0 { nextContactID = 1 }; return nextContactID }
    private let clock: () -> TimeInterval
    private struct Contact {
        let pencil: Bool, start: CGPoint, began: TimeInterval
        var point: CGPoint, normalized: CGPoint
    }
    private var contacts: [UInt64: Contact] = [:]
    private var quarantine: Set<UInt64> = []
    private var pencil: UInt64?
    private var pencilMouse: PencilMouseState
    var precisePencilAvailable = true
    var pencilRightArmed: Bool { pencilMouse.rightArmed }
    private var pencilMayStart: Bool { enabled && hardwareCaptureEnabled && precisePencilAvailable }
    private var native: (id: UInt64, point: CGPoint, pressure: UInt8)?
    private var lastLease: TimeInterval = 0
    private var buttons: Set<UInt8> = []
    private var buttonTransactions: [UInt8: UInt32] = [:]
    private var buttonConnection: UInt64?
    private var lastButtonTransaction: UInt32 = 0
    /// Scope retirement preserves the counter. Only a new connection resets it.
    func beginConnection(_ generation: UInt64) {
        guard buttonConnection != generation else { return }
        retire() // Emit old terminals with their old transactions before resetting.
        buttonConnection = generation; lastButtonTransaction = 0
    }
    private var externalButtons: Set<UInt8> = []
    private var keys: [UInt16: Set<String>] = [:]
    private var physical: Set<UInt16> = []
    // A modal responder owns these presses until their Up; repeats must not replay on close.
    private var quarantinedHardware: Set<UInt16> = []
    private(set) var hardwareCaptureEnabled = true
    func setHardwareCaptureEnabled(_ active: Bool) {
        guard hardwareCaptureEnabled != active else { return }
        hardwareCaptureEnabled = active
        if !active {
            quarantinedHardware.formUnion(physical)
            retire()
        }
    }
    private var modifierStates: [IPadModifier: IPadModifierState] = [:]
    private var actionModifiers: Set<IPadModifier> = []
    // Idempotent scopes: a nested key tap cannot finish an admitted contact.
    private var actionOwners: Set<String> = []
    private var actionModifierOwners: [IPadModifier: Set<String>] = [:]
    private var physicalEvidence: [UInt16: UInt64] = [:]
    private var actionPhysicalEvidence: [UInt16: UInt64] = [:]
    private var uncertainModifiers: Set<UInt16> = []
    private var evidenceSequence: UInt64 = 0
    private var lastHardwareEvent: TimeInterval = 0
    private var lastPointerActionEnd: TimeInterval = 0
    private var commandEvidence: Set<UInt16> = []
    private var preferredCommandSide: UInt16 = 0xe3
    private var currentPointerCommand: Bool?
    private var currentPointerCommandSides: Set<UInt16> = []
    private var commandRestorationEnabled = true
    private var suppressedTap = false, longPressed = false, moved = false
    private var maximumFingers = 0
    private var gestureCancelled = false
    private var gestureBegan: TimeInterval = 0
    private var settingsCandidate = false
    private var twoOrigin: CGPoint?, twoPrevious: CGPoint?
    private var pinchDistance: CGFloat?, pinchPrevious: CGFloat?
    private var pinching = false, scrolling = false
    private var externalScrolling = false
    var isExternalScrolling: Bool { externalScrolling }
    var isExternalTransforming: Bool { actionOwners.contains("transform") }
    private var hoverAnchor: CGPoint?
    private var neutralRequired = false
    private var fractional = CGPoint.zero
    private var wheelFraction = CGPoint.zero
    private var history: [(TimeInterval, CGPoint)] = []
    private var velocity = CGPoint.zero
    private var inertiaStarted: TimeInterval?, inertiaLast: TimeInterval = 0
    private var inertiaDistance: CGFloat = 0

    init(clock: @escaping () -> TimeInterval) {
        self.clock = clock; pencilMouse = PencilMouseState(clock: clock)
    }
    func togglePencilRight() {
        guard pencilMayStart else { return }
        pencilMouse.toggleRight(); changed?()
    }
    func pencilHover(at p: CGPoint?) {
        guard p == nil || pencilMayStart else { return }
        applyPencil(pencilMouse.hover(at: p))
    }
    /// Palm retirement is scoped to direct fingers and their synthetic drag.
    /// Physical buttons, transactions, wheel and trackpad transforms survive.
    private func retireFingerScope() {
        guard !contacts.isEmpty || native != nil || drag != .idle || inertiaStarted != nil ||
              actionOwners.contains("pointer") else { return }
        let preserveExternalRemainders = externalScrolling || isExternalTransforming || !externalButtons.isEmpty
        let priorWheel = wheelFraction, priorRelative = fractional
        stopInertia()
        quarantine.formUnion(contacts.keys); contacts.removeAll()
        cancelNative()
        if pencil == nil {
            for b in buttons.subtracting(externalButtons).sorted() { button(b, false) }
        }
        drag = .idle
        endAction()
        resetGesture()
        if preserveExternalRemainders { wheelFraction = priorWheel; fractional = priorRelative }
    }
    private func claimPencilScope() {
        retireFingerScope()
        if externalButtons.isEmpty { hoverAnchor = nil; fractional = .zero }
    }
    private func applyPencil(_ effects: [PencilMouseState.Effect]) {
        for effect in effects {
            switch effect {
            case .claimFingers: claimPencilScope()
            case let .move(p):
                if externalButtons.isEmpty { send(.pointer(0, 0, normalized(p.x), normalized(p.y))) }
            case let .button(b, down): button(b, down)
            }
        }
        changed?()
    }
    private func beginPencil(id: UInt64, at p: CGPoint) {
        guard pencilMayStart, !quarantine.contains(id), pencilMouse.activeID == nil else { return }
        let effects = pencilMouse.begin(id: id, at: p, pointerAvailable: externalButtons.isEmpty)
        guard !effects.isEmpty else { return }
        // Retire the previous scope before acquiring this action's modifiers.
        claimPencilScope()
        if externalButtons.isEmpty { pencil = id; beginAction("pencil") }
        applyPencil(effects.filter { $0 != .claimFingers })
    }
    private func endPencil(id: UInt64, at p: CGPoint?, cancelled: Bool) {
        guard pencilMouse.activeID == id else { return }
        applyPencil(pencilMouse.end(id: id, at: p, cancelled: cancelled || !pencilMayStart))
        pencil = nil; endAction("pencil")
    }
    private func send(_ e: IPadInputEvent) { emit?(e) }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func usage(_ m: IPadModifier) -> UInt16 {
        switch m { case .control: return 0xe0; case .alt: return 0xe2; case .shift: return 0xe1; case .win: return 0x100 }
    }
    private func own(_ key: UInt16, _ owner: String, _ down: Bool) {
        var owners = keys[key] ?? []
        if down {
            let first = owners.isEmpty
            guard owners.insert(owner).inserted else { return }
            keys[key] = owners; if first { send(.key(key, 0)) }
        } else {
            guard owners.remove(owner) != nil else { return }
            if owners.isEmpty { keys.removeValue(forKey: key); send(.key(key, 1)) }
            else { keys[key] = owners }
        }
    }
    func setModifier(_ m: IPadModifier, _ state: IPadModifierState) {
        modifierStates[m] = state
        own(usage(m), "bar", state == .locked && typeEnabled)
        if state != .oneShot, actionModifiers.remove(m) != nil {
            actionModifierOwners.removeValue(forKey: m)
            own(usage(m), "action", false)
        }
    }
    private func beginAction(_ owner: String = "pointer") {
        guard actionOwners.insert(owner).inserted else { return }
        if isPointerAction(owner) { restorePointerCommand() }
        if actionOwners.count == 1 { actionPhysicalEvidence = physicalEvidence }
        for m in IPadModifier.allCases where typeEnabled && modifierStates[m] == .oneShot {
            actionModifierOwners[m,default: []].insert(owner)
            actionModifiers.insert(m); own(usage(m), "action", true)
        }
    }
    private func endAction(_ owner: String = "pointer") {
        guard actionOwners.remove(owner) != nil else { return }
        defer { if isPointerAction(owner) && !pointerActionIsActive { lastPointerActionEnd = clock() } }
        for m in IPadModifier.allCases where actionModifiers.contains(m) {
            actionModifierOwners[m]?.remove(owner)
            guard actionModifierOwners[m]?.isEmpty == true else { continue }
            actionModifierOwners.removeValue(forKey: m); actionModifiers.remove(m)
            own(usage(m), "action", false)
            if modifierStates[m] == .oneShot { modifierStates[m] = .off; consumedModifier?(m) }
        }
        if actionOwners.isEmpty {
            releaseUnknownActionModifiers()
            actionPhysicalEvidence.removeAll()
        }
    }
    private func canonicalPhysical(_ original: UInt16) -> UInt16 {
        original == 0xe3 ? 0xe0 : original == 0xe7 ? 0xe4 : original
    }
    private func isCommand(_ key: UInt16) -> Bool { key == 0xe3 || key == 0xe7 }
    private func isPointerAction(_ owner: String) -> Bool {
        ["pointer","pencil","click","externalButtons","scroll","transform","wheel","zoom"].contains(owner)
    }
    private var pointerActionIsActive: Bool {
        !contacts.isEmpty || native != nil || !buttons.isEmpty || drag != .idle || externalScrolling ||
            isExternalTransforming || inertiaStarted != nil || actionOwners.contains { isPointerAction($0) }
    }
    /// Current event flags or a positive keyboard query authorize restoration.
    /// Remembered press evidence chooses sides only; nil never authorizes Down.
    /// Scoped flags are never stored as a deferred pointer action.
    func withPointerCommand<T>(_ down: Bool?, _ body: () -> T) -> T {
        let previous = currentPointerCommand, previousSides = currentPointerCommandSides
        currentPointerCommand = down; currentPointerCommandSides.removeAll()
        defer { currentPointerCommand = previous; currentPointerCommandSides = previousSides }
        if let down {
            if down && enabled && typeEnabled {
                var possibleSides: [UInt16] = []
                for key: UInt16 in [0xe3,0xe7] {
                    let query = physicalKeyIsDown?(key)
                    if query == false { commandEvidence.remove(key) }
                    else {
                        possibleSides.append(key)
                        if query == true { commandEvidence.insert(key) }
                    }
                }
                let side = possibleSides.contains(preferredCommandSide) ? preferredCommandSide : (possibleSides.first ?? preferredCommandSide)
                if commandEvidence.isEmpty {
                    commandEvidence.insert(side)
                }
                currentPointerCommandSides = commandEvidence
            } else if !down {
                commandEvidence.removeAll()
                for key: UInt16 in [0xe3,0xe7] { uncertainModifiers.remove(key); releasePhysical(key) }
            }
        }
        return body()
    }
    /// SwiftUI controls have no hardware event. They may use explicit bar
    /// modifiers and existing owners, but cannot acquire a new Command owner.
    func withoutCommandRestoration<T>(_ body: () -> T) -> T {
        let previous = commandRestorationEnabled; commandRestorationEnabled = false
        defer { commandRestorationEnabled = previous }
        return body()
    }
    private func restorePointerCommand() {
        guard enabled, typeEnabled, hardwareCaptureEnabled, commandRestorationEnabled else { return }
        for key: UInt16 in [0xe3,0xe7] {
            if quarantinedHardware.contains(key) { continue }
            let query = physicalKeyIsDown?(key)
            let down = currentPointerCommand.map { $0 && currentPointerCommandSides.contains(key) }
                ?? query ?? false
            if down {
                commandEvidence.insert(key); preferredCommandSide = key
                guard physical.insert(key).inserted else { continue }
                evidenceSequence &+= 1; physicalEvidence[key] = evidenceSequence
                if !actionOwners.isEmpty && actionPhysicalEvidence[key] == nil { actionPhysicalEvidence[key] = evidenceSequence }
                uncertainModifiers.remove(key)
                own(canonicalPhysical(key), "physical\(key)", true)
            } else if query == false || currentPointerCommand == false {
                commandEvidence.remove(key); uncertainModifiers.remove(key); releasePhysical(key)
            }
        }
    }
    private func releasePhysical(_ original: UInt16, uncertain: Bool = false) {
        if isCommand(original) { commandEvidence.remove(original) }
        guard physical.remove(original) != nil else { return }
        physicalEvidence.removeValue(forKey: original)
        if uncertain { uncertainModifiers.insert(original) }
        own(canonicalPhysical(original), "physical\(original)", false)
        if original < 0xe0 { endAction("hardware\(original)") }
    }
    private func releaseUnknownActionModifiers() {
        for key in physical.sorted() where (0xe0...0xe7).contains(key) {
            let state = physicalKeyIsDown?(key)
            if state == false || (state == nil && isCommand(key) && physicalEvidence[key] == actionPhysicalEvidence[key]) {
                releasePhysical(key,uncertain: state == nil)
            }
        }
    }
    func hardware(usage original: UInt16, down: Bool) {
        if !hardwareCaptureEnabled {
            if down { quarantinedHardware.insert(original) } else { quarantinedHardware.remove(original) }
            return
        }
        if quarantinedHardware.contains(original) {
            if !down { quarantinedHardware.remove(original) }
            return
        }
        lastHardwareEvent = clock()
        let canonical = canonicalPhysical(original)
        if down {
            guard typeEnabled else { return }
            cancelInertia()
            if isCommand(original) { commandEvidence.insert(original); preferredCommandSide = original }
            if (0xe0...0xe7).contains(original) {
                evidenceSequence &+= 1; physicalEvidence[original] = evidenceSequence
                if !actionOwners.isEmpty && actionPhysicalEvidence[original] == nil {
                    actionPhysicalEvidence[original] = evidenceSequence
                }
                uncertainModifiers.remove(original)
            }
            if physical.contains(original) {
                if canonical < 0xe0 { send(.key(canonical, 2)) }; return
            }
            physical.insert(original)
            if canonical < 0xe0 { beginAction("hardware\(original)") }
            own(canonical, "physical\(original)", true)
        } else {
            if isCommand(original) { commandEvidence.remove(original) }
            uncertainModifiers.remove(original)
            releasePhysical(original)
        }
    }
    /// Called before an ordinary Down, or for pressesChanged. Only Command
    /// owners use uncertainty release; other physical modifiers need their Up.
    func hardwareModifiers(command: Bool, control: Bool, alt: Bool, shift: Bool, fresh: Bool = false) {
        guard hardwareCaptureEnabled else { return }
        lastHardwareEvent = clock()
        for (held, left, right) in [(command, UInt16(0xe3), UInt16(0xe7)),
                                   (control, 0xe0, 0xe4), (alt, 0xe2, 0xe6), (shift, 0xe1, 0xe5)] {
            let sides: [UInt16] = [left,right]
            if !held { quarantinedHardware.subtract(sides) }
            if sides.contains(where: { quarantinedHardware.contains($0) }) { continue }
            if !held && isCommand(left) {
                for key in sides { uncertainModifiers.remove(key); releasePhysical(key) }
            } else if held {
                let remembered = sides.filter { uncertainModifiers.contains($0) || (isCommand($0) && commandEvidence.contains($0)) }
                for key in remembered { hardware(usage: key,down: true) }
                if !sides.contains(where: { physical.contains($0) }) { hardware(usage: isCommand(left) ? preferredCommandSide : left,down: true) }
                else if fresh {
                    for key in sides where physical.contains(key) { hardware(usage: key,down: true) }
                }
            }
        }
    }
    func hardwareDisconnected() {
        let ordered = physical.sorted {
            let am = (0xe0...0xe7).contains($0), bm = (0xe0...0xe7).contains($1)
            return am != bm ? !am : $0 < $1
        }
        for key in ordered { releasePhysical(key) }
        uncertainModifiers.removeAll(); physicalEvidence.removeAll(); actionPhysicalEvidence.removeAll()
        commandEvidence.removeAll(); preferredCommandSide = 0xe3; currentPointerCommand = nil; currentPointerCommandSides.removeAll()
    }
    func tapKey(_ key: UInt16) {
        guard typeEnabled else { return }; beginAction("tap")
        let canonical: UInt16 = key == 0xe3 || key == 0xe7 ? 0x100 : key
        own(canonical, "tap", true); own(canonical, "tap", false); endAction("tap")
    }
    func shortcut(_ key: UInt16, shift: Bool) {
        guard typeEnabled else { return }; beginAction("shortcut")
        own(0x100, "shortcut", true); if shift { own(0xe1, "shortcut", true) }
        if key != 0 && key != 0xe3 && key != 0xe7 { own(key, "tap", true); own(key, "tap", false) }
        if shift { own(0xe1, "shortcut", false) }; own(0x100, "shortcut", false); endAction("shortcut")
    }
    private func button(_ b: UInt8, _ down: Bool) {
        if down {
            guard !buttons.contains(b), lastButtonTransaction < UInt32.max else { return }
            restorePointerCommand()
            lastButtonTransaction += 1
            buttons.insert(b); buttonTransactions[b] = lastButtonTransaction
            send(.button(b, 0, lastButtonTransaction))
        } else if buttons.remove(b) != nil, let transaction = buttonTransactions.removeValue(forKey: b) {
            send(.button(b, 1, transaction))
        }
    }
    func accessibleMove(to p: CGPoint) {
        guard enabled else { return }; cancelInertia()
        if drag == .latched, mode == .direct, let n = native {
            touch(.update,id: n.id,at: p)
        } else { send(.pointer(0, 0, normalized(p.x), normalized(p.y))) }
    }
    func click(_ b: UInt8, at p: CGPoint) {
        guard enabled else { return }
        if b == 1 && drag == .latched { releaseDrag(); return }
        guard !buttons.contains(b) else { return }; cancelInertia()
        let owner = b == 1 && drag == .armed ? "pointer" : "click"
        beginAction(owner)
        if b == 1 && drag == .armed {
            if mode == .direct && directAvailable { touch(.down,id: allocateContactID(),at: p) }
            else if mode == .trackpad { accessibleMove(to: p); button(1,true) }
            else { endAction(owner); return }
            drag = .latched; return
        }
        accessibleMove(to: p); button(b, true); button(b, false); endAction(owner)
    }
    func armDrag() {
        guard enabled else { return }; cancelInertia()
        if let id = pencilMouse.activeID { quarantine.insert(id); endPencil(id: id, at: nil, cancelled: true) }
        _ = pencilMouse.retire(); changed?()
        quarantine.formUnion(contacts.keys); contacts.removeAll(); pencil = nil
        cancelNative(); for b in buttons.sorted() { button(b,false) }
        externalButtons.removeAll(); hoverAnchor = nil; neutralRequired = true
        drag = .idle; endAction(); endAction("externalButtons")
        endExternalScroll(); endExternalTransform(); resetGesture(); drag = .armed
    }
    func releaseDrag() {
        guard drag != .idle else { return }
        if let n = native { touch(.up,id: n.id,at: n.point,pressure: n.pressure) }
        button(1, false); drag = .idle; suppressedTap = true; endAction()
        if !pointerActionIsActive { lastPointerActionEnd = clock() }
    }
    private func normalized(_ n: CGFloat) -> Int32 { Int32((min(1, max(0, n)) * 65535).rounded()) }
    private func touch(_ phase: DirectTouchPhase, id: UInt64, at p: CGPoint, pressure: UInt8 = 255) {
        if phase == .down { restorePointerCommand(); native = (id, p, pressure); lastLease = clock() }
        else if phase == .update { native?.point = p; native?.pressure = pressure; lastLease = clock() }
        send(.touch(phase, id, p, pressure))
        if phase == .up || phase == .cancel { native = nil }
    }
    private func cancelNative() { if let n = native { touch(.cancel, id: n.id, at: n.point, pressure: n.pressure) } }

    func begin(id: UInt64, pencil isPencil: Bool, point: CGPoint, normalized p: CGPoint, tapCount: Int = 1, pressure: UInt8 = 255) {
        guard enabled, id != 0, contacts[id] == nil else { return }
        cancelInertia()
        if isPencil { beginPencil(id: id, at: p); return }
        if pencilMouse.blocksFingers || quarantine.contains(id) {
            quarantine.insert(id); return
        }
        guard mode != .direct || directAvailable else { return }
        if !externalButtons.isEmpty { quarantine.insert(id); return }
        hoverAnchor = nil
        if contacts.isEmpty { resetGesture(); beginAction() }
        contacts[id] = Contact(pencil: isPencil, start: point, began: clock(), point: point, normalized: p)
        if !isPencil && gestureCancelled { return }
        maximumFingers = max(maximumFingers, contacts.count)
        if contacts.count == 1 {
            if drag == .latched { suppressedTap = true }
            else if mode == .direct { touch(.down, id: id, at: p) }
            else if drag == .armed || tapCount >= 2 { button(1, true); if tapCount >= 2 { suppressedTap = true } }
        } else {
            cancelNative(); button(1, false); if drag != .idle { drag = .idle }
            let (center, span) = geometry(); twoOrigin = center; twoPrevious = center
            pinchDistance = span; pinchPrevious = span
            if contacts.count == 3 { settingsCandidate = clock() - gestureBegan <= 0.150 }
        }
    }
    private func geometry() -> (CGPoint, CGFloat) {
        let c = contacts.sorted { $0.key < $1.key }.map(\.value)
        let center = CGPoint(x: c.reduce(0) { $0 + $1.point.x } / CGFloat(max(1,c.count)), y: c.reduce(0) { $0 + $1.point.y } / CGFloat(max(1,c.count)))
        return (center, c.count == 2 ? distance(c[0].point,c[1].point) : 0)
    }
    private func resetGesture() {
        suppressedTap = false; longPressed = false; moved = false; maximumFingers = 0; gestureCancelled = false
        gestureBegan = clock(); settingsCandidate = false
        twoOrigin = nil; twoPrevious = nil; pinchDistance = nil; pinchPrevious = nil
        pinching = false; scrolling = false; history.removeAll(); wheelFraction = .zero; fractional = .zero
    }
    func move(id: UInt64, point: CGPoint, normalized p: CGPoint, pressure: UInt8 = 255) {
        if pencilMouse.activeID == id {
            if pencilMayStart { applyPencil(pencilMouse.move(id: id, to: p)) }
            return
        }
        guard enabled, !gestureCancelled, var c = contacts[id], !quarantine.contains(id) else { return }
        let previous = c.point; c.point = point; c.normalized = p; contacts[id] = c
        if distance(c.start,point) > 8 { moved = true }
        if maximumFingers >= 2 {
            guard contacts.count == 2 else { return }
            let (center, span) = geometry()
            let before = twoPrevious ?? center; twoPrevious = center
            if let baseline = pinchDistance, baseline > 0, !scrolling,
               abs(span / baseline - 1) >= 0.05 { pinching = true; suppressedTap = true }
            if pinching {
                if let prior = pinchPrevious, prior > 0 { zoom(scale: span / prior, at: centroidNormalized()) }
                pinchPrevious = span; return
            }
            if let start = twoOrigin, distance(start,center) >= 8 { scrolling = true; suppressedTap = true }
            if scrolling { fingerScroll(CGPoint(x: center.x-before.x,y: center.y-before.y)) }
            return
        }
        if mode == .direct {
            if let n = native { touch(.update,id: n.id,at: p) }
        } else if !longPressed {
            relative(CGPoint(x: point.x-previous.x,y: point.y-previous.y))
        }
    }
    /// Update all contacts before classifying span versus centroid movement.
    /// UIKit sets are unordered; sequential classification can invent a pinch.
    func moveBatch(_ samples: [(id: UInt64, point: CGPoint, normalized: CGPoint)]) {
        if contacts.count < 2 || pencil != nil {
            for s in samples { move(id: s.id,point: s.point,normalized: s.normalized) }; return
        }
        var first: (id: UInt64, point: CGPoint, normalized: CGPoint)?
        for s in samples {
            guard var c = contacts[s.id], !quarantine.contains(s.id) else { continue }
            c.point = s.point; c.normalized = s.normalized; contacts[s.id] = c
            if distance(c.start,s.point) > 8 { moved = true }
            if first == nil { first = s }
        }
        if let s = first { move(id: s.id,point: s.point,normalized: s.normalized) }
    }

    private func centroidNormalized() -> CGPoint {
        CGPoint(x: contacts.values.reduce(0) { $0 + $1.normalized.x } / CGFloat(max(1,contacts.count)),
                y: contacts.values.reduce(0) { $0 + $1.normalized.y } / CGFloat(max(1,contacts.count)))
    }
    func end(id: UInt64, point: CGPoint, normalized p: CGPoint, cancelled: Bool) {
        if quarantine.remove(id) != nil { return }
        if pencilMouse.activeID == id { endPencil(id: id, at: p, cancelled: cancelled); return }
        guard let c = contacts[id] else { return }
        defer { if !pointerActionIsActive { lastPointerActionEnd = clock() } }
        if cancelled && !c.pencil && maximumFingers >= 2 {
            // Cancellation belongs to the whole gesture, even if UIKit lifts the
            // remaining contacts normally or adds a finger before the final lift.
            gestureCancelled = true; suppressedTap = true; settingsCandidate = false
            scrolling = false; stopInertia(); cancelNative(); button(1,false)
            drag = .idle; endAction()
        }
        // Always finish with the final location under the old coordinate contract.
        if !cancelled { move(id: id,point: point,normalized: p) }
        contacts.removeValue(forKey: id)
        if maximumFingers == 1 {
            if cancelled { cancelNative(); button(1,false); drag = .idle }
            else if drag == .armed { drag = .latched; suppressedTap = true }
            else if drag == .latched {
                if !moved { releaseDrag() }
            } else if let n = native { touch(.up,id: n.id,at: n.point,pressure: n.pressure) }
            else if buttons.contains(1) { button(1,false) }
            else if mode == .trackpad && !moved && !suppressedTap && !longPressed { button(1,true); button(1,false) }
        }
        if contacts.isEmpty {
            if !gestureCancelled && maximumFingers == 3 && settingsCandidate && !moved && !cancelled && clock()-gestureBegan <= 0.300 {
                openSettings?()
            }
            if !gestureCancelled && maximumFingers == 2 && !suppressedTap && !cancelled { button(2,true); button(2,false) }
            if scrolling && !cancelled && !gestureCancelled { startInertia() }
            if drag == .idle && inertiaStarted == nil { endAction() }
        }
    }
    private func relative(_ delta: CGPoint) {
        fractional.x += delta.x * relativeScale.x; fractional.y += delta.y * relativeScale.y
        let x = Int32(max(-32767,min(32767,fractional.x.rounded(.towardZero))))
        let y = Int32(max(-32767,min(32767,fractional.y.rounded(.towardZero))))
        fractional.x -= CGFloat(x); fractional.y -= CGFloat(y)
        if x != 0 || y != 0 { send(.pointer(1,0,x,y)) }
    }
    func external(point: CGPoint, normalized p: CGPoint, buttons mask: UInt) {
        guard enabled, hardwareCaptureEnabled else {
            // Ineligibility cannot reject an already-owned physical Up, but
            // neither movement nor a new bit may cross this boundary.
            for b in externalButtons.sorted() where mask & (1 << UInt(b-1)) == 0 {
                externalButtons.remove(b); button(b,false)
            }
            if externalButtons.isEmpty { endAction("externalButtons") }
            hoverAnchor = nil; fractional = .zero; neutralRequired = true
            return
        }
        guard contacts.isEmpty, drag == .idle else { return }; cancelInertia()
        // Physical button Down wins arbitration. Retire the old tip before
        // acquiring a new transaction; its later Up cannot release the mouse.
        if let id = pencil {
            guard mask != 0 else { return }
            quarantine.insert(id); endPencil(id: id, at: nil, cancelled: true)
        }
        if neutralRequired {
            hoverAnchor = point
            guard mask == 0 else { return }; neutralRequired = false
        }
        if mode == .trackpad { if let a = hoverAnchor { relative(CGPoint(x: point.x-a.x,y: point.y-a.y)) } }
        else { send(.pointer(0,0,normalized(p.x),normalized(p.y))) }
        hoverAnchor = point
        for b in UInt8(1)...UInt8(5) {
            let down = mask & (1 << UInt(b-1)) != 0
            if down && externalButtons.insert(b).inserted { beginAction("externalButtons"); button(b,true) }
            else if !down && externalButtons.remove(b) != nil { button(b,false) }
        }
        if externalButtons.isEmpty { endAction("externalButtons") }
    }
    func hover(point: CGPoint, normalized p: CGPoint) {
        guard enabled, hardwareCaptureEnabled, contacts.isEmpty, pencil == nil, drag == .idle else { return }
        if mode == .trackpad { if let a = hoverAnchor { relative(CGPoint(x: point.x-a.x,y: point.y-a.y)) } }
        else { send(.pointer(0,0,normalized(p.x),normalized(p.y))) }
        hoverAnchor = point
    }
    func hoverExited() {
        for b in externalButtons.sorted() { button(b,false) }; externalButtons.removeAll()
        hoverAnchor = nil; fractional = .zero
        neutralRequired = true; endAction("externalButtons")
    }
    func zoom(scale: CGFloat, at p: CGPoint) {
        guard enabled, hardwareCaptureEnabled, isExternalTransforming || !pencilMouse.blocksFingers,
              zoomAvailable, scale.isFinite, scale > 0 else { return }
        cancelNative()
        if pencil == nil && !externalButtons.contains(1) { button(1,false) }
        if drag != .idle { drag = .idle }; cancelInertia(); suppressedTap = true
        let amount = Int32(max(-32767,min(32767,(log2(Double(scale)) * 1200).rounded())))
        guard amount != 0 else { return }
        let temporary = !pointerActionIsActive
        if temporary { beginAction("zoom") } else { restorePointerCommand() }
        defer { if temporary { endAction("zoom") } }
        let packed = UInt32(normalized(p.x)) | UInt32(normalized(p.y)) << 16
        send(.pointer(4,0,amount,Int32(bitPattern: packed)))
    }
    func beginExternalScroll() {
        guard enabled, hardwareCaptureEnabled else { return }
        // Acquire before retiring fingers: their one-shot modifier may also
        // belong to this new action. Physical button ownership is independent.
        externalScrolling = true; beginAction("scroll")
        retireFingerScope(); endExternalTransform()
    }
    func endExternalScroll() { externalScrolling = false; endAction("scroll") }
    func beginExternalTransform() {
        guard enabled, hardwareCaptureEnabled else { return }
        beginAction("transform")
        retireFingerScope(); endExternalScroll()
    }
    func endExternalTransform() { endAction("transform") }
    func externalScroll(_ delta: CGPoint, discrete: Bool) {
        guard enabled, hardwareCaptureEnabled else { return }
        if inertiaStarted != nil { cancelInertia() }
        // UIKit owns continuous scrolling AND its momentum. Never start client inertia here.
        let x = discrete ? (delta.x == 0 ? 0 : delta.x > 0 ? 120.0 : -120.0) : Double(delta.x * 5)
        let y = discrete ? (delta.y == 0 ? 0 : delta.y > 0 ? 120.0 : -120.0) : Double(delta.y * 5)
        if !externalScrolling { beginAction("wheel") }
        wheel(CGPoint(x: x,y: y)); if !externalScrolling { endAction("wheel") }
    }
    private func wheel(_ raw: CGPoint) {
        let d = reverseScroll ? CGPoint(x: -raw.x,y: -raw.y) : raw
        if wheelFraction.x * d.x < 0 { wheelFraction.x = 0 }
        if wheelFraction.y * d.y < 0 { wheelFraction.y = 0 }
        wheelFraction.x += d.x; wheelFraction.y += d.y
        let x = Int32(max(-32767,min(32767,wheelFraction.x.rounded(.towardZero))))
        let y = Int32(max(-32767,min(32767,wheelFraction.y.rounded(.towardZero))))
        wheelFraction.x -= CGFloat(x); wheelFraction.y -= CGFloat(y)
        if x != 0 || y != 0 {
            let temporary = !pointerActionIsActive
            if temporary { beginAction("wheel") } else { restorePointerCommand() }
            defer { if temporary { endAction("wheel") } }
            send(.pointer(3,0,y,-x))
        }
    }
    func fingerScroll(_ delta: CGPoint) {
        guard enabled, !pencilMouse.blocksFingers else { return }
        let d = CGPoint(x: delta.x*5,y: delta.y*5), now = clock()
        if let last = history.last, last.1.x*d.x < 0 || last.1.y*d.y < 0 { history.removeAll(); cancelInertia() }
        history.append((now,d)); history.removeAll { now - $0.0 > 0.080 }
        wheel(d)
    }
    func startInertia() {
        guard inertiaEnabled, history.count >= 2 else { return }
        let now = clock(); history.removeAll { now - $0.0 > 0.080 }
        guard let first = history.first, now > first.0 else { return }
        let sum = history.reduce(CGPoint.zero) { CGPoint(x: $0.x+$1.1.x,y: $0.y+$1.1.y) }
        let seconds = CGFloat(now-first.0)
        velocity = CGPoint(x: sum.x/seconds,y: sum.y/seconds)
        let speed = hypot(velocity.x,velocity.y)
        if speed > 6000 { velocity.x *= 6000/speed; velocity.y *= 6000/speed }
        inertiaStarted = now; inertiaLast = now; inertiaDistance = 0
    }
    private func stopInertia() { inertiaStarted = nil; velocity = .zero; history.removeAll(); wheelFraction = .zero }
    func cancelInertia() {
        let wasRunning = inertiaStarted != nil; stopInertia()
        if wasRunning && contacts.isEmpty && drag == .idle { endAction() }
        if wasRunning && !pointerActionIsActive { lastPointerActionEnd = clock() }
    }
    func tick() {
        let now = clock()
        let wasArmed = pencilMouse.rightArmed; pencilMouse.tick()
        if wasArmed != pencilMouse.rightArmed { changed?() }
        for key in physical.sorted() where physicalKeyIsDown?(key) == false {
            releasePhysical(key)
        }
        if !pointerActionIsActive && now-lastHardwareEvent >= 2.0 && now-lastPointerActionEnd >= 2.0 &&
           physical.allSatisfy({ (0xe0...0xe7).contains($0) }) {
            for key in physical.sorted() where isCommand(key) && physicalKeyIsDown?(key) == nil { releasePhysical(key,uncertain: true) }
        }
        guard enabled else { return }
        if let n = native, now-lastLease >= 1.0 / 30 { touch(.update,id: n.id,at: n.point,pressure: n.pressure) }
        if mode == .trackpad, contacts.count == 1, maximumFingers == 1, !moved, !longPressed,
           drag == .idle, !suppressedTap, let c = contacts.values.first, !c.pencil, now-c.began >= 0.500 {
            longPressed = true; suppressedTap = true; button(1,false); button(2,true); button(2,false)
        }
        guard let started = inertiaStarted else { return }
        let dt = now-inertiaLast
        guard dt >= 1.0 / 60 else { return }
        // A paused main thread must not replay a backlog of momentum.
        guard dt <= 0.100, now-started <= 0.800 else { cancelInertia(); endAction(); return }
        let decay = CGFloat(exp(-dt / 0.200)), factor = CGFloat(0.200) * (1-decay)
        var d = CGPoint(x: velocity.x*factor,y: velocity.y*factor)
        let amount = hypot(d.x,d.y), remaining = max(0,2400-inertiaDistance)
        if amount > remaining && amount > 0 { d.x *= remaining/amount; d.y *= remaining/amount }
        inertiaDistance += min(amount,remaining); wheel(d)
        velocity.x *= decay; velocity.y *= decay; inertiaLast = now
        if hypot(velocity.x,velocity.y) < 8 || inertiaDistance >= 2400 { cancelInertia(); endAction() }
    }
    func retire() {
        // Stop delayed work first, then pointer terminals, ordinary keys, modifiers.
        if let id = pencilMouse.activeID { quarantine.insert(id) }
        _ = pencilMouse.retire() // Generic button retirement below retains terminal ordering.
        changed?()
        stopInertia(); externalScrolling = false; quarantine.formUnion(contacts.keys); contacts.removeAll()
        cancelNative(); for b in buttons.sorted() { button(b,false) }
        for key in keys.keys.sorted() where key < 0xe0 { send(.key(key,1)) }
        for key in keys.keys.sorted() where key >= 0xe0 { send(.key(key,1)) }
        keys.removeAll(); physical.removeAll(); externalButtons.removeAll(); modifierStates.removeAll(); actionModifiers.removeAll()
        actionOwners.removeAll(); actionModifierOwners.removeAll()
        physicalEvidence.removeAll(); actionPhysicalEvidence.removeAll(); uncertainModifiers.removeAll()
        commandEvidence.removeAll(); preferredCommandSide = 0xe3; currentPointerCommand = nil; currentPointerCommandSides.removeAll()
        lastPointerActionEnd = clock()
        pencil = nil; drag = .idle
        hoverAnchor = nil; neutralRequired = true; resetGesture()
    }
}
