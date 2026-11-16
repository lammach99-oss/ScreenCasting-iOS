import Foundation
import CoreGraphics

enum IPadInputEvent: Equatable {
    case touch(DirectTouchPhase, UInt64, CGPoint, UInt8)
    case pointer(UInt8, UInt8, Int32, Int32)
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
    private var palmUntil: TimeInterval = 0
    private var native: (id: UInt64, point: CGPoint, pressure: UInt8)?
    private var lastLease: TimeInterval = 0
    private var buttons: Set<UInt8> = []
    private var externalButtons: Set<UInt8> = []
    private var keys: [UInt16: Set<String>] = [:]
    private var physical: Set<UInt16> = []
    private var modifierStates: [IPadModifier: IPadModifierState] = [:]
    private var actionModifiers: Set<IPadModifier> = []
    private var actionActive = false
    private var suppressedTap = false, longPressed = false, moved = false
    private var maximumFingers = 0
    private var gestureBegan: TimeInterval = 0
    private var settingsCandidate = false
    private var twoOrigin: CGPoint?, twoPrevious: CGPoint?
    private var pinchDistance: CGFloat?, pinchPrevious: CGFloat?
    private var pinching = false, scrolling = false
    private var externalScrolling = false
    private var hoverAnchor: CGPoint?
    private var neutralRequired = false
    private var fractional = CGPoint.zero
    private var wheelFraction = CGPoint.zero
    private var history: [(TimeInterval, CGPoint)] = []
    private var velocity = CGPoint.zero
    private var inertiaStarted: TimeInterval?, inertiaLast: TimeInterval = 0
    private var inertiaDistance: CGFloat = 0

    init(clock: @escaping () -> TimeInterval) { self.clock = clock }
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
            own(usage(m), "action", false)
        }
    }
    private func beginAction() {
        guard !actionActive else { return }; actionActive = true
        for m in IPadModifier.allCases where typeEnabled && modifierStates[m] == .oneShot {
            actionModifiers.insert(m); own(usage(m), "action", true)
        }
    }
    private func endAction() {
        guard actionActive else { return }; actionActive = false
        for m in IPadModifier.allCases where actionModifiers.contains(m) {
            own(usage(m), "action", false)
            if modifierStates[m] == .oneShot { modifierStates[m] = .off; consumedModifier?(m) }
        }
        actionModifiers.removeAll()
    }
    func hardware(usage original: UInt16, down: Bool) {
        let canonical: UInt16 = original == 0xe3 ? 0xe0 : original == 0xe7 ? 0xe4 : original
        let owner = "physical\(original)"
        if down {
            guard typeEnabled else { return }
            cancelInertia()
            if physical.contains(original) {
                if canonical < 0xe0 { send(.key(canonical, 2)) }; return
            }
            physical.insert(original); if canonical < 0xe0 { beginAction() }; own(canonical, owner, true)
        } else {
            guard physical.remove(original) != nil else { return }
            own(canonical, owner, false)
            if physical.allSatisfy({ (0xe0...0xe7).contains($0) }) && contacts.isEmpty && drag == .idle { endAction() }
        }
    }
    func hardwareDisconnected() {
        let ordered = physical.sorted {
            let am = (0xe0...0xe7).contains($0), bm = (0xe0...0xe7).contains($1)
            return am != bm ? !am : $0 < $1
        }
        for key in ordered { hardware(usage: key,down: false) }
    }
    func tapKey(_ key: UInt16) {
        guard typeEnabled else { return }; beginAction()
        let canonical: UInt16 = key == 0xe3 || key == 0xe7 ? 0x100 : key
        own(canonical, "tap", true); own(canonical, "tap", false); endAction()
    }
    func shortcut(_ key: UInt16, shift: Bool) {
        guard typeEnabled else { return }; beginAction()
        own(0x100, "shortcut", true); if shift { own(0xe1, "shortcut", true) }
        if key != 0xe3 && key != 0xe7 { own(key, "tap", true); own(key, "tap", false) }
        if shift { own(0xe1, "shortcut", false) }; own(0x100, "shortcut", false); endAction()
    }
    private func button(_ b: UInt8, _ down: Bool) {
        if down { if buttons.insert(b).inserted { send(.pointer(2, b, 0, 0)) } }
        else if buttons.remove(b) != nil { send(.pointer(2, b, 1, 0)) }
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
        guard !buttons.contains(b) else { return }; cancelInertia(); beginAction()
        if b == 1 && drag == .armed {
            if mode == .direct && directAvailable { touch(.down,id: allocateContactID(),at: p) }
            else if mode == .trackpad { accessibleMove(to: p); button(1,true) }
            else { endAction(); return }
            drag = .latched; return
        }
        accessibleMove(to: p); button(b, true); button(b, false); endAction()
    }
    func armDrag() {
        guard enabled else { return }; cancelInertia()
        quarantine.formUnion(contacts.keys); contacts.removeAll(); pencil = nil
        cancelNative(); for b in buttons.sorted() { button(b,false) }
        externalButtons.removeAll(); hoverAnchor = nil; neutralRequired = true
        drag = .idle; endAction(); resetGesture(); drag = .armed
    }
    func releaseDrag() {
        guard drag != .idle else { return }
        if let n = native { touch(.up,id: n.id,at: n.point,pressure: n.pressure) }
        button(1, false); drag = .idle; suppressedTap = true; endAction()
    }
    private func normalized(_ n: CGFloat) -> Int32 { Int32((min(1, max(0, n)) * 65535).rounded()) }
    private func touch(_ phase: DirectTouchPhase, id: UInt64, at p: CGPoint, pressure: UInt8 = 255) {
        if phase == .down { native = (id, p, pressure); lastLease = clock() }
        else if phase == .update { native?.point = p; native?.pressure = pressure; lastLease = clock() }
        send(.touch(phase, id, p, pressure))
        if phase == .up || phase == .cancel { native = nil }
    }
    private func cancelNative() { if let n = native { touch(.cancel, id: n.id, at: n.point, pressure: n.pressure) } }

    func begin(id: UInt64, pencil isPencil: Bool, point: CGPoint, normalized p: CGPoint, tapCount: Int = 1, pressure: UInt8 = 255) {
        guard enabled, id != 0, contacts[id] == nil else { return }
        cancelInertia()
        if isPencil {
            guard pencil == nil else { return }
            quarantine.formUnion(contacts.keys); contacts.removeAll()
            cancelNative(); for b in buttons.sorted() { button(b, false) }
            externalButtons.removeAll(); hoverAnchor = nil; neutralRequired = true
            drag = .idle; endAction(); resetGesture(); pencil = id
        } else if pencil != nil || clock() < palmUntil || quarantine.contains(id) {
            quarantine.insert(id); return
        }
        guard isPencil || mode != .direct || directAvailable else { return }
        if !isPencil && !externalButtons.isEmpty { quarantine.insert(id); return }
        hoverAnchor = nil
        if contacts.isEmpty { resetGesture(); beginAction() }
        contacts[id] = Contact(pencil: isPencil, start: point, began: clock(), point: point, normalized: p)
        if isPencil {
            if mode == .direct && directAvailable { touch(.down, id: id, at: p, pressure: 255) }
            else if mode == .trackpad { button(1, true) }
            return
        }
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
        suppressedTap = false; longPressed = false; moved = false; maximumFingers = 0
        gestureBegan = clock(); settingsCandidate = false
        twoOrigin = nil; twoPrevious = nil; pinchDistance = nil; pinchPrevious = nil
        pinching = false; scrolling = false; history.removeAll(); wheelFraction = .zero; fractional = .zero
    }
    func move(id: UInt64, point: CGPoint, normalized p: CGPoint, pressure: UInt8 = 255) {
        guard enabled, var c = contacts[id], !quarantine.contains(id) else { return }
        let previous = c.point; c.point = point; c.normalized = p; contacts[id] = c
        if distance(c.start,point) > 8 { moved = true }
        if c.pencil {
            if let n = native { touch(.update, id: n.id, at: p, pressure: 255) }
            else if mode == .trackpad { relative(CGPoint(x: point.x-previous.x,y: point.y-previous.y)) }; return
        }
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
        guard let c = contacts[id] else { return }
        // Always finish with the final location under the old coordinate contract.
        if !cancelled { move(id: id,point: point,normalized: p) }
        contacts.removeValue(forKey: id)
        if c.pencil {
            if let n = native { touch(cancelled ? .cancel : .up,id: n.id,at: n.point,pressure: n.pressure) }
            button(1,false); pencil = nil; palmUntil = clock() + 0.150
        } else if maximumFingers == 1 {
            if cancelled { cancelNative(); button(1,false); drag = .idle }
            else if drag == .armed { drag = .latched; suppressedTap = true }
            else if drag == .latched {
                if !moved { releaseDrag() }
            } else if let n = native { touch(.up,id: n.id,at: n.point,pressure: n.pressure) }
            else if buttons.contains(1) { button(1,false) }
            else if mode == .trackpad && !moved && !suppressedTap && !longPressed { button(1,true); button(1,false) }
        }
        if contacts.isEmpty {
            if maximumFingers == 3 && settingsCandidate && !moved && !cancelled && clock()-gestureBegan <= 0.300 {
                openSettings?()
            }
            if maximumFingers == 2 && !suppressedTap && !cancelled { button(2,true); button(2,false) }
            if scrolling && !cancelled { startInertia() }
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
        guard enabled, pencil == nil, contacts.isEmpty, drag == .idle else { return }; cancelInertia()
        if neutralRequired {
            hoverAnchor = point
            guard mask == 0 else { return }; neutralRequired = false
        }
        if mode == .trackpad { if let a = hoverAnchor { relative(CGPoint(x: point.x-a.x,y: point.y-a.y)) } }
        else { send(.pointer(0,0,normalized(p.x),normalized(p.y))) }
        hoverAnchor = point
        for b in UInt8(1)...UInt8(5) {
            let down = mask & (1 << UInt(b-1)) != 0
            if down && externalButtons.insert(b).inserted { beginAction(); button(b,true) }
            else if !down && externalButtons.remove(b) != nil { button(b,false) }
        }
        if buttons.isEmpty && drag == .idle { endAction() }
    }
    func hover(point: CGPoint, normalized p: CGPoint) {
        guard enabled, contacts.isEmpty, pencil == nil, drag == .idle else { return }
        if mode == .trackpad { if let a = hoverAnchor { relative(CGPoint(x: point.x-a.x,y: point.y-a.y)) } }
        else { send(.pointer(0,0,normalized(p.x),normalized(p.y))) }
        hoverAnchor = point
    }
    func hoverExited() {
        for b in externalButtons.sorted() { button(b,false) }; externalButtons.removeAll()
        hoverAnchor = nil; fractional = .zero
        neutralRequired = true; if contacts.isEmpty && drag == .idle { endAction() }
    }
    func zoom(scale: CGFloat, at p: CGPoint) {
        guard enabled, pencil == nil, zoomAvailable, scale.isFinite, scale > 0 else { return }
        cancelNative(); button(1,false); if drag != .idle { drag = .idle }; cancelInertia(); suppressedTap = true
        let amount = Int32(max(-32767,min(32767,(log2(Double(scale)) * 1200).rounded())))
        guard amount != 0 else { return }
        let packed = UInt32(normalized(p.x)) | UInt32(normalized(p.y)) << 16
        send(.pointer(4,0,amount,Int32(bitPattern: packed)))
    }
    func beginExternalScroll() {
        guard enabled, pencil == nil else { return }; cancelInertia(); cancelNative()
        for b in buttons.sorted() { button(b,false) }
        quarantine.formUnion(contacts.keys); contacts.removeAll(); drag = .idle
        externalScrolling = true; beginAction()
    }
    func endExternalScroll() { externalScrolling = false; endAction() }
    func beginExternalTransform() {
        guard enabled, pencil == nil else { return }; cancelInertia(); cancelNative()
        for b in buttons.sorted() { button(b,false) }
        quarantine.formUnion(contacts.keys); contacts.removeAll(); drag = .idle
        endAction(); beginAction()
    }
    func endExternalTransform() { endAction() }
    func externalScroll(_ delta: CGPoint, discrete: Bool) {
        guard enabled, pencil == nil else { return }
        if inertiaStarted != nil { cancelInertia() }
        // UIKit owns continuous scrolling AND its momentum. Never start client inertia here.
        let x = discrete ? (delta.x == 0 ? 0 : delta.x > 0 ? 120.0 : -120.0) : Double(delta.x * 5)
        let y = discrete ? (delta.y == 0 ? 0 : delta.y > 0 ? 120.0 : -120.0) : Double(delta.y * 5)
        beginAction(); wheel(CGPoint(x: x,y: y)); if !externalScrolling { endAction() }
    }
    private func wheel(_ raw: CGPoint) {
        let d = reverseScroll ? CGPoint(x: -raw.x,y: -raw.y) : raw
        if wheelFraction.x * d.x < 0 { wheelFraction.x = 0 }
        if wheelFraction.y * d.y < 0 { wheelFraction.y = 0 }
        wheelFraction.x += d.x; wheelFraction.y += d.y
        let x = Int32(max(-32767,min(32767,wheelFraction.x.rounded(.towardZero))))
        let y = Int32(max(-32767,min(32767,wheelFraction.y.rounded(.towardZero))))
        wheelFraction.x -= CGFloat(x); wheelFraction.y -= CGFloat(y)
        if x != 0 || y != 0 { send(.pointer(3,0,y,-x)) }
    }
    func fingerScroll(_ delta: CGPoint) {
        guard enabled else { return }
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
    }
    func tick() {
        let now = clock()
        for key in physical.sorted() where physicalKeyIsDown?(key) == false {
            hardware(usage: key,down: false)
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
        stopInertia(); externalScrolling = false; quarantine.formUnion(contacts.keys); contacts.removeAll()
        cancelNative(); for b in buttons.sorted() { button(b,false) }
        for key in keys.keys.sorted() where key < 0xe0 { send(.key(key,1)) }
        for key in keys.keys.sorted() where key >= 0xe0 { send(.key(key,1)) }
        keys.removeAll(); physical.removeAll(); externalButtons.removeAll(); modifierStates.removeAll(); actionModifiers.removeAll()
        actionActive = false; pencil = nil; palmUntil = 0; drag = .idle
        hoverAnchor = nil; neutralRequired = true; resetGesture()
    }
}
