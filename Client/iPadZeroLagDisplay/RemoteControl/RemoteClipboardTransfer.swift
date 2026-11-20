import CryptoKit
import Foundation

/// One clipboard update at a time, owned by the network queue.
final class RemoteClipboardTransfer {
    typealias Wire = RemoteClipboardProtocol

    let offer: Wire.Offer
    let outgoing: Bool
    let started: TimeInterval
    private(set) var progressed: TimeInterval
    private(set) var revision: Int?
    private var bytes: Data
    private var hash = SHA256()
    private var sentBytes = 0
    private var index: UInt32 = 0
    private var accepted = false
    private var ended = false

    init(offer: Wire.Offer, outgoingBytes: Data? = nil, now: TimeInterval) {
        self.offer = offer
        outgoing = outgoingBytes != nil
        bytes = outgoingBytes ?? Data()
        started = now
        progressed = now
    }

    var deadline: TimeInterval { min(progressed + 10, started + 120) }

    func expired(now: TimeInterval) -> Bool { now >= deadline }

    func accept(revision: Int, now: TimeInterval) -> Bool {
        guard !accepted, !ended else { return false }
        accepted = true
        self.revision = revision
        progressed = now
        return true
    }

    func append(index: UInt32, offset: Int, data: Data, maxChunk: Int, now: TimeInterval) -> Bool {
        guard !outgoing, accepted, !ended, index == self.index, offset == bytes.count,
              data.count <= maxChunk, !data.isEmpty, data.count <= offer.length - offset else { return false }
        bytes.append(data)
        hash.update(data: data)
        self.index += 1
        progressed = now
        return true
    }

    func finish(length: Int, digest: Data, now: TimeInterval) -> Data? {
        guard !outgoing, accepted, !ended, length == offer.length, bytes.count == length,
              digest == offer.digest, Data(hash.finalize()) == digest else { return nil }
        ended = true
        progressed = now
        let result = bytes
        bytes = Data()
        return result
    }

    func next(maxChunk: Int, now: TimeInterval) -> Wire.Message? {
        guard outgoing, accepted, !ended else { return nil }
        progressed = now
        if sentBytes == bytes.count {
            ended = true
            bytes = Data()
            return .end(offer.prefix, offer.length, offer.digest)
        }
        let end = min(sentBytes + maxChunk, bytes.count)
        let message = Wire.Message.chunk(offer.prefix, index, sentBytes, bytes.subdata(in: sentBytes..<end))
        index += 1
        sentBytes = end
        return message
    }

    var awaitingResult: Bool { outgoing && ended }
}

/// Main-actor pasteboard work and writer admission share a small, payload-free fence.
final class RemoteClipboardAuthority {
    typealias Wire = RemoteClipboardProtocol
    struct Grant: Equatable {
        let token: UUID
        let epoch: UInt64
        let directions: UInt8
        let maxBytes: Int
    }

    private let lock = NSLock()
    private var active = false
    private var grant: Grant?
    private var deadline: TimeInterval = 0
    private var transfer: Wire.Prefix?
    private var transferDeadline: TimeInterval = 0

    var sceneActive: Bool { withLock { active } }

    func setSceneActive(_ value: Bool) {
        withLock {
            active = value
            if !value {
                grant = nil
                transfer = nil
            }
        }
    }

    func update(_ state: Wire.State?, deadline: TimeInterval, transfer: RemoteClipboardTransfer?) {
        withLock {
            grant = state.map { Grant(token: $0.token, epoch: $0.epoch, directions: $0.directions, maxBytes: $0.maxBytes) }
            self.deadline = deadline
            self.transfer = transfer?.offer.prefix
            transferDeadline = transfer?.deadline ?? 0
        }
    }

    func allows(_ grant: Grant, direction: UInt8, prefix: Wire.Prefix? = nil) -> Bool {
        withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return active && self.grant == grant && grant.directions & direction != 0 && now < deadline &&
                (prefix == nil || (transfer == prefix && now < transferDeadline))
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
