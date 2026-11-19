import Foundation

enum RemoteSecureDesktopProtocol {
    enum Operation: UInt8 { case controlOn = 1, controlOff, presented }
    enum Desktop: UInt8 { case unknown, standard, winlogon, screenSaver, unavailable = 255 }
    enum Phase: UInt8 { case hidden, preparing, firstFrame, unavailable }
    enum Backend: UInt8 { case none, dxgi, gdi }
    enum Permissions: UInt8 { case none = 0, video = 1, videoAndInputAfterPresented = 3 }
    enum Reason: UInt8 { case none, policy, noControl, transition, captureFailed, scopeLost, inputFailed }

    enum Message {
        case request(operation: Operation, videoSequence: UInt32, captureRevision: UInt64, sourceEpoch: UInt64)
        case state(desktop: Desktop, phase: Phase, backend: Backend, permissions: Permissions, reason: Reason,
                   captureRevision: UInt64, sourceEpoch: UInt64, firstVideoSequence: UInt32)

        var type: WireMessageType {
            switch self {
            case .request: return .remoteSecureDesktopRequest
            case .state: return .remoteSecureDesktopState
            }
        }
    }

    private static let requestSize = 24, stateSize = 32

    static func isValidLength(type: WireMessageType, length: Int) -> Bool {
        switch type {
        case .remoteSecureDesktopRequest: return length == requestSize
        case .remoteSecureDesktopState: return length == stateSize
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
        }
        data[0] = 1
        return decode(type: message.type, payload: data) == nil ? nil : data
    }

    static func decode(type: WireMessageType, payload: Data, flags: UInt16 = 0) -> Message? {
        guard flags == 0, isValidLength(type: type, length: payload.count) else { return nil }
        let data = Data(payload)
        guard data[0] == 1 else { return nil }
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
