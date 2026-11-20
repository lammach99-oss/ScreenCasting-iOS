import Foundation

enum RemoteSecureDesktopProtocol {
    enum Operation: UInt8 { case controlOn = 1, controlOff, presented }
    enum Desktop: UInt8 { case unknown, standard, winlogon, screenSaver, unavailable = 255 }
    enum Phase: UInt8 { case hidden, preparing, firstFrame, unavailable }
    enum Backend: UInt8 { case none, dxgi, gdi }
    enum Permissions: UInt8 { case none = 0, video = 1, videoAndInputAfterPresented = 3 }
    enum Reason: UInt8 { case none, policy, noControl, transition, captureFailed, scopeLost, inputFailed }

    enum Message: Equatable {
        case request(operation: Operation, videoSequence: UInt32, captureRevision: UInt64, sourceEpoch: UInt64)
        case state(desktop: Desktop, phase: Phase, backend: Backend, permissions: Permissions, reason: Reason,
                   captureRevision: UInt64, sourceEpoch: UInt64, firstVideoSequence: UInt32)
        case sasAvailability(available: Bool)

        var type: WireMessageType {
            switch self {
            case .request: return .remoteSecureDesktopRequest
            case .state: return .remoteSecureDesktopState
            case .sasAvailability: return .remoteSasAvailability
            }
        }
    }

    private static let requestSize = 24, stateSize = 32, sasAvailabilitySize = 2

    static func isValidLength(type: WireMessageType, length: Int) -> Bool {
        switch type {
        case .remoteSecureDesktopRequest: return length == requestSize
        case .remoteSecureDesktopState: return length == stateSize
        case .remoteSasAvailability: return length == sasAvailabilitySize
        default: return false
        }
    }

    static func encode(_ message: Message) -> Data? {
        var data: Data
        switch message {
        case let .request(operation, videoSequence, revision, source):
            data = Data(count: requestSize)
            data[1] = operation.rawValue
            data.storeLittleEndian(videoSequence, at: 4)
            data.storeLittleEndian(revision, at: 8)
            data.storeLittleEndian(source, at: 16)
        case let .state(desktop, phase, backend, permissions, reason, revision, source, videoSequence):
            data = Data(count: stateSize)
            data[1] = desktop.rawValue
            data[2] = phase.rawValue
            data[3] = backend.rawValue
            data[4] = permissions.rawValue
            data[5] = reason.rawValue
            data.storeLittleEndian(revision, at: 8)
            data.storeLittleEndian(source, at: 16)
            data.storeLittleEndian(videoSequence, at: 24)
        case let .sasAvailability(available):
            return Data([1, available ? 1 : 0])
        }
        data[0] = 1
        return decode(type: message.type, payload: data) == nil ? nil : data
    }

    static func decode(type: WireMessageType, payload: Data, flags: UInt16 = 0) -> Message? {
        guard flags == 0, isValidLength(type: type, length: payload.count) else { return nil }
        let data = Data(payload)
        guard data[0] == 1 else { return nil }
        if type == .remoteSasAvailability {
            guard data[1] <= 1 else { return nil }
            return .sasAvailability(available: data[1] == 1)
        }
        let revision = data.loadLittleEndian(UInt64.self, at: 8)
        let source = data.loadLittleEndian(UInt64.self, at: 16)
        switch type {
        case .remoteSecureDesktopRequest:
            let videoSequence = data.loadLittleEndian(UInt32.self, at: 4)
            guard let operation = Operation(rawValue: data[1]), data.loadLittleEndian(UInt16.self, at: 2) == 0 else { return nil }
            if operation == .presented {
                guard videoSequence != 0, revision != 0, source != 0 else { return nil }
            } else {
                guard videoSequence == 0, revision == 0, source == 0 else { return nil }
            }
            return .request(operation: operation, videoSequence: videoSequence, captureRevision: revision, sourceEpoch: source)
        case .remoteSecureDesktopState:
            let videoSequence = data.loadLittleEndian(UInt32.self, at: 24)
            guard let desktop = Desktop(rawValue: data[1]), let phase = Phase(rawValue: data[2]),
                  let backend = Backend(rawValue: data[3]), let permissions = Permissions(rawValue: data[4]),
                  let reason = Reason(rawValue: data[5]), data.loadLittleEndian(UInt16.self, at: 6) == 0,
                  data.loadLittleEndian(UInt32.self, at: 28) == 0, revision != 0,
                  source != 0 || desktop == .unknown || desktop == .unavailable else { return nil }
            let visibleLane = phase == .preparing || phase == .firstFrame
            guard visibleLane == (reason == .none),
                  !visibleLane || desktop == .standard || desktop == .winlogon else { return nil }
            if phase == .firstFrame {
                guard videoSequence != 0, backend != .none, backend != .gdi || desktop == .winlogon,
                      permissions == .video || (permissions == .videoAndInputAfterPresented && desktop == .winlogon) else { return nil }
            } else {
                guard videoSequence == 0, backend == .none, permissions == .none else { return nil }
            }
            return .state(desktop: desktop, phase: phase, backend: backend, permissions: permissions, reason: reason,
                          captureRevision: revision, sourceEpoch: source, firstVideoSequence: videoSequence)
        default: return nil
        }
    }
}

/// Connection-scoped publication and input gate, owned by the network queue.
struct RemoteSecureDesktopState {
    static let preferenceKey = "ScreenCasting.client.remoteSecureDesktop"
    typealias ProtocolMessage = RemoteSecureDesktopProtocol.Message
    typealias Desktop = RemoteSecureDesktopProtocol.Desktop

    enum Change: Equatable { case unchanged, fence, reconnect }
    enum VideoAdmission: Equatable { case pass, drop, barrier, invalid }

    private(set) var supported = false
    private(set) var sasAvailabilitySupported = false
    private var sasAvailable = false
    private(set) var covered = false
    private(set) var control = false
    private(set) var desktop: Desktop = .standard
    private(set) var sawStandardVideo = false
    private var state: ProtocolMessage?
    private var revision: UInt64 = 0
    private var retiredRevision: UInt64 = 0
    private var sourceEpoch: UInt64 = 0
    private var nextIDR: UInt32?
    private var awaitingDecoder: UInt64?
    private var discardPair = false
    private(set) var needsKeyframe = false
    private var pendingAck: ProtocolMessage?
    private var ackAdmitted = false

    var expectsIDR: Bool { nextIDR != nil }
    func awaitsWireIDR(sequence: UInt32) -> Bool { nextIDR == sequence }
    var restrictsFeatures: Bool { covered || desktop != .standard || pendingAck != nil }
    var canSas: Bool {
        if !supported { return true }
        guard control, !covered else { return false }
        if desktop == .standard { return sasAvailable }
        guard desktop == .winlogon, ackAdmitted,
              case .state(_, .firstFrame, _, .videoAndInputAfterPresented, _, _, _, _)? = state else { return false }
        return true
    }
    var allowsScanAndPointer: Bool { !restrictsFeatures || (desktop == .winlogon && canSas) }
    var hasPresentedBarrier: Bool { ackAdmitted }

    mutating func begin(accepted: UInt64, control: Bool) -> ProtocolMessage? {
        self = Self()
        supported = accepted & RemoteFeatureNegotiation.remoteSecureDesktopFeature != 0
        sasAvailabilitySupported = supported && accepted & RemoteFeatureNegotiation.remoteSasAvailabilityFeature != 0
        return setControl(control)
    }

    mutating func updateSasAvailability(_ available: Bool) {
        sasAvailable = sasAvailabilitySupported && control && available
    }

    mutating func setControl(_ enabled: Bool) -> ProtocolMessage? {
        guard supported, control != enabled else { return nil }
        control = enabled
        sasAvailable = false
        if !enabled, desktop != .standard {
            retiredRevision = revision
            fence()
        }
        return .request(operation: enabled ? .controlOn : .controlOff,
                        videoSequence: 0, captureRevision: 0, sourceEpoch: 0)
    }

    mutating func observeDesktop(_ desktop: Desktop, adaptiveOwner: Bool, timedVideo: Bool) -> Change {
        guard supported, self.desktop != desktop else { return .unchanged }
        self.desktop = desktop
        retiredRevision = revision
        fence()
        return adaptiveOwner || timedVideo ? .reconnect : .fence
    }

    mutating func receive(_ message: ProtocolMessage, adaptiveOwner: Bool, timedVideo: Bool) -> Change {
        guard supported, case let .state(desktop, phase, _, _, _, revision, epoch, sequence) = message else { return .unchanged }
        let stale = revision <= retiredRevision || revision < self.revision || message == state ||
            (epoch != 0 && epoch < sourceEpoch)
        let invalidContinuation: Bool
        if revision == self.revision, case let .state(oldDesktop, oldPhase, _, _, _, _, oldEpoch, _)? = state {
            invalidContinuation = oldDesktop != desktop || oldEpoch != epoch || oldPhase == .firstFrame ||
                oldPhase == .unavailable || (oldPhase == .preparing && phase == .hidden)
        } else {
            invalidContinuation = false
        }
        if stale || invalidContinuation {
            if phase == .firstFrame { nextIDR = sequence; discardPair = true }
            return .unchanged
        }

        let changedSource = sourceEpoch != 0 && epoch != sourceEpoch
        let reconnect = timedVideo || (adaptiveOwner && (self.desktop != desktop || changedSource))
        self.desktop = desktop
        self.revision = revision
        sourceEpoch = max(sourceEpoch, epoch)
        state = message
        fence()
        nextIDR = phase == .firstFrame ? sequence : nil
        discardPair = desktop == .winlogon && !control
        return reconnect ? .reconnect : .fence
    }

    private mutating func fence() {
        covered = true
        discardPair = true
        awaitingDecoder = nil
        pendingAck = nil
        ackAdmitted = false
        needsKeyframe = false
        sawStandardVideo = false
    }

    mutating func admit(sequence: UInt32, isIDR: Bool, decoder: UInt64) -> VideoAdmission {
        if let expected = nextIDR {
            guard isIDR, sequence == expected else { return .invalid }
            nextIDR = nil
            guard !discardPair else { return .drop }
            awaitingDecoder = decoder
            return .barrier
        }
        if covered {
            if awaitingDecoder != nil { needsKeyframe = true }
            return .drop
        }
        if needsKeyframe {
            guard isIDR else { return .drop }
            needsKeyframe = false
        }
        if desktop == .standard { sawStandardVideo = true }
        return .pass
    }

    func awaitsPresentation(sequence: UInt32, decoder: UInt64) -> Bool {
        guard awaitingDecoder == decoder,
              case let .state(_, .firstFrame, _, _, _, _, _, expected)? = state else { return false }
        return sequence == expected
    }

    mutating func presented(sequence: UInt32, decoder: UInt64) -> ProtocolMessage? {
        guard awaitsPresentation(sequence: sequence, decoder: decoder),
              case let .state(_, .firstFrame, _, _, _, revision, epoch, _)? = state else { return nil }
        awaitingDecoder = nil
        covered = false
        sawStandardVideo = desktop == .standard
        let ack = ProtocolMessage.request(operation: .presented, videoSequence: sequence,
                                          captureRevision: revision, sourceEpoch: epoch)
        pendingAck = ack
        return ack
    }

    mutating func admitRequest(_ message: ProtocolMessage) -> Bool {
        guard supported, case let .request(operation, _, _, _) = message else { return false }
        guard operation == .presented else { return true }
        guard message == pendingAck else { return false }
        pendingAck = nil
        ackAdmitted = true
        return true
    }

    static func hasIDR(_ data: Data, lengthPrefixed: Bool) -> Bool {
        let ranges = lengthPrefixed ? LengthPrefixedNALScanner.ranges(in: data) : AnnexBNALScanner.ranges(in: data)
        return ranges?.contains { range in
            guard range.count >= 2 else { return false }
            let type = (data[range.lowerBound] >> 1) & 0x3f
            return type == 19 || type == 20
        } == true
    }
}
