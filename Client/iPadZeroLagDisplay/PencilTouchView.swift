import SwiftUI
import UIKit

// MARK: - PencilTouchView

/// SwiftUI wrapper for high-frequency (240Hz) Apple Pencil & pressure touch ingestion.
///
/// ## Two output paths (both fire simultaneously):
/// - `onPencilInput`:      Delivers the rich `PencilPacket` (legacy — backward-compat)
/// - `onSendTouchEvent`:   Delivers the typed arguments for `NetworkManager.sendTouchEvent`
///                         matching the 8-byte wire format the C# host expects.
/// - `onNetworkSend`:      Legacy raw-bytes callback (now emits the 8-byte packet, NOT
///                         the old PencilPacket struct) to avoid breaking existing callers.
public struct PencilTouchView: UIViewRepresentable {

    // MARK: Callbacks

    /// Called with the full `PencilPacket` for local rendering / tilt visualisation.
    public var onPencilInput: ((PencilPacket) -> Void)?

    /// Preferred callback — delivers typed arguments directly to `NetworkManager`.
    /// ```swift
    /// PencilTouchView { type, x, y, pressure in
    ///     networkManager.sendTouchEvent(type: type, x: x, y: y, pressure: pressure)
    /// }
    /// ```
    public var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?

    /// Legacy raw-bytes callback. Now emits the 8-byte TouchInputPacket wire format.
    /// Kept for backward compatibility with code that passes bytes directly to `sendData`.
    public var onNetworkSend: ((Data) -> Void)?
    public var onPointerInput: ((PointerInputCommand) -> Void)?
    public var onOpenSettings: (() -> Void)?

    /// Normalized aspect-fit rectangle occupied by the remote video in this view.
    /// The Metal renderer is the source of truth for this displayed geometry.
    public var contentViewport: VideoContentViewport?
    var onBoundsChanged: ((CGRect) -> Void)?

    // MARK: Init

    public init(
        onPencilInput:    ((PencilPacket) -> Void)?                        = nil,
        onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)? = nil,
        onNetworkSend:    ((Data) -> Void)?                                = nil,
        onPointerInput:   ((PointerInputCommand) -> Void)?                 = nil,
        onOpenSettings:   (() -> Void)?                                    = nil,
        contentViewport:  VideoContentViewport?                             = nil,
        onBoundsChanged:  ((CGRect) -> Void)?                               = nil
    ) {
        self.onPencilInput    = onPencilInput
        self.onSendTouchEvent = onSendTouchEvent
        self.onNetworkSend    = onNetworkSend
        self.onPointerInput   = onPointerInput
        self.onOpenSettings   = onOpenSettings
        self.contentViewport  = contentViewport
        self.onBoundsChanged  = onBoundsChanged
    }

    public func makeUIView(context: Context) -> PencilUIKitView {
        let view = PencilUIKitView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        updateUIView(view, context: context)
        return view
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PencilUIKitView,
        context: Context
    ) -> CGSize? {
        FullscreenSurfaceLayout.exactSize(
            width: proposal.width,
            height: proposal.height)
    }

    public func updateUIView(_ uiView: PencilUIKitView, context: Context) {
        uiView.onPencilInput    = onPencilInput
        uiView.onSendTouchEvent = onSendTouchEvent
        uiView.onNetworkSend    = onNetworkSend
        uiView.onPointerInput   = onPointerInput
        uiView.onOpenSettings   = onOpenSettings
        uiView.contentViewport  = contentViewport
        uiView.onBoundsChanged  = onBoundsChanged
    }
}

// MARK: - PencilPacket (legacy, for onPencilInput)

public struct PencilPacket {
    public var magic: UInt32 = 0x50454E43 // "PENC"
    public var xRatio: Float
    public var yRatio: Float
    public var pressure: Float
    public var tiltX: UInt16
    public var tiltY: UInt16
    public var pointerFlags: UInt8 // 1=TouchDown, 2=Move, 4=TouchUp, 8=IsEraser
}

// MARK: - Touch Event Type flag mapping

/// Maps PencilUIKitView's UIKit touch flags to the wire-protocol `TouchEventType`.
private func touchEventType(for flags: UInt8) -> TouchEventType {
    switch flags {
    case 1: return .down
    case 4: return .up
    default: return .move   // flags == 2 (move) and anything else
    }
}

// MARK: - Touch Wire Format constants (mirrors NetworkManager.swift)

private let kTouchMagic: UInt16 = 0x5449
private let kTouchPacketSize    = 8

enum DirectTouchGestureOutput: Equatable {
    case pointer(PointerInputAction, CGPoint, Int16)
    case openSettings
}

struct PointerInputCoordinateState {
    private(set) var lastValidPoint: CGPoint?

    mutating func resolve(action: PointerInputAction, mappedPoint: CGPoint?) -> CGPoint? {
        if let mappedPoint {
            lastValidPoint = mappedPoint
            return mappedPoint
        }
        guard action == .leftUp else { return nil }
        defer { lastValidPoint = nil }
        return lastValidPoint ?? .zero
    }

    mutating func clearAfterRelease(_ action: PointerInputAction) {
        if action == .leftUp { lastValidPoint = nil }
    }
}

struct LifetimeIdentityMap<Key: Hashable> {
    private var nextID: UInt64 = 1
    private var identities: [Key: UInt64] = [:]

    mutating func begin(_ key: Key) -> UInt64 {
        if let existing = identities[key] { return existing }
        let allocated = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        identities[key] = allocated
        return allocated
    }

    func existing(_ key: Key) -> UInt64? { identities[key] }

    @discardableResult
    mutating func end(_ key: Key) -> UInt64? {
        identities.removeValue(forKey: key)
    }
}

struct DirectTouchGestureStateMachine {
    private struct Contact {
        let id: UInt64
        let beganAt: TimeInterval
        let start: CGPoint
        var point: CGPoint
        var maxExcursion: CGFloat
    }

    private enum State {
        case idle
        case oneFinger(UInt64)
        case scrolling(UInt64, lastY: CGFloat, wheelRemainder: CGFloat)
        case twoFinger(UInt64, UInt64, secondBeganAt: TimeInterval)
        case dragging(UInt64, UInt64)
        case threeFinger(
            startedAt: TimeInterval,
            participants: Set<UInt64>,
            completed: Set<UInt64>,
            valid: Bool)
        case suppressed
        case pencilExclusive
        case palmGuard(until: TimeInterval)
    }

    private var state: State = .idle
    private var contacts: [UInt64: Contact] = [:]
    private var ignoredContacts: Set<UInt64> = []
    private let tapDuration: TimeInterval = 0.250
    private let tapMovement: CGFloat = 12
    private let dragMovement: CGFloat = 6
    private let threeFingerSync: TimeInterval = 0.150
    private let threeFingerDuration: TimeInterval = 0.300
    private let threeFingerMovement: CGFloat = 15
    private let palmGuardDuration: TimeInterval = 0.150
    private let wheelPointsPerStep: CGFloat = 21

    mutating func begin(
        id: UInt64,
        point: CGPoint,
        timestamp: TimeInterval
    ) -> [DirectTouchGestureOutput] {
        switch state {
        case .pencilExclusive:
            ignoredContacts.insert(id)
            return []
        case .palmGuard(let until) where timestamp < until:
            ignoredContacts.insert(id)
            return []
        default:
            break
        }
        if !ignoredContacts.isEmpty {
            ignoredContacts.insert(id)
            return []
        }

        contacts[id] = Contact(
            id: id,
            beganAt: timestamp,
            start: point,
            point: point,
            maxExcursion: 0)
        if case .threeFinger(_, _, let completed, _) = state,
           !completed.isEmpty {
            state = .suppressed
            return []
        }
        if contacts.count >= 4 {
            state = .suppressed
            return []
        }
        if case .scrolling = state { return [] }
        if case .dragging = state { return [] }
        if contacts.count == 3 {
            let times = contacts.values.map(\.beganAt)
            if let first = times.min(), let last = times.max(),
               last - first <= threeFingerSync {
                state = .threeFinger(
                    startedAt: first,
                    participants: Set(contacts.keys),
                    completed: [],
                    valid: true)
            } else {
                state = .suppressed
            }
            return []
        }

        switch state {
        case .idle, .palmGuard:
            state = .oneFinger(id)
        case .oneFinger(let primary) where contacts.count == 2:
            state = .twoFinger(primary, id, secondBeganAt: timestamp)
        case .scrolling:
            break
        default:
            break
        }
        return []
    }

    mutating func move(
        id: UInt64,
        point: CGPoint,
        timestamp: TimeInterval
    ) -> [DirectTouchGestureOutput] {
        guard !ignoredContacts.contains(id),
              var contact = contacts[id] else { return [] }
        contact.point = point
        contact.maxExcursion = max(
            contact.maxExcursion,
            distance(contact.start, point))
        contacts[id] = contact

        switch state {
        case .oneFinger(let primary) where primary == id:
            let dx = point.x - contact.start.x
            let dy = point.y - contact.start.y
            if abs(dy) >= 12 && abs(dy) >= abs(dx) * 0.6 {
                state = .scrolling(primary, lastY: point.y, wheelRemainder: 0)
                return [.pointer(.move, contact.start, 0)]
            }
        case .scrolling(let primary, let lastY, let remainder) where primary == id:
            let accumulated = remainder + (point.y - lastY)
            var steps = Int(accumulated / wheelPointsPerStep)
            steps = max(-8, min(8, steps))
            let used = CGFloat(steps) * wheelPointsPerStep
            state = .scrolling(
                primary,
                lastY: point.y,
                wheelRemainder: accumulated - used)
            guard steps != 0 else { return [] }
            return [.pointer(
                .verticalWheel,
                point,
                Int16(clamping: steps * 120))]
        case .twoFinger(let primary, let secondary, _) where primary == id:
            if distance(contact.start, point) >= dragMovement {
                state = .dragging(primary, secondary)
                return [.pointer(.leftDown, point, 0)]
            }
        case .dragging(let primary, _) where primary == id:
            return [.pointer(.move, point, 0)]
        case .threeFinger(let startedAt, let participants, let completed, let valid):
            state = .threeFinger(
                startedAt: startedAt,
                participants: participants,
                completed: completed,
                valid: valid && contact.maxExcursion <= threeFingerMovement)
        default:
            break
        }
        return []
    }

    mutating func end(
        id: UInt64,
        point: CGPoint,
        timestamp: TimeInterval,
        cancelled: Bool = false
    ) -> [DirectTouchGestureOutput] {
        if ignoredContacts.remove(id) != nil {
            contacts.removeValue(forKey: id)
            settleAfterIgnoredContacts(timestamp: timestamp)
            return []
        }
        guard var contact = contacts[id] else { return [] }
        contact.point = point
        contact.maxExcursion = max(
            contact.maxExcursion,
            distance(contact.start, point))
        contacts[id] = contact
        var outputs: [DirectTouchGestureOutput] = []

        switch state {
        case .oneFinger(let primary) where primary == id:
            if !cancelled,
               timestamp - contact.beganAt <= tapDuration,
               contact.maxExcursion <= tapMovement {
                outputs.append(.pointer(.leftClick, point, 0))
            }
            state = .suppressed
        case .scrolling:
            state = .suppressed
        case .twoFinger(let primary, let secondary, let secondBeganAt):
            if id == secondary,
               !cancelled,
               timestamp - secondBeganAt <= tapDuration,
               let primaryContact = contacts[primary],
               primaryContact.maxExcursion <= tapMovement {
                outputs.append(.pointer(.rightClick, primaryContact.point, 0))
            }
            state = .suppressed
        case .dragging(let primary, _):
            let finalPoint = contacts[primary]?.point ?? point
            outputs.append(.pointer(.leftUp, finalPoint, 0))
            state = .suppressed
        case .threeFinger(
            let startedAt,
            let participants,
            var completed,
            let valid):
            completed.insert(id)
            let remainsValid = valid &&
                !cancelled &&
                timestamp - startedAt <= threeFingerDuration &&
                contact.maxExcursion <= threeFingerMovement
            if completed == participants {
                if remainsValid { outputs.append(.openSettings) }
                state = .suppressed
            } else {
                state = .threeFinger(
                    startedAt: startedAt,
                    participants: participants,
                    completed: completed,
                    valid: remainsValid)
            }
        default:
            break
        }

        contacts.removeValue(forKey: id)
        if contacts.isEmpty, case .suppressed = state {
            state = .idle
        }
        return outputs
    }

    mutating func pencilBegan(timestamp: TimeInterval) -> [DirectTouchGestureOutput] {
        var outputs: [DirectTouchGestureOutput] = []
        if case .dragging(let primary, _) = state {
            let point = contacts[primary]?.point ?? .zero
            outputs.append(.pointer(.leftUp, point, 0))
        }
        ignoredContacts.formUnion(contacts.keys)
        contacts.removeAll()
        state = .pencilExclusive
        return outputs
    }

    mutating func pencilEnded(timestamp: TimeInterval) {
        state = .palmGuard(until: timestamp + palmGuardDuration)
    }

    private mutating func settleAfterIgnoredContacts(timestamp: TimeInterval) {
        guard ignoredContacts.isEmpty,
              case .palmGuard(let until) = state,
              timestamp >= until else { return }
        state = .idle
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

// MARK: - PencilUIKitView

public class PencilUIKitView: UIView {

    // MARK: Callbacks (set by PencilTouchView.updateUIView)
    public var onPencilInput:    ((PencilPacket) -> Void)?
    public var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?
    public var onNetworkSend:    ((Data) -> Void)?
    public var onPointerInput: ((PointerInputCommand) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var contentViewport: VideoContentViewport?
    var inputGeometryContext: InputGeometryDiagnosticContext?
    var diagnosticSink: ((String) -> Void)?
    public var onBoundsChanged: ((CGRect) -> Void)?

    private var activeTouchIdentifier: ObjectIdentifier?
    private var lastNormalizedPoint: CGPoint?
    private var lastReportedBounds: CGRect?
    private var inputGeometrySampler = InputGeometryDiagnosticSampler()
    private var directGesture = DirectTouchGestureStateMachine()
    private var pointerCoordinateState = PointerInputCoordinateState()
    private var directTouchIDs = LifetimeIdentityMap<ObjectIdentifier>()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastReportedBounds else { return }
        lastReportedBounds = bounds
        onBoundsChanged?(bounds)
    }

    // MARK: - UIKit touch overrides (pass event for coalesced touch access)

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches(touches, flags: 1, event: event)
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches(touches, flags: 2, event: event)
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches(touches, flags: 4, event: event)
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        routeTouches(touches, flags: 4, event: event, cancelled: true)
    }

    private func routeTouches(
        _ touches: Set<UITouch>,
        flags: UInt8,
        event: UIEvent?,
        cancelled: Bool = false
    ) {
        let pencilTouches = Set(touches.filter { $0.type == .pencil })
        let directTouches = touches.filter { $0.type == .direct }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return UInt(bitPattern: Unmanaged.passUnretained(lhs).toOpaque()) <
                    UInt(bitPattern: Unmanaged.passUnretained(rhs).toOpaque())
            }

        if let pencil = pencilTouches.first, flags == 1 {
            emit(directGesture.pencilBegan(timestamp: pencil.timestamp))
        }
        if !pencilTouches.isEmpty {
            handlePencilTouches(pencilTouches, flags: flags, event: event)
            if flags == 4, let pencil = pencilTouches.first {
                directGesture.pencilEnded(timestamp: pencil.timestamp)
            }
        }

        for touch in directTouches {
            let key = ObjectIdentifier(touch)
            let id: UInt64
            if flags == 1 {
                id = directTouchIDs.begin(key)
            } else {
                guard let existing = directTouchIDs.existing(key) else { continue }
                id = existing
            }
            let point = touch.location(in: self)
            let outputs: [DirectTouchGestureOutput]
            switch flags {
            case 1:
                outputs = directGesture.begin(
                    id: id, point: point, timestamp: touch.timestamp)
            case 2:
                outputs = directGesture.move(
                    id: id, point: point, timestamp: touch.timestamp)
            default:
                outputs = directGesture.end(
                    id: id,
                    point: point,
                    timestamp: touch.timestamp,
                    cancelled: cancelled)
            }
            emit(outputs)
            if flags == 4 { directTouchIDs.end(key) }
        }
    }

    private func emit(_ outputs: [DirectTouchGestureOutput]) {
        for output in outputs {
            switch output {
            case .openSettings:
                onOpenSettings?()
            case .pointer(let action, let point, let value):
                let normalized = bounds.width > 0 && bounds.height > 0
                    ? contentViewport?.normalizedPoint(for: point, in: bounds)
                    : nil
                guard let resolved = pointerCoordinateState.resolve(
                    action: action,
                    mappedPoint: normalized) else { continue }
                let x = UInt16(clamping: Int((resolved.x * 65_535).rounded()))
                let y = UInt16(clamping: Int((resolved.y * 65_535).rounded()))
                onPointerInput?(PointerInputCommand(
                    action: action,
                    x: x,
                    y: y,
                    value: value))
                pointerCoordinateState.clearAfterRelease(action)
            }
        }
    }

    // MARK: - Core packet builder

    private func handlePencilTouches(_ touches: Set<UITouch>, flags: UInt8, event: UIEvent?) {
        guard let primaryTouch = touches.first else { return }

        // Consume all 240Hz coalesced samples — every intermediate Pencil position.
        let allTouches = flags == 4
            ? [primaryTouch]
            : event?.coalescedTouches(for: primaryTouch) ?? [primaryTouch]

        let bounds = self.bounds
        guard
            bounds.width > 0,
            bounds.height > 0,
            let contentViewport
        else {
            if flags == 4 {
                activeTouchIdentifier = nil
                lastNormalizedPoint = nil
            }
            return
        }

        let touchIdentifier = ObjectIdentifier(primaryTouch)
        let primaryLocation = primaryTouch.location(in: self)
        let primaryMappedPoint = contentViewport.normalizedPoint(
            for: primaryLocation,
            in: bounds)
        if flags == 1 {
            guard activeTouchIdentifier == nil, primaryMappedPoint != nil else {
                logRejectedTouchIfNeeded(
                    event: touchEventType(for: flags),
                    location: primaryLocation,
                    bounds: bounds,
                    contentViewport: contentViewport,
                    insideContent: primaryMappedPoint != nil,
                    timestamp: primaryTouch.timestamp)
                return
            }
            activeTouchIdentifier = touchIdentifier
        } else {
            guard activeTouchIdentifier == touchIdentifier else { return }
        }

        for touch in allTouches {
            let location = touch.location(in: self)
            let mappedNormalizedPoint = contentViewport.normalizedPoint(
                for: location,
                in: bounds)
            let normalizedPoint = mappedNormalizedPoint ??
                (flags == 4 ? lastNormalizedPoint : nil)
            guard let normalizedPoint else {
                logRejectedTouchIfNeeded(
                    event: touchEventType(for: flags),
                    location: location,
                    bounds: bounds,
                    contentViewport: contentViewport,
                    insideContent: false,
                    timestamp: touch.timestamp)
                continue
            }
            lastNormalizedPoint = normalizedPoint

            // ── Normalised ratios (0.0 – 1.0) ───────────────────────────────
            let xRatio = Float(normalizedPoint.x).clamped(0, 1)
            let yRatio = Float(normalizedPoint.y).clamped(0, 1)

            // ── Pressure ─────────────────────────────────────────────────────
            let pressureFloat: Float = touch.maximumPossibleForce > 0
                ? Float(touch.force / touch.maximumPossibleForce).clamped(0, 1)
                : 1.0

            // ── Tilt (for the legacy PencilPacket) ───────────────────────────
            let altitude = touch.altitudeAngle
            let azimuth  = touch.azimuthAngle(in: self)
            let tiltX = UInt16(clamping: Int(abs(cos(azimuth) * cos(altitude) * (180.0 / .pi))))
            let tiltY = UInt16(clamping: Int(abs(sin(azimuth) * cos(altitude) * (180.0 / .pi))))

            // ── Map to wire-format integers ───────────────────────────────────
            // UInt16 space (0 – 65535) is resolution-independent; the C# host
            // divides by 65535 and multiplies by its virtual screen resolution.
            let wireX        = UInt16(clamping: Int((xRatio       * 65535).rounded()))
            let wireY        = UInt16(clamping: Int((yRatio        * 65535).rounded()))
            let wirePressure = UInt8 (clamping: Int((pressureFloat * 255  ).rounded()))
            let wireType     = touchEventType(for: flags)

            if let inputGeometryContext {
                let snapshot = InputGeometrySnapshot.make(
                    event: wireType,
                    context: inputGeometryContext,
                    touchPoint: location,
                    touchBounds: bounds,
                    contentRect: contentViewport.contentRect(in: bounds),
                    insideContent: mappedNormalizedPoint != nil,
                    normalizedPoint: normalizedPoint,
                    wireX: wireX,
                    wireY: wireY)
                if inputGeometrySampler.shouldLog(
                    event: wireType,
                    timestamp: touch.timestamp,
                    context: inputGeometryContext) {
                    InputGeometryDiagnostics.log(
                        snapshot,
                        collectibleSink: diagnosticSink)
                }
            }

            // ── Emit: typed callback (primary path) ───────────────────────────
            onSendTouchEvent?(wireType, wireX, wireY, wirePressure)

            // ── Emit: legacy raw-bytes callback ───────────────────────────────
            // Now serialises the 8-byte TouchInputPacket instead of PencilPacket.
            if onNetworkSend != nil {
                var packet = Data(count: kTouchPacketSize)
                packet.withUnsafeMutableBytes { buf in
                    buf.storeBytes(of: kTouchMagic.littleEndian,   toByteOffset: 0, as: UInt16.self)
                    buf.storeBytes(of: wireType.rawValue,           toByteOffset: 2, as: UInt8.self)
                    buf.storeBytes(of: wirePressure,                toByteOffset: 3, as: UInt8.self)
                    buf.storeBytes(of: wireX.littleEndian,          toByteOffset: 4, as: UInt16.self)
                    buf.storeBytes(of: wireY.littleEndian,          toByteOffset: 6, as: UInt16.self)
                }
                onNetworkSend?(packet)
            }

            // ── Emit: legacy PencilPacket (for local tilt / rendering) ────────
            var pencilPacket = PencilPacket(
                xRatio:       xRatio,
                yRatio:       yRatio,
                pressure:     pressureFloat,
                tiltX:        tiltX,
                tiltY:        tiltY,
                pointerFlags: flags
            )
            onPencilInput?(pencilPacket)
        }

        if flags == 4 {
            activeTouchIdentifier = nil
            lastNormalizedPoint = nil
        }
    }

    private func logRejectedTouchIfNeeded(
        event: TouchEventType,
        location: CGPoint,
        bounds: CGRect,
        contentViewport: VideoContentViewport,
        insideContent: Bool,
        timestamp: TimeInterval
    ) {
        guard let inputGeometryContext,
              inputGeometrySampler.shouldLog(
                event: event,
                timestamp: timestamp,
                context: inputGeometryContext) else {
            return
        }
        InputGeometryDiagnostics.log(
            InputGeometrySnapshot.make(
                event: event,
                context: inputGeometryContext,
                touchPoint: location,
                touchBounds: bounds,
                contentRect: contentViewport.contentRect(in: bounds),
                insideContent: insideContent,
                normalizedPoint: nil,
                wireX: nil,
                wireY: nil),
            collectibleSink: diagnosticSink)
    }
}

// MARK: - Private Float helper

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
