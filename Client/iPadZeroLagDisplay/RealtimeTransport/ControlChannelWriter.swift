import Foundation
import Network

/// Serializes every send issued against one control `NWConnection`.
/// Callers must invoke this object only on its injected queue.
final class ControlChannelWriter {
    struct DiagnosticContext {
        let sequence: UInt64
        let event: String
    }

    typealias Sender = (
        Data,
        DiagnosticContext?,
        @escaping (NWError?) -> Void
    ) -> Void

    private enum Priority {
        case reliable
        case telemetry
        case movement
        case bulk
        case pacedBulk

        var isBulk: Bool { self == .bulk || self == .pacedBulk }
    }

    private struct Pending {
        let data: Data
        let priority: Priority
        let generation: UInt64
        let diagnostic: DiagnosticContext?
        let ready: (() -> Bool)?
        let completion: (NWError?) -> Void
    }

    private static let reliableCapacity = 64
    private let queue: DispatchQueue
    private let sender: Sender
    private var pending: [Pending] = []
    private var sending = false
    private var activeSendID: UInt64 = 0
    private var inFlight: Pending?
    private var generation: UInt64 = 0

    init(queue: DispatchQueue, sender: @escaping Sender) {
        self.queue = queue
        self.sender = sender
    }

    func begin(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        self.generation = generation
        pending.removeAll(keepingCapacity: true)
        if !sending { drain() }
    }

    /// Returns false only when reliable backpressure reaches the fixed bound.
    /// State transitions therefore remain visible to the caller instead of being
    /// silently dropped like lossy telemetry.
    @discardableResult
    func enqueue(
        _ data: Data,
        diagnostic: DiagnosticContext? = nil,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard reliableCount < Self.reliableCapacity else {
            return false
        }
        pending.append(Pending(
            data: data,
            priority: .reliable,
            generation: generation,
            diagnostic: diagnostic,
            ready: nil,
            completion: completion))
        drain()
        return true
    }

    /// A readiness predicate places the frame on the independently bounded paced lane.
    @discardableResult
    func enqueueBulk(_ data: Data, ready: (() -> Bool)? = nil, completion: @escaping (NWError?) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let priority: Priority = ready == nil ? .bulk : .pacedBulk
        let count = pending.filter { $0.priority == priority }.count + (inFlight?.priority == priority ? 1 : 0)
        guard count < 2 else { return false }
        pending.append(Pending(data: data, priority: priority, generation: generation, diagnostic: nil, ready: ready, completion: completion))
        drain()
        return true
    }
    /// Telemetry is latest-wins. Replacing an unsent report keeps reliable input
    /// transitions within the bounded queue without creating a second writer.
    func enqueueTelemetry(
        _ data: Data,
        diagnostic: DiagnosticContext? = nil,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeAll { $0.priority == .telemetry }
        pending.append(Pending(
            data: data,
            priority: .telemetry,
            generation: generation,
            diagnostic: diagnostic,
            ready: nil,
            completion: completion))
        drain()
    }

    /// Pointer movement is latest-wins, independently from telemetry. It is
    /// deliberately separate so a feedback report cannot erase the current
    /// pointer position and vice versa.
    func enqueueMovement(
        _ data: Data,
        diagnostic: DiagnosticContext? = nil,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeAll { $0.priority == .movement }
        pending.append(Pending(
            data: data,
            priority: .movement,
            generation: generation,
            diagnostic: diagnostic,
            ready: nil,
            completion: completion))
        drain()
    }

    /// Starts the next send only from the previous send's completion.
    func drain() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !sending, !pending.isEmpty else { return }
        let index: Int
        if let control = pending.firstIndex(where: { !$0.priority.isBulk }) {
            index = control
        } else if pending[0].ready?() != false {
            index = 0
        } else if let unpaced = pending.firstIndex(where: { $0.priority == .bulk }) {
            // Paused file sends leave room for clipboard on the same control stream.
            index = unpaced
        } else {
            return
        }
        let next = pending.remove(at: index)
        sending = true
        inFlight = next
        activeSendID &+= 1
        let sendID = activeSendID
        sender(next.data, next.diagnostic) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.sending, self.activeSendID == sendID else { return }
                self.sending = false
                self.inFlight = nil
                if next.generation == self.generation {
                    next.completion(error)
                }
                self.drain()
            }
        }
    }

    /// Drop unsent input at a local eligibility boundary, retaining terminal events
    /// and the active write. Settle discarded work successfully: suspension is not a socket fault.
    func discardPending(where predicate: (Data) -> Bool, error: NWError? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        let removed = pending.filter { predicate($0.data) }
        pending.removeAll { predicate($0.data) }
        for item in removed { item.completion(error) }
    }

    /// Retires queued transfer frames without disturbing reliable input or the active write.
    func cancelBulk() {
        dispatchPrecondition(condition: .onQueue(queue))
        let removed = pending.filter { $0.priority.isBulk }
        pending.removeAll { $0.priority.isBulk }
        // Settle ownership after queue mutation so callbacks may safely enqueue.
        for item in removed { item.completion(.posix(.ECANCELED)) }
    }

    /// Keeps an in-flight send serialized, but drops all stale queued work.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
    }

    /// Use only after retiring the underlying connection. Ordinary cancel()
    /// retains serialization when the same socket may still be in use.
    func abandonConnection() {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        activeSendID &+= 1
        sending = false
        inFlight = nil
    }

    private var reliableCount: Int {
        pending.reduce(into: 0) { count, item in
            if item.priority == .reliable { count += 1 }
        } + (inFlight?.priority == .reliable ? 1 : 0)
    }
}
