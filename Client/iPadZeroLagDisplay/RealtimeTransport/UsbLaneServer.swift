import CryptoKit
import Foundation
import Network

enum UsbLaneKind: UInt8, CaseIterable {
    case control = 1
    case video = 2
    case audio = 3

    var port: NWEndpoint.Port {
        switch self {
        case .control: return 12345
        case .video: return 12346
        case .audio: return 12347
        }
    }
}

struct UsbLaneBinding {
    static let version: UInt8 = 1
    static let signedSize = 25
    static let encodedSize = 60

    let sessionID: SessionID
    let lane: UsbLaneKind
    let generation: UInt64
    let mac: Data

    static func decode(_ data: Data) -> UsbLaneBinding? {
        guard data.count == encodedSize,
              data[17] == version,
              data[18] == 0,
              data[19] == 0,
              let sessionID = SessionID(bytes: data.subdata(in: 0..<16)),
              let lane = UsbLaneKind(rawValue: data[16])
        else { return nil }
        let generation = data.loadLittleEndian(UInt64.self, at: 20)
        guard generation != 0 else { return nil }
        return UsbLaneBinding(
            sessionID: sessionID,
            lane: lane,
            generation: generation,
            mac: data.subdata(in: 28..<60))
    }

    func validate(expectedSessionID: SessionID, secret: Data) -> Bool {
        guard sessionID == expectedSessionID,
              secret.count == 32,
              mac.count == 32
        else { return false }
        var signed = Data(count: Self.signedSize)
        sessionID.write(to: &signed, at: 0)
        signed[16] = lane.rawValue
        signed.storeLittleEndian(generation, at: 17)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: signed,
            using: SymmetricKey(data: secret)))
        return mac.timingSafeEquals(expected)
    }
}

final class UsbLaneServer {
    typealias ParametersProvider = () throws -> NWParameters
    typealias BoundHandler = (UsbLaneKind, UInt64, NWConnection) -> Void
    typealias FailureHandler = (Error) -> Void

    private let networkQueue: DispatchQueue
    private let parametersProvider: ParametersProvider
    private let onBound: BoundHandler
    private let onFailure: FailureHandler
    private var listeners: [UsbLaneKind: NWListener] = [:]
    private var connections: [UsbLaneKind: NWConnection] = [:]
    private var highestGeneration: [UsbLaneKind: UInt64] = [:]
    private var sessionID: SessionID?
    private var secret = Data()
    private var stopped = true

    init(
        networkQueue: DispatchQueue,
        parametersProvider: @escaping ParametersProvider,
        onBound: @escaping BoundHandler,
        onFailure: @escaping FailureHandler)
    {
        self.networkQueue = networkQueue
        self.parametersProvider = parametersProvider
        self.onBound = onBound
        self.onFailure = onFailure
    }

    func start(sessionID: SessionID, secret: Data) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.abortOnQueue()
            guard secret.count == 32 else { return }
            self.sessionID = sessionID
            self.secret = Data(secret)
            self.stopped = false
            do {
                try self.startListener(for: .video)
            } catch {
                self.abortOnQueue()
                self.onFailure(error)
                return
            }
            do {
                try self.startListener(for: .audio)
            } catch {
                // Audio is explicitly optional. The commit declares whether
                // Opus is active; the authenticated video lane remains usable.
            }
        }
    }

    func stop() {
        abort()
    }

    func finalize() {
        networkQueue.async { [weak self] in
            self?.finalizeOnQueue()
        }
    }

    func abort() {
        networkQueue.async { [weak self] in
            self?.abortOnQueue()
        }
    }

    private func startListener(for lane: UsbLaneKind) throws {
        let listener = try NWListener(
            using: parametersProvider(),
            on: lane.port)
        listeners[lane] = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, expectedLane: lane)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state,
               !self.stopped,
               lane != .audio {
                self.onFailure(error)
            }
        }
        listener.start(queue: networkQueue)
    }

    private func accept(
        _ connection: NWConnection,
        expectedLane: UsbLaneKind)
    {
        guard !stopped, connections[expectedLane] == nil else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receiveBinding(
                    connection,
                    expectedLane: expectedLane,
                    accumulated: Data())
            case .failed, .cancelled:
                if self.connections[expectedLane] === connection {
                    self.connections.removeValue(forKey: expectedLane)
                }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveBinding(
        _ connection: NWConnection,
        expectedLane: UsbLaneKind,
        accumulated: Data)
    {
        let totalSize = 16 + UsbLaneBinding.encodedSize
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: totalSize - accumulated.count)
        { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var bytes = accumulated
            if let content { bytes.append(content) }
            if let error {
                connection.cancel()
                self.onFailure(error)
                return
            }
            if bytes.count < totalSize && !isComplete {
                self.receiveBinding(
                    connection,
                    expectedLane: expectedLane,
                    accumulated: bytes)
                return
            }
            self.finishBinding(
                connection,
                expectedLane: expectedLane,
                bytes: bytes)
        }
    }

    private func finishBinding(
        _ connection: NWConnection,
        expectedLane: UsbLaneKind,
        bytes: Data)
    {
        guard bytes.count == 16 + UsbLaneBinding.encodedSize,
              bytes.loadLittleEndian(UInt32.self, at: 0) == 0x54534353,
              bytes[4] == 1,
              bytes[5] == 13,
              bytes.loadLittleEndian(UInt32.self, at: 8) ==
                UInt32(UsbLaneBinding.encodedSize),
              let expectedSession = sessionID,
              let binding = UsbLaneBinding.decode(
                bytes.subdata(in: 16..<bytes.count)),
              binding.lane == expectedLane,
              binding.validate(
                expectedSessionID: expectedSession,
                secret: secret),
              connections[expectedLane] == nil,
              binding.generation >
                (highestGeneration[expectedLane] ?? 0)
        else {
            sendResult(
                connection,
                lane: expectedLane,
                generation: 0,
                status: 1,
                thenCancel: true)
            return
        }

        highestGeneration[expectedLane] = binding.generation
        connections[expectedLane] = connection
        sendResult(
            connection,
            lane: expectedLane,
            generation: binding.generation,
            status: 0,
            thenCancel: false)
        { [weak self] in
            self?.onBound(expectedLane, binding.generation, connection)
        }
    }

    private func sendResult(
        _ connection: NWConnection,
        lane: UsbLaneKind,
        generation: UInt64,
        status: UInt8,
        thenCancel: Bool,
        completion: (() -> Void)? = nil)
    {
        guard let sessionID else {
            connection.cancel()
            return
        }
        var payload = Data(count: 28)
        payload[0] = 1
        payload[1] = lane.rawValue
        payload[2] = status
        sessionID.write(to: &payload, at: 4)
        payload.storeLittleEndian(generation, at: 20)

        var message = Data(count: 16)
        message.storeLittleEndian(UInt32(0x54534353), at: 0)
        message[4] = 1
        message[5] = 14
        message.storeLittleEndian(UInt32(payload.count), at: 8)
        message.append(payload)
        connection.send(
            content: message,
            completion: .contentProcessed { error in
                if thenCancel || error != nil {
                    connection.cancel()
                } else {
                    completion?()
                }
            })
    }

    private func finalizeOnQueue() {
        stopped = true
        listeners.values.forEach { $0.cancel() }
        listeners.removeAll()
        connections.removeAll()
        highestGeneration.removeAll()
        sessionID = nil
        secret.resetBytes(in: 0..<secret.count)
        secret.removeAll(keepingCapacity: false)
    }

    private func abortOnQueue() {
        connections.values.forEach { $0.cancel() }
        finalizeOnQueue()
    }
}

private extension Data {
    func timingSafeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for index in indices {
            difference |= self[index] ^ other[index]
        }
        return difference == 0
    }
}
