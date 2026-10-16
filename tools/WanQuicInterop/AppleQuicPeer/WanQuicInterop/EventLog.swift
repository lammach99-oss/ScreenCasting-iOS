import Foundation
import Network

enum LaneEvidence {
    static func extractFields(role: String, laneID: UUID, options: NWProtocolQUIC.Options) -> [String: Any] {
        var fields = fields(role: role, laneID: laneID, state: "extract")
        fields["extractEndpoint"] = "nil"
        fields["direction"] = String(describing: options.direction)
        fields["isDatagram"] = options.isDatagram
        fields["optionsALPN"] = TestProtocol.alpn
        return fields
    }
    static func fields(role: String, laneID: UUID, state: String, error: NWError? = nil) -> [String: Any] {
        var fields: [String: Any] = ["laneRole": role, "laneID": laneID.uuidString, "networkState": state]
        if let error {
            switch error {
            case .posix(let code): fields["nativeErrorDomain"] = "POSIX"; fields["nativeErrorCode"] = Int(code.rawValue)
            case .dns(let code): fields["nativeErrorDomain"] = "DNS"; fields["nativeErrorCode"] = Int(code)
            case .tls(let code): fields["nativeErrorDomain"] = "TLS"; fields["nativeErrorCode"] = Int(code)
            @unknown default: fields["nativeErrorDomain"] = "unknown"; fields["nativeErrorCode"] = (error as NSError).code
            }
            fields["nativeErrorDescription"] = String(describing: error).prefix(512).description
            let bridged = error as NSError
            fields["bridgedDomain"] = bridged.domain
            fields["bridgedCode"] = bridged.code
            if let underlying = bridged.userInfo[NSUnderlyingErrorKey] as? NSError {
                fields["underlyingDomain"] = underlying.domain
                fields["underlyingCode"] = underlying.code
            }
        }
        return fields
    }
}

struct EvidenceSnapshot {
    var runID = "None"
    var generation: UInt64 = 0
    var connectionState = "Idle"
    var lastEvent = "None"
    var appleCapacity: Int?
    var controlReplies = 0
    var hostDatagrams = 0
    var sendErrors = 0
    var truncated = false
    var storageError: String?
    var fileURL: URL?
}

final class EvidenceRecorder {
    private let lock = NSLock()
    private let directory: URL
    private let maximumBytes: Int
    private let retainedRuns: Int
    private var handle: FileHandle?
    private var bytes = 0
    private var state = EvidenceSnapshot()
    init(directory: URL, maximumBytes: Int = 4 * 1024 * 1024, retainedRuns: Int = 8) {
        self.directory = directory
        self.maximumBytes = max(0, maximumBytes)
        self.retainedRuns = max(1, retainedRuns)
    }
    deinit { try? handle?.close() }
    @discardableResult
    func beginRun(generation: UInt64) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try handle?.close(); handle = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("WanQuicInterop-\(id).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        bytes = 0; state = EvidenceSnapshot()
        state.runID = id; state.generation = generation; state.fileURL = url
        let logs = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.creationDateKey]).filter {
                $0.lastPathComponent.hasPrefix("WanQuicInterop-") && $0.pathExtension == "jsonl"
            }.sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
        for old in logs.filter({ $0 != url }).prefix(max(0, logs.count - retainedRuns)) {
            try FileManager.default.removeItem(at: old)
        }
        return url
    }
    @discardableResult
    func append(json: Data, event: String, generation: UInt64, value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        state.lastEvent = event
        switch event {
        case "group_ready_exact_alpn": state.connectionState = "Connected"
        case "control_same_group": state.connectionState = "Control ready"
        case "datagram_same_group": state.connectionState = "DATAGRAM ready"
        case "run_started": state.connectionState = "Connecting"
        case "run_retired": state.connectionState = "Retired"
        case "control_reply": state.controlReplies += 1
        case "host_datagram_received": state.hostDatagrams += 1
        case "send_rejected": state.sendErrors += 1
        case "apple_capacity": state.appleCapacity = value
        default:
            if event.contains("failed") || event.contains("fault") || event.contains("mismatch") {
                state.connectionState = "Failed"
            }
        }
        guard let handle else { state.storageError = "No active evidence file"; return false }
        var line = json; line.append(0x0a)
        guard line.count <= maximumBytes - bytes else { state.truncated = true; return false }
        do {
            try handle.write(contentsOf: line)
            try handle.synchronize() // evidence is durable without an attached debugger
            bytes += line.count
            return true
        } catch { state.storageError = error.localizedDescription; return false }
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0); try handle.synchronize()
        bytes = 0
        let id = state.runID, generation = state.generation, url = state.fileURL
        state = EvidenceSnapshot(); state.runID = id; state.generation = generation; state.fileURL = url
    }
    func snapshot() -> EvidenceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    func setError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        state.storageError = error.localizedDescription
    }
    // Copy a synchronized immutable export so later callbacks cannot modify a shared file.
    func export(to directory: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        try handle?.synchronize()
        guard let source = state.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("WanQuicInterop-export-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

enum EventLog {
    private static let recorder = EvidenceRecorder(directory:
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    static func beginRun(generation: UInt64) {
        do { _ = try recorder.beginRun(generation: generation) }
        catch { recorder.setError(error) }
        write("run_started", generation: generation, owner: UUID())
    }
    static func clear() { do { try recorder.clear() } catch { recorder.setError(error) } }
    static func snapshot() -> EvidenceSnapshot { recorder.snapshot() }
    static func export() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WanQuicInteropExports")
        // Exports are temporary. Remove old copies only on an explicit new export.
        try? FileManager.default.removeItem(at: directory)
        return try recorder.export(to: directory)
    }
    // Existing event semantics/fields remain unchanged; only synthetic metadata.
    static func write(_ event: String, generation: UInt64, owner: UUID, sequence: UInt32 = 0, value: Int = 0, details: [String: Any] = [:]) {
        var fields: [String: Any] = details
        fields.merge(["event": event, "generation": generation,
            "owner": owner.uuidString, "sequence": sequence, "value": value,
            "monotonicSeconds": ProcessInfo.processInfo.systemUptime]) { _, base in base }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            _ = recorder.append(json: data, event: event, generation: generation, value: value)
        }
    }
}
