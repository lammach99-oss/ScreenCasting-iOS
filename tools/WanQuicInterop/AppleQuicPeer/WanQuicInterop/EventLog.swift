import Foundation

enum EventLog {
    // Only synthetic record identities and numeric sizes; never user media/input.
    static func write(_ event: String, generation: UInt64, owner: UUID, sequence: UInt32 = 0, value: Int = 0) {
        let fields: [String: Any] = ["event": event, "generation": generation,
            "owner": owner.uuidString, "sequence": sequence, "value": value,
            "monotonicSeconds": ProcessInfo.processInfo.systemUptime]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line) }
    }
}