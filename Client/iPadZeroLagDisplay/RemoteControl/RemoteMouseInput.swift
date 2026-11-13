import Foundation

// Bit positions match UIEvent.ButtonMask; unknown auxiliary buttons are ignored.
struct RemoteMouseButtons: OptionSet {
    let rawValue: UInt
    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let middle = Self(rawValue: 1 << 2)
    static let x1 = Self(rawValue: 1 << 3)
    static let x2 = Self(rawValue: 1 << 4)
}

struct RemoteMouseSample {
    let point: CGPoint
    let timestamp: TimeInterval
    // Centroid and participating count, not remaining count. End once, at last lift.
    let touchCount: Int
    let tapCount: Int
    let device: RemoteMouseDevice
    let buttons: RemoteMouseButtons
}

// Pure state machine. RI-F supplies the aspect-fit video rect in sample coordinates,
// and captures token/generation at gesture origin. Send results in array order.
struct RemoteMouseInput {
    private struct Gesture {
        let device: RemoteMouseDevice
        let mode: RemoteMouseMode
        var start: CGPoint
        let began: TimeInterval
        var last: CGPoint
        var timestamp: TimeInterval
        var count: Int
        var tapEligible: Bool
        var dragging: Bool
        var scrolled = false
    }

    private(set) var mode: RemoteMouseMode
    private(set) var heldButtons: Set<UInt8> = []
    private var context: RemoteInputContextCommand?
    private var videoRect: CGRect
    private var generation: UInt64
    private var inputReady: Bool
    private var gesture: Gesture?
    private var hoverPoint: CGPoint?
    private var lastTap: (point: CGPoint, timestamp: TimeInterval)?
    private var relativeX: CGFloat = 0
    private var relativeY: CGFloat = 0
    private var wheelVertical: CGFloat = 0
    private var wheelHorizontal: CGFloat = 0

    // Existing finger tap thresholds and finger/indirect wheel calibrations.
    private let tapDuration: TimeInterval = 0.250
    private let tapMovement: CGFloat = 12
    private let doubleTapInterval: TimeInterval = 0.300

    init(context: RemoteInputContextCommand?, videoRect: CGRect, generation: UInt64,
         mode: RemoteMouseMode = .auto, inputReady: Bool = true) {
        self.context = context
        self.videoRect = videoRect
        self.generation = generation
        self.mode = mode
        self.inputReady = inputReady
    }

    // Context/epoch/source retirement is owned by the host. Never re-stamp releases.
    // RI-F passes inputReady only after negotiation, ready context and fresh keyframe.
    // Send returned releases on a layout-only change while the old context is valid.
    @discardableResult
    mutating func configure(context: RemoteInputContextCommand?, videoRect: CGRect,
                            generation: UInt64, inputReady: Bool = true) -> [RemotePointerCommand] {
        var releases: [RemotePointerCommand] = []
        if self.context == context && self.generation == generation && self.inputReady == inputReady
            && self.videoRect != videoRect, let token = context?.token {
            releases = reset(token: token, generation: generation)
        }
        if self.context != context || self.videoRect != videoRect || self.generation != generation
            || self.inputReady != inputReady {
            clear()
        }
        self.context = context
        self.videoRect = videoRect
        self.generation = generation
        self.inputReady = inputReady
        return releases
    }

    // RI-F also sends RemoteInputResetCommand(reason: 3), then waits for re-arming.
    mutating func setMode(_ value: RemoteMouseMode, token: UInt64,
                          generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation), value != mode else { return [] }
        let releases = reset(token: token, generation: generation)
        mode = value
        return releases
    }

    mutating func touchBegan(_ sample: RemoteMouseSample, token: UInt64,
                             generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation), valid(sample) else { return [] }
        if sample.device == .indirectPointer {
            return hover(point: sample.point, buttons: sample.buttons, token: token, generation: generation)
        }
        guard inside(sample.point) else { return [] }
        if gesture != nil {
            return touchMoved(sample, token: token, generation: generation)
        }
        let resolved = mode.resolved(for: sample.device)
        let recentTap = lastTap.map {
            sample.timestamp >= $0.timestamp && sample.timestamp - $0.timestamp <= doubleTapInterval
                && distance(sample.point, $0.point) <= tapMovement
        } ?? false
        let dragging = sample.touchCount == 1 && (sample.device == .pencil
            || sample.tapCount >= 2 || recentTap)
        lastTap = nil
        gesture = Gesture(device: sample.device, mode: resolved, start: sample.point,
            began: sample.timestamp, last: sample.point, timestamp: sample.timestamp,
            count: sample.touchCount, tapEligible: sample.touchCount <= 2, dragging: dragging)
        var result: [RemotePointerCommand] = []
        if resolved == .direct { result = absolute(sample.point, token: token) }
        if dragging { result += button(1, down: true, token: token) }
        return result
    }

    mutating func touchMoved(_ sample: RemoteMouseSample, token: UInt64,
                             generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation), valid(sample) else { return [] }
        if sample.device == .indirectPointer {
            return hover(point: sample.point, buttons: sample.buttons, token: token, generation: generation)
        }
        guard var current = gesture, current.device == sample.device,
              sample.timestamp >= current.timestamp else { return [] }
        let delta = CGPoint(x: sample.point.x - current.last.x, y: sample.point.y - current.last.y)
        current.last = sample.point
        current.timestamp = sample.timestamp
        if sample.touchCount != current.count {
            let joiningSecondFinger = current.count == 1 && sample.touchCount == 2
                && !current.dragging && current.tapEligible
            current.count = max(current.count, sample.touchCount)
            current.tapEligible = joiningSecondFinger
            current.start = sample.point
            var result: [RemotePointerCommand] = []
            if current.dragging {
                result = button(1, down: false, token: token)
                current.dragging = false
            }
            gesture = current
            return result
        }
        if distance(sample.point, current.start) > tapMovement { current.tapEligible = false }
        var result: [RemotePointerCommand] = []
        if current.count == 2 && sample.device == .finger {
            // Tap jitter must not become a wheel event. Once classified, include
            // the full displacement and then preserve every subsequent fraction.
            let startedScroll = !current.scrolled && distance(sample.point, current.start) >= tapMovement
            if startedScroll { current.scrolled = true }
            if current.scrolled {
                let movement = startedScroll ? CGPoint(x: sample.point.x - current.start.x,
                    y: sample.point.y - current.start.y) : delta
                let unitsPerPoint: CGFloat = 120 / 72
                result = scroll(vertical: movement.y * unitsPerPoint, horizontal: -movement.x * unitsPerPoint,
                    token: token, generation: generation)
            }
        } else if current.count == 1 {
            result = current.mode == .direct ? absolute(sample.point, token: token)
                : relative(delta, token: token)
        }
        gesture = current
        return result
    }

    mutating func touchEnded(_ sample: RemoteMouseSample, token: UInt64,
                             generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation), valid(sample) else { return [] }
        if sample.device == .indirectPointer {
            return hover(point: sample.point, buttons: sample.buttons, token: token, generation: generation)
        }
        guard let current = gesture, current.device == sample.device,
              sample.timestamp >= current.timestamp else { return [] }
        gesture = nil
        var result = current.mode == .direct ? absolute(sample.point, token: token) : []
        if current.dragging {
            result += button(1, down: false, token: token)
        } else if current.tapEligible && !current.scrolled
            && sample.timestamp - current.began <= tapDuration
            && distance(sample.point, current.start) <= tapMovement && inside(sample.point) {
            result += click(current.count == 2 ? 2 : 1, token: token)
            if current.count == 1 { lastTap = (sample.point, sample.timestamp) }
        }
        return result
    }

    // Feed hover AND indirect button-mask changes here, including the final empty mask.
    mutating func hover(point: CGPoint, buttons: RemoteMouseButtons = [], token: UInt64,
                        generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation), finite(point) else { return [] }
        let accepted = inside(point)
        var result: [RemotePointerCommand] = []
        if accepted {
            if mode.resolved(for: .indirectPointer) == .direct {
                result = absolute(point, token: token)
            } else if let previous = hoverPoint {
                result = relative(CGPoint(x: point.x - previous.x, y: point.y - previous.y), token: token)
            }
            hoverPoint = point
        } else {
            hoverPoint = nil
        }
        for id in UInt8(1)...5 {
            let down = buttons.rawValue & (UInt(1) << Int(id - 1)) != 0
            // Releases remain valid outside video; a margin can never start a press.
            if !down || accepted { result += button(id, down: down, token: token) }
        }
        return result
    }

    // Deltas here are Windows wheel units, positive vertical up/horizontal right.
    mutating func scroll(vertical: CGFloat, horizontal: CGFloat, token: UInt64,
                         generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation), vertical.isFinite, horizontal.isFinite else { return [] }
        let a = Self.units(vertical, remainder: &wheelVertical)
        let b = Self.units(horizontal, remainder: &wheelHorizontal)
        return a == 0 && b == 0 ? [] : [command(3, a, b, token: token)]
    }

    // UIKit pan deltas: existing indirect convention, 24 points == one notch.
    mutating func scrollPoints(_ delta: CGPoint, token: UInt64,
                               generation: UInt64) -> [RemotePointerCommand] {
        scroll(vertical: delta.y * 5, horizontal: -delta.x * 5, token: token, generation: generation)
    }

    mutating func middleClick(token: UInt64, generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation) else { return [] }
        return click(3, token: token)
    }

    // Call on cancellation/focus loss/background/control off before sending message 66.
    // Invalid contexts clear locally through configure(), with no stale wire releases.
    mutating func reset(token: UInt64, generation: UInt64) -> [RemotePointerCommand] {
        guard owns(token, generation) else { return [] }
        let result = heldButtons.sorted().map { command(2, 1, token: token, button: $0) }
        clear()
        return result
    }

    private func owns(_ token: UInt64, _ generation: UInt64) -> Bool {
        guard inputReady, self.generation == generation, let context,
              context.state == 1, context.token == token, token != 0,
              context.desktop == 1 || context.desktop == 2 || context.desktop == 3,
              context.width > 0, context.height > 0 else { return false }
        return videoRect.origin.x.isFinite && videoRect.origin.y.isFinite
            && videoRect.width.isFinite && videoRect.height.isFinite
            && videoRect.width > 0 && videoRect.height > 0
    }

    private func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    private func valid(_ sample: RemoteMouseSample) -> Bool {
        finite(sample.point) && sample.timestamp.isFinite && sample.touchCount > 0
    }

    private func inside(_ point: CGPoint) -> Bool {
        finite(point) && point.x >= videoRect.minX && point.x <= videoRect.maxX
            && point.y >= videoRect.minY && point.y <= videoRect.maxY
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func absolute(_ point: CGPoint, token: UInt64) -> [RemotePointerCommand] {
        guard inside(point), let context else { return [] }
        // Wire coordinates are source-local normalized coordinates. Host mapping adds
        // signed left/top. Do not normalize these against the whole virtual desktop.
        func coordinate(_ fraction: CGFloat, pixels: UInt32) -> Int32 {
            let sourceOffset = fraction * CGFloat(pixels - 1)
            return pixels == 1 ? 0 : Int32((sourceOffset / CGFloat(pixels - 1) * 65535).rounded())
        }
        return [command(0, coordinate((point.x - videoRect.minX) / videoRect.width, pixels: context.width),
            coordinate((point.y - videoRect.minY) / videoRect.height, pixels: context.height), token: token)]
    }

    private mutating func relative(_ delta: CGPoint, token: UInt64) -> [RemotePointerCommand] {
        guard let context else { return [] }
        let a = Self.units(delta.x * CGFloat(context.width) / videoRect.width, remainder: &relativeX)
        let b = Self.units(delta.y * CGFloat(context.height) / videoRect.height, remainder: &relativeY)
        return a == 0 && b == 0 ? [] : [command(1, a, b, token: token)]
    }

    private static func units(_ value: CGFloat, remainder: inout CGFloat) -> Int32 {
        let accumulated = value + remainder
        if accumulated >= 32767 { remainder = 0; return 32767 }
        if accumulated <= -32767 { remainder = 0; return -32767 }
        guard accumulated.isFinite else { remainder = 0; return 0 }
        let whole = accumulated.rounded(.towardZero)
        remainder = accumulated - whole
        return Int32(whole)
    }

    private mutating func button(_ id: UInt8, down: Bool, token: UInt64) -> [RemotePointerCommand] {
        guard heldButtons.contains(id) != down else { return [] }
        if down { heldButtons.insert(id) } else { heldButtons.remove(id) }
        return [command(2, down ? 0 : 1, token: token, button: id)]
    }

    private mutating func click(_ id: UInt8, token: UInt64) -> [RemotePointerCommand] {
        guard !heldButtons.contains(id) else { return [] }
        return button(id, down: true, token: token) + button(id, down: false, token: token)
    }

    private func command(_ kind: UInt8, _ a: Int32 = 0, _ b: Int32 = 0,
                         token: UInt64, button: UInt8 = 0) -> RemotePointerCommand {
        RemotePointerCommand(kind: kind, button: button, token: token, a: a, b: b)
    }

    private mutating func clear() {
        heldButtons.removeAll()
        gesture = nil
        hoverPoint = nil
        lastTap = nil
        relativeX = 0
        relativeY = 0
        wheelVertical = 0
        wheelHorizontal = 0
    }
}
