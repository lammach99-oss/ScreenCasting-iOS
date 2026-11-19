import Foundation

/// One instance per authenticated remote connection. Mutated on the network queue.
struct RemoteFileAccess {
    enum Selection { case upload([URL]), download }
    enum Effect { case send(RemoteFileProtocol.Message), upload([URL]), retire }
    private struct Request {
        let id: UInt64
        let operation: RemoteFileProtocol.Operation
        let selection: Selection
    }

    let identity = UUID()
    private var lastRequest: UInt64 = 0
    private var pending: Request?
    private var writtenRequest: UInt64?
    private var abandonedRequests: Set<UInt64> = []
    private var waitingSince: TimeInterval?
    private var incomingReady = false
    private var incomingIDs: Set<UUID> = []
    private var retiredGrants: Set<UUID> = []
    private var desktopEpoch: UInt64?
    private(set) var grant: UUID?
    private(set) var directions: RemoteFileProtocol.Direction = .none
    private(set) var status: String?
    var waiting: Bool { pending != nil || incomingReady }
    var mayUpload: Bool { directions.rawValue & RemoteFileProtocol.Direction.toHost.rawValue != 0 }

    mutating func desktopRequiresRevocation(_ context: RemoteInputContextCommand) -> Bool {
        let changed = desktopEpoch.map { $0 != context.desktopEpoch } ?? false
        desktopEpoch = context.desktopEpoch
        return context.desktop != 1 || changed
    }

    func mayWriteRequest(_ id: UInt64) -> Bool {
        pending?.id == id
    }
    mutating func didStartRequest(_ id: UInt64) { writtenRequest = id }

    private mutating func control(_ op: RemoteFileProtocol.Operation, _ directions: RemoteFileProtocol.Direction,
                                  _ grant: UUID) -> RemoteFileProtocol.Message? {
        guard lastRequest < UInt64.max else { return nil }
        lastRequest += 1
        return .control(operation: op, requestId: lastRequest, directions: directions, grantId: grant)
    }

    mutating func start(_ selection: Selection, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RemoteFileProtocol.Message? {
        guard !waiting, incomingIDs.count < 1024, retiredGrants.count < 1024, abandonedRequests.count < 1024 else { return nil }
        guard let grant else {
            guard let message = control(.requestGrant, .both, RemoteFileProtocol.emptyID) else { return nil }
            pending = Request(id: lastRequest, operation: .requestGrant, selection: selection)
            waitingSince = now
            status = "Waiting for file permission on the PC."
            return message
        }
        guard case .download = selection, directions.rawValue & RemoteFileProtocol.Direction.toController.rawValue != 0 else {
            status = "The PC did not allow that transfer direction."
            return nil
        }
        guard let message = control(.requestHostFiles, .toController, grant) else { return nil }
        pending = Request(id: lastRequest, operation: .requestHostFiles, selection: selection)
        waitingSince = now
        status = "Ask the person at the PC to choose files."
        return message
    }

    mutating func receive(_ message: RemoteFileProtocol.Message, allowed: Bool,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [Effect] {
        guard case let .state(phase, id, reason, directions, grantId) = message else { return [] }
        if abandonedRequests.contains(id) {
            if phase == .pending { return [] }
            abandonedRequests.remove(id)
            if phase == .granted {
                retiredGrants.insert(grantId)
                return control(.release, .none, grantId).map { [.send($0)] } ?? []
            }
            return []
        }
        if phase == .revoked, grantId == grant {
            clear()
            pending = nil
            status = "The PC ended file access."
            return [.retire]
        }
        guard let request = pending, request.id == id, writtenRequest == id else { return [] }
        if phase == .pending { return [] }
        if phase == .denied {
            pending = nil
            status = reason == .noControl ? "Turn on Control on the PC to transfer files." :
                reason == .userDeclined ? "The request was declined on the PC." : "The PC could not allow file transfer."
            if reason == .invalidGrant || reason == .scopeLost || reason == .noControl {
                clear()
                return [.retire]
            }
            return []
        }
        switch (request.operation, phase) {
        case (.requestGrant, .granted):
            pending = nil
            guard allowed, !retiredGrants.contains(grantId) else {
                retiredGrants.insert(grantId)
                return control(.release, .none, grantId).map { [.send($0)] } ?? []
            }
            grant = grantId
            self.directions = directions
            status = "File access granted."
            switch request.selection {
            case .upload(let urls):
                if mayUpload { return [.upload(urls)] }
            case .download:
                if let message = start(.download, now: now) { return [.send(message)] }
            }
            status = "The PC did not allow that transfer direction."
        case (.requestHostFiles, .hostFilesReady) where grant == grantId:
            pending = nil
            incomingReady = allowed
            waitingSince = now
            if incomingReady { status = "Waiting for the selected files." }
        default: break
        }
        return []
    }

    mutating func takeIncomingOffer(grant: UUID, offer: UUID) -> Bool {
        guard self.grant == grant, incomingIDs.count < 1024,
              incomingIDs.insert(offer).inserted, incomingReady else { return false }
        incomingReady = false
        status = nil
        return true
    }

    mutating func revoke() -> RemoteFileProtocol.Message? {
        if let pending, pending.operation == .requestGrant, pending.id == writtenRequest {
            abandonedRequests.insert(pending.id) // A delayed Granted still needs a Release.
        }
        pending = nil
        let previous = grant
        clear()
        status = nil
        return previous.flatMap { control(.release, .none, $0) }
    }

    func expire(now: TimeInterval) -> Bool {
        guard waiting, let waitingSince, now - waitingSince >= 60 else { return false }
        return true
    }

    mutating func markTimedOut() { status = "The PC did not answer the file request in time." }

    private mutating func clear() {
        if let grant { retiredGrants.insert(grant) }
        grant = nil
        directions = .none
        incomingReady = false
    }
}

struct RemoteFileMediaPacing {
    private var bytes = 0
    private var lastSample: TimeInterval?
    private var lastPresented: UInt32?
    private var healthyAt: TimeInterval?
    private var bytesPerSecond = 0.0
    private(set) var nextWrite: TimeInterval = 0

    mutating func received(bytes count: Int) { bytes += count }

    mutating func feedback(now: TimeInterval, presented: UInt32, queueAge: UInt16, drops: UInt16) {
        if lastSample == nil { lastSample = now }
        guard let lastSample, now - lastSample >= 1 else { return }
        if presented != 0, presented != lastPresented, queueAge <= 100, drops == 0, bytes > 0 {
            bytesPerSecond = min(250_000, Double(bytes) / (now - lastSample) / 10)
            healthyAt = now
        } else { healthyAt = nil }
        lastPresented = presented
        self.lastSample = now
        bytes = 0
    }

    func rate(now: TimeInterval, unsettled: Bool) -> Double {
        guard !unsettled, let healthyAt, now - healthyAt < 3 else { return 0 }
        return bytesPerSecond
    }

    mutating func reserve(bytes: Int, now: TimeInterval, rate: Double) {
        nextWrite = now + Double(bytes) / rate
    }
}
