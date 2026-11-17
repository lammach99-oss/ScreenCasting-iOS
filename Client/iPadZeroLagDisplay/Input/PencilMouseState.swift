import Foundation
import CoreGraphics

/// Normalized coordinates and ordered effects; no platform event construction.
struct PencilMouseState {
    enum Effect: Equatable {
        case claimFingers
        case move(CGPoint)
        case button(UInt8, Bool)
    }
    private let clock: () -> TimeInterval
    private(set) var activeID: UInt64?
    private var activeButton: UInt8 = 1
    private var hovering = false
    private var graceUntil: TimeInterval = -.infinity
    private var armedUntil: TimeInterval = -.infinity
    private(set) var rightArmed = false
    var blocksFingers: Bool { hovering || activeID != nil || clock() < graceUntil }

    init(clock: @escaping () -> TimeInterval) { self.clock = clock }
    private func valid(_ p: CGPoint) -> Bool {
        p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y)
    }
    mutating func toggleRight() {
        tick()
        rightArmed.toggle()
        armedUntil = rightArmed ? clock() + 5.0 : -.infinity
    }
    mutating func tick() {
        if clock() >= armedUntil { rightArmed = false }
    }
    mutating func hover(at point: CGPoint?) -> [Effect] {
        guard let point, valid(point) else {
            if hovering { hovering = false; graceUntil = clock() + 0.400 }
            return []
        }
        guard activeID == nil else { return [] }
        let claim = !hovering
        hovering = true
        return (claim ? [.claimFingers] : []) + [.move(point)]
    }
    mutating func begin(id: UInt64, at point: CGPoint) -> [Effect] {
        guard activeID == nil, id != 0, valid(point) else { return [] }
        tick()
        activeID = id; activeButton = rightArmed ? 2 : 1
        rightArmed = false; armedUntil = -.infinity
        hovering = false // Hover-to-tip handoff must not leave a permanent hover lease.
        return [.claimFingers, .move(point), .button(activeButton, true)]
    }
    mutating func move(id: UInt64, to point: CGPoint) -> [Effect] {
        guard activeID == id, valid(point) else { return [] }
        return [.move(point)]
    }
    mutating func end(id: UInt64, at point: CGPoint?, cancelled: Bool) -> [Effect] {
        guard activeID == id else { return [] }
        let move: [Effect]
        if !cancelled, let point, valid(point) { move = [.move(point)] } else { move = [] }
        activeID = nil; hovering = false; graceUntil = clock() + 0.400
        return move + [.button(activeButton, false)]
    }
    mutating func retire() -> [Effect] {
        let effects: [Effect] = activeID == nil ? [] : [.button(activeButton, false)]
        if activeID != nil || hovering { graceUntil = clock() + 0.400 }
        activeID = nil; hovering = false; rightArmed = false; armedUntil = -.infinity
        return effects
    }
}
