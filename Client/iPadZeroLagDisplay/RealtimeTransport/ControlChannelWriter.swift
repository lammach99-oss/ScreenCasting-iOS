import Foundation
import Network

/// Serializes every send issued against one control `NWConnection`.
/// Callers must invoke this object only on its injected queue.
final class ControlChannelWriter {
    typealias Sender = (Data, @escaping (NWError?) -> Void) -> Void

    private enum Priority {
        case reliable
        case telemetry
        case movement
    }

    private struct Pending {
        let data: Data
        let priority: Priority
        let generation: UInt64
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
            completion: completion))
        drain()
        return true
    }

    /// Telemetry is latest-wins. Replacing an unsent report keeps reliable input
    /// transitions within the bounded queue without creating a second writer.
    func enqueueTelemetry(
        _ data: Data,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeAll { $0.priority == .telemetry }
        pending.append(Pending(
            data: data,
            priority: .telemetry,
            generation: generation,
            completion: completion))
        drain()
    }

    /// Pointer movement is latest-wins, independently from telemetry. It is
    /// deliberately separate so a feedback report cannot erase the current
    /// pointer position and vice versa.
    func enqueueMovement(
        _ data: Data,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        pending.removeAll { $0.priority == .movement }
        pending.append(Pending(
            data: data,
            priority: .movement,
            generation: generation,
            completion: completion))
        drain()
    }

    /// Starts the next send only from the previous send's completion.
    func drain() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !sending, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        sending = true
        inFlight = next
        activeSendID &+= 1
        let sendID = activeSendID
        sender(next.data) { [weak self] error in
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

    /// Keeps an in-flight send serialized, but drops all stale queued work.
    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
    }

    private var reliableCount: Int {
        pending.reduce(into: 0) { count, item in
            if item.priority == .reliable { count += 1 }
        } + (inFlight?.priority == .reliable ? 1 : 0)
    }
}
