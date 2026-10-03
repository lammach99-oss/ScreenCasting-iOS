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
    public var onDirectTouchContact: ((DirectTouchContactCommand) -> Void)?
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
        onDirectTouchContact: ((DirectTouchContactCommand) -> Void)? = nil,
        onPointerInput:   ((PointerInputCommand) -> Void)?                 = nil,
        onOpenSettings:   (() -> Void)?                                    = nil,
        contentViewport:  VideoContentViewport?                             = nil,
        onBoundsChanged:  ((CGRect) -> Void)?                               = nil
    ) {
        self.onPencilInput    = onPencilInput
        self.onSendTouchEvent = onSendTouchEvent
        self.onNetworkSend    = onNetworkSend
        self.onDirectTouchContact = onDirectTouchContact
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
        uiView.onDirectTouchContact = onDirectTouchContact
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
    case directTouch(DirectTouchPhase, UInt64, CGPoint, UInt8)
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

    mutating func removeAll() { identities.removeAll() }

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
        var movedBeforeHold = false
    }

    private struct TwoFingerGesture {
        let first: UInt64
        let second: UInt64
        let beganAt: TimeInterval
        let initialSpan: CGFloat
        var lastSpan: CGFloat
        var points: [UInt64: CGPoint]
        var completed: Set<UInt64> = []
        var validTap = true
        var pinching = false
    }

    private enum State {
        case idle
        case oneFinger(UInt64)
        case scrolling(UInt64)
        case horizontalScrolling(UInt64)
        case twoFinger(TwoFingerGesture)
        case dragging(UInt64)
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
    private var committedContactID: UInt64?
    private var ignoredContacts: Set<UInt64> = []
    private var wheelRemainder: CGFloat = 0
    private var zoomRemainder: CGFloat = 0
    private let tapDuration: TimeInterval = 0.250
    private let tapMovement: CGFloat = 12
    private let dragMovement: CGFloat = 6
    private let holdDuration: TimeInterval = 1.000
    private let holdSlop: CGFloat = 8
    private let wheelPointsPerStep: CGFloat = 42
    private let threeFingerSync: TimeInterval = 0.150
    private let threeFingerDuration: TimeInterval = 0.300
    private let threeFingerMovement: CGFloat = 15
    private let palmGuardDuration: TimeInterval = 0.150

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
            let output = finishContact(cancelled: true)
            state = .suppressed
            return output
        }
        if case .scrolling = state { return [] }
        if case .horizontalScrolling = state { return [] }
        if case .dragging = state { return [] }
        if contacts.count == 3 {
            if case .twoFinger(let pair) = state,
               pair.pinching || !pair.completed.isEmpty || !pair.validTap {
                state = .suppressed
                return []
            }
            let times = contacts.values.map(\.beganAt)
            if let first = times.min(), let last = times.max(),
               last - first <= threeFingerSync,
               contacts.values.allSatisfy({ $0.maxExcursion <= threeFingerMovement }) {
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
            wheelRemainder = 0
            zoomRemainder = 0
            state = .oneFinger(id)
        case .oneFinger(let primary) where contacts.count == 2:
            guard let first = contacts[primary] else { return [] }
            let span = distance(first.point, point)
            state = .twoFinger(TwoFingerGesture(
                first: primary, second: id, beganAt: first.beganAt,
                initialSpan: span, lastSpan: span,
                points: [primary: first.point, id: point],
                validTap: first.maxExcursion <= tapMovement))
        case .scrolling:
            break
        case .horizontalScrolling:
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
        let previousPoint = contact.point
        let holdEligible = !contact.movedBeforeHold && contact.maxExcursion <= holdSlop
        contact.point = point
        contact.maxExcursion = max(
            contact.maxExcursion,
            distance(contact.start, point))
        if timestamp - contact.beganAt < holdDuration && contact.maxExcursion > holdSlop {
            contact.movedBeforeHold = true
        }
        contacts[id] = contact

        switch state {
        case .oneFinger(let primary) where primary == id:
            let dx = point.x - contact.start.x
            let dy = point.y - contact.start.y
            if timestamp - contact.beganAt >= holdDuration,
               holdEligible, distance(contact.start, point) >= dragMovement {
                state = .dragging(primary)
                return commitContact(contact, point: point)
            }
            if abs(dy) >= 12 && abs(dy) >= abs(dx) * 0.6 {
                state = .scrolling(primary)
                return wheel(action: .verticalWheel, points: dy, target: point)
            }
            if abs(dx) >= 12 && abs(dy) < abs(dx) * 0.6 {
                state = .horizontalScrolling(primary)
                return wheel(action: .horizontalWheel, points: -dx, target: point)
            }
        case .scrolling(let primary) where primary == id:
            return wheel(action: .verticalWheel, points: point.y - previousPoint.y, target: point)
        case .horizontalScrolling(let primary) where primary == id:
            return wheel(action: .horizontalWheel, points: previousPoint.x - point.x, target: point)
        case .twoFinger(var pair):
            guard pair.completed.isEmpty else { return [] }
            pair.points[id] = point
            pair.validTap = pair.validTap && contact.maxExcursion <= tapMovement
            let first = pair.points[pair.first] ?? .zero
            let second = pair.points[pair.second] ?? .zero
            let span = distance(first, second)
            if pair.initialSpan > 0, span > 0,
               pair.pinching || (abs(span - pair.initialSpan) >= 11 && abs(log(span / pair.initialSpan)) >= 0.05) {
                pair.pinching = true
                pair.validTap = false
                zoomRemainder += log(span / pair.lastSpan) * 120 / log(1.1)
                pair.lastSpan = span
                state = .twoFinger(pair)
                let value = Self.takeWheelUnits(&zoomRemainder)
                return value == 0 ? [] : [.pointer(.zoomWheel, midpoint(first, second), value)]
            }
            state = .twoFinger(pair)
        case .dragging(let primary) where primary == id:
            return [.directTouch(.update, primary, point, 255)]
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
               contact.maxExcursion <= tapMovement,
               (timestamp - contact.beganAt <= tapDuration ||
                (!contact.movedBeforeHold && contact.maxExcursion <= holdSlop && timestamp - contact.beganAt >= holdDuration)) {
                outputs += [.directTouch(.down, id, contact.start, 255), .directTouch(.up, id, contact.start, 255)]
            }
            state = .suppressed
        case .scrolling, .horizontalScrolling:
            outputs += finishContact(cancelled: cancelled)
            state = .suppressed
        case .twoFinger(var pair):
            pair.points[id] = point
            pair.completed.insert(id)
            pair.validTap = pair.validTap && !cancelled &&
                contact.maxExcursion <= tapMovement && timestamp - pair.beganAt <= tapDuration
            if pair.completed.count == 2 {
                if pair.validTap && !pair.pinching,
                   let first = pair.points[pair.first], let second = pair.points[pair.second] {
                    outputs.append(.pointer(.rightClick, midpoint(first, second), 0))
                }
                state = .suppressed
            } else {
                state = .twoFinger(pair)
            }
        case .dragging:
            outputs += finishContact(cancelled: cancelled)
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
        let outputs = finishContact(cancelled: true)
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

    private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private static func takeWheelUnits(_ remainder: inout CGFloat) -> Int16 {
        let units = max(-960, min(960, remainder.rounded(.towardZero)))
        remainder -= units
        return Int16(units)
    }

    private mutating func wheel(action: PointerInputAction, points: CGFloat, target: CGPoint) -> [DirectTouchGestureOutput] {
        wheelRemainder += points * 120 / wheelPointsPerStep
        let value = Self.takeWheelUnits(&wheelRemainder)
        return value == 0 ? [] : [.pointer(action, target, value)]
    }

    private mutating func commitContact(_ contact: Contact, point: CGPoint) -> [DirectTouchGestureOutput] {
        committedContactID = contact.id
        return [.directTouch(.down, contact.id, contact.start, 255),
                .directTouch(.update, contact.id, point, 255)]
    }

    private mutating func finishContact(cancelled: Bool) -> [DirectTouchGestureOutput] {
        guard let id = committedContactID else { return [] }
        committedContactID = nil
        return [.directTouch(cancelled ? .cancel : .up, id, contacts[id]?.point ?? .zero, 255)]
    }

    mutating func retire() -> [DirectTouchGestureOutput] {
        let outputs = finishContact(cancelled: true)
        contacts.removeAll(); ignoredContacts.removeAll(); state = .idle
        wheelRemainder = 0; zoomRemainder = 0
        return outputs
    }

}

// MARK: - PencilUIKitView

enum RemoteKeyboardKeyMapper {
    static func virtualKey(for usage: UIKeyboardHIDUsage) -> UInt16? {
        let hid = usage.rawValue
        switch hid {
        case 0x04...0x1D: return UInt16(0x41 + hid - 0x04)
        case 0x1E...0x26: return UInt16(0x31 + hid - 0x1E)
        case 0x27: return 0x30
        case 0x28: return 0x0D
        case 0x29: return 0x1B
        case 0x2A: return 0x08
        case 0x2B: return 0x09
        case 0x2C: return 0x20
        case 0x2D: return 0xBD
        case 0x2E: return 0xBB
        case 0x2F: return 0xDB
        case 0x30: return 0xDD
        case 0x31: return 0xDC
        case 0x33: return 0xBA
        case 0x34: return 0xDE
        case 0x35: return 0xC0
        case 0x36: return 0xBC
        case 0x37: return 0xBE
        case 0x38: return 0xBF
        case 0x39: return 0x14
        case 0x3A...0x45: return UInt16(0x70 + hid - 0x3A)
        case 0x49: return 0x2D
        case 0x4A: return 0x24
        case 0x4B: return 0x21
        case 0x4C: return 0x2E
        case 0x4D: return 0x23
        case 0x4E: return 0x22
        case 0x4F: return 0x27
        case 0x50: return 0x25
        case 0x51: return 0x28
        case 0x52: return 0x26
        case 0xE1: return 0xA0
        case 0xE5: return 0xA1
        case 0xE2: return 0xA4
        case 0xE6: return 0xA5
        case 0xE3, 0xE7: return 0xA2 // Command -> left Ctrl
        case 0xE0, 0xE4: return 0xA3 // Control -> right Ctrl
        default: return nil
        }
    }
}

public class PencilUIKitView: UIView {

    public var onKeyboardInput: ((KeyboardInputCommand) -> Void)?
    public var keyboardCaptureEnabled = false {
        didSet { updateKeyboardCapture() }
    }
    var hardwareKeyActivityEnabled = false
    var onHardwareKeyActivity: (() -> Void)?
    var passiveKeyboardCaptureEnabled = false {
        didSet { updateKeyboardCapture() }
    }
    private var activeRemotePhysicalKeys: [UIKeyboardHIDUsage: UInt16] = [:]
    private var remoteVirtualKeyOwnerCounts: [UInt16: Int] = [:]
    #if targetEnvironment(simulator)
    var hardwareKeyUsageForTesting: ((UIPress) -> UIKeyboardHIDUsage?)?
    #endif

    private func hardwareKeyUsage(for press: UIPress) -> UIKeyboardHIDUsage? {
        #if targetEnvironment(simulator)
        if let decode = hardwareKeyUsageForTesting { return decode(press) }
        #endif
        return press.key?.keyCode
    }

    override public var canBecomeFirstResponder: Bool { true }

    private func updateKeyboardCapture() {
        if !keyboardCaptureEnabled { releaseActiveRemoteKeys() }
        if (keyboardCaptureEnabled || passiveKeyboardCaptureEnabled) && window != nil {
            if !isFirstResponder { becomeFirstResponder() }
        } else {
            resignFirstResponder()
        }
    }

    private func releaseActiveRemoteKeys() {
        for virtualKey in remoteVirtualKeyOwnerCounts.keys.sorted() {
            onKeyboardInput?(KeyboardInputCommand(action: .keyUp, virtualKey: virtualKey))
        }
        activeRemotePhysicalKeys.removeAll()
        remoteVirtualKeyOwnerCounts.removeAll()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        updateKeyboardCapture()
        if window == nil { retireDirectTouch(); directTouchEnabled = false }
    }

    // Kept separate from UIPress construction so key lifetime can be tested
    // deterministically without synthesizing UIKit hardware events.
    @discardableResult
    func handleHardwareKey(_ usage: UIKeyboardHIDUsage, action: KeyboardInputAction) -> Bool {
        if action == .keyDown && !keyboardCaptureEnabled && hardwareKeyActivityEnabled { onHardwareKeyActivity?() }
        guard keyboardCaptureEnabled,
              let virtualKey = RemoteKeyboardKeyMapper.virtualKey(for: usage) else { return false }
        if action == .keyDown {
            if activeRemotePhysicalKeys[usage] == nil {
                activeRemotePhysicalKeys[usage] = virtualKey
                remoteVirtualKeyOwnerCounts[virtualKey, default: 0] += 1
            }
            // UIKit repeats still travel remotely without acquiring another owner.
        } else {
            guard activeRemotePhysicalKeys.removeValue(forKey: usage) != nil else { return true }
            let remaining = (remoteVirtualKeyOwnerCounts[virtualKey] ?? 1) - 1
            if remaining > 0 {
                remoteVirtualKeyOwnerCounts[virtualKey] = remaining
                return true
            }
            remoteVirtualKeyOwnerCounts.removeValue(forKey: virtualKey)
        }
        onKeyboardInput?(KeyboardInputCommand(action: action, virtualKey: virtualKey))
        return true
    }

    func unhandledHardwarePresses(_ presses: Set<UIPress>, action: KeyboardInputAction) -> Set<UIPress> {
        // UIKit supplies a set: apply modifiers before ordinary Down events,
        // and release them after ordinary Up events in the same batch.
        let ordered = presses.sorted { lhs, rhs in
            let left = hardwareKeyUsage(for: lhs)?.rawValue ?? 0
            let right = hardwareKeyUsage(for: rhs)?.rawValue ?? 0
            let leftModifier = (0xE0...0xE7).contains(left)
            let rightModifier = (0xE0...0xE7).contains(right)
            if leftModifier != rightModifier {
                return action == .keyDown ? leftModifier : !leftModifier
            }
            return left < right
        }
        return Set(ordered.filter { press in
            guard let usage = hardwareKeyUsage(for: press) else { return true }
            return !handleHardwareKey(usage, action: action)
        })
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledHardwarePresses(presses, action: .keyDown)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledHardwarePresses(presses, action: .keyUp)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = unhandledHardwarePresses(presses, action: .keyUp)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    // MARK: Callbacks (set by PencilTouchView.updateUIView)
    public var onPencilInput:    ((PencilPacket) -> Void)?
    public var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?
    public var onNetworkSend:    ((Data) -> Void)?
    public var onDirectTouchContact: ((DirectTouchContactCommand) -> Void)?
    public var onPointerInput: ((PointerInputCommand) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var contentViewport: VideoContentViewport? {
        willSet { if newValue != contentViewport { retireDirectTouch() } }
    }
    private var directTouchEnabled = false
    private var directTouchGeneration: UInt64?
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
    private var activeDirectContact: (id: UInt64, point: CGPoint)?

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
        if lastReportedBounds != nil { retireDirectTouch() }
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

        guard directTouchEnabled else { return }
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

    func configureDirectTouch(active: Bool, generation: UInt64) {
        if directTouchGeneration != generation || !active { retireDirectTouch() }
        directTouchGeneration = generation
        directTouchEnabled = active
    }

    func retireDirectTouch() {
        if let active = activeDirectContact {
            activeDirectContact = nil
            onDirectTouchContact?(DirectTouchContactCommand(phase: .cancel, pressure: 255, contactID: active.id,
                x: UInt16(clamping: Int((active.point.x * 65_535).rounded())),
                y: UInt16(clamping: Int((active.point.y * 65_535).rounded()))))
        }
        _ = directGesture.retire()
        directTouchIDs.removeAll()
    }

    private func emit(_ outputs: [DirectTouchGestureOutput]) { emitDirectOutputs(outputs) }

    func emitDirectOutputs(_ outputs: [DirectTouchGestureOutput]) {
        for output in outputs {
            switch output {
            case .directTouch(let phase, let id, let point, let pressure):
                let mapped = contentViewport?.normalizedPoint(for: point, in: bounds)
                if phase == .down {
                    guard directTouchEnabled, let mapped, activeDirectContact == nil else { continue }
                    activeDirectContact = (id, mapped)
                } else {
                    guard activeDirectContact?.id == id else { continue }
                    if phase == .update, mapped == nil { continue }
                }
                guard let normalized = mapped ?? activeDirectContact?.point else { continue }
                if phase == .up || phase == .cancel { activeDirectContact = nil }
                else { activeDirectContact = (id, normalized) }
                onDirectTouchContact?(DirectTouchContactCommand(phase: phase, pressure: pressure, contactID: id,
                    x: UInt16(clamping: Int((normalized.x * 65_535).rounded())),
                    y: UInt16(clamping: Int((normalized.y * 65_535).rounded()))))
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

// MARK: - Native software keyboard; Hardware V1 above remains unchanged.
public enum RemoteKeyboardMode: Equatable {
    case none, hardware, softwareAvailable, softwareOpen
    static func resolve(active: Bool, hardware: Bool, requested: Bool) -> RemoteKeyboardMode {
        !active ? .none : hardware ? .hardware : requested ? .softwareOpen : .softwareAvailable
    }
}
enum SoftwareKeyboardEmission: Equatable { case text(String), key(UInt16) }
enum SoftwareKeyboardRouter {
    static func route(_ text: String) -> [SoftwareKeyboardEmission] {
        guard !text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && ![8, 9, 10, 13].contains($0.value)
        }) else { return [] }
        var result: [SoftwareKeyboardEmission] = []
        var buffer = ""
        var previousCR = false
        func flush() { if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" } }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 13: flush(); result.append(.key(0x0D)); previousCR = true
            case 10: flush(); if !previousCR { result.append(.key(0x0D)) }; previousCR = false
            case 9: flush(); result.append(.key(0x09)); previousCR = false
            case 8: flush(); result.append(.key(0x08)); previousCR = false
            default:
                previousCR = false
                buffer.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }
}
struct SoftwareKeyboardCommittedShadow {
    static let maximumCharacters = 128
    private(set) var text = ""

    func delta(to current: String) -> [SoftwareKeyboardEmission]? {
        let previous = Array(text)
        let next = Array(current)
        var prefix = 0
        // Character equality normalizes canonically equivalent text; wire text must not.
        while prefix < min(previous.count, next.count),
              Array(String(previous[prefix]).utf8) == Array(String(next[prefix]).utf8) {
            prefix += 1
        }
        let suffix = String(next.dropFirst(prefix))
        let inserted = SoftwareKeyboardRouter.route(suffix)
        guard suffix.isEmpty || !inserted.isEmpty else { return nil }
        return Array(repeating: .key(0x08), count: previous.count - prefix) + inserted
    }

    mutating func commit(_ current: String) {
        text = String(current.suffix(Self.maximumCharacters))
    }
    mutating func reset() { text = "" }
}

final class RemoteSoftwareKeyboardTextView: UITextView, UITextViewDelegate {
    var deliveryEnabled = false
    var onEmission: ((SoftwareKeyboardEmission) -> Void)?
    var onDismiss: (() -> Void)?
    var onHardwarePresses: ((Set<UIPress>, KeyboardInputAction) -> Set<UIPress>)?
    private var consuming = false
    private var committedShadow = SoftwareKeyboardCommittedShadow()
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        delegate = self
        backgroundColor = .clear; textColor = .clear; tintColor = .clear
        // Keep native IME context; unsupported predictive rewriting remains disabled.
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        isScrollEnabled = false; isAccessibilityElement = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }
    required init?(coder: NSCoder) { nil }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = onHardwarePresses?(presses, .keyDown) ?? presses
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = onHardwarePresses?(presses, .keyUp) ?? presses
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = onHardwarePresses?(presses, .keyUp) ?? presses
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
    func consumeCommittedBuffer() {
        guard !consuming else { return }
        guard deliveryEnabled else { discardBuffer(); return }
        guard markedTextRange == nil else { return }
        let committed = text ?? ""
        guard let delta = committedShadow.delta(to: committed) else {
            consuming = true; text = committedShadow.text; consuming = false
            return
        }
        guard let emit = onEmission else { return }
        consuming = true
        defer {
            consuming = false
            if !deliveryEnabled { discardBuffer() }
        }
        for emission in delta {
            guard deliveryEnabled else { return }
            emit(emission)
        }
        guard deliveryEnabled else { return }
        committedShadow.commit(committed)
        if Array(committed.utf8) != Array(committedShadow.text.utf8) { text = committedShadow.text }
        selectedRange = NSRange(location: committedShadow.text.utf16.count, length: 0)
    }
    func textViewDidChange(_ textView: UITextView) { consumeCommittedBuffer() }
    override func insertText(_ text: String) { super.insertText(text); consumeCommittedBuffer() }
    override func unmarkText() { super.unmarkText(); consumeCommittedBuffer() }
    override func deleteBackward() {
        guard deliveryEnabled else { discardBuffer(); return }
        if markedTextRange != nil || !(text ?? "").isEmpty || !committedShadow.text.isEmpty {
            super.deleteBackward()
            consumeCommittedBuffer()
        }
        else { onEmission?(.key(0x08)) }
    }
    private func discardBuffer() {
        guard !consuming else { return }
        consuming = true; text = ""; super.unmarkText(); text = ""; committedShadow.reset(); consuming = false
    }
    func deactivateAndDiscardComposition() {
        deliveryEnabled = false; discardBuffer(); resignFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        deliveryEnabled = false; discardBuffer()
        return super.resignFirstResponder()
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        deliveryEnabled = false; discardBuffer(); onDismiss?()
    }
}
