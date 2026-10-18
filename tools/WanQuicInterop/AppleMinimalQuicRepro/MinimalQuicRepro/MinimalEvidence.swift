import Foundation

// Owner-queue confined. Summary has its own reserved slot and is never evicted.
final class MinimalEvidence {
    let identity: MinimalIdentity
    let limit: Int
    let optionalLimit: Int
    private(set) var records: [[String: Any]] = []
    private(set) var droppedDiagnostics = 0
    private(set) var storageError: String?
    private var optionalCount = 0
    private let fileURL: URL?
    var truncated: Bool { droppedDiagnostics != 0 }
    var captureComplete: Bool { !truncated && storageError == nil }
    init(identity: MinimalIdentity, limit: Int = 256, optionalLimit: Int = 128, fileURL: URL? = nil) {
        precondition(limit >= 2 && optionalLimit >= 0 && optionalLimit < limit)
        self.identity = identity
        self.limit = limit
        self.optionalLimit = optionalLimit
        self.fileURL = fileURL
        if let fileURL {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: fileURL, options: .atomic)
            } catch { storageError = String(describing: error).prefix(512).description }
        }
    }
    @discardableResult
    func record(_ event: String, identity candidate: MinimalIdentity, fields: [String: Any] = [:], critical: Bool = true) -> Bool {
        guard candidate == identity else { return false }
        guard records.count < limit - 1, critical || optionalCount < optionalLimit else {
            droppedDiagnostics += 1
            return false
        }
        if !critical { optionalCount += 1 }
        let entry = row(event, fields)
        records.append(entry)
        if let fileURL, storageError == nil {
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Self.encode(entry))
            } catch { storageError = String(describing: error).prefix(512).description }
        }
        return true
    }
    private func row(_ event: String, _ fields: [String: Any]) -> [String: Any] {
        var result = fields
        result["runID"] = identity.runID.uuidString
        result["groupID"] = identity.groupID.uuidString
        result["controlID"] = identity.controlID.uuidString
        result["generation"] = identity.generation
        result["event"] = event
        result["monotonicSeconds"] = ProcessInfo.processInfo.systemUptime
        return result
    }
    var summary: [String: Any] {
        row("capture_summary_detail", ["captureComplete": captureComplete,
            "droppedDiagnostics": droppedDiagnostics, "truncated": truncated,
            "storageError": storageError as Any? ?? NSNull(), "recordCount": records.count + 1])
    }
    static func encode(_ row: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    }
    func export(to url: URL) throws {
        do {
            var output = Data()
            for entry in records + [summary] { output.append(try Self.encode(entry)) }
            try output.write(to: url, options: .atomic)
        } catch {
            storageError = String(describing: error).prefix(512).description
            throw error
        }
    }
}
